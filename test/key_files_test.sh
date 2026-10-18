#!/usr/bin/env bash
# Tests that the key commands keep their key files out of the working directory.
#
# sign, attest, sign_blob, verify, verify_attestation and verify_blob decode
# the key into a private temporary directory. A cosign.key or cosign.pub in
# the working directory, such as a project's own public key, must be left
# untouched, and a symlink at that name must not redirect the write. Cosign
# must get the decoded key, read-only in a directory only the user can open,
# and no key file may be left in the working directory or in TMPDIR.
# generate_key_pair is covered by generate_key_pair_test.sh.
#
# Run from a checkout:
#   bash test/key_files_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/src/scripts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin"

cat > "${TMP}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
# The scripts pass values on stdin; as an argument, one starting with "-"
# would be parsed as a flag by the real CLI.
if [[ "${1:-}" == "env" && "${2:-}" == "subst" && $# -eq 2 ]]; then
  cat
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

# Prints COSIGN_GIT_VERSION for "cosign version". Any other call records the
# key file it was given (--key PATH or --key=PATH) in KEY_LOG: the path, its
# mode, its directory's mode, and whether its content is the decoded key in
# EXPECTED_KEY. "cosign verify" prints an image signature payload.
cat > "${TMP}/bin/cosign" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
  printf '{"gitVersion":"%s"}\n' "${COSIGN_GIT_VERSION}"
  exit 0
fi
key="" prev=""
for arg in "$@"; do
  if [[ "$prev" == "--key" ]]; then
    key="$arg"
  elif [[ "$arg" == --key=* ]]; then
    key="${arg#--key=}"
  fi
  prev="$arg"
done
if [[ -n "$key" ]]; then
  content=different
  if cmp -s "$key" "$EXPECTED_KEY"; then
    content=decoded
  fi
  printf '%s %s %s %s %s\n' "$1" "$key" "$(stat -c %a "$key")" "$(stat -c %a "$(dirname "$key")")" "$content" >> "$KEY_LOG"
fi
if [[ "${1:-}" == "verify" ]]; then
  printf '[{"critical":{"type":"cosign container image signature"}}]\n'
fi
exit 0
EOF
chmod +x "${TMP}/bin/circleci" "${TMP}/bin/crane" "${TMP}/bin/cosign"

FAILURES=0

fail_case() {
  printf 'FAIL: %s\n' "$1"
  sed 's/^/    /' "${CASE}/out"
  FAILURES=$((FAILURES + 1))
}

# snapshot DIR...: every entry under each DIR with its type, link target and
# content hash, so any change to the files or the links shows up.
snapshot() {
  local dir
  for dir in "$@"; do
    (cd "$dir" && find . -mindepth 1 -printf '%p %y %l\n' | LC_ALL=C sort)
    (cd "$dir" && find . -mindepth 1 -type f -exec sha256sum {} + | LC_ALL=C sort)
  done
}

# run_case SCRIPT VERSION LAYOUT: runs SCRIPT with a private key (sign,
# attest, sign_blob) or a public key (the verify scripts) in a working
# directory that already has cosign.key and cosign.pub. LAYOUT "files" makes
# them regular files, "symlinks" makes them links to files outside it.
run_case() {
  local script="$1" version="$2" layout="$3"
  local name="${script} ${version} ${layout}" status before after key_lines
  CASE="${TMP}/${script}-${version}-${layout}"
  local work="${CASE}/work" outside="${CASE}/outside" tmpdir="${CASE}/tmp"
  mkdir -p "$work" "$outside" "$tmpdir"
  : > "${CASE}/key.log"

  printf 'test blob\n' > "${work}/blob.txt"
  printf 'test signature\n' > "${work}/blob.txt.sig"
  printf '{}\n' > "${work}/predicate.json"
  if [[ "$layout" == "files" ]]; then
    printf "the project's own private key\n" > "${work}/cosign.key"
    printf "the project's own public key\n" > "${work}/cosign.pub"
  else
    printf 'a file the symlink points to\n' > "${outside}/target.key"
    printf 'a file the symlink points to\n' > "${outside}/target.pub"
    ln -s "${outside}/target.key" "${work}/cosign.key"
    ln -s "${outside}/target.pub" "${work}/cosign.pub"
  fi

  local key_text="decoded public key"
  case "$script" in
    sign | attest | sign_blob) key_text="decoded private key" ;;
  esac
  printf '%s\n' "$key_text" > "${CASE}/expected.key"

  before="$(snapshot "$work" "$outside")"
  set +e
  (
    cd "$work"
    PATH="${TMP}/bin:${PATH}" TMPDIR="$tmpdir" \
      COSIGN_GIT_VERSION="$version" KEY_LOG="${CASE}/key.log" EXPECTED_KEY="${CASE}/expected.key" \
      PARAM_IMAGE="registry.local:5000/app:1.0" PARAM_KEYLESS=0 PARAM_BUNDLE_FORMAT=auto \
      PARAM_ANNOTATIONS="" PARAM_PREDICATE=predicate.json PARAM_PREDICATE_TYPE=slsaprovenance \
      PARAM_BLOB=blob.txt PARAM_SIGNATURE=blob.txt.sig PARAM_OUTPUT_SIGNATURE="" \
      PARAM_PRIVATE_KEY=TEST_PRIVATE_KEY PARAM_PASSWORD=TEST_PASSWORD PARAM_PUBLIC_KEY=TEST_PUBLIC_KEY \
      TEST_PRIVATE_KEY="$(base64 -w0 "${CASE}/expected.key")" TEST_PASSWORD=pw \
      TEST_PUBLIC_KEY="$(base64 -w0 "${CASE}/expected.key")" \
      SCRIPT_IMAGE_REF_LIB="$(cat "${SCRIPTS}/lib/image_ref.sh")" \
      SCRIPT_BUNDLE_FORMAT_LIB="$(cat "${SCRIPTS}/lib/bundle_format.sh")" \
      bash "${SCRIPTS}/${script}.sh" > "${CASE}/out" 2>&1
  )
  status=$?
  set -e
  after="$(snapshot "$work" "$outside")"
  key_lines="$(cat "${CASE}/key.log")"

  if [[ "$status" -ne 0 ]]; then
    fail_case "${name}: exit ${status}"
  elif [[ "$before" != "$after" ]]; then
    fail_case "${name}: the working directory or a symlink target changed:"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
  elif [[ -z "$key_lines" ]]; then
    fail_case "${name}: cosign was not given a key file"
  elif grep -qF -- " ${work}/" <<< "$key_lines" || grep -qE '^[^ ]+ [^/]' <<< "$key_lines"; then
    fail_case "${name}: cosign was given a key in the working directory: ${key_lines}"
  elif grep -vqE '^[^ ]+ [^ ]+ 400 700 decoded$' <<< "$key_lines"; then
    fail_case "${name}: the key cosign read was not the decoded key, mode 0400 in a 0700 directory: ${key_lines}"
  elif [[ -n "$(ls -A "$tmpdir")" ]]; then
    fail_case "${name}: left files in TMPDIR: $(ls -A "$tmpdir")"
  else
    printf 'ok: %s\n' "$name"
  fi
}

for script in sign attest sign_blob verify verify_attestation verify_blob; do
  for version in v3.1.3 v2.6.5 v1.13.6; do
    run_case "$script" "$version" files
  done
  run_case "$script" v3.1.3 symlinks
done

if [[ "$FAILURES" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$FAILURES"
  exit 1
fi
printf '\nAll key file tests passed.\n'
