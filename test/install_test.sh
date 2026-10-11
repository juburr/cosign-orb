#!/usr/bin/env bash
# Tests for checksum verification in src/scripts/install.sh.
#
# Locks these behaviors:
#   the install command's default verify_checksums refuses a version that is
#   not in the checksum table
#   a listed version with the wrong checksum is refused unless checks are off
#   known_versions and false install unverified binaries only when asked
#   uname -m picks the amd64 or arm64 asset and checksum; other machines fail
#
# Downloads are stubbed, so no network access is needed.
#
# Run from a checkout:
#   bash test/install_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${INSTALL_SCRIPT:-${ROOT}/src/scripts/install.sh}"
COMMAND="${ROOT}/src/commands/install.yml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Only these tools are on PATH, so the stub curl is used and wget is not.
BIN="${TMP}/bin"
mkdir -p "$BIN"
for cmd in awk bash cat chmod gzip mv rm sha512sum tar; do
  ln -s "$(command -v "$cmd")" "${BIN}/${cmd}"
done

cat > "${BIN}/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" ]]; then
  printf '%s\n' "${3-}"
  exit 0
fi
exit 1
EOF

# uname reports UNAME_S and UNAME_M (Linux on x86_64 by default).
cat > "${BIN}/uname" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${UNAME_M:-x86_64}" ;;
  *) exit 1 ;;
esac
EOF

# Writes a fake binary to the -o path and records the URL.
cat > "${BIN}/curl" << 'EOF'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
printf '#!/bin/sh\necho "not really cosign"\n' > "$out"
EOF
chmod +x "${BIN}/circleci" "${BIN}/curl" "${BIN}/uname"
export CURL_LOG="${TMP}/curl.log"

FAILURES=0

# The default the install command passes when verify_checksums is not set.
DEFAULT_MODE="$(awk '/^  verify_checksums:/ {found=1} found && /^    default:/ {print $2; exit}' "$COMMAND")"
if [[ -z "$DEFAULT_MODE" ]]; then
  printf 'FAIL: could not read the verify_checksums default from %s\n' "$COMMAND"
  exit 1
fi
printf 'install command default: verify_checksums=%s\n' "$DEFAULT_MODE"

# run_install NAME WANT(pass|fail) VERSION MODE|unset EXPECTED_OUTPUT
run_install() {
  local name="$1" want="$2" version="$3" mode="$4" expected="$5"
  local work="${TMP}/work-${RANDOM}" status
  mkdir -p "${work}/install"
  : > "$CURL_LOG"
  set +e
  (
    cd "$work"
    if [[ "$mode" == "unset" ]]; then
      unset PARAM_VERIFY_CHECKSUMS
    else
      export PARAM_VERIFY_CHECKSUMS="$mode"
    fi
    PATH="$BIN" PARAM_INSTALL_PATH="${work}/install" PARAM_VERSION="$version" \
      "${BIN}/bash" "$SCRIPT" > "${work}/out" 2>&1
  )
  status=$?
  set -e

  local problem=""
  if [[ "$want" == "pass" && "$status" -ne 0 ]]; then
    problem="exit ${status}, wanted success"
  elif [[ "$want" == "fail" && "$status" -eq 0 ]]; then
    problem="succeeded, wanted a failure"
  elif [[ "$want" == "fail" && -e "${work}/install/cosign" ]]; then
    problem="failed but still installed a binary"
  elif [[ "$want" == "pass" && ! -x "${work}/install/cosign" ]]; then
    problem="succeeded but installed no binary"
  elif ! grep -qF -- "$expected" "${work}/out"; then
    problem="output did not mention '${expected}'"
  fi

  if [[ -n "$problem" ]]; then
    printf 'FAIL: %s: %s\n' "$name" "$problem"
    sed 's/^/    /' "${work}/out"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok: %s\n' "$name"
  fi
}

UNLISTED="9.9.9"
LISTED="3.1.3"

run_install "default refuses an unlisted version" fail "$UNLISTED" "$DEFAULT_MODE" "No checksum available for version ${UNLISTED}"
run_install "unset mode refuses an unlisted version" fail "$UNLISTED" unset "No checksum available for version ${UNLISTED}"
run_install "strict refuses an unlisted version" fail "$UNLISTED" strict "opt out with verify_checksums: known_versions"
run_install "known_versions installs an unlisted version with a warning" pass "$UNLISTED" known_versions "Installing an UNVERIFIED binary"
run_install "false installs without verification" pass "$UNLISTED" false "Checksum validation is disabled"
run_install "default refuses a listed version with the wrong checksum" fail "$LISTED" "$DEFAULT_MODE" "Checksum verification failed"
if grep -qx "https://github.com/sigstore/cosign/releases/download/v${LISTED}/cosign-linux-amd64" "$CURL_LOG"; then
  printf 'ok: downloads the release asset\n'
else
  printf 'FAIL: unexpected download URL: %s\n' "$(cat "$CURL_LOG")"
  FAILURES=$((FAILURES + 1))
fi
run_install "known_versions refuses a listed version with the wrong checksum" fail "$LISTED" known_versions "Checksum verification failed"
run_install "an unknown mode is refused" fail "$LISTED" relaxed "verify_checksums must be strict, known_versions or false"

# Architecture selection. 1.8.0 has an amd64 checksum but no arm64 one.
expect_download() {
  local name="$1" url="$2"
  if grep -qxF "$url" "$CURL_LOG"; then
    printf 'ok: %s\n' "$name"
  else
    printf 'FAIL: %s: downloaded %s\n' "$name" "$(cat "$CURL_LOG")"
    FAILURES=$((FAILURES + 1))
  fi
}
RELEASES="https://github.com/sigstore/cosign/releases/download"

export UNAME_M=aarch64
run_install "aarch64 checks the arm64 checksum" fail "$LISTED" "$DEFAULT_MODE" "Checksum verification failed"
expect_download "aarch64 downloads the arm64 asset" "${RELEASES}/v${LISTED}/cosign-linux-arm64"
run_install "aarch64 refuses a version with no arm64 checksum" fail 1.8.0 "$DEFAULT_MODE" "No checksum available for version 1.8.0 on arm64"

export UNAME_M=arm64
run_install "arm64 checks the arm64 checksum" fail "$LISTED" "$DEFAULT_MODE" "ARCH: arm64 (uname -m: arm64)"
expect_download "arm64 downloads the arm64 asset" "${RELEASES}/v${LISTED}/cosign-linux-arm64"

export UNAME_M=x86_64
run_install "x86_64 finds the amd64 checksum for 1.8.0" fail 1.8.0 "$DEFAULT_MODE" "Checksum verification failed"
expect_download "x86_64 downloads the amd64 asset" "${RELEASES}/v1.8.0/cosign-linux-amd64"

export UNAME_M=armv7l
run_install "armv7l is refused" fail "$LISTED" "$DEFAULT_MODE" "Unsupported architecture 'armv7l'"
if [[ -s "$CURL_LOG" ]]; then
  printf 'FAIL: armv7l downloaded %s\n' "$(cat "$CURL_LOG")"
  FAILURES=$((FAILURES + 1))
fi
export UNAME_M=riscv64
run_install "riscv64 is refused" fail "$LISTED" "$DEFAULT_MODE" "Unsupported architecture 'riscv64'"
export UNAME_M=arm64 UNAME_S=Darwin
run_install "macOS is refused" fail "$LISTED" "$DEFAULT_MODE" "installs Linux builds of Cosign"
unset UNAME_M UNAME_S

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll install tests passed.\n'
