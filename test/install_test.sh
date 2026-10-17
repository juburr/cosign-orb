#!/usr/bin/env bash
#
# Install contract tests for src/scripts/install.sh, run offline. Every juburr
# orb's install command meets the same contract:
#
#   - the checksum table is well formed and lists the default version
#   - install.sh checks for bash and sets -euo pipefail, and stays small
#     enough for CircleCI to launch
#   - install.yml defaults to strict verification, passes every parameter,
#     and caches the directory install.sh uses under a version and
#     architecture key
#   - strict mode, which an unset verify_checksums also means, refuses an
#     unlisted version before downloading anything
#   - invalid versions and parameter values are rejected up front
#   - known_versions and false install unlisted versions, with a warning
#   - a listed version is installed only when its checksum matches, in
#     strict and known_versions mode alike
#   - uname -m picks the amd64 or arm64 release; other platforms fail
#   - downloads fall back to the next URL, and work with wget alone or an
#     old curl
#   - install_path expands variables and ~/, defaults under HOME, must be
#     absolute, and is added to the PATH of later steps only when it isn't
#     already there; another copy earlier on the PATH is reported
#   - only verified releases are cached, a cached release is verified again,
#     and the cache isn't read when there is nothing to verify against
#   - a binary that cannot run, crashes, or fails its version command fails
#     the install
#   - nothing is left in the working directory or TMPDIR
#
# Downloads, uname and the circleci CLI are stubbed, so no network is needed.
# Everything below the tool fixture is identical in every orb's copy.
#
# Run from a checkout:
#   bash PATH_TO_THIS_FILE

set -uo pipefail

# >>> tool fixture >>>
# How this orb's stand-in releases differ from the default single-binary
# shape. Nothing here: the shared section reads the asset layout from
# install.sh's tool definition.
# <<< tool fixture <<<

# >>> shared install contract >>>
# Everything from here to the end marker is identical in every juburr orb.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
INSTALL_SH="${ROOT}/src/scripts/install.sh"
INSTALL_YML="${ROOT}/src/commands/install.yml"

# The tool definition and shared functions, for asset names and URLs.
# shellcheck source=/dev/null
source <(sed -n '/^# >>> tool definition >>>$/,/^# <<< shared install logic <<<$/p' "${INSTALL_SH}")

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
SERVE="${WORK}/serve"
mkdir -p "${STUBS}" "${SERVE}"

FAILURES=0
CURRENT=""
RC=0
OUTPUT=""

begin() {
    CURRENT=$1
    echo "--- ${CURRENT}"
}

check() {
    local description=$1
    shift
    if "$@"; then
        echo "  ok: ${description}"
    else
        echo "  FAIL: ${description}"
        while IFS= read -r line; do
            echo "    | ${line}"
        done <<< "${OUTPUT}"
        FAILURES=$((FAILURES + 1))
    fi
}

# Defaults for the tool fixture's hooks, used when the fixture doesn't
# define its own.
if ! declare -F fixture_binary > /dev/null; then
    # fixture_binary ARCH: a stand-in binary for ARCH that runs anywhere.
    fixture_binary() {
        printf '#!/bin/sh\necho "fake %s for %s"\n' "${TOOL_BINARY}" "$1"
    }
fi
if ! declare -F fixture_make_asset > /dev/null; then
    # fixture_make_asset VERSION ARCH DEST CONTENT: writes a release asset to
    # DEST that holds CONTENT as the binary, and prints the path of the file
    # the checksum table describes.
    fixture_make_asset() {
        local member dir
        member=$(tool_archive_member "$1" "$2")
        if [[ -z "${member}" ]]; then
            cp "$4" "$3"
            printf '%s\n' "$3"
            return
        fi
        dir=$(mktemp -d "${WORK}/asset.XXXXXX")
        mkdir -p "${dir}/$(dirname "${member}")"
        cp "$4" "${dir}/${member}"
        chmod 0755 "${dir}/${member}"
        tar -czf "$3" -C "${dir}" "${member}"
        printf '%s\n' "${dir}/${member}"
    }
fi
if ! declare -F fixture_installed_file > /dev/null; then
    # fixture_installed_file CASE INSTALL_PATH: what the install puts on the
    # PATH.
    fixture_installed_file() {
        printf '%s/%s\n' "$2" "${TOOL_BINARY}"
    }
