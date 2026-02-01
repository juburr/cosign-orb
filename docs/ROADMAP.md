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

## Security Model: Understanding the Trust Boundaries

A critical consideration when planning signing infrastructure is understanding where secrets live and what happens if they're compromised. This section analyzes three approaches and their security implications.

### The Problem with Stored Secrets

CircleCI contexts are the current mechanism for storing signing credentials. The fundamental question is: **if an attacker compromises a CircleCI context, what can they do?**

### Tier 1: Base64 Private Key in Context (Current Approach)

```
CircleCI Context ──────────────────────────────► Signing Key
         │
         ▼
   [COSIGN_PRIVATE_KEY]   (base64-encoded)
   [COSIGN_PASSWORD]
```

**Security characteristics:**
- Private key stored directly in CircleCI
- Compromise of context = **permanent key theft**
- Attacker can sign anything, anywhere, indefinitely
- No audit trail of key usage
- Must generate new keys and re-sign everything if compromised

**When appropriate:** Development/testing, low-security requirements, or when simplicity outweighs security concerns.

### Tier 2: Static Cloud Credentials → KMS (Intermediate)

```
CircleCI Context ──► AWS Credentials ──► KMS ──► Sign Operation
         │                                           │
         ▼                                           ▼
   [AWS_ACCESS_KEY_ID]                    Key never leaves HSM
   [AWS_SECRET_ACCESS_KEY]                CloudTrail audit log
```

**Security characteristics:**
- Cloud credentials stored in CircleCI (still a stored secret)
- Key material **never leaves the HSM** - attacker cannot extract it
- Compromise allows signing **until credentials are rotated**
- **Audit trail** via CloudTrail/Cloud Logging shows all signing operations
- Fine-grained IAM policies can restrict operations, source IPs, time windows
- Credential rotation locks out attacker without regenerating signing keys

**Improvement over Tier 1:**
| Factor | Base64 Key | Static Creds → KMS |
|--------|------------|-------------------|
| Key extraction possible | Yes | No |
| Post-compromise recovery | Regenerate keys | Rotate credentials |
| Audit trail | None | Full |
| Access control granularity | None | IAM policies |

**When appropriate:** Organizations wanting audit trails and KMS benefits, but not yet ready for OIDC federation. This is a **stepping stone**, not an end goal.

### Tier 3: OIDC Federation → KMS or Keyless (Recommended)

```
CircleCI Job ──► OIDC Token ──► Cloud Provider ──► Temp Creds ──► Sign
      │              │               │                  │
      ▼              ▼               ▼                  ▼
   No stored     JWT signed      STS/Workload       15-min TTL
   secrets       by CircleCI     Identity           Auto-expire
```

**Security characteristics:**
- **No secrets stored in CircleCI contexts**
- OIDC token is job-specific, short-lived (~60 minutes)
- Cloud provider exchanges token for temporary credentials (~15 minutes)
- Attacker must have an **active CI job** to sign - cannot sign externally
- IAM trust policy restricts which projects/branches can assume the role
- Full audit trail with job-level granularity

**How it works:**
1. CircleCI job starts and receives `$CIRCLE_OIDC_TOKEN` (a signed JWT)
2. JWT contains claims: `org_id`, `project_id`, `branch`, `user_id`
3. Cloud provider validates JWT signature against CircleCI's OIDC endpoint
4. If trust policy allows, provider issues temporary credentials
5. Job uses temporary credentials to sign via KMS (or Fulcio for keyless)
6. Credentials automatically expire

### Why Does AWS Trust CircleCI's JWT?

AWS doesn't inherently trust CircleCI - **you explicitly configure AWS to trust CircleCI's OIDC endpoint**. This is a critical one-time setup step.

**Step 1: Register CircleCI as an Identity Provider**

You create an OIDC Identity Provider in your AWS account:

