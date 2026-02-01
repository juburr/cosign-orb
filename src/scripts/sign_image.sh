#!/bin/bash

# This script is intended to sign container images the traditional way -- within a private
# organization with a pre-generated key file. E.g., at this time it doesn't support keyless
# signing, transparency log uploads to Rekor, or other advanced features just yet.

set -e
set +o history

# Read in orb parameters
COSIGN_PRIVATE_KEY=${!PARAM_PRIVATE_KEY}
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
PASSWORD=${!PARAM_PASSWORD}
ANNOTATIONS=$(circleci env subst "${PARAM_ANNOTATIONS}")

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
# it to be used by Cosign. Setting it here prevents the "cosign sign" command from prompting
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

# Determine the image digest
echo "Determining image URI digest..."
IMAGE_URI_DIGEST=""
if command -v crane 1> /dev/null; then
    echo "  Tool: crane"
    # While docker inspect returns registry/image@sha256:hash, crane simply returns
    # sha256:hash. We need to add the registry/image@ prefix ourselves.
    DIGEST=$(crane digest "${IMAGE}")
    IMAGE_WITHOUT_TAG=$(echo "${IMAGE}" | cut -d ':' -f 1)
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
elif command -v docker 1> /dev/null; then
    echo "  Tool: docker"

    # Docker requires the image to exist locally in order for
    # the "docker inspect" command to return the digest. It
    # fails with a hard error otherwise.
    if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
        echo "The image exists locally."
    else
        echo "The image does not exist locally, but is needed by Docker to compute the digest."
        echo "Pulling image ${IMAGE}..."
        docker pull "${IMAGE}"
    fi

    # When pushing a single image to multiple registries, docker inspect always returns
    # a registry/image@sha256:hash value with the first registry you attempted to use, even if
    # $IMAGE is that of the second registry. Reconstruct the correct value ourselves.
    DIGEST_WITH_REGISTRY=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}")
    DIGEST=$(echo "${DIGEST_WITH_REGISTRY}" | cut -d '@' -f 2)
    IMAGE_WITHOUT_TAG=$(echo "${IMAGE}" | cut -d ':' -f 1)
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
else
    echo "This orb requires that either crane or docker be installed."
    cleanup_secrets
    exit 1
fi
echo "  Image URI Digest: ${IMAGE_URI_DIGEST}"

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

# Build annotation flags if annotations are provided
ANNOTATION_FLAGS=()
if [[ -n "${ANNOTATIONS}" ]]; then
    echo "Processing annotations..."
    IFS=',' read -ra ANNOTATION_PAIRS <<< "${ANNOTATIONS}"
    for pair in "${ANNOTATION_PAIRS[@]}"; do
        # Trim whitespace
        pair=$(echo "${pair}" | xargs)
        if [[ -n "${pair}" ]]; then
            # Validate that the pair contains an equals sign
            if [[ "${pair}" != *"="* ]]; then
                echo "ERROR: Invalid annotation format '${pair}'. Expected key=value."
                cleanup_secrets
                exit 1
            fi
            echo "  Adding annotation: ${pair}"
            ANNOTATION_FLAGS+=("-a" "${pair}")
        fi
    done
fi

# Sign the image using its digest
echo "Signing ${IMAGE_URI_DIGEST}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign sign --key cosign.key --no-tlog-upload "${ANNOTATION_FLAGS[@]}" "${IMAGE_URI_DIGEST}"
elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
    cosign sign --key cosign.key --tlog-upload=false "${ANNOTATION_FLAGS[@]}" "${IMAGE_URI_DIGEST}"
else
    # Cosign v3: Create an empty signing config for private infrastructure (no Rekor, Fulcio, TSA)
    # This is the non-deprecated approach, replacing --tlog-upload=false
    SIGNING_CONFIG=$(mktemp)
    printf '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}\n' > "${SIGNING_CONFIG}"
    cosign sign --key cosign.key --signing-config="${SIGNING_CONFIG}" "${ANNOTATION_FLAGS[@]}" "${IMAGE_URI_DIGEST}"
    rm -f "${SIGNING_CONFIG}"
fi
