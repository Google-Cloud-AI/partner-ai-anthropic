# Networking: how developers reach the gateway

This is the decision that determines whether your deployment works. Read it
before you deploy, not after.

## The constraint

Claude Code's `/login` **refuses to connect to a self-hosted gateway whose
hostname resolves to a public address.** From the gateway documentation:

> At `/login`, Claude Code requires the gateway's hostname or IP address to
> resolve only to private addresses: RFC 1918, link-local, CGNAT
> `100.64.0.0/10`, IPv6 ULA `fc00::/7`, or loopback for local development. For a
> gateway you host, any public address is rejected. The check runs on each
> resolved IP, so if any address the name resolves to is public, `/login`
> rejects the URL.

This is a deliberate security control, not a configuration wrinkle. A gateway a
developer trusts can push managed settings that execute commands on their
machine, so the client refuses to extend that trust to anything reachable from
the open internet. A small fixed set of Anthropic-operated endpoints is exempt
by compiled-in hostname match; nothing you host can qualify.

**The practical consequence:** there is no "just make it public" configuration.
A publicly-reachable deployment will build cleanly, pass its health checks, boot
without errors — and then every developer sign-in will fail. `INGRESS_TRAFFIC_ALL`
is rejected by this deployer's variable validation for that reason.

If developers also route HTTPS through a corporate proxy, the **proxy host**
must resolve privately too, or the gateway host needs to be in their `NO_PROXY`.

## The two supported topologies

### Option 1 — Internal ingress, no load balancer

`ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"` (the default)

Keeps Cloud Run's generated `*.run.app` URL as `public_url`. Fewest resources
and nothing extra to run.

The catch is that `*.run.app` resolves publicly by default, which `/login`
rejects. It only works if your organization **already operates**:

- a Private Service Connect endpoint for Google APIs,
- a Cloud DNS private zone resolving `*.run.app` to that endpoint, and
- routing from developer networks to it.

Cloud Run does not provision any of this, and neither does this deployer. If
your network team already runs this pattern for other Google APIs, this is the
cheapest path. If the phrase is unfamiliar to them, it is not.

Google's [private networking guide for Cloud Run](https://cloud.google.com/run/docs/securing/private-networking)
covers the build.

### Option 2 — Internal Application Load Balancer

`ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"`

You put an internal Application Load Balancer in front of the service with your
own internal DNS name and TLS certificate, then set `gateway_public_url` to that
hostname. More to build, but self-contained — it does not depend on
`*.run.app` private resolution existing beforehand, and it gives you a place to
attach Cloud Armor or additional controls.

Requires two extra variables:

| Variable | Why |
|---|---|
| `gateway_public_url` | There is no generated URL to fall back to. The gateway builds its IdP `redirect_uri` from this alone. |
| `proxy_only_subnet_cidr` | Adds the ALB to `trusted_proxies`, so client IPs survive into rate limits and audit events instead of every request appearing to come from the load balancer. |

**This deployer does not create the ALB, the DNS record, or the certificate.**
Terraform provisions the Cloud Run service with the correct ingress and config;
the load balancer in front is yours to build. It is scoped out deliberately —
certificate sourcing and internal DNS differ too much between organizations for
a default to be useful.

### What is not an option

| | Why not |
|---|---|
| `INGRESS_TRAFFIC_ALL` + `*.run.app` | `/login` rejects the public address. Deploys fine, cannot be signed into. |
| External ALB (class `gce`) | Provisions a public forwarding-rule address — same rejection. |
| Cloud Run IAM auth instead of gateway OIDC | Clients carry no GCP token. An enforced invoker check returns 403 before the container is reached. |

## Two independent layers, easily confused

**Ingress** controls which networks can reach the service. **The invoker IAM
check** controls whether Cloud Run demands a Google identity on each request.
They are unrelated, and this deployment needs them set differently.

The invoker check must be **open or disabled**, because the gateway runs its own
OIDC and its clients present no GCP token. That is not a weakening of security:
it moves authentication from Cloud Run's layer into the gateway, which is the
only layer that can run a browser sign-in flow and issue per-user sessions.
Ingress is what actually restricts reachability.

`var.invoker_mode` picks how:

- **`allusers`** (default) — grants `allUsers` the `roles/run.invoker` role.
  Matches the upstream reference assets. Blocked by Domain Restricted Sharing
  (`constraints/iam.allowedPolicyMemberDomains`).
- **`external`** — creates no binding. Use when DRS blocks `allUsers`; disable
  the check out of band:
  ```bash
  gcloud run services update claude-gateway --region=<region> --no-invoker-iam-check
  ```
  The stable Terraform provider has no `invoker_iam_disabled` attribute (it is
  `google-beta` only), which is why this is a flag rather than a resource.

If both are blocked by org policy, the GKE track exposes the gateway at the
network layer with no `allUsers` binding at all. That track is out of scope
here; see the upstream documentation.

## Verifying before you hand it to developers

From a machine on the corporate network:

```bash
# 1. Every returned address must be private.
nslookup claude-gateway.internal.example.com

# 2. The gateway should answer.
curl -sS https://claude-gateway.internal.example.com/readyz

# 3. Discovery must advertise the same origin as public_url.
curl -sS https://claude-gateway.internal.example.com/.well-known/openid-configuration
```

If step 1 returns any public address, stop — `/login` will reject the gateway no
matter what else is correct.

## `public_url` and the redirect URI

The gateway builds its IdP `redirect_uri` and discovery document **only** from
`listen.public_url`, never from `X-Forwarded-Host` or `X-Forwarded-Proto`. Two
consequences:

1. `<public_url>/oauth/callback` must be registered on the OAuth client
   *exactly*, before the first sign-in.
2. Changing `public_url` requires a redeploy.

With internal-only ingress there is a chicken-and-egg problem: the gateway needs
its URL, but Cloud Run only mints it once the service exists. This deployer
resolves it by leaving `public_url: ${GATEWAY_PUBLIC_URL}` as an environment
placeholder in the rendered YAML, so `deploy.sh` closes the loop with a single
env-var update rather than a new secret version and a second full apply.