fi
if ! declare -F fixture_installed_content > /dev/null; then
    # fixture_installed_content INSTALL_PATH: the installed file that holds
    # the stand-in binary's content.
    fixture_installed_content() {
        printf '%s/%s\n' "$1" "${TOOL_BINARY}"
    }
fi
if ! declare -F fixture_path_dir > /dev/null; then
    # fixture_path_dir CASE: the directory the install adds to the PATH.
    fixture_path_dir() {
        printf '%s/bin\n' "$1"
    }
fi
if ! declare -F fixture_env > /dev/null; then
    # fixture_env CASE: extra VAR=value settings for every install run.
    fixture_env() {
        :
    }
fi
if ! declare -F fixture_setup > /dev/null; then
    # fixture_setup STUB_DIR: installs any extra stubs the tool needs.
    fixture_setup() {
        :
    }
fi
if ! declare -F fixture_checks > /dev/null; then
    # fixture_checks: checks only this tool needs, run after the shared ones.
    fixture_checks() {
        :
    }
fi
read -r -a TEST_VERSIONS <<< "${FIXTURE_TEST_VERSIONS:-0.0.0-orbtest 0.0.1-orbtest 0.0.2-orbtest 0.0.3-orbtest 0.0.4-orbtest 0.0.5-orbtest}"
LISTED=${TEST_VERSIONS[0]}    # in the table, and the served asset matches
TAMPERED=${TEST_VERSIONS[1]}  # in the table, but the served asset differs
BROKEN=${TEST_VERSIONS[2]}    # in the table and matches, but cannot run
UNLISTED=${TEST_VERSIONS[3]}  # not in the table
FALLBACK=${TEST_VERSIONS[4]}  # in the table, served only at the second URL
FAILING=${TEST_VERSIONS[5]}   # in the table and matches, but runs and fails

if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
    ARCHES="noarch"
else
    ARCHES=${TOOL_ARCHES}
fi
DEFAULT_ARCH=${ARCHES%% *}

# Stubs. Downloads are served from SERVE by URL and logged to DOWNLOAD_LOG.
# CURL_OLD=1 makes curl behave like a release before 7.52, which rejects
# --retry-connrefused. CURL_RESETS=N makes the first N curl downloads drop
# the connection.
cat > "${STUBS}/curl" << 'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            printf '%s\n' " -f, --fail" " -o, --output <file>" " --retry <num>"
            if [[ -z "${CURL_OLD:-}" ]]; then
                printf '%s\n' " --retry-connrefused"
            fi
            exit 0
            ;;
        --retry-connrefused)
            if [[ -n "${CURL_OLD:-}" ]]; then
                echo "curl: option --retry-connrefused: is unknown" >&2
                exit 2
            fi
            shift
            ;;
        -o) out=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
echo "${url}" >> "${DOWNLOAD_LOG}"
if [[ "$(wc -l < "${DOWNLOAD_LOG}")" -le "${CURL_RESETS:-0}" ]]; then
    echo "curl: (56) Recv failure: Connection reset by peer" >&2
    exit 56
fi
file="${SERVE_DIR}/$(printf '%s' "${url}" | sha256sum | cut -c1-32)"
if [[ -n "${FAIL_DOWNLOADS:-}" || ! -f "${file}" ]]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
fi
cp "${file}" "${out}"
EOF
# The wget stub supports only the options its --help lists, as a limited
# build such as BusyBox wget does.
cat > "${STUBS}/wget" << 'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            printf '%s\n' "  -q,  --quiet" "  -t,  --tries=NUMBER" "       --retry-connrefused" "  -O,  --output-document=FILE"
            exit 0
            ;;
        -O) out=$2; shift 2 ;;
        -q | --tries=* | --retry-connrefused) shift ;;
        https://*) url=$1; shift ;;
        *)
            echo "wget: unrecognized option '$1'" >&2
            exit 2
            ;;
    esac
done
echo "${url}" >> "${DOWNLOAD_LOG}"
file="${SERVE_DIR}/$(printf '%s' "${url}" | sha256sum | cut -c1-32)"
if [[ -n "${FAIL_DOWNLOADS:-}" || ! -f "${file}" ]]; then
    echo "wget: server returned error: HTTP/1.1 404 Not Found" >&2
    exit 8
