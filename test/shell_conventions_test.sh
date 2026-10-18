#!/bin/bash
#
# Checks the shell conventions every juburr orb's src/scripts follow. The same
# file is in every orb; keep the copies identical.
#
#   1. The first line is #!/bin/bash.
#   2. The first command is `set -euo pipefail`, alone on its line or
#      followed by ; and more commands (set -euo pipefail; IFS=$'\n\t').
#      Libraries under lib/ are eval'ed by a script that already set it, so
#      they have no set line.
#      A script that must not stop on errors says why on a line
#      `# shell-conventions: no-errexit <reason>` and uses `set -uo pipefail`.
#   3. No `set +o history` (a no-op in a non-interactive shell), and no set
#      command that turns xtrace on (it would print secrets).
#   4. Messages start with ERROR: or WARN: and go to stderr: every echo or
#      printf command that prints one of them starts its first argument
#      (after redirections, echo's -n, -e and -E, printf's --, and a bare
#      '%s\n' format) with it and
#      has >&2 or 1>&2 (or is inside a { ...; } >&2 group that ends the
#      line). Output captured by $(...) and printf -v is not printed, and
#      heredoc bodies are data, so neither is checked for this.
#      Error:, FATAL:, WARNING: and Warning: are not used.
#   5. Exports written by echo or printf quote every value with printf %q,
#      so no value can end the quoting or run a command when later steps
#      source $BASH_ENV. Everything after export NAME= up to the end of
#      its shell word (a space outside quotes; adjacent quoted parts, as
#      in 'export A='"$v", are one word), or for printf up to a \n, must
#      be %q or plain text. For echo, % and \n are plain text. This
#      applies to every printed export, including one in
#      a substitution, not only to lines that name $BASH_ENV: exports also
#      reach it through groups, tee and helper files.
#   6. eval only runs code the orb itself includes: a variable whose name
#      ends in _LIB or _SCRIPT, and not a PARAM_ variable, which holds a
#      parameter's value (a parameter named script is PARAM_SCRIPT).
#
# Each line is split into its commands at ;, &, |, && and || outside quotes,
# and every command is checked on its own. Checks 3, 5 and 6 also split and
# check the commands inside each $(...), <(...), >(...) or backtick
# substitution, in double quotes or none (single quotes make it text). A
# command may follow keywords, a one-line function declaration, a case
# pattern, variable assignments (quoted values included), redirections, and
# command or builtin. A >&2 only counts outside quotes and comments. A
# heredoc that is never closed fails the check, since everything after it
# would be skipped as data. Commands that span lines, or a { ...; } >&2 group
# over several lines, are not followed: write one message command per line
# with its own >&2.
#
# This is a line check of the ordinary spellings, not a shell parser: it
# catches the usual ways of breaking these rules by mistake, not code written
# to get past it. Such code can still hide from it (a quoted command word
# such as 'eval', a command split over lines, an export assembled from
# several printf calls), so review still applies.
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
# ;, &, |, &&, || and |& outside single and double quotes and outside $(...),
# $((...)), <(...) and >(...) (the & in >&2 or &> is a redirection), and the
# skeletons array to the same commands with quoted text and a trailing #
# comment removed. A substitution's own commands are split when it is checked.
split_commands() {
    local line=$1 current="" skeleton="" quote="" char prev=" " depth=0 i
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
        elif [[ "${char}" == "(" && ( "${prev}" == [\$\<\>] || "${depth}" -gt 0 ) ]]; then
            depth=$((depth + 1))
            skeleton+=${char}
        elif [[ "${char}" == ")" && "${depth}" -gt 0 ]]; then
            depth=$((depth - 1))
            skeleton+=${char}
        elif [[ "${depth}" -gt 0 ]]; then
            skeleton+=${char}
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

# A variable assignment word; its value may hold quoted text, or a $(...)
# or $((...)) with spaces in it.
assignment="[A-Za-z_][A-Za-z0-9_]*\\+?=(\"[^\"]*\"|'[^']*'|\\\$\\(\\([^)]*\\)\\)|\\\$\\([^)]*\\)|[^[:space:]\"'();|&<>])*"
# Where a command word starts within one command: after keywords, !, {, (,
# a one-line function declaration (f() {, f() ( or function f {), a case
# pattern, variable assignments and redirections, behind the command or
# builtin wrappers (with command's -p or --), and after a backslash (\eval).
lead='^[[:space:]]*((if|then|do|else|elif|while|until|time|coproc|!|\{|\()[[:space:]]+|\(|(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)[[:space:]]*[{(][[:space:]]+|function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]+[{(][[:space:]]+|case[[:space:]].*[[:space:]]in[[:space:]]+|\(?[^[:space:]()]+\)[[:space:]]*)*(('"${assignment}"'|[0-9]*&?[<>]+&?[[:space:]]*[^[:space:]<>]+)[[:space:]]+)*((command|builtin)([[:space:]]+(-p|--))*[[:space:]]+)*\\?'
# An allowed eval may redirect its output (eval "${X_LIB}" 2>/dev/null or
# &>/dev/null).
allowed_eval='eval[[:space:]]+"\$\{[A-Z0-9_]+_(LIB|SCRIPT)\}"([[:space:]]+[0-9]*&?[<>]+&?[[:space:]]*[^[:space:]]+)*[[:space:]]*([)`].*)?$'
# A PARAM_ variable holds a parameter's value, even one named ..._SCRIPT.
param_eval='eval[[:space:]]+"\$\{PARAM_'
# What may come before an echo or printf's message text: redirections, the
# options echo takes (-n, -e and -E; echo prints any other, -- included) or
# printf's --, and for printf a bare '%s\n' format (with redirections after
# it too).
redirection='[0-9]*>&[0-9]+|[0-9]*>>?[[:space:]]*[^[:space:]]+'
echo_before_text='^([[:space:]]*(-[neE]+|'"${redirection}"')[[:space:]]+)*'
printf_before_text='^([[:space:]]*(--|'"${redirection}"')[[:space:]]+)*'
printf_format=$'(\\$?["\']%s(\\\\n)?["\'][[:space:]]+)?'
redirections='(('"${redirection}"')[[:space:]]+)*'
text_start=$'(\\$?["\'])?(ERROR|WARN):'
# A >&2 or 1>&2 (3>&2 and {fd}>&2 send another descriptor, not stdout).
stderr_re='(^|[^0-9}])1?>&2([^0-9]|$)'
# A heredoc's start: <<WORD, <<-WORD, <<'WORD' or <<"WORD", but not <<<.
heredoc_re="(^|[^<])<<(-?)[[:space:]]*('([^']*)'|\"([^\"]*)\"|([^[:space:];&|<>()'\"]+))"
# word_value TEXT QUOTE: sets value to TEXT up to the end of the shell word
# it starts in, inside QUOTE (', " or none), with the quote characters
# removed. Adjacent quoted parts belong to the same word ('a='"$b" is one),
# which ends at a space or a ;, &, |, <, >, ( or ) outside quotes.
word_end='^[[:space:];&|<>()]$'
word_value() {
    local text=$1 quote=$2 char j
    value=""
    for ((j = 0; j < ${#text}; j++)); do
        char=${text:j:1}
        if [[ -n "${quote}" && "${char}" == "${quote}" ]]; then
            quote=""
            continue
        elif [[ "${quote}" != "'" && "${char}" == "\\" ]]; then
            value+=${text:j:2}
            j=$((j + 1))
            continue
        elif [[ -z "${quote}" && ( "${char}" == "'" || "${char}" == '"' ) ]]; then
            quote=${char}
            continue
        elif [[ -z "${quote}" && "${char}" =~ ${word_end} ]]; then
            break
        fi
        value+=${char}
    done
}

# unsafe_export TEXT: succeeds if an export NAME= in the echo or printf
# command TEXT takes a value that is neither %q nor plain text. The value
# ends at the end of its shell word, or for printf at a \n.
unsafe_export() {
    local text=$1 quote="" char value i printing=printf
    if [[ "${text}" =~ ${lead}echo([[:space:]]|$) ]]; then
        printing="echo"
    fi
    for ((i = 0; i < ${#text}; i++)); do
        char=${text:i:1}
        if [[ -n "${quote}" && "${char}" == "${quote}" ]]; then
            quote=""
            continue
        elif [[ "${quote}" != "'" && "${char}" == "\\" ]]; then
            i=$((i + 1))
            continue
        elif [[ -z "${quote}" && ( "${char}" == "'" || "${char}" == '"' ) ]]; then
            quote=${char}
            continue
        fi
        [[ "${text:i}" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*|%[a-z])=(.*) ]] || continue
        word_value "${BASH_REMATCH[2]}" "${quote}"
        if [[ "${printing}" == echo ]]; then
            # echo prints % and \n as they are.
            value=${value//%/}
        else
            value=${value%%\\n*}
            # %% prints a literal %, %q quotes the value, and a later
            # " %s=" is the next assignment's name (export %s=%q %s=%q).
            value=${value//%%/}
            value=${value// %s=/ }
            value=${value//%q/}
        fi
        if [[ "${value}" == *[\$%\`]* ]]; then
            return 0
        fi
    done
    return 1
}

# find_substitutions TEXT: sets positions to TEXT and to the text after each
# $( (not $((, which is arithmetic) or backtick in it that is not inside
# single quotes, and after each <( or >( outside quotes.
find_substitutions() {
    local text=$1 quote="" char i
    positions=("${text}")
    for ((i = 0; i < ${#text}; i++)); do
        char=${text:i:1}
        if [[ "${quote}" == "'" ]]; then
            [[ "${char}" != "'" ]] || quote=""
        elif [[ "${char}" == "\\" ]]; then
            i=$((i + 1))
        elif [[ "${char}" == '"' ]]; then
            if [[ -z "${quote}" ]]; then quote='"'; else quote=""; fi
        elif [[ "${char}" == "'" && -z "${quote}" ]]; then
            quote="'"
        elif [[ "${char}" == '`' ]]; then
            positions+=("${text:i+1}")
        elif [[ "${char}" == '$' && "${text:i+1:2}" == "((" ]]; then
            # $((...)) is arithmetic, not commands.
            i=$((i + 2))
        elif [[ "${char}" == '$' && "${text:i+1:1}" == "(" ]]; then
            positions+=("${text:i+2}")
        elif [[ -z "${quote}" && ( "${char}" == "<" || "${char}" == ">" ) && "${text:i+1:1}" == "(" ]]; then
            positions+=("${text:i+2}")
        fi
    done
}

# fail_line MESSAGE: reports MESSAGE for the current line, once.
declare -A reported=()
fail_line() {
    if [[ -z "${reported[$1]:-}" ]]; then
        reported[$1]=1
        fail "${where}: $1"
    fi
}

for script in "${scripts[@]}"; do
    path="${root}/${script}"

    # 1. Shebang.
    if [[ "$(head -n 1 "${path}")" != "#!/bin/bash" ]]; then
        fail "${script}: the first line must be #!/bin/bash"
    fi

    # 2. The first command, skipping comments, blank lines, and the bash
    # version guard install.sh runs before it (but not an else or elif in
    # that guard, which would run before the set command).
    if [[ "${script}" != */lib/* ]]; then
        want="set -euo pipefail"
        if grep -qE '^# shell-conventions: no-errexit [^ ]' "${path}"; then
            want="set -uo pipefail"
        fi
        first=$(awk '
            /^[[:space:]]*(#|$)/ { next }
            /^if \[ -z "\$\{BASH_VERSION:-\}" \]/ { guard = 1 }
            guard && /^[[:space:]]*(else|elif)([[:space:];]|$)/ { print; exit }
            guard { if ($0 ~ /^fi$/) guard = 0; next }
            { sub(/[[:space:]]+#.*$/, ""); print; exit }
        ' "${path}")
        # The set command may be followed by ; and more commands.
        first_command=${first%%;*}
        first_command=${first_command%"${first_command##*[![:space:]]}"}
        if [[ "${first_command}" != "${want}" ]]; then
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
                    heredoc="${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]//\\/}"
                    heredoc_line=${lineno}
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
        reported=()
        split_commands "${line}"
        line_commands=("${commands[@]}")
        line_skeletons=("${skeletons[@]}")

        # A { ...; } >&2 or ( ...; ) >&2 group that ends this line sends the
        # commands in it, from its opening { or ( on, to stderr.
        group_start=${#line_commands[@]}
        last=$((${#line_commands[@]} - 1))
        if [[ "${line_skeletons[last]}" =~ ^[[:space:]]*[\}\)][[:space:]]*(1?>&2)([[:space:]]|$) ]]; then
            depth=0
            for ((c = last; c >= 0; c--)); do
                if [[ "${line_skeletons[c]}" =~ ^[[:space:]]*[\}\)] ]]; then
                    depth=$((depth + 1))
                fi
                if [[ "${line_skeletons[c]}" =~ ^[[:space:]]*(\{[[:space:]]|\() ]]; then
                    depth=$((depth - 1))
                    if [[ "${depth}" -eq 0 ]]; then
                        group_start=${c}
                        break
                    fi
                fi
            done
        fi

        for ((c = 0; c < ${#line_commands[@]}; c++)); do
            cmd=${line_commands[c]}
            skeleton=${line_skeletons[c]}
            # Checks 3, 5 and 6 read the command and the commands in each
            # substitution in it.
            find_substitutions "${cmd}"
            for text in "${positions[@]}"; do
                split_commands "${text}"
                for piece in "${commands[@]}"; do
                    # 3. History and xtrace: any -...x... option or -o xtrace
                    # before the -- that ends set's options.
                    if [[ "${piece}" =~ ${lead}set([[:space:]]|[\<\>]|$) ]]; then
                        options=${piece%%[[:space:]]--[[:space:]]*}
                        options=${options%[[:space:]]--}
                        if [[ "${options}" =~ [[:space:]]\+o[[:space:]]+history ]]; then
                            fail_line "remove 'set +o history'; it does nothing in a non-interactive shell"
                        fi
                        if [[ "${options}" =~ [[:space:]]-[A-Za-z]*x[A-Za-z]*([[:space:]]|[\)\}&|\`\<\>]|$) ||
                            "${options}" =~ -o[[:space:]]+xtrace([[:space:]]|[\)\}&|\`\<\>]|$) ]]; then
                            fail_line "do not enable xtrace; it prints secrets"
                        fi
                    fi
                    # 5. Exports: every value printed after export NAME= is
                    # %q, or text with no expansion or conversion in it.
                    if [[ "${in_heredoc}" == false && "${piece}" == *export* && "${piece}" =~ ${lead}(echo|printf)([[:space:]]|$) ]] &&
                        unsafe_export "${piece}"; then
                        fail_line "write exports with printf 'export %s=%q\\n' NAME \"\$value\""
                    fi
                    # 6. eval.
                    if [[ "${piece}" =~ ${lead}eval([[:space:]]|[\<\>]|$) ]] &&
                        { ! [[ "${piece}" =~ ${lead}${allowed_eval} ]] || [[ "${piece}" =~ ${lead}${param_eval} ]]; }; then
                        fail_line "eval may only run orb code (\"\${NAME_LIB}\" or \"\${NAME_SCRIPT}\", not a PARAM_ variable)"
                    fi
                done
            done

            # 4. Messages, for a command that prints (not one inside a
            # substitution, whose output is captured, and not printf -v,
            # which assigns a variable).
            if [[ "${in_heredoc}" == false && "${cmd}" =~ ${lead}(echo|printf)([[:space:]]|$) ]]; then
                command_word=${BASH_REMATCH[0]}
                arguments=${cmd:${#command_word}}
                if [[ "${command_word}" =~ printf[[:space:]]*$ && "${arguments}" =~ ^[[:space:]]*-v[[:space:]] ]]; then
                    continue
                fi
                # A prefix is a whole word: failOnError: is a YAML key, and
                # ${ERROR:-none} expands a variable.
                if [[ "${cmd}" =~ (^|[^A-Za-z0-9_{$])(Error|FATAL|WARNING|Warning): ]]; then
                    fail_line "use ERROR: or WARN:, not ${BASH_REMATCH[2]}:"
                fi
                if [[ "${cmd}" =~ (^|[^A-Za-z0-9_{$])(ERROR|WARN): ]]; then
                    prefix=${BASH_REMATCH[2]}
                    if [[ "${command_word}" =~ printf[[:space:]]*$ ]]; then
                        message_re=${printf_before_text}${printf_format}${redirections}
                    else
                        message_re=${echo_before_text}
                    fi
                    message_re+=${text_start}
                    if ! [[ "${arguments}" =~ ${message_re} ]]; then
                        fail_line "start the message text with ${prefix}:"
                    fi
                    if ! [[ "${skeleton}" =~ ${stderr_re} || ${c} -ge ${group_start} ]]; then
                        fail_line "${prefix}: messages go to stderr (>&2)"
                    fi
                fi
            fi
        done
    done < "${path}"
    if [[ -n "${heredoc}" ]]; then
        fail "${script}:${heredoc_line}: the heredoc <<${heredoc} is never closed, so checks 4 and 5 skipped the rest of the file"
    fi
done

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} shell convention failure(s) in ${#scripts[@]} scripts."
    exit 1
fi
echo "All ${#scripts[@]} scripts follow the shell conventions."
