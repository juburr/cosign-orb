# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a CircleCI Orb for Cosign, a signing and verification tool for container images. The orb simplifies installation and use of Cosign within CircleCI pipelines.

## Development Commands

CI runs automatically via CircleCI's orb-tools (lint, pack, review, shellcheck, publish).

Local validation:
- `circleci orb validate src/@orb.yml` - Validate orb syntax (requires CircleCI CLI)
- `yamllint .` - YAML linting (config: relaxed profile, max 200 char lines)
- `shellcheck src/scripts/*.sh` - Shell script linting
- `bash test/env_subst_test.sh` - Checks that scripts pass parameter values to `circleci env subst` on stdin (`printf '%s' "${PARAM_X}" | circleci env subst`); as an argument, a value starting with `-` is parsed as a CLI flag

### Local Development Environment

Developers on this project make a best effort to install all three major versions of Cosign for convenience in local development, testing, and viewing available commands:

| Binary | Version | Purpose |
|--------|---------|---------|
| `cosign` | v3.1.3 | Latest major version (default) |
| `cosign2` | v2.6.5 | Legacy v2 testing |
| `cosign1` | v1.13.6 | Legacy v1 testing |

### Reference Documentation

The official Cosign project is included as a git submodule at `./ref/cosign` for quick review of source code and documentation. This allows convenient access to Cosign's implementation details when developing version-specific functionality.

## Architecture

### Orb Structure

```
src/
├── @orb.yml           # Orb metadata and version
├── commands/          # YAML command definitions (install, sign, verify, attest, verify_attestation, sign_blob, verify_blob, generate_key_pair, check_oidc)
├── scripts/           # Bash implementations for each command
└── examples/          # Usage examples
```

### Commands

1. **install** - Downloads and installs Cosign with SHA-512 checksum verification
2. **sign** - Signs container images using base64-encoded private keys
3. **verify** - Verifies container image signatures
4. **attest** - Attaches attestations (SBOM, vulnerability reports) to images
5. **verify_attestation** - Verifies attestations on images

### Version Compatibility

Scripts handle Cosign v1, v2, and v3 with version-specific approaches for private infrastructure (no transparency log):
- v1: `--no-tlog-upload`
- v2: `--tlog-upload=false`
- v3: `--signing-config=<path>` with an empty signing config JSON (no Rekor/Fulcio/TSA services)

The v3 approach creates a minimal signing config file inline:
```json
{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}
```

`sign` and `attest` take a `bundle_format` parameter (`auto`, `bundle`, `legacy`); the flag mapping per Cosign version lives in `src/scripts/lib/bundle_format.sh`. Cosign 3 rejects `--signing-config` with the legacy format, so `legacy` on Cosign 3 uses `--new-bundle-format=false --use-signing-config=false --tlog-upload=false`. `verify` and `verify_attestation` take the same parameter; where Cosign cannot be limited to one format (bundle on Cosign 3, legacy on Cosign 2.6.3+), they also run a second verification limited to the other format, which must fail.

Shared shell helpers live in `src/scripts/lib/`. Commands pass them to the step through an environment variable (`SCRIPT_..._LIB: << include(scripts/lib/....sh) >>`) and the script `eval`s it. Unit tests for them are in `test/` and run in the `lint-pack` workflow.

Cosign 3.1 deprecates several flags the orb still passes (`--private-infrastructure`, `--tlog-upload`, `--fulcio-url`, `--rekor-url`, `--oidc-issuer`, `--new-bundle-format`, and the legacy blob `--output-signature` / `--output-certificate` / `--signature` flags). They remain registered and behave the same through 3.1.3. Removal is planned for v4, which will need a separate migration to `--bundle`, `--signing-config`, and `--insecure-ignore-tlog`.

### Key Format Compatibility

**Warning:** Cosign v1 and v2+ use incompatible key formats:
- v1: `ENCRYPTED COSIGN PRIVATE KEY`
- v2+: `ENCRYPTED SIGSTORE PRIVATE KEY`

Keys generated with v2/v3 cannot be used with v1 (error: `unsupported pem type: ENCRYPTED SIGSTORE PRIVATE KEY`). The CI pipeline generates v1-compatible keys dynamically for v1 integration tests.

### Checksum Verification

