#!/usr/bin/env bash
#
# Tests for the GitHub Actions in actions/, run offline. It checks that:
#
#   - every orb command has an action of the same name, and every action a
#     command, so the two can't drift apart
#   - each action takes the command's parameters as inputs, with the same
#     defaults, passes each to its scripts as the same PARAM_ variables the
#     command sets, and runs the scripts the command includes. A command
#     whose steps run other commands of the orb (an install command that
#     runs install_<tool>, say) must run what those commands run, with the
#     inputs the command passes them
#   - inputs only reach a step through env, if: conditions and paths (a
#     step's working-directory, or an action's path), never inside a run
#     script, where GitHub would paste them in as code
#   - a command that stores artifacts has an action that uploads them, even
#     when an earlier step fails
#   - defaults that a YAML 1.1 reader would take for a boolean or a number
#     are quoted, since every input is a string
#   - every action another one uses is pinned to a full commit SHA
#   - actions/run_script.sh runs a script and passes on what it exports for
#     later steps: PATH entries through GITHUB_PATH, in order, and other
#     variables through GITHUB_ENV, multi-line values included, and values
#     the step already had included; it passes on nothing when the script
#     fails, keeps its exit code, hands the script a library the way
#     CircleCI's << include() >> does, and traces nothing, even in a job
#     that traces every step
#
# Identical in every juburr orb that ships GitHub Actions.
#
# Run from a checkout:
#   bash PATH_TO_THIS_FILE

# The bodies of the scripts run_script.sh runs, and the patterns grep
# matches, are single-quoted to keep them from expanding here.
# shellcheck disable=SC2016

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
RUN_SCRIPT="${ROOT}/actions/run_script.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
OUTPUT=""
DETAIL=""
RC=0

begin() {
    echo "--- $1"
}

check() {
    local description=$1
    shift
    DETAIL=""
    if "$@"; then
        echo "  ok: ${description}"
    else
        echo "  FAIL: ${description}"
        while IFS= read -r line; do
            echo "    | ${line}"
        done <<< "${DETAIL:-${OUTPUT}}"
        FAILURES=$((FAILURES + 1))
    fi
}

same() {
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    DETAIL=$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$1") | sed -e 's/^</expected:/' -e 's/^>/got:     /' | grep -v '^[0-9]')
    return 1
}
none() {
    if [[ -z "$1" ]]; then
        return 0
    fi
    DETAIL=$1
    return 1
}
rc_is() { [[ "${RC}" -eq "$1" ]]; }
output_has() { [[ "${OUTPUT}" == *"$1"* ]]; }

