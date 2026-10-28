#!/usr/bin/env bash
# Tests for src/scripts/lib/ci.sh, the helpers that let the scripts run as
# CircleCI commands and as GitHub Actions.
#
# Locks how parameters are expanded and read as booleans with and without the
# CircleCI CLI, the OIDC issuer and certificate identity regexp each CI's
# keyless certificates carry, and how the Sigstore-audience token is
# requested: on GitHub Actions the request token must reach curl as a header
# on stdin, never as an argument, and every failure must say what is missing.
#
# Run from a checkout:
#   bash test/ci_lib_test.sh

# The code each case runs is single-quoted, to expand in the bash that runs
# it, not here.
# shellcheck disable=SC2016

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/src/scripts/lib/ci.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/nocli" "${TMP}/tools"

# A stand-in for the CircleCI CLI: env subst expands $NAME from stdin (as
# envsubst would, which needs no extra tool here), and run oidc get prints
# FAKE_OIDC_TOKEN when it is asked for the sigstore audience.
cat > "${TMP}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" && $# -eq 2 ]]; then
  value=$(cat)
  while [[ "${value}" =~ \$([A-Z_][A-Z0-9_]*) ]]; do
    name=${BASH_REMATCH[1]}
    value=${value//\$${name}/${!name:-}}
  done
  printf '%s' "${value}"
  exit 0
fi
if [[ "$*" == 'run oidc get --claims {"aud": "sigstore"}' && -n "${FAKE_OIDC_TOKEN:-}" ]]; then
  printf '%s\n' "${FAKE_OIDC_TOKEN}"
  exit 0
fi
exit 1
EOF

# A stand-in for curl: it records its arguments and the headers it read from
# stdin (-H @-), and answers with FAKE_CURL_BODY, or fails with
# FAKE_CURL_EXIT.
cat > "${TMP}/bin/curl" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_CURL_LOG}.args"
for arg in "$@"; do
  if [[ "${arg}" == "@-" ]]; then
    cat > "${FAKE_CURL_LOG}.stdin"
  fi
done
if [[ -n "${FAKE_CURL_EXIT:-}" ]]; then
  echo "curl: (22) The requested URL returned error: 403" >&2
  exit "${FAKE_CURL_EXIT}"
fi
printf '%s' "${FAKE_CURL_BODY:-}"
EOF
chmod +x "${TMP}/bin/circleci" "${TMP}/bin/curl"
# The tools the library and the stand-ins use, on every case's PATH; nocli
# has curl but not the CircleCI CLI.
for tool in jq base64 cut tr cat; do
  ln -s "$(command -v "${tool}")" "${TMP}/tools/${tool}"
done
ln -s "${TMP}/bin/curl" "${TMP}/nocli/curl"

FAILURES=0

# lib CLI_DIR [VAR=VALUE...] -- CODE: runs CODE in a bash that has loaded the
# library, with only CLI_DIR, the tools and bash's own directory on the PATH
# and the CI variables of this job cleared, then the given variables set.
# Sets OUT (stdout), ERR (stderr) and STATUS.
lib() {
  local dir="$1"
  shift
  local vars=()
  while [[ "$1" != "--" ]]; do
    vars+=("$1")
    shift
  done
  shift
  set +e
  OUT=$(env -i PATH="${dir}:${TMP}/tools:$(dirname "$(command -v bash)")" HOME="${TMP}" FAKE_CURL_LOG="${TMP}/curl" \
    ${vars[@]+"${vars[@]}"} bash -c 'set -euo pipefail; eval "$(cat "$1")"; '"$1" _ "${LIB}" 2> "${TMP}/err")
  STATUS=$?
  set -e
  ERR=$(cat "${TMP}/err")
}

