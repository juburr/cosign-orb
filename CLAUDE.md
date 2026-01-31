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

## Architecture

### Orb Structure

```
src/
├── @orb.yml           # Orb metadata and version
├── commands/          # YAML command definitions (install, sign_image, verify_image, attest, verify_attestation)
├── scripts/           # Bash implementations for each command
└── examples/          # Usage examples
```

### Commands

1. **install** - Downloads and installs Cosign with SHA-512 checksum verification
2. **sign_image** - Signs container images using base64-encoded private keys
3. **verify_image** - Verifies container image signatures
4. **attest** - Attaches attestations (SBOM, vulnerability reports) to images
5. **verify_attestation** - Verifies attestations on images

### Version Compatibility

Scripts handle Cosign v1, v2, and v3 with version-specific flags:
- v1: `--no-tlog-upload`
- v2: `--tlog-upload=false`
- v3: `--upload=false` / `--no-upload`

### Checksum Verification

`src/scripts/install.sh` contains a lookup table of SHA-512 checksums for 75+ Cosign versions. Three verification modes:
- `strict`: Fails if version not in lookup table
- `known_versions` (default): Warns but allows unknown versions
- `false`: Skips verification (not recommended)

### Security Patterns

- No `sudo` usage - installs to user-owned directories
- Keys passed via environment variables (base64-encoded)
- Secure cleanup using `shred -vzuf -n 10` for key files
- Private key permissions set to 0400

## Key Files

- `.circleci/config.yml` - Main CI pipeline (lint, pack, review, shellcheck)
- `.circleci/test-deploy.yml` - Test and publish workflow
- `src/commands/*.yml` - Orb command definitions with parameters
- `src/scripts/*.sh` - Shell implementations

## Release Process

1. Create a release tag matching `v[0-9]+.[0-9]+.[0-9]+`
2. CI runs tests and publishes to CircleCI registry
3. Requires `orb-publishing` context with registry credentials
