#!/usr/bin/env bash
# Tests for src/scripts/lib/image_ref.sh.
#
# Locks these failures:
#   repo@sha256:<hex> must not become repo@sha256@sha256:<hex>
#   localhost:5000/ns/img:1.0 must keep the registry port
#   a failed crane or docker read must be fatal, with no fallthrough
#   docker must use the RepoDigests entry for the requested repository
#
# Run from a checkout:
#   bash test/image_ref_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${IMAGE_REF_LIB:-${ROOT}/src/scripts/lib/image_ref.sh}"

HEX_A="$(printf 'a%.0s' {1..64})"
HEX_B="$(printf 'b%.0s' {1..64})"
HEX_C="$(printf 'c%.0s' {1..64})"
DIGEST_A="sha256:${HEX_A}"
DIGEST_B="sha256:${HEX_B}"
DIGEST_C="sha256:${HEX_C}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Tool directories. Each test runs with PATH limited to essentials plus one
# of these, so a real crane or docker on the host is never used.
ESSENTIALS="${TMP}/essentials"
CRANE_DIR="${TMP}/crane"
DOCKER_DIR="${TMP}/docker"
BOTH_DIR="${TMP}/both"
mkdir -p "$ESSENTIALS" "$CRANE_DIR" "$DOCKER_DIR" "$BOTH_DIR"
for cmd in bash cat grep mktemp rm tr; do
  ln -s "$(command -v "$cmd")" "${ESSENTIALS}/${cmd}"
done

cat > "${CRANE_DIR}/crane" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CRANE_LOG"
if [[ "${CRANE_EXIT:-0}" != "0" ]]; then
  printf 'crane: simulated failure\n' >&2
  exit "$CRANE_EXIT"
fi
printf '%s' "${CRANE_STDOUT-}"
EOF

cat > "${DOCKER_DIR}/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  if [[ "$3" == "--format" ]]; then
    printf '%s' "${DOCKER_REPO_DIGESTS-}"
    exit 0
  fi
  if [[ "${DOCKER_LOCAL:-1}" == "1" ]]; then
    exit 0
  fi
  printf '%s\n' "${DOCKER_INSPECT_ERROR:-Error response from daemon: No such image: $3}" >&2
  exit 1
fi
if [[ "$1" == "pull" ]]; then
  ref="${!#}"
  for bad in ${DOCKER_PULL_FAIL-}; do
    if [[ "$ref" == "$bad" ]]; then
      printf 'Error response from daemon: %s: not found\n' "$ref" >&2
      exit 1
    fi
  done
  exit 0
fi
printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 1
EOF

chmod +x "${CRANE_DIR}/crane" "${DOCKER_DIR}/docker"
ln -s "${CRANE_DIR}/crane" "${BOTH_DIR}/crane"
ln -s "${DOCKER_DIR}/docker" "${BOTH_DIR}/docker"

FAILURES=0
CRANE_LOG="${TMP}/crane.log"
DOCKER_LOG="${TMP}/docker.log"
export CRANE_LOG DOCKER_LOG

fail_case() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

pass_case() {
  printf 'ok: %s\n' "$1"
}

# run_resolve TOOLDIR REF: runs resolve_image_uri_digest in a clean shell.
# Sets OUT, ERR and STATUS.
run_resolve() {
  local tooldir="$1" ref="$2"
  : > "$CRANE_LOG"
  : > "$DOCKER_LOG"
  set +e
  OUT="$(PATH="${ESSENTIALS}:${tooldir}" bash -c 'eval "$(cat "$1")"; resolve_image_uri_digest "$2"' _ "$LIB" "$ref" 2> "${TMP}/err")"
  STATUS=$?
  set -e
  ERR="$(cat "${TMP}/err")"
}

