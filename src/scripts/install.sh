#!/bin/bash

set -e

# Read in orb parameters
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Check if the cosign tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f cosign.tar.gz ]]; then
    tar xzf cosign.tar.gz
fi

# If there was no cache hit, go ahead and re-download the binary.
# Tar it up to save on cache space used.
if [[ ! -f cosign-linux-amd64 ]]; then
    wget "https://github.com/sigstore/cosign/releases/download/v${VERSION}/cosign-linux-amd64"
    tar czf cosign.tar.gz cosign-linux-amd64
fi

# A cosign binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. Move it to an appropriate bin directory and mark it
# as executable.
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign