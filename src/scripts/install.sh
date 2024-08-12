#!/bin/bash

set -e

# Read in orb parameters
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}"
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Print command arguments for debugging purposes.
echo "Running Cosign installer..."
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for different versions of cosign-linux-amd64
declare -A sha512sums
sha512sums=(
    ["2.4.0"]="acf268337df43040e31f5d83628c0556a81edd2e7b91ff7640cb34862e5200fb7c313389001a0be4ee65a554ef225fcd9ab18e10bc2e3f5dba7effe2ff84d8bb"
    ["2.3.0"]="d5339dc2915c9078c15218557f8e5123b640ef4fe6b5fd402548b2c744c85d4f7549b1fcfb5712cd5dfc51bdb43253ea459e83bf00b435d03e81a6c0773835ec"
    ["2.2.4"]="1b2fcf9eeb03ffdb2b552b608dbc6c68f9a3be5dac1bda81ed8308fb116a17b04d5e7d72e5da7aa2025932db4c0d48967abeeac5b0056882b82cb897aa1eeb72"
    ["2.2.3"]="35584c00e10efc4a562e473ad37e24350aad9ce3bbc588f981d1ea79486848573c68d6bca8d6443db4d07a15d8ddfd57f4609c85247c0ff6c09fe8d0d3ef1b57"
    ["2.2.2"]="0877382b5121a12d25869104e9eb674799cbd393d2ec4e0e3c5e4cb55ea7ea6135b6966e75f317ea338a8d8a544e8cf1bdd01a06decb62df3679380dc24445c6"
    ["2.2.1"]="b47c77b57b08eafe252fb0a6d39d7bfda34b50cdfa554f5b358be97b2e5b540b7e9343d39a015c33399d16d76946d03f0cb8fc6f08cd65c397cc1e3a2293020a"
    ["2.2.0"]="4fdc69704625b686eae18964a8e9ba621d6d87b419f2adc8c7af09cc661ded6a4a5998cbeac1c106e261331097877ea6c56c6d9fb8b959bcf9df928f047ddd50"
    ["2.1.1"]="05e8403cd9b1da69d8778244dcadd81de4fb3e5177af1ae103a1d7b4d494be14c185c1b0de428e6e116c0016f79e5fa78c53d22a4b274bf7adb8fd089521789c"
    ["2.1.0"]="be2567ec629af1ab6243203d4c60fb4c343c21274a0585c92edaccbe70840de8a97bc25dce4730fb50cc3f2c7c1cbae1ec876626853160994f7b912d53df4ee1"
    ["2.0.2"]="6f077fb946223c2c452b222755e2891ebbc31e0166db120167a96f88eeb6f93f4e297eb1115a5bb03fedcc0bc46a5f2ad6eea3b127ba8bf7d72797565fed0eb4"
    ["2.0.1"]="f572d23e13849b7974ca5ae0ebc18f773b6cb6ff7a02237996720376105d7765a982a36f6b515ede20b5197b3d9576e74a73c5215a61cbd9818a0699c617b1d7"
    ["2.0.0"]="c11f645895fa7670bd7f1fbfd8763e9018a1b7cb8458585d3762d3df9a0b697bc84b6bc3b55c46cbf8882a8e76d4ebee06347e591a141498216ca75994b0d6b1"
    ["1.13.6"]="f775b9826876d5ddb92a1a73a394d89f74efd36ea05925a4db1ee206b3adf7238b8cb5c25d11d1a1abc30d4699adcd4459d28658c5d41ead3283363c3dc76164"
    # Versions 1.13.3, 1.13.4, and 1.13.5 were not released correctly.
    ["1.13.2"]="eccb284cc560974a853caee0650dba1b6da02c996dfe31637b13d6015710afdb7ce90314dc33e02f0291264be1289714c2e439c552b5207fd4b811ed3dea8eb9"
    ["1.13.1"]="cbbaf2a6fd20ad85fbe16b4710fced529547f9d3b6e1888194ba10588353cf80eba5d56502083190a7e99fd13d5cf10d4a6998f8044cf32c19f92fd6a47ea52a"
    ["1.13.0"]="0344d19b9bc27d9612458187ee99f5ea35ddf8935b6880e8e91a2260e932ab6dc0a4478ae4fc5a33c1d9fcbb52677070a64bb4d2462bc01800fa96f2e5a515e8"
    ["1.12.1"]="b2b17218dbe42c13559239a07477661a1937c7a1ba27a73d6e5302a771a613758a5497e5759f133b8528a2b730f1bc8d186ddcb300bf55238bb7d71457c2ff8a"
    ["1.12.0"]="5f1462c28c9b10be618c3e23cdff7e7a772a469d50de84602686f7286cb492bf0163b35204655aa1aba26115f095e37618c7f4a6c57edcabe29ad0483dba056b"
    ["1.11.1"]="9762f4d69a600cf8c4cda4d700ba009c474041239d2e533ec99cba6268748228a3bfa60f89982c46b1e5d61492f2c88c0a65cf6a2b91e6ad95df1c8304619076"
    ["1.11.0"]="56ce88fd3772848a128314d79ef7b24612a36a9310882e67c2514cb30ea7b04226af6a8cd63b58a3fb48756291922b67c5bc83645f20a3fdb8e2cfde02d8e086"
    ["1.10.1"]="93511340b519a5e514989af0808e2df283acbfaad2b978b84076924adecc5bc379a73f8bf27fe5e1e2dd76c81235ced1bda240b524db84c647b997881a43bee0"
    ["1.10.0"]="80a1d2a0b02cbdf4366aaa20ef4b952a8c7fa0f363092b4b5e92eac2aec6b068f569e319557eaa96cddf2fc7498801ebbc24b30b6f01cc1b4a45e896042f34e3"
    ["1.9.0"]="cba86c261f5a814677b2cd00aecfe4eb82e4d83fad5cf9534672ec29a05414d9ff1dca110370bf988879e06e741cdbfb471c71292e792cf5d22d6d888cc68f14"
    ["1.8.0"]="08c79f4c353bab035d391d98cab4f1a86cc3dd36961d2f492e7f61d6fe7ee7e56a4c42176e229ca4c2aa77b93a606b37c8f796ac98dfcc5ff46eed8886e99101"
    ["1.7.2"]="cd86a44102451a787a2161394c708878d753babf2e3490d0c2b0da7c502507f415cf52d989809089fa3144dc4bec357625ecad1875580256c83e8b47e952be3e"
    ["1.7.1"]="729eb5cad37942a6f223bd406bd89d897a697819f2d4392b32c13f23b79623f4f09d360a47b3af2796134c863e59feb452f1b9828fe90d7ab2eda3de6660b7ac"
    # Version 1.7.0 was not released correctly.
    ["1.6.0"]="4d4612c2bc589cdf0e7eade85b7740ba8967519828ed28ca97a250b29e08c9228b7b23d8d7cf6c4c09b2c2dea94052c4dd4c3ed63db45773a03088ff0a45a0a0"
    ["1.5.2"]="863173754b45a6edb3444f9951f983589eecf0846da20df61c59d66d3cf9416a5ed1a91a8eb490bf917528b178b30f2d739cb041b6d0d485d372741542a20951"
    ["1.5.1"]="b3862ddbef2998d6d2328c1c08376968aeb12b27ae0965a197d7586f0421352e50b72fee4a7bca34c2ae467b886e4bc607d9a3e45ac3a9f74cb4fe0806074c77"
    ["1.5.0"]="43bae563588becdf14349783af7b18fa95eea8816b5f8a885c44d686413f71455a3d687d783b76058d8f0b98e4d4fab57b06e7dd24da861c6d195393876643e3"
    ["1.4.1"]="bee4cb0bfd7752c103c06d6eb5c8f7747c641bf975f1a389fcdc71024cc009158c4c47ec313be37c23847464ad901fd26580570512f5ed64730b7e403702e9c8"
    ["1.4.0"]="bc5aed94679d2396804182ff6da3620ca251fbca17184e6efbb9f3747411c7ea850f8bcbae7f5484aac91ec35b20c1ca85b396f213961dcc1f2a5150fa45f1fe"
    ["1.3.1"]="720b2e0b70c69192277327f393b7da2880f7944117eea5eab78026fa5c62b133006c2ae8a4a33898b115696f92c8b2f2af58a25d62279f1f41fa155a689909bf"
    ["1.3.0"]="7a6e947abb5bced117fd25195fc30ae67e3d505d3f6ec91f0a386620c5338ece1cb9cdde4a45f96b66b09a318981592b85e37da2e11c5dea73e16386d7f105e0"
    ["1.2.1"]="da03d28c448b0a83037ae9c05d7ba48c177f5f3272cb9ddb0e53c2ad363fe7216964fd53f91734466d1275115b170cd5547969ab8151f97e52a55370bd979fe0"
    ["1.2.0"]="cf5e2f63e7790dcc01795a00bd10c84245ac28a280fe79e88fc8f418c60ba714aec6d0078a0a7ee42e72b33ce6cc4b7bc8bcd3b2f3a37dfcc03d73237079dc04"
    ["1.1.0"]="c4a8f1703960d6d83b7548536bc3df046c472bb932e910038f38f8b6f12146603d3f58bf601d2556f25250dc754852b3ecb84838557439a68107714003325fc2"
    ["1.0.0"]="f8480a81448ff59d028bb1f11074905d3f50608a2b6a332300d5e31c0520da4bd299171b91bc1acb55791c698700ca4fce9d4a561e26bca88c5e48ea24890fb0"
)

