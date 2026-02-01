#!/bin/bash

# This script signs container images using Cosign.
# Supports two modes:
#   1. Private key signing - Traditional signing with a pre-generated key
#   2. Keyless signing - OIDC-based signing via Fulcio/Rekor (no key management)

set -e
set +o history

# Read in orb parameters
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
KEYLESS="${PARAM_KEYLESS:-0}"
ANNOTATIONS=$(circleci env subst "${PARAM_ANNOTATIONS}")
FULCIO_URL="${PARAM_FULCIO_URL:-https://fulcio.sigstore.dev}"
REKOR_URL="${PARAM_REKOR_URL:-https://rekor.sigstore.dev}"
# OIDC issuer for CircleCI keyless signing
# Default uses the organization-specific issuer URL (required by Fulcio)
# Can be overridden for private Fulcio deployments
if [[ -n "${PARAM_OIDC_ISSUER:-}" ]]; then
    OIDC_ISSUER="${PARAM_OIDC_ISSUER}"
elif [[ -n "${CIRCLE_ORGANIZATION_ID:-}" ]]; then
    OIDC_ISSUER="https://oidc.circleci.com/org/${CIRCLE_ORGANIZATION_ID}"
else
    # Fallback to base URL (may not work with all Fulcio configurations)
    OIDC_ISSUER="https://oidc.circleci.com"
fi

# Only read key-related params if not using keyless
if [[ "${KEYLESS}" != "1" ]]; then
    COSIGN_PRIVATE_KEY=${!PARAM_PRIVATE_KEY}
    PASSWORD=${!PARAM_PASSWORD}
fi

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    if [ -f cosign.key ]; then
        shred -vzuf -n 10 cosign.key 2> /dev/null || true
    fi
    unset PARAM_PRIVATE_KEY
    unset PARAM_PASSWORD
    unset PASSWORD
    unset COSIGN_PRIVATE_KEY
    unset COSIGN_PASSWORD
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

# Determine the image digest
echo "Determining image URI digest..."
IMAGE_URI_DIGEST=""
if command -v crane 1> /dev/null; then
    echo "  Tool: crane"
    DIGEST=$(crane digest "${IMAGE}")
    IMAGE_WITHOUT_TAG=$(echo "${IMAGE}" | cut -d ':' -f 1)
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
elif command -v docker 1> /dev/null; then
    echo "  Tool: docker"
    if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
        echo "The image exists locally."
    else
        echo "The image does not exist locally, but is needed by Docker to compute the digest."
        echo "Pulling image ${IMAGE}..."
        docker pull "${IMAGE}"
    fi
    DIGEST_WITH_REGISTRY=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}")
    DIGEST=$(echo "${DIGEST_WITH_REGISTRY}" | cut -d '@' -f 2)
    IMAGE_WITHOUT_TAG=$(echo "${IMAGE}" | cut -d ':' -f 1)
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
else
    echo "This orb requires that either crane or docker be installed."
    exit 1
fi
echo "  Image URI Digest: ${IMAGE_URI_DIGEST}"

# Build annotation flags if annotations are provided
ANNOTATION_FLAGS=()
if [[ -n "${ANNOTATIONS}" ]]; then
    echo "Processing annotations..."
    IFS=',' read -ra ANNOTATION_PAIRS <<< "${ANNOTATIONS}"
    for pair in "${ANNOTATION_PAIRS[@]}"; do
        pair=$(echo "${pair}" | xargs)
        if [[ -n "${pair}" ]]; then
            if [[ "${pair}" != *"="* ]]; then
                echo "ERROR: Invalid annotation format '${pair}'. Expected key=value."
                exit 1
            fi
            echo "  Adding annotation: ${pair}"
            ANNOTATION_FLAGS+=("-a" "${pair}")
        fi
    done
fi

