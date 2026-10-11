<div align="center">
  <img align="center" width="256" src="assets/logos/cosign-orb.png?v=4" alt="Cosign Orb">
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
- **Keyless signing** via CircleCI OIDC - no key management required
- **Verify image signatures** before deployment to ensure authenticity
- **Private infrastructure support** - Sign without uploading to public transparency logs

### 📜 Attestation Support
- **Attach attestations** to container images (SBOMs, vulnerability scans, SLSA provenance)
- **Keyless attestations** via CircleCI OIDC - no key management required
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
| `check_oidc` | Verify CircleCI OIDC token availability for keyless signing |
| `generate_key_pair` | Generate a Cosign key pair (for development/testing) |
| `sign_image` | Sign a container image (supports private key or keyless modes) |
| `verify_image` | Verify a container image signature |
| `sign_blob` | Sign an arbitrary file (blob) using a private key |
| `verify_blob` | Verify a blob signature |
| `attest` | Attach an attestation (SBOM, provenance, etc.) to an image (supports private key or keyless modes) |
| `verify_attestation` | Verify an attestation attached to an image (supports public key or keyless modes) |

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
          version: "3.1.3"
          verify_checksums: strict
      - run:
          name: Use Cosign
          command: cosign version
```

### Generate Key Pair (Development/Testing)

Generate a throwaway key pair for testing. For production, use a key management system.

```yaml
steps:
  - cosign/install
  - cosign/generate_key_pair:
      password: "my-test-password"
  # Keys are now available as COSIGN_PRIVATE_KEY, COSIGN_PUBLIC_KEY, COSIGN_PASSWORD
  - cosign/sign_image:
      image: "myregistry.com/myimage:latest"
```

### Sign a Container Image

Sign images using a private key stored in a CircleCI context. See the [Private Key Signing Guide](docs/private-key-signing.md) for key generation and setup instructions.

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
          version: "3.1.3"
      - cosign/sign_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          # Requires COSIGN_PRIVATE_KEY and COSIGN_PASSWORD in your context
```

### Keyless Signing (Recommended)

Sign container images without managing keys using CircleCI's OIDC identity. Signatures are recorded in the public Sigstore transparency log. See the [Keyless Signing Guide](docs/keyless-signing.md) for complete documentation.

```yaml
version: 2.1

orbs:
  cosign: juburr/cosign-orb@latest

jobs:
  build-and-sign-keyless:
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
      - cosign/install
      - cosign/sign_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          keyless: true
          # No keys required! Uses CircleCI OIDC token automatically
```

**Prerequisites for keyless signing:**
- CircleCI Cloud or CircleCI Server 4.x+
- OIDC enabled for your organization
- Use `cosign/check_oidc` to verify OIDC is available

**Privacy note:** Keyless signatures are recorded in the public Rekor transparency log, which includes your CircleCI organization and project IDs.

### Sign with Annotations

Add metadata to your signatures with annotations:

```yaml
steps:
  - cosign/install
  - cosign/sign_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      annotations: "build.commit=${CIRCLE_SHA1},build.pipeline=${CIRCLE_PIPELINE_NUMBER}"
```

### Sign by Digest (Images, Helm Charts, and Other OCI Artifacts)

`sign_image` and `attest` always sign a digest. Pass either a tag or a digest:

```yaml
steps:
  - cosign/install
  - cosign/sign_image:
      # Signed exactly as given, after checking that the registry serves this digest
      image: "ghcr.io/my-org/charts/my-chart@sha256:<64 hex characters>"
  - cosign/sign_image:
      # Resolved to registry.example.com:5000/team/app@sha256:... first; the registry port is kept
      image: "registry.example.com:5000/team/app:1.2.3"
```

How the digest is read:

- **crane** (used when installed) reads the registry directly. It works for any OCI artifact, including Helm charts, and is recommended.
- **docker** (fallback) uses the digest Docker recorded for the requested repository, then pulls `repository@digest` to confirm the registry serves it. Docker can only do this for content its engine can pull; Helm charts and other non-image artifacts need crane unless your Docker Engine uses the containerd image store.
- Any failure stops the step. The orb never falls back from crane to docker, and never signs a digest the registry did not confirm.