expect_resolved() {
  local name="$1" tooldir="$2" ref="$3" want="$4"
  run_resolve "$tooldir" "$ref"
  if [[ "$STATUS" -ne 0 ]]; then
    fail_case "${name}: exit ${STATUS}, wanted ${want}"
    printf '%s\n' "$ERR" | sed 's/^/    /'
    return
  fi
  if [[ "$OUT" != "$want" ]]; then
    fail_case "${name}: got '${OUT}', wanted '${want}'"
    return
  fi
  pass_case "$name"
}

expect_refused() {
  local name="$1" tooldir="$2" ref="$3" message="$4"
  run_resolve "$tooldir" "$ref"
  if [[ "$STATUS" -eq 0 ]]; then
    fail_case "${name}: succeeded with '${OUT}', wanted a failure"
    return
  fi
  if [[ -n "$OUT" ]]; then
    fail_case "${name}: printed '${OUT}' on stdout while failing"
    return
  fi
  if [[ "$ERR" != *"$message"* ]]; then
    fail_case "${name}: stderr did not mention '${message}'"
    printf '%s\n' "$ERR" | sed 's/^/    /'
    return
  fi
  pass_case "$name"
}

log_has() {
  grep -qxF -- "$2" "$1"
}

run_parse_cases() {
  local repo tag digest
  check_parse() {
    local ref="$1" want_repo="$2" want_tag="$3" want_digest="$4"
    set +e
    read -r repo tag digest < <(bash -c 'eval "$(cat "$1")"; parse_image_ref "$2" && printf "%s %s %s\n" "${IMAGE_REF_REPOSITORY:--}" "${IMAGE_REF_TAG:--}" "${IMAGE_REF_DIGEST:--}"' _ "$LIB" "$ref" 2> /dev/null)
    set -e
    if [[ "$repo" == "$want_repo" && "$tag" == "$want_tag" && "$digest" == "$want_digest" ]]; then
      pass_case "parse ${ref}"
    else
      fail_case "parse ${ref}: got '${repo} ${tag} ${digest}', wanted '${want_repo} ${want_tag} ${want_digest}'"
    fi
  }
  check_parse "ttl.sh/app:1h" "ttl.sh/app" "1h" "-"
  check_parse "localhost:5000/ns/img:1.0" "localhost:5000/ns/img" "1.0" "-"
  check_parse "localhost:5000/ns/img" "localhost:5000/ns/img" "-" "-"
  check_parse "registry.local:5000/ns/img@${DIGEST_A}" "registry.local:5000/ns/img" "-" "${DIGEST_A}"
  check_parse "ghcr.io/juburr/charts/app:1.2.3@${DIGEST_A}" "ghcr.io/juburr/charts/app" "1.2.3" "${DIGEST_A}"
  check_parse "ubuntu" "ubuntu" "-" "-"

  bad_parse() {
    local ref="$1" message="$2"
    set +e
    err="$(bash -c 'eval "$(cat "$1")"; parse_image_ref "$2"' _ "$LIB" "$ref" 2>&1 > /dev/null)"
    status=$?
    set -e
    if [[ "$status" -ne 0 && "$err" == *"$message"* ]]; then
      pass_case "parse rejects ${ref:-<empty>}"
    else
      fail_case "parse ${ref:-<empty>}: exit ${status}, stderr '${err}'"
    fi
  }
  bad_parse "" "is empty"
  bad_parse "repo@sha256:abc" "not a sha256 digest"
  bad_parse "repo@sha256:$(printf 'A%.0s' {1..64})" "not a sha256 digest"
  bad_parse "repo@sha512:$(printf 'a%.0s' {1..128})" "not a sha256 digest"
  bad_parse "a@b@${DIGEST_A}" "more than one"
  bad_parse "repo:" "empty tag"
  bad_parse "localhost:5000/" "Could not parse"
  bad_parse "ttl.sh/app 1h" "whitespace"
}

