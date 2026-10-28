#!/bin/bash
#
# Runs one of the orb's scripts as a GitHub Actions step. The scripts are
# written for CircleCI, where a step hands values to later steps by appending
# exports to the file BASH_ENV names, which CircleCI sources before each
# step. GitHub Actions has no such file, so this gives the script a fresh
# one, then passes on what sourcing it changes, and every variable it
# exports, changed or not: new PATH entries through GITHUB_PATH, and other
# variables through GITHUB_ENV. It is identical in every juburr orb that
# ships GitHub Actions.
#
# Usage: run_script.sh SCRIPT [NAME=FILE ...]
#
# Each NAME=FILE sets the environment variable NAME, which must start with
# SCRIPT_, to the contents of FILE, as a CircleCI command passes a shared
# library to its script with << include(FILE) >>.
#
# The script's exit code is the step's; nothing is passed on when it fails.

set -euo pipefail
# The step's environment and what the script exports can hold secrets, which
# xtrace (SHELLOPTS, or set -x in the job's BASH_ENV) would print quoted.
set +o xtrace

if [[ $# -lt 1 || ! -f "$1" ]]; then
    echo "ERROR: Usage: run_script.sh SCRIPT [NAME=FILE ...], where SCRIPT is one of the orb's scripts." >&2
    exit 2
fi
SCRIPT=$1
shift
for name in GITHUB_ENV GITHUB_PATH; do
    if [[ -z "${!name:-}" ]]; then
        echo "ERROR: ${name} is not set. run_script.sh runs the orb's scripts in a GitHub Actions step." >&2
        exit 2
    fi
done
# Bash 4.0 reads an empty "$@" as unset.
SETTINGS=()
if [[ $# -gt 0 ]]; then
    SETTINGS=("$@")
fi
for setting in ${SETTINGS[@]+"${SETTINGS[@]}"}; do
    name=${setting%%=*}
    file=${setting#*=}
    if [[ "${setting}" != *=* || ! "${name}" =~ ^SCRIPT_[A-Z0-9_]+$ || ! -f "${file}" ]]; then
        echo "ERROR: ${setting} must be NAME=FILE, with NAME starting with SCRIPT_ and FILE one of the orb's files." >&2
        exit 2
    fi
    export "${name}=$(cat "${file}")"
done

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# A job's own BASH_ENV, if it sets one, is never read or written here.
export BASH_ENV="${WORK}/bash_env"
: > "${BASH_ENV}"
rc=0
bash "${SCRIPT}" || rc=$?
if [[ "${rc}" -ne 0 ]]; then
    exit "${rc}"
fi
if [[ ! -s "${BASH_ENV}" ]]; then
    exit 0
fi

# What sourcing the exports changes: the environment of a shell that
# sources them, against one that doesn't, both started from this one.
env -u BASH_ENV bash --noprofile --norc -c 'env -0' > "${WORK}/before"
# shellcheck disable=SC2016 # $1 is expanded by the inner shell
if ! env -u BASH_ENV bash --noprofile --norc -c '. "$1" && env -0' _ "${BASH_ENV}" > "${WORK}/after"; then
    echo "ERROR: The exports ${SCRIPT} wrote for later steps could not be read." >&2
    exit 1
fi

declare -A BEFORE=()
while IFS= read -r -d '' entry; do
    BEFORE[${entry%%=*}]=${entry#*=}
done < "${WORK}/before"

# The variables the script exports by name (export NAME=...), which are
# passed on even when the step already had the same value: a value from the
# step's own env reaches no later step unless it is written to GITHUB_ENV.
declare -A EXPORTED=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        EXPORTED[${BASH_REMATCH[1]}]=1
    fi
done < "${BASH_ENV}"

# delimiter VALUE: a random line that VALUE doesn't contain, to end a
# multi-line GITHUB_ENV value.
delimiter() {
    local candidate
    while true; do
        candidate="ghadelimiter_$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
        if [[ $'\n'"$1"$'\n' != *$'\n'"${candidate}"$'\n'* ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
}

while IFS= read -r -d '' entry; do
    name=${entry%%=*}
    value=${entry#*=}
    case "${name}" in
        _ | SHLVL | PWD | OLDPWD | BASH_ENV | BASH_FUNC_* | SCRIPT_*) continue ;;
    esac
    if [[ -n "${BEFORE[${name}]+set}" && "${BEFORE[${name}]}" == "${value}" && -z "${EXPORTED[${name}]+set}" ]]; then
        continue
    fi
    if [[ "${name}" == PATH ]]; then
        # The entries that weren't on the PATH. GitHub puts each line of
        # GITHUB_PATH before the ones written earlier, so they are written
        # last first, to keep their order.
        added=()
        IFS=: read -r -a entries <<< "${value}"
        for dir in ${entries[@]+"${entries[@]}"}; do
            if [[ -n "${dir}" && ":${BEFORE[PATH]:-}:" != *":${dir}:"* ]]; then
                added=("${dir}" ${added[@]+"${added[@]}"})
            fi
        done
        for dir in ${added[@]+"${added[@]}"}; do
            printf '%s\n' "${dir}" >> "${GITHUB_PATH}"
        done
        continue
    fi
    end=$(delimiter "${value}")
    printf '%s<<%s\n%s\n%s\n' "${name}" "${end}" "${value}" "${end}" >> "${GITHUB_ENV}"
done < "${WORK}/after"