fi
cp "${file}" "${out}"
EOF
# Retries wait without delaying the tests.
printf '#!/bin/sh\nexit 0\n' > "${STUBS}/sleep"
cat > "${STUBS}/uname" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    -s) echo "${FAKE_OS:-Linux}" ;;
    -m) echo "${FAKE_ARCH:-x86_64}" ;;
    *) echo "uname stub: unexpected arguments: $*" >&2; exit 1 ;;
esac
EOF
# Like `circleci env subst`, expands $NAME and ${NAME} references. Values must
# arrive on stdin: as an argument, the real CLI parses a leading "-" as a flag.
cat > "${STUBS}/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" != "env subst" ]]; then
    echo "circleci stub: expected 'env subst' with the value on stdin, got: $*" >&2
    exit 1
fi
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s' "${output}${input}"
EOF
chmod +x "${STUBS}"/*
fixture_setup "${STUBS}"

# A PATH with the stubs and every other command, except curl, so that
# downloads go through wget.
NO_CURL="${WORK}/no-curl"
mkdir "${NO_CURL}"
IFS=: read -r -a path_dirs <<< "${STUBS}:${PATH}"
for dir in "${path_dirs[@]}"; do
    links=()
    for file in "${dir}"/*; do
        name=${file##*/}
        if [[ "${dir}" == /* && "${name}" != "curl" && -x "${file}" && ! -d "${file}" && ! -e "${NO_CURL}/${name}" ]]; then
            links+=("${file}")
        fi
    done
    if [[ "${#links[@]}" -gt 0 ]]; then
        ln -s "${links[@]}" "${NO_CURL}/"
    fi
done

# url VERSION ARCH [N]: the Nth URL install.sh tries (default 1).
url() {
    tool_asset_urls "$1" "$2" "$(tool_asset_name "$1" "$2")" | sed -n "${3:-1}p"
}
URL_COUNT=$(tool_asset_urls "${LISTED}" "${DEFAULT_ARCH}" "$(tool_asset_name "${LISTED}" "${DEFAULT_ARCH}")" | wc -l)

# serve VERSION ARCH CONTENT [N]: serves a release asset holding CONTENT at
# the Nth URL install.sh tries (default 1), and prints the SHA-512 the table
# needs for it.
serve() {
    local asset verified
    asset=$(tool_asset_name "$1" "$2")
    verified=$(fixture_make_asset "$1" "$2" "${WORK}/${asset}.tmp" "$3")
    sha512sum "${verified}" | awk '{ print $1 }'
    mv "${WORK}/${asset}.tmp" "${SERVE}/$(printf '%s' "$(url "$1" "$2" "${4:-1}")" | sha256sum | cut -c1-32)"
}

# A copy of install.sh whose table also lists the test versions.
SCRIPT="${WORK}/install.sh"
: > "${WORK}/entries"
for arch in ${ARCHES}; do
    fixture_binary "${arch}" > "${WORK}/good-${arch}"
    printf '\177ELF\0\0\0\0not a program for this machine\n' > "${WORK}/broken-${arch}"
    printf '#!/bin/sh\necho tampered\n' > "${WORK}/tampered-${arch}"
    # Exits with code 3, or crashes with SIGSEGV (139) when ORB_TEST_CRASH is set.
    # shellcheck disable=SC2016 # expanded by the stand-in binary
    printf '#!/bin/sh\n[ -n "${ORB_TEST_CRASH:-}" ] && kill -SEGV $$\nexit 3\n' > "${WORK}/failing-${arch}"
    good=$(serve "${LISTED}" "${arch}" "${WORK}/good-${arch}")
    serve "${UNLISTED}" "${arch}" "${WORK}/good-${arch}" > /dev/null
    broken=$(serve "${BROKEN}" "${arch}" "${WORK}/broken-${arch}")
    failing=$(serve "${FAILING}" "${arch}" "${WORK}/failing-${arch}")
    tampered_listed=$(fixture_make_asset "${TAMPERED}" "${arch}" "${WORK}/unused.tmp" "${WORK}/good-${arch}" | xargs sha512sum | awk '{ print $1 }')
    serve "${TAMPERED}" "${arch}" "${WORK}/tampered-${arch}" > /dev/null
    printf '    ["%s/%s"]="%s"\n' "${LISTED}" "${arch}" "${good}" "${TAMPERED}" "${arch}" "${tampered_listed}" \
        "${BROKEN}" "${arch}" "${broken}" "${FAILING}" "${arch}" "${failing}" >> "${WORK}/entries"
    if [[ "${URL_COUNT}" -gt 1 ]]; then
        fallback=$(serve "${FALLBACK}" "${arch}" "${WORK}/good-${arch}" 2)
        printf '    ["%s/%s"]="%s"\n' "${FALLBACK}" "${arch}" "${fallback}" >> "${WORK}/entries"
    fi
done
sed "/^declare -A sha512sums=($/r ${WORK}/entries" "${INSTALL_SH}" > "${SCRIPT}"

CASE=""
# new_case: a fresh HOME, working directory, TMPDIR and download log.
new_case() {
    CASE=$(mktemp -d "${WORK}/case.XXXXXX")
    mkdir -p "${CASE}/home" "${CASE}/work" "${CASE}/tmp"
    : > "${CASE}/downloads.log"
    : > "${CASE}/bash_env"
}

# run_install [-u NAME]... [VAR=value ...]: runs the test copy of install.sh
# in CASE with the test defaults, overridden by the given settings, and with
# each NAME removed from the environment.
run_install() {
    local unset=() settings=() extra=() kept=() setting name
    while [[ "${1:-}" == "-u" ]]; do
        unset+=(-u "$2")
        shift 2
    done
    mapfile -t extra < <(fixture_env "${CASE}")
    settings=("HOME=${CASE}/home" "BASH_ENV=${CASE}/bash_env" "TMPDIR=${CASE}/tmp" "PATH=${STUBS}:${PATH}"
        "DOWNLOAD_LOG=${CASE}/downloads.log" "SERVE_DIR=${SERVE}" FAKE_OS=Linux FAKE_ARCH=x86_64
        "PARAM_VERSION=${LISTED}" PARAM_VERIFY_CHECKSUMS=strict "PARAM_INSTALL_PATH=${CASE}/bin" PARAM_CACHING=false
        ${extra[@]+"${extra[@]}"} "$@")
    for setting in "${settings[@]}"; do
        for name in ${unset[@]+"${unset[@]}"}; do
            if [[ "${setting}" == "${name}="* ]]; then
                continue 2
            fi
        done
        kept+=("${setting}")
    done
    OUTPUT=$(cd "${CASE}/work" && env ${unset[@]+"${unset[@]}"} "${kept[@]}" bash "${SCRIPT}" 2>&1)
    RC=$?
}

succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
# installed_in INSTALL_PATH [ARCH]: the stand-in binary for ARCH is installed
# in INSTALL_PATH, executable and with the content that was served.
installed_in() {
    [[ -x "$(fixture_installed_file "${CASE}" "$1")" ]] \
        && cmp -s "$(fixture_installed_content "$1")" "${WORK}/good-${2:-${DEFAULT_ARCH}}"
}
installed() { installed_in "${CASE}/bin" "$@"; }
not_installed() { [[ ! -e "$(fixture_installed_file "${CASE}" "${CASE}/bin")" ]]; }
uninstall() { rm -rf "$(dirname "$(fixture_installed_file "${CASE}" "${CASE}/bin")")" "${CASE:?}/bin"; }
no_downloads() { [[ ! -s "${CASE}/downloads.log" ]]; }
downloaded() { grep -qxF -- "$1" "${CASE}/downloads.log"; }
download_count() { [[ "$(wc -l < "${CASE}/downloads.log")" -eq "$1" ]]; }
clean_tmp() { [[ -z "$(ls -A "${CASE}/tmp")" ]]; }
clean_work() { [[ -z "$(ls -A "${CASE}/work")" ]]; }
# No temporary file (named .<name>.XXXXXX) is left beside an installed file
# or in the cache, where save_cache would pick it up.
no_stray_temp() {
    local stray
    stray=$(find "${CASE}" -path "${CASE}/tmp" -prune -o -name '.*.??????' -print)
    OUTPUT+=$'\n'"stray temporary files: ${stray}"
    [[ -z "${stray}" ]]
}
no_cache() { [[ ! -e "${CASE}/home/.cache" ]]; }
path_exported() { grep -qF -- "$(printf 'export PATH=%q:' "$(fixture_path_dir "${CASE}")")" "${CASE}/bash_env"; }
path_not_exported() { ! grep -q '^export PATH=' "${CASE}/bash_env"; }
cache_file() {
    printf '%s/home/.cache/%s/%s/%s/%s\n' "${CASE}" "${ORB_NAME}" "$1" "$2" "$(tool_asset_name "$1" "$2")"
}
served_file() {
    printf '%s/%s\n' "${SERVE}" "$(printf '%s' "$(url "$1" "$2")" | sha256sum | cut -c1-32)"
}
# yml_block NAME: the lines of install.yml's parameter NAME.
yml_block() {
    awk -v name="  $1:" '$0 == name { p = 1; next } p && /^  [^ ]/ { exit } p' "${INSTALL_YML}"
}

echo "=== ${TOOL_NAME} install contract"

begin "the checksum table is well formed"
declare -A sha512sums=()
# shellcheck source=/dev/null
source <(sed -n '/^# >>> checksum table >>>$/,/^# <<< checksum table <<<$/p' "${INSTALL_SH}")
bad_keys=""
for key in "${!sha512sums[@]}"; do
    if [[ ! "${key}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?/([a-z0-9]+)$ ]] \
        || [[ " ${ARCHES} " != *" ${BASH_REMATCH[3]} "* ]] \
        || [[ ! "${sha512sums[${key}]}" =~ ^[0-9a-f]{128}$ ]]; then
        bad_keys+="${key} "
    fi
done
OUTPUT="malformed entries: ${bad_keys}"
check "every key is <version>/<arch> for a supported arch, and every value a SHA-512" test -z "${bad_keys}"
OUTPUT=""
check "the table has entries" test "${#sha512sums[@]}" -gt 0

begin "install.sh"
OUTPUT=$(head -n 1 "${INSTALL_SH}")
check "starts with #!/bin/bash" test "${OUTPUT}" = "#!/bin/bash"
line_of() { grep -n -m 1 -xF -- "$1" "${INSTALL_SH}" | cut -d: -f1; }
# shellcheck disable=SC2016 # matched literally
GUARD_LINE=$(line_of 'if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then')
SET_LINE=$(line_of 'set -euo pipefail')
DEFINITION_LINE=$(line_of '# >>> tool definition >>>')
OUTPUT="bash check: line ${GUARD_LINE:-none}, set -euo pipefail: line ${SET_LINE:-none}, tool definition: line ${DEFINITION_LINE:-none}"
check "checks for bash 4, then sets -euo pipefail, before the tool definition" \
    test "${GUARD_LINE:-0}" -gt 0 -a "${SET_LINE:-0}" -gt "${GUARD_LINE:-0}" -a "${DEFINITION_LINE:-0}" -gt "${SET_LINE:-0}"
if command -v dash > /dev/null 2>&1; then
    OUTPUT=$(dash "${INSTALL_SH}" 2>&1)
    RC=$?
    check "run with sh (dash), says it needs bash" said "needs bash 4 or newer"
fi
check "is small enough for CircleCI to launch (under 120000 bytes)" test "$(wc -c < "${INSTALL_SH}")" -lt 120000

begin "install.yml"
DEFAULT_VERSION=$(yml_block version | awk '/^    default:/ { gsub(/"/, "", $2); print $2; exit }')
DEFAULT_MODE=$(yml_block verify_checksums | awk '/^    default:/ { gsub(/"/, "", $2); print $2; exit }')
OUTPUT="default version: ${DEFAULT_VERSION}, default verify_checksums: ${DEFAULT_MODE}"
check "verify_checksums defaults to strict" test "${DEFAULT_MODE}" = "strict"
for arch in ${ARCHES}; do
    check "the default version ${DEFAULT_VERSION} is listed for ${arch}" test -n "${sha512sums["${DEFAULT_VERSION}/${arch}"]:-}"
done
if [[ "${ARCHES}" == "amd64 arm64" ]]; then
    check "the default version has a different checksum per architecture" \
        test "${sha512sums["${DEFAULT_VERSION}/amd64"]:-a}" != "${sha512sums["${DEFAULT_VERSION}/arm64"]:-a}"
fi
OUTPUT=$(yml_block install_path)
check "install_path is documented to default to \$HOME/${TOOL_DEFAULT_INSTALL_DIR}" said "Defaults to \$HOME/${TOOL_DEFAULT_INSTALL_DIR}."
OUTPUT=$(cat "${INSTALL_YML}")
for param in caching install_path verify_checksums version; do
    check "passes ${param} to install.sh" said "PARAM_${param^^}: << parameters.${param} >>"
done
check "runs install.sh" said "command: << include(scripts/install.sh) >>"
check "writes the cache key file from the CPU and HOME" said "command: echo \"\$(uname -m) \${HOME}\" > /tmp/${ORB_NAME}-cache-key"
KEYS=$(grep -E '^ +key: ' "${INSTALL_YML}" | sed -E 's/^ +key: //' | sort -u)
OUTPUT="cache keys: ${KEYS}"
check "restores and saves one cache key, made of the orb, version, architecture and HOME" \
    test "${KEYS}" = "${ORB_NAME}-v1-<< parameters.version >>-{{ checksum \"/tmp/${ORB_NAME}-cache-key\" }}"
OUTPUT=$(cat "${INSTALL_YML}")
check "saves the directory install.sh caches in" grep -qE "^ +- ~/\.cache/${ORB_NAME}\$" "${INSTALL_YML}"

begin "a listed version installs after verification"
new_case
run_install
check "succeeds" succeeded
check "verifies the checksum" said "Checksum verification passed."
check "installs the verified binary" installed
check "downloads the ${DEFAULT_ARCH} asset" downloaded "$(url "${LISTED}" "${DEFAULT_ARCH}")"
check "adds the install directory to the PATH of later steps" path_exported
check "leaves no temporary files" clean_tmp
check "leaves no temporary files beside the installed file" no_stray_temp
check "writes nothing to the working directory" clean_work

begin "a leading v in the version is ignored"
new_case
run_install PARAM_VERSION="v${LISTED}"
check "succeeds" succeeded
check "installs" installed

begin "strict mode refuses an unlisted version before downloading"
new_case
run_install PARAM_VERSION="${UNLISTED}"
check "fails" failed
check "says there is no checksum" said "no checksum for ${TOOL_NAME} ${UNLISTED}"
check "downloads nothing" no_downloads
check "installs nothing" not_installed

begin "an unset verify_checksums means strict"
new_case
run_install PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=
check "fails" failed
check "downloads nothing" no_downloads

begin "known_versions installs an unlisted version unverified, with a warning"
new_case
run_install PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions
check "succeeds" succeeded
check "warns" said "UNVERIFIED"
check "installs" installed

begin "false installs without verification, with a warning"
new_case
run_install PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=false
check "succeeds" succeeded
check "warns" said "WITHOUT checksum verification"
check "installs" installed

begin "a listed version whose download doesn't match is refused"
for mode in strict known_versions; do
    new_case
    run_install PARAM_VERSION="${TAMPERED}" PARAM_VERIFY_CHECKSUMS="${mode}" PARAM_CACHING=true
    check "${mode}: fails" failed
    check "${mode}: reports the mismatch" said "Checksum verification failed."
    check "${mode}: installs nothing" not_installed
    check "${mode}: caches nothing" no_cache
    check "${mode}: leaves no temporary files" clean_tmp
done

begin "the real table is used: the default version doesn't match a stand-in"
new_case
serve "${DEFAULT_VERSION}" "${DEFAULT_ARCH}" "${WORK}/good-${DEFAULT_ARCH}" > /dev/null
run_install PARAM_VERSION="${DEFAULT_VERSION}"
check "fails" failed
check "reports the mismatch" said "Checksum verification failed."
check "installs nothing" not_installed

begin "invalid parameters are rejected before downloading"
# verify_checksums false, so the version check is all that stops these from
# reaching the download URL.
for value in latest "1.2.3/../../x" "1.2.3 4" "-1.2.3" ""; do
    new_case
    run_install PARAM_VERSION="${value}" PARAM_VERIFY_CHECKSUMS=false
    check "version '${value}' is rejected" failed
    check "nothing is downloaded for '${value}'" no_downloads
done
new_case
run_install PARAM_VERIFY_CHECKSUMS=yes
check "verify_checksums 'yes' is rejected" failed
check "nothing is downloaded" no_downloads
new_case
run_install PARAM_CACHING=maybe
check "caching 'maybe' is rejected" failed
new_case
run_install PARAM_INSTALL_PATH=relative/bin
check "a relative install_path is rejected" failed
check "nothing is downloaded" no_downloads

if [[ "${ARCHES}" == "noarch" ]]; then
    begin "an architecture-independent release installs on any platform"
    new_case
    run_install FAKE_OS=Darwin FAKE_ARCH=s390x
    check "succeeds" succeeded
    check "downloads the noarch asset" downloaded "$(url "${LISTED}" noarch)"
else
    begin "uname -m picks the architecture"
    for machine in x86_64:amd64 aarch64:arm64 arm64:arm64; do
        new_case
        run_install FAKE_ARCH="${machine%%:*}"
        check "${machine%%:*} succeeds" succeeded
        check "${machine%%:*} downloads the ${machine##*:} asset" downloaded "$(url "${LISTED}" "${machine##*:}")"
        check "${machine%%:*} installs the ${machine##*:} binary" installed "${machine##*:}"
    done
    new_case
    run_install FAKE_ARCH=s390x
    check "an unsupported architecture is rejected" failed
    check "nothing is downloaded for it" no_downloads
    new_case
    run_install FAKE_OS=Darwin
    check "a non-Linux system is rejected" failed
    check "nothing is downloaded for it" no_downloads
fi

begin "downloads"
if [[ "${URL_COUNT}" -gt 1 ]]; then
    new_case
    run_install PARAM_VERSION="${FALLBACK}"
    check "falls back to the next URL" succeeded
    check "tried the first URL" downloaded "$(url "${FALLBACK}" "${DEFAULT_ARCH}")"
    check "downloaded the second URL" downloaded "$(url "${FALLBACK}" "${DEFAULT_ARCH}" 2)"
    check "installs" installed
fi
new_case
run_install PATH="${NO_CURL}"
check "without curl, downloads with wget" succeeded
check "wget downloads the asset once" download_count 1
check "and installs" installed
new_case
run_install CURL_OLD=1
check "works with curl older than 7.52" succeeded
check "and installs" installed
new_case
run_install CURL_RESETS=2
check "retries a dropped connection" succeeded
check "trying three times" download_count 3
check "and installs" installed
new_case
run_install CURL_RESETS=$((3 * URL_COUNT))
check "fails after three dropped connections on every URL" failed
check "having tried each URL three times" download_count "$((3 * URL_COUNT))"
new_case
run_install FAIL_DOWNLOADS=1
check "a failed download fails" failed
check "says the download failed" said "Could not download ${TOOL_NAME}"
check "an HTTP error isn't retried" download_count "${URL_COUNT}"
check "installs nothing" not_installed
check "leaves no temporary files" clean_tmp

begin "install_path"
new_case
run_install PARAM_INSTALL_PATH="\${ORB_TEST_ROOT}/bin" ORB_TEST_ROOT="${CASE}"
check "expands environment variables" installed
new_case
# shellcheck disable=SC2088 # the ~ is for install.sh to expand
run_install PARAM_INSTALL_PATH="~/tools"
check "expands a leading ~/" installed_in "${CASE}/home/tools"
new_case
run_install PARAM_INSTALL_PATH="${CASE}/bin///"
check "accepts trailing slashes" installed
new_case
run_install PARAM_INSTALL_PATH=
check "defaults to \$HOME/${TOOL_DEFAULT_INSTALL_DIR}" installed_in "${CASE}/home/${TOOL_DEFAULT_INSTALL_DIR}"
new_case
mkdir -p "$(fixture_path_dir "${CASE}")"
run_install PATH="$(fixture_path_dir "${CASE}"):${STUBS}:${PATH}"
check "succeeds when already on the PATH" succeeded
check "is not added to the PATH again" path_not_exported
check "doesn't warn about another copy" not_said "comes before"
new_case
mkdir -p "$(fixture_path_dir "${CASE}")"
ln -s "$(fixture_path_dir "${CASE}")" "${CASE}/alias"
run_install PATH="${CASE}/alias:$(fixture_path_dir "${CASE}"):${STUBS}:${PATH}"
check "doesn't warn when a symlink to the same directory comes first on the PATH" not_said "comes before"
new_case
mkdir -p "$(fixture_path_dir "${CASE}")" "${CASE}/shadow"
fixture_binary "${DEFAULT_ARCH}" > "${CASE}/shadow/${TOOL_BINARY}"
chmod +x "${CASE}/shadow/${TOOL_BINARY}"
run_install PATH="${CASE}/shadow:$(fixture_path_dir "${CASE}"):${STUBS}:${PATH}"
check "warns when another ${TOOL_BINARY} comes first on the PATH" said "${CASE}/shadow/${TOOL_BINARY} comes before"
new_case
run_install BASH_ENV=
check "works without BASH_ENV" succeeded
new_case
run_install -u HOME PARAM_CACHING=true
check "works without HOME when install_path is set" installed
check "says the cache is not used without HOME" said "HOME is not set, so the cache is not used."
new_case
run_install -u HOME PARAM_INSTALL_PATH=
check "fails without HOME when install_path is empty" failed
check "says HOME is not set" said "HOME is not set"
check "downloads nothing" no_downloads

begin "caching"
new_case
# A symlink at a guessable temporary name must not be written through.
mkdir -p "$(dirname "$(cache_file "${LISTED}" "${DEFAULT_ARCH}")")"
printf 'untouched\n' > "${CASE}/victim"
ln -s "${CASE}/victim" "$(cache_file "${LISTED}" "${DEFAULT_ARCH}").partial"
run_install PARAM_CACHING=true
check "succeeds" succeeded
check "stores the verified asset" cmp -s "$(cache_file "${LISTED}" "${DEFAULT_ARCH}")" "$(served_file "${LISTED}" "${DEFAULT_ARCH}")"
check "doesn't write through a planted symlink" grep -qx untouched "${CASE}/victim"
rm -f "$(cache_file "${LISTED}" "${DEFAULT_ARCH}").partial"
check "leaves no temporary files in the cache" no_stray_temp
uninstall
: > "${CASE}/downloads.log"
run_install PARAM_CACHING=1 FAIL_DOWNLOADS=1
check "installs from the cache with downloads failing" installed
check "says it used the cache" said "from the cache"
check "downloads nothing" no_downloads
# A cached asset that extracts but holds the wrong binary.
fixture_make_asset "${LISTED}" "${DEFAULT_ARCH}" "$(cache_file "${LISTED}" "${DEFAULT_ARCH}")" "${WORK}/tampered-${DEFAULT_ARCH}" > /dev/null
uninstall
run_install PARAM_CACHING=true
check "verifies a cached asset, and recovers when it doesn't match" installed
check "warns about it" said "failed verification. Discarding it"
check "downloads the asset again" downloaded "$(url "${LISTED}" "${DEFAULT_ARCH}")"
check "replaces the cached asset" cmp -s "$(cache_file "${LISTED}" "${DEFAULT_ARCH}")" "$(served_file "${LISTED}" "${DEFAULT_ARCH}")"
new_case
run_install PARAM_CACHING=true PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions
check "an unverified asset installs" installed
check "but nothing is cached" no_cache
new_case
mkdir -p "$(dirname "$(cache_file "${UNLISTED}" "${DEFAULT_ARCH}")")"
fixture_make_asset "${UNLISTED}" "${DEFAULT_ARCH}" "$(cache_file "${UNLISTED}" "${DEFAULT_ARCH}")" "${WORK}/tampered-${DEFAULT_ARCH}" > /dev/null
run_install PARAM_CACHING=true PARAM_VERSION="${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions
check "a cached asset is not used when there is no checksum to verify it" installed
check "the asset is downloaded instead" downloaded "$(url "${UNLISTED}" "${DEFAULT_ARCH}")"
new_case
run_install PARAM_CACHING=false
check "caching off leaves no cache" no_cache

if declare -F tool_version > /dev/null; then
    begin "a binary that cannot run on this machine fails the install"
    new_case
    run_install PARAM_VERSION="${BROKEN}"
    check "fails" failed
    check "says it cannot run" said "cannot run on this machine"
    new_case
    run_install PARAM_VERSION="${FAILING}" ORB_TEST_CRASH=1
    check "a binary that crashes (SIGSEGV) fails the install" failed
    check "with its exit code" said "exited with code 139"
    new_case
    run_install PARAM_VERSION="${FAILING}"
    check "a binary whose version command fails fails the install" failed
    check "with its exit code" said "exited with code 3"
fi

fixture_checks

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} install contract check(s) failed."
    exit 1
fi
echo "All install contract checks passed."
# <<< shared install contract <<<
