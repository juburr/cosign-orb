#!/bin/bash
# Verifies that the job's OIDC token is available and displays key claims:
# CIRCLE_OIDC_TOKEN in a CircleCI job, or a token from the token service of a
# GitHub Actions job. Used to confirm OIDC is properly configured before using
# keyless signing.

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the OIDC token.
set +o xtrace

# Load the CI helpers (src/scripts/lib/ci.sh).
if [[ -z "${SCRIPT_CI_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded. SCRIPT_CI_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_CI_LIB}"

if ci_github; then
    echo "=== GitHub Actions OIDC Token Check ==="
    echo ""
    # The token keyless signing gets: the sigstore audience, which also
    # checks that the job has the id-token: write permission.
    TOKEN=$(ci_sigstore_token) || exit 1
    echo "SUCCESS: An OIDC token with the sigstore audience is available"
    echo "Token length: ${#TOKEN} characters"
    echo ""
    PAYLOAD=$(ci_jwt_claims "${TOKEN}") || PAYLOAD=""
    if [[ -z "${PAYLOAD}" ]]; then
        echo "ERROR: Failed to decode JWT payload" >&2
        exit 1
    fi

    echo "=== OIDC Token Claims ==="
    echo "${PAYLOAD}" | jq .
    echo ""

    echo "=== Key Values for Keyless Signing ==="
    OIDC_ISSUER=$(echo "${PAYLOAD}" | jq -r '.iss')
    REPOSITORY=$(echo "${PAYLOAD}" | jq -r '.repository')
    WORKFLOW_REF=$(echo "${PAYLOAD}" | jq -r '.job_workflow_ref')
    echo "OIDC Issuer: ${OIDC_ISSUER}"
    echo "Repository: ${REPOSITORY}"
    echo "Workflow: ${WORKFLOW_REF}"
    echo ""

    echo "=== Verification Parameters ==="
    echo "For keyless verification, use these values:"
    echo ""
    echo "  certificate_oidc_issuer: \"${OIDC_ISSUER}\""
    echo ""
    echo "  # Option 1: Exact match (this workflow file, at this ref)"
    echo "  certificate_identity: \"${GITHUB_SERVER_URL:-https://github.com}/${WORKFLOW_REF}\""
    echo ""
    echo "  # Option 2: Regexp match (any workflow of this repository, the default in its jobs)"
    # Single quotes: YAML refuses the regexp's \. inside double quotes.
    echo "  certificate_identity_regexp: '$(ci_identity_regexp)'"
    echo ""
    echo "=== OIDC is ready for keyless signing ==="
    exit 0
fi

echo "=== CircleCI OIDC Token Check ==="
echo ""

if [[ -z "${CIRCLE_OIDC_TOKEN:-}" ]]; then
    echo "ERROR: CIRCLE_OIDC_TOKEN is not set" >&2
    echo "" >&2
    echo "Possible causes:" >&2
    echo "  1. OIDC is not enabled for your CircleCI organization" >&2
    echo "  2. You are using CircleCI Server < 4.x without OIDC configuration" >&2
    echo "  3. Your CircleCI plan does not include OIDC tokens" >&2
    echo "" >&2
    echo "To enable OIDC, check your CircleCI Organization Settings." >&2
    exit 1
fi

echo "SUCCESS: CIRCLE_OIDC_TOKEN is available"
echo "Token length: ${#CIRCLE_OIDC_TOKEN} characters"
echo ""

# Extract and decode payload. A decoding failure leaves PAYLOAD empty, which
# the check below reports.
PAYLOAD=$(ci_jwt_claims "${CIRCLE_OIDC_TOKEN}") || PAYLOAD=""

if [[ -z "${PAYLOAD}" ]]; then
    echo "ERROR: Failed to decode JWT payload" >&2
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
