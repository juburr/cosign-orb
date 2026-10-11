#!/bin/bash

# Shared signature storage format helpers. Commands load this file through an
# environment variable and eval it, so it must only define functions.
#
# bundle_format selects how signatures and attestations are stored:
#   auto    No format flags. The installed Cosign's default applies: legacy for
#           Cosign 1 and 2, Sigstore bundles for Cosign 3.
#   bundle  One Sigstore bundle per signature or attestation, stored as an OCI
#           referrer of the subject (--new-bundle-format).
#   legacy  Signature and attestation images under the sha256-<hex>.sig and
#           sha256-<hex>.att tags.
#
# Every function sets BUNDLE_FORMAT_FLAGS, and returns non-zero after printing
# an error when the installed Cosign cannot honor the requested format.

bundle_format_log() {
    printf '%s\n' "$*" >&2
}

validate_bundle_format() {
    case "$1" in
        auto | bundle | legacy) return 0 ;;
    esac
    bundle_format_log "ERROR: bundle_format must be auto, bundle or legacy, not '$1'."
    return 1
}

# Cosign 3 hides the deprecated --new-bundle-format flag from --help but still
# accepts it. Cosign 2 added it to attest, verify and verify-attestation in
# 2.5.0, and to sign in 2.6.0. In 2.5.x, verify accepts the flag but still
# reads only legacy signatures, so bundle support for image signatures is
# checked on sign (see verify_format_flags).
cosign_has_bundle_flag() {
    local major="$1"
    local subcommand="$2"
    local help

    case "${major}" in
        3) return 0 ;;
        2)
            # Read the whole help text first. Piping into grep -q can end the
            # pipeline early and fail it under pipefail.
            help="$(cosign "${subcommand}" --help 2>&1)" || true
            [[ "${help}" == *"--new-bundle-format"* ]]
            return
            ;;
    esac
    return 1
}

# Returns 0 when VERSION (for example 2.6.5 or 2.6.5-rc.1) is at least MINIMUM.
# An unparsable VERSION returns 0, so callers take the stricter path.
cosign_version_at_least() {
    local version="${1%%[-+]*}"
    local minimum="$2"
    local v_major v_minor v_patch m_major m_minor m_patch

    if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    IFS=. read -r v_major v_minor v_patch <<< "${version}"
    IFS=. read -r m_major m_minor m_patch <<< "${minimum}"
    if (( v_major != m_major )); then
        (( v_major > m_major ))
        return
    fi
    if (( v_minor != m_minor )); then
        (( v_minor > m_minor ))
        return
    fi
    (( v_patch >= m_patch ))
}

# Flags for cosign sign or attest with a private key and no transparency log.
# signing_config is the empty signing config file Cosign 3 uses for that.
private_key_sign_flags() {
    local major="$1"
    local subcommand="$2"
    local format="$3"
    local signing_config="$4"

    BUNDLE_FORMAT_FLAGS=()
    validate_bundle_format "${format}" || return 1

    case "${major}" in
        1)
            if [[ "${format}" == "bundle" ]]; then
                bundle_format_log "ERROR: Cosign 1 cannot write Sigstore bundles. Use bundle_format auto or legacy."
                return 1
            fi
            BUNDLE_FORMAT_FLAGS=(--no-tlog-upload)
            ;;
        2)
            BUNDLE_FORMAT_FLAGS=(--tlog-upload=false)
            if [[ "${format}" == "bundle" ]]; then
                if ! cosign_has_bundle_flag 2 "${subcommand}"; then
                    bundle_format_log "ERROR: This Cosign 2 release cannot write Sigstore bundles with 'cosign ${subcommand}'."
                    bundle_format_log "bundle_format bundle needs Cosign 2.6.0 or later for sign_image, and 2.5.0 or later for attest."
                    return 1
                fi
                # Not --signing-config: with one, Cosign 2.6.5 attest labels the
                # referrer with the signature predicate type instead of the
                # attestation's.
                BUNDLE_FORMAT_FLAGS+=(--new-bundle-format=true)
            elif [[ "${format}" == "legacy" ]] && cosign_has_bundle_flag 2 "${subcommand}"; then
                BUNDLE_FORMAT_FLAGS+=(--new-bundle-format=false)
            fi
            ;;
        3)
            case "${format}" in
                auto) BUNDLE_FORMAT_FLAGS=(--signing-config="${signing_config}") ;;
                bundle) BUNDLE_FORMAT_FLAGS=(--new-bundle-format=true --signing-config="${signing_config}") ;;
                legacy)
                    # Cosign 3 rejects a signing config with the legacy format, so
                    # the transparency log is turned off with deprecated flags.
                    BUNDLE_FORMAT_FLAGS=(--new-bundle-format=false --use-signing-config=false --tlog-upload=false)
                    ;;
            esac
            ;;
        *)
            bundle_format_log "ERROR: Unsupported Cosign major version: ${major}"
            return 1
            ;;
    esac
}

