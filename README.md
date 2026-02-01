<div align="center">
  <img align="center" width="240" src="assets/logos/cosign-orb.png?v=2" alt="Cosign Orb">
  <h1>CircleCI Cosign Orb</h1>
  <i>Secure container image signing and verification for CircleCI pipelines.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/cosign-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/cosign-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/cosign-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/cosign-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/cosign-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

A CircleCI Orb for [Cosign](https://github.com/sigstore/cosign), the industry-standard tool for signing, verifying, and attesting container images. Protect your software supply chain by cryptographically signing container images directly in your CI/CD pipeline.

## 💡 Why Use This Orb?

Container image signing is a critical component of software supply chain security. This orb makes it easy to:

- **Prove authenticity** - Cryptographically prove that images were built by your CI pipeline
- **Detect tampering** - Verification fails if an image has been modified after signing
- **Meet compliance requirements** - Support SLSA, NIST 800-171, CMMC, and other supply chain security frameworks
- **Attach attestations** - Include SBOMs, vulnerability reports, and provenance metadata with your images

## ✨ Features

### 🔏 Container Image Signing & Verification
- **Sign container images** with private keys stored securely in CircleCI contexts
- **Verify image signatures** before deployment to ensure authenticity
- **Private infrastructure support** - Sign without uploading to public transparency logs

### 📜 Attestation Support
- **Attach attestations** to container images (SBOMs, vulnerability scans, SLSA provenance)
- **Verify attestations** with support for multiple predicate types
- **Standards compliant** - Supports SPDX, CycloneDX, and custom predicate formats

### 🔖 Multi-Version Compatibility
- **Cosign v1, v2, and v3** - Automatic version detection with appropriate flags
- **Key format handling** - Manages differences between v1 and v2+ key formats
- **Future-proof** - Designed to accommodate Cosign's evolving API

### 🛡️ Enterprise-Ready Security
- **SHA-512 checksum verification** - Every Cosign download is verified against known checksums
- **Secure key handling** - Keys destroyed with `shred` after use, minimal file permissions (0400)
- **No sudo required** - Installs to user-owned directories without elevated privileges
- **Secret hygiene** - Follows CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) for handling sensitive data

### 🔒 Air-Gapped & Private Infrastructure
- **Skip transparency logs** - Sign images without uploading to Rekor (ideal for private infrastructure)
- **Self-hosted CircleCI support** - Works with CircleCI Server deployments
- **Compliance-friendly** - Suitable for NIST 800-171, CMMC, and regulated environments
- **No external dependencies** - Signing works entirely within your infrastructure

### ⚡ Performance & Reliability
- **Built-in caching** - Optional caching prevents redundant downloads across pipeline runs
- **Fast installation** - Lightweight binary download, typically completes in seconds
- **Comprehensive CI testing** - Every release tested against Cosign v1, v2, and v3

### 🙈 Privacy Respecting
- **No telemetry** - Zero usage data collected or transmitted to orb developers
- **Fully open source** - Complete transparency into orb behavior
- **Your data stays yours** - All operations happen within your CircleCI environment

## 🧰 Available Commands

| Command | Description |
|---------|-------------|
| `install` | Download and install Cosign with checksum verification |
| `sign_image` | Sign a container image using a private key |
| `verify_image` | Verify a container image signature |
| `sign_blob` | Sign an arbitrary file (blob) using a private key |
| `verify_blob` | Verify a blob signature |
| `attest` | Attach an attestation (SBOM, provenance, etc.) to an image |
| `verify_attestation` | Verify an attestation attached to an image |

## 🚀 Quick Start

### Installation Only

Install Cosign and use it with custom commands:

```yaml
version: 2.1

orbs:
  cosign: juburr/cosign-orb@latest

jobs:
  example:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - cosign/install:
          version: "3.0.4"
          verify_checksums: strict
      - run:
          name: Use Cosign
          command: cosign version
```

### Sign a Container Image

```yaml
version: 2.1

orbs:
  cosign: juburr/cosign-orb@latest

jobs:
  build-and-sign:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - setup_remote_docker
      - run:
          name: Build and Push Image
          command: |
            docker build -t myregistry.com/myimage:${CIRCLE_SHA1} .
            docker push myregistry.com/myimage:${CIRCLE_SHA1}
      - cosign/install:
          version: "3.0.4"
      - cosign/sign_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          # Requires COSIGN_PRIVATE_KEY and COSIGN_PASSWORD in your context
```

### Sign with Annotations

Add metadata to your signatures with annotations:

