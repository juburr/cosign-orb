#!/bin/bash

# This script verifies blob signatures using Cosign.
# Supports two modes:
#   1. Public key verification - Traditional verification with a public key
#   2. Keyless verification - Verify using certificate identity and OIDC issuer

set -euo pipefail

# Read in orb parameters
BLOB=$(printf '%s' "${PARAM_BLOB}" | circleci env subst)
SIGNATURE=$(printf '%s' "${PARAM_SIGNATURE}" | circleci env subst)
KEYLESS="${PARAM_KEYLESS:-false}"
# Normalize boolean: CircleCI passes "true"/"false" strings, but also accept "1"/"0"
if [[ "${KEYLESS}" == "true" ]] || [[ "${KEYLESS}" == "1" ]]; then
    KEYLESS="1"
else
    KEYLESS="0"
fi
CERTIFICATE=$(printf '%s' "${PARAM_CERTIFICATE:-}" | circleci env subst)
CERTIFICATE_IDENTITY=$(printf '%s' "${PARAM_CERTIFICATE_IDENTITY:-}" | circleci env subst)
CERTIFICATE_IDENTITY_REGEXP=$(printf '%s' "${PARAM_CERTIFICATE_IDENTITY_REGEXP:-}" | circleci env subst)
CERTIFICATE_OIDC_ISSUER=$(printf '%s' "${PARAM_CERTIFICATE_OIDC_ISSUER:-}" | circleci env subst)
CERTIFICATE_OIDC_ISSUER_REGEXP=$(printf '%s' "${PARAM_CERTIFICATE_OIDC_ISSUER_REGEXP:-}" | circleci env subst)

# Only read key-related params if not using keyless
if [[ "${KEYLESS}" != "1" ]]; then
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

# Verify the blob file exists
if [[ ! -f "${BLOB}" ]]; then
    echo "ERROR: Blob file does not exist: ${BLOB}" >&2
    exit 1
fi
echo "Blob file: ${BLOB}"

# Verify the signature file exists
if [[ ! -f "${SIGNATURE}" ]]; then
    echo "ERROR: Signature file does not exist: ${SIGNATURE}" >&2
    exit 1
fi
echo "Signature file: ${SIGNATURE}"

# ==============================================================================
# KEYLESS VERIFICATION MODE
# ==============================================================================
if [[ "${KEYLESS}" == "1" ]]; then
    echo ""
    echo "=== Keyless Verification Mode ==="

    # Validate certificate file is provided for keyless mode
    if [[ -z "${CERTIFICATE}" ]]; then
        echo "ERROR: certificate is required for keyless blob verification." >&2
        echo "" >&2
        echo "Unlike image verification where certificates are retrieved from the registry," >&2
        echo "blob verification requires the certificate file saved during signing." >&2
        echo "" >&2
        echo "Example:" >&2
        echo "  cosign/verify_blob:" >&2
        echo "    blob: \"./artifact.tar.gz\"" >&2
        echo "    signature: \"./artifact.tar.gz.sig\"" >&2
        echo "    certificate: \"./artifact.tar.gz.crt\"" >&2
        echo "    keyless: true" >&2
        exit 1
    fi

    # Verify the certificate file exists
    if [[ ! -f "${CERTIFICATE}" ]]; then
        echo "ERROR: Certificate file does not exist: ${CERTIFICATE}" >&2
        exit 1
    fi
    echo "Certificate file: ${CERTIFICATE}"

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
            echo "  2. Run in a CircleCI environment where CIRCLE_PROJECT_ID is available" >&2
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
        echo "  2. Run in a CircleCI environment where CIRCLE_ORGANIZATION_ID is available" >&2
        exit 1
    fi

    # Verify blob signature using keyless mode
    echo ""
    echo "Verifying keyless signature for ${BLOB}..."

    if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
        # Cosign v1 requires COSIGN_EXPERIMENTAL=1 for keyless verification
        COSIGN_EXPERIMENTAL=1 cosign verify-blob \
            --certificate="${CERTIFICATE}" \
            --signature="${SIGNATURE}" \
            "${IDENTITY_FLAGS[@]}" \
            "${BLOB}"
    else
        # Cosign v2 and v3
        cosign verify-blob \
            --certificate="${CERTIFICATE}" \
            --signature="${SIGNATURE}" \
            "${IDENTITY_FLAGS[@]}" \
            "${BLOB}"
    fi

    echo ""
    echo "=== Keyless Verification Complete ==="
    echo "Blob verified: ${BLOB}"
    exit 0
fi

# ==============================================================================
# PUBLIC KEY VERIFICATION MODE
# ==============================================================================
echo ""
echo "=== Public Key Verification Mode ==="

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

# Verify blob signature using the public key
echo "Verifying cosign signature for ${BLOB}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign verify-blob --key "${KEY_FILE}" --signature "${SIGNATURE}" "${BLOB}"
else
    # Cosign v2 and v3: --private-infrastructure flag works in both versions
    cosign verify-blob --key "${KEY_FILE}" --signature "${SIGNATURE}" --private-infrastructure "${BLOB}"
fi

echo ""
echo "=== Public Key Verification Complete ==="
echo "Blob verified: ${BLOB}"