# Flags for keyless cosign sign or attest. Keyless signing can pin the format
# each Cosign major writes by default; switching away from it is not supported.
keyless_sign_flags() {
    local major="$1"
    local subcommand="$2"
    local format="$3"
    local default_format="legacy"

    BUNDLE_FORMAT_FLAGS=()
    validate_bundle_format "${format}" || return 1
    if [[ "${format}" == "auto" ]]; then
        return 0
    fi

    if [[ "${major}" == "3" ]]; then
        default_format="bundle"
    fi
    if [[ "${format}" != "${default_format}" ]]; then
        bundle_format_log "ERROR: Keyless signing with bundle_format ${format} is not supported with Cosign ${major}."
        bundle_format_log "Use bundle_format auto or ${default_format}, which is what Cosign ${major} writes for keyless signing."
        return 1
    fi

    case "${major}" in
        2)
            if cosign_has_bundle_flag 2 "${subcommand}"; then
                BUNDLE_FORMAT_FLAGS=(--new-bundle-format=false)
            fi
            ;;
        3) BUNDLE_FORMAT_FLAGS=(--new-bundle-format=true) ;;
    esac
    return 0
}

# Flags for cosign verify or verify-attestation.
#
# Where Cosign can be limited to one format, BUNDLE_FORMAT_FLAGS does that and
# BUNDLE_FORMAT_COUNTER_FLAGS is empty. Two cases have no such switch:
#   - Cosign 3 falls back to legacy objects when no bundle is attached, even
#     with --new-bundle-format=true.
#   - Cosign 2.6.3 and later switch to bundles whenever any are attached, even
#     with --new-bundle-format=false. Earlier releases honor the flag.
# There, BUNDLE_FORMAT_COUNTER_FLAGS limits a second verification to the other
# format. The caller must fail if that second verification succeeds, because
# Cosign may then have used those objects for the first one.
verify_format_flags() {
    local major="$1"
    local subcommand="$2"
    local format="$3"
    local version="${4:-}"
    local capability="${subcommand}"

    BUNDLE_FORMAT_FLAGS=()
    BUNDLE_FORMAT_COUNTER_FLAGS=()
    validate_bundle_format "${format}" || return 1
    if [[ "${format}" == "auto" ]]; then
        return 0
    fi

    case "${major}" in
        1)
            # Cosign 1 only reads legacy objects.
            if [[ "${format}" == "bundle" ]]; then
                bundle_format_log "ERROR: Cosign 1 cannot read Sigstore bundles. Use bundle_format auto or legacy."
                return 1
            fi
            ;;
        2)
            # Cosign 2 reads bundle image signatures from 2.6.0, the release
            # that added --new-bundle-format to sign.
            if [[ "${subcommand}" == "verify" ]]; then
                capability="sign"
            fi
            if ! cosign_has_bundle_flag 2 "${capability}"; then
                # Older Cosign 2 releases only read legacy objects here.
                if [[ "${format}" == "bundle" ]]; then
                    bundle_format_log "ERROR: This Cosign 2 release cannot read Sigstore bundles with 'cosign ${subcommand}'."
                    bundle_format_log "bundle_format bundle needs Cosign 2.6.0 or later for verify_image, and 2.5.0 or later for verify_attestation."
                    return 1
                fi
                return 0
            fi
            if [[ "${format}" == "bundle" ]]; then
                BUNDLE_FORMAT_FLAGS=(--new-bundle-format=true)
            else
                BUNDLE_FORMAT_FLAGS=(--new-bundle-format=false)
                if cosign_version_at_least "${version}" 2.6.3; then
                    BUNDLE_FORMAT_COUNTER_FLAGS=(--new-bundle-format=true)
                fi
            fi
            ;;
        3)
            if [[ "${format}" == "legacy" ]]; then
                BUNDLE_FORMAT_FLAGS=(--new-bundle-format=false)
            else
                BUNDLE_FORMAT_FLAGS=(--new-bundle-format=true)
                BUNDLE_FORMAT_COUNTER_FLAGS=(--new-bundle-format=false)
            fi
            ;;
        *)
            bundle_format_log "ERROR: Unsupported Cosign major version: ${major}"
            return 1
            ;;
    esac
    return 0
}

