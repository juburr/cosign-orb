#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
PREDICATE_TYPE=$(circleci env subst "${PARAM_PREDICATE_TYPE}")
COSIGN_PUBLIC_KEY=${!PARAM_PUBLIC_KEY}

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    shred -vzu -n 10 cosign.pub 2> /dev/null || true
    unset PARAM_PUBLIC_KEY
    unset COSIGN_PUBLIC_KEY
    echo "Secrets destroyed."
}
trap cleanup_secrets EXIT

# Load public key, normally a base64 encoded secret within a CircleCI context
echo "${COSIGN_PUBLIC_KEY}" | base64 --decode > cosign.pub

# Verify image signature using the public key
echo "Verifying cosign signature for ${IMAGE}..."
cosign verify-attestation \
    --type "${PREDICATE_TYPE}" \
    --key cosign.pub \
    --private-infrastructure \
    "${IMAGE}"

# Cleanup
rm cosign.pub
