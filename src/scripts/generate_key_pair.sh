#!/bin/bash

# This script generates a Cosign key pair for development and testing purposes.
# WARNING: For production use, store keys in a proper key management system
# (AWS KMS, HashiCorp Vault, GCP KMS, etc.) or CircleCI contexts.

set -e
set +o history

# Read in orb parameters
PASSWORD=$(circleci env subst "${PARAM_PASSWORD}")
PRIVATE_KEY_VAR="${PARAM_PRIVATE_KEY_VAR}"
PUBLIC_KEY_VAR="${PARAM_PUBLIC_KEY_VAR}"
PASSWORD_VAR="${PARAM_PASSWORD_VAR}"

# Generate a random password if none provided
if [[ -z "${PASSWORD}" ]]; then
    echo "No password provided, generating a random one..."
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

# Export to BASH_ENV for use in subsequent steps
echo "Exporting keys to environment variables..."
echo "  ${PASSWORD_VAR} (password)"
echo "  ${PRIVATE_KEY_VAR} (base64-encoded private key)"
echo "  ${PUBLIC_KEY_VAR} (base64-encoded public key)"

{
    echo "export ${PASSWORD_VAR}='${PASSWORD}'"
    echo "export ${PRIVATE_KEY_VAR}='${PRIVATE_KEY_B64}'"
    echo "export ${PUBLIC_KEY_VAR}='${PUBLIC_KEY_B64}'"
} >> "${BASH_ENV}"

echo ""
echo "Key pair generated successfully."
echo "WARNING: These keys are for development/testing only."
echo "For production, use a key management system or store keys in CircleCI contexts."
