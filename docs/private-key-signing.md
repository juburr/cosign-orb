# Private Key Signing Guide

This guide covers container image signing using private keys for organizations that need to sign images without using public transparency logs or external services.

## Overview

Private key signing is ideal for:
- Air-gapped or isolated environments
- Organizations with strict compliance requirements (NIST 800-171, CMMC, FedRAMP)
- Teams that prefer traditional PKI-style key management
- Development and testing workflows

## Security Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CircleCI Pipeline                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────┐  │
│  │  CircleCI   │───►│   Cosign    │───►│   Container Registry    │  │
│  │   Context   │    │   (sign)    │    │   (image + signature)   │  │
│  └─────────────┘    └─────────────┘    └─────────────────────────┘  │
│        │                                                            │
│        │ COSIGN_PRIVATE_KEY (base64)                                │
│        │ COSIGN_PASSWORD                                            │
│        ▼                                                            │
│  ┌─────────────┐                                                    │
│  │  Decoded    │  Permissions: 0400                                 │
│  │  cosign.key │  Destroyed after use (shred)                       │
│  └─────────────┘                                                    │
│                                                                     │
│  NO external calls to:                                              │
│  - Fulcio (certificate authority)                                   │
│  - Rekor (transparency log)                                         │
│  - Any Sigstore infrastructure                                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Generate a Key Pair

Generate a Cosign key pair on your local machine:

```bash
# Generate keys (you'll be prompted for a password)
cosign generate-key-pair

# This creates:
# - cosign.key (private key - keep secret!)
# - cosign.pub (public key - distribute for verification)
```

### 2. Base64 Encode the Keys

CircleCI contexts store secrets as strings, so we base64 encode the keys:

```bash
# Encode the private key
cat cosign.key | base64 -w 0 > cosign.key.b64

# Encode the public key
cat cosign.pub | base64 -w 0 > cosign.pub.b64
```

### 3. Create a CircleCI Context

1. Go to **Organization Settings** → **Contexts**
2. Create a new context (e.g., `cosign-signing`)
3. Add the following environment variables:

| Variable | Value |
|----------|-------|
| `COSIGN_PRIVATE_KEY` | Contents of `cosign.key.b64` |
| `COSIGN_PUBLIC_KEY` | Contents of `cosign.pub.b64` |
| `COSIGN_PASSWORD` | The password you used when generating keys |

### 4. Configure Your Pipeline

```yaml
version: 2.1

orbs:
  cosign: juburr/cosign-orb@1.x

jobs:
  build-and-sign:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - setup_remote_docker

      # Build and push your image
      - run:
          name: Build and push image
          command: |
            docker build -t myregistry.com/myimage:${CIRCLE_SHA1} .
            docker push myregistry.com/myimage:${CIRCLE_SHA1}

      # Install Cosign and sign the image
      - cosign/install:
          version: "3.0.4"
      - cosign/sign_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"

workflows:
  build-sign-deploy:
    jobs:
      - build-and-sign:
          context: cosign-signing  # Use your context with the keys
```

### 5. Verify Signed Images

In your deployment pipeline or on any machine with the public key:

```yaml
steps:
  - cosign/install
  - cosign/verify_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      # Uses COSIGN_PUBLIC_KEY from context
```

## Adding Annotations

Add metadata to your signatures to track build provenance:

```yaml
- cosign/sign_image:
    image: "myregistry.com/myimage:${CIRCLE_SHA1}"
    annotations: "commit=${CIRCLE_SHA1},pipeline=${CIRCLE_PIPELINE_NUMBER},branch=${CIRCLE_BRANCH}"
```

Verify annotations match expected values:

```bash
cosign verify --key cosign.pub \
  -a commit=abc123 \
  -a pipeline=42 \
  myregistry.com/myimage@sha256:...
```

## Security Best Practices

### Key Management

1. **Generate keys securely**: Use a secure workstation, not a shared CI environment
2. **Rotate keys periodically**: Establish a key rotation schedule
3. **Limit context access**: Only grant context access to jobs that need to sign
4. **Use separate keys per environment**: Production, staging, and development should have different keys

### Secret Hygiene

