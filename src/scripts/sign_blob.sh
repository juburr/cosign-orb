#!/bin/bash

# This script signs blobs (arbitrary files) using Cosign.
# Supports two modes:
#   1. Private key signing - Traditional signing with a pre-generated key
#   2. Keyless signing - OIDC-based signing via Fulcio/Rekor (no key management)

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the key and password.
set +o xtrace

# Read in orb parameters
BLOB=$(printf '%s' "${PARAM_BLOB}" | circleci env subst)
OUTPUT_SIGNATURE=$(printf '%s' "${PARAM_OUTPUT_SIGNATURE}" | circleci env subst)
KEYLESS="${PARAM_KEYLESS:-false}"
# Normalize boolean: CircleCI passes "true"/"false" strings, but also accept "1"/"0"
if [[ "${KEYLESS}" == "true" ]] || [[ "${KEYLESS}" == "1" ]]; then
    KEYLESS="1"
else
    KEYLESS="0"
fi
OUTPUT_CERTIFICATE=$(printf '%s' "${PARAM_OUTPUT_CERTIFICATE:-}" | circleci env subst)
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
    cleanup_secrets
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Verify the blob file exists
if [[ ! -f "${BLOB}" ]]; then
    echo "ERROR: Blob file does not exist: ${BLOB}" >&2
    cleanup_secrets
    exit 1
fi
echo "Blob file: ${BLOB}"

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

    # Validate output_certificate is provided for keyless mode
    if [[ -z "${OUTPUT_CERTIFICATE}" ]]; then
        echo "ERROR: output_certificate is required for keyless blob signing." >&2
        echo "" >&2
        echo "Unlike image signing where certificates are stored in the registry," >&2
        echo "blob signing requires you to save the certificate to a file for verification." >&2
        echo "" >&2
        echo "Example:" >&2
        echo "  cosign/sign_blob:" >&2
        echo "    blob: \"./artifact.tar.gz\"" >&2
        echo "    keyless: true" >&2
        echo "    output_signature: \"./artifact.tar.gz.sig\"" >&2
        echo "    output_certificate: \"./artifact.tar.gz.crt\"" >&2
        exit 1
    fi
    echo "Certificate output: ${OUTPUT_CERTIFICATE}"

    # Build output signature flag if specified
    if [[ -n "${OUTPUT_SIGNATURE}" ]]; then
        echo "Signature output: ${OUTPUT_SIGNATURE}"
    else
        echo "Signature output: stdout"
    fi

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

    # Sign the blob using keyless mode
    echo "Signing ${BLOB} (keyless)..."

    if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
        # Cosign v1 requires COSIGN_EXPERIMENTAL=1 and explicit --identity-token
        if [[ -n "${OUTPUT_SIGNATURE}" ]]; then
            COSIGN_EXPERIMENTAL=1 cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --identity-token="${SIGSTORE_ID_TOKEN}" \
                --output-signature="${OUTPUT_SIGNATURE}" \
                --output-certificate="${OUTPUT_CERTIFICATE}" \
                -y \
                "${BLOB}"
        else
            COSIGN_EXPERIMENTAL=1 cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --identity-token="${SIGSTORE_ID_TOKEN}" \
                --output-certificate="${OUTPUT_CERTIFICATE}" \
                -y \
                "${BLOB}"
        fi
    elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
        # Cosign v2
        if [[ -n "${OUTPUT_SIGNATURE}" ]]; then
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-signature="${OUTPUT_SIGNATURE}" \
                --output-certificate="${OUTPUT_CERTIFICATE}" \
                --yes \
                "${BLOB}"
        else
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-certificate="${OUTPUT_CERTIFICATE}" \
                --yes \
                "${BLOB}"
        fi
    else
        # Cosign v3: must disable signing config when specifying explicit URLs
        # Also disable new bundle format to use legacy --output-signature/--output-certificate
        if [[ -n "${OUTPUT_SIGNATURE}" ]]; then
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-signature="${OUTPUT_SIGNATURE}" \
                --output-certificate="${OUTPUT_CERTIFICATE}" \
                --yes \
                --use-signing-config=false \
                --new-bundle-format=false \
                "${BLOB}"
        else
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-certificate="${OUTPUT_CERTIFICATE}" \
                --yes \
                --use-signing-config=false \
                --new-bundle-format=false \
                "${BLOB}"
        fi
    fi

    echo ""
    echo "=== Keyless Signing Complete ==="
    echo "Blob signed: ${BLOB}"
    echo "Certificate saved to: ${OUTPUT_CERTIFICATE}"
    if [[ -n "${OUTPUT_SIGNATURE}" ]]; then
        echo "Signature saved to: ${OUTPUT_SIGNATURE}"
    fi
    echo "Signature recorded in Rekor transparency log"
    exit 0
fi

# ==============================================================================
# PRIVATE KEY SIGNING MODE
# ==============================================================================
echo ""
echo "=== Private Key Signing Mode ==="

# COSIGN_PASSWORD is a special env var used by the Cosign tool, and must be exported for
# it to be used by Cosign. Setting it here prevents the "cosign sign-blob" command from prompting
# for a password in the CI pipeline.
if ! type export | grep -q 'export is a shell builtin'; then
    echo "ERROR: The export command is not a shell builtin. It is not safe to proceed." >&2
    exit 1
fi
export COSIGN_PASSWORD="${PASSWORD}"

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

# Build output signature flag if specified
OUTPUT_FLAG=""
if [[ -n "${OUTPUT_SIGNATURE}" ]]; then
    OUTPUT_FLAG="--output-signature=${OUTPUT_SIGNATURE}"
    echo "Signature output: ${OUTPUT_SIGNATURE}"
else
    echo "Signature output: stdout"
fi

# Sign the blob
echo "Signing ${BLOB}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    # Cosign v1: no tlog flags needed for sign-blob
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key "${KEY_FILE}" "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key "${KEY_FILE}" "${BLOB}"
    fi
elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key "${KEY_FILE}" --tlog-upload=false "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key "${KEY_FILE}" --tlog-upload=false "${BLOB}"
    fi
else
    # Cosign v3: Must disable the default signing config and new bundle format to use --output-signature
    # By default, v3 sets --use-signing-config=true which requires --bundle output format.
    # To use the legacy --output-signature flag, we disable both the signing config and new bundle format.
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key "${KEY_FILE}" --tlog-upload=false --use-signing-config=false --new-bundle-format=false "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key "${KEY_FILE}" --tlog-upload=false --use-signing-config=false --new-bundle-format=false "${BLOB}"
    fi
fi

echo ""
echo "=== Private Key Signing Complete ==="
echo "Blob signed: ${BLOB}"