`src/scripts/install.sh` contains a lookup table of SHA-512 checksums for published Cosign releases, keyed by `"<version>/<arch>"` (`amd64` or `arm64`, detected from `uname -m`). install.sh follows the layout every juburr orb's install.sh shares: a tool definition, a shared install logic block that must stay identical across the orbs, and the checksum table. `test/install_test.sh` is the install contract test shared by the orbs. `src/scripts/install_hash.sh` prints new entries for both architectures after verifying each release binary's keyless signature. Three verification modes:
- `strict` (default): Fails if version not in lookup table
- `known_versions`: Warns but installs an unverified binary for unknown versions
- `false`: Skips verification (not recommended)

### Security Patterns

- No `sudo` usage - installs to user-owned directories
- Keys passed via environment variables (base64-encoded); credential parameters are `env_var_name`s, never literal secrets
- `generate_key_pair` uses the password already in the variable named by `password_env_var`, or generates a random one, and writes its exports to `$BASH_ENV` with `printf 'export %s=%q\n'` so no value can break or inject into later steps (`test/generate_key_pair_test.sh`)
- Key files (`cosign.key`, `cosign.pub`) are written to a private `mktemp -d` directory created under `umask 077`, never the working directory, where they would overwrite (and the cleanup would then shred) a project's own key files or follow a symlink. `generate_key_pair` runs `cosign generate-key-pair` inside that directory in a subshell. Keys are set to 0400, and the script's single EXIT trap shreds them with `shred -vzuf -n 10` and removes the directory (`test/key_files_test.sh`, `test/generate_key_pair_test.sh`)

### Shell conventions

Every script under `src/scripts/` except the shared install code follows the conventions all juburr orbs share; `test/shell_conventions_test.sh` (identical in every orb, never edit it) checks the mechanical ones:
- `#!/bin/bash`, then `set -euo pipefail` as the first command (libraries in `lib/` have no `set` line). Read optional and indirectly named variables as `${VAR:-}` / `${!name:-}`.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, because bash before 4.4 treats an empty array as unset under `-u` and the orb supports bash 4.0+ (`test/empty_arrays_test.sh`).
- No `set +o history`, never enable xtrace. Scripts that handle a key, password or token run `set +o xtrace` with a one-line comment.
- Messages start with `ERROR: ` or `WARN: ` and go to stderr, continuation lines included. Every non-zero exit prints an `ERROR:` line first.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`. `eval` only runs `"${..._LIB}"` / `"${..._SCRIPT}"`.
- Secrets never go on a command line. Secret and temporary files come from `mktemp`, are removed by the script's one EXIT trap, and never use fixed names.

## Key Files

- `.circleci/config.yml` - Main CI pipeline (lint, pack, review, shellcheck)
- `.circleci/test-deploy.yml` - Test and publish workflow
- `src/commands/*.yml` - Orb command definitions with parameters
- `src/scripts/*.sh` - Shell implementations

## CI Testing

### Test Registry (ttl.sh)

Integration tests use [ttl.sh](https://ttl.sh), a free ephemeral container registry that requires no authentication. Images are automatically deleted after the specified TTL.

**⚠️ SECURITY WARNING: ttl.sh is a third-party service outside our control.**
- **NEVER** include sensitive information, secrets, keys, or PII in test images
- **NEVER** assume images are truly ephemeral - they could be archived or read by others
- Test images should contain only minimal, non-sensitive content (e.g., empty files, timestamp strings)
- Always use unique UUIDs in image names to avoid collisions

### Test Contexts

The CI pipeline uses CircleCI contexts for secrets:

| Context | Variables | Purpose |
|---------|-----------|---------|
| `orb-publishing` | Registry credentials | Publishing orb to CircleCI registry |

Integration tests generate throwaway key pairs dynamically rather than using stored secrets. This is more secure and avoids key format compatibility issues between Cosign versions.

### Test Coverage

The test pipeline validates:
1. **Install command** - Multiple Cosign versions (v1.x, v2.x, v3.x) with checksum verification
2. **Sign/Verify workflow** - Full image signing and verification cycle
3. **Attest/Verify workflow** - Attestation creation and verification
4. **Version compatibility** - Ensures scripts work correctly with v1, v2, and v3

## Release Process

1. Create a release tag matching `v[0-9]+.[0-9]+.[0-9]+`
2. CI runs tests and publishes to CircleCI registry
3. Requires `orb-publishing` context with registry credentials