# Cosign errors that mean nothing in the requested format verified, as
# opposed to a registry, network or trust material failure.
BUNDLE_FORMAT_NOT_VERIFIED_PATTERN='no signatures found|no matching signatures|no matching attestations|none of the attestations matched the predicate type|no valid bundles exist in registry'

# Prints IMAGE pinned to the digest its tag points at now, so the first and
# second verifications inspect the same image even if the tag moves between
# them. A digest reference is printed unchanged. cosign triangulate resolves
# the tag the same way verification does, in Cosign 1, 2 and 3.
pin_image_to_digest() {
    local image="$1"
    local out repository last

    if [[ "${image}" == *@sha256:* ]]; then
        printf '%s\n' "${image}"
        return 0
    fi
    if ! out="$(cosign triangulate --type signature "${image}")"; then
        bundle_format_log "ERROR: Could not resolve ${image} to a digest."
        return 1
    fi
    if [[ ! "${out}" =~ :sha256-([0-9a-f]{64})\.sig$ ]]; then
        bundle_format_log "ERROR: Could not read a digest for ${image} from '${out}'."
        return 1
    fi
    # A colon is a tag separator only in the last path component, so a
    # registry port is kept.
    repository="${image}"
    last="${repository##*/}"
    if [[ "${last}" == *:* ]]; then
        repository="${repository%:*}"
    fi
    printf '%s@sha256:%s\n' "${repository}" "${BASH_REMATCH[1]}"
}

# Runs the second verification described above when one is needed. Pass the
# cosign command without the image, then the image as the last argument.
# Returns non-zero when objects in the other format verify, or when the
# second verification fails for any reason other than finding nothing that
# verifies: the result is then unknown, so the step fails closed.
check_other_format_does_not_verify() {
    local format="$1"
    shift
    local image="${!#}"
    local args=("${@:1:$#-1}")
    local other="legacy .sig/.att objects"
    local err_file

    if [[ ${#BUNDLE_FORMAT_COUNTER_FLAGS[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "${format}" == "legacy" ]]; then
        other="Sigstore bundles"
    fi

    bundle_format_log "Checking that no ${other} verify for ${image}, since Cosign cannot be limited to ${format} objects here..."
    err_file="$(mktemp)"
    if "${args[@]}" "${BUNDLE_FORMAT_COUNTER_FLAGS[@]}" "${image}" > /dev/null 2> "${err_file}"; then
        rm -f "${err_file}"
        bundle_format_log "ERROR: ${other} also verify for ${image}, so Cosign may not have used ${format} objects."
        bundle_format_log "The subject has signatures or attestations in both formats. Use bundle_format auto to accept either."
        return 1
    fi
    if ! grep -qE "${BUNDLE_FORMAT_NOT_VERIFIED_PATTERN}" "${err_file}"; then
        bundle_format_log "ERROR: Could not check whether ${other} verify for ${image}:"
        cat "${err_file}" >&2
        rm -f "${err_file}"
        return 1
    fi
    rm -f "${err_file}"
    bundle_format_log "  None verify. The result came from ${format} objects."
    return 0
}
