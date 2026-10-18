#!/bin/bash

# This script generates a Cosign key pair for development and testing purposes.
# WARNING: For production use, store keys in a proper key management system
# (AWS KMS, HashiCorp Vault, GCP KMS, etc.) or CircleCI contexts.

set -e
set +o history

# Read in orb parameters. Each one is the name of an environment variable.
PRIVATE_KEY_ENV_VAR="${PARAM_PRIVATE_KEY_ENV_VAR}"
PUBLIC_KEY_ENV_VAR="${PARAM_PUBLIC_KEY_ENV_VAR}"
PASSWORD_ENV_VAR="${PARAM_PASSWORD_ENV_VAR}"

# The names are written to BASH_ENV as they are, so each must be a valid
# shell variable name.
for name in "${PRIVATE_KEY_ENV_VAR}" "${PUBLIC_KEY_ENV_VAR}" "${PASSWORD_ENV_VAR}"; do
    if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: '${name}' is not a valid environment variable name."
        exit 1
    fi
done

# Use the password the variable named by password_env_var already holds.
# Otherwise generate a random one.
PASSWORD="${!PASSWORD_ENV_VAR:-}"
if [[ -n "${PASSWORD}" ]]; then
    echo "Using the password in ${PASSWORD_ENV_VAR}."
else
    echo "${PASSWORD_ENV_VAR} is empty or not set, generating a random password..."
    PASSWORD=$(openssl rand -base64 32)
fi

# Cleanup function to securely delete key files
cleanup_key_files() {
    echo "Cleaning up key files..."
    shred -vzuf -n 10 cosign.key 2> /dev/null || true
    shred -vzuf -n 10 cosign.pub 2> /dev/null || true
    echo "Key files destroyed."
}
trap cleanup_key_files EXIT

# COSIGN_PASSWORD is used by cosign generate-key-pair
if ! type export | grep -q 'export is a shell builtin'; then
    echo "The export command is not a shell builtin. It is not safe to proceed."
    exit 1
fi
export COSIGN_PASSWORD="${PASSWORD}"

# Generate the key pair
echo "Generating Cosign key pair..."
cosign generate-key-pair

# Verify the key files were created
if [[ ! -f cosign.key ]] || [[ ! -f cosign.pub ]]; then
    echo "ERROR: Key pair generation failed. Key files not found."
    exit 1
fi

# Base64 encode the keys
echo "Encoding keys..."
PRIVATE_KEY_B64=$(base64 -w0 cosign.key)
PUBLIC_KEY_B64=$(base64 -w0 cosign.pub)

# Export to BASH_ENV for use in subsequent steps. %q quotes each value for
# the shell, so no character in the password can end the value early or run
# as a command when later steps source BASH_ENV.
echo "Exporting keys to environment variables..."
echo "  ${PASSWORD_ENV_VAR} (password)"
echo "  ${PRIVATE_KEY_ENV_VAR} (base64-encoded private key)"
echo "  ${PUBLIC_KEY_ENV_VAR} (base64-encoded public key)"

{
    printf 'export %s=%q\n' "${PASSWORD_ENV_VAR}" "${PASSWORD}"
    printf 'export %s=%q\n' "${PRIVATE_KEY_ENV_VAR}" "${PRIVATE_KEY_B64}"
    printf 'export %s=%q\n' "${PUBLIC_KEY_ENV_VAR}" "${PUBLIC_KEY_B64}"
} >> "${BASH_ENV}"

echo ""
echo "Key pair generated successfully."
echo "WARNING: These keys are for development/testing only."
echo "For production, use a key management system or store keys in CircleCI contexts."
