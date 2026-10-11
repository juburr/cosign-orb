#!/bin/bash

# Convenience script, not used directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh. Prints one entry per supported architecture.
#
# Each binary's keyless Sigstore signature is verified against the
# Cosign release identity before its checksum is printed, so a local
# cosign is required. A binary that cannot be verified is reported
# and gets no entry.

set -e
set +o history

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi
if ! command -v cosign > /dev/null; then
  echo "cosign is required to verify the release signatures."
  exit 1
fi

IDENTITY="keyless@projectsigstore.iam.gserviceaccount.com"
ISSUER="https://accounts.google.com"
BASE_URL="https://github.com/sigstore/cosign/releases/download/v${VERSION}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
cd "${WORK_DIR}"

# Newer releases publish a Sigstore bundle per binary; older ones publish a
# keyless signature and certificate. Download output is suppressed for
# readability; re-enable it if you need to debug anything.
for ARCH in amd64 arm64; do
  ASSET="cosign-linux-${ARCH}"
  if ! wget -q "${BASE_URL}/${ASSET}" -O "${ASSET}"; then
    echo "# v${VERSION} has no ${ASSET} release asset" >&2
    continue
  fi
  if wget -q "${BASE_URL}/${ASSET}.sigstore.json" -O "${ASSET}.sigstore.json"; then
    VERIFY_ARGS=(--bundle "${ASSET}.sigstore.json")
  elif wget -q "${BASE_URL}/${ASSET}-keyless.sig" -O "${ASSET}.sig" && \
       wget -q "${BASE_URL}/${ASSET}-keyless.pem" -O "${ASSET}.pem"; then
    VERIFY_ARGS=(--signature "${ASSET}.sig" --certificate "${ASSET}.pem")
  else
    echo "# v${VERSION} ${ASSET}: no keyless signature published, skipped" >&2
    continue
  fi
  if ! cosign verify-blob "${VERIFY_ARGS[@]}" \
      --certificate-identity "${IDENTITY}" --certificate-oidc-issuer "${ISSUER}" \
      "${ASSET}" > /dev/null 2>&1; then
    echo "# v${VERSION} ${ASSET}: signature did not verify, skipped" >&2
    continue
  fi
  CHECKSUM=$(sha512sum "${ASSET}" | awk '{ print $1 }')
  echo "[\"${VERSION}/${ARCH}\"]=\"${CHECKSUM}\""
done
