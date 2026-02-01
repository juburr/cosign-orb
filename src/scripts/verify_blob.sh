#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
BLOB=$(circleci env subst "${PARAM_BLOB}")
SIGNATURE=$(circleci env subst "${PARAM_SIGNATURE}")
COSIGN_PUBLIC_KEY=${!PARAM_PUBLIC_KEY}

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    shred -vzuf -n 10 cosign.pub 2> /dev/null || true
    unset PARAM_PUBLIC_KEY
    unset COSIGN_PUBLIC_KEY
    echo "Secrets destroyed."
}
trap cleanup_secrets EXIT

# Verify Cosign version is supported
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-)
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ] && [ "${COSIGN_MAJOR_VERSION}" != "3" ]; then
    echo "Unsupported Cosign version: ${COSIGN_MAJOR_VERSION}"
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Verify the blob file exists
if [[ ! -f "${BLOB}" ]]; then
    echo "ERROR: Blob file does not exist: ${BLOB}"
    exit 1
fi
echo "Blob file: ${BLOB}"

# Verify the signature file exists
if [[ ! -f "${SIGNATURE}" ]]; then
    echo "ERROR: Signature file does not exist: ${SIGNATURE}"
    exit 1
fi
echo "Signature file: ${SIGNATURE}"

# Load public key, normally a base64 encoded secret within a CircleCI context
if [[ -z "${COSIGN_PUBLIC_KEY}" ]]; then
    echo "ERROR: Public key is empty. Check that the environment variable is set correctly."
    exit 1
fi
# Use printf instead of echo for more predictable handling of special characters
if ! printf '%s' "${COSIGN_PUBLIC_KEY}" | base64 --decode > cosign.pub 2>&1; then
    echo "ERROR: Failed to decode public key. Ensure it is valid base64."
    exit 1
fi
if [[ ! -s cosign.pub ]]; then
    echo "ERROR: Decoded public key is empty."
    exit 1
fi
echo "Wrote public key: cosign.pub"
chmod 0400 cosign.pub
echo "Set public key permissions: 0400"

# Verify blob signature using the public key
echo "Verifying cosign signature for ${BLOB}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign verify-blob --key cosign.pub --signature "${SIGNATURE}" "${BLOB}"
else
    # Cosign v2 and v3: --private-infrastructure flag works in both versions
    cosign verify-blob --key cosign.pub --signature "${SIGNATURE}" --private-infrastructure "${BLOB}"
fi

# Cleanup
rm cosign.pub
