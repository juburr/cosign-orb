#!/bin/bash
#
# Installs Cosign for the install command: the Linux amd64 or arm64 build that
# matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (Cosign only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing Cosign needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="cosign-orb"
TOOL_NAME="Cosign"
TOOL_BINARY="cosign"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'cosign-linux-%s\n' "$2"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf 'https://github.com/sigstore/cosign/releases/download/v%s/%s\n' "$1" "$3"
}

# tool_archive_member VERSION ARCH: empty, since Cosign publishes bare
# binaries. The checksum table holds the SHA-512 of the asset itself.
tool_archive_member() {
    :
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    "$1" version
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty.
orb_extract() {
    local asset=$1 member=$2 dir
    if [[ -z "${member}" ]]; then
        ORB_VERIFIED_FILE=${asset}
        return 0
    fi
    dir="${ORB_WORK_DIR}/extract"
    rm -rf "${dir}"
    mkdir "${dir}"
    if ! tar -xzf "${asset}" -C "${dir}" --no-same-owner -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
        orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
        return 1
    fi
    ORB_VERIFIED_FILE="${dir}/${member}"
    if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            cp "${ORB_CACHE_FILE}" "${asset}"
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            rm -f "${ORB_CACHE_FILE}"
            use_cache=false
            continue
        fi
        orb_die "${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) failed verification and was not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST,
# replacing any existing file in a single rename.
orb_install_file() {
    local dir=${2%/*}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if ! { orb_temp_beside "$2" && cp "$1" "${ORB_TEMP}" && chmod 0755 "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "$2"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# Runs the installed binary once, which catches a build that can't run here:
# one for another architecture (exit code 126), or one that crashes, such as
# with SIGILL on a CPU it doesn't support. tool_version needs no network, so
# any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "${ORB_INSTALL_PATH}/${TOOL_BINARY}" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The installed ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_smoke_test
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
#
# Each entry was added only after the binary's keyless Sigstore signature
# verified against the Cosign release identity. Linux arm64 builds start at 1.9.0.
declare -A sha512sums=(
    ["3.1.3/amd64"]="299a32c20b9a6ae981e5decd5a3d91b0f1dfc03c6f38e90f0adfa92b993bfd38faecdd99d80e749b8b9f34e4516c09928cbe785ad6c150db8f3a6a4a84ff5e53"
    ["3.1.3/arm64"]="d372dead7e417d60a1e02c34183f32ae171ac82d1085cc5180032dcd38db792ae6ed562de5cfedfd77cf0f8def35a54313253601bffab77e075ea3239ecd99ad"
    ["3.1.2/amd64"]="01174ede4958413aca502e7eafdff34a5a7fab39c25af66b84c24b98e354e5cf2631bf2c07ecdd8c684dfab843f9694237606706eeafc20ae30ed5ed831f1d60"
    ["3.1.2/arm64"]="635c9d2d661dc300ce8038f5f922af90886faa8b7baacdbb7f6de9f734b80d18bb13b4d34854720fd6d0a63839b8899d2b4fdea2811c0d7e07a802cdb518df24"
    ["3.1.1/amd64"]="2dacab69213a9a6ef3c17050a070294ad5fd95bd2e65cdb81f458bcba2599ea71524ccd139680b643f17e87c23dc8aa59bb4d6f9cc82d333f0458a0d9dc4b0b5"
    ["3.1.1/arm64"]="a3261f40193777fbd1a7892e6ff727b0021d53082fb006b3afc37796619d67001f5ab89c2db711b129961202c6621ebc37969717bb4193b58fc0ff113fc53ebb"
    # Version 3.1.0 was skipped by the release pipeline. v3.1.1 is the first 3.1 release.
    ["3.0.6/amd64"]="57602e8b05025b02b10b8d646d0553c788c6d1867a78b3dc3c3fb8e23a46f923f35bd2c738fd9dc090cd3c7cd45c543dfc84168f50d30992ae59bb30df07d62e"
    ["3.0.6/arm64"]="7bbf3e637ee457552c28432db4eec201c58eab090cde697df50560d03aff658584408bb20cc2c751be8a6a77fb826b2e1a6fb9400cfb38f0749afb3ff9cc862c"
    ["3.0.5/amd64"]="71637fd143613301ad95c63d9db8dffa2c80cd7e77aa9ffadb1398aa0dd86d03db53c82159835378711f55067c29822f84d5a062e79c3e36d16b92e3f080ac50"
    ["3.0.5/arm64"]="4e0d2cf9f6ebd8da514167b02e9dacad7d7d70c0d0e090d09ab80abcd381f346cabc9a1f33db5bd96faed803d6db5d8eb34cbe5a075914d57d9c591990237c69"
    ["3.0.4/amd64"]="94029f536a5b6596ca21bc11eff6e51eb0e75c18ef0ee0002beb3865454d98b2a5c00192dff1c2e0e2f3fea7dbacddb11ad59d8e53f9e9ea9b8c09dc62e127b4"
    ["3.0.4/arm64"]="190010c86aabc94d94bde54780d023bcd7d182ab0d9544b4a260fd5a848a7bdc384047a0a9881334f8fdabac2dc902518a0efed1ae6d12e343ae36551c1a7006"
    ["3.0.3/amd64"]="669eff5b8b94fc2f19f92c20f6ba079fb8ef20e206e96d5371c11fc949f605466880a2f63953dc481339bb894554dd7f915c6a253e42a63fb00b9370395ea785"
    ["3.0.3/arm64"]="a0b23c559898fa7d5ca39adfb13576ccf5ae1fe587205b5e4e3fe092e1c5bc413fe8bd9ee605c2eb533b903d6c35f095e3d3ce1dfa0a23d5943b34a778ebde31"
    ["3.0.2/amd64"]="f685b81891f40fafe8e9a96e4901bce2a4de6918f3ae0ce5e79a65feaffb7b6c78ae5da2f253dc92a5fc4aac9f55e09cd4f48ee42183fab3736c1000922a00ac"
    ["3.0.2/arm64"]="728d819e0165b82cd9731f26c424f77a0ff31023749759d964c484ca22ad84b5ebee7ec2b054a7949f164bc384a0a3882816d7ab34245bcf474025871a52f080"
    ["3.0.1/amd64"]="013673207c304514dac7d62cb67b6123078bf445ba202e5a4e6fb077350f7bebe0fc2a9505d1d3554bc2f5d1a9e6745333d9015f6cc1a5b5bcffae7901a840fe"
    ["3.0.1/arm64"]="0f290c38d1dee441b6da4394c67ce802dc515dbbf086a28d03950ededfa71b3a96f1193aabede4b836558e07d149a627e415a6d21ccdf49e1384bcf8a8a24d89"
    # Version 3.0.0 was not released correctly.
    ["2.6.5/amd64"]="4ffa3dcb334c60e1d7777713b60d803cc1ea4db17257bd13705ff4fde8e783cb9c86ff75d5ba2b2f371a73cb468465d9a2a863cd5c0c753e1af440249182cdb6"
    ["2.6.5/arm64"]="b2cb6c330d1161b2124910836b8f31ef1db8149acd5b943d76b5145d377c6756024552063d1d50a9800796a53f7c8609a9b0e1485e0f5be82e7c8823a163847a"
    ["2.6.4/amd64"]="e9b92b86d9ae438a0d93bb027add9238a6e358fd8981eb369f24a4dfc2545fca8f75d28d783407fefc5ca5522deb6c99c4f4671cec4c4b92ee97d767c17b7b80"
    ["2.6.4/arm64"]="637510b00df0e8cadca64cebf01c0583c23504abe0547484c1a1f68a34569e688760290d44bbd5c78fa604f31e998aa7e80f59b054ecd50bf2d4c4a63a657154"
    ["2.6.3/amd64"]="c0eabe1a284b3d656d56426dedd212cdf7b49e5aabd22eb2fc683065ea73269f44a199cc5f78b770662b2508dc66729134c519e0b03fb982a592fc73f16b0b27"
    ["2.6.3/arm64"]="457524d3e7102b344856caa1bef283001e3695db8dd3039d8d1e60f5151541a9ac65f1668c16399c9fb96c18e3963b5098b8fab8fe8d72d598a7a244907dbee9"
    ["2.6.2/amd64"]="3d775c2727df9d375070a9ac81293a2139229ae3fd39e6a587593a08304ac2ef44b106f53a4a7c9a7da1cea08565685bbf94e900229635e4b82b770be5031a86"
    ["2.6.2/arm64"]="60ff465ff5d36911166914492e4caef22678afbaa85909f4a85e8b961bfc45eff6cc3024d9fe74b31f008142877a060e083dff1561f88c7ef10f675d43f870be"
    ["2.6.1/amd64"]="e4db469e0cf8f35fc5440ca2239588209d06e1e91f9fc829d80c178d52fd7cbd389616be50bbbb032c58a59a4764f60416dc3da196ea272e685efbc47c12ef8f"
    ["2.6.1/arm64"]="6799e0eec813093dc5e38edc8204f230b3434b167e8fe594672ce6df40e066cbdbee7629d4562cfde0289b5a57d2ffa38e3653fd9e2d09e1dfcc560741deab00"
    ["2.6.0/amd64"]="87b5a39cdcd5d84a1204f5a206d658a4d7e4b2acd8b1803f125df228c40572b52669fc404f4fb88101c8e03c58b5433a3b4dc31c3e3ae2e8a04ee5a340cd3210"
    ["2.6.0/arm64"]="8548497850a0b235ab007bfaa6de8ec175f950eaa14ca6c268af7658f8f7c123598f3c8426990166e37704f964cadd85f90f4bccd080688023717c2ac01ce0c8"
    ["2.5.3/amd64"]="f75802f709f2a03165e5a0782e84d4656731743bb919a32ce937f1dc5855bca21eaa843342fcc521926b7f4808ab1143938d6fa660719783ec4510f026a01ca6"
    ["2.5.3/arm64"]="2b37d6f561e85fce75ac98770652b003d30ee4fabf7d0bff25a6e2823741bef1a64bf9d57d3e34859226215194e5c146dc35bd558027aa5691ca4fd2ff2cdd4d"
    ["2.5.2/amd64"]="08368ebc4f23fd666fea523f7aa872462ffa0ad06defae916ee2aaf0e2cde7b9a27fcc2dc292a2f2181c51603bdaa4973384ccf6eb84d184e2af2acce1338590"
    ["2.5.2/arm64"]="7477c8c5d97798f8c730260ddee9a77de36e7d3aa3a771217b6814b87c8bf572fbab69c5778becd2691a9b91122fafa6984d78b3f655eb60531f83bef39d5600"
    ["2.5.1/amd64"]="6bdf823cb3b115b1558fce920f3a91d7781e4f7a863ecea32cd7bacee826e30506480aaaffcb2eae502edde810289ecf4ca43dd9ef6a30ce74f704ef3073f363"
    ["2.5.1/arm64"]="1a97f9f88ef67bc6eb0e8764032cb58753c4f75dace3f67b03ca167b257fba358ff5b83ca774f5fb2417dba20370727e97edab4fe3dc5bcf1d3225697038b2f7"
    ["2.5.0/amd64"]="517ff06639a563c9ce7e360203d9ca996ca09a850f4c884abe6533c52c9f60e11b6b417e446cb6f1a4d91d811e476b4fcaa5adc78fc7313c50a55b009c32427c"
    ["2.5.0/arm64"]="d3d1f9e8f7c7014fa0cc7f5fc5e42347b274088e01608f83e5e7b7a751df16a2d284f4cc5e35d22f359b49a0e1c397698564e3b92f6666301db94672589273cd"
    ["2.4.3/amd64"]="b1c2475a694290cfeb129ef04cd3b23a61bd5f8c9ca609a103824adf22baead2fc5d14291467c5e12ec95b17d355da680e042c5961f2cab5cb08ea259a83f444"
    ["2.4.3/arm64"]="053d09ec89000735bd953731db0793b9a4846c76b24fb840d0d63203cb1c51c09d554f8e24c473684312ea9dfd4b01fbd6b77be16f20583e21f6d47ebaa4cabf"
    ["2.4.2/amd64"]="e7d282e2933219d6ab636f913970b89bf3c30aecbcffaf89ece4c784793bb04ed14349137bf31fba7251c22f7b01d306587fbd4b2bdf5a25d36bd0ce876424ac"
    ["2.4.2/arm64"]="c10945b8f2f6864b70dd64fd9ee5e2d186f4b6ea863c7b56565172eb263afc42be0786c0b87f9bdb5be266f60e2ef6963aa3c36a11f5006b431f8df970e7a450"
    ["2.4.1/amd64"]="6aaed7f63bf6ae7dea27a982d6cf5de8ec50876d5fb5ad9e38c9c178786929aa7930da8cde1aafbe76e5026366fc6006da1812995eb1dc2c1894b52e0e6ed191"
    ["2.4.1/arm64"]="2ad63370d699afacb59704f557108db55dc9bc0c919b443b0f2f5e4b18995e37a4e569840a3042b894ae1f99594552339dd1205775e4c334e1fa84dff02ba76f"
    ["2.4.0/amd64"]="acf268337df43040e31f5d83628c0556a81edd2e7b91ff7640cb34862e5200fb7c313389001a0be4ee65a554ef225fcd9ab18e10bc2e3f5dba7effe2ff84d8bb"
    ["2.4.0/arm64"]="cd8596991bdf4a3892130c4a5563d34a98705fe09c59b23f91729311769b63d4bddee82c47ad1ebe2b8e9d1af1eef12f7482936f45c0827e47015c10a271dc01"
    ["2.3.0/amd64"]="d5339dc2915c9078c15218557f8e5123b640ef4fe6b5fd402548b2c744c85d4f7549b1fcfb5712cd5dfc51bdb43253ea459e83bf00b435d03e81a6c0773835ec"
    ["2.3.0/arm64"]="bf436295344a284c3e662df4eac4ede4535a65a8d7b9be4a00443193d6473ab41398528ef0f7bb06a452c075612d981342687e9c698ce5531415d145bf4ee4ae"
    ["2.2.4/amd64"]="1b2fcf9eeb03ffdb2b552b608dbc6c68f9a3be5dac1bda81ed8308fb116a17b04d5e7d72e5da7aa2025932db4c0d48967abeeac5b0056882b82cb897aa1eeb72"
    ["2.2.4/arm64"]="2d6bc41bad000b3a747d0f467049bbde6db2696b0d2f7e4628266caef8812a8f063d8bc580fa66c6359a592d63548c928711340d5bbbb92e87c6c2dac838c660"
    ["2.2.3/amd64"]="35584c00e10efc4a562e473ad37e24350aad9ce3bbc588f981d1ea79486848573c68d6bca8d6443db4d07a15d8ddfd57f4609c85247c0ff6c09fe8d0d3ef1b57"
    ["2.2.3/arm64"]="3a024c4f8aa0d74bcc79c702cfe7eb60b1d4feec668901875e57b0f9d4f5ee2229a21e0303324a4e6a04e14f748415511a8c0498adc662f56c73163e21c56f61"
    ["2.2.2/amd64"]="0877382b5121a12d25869104e9eb674799cbd393d2ec4e0e3c5e4cb55ea7ea6135b6966e75f317ea338a8d8a544e8cf1bdd01a06decb62df3679380dc24445c6"
    ["2.2.2/arm64"]="944c51b14f82ca969a7c40f9535fec27e4e32d06db48ee6c54421bcf3e9e28f3bde495af9c0c11ad3dfe1c74d68286449bd8e82d3def7a82ff753b2dc061195a"
    ["2.2.1/amd64"]="b47c77b57b08eafe252fb0a6d39d7bfda34b50cdfa554f5b358be97b2e5b540b7e9343d39a015c33399d16d76946d03f0cb8fc6f08cd65c397cc1e3a2293020a"
    ["2.2.1/arm64"]="9f463fee9f202e297a78d394dd58013f6cbdf3ba6b651347b080f7a76d5fcebc3572730bca4ba09fa956443d52991f22f38caac9bb56931cb98d921f5708e845"
    ["2.2.0/amd64"]="4fdc69704625b686eae18964a8e9ba621d6d87b419f2adc8c7af09cc661ded6a4a5998cbeac1c106e261331097877ea6c56c6d9fb8b959bcf9df928f047ddd50"
    ["2.2.0/arm64"]="3455020132e87a5fe92e8b21ba54850b3a5e307891b54d1a3686679c9224cc1c529f0881be1a4242aba0b16ea4b68b0fa51c5c6fe23480be8de545f7aa9f89a6"
    ["2.1.1/amd64"]="05e8403cd9b1da69d8778244dcadd81de4fb3e5177af1ae103a1d7b4d494be14c185c1b0de428e6e116c0016f79e5fa78c53d22a4b274bf7adb8fd089521789c"
    ["2.1.1/arm64"]="28565845d03dfe8d83c31f8d4c5f5465807ae032b8f3e0088635081750a2a9ab05536b8ea474a9a4cfba709a05b5c92bfc7d4629e5e7bce2ba52e3375de46195"
    ["2.1.0/amd64"]="be2567ec629af1ab6243203d4c60fb4c343c21274a0585c92edaccbe70840de8a97bc25dce4730fb50cc3f2c7c1cbae1ec876626853160994f7b912d53df4ee1"
    ["2.1.0/arm64"]="4f25ad656bbfbdc35fe32801250ba5499518650e47c2d211de6b4cc170b3fd7a938c5c903949084e63730955a8b815617504be4ead6b04719b65184d59bd6d73"
    ["2.0.2/amd64"]="6f077fb946223c2c452b222755e2891ebbc31e0166db120167a96f88eeb6f93f4e297eb1115a5bb03fedcc0bc46a5f2ad6eea3b127ba8bf7d72797565fed0eb4"
    ["2.0.2/arm64"]="6438fc9409b4aa1a727f6d141f4dfefcb2311bd7455b184542b32f45728ae3e73f2142c1c10bcf784a6d63b697acbecbac4ee907c99c403a8d2a469f239089a8"
    ["2.0.1/amd64"]="f572d23e13849b7974ca5ae0ebc18f773b6cb6ff7a02237996720376105d7765a982a36f6b515ede20b5197b3d9576e74a73c5215a61cbd9818a0699c617b1d7"
    ["2.0.1/arm64"]="2c038c1d4632bff1bb9178c1bef8152b1270a661aa21c1802a8b92e5c206686a83257fa14996bbfd4392a4138563b76e82dd0ba2948967b03ee8c96c04b48593"
    ["2.0.0/amd64"]="c11f645895fa7670bd7f1fbfd8763e9018a1b7cb8458585d3762d3df9a0b697bc84b6bc3b55c46cbf8882a8e76d4ebee06347e591a141498216ca75994b0d6b1"
    ["2.0.0/arm64"]="b63cd71ad5ad1901f324e67f460ace57683d67659a2acaced717f306be77c3e769daa27a66c697e3005b4cb6ac45273438d721971db7e260598ce007d02982ad"
    ["1.13.6/amd64"]="f775b9826876d5ddb92a1a73a394d89f74efd36ea05925a4db1ee206b3adf7238b8cb5c25d11d1a1abc30d4699adcd4459d28658c5d41ead3283363c3dc76164"
    ["1.13.6/arm64"]="29ff7ef6cda36d4d543e10967307c95219b6a0b091ff7f236457fba6b552bcf1170818c85746792ee61ce7c27ec8aa67a0abf2fd067cf858191d091f2d4556ec"
    # Versions 1.13.3, 1.13.4, and 1.13.5 were not released correctly.
    ["1.13.2/amd64"]="eccb284cc560974a853caee0650dba1b6da02c996dfe31637b13d6015710afdb7ce90314dc33e02f0291264be1289714c2e439c552b5207fd4b811ed3dea8eb9"
    ["1.13.2/arm64"]="518d56d22e249f6988c1cb50ade69674062a15bf167d182e0967ba5d4e8507a95c76ad5dee225967474395c78b6f7d7db40b1444cf0b50b088a094d0420940bf"
    ["1.13.1/amd64"]="cbbaf2a6fd20ad85fbe16b4710fced529547f9d3b6e1888194ba10588353cf80eba5d56502083190a7e99fd13d5cf10d4a6998f8044cf32c19f92fd6a47ea52a"
    ["1.13.1/arm64"]="857fc135a79abdfeb377a40463dfa0185f8776797ba81af8c181fc30501b53a1b940f06d6992fa0286d58cfd1ff3db1e27a0a732df417997a7cf3e155e80c682"
    ["1.13.0/amd64"]="0344d19b9bc27d9612458187ee99f5ea35ddf8935b6880e8e91a2260e932ab6dc0a4478ae4fc5a33c1d9fcbb52677070a64bb4d2462bc01800fa96f2e5a515e8"
    ["1.13.0/arm64"]="f882e76754fcb38aabe880a0bfa4fa51e7ecd3ec5471f5dc25d4fc56c35c79f3c9600bb623427f01ad35bc2fc08ebe3e20929a5db8a7f3be18565e850553b3be"
    ["1.12.1/amd64"]="b2b17218dbe42c13559239a07477661a1937c7a1ba27a73d6e5302a771a613758a5497e5759f133b8528a2b730f1bc8d186ddcb300bf55238bb7d71457c2ff8a"
    ["1.12.1/arm64"]="8a038e65c979a22591aa80dc252a98f3157e86cafcc637693bc9d00731b3efe0e2d7b60d81f4d433fcaa2d66193e6c0a7f7571ff5fb6e3c4d8516fafc021ecef"
    ["1.12.0/amd64"]="5f1462c28c9b10be618c3e23cdff7e7a772a469d50de84602686f7286cb492bf0163b35204655aa1aba26115f095e37618c7f4a6c57edcabe29ad0483dba056b"
    ["1.12.0/arm64"]="9128bce4defb2f571881d6e3cb2cf6a3e39ae4ec01cea34f3d0c7fb824757dfff4d34b545cdf5acf607af6a21cbb3ff09cbd8ca1c692af7b5b38af3ad67e7353"
    ["1.11.1/amd64"]="9762f4d69a600cf8c4cda4d700ba009c474041239d2e533ec99cba6268748228a3bfa60f89982c46b1e5d61492f2c88c0a65cf6a2b91e6ad95df1c8304619076"
    ["1.11.1/arm64"]="36f261c292f2f8bd7cd34d80d3f5bb1f212d2141dff03ad6e1d4589da5770846149727d59d01dde7373cd0c3f3a57de4ca29c216b28d7eae5a5368f699ace892"
    ["1.11.0/amd64"]="56ce88fd3772848a128314d79ef7b24612a36a9310882e67c2514cb30ea7b04226af6a8cd63b58a3fb48756291922b67c5bc83645f20a3fdb8e2cfde02d8e086"
    ["1.11.0/arm64"]="56539c39f45723dd15104b0d72af8a557ceca0e4b70cfb696a6cbd5a23df393978a9ec32cb3121ff311d92d88e381db3c526f230274b61cfe6aee03365dad970"
    ["1.10.1/amd64"]="93511340b519a5e514989af0808e2df283acbfaad2b978b84076924adecc5bc379a73f8bf27fe5e1e2dd76c81235ced1bda240b524db84c647b997881a43bee0"
    ["1.10.1/arm64"]="ac164553d6615a235e436890a416173a1d8771ed7874667ed018ca0021c20eb7d1b03e7fde4dab50ecd9a1b910244d07c6e0a2c96c39feb80062b047b2241eac"
    ["1.10.0/amd64"]="80a1d2a0b02cbdf4366aaa20ef4b952a8c7fa0f363092b4b5e92eac2aec6b068f569e319557eaa96cddf2fc7498801ebbc24b30b6f01cc1b4a45e896042f34e3"
    ["1.10.0/arm64"]="9741d456801892eece37d208702a2e131d3405ac3521112387a3770ed2e2e079bdc7b60786d71e69fa3cd4719731e525e7e6faac4694f5a4dadf6a6a2becc059"
    ["1.9.0/amd64"]="cba86c261f5a814677b2cd00aecfe4eb82e4d83fad5cf9534672ec29a05414d9ff1dca110370bf988879e06e741cdbfb471c71292e792cf5d22d6d888cc68f14"
    ["1.9.0/arm64"]="aea4c78fdfe45b5bc35bba6c6f7caf891d060e9574c78ffe2de0fc6756598ded6a52e1e11464897ea325fbbd735aa45aeafbd2b978d8e42ac963e50d96cf4bdf"
    ["1.8.0/amd64"]="08c79f4c353bab035d391d98cab4f1a86cc3dd36961d2f492e7f61d6fe7ee7e56a4c42176e229ca4c2aa77b93a606b37c8f796ac98dfcc5ff46eed8886e99101"
    ["1.7.2/amd64"]="cd86a44102451a787a2161394c708878d753babf2e3490d0c2b0da7c502507f415cf52d989809089fa3144dc4bec357625ecad1875580256c83e8b47e952be3e"
    ["1.7.1/amd64"]="729eb5cad37942a6f223bd406bd89d897a697819f2d4392b32c13f23b79623f4f09d360a47b3af2796134c863e59feb452f1b9828fe90d7ab2eda3de6660b7ac"
    # Version 1.7.0 was not released correctly.
    ["1.6.0/amd64"]="4d4612c2bc589cdf0e7eade85b7740ba8967519828ed28ca97a250b29e08c9228b7b23d8d7cf6c4c09b2c2dea94052c4dd4c3ed63db45773a03088ff0a45a0a0"
    ["1.5.2/amd64"]="863173754b45a6edb3444f9951f983589eecf0846da20df61c59d66d3cf9416a5ed1a91a8eb490bf917528b178b30f2d739cb041b6d0d485d372741542a20951"
    ["1.5.1/amd64"]="b3862ddbef2998d6d2328c1c08376968aeb12b27ae0965a197d7586f0421352e50b72fee4a7bca34c2ae467b886e4bc607d9a3e45ac3a9f74cb4fe0806074c77"
    ["1.5.0/amd64"]="43bae563588becdf14349783af7b18fa95eea8816b5f8a885c44d686413f71455a3d687d783b76058d8f0b98e4d4fab57b06e7dd24da861c6d195393876643e3"
    ["1.4.1/amd64"]="bee4cb0bfd7752c103c06d6eb5c8f7747c641bf975f1a389fcdc71024cc009158c4c47ec313be37c23847464ad901fd26580570512f5ed64730b7e403702e9c8"
    ["1.4.0/amd64"]="bc5aed94679d2396804182ff6da3620ca251fbca17184e6efbb9f3747411c7ea850f8bcbae7f5484aac91ec35b20c1ca85b396f213961dcc1f2a5150fa45f1fe"
    ["1.3.1/amd64"]="720b2e0b70c69192277327f393b7da2880f7944117eea5eab78026fa5c62b133006c2ae8a4a33898b115696f92c8b2f2af58a25d62279f1f41fa155a689909bf"
    ["1.3.0/amd64"]="7a6e947abb5bced117fd25195fc30ae67e3d505d3f6ec91f0a386620c5338ece1cb9cdde4a45f96b66b09a318981592b85e37da2e11c5dea73e16386d7f105e0"
    ["1.2.1/amd64"]="da03d28c448b0a83037ae9c05d7ba48c177f5f3272cb9ddb0e53c2ad363fe7216964fd53f91734466d1275115b170cd5547969ab8151f97e52a55370bd979fe0"
    ["1.2.0/amd64"]="cf5e2f63e7790dcc01795a00bd10c84245ac28a280fe79e88fc8f418c60ba714aec6d0078a0a7ee42e72b33ce6cc4b7bc8bcd3b2f3a37dfcc03d73237079dc04"
    ["1.1.0/amd64"]="c4a8f1703960d6d83b7548536bc3df046c472bb932e910038f38f8b6f12146603d3f58bf601d2556f25250dc754852b3ecb84838557439a68107714003325fc2"
    ["1.0.0/amd64"]="f8480a81448ff59d028bb1f11074905d3f50608a2b6a332300d5e31c0520da4bd299171b91bc1acb55791c698700ca4fce9d4a561e26bca88c5e48ea24890fb0"
)
# <<< checksum table <<<

orb_install_main
