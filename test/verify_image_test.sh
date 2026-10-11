#!/usr/bin/env bash
# Tests for the image signature check in src/scripts/verify_image.sh.
#
# Cosign 2.6+ and 3 accept any Sigstore bundle signed by the key as an image
# signature, including an attestation. verify_image must fail unless one of
# the payloads Cosign verified is an image signature.
#
# Run from a checkout:
#   bash test/verify_image_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${VERIFY_IMAGE_SCRIPT:-${ROOT}/src/scripts/verify_image.sh}"
LIB="${ROOT}/src/scripts/lib/bundle_format.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/work"

cat > "${TMP}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" ]]; then
  printf '%s\n' "${3-}"
  exit 0
fi
exit 1
EOF

# Prints COSIGN_GIT_VERSION for "cosign version" and COSIGN_VERIFY_STDOUT for
# "cosign verify". A verification carrying COSIGN_FAIL_FLAG fails with Cosign's
# "no signatures found" error, which is how the counter-check behaves when the
# subject has only one format.
cat > "${TMP}/bin/cosign" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
  printf '{"gitVersion":"%s"}\n' "${COSIGN_GIT_VERSION}"
  exit 0
fi
if [[ "${1:-}" == "verify" ]]; then
  for arg in "$@"; do
    if [[ -n "${COSIGN_FAIL_FLAG:-}" && "$arg" == "${COSIGN_FAIL_FLAG}" ]]; then
      printf 'Error: no signatures found\n' >&2
      exit 10
    fi
  done
  printf '%s' "${COSIGN_VERIFY_STDOUT}"
  exit 0
fi
exit 1
EOF
chmod +x "${TMP}/bin/circleci" "${TMP}/bin/cosign"

FAILURES=0

SIGNATURE_BUNDLE='[{"critical":{"identity":{"docker-reference":"r/app"},"image":{"docker-manifest-digest":"sha256:aa"},"type":"https://sigstore.dev/cosign/sign/v1"},"optional":{}}]'
ATTESTATION_BUNDLE='[{"critical":{"identity":{"docker-reference":"r/app"},"image":{"docker-manifest-digest":"sha256:aa"},"type":"https://slsa.dev/provenance/v0.2"},"optional":{}}]'
LEGACY='[{"critical":{"identity":{"docker-reference":"r/app"},"image":{"docker-manifest-digest":"sha256:aa"},"type":"cosign container image signature"},"optional":null}]'
MIXED='[{"critical":{"type":"https://slsa.dev/provenance/v0.2"}},{"critical":{"type":"https://sigstore.dev/cosign/sign/v1"}}]'

# run_case NAME WANT(pass|fail) GIT_VERSION BUNDLE_FORMAT STDOUT
run_case() {
  local name="$1" want="$2" version="$3" format="$4" stdout="$5" status fail_flag=""
  # Cosign 3 with bundle_format bundle runs a legacy-only counter-check.
  if [[ "$version" == v3.* && "$format" == "bundle" ]]; then
    fail_flag="--new-bundle-format=false"
  fi
  set +e
  (
    cd "${TMP}/work"
    PATH="${TMP}/bin:${PATH}" \
      COSIGN_GIT_VERSION="$version" COSIGN_VERIFY_STDOUT="$stdout" COSIGN_FAIL_FLAG="$fail_flag" \
      PARAM_IMAGE="registry.local:5000/app@sha256:aa" PARAM_KEYLESS=0 PARAM_BUNDLE_FORMAT="$format" \
      PARAM_PUBLIC_KEY=TEST_PUBLIC_KEY TEST_PUBLIC_KEY="$(printf 'not a real key' | base64)" \
      SCRIPT_BUNDLE_FORMAT_LIB="$(cat "$LIB")" \
      bash "$SCRIPT" > "${TMP}/out" 2>&1
  )
  status=$?
  set -e
  if [[ "$want" == "pass" && "$status" -eq 0 ]] || [[ "$want" == "fail" && "$status" -ne 0 ]]; then
    printf 'ok: %s\n' "$name"
  else
    printf 'FAIL: %s (exit %s, wanted %s)\n' "$name" "$status" "$want"
    sed 's/^/    /' "${TMP}/out"
    FAILURES=$((FAILURES + 1))
  fi
}

run_case "v3 bundle signature" pass v3.1.3 auto "$SIGNATURE_BUNDLE"
run_case "v3 bundle signature, bundle_format bundle" pass v3.1.3 bundle "$SIGNATURE_BUNDLE"
run_case "v3 attestation bundle only" fail v3.1.3 auto "$ATTESTATION_BUNDLE"
run_case "v3 attestation bundle only, bundle_format bundle" fail v3.1.3 bundle "$ATTESTATION_BUNDLE"
run_case "v3 legacy signature" pass v3.1.3 legacy "$LEGACY"
run_case "v3 attestation and signature bundles" pass v3.1.3 auto "$MIXED"
run_case "v2 attestation bundle only" fail v2.6.5 auto "$ATTESTATION_BUNDLE"
run_case "v1 output with a leading blank line" pass v1.13.6 auto $'\n'"$LEGACY"$'\n'
run_case "unreadable output" fail v3.1.3 auto "not json"
run_case "empty output" fail v3.1.3 auto ""

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll verify_image signature tests passed.\n'
