#!/bin/bash

# This script attaches attestations to container images using Cosign.
# Supports two modes:
#   1. Private key attestation - Traditional attestation with a pre-generated key
#   2. Keyless attestation - OIDC-based attestation via Fulcio/Rekor (no key management)

set -e
set +o history

# Read in orb parameters
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
PREDICATE=$(circleci env subst "${PARAM_PREDICATE}")
PREDICATE_TYPE=$(circleci env subst "${PARAM_PREDICATE_TYPE}")
KEYLESS="${PARAM_KEYLESS:-0}"
FULCIO_URL="${PARAM_FULCIO_URL:-https://fulcio.sigstore.dev}"
REKOR_URL="${PARAM_REKOR_URL:-https://rekor.sigstore.dev}"

is_keyless_enabled() {
    case "${KEYLESS,,}" in
        1|true) return 0 ;;
        *) return 1 ;;
    esac
}

# OIDC issuer for CircleCI keyless attestation
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
if ! is_keyless_enabled; then
    COSIGN_PRIVATE_KEY=${!PARAM_PRIVATE_KEY}

    # COSIGN_PASSWORD is a special env var used by the Cosign tool, and must be exported for
    # it to be used by Cosign. Setting it here prevents the "cosign attest" command from prompting
    # for a password in the CI pipeline.
    if ! type export | grep -q 'export is a shell builtin'; then
        echo "The export command is not a shell builtin. It is not safe to proceed."
        exit 1
    fi
    export COSIGN_PASSWORD=${!PARAM_PASSWORD}
fi

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    if [ -f cosign.key ]; then
        shred -vzuf -n 10 cosign.key 2> /dev/null || true
    fi
    unset PARAM_PRIVATE_KEY
    unset PARAM_PASSWORD
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
    echo "  DIGEST: ${DIGEST}"
    IMAGE_WITHOUT_TAG=$(echo "${IMAGE}" | cut -d ':' -f 1)
    echo "  IMAGE_WITHOUT_TAG: ${IMAGE_WITHOUT_TAG}"
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
    echo "  IMAGE_URI_DIGEST: ${IMAGE_URI_DIGEST}"
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
    echo "  DIGEST_WITH_REGISTRY: ${DIGEST_WITH_REGISTRY}"
    DIGEST=$(echo "${DIGEST_WITH_REGISTRY}" | cut -d '@' -f 2)
    echo "  DIGEST: ${DIGEST}"
    IMAGE_WITHOUT_TAG=$(echo "${IMAGE}" | cut -d ':' -f 1)
    echo "  IMAGE_WITHOUT_TAG: ${IMAGE_WITHOUT_TAG}"
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
    echo "  IMAGE_URI_DIGEST: ${IMAGE_URI_DIGEST}"
else
    echo "This orb requires that either crane or docker be installed."
    cleanup_secrets
    exit 1
fi

# ==============================================================================
# KEYLESS ATTESTATION MODE
# ==============================================================================
if is_keyless_enabled; then
    echo ""
    echo "=== Keyless Attestation Mode ==="
    echo "Using CircleCI OIDC for identity-based attestation"
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
        echo "Keyless attestation requires CircleCI OIDC to be enabled."
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

    # Attest the image using keyless mode
    echo "Attesting ${IMAGE_URI_DIGEST} (keyless)..."
    echo "  Predicate: ${PREDICATE}"
    echo "  Predicate Type: ${PREDICATE_TYPE}"

    if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
        # Cosign v1 requires COSIGN_EXPERIMENTAL=1 and explicit --identity-token
        COSIGN_EXPERIMENTAL=1 cosign attest \
            --predicate "${PREDICATE}" \
            --type "${PREDICATE_TYPE}" \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            --identity-token="${SIGSTORE_ID_TOKEN}" \
            -y \
            "${IMAGE_URI_DIGEST}"
    elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
        # Cosign v2
        cosign attest \
            --predicate "${PREDICATE}" \
            --type "${PREDICATE_TYPE}" \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            --yes \
            "${IMAGE_URI_DIGEST}"
    else
        # Cosign v3: must disable signing config when specifying explicit URLs
        cosign attest \
            --predicate "${PREDICATE}" \
            --type "${PREDICATE_TYPE}" \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            --yes \
            --use-signing-config=false \
            "${IMAGE_URI_DIGEST}"
    fi

    echo ""
    echo "=== Keyless Attestation Complete ==="
    echo "Image attested: ${IMAGE_URI_DIGEST}"
    echo "Attestation recorded in Rekor transparency log"
    exit 0
fi

# ==============================================================================
# PRIVATE KEY ATTESTATION MODE
# ==============================================================================
echo ""
echo "=== Private Key Attestation Mode ==="

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

# Attest the image using its digest
echo "Attesting ${IMAGE_URI_DIGEST}..."
echo "  Predicate: ${PREDICATE}"
echo "  Predicate Type: ${PREDICATE_TYPE}"
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign attest \
        --predicate "${PREDICATE}" \
        --type "${PREDICATE_TYPE}" \
        --key cosign.key \
        --no-tlog-upload \
        "${IMAGE_URI_DIGEST}"
elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
    cosign attest \
        --predicate "${PREDICATE}" \
        --type "${PREDICATE_TYPE}" \
        --key cosign.key \
        --tlog-upload=false \
        "${IMAGE_URI_DIGEST}"
else
    # Cosign v3: Create an empty signing config for private infrastructure (no Rekor, Fulcio, TSA)
    # This is the non-deprecated approach, replacing --tlog-upload=false
    SIGNING_CONFIG=$(mktemp)
    printf '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}\n' > "${SIGNING_CONFIG}"
    cosign attest \
        --predicate "${PREDICATE}" \
        --type "${PREDICATE_TYPE}" \
        --key cosign.key \
        --signing-config="${SIGNING_CONFIG}" \
        "${IMAGE_URI_DIGEST}"
    rm -f "${SIGNING_CONFIG}"
fi

echo ""
echo "=== Private Key Attestation Complete ==="
echo "Image attested: ${IMAGE_URI_DIGEST}"
