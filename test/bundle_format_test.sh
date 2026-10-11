#!/usr/bin/env bash
# Tests for src/scripts/lib/bundle_format.sh.
#
# Locks the flags each Cosign major gets for bundle_format auto, bundle and
# legacy, the errors for combinations Cosign cannot honor, and the second
# verification that guards the cases Cosign cannot limit to one format.
#
# Run from a checkout:
#   bash test/bundle_format_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${BUNDLE_FORMAT_LIB:-${ROOT}/src/scripts/lib/bundle_format.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A cosign stub. --help prints the flag when COSIGN_HAS_FLAG=1, or when the
# subcommand is listed in COSIGN_FLAG_ON. Any other call is logged and exits
# with COSIGN_VERIFY_EXIT.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/cosign" << 'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == "--help" ]]; then
  printf 'Usage: cosign %s [flags]\n' "$1"
  if [[ "${COSIGN_HAS_FLAG:-0}" == "1" || " ${COSIGN_FLAG_ON:-} " == *" $1 "* ]]; then
    printf '      --new-bundle-format   expect the signature/attestation to be packaged in a Sigstore bundle\n'
  fi
  exit 0
fi
printf '%s\n' "$*" >> "$COSIGN_LOG"
exit "${COSIGN_VERIFY_EXIT:-1}"
EOF
chmod +x "${TMP}/bin/cosign"
export COSIGN_LOG="${TMP}/cosign.log"

FAILURES=0

fail_case() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

pass_case() {
  printf 'ok: %s\n' "$1"
}

# run_fn HAS_FLAG FUNCTION ARGS...: runs a library function in a clean shell
# and prints "status|BUNDLE_FORMAT_FLAGS|BUNDLE_FORMAT_COUNTER_FLAGS".
run_fn() {
  local has_flag="$1"
  shift
  : > "$COSIGN_LOG"
  set +e
  PATH="${TMP}/bin:${PATH}" COSIGN_HAS_FLAG="$has_flag" bash -c '
    set -eo pipefail
    eval "$(cat "$1")"
    shift
    status=0
    "$@" 2> /dev/null || status=$?
    printf "%s|%s|%s\n" "$status" "${BUNDLE_FORMAT_FLAGS[*]:-}" "${BUNDLE_FORMAT_COUNTER_FLAGS[*]:-}"
  ' _ "$LIB" "$@"
  set -e
}

expect() {
  local name="$1" want="$2"
  shift 2
  local got
  got="$(run_fn "$@")"
  if [[ "$got" == "$want" ]]; then
    pass_case "$name"
  else
    fail_case "${name}: got '${got}', wanted '${want}'"
  fi
}

SC="/tmp/signing-config.json"
V3_LEGACY="--new-bundle-format=false --use-signing-config=false --tlog-upload=false"

run_private_key_cases() {
  # Cosign 1
  expect "private key v1 auto" "0|--no-tlog-upload|" 0 private_key_sign_flags 1 sign auto "$SC"
  expect "private key v1 legacy" "0|--no-tlog-upload|" 0 private_key_sign_flags 1 sign legacy "$SC"
  expect "private key v1 bundle is refused" "1||" 0 private_key_sign_flags 1 sign bundle "$SC"

  # Cosign 2, with and without --new-bundle-format
  expect "private key v2 auto" "0|--tlog-upload=false|" 1 private_key_sign_flags 2 sign auto "$SC"
  expect "private key v2 bundle" "0|--tlog-upload=false --new-bundle-format=true|" 1 private_key_sign_flags 2 sign bundle "$SC"
  expect "private key v2 legacy" "0|--tlog-upload=false --new-bundle-format=false|" 1 private_key_sign_flags 2 attest legacy "$SC"
  expect "private key old v2 bundle is refused" "1|--tlog-upload=false|" 0 private_key_sign_flags 2 sign bundle "$SC"
  expect "private key old v2 legacy" "0|--tlog-upload=false|" 0 private_key_sign_flags 2 sign legacy "$SC"

  # Cosign 3
  expect "private key v3 auto" "0|--signing-config=${SC}|" 0 private_key_sign_flags 3 sign auto "$SC"
  expect "private key v3 bundle" "0|--new-bundle-format=true --signing-config=${SC}|" 0 private_key_sign_flags 3 attest bundle "$SC"
  expect "private key v3 legacy" "0|${V3_LEGACY}|" 0 private_key_sign_flags 3 sign legacy "$SC"

  expect "private key unknown format is refused" "1||" 0 private_key_sign_flags 3 sign referrers "$SC"
  expect "private key unknown major is refused" "1||" 0 private_key_sign_flags 4 sign auto "$SC"
}

run_keyless_cases() {
  expect "keyless v1 auto" "0||" 0 keyless_sign_flags 1 sign auto
  expect "keyless v1 legacy" "0||" 0 keyless_sign_flags 1 sign legacy
  expect "keyless v1 bundle is refused" "1||" 0 keyless_sign_flags 1 sign bundle
  expect "keyless v2 legacy" "0|--new-bundle-format=false|" 1 keyless_sign_flags 2 attest legacy
  expect "keyless old v2 legacy" "0||" 0 keyless_sign_flags 2 sign legacy
  expect "keyless v2 bundle is refused" "1||" 1 keyless_sign_flags 2 sign bundle
  expect "keyless v3 auto" "0||" 0 keyless_sign_flags 3 sign auto
  expect "keyless v3 bundle" "0|--new-bundle-format=true|" 0 keyless_sign_flags 3 sign bundle
  expect "keyless v3 legacy is refused" "1||" 0 keyless_sign_flags 3 attest legacy
}