run_normalize_cases() {
  check_norm() {
    local got
    got="$(bash -c 'eval "$(cat "$1")"; normalize_repository "$2"' _ "$LIB" "$1")"
    if [[ "$got" == "$2" ]]; then
      pass_case "normalize $1"
    else
      fail_case "normalize $1: got '${got}', wanted '$2'"
    fi
  }
  check_norm "ubuntu" "docker.io/library/ubuntu"
  check_norm "org/app" "docker.io/org/app"
  check_norm "docker.io/ubuntu" "docker.io/library/ubuntu"
  check_norm "index.docker.io/library/ubuntu" "docker.io/library/ubuntu"
  check_norm "localhost/app" "localhost/app"
  check_norm "localhost:5000/ns/app" "localhost:5000/ns/app"
  check_norm "ghcr.io/org/app" "ghcr.io/org/app"
}

run_crane_cases() {
  export CRANE_STDOUT="${DIGEST_A}" CRANE_EXIT=0

  expect_resolved "crane: tag" "$CRANE_DIR" "ttl.sh/app:1h" "ttl.sh/app@${DIGEST_A}"
  log_has "$CRANE_LOG" "digest ttl.sh/app:1h" || fail_case "crane: tag was not read from the registry"

  expect_resolved "crane: registry port with tag" "$CRANE_DIR" "localhost:5000/ns/img:1.0" "localhost:5000/ns/img@${DIGEST_A}"
  expect_resolved "crane: registry port without tag" "$CRANE_DIR" "localhost:5000/ns/img" "localhost:5000/ns/img@${DIGEST_A}"
  expect_resolved "crane: digest is kept" "$CRANE_DIR" "ghcr.io/juburr/charts/app@${DIGEST_A}" "ghcr.io/juburr/charts/app@${DIGEST_A}"
  log_has "$CRANE_LOG" "digest ghcr.io/juburr/charts/app@${DIGEST_A}" || fail_case "crane: digest was not checked against the registry"
  expect_resolved "crane: port and digest" "$CRANE_DIR" "registry.local:5000/ns/img@${DIGEST_A}" "registry.local:5000/ns/img@${DIGEST_A}"
  expect_resolved "crane: tag and digest drops the tag" "$CRANE_DIR" "registry.local:5000/ns/img:1.0@${DIGEST_A}" "registry.local:5000/ns/img@${DIGEST_A}"

  CRANE_STDOUT="  ${DIGEST_A}"$'\r\n' expect_resolved "crane: whitespace is trimmed" "$CRANE_DIR" "ttl.sh/app:1h" "ttl.sh/app@${DIGEST_A}"

  CRANE_STDOUT="${DIGEST_B}" expect_refused "crane: registry digest differs from the requested one" "$CRANE_DIR" "ttl.sh/app@${DIGEST_A}" "not the requested"
  CRANE_STDOUT="" expect_refused "crane: empty output" "$CRANE_DIR" "ttl.sh/app:1h" "is not a sha256 digest"
  CRANE_STDOUT="sha512:abc" expect_refused "crane: non-sha256 output" "$CRANE_DIR" "ttl.sh/app:1h" "is not a sha256 digest"

  CRANE_EXIT=1 expect_refused "crane: failed tag read" "$BOTH_DIR" "ttl.sh/app:1h" "crane digest failed"
  if [[ -s "$DOCKER_LOG" ]]; then
    fail_case "crane: a failed read fell through to docker"
  else
    pass_case "crane: a failed read does not fall through to docker"
  fi
  CRANE_EXIT=1 expect_refused "crane: digest the registry does not serve" "$BOTH_DIR" "ttl.sh/app@${DIGEST_A}" "crane digest failed"
  [[ -s "$DOCKER_LOG" ]] && fail_case "crane: a failed digest check fell through to docker"
  unset CRANE_STDOUT CRANE_EXIT
}

