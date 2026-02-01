#!/bin/bash

# This script is intended to sign blobs (arbitrary files) the traditional way -- within a private
# organization with a pre-generated key file. E.g., at this time it doesn't support keyless
# signing, transparency log uploads to Rekor, or other advanced features just yet.

set -e
set +o history

# Read in orb parameters
COSIGN_PRIVATE_KEY=${!PARAM_PRIVATE_KEY}
BLOB=$(circleci env subst "${PARAM_BLOB}")
SIGNATURE_OUTPUT=$(circleci env subst "${PARAM_SIGNATURE_OUTPUT}")
PASSWORD=${!PARAM_PASSWORD}

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    shred -vzuf -n 10 cosign.key 2> /dev/null || true
    unset PARAM_PRIVATE_KEY
    unset PARAM_PASSWORD
    unset PASSWORD
    unset COSIGN_PRIVATE_KEY
    unset COSIGN_PASSWORD
    echo "Secrets destroyed."
}
trap cleanup_secrets EXIT

# COSIGN_PASSWORD is a special env var used by the Cosign tool, and must be exported for
# it to be used by Cosign. Setting it here prevents the "cosign sign-blob" command from prompting
# for a password in the CI pipeline.
if ! type export | grep -q 'export is a shell builtin'; then
    echo "The export command is not a shell builtin. It is not safe to proceed."
    exit 1
fi
export COSIGN_PASSWORD="${PASSWORD}"

# Verify Cosign version is supported
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-)
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ] && [ "${COSIGN_MAJOR_VERSION}" != "3" ]; then
    echo "Unsupported Cosign version: ${COSIGN_MAJOR_VERSION}"
    cleanup_secrets
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Verify the blob file exists
if [[ ! -f "${BLOB}" ]]; then
    echo "ERROR: Blob file does not exist: ${BLOB}"
    cleanup_secrets
    exit 1
fi
echo "Blob file: ${BLOB}"

# Load the private key, normally a base64 encoded secret within a CircleCI context
# Note that a Cosign v2 key used with Cosign v1 may throw: unsupported pem type: ENCRYPTED SIGSTORE PRIVATE KEY
if [[ -z "${COSIGN_PRIVATE_KEY}" ]]; then
    echo "ERROR: Private key is empty. Check that the environment variable is set correctly."
    cleanup_secrets
    exit 1
fi
# Use printf instead of echo for more predictable handling of special characters
# The || true prevents set -e from exiting on decode failure; we check the result below
if ! printf '%s' "${COSIGN_PRIVATE_KEY}" | base64 --decode > cosign.key 2>&1; then
    echo "ERROR: Failed to decode private key. Ensure it is valid base64."
    cleanup_secrets
    exit 1
fi
if [[ ! -s cosign.key ]]; then
    echo "ERROR: Decoded private key is empty."
    cleanup_secrets
    exit 1
fi
echo "Wrote private key: cosign.key"
chmod 0400 cosign.key
echo "Set private key permissions: 0400"

# Build output signature flag if specified
OUTPUT_FLAG=""
if [[ -n "${SIGNATURE_OUTPUT}" ]]; then
    OUTPUT_FLAG="--output-signature=${SIGNATURE_OUTPUT}"
    echo "Signature output: ${SIGNATURE_OUTPUT}"
else
    echo "Signature output: stdout"
fi

# Sign the blob
echo "Signing ${BLOB}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    # Cosign v1: no tlog flags needed for sign-blob
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key cosign.key "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key cosign.key "${BLOB}"
    fi
elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key cosign.key --tlog-upload=false "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key cosign.key --tlog-upload=false "${BLOB}"
    fi
else
    # Cosign v3: Must disable the default signing config and new bundle format to use --output-signature
    # By default, v3 sets --use-signing-config=true which requires --bundle output format.
    # To use the legacy --output-signature flag, we disable both the signing config and new bundle format.
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key cosign.key --tlog-upload=false --use-signing-config=false --new-bundle-format=false "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key cosign.key --tlog-upload=false --use-signing-config=false --new-bundle-format=false "${BLOB}"
    fi
fi
