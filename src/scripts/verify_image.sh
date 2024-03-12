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
PARAM_PUBLIC_KEY=$(expand_circleci_env_vars "${PARAM_PUBLIC_KEY}")

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
