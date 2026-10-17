#!/bin/bash
#
# Writes the file the install command's cache key is computed from. It is
# identical in every juburr orb that installs a tool. The file names:
#
#   - the CPU, from uname -m, so amd64 and arm64 never share a cache;
#   - HOME, since a cache is restored to the absolute path it was saved from;
#   - the version with environment variables expanded, as install.sh expands
#     it, so a version given as ${VAR} gets a key of its own per value.
#
# Parameters arrive as PARAM_VERSION and ORB_CACHE_KEY_FILE.

set -euo pipefail

version=${PARAM_VERSION:-}
# The value is piped in on stdin: passed as an argument, a value starting
# with "-" would be parsed as a flag.
if command -v circleci > /dev/null 2>&1; then
    version=$(printf '%s' "${version}" | circleci env subst)
fi
# The file is written under a new name and renamed into place, so a file or
# symlink someone else left at its name in a shared /tmp is never written
# through. mv would move it into a directory, so that is refused.
tmp=$(mktemp "${ORB_CACHE_KEY_FILE}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
printf '%s\n%s\n%s\n' "$(uname -m)" "${HOME:-}" "${version#v}" > "${tmp}"
if [[ -d "${ORB_CACHE_KEY_FILE}" ]] || ! mv -f "${tmp}" "${ORB_CACHE_KEY_FILE}"; then
    echo "ERROR: Could not write ${ORB_CACHE_KEY_FILE}." >&2
    exit 1
fi