The orb follows these security practices automatically:
- Private key file permissions set to `0400` (owner read-only)
- Keys destroyed with `shred -vzuf -n 10` after use
- Environment variables unset after signing completes
- No `sudo` required - installs to user-owned directories

### Version Compatibility

**Important**: Cosign v1 and v2+ use incompatible key formats:

| Version | Key Header |
|---------|------------|
| v1.x | `ENCRYPTED COSIGN PRIVATE KEY` |
| v2.x, v3.x | `ENCRYPTED SIGSTORE PRIVATE KEY` |

Keys generated with v2/v3 **cannot** be used with v1. If you need v1 compatibility, generate keys using Cosign v1.

## Signing Blobs (Arbitrary Files)

Sign any file, not just container images:

```yaml
steps:
  - cosign/install
  - cosign/sign_blob:
      blob: "./release.tar.gz"
      signature_output: "./release.tar.gz.sig"
  - cosign/verify_blob:
      blob: "./release.tar.gz"
      signature: "./release.tar.gz.sig"
```

## Attestations

Attach attestations (SBOMs, vulnerability reports, provenance) to images:

```yaml
steps:
  - cosign/install

  # Generate SBOM (example using syft)
  - run:
      name: Generate SBOM
      command: syft myregistry.com/myimage:${CIRCLE_SHA1} -o spdx-json > sbom.spdx.json

  # Attach as attestation (uses COSIGN_PRIVATE_KEY from context)
  - cosign/attest:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate: "sbom.spdx.json"
      predicate_type: "spdxjson"

  # Verify the attestation
  - cosign/verify_attestation:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate_type: "spdxjson"
```

> **Note**: Attestations also support keyless mode. See the [Keyless Signing Guide](keyless-signing.md) for details on using OIDC-based attestations.

## Troubleshooting

### "unsupported pem type: ENCRYPTED SIGSTORE PRIVATE KEY"

You're using a v2/v3 key with Cosign v1. Either:
- Upgrade to Cosign v2+ in your pipeline
- Regenerate keys using Cosign v1

### "Private key is empty"

Check that:
1. The `COSIGN_PRIVATE_KEY` environment variable is set in your context
2. The context is attached to your job
3. The value is properly base64 encoded (no newlines)

### "Failed to decode private key"

The base64 encoding may be corrupted. Re-encode:
```bash
cat cosign.key | base64 -w 0  # -w 0 prevents line wrapping
```

## How Private Signing Works

When using private key signing, the orb uses Cosign's `--private-infrastructure` flag (v2+) or `--no-tlog-upload` flag (v1). This ensures:

1. **No Rekor upload** - Signatures are not recorded in the public transparency log
2. **No Fulcio interaction** - No certificate authority is contacted
3. **Self-contained verification** - Only your public key is needed to verify

### Version-Specific Flags

The orb automatically uses the correct flags for each Cosign version:

| Version | Signing Flag | Verification Flag |
|---------|--------------|-------------------|
| v1.x | `--no-tlog-upload` | (none needed) |
| v2.x | `--tlog-upload=false` | `--private-infrastructure` |
| v3.x | `--signing-config=<path>` | `--private-infrastructure` |

For v3, the orb creates a minimal signing config that disables all Sigstore services.

## Comparison with Keyless Signing

| Aspect | Private Key | Keyless (OIDC) |
|--------|-------------|----------------|
| Key management | You manage keys | No keys to manage |
| Transparency log | Not used (private) | Public (Rekor) |
| Identity verification | By public key | By OIDC identity |
| Best for | Air-gapped, compliance | Public projects, convenience |
| Setup complexity | Medium | Low |
| Key rotation | Required | Not needed |
| Audit trail | Manual | Automatic (Rekor) |

See [Keyless Signing Guide](keyless-signing.md) for OIDC-based signing.

## Further Reading

- [Sigstore Documentation](https://docs.sigstore.dev/)
- [Cosign Key Management](https://docs.sigstore.dev/cosign/key-generation/)
- [CircleCI Contexts](https://circleci.com/docs/contexts/)
- [Keyless Signing Guide](keyless-signing.md)