expect() {
  local description="$1" status="$2" out="$3"
  if [[ "${STATUS}" -eq "${status}" && "${OUT}" == "${out}" ]]; then
    printf 'ok: %s\n' "${description}"
  else
    printf 'FAIL: %s\n    status %s (want %s)\n    stdout: %s\n    want:   %s\n    stderr: %s\n' \
      "${description}" "${STATUS}" "${status}" "${OUT}" "${out}" "${ERR}"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_err() {
  local description="$1" text="$2"
  # A tool's own message (curl's, say) may come first, and the text may be
  # on a continuation line of the ERROR: message.
  if [[ "${STATUS}" -ne 0 && "${ERR}" == *"${text}"* && $'\n'"${ERR}" == *$'\nERROR: '* ]]; then
    printf 'ok: %s\n' "${description}"
  else
    printf 'FAIL: %s\n    status %s, stderr: %s\n    want an ERROR: line with: %s\n' "${description}" "${STATUS}" "${ERR}" "${text}"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- ci_subst
lib "${TMP}/bin" NAME=world -- 'ci_subst "hello \$NAME"'
expect "ci_subst expands variables with the CircleCI CLI" 0 "hello world"
lib "${TMP}/bin" -- 'ci_subst "-n"'
expect "ci_subst passes a value starting with - on stdin, not as a flag" 0 "-n"
lib "${TMP}/nocli" NAME=world -- 'ci_subst "-e hello \$NAME"'
expect "ci_subst uses the value as is without the CLI" 0 "-e hello \$NAME"

# --- ci_bool
for value in 1 true; do
  lib "${TMP}/nocli" -- "ci_bool keyless ${value}"
  expect "ci_bool reads ${value} as 1" 0 "1"
done
for value in 0 false '""'; do
  lib "${TMP}/nocli" -- "ci_bool keyless ${value}"
  expect "ci_bool reads ${value} as 0" 0 "0"
done
lib "${TMP}/nocli" -- 'ci_bool keyless yes'
expect_err "ci_bool refuses anything else, naming the parameter" "keyless must be true or false, not 'yes'"

# --- ci_oidc_issuer
lib "${TMP}/nocli" GITHUB_ACTIONS=true -- 'ci_oidc_issuer'
expect "GitHub Actions issuer on github.com" 0 "https://token.actions.githubusercontent.com"
lib "${TMP}/nocli" GITHUB_ACTIONS=true GITHUB_SERVER_URL=https://github.com -- 'ci_oidc_issuer'
expect "GitHub Actions issuer with GITHUB_SERVER_URL set to github.com" 0 "https://token.actions.githubusercontent.com"
lib "${TMP}/nocli" GITHUB_ACTIONS=true GITHUB_SERVER_URL=https://ghe.example.com -- 'ci_oidc_issuer'
expect "GitHub Enterprise Server issuer" 0 "https://ghe.example.com/_services/token"
lib "${TMP}/nocli" CIRCLE_ORGANIZATION_ID=org-123 -- 'ci_oidc_issuer'
expect "CircleCI organization issuer" 0 "https://oidc.circleci.com/org/org-123"
lib "${TMP}/nocli" -- 'ci_oidc_issuer'
expect "no issuer outside CI" 0 ""

# --- ci_identity_regexp
lib "${TMP}/nocli" GITHUB_ACTIONS=true GITHUB_REPOSITORY=juburr/my.repo -- 'ci_identity_regexp'
expect "GitHub Actions identity regexp escapes dots" 0 '^https://github\.com/juburr/my\.repo/\.github/workflows/'
regexp=${OUT}
for identity in \
  "https://github.com/juburr/my.repo/.github/workflows/actions.yml@refs/heads/main" \
  "https://github.com/juburr/my.repo/.github/workflows/release.yml@refs/tags/v1.0.0"; do
  if [[ "${identity}" =~ ${regexp} ]]; then
    printf 'ok: the regexp matches %s\n' "${identity}"
  else
    printf 'FAIL: the regexp does not match %s\n' "${identity}"
    FAILURES=$((FAILURES + 1))
  fi
done
for identity in \
  "https://github.com/juburr/myXrepo/.github/workflows/actions.yml@refs/heads/main" \
  "https://github.com/juburr/my.repo-fork/.github/workflows/actions.yml@refs/heads/main" \
  "https://evil.example/https://github.com/juburr/my.repo/.github/workflows/x.yml@refs/heads/main"; do
  if [[ "${identity}" =~ ${regexp} ]]; then
    printf 'FAIL: the regexp matches %s\n' "${identity}"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok: the regexp does not match %s\n' "${identity}"
  fi
done
lib "${TMP}/nocli" GITHUB_ACTIONS=true GITHUB_SERVER_URL=https://ghe.example.com GITHUB_REPOSITORY=org/repo -- 'ci_identity_regexp'
expect "GitHub Enterprise Server identity regexp" 0 '^https://ghe\.example\.com/org/repo/\.github/workflows/'
lib "${TMP}/nocli" CIRCLE_PROJECT_ID=proj-456 -- 'ci_identity_regexp'
expect "CircleCI project identity regexp" 0 "https://circleci.com/api/v2/projects/proj-456/pipeline-definitions/.*"
lib "${TMP}/nocli" -- 'ci_identity_regexp'
expect "no identity regexp outside CI" 0 ""

# --- ci_sigstore_token on GitHub Actions
GITHUB_OIDC=(GITHUB_ACTIONS=true "ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example/idtoken?api-version=2.0"
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-secret-123)
lib "${TMP}/nocli" "${GITHUB_OIDC[@]}" 'FAKE_CURL_BODY={"count":1,"value":"header.payload.sig"}' -- 'ci_sigstore_token'
expect "ci_sigstore_token prints the token GitHub's token service returns" 0 "header.payload.sig"
if grep -qxF "https://token.example/idtoken?api-version=2.0&audience=sigstore" "${TMP}/curl.args"; then
  printf 'ok: the token is requested with the sigstore audience\n'
else
  printf 'FAIL: curl was called with:\n%s\n' "$(cat "${TMP}/curl.args")"
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "request-secret-123" "${TMP}/curl.args"; then
  printf 'FAIL: the request token is on curl'"'"'s command line\n'
  FAILURES=$((FAILURES + 1))
elif [[ "$(cat "${TMP}/curl.stdin")" == "Authorization: bearer request-secret-123" ]]; then
  printf 'ok: the request token reaches curl as a header on stdin\n'
else
  printf 'FAIL: curl read on stdin: %s\n' "$(cat "${TMP}/curl.stdin")"
  FAILURES=$((FAILURES + 1))
fi
if grep -qxF -- "--fail" "${TMP}/curl.args" && grep -qxF -- "=https" "${TMP}/curl.args"; then
  printf 'ok: curl runs with --fail and --proto =https\n'
else
  printf 'FAIL: curl was called with:\n%s\n' "$(cat "${TMP}/curl.args")"
  FAILURES=$((FAILURES + 1))
fi
lib "${TMP}/nocli" GITHUB_ACTIONS=true -- 'ci_sigstore_token'
expect_err "without the request variables, the error names id-token: write" "id-token: write"
lib "${TMP}/nocli" "${GITHUB_OIDC[@]}" FAKE_CURL_EXIT=22 -- 'ci_sigstore_token'
expect_err "a refused request fails" "refused the OIDC token request (curl exit code 22)"
lib "${TMP}/nocli" "${GITHUB_OIDC[@]}" 'FAKE_CURL_BODY={"message":"nope"}' -- 'ci_sigstore_token'
expect_err "an answer without a token fails" "answered without an OIDC token"
lib "${TMP}/nocli" "${GITHUB_OIDC[@]}" 'FAKE_CURL_BODY=<html>' -- 'ci_sigstore_token'
expect_err "an answer that isn't JSON fails" "answered without an OIDC token"

# --- ci_sigstore_token on CircleCI
lib "${TMP}/bin" FAKE_OIDC_TOKEN=circle.token.sig -- 'ci_sigstore_token'
expect "ci_sigstore_token asks the CircleCI CLI for the sigstore audience" 0 "circle.token.sig"
lib "${TMP}/bin" -- 'ci_sigstore_token'
expect_err "a CircleCI job without OIDC fails" "Failed to get an OIDC token from CircleCI"
lib "${TMP}/nocli" -- 'ci_sigstore_token'
expect_err "without the CircleCI CLI it fails" "The CircleCI CLI is not installed"

# --- ci_jwt_claims: base64url without padding, with - and _ in it.
payload='{"sub":"repo:o/r","x":"??>"}'
part=$(printf '%s' "${payload}" | base64 -w0 | tr '/+' '_-' | tr -d '=')
if [[ "${part}" != *_* && "${part}" != *-* ]]; then
  echo "FAIL: the test payload does not exercise base64url's characters (${part})"
  FAILURES=$((FAILURES + 1))
fi
lib "${TMP}/nocli" -- "ci_jwt_claims 'header.${part}.signature'"
expect "ci_jwt_claims decodes a base64url payload without padding" 0 "${payload}"

if [[ "${FAILURES}" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "${FAILURES}"
  exit 1
fi
printf '\nAll CI helper tests passed.\n'