# fields FILE BLOCK: "name=default" for each entry of a top-level mapping
# (parameters: in a command, inputs: in an action), sorted. A default's
# quotes are dropped, so true and "true" match.
fields() {
    awk -v block="$2:" '
        $0 == block { inside = 1; next }
        /^[^ #]/ { inside = 0 }
        !inside { next }
        /^  [a-z_][a-z0-9_]*:[ ]*$/ { if (name != "") print name "=" value; name = $1; sub(/:$/, "", name); value = ""; next }
        /^    default:/ { value = $0; sub(/^    default:[ ]*/, "", value); gsub(/^"|"$/, "", value) }
        END { if (name != "") print name "=" value }
    ' "$1" | LC_ALL=C sort
}

# passed FILE PATTERN: the "PARAM_X=y" pairs a file sets, from lines such as
# "PARAM_X: << parameters.y >>" or "PARAM_X: ${{ inputs.y }}", one per
# line it is set on, so a variable set in two steps counts twice.
passed() {
    sed -nE "s/^ +(PARAM_[A-Z0-9_]+): ${2}$/\\1=\\2/p" "$1"
}

# included FILE: the files a command includes, as their paths under src/.
included() {
    grep -oE '<< include\(([^)]+)\) >>' "$1" | sed -E 's/<< include\((.*)\) >>/\1/'
}

# invoked FILE: for each step of a command that runs another of the orb's
# commands, "COMMAND PARAMETER INPUT" for each parameter it passes it, and
# "COMMAND" alone for one it passes none.
invoked() {
    awk -v dir="${ROOT}/src/commands" '
        function known(name,   path, found) { path = dir "/" name ".yml"; found = (getline line < path) > 0; close(path); return found }
        match($0, /^ +- [a-z_][a-z0-9_]*:[ ]*$/) {
            name = $0; sub(/^ +- /, "", name); sub(/:[ ]*$/, "", name)
            indent = index($0, "-")
            current = ""
            if (name != "run" && name != "when" && name != "restore_cache" && name != "save_cache" \
                && name != "store_artifacts" && name != "store_test_results" && known(name)) {
                current = name; print name
            }
            next
        }
        current != "" {
            match($0, /^ */)
            if (NF && RLENGTH < indent + 2) { current = ""; next }
            if ($0 ~ /^ +[a-z_][a-z0-9_]*: << parameters\.[a-z0-9_]+ >>$/) {
                key = $1; sub(/:$/, "", key)
                value = $0; sub(/^.*parameters\./, "", value); sub(/ >>$/, "", value)
                print current " " key " " value
            }
        }
    ' "$1"
}

# expected_passed FILE: the PARAM_ pairs an action for the command in FILE
# must set: the command's own, and those of every command it runs, with the
# parameters it passes them renamed to its own.
expected_passed() {
    local yml=$1 entry command parameter input pair var name
    passed "${yml}" '<< parameters\.([a-z0-9_]+) >>'
    while IFS= read -r command; do
        [[ "${command}" == *" "* ]] && continue
        declare -A rename=()
        while read -r entry parameter input; do
            [[ "${entry}" == "${command}" && -n "${parameter}" ]] && rename[${parameter}]=${input}
        done < <(invoked "${yml}")
        while IFS= read -r pair; do
            var=${pair%%=*}
            name=${pair#*=}
            printf '%s=%s\n' "${var}" "${rename[${name}]:-<${command}.${name} not passed>}"
        done < <(passed "${ROOT}/src/commands/${command}.yml" '<< parameters\.([a-z0-9_]+) >>')
        unset rename
    done < <(invoked "${yml}")
}

# expected_scripts FILE: the files the action for the command in FILE must
# use: what the command includes, and what every command it runs includes.
expected_scripts() {
    local command
    included "$1"
    while IFS= read -r command; do
        [[ "${command}" == *" "* ]] && continue
        included "${ROOT}/src/commands/${command}.yml"
    done < <(invoked "$1")
}

# --------------------------------------------------------- command and action
for command_yml in "${ROOT}"/src/commands/*.yml; do
    name=$(basename "${command_yml}" .yml)
    action_yml="${ROOT}/actions/${name}/action.yml"
    begin "${name}"
    check "has an action at actions/${name}" test -f "${action_yml}"
    [[ -f "${action_yml}" ]] || continue
    check "takes the command's parameters as inputs, with the same defaults" \
        same "$(fields "${action_yml}" inputs)" "$(fields "${command_yml}" parameters)"
    check "passes each input to its scripts as the command does" \
        same "$(passed "${action_yml}" '\$\{\{ inputs\.([a-z0-9_]+) \}\}' | LC_ALL=C sort)" \
        "$(expected_passed "${command_yml}" | LC_ALL=C sort)"
    missing=""
    while IFS= read -r script; do
        [[ -n "${script}" ]] || continue
        grep -qF "/src/${script}\"" "${action_yml}" || missing+="${script} "
    done < <(expected_scripts "${command_yml}" | LC_ALL=C sort -u)
    check "runs every script the command includes" none "${missing}"
    if grep -qE '^ +- store_artifacts:' "${command_yml}"; then
        check "uploads the reports as artifacts, even when a step fails" \
            grep -qE '^ +if: always\(\) && \(inputs\.store_artifacts == .true. \|\| inputs\.store_artifacts == .1.\)$' "${action_yml}"
    fi
done
for action_yml in "${ROOT}"/actions/*/action.yml; do
    name=$(basename "$(dirname "${action_yml}")")
    begin "actions/${name}"
    check "has an orb command of the same name" test -f "${ROOT}/src/commands/${name}.yml"
    # An input may appear in env (NAME: ${{ inputs.x }}), in if: conditions,
    # which GitHub evaluates as expressions, not code, and as a path: a
    # step's working-directory, or the path an action it uses takes.
    # GitHub passes every input as a string; a YAML 1.1 reader takes an
    # unquoted on or yes for a boolean.
    check "quotes defaults that read as booleans or numbers" none "$(grep -nEi '^    default: (on|off|yes|no|y|n|true|false|[0-9][0-9.]*)$' "${action_yml}")"
    check "uses inputs only in env, if: conditions and paths" none "$(grep -nF '${{ inputs.' "${action_yml}" \
        | grep -vE '^[0-9]+: +[A-Z_][A-Z0-9_]*: \$\{\{ inputs\.[a-z0-9_]+ \}\}$' \
        | grep -vE '^[0-9]+: +(working-directory|path): \$\{\{ inputs\.[a-z0-9_]+ \}\}$' \
        | grep -vE '^[0-9]+: +(- )?if: ')"
done

begin "pinned actions"
unpinned=$(grep -nE '^\s+(- )?uses: ' "${ROOT}"/actions/*/action.yml "${ROOT}"/.github/workflows/*.yml 2> /dev/null \
    | grep -vE 'uses: \./' \
    | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$')
check "every action used is pinned to a commit SHA, with its version in a comment" none "${unpinned}"

# --------------------------------------------------------------- run_script.sh
# run SCRIPT_BODY [VAR=value ...]: runs a script with that body through
# run_script.sh, with fresh GITHUB_ENV and GITHUB_PATH files. Sets RC and
# OUTPUT. RUN_ARGS holds any NAME=FILE arguments for run_script.sh.
RUN_ARGS=()
run() {
    local body=$1 vars=()
    shift
    # Bash 4.0 reads an empty "$@" as unset.
    if [[ $# -gt 0 ]]; then
        vars=("$@")
    fi
    rm -rf "${WORK}/case" && mkdir -p "${WORK}/case"
    printf '#!/bin/bash\nset -euo pipefail\n%s\n' "${body}" > "${WORK}/case/script.sh"
    : > "${WORK}/case/env"
    : > "${WORK}/case/path"
    RC=0
    OUTPUT=$(env GITHUB_ENV="${WORK}/case/env" GITHUB_PATH="${WORK}/case/path" ${vars[@]+"${vars[@]}"} \
        bash "${RUN_SCRIPT}" "${WORK}/case/script.sh" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} 2>&1) || RC=$?
    RUN_ARGS=()
}
github_path() { cat "${WORK}/case/path"; }
github_env() { cat "${WORK}/case/env"; }
# env_value NAME: the value GITHUB_ENV gives NAME, read as GitHub reads it.
env_value() {
    awk -v name="$1" '
        !inside && index($0, name "<<") == 1 { end = substr($0, length(name) + 3); inside = 1; value = ""; first = 1; next }
        inside && $0 == end { inside = 0; printf "%s", value; exit }
        inside { value = value (first ? "" : "\n") $0; first = 0 }
    ' "${WORK}/case/env"
}

begin "run_script.sh: PATH"
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/tool/bin >> "${BASH_ENV}"'
check "succeeds" rc_is 0
check "adds the directory to GITHUB_PATH" same "$(github_path)" "/opt/tool/bin"
check "and nothing to GITHUB_ENV" none "$(github_env)"
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/second >> "${BASH_ENV}"
printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/first >> "${BASH_ENV}"'
check "writes several directories last first, so GitHub keeps their order" same "$(github_path)" $'/opt/second\n/opt/first'
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /usr/bin >> "${BASH_ENV}"'
check "leaves out a directory already on the PATH" none "$(github_path)"

begin "run_script.sh: other variables"
run 'printf '"'"'export %s=%q\n'"'"' TOOL_DIGEST sha256:abc >> "${BASH_ENV}"'
check "passes a variable through GITHUB_ENV" same "$(env_value TOOL_DIGEST)" "sha256:abc"
check "ended by a random delimiter" grep -qE '^TOOL_DIGEST<<ghadelimiter_[0-9a-f]{32}$' "${WORK}/case/env"
run 'notes=$'"'"'line one\n\nline three'"'"'
printf '"'"'export %s=%q\n'"'"' NOTES "${notes}" >> "${BASH_ENV}"'
check "keeps a multi-line value" same "$(env_value NOTES)" $'line one\n\nline three'
run 'printf '"'"'export %s=%q\n'"'"' KEPT "$KEPT" >> "${BASH_ENV}"' KEPT=same
check "passes on a variable it exports with the value the step already had" same "$(env_value KEPT)" "same"
run 'printf '"'"'export %s=%q\n'"'"' TOOL_DIGEST sha256:abc >> "${BASH_ENV}"' UNTOUCHED=same
check "and no variable it doesn't export" same "$(github_env | grep -c '^UNTOUCHED<<')" 0
run 'printf '"'"'export %s=%q\n'"'"' QUOTED "a \"b\" \$c \`d\`" >> "${BASH_ENV}"'
check "passes quotes, dollars and backticks as they are" same "$(env_value QUOTED)" 'a "b" $c `d`'

begin "run_script.sh: tracing"
# A job can trace every step with SHELLOPTS or set -x in its BASH_ENV. The
# quoted forms xtrace prints don't match the secrets GitHub masks.
SECRET_VALUE="prefix'secret-suffix"
run 'printf '"'"'export %s=%q\n'"'"' TOKEN "$TOKEN" >> "${BASH_ENV}"' SHELLOPTS=xtrace "TOKEN=${SECRET_VALUE}"
check "traces nothing in a job that exports SHELLOPTS=xtrace" none "$(grep -F 'secret-suffix' <<< "${OUTPUT}")"
check "and still passes the value on" same "$(env_value TOKEN)" "${SECRET_VALUE}"
printf 'set -x\n' > "${WORK}/job-bash-env"
run 'printf '"'"'export %s=%q\n'"'"' TOKEN "$TOKEN" >> "${BASH_ENV}"' BASH_ENV="${WORK}/job-bash-env" "TOKEN=${SECRET_VALUE}"
check "or that sets -x in its BASH_ENV" none "$(grep -F 'secret-suffix' <<< "${OUTPUT}")"

begin "run_script.sh: libraries"
printf '%s\n' 'lib_greet() { echo "hello from the library"; }' > "${WORK}/lib.sh"
RUN_ARGS=("SCRIPT_TEST_LIB=${WORK}/lib.sh")
run 'eval "${SCRIPT_TEST_LIB}"; lib_greet; printf '"'"'export %s=%q\n'"'"' DONE yes >> "${BASH_ENV}"'
check "sets SCRIPT_ variables to a file's contents, as << include() >> does" output_has "hello from the library"
check "and doesn't pass the library on to later steps" same "$(github_env | grep -c '^SCRIPT_TEST_LIB<<')" 0
RUN_ARGS=("NOT_A_SCRIPT_VAR=${WORK}/lib.sh")
run 'true'
check "refuses a variable that doesn't start with SCRIPT_" rc_is 2
RUN_ARGS=("SCRIPT_TEST_LIB=${WORK}/missing.sh")
run 'true'
check "refuses a file that doesn't exist" rc_is 2

begin "run_script.sh: the script's own result"
run 'echo "to stdout"; echo "WARN: to stderr" >&2'
check "shows the script's output" output_has "to stdout"
check "and its warnings" output_has "WARN: to stderr"
check "writes nothing when nothing is exported" none "$(github_env)$(github_path)"
run 'printf '"'"'export PATH=%q:"${PATH}"\n'"'"' /opt/tool/bin >> "${BASH_ENV}"; exit 3'
check "keeps a failing script's exit code" rc_is 3
check "and passes nothing on" none "$(github_env)$(github_path)"
run 'printf '"'"'export %s=%q\n'"'"' LEAK yes >> "${BASH_ENV}"' BASH_ENV=/nonexistent/job-bash-env
check "gives the script its own BASH_ENV, not the job's" same "$(env_value LEAK)" "yes"
run 'true' GITHUB_ENV=
check "refuses to run without GITHUB_ENV" rc_is 2
check "saying so" output_has "ERROR: GITHUB_ENV is not set."

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All GitHub Actions checks passed."