```bash
aws iam create-open-id-connect-provider \
  --url "https://oidc.circleci.com/org/YOUR_ORG_ID" \
  --client-id-list "YOUR_ORG_ID" \
  --thumbprint-list "..."
```

This tells AWS: "I trust JWTs signed by this issuer."

**Step 2: AWS Fetches CircleCI's Public Keys**

When you register the provider, AWS retrieves CircleCI's public signing keys from their OIDC discovery endpoint:

```
https://oidc.circleci.com/org/YOUR_ORG_ID/.well-known/openid-configuration
    └── returns jwks_uri ──►
https://oidc.circleci.com/org/YOUR_ORG_ID/.well-known/jwks.json
    └── contains public keys for JWT verification
```

**Step 3: JWT Verification Flow**

```
┌─────────────┐                              ┌─────────────┐
│  CircleCI   │  1. Job starts, provides     │   CI Job    │
│   Server    │     signed JWT ────────────► │             │
└──────┬──────┘     ($CIRCLE_OIDC_TOKEN)     └──────┬──────┘
       │                                            │
       │                                            │ 2. AssumeRoleWithWebIdentity
       │                                            │    (sends JWT)
       │                                            ▼
       │                                     ┌─────────────┐
       │  3. Fetch public keys (if not       │   AWS STS   │
       │◄─── cached from registration) ──────│             │
       │                                     └──────┬──────┘
       │  4. Return JWKS (public keys)              │
       │─────────────────────────────────────►      │
                                                    │ 5. Verify:
                                                    │    - JWT signature (using public key)
                                                    │    - Issuer matches registered provider
                                                    │    - Token not expired
                                                    │    - Claims match trust policy
                                                    ▼
                                             ┌─────────────┐
                                             │ Temp Creds  │
                                             │ (15 min)    │
                                             └─────────────┘
```

**What AWS Verifies:**
| Check | Description |
|-------|-------------|
| Signature | JWT was signed by CircleCI's private key (verified via public key) |
| Issuer (`iss`) | Matches the registered OIDC provider URL |
| Audience (`aud`) | Matches expected value in trust policy |
| Expiration (`exp`) | Token hasn't expired |
| Custom claims | Your IAM conditions (project ID, branch, etc.) |

**Why This Is Secure:**
- **Only CircleCI has the private key** - Nobody else can forge valid JWTs
- **You control the trust policy** - You decide which projects/branches can assume roles
- **Short-lived tokens** - JWTs expire in ~60 min, credentials in ~15 min
- **No shared secrets** - Unlike static credentials, there's nothing to steal

**CircleCI OIDC Token Claims:**
```json
{
  "iss": "https://oidc.circleci.com/org/<org-id>",
  "sub": "org/<org-id>/project/<project-id>/user/<user-id>",
  "aud": "<org-id>",
  "oidc.circleci.com/project-id": "<project-id>",
  "oidc.circleci.com/context-ids": ["<context-id>"]
}
```

**AWS IAM Trust Policy Example:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/oidc.circleci.com/org/ORG_ID"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.circleci.com/org/ORG_ID:aud": "ORG_ID"
      },
      "StringLike": {
        "oidc.circleci.com/org/ORG_ID:sub": "org/ORG_ID/project/PROJECT_ID/*"
      }
    }
  }]
}
```

### Security Comparison Summary

| Approach | Stored Secrets | Compromise Impact | Recovery |
|----------|---------------|-------------------|----------|
| Base64 key in context | Private key | Permanent signing capability | Regenerate all keys |
| Static cloud creds → KMS | Cloud credentials | Sign until rotation | Rotate credentials |
| **OIDC → KMS** | **None** | **Must run CI job** | **Nothing to rotate** |
| **OIDC → Keyless (Fulcio)** | **None** | **Must run CI job** | **Nothing to rotate** |

### CircleCI Server (On-Premises) OIDC Support

OIDC is supported in **CircleCI Server 4.x** but requires additional configuration because you're running your own identity provider.

**The difference from CircleCI Cloud:**
- Cloud: CircleCI manages the signing keys; you just trust their endpoint
- Server: **You generate and manage your own signing keys**

**Setup steps:**

1. **Generate a JSON Web Key (JWK) pair** - This is your Server's signing key
   ```bash
   # Generate JWK and save to file
   # Private key stays in Server, public key is advertised via OIDC endpoint
   ```

2. **Configure JWK in Helm values:**
   ```yaml
   oidc:
     json_web_keys: "<base64-encoded-jwk>"
   ```

3. **Register your Server as an OIDC provider in AWS:**
   ```bash
   aws iam create-open-id-connect-provider \
     --url "https://your-circleci-server.example.com/org/ORG_ID" \
     --client-id-list "ORG_ID" \
     --thumbprint-list "..."
   ```

The OIDC issuer URL for Server installations follows the pattern:
`https://<your-circleci-server-domain>/org/<organization-id>`

