#!/bin/bash

set -e

PARAM_IMAGE=$(eval echo "${PARAM_IMAGE}")
PARAM_PRIVATE_KEY=$(eval echo "${PARAM_PRIVATE_KEY}")

# Load the private key, normally a base64 encoded secret within a CircleCI context
echo "${PARAM_PRIVATE_KEY}" | base64 --decode > cosign.key

# Sign the image using its digest
IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${PARAM_IMAGE}")
echo "Signing ${IMAGE_DIGEST}..."
cosign sign --key cosign.key "${IMAGE_DIGEST}"

# As an precautionary measure, destroy the private key at this point
shred -vzu -n 10 cosign.key
unset PARAM_PRIVATE_KEY