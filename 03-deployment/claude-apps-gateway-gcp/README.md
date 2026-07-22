# Claude apps gateway on Google Cloud

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

Deployment automation for the [Claude apps gateway](https://code.claude.com/docs/en/claude-apps-gateway)
on Google Cloud — an interactive wizard over either Terraform or plain `gcloud`,
provisioning Cloud Run, Cloud SQL, Secret Manager, and the VPC the gateway
needs.

The gateway is a self-hosted service between your developers' Claude Code
clients and your model provider. Developers sign in with your corporate identity
provider instead of holding API keys or cloud credentials; the gateway holds the
upstream credential, enforces model access by IdP group, and relays telemetry to
your own observability stack.

```bash
cd 03-deployment/claude-apps-gateway-gcp
./deploy.sh
```

## Read this before you deploy

**Claude Code will not sign in to a gateway whose hostname resolves to a public
address.** It is a deliberate security control: a trusted gateway can push
managed settings that run commands on developer machines, so the client refuses
to extend that trust to anything reachable from the open internet.

This has a sharp practical edge. A publicly-reachable deployment builds cleanly,
passes health checks, boots without errors — and then every sign-in fails. There
is no "just make it public" configuration, and this module rejects one at the
variable-validation layer rather than letting you discover it at rollout.

Both supported topologies are private, and both need network plumbing that Cloud
Run does not provision for you. **[docs/NETWORKING.md](docs/NETWORKING.md)
covers the choice** — it is the decision that determines whether your deployment
works.

Second: a deployed gateway is not a usable gateway. Developers cannot select it
manually at `/login`; the URL must reach their machines through managed settings
via MDM. See [docs/CLIENT-SETUP.md](docs/CLIENT-SETUP.md).

## Prerequisites

| Requirement | Notes |
|---|---|
| GCP project with billing | Plus permission to create Cloud Run, Cloud SQL, Secret Manager, VPC, and IAM resources |
| `gcloud`, authenticated | Google Cloud Shell has this already and is the smoothest path |
| `terraform` ≥ 1.5 | Only for the Terraform method |
| OAuth 2.0 web-application client | From Google Workspace or any OIDC-compliant IdP |
| Models enabled in Model Garden | For your chosen region — availability is per-region |
| A private hostname | Per your chosen topology |

`bash`, `curl`, and `envsubst` are needed by the scripts; all three are present
in Cloud Shell. The gateway binary is downloaded automatically at the pinned
version — you do not need to fetch it yourself.

## Method 1 — Interactive wizard (recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

Prompts for project, region, IdP, and topology; downloads the gateway binary;
then hands off to Terraform or `gcloud`. Answers are saved to `config.env`
(gitignored, owner-only) so re-running is not a re-interrogation.

It finishes by printing the three remaining steps — redirect URI, DNS
verification, and the MDM snippet — because the deployment is not usable until
all three are done.

## Method 2 — Terraform directly

For CI, or when you want to review the plan before applying.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform plan
terraform apply
```

> **`terraform.tfvars` outranks `TF_VAR_*` environment variables.** A stale file
> here silently wins over anything you export — which is how a deployment ends
> up in the wrong project. `deploy.sh` regenerates the file from its prompts for
> exactly this reason.

The binary must be present before the image build:

```bash
curl -fsSL "https://downloads.claude.ai/claude-code-releases/2.1.206/linux-x64/claude" \
  -o templates/claude && chmod +x templates/claude
```

In CI where a separate stage builds and pushes the image, set
`build_image = false` and ensure the image already exists at
`<region>-docker.pkg.dev/<project>/claude-gateway/gateway:<gateway_version>`.

For anything beyond a single-operator trial, uncomment the GCS backend in
`versions.tf`. Local state holds the generated Postgres password and the
rendered config in plaintext, and cannot be shared or locked.

### Key variables

| Variable | Default | Notes |
|---|---|---|
| `project_id` | — | Required |
| `region` | `us-east5` | Must publish your models in Model Garden |
| `allowed_email_domain` | — | The entire access-control list. `example.com` is rejected. |
| `ingress` | `INGRESS_TRAFFIC_INTERNAL_ONLY` | Or `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`. `ALL` is not offered. |
| `gateway_public_url` | `""` | Auto-filled with the `*.run.app` URL on internal ingress; required behind an ALB |
| `proxy_only_subnet_cidr` | `""` | Required behind an ALB, so client IPs survive into audit events |
| `invoker_mode` | `allusers` | `external` when Domain Restricted Sharing blocks the `allUsers` binding |
| `gateway_version` | `2.1.206` | Also the image tag; bumping forces a rebuild |
| `min_instances` | `1` | Keep at 1 — boot is fail-closed on Postgres |
| `build_image` | `true` | `false` in CI |

Full descriptions live in `terraform/variables.tf`.

## Method 3 — gcloud CLI

No state file, and every step is readable line by line.

```bash
export PROJECT_ID="your-project-id"
export REGION="us-east5"
export OAUTH_CLIENT_ID="..."
export OAUTH_CLIENT_SECRET="..."
export ALLOWED_DOMAIN="acme.com"

# Optional: INGRESS, INVOKER_MODE, GATEWAY_PUBLIC_URL,
#           PROXY_ONLY_SUBNET_CIDR, GATEWAY_VERSION, VPC_NAME

chmod +x gcloud-scripts/deploy-gcloud.sh
./gcloud-scripts/deploy-gcloud.sh
```

Idempotent — safe to re-run. Note it rotates the database password on re-runs
against an existing instance.

## After deploying

1. **Authorize the redirect URI.** Add `<public_url>/oauth/callback` to the
   OAuth client, exactly. The gateway builds it from `public_url` alone and
   ignores `X-Forwarded-*`.
2. **Verify private resolution.** `nslookup <gateway-host>` from a developer
   machine. Every address must be private, or `/login` rejects it.
3. **Push managed settings via MDM.**
   `terraform output -raw managed_settings_snippet`
4. **Verify sign-in** from a machine on the corporate network.

## Teardown

```bash
./teardown.sh
```

Handles the failure this stack actually has: destroying the Private Services
Access peering fails while Cloud SQL still holds an address in the reserved
range, and that peering blocks the VPC, subnet, and range behind it. The script
retries, falls back to deleting the peering with `gcloud`, re-runs destroy, then
**verifies all six resource classes and exits non-zero if anything survives** —
so a partial teardown cannot be mistaken for a clean one.

## Documentation

| Document | Covers |
|---|---|
| [docs/NETWORKING.md](docs/NETWORKING.md) | The private-address requirement and the two supported topologies |
| [docs/CLIENT-SETUP.md](docs/CLIENT-SETUP.md) | Managed settings, MDM rollout, certificate pinning |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | What gets built, request path, design decisions |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Failures by phase: deploy, boot, sign-in, runtime, teardown |

Upstream: [Claude apps gateway on Google Cloud](https://code.claude.com/docs/en/claude-apps-gateway-on-gcp)
· [reference deployment assets](https://github.com/anthropics/claude-code/tree/main/examples/gateway/gcp)
