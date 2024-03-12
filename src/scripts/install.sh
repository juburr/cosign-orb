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
PARAM_VERSION=$(expand_circleci_env_vars "${PARAM_VERSION}")

# Check if the cosign tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f cosign.tar.gz ]]; then
    tar xzf cosign.tar.gz
fi

# If there was no cache hit, go ahead and re-download the binary.
# Tar it up to save on cache space used.
if [[ ! -f cosign-linux-amd64 ]]; then
    wget "https://github.com/sigstore/cosign/releases/download/v${PARAM_VERSION}/cosign-linux-amd64"
    tar czf cosign.tar.gz cosign-linux-amd64
fi

# A cosign binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. Move it to an appropriate bin directory and mark it
# as executable.
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign