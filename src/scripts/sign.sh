#!/bin/bash

# This script signs container images using Cosign.
# Supports two modes:
#   1. Private key signing - Traditional signing with a pre-generated key
#   2. Keyless signing - OIDC-based signing via Fulcio/Rekor (no key management)

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the key and password.
set +o xtrace

# Read in orb parameters
IMAGE=$(printf '%s' "${PARAM_IMAGE}" | circleci env subst)
KEYLESS="${PARAM_KEYLESS:-0}"
ANNOTATIONS=$(printf '%s' "${PARAM_ANNOTATIONS}" | circleci env subst)
BUNDLE_FORMAT="${PARAM_BUNDLE_FORMAT:-auto}"
# Temporary signing config created by this script. Start empty so the cleanup
# trap never removes a SIGNING_CONFIG path inherited from the job environment.
SIGNING_CONFIG=""
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
    COSIGN_PRIVATE_KEY=${!PARAM_PRIVATE_KEY:-}
    PASSWORD=${!PARAM_PASSWORD:-}
fi

# Private directory for the decoded key. A cosign.key in the working directory
# may be the project's own file, or a symlink that would redirect the write.
# Start empty so the cleanup trap never removes a KEY_DIR inherited from the
# job environment.
KEY_DIR=""

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    if [[ -n "${KEY_DIR:-}" ]]; then
        if [ -f "${KEY_DIR}/cosign.key" ]; then
            shred -vzuf -n 10 "${KEY_DIR}/cosign.key" 2> /dev/null || true
        fi
        rm -rf "${KEY_DIR}"
    fi
    if [[ -n "${SIGNING_CONFIG:-}" ]]; then
        rm -f "${SIGNING_CONFIG}"
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
# A failure here leaves the version empty, which the check below reports.
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-) || true
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ] && [ "${COSIGN_MAJOR_VERSION}" != "3" ]; then
    echo "ERROR: Unsupported Cosign version: ${COSIGN_MAJOR_VERSION}" >&2
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Load the shared helpers (src/scripts/lib/image_ref.sh and bundle_format.sh).
if [[ -z "${SCRIPT_IMAGE_REF_LIB:-}" || -z "${SCRIPT_BUNDLE_FORMAT_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded. SCRIPT_IMAGE_REF_LIB or SCRIPT_BUNDLE_FORMAT_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_IMAGE_REF_LIB}"
eval "${SCRIPT_BUNDLE_FORMAT_LIB}"

# Pick the signature storage format flags before touching the registry.
echo "Signature storage format: ${BUNDLE_FORMAT}"
if [[ "${KEYLESS}" == "1" ]]; then
    keyless_sign_flags "${COSIGN_MAJOR_VERSION}" sign "${BUNDLE_FORMAT}" || exit 1
else
    # Cosign 3 turns the transparency log off with an empty signing config (no Rekor, Fulcio or TSA).
    SIGNING_CONFIG=$(mktemp)
    printf '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}\n' > "${SIGNING_CONFIG}"
    private_key_sign_flags "${COSIGN_MAJOR_VERSION}" sign "${BUNDLE_FORMAT}" "${SIGNING_CONFIG}" || exit 1
fi
echo "  Format flags: ${BUNDLE_FORMAT_FLAGS[*]:-(none)}"

# Determine the image digest
echo "Determining image URI digest..."
if ! IMAGE_URI_DIGEST=$(resolve_image_uri_digest "${IMAGE}"); then
    echo "ERROR: Could not determine the digest for ${IMAGE}." >&2
    exit 1
fi
echo "  Image URI Digest: ${IMAGE_URI_DIGEST}"

# Build annotation flags if annotations are provided
ANNOTATION_FLAGS=()
if [[ -n "${ANNOTATIONS}" ]]; then
    echo "Processing annotations..."
    IFS=',' read -ra ANNOTATION_PAIRS <<< "${ANNOTATIONS}"
    for pair in ${ANNOTATION_PAIRS[@]+"${ANNOTATION_PAIRS[@]}"}; do
        pair=$(echo "${pair}" | xargs)
        if [[ -n "${pair}" ]]; then
            if [[ "${pair}" != *"="* ]]; then
                echo "ERROR: Invalid annotation format '${pair}'. Expected key=value." >&2
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
        echo "ERROR: CircleCI CLI is not installed." >&2
        echo "The circleci CLI is required to request OIDC tokens with custom audience." >&2
        exit 1
    fi

    SIGSTORE_ID_TOKEN=$(circleci run oidc get --claims '{"aud": "sigstore"}')
    if [[ -z "${SIGSTORE_ID_TOKEN:-}" ]]; then
        echo "ERROR: Failed to get OIDC token from CircleCI." >&2
        echo "" >&2
        echo "Keyless signing requires CircleCI OIDC to be enabled." >&2
        echo "Please ensure:" >&2
        echo "  1. You are using CircleCI Cloud or Server 4.x+" >&2
        echo "  2. OIDC is enabled for your organization" >&2
        echo "  3. Your plan supports OIDC tokens" >&2
        echo "" >&2
        echo "Run the 'check_oidc' command to diagnose OIDC issues." >&2
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
            ${ANNOTATION_FLAGS[@]+"${ANNOTATION_FLAGS[@]}"} \
            ${BUNDLE_FORMAT_FLAGS[@]+"${BUNDLE_FORMAT_FLAGS[@]}"} \
            -y \
            "${IMAGE_URI_DIGEST}"
    elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
        # Cosign v2
        cosign sign \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            ${ANNOTATION_FLAGS[@]+"${ANNOTATION_FLAGS[@]}"} \
            ${BUNDLE_FORMAT_FLAGS[@]+"${BUNDLE_FORMAT_FLAGS[@]}"} \
            --yes \
            "${IMAGE_URI_DIGEST}"
    else
        # Cosign v3: must disable signing config when specifying explicit URLs
        cosign sign \
            --fulcio-url="${FULCIO_URL}" \
            --rekor-url="${REKOR_URL}" \
            --oidc-issuer="${OIDC_ISSUER}" \
            ${ANNOTATION_FLAGS[@]+"${ANNOTATION_FLAGS[@]}"} \
            ${BUNDLE_FORMAT_FLAGS[@]+"${BUNDLE_FORMAT_FLAGS[@]}"} \
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
    echo "ERROR: The export command is not a shell builtin. It is not safe to proceed." >&2
    exit 1
fi
export COSIGN_PASSWORD="${PASSWORD}"

# Load the private key into KEY_DIR rather than the working directory.
if [[ -z "${COSIGN_PRIVATE_KEY}" ]]; then
    echo "ERROR: Private key is empty. Check that the environment variable is set correctly." >&2
    exit 1
fi
if ! KEY_DIR=$(umask 077 && mktemp -d); then
    echo "ERROR: Could not create a private temporary directory for the private key." >&2
    exit 1
fi
KEY_FILE="${KEY_DIR}/cosign.key"
if ! (umask 077 && printf '%s' "${COSIGN_PRIVATE_KEY}" | base64 --decode > "${KEY_FILE}" 2>&1); then
    echo "ERROR: Failed to decode private key. Ensure it is valid base64." >&2
    exit 1
fi
if [[ ! -s "${KEY_FILE}" ]]; then
    echo "ERROR: Decoded private key is empty." >&2
    exit 1
fi
echo "Wrote private key: ${KEY_FILE}"
chmod 0400 "${KEY_FILE}"
echo "Set private key permissions: 0400"

# Sign the image using its digest. BUNDLE_FORMAT_FLAGS also turns off the transparency log,
# so private_key_sign_flags never leaves it empty.
echo "Signing ${IMAGE_URI_DIGEST}..."
cosign sign --key "${KEY_FILE}" "${BUNDLE_FORMAT_FLAGS[@]}" ${ANNOTATION_FLAGS[@]+"${ANNOTATION_FLAGS[@]}"} "${IMAGE_URI_DIGEST}"
rm -f "${SIGNING_CONFIG}"

echo ""
echo "=== Private Key Signing Complete ==="
echo "Image signed: ${IMAGE_URI_DIGEST}"
