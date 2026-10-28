#!/bin/bash

# This script verifies attestations on container images using Cosign.
# Supports two modes:
#   1. Public key verification - Traditional verification with a public key
#   2. Keyless verification - Verify using certificate identity and OIDC issuer

set -euo pipefail

# Load the CI helpers (src/scripts/lib/ci.sh): parameter expansion, booleans,
# and the job's OIDC identity on CircleCI or GitHub Actions.
if [[ -z "${SCRIPT_CI_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded. SCRIPT_CI_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_CI_LIB}"

# Read in orb parameters
IMAGE=$(ci_subst "${PARAM_IMAGE}")
PREDICATE_TYPE=$(ci_subst "${PARAM_PREDICATE_TYPE}")
KEYLESS=$(ci_bool keyless "${PARAM_KEYLESS:-0}")
BUNDLE_FORMAT="${PARAM_BUNDLE_FORMAT:-auto}"
CERTIFICATE_IDENTITY=$(ci_subst "${PARAM_CERTIFICATE_IDENTITY:-}")
CERTIFICATE_IDENTITY_REGEXP=$(ci_subst "${PARAM_CERTIFICATE_IDENTITY_REGEXP:-}")
CERTIFICATE_OIDC_ISSUER=$(ci_subst "${PARAM_CERTIFICATE_OIDC_ISSUER:-}")
CERTIFICATE_OIDC_ISSUER_REGEXP=$(ci_subst "${PARAM_CERTIFICATE_OIDC_ISSUER_REGEXP:-}")

is_keyless_enabled() {
    case "${KEYLESS,,}" in
        1|true) return 0 ;;
        *) return 1 ;;
    esac
}

# Only read key-related params if not using keyless
if ! is_keyless_enabled; then
    COSIGN_PUBLIC_KEY=${!PARAM_PUBLIC_KEY:-}
fi

# Private directory for the decoded key. A cosign.pub in the working directory
# is often the project's own public key, and may be a symlink that would
# redirect the write. Start empty so the cleanup trap never removes a KEY_DIR
# inherited from the job environment.
KEY_DIR=""

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    if [[ -n "${KEY_DIR:-}" ]]; then
        if [ -f "${KEY_DIR}/cosign.pub" ]; then
            shred -vzuf -n 10 "${KEY_DIR}/cosign.pub" 2> /dev/null || true
        fi
        rm -rf "${KEY_DIR}"
    fi
    unset PARAM_PUBLIC_KEY
    unset COSIGN_PUBLIC_KEY
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

