#!/bin/bash

# This script is intended to sign container images the traditional way -- within a private
# organization with a pre-generated key file. E.g., at this time it doesn't support keyless
# signing, transparency log uploads to Rekor, or other advanced features just yet.

set -e

# Check to see if there are any environment variables within another environment
# variable, and if so, expand them. This allows environment variables to be passed
# as arguments to CircleCI orbs, which often don't interpret those variables correctly.
# Although this function seems complex, it's safer than doing: VAR=$(eval echo "${VAR}")
# and is less susceptible to command injection.
#   - Supported: ${VARIABLE}
#   - Unsupported: $VARIABLE
expand_circleci_env_vars() {
    search_substring=${1}
    result=""

    regex="([^}]*)[$]\{([a-zA-Z_]+[a-zA-Z0-9_]*)\}(.*)"
    while [[ $search_substring =~ $regex ]]; do
        prefix=${BASH_REMATCH[1]}
        match=${BASH_REMATCH[2]}
        suffix=${BASH_REMATCH[3]}

        # if the environment variable exists, evaluate it, but
        # guard against infinite recursion. e.g., MYVAR="\$MYVAR"
        if [[ -n ${!match} ]] && [[ "${!match}" != "\${${match}}" ]]; then
            repaired="${prefix}${!match}"
            result="${result}${repaired}"
            search_substring="${suffix}"
        else
            result="${result}${prefix}"
            search_substring="${suffix}"
        fi
    done

    midpoint_result="${result}${search_substring}"
    search_substring="${result}${search_substring}"
    result=""
    env_var_present=false

    # Handle the non-squiggley brace syntax: $VARIABLE.
    regex="([^$]*)[$]([a-zA-Z_]+[a-zA-Z0-9_]*)(.*)"
    while [[ $search_substring =~ $regex ]]; do
        prefix=${BASH_REMATCH[1]}
        match=${BASH_REMATCH[2]}
        suffix=${BASH_REMATCH[3]}

        # if the environment variable exists, evaluate it, but
        # guard against infinite recursion. e.g., MYVAR="\$MYVAR"
        if [[ -n ${!match} ]] && [[ "${!match}" != "\$${match}" ]]; then
            repaired="${prefix}${!match}"
            result="${result}${repaired}"
            search_substring="${suffix}"
            env_var_present=true
        else
            # If completely unset and not just an empty value, just leave it be
            # to deal with inadequacies of aggressive mode. If the variable is
            # actually present, but has an empty value, replace it with "".
            if [[ -z ${!match+x} ]]; then
                result="${result}${prefix}\$${match}"
            else
                result="${result}${prefix}"
                env_var_present=true
            fi

            search_substring="${suffix}"
        fi
    done
    result="${result}${search_substring}"

    # If we can't find at least one environment variable, this field
    # may have been intended for some other purprose and just happened
    # to contain a question mark and resembled an environment variable.
    # Toss out anything we did in the second stage when this happens.
    if [[ $env_var_present != true ]]; then
        result=${midpoint_result}
    fi

    echo "${result}"
    return 0
}

# Ensure CircleCI environment variables can be passed in as orb parameters
PARAM_IMAGE=$(expand_circleci_env_vars "${PARAM_IMAGE}")
PARAM_PRIVATE_KEY=$(expand_circleci_env_vars "${PARAM_PRIVATE_KEY}")
PARAM_PASSWORD=$(expand_circleci_env_vars "${PARAM_PASSWORD}")

# Cleanup makes a best effort to destroy all secrets.
cleanup_secrets() {
    echo "Cleaning up secrets..."
    shred -vzu -n 10 cosign.key 2> /dev/null || true
    unset PARAM_PRIVATE_KEY
    unset PARAM_PASSWORD
    unset COSIGN_PASSWORD
    echo "Secrets destroyed."
}

# Verify Cosign version is supported
COSIGN_VERSION=$(cosign version --json 2>&1 | jq -r '.gitVersion' | cut -c2-)
COSIGN_MAJOR_VERSION=$(echo "${COSIGN_VERSION}" | cut -d '.' -f 1)
if [ "${COSIGN_MAJOR_VERSION}" != "1" ] && [ "${COSIGN_MAJOR_VERSION}" != "2" ]; then
    echo "Unsupported Cosign version: ${MAJOR_VERSION}"
    cleanup_secrets
    exit 1
fi
echo "Detected Cosign major version: ${COSIGN_MAJOR_VERSION}"

# Determine the image digest
echo "Determining image URI digest..."
IMAGE_URI_DIGEST=""
if command -v crane 1> /dev/null; then
    echo "  Tool: crane"
    # While docker inspect returns registry/image@sha256:hash, crane simply returns
    # sha256:hash. We need to add the registry/image@ prefix ourselves.
    DIGEST=$(crane digest "${PARAM_IMAGE}")
    IMAGE_WITHOUT_TAG=$(echo "${PARAM_IMAGE}" | cut -d ':' -f 1)
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
elif command -v docker 1> /dev/null; then
    echo "  Tool: docker"
    # When pushing a single image to multiple registries, docker inspect always returns
    # a registry/image@sha256:hash value with the first registry you attempted to use, even if
    # $PARAM_IMAGE is that of the second registry. Reconstruct the correct value ourselves.
    DIGEST_WITH_REGISTRY=$(docker inspect --format='{{index .RepoDigests 0}}' "${PARAM_IMAGE}")
    DIGEST=$(echo "${DIGEST_WITH_REGISTRY}" | cut -d '@' -f 2)
    IMAGE_WITHOUT_TAG=$(echo "${PARAM_IMAGE}" | cut -d ':' -f 1)
    IMAGE_URI_DIGEST="${IMAGE_WITHOUT_TAG}@${DIGEST}"
else
    echo "This orb requires that either crane or docker be installed."
    cleanup_secrets
    exit 1
fi
echo "  Image URI Digest: ${IMAGE_URI_DIGEST}"

# Load the private key, normally a base64 encoded secret within a CircleCI context
# Note that a Cosign v2 key used with Cosign v1 may throw: unsupported pem type: ENCRYPTED SIGSTORE PRIVATE KEY
echo "${PARAM_PRIVATE_KEY}" | base64 --decode > cosign.key
echo "Wrote private key: cosign.key"

# Load the password into COSIGN_PASSWORD, preventing the "cosign sign" command from prompting
# for a password in the CI pipeline.
export COSIGN_PASSWORD="${PARAM_PASSWORD}"

# Sign the image using its digest
echo "Signing ${IMAGE_URI_DIGEST}..."
if [ "${COSIGN_MAJOR_VERSION}" == "1" ]; then
    cosign sign --key cosign.key --no-tlog-upload "${IMAGE_URI_DIGEST}"
else
    cosign sign --key cosign.key --tlog-upload=false "${IMAGE_URI_DIGEST}"
fi

# Cleanup before exiting
cleanup_secrets