run_verify_flag_cases() {
  expect "verify auto passes no flags" "0||" 1 verify_format_flags 3 verify auto
  expect "verify v1 legacy" "0||" 0 verify_format_flags 1 verify legacy
  expect "verify v1 bundle is refused" "1||" 0 verify_format_flags 1 verify bundle
  expect "verify old v2 legacy" "0||" 0 verify_format_flags 2 verify legacy
  expect "verify old v2 bundle is refused" "1||" 0 verify_format_flags 2 verify bundle
  expect "verify v2 bundle is enforced by Cosign" "0|--new-bundle-format=true|" 1 verify_format_flags 2 verify bundle
  expect "verify v2 legacy needs a second check" "0|--new-bundle-format=false|--new-bundle-format=true" 1 verify_format_flags 2 verify-attestation legacy
  expect "verify v3 legacy is enforced by Cosign" "0|--new-bundle-format=false|" 0 verify_format_flags 3 verify legacy
  expect "verify v3 bundle needs a second check" "0|--new-bundle-format=true|--new-bundle-format=false" 0 verify_format_flags 3 verify-attestation bundle

  # Cosign 2.5.x: attest, verify and verify-attestation take the flag, sign
  # does not, and verify ignores it for image signatures.
  export COSIGN_FLAG_ON="attest verify verify-attestation"
  expect "verify 2.5.x image signature bundle is refused" "1||" 0 verify_format_flags 2 verify bundle
  expect "verify 2.5.x image signature legacy" "0||" 0 verify_format_flags 2 verify legacy
  expect "verify 2.5.x attestation bundle" "0|--new-bundle-format=true|" 0 verify_format_flags 2 verify-attestation bundle
  expect "sign 2.5.x bundle is refused" "1|--tlog-upload=false|" 0 private_key_sign_flags 2 sign bundle "$SC"
  expect "attest 2.5.x bundle" "0|--tlog-upload=false --new-bundle-format=true|" 0 private_key_sign_flags 2 attest bundle "$SC"
  unset COSIGN_FLAG_ON
}

# check HAS_FLAG VERIFY_EXIT MAJOR FORMAT: runs verify_format_flags and then
# check_other_format_does_not_verify with a stub verification.
run_check() {
  local verify_exit="$1" major="$2" format="$3"
  : > "$COSIGN_LOG"
  set +e
  PATH="${TMP}/bin:${PATH}" COSIGN_HAS_FLAG=1 COSIGN_VERIFY_EXIT="$verify_exit" bash -c '
    set -eo pipefail
    eval "$(cat "$1")"
    verify_format_flags "$2" verify "$3"
    check_other_format_does_not_verify "$3" cosign verify --key cosign.pub "registry.local:5000/app@sha256:abc"
  ' _ "$LIB" "$major" "$format" 2> /dev/null
  CHECK_STATUS=$?
  set -e
}

run_counter_check_cases() {
  run_check 1 3 bundle
  if [[ "$CHECK_STATUS" -eq 0 ]] && grep -qxF "verify --key cosign.pub --new-bundle-format=false registry.local:5000/app@sha256:abc" "$COSIGN_LOG"; then
    pass_case "v3 bundle: passes when legacy objects do not verify"
  else
    fail_case "v3 bundle: status ${CHECK_STATUS}, log '$(cat "$COSIGN_LOG")'"
  fi

  run_check 0 3 bundle
  if [[ "$CHECK_STATUS" -ne 0 ]]; then
    pass_case "v3 bundle: fails when legacy objects also verify"
  else
    fail_case "v3 bundle: passed although legacy objects verify"
  fi

  run_check 0 2 legacy
  if [[ "$CHECK_STATUS" -ne 0 ]] && grep -qxF "verify --key cosign.pub --new-bundle-format=true registry.local:5000/app@sha256:abc" "$COSIGN_LOG"; then
    pass_case "v2 legacy: fails when Sigstore bundles also verify"
  else
    fail_case "v2 legacy: status ${CHECK_STATUS}, log '$(cat "$COSIGN_LOG")'"
  fi

  run_check 0 3 legacy
  if [[ "$CHECK_STATUS" -eq 0 && ! -s "$COSIGN_LOG" ]]; then
    pass_case "v3 legacy: no second verification, Cosign enforces it"
  else
    fail_case "v3 legacy: status ${CHECK_STATUS}, log '$(cat "$COSIGN_LOG")'"
  fi
}

main() {
  run_private_key_cases
  run_keyless_cases
  run_verify_flag_cases
  run_counter_check_cases
  if [[ "$FAILURES" -ne 0 ]]; then
    printf '\n%d failure(s)\n' "$FAILURES"
    exit 1
  fi
  printf '\nAll bundle format tests passed.\n'
}

main "$@"