```yaml
steps:
  - cosign/install
  - cosign/sign_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      annotations: "build.commit=${CIRCLE_SHA1},build.pipeline=${CIRCLE_PIPELINE_NUMBER}"
```

### Verify an Image Signature

```yaml
steps:
  - cosign/install
  - cosign/verify_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      # Requires COSIGN_PUBLIC_KEY in your context
```

### Sign and Verify a Blob (Arbitrary File)

```yaml
steps:
  - cosign/install
  - cosign/sign_blob:
      blob: "./artifact.tar.gz"
      signature_output: "./artifact.tar.gz.sig"
      # Requires COSIGN_PRIVATE_KEY and COSIGN_PASSWORD in your context
  - cosign/verify_blob:
      blob: "./artifact.tar.gz"
      signature: "./artifact.tar.gz.sig"
      # Requires COSIGN_PUBLIC_KEY in your context
```

### Attach and Verify Attestations

```yaml
steps:
  - cosign/install
  - cosign/attest:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate: "./sbom.spdx.json"
      predicate_type: "spdxjson"
  - cosign/verify_attestation:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate_type: "spdxjson"
```

## ⚙️ Configuration

### Install Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `version` | string | `3.0.4` | Cosign version to install |
| `caching` | boolean | `true` | Cache the Cosign binary between runs |
| `install_path` | string | `/home/circleci/bin` | Installation directory |
| `verify_checksums` | enum | `known_versions` | Checksum verification mode: `strict`, `known_versions`, or `false` |

### Sign/Verify Image Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `image` | string | *required* | Full image reference (e.g., `registry.com/image:tag`) |
| `private_key` | env_var_name | `COSIGN_PRIVATE_KEY` | Environment variable containing base64-encoded private key |
| `public_key` | env_var_name | `COSIGN_PUBLIC_KEY` | Environment variable containing base64-encoded public key |
| `password` | env_var_name | `COSIGN_PASSWORD` | Environment variable containing key password |
| `annotations` | string | `""` | Comma-separated key=value pairs to add to signature (sign only, e.g., `"env=prod,team=platform"`) |

### Sign/Verify Blob Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `blob` | string | *required* | Path to the file to sign or verify |
| `signature` | string | *required* (verify only) | Path to the signature file |
| `signature_output` | string | `""` (stdout) | Path to write the signature (sign only) |
| `private_key` | env_var_name | `COSIGN_PRIVATE_KEY` | Environment variable containing base64-encoded private key |
| `public_key` | env_var_name | `COSIGN_PUBLIC_KEY` | Environment variable containing base64-encoded public key |
| `password` | env_var_name | `COSIGN_PASSWORD` | Environment variable containing key password |

### Attestation Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `image` | string | *required* | Full image reference |
| `predicate` | string | *required* | Path to predicate file |
| `predicate_type` | string | *required* | Attestation type (e.g., `spdxjson`, `cyclonedx`, `slsaprovenance`) |

## 🔑 Key Management

### Generating Keys

Generate a Cosign key pair for signing:

```bash
cosign generate-key-pair
# Creates cosign.key (private) and cosign.pub (public)
```

### Storing Keys in CircleCI

1. Base64-encode your keys:
   ```bash
   cat cosign.key | base64 -w 0 > cosign.key.b64
   cat cosign.pub | base64 -w 0 > cosign.pub.b64
   ```

2. Add to a CircleCI context:
   - `COSIGN_PRIVATE_KEY` - Contents of `cosign.key.b64`
   - `COSIGN_PUBLIC_KEY` - Contents of `cosign.pub.b64`
   - `COSIGN_PASSWORD` - The password used when generating keys

### Version Compatibility Note

Cosign v1 and v2+ use different key formats:
- **v1**: `ENCRYPTED COSIGN PRIVATE KEY`
- **v2+**: `ENCRYPTED SIGSTORE PRIVATE KEY`

Keys generated with v2/v3 cannot be used with v1. If you need v1 compatibility, generate keys using Cosign v1.

## 🗺️ Roadmap

We're actively developing new features. See our [roadmap](docs/ROADMAP.md) for planned enhancements including:

- Keyless signing via CircleCI OIDC
- Cloud KMS integration (AWS KMS, GCP KMS, Azure Key Vault)
- Pre-built jobs for common workflows

## 🤝 Contributing

Contributions are welcome! Please see our contributing guidelines for more information.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📚 Resources

- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Sigstore Project](https://www.sigstore.dev/)
- [CircleCI Orb Registry](https://circleci.com/developer/orbs/orb/juburr/cosign-orb)
- [CircleCI Orb Documentation](https://circleci.com/docs/orb-intro/)
