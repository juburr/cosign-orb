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

### Local Development Environment

Developers on this project make a best effort to install all three major versions of Cosign for convenience in local development, testing, and viewing available commands:

| Binary | Version | Purpose |
|--------|---------|---------|
| `cosign` | v3.0.4 | Latest major version (default) |
| `cosign2` | v2.6.1 | Legacy v2 testing |
| `cosign1` | v1.13.6 | Legacy v1 testing |

### Reference Documentation

The official Cosign project is included as a git submodule at `./ref/cosign` for quick review of source code and documentation. This allows convenient access to Cosign's implementation details when developing version-specific functionality.

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

Scripts handle Cosign v1, v2, and v3 with version-specific approaches for private infrastructure (no transparency log):
- v1: `--no-tlog-upload`
- v2: `--tlog-upload=false`
- v3: `--signing-config=<path>` with an empty signing config JSON (no Rekor/Fulcio/TSA services)

The v3 approach creates a minimal signing config file inline:
```json
{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}
```

### Key Format Compatibility

**Warning:** Cosign v1 and v2+ use incompatible key formats:
- v1: `ENCRYPTED COSIGN PRIVATE KEY`
- v2+: `ENCRYPTED SIGSTORE PRIVATE KEY`

Keys generated with v2/v3 cannot be used with v1 (error: `unsupported pem type: ENCRYPTED SIGSTORE PRIVATE KEY`). The CI pipeline generates v1-compatible keys dynamically for v1 integration tests.

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
