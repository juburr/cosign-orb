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
#   3. No `set +o history` (a no-op in a non-interactive shell), and no set
#      command that turns xtrace on (it would print secrets).
#   4. Messages start with ERROR: or WARN: and go to stderr: every echo or
#      printf command that prints one of them starts its first argument
#      (after options, redirections, and a bare '%s\n' format) with it and
#      has >&2 or 1>&2 (or is inside a { ...; } >&2 group on the same line).
#      Heredoc bodies are data and are not checked for this.
#      Error:, FATAL:, WARNING: and Warning: are not used.
#   5. Exports written by echo or printf quote every value (every NAME=
#      after an export, not only the first) with printf %q, so no value can
#      end the quoting or run a command when later steps source $BASH_ENV.
#      This applies to every printed export, not only to lines that name
#      $BASH_ENV: exports also reach it through groups, tee and helper files.
#   6. eval only runs code the orb itself includes: a variable whose name
#      ends in _LIB or _SCRIPT.
#
# Each line is split into its commands at ;, &, |, && and || outside quotes,
# and every command is checked on its own. Checks 3 and 6 also look inside
# each $(...) or backtick substitution, and a command may follow keywords,
# a one-line function declaration, a case pattern, variable assignments,
# redirections, and command or builtin. A >&2 only counts outside quotes and
# comments. Commands that span lines, or a { ...; } >&2 group over several
# lines, are not followed: write one message command per line with its own
# >&2.
#
# This is a line check of the ordinary spellings, not a shell parser. Code
# can still hide from it (a quoted command word such as 'eval', a command
# split over lines, a message in a heredoc that a shell runs), so review
# still applies.
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

