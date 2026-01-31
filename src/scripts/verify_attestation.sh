#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
PREDICATE_TYPE=$(circleci env subst "${PARAM_PREDICATE_TYPE}")
COSIGN_PUBLIC_KEY=${!PARAM_PUBLIC_KEY}

# Verify Cosign version is supported (v2+ required for --private-infrastructure flag)
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-)
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "2" ] && [ "${COSIGN_MAJOR_VERSION}" != "3" ]; then
    echo "Unsupported Cosign version: ${COSIGN_MAJOR_VERSION}. This command requires Cosign v2 or v3."
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    shred -vzuf -n 10 cosign.pub 2> /dev/null || true
    unset PARAM_PUBLIC_KEY
    unset COSIGN_PUBLIC_KEY
    echo "Secrets destroyed."
}
trap cleanup_secrets EXIT

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

# Verify image signature using the public key
echo "Verifying cosign signature for ${IMAGE}..."
cosign verify-attestation \
    --type "${PREDICATE_TYPE}" \
    --key cosign.pub \
    --private-infrastructure \
    "${IMAGE}"

# Cleanup
rm cosign.pub