**Trust model for Server:**
```
Your CircleCI Server ──► Signs JWTs with your private key
         │
         ▼
Your OIDC endpoint ──► Advertises your public key via /.well-known/jwks.json
         │
         ▼
AWS (your account) ──► Fetches public key, verifies JWTs, issues temp creds
```

**Note:** Ensure the JWK contains required fields (`alg`, `kid`) to avoid `InvalidIdentityToken` errors when assuming AWS roles.

### Recommendations by Use Case

| Use Case | Recommended Approach |
|----------|---------------------|
| Open source projects | Keyless (Fulcio) via OIDC |
| Enterprise with cloud KMS | OIDC → Cloud KMS |
| Air-gapped / private infrastructure | Static credentials → private KMS |
| Development / testing | Base64 keys in context |
| Highly regulated (audit required) | OIDC → KMS with CloudTrail |

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

**Goal:** Enable enterprise users to leverage cloud-managed keys with proper access controls, **preferably via OIDC federation** to eliminate stored secrets.

### Authentication Methods (In Order of Preference)

#### Method A: OIDC Federation (Recommended)
No secrets stored in CircleCI. Uses `$CIRCLE_OIDC_TOKEN` to assume a cloud IAM role.

```yaml
parameters:
  kms_key:
    type: string
    description: "KMS key URI (e.g., awskms://alias/cosign-key)"
  oidc_role_arn:
    type: string
    description: "IAM role ARN to assume via OIDC (e.g., arn:aws:iam::123456789:role/cosign-signing)"
  # AWS automatically uses CIRCLE_OIDC_TOKEN for AssumeRoleWithWebIdentity
```

**Prerequisites:**
1. Configure CircleCI as an OIDC identity provider in your cloud account
2. Create an IAM role with trust policy allowing your CircleCI org/project
3. Grant the role permission to use the specific KMS key for signing

#### Method B: Static Credentials (Fallback)
For environments where OIDC is not available (older CircleCI Server versions, air-gapped networks with no external OIDC trust).

```yaml
parameters:
  kms_key:
    type: string
    description: "KMS key URI"
  # Uses AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY from context
```

**When to use static credentials:**
- CircleCI Server < 4.x without OIDC support
- Air-gapped environments where cloud KMS cannot trust external OIDC providers
- Legacy integrations being migrated incrementally

### Enhanced `sign_image` Command
Add support for KMS key references with OIDC-first authentication:

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
  oidc_role_arn:
    type: string
    default: ""
    description: |
      (Recommended) IAM role to assume via OIDC. If provided, uses
      $CIRCLE_OIDC_TOKEN for authentication instead of static credentials.
  aws_region:
    type: string
    default: "us-east-1"
    description: "AWS region for KMS operations"
```

### Implementation: OIDC → AWS KMS Flow

```bash
#!/bin/bash
# Assume role using CircleCI OIDC token
if [[ -n "${OIDC_ROLE_ARN}" ]]; then
  CREDS=$(aws sts assume-role-with-web-identity \
    --role-arn "${OIDC_ROLE_ARN}" \
    --role-session-name "circleci-cosign-${CIRCLE_BUILD_NUM}" \
    --web-identity-token "${CIRCLE_OIDC_TOKEN}" \
    --duration-seconds 900)

  export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')
