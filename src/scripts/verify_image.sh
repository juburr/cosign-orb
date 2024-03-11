#!/bin/bash

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

        if [[ -n ${!match} ]] && [[ "${!match}" != "\${${match}}" ]]; then
            repaired="${prefix}${!match}"
            result="${result}${repaired}"
            search_substring="${suffix}"
        else
            result="${result}${prefix}"
            search_substring="${suffix}"
        fi
    done

    # If we're not running in aggressive mode, we can go ahead
    # and return the result at this point
    if [[ "${AGGRESSIVE_MODE}" != "true" ]]; then
        echo "${result}${search_substring}"
        return 0
    fi

    search_substring="${result}"
    result=""

    # In aggressive mode we handle the non-squiggly brace syntax: $VARIABLE
    # This should not be done for fields expected to contain a question mark,
    # such as a name, description, or even a password.
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
        else
            result="${result}${prefix}"
            search_substring="${suffix}"
        fi
    done

    echo "${result}${search_substring}"
    return 0
}

# Ensure CircleCI environment variables can be passed in as orb parameters
PARAM_IMAGE=$(expand_circleci_env_vars "${PARAM_IMAGE}" true)
PARAM_PUBLIC_KEY=$(expand_circleci_env_vars "${PARAM_PUBLIC_KEY}" true)

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