run_docker_cases() {
  export DOCKER_LOCAL=1 DOCKER_PULL_FAIL=""
  export DOCKER_REPO_DIGESTS="127.0.0.1:5000/other/img@${DIGEST_B}
localhost:5000/ns/img@${DIGEST_A}
"
  expect_resolved "docker: picks the requested repository, not index 0" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "localhost:5000/ns/img@${DIGEST_A}"
  log_has "$DOCKER_LOG" "pull --quiet localhost:5000/ns/img@${DIGEST_A}" || fail_case "docker: the digest was not confirmed against the registry"

  DOCKER_REPO_DIGESTS="other.example/ns/img@${DIGEST_B}" \
    expect_refused "docker: no digest for the requested repository" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "no digest recorded for localhost:5000/ns/img"
  DOCKER_REPO_DIGESTS="" \
    expect_refused "docker: never pushed" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "no digest recorded"
  DOCKER_REPO_DIGESTS="localhost:5000/ns/img@${DIGEST_A}
localhost:5000/ns/img@${DIGEST_C}" \
    expect_refused "docker: two digests for one repository" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "more than one digest"

  DOCKER_REPO_DIGESTS="ubuntu@${DIGEST_A}" \
    expect_resolved "docker: Docker Hub short name" "$DOCKER_DIR" "docker.io/library/ubuntu:22.04" "docker.io/library/ubuntu@${DIGEST_A}"
  DOCKER_REPO_DIGESTS="docker.io/library/ubuntu@${DIGEST_A}" \
    expect_resolved "docker: Docker Hub full name" "$DOCKER_DIR" "ubuntu:22.04" "ubuntu@${DIGEST_A}"

  DOCKER_PULL_FAIL="localhost:5000/ns/img@${DIGEST_A}" \
    expect_refused "docker: recorded digest is missing from the registry" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "could not be pulled from the registry"

  DOCKER_LOCAL=0 expect_resolved "docker: pulls a missing image" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "localhost:5000/ns/img@${DIGEST_A}"
  log_has "$DOCKER_LOG" "pull localhost:5000/ns/img:1.0" || fail_case "docker: the missing image was not pulled"
  DOCKER_LOCAL=0 DOCKER_PULL_FAIL="localhost:5000/ns/img:1.0" \
    expect_refused "docker: failed pull" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "docker pull failed"
  DOCKER_LOCAL=0 DOCKER_INSPECT_ERROR="Cannot connect to the Docker daemon" \
    expect_refused "docker: daemon unavailable" "$DOCKER_DIR" "localhost:5000/ns/img:1.0" "docker image inspect failed"

  expect_resolved "docker: digest is kept" "$DOCKER_DIR" "registry.local:5000/ns/img@${DIGEST_A}" "registry.local:5000/ns/img@${DIGEST_A}"
  if grep -q "image inspect" "$DOCKER_LOG"; then
    fail_case "docker: a digest reference was looked up locally instead of in the registry"
  fi
  log_has "$DOCKER_LOG" "pull --quiet registry.local:5000/ns/img@${DIGEST_A}" || fail_case "docker: the digest was not confirmed against the registry"
  DOCKER_PULL_FAIL="registry.local:5000/ns/img@${DIGEST_A}" \
    expect_refused "docker: digest the registry does not serve" "$DOCKER_DIR" "registry.local:5000/ns/img@${DIGEST_A}" "could not be pulled from the registry"
  unset DOCKER_LOCAL DOCKER_PULL_FAIL DOCKER_REPO_DIGESTS
}

run_tool_cases() {
  expect_refused "no crane or docker" "${TMP}/none" "ttl.sh/app:1h" "either crane or docker"
}

main() {
  run_parse_cases
  run_normalize_cases
  run_crane_cases
  run_docker_cases
  run_tool_cases
  if [[ "$FAILURES" -ne 0 ]]; then
    printf '\n%d failure(s)\n' "$FAILURES"
    exit 1
  fi
  printf '\nAll image reference tests passed.\n'
}

main "$@"
