#!/bin/bash

set -e

PARAM_IMAGE=$(eval echo "${PARAM_IMAGE}")
PARAM_PUBLIC_KEY=$(eval echo "${PARAM_PUBLIC_KEY}")

# Load public key, normally a base64 encoded secret within a CircleCI context
echo "${PARAM_PUBLIC_KEY}" | base64 --decode > cosign.pub

# Verify image signature using the public key
echo "Verifying cosign signature for ${PARAM_IMAGE}..."
cosign verify --key cosign.pub "${PARAM_IMAGE}"

rm cosign.pub