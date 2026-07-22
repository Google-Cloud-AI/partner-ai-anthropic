# Troubleshooting

## Deploy-time

| Symptom | Cause | Fix |
|---|---|---|
| `Container manifest type … must support amd64/linux` | Image built on a non-amd64 host, or buildx emitted an OCI image index | Build through Cloud Build (the default here), or locally with `--platform=linux/amd64 --provenance=false` |
| `invoker_iam_disabled is not currently available` | Blocked by `constraints/run.managed.requireInvokerIam` | Use `invoker_mode = "allusers"` |
| `--allow-unauthenticated` rejected | Domain Restricted Sharing (`constraints/iam.allowedPolicyMemberDomains`) blocks the `allUsers` binding | Use `invoker_mode = "external"` and `--no-invoker-iam-check`. If both are blocked, the GKE track needs neither. |
| `allowed_email_domain is still the placeholder` | Deliberate guard | Set your real Workspace domain — it is the gateway's entire access-control list |
| Terraform applies into an unexpected project | A stale `terraform.tfvars` outranks `TF_VAR_*` | Re-run `deploy.sh`, which regenerates it. Never set only the env vars. |
| Cloud Build cannot find `templates/claude` | Binary not downloaded | `deploy.sh` fetches it; standalone, download the pinned `linux-x64` release |

## Boot

Gateway boot is fail-closed on config, the Postgres connection (5-second
timeout), OIDC discovery, and upstream client construction. Any of them failing
exits rather than serving degraded. Check logs:

```bash
gcloud run services logs read claude-gateway --region=<region> --limit=100
```

A healthy boot logs, in order: `config.load` → migrations applied → listening.

| Symptom | Cause | Fix |
|---|---|---|
| Postgres connection timeout at boot | Service not attached to the VPC, or Cloud SQL has no private IP on it | Confirm `--network`/`--subnet` direct egress and that the instance was created with `--no-assign-ip` on the same VPC |
| `requires the native binary` | Image built with a Node-based Claude Code rather than the native binary | Use the `linux-x64` native release; the server needs runtime features Node lacks |
| OIDC discovery fails at boot | Egress cannot reach `accounts.google.com` | Egress must be `PRIVATE_RANGES_ONLY`, not all-traffic — otherwise IdP traffic is forced through the VPC with no NAT |

**A clean boot does not prove inference works.** Upstream credentials resolve on
the first request, not at startup.

## Sign-in

| Symptom | Cause | Fix |
|---|---|---|
| `/login` rejects the URL | Hostname resolves to a public address | [NETWORKING.md](NETWORKING.md). Verify with `nslookup` from a developer machine. |
| `/login` rejects it despite private DNS | Corporate HTTPS proxy resolves publicly | Add the gateway host to `NO_PROXY` on developer machines |
| `redirect_uri_mismatch` | `<public_url>/oauth/callback` not registered exactly | Add it to the OAuth client; re-check after any `public_url` change |
| Signs in, then denied | Email domain outside `allowed_email_domains` | Correct the domain and redeploy |
| No **Cloud gateway** screen | Managed settings never landed | [CLIENT-SETUP.md](CLIENT-SETUP.md) — there is no manual option to pick |
| Trust prompt reappears for everyone | TLS certificate rotated | Expected. Republish the fingerprint. |

## Runtime

| Symptom | Cause | Fix |
|---|---|---|
| `403 PERMISSION_DENIED` from the upstream | Wrong runtime service account, or the model is not enabled in Model Garden for the region | Confirm `--service-account`, then enable each model in Model Garden for that region |
| Streaming cut off at a fixed duration | Cloud Run request timeout (default 300s) | `request_timeout_seconds = 3600` (the default here) |
| Cold-start sign-in failures | Scaled to zero; boot gives Postgres 5 seconds | Keep `min_instances = 1` |
| `403 Forbidden` before reaching the container | Invoker check still enforced | See the invoker rows above |

## Teardown

| Symptom | Cause | Fix |
|---|---|---|
| Destroy fails on `google_service_networking_connection` | Cloud SQL still holds an address in the reserved range | Expected. `teardown.sh` retries, force-deletes the peering, re-runs destroy. |
| VPC, subnet, or reserved range survive | The peering blocked them | Re-run `teardown.sh`; it verifies and reports what remains |
| `terraform destroy` says nothing to do, resources exist | State drift, or a different state file | `terraform state list`, then import or delete with gcloud |

`teardown.sh` ends with an explicit check of all six resource classes and exits
non-zero if anything survives, so a partial teardown cannot be mistaken for a
clean one.
