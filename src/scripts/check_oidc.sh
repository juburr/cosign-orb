#!/bin/bash
# Verifies that CircleCI OIDC token is available and displays key claims.
# Used to confirm OIDC is properly configured before using keyless signing.

set -euo pipefail

echo "=== CircleCI OIDC Token Check ==="
echo ""

if [[ -z "${CIRCLE_OIDC_TOKEN:-}" ]]; then
    echo "ERROR: CIRCLE_OIDC_TOKEN is not set"
    echo ""
    echo "Possible causes:"
    echo "  1. OIDC is not enabled for your CircleCI organization"
    echo "  2. You are using CircleCI Server < 4.x without OIDC configuration"
    echo "  3. Your CircleCI plan does not include OIDC tokens"
    echo ""
    echo "To enable OIDC, check your CircleCI Organization Settings."
    exit 1
fi

echo "SUCCESS: CIRCLE_OIDC_TOKEN is available"
echo "Token length: ${#CIRCLE_OIDC_TOKEN} characters"
echo ""

# JWT uses base64url encoding - convert to standard base64 and add padding
decode_jwt_part() {
    local part="$1"
    # Replace URL-safe chars with standard base64 chars
    local b64
    b64=$(echo "$part" | tr '_-' '/+')
    # Add padding if needed
    local pad=$((4 - ${#b64} % 4))
    if [[ $pad -ne 4 ]]; then
        b64="${b64}$(printf '=%.0s' $(seq 1 $pad))"
    fi
    echo "$b64" | base64 -d 2>/dev/null
}

# Extract and decode payload
PAYLOAD=$(decode_jwt_part "$(echo "${CIRCLE_OIDC_TOKEN}" | cut -d. -f2)")

if [[ -z "${PAYLOAD}" ]]; then
    echo "ERROR: Failed to decode JWT payload"
    exit 1
fi

echo "=== OIDC Token Claims ==="
echo "${PAYLOAD}" | jq .
echo ""

echo "=== Key Values for Keyless Signing ==="
OIDC_ISSUER=$(echo "${PAYLOAD}" | jq -r '.iss')
ORG_ID=$(echo "${PAYLOAD}" | jq -r '.["oidc.circleci.com/org-id"]')
PROJECT_ID=$(echo "${PAYLOAD}" | jq -r '.["oidc.circleci.com/project-id"]')
PIPELINE_DEF_ID=$(echo "${PAYLOAD}" | jq -r '.["oidc.circleci.com/pipeline-definition-id"]')
VCS_ORIGIN=$(echo "${PAYLOAD}" | jq -r '.["oidc.circleci.com/vcs-origin"]')

echo "OIDC Issuer: ${OIDC_ISSUER}"
echo "Org ID: ${ORG_ID}"
echo "Project ID: ${PROJECT_ID}"
echo "Pipeline Definition ID: ${PIPELINE_DEF_ID}"
echo "VCS Origin: ${VCS_ORIGIN}"
echo ""

echo "=== Verification Parameters ==="
echo "For keyless verification, use these values:"
echo ""
echo "  certificate_oidc_issuer: \"${OIDC_ISSUER}\""
echo ""
echo "  # Option 1: Exact match (requires PIPELINE_DEFINITION_ID from Project Settings)"
echo "  certificate_identity: \"https://circleci.com/api/v2/projects/${PROJECT_ID}/pipeline-definitions/<your-pipeline-def-id>\""
echo ""
echo "  # Option 2: Regexp match (flexible, matches any pipeline definition)"
echo "  certificate_identity_regexp: \"https://circleci.com/api/v2/projects/${PROJECT_ID}/pipeline-definitions/.*\""
echo ""
echo "=== OIDC is ready for keyless signing ==="