# Load the shared format helpers (src/scripts/lib/bundle_format.sh).
if [[ -z "${SCRIPT_BUNDLE_FORMAT_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded. SCRIPT_BUNDLE_FORMAT_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_BUNDLE_FORMAT_LIB}"

echo "Expected attestation storage format: ${BUNDLE_FORMAT}"
verify_format_flags "${COSIGN_MAJOR_VERSION}" verify-attestation "${BUNDLE_FORMAT}" "${COSIGN_VERSION}" || exit 1
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
if is_keyless_enabled; then
    echo ""
    echo "=== Keyless Attestation Verification Mode ==="

    # Without an issuer, the job's own: a GitHub Actions workflow's, or a
    # CircleCI organization's (CIRCLE_ORGANIZATION_ID).
    EFFECTIVE_OIDC_ISSUER="${CERTIFICATE_OIDC_ISSUER}"
    EFFECTIVE_OIDC_ISSUER_REGEXP="${CERTIFICATE_OIDC_ISSUER_REGEXP}"
    if [[ -z "${EFFECTIVE_OIDC_ISSUER}" ]] && [[ -z "${EFFECTIVE_OIDC_ISSUER_REGEXP}" ]]; then
        EFFECTIVE_OIDC_ISSUER=$(ci_oidc_issuer)
        if [[ -n "${EFFECTIVE_OIDC_ISSUER}" ]]; then
            echo "Auto-detected the OIDC issuer from the job's environment"
        fi
    fi

    # Without an identity, any of the job's project's: a workflow of this
    # GitHub repository, or a CircleCI project's pipeline (CIRCLE_PROJECT_ID).
    EFFECTIVE_IDENTITY="${CERTIFICATE_IDENTITY}"
    EFFECTIVE_IDENTITY_REGEXP="${CERTIFICATE_IDENTITY_REGEXP}"
    if [[ -z "${EFFECTIVE_IDENTITY}" ]] && [[ -z "${EFFECTIVE_IDENTITY_REGEXP}" ]]; then
        EFFECTIVE_IDENTITY_REGEXP=$(ci_identity_regexp)
        if [[ -n "${EFFECTIVE_IDENTITY_REGEXP}" ]]; then
            echo "Auto-detected the certificate identity regexp from the job's environment"
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
            echo "WARN: Cosign v1 does not support --certificate-identity-regexp" >&2
            echo "Skipping identity verification (issuer will still be verified)." >&2
            echo "For full identity verification, upgrade to Cosign v2+." >&2
            # In v1, omitting --certificate-identity skips that check
        else
            echo "Certificate identity regexp: ${EFFECTIVE_IDENTITY_REGEXP}"
            IDENTITY_FLAGS+=("--certificate-identity-regexp=${EFFECTIVE_IDENTITY_REGEXP}")
        fi
    else
        if [ "${COSIGN_MAJOR_VERSION}" != "1" ]; then
            echo "ERROR: Keyless verification requires either certificate_identity or certificate_identity_regexp" >&2
            echo "" >&2
            echo "You can either:" >&2
            echo "  1. Provide certificate_identity or certificate_identity_regexp parameter" >&2
            echo "  2. Run in a GitHub Actions workflow, or a CircleCI job where CIRCLE_PROJECT_ID is available" >&2
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
            echo "ERROR: Cosign v1 does not support --certificate-oidc-issuer-regexp" >&2
            echo "Use certificate_oidc_issuer with an exact match, or upgrade to Cosign v2+." >&2
            exit 1
        fi
        echo "Certificate OIDC issuer regexp: ${EFFECTIVE_OIDC_ISSUER_REGEXP}"
        IDENTITY_FLAGS+=("--certificate-oidc-issuer-regexp=${EFFECTIVE_OIDC_ISSUER_REGEXP}")
    else
        echo "ERROR: Keyless verification requires either certificate_oidc_issuer or certificate_oidc_issuer_regexp" >&2
        echo "" >&2
        echo "You can either:" >&2
        echo "  1. Provide certificate_oidc_issuer or certificate_oidc_issuer_regexp parameter" >&2
        echo "  2. Run in a GitHub Actions workflow, or a CircleCI job where CIRCLE_ORGANIZATION_ID is available" >&2
        exit 1
    fi

    # Verify attestation using keyless mode
    echo ""
    echo "Verifying keyless attestation for ${IMAGE}..."
    echo "  Predicate Type: ${PREDICATE_TYPE}"

    if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
        # Cosign v1 requires COSIGN_EXPERIMENTAL=1 for keyless verification
        COSIGN_EXPERIMENTAL=1 cosign verify-attestation \
            --type "${PREDICATE_TYPE}" \
            "${IDENTITY_FLAGS[@]}" \
            ${BUNDLE_FORMAT_FLAGS[@]+"${BUNDLE_FORMAT_FLAGS[@]}"} \
            "${IMAGE}"
    else
        # Cosign v2 and v3
        cosign verify-attestation \
            --type "${PREDICATE_TYPE}" \
            "${IDENTITY_FLAGS[@]}" \
            ${BUNDLE_FORMAT_FLAGS[@]+"${BUNDLE_FORMAT_FLAGS[@]}"} \
            "${IMAGE}"
        check_other_format_does_not_verify "${BUNDLE_FORMAT}" \
            cosign verify-attestation --type "${PREDICATE_TYPE}" "${IDENTITY_FLAGS[@]}" "${IMAGE}" || exit 1
    fi

    echo ""
    echo "=== Keyless Attestation Verification Complete ==="
    echo "Attestation verified: ${IMAGE}"
    exit 0
fi

# ==============================================================================
# PUBLIC KEY VERIFICATION MODE
# ==============================================================================
echo ""
echo "=== Public Key Attestation Verification Mode ==="

# Load public key, normally a base64 encoded secret within a CircleCI context,
# into KEY_DIR rather than the working directory.
if [[ -z "${COSIGN_PUBLIC_KEY}" ]]; then
    echo "ERROR: Public key is empty. Check that the environment variable is set correctly." >&2
    exit 1
fi
if ! KEY_DIR=$(umask 077 && mktemp -d); then
    echo "ERROR: Could not create a private temporary directory for the public key." >&2
    exit 1
fi
KEY_FILE="${KEY_DIR}/cosign.pub"
# Use printf instead of echo for more predictable handling of special characters
if ! (umask 077 && printf '%s' "${COSIGN_PUBLIC_KEY}" | base64 --decode > "${KEY_FILE}" 2>&1); then
    echo "ERROR: Failed to decode public key. Ensure it is valid base64." >&2
    exit 1
fi
if [[ ! -s "${KEY_FILE}" ]]; then
    echo "ERROR: Decoded public key is empty." >&2
    exit 1
fi
echo "Wrote public key: ${KEY_FILE}"
chmod 0400 "${KEY_FILE}"
echo "Set public key permissions: 0400"

# Verify attestation using the public key
echo "Verifying cosign attestation for ${IMAGE}..."
echo "  Predicate Type: ${PREDICATE_TYPE}"
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    # Cosign v1: tlog verification is experimental and off by default, no special flags needed
    cosign verify-attestation \
        --type "${PREDICATE_TYPE}" \
        --key "${KEY_FILE}" \
        ${BUNDLE_FORMAT_FLAGS[@]+"${BUNDLE_FORMAT_FLAGS[@]}"} \
        "${IMAGE}"
else
    # Cosign v2 and v3: --private-infrastructure skips tlog verification
    cosign verify-attestation \
        --type "${PREDICATE_TYPE}" \
        --key "${KEY_FILE}" \
        --private-infrastructure \
        ${BUNDLE_FORMAT_FLAGS[@]+"${BUNDLE_FORMAT_FLAGS[@]}"} \
        "${IMAGE}"
    check_other_format_does_not_verify "${BUNDLE_FORMAT}" \
        cosign verify-attestation --type "${PREDICATE_TYPE}" --key "${KEY_FILE}" --private-infrastructure "${IMAGE}" || exit 1
fi

echo ""
echo "=== Public Key Attestation Verification Complete ==="
echo "Attestation verified: ${IMAGE}"