# ==============================================================================
# KEYLESS SIGNING MODE
# ==============================================================================
if [[ "${KEYLESS}" == "1" ]]; then
    echo ""
    echo "=== Keyless Signing Mode ==="
    echo "Using CircleCI OIDC for identity-based signing"
    echo "  Fulcio URL: ${FULCIO_URL}"
    echo "  Rekor URL: ${REKOR_URL}"
    echo "  OIDC Issuer: ${OIDC_ISSUER}"
    echo ""

    # Get OIDC token with correct audience for Sigstore
    # The default CIRCLE_OIDC_TOKEN has org ID as audience, but Fulcio expects "sigstore"
    echo "Requesting OIDC token with Sigstore audience..."
    if ! command -v circleci &> /dev/null; then
        echo "ERROR: CircleCI CLI is not installed."
        echo "The circleci CLI is required to request OIDC tokens with custom audience."
        exit 1
    fi

    SIGSTORE_ID_TOKEN=$(circleci run oidc get --claims '{"aud": "sigstore"}')
    if [[ -z "${SIGSTORE_ID_TOKEN:-}" ]]; then
        echo "ERROR: Failed to get OIDC token from CircleCI."
        echo ""
        echo "Keyless signing requires CircleCI OIDC to be enabled."
        echo "Please ensure:"
        echo "  1. You are using CircleCI Cloud or Server 4.x+"
        echo "  2. OIDC is enabled for your organization"
        echo "  3. Your plan supports OIDC tokens"
        echo ""
        echo "Run the 'check_oidc' command to diagnose OIDC issues."
        exit 1
    fi
    export SIGSTORE_ID_TOKEN
    echo "OIDC token obtained (${#SIGSTORE_ID_TOKEN} characters)"

    # Sign the image using keyless mode
    echo "Signing ${IMAGE_URI_DIGEST} (keyless)..."

    if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
        # Cosign v1 requires COSIGN_EXPERIMENTAL=1 and explicit --identity-token
        COSIGN_EXPERIMENTAL=1 cosign sign \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            --identity-token="${SIGSTORE_ID_TOKEN}" \
            "${ANNOTATION_FLAGS[@]}" \
            -y \
            "${IMAGE_URI_DIGEST}"
    elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
        # Cosign v2
        cosign sign \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            "${ANNOTATION_FLAGS[@]}" \
            --yes \
            "${IMAGE_URI_DIGEST}"
    else
        # Cosign v3: must disable signing config when specifying explicit URLs
        cosign sign \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            "${ANNOTATION_FLAGS[@]}" \
            --yes \
            --use-signing-config=false \
            "${IMAGE_URI_DIGEST}"
    fi

    echo ""
    echo "=== Keyless Signing Complete ==="
    echo "Image signed: ${IMAGE_URI_DIGEST}"
    echo "Signature recorded in Rekor transparency log"
    exit 0
fi

# ==============================================================================
# PRIVATE KEY SIGNING MODE
# ==============================================================================
echo ""
echo "=== Private Key Signing Mode ==="

# Export password for Cosign (prevents interactive prompt)
if ! type export | grep -q 'export is a shell builtin'; then
    echo "The export command is not a shell builtin. It is not safe to proceed."
    exit 1
fi
export COSIGN_PASSWORD="${PASSWORD}"

# Load the private key
if [[ -z "${COSIGN_PRIVATE_KEY}" ]]; then
    echo "ERROR: Private key is empty. Check that the environment variable is set correctly."
    exit 1
fi
if ! printf '%s' "${COSIGN_PRIVATE_KEY}" | base64 --decode > cosign.key 2>&1; then
    echo "ERROR: Failed to decode private key. Ensure it is valid base64."
    exit 1
fi
if [[ ! -s cosign.key ]]; then
    echo "ERROR: Decoded private key is empty."
    exit 1
fi
echo "Wrote private key: cosign.key"
chmod 0400 cosign.key
echo "Set private key permissions: 0400"

# Sign the image using its digest
echo "Signing ${IMAGE_URI_DIGEST}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign sign --key cosign.key --no-tlog-upload "${ANNOTATION_FLAGS[@]}" "${IMAGE_URI_DIGEST}"
elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
    cosign sign --key cosign.key --tlog-upload=false "${ANNOTATION_FLAGS[@]}" "${IMAGE_URI_DIGEST}"
else
    # Cosign v3: Create an empty signing config for private infrastructure
    SIGNING_CONFIG=$(mktemp)
    printf '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}\n' > "${SIGNING_CONFIG}"
    cosign sign --key cosign.key --signing-config="${SIGNING_CONFIG}" "${ANNOTATION_FLAGS[@]}" "${IMAGE_URI_DIGEST}"
    rm -f "${SIGNING_CONFIG}"
fi

echo ""
echo "=== Private Key Signing Complete ==="
echo "Image signed: ${IMAGE_URI_DIGEST}"
