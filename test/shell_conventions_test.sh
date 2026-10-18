#!/bin/bash
#
# Checks the shell conventions every juburr orb's src/scripts follow. The same
# file is in every orb; keep the copies identical.
#
#   1. The first line is #!/bin/bash.
#   2. The first command is `set -euo pipefail`. Libraries under lib/ are
#      eval'ed by a script that already set it, so they have no set line.
#      A script that must not stop on errors says why on a line
#      `# shell-conventions: no-errexit <reason>` and uses `set -uo pipefail`.
#   3. No `set +o history` (a no-op in a non-interactive shell) and no
#      `set -x` (it would print secrets).
#   4. Messages start with ERROR: or WARN: and go to stderr: every echo or
#      printf line that has one of them also has >&2. Error:, FATAL:,
#      WARNING: and Warning: are not used.
#   5. Lines written to $BASH_ENV quote their value with printf %q, so no
#      value can end the quoting or run a command when later steps source it.
#   6. eval only runs code the orb itself includes: a variable whose name
#      ends in _LIB or _SCRIPT.
#
# The shared install code (install.sh, install_hash.sh and cache_key.sh) is
# not checked here. It is kept identical across the orbs as a unit, and
# install_hash.sh sends a function's messages to stderr where it calls it,
# which a line-by-line check can't see.

set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
while [[ ! -f "${root}/src/@orb.yml" ]]; do
    [[ "${root}" != / ]] || { echo "ERROR: src/@orb.yml not found above $0" >&2; exit 1; }
    root=$(dirname "${root}")
done

failures=0
fail() {
    printf 'FAIL: %s\n' "$*"
    failures=$((failures + 1))
}

mapfile -t scripts < <(cd "${root}" && find src/scripts -name '*.sh' -type f \
    ! -path src/scripts/install.sh ! -path src/scripts/install_hash.sh ! -path src/scripts/cache_key.sh |
    LC_ALL=C sort)
if [[ ${#scripts[@]} -eq 0 ]]; then
    echo "No scripts to check besides the shared install code."
    exit 0
fi

for script in "${scripts[@]}"; do
    path="${root}/${script}"

    # 1. Shebang.
    if [[ "$(head -n 1 "${path}")" != "#!/bin/bash" ]]; then
        fail "${script}: the first line must be #!/bin/bash"
    fi

    # 2. The first command, skipping comments, blank lines, and the bash
    # version guard install.sh runs before it.
    if [[ "${script}" != */lib/* ]]; then
        want="set -euo pipefail"
        if grep -qE '^# shell-conventions: no-errexit [^ ]' "${path}"; then
            want="set -uo pipefail"
        fi
        first=$(awk '
            /^[[:space:]]*(#|$)/ { next }
            /^if \[ -z "\$\{BASH_VERSION:-\}" \]/ { guard = 1 }
            guard { if ($0 ~ /^fi$/) guard = 0; next }
            { print; exit }
        ' "${path}")
        if [[ "${first}" != "${want}" ]]; then
            fail "${script}: the first command must be '${want}', not '${first}'"
        fi
    fi

    # Checks 3 to 6 read code lines only: comment lines are skipped.
    lineno=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        where="${script}:${lineno}"

        # 3. History and xtrace.
        if [[ "${line}" =~ (^|[[:space:];])set[[:space:]]+\+o[[:space:]]+history ]]; then
            fail "${where}: remove 'set +o history'; it does nothing in a non-interactive shell"
        fi
        if [[ "${line}" =~ (^|[[:space:];])set[[:space:]]+(-[a-wyz]*x|-o[[:space:]]+xtrace) ]]; then
            fail "${where}: do not enable xtrace; it prints secrets"
        fi

        # 4. Message prefixes.
        if [[ "${line}" =~ (^|[[:space:];|&\(])(echo|printf)[[:space:]] ]]; then
            if [[ "${line}" =~ (Error|FATAL|WARNING|Warning): ]]; then
                fail "${where}: use ERROR: or WARN:, not ${BASH_REMATCH[1]}:"
            fi
            if [[ "${line}" =~ (ERROR|WARN): ]] && [[ "${line}" != *">&2"* ]]; then
                fail "${where}: ${BASH_REMATCH[1]}: messages go to stderr (>&2)"
            fi
            # 5. Exports: a value expanded in a double-quoted string, or filled
            # in by %s, must be quoted with %q instead.
            if [[ "${line}" != *"%q"* ]] \
                && { [[ "${line}" =~ \"export[[:space:]]+[^\"=]+=[^\"]*(\$|%s) ]] \
                    || [[ "${line}" =~ \'export[[:space:]]+[^\'=]+=[^\']*%s ]]; }; then
                fail "${where}: write exports with printf 'export %s=%q\\n' NAME \"\$value\""
            fi
        fi

        # 6. eval, where a command starts: not in "oscap xccdf eval".
        cmd_start='(^|[;&|(]|\$\(|(^|[[:space:]])(then|do|else))[[:space:]]*'
        if [[ "${line}" =~ ${cmd_start}eval[[:space:]] ]] \
            && ! [[ "${line}" =~ ${cmd_start}eval[[:space:]]+\"\$\{[A-Z0-9_]+_(LIB|SCRIPT)\}\"[[:space:]]*($|[;|&#]) ]]; then
            fail "${where}: eval may only run orb code (\"\${NAME_LIB}\" or \"\${NAME_SCRIPT}\")"
        fi
    done < "${path}"
done

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} shell convention failure(s) in ${#scripts[@]} scripts."
    exit 1
fi
echo "All ${#scripts[@]} scripts follow the shell conventions."
