#!/bin/bash

# Shared CI helpers. Commands load this file through an environment variable
# (SCRIPT_CI_LIB) and eval it, so it must only define functions. They let a
# script run the same way as a CircleCI command and as a GitHub Action:
#   - ci_subst expands environment variables in a parameter with the CircleCI
#     CLI, and uses the value as it is without it (GitHub Actions, local runs).
#   - ci_bool reads a boolean as CircleCI passes it (1 or 0) or as a GitHub
#     Actions input (true or false).
#   - ci_oidc_issuer, ci_identity_regexp and ci_sigstore_token give keyless
#     signing and verification the job's own OIDC identity: a CircleCI
#     project's, or a GitHub repository's workflows'.

# ci_subst VALUE: prints VALUE with environment variables expanded by
# `circleci env subst`, which reads it on stdin: passed as an argument, a
# value starting with "-" would be read as a flag. Without the CLI, it prints
# VALUE as it is.
ci_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s' "$1"
    fi
}

# ci_bool NAME VALUE: prints 1 for 1 or true, and 0 for 0, false or nothing.
# Anything else fails, naming the parameter.
ci_bool() {
    case "$2" in
        1 | true) echo 1 ;;
        0 | false | "") echo 0 ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            return 1
            ;;
    esac
}

# ci_github: succeeds in a GitHub Actions job.
ci_github() {
    [[ "${GITHUB_ACTIONS:-}" == true ]]
}

# ci_oidc_issuer: prints the issuer of this job's OIDC tokens, which Fulcio
# records in a keyless certificate:
#   - GitHub Actions: https://token.actions.githubusercontent.com, or
#     <server>/_services/token on GitHub Enterprise Server;
#   - CircleCI: https://oidc.circleci.com/org/<organization ID>.
# Prints nothing when it can't tell.
ci_oidc_issuer() {
    local server
    if ci_github; then
        server=${GITHUB_SERVER_URL:-https://github.com}
        if [[ "${server}" == "https://github.com" ]]; then
            echo "https://token.actions.githubusercontent.com"
        else
            echo "${server}/_services/token"
        fi
    elif [[ -n "${CIRCLE_ORGANIZATION_ID:-}" ]]; then
        echo "https://oidc.circleci.com/org/${CIRCLE_ORGANIZATION_ID}"
    fi
}

# ci_identity_regexp: prints a certificate identity regexp that matches the
# keyless certificates of this job's project:
#   - GitHub Actions: any workflow of this repository, as Fulcio records it
#     (<server>/<owner>/<repo>/.github/workflows/<file>@<ref>);
#   - CircleCI: any pipeline definition of this project.
# Prints nothing when it can't tell.
ci_identity_regexp() {
    local server repository
    if ci_github && [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        server=${GITHUB_SERVER_URL:-https://github.com}
        repository=${GITHUB_REPOSITORY}
        # Repository names can hold dots, which a regexp reads as any character.
        printf '^%s/%s/\\.github/workflows/\n' "${server//./\\.}" "${repository//./\\.}"
    elif [[ -n "${CIRCLE_PROJECT_ID:-}" ]]; then
        echo "https://circleci.com/api/v2/projects/${CIRCLE_PROJECT_ID}/pipeline-definitions/.*"
    fi
}

# ci_sigstore_token: prints an OIDC token for this job with the audience
# Fulcio expects, "sigstore", or fails with what is missing:
#   - GitHub Actions: from the job's token service, which needs the
#     id-token: write permission;
#   - CircleCI: from `circleci run oidc get`, since the job's
#     CIRCLE_OIDC_TOKEN has the organization ID as its audience.
ci_sigstore_token() {
    local response token="" status=0
    if ci_github; then
        if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
            echo "ERROR: This GitHub Actions job can't request an OIDC token." >&2
            echo "  Keyless signing needs the job (or workflow) to have the permission id-token: write." >&2
            echo "  Workflows that pull requests from forks run never get one." >&2
            return 1
        fi
        # The request token reaches curl as a header on stdin, never on its
        # command line, where other processes could read it.
        response=$(printf 'Authorization: bearer %s\n' "${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
            | curl -sS --fail --proto '=https' -H @- "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sigstore") || status=$?
        if [[ "${status}" -ne 0 ]]; then
            echo "ERROR: GitHub's token service refused the OIDC token request (curl exit code ${status})." >&2
            return 1
        fi
        token=$(printf '%s' "${response}" | jq -r '.value // empty' 2> /dev/null) || token=""
        if [[ -z "${token}" ]]; then
            echo "ERROR: GitHub's token service answered without an OIDC token." >&2
            return 1
        fi
    else
        if ! command -v circleci > /dev/null 2>&1; then
            echo "ERROR: The CircleCI CLI is not installed." >&2
            echo "  Keyless signing on CircleCI requests its OIDC token with circleci run oidc get." >&2
            return 1
        fi
        token=$(circleci run oidc get --claims '{"aud": "sigstore"}') || token=""
        if [[ -z "${token}" ]]; then
            echo "ERROR: Failed to get an OIDC token from CircleCI." >&2
            echo "" >&2
            echo "Keyless signing requires CircleCI OIDC to be enabled." >&2
            echo "Please ensure:" >&2
            echo "  1. You are using CircleCI Cloud or Server 4.x+" >&2
            echo "  2. OIDC is enabled for your organization" >&2
            echo "  3. Your plan supports OIDC tokens" >&2
            echo "" >&2
            echo "Run the 'check_oidc' command to diagnose OIDC issues." >&2
            return 1
        fi
    fi
    printf '%s\n' "${token}"
}

# ci_jwt_claims TOKEN: prints the claims of a JWT, its decoded payload.
ci_jwt_claims() {
    local part b64
    part=$(printf '%s' "$1" | cut -d. -f2)
    # base64url: URL-safe characters and no padding.
    b64=$(printf '%s' "${part}" | tr '_-' '/+')
    while ((${#b64} % 4)); do
        b64+="="
    done
    printf '%s' "${b64}" | base64 -d 2> /dev/null
}
