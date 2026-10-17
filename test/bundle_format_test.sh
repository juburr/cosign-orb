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
# subcommand is listed in COSIGN_FLAG_ON. Any other call is logged, prints
# COSIGN_VERIFY_STDERR and exits with COSIGN_VERIFY_EXIT.
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
printf '%s\n' "${COSIGN_VERIFY_STDERR-Error: no signatures found}" >&2
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
  expect "verify 2.6.3 legacy needs a second check" "0|--new-bundle-format=false|--new-bundle-format=true" 1 verify_format_flags 2 verify legacy 2.6.3
  expect "verify 2.6.5 legacy needs a second check" "0|--new-bundle-format=false|--new-bundle-format=true" 1 verify_format_flags 2 verify-attestation legacy 2.6.5
  expect "verify 2.6.2 legacy is enforced by Cosign" "0|--new-bundle-format=false|" 1 verify_format_flags 2 verify legacy 2.6.2
  expect "verify 2.6.0 legacy is enforced by Cosign" "0|--new-bundle-format=false|" 1 verify_format_flags 2 verify-attestation legacy 2.6.0
  expect "verify v3 legacy is enforced by Cosign" "0|--new-bundle-format=false|" 0 verify_format_flags 3 verify legacy
  expect "verify v3 bundle needs a second check" "0|--new-bundle-format=true|--new-bundle-format=false" 0 verify_format_flags 3 verify-attestation bundle

  # Cosign 2.5.x: attest, verify and verify-attestation take the flag, sign
  # does not, and verify ignores it for image signatures.
  export COSIGN_FLAG_ON="attest verify verify-attestation"
  expect "verify 2.5.x image signature bundle is refused" "1||" 0 verify_format_flags 2 verify bundle
  expect "verify 2.5.x image signature legacy" "0||" 0 verify_format_flags 2 verify legacy
  expect "verify 2.5.x attestation bundle" "0|--new-bundle-format=true|" 0 verify_format_flags 2 verify-attestation bundle
  expect "verify 2.5.x attestation legacy is enforced by Cosign" "0|--new-bundle-format=false|" 0 verify_format_flags 2 verify-attestation legacy 2.5.3
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

run_version_cases() {
  check_version() {
    local version="$1" minimum="$2" want="$3" got
    if bash -c 'eval "$(cat "$1")"; cosign_version_at_least "$2" "$3"' _ "$LIB" "$version" "$minimum"; then
      got=yes
    else
      got=no
    fi
    if [[ "$got" == "$want" ]]; then
      pass_case "version ${version} >= ${minimum}: ${want}"
    else
      fail_case "version ${version} >= ${minimum}: got ${got}, wanted ${want}"
    fi
  }
  check_version 2.6.3 2.6.3 yes
  check_version 2.6.10 2.6.3 yes
  check_version 2.6.2 2.6.3 no
  check_version 2.5.9 2.6.3 no
  check_version 3.0.1 2.6.3 yes
  check_version 1.13.6 2.6.3 no
  check_version 2.6.3-rc.1 2.6.3 yes
  check_version garbage 2.6.3 yes
  check_version "" 2.6.3 yes
}

# The second verification must only pass on Cosign's "nothing verified"
# errors. Anything else leaves the format unknown and must fail.
run_counter_error_cases() {
  classify() {
    local name="$1" stderr="$2" want="$3"
    set +e
    PATH="${TMP}/bin:${PATH}" COSIGN_VERIFY_EXIT=1 COSIGN_VERIFY_STDERR="$stderr" bash -c '
      eval "$(cat "$1")"
      verify_format_flags 3 verify bundle
      check_other_format_does_not_verify bundle cosign verify --key cosign.pub "registry.local:5000/app@sha256:abc"
    ' _ "$LIB" > /dev/null 2>&1
    local status=$?
    set -e
    if [[ "$want" == "pass" && "$status" -eq 0 ]] || [[ "$want" == "fail" && "$status" -ne 0 ]]; then
      pass_case "second verification: ${name}"
    else
      fail_case "second verification: ${name}: exit ${status}, wanted ${want}"
    fi
  }
  classify "no signatures found" "Error: no signatures found" pass
  classify "no matching signatures" "Error: no matching signatures: invalid signature when validating ASN.1 encoded signature" pass
  classify "no matching attestations" "Error: no matching attestations: " pass
  classify "no valid bundles" "Error: no valid bundles exist in registry" pass
  classify "only other predicate types" "Error: none of the attestations matched the predicate type: slsaprovenance, found: https://cosign.sigstore.dev/attestation/v1" pass
  classify "registry unreachable" 'Error: Get "https://registry.local:5000/v2/": dial tcp 10.0.0.1:5000: connect: connection refused' fail
  classify "authentication failure" "Error: GET https://registry.local:5000/v2/app/manifests/sha256-abc.sig: UNAUTHORIZED: authentication required" fail
  classify "trust material lookup" "Error: unable to fetch trusted root: tuf-repo-cdn.sigstore.dev: timeout" fail
  classify "no output" "" fail
}

