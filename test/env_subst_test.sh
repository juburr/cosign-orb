#!/usr/bin/env bash
#
# Parameter values must reach `circleci env subst` on stdin:
#
#   VALUE=$(printf '%s' "${PARAM_VALUE}" | circleci env subst)
#
# Passed as an argument instead, a value that starts with "-" (such as extra
# arguments like "--no-cache") is parsed by the CLI as a flag rather than
# substituted, so the step fails or gets the wrong value.
#
# This test fails if any script or command under src/ passes a value to
# `circleci env subst` as an argument. When a circleci CLI is on the PATH (as
# it is in CircleCI jobs), it also checks that the stdin form leaves values
# that start with "-" intact and still expands environment variables.
#
# Run from a checkout:
#   bash <this file>

set -euo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
cd "${ROOT}"

FAILURES=0

# A quote, "$" or "-" after the command means a value is passed as an argument.
# Comment lines are skipped, since they may describe that form.
ARGUMENT_CALLS=$(grep -rnE "circleci env subst[[:space:]]+[\"'\$-]" src \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -n "${ARGUMENT_CALLS}" ]]; then
    echo "FAIL: pass values to circleci env subst on stdin, not as an argument:"
    while IFS= read -r call; do
        printf '  %s\n' "${call}"
    done <<< "${ARGUMENT_CALLS}"
    FAILURES=$((FAILURES + 1))
else
    echo "ok: every circleci env subst call under src/ reads its value from stdin"
fi

# check INPUT WANT: substitutes INPUT the way the orb's scripts do.
check() {
    local input=$1
    local want=$2
    local got
    if ! got=$(printf '%s' "${input}" | circleci env subst); then
        got="(circleci env subst exited non-zero)"
    fi
    if [[ "${got}" == "${want}" ]]; then
        printf 'ok: %s\n' "${input}"
    else
        printf 'FAIL: %s became %s, wanted %s\n' "${input}" "${got}" "${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

if command -v circleci > /dev/null 2>&1; then
    export ORB_ENV_SUBST_TEST_VALUE="expanded"
    check "--no-cache" "--no-cache"
    check "--help" "--help"
    check "-n" "-n"
    check "-e" "-e"
    # shellcheck disable=SC2016 # expanded by circleci env subst, not by bash
    check '--label=${ORB_ENV_SUBST_TEST_VALUE}' "--label=expanded"
    # shellcheck disable=SC2016 # expanded by circleci env subst, not by bash
    check '$ORB_ENV_SUBST_TEST_VALUE' "expanded"
else
    echo "skip: no circleci CLI on the PATH, so the stdin form was not run against one"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All circleci env subst tests passed."
