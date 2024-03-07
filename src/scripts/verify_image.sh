#!/bin/bash

set -e

# Use parameter expansion to ensure CircleCI environment variables can be passed in as orb parameters
expand_env_var() {
    if [[ "${1}" =~ ^\$\{(.*)\}$ ]] || [[ "${1}" =~ ^\$(.*)$ ]]; then
        INNER_ENV_VAR="${BASH_REMATCH[1]}"
        VALUE="${!INNER_ENV_VAR}"
        if [[ -n "${VALUE}" ]]; then
            echo "${VALUE}"
            return 0
        fi
    fi
    echo "${1}"
}

PARAM_IMAGE=$(expand_env_var "${PARAM_IMAGE}")
PARAM_PUBLIC_KEY=$(expand_env_var "${PARAM_PUBLIC_KEY}")

# Verify Cosign version is supported
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-)
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ]; then
    echo "Unsupported Cosign version: ${MAJOR_VERSION}"
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Load public key, normally a base64 encoded secret within a CircleCI context
echo "${PARAM_PUBLIC_KEY}" | base64 --decode > cosign.pub

# Verify image signature using the public key
echo "Verifying cosign signature for ${PARAM_IMAGE}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign verify --key cosign.pub "${PARAM_IMAGE}"
else
    cosign verify --private-infrastructure=true --key cosign.pub "${PARAM_IMAGE}"
fi

# Cleanup
rm cosign.pub
