#!/bin/bash

# Shared image reference helpers. Commands load this file through an
# environment variable (see sign.yml and attest.yml) and eval it, so it
# must only define functions.
#
# resolve_image_uri_digest prints REPOSITORY@sha256:<hex> for a reference:
#   - A reference that already names a sha256 digest keeps that digest. The
#     digest is checked against the registry, and a digest the registry does
#     not have is an error.
#   - Otherwise the tag is resolved to a digest. A colon is a tag separator
#     only in the last path component, so a registry port is kept:
#       localhost:5000/ns/app:1.0 -> localhost:5000/ns/app
#
# Every failure is fatal: the function returns non-zero and prints nothing on
# stdout. Progress and errors go to stderr.

IMAGE_REF_SHA256_PATTERN='^sha256:[0-9a-f]{64}$'

image_ref_log() {
    printf '%s\n' "$*" >&2
}

# Sets IMAGE_REF_REPOSITORY, IMAGE_REF_TAG and IMAGE_REF_DIGEST for a reference.
parse_image_ref() {
    local ref="$1"
    local name last

    IMAGE_REF_REPOSITORY=""
    IMAGE_REF_TAG=""
    IMAGE_REF_DIGEST=""

    if [[ -z "${ref}" ]]; then
        image_ref_log "ERROR: The image reference is empty."
        return 1
    fi
    if [[ "${ref}" == *[[:space:]]* ]]; then
        image_ref_log "ERROR: The image reference '${ref}' contains whitespace."
        return 1
    fi

    name="${ref}"
    if [[ "${ref}" == *@* ]]; then
        name="${ref%@*}"
        IMAGE_REF_DIGEST="${ref##*@}"
        if [[ "${name}" == *@* ]]; then
            image_ref_log "ERROR: The image reference '${ref}' contains more than one '@'."
            return 1
        fi
        # go-containerregistry, which Cosign uses to parse references, only
        # accepts sha256 digests with lowercase hex.
        if [[ ! "${IMAGE_REF_DIGEST}" =~ ${IMAGE_REF_SHA256_PATTERN} ]]; then
            image_ref_log "ERROR: '${IMAGE_REF_DIGEST}' in '${ref}' is not a sha256 digest (sha256: followed by 64 lowercase hex characters)."
            return 1
        fi
    fi

    last="${name##*/}"
    if [[ "${last}" == *:* ]]; then
        IMAGE_REF_TAG="${last##*:}"
        name="${name%:*}"
        if [[ -z "${IMAGE_REF_TAG}" ]]; then
            image_ref_log "ERROR: The image reference '${ref}' has an empty tag."
            return 1
        fi
    fi

    last="${name##*/}"
    if [[ -z "${name}" || -z "${last}" || "${last}" == *:* ]]; then
        image_ref_log "ERROR: Could not parse a repository name from '${ref}'."
        return 1
    fi

    IMAGE_REF_REPOSITORY="${name}"
    return 0
}

# Docker reports Docker Hub repositories by their short names (ubuntu,
# org/app). Expand a repository to docker.io/library/ubuntu form so names
# can be compared.
normalize_repository() {
    local repo="$1"
    local first="${repo%%/*}"

    if [[ "${repo}" != */* ]] || [[ "${first}" != *.* && "${first}" != *:* && "${first}" != "localhost" ]]; then
        repo="docker.io/${repo}"
    fi
    if [[ "${repo}" == index.docker.io/* ]]; then
        repo="docker.io/${repo#index.docker.io/}"
    fi
    if [[ "${repo}" == docker.io/* && "${repo#docker.io/}" != */* ]]; then
        repo="docker.io/library/${repo#docker.io/}"
    fi
    printf '%s\n' "${repo}"
}

# Tools print either "sha256:..." or "registry/name@sha256:...", sometimes
# with surrounding whitespace.
normalize_digest_output() {
    local raw="$1"
    raw="${raw//$'\r'/}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ "${raw}" == *@* ]]; then
        raw="${raw##*@}"
    fi
    printf '%s' "${raw}"
}

# Prints the digest docker recorded for the requested repository. RepoDigests
# lists one entry per repository the image was pulled from or pushed to, in no
# order that matches the request, so index 0 can belong to another registry.
docker_repo_digest() {
    local ref="$1"
    local repository="$2"
    local wanted entries entry entry_repo digest found=""

    wanted="$(normalize_repository "${repository}")"
    if ! entries="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${ref}")"; then
        image_ref_log "ERROR: docker image inspect failed for '${ref}'."
        return 1
    fi

    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        entry_repo="${entry%@*}"
        digest="${entry##*@}"
        if [[ "$(normalize_repository "${entry_repo}")" != "${wanted}" ]]; then
            continue
        fi
        if [[ -n "${found}" && "${found}" != "${digest}" ]]; then
            image_ref_log "ERROR: Docker recorded more than one digest for ${repository}: ${found} and ${digest}."
            image_ref_log "Sign by digest (repository@sha256:...) or install crane so the registry can be read directly."
            return 1
        fi
        found="${digest}"
    done <<< "${entries}"

    if [[ -z "${found}" ]]; then
        image_ref_log "ERROR: Docker has no digest recorded for ${repository}."
        image_ref_log "  RepoDigests: $(printf '%s' "${entries}" | tr '\n' ' ')"
        image_ref_log "Docker only records a digest after the image is pushed to, or pulled from, that repository."
        return 1
    fi
    printf '%s\n' "${found}"
}

resolve_image_uri_digest() {
    local ref="$1"
    local digest err_file

    if ! parse_image_ref "${ref}"; then
        return 1
    fi
    image_ref_log "  Repository: ${IMAGE_REF_REPOSITORY}"
    if [[ -n "${IMAGE_REF_TAG}" ]]; then
        image_ref_log "  Tag: ${IMAGE_REF_TAG}"
    fi
    if [[ -n "${IMAGE_REF_DIGEST}" ]]; then
        image_ref_log "  Requested digest: ${IMAGE_REF_DIGEST}"
    fi

    err_file="$(mktemp)"

    if command -v crane > /dev/null 2>&1; then
        image_ref_log "  Tool: crane"
        # A crane failure is fatal. Falling back to docker could pick up a
        # stale local image and sign a digest the registry no longer serves.
        if ! digest="$(crane digest "${ref}" 2> "${err_file}")"; then
            image_ref_log "ERROR: crane digest failed for '${ref}'."
            cat "${err_file}" >&2
            rm -f "${err_file}"
            return 1
        fi
        digest="$(normalize_digest_output "${digest}")"
    elif command -v docker > /dev/null 2>&1; then
        image_ref_log "  Tool: docker"
        if [[ -n "${IMAGE_REF_DIGEST}" ]]; then
            digest="${IMAGE_REF_DIGEST}"
        else
            if docker image inspect "${ref}" > /dev/null 2> "${err_file}"; then
                image_ref_log "  The image exists locally."
            elif grep -qi "no such image" "${err_file}"; then
                image_ref_log "  The image does not exist locally. Pulling ${ref}..."
                if ! docker pull "${ref}" >&2 2> "${err_file}"; then
                    image_ref_log "ERROR: docker pull failed for '${ref}'."
                    cat "${err_file}" >&2
                    rm -f "${err_file}"
                    return 1
                fi
            else
                image_ref_log "ERROR: docker image inspect failed for '${ref}'."
                cat "${err_file}" >&2
                rm -f "${err_file}"
                return 1
            fi
            if ! digest="$(docker_repo_digest "${ref}" "${IMAGE_REF_REPOSITORY}")"; then
                rm -f "${err_file}"
                return 1
            fi
        fi

        # Docker's recorded digest describes local content. After re-pushing a
        # pulled multi-platform image it can name a digest the target registry
        # never received, so confirm the registry serves it.
        image_ref_log "  Confirming ${IMAGE_REF_REPOSITORY}@${digest} exists in the registry..."
        if ! docker pull --quiet "${IMAGE_REF_REPOSITORY}@${digest}" > /dev/null 2> "${err_file}"; then
            image_ref_log "ERROR: ${IMAGE_REF_REPOSITORY}@${digest} could not be pulled from the registry."
            cat "${err_file}" >&2
            image_ref_log "Install crane to read digests from the registry directly, or sign by a digest the registry serves."
            rm -f "${err_file}"
            return 1
        fi
    else
        image_ref_log "ERROR: This orb requires that either crane or docker be installed."
        rm -f "${err_file}"
        return 1
    fi
    rm -f "${err_file}"

    if [[ ! "${digest}" =~ ${IMAGE_REF_SHA256_PATTERN} ]]; then
        image_ref_log "ERROR: '${digest}' returned for '${ref}' is not a sha256 digest."
        return 1
    fi
    if [[ -n "${IMAGE_REF_DIGEST}" && "${digest}" != "${IMAGE_REF_DIGEST}" ]]; then
        image_ref_log "ERROR: The registry returned ${digest} for '${ref}', not the requested ${IMAGE_REF_DIGEST}."
        return 1
    fi

    printf '%s@%s\n' "${IMAGE_REF_REPOSITORY}" "${digest}"
}
