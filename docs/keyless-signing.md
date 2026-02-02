# Keyless Signing Guide

This guide covers keyless container image signing and attestation using CircleCI OIDC tokens and the Sigstore public infrastructure (Fulcio and Rekor).

## Overview

Keyless signing eliminates the need to manage long-lived signing keys. Instead, signatures are tied to your CI identity through OIDC (OpenID Connect).

**Benefits:**
- No keys to generate, store, rotate, or protect
- Signatures are tied to your CI pipeline identity
- Automatic audit trail via public transparency log
- Industry-standard approach used by major open source projects

**Trade-offs:**
- Signatures are recorded in a public transparency log (Rekor)
- Your CircleCI organization and project IDs are visible in the log
- Requires internet access to Sigstore infrastructure

## Security Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CircleCI Pipeline                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. Request OIDC Token                                                      │
│     ┌─────────────┐                                                        │
│     │  CircleCI   │ ─── circleci run oidc get ───►  OIDC Token (JWT)       │
│     │    Job      │     with audience "sigstore"                           │
│     └─────────────┘                                                        │
│            │                                                                │
│            ▼                                                                │
│  2. Exchange Token for Certificate                                          │
│     ┌─────────────┐         ┌─────────────┐                                │
│     │   Cosign    │ ──────► │   Fulcio    │  (Sigstore Certificate Authority)
│     │             │         │             │                                │
│     └─────────────┘         └─────────────┘                                │
│            │                       │                                        │
│            │                       ▼                                        │
│            │              Validates OIDC token                             │
│            │              Issues short-lived certificate (10 min)          │
│            │              Certificate contains:                            │
│            │                - Subject: CircleCI project URL                │
│            │                - Issuer: CircleCI OIDC endpoint               │
│            ▼                                                                │
│  3. Sign Image                                                              │
│     ┌─────────────┐         ┌─────────────┐                                │
│     │   Cosign    │ ──────► │   Rekor     │  (Transparency Log)            │
│     │             │         │             │                                │
│     └─────────────┘         └─────────────┘                                │
│            │                       │                                        │
│            │                       ▼                                        │
│            │              Records signature permanently                    │
│            │              Provides inclusion proof                         │
│            ▼                                                                │
│  4. Push Signature to Registry                                              │
│     ┌─────────────────────────┐                                            │
│     │   Container Registry    │                                            │
│     │   (image + signature)   │                                            │
│     └─────────────────────────┘                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### CircleCI Cloud

OIDC tokens are **automatically available** on CircleCI Cloud - no configuration required!

You just need to know your **Organization ID** (a UUID):
1. Go to **Organization Settings** → **Overview**
2. Copy the **Organization ID** (format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)

> **Note**: The Organization ID is a UUID, not your organization's username/slug.

### CircleCI Server (Self-Hosted)

CircleCI Server 4.x+ supports OIDC, but requires additional configuration:

1. **Generate a JSON Web Key (JWK) pair** for your Server instance
2. **Configure the JWK in Helm values:**
   ```yaml
   oidc:
     json_web_keys: "<base64-encoded-jwk>"
   ```
3. **Ensure the JWK contains required fields** (`alg`, `kid`) to avoid `InvalidIdentityToken` errors

The OIDC issuer URL for Server follows this pattern:
```
https://<your-circleci-server-domain>/org/<organization-id>
```

