# Cosign Orb Roadmap

This document outlines the strategic roadmap for the cosign-orb CircleCI Orb, based on analysis of the current implementation, Cosign capabilities, and industry usage patterns.

## Executive Summary

The cosign-orb currently provides solid foundational support for container image signing and verification using private key infrastructure. However, the industry has largely moved toward **keyless signing** using OIDC identity, which eliminates key management overhead and is the recommended approach for public CI/CD pipelines.

This roadmap prioritizes features based on:
1. **User demand** - What developers actually need in their CI/CD workflows
2. **Industry trends** - Where container supply chain security is heading
3. **Ease of adoption** - Reducing friction for new users
4. **Enterprise requirements** - Supporting air-gapped and regulated environments

---

## Current State (v1.x)

### Existing Commands
| Command | Description | Signing Method |
|---------|-------------|----------------|
| `install` | Download and install Cosign with SHA-512 verification | N/A |
| `sign_image` | Sign container images | Private key (base64) |
| `verify_image` | Verify image signatures | Public key (base64) |
| `attest` | Attach attestations (SBOM, SLSA, etc.) | Private key (base64) |
| `verify_attestation` | Verify attestations on images | Public key (base64) |

### Current Strengths
- Multi-version support (Cosign v1, v2, v3)
- Strong security practices (checksum verification, secure key cleanup, file permissions)
- Private infrastructure mode (no external dependencies)
- Comprehensive CI testing

### Current Limitations
- **No keyless signing** - Requires manual key management
- **No KMS integration** - Can't use cloud-managed keys
- **No blob signing** - Only container images supported
- **No annotations** - Can't add metadata to signatures
- **No multi-arch support** - No recursive signing for manifests
- **Only Linux x86_64** - No macOS or ARM executors
- **No jobs** - Only commands, users must compose their own workflows

---

## Phase 1: Keyless Signing (High Priority)

**Goal:** Enable OIDC-based keyless signing, the industry-standard approach for public CI/CD.

Keyless signing eliminates the need for long-lived signing keys by using identity from the CI provider (CircleCI OIDC). Short-lived certificates are issued by Fulcio and signatures are recorded in Rekor transparency log.

### New Commands

#### `sign_image_keyless`
Sign container images using CircleCI's OIDC identity token.

```yaml
parameters:
  image:
    type: string
    description: "Image to sign (e.g., registry.example.com/image@sha256:...)"
  oidc_issuer:
    type: string
    default: "https://oidc.circleci.com/org/<org-id>"
    description: "OIDC issuer URL"
  fulcio_url:
    type: string
    default: "https://fulcio.sigstore.dev"
    description: "Fulcio CA URL"
  rekor_url:
    type: string
    default: "https://rekor.sigstore.dev"
    description: "Rekor transparency log URL"
  annotations:
    type: string
    default: ""
    description: "Comma-separated key=value annotations"
  recursive:
    type: boolean
    default: false
    description: "Sign all images in a multi-arch manifest"
```

#### `verify_image_keyless`
Verify keylessly-signed images using certificate identity.

```yaml
parameters:
  image:
    type: string
    description: "Image to verify"
  certificate_identity:
    type: string
    description: "Expected identity in certificate (email, URI, etc.)"
  certificate_identity_regexp:
    type: string
    default: ""
    description: "Regex pattern for certificate identity"
  certificate_oidc_issuer:
    type: string
    description: "Expected OIDC issuer in certificate"
  certificate_oidc_issuer_regexp:
    type: string
    default: ""
    description: "Regex pattern for OIDC issuer"
```

#### `attest_keyless`
Create attestations using keyless signing.

```yaml
parameters:
  image:
    type: string
  predicate:
    type: string
  predicate_type:
    type: string
  oidc_issuer:
    type: string
    default: "https://oidc.circleci.com/org/<org-id>"
```

#### `verify_attestation_keyless`
Verify keylessly-signed attestations.

### Implementation Notes
- CircleCI OIDC tokens: Use `$CIRCLE_OIDC_TOKEN` or equivalent mechanism
- Fulcio integration: Request short-lived signing certificates
- Rekor integration: Record signatures in transparency log
- Privacy consideration: Keyless signing records identity permanently in public log

### Use Cases Addressed
- Zero key management for open source projects
- Automatic identity-based verification in Kubernetes admission controllers
- Audit trail via Rekor transparency log
- GitHub/GitLab parity (both support keyless signing)

---

## Phase 2: Cloud KMS Integration (High Priority)

**Goal:** Enable enterprise users to leverage cloud-managed keys with proper access controls.

### Enhanced `sign_image` Command
Add support for KMS key references:

```yaml
parameters:
  key:
    type: string
    description: |
      Key reference. Supports:
      - env://ENV_VAR (environment variable with base64 key)
      - awskms://[ENDPOINT]/[ID/ALIAS/ARN]
      - gcpkms://projects/[PROJECT]/locations/global/keyRings/[KEYRING]/cryptoKeys/[KEY]
      - azurekms://[VAULT_NAME][VAULT_URI]/[KEY]
      - hashivault://[KEY]
      - k8s://[NAMESPACE]/[KEY]
```

### New Commands

#### `generate_key_pair`
Generate cosign key pairs (local or in KMS).

```yaml
parameters:
  output_prefix:
    type: string
    default: "cosign"
    description: "Prefix for generated .key and .pub files"
  kms:
    type: string
    default: ""
    description: "KMS URI to create keys in cloud provider"
  password_env:
    type: env_var_name
    default: "COSIGN_PASSWORD"
    description: "Environment variable containing key password"
```

### Use Cases Addressed
- Enterprise key management requirements
- Centralized key rotation and access control
- Compliance with security policies requiring HSM-backed keys
- Air-gapped environments with private KMS

---

## Phase 3: Blob Signing (Medium Priority)

**Goal:** Enable signing of arbitrary files (binaries, SBOMs, configs, etc.).

### New Commands

#### `sign_blob`
Sign arbitrary files with base64-encoded signature output.

```yaml
parameters:
  file:
    type: string
    description: "Path to file to sign"
  output_signature:
    type: string
    description: "Path to write signature file"
  output_certificate:
    type: string
    default: ""
    description: "Path to write certificate (keyless only)"
  output_bundle:
    type: string
    default: ""
    description: "Path to write verification bundle"
  private_key:
    type: env_var_name
    default: "COSIGN_PRIVATE_KEY"
  # Also supports keyless mode
  keyless:
    type: boolean
    default: false
```

#### `verify_blob`
Verify signatures on arbitrary files.

```yaml
parameters:
  file:
    type: string
  signature:
    type: string
    description: "Path to signature file or base64-encoded signature"
  public_key:
    type: env_var_name
    default: "COSIGN_PUBLIC_KEY"
  # Also supports keyless verification
  certificate_identity:
    type: string
    default: ""
  certificate_oidc_issuer:
    type: string
    default: ""
```

#### `attest_blob`
Attach attestations to arbitrary files.

#### `verify_blob_attestation`
Verify attestations on arbitrary files.

### Use Cases Addressed
- Sign release binaries (CLI tools, installers)
- Sign SBOM files before publishing
- Sign configuration files
- Sign Helm charts and other artifacts

---

## Phase 4: Supply Chain Workflows (Medium Priority)

**Goal:** Provide convenience commands for common supply chain security patterns.

### New Commands

#### `attach_sbom`
Attach an existing SBOM to a container image.

```yaml
parameters:
  image:
    type: string
  sbom:
    type: string
    description: "Path to SBOM file"
  sbom_type:
    type: enum
    enum: ["spdx", "cyclonedx", "syft"]
```

#### `download_sbom`
Download SBOM attached to an image.

```yaml
parameters:
  image:
    type: string
  output:
    type: string
    description: "Path to write SBOM"
```

#### `tree`
Display supply chain artifacts for an image (signatures, SBOMs, attestations).

```yaml
parameters:
  image:
    type: string
```

#### `copy`
Copy container images with their signatures and attestations.

```yaml
parameters:
  source:
    type: string
    description: "Source image reference"
  destination:
    type: string
    description: "Destination image reference"
  only:
    type: string
    default: ""
    description: "Comma-separated list: sig,att,sbom (empty = all)"
  platform:
    type: string
    default: ""
    description: "Platform filter for multi-arch images"
```

#### `clean`
Remove all signatures from an image (useful for testing/development).

```yaml
parameters:
  image:
    type: string
```

### Use Cases Addressed
- Multi-registry deployments (copy signed images between registries)
- SBOM distribution workflows
- Supply chain visibility (tree command)
- Development/testing cleanup

---

## Phase 5: Ready-to-Use Jobs (Medium Priority)

**Goal:** Provide complete workflow jobs that combine multiple commands.

### New Jobs

#### `sign_and_push`
Complete job: build, push, and sign a container image.

```yaml
parameters:
  image:
    type: string
  dockerfile:
    type: string
    default: "Dockerfile"
  context:
    type: string
    default: "."
  signing_method:
    type: enum
    enum: ["keyless", "private_key", "kms"]
  # Method-specific parameters...
```

#### `sign_and_attest`
Sign an image and attach SBOM/SLSA attestations.

```yaml
parameters:
  image:
    type: string
  generate_sbom:
    type: boolean
    default: true
  sbom_tool:
    type: enum
    enum: ["syft", "trivy"]
    default: "syft"
  signing_method:
    type: enum
    enum: ["keyless", "private_key", "kms"]
```