# sign_image and attest create a temporary signing config. Their cleanup must
# never delete a SIGNING_CONFIG path inherited from the job environment.
run_signing_config_cleanup_cases() {
  local stub="${TMP}/cleanup-bin" user_config="${TMP}/user-signing-config.json" tmp_dir script keyless
  mkdir -p "$stub"
  cat > "${stub}/cosign" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
  printf '{"gitVersion":"v3.1.3"}\n'
  exit 0
fi
exit 1
EOF
  cat > "${stub}/circleci" << 'EOF'
#!/usr/bin/env bash
# The scripts pass values on stdin; as an argument, one starting with "-"
# would be parsed as a flag by the real CLI.
if [[ "${1:-}" == "env" && "${2:-}" == "subst" && $# -eq 2 ]]; then
  cat
  exit 0
fi
exit 1
EOF
  chmod +x "${stub}/cosign" "${stub}/circleci"

  for script in sign_image attest; do
    for keyless in 1 0; do
      printf '{"user":"config"}\n' > "$user_config"
      tmp_dir="$(mktemp -d "${TMP}/tmpdir.XXXXXX")"
      set +e
      # No crane or docker on PATH, so digest resolution fails and the
      # script exits through its cleanup trap.
      (
        cd "$TMP"
        PATH="${stub}:/usr/bin:/bin" TMPDIR="$tmp_dir" SIGNING_CONFIG="$user_config" \
          PARAM_IMAGE="registry.local:5000/app:1.0" PARAM_KEYLESS="$keyless" PARAM_BUNDLE_FORMAT=auto \
          PARAM_PREDICATE=predicate.json PARAM_PREDICATE_TYPE=slsaprovenance PARAM_ANNOTATIONS="" \
          PARAM_PRIVATE_KEY=TEST_KEY PARAM_PASSWORD=TEST_PASSWORD TEST_KEY=dGVzdA== TEST_PASSWORD=pw \
          SCRIPT_IMAGE_REF_LIB="$(cat "${ROOT}/src/scripts/lib/image_ref.sh")" \
          SCRIPT_BUNDLE_FORMAT_LIB="$(cat "$LIB")" \
          bash "${ROOT}/src/scripts/${script}.sh" > /dev/null 2>&1
      )
      set -e
      if [[ ! -f "$user_config" ]]; then
        fail_case "${script} keyless=${keyless}: deleted the inherited SIGNING_CONFIG file"
      elif [[ -n "$(ls -A "$tmp_dir")" ]]; then
        fail_case "${script} keyless=${keyless}: left temporary files: $(ls -A "$tmp_dir")"
      else
        pass_case "${script} keyless=${keyless}: keeps the inherited SIGNING_CONFIG and removes its own"
      fi
    done
  done
}

# A tag is pinned to one digest before the two verifications.
run_pin_cases() {
  local stub="${TMP}/pin-bin" hex
  hex="$(printf 'd%.0s' {1..64})"
  mkdir -p "$stub"
  cat > "${stub}/cosign" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "triangulate" ]]; then
  printf '%s\n' "$*" >> "$COSIGN_LOG"
  printf '%s\n' "${TRIANGULATE_OUT-}"
  exit "${TRIANGULATE_EXIT:-0}"
fi
exit 1
EOF
  chmod +x "${stub}/cosign"

  pin() {
    local name="$1" image="$2" out="$3" exit_code="$4" want="$5" got status
    : > "$COSIGN_LOG"
    set +e
    got="$(PATH="${stub}:${PATH}" TRIANGULATE_OUT="$out" TRIANGULATE_EXIT="$exit_code" bash -c 'eval "$(cat "$1")"; pin_image_to_digest "$2"' _ "$LIB" "$image" 2> /dev/null)"
    status=$?
    set -e
    if [[ "$want" == "fail" ]]; then
      if [[ "$status" -ne 0 && -z "$got" ]]; then pass_case "pin: ${name}"; else fail_case "pin: ${name}: got '${got}' (exit ${status}), wanted a failure"; fi
    elif [[ "$status" -eq 0 && "$got" == "$want" ]]; then
      pass_case "pin: ${name}"
    else
      fail_case "pin: ${name}: got '${got}' (exit ${status}), wanted '${want}'"
    fi
  }
  pin "tag with a registry port" "localhost:5000/ns/app:1.0" "localhost:5000/ns/app:sha256-${hex}.sig" 0 "localhost:5000/ns/app@sha256:${hex}"
  pin "no tag" "ghcr.io/org/app" "ghcr.io/org/app:sha256-${hex}.sig" 0 "ghcr.io/org/app@sha256:${hex}"
  pin "signatures in another repository" "ghcr.io/org/app:v1" "ghcr.io/org/signatures:sha256-${hex}.sig" 0 "ghcr.io/org/app@sha256:${hex}"
  pin "digest reference is kept" "ghcr.io/org/app@sha256:${hex}" "unused" 0 "ghcr.io/org/app@sha256:${hex}"
  if [[ -s "$COSIGN_LOG" ]]; then fail_case "pin: a digest reference was resolved again"; fi
  pin "triangulate fails" "ghcr.io/org/app:v1" "" 1 fail
  pin "unexpected triangulate output" "ghcr.io/org/app:v1" "ghcr.io/org/app:v1.sig" 0 fail
}

