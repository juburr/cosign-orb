#!/usr/bin/env bash
# Tests sign, attest, verify and verify_attestation on the paths where their
# flag arrays are empty: bundle_format auto and no annotations, with a key and
# keyless, on Cosign 1, 2 and 3.
#
# This matters on bash older than 4.4. Under set -u, those versions treat an
# empty array as unset, so "${FLAGS[@]}" aborts the step with "unbound
# variable" before Cosign runs. The scripts expand such arrays as
# ${FLAGS[@]+"${FLAGS[@]}"}. On any bash, this test also checks that an empty
# array adds no argument at all, not an empty one.
#
# The scripts are run with the bash first on PATH, so this checks an older
# bash when one is put there.
#
# Run from a checkout:
#   bash test/empty_arrays_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/src/scripts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/work"

# env subst echoes stdin; "run oidc get" prints a token for keyless signing.
cat > "${TMP}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" && $# -eq 2 ]]; then
  cat
  exit 0
fi
if [[ "${1:-}" == "run" && "${2:-}" == "oidc" && "${3:-}" == "get" ]]; then
  printf 'test-oidc-token\n'
  exit 0
fi
exit 1
EOF

# sign and attest resolve the image digest with crane when it is on PATH.
cat > "${TMP}/bin/crane" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "digest" ]]; then
  printf 'sha256:%s\n' "$(printf 'a%.0s' {1..64})"
  exit 0
fi
exit 1
EOF

# Prints COSIGN_GIT_VERSION for "cosign version". Any other call is logged to
# COSIGN_LOG as a "call" line followed by one "arg:" line per argument, and
# "cosign verify" prints an image signature payload.
cat > "${TMP}/bin/cosign" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
  printf '{"gitVersion":"%s"}\n' "${COSIGN_GIT_VERSION}"
  exit 0
fi
printf 'call\n' >> "$COSIGN_LOG"
for arg in "$@"; do
  printf 'arg:%s\n' "$arg" >> "$COSIGN_LOG"
done
if [[ "${1:-}" == "verify" ]]; then
  printf '[{"critical":{"type":"cosign container image signature"}}]\n'
fi
exit 0
EOF
chmod +x "${TMP}/bin/circleci" "${TMP}/bin/crane" "${TMP}/bin/cosign"

printf '{}\n' > "${TMP}/work/predicate.json"
KEY_B64="$(printf 'not a real key\n' | base64 -w0)"
DIGEST="sha256:$(printf 'a%.0s' {1..64})"

FAILURES=0

# run_case SCRIPT VERSION MODE: runs SCRIPT with bundle_format auto and no
# annotations, with a key (MODE key) or keyless (MODE keyless).
run_case() {
  local script="$1" version="$2" mode="$3"
  local name="${script} ${version} ${mode}" status keyless=0 subcommand
  local out="${TMP}/out" log="${TMP}/cosign.log"
  : > "$log"
  if [[ "$mode" == "keyless" ]]; then
    keyless=1
  fi
  case "$script" in
    sign) subcommand=sign ;;
    attest) subcommand=attest ;;
    verify) subcommand=verify ;;
    verify_attestation) subcommand=verify-attestation ;;
  esac

  set +e
  (
    cd "${TMP}/work"
    # The keyless cases get their token from the CircleCI stand-in, so a
    # GitHub Actions runner's GITHUB_ACTIONS must not reach the script.
    env -u GITHUB_ACTIONS PATH="${TMP}/bin:${PATH}" COSIGN_GIT_VERSION="$version" COSIGN_LOG="$log" \
      PARAM_IMAGE="registry.local:5000/app@${DIGEST}" PARAM_KEYLESS="$keyless" PARAM_BUNDLE_FORMAT=auto \
      PARAM_ANNOTATIONS="" PARAM_PREDICATE=predicate.json PARAM_PREDICATE_TYPE=slsaprovenance \
      PARAM_PRIVATE_KEY=TEST_PRIVATE_KEY PARAM_PASSWORD=TEST_PASSWORD PARAM_PUBLIC_KEY=TEST_PUBLIC_KEY \
      TEST_PRIVATE_KEY="$KEY_B64" TEST_PASSWORD=pw TEST_PUBLIC_KEY="$KEY_B64" \
      PARAM_CERTIFICATE_IDENTITY="https://circleci.com/api/v2/projects/p/pipeline-definitions/d" \
      PARAM_CERTIFICATE_OIDC_ISSUER="https://oidc.circleci.com/org/o" \
      SCRIPT_IMAGE_REF_LIB="$(cat "${SCRIPTS}/lib/image_ref.sh")" \
      SCRIPT_BUNDLE_FORMAT_LIB="$(cat "${SCRIPTS}/lib/bundle_format.sh")" \
      SCRIPT_CI_LIB="$(cat "${SCRIPTS}/lib/ci.sh")" \
      bash "${SCRIPTS}/${script}.sh" > "$out" 2>&1
  )
  status=$?
  set -e

  local problem=""
  if [[ "$status" -ne 0 ]]; then
    problem="exit ${status}"
  elif grep -q 'unbound variable' "$out"; then
    problem="the output mentions an unbound variable"
  elif ! grep -qxF -- "arg:${subcommand}" "$log"; then
    problem="cosign ${subcommand} did not run"
  elif grep -qx 'arg:' "$log"; then
    problem="cosign was given an empty argument"
  elif [[ "$(tail -n 1 "$log")" != "arg:registry.local:5000/app@${DIGEST}" ]]; then
    problem="the image was not cosign's last argument"
  fi
  if [[ -n "$problem" ]]; then
    printf 'FAIL: %s: %s\n' "$name" "$problem"
    sed 's/^/    /' "$out" "$log"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok: %s\n' "$name"
  fi
}

for script in sign attest verify verify_attestation; do
  for version in v3.1.3 v2.6.5 v1.13.6; do
    run_case "$script" "$version" key
    run_case "$script" "$version" keyless
  done
done

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll empty array tests passed.\n'
