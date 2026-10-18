#!/usr/bin/env bash
# Tests for src/scripts/generate_key_pair.sh.
#
# Locks the password choice (the value of the variable named by
# password_env_var, or a random one when that is empty) and the BASH_ENV
# exports, which must give later steps the exact values even when the
# password contains quotes or shell syntax.
#
# Run from a checkout:
#   bash test/generate_key_pair_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${GENERATE_KEY_PAIR_SCRIPT:-${ROOT}/src/scripts/generate_key_pair.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin"

# "cosign generate-key-pair" writes key files that record the password it
# was given, so a test can check which password encrypted the key.
cat > "${TMP}/bin/cosign" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "generate-key-pair" ]]; then
  printf 'PRIVATE KEY encrypted with: %s' "${COSIGN_PASSWORD}" > cosign.key
  printf 'PUBLIC KEY\n' > cosign.pub
  exit 0
fi
exit 1
EOF
chmod +x "${TMP}/bin/cosign"

FAILURES=0

fail_case() {
  printf 'FAIL: %s\n' "$1"
  sed 's/^/    /' "${TMP}/out"
  FAILURES=$((FAILURES + 1))
}

# run NAME [VAR=VALUE...]: runs the script in a fresh work directory with the
# default parameters, overridden by any VAR=VALUE given, and sets STATUS.
run() {
  local name="$1"
  shift
  WORK="${TMP}/${name}"
  mkdir -p "${WORK}"
  : > "${WORK}/bash_env"
  set +e
  (
    cd "${WORK}"
    env -u COSIGN_PASSWORD -u COSIGN_PRIVATE_KEY -u COSIGN_PUBLIC_KEY \
      PATH="${TMP}/bin:${PATH}" BASH_ENV="${WORK}/bash_env" \
      PARAM_PRIVATE_KEY_ENV_VAR=COSIGN_PRIVATE_KEY PARAM_PUBLIC_KEY_ENV_VAR=COSIGN_PUBLIC_KEY \
      PARAM_PASSWORD_ENV_VAR=COSIGN_PASSWORD "$@" \
      bash "${SCRIPT}" > "${TMP}/out" 2>&1
  )
  STATUS=$?
  set -e
}

# exported NAME: prints the value a later step sees for NAME after sourcing
# BASH_ENV in an otherwise empty environment. It runs in the work directory,
# so any command a bad export runs leaves its files there.
exported() {
  # shellcheck disable=SC2016 # expanded by the child shell, not here
  (cd "${WORK}" && env -i PATH="${PATH}" bash -c 'set -e; source "$1"; printf "%s" "${!2}"' _ "${WORK}/bash_env" "$1")
}

# A password with quotes, command substitutions, globs, whitespace and a
# newline. Sourcing a naively quoted export of it would run the commands.
TRICKY_PASSWORD=$'it\'s "quoted" $(touch pwned-dollar) `touch pwned-backtick` ; touch pwned-semicolon *\n\tsecond line'

run "random password"
password="$(exported COSIGN_PASSWORD)"
if [[ "$STATUS" -ne 0 ]]; then
  fail_case "random password: exit ${STATUS}"
elif [[ ${#password} -lt 32 ]]; then
  fail_case "random password: exported password '${password}' is too short"
elif [[ "$(exported COSIGN_PRIVATE_KEY | base64 --decode)" != "PRIVATE KEY encrypted with: ${password}" ]]; then
  fail_case "random password: the private key was not encrypted with the exported password"
elif [[ "$(exported COSIGN_PUBLIC_KEY | base64 --decode)" != "PUBLIC KEY" ]]; then
  fail_case "random password: COSIGN_PUBLIC_KEY is wrong"
elif [[ -e "${WORK}/cosign.key" || -e "${WORK}/cosign.pub" ]]; then
  fail_case "random password: key files were left behind"
else
  printf 'ok: random password when COSIGN_PASSWORD is not set\n'
fi

run "empty password" COSIGN_PASSWORD=""
password="$(exported COSIGN_PASSWORD)"
if [[ "$STATUS" -eq 0 && ${#password} -ge 32 ]] && grep -qF "generating a random password" "${TMP}/out"; then
  printf 'ok: random password when COSIGN_PASSWORD is empty\n'
else
  fail_case "empty password: exit ${STATUS}, exported password '${password}'"
fi

run "known password" PARAM_PASSWORD_ENV_VAR=MY_PASSWORD MY_PASSWORD="${TRICKY_PASSWORD}"
password="$(exported MY_PASSWORD 2> /dev/null || true)"
if [[ "$STATUS" -ne 0 ]]; then
  fail_case "known password: exit ${STATUS}"
elif compgen -G "${WORK}/pwned-*" > /dev/null; then
  fail_case "known password: sourcing BASH_ENV ran commands from the password"
elif [[ "${password}" != "${TRICKY_PASSWORD}" ]]; then
  fail_case "known password: exported MY_PASSWORD is '${password}'"
elif [[ "$(exported COSIGN_PRIVATE_KEY | base64 --decode)" != "PRIVATE KEY encrypted with: ${TRICKY_PASSWORD}" ]]; then
  fail_case "known password: the private key was not encrypted with MY_PASSWORD"
else
  printf 'ok: the password in password_env_var is used and exported intact\n'
fi

run "custom names" PARAM_PRIVATE_KEY_ENV_VAR=MY_KEY PARAM_PUBLIC_KEY_ENV_VAR=MY_PUB PARAM_PASSWORD_ENV_VAR=MY_PW
if [[ "$STATUS" -eq 0 && "$(exported MY_PUB | base64 --decode)" == "PUBLIC KEY" && -n "$(exported MY_KEY)" && -n "$(exported MY_PW)" ]] \
  && ! grep -q "COSIGN_PRIVATE_KEY\|COSIGN_PUBLIC_KEY" "${WORK}/bash_env"; then
  printf 'ok: keys and password are written to the named variables\n'
else
  fail_case "custom names: exit ${STATUS}, BASH_ENV: $(cat "${WORK}/bash_env")"
fi

run "invalid name" 'PARAM_PASSWORD_ENV_VAR=X;touch pwned'
if [[ "$STATUS" -ne 0 && ! -s "${WORK}/bash_env" ]] && ! compgen -G "${WORK}/pwned*" > /dev/null; then
  printf 'ok: an invalid variable name is refused before anything is exported\n'
else
  fail_case "invalid name: exit ${STATUS}, BASH_ENV: $(cat "${WORK}/bash_env")"
fi

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll generate_key_pair tests passed.\n'