# verify_image and verify_attestation must run both verifications against the
# same pinned digest when a tag is given.
run_pinned_script_cases() {
  local stub="${TMP}/verify-bin" hex log="${TMP}/verify.log" script subcommand
  hex="$(printf 'e%.0s' {1..64})"
  mkdir -p "$stub"
  cat > "${stub}/cosign" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) printf '{"gitVersion":"v3.1.3"}\n'; exit 0 ;;
  triangulate) printf 'registry.local:5000/app:sha256-%s.sig\n' "$PIN_HEX"; exit 0 ;;
  verify | verify-attestation)
    printf '%s\n' "$*" >> "$VERIFY_LOG"
    for arg in "$@"; do
      if [[ "$arg" == "--new-bundle-format=false" ]]; then
        printf 'Error: no signatures found\n' >&2
        exit 10
      fi
    done
    printf '[{"critical":{"type":"https://sigstore.dev/cosign/sign/v1"}}]\n'
    exit 0
    ;;
esac
exit 1
EOF
  cat > "${stub}/circleci" << 'EOF'
#!/usr/bin/env bash
# The scripts pass values on stdin; as an argument, one starting with "-"
# would be parsed as a flag by the real CLI.
if [[ "${1:-}" == "env" && "${2:-}" == "subst" && $# -eq 2 ]]; then
  cat
  exit 0
fi
exit 1
EOF
  chmod +x "${stub}/cosign" "${stub}/circleci"

  for script in verify_image verify_attestation; do
    subcommand=verify
    [[ "$script" == "verify_attestation" ]] && subcommand=verify-attestation
    : > "$log"
    set +e
    (
      cd "$TMP"
      PATH="${stub}:/usr/bin:/bin" VERIFY_LOG="$log" PIN_HEX="$hex" \
        PARAM_IMAGE="registry.local:5000/app:1.0" PARAM_KEYLESS=0 PARAM_BUNDLE_FORMAT=bundle \
        PARAM_PREDICATE_TYPE=slsaprovenance PARAM_PUBLIC_KEY=TEST_PUBLIC_KEY TEST_PUBLIC_KEY=dGVzdA== \
        SCRIPT_BUNDLE_FORMAT_LIB="$(cat "$LIB")" \
        bash "${ROOT}/src/scripts/${script}.sh" > /dev/null 2>&1
    )
    local status=$?
    set -e
    local calls pinned
    calls="$(grep -c "^${subcommand} " "$log" || true)"
    pinned="$(grep -c "registry.local:5000/app@sha256:${hex}$" "$log" || true)"
    if [[ "$status" -eq 0 && "$calls" -eq 2 && "$pinned" -eq 2 ]]; then
      pass_case "${script}: both verifications use the pinned digest"
    else
      fail_case "${script}: exit ${status}, ${calls} verifications, ${pinned} on the pinned digest: $(tr '\n' '|' < "$log")"
    fi
  done
}

main() {
  run_pin_cases
  run_pinned_script_cases
  run_version_cases
  run_counter_error_cases
  run_signing_config_cleanup_cases
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