Only `sha256` digests are accepted, because that is what Cosign's reference parser supports. In a `repository:tag@sha256:...` reference the tag is ignored, as Cosign ignores it.

### Pin the Signature Storage Format

Cosign can store signatures and attestations in two layouts, and its default changed between major versions. Set `bundle_format` on `sign_image`, `attest`, `verify_image` and `verify_attestation` so a Cosign upgrade cannot silently change what lands in your registry:

```yaml
steps:
  - cosign/install
  - cosign/sign_image:
      image: "ghcr.io/my-org/app@sha256:<64 hex characters>"
      bundle_format: bundle
  - cosign/attest:
      image: "ghcr.io/my-org/app@sha256:<64 hex characters>"
      predicate: "./sbom.spdx.json"
      predicate_type: "spdxjson"
      bundle_format: bundle
  - cosign/verify_image:
      image: "ghcr.io/my-org/app@sha256:<64 hex characters>"
      bundle_format: bundle
```

| `bundle_format` | What `sign_image` and `attest` write for subject `sha256:<hex>` |
|-----------------|--------------------------------------------------------------|
| `auto` (default) | Whatever the installed Cosign writes by default: `legacy` for Cosign 1 and 2, `bundle` for Cosign 3 (including the orb's default, 3.1.3). |
| `bundle` | One Sigstore bundle (`application/vnd.dev.sigstore.bundle.v0.3+json`) per signature or attestation, in an OCI 1.1 manifest whose `subject` is the digest. The manifest annotation `dev.sigstore.bundle.predicateType` is `https://sigstore.dev/cosign/sign/v1` for signatures, or the attestation's predicate type. Registries with the OCI referrers API index these natively. Other registries get an image index under the tag `sha256-<hex>` that lists them. Every run adds a new manifest. |
| `legacy` | The tag `sha256-<hex>.sig` for signatures and `sha256-<hex>.att` for attestations. Each is one image with one layer per signature or attestation, and every run adds a layer. |

With a private key, both formats skip the transparency log. On the verify commands, `bundle_format` names the format that must satisfy verification:

- Cosign is limited to that format wherever it has a switch for it.
- Two cases have no switch. Cosign 3 falls back to legacy objects when no bundle is attached, and Cosign 2.6.3+ switches to bundles whenever any are attached. In those cases the step verifies normally, then fails if objects in the other format also verify.
- With `auto`, Cosign 2.6.3+ and 3 prefer bundles when present. Earlier Cosign 2 releases only read legacy objects.

**Choosing a format:**

| | `bundle` | `legacy` |
|---|---|---|
| Cosign support | Write: Cosign 2.6.0+ (`sign_image`), 2.5.0+ (`attest`), and 3.x. Read: Cosign 2.6.0+ (`verify_image`), 2.5.0+ (`verify_attestation`), 3.x. | Every Cosign version. Cosign 3 deprecates it and plans to remove it in Cosign 4. In Cosign 3, private-key signing without a transparency log needs the deprecated `--tlog-upload=false --use-signing-config=false` flags. |
| Offline verification (`cosign save`, then `cosign verify --local-image`) | Works with Cosign 3.1.3 when the subject is a single image manifest (for example a Helm chart). Fails when the subject is an image index (for example a multi-platform image), and fails on Cosign 2.6.5. The saved layout stores the bundles as blobs that `index.json` does not list; Cosign 3 finds them by scanning the blobs. | Works with Cosign 2 and 3, for image manifests and image indexes. `index.json` lists the signatures and attestations (annotation `kind`: `dev.cosignproject.cosign/sigs` and `.../atts`). |
| Other tools | Need OCI referrers and Sigstore bundle support. | Read by older policy engines and admission controllers that only know `.sig`/`.att` tags. |

Prefer `bundle` unless something that reads your signatures only understands `.sig`/`.att` tags, or you need offline verification of multi-platform images. Whichever you choose, set it explicitly in production pipelines. Keyless signing can pin the format its Cosign major writes by default (`legacy` for Cosign 1 and 2, `bundle` for Cosign 3), but cannot switch formats.

### Verify an Image Signature

```yaml
steps:
  - cosign/install
  - cosign/verify_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      # Requires COSIGN_PUBLIC_KEY in your context
```

`verify_image` passes only when Cosign verified an image signature. Cosign 2.6+ and 3 accept any Sigstore bundle signed by the key or identity, including an attestation, as a signature. An image that was attested but never signed therefore fails `verify_image`; check its attestations with `verify_attestation`.

### Verify a Keyless Signature

Verify images signed with keyless signing. When verifying images signed by the **same project**, parameters are auto-detected:

```yaml
steps:
  - cosign/install
  - cosign/verify_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      keyless: true
      # Auto-detects from CIRCLE_ORGANIZATION_ID and CIRCLE_PROJECT_ID
      # Only works for same-project verification!
```

For **cross-project** or **cross-organization** verification, specify the signing project's IDs:

```yaml
steps:
  - cosign/install
  - cosign/verify_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      keyless: true
      certificate_oidc_issuer: "https://oidc.circleci.com/org/<your-org-id>"
      certificate_identity_regexp: "https://circleci.com/api/v2/projects/<your-project-id>/pipeline-definitions/.*"
```

See the [Keyless Signing Guide](docs/keyless-signing.md) for details on certificate identity formats and verification options.

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

### Keyless Sign and Verify a Blob (Recommended)

Sign arbitrary files without managing keys using CircleCI's OIDC identity. Signatures are recorded in the public Sigstore transparency log.

```yaml
steps:
  - cosign/install
  - cosign/sign_blob:
      blob: "./artifact.tar.gz"
      keyless: true
      signature_output: "./artifact.tar.gz.sig"
      certificate_output: "./artifact.tar.gz.crt"  # Required for keyless blob signing
      # No keys required! Uses CircleCI OIDC token automatically
  - cosign/verify_blob:
      blob: "./artifact.tar.gz"
      signature: "./artifact.tar.gz.sig"
      certificate: "./artifact.tar.gz.crt"  # Certificate from signing step
      keyless: true
      # Auto-detects from CIRCLE_ORGANIZATION_ID and CIRCLE_PROJECT_ID
```

For **cross-project** verification, specify the signing project's IDs:

```yaml
steps:
  - cosign/install
  - cosign/verify_blob:
      blob: "./artifact.tar.gz"
      signature: "./artifact.tar.gz.sig"
      certificate: "./artifact.tar.gz.crt"
      keyless: true
      certificate_oidc_issuer: "https://oidc.circleci.com/org/<your-org-id>"
      certificate_identity_regexp: "https://circleci.com/api/v2/projects/<your-project-id>/pipeline-definitions/.*"
```

**Note:** Unlike image signing where certificates are stored in the registry, blob signing requires you to save the certificate file during signing and provide it during verification.

### Attach and Verify Attestations

Attach attestations (SBOMs, provenance, vulnerability reports) using a private key:

```yaml
steps:
  - cosign/install
  - cosign/attest:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate: "./sbom.spdx.json"
      predicate_type: "spdxjson"
      # Requires COSIGN_PRIVATE_KEY and COSIGN_PASSWORD in your context
  - cosign/verify_attestation:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate_type: "spdxjson"
      # Requires COSIGN_PUBLIC_KEY in your context
```

### Keyless Attestations (Recommended)

Attach attestations without managing keys using CircleCI's OIDC identity:

```yaml
steps:
  - cosign/install
  - cosign/attest:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate: "./sbom.spdx.json"
      predicate_type: "spdxjson"
      keyless: true
      # No keys required! Uses CircleCI OIDC token automatically
  - cosign/verify_attestation:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate_type: "spdxjson"
      keyless: true
      # Auto-detects from CIRCLE_ORGANIZATION_ID and CIRCLE_PROJECT_ID
```

For cross-project verification of keyless attestations, specify the signing project's IDs:

```yaml
steps:
  - cosign/install
  - cosign/verify_attestation:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate_type: "spdxjson"
      keyless: true
      certificate_oidc_issuer: "https://oidc.circleci.com/org/<your-org-id>"
      certificate_identity_regexp: "https://circleci.com/api/v2/projects/<your-project-id>/pipeline-definitions/.*"
```

## ⚙️ Configuration

### Install Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `version` | string | `3.1.3` | Cosign version to install |
| `caching` | boolean | `true` | Cache the Cosign binary between runs |
| `install_path` | string | `/home/circleci/bin` | Installation directory |
| `verify_checksums` | enum | `known_versions` | Checksum verification mode: `strict`, `known_versions`, or `false` |

### Generate Key Pair Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `password` | string | `""` | Password to encrypt the private key (random if empty) |
| `private_key_var` | string | `COSIGN_PRIVATE_KEY` | Environment variable for base64-encoded private key |
| `public_key_var` | string | `COSIGN_PUBLIC_KEY` | Environment variable for base64-encoded public key |
| `password_var` | string | `COSIGN_PASSWORD` | Environment variable for the password |

### Sign Image Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `image` | string | *required* | Image or OCI artifact by tag (`registry.com/image:tag`) or digest (`registry.com/image@sha256:...`) |
| `keyless` | boolean | `false` | Use keyless signing via CircleCI OIDC (no keys required) |
| `private_key` | env_var_name | `COSIGN_PRIVATE_KEY` | Environment variable containing base64-encoded private key (ignored if keyless) |
| `password` | env_var_name | `COSIGN_PASSWORD` | Environment variable containing key password (ignored if keyless) |
| `annotations` | string | `""` | Comma-separated key=value pairs to add to signature (e.g., `"env=prod,team=platform"`) |
| `fulcio_url` | string | `https://fulcio.sigstore.dev` | Fulcio CA URL (keyless only) |
| `rekor_url` | string | `https://rekor.sigstore.dev` | Rekor transparency log URL (keyless only) |
| `oidc_issuer` | string | `https://oidc.circleci.com/org/<org-id>` | OIDC issuer URL (auto-detected from CIRCLE_ORGANIZATION_ID, keyless only) |
| `bundle_format` | enum | `auto` | Signature storage format: `auto`, `bundle`, or `legacy`. See [Pin the Signature Storage Format](#pin-the-signature-storage-format) |

### Verify Image Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `image` | string | *required* | Full image reference (e.g., `registry.com/image:tag`) |
| `keyless` | boolean | `false` | Use keyless verification via certificate identity matching |
| `public_key` | env_var_name | `COSIGN_PUBLIC_KEY` | Environment variable containing base64-encoded public key (ignored if keyless) |
| `certificate_identity` | string | *auto-detected* | Expected identity in Fulcio certificate (keyless only). Auto-detected from `CIRCLE_PROJECT_ID` if not provided. |
| `certificate_identity_regexp` | string | *auto-detected* | Regex pattern for certificate identity (keyless only). Auto-generated from `CIRCLE_PROJECT_ID` if identity not provided. |
| `certificate_oidc_issuer` | string | *auto-detected* | Expected OIDC issuer in certificate (keyless only). Auto-detected from `CIRCLE_ORGANIZATION_ID` if not provided. |
| `certificate_oidc_issuer_regexp` | string | `""` | Regex pattern for OIDC issuer (keyless only) |
| `bundle_format` | enum | `auto` | Signature format that must satisfy verification: `auto`, `bundle`, or `legacy` |

### Sign Blob Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `blob` | string | *required* | Path to the file to sign |
| `signature_output` | string | `""` (stdout) | Path to write the signature |
| `keyless` | boolean | `false` | Use keyless signing via CircleCI OIDC (no keys required) |
| `certificate_output` | string | `""` | Path to write the Fulcio certificate (required when keyless is true) |
| `private_key` | env_var_name | `COSIGN_PRIVATE_KEY` | Environment variable containing base64-encoded private key (ignored if keyless) |
| `password` | env_var_name | `COSIGN_PASSWORD` | Environment variable containing key password (ignored if keyless) |
| `fulcio_url` | string | `https://fulcio.sigstore.dev` | Fulcio CA URL (keyless only) |
| `rekor_url` | string | `https://rekor.sigstore.dev` | Rekor transparency log URL (keyless only) |
| `oidc_issuer` | string | `https://oidc.circleci.com/org/<org-id>` | OIDC issuer URL (auto-detected from CIRCLE_ORGANIZATION_ID, keyless only) |

### Verify Blob Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `blob` | string | *required* | Path to the file to verify |
| `signature` | string | *required* | Path to the signature file |
| `keyless` | boolean | `false` | Use keyless verification via certificate identity matching |
| `certificate` | string | `""` | Path to the certificate file (required when keyless is true) |
| `public_key` | env_var_name | `COSIGN_PUBLIC_KEY` | Environment variable containing base64-encoded public key (ignored if keyless) |
| `certificate_identity` | string | *auto-detected* | Expected identity in Fulcio certificate (keyless only). Auto-detected from `CIRCLE_PROJECT_ID` if not provided. |
| `certificate_identity_regexp` | string | *auto-detected* | Regex pattern for certificate identity (keyless only). Auto-generated from `CIRCLE_PROJECT_ID` if identity not provided. |
| `certificate_oidc_issuer` | string | *auto-detected* | Expected OIDC issuer in certificate (keyless only). Auto-detected from `CIRCLE_ORGANIZATION_ID` if not provided. |
| `certificate_oidc_issuer_regexp` | string | `""` | Regex pattern for OIDC issuer (keyless only) |

### Attest Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `image` | string | *required* | Image or OCI artifact by tag (`registry.com/image:tag`) or digest (`registry.com/image@sha256:...`) |
| `predicate` | string | *required* | Path to predicate file |
| `predicate_type` | string | *required* | Attestation type (e.g., `spdxjson`, `cyclonedx`, `slsaprovenance`) |
| `keyless` | boolean | `false` | Use keyless attestation via CircleCI OIDC (no keys required) |
| `private_key` | env_var_name | `COSIGN_PRIVATE_KEY` | Environment variable containing base64-encoded private key (ignored if keyless) |
| `password` | env_var_name | `COSIGN_PASSWORD` | Environment variable containing key password (ignored if keyless) |
| `fulcio_url` | string | `https://fulcio.sigstore.dev` | Fulcio CA URL (keyless only) |
| `rekor_url` | string | `https://rekor.sigstore.dev` | Rekor transparency log URL (keyless only) |
| `oidc_issuer` | string | `https://oidc.circleci.com/org/<org-id>` | OIDC issuer URL (auto-detected from CIRCLE_ORGANIZATION_ID, keyless only) |
| `bundle_format` | enum | `auto` | Attestation storage format: `auto`, `bundle`, or `legacy` |

### Verify Attestation Command Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `image` | string | *required* | Full image reference |
| `predicate_type` | string | *required* | Attestation type to verify (e.g., `spdxjson`, `cyclonedx`, `slsaprovenance`) |
| `keyless` | boolean | `false` | Use keyless verification via certificate identity matching |
| `public_key` | env_var_name | `COSIGN_PUBLIC_KEY` | Environment variable containing base64-encoded public key (ignored if keyless) |
| `certificate_identity` | string | *auto-detected* | Expected identity in Fulcio certificate (keyless only). Auto-detected from `CIRCLE_PROJECT_ID` if not provided. |
| `certificate_identity_regexp` | string | *auto-detected* | Regex pattern for certificate identity (keyless only). Auto-generated from `CIRCLE_PROJECT_ID` if identity not provided. |
| `certificate_oidc_issuer` | string | *auto-detected* | Expected OIDC issuer in certificate (keyless only). Auto-detected from `CIRCLE_ORGANIZATION_ID` if not provided. |
| `certificate_oidc_issuer_regexp` | string | `""` | Regex pattern for OIDC issuer (keyless only) |
| `bundle_format` | enum | `auto` | Attestation format that must satisfy verification: `auto`, `bundle`, or `legacy` |

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

## 📖 Documentation

| Guide | Description |
|-------|-------------|
| [Keyless Signing Guide](docs/keyless-signing.md) | OIDC-based signing with CircleCI, Fulcio, and Rekor |
| [Private Key Signing Guide](docs/private-key-signing.md) | Traditional signing for air-gapped environments |
| [Roadmap](docs/ROADMAP.md) | Planned features and enhancements |

## 🗺️ Roadmap

We're actively developing new features. See our [roadmap](docs/ROADMAP.md) for planned enhancements including:

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
