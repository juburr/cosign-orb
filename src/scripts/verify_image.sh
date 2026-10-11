#!/bin/bash

# This script verifies container image signatures using Cosign.
# Supports two modes:
#   1. Public key verification - Traditional verification with a public key
#   2. Keyless verification - Verify using certificate identity and OIDC issuer

set -e
set +o history

# Read in orb parameters
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
KEYLESS="${PARAM_KEYLESS:-0}"
BUNDLE_FORMAT="${PARAM_BUNDLE_FORMAT:-auto}"
CERTIFICATE_IDENTITY=$(circleci env subst "${PARAM_CERTIFICATE_IDENTITY:-}")
CERTIFICATE_IDENTITY_REGEXP=$(circleci env subst "${PARAM_CERTIFICATE_IDENTITY_REGEXP:-}")
CERTIFICATE_OIDC_ISSUER=$(circleci env subst "${PARAM_CERTIFICATE_OIDC_ISSUER:-}")
CERTIFICATE_OIDC_ISSUER_REGEXP=$(circleci env subst "${PARAM_CERTIFICATE_OIDC_ISSUER_REGEXP:-}")

# Only read key-related params if not using keyless
if [[ "${KEYLESS}" != "1" ]]; then
    COSIGN_PUBLIC_KEY=${!PARAM_PUBLIC_KEY}
fi

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    if [ -f cosign.pub ]; then
        shred -vzuf -n 10 cosign.pub 2> /dev/null || true
    fi
    unset PARAM_PUBLIC_KEY
    unset COSIGN_PUBLIC_KEY
    echo "Secrets destroyed."
}
trap cleanup_secrets EXIT

# Cosign 2.6+ and 3 accept any Sigstore bundle signed by the key or identity
# as an image signature, including an attestation bundle. Require that at
# least one verified payload is an image signature: the legacy simple signing
# type, or the bundle signature predicate type. Returns 1 if none is, and 2 if
# the output can't be read.
require_image_signature() {
    local output="$1"
    local types

    printf '%s\n' "${output}"
    if ! types="$(printf '%s\n' "${output}" | jq -r -s '[.[] | if type == "array" then .[] else . end | .critical.type? // "unknown"] | unique | join(", ")')"; then
        echo "ERROR: Could not read Cosign's verification output."
        return 2
    fi
    echo "Verified payload types: ${types}"
    if ! printf '%s\n' "${output}" | jq -e -s '[.[] | if type == "array" then .[] else . end | .critical.type?] | any(. == "cosign container image signature" or . == "https://sigstore.dev/cosign/sign/v1")' > /dev/null; then
        echo "No image signature among them. The image may only have attestations."
        return 1
    fi
}

# Verifies IMAGE with Cosign 2 or 3 (the command and its flags are the
# arguments) and requires an image signature. When an image has any Sigstore
# bundle, Cosign 3 checks only bundles, and Cosign 2.6.3 and later can't be
# limited to legacy signatures at all. So with bundle_format auto, Cosign 3
# checks the legacy signatures when no bundle is an image signature.
verify_image_signature() {
    local output status=0

    output=$("$@" "${BUNDLE_FORMAT_FLAGS[@]}" "${IMAGE}") || return 1
    require_image_signature "${output}" || status=$?
    if [[ "${status}" -eq 1 && "${COSIGN_MAJOR_VERSION}" == "3" && "${BUNDLE_FORMAT}" == "auto" ]]; then
        echo "Checking legacy signatures only (--new-bundle-format=false)..."
        output=$("$@" --new-bundle-format=false "${IMAGE}") || return 1
        status=0
        require_image_signature "${output}" || status=$?
    fi
    if [[ "${status}" -eq 0 ]]; then
        return 0
    fi
    if [[ "${status}" -eq 1 && "${COSIGN_MAJOR_VERSION}" == "2" && "${BUNDLE_FORMAT}" != "bundle" ]] \
        && cosign_version_at_least "${COSIGN_VERSION}" 2.6.3; then
        echo "If the image also has a legacy signature, Cosign ${COSIGN_VERSION} can't verify it: Cosign 2.6.3 and later check only Sigstore bundles when an image has any. Use Cosign 3, or sign in the bundle format."
    fi
    echo "ERROR: No image signature verified."
    return 1
}

