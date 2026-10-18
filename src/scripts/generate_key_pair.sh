#!/bin/bash

# This script generates a Cosign key pair for development and testing purposes.
# WARNING: For production use, store keys in a proper key management system
# (AWS KMS, HashiCorp Vault, GCP KMS, etc.) or CircleCI contexts.

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the keys and password.
set +o xtrace

# Read in orb parameters. Each one is the name of an environment variable.
PRIVATE_KEY_ENV_VAR="${PARAM_PRIVATE_KEY_ENV_VAR}"
PUBLIC_KEY_ENV_VAR="${PARAM_PUBLIC_KEY_ENV_VAR}"
PASSWORD_ENV_VAR="${PARAM_PASSWORD_ENV_VAR}"

# The names are written to BASH_ENV as they are, so each must be a valid
# shell variable name.
for name in "${PRIVATE_KEY_ENV_VAR}" "${PUBLIC_KEY_ENV_VAR}" "${PASSWORD_ENV_VAR}"; do
    if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: '${name}' is not a valid environment variable name." >&2
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

# cosign generate-key-pair writes cosign.key and cosign.pub into the current
# directory. It runs in this private directory instead of the working
# directory, where it would overwrite (and the cleanup would then destroy) the
# project's own key files, or follow a symlink planted there. Start empty so
# the cleanup trap never removes a KEY_DIR inherited from the job environment.
KEY_DIR=""

# Cleanup function to securely delete key files
cleanup_key_files() {
    echo "Cleaning up key files..."
    if [[ -n "${KEY_DIR:-}" ]]; then
        shred -vzuf -n 10 "${KEY_DIR}/cosign.key" 2> /dev/null || true
        shred -vzuf -n 10 "${KEY_DIR}/cosign.pub" 2> /dev/null || true
        rm -rf "${KEY_DIR}"
    fi
    echo "Key files destroyed."
}
trap cleanup_key_files EXIT

# COSIGN_PASSWORD is used by cosign generate-key-pair
if ! type export | grep -q 'export is a shell builtin'; then
    echo "ERROR: The export command is not a shell builtin. It is not safe to proceed." >&2
    exit 1
fi
export COSIGN_PASSWORD="${PASSWORD}"

# Generate the key pair. The subshell keeps the step's working directory.
if ! KEY_DIR=$(umask 077 && mktemp -d); then
    echo "ERROR: Could not create a private temporary directory for the key pair." >&2
    exit 1
fi
echo "Generating Cosign key pair..."
(cd "${KEY_DIR}" && umask 077 && cosign generate-key-pair)

# Verify the key files were created
if [[ ! -f "${KEY_DIR}/cosign.key" ]] || [[ ! -f "${KEY_DIR}/cosign.pub" ]]; then
    echo "ERROR: Key pair generation failed. Key files not found." >&2
    exit 1
fi

# Base64 encode the keys
echo "Encoding keys..."
PRIVATE_KEY_B64=$(base64 -w0 "${KEY_DIR}/cosign.key")
PUBLIC_KEY_B64=$(base64 -w0 "${KEY_DIR}/cosign.pub")

# Export to BASH_ENV for use in subsequent steps. %q quotes each value for
# the shell, so no character in the password can end the value early or run
# as a command when later steps source BASH_ENV.
echo "Exporting keys to environment variables..."
echo "  ${PASSWORD_ENV_VAR} (password)"
echo "  ${PRIVATE_KEY_ENV_VAR} (base64-encoded private key)"
echo "  ${PUBLIC_KEY_ENV_VAR} (base64-encoded public key)"

if [[ -z "${BASH_ENV:-}" ]]; then
    echo "ERROR: BASH_ENV is not set, so the keys cannot be exported to later steps." >&2
    exit 1
fi
{
    printf 'export %s=%q\n' "${PASSWORD_ENV_VAR}" "${PASSWORD}"
    printf 'export %s=%q\n' "${PRIVATE_KEY_ENV_VAR}" "${PRIVATE_KEY_B64}"
    printf 'export %s=%q\n' "${PUBLIC_KEY_ENV_VAR}" "${PUBLIC_KEY_B64}"
} >> "${BASH_ENV}"

echo ""
echo "Key pair generated successfully."
echo "WARN: These keys are for development/testing only." >&2
echo "For production, use a key management system or store keys in CircleCI contexts." >&2
