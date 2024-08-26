#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
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
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ]; then
    echo "Unsupported Cosign version: ${MAJOR_VERSION}"
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Load public key, normally a base64 encoded secret within a CircleCI context
echo "${COSIGN_PUBLIC_KEY}" | base64 --decode > cosign.pub
echo "Wrote public key: cosign.pub"
chmod 0400 cosign.pub
echo "Set public key permissions: 0400"

# Verify image signature using the public key
echo "Verifying cosign signature for ${IMAGE}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign verify --key cosign.pub "${IMAGE}"
else
    cosign verify --private-infrastructure=true --key cosign.pub "${IMAGE}"
fi

# Cleanup
rm cosign.pub