For detailed setup instructions, see the [CircleCI Server OIDC documentation](https://circleci.com/docs/openid-connect-tokens/).

## Quick Start

### 1. Verify OIDC is Available

First, confirm OIDC tokens are available in your environment:

```yaml
version: 2.1

orbs:
  cosign: juburr/cosign-orb@1.x

jobs:
  check-oidc:
    docker:
      - image: cimg/base:current
    steps:
      - cosign/check_oidc  # Displays OIDC token claims
```

### 2. Sign an Image (Keyless)

```yaml
jobs:
  build-and-sign:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - setup_remote_docker

      - run:
          name: Build and push image
          command: |
            docker build -t myregistry.com/myimage:${CIRCLE_SHA1} .
            docker push myregistry.com/myimage:${CIRCLE_SHA1}

      - cosign/install
      - cosign/sign_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          keyless: true
          # No keys required! Uses CircleCI OIDC automatically
```

### 3. Verify a Keyless Signature

**Minimal configuration** (same-project verification):

```yaml
steps:
  - cosign/install
  - cosign/verify_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      keyless: true
      # OIDC issuer and certificate identity are auto-detected from
      # CIRCLE_ORGANIZATION_ID and CIRCLE_PROJECT_ID
```

> **Important**: Auto-detection only works when verifying images signed by the **same project**. The orb uses your current `CIRCLE_PROJECT_ID` to build the expected certificate identity. If you're verifying an image signed by a different project (or organization), you must specify the signing project's IDs explicitly.

**With explicit parameters** (for cross-project verification or outside CircleCI):

```yaml
steps:
  - cosign/install
  - cosign/verify_image:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      keyless: true
      certificate_oidc_issuer: "https://oidc.circleci.com/org/<your-org-id>"
      certificate_identity_regexp: "https://circleci.com/api/v2/projects/<your-project-id>/pipeline-definitions/.*"
```

### 4. Attach a Keyless Attestation

Attach attestations (SBOMs, provenance, vulnerability reports) using keyless signing:

```yaml
steps:
  - cosign/install
  - cosign/attest:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate: "./sbom.spdx.json"
      predicate_type: "spdxjson"
      keyless: true
      # No keys required! Uses CircleCI OIDC automatically
```

### 5. Verify a Keyless Attestation

**Minimal configuration** (same-project verification):

```yaml
steps:
  - cosign/install
  - cosign/verify_attestation:
      image: "myregistry.com/myimage:${CIRCLE_SHA1}"
      predicate_type: "spdxjson"
      keyless: true
      # Auto-detects from CIRCLE_ORGANIZATION_ID and CIRCLE_PROJECT_ID
```

**With explicit parameters** (for cross-project verification):

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

### 6. Sign a Blob (Keyless)

Sign arbitrary files (binaries, SBOMs, config files) using keyless signing:

```yaml
steps:
  - cosign/install
  - cosign/sign_blob:
      blob: "./artifact.tar.gz"
      keyless: true
      signature_output: "./artifact.tar.gz.sig"
      certificate_output: "./artifact.tar.gz.crt"
      # No keys required! Uses CircleCI OIDC automatically
```

> **Important**: Unlike image signing where certificates are stored in the registry, blob signing requires you to save both the signature and certificate files. The `certificate_output` parameter is required for keyless blob signing.

### 7. Verify a Keyless Blob Signature

**Minimal configuration** (same-project verification):

```yaml
steps:
  - cosign/install
  - cosign/verify_blob:
      blob: "./artifact.tar.gz"
      signature: "./artifact.tar.gz.sig"
      certificate: "./artifact.tar.gz.crt"
      keyless: true
      # Auto-detects from CIRCLE_ORGANIZATION_ID and CIRCLE_PROJECT_ID
```

**With explicit parameters** (for cross-project verification):

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

> **Note**: The `certificate` parameter is required for keyless blob verification. This is the certificate file generated during signing (`certificate_output`).

## Understanding Certificate Identity

When Fulcio issues a certificate for CircleCI, it transforms the OIDC claims into a specific format:

| Certificate Field | Value |
|-------------------|-------|
| Subject (SAN URI) | `https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/<pipeline-def-id>` |
| Issuer | `https://oidc.circleci.com/org/<org-id>` |

### Additional Certificate Extensions

Fulcio embeds additional provenance information from CircleCI's OIDC claims:

| Extension | Description | Example Value |
|-----------|-------------|---------------|
| Build Config URI | Link to pipeline configuration | `https://circleci.com/api/v2/pipeline/<pipeline-id>/config` |
| Build Signer URI | Same as subject | `https://circleci.com/api/v2/projects/.../pipeline-definitions/...` |
| Run Invocation URI | Link to specific workflow/job | `https://circleci.com/workflow/<workflow-id>/job/<job-id>` |
| Source Repository URI | VCS repository URL | `https://github.com/your-org/your-repo` |
| Source Repository Ref | Git reference | `refs/heads/main` |
| Runner Environment | Execution environment | `circleci-hosted` or `ssh-rerun` |

### Finding Your IDs

You need three IDs for keyless verification:

1. **Organization ID** - Go to **Organization Settings** → **Overview**
2. **Project ID** - Go to **Project Settings** → **Overview**
3. **Pipeline Definition ID** - Go to **Project Settings** and look for your pipeline definition ID

Run `cosign/check_oidc` in a job to see your OIDC token claims and verification parameters:

```
=== Key Values for Keyless Signing ===
OIDC Issuer: https://oidc.circleci.com/org/4b7f2900-a61f-4b16-acdd-145f3f98b3df
Org ID: 4b7f2900-a61f-4b16-acdd-145f3f98b3df
Project ID: 37839385-e92c-499b-8ad7-8be5f4544a81
Pipeline Definition ID: 46322274-27e9-570a-832a-d0be5c3987b9
VCS Origin: https://github.com/your-org/your-repo

=== Verification Parameters ===
For keyless verification, use these values:

  certificate_oidc_issuer: "https://oidc.circleci.com/org/4b7f2900-a61f-4b16-acdd-145f3f98b3df"

  # Option 1: Exact match
  certificate_identity: "https://circleci.com/api/v2/projects/37839385-e92c-499b-8ad7-8be5f4544a81/pipeline-definitions/<your-pipeline-def-id>"

  # Option 2: Regexp match
  certificate_identity_regexp: "https://circleci.com/api/v2/projects/37839385-e92c-499b-8ad7-8be5f4544a81/pipeline-definitions/.*"
```

### Understanding Auto-Detection vs Explicit Parameters

When you run `cosign/verify_image` with `keyless: true` and no other parameters, the orb auto-detects verification parameters from your CircleCI environment:

| What's Auto-Detected | From | Value Generated |
|---------------------|------|-----------------|
| OIDC Issuer | `CIRCLE_ORGANIZATION_ID` | `https://oidc.circleci.com/org/<your-org-id>` |
| Certificate Identity | `CIRCLE_PROJECT_ID` | `https://circleci.com/api/v2/projects/<your-project-id>/pipeline-definitions/.*` |

**This works perfectly when:**
- You're verifying an image signed by the **same project**
- The signing and verification happen in the **same organization**

**You need explicit parameters when:**
- Verifying an image signed by a **different project** (use that project's ID)
- Verifying an image signed by a **different organization** (use that org's ID)
- Verifying **outside of CircleCI** (no environment variables available)
- You want **stricter verification** with exact identity matching

### Verification Options

You have two options for certificate identity verification:

**Option 1: Exact Match (Recommended for production)**

If you know your `PIPELINE_DEFINITION_ID`, use exact matching for stricter verification:

```yaml
- cosign/verify_image:
    image: "myregistry.com/myimage:${CIRCLE_SHA1}"
    keyless: true
    certificate_oidc_issuer: "https://oidc.circleci.com/org/<org-id>"
    certificate_identity: "https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/<pipeline-def-id>"
```

**Option 2: Regexp Match (Flexible)**

Use regexp if you want to accept any pipeline definition from your project:

```yaml
- cosign/verify_image:
    image: "myregistry.com/myimage:${CIRCLE_SHA1}"
    keyless: true
    certificate_oidc_issuer: "https://oidc.circleci.com/org/<org-id>"
    certificate_identity_regexp: "https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/.*"
```

> **Note**: The regexp uses Go regular expression syntax. Special characters like `.` in URLs should match literally in practice, but for strict matching you can escape them: `https://circleci\.com/api/v2/projects/...`

## Version Compatibility

| Cosign Version | Keyless Image Sign | Keyless Image Verify | Keyless Blob Sign | Keyless Blob Verify | Notes |
|----------------|--------------------|----------------------|-------------------|---------------------|-------|
| v1.x | Yes | Partial | Yes | Partial | Identity regexp not supported; issuer-only verification |
| v2.x | Yes | Yes | Yes | Yes | Full support |
| v3.x | Yes | Yes | Yes | Yes | Full support |

### Cosign v1 Limitations

Cosign v1 does not support `--certificate-identity-regexp`. When using v1 for keyless verification:

- The orb will **skip identity verification** with a warning
- **Issuer verification still works** (confirms signature came from your CircleCI org)
- For full identity verification, upgrade to Cosign v2+

Example v1 output:
```
WARNING: Cosign v1 does not support --certificate-identity-regexp
Skipping identity verification (issuer will still be verified).
For full identity verification, upgrade to Cosign v2+.
```

## Privacy Considerations

Keyless signatures are recorded in the **public Rekor transparency log**. This means:

1. **Your CircleCI organization ID is visible** in the certificate issuer
2. **Your project ID is visible** in the certificate subject
3. **Signing timestamps are recorded** permanently
4. **Anyone can query Rekor** to see when your images were signed

This is by design - transparency logs provide an audit trail. However, if you need privacy, use [private key signing](private-key-signing.md) instead.

### What's Recorded in Rekor

Each signature entry in Rekor contains certificate metadata including:

```json
{
  "certificateSubject": "https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/<pipeline-def-id>",
  "certificateIssuer": "https://oidc.circleci.com/org/<org-id>",
  "integratedTime": 1705315800,
  "logIndex": 12345678,
  "logID": "c0d23d6ad406973f9559f3ba2d1ca01f84147d8ffc5b8445c224f98b9591801d"
}
```

You can search for your signatures using the [Rekor Search UI](https://search.sigstore.dev/) or the CLI:
```bash
rekor-cli search --sha sha256:<image-digest>
```

## How OIDC Trust Works

You might wonder: how does Fulcio trust CircleCI's OIDC tokens?

### The Trust Chain

1. **Fulcio has a configured list of trusted OIDC issuers**
   - CircleCI is included: `https://oidc.circleci.com/org/*`

2. **When you sign, Cosign sends your OIDC token to Fulcio**

3. **Fulcio validates the token:**
   - Fetches CircleCI's public keys from their OIDC discovery endpoint
   - Verifies the JWT signature
   - Checks token expiration
   - Confirms the issuer matches the configured pattern

4. **If valid, Fulcio issues a short-lived certificate (10 minutes)**

5. **Cosign uses the certificate to sign, then the certificate expires**

### Why This Is Secure

- **CircleCI's private key never leaves CircleCI** - they sign the OIDC tokens
- **Tokens are short-lived** - typically 60 minutes
- **Certificates are very short-lived** - 10 minutes
- **Signatures are recorded in Rekor** - providing an immutable audit trail
- **No secrets to steal** - everything is ephemeral

## Sigstore Components

### Fulcio (Certificate Authority)

Fulcio issues short-lived code signing certificates based on OIDC identity. It:
- Validates OIDC tokens from trusted providers (GitHub, GitLab, CircleCI, etc.)
- Issues X.509 certificates with embedded identity information
- Certificates expire in 10 minutes (no revocation needed)

**Public instance:** `https://fulcio.sigstore.dev`

### Rekor (Transparency Log)

Rekor is an immutable, append-only log of signing events. It:
- Records all signatures permanently
- Provides cryptographic proof of inclusion
- Enables auditing and verification
- Prevents backdating attacks

**Public instance:** `https://rekor.sigstore.dev`

You can search Rekor for your signatures:
```bash
rekor-cli search --email your-identity
```

## Complete Example

### Minimal Configuration (Recommended)

When signing and verifying within the same CircleCI organization, everything is auto-detected:

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

      - run:
          name: Build and push image
          command: |
            docker build -t myregistry.com/myimage:${CIRCLE_SHA1} .
            docker push myregistry.com/myimage:${CIRCLE_SHA1}

      - cosign/install
      - cosign/sign_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          keyless: true

      # Optionally attach an SBOM attestation
      - run:
          name: Generate SBOM
          command: syft myregistry.com/myimage:${CIRCLE_SHA1} -o spdx-json > sbom.spdx.json
      - cosign/attest:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          predicate: "sbom.spdx.json"
          predicate_type: "spdxjson"
          keyless: true

  verify:
    docker:
      - image: cimg/base:current
    steps:
      - cosign/install
      - cosign/verify_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          keyless: true
          # Auto-detects from CIRCLE_ORGANIZATION_ID and CIRCLE_PROJECT_ID
      - cosign/verify_attestation:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          predicate_type: "spdxjson"
          keyless: true

workflows:
  build-sign-verify:
    jobs:
      - build-and-sign
      - verify:
          requires:
            - build-and-sign
```

### Advanced Configuration

For cross-project verification, stricter identity matching, or running outside CircleCI:

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
      - cosign/check_oidc  # Optional: debug OIDC claims

      - run:
          name: Build and push image
          command: |
            docker build -t myregistry.com/myimage:${CIRCLE_SHA1} .
            docker push myregistry.com/myimage:${CIRCLE_SHA1}

      - cosign/install:
          version: "3.0.4"
      - cosign/sign_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          keyless: true
          annotations: "commit=${CIRCLE_SHA1},pipeline=${CIRCLE_PIPELINE_NUMBER}"

  # Verify with exact identity match (requires PIPELINE_DEFINITION_ID from Project Settings)
  verify-exact:
    docker:
      - image: cimg/base:current
    environment:
      PIPELINE_DEFINITION_ID: "46322274-27e9-570a-832a-d0be5c3987b9"
    steps:
      - cosign/install:
          version: "3.0.4"
      - run:
          name: Verify with exact identity
          command: |
            cosign verify myregistry.com/myimage:${CIRCLE_SHA1} \
              --certificate-oidc-issuer "https://oidc.circleci.com/org/${CIRCLE_ORGANIZATION_ID}" \
              --certificate-identity "https://circleci.com/api/v2/projects/${CIRCLE_PROJECT_ID}/pipeline-definitions/${PIPELINE_DEFINITION_ID}"

  # Cross-project verification (explicit parameters)
  verify-cross-project:
    docker:
      - image: cimg/base:current
    steps:
      - cosign/install:
          version: "3.0.4"
      - cosign/verify_image:
          image: "myregistry.com/myimage:${CIRCLE_SHA1}"
          keyless: true
          certificate_oidc_issuer: "https://oidc.circleci.com/org/SIGNING_ORG_ID"
          certificate_identity_regexp: "https://circleci.com/api/v2/projects/SIGNING_PROJECT_ID/pipeline-definitions/.*"

workflows:
  build-sign-verify:
    jobs:
      - build-and-sign
      - verify-exact:
          requires:
            - build-and-sign
      - verify-cross-project:
          requires:
            - build-and-sign
```

> **Note**: For cross-project verification, replace `SIGNING_ORG_ID` and `SIGNING_PROJECT_ID` with the organization and project IDs where the image was originally signed.

## Troubleshooting

### "CIRCLE_OIDC_TOKEN is not set"

OIDC tokens may not be available if:
1. You're using CircleCI Server < 4.x without OIDC configuration
2. Your CircleCI plan doesn't include OIDC tokens

Run `cosign/check_oidc` to diagnose.

### "Fulcio returned 400: error processing identity token"

The OIDC token audience is incorrect. The orb handles this automatically by requesting a token with the `sigstore` audience:
```bash
circleci run oidc get --claims '{"aud": "sigstore"}'
```

If you're manually calling Cosign, ensure you set:
```bash
export SIGSTORE_ID_TOKEN=$(circleci run oidc get --claims '{"aud": "sigstore"}')
```

### "no matching signatures: expected identity not found"

Your verification parameters don't match the certificate:

1. **Check the certificate_oidc_issuer** - Must match `https://oidc.circleci.com/org/<org-id>` exactly
2. **Check the certificate_identity or regexp** - Must match the certificate subject:
   - Exact: `https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/<pipeline-def-id>`
   - Regexp: `https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/.*`
3. **Verify your IDs are correct** - Run `cosign/check_oidc` to see the actual values

**Debug tip**: Extract the certificate from a signed image to see the actual identity:
```bash
cosign verify myregistry.com/myimage:tag \
  --certificate-identity-regexp='.*' \
  --certificate-oidc-issuer-regexp='.*' 2>&1 | head -50
```

### "cannot specify service URLs and use signing config" (v3 only)

Cosign v3 requires `--use-signing-config=false` when specifying explicit Fulcio/Rekor URLs. The orb handles this automatically.

### "unknown flag: --certificate-identity-regexp" (v1 only)

Cosign v1 does not support regexp matching for certificate identity. The orb handles this gracefully by skipping identity verification with a warning. Upgrade to Cosign v2+ for full identity verification support.

### "PKCE" or "interactive login" errors (v1)

Cosign v1 may try to start an interactive OIDC flow. Ensure:
1. You're passing `--identity-token` explicitly
2. The `SIGSTORE_ID_TOKEN` environment variable is set
3. You're using `-y` flag to skip confirmation prompts

The orb handles these automatically.

## Comparison with Private Key Signing

| Aspect | Keyless (OIDC) | Private Key |
|--------|----------------|-------------|
| Key management | None | You manage keys |
| Setup | Minimal | Medium |
| Transparency | Public log | Private |
| Identity | OIDC-based | Key-based |
| Best for | Public projects, convenience | Air-gapped, compliance |
| Audit trail | Automatic (Rekor) | Manual |

## Policy Validation

You can validate provenance claims from signed artifacts to enforce security policies. For example, you might want to reject artifacts signed during SSH debug sessions.

The certificate extensions include a `runner_environment` claim that indicates how the job was executed:
- `circleci-hosted` - Normal CI execution
- `ssh-rerun` - SSH debug session (potentially compromised)

Example policy check (after extracting certificate extensions):
```bash
if [ "$runner_environment" = "ssh-rerun" ]; then
    echo "ERROR: Artifact was signed during SSH debug session"
    exit 1
fi
```

For a complete example of policy validation, see CircleCI's [sign-and-publish-examples](https://github.com/CircleCI-Public/sign-and-publish-examples) repository.

## Staging Environment

For testing, you can use Sigstore's staging environment instead of production. This is useful for development without cluttering the production transparency log.

The orb currently uses production Sigstore infrastructure. To use staging, you would need to:
1. Initialize the staging TUF root
2. Use staging Fulcio/Rekor URLs

See the [sign-and-publish-examples](https://github.com/CircleCI-Public/sign-and-publish-examples) repository for staging configuration.

## Further Reading

- [Sigstore Documentation](https://docs.sigstore.dev/)
- [CircleCI OIDC Documentation](https://circleci.com/docs/openid-connect-tokens/)
- [CircleCI Sign and Publish Examples](https://github.com/CircleCI-Public/sign-and-publish-examples)
- [Fulcio OIDC Configuration](https://github.com/sigstore/fulcio/blob/main/config/identity/config.yaml)
- [Fulcio Certificate Authority](https://docs.sigstore.dev/certificate_authority/overview/)
- [Rekor Transparency Log](https://docs.sigstore.dev/logging/overview/)
- [Private Key Signing Guide](private-key-signing.md)