# Verfies that the SHA-512 checksum of a file matches what was in the lookup table
verify_checksum() {
    local file=$1
    local expected_checksum=$2

    actual_checksum=$(sha512sum "${file}" | awk '{ print $1 }')

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${expected_checksum}"

    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

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
# through cache or re-downloaded. First verify its integrity.
if [[ "${VERIFY_CHECKSUMS}" != "false" ]]; then
    EXPECTED_CHECKSUM=${sha512sums[${VERSION}]}
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        # If the version is in the table, verify the checksum
        verify_checksum "cosign-linux-amd64" "${EXPECTED_CHECKSUM}"
    else
        # If the version is not in the table, this means that a new version of Cosign
        # was released but this orb hasn't been updated yet to include its checksum in
        # the lookup table. Allow developers to configure if they want this to result in
        # a hard error, via "strict mode" (recommended), or to allow execution for versions
        # not directly specified in the above lookup table.
        if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
            echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
            echo "WARN: Skipping checksum verification..."
        else
            echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
            echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
            exit 1
        fi
    fi
else
    echo "WARN: Checksum validation is disabled. This is not recommended. Skipping..."
fi

# After verifying integrity, install it by moving it to
# an appropriate bin directory and marking it as executable.
mv cosign-linux-amd64 "${INSTALL_PATH}/cosign"
chmod +x "${INSTALL_PATH}/cosign"