#!/bin/bash

# This script signs blobs (arbitrary files) using Cosign.
# Supports two modes:
#   1. Private key signing - Traditional signing with a pre-generated key
#   2. Keyless signing - OIDC-based signing via Fulcio/Rekor (no key management)

set -e
set +o history

# Read in orb parameters
BLOB=$(circleci env subst "${PARAM_BLOB}")
SIGNATURE_OUTPUT=$(circleci env subst "${PARAM_SIGNATURE_OUTPUT}")
KEYLESS="${PARAM_KEYLESS:-false}"
# Normalize boolean: CircleCI passes "true"/"false" strings, but also accept "1"/"0"
if [[ "${KEYLESS}" == "true" ]] || [[ "${KEYLESS}" == "1" ]]; then
    KEYLESS="1"
else
    KEYLESS="0"
fi
CERTIFICATE_OUTPUT=$(circleci env subst "${PARAM_CERTIFICATE_OUTPUT:-}")
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
    cleanup_secrets
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Verify the blob file exists
if [[ ! -f "${BLOB}" ]]; then
    echo "ERROR: Blob file does not exist: ${BLOB}"
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

    # Validate certificate_output is provided for keyless mode
    if [[ -z "${CERTIFICATE_OUTPUT}" ]]; then
        echo "ERROR: certificate_output is required for keyless blob signing."
        echo ""
        echo "Unlike image signing where certificates are stored in the registry,"
        echo "blob signing requires you to save the certificate to a file for verification."
        echo ""
        echo "Example:"
        echo "  cosign/sign_blob:"
        echo "    blob: \"./artifact.tar.gz\""
        echo "    keyless: true"
        echo "    signature_output: \"./artifact.tar.gz.sig\""
        echo "    certificate_output: \"./artifact.tar.gz.crt\""
        exit 1
    fi
    echo "Certificate output: ${CERTIFICATE_OUTPUT}"

    # Build output signature flag if specified
    if [[ -n "${SIGNATURE_OUTPUT}" ]]; then
        echo "Signature output: ${SIGNATURE_OUTPUT}"
    else
        echo "Signature output: stdout"
    fi

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

    # Sign the blob using keyless mode
    echo "Signing ${BLOB} (keyless)..."

    if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
        # Cosign v1 requires COSIGN_EXPERIMENTAL=1 and explicit --identity-token
        if [[ -n "${SIGNATURE_OUTPUT}" ]]; then
            COSIGN_EXPERIMENTAL=1 cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --identity-token="${SIGSTORE_ID_TOKEN}" \
                --output-signature="${SIGNATURE_OUTPUT}" \
                --output-certificate="${CERTIFICATE_OUTPUT}" \
                -y \
                "${BLOB}"
        else
            COSIGN_EXPERIMENTAL=1 cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --identity-token="${SIGSTORE_ID_TOKEN}" \
                --output-certificate="${CERTIFICATE_OUTPUT}" \
                -y \
                "${BLOB}"
        fi
    elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
        # Cosign v2
        if [[ -n "${SIGNATURE_OUTPUT}" ]]; then
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-signature="${SIGNATURE_OUTPUT}" \
                --output-certificate="${CERTIFICATE_OUTPUT}" \
                --yes \
                "${BLOB}"
        else
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-certificate="${CERTIFICATE_OUTPUT}" \
                --yes \
                "${BLOB}"
        fi
    else
        # Cosign v3: must disable signing config when specifying explicit URLs
        # Also disable new bundle format to use legacy --output-signature/--output-certificate
        if [[ -n "${SIGNATURE_OUTPUT}" ]]; then
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-signature="${SIGNATURE_OUTPUT}" \
                --output-certificate="${CERTIFICATE_OUTPUT}" \
                --yes \
                --use-signing-config=false \
                --new-bundle-format=false \
                "${BLOB}"
        else
            cosign sign-blob \
                --fulcio-url="${FULCIO_URL}" \
                --rekor-url="${REKOR_URL}" \
                --oidc-issuer="${OIDC_ISSUER}" \
                --output-certificate="${CERTIFICATE_OUTPUT}" \
                --yes \
                --use-signing-config=false \
                --new-bundle-format=false \
                "${BLOB}"
        fi
    fi

    echo ""
    echo "=== Keyless Signing Complete ==="
    echo "Blob signed: ${BLOB}"
    echo "Certificate saved to: ${CERTIFICATE_OUTPUT}"
    if [[ -n "${SIGNATURE_OUTPUT}" ]]; then
        echo "Signature saved to: ${SIGNATURE_OUTPUT}"
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
    echo "The export command is not a shell builtin. It is not safe to proceed."
    exit 1
fi
export COSIGN_PASSWORD="${PASSWORD}"

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

# Build output signature flag if specified
OUTPUT_FLAG=""
if [[ -n "${SIGNATURE_OUTPUT}" ]]; then
    OUTPUT_FLAG="--output-signature=${SIGNATURE_OUTPUT}"
    echo "Signature output: ${SIGNATURE_OUTPUT}"
else
    echo "Signature output: stdout"
fi

# Sign the blob
echo "Signing ${BLOB}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    # Cosign v1: no tlog flags needed for sign-blob
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key cosign.key "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key cosign.key "${BLOB}"
    fi
elif [ "${COSIGN_MAJOR_VERSION}" == "2" ]; then
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key cosign.key --tlog-upload=false "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key cosign.key --tlog-upload=false "${BLOB}"
    fi
else
    # Cosign v3: Must disable the default signing config and new bundle format to use --output-signature
    # By default, v3 sets --use-signing-config=true which requires --bundle output format.
    # To use the legacy --output-signature flag, we disable both the signing config and new bundle format.
    if [[ -n "${OUTPUT_FLAG}" ]]; then
        cosign sign-blob --key cosign.key --tlog-upload=false --use-signing-config=false --new-bundle-format=false "${OUTPUT_FLAG}" "${BLOB}"
    else
        cosign sign-blob --key cosign.key --tlog-upload=false --use-signing-config=false --new-bundle-format=false "${BLOB}"
    fi
fi

echo ""
echo "=== Private Key Signing Complete ==="
echo "Blob signed: ${BLOB}"