#### `verify_policy`
Verify image against a policy (signatures, attestations, etc.).

```yaml
parameters:
  image:
    type: string
  require_signature:
    type: boolean
    default: true
  require_sbom:
    type: boolean
    default: false
  require_slsa:
    type: boolean
    default: false
  signing_method:
    type: enum
    enum: ["keyless", "private_key"]
```

### Use Cases Addressed
- Simplified adoption (one job instead of multiple commands)
- Best practices enforcement
- Reduced configuration complexity

---

## Phase 6: Advanced Features (Lower Priority)

### Multi-Architecture Support
- Add `recursive` parameter to sign all images in a manifest list
- Platform-specific signing for multi-arch builds

### Enhanced Verification
- Policy-based verification using CUE or Rego
- GitHub Actions workflow claim verification
- Custom annotation matching

### Platform Expansion
- macOS executor support (darwin binaries)
- ARM64 executor support (arm64 binaries)

### Offline/Air-Gapped Improvements
- TUF root initialization command
- Bundle creation for offline verification
- Local image verification (from `cosign save`)

### Annotations Support
- Add `annotations` parameter to all signing commands
- Enable metadata attachment (git commit, CI URL, build info)

---

## Release Timeline (Suggested)

| Phase | Features | Target Version |
|-------|----------|----------------|
| 1 | Keyless signing/verification | v2.0.0 |
| 2 | KMS integration, generate-key-pair | v2.1.0 |
| 3 | Blob signing/verification | v2.2.0 |
| 4 | Supply chain workflows (copy, tree, attach_sbom) | v2.3.0 |
| 5 | Ready-to-use jobs | v2.4.0 |
| 6 | Advanced features | v3.0.0+ |

---

## Competitive Analysis

### Other Cosign Integrations

| Platform | Keyless | KMS | Blob | Jobs |
|----------|---------|-----|------|------|
| GitHub Actions (sigstore/cosign-installer) | Yes | Yes | Yes | No |
| GitLab CI (native) | Yes | Yes | Yes | No |
| cpanato/cosign-orb (CircleCI) | Yes | No | No | No |
| twdps/cosign (CircleCI) | No | No | No | Yes |
| **This orb (current)** | No | No | No | No |
| **This orb (planned)** | Yes | Yes | Yes | Yes |

### Differentiation Strategy
1. **Most complete CircleCI orb** - Cover all major Cosign features
2. **Enterprise-ready** - KMS support, private infrastructure mode
3. **Developer-friendly** - Jobs for common workflows
4. **Well-tested** - Comprehensive CI for v1/v2/v3 compatibility

---

## User Feedback Channels

To prioritize features based on real user needs:
1. GitHub Issues for feature requests
2. CircleCI Discuss forum engagement
3. Sigstore Slack community feedback
4. Usage analytics (if available through CircleCI orb registry)

---

## Security Considerations

### Keyless Signing Privacy
- Signatures include identity (email/subject) in public transparency log
- Users should understand PII implications before enabling keyless
- Provide documentation on identity policies

### Key Management Best Practices
- Recommend KMS over environment variable keys for production
- Document secure key rotation procedures
- Warn about key format incompatibilities between versions

### Attestation Integrity
- Validate predicate content before signing
- Document trust boundaries for third-party SBOM generators
- Support policy-based verification for critical workloads

---

## Implementation Priorities

Based on industry research and user demand:

### Must Have (Phase 1-2)
1. **Keyless signing** - Eliminates key management, industry standard
2. **KMS integration** - Enterprise requirement
3. **Keyless verification with identity matching** - Required for admission control

### Should Have (Phase 3-4)
4. **Blob signing** - Sign binaries, SBOMs, configs
5. **Copy command** - Multi-registry workflows
6. **SBOM workflow commands** - Growing compliance requirements

### Nice to Have (Phase 5-6)
7. **Pre-built jobs** - Developer convenience
8. **Policy verification** - Advanced use cases
9. **Multi-platform support** - Niche requirement

---

## Appendix: Cosign Command Coverage

| Cosign Command | Current Orb | Roadmap Phase |
|----------------|-------------|---------------|
| sign | sign_image | Current |
| verify | verify_image | Current |
| attest | attest | Current |
| verify-attestation | verify_attestation | Current |
| generate-key-pair | - | Phase 2 |
| sign-blob | - | Phase 3 |
| verify-blob | - | Phase 3 |
| attest-blob | - | Phase 3 |
| verify-blob-attestation | - | Phase 3 |
| attach sbom | - | Phase 4 |
| download sbom | - | Phase 4 |
| copy | - | Phase 4 |
| tree | - | Phase 4 |
| clean | - | Phase 4 |
| initialize | - | Phase 6 |
| save/load | - | Phase 6 |