# Verify Cosign version is supported
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-)
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ] && [ "${COSIGN_MAJOR_VERSION}" != "3" ]; then
    echo "Unsupported Cosign version: ${COSIGN_MAJOR_VERSION}"
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Load the shared format helpers (src/scripts/lib/bundle_format.sh).
if [[ -z "${SCRIPT_BUNDLE_FORMAT_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded. SCRIPT_BUNDLE_FORMAT_LIB is empty."
    exit 1
fi
eval "${SCRIPT_BUNDLE_FORMAT_LIB}"

echo "Expected signature storage format: ${BUNDLE_FORMAT}"
verify_format_flags "${COSIGN_MAJOR_VERSION}" verify "${BUNDLE_FORMAT}" "${COSIGN_VERSION}" || exit 1
echo "  Format flags: ${BUNDLE_FORMAT_FLAGS[*]:-(none)}"

# A second, format-limited verification follows. Pin a tag to one digest so
# both verifications check the same image.
if [[ ${#BUNDLE_FORMAT_COUNTER_FLAGS[@]} -gt 0 ]]; then
    IMAGE=$(pin_image_to_digest "${IMAGE}") || exit 1
    echo "  Verifying ${IMAGE}"
fi

# ==============================================================================
# KEYLESS VERIFICATION MODE
# ==============================================================================
if [[ "${KEYLESS}" == "1" ]]; then
    echo ""
    echo "=== Keyless Verification Mode ==="

    # Auto-detect OIDC issuer from CircleCI environment if not provided
    EFFECTIVE_OIDC_ISSUER="${CERTIFICATE_OIDC_ISSUER}"
    EFFECTIVE_OIDC_ISSUER_REGEXP="${CERTIFICATE_OIDC_ISSUER_REGEXP}"
    if [[ -z "${EFFECTIVE_OIDC_ISSUER}" ]] && [[ -z "${EFFECTIVE_OIDC_ISSUER_REGEXP}" ]]; then
        if [[ -n "${CIRCLE_ORGANIZATION_ID:-}" ]]; then
            EFFECTIVE_OIDC_ISSUER="https://oidc.circleci.com/org/${CIRCLE_ORGANIZATION_ID}"
            echo "Auto-detected OIDC issuer from CIRCLE_ORGANIZATION_ID"
        fi
    fi

    # Auto-detect certificate identity regexp from CircleCI environment if not provided
    EFFECTIVE_IDENTITY="${CERTIFICATE_IDENTITY}"
    EFFECTIVE_IDENTITY_REGEXP="${CERTIFICATE_IDENTITY_REGEXP}"
    if [[ -z "${EFFECTIVE_IDENTITY}" ]] && [[ -z "${EFFECTIVE_IDENTITY_REGEXP}" ]]; then
        if [[ -n "${CIRCLE_PROJECT_ID:-}" ]]; then
            EFFECTIVE_IDENTITY_REGEXP="https://circleci.com/api/v2/projects/${CIRCLE_PROJECT_ID}/pipeline-definitions/.*"
            echo "Auto-detected certificate identity regexp from CIRCLE_PROJECT_ID"
        fi
    fi

    # Build identity flags
    IDENTITY_FLAGS=()

    # Certificate identity (required: either exact or regexp)
    # Note: Cosign v1 only supports exact match, not regexp
    if [[ -n "${EFFECTIVE_IDENTITY}" ]]; then
        echo "Certificate identity: ${EFFECTIVE_IDENTITY}"
        IDENTITY_FLAGS+=("--certificate-identity=${EFFECTIVE_IDENTITY}")
    elif [[ -n "${EFFECTIVE_IDENTITY_REGEXP}" ]]; then
        if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
            echo "WARNING: Cosign v1 does not support --certificate-identity-regexp"
            echo "Skipping identity verification (issuer will still be verified)."
            echo "For full identity verification, upgrade to Cosign v2+."
            # In v1, omitting --certificate-identity skips that check
        else
            echo "Certificate identity regexp: ${EFFECTIVE_IDENTITY_REGEXP}"
            IDENTITY_FLAGS+=("--certificate-identity-regexp=${EFFECTIVE_IDENTITY_REGEXP}")
        fi
    else
        if [ "${COSIGN_MAJOR_VERSION}" != "1" ]; then
            echo "ERROR: Keyless verification requires either certificate_identity or certificate_identity_regexp"
            echo ""
            echo "You can either:"
            echo "  1. Provide certificate_identity or certificate_identity_regexp parameter"
            echo "  2. Run in a CircleCI environment where CIRCLE_PROJECT_ID is available"
            exit 1
        fi
        # v1 allows skipping identity check
    fi

    # OIDC issuer (required: either exact or regexp)
    # Note: Cosign v1 only supports exact match, not regexp
    if [[ -n "${EFFECTIVE_OIDC_ISSUER}" ]]; then
        echo "Certificate OIDC issuer: ${EFFECTIVE_OIDC_ISSUER}"
        IDENTITY_FLAGS+=("--certificate-oidc-issuer=${EFFECTIVE_OIDC_ISSUER}")
    elif [[ -n "${EFFECTIVE_OIDC_ISSUER_REGEXP}" ]]; then
        if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
            echo "ERROR: Cosign v1 does not support --certificate-oidc-issuer-regexp"
            echo "Use certificate_oidc_issuer with an exact match, or upgrade to Cosign v2+."
            exit 1
        fi
        echo "Certificate OIDC issuer regexp: ${EFFECTIVE_OIDC_ISSUER_REGEXP}"
        IDENTITY_FLAGS+=("--certificate-oidc-issuer-regexp=${EFFECTIVE_OIDC_ISSUER_REGEXP}")
    else
        echo "ERROR: Keyless verification requires either certificate_oidc_issuer or certificate_oidc_issuer_regexp"
        echo ""
        echo "You can either:"
        echo "  1. Provide certificate_oidc_issuer or certificate_oidc_issuer_regexp parameter"
        echo "  2. Run in a CircleCI environment where CIRCLE_ORGANIZATION_ID is available"
        exit 1
    fi

    # Verify image signature using keyless mode
    echo ""
    echo "Verifying keyless signature for ${IMAGE}..."

    if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
        # Cosign v1 requires COSIGN_EXPERIMENTAL=1 for keyless verification
        VERIFY_OUTPUT=$(COSIGN_EXPERIMENTAL=1 cosign verify \
            "${IDENTITY_FLAGS[@]}" \
            "${BUNDLE_FORMAT_FLAGS[@]}" \
            "${IMAGE}")
        require_image_signature "${VERIFY_OUTPUT}" || exit 1
    else
        # Cosign v2 and v3
        verify_image_signature cosign verify "${IDENTITY_FLAGS[@]}" || exit 1
        check_other_format_does_not_verify "${BUNDLE_FORMAT}" cosign verify "${IDENTITY_FLAGS[@]}" "${IMAGE}" || exit 1
    fi

    echo ""
    echo "=== Keyless Verification Complete ==="
    echo "Image verified: ${IMAGE}"
    exit 0
fi

# ==============================================================================
# PUBLIC KEY VERIFICATION MODE
# ==============================================================================
echo ""
echo "=== Public Key Verification Mode ==="

# Load public key, normally a base64 encoded secret within a CircleCI context
if [[ -z "${COSIGN_PUBLIC_KEY}" ]]; then
    echo "ERROR: Public key is empty. Check that the environment variable is set correctly."
    exit 1
fi
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
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    VERIFY_OUTPUT=$(cosign verify --key cosign.pub "${BUNDLE_FORMAT_FLAGS[@]}" "${IMAGE}")
    require_image_signature "${VERIFY_OUTPUT}" || exit 1
else
    # Cosign v2 and v3: --private-infrastructure flag works in both versions
    verify_image_signature cosign verify --private-infrastructure --key cosign.pub || exit 1
    check_other_format_does_not_verify "${BUNDLE_FORMAT}" cosign verify --private-infrastructure --key cosign.pub "${IMAGE}" || exit 1
fi

echo ""
echo "=== Public Key Verification Complete ==="
echo "Image verified: ${IMAGE}"

# Cleanup
rm -f cosign.pub
