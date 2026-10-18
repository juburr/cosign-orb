#!/bin/bash

# This script attaches attestations to container images using Cosign.
# Supports two modes:
#   1. Private key attestation - Traditional attestation with a pre-generated key
#   2. Keyless attestation - OIDC-based attestation via Fulcio/Rekor (no key management)

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the key and password.
set +o xtrace

# Read in orb parameters
IMAGE=$(printf '%s' "${PARAM_IMAGE}" | circleci env subst)
PREDICATE=$(printf '%s' "${PARAM_PREDICATE}" | circleci env subst)
PREDICATE_TYPE=$(printf '%s' "${PARAM_PREDICATE_TYPE}" | circleci env subst)
KEYLESS="${PARAM_KEYLESS:-0}"
BUNDLE_FORMAT="${PARAM_BUNDLE_FORMAT:-auto}"
# Temporary signing config created by this script. Start empty so the cleanup
# trap never removes a SIGNING_CONFIG path inherited from the job environment.
SIGNING_CONFIG=""
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
    COSIGN_PRIVATE_KEY=${!PARAM_PRIVATE_KEY:-}

    # COSIGN_PASSWORD is a special env var used by the Cosign tool, and must be exported for
    # it to be used by Cosign. Setting it here prevents the "cosign attest" command from prompting
    # for a password in the CI pipeline.
    if ! type export | grep -q 'export is a shell builtin'; then
        echo "ERROR: The export command is not a shell builtin. It is not safe to proceed." >&2
        exit 1
    fi
    export COSIGN_PASSWORD=${!PARAM_PASSWORD:-}
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
    cleanup_secrets
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

# Pick the attestation storage format flags before touching the registry.
echo "Attestation storage format: ${BUNDLE_FORMAT}"
if is_keyless_enabled; then
    keyless_sign_flags "${COSIGN_MAJOR_VERSION}" attest "${BUNDLE_FORMAT}" || exit 1
else
    # Cosign 3 turns the transparency log off with an empty signing config (no Rekor, Fulcio or TSA).
    SIGNING_CONFIG=$(mktemp)
    printf '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}\n' > "${SIGNING_CONFIG}"
    private_key_sign_flags "${COSIGN_MAJOR_VERSION}" attest "${BUNDLE_FORMAT}" "${SIGNING_CONFIG}" || exit 1
fi
echo "  Format flags: ${BUNDLE_FORMAT_FLAGS[*]:-(none)}"

# Determine the image digest
echo "Determining image URI digest..."
if ! IMAGE_URI_DIGEST=$(resolve_image_uri_digest "${IMAGE}"); then
    echo "ERROR: Could not determine the digest for ${IMAGE}." >&2
    exit 1
fi
echo "  Image URI Digest: ${IMAGE_URI_DIGEST}"

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
        echo "ERROR: CircleCI CLI is not installed." >&2
        echo "The circleci CLI is required to request OIDC tokens with custom audience." >&2
        exit 1
    fi

    SIGSTORE_ID_TOKEN=$(circleci run oidc get --claims '{"aud": "sigstore"}')
    if [[ -z "${SIGSTORE_ID_TOKEN:-}" ]]; then
        echo "ERROR: Failed to get OIDC token from CircleCI." >&2
        echo "" >&2
        echo "Keyless attestation requires CircleCI OIDC to be enabled." >&2
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
            "${BUNDLE_FORMAT_FLAGS[@]}" \
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
            "${BUNDLE_FORMAT_FLAGS[@]}" \
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
            "${BUNDLE_FORMAT_FLAGS[@]}" \
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

# Load the private key, normally a base64 encoded secret within a CircleCI context,
# into KEY_DIR rather than the working directory.
# Note that a Cosign v2 key used with Cosign v1 may throw: unsupported pem type: ENCRYPTED SIGSTORE PRIVATE KEY
if [[ -z "${COSIGN_PRIVATE_KEY}" ]]; then
    echo "ERROR: Private key is empty. Check that the environment variable is set correctly." >&2
    cleanup_secrets
    exit 1
fi
if ! KEY_DIR=$(umask 077 && mktemp -d); then
    echo "ERROR: Could not create a private temporary directory for the private key." >&2
    cleanup_secrets
    exit 1
fi
KEY_FILE="${KEY_DIR}/cosign.key"
# Use printf instead of echo for more predictable handling of special characters
# The || true prevents set -e from exiting on decode failure; we check the result below
if ! (umask 077 && printf '%s' "${COSIGN_PRIVATE_KEY}" | base64 --decode > "${KEY_FILE}" 2>&1); then
    echo "ERROR: Failed to decode private key. Ensure it is valid base64." >&2
    cleanup_secrets
    exit 1
fi
if [[ ! -s "${KEY_FILE}" ]]; then
    echo "ERROR: Decoded private key is empty." >&2
    cleanup_secrets
    exit 1
fi
echo "Wrote private key: ${KEY_FILE}"
chmod 0400 "${KEY_FILE}"
echo "Set private key permissions: 0400"

# Attest the image using its digest. BUNDLE_FORMAT_FLAGS also turns off the transparency log.
echo "Attesting ${IMAGE_URI_DIGEST}..."
echo "  Predicate: ${PREDICATE}"
echo "  Predicate Type: ${PREDICATE_TYPE}"
cosign attest \
    --predicate "${PREDICATE}" \
    --type "${PREDICATE_TYPE}" \
    --key "${KEY_FILE}" \
    "${BUNDLE_FORMAT_FLAGS[@]}" \
    "${IMAGE_URI_DIGEST}"
rm -f "${SIGNING_CONFIG}"

echo ""
echo "=== Private Key Attestation Complete ==="
echo "Image attested: ${IMAGE_URI_DIGEST}"
