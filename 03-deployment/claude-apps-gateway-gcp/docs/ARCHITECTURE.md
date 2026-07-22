# Architecture

## What gets created

| Resource | Purpose |
|---|---|
| Cloud Run service | Runs the gateway container. Direct VPC egress, private-ranges-only. |
| Artifact Registry repo | Holds the image, tagged with the pinned gateway version. |
| Cloud SQL for PostgreSQL | Session store, private IP only, reached over the VPC. |
| Secret Manager (×4) | `gateway.yaml`, JWT signing key, OIDC client secret, Postgres URL. |
| Service account | Runs the container; holds `roles/aiplatform.user` for the model upstream. |
| VPC + subnet | Hosts Cloud Run egress and the private-IP database. |
| PSA peering + reserved range | Lets Cloud SQL exist without a public IP. |

## Request path

```
Developer laptop (corporate network)
        │  HTTPS, private DNS only — /login refuses public addresses
        ▼
Cloud Run  ingress=internal[-and-cloud-load-balancing]
        │  invoker IAM check open or disabled
        ▼
Gateway container
        ├─ OIDC sign-in ──────────────▶ accounts.google.com   (direct egress)
        ├─ session state ─────────────▶ Cloud SQL private IP  (VPC egress)
        └─ inference ─────────────────▶ Vertex / Agent Platform (ADC)
```

Egress is `PRIVATE_RANGES_ONLY`, so only VPC-bound traffic takes the network
interface. Model-upstream and IdP traffic goes out directly, which is why no
Cloud NAT is required.

## Where authentication actually happens

Two gates a request could pass through, and only the second one is real here:

1. **Cloud Run invoker IAM** — deliberately open or disabled. The gateway's
   clients hold no GCP token, so an enforced check would 403 every request
   before the container saw it.
2. **The gateway's own OIDC layer** — the actual door. Unauthenticated requests
   are redirected to the IdP, the returned id_token is verified, the email
   domain is checked against `allowed_email_domains`, and a session JWT signed
   with `session.jwt_secret` is issued and persisted in Postgres.

`allowed_email_domain` is therefore the entire access-control list. The
Terraform variable rejects the documentation placeholder `example.com` for that
reason.

Reachability is constrained by **ingress**, which is an independent layer. See
[NETWORKING.md](NETWORKING.md).

## Secret handling

No secret is written into `gateway.yaml`. The template carries `${VAR}`
placeholders that the gateway expands from its environment at boot; Cloud Run
injects the three sensitive values from Secret Manager, and the config itself
mounts as a file at `/etc/claude/gateway.yaml`. The split exists because Cloud
Run cannot mount multiple secrets into one directory.

The rendered YAML holds only non-secret values — project, region, client ID,
domain, trusted proxies — so it is safe to store as a Secret Manager version and
to read back when debugging.

**Terraform state is the exception.** It contains the generated Postgres
password and the rendered config in plaintext. It is gitignored; use a GCS
backend for anything beyond a single-operator trial. The commented backend block
in `terraform/versions.tf` is ready to uncomment.

## File layout

```
claude-apps-gateway-gcp/
├── deploy.sh                 Interactive entry point
├── teardown.sh               Teardown with leftover verification
├── lib/common.sh             Shared shell helpers
├── config.env                Saved answers (generated, gitignored)
├── docs/                     This documentation
├── templates/
│   ├── Dockerfile            Distroless runtime image
│   ├── gateway.yaml.template Two-level substitution — read its header
│   └── claude                Gateway binary (downloaded, gitignored, ~260 MB)
├── terraform/
│   ├── versions.tf           Providers, backend
│   ├── variables.tf          All inputs, documented
│   ├── locals.tf             Derived values: image tag, proxies, config render
│   ├── apis.tf               Service API enablement
│   ├── iam.tf                Service account and roles
│   ├── network.tf            VPC, subnet, PSA peering
│   ├── database.tf           Cloud SQL
│   ├── secrets.tf            All four secrets, one for_each
│   ├── image.tf              Artifact Registry and Cloud Build
│   ├── cloud_run.tf          Service and invoker layer
│   └── outputs.tf            URLs, redirect URI, MDM snippet, next steps
└── gcloud-scripts/           Equivalent imperative path, no state file
```

The Terraform is one root module split by concern rather than a set of nested
modules. At this size nested modules would add variable-plumbing indirection
without any reuse to justify it — there is exactly one caller. Splitting by file
gives the same navigability with none of that cost.

## Design decisions worth knowing

**The image tag is the gateway version, not `latest`.** Bumping
`gateway_version` changes the tag, which changes the `null_resource` trigger,
which forces a rebuild and a new revision. With `latest` and no triggers, the
build fires once for the lifetime of the state and every later version bump
silently redeploys the old image.

**`min_instances = 1`.** Gateway boot is fail-closed and gives Postgres a
5-second connection timeout. Scale-to-zero turns every cold start into a
sign-in failure risk.

**`sslmode=require`.** The hop is inside the VPC, but the session store carries
auth state and Cloud SQL terminates TLS at no cost.

**`deploy.sh` writes `terraform.tfvars`.** Terraform ranks `terraform.tfvars`
above `TF_VAR_*` environment variables, so exporting the answers would let a
stale file on disk silently win — deploying your configuration into whichever
project the previous operator used.

**The PSA peering is not `ABANDON`-ed on destroy.** Its deletion legitimately
fails while Cloud SQL still holds an address in the reserved range, and it
blocks the VPC, subnet, and range behind it. `teardown.sh` retries, falls back
to deleting it with gcloud, then re-runs destroy and verifies. Setting
`deletion_policy = "ABANDON"` would convert a retryable failure into permanently
orphaned infrastructure.