# split_commands LINE: sets the commands array to LINE's commands, split at
# ;, &, |, &&, || and |& outside single and double quotes (the & in >&2 or &>
# is a redirection), and the skeletons array to the same commands with quoted
# text and a trailing # comment removed.
split_commands() {
    local line=$1 current="" skeleton="" quote="" char prev=" " i
    commands=()
    skeletons=()
    for ((i = 0; i < ${#line}; i++)); do
        char=${line:i:1}
        if [[ "${quote}" == "'" ]]; then
            [[ "${char}" != "'" ]] || quote=""
        elif [[ "${char}" == "\\" ]]; then
            current+=${char}
            i=$((i + 1))
            char=${line:i:1}
        elif [[ "${quote}" == '"' ]]; then
            [[ "${char}" != '"' ]] || quote=""
        elif [[ "${char}" == "'" || "${char}" == '"' ]]; then
            quote=${char}
        elif [[ "${char}" == "#" && "${prev}" =~ [[:space:]] ]]; then
            break
        elif [[ "${char}" == ";" ]]; then
            commands+=("${current}")
            skeletons+=("${skeleton}")
            current=""
            skeleton=""
            prev=${char}
            continue
        elif [[ "${char}" == "|" ]] ||
            [[ "${char}" == "&" && "${prev}" != [\<\>] && "${line:i+1:1}" != ">" ]]; then
            commands+=("${current}")
            skeletons+=("${skeleton}")
            current=""
            skeleton=""
            if [[ "${line:i+1:1}" == "${char}" || "${char}${line:i+1:1}" == "|&" ]]; then
                i=$((i + 1))
            fi
            prev=${char}
            continue
        else
            skeleton+=${char}
        fi
        current+=${char}
        prev=${char}
    done
    commands+=("${current}")
    skeletons+=("${skeleton}")
}

if [[ ! -d "${root}/src/scripts" ]]; then
    echo "ERROR: ${root}/src/scripts does not exist" >&2
    exit 1
fi
# A command substitution, so set -e stops here if find fails.
listing=$(cd "${root}" && find src/scripts -name '*.sh' -type f \
    ! -path src/scripts/install.sh ! -path src/scripts/install_hash.sh ! -path src/scripts/cache_key.sh |
    LC_ALL=C sort)
scripts=()
if [[ -n "${listing}" ]]; then
    mapfile -t scripts <<< "${listing}"
fi
if [[ ${#scripts[@]} -eq 0 ]]; then
    echo "No scripts to check besides the shared install code."
    exit 0
fi

# Where a command word starts within one command: after keywords, !, {, (,
# a one-line function declaration (f() { or function f {), a case pattern,
# variable assignments and redirections, behind the command or builtin
# wrappers, and after a backslash (\eval).
lead='^[[:space:]]*((if|then|do|else|elif|while|until|time|!|\{|\()[[:space:]]+|\(|(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)[[:space:]]*\{[[:space:]]+|function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]+\{[[:space:]]+|case[[:space:]].*[[:space:]]in[[:space:]]+|\(?[^[:space:]()]+\)[[:space:]]*)*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[0-9]*[<>]+&?[[:space:]]*[^[:space:]<>]+)[[:space:]]+)*((command|builtin)[[:space:]]+)*\\?'
allowed_eval='eval[[:space:]]+"\$\{[A-Z0-9_]+_(LIB|SCRIPT)\}"[[:space:]]*([)`].*)?$'
# What may come before an echo or printf's message text: options and
# redirections, and for printf a bare '%s\n' format.
before_text='^([[:space:]]*(-[A-Za-z-]*|[0-9]*>&[0-9]+|[0-9]*>>?[[:space:]]*[^[:space:]]+)[[:space:]]+)*'
printf_format=$'(["\']%s(\\\\n)?["\'][[:space:]]+)?'
text_start=$'["\']?(ERROR|WARN):'
assignment_re='^([A-Za-z_][A-Za-z0-9_]*|%[a-z])=([^[:space:]\\]*)[[:space:]]*(.*)'
# A >&2 or 1>&2 (3>&2 sends descriptor 3, not stdout).
stderr_re='(^|[^0-9])1?>&2([^0-9]|$)'
# A heredoc's start: <<WORD, <<-WORD, <<'WORD' or <<"WORD", but not <<<.
heredoc_re="(^|[^<])<<(-?)[[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_]*)"

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

    # Checks 3 to 6 read code lines only: comment lines are skipped, and so
    # are lines with no echo, printf, set or eval (base64 payloads, data).
    lineno=0
    heredoc=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        # Checks 4 and 5 skip heredoc bodies, which are data. Checks 3 and 6
        # still read them: a heredoc fed to a shell is code, and an unquoted
        # one runs the $(...) in it.
        in_heredoc=false
        if [[ -n "${heredoc}" ]]; then
            delimiter_line=${line}
            while [[ "${strip_tabs}" == true && "${delimiter_line}" == $'\t'* ]]; do
                delimiter_line=${delimiter_line:1}
            done
            if [[ "${delimiter_line}" == "${heredoc}" ]]; then
                heredoc=""
                continue
            fi
            in_heredoc=true
        elif [[ "${line}" == *"<<"* ]]; then
            split_commands "${line}"
            for ((c = 0; c < ${#commands[@]}; c++)); do
                # $(( a << b )) is a shift, not a heredoc.
                if [[ "${skeletons[c]}" == *"<<"* && "${skeletons[c]}" != *"(("* && "${commands[c]}" =~ ${heredoc_re} ]]; then
                    heredoc=${BASH_REMATCH[3]}
                    strip_tabs=false
                    if [[ "${BASH_REMATCH[2]}" == "-" ]]; then
                        strip_tabs=true
                    fi
                    break
                fi
            done
        fi
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ (echo|printf|set|eval) ]] || continue
        where="${script}:${lineno}"
        split_commands "${line}"

        # A { ...; } >&2 or ( ...; ) >&2 group on this line sends every
        # command in it to stderr.
        group_to_stderr=false
        if [[ "${skeletons[-1]}" =~ ^[[:space:]]*[\}\)][[:space:]]*(1?>&2)([[:space:]]|$) ]]; then
            group_to_stderr=true
        fi

        for ((c = 0; c < ${#commands[@]}; c++)); do
            cmd=${commands[c]}
            skeleton=${skeletons[c]}
            # Checks 3 and 6 look at the command and at the text after each
            # $( or backtick in it.
            positions=("${cmd}")
            rest=${cmd}
            while [[ "${rest}" =~ (\$\(|\`)(.*) ]]; do
                rest=${BASH_REMATCH[2]}
                positions+=("${rest}")
            done
            for text in "${positions[@]}"; do
                # 3. History and xtrace: any -...x... option or -o xtrace
                # before the -- that ends set's options.
                if [[ "${text}" =~ ${lead}set([[:space:]]|$) ]]; then
                    options=${text%%[[:space:]]--[[:space:]]*}
                    options=${options%[[:space:]]--}
                    if [[ "${options}" =~ [[:space:]]\+o[[:space:]]+history ]]; then
                        fail "${where}: remove 'set +o history'; it does nothing in a non-interactive shell"
                    fi
                    if [[ "${options}" =~ [[:space:]]-[A-Za-z]*x[A-Za-z]*([[:space:]]|[\)\}&|\`]|$) ||
                        "${options}" =~ -o[[:space:]]+xtrace([[:space:]]|[\)\}&|\`]|$) ]]; then
                        fail "${where}: do not enable xtrace; it prints secrets"
                    fi
                fi
                # 6. eval.
                if [[ "${text}" =~ ${lead}eval([[:space:]]|$) ]] && ! [[ "${text}" =~ ${lead}${allowed_eval} ]]; then
                    fail "${where}: eval may only run orb code (\"\${NAME_LIB}\" or \"\${NAME_SCRIPT}\")"
                fi
            done

            if [[ "${in_heredoc}" == false && "${cmd}" =~ ${lead}(echo|printf)([[:space:]]|$) ]]; then
                command_word=${BASH_REMATCH[0]}
                arguments=${cmd:${#command_word}}
                # 4. Message prefixes.
                # A prefix is a whole word: failOnError: is a YAML key.
                if [[ "${cmd}" =~ (^|[^A-Za-z0-9_])(Error|FATAL|WARNING|Warning): ]]; then
                    fail "${where}: use ERROR: or WARN:, not ${BASH_REMATCH[2]}:"
                fi
                if [[ "${cmd}" =~ (^|[^A-Za-z0-9_])(ERROR|WARN): ]]; then
                    prefix=${BASH_REMATCH[2]}
                    message_re=${before_text}
                    if [[ "${command_word}" =~ printf[[:space:]]*$ ]]; then
                        message_re+=${printf_format}
                    fi
                    message_re+=${text_start}
                    if ! [[ "${arguments}" =~ ${message_re} ]]; then
                        fail "${where}: start the message text with ${prefix}:"
                    fi
                    if ! [[ "${skeleton}" =~ ${stderr_re} || "${group_to_stderr}" == true ]]; then
                        fail "${where}: ${prefix}: messages go to stderr (>&2)"
                    fi
                fi
                # 5. Exports: every NAME= assignment after an export takes
                # its value from %q, or from text with no expansion or
                # conversion in it.
                rest=${cmd}
                unsafe_export=false
                while [[ "${rest}" =~ export[[:space:]]+(.*) ]]; do
                    rest=${BASH_REMATCH[1]}
                    while [[ "${rest}" =~ ${assignment_re} ]]; do
                        value=${BASH_REMATCH[2]}
                        rest=${BASH_REMATCH[3]}
                        if [[ "${value}" != "%q" && ( "${value}" == *'$'* || "${value}" == *%* || "${value}" == *'`'* ) ]]; then
                            unsafe_export=true
                        fi
                    done
                done
                if [[ "${unsafe_export}" == true ]]; then
                    fail "${where}: write exports with printf 'export %s=%q\\n' NAME \"\$value\""
                fi
            fi
        done
    done < "${path}"
done

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} shell convention failure(s) in ${#scripts[@]} scripts."
    exit 1
fi
echo "All ${#scripts[@]} scripts follow the shell conventions."
