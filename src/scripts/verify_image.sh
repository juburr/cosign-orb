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

# Verify Cosign version is supported
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-)
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ] && [ "${COSIGN_MAJOR_VERSION}" != "3" ]; then
    echo "Unsupported Cosign version: ${COSIGN_MAJOR_VERSION}"
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

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
        COSIGN_EXPERIMENTAL=1 cosign verify \
            "${IDENTITY_FLAGS[@]}" \
            "${IMAGE}"
    else
        # Cosign v2 and v3
        cosign verify \
            "${IDENTITY_FLAGS[@]}" \
            "${IMAGE}"
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
    cosign verify --key cosign.pub "${IMAGE}"
else
    # Cosign v2 and v3: --private-infrastructure flag works in both versions
    cosign verify --private-infrastructure --key cosign.pub "${IMAGE}"
fi

echo ""
echo "=== Public Key Verification Complete ==="
echo "Image verified: ${IMAGE}"

# Cleanup
rm -f cosign.pub