fi

# Sign using KMS key (credentials are temporary, auto-expire)
cosign sign --key "${KMS_KEY}" "${IMAGE}"
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
  oidc_role_arn:
    type: string
    default: ""
    description: "IAM role to assume via OIDC for KMS key creation"
```

#### `setup_oidc_aws`
Helper command to configure AWS credentials via OIDC (can be used before other commands).

```yaml
parameters:
  role_arn:
    type: string
    description: "IAM role ARN to assume"
  region:
    type: string
    default: "us-east-1"
  session_duration:
    type: integer
    default: 900
    description: "Session duration in seconds (max 3600)"
```

### Documentation Requirements
- Step-by-step guide for setting up OIDC trust with AWS, GCP, Azure
- IAM policy examples with least-privilege permissions
- Troubleshooting guide for common OIDC errors
- Migration guide from static credentials to OIDC

### Use Cases Addressed
- Enterprise key management requirements
- Centralized key rotation and access control
- Compliance with security policies requiring HSM-backed keys
- **Zero stored secrets** with OIDC federation
- Air-gapped environments with private KMS (static credentials fallback)

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

### Authentication Hierarchy
See [Security Model: Understanding the Trust Boundaries](#security-model-understanding-the-trust-boundaries) for detailed analysis.

**Recommended progression:**
1. **Start with keyless (Fulcio)** for open source or when transparency is acceptable
2. **Use OIDC → KMS** for enterprises needing private keys with no stored secrets
3. **Fall back to static credentials → KMS** only when OIDC is unavailable
4. **Avoid base64 keys in contexts** except for development/testing

### Keyless Signing Privacy
- Signatures include identity (email/subject) in public transparency log
- Users should understand PII implications before enabling keyless
- Provide documentation on identity policies
- Consider whether your organization's CI identity should be publicly visible

### OIDC Security Best Practices
- Restrict IAM trust policies to specific CircleCI projects, not entire organizations
- Use `circleci_project_id` claim to limit which projects can sign
- Set short session durations (15 minutes) for temporary credentials
- Consider IP restrictions for additional defense-in-depth
- Regularly audit CloudTrail/Cloud Logging for unexpected signing operations

### Key Management Best Practices
- **Prefer OIDC → KMS** over static credentials for production
- If using static credentials, rotate regularly and use dedicated signing-only credentials
- Document secure key rotation procedures
- Warn about key format incompatibilities between Cosign versions (v1 vs v2+)

### Attestation Integrity
- Validate predicate content before signing
- Document trust boundaries for third-party SBOM generators
- Support policy-based verification for critical workloads

---

## Implementation Priorities

Based on industry research, user demand, and security analysis:

### Must Have (Phase 1-2)
1. **Keyless signing via OIDC** - Zero key management, industry standard, no stored secrets
2. **OIDC → KMS integration** - Enterprise requirement with no stored secrets
3. **Keyless verification with identity matching** - Required for Kubernetes admission control
4. **Static credentials → KMS** - Fallback for environments without OIDC support

### Should Have (Phase 3-4)
5. **Blob signing** - Sign binaries, SBOMs, configs
6. **Copy command** - Multi-registry workflows
7. **SBOM workflow commands** - Growing compliance requirements

### Nice to Have (Phase 5-6)
8. **Pre-built jobs** - Developer convenience
9. **Policy verification** - Advanced use cases
10. **Multi-platform support** - Niche requirement

### Security-First Approach
The implementation order prioritizes eliminating stored secrets:
- Phase 1 (keyless) and Phase 2 (OIDC → KMS) both achieve **zero stored secrets**
- Static credential support is included for backward compatibility, not as a recommendation
- Documentation should steer users toward OIDC-based approaches

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
