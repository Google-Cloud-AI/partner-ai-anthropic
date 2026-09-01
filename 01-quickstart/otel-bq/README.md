# Claude Code → Google-built OTel Collector on Cloud Run

Ships Claude Code telemetry into Google Cloud Observability via the
[Google-built OpenTelemetry Collector](https://docs.cloud.google.com/stackdriver/docs/instrumentation/google-built-otel)
running on Cloud Run. Designed to be deployed once by an admin and used by a
whole team — each developer authenticates as themselves from their own laptop.

```
Claude Code (each developer's machine)
   │  OTLP/HTTP (protobuf), Authorization: Bearer <ID token>
   ▼
Cloud Run "claude-otel-collector"   ← Google-built OTel Collector (public image)
   │  googlecloud + googlemanagedprometheus exporters (ADC = runtime SA)
   ▼
Cloud Logging · Cloud Monitoring (Managed Prometheus) · Cloud Trace
```

- **Signals:** logs (Claude Code events) + metrics; the traces pipeline is wired
  and ready — span export is a Claude Code beta, off by default, opted into per
  developer (see [Traces (beta)](#traces-beta)).
- **Auth:** Cloud Run requires IAM (`--no-allow-unauthenticated`). No key files —
  tokens are minted either from the GCP metadata server (on GCP compute) or via
  `gcloud` service-account impersonation (on laptops). See [Authentication](#authentication).
- **Config delivery:** `collector-config.yaml` is stored in Secret Manager and
  volume-mounted at `/etc/otelcol-google/config.yaml`. No custom image / build.
- **Port:** Cloud Run container port is `4318`; the OTLP/HTTP receiver listens there.
  External HTTPS (443) → 4318.
- **Configuration:** all deployment-specific values live in `config.env` (created
  by `./setup.sh`), which is gitignored — nothing account-specific is committed.

## Files

| File | Purpose |
|------|---------|
| `config.env.example` | Template of all settings; copy to `config.env` or run `setup.sh`. |
| `setup.sh` | Interactive: writes `config.env` and renders the SQL templates. |
| `deploy.sh` | Idempotent provisioning: APIs, SAs, IAM, secret, Cloud Run deploy. |
| `collector-config.yaml` | Collector pipelines (receivers/processors/exporters). |
| `otel-headers-helper.sh` | Mints the `Authorization` header for Claude Code (metadata → gcloud). |
| `print-settings.sh` | Prints the `~/.claude/settings.json` snippet for a developer. |
| `.collector-url` | Written by `deploy.sh`; the service URL (used as token audience). |
| `daily-spend.sql` / `spend-by-model.sql` | Cost queries for Log Analytics (templates; `setup.sh` renders `*.local.sql`). |
| `cost-dashboard-setup.sh` | Creates a BigQuery linked dataset + exact cost views for Looker Studio. |
| `productivity-dashboard.json` | Cloud Monitoring dashboard: commits, PRs, lines, sessions, tokens. |

---

## Admin setup (once per project)

1. **Authenticate gcloud** with an identity that can deploy (run/secret/SA admin):
   ```bash
   gcloud auth login
   ```

2. **Configure** — provide your project and who may send telemetry:
   ```bash
   ./setup.sh
   ```
   Key answers:
   - `PROJECT` — your GCP project ID.
   - `DEVELOPERS` — **who may send telemetry.** Use a **domain or group** so you
     never list individuals: `domain:yourcompany.com` (any authenticated user in
     your org) or `group:claude-users@yourcompany.com` (manage membership in
     Google Workspace). An explicit `user:` list works too but isn't necessary.
     Whoever is covered here can impersonate the invoker SA to mint a token.
   - `INVOKER_MEMBERS` — optional; SAs of GCP machines (Cloud Workstations/VMs)
     that send directly via the metadata server.

3. **Deploy the collector:**
   ```bash
   ./deploy.sh
   ```
   Provisions everything and prints the service URL (saved to `.collector-url`).

4. **Share** the service URL with your developers and tell them they've been
   granted access.

Onboarding later: if `DEVELOPERS` is a **group or domain**, just add the person
in Google Workspace — no repo change, no redeploy. Only if you used an explicit
`user:` list do you edit `config.env` and re-run `./deploy.sh` (idempotent).

---

## Developer setup (each laptop)

> **What you need from the admin first.** `.collector-url` and `config.env` are
> both gitignored, so a fresh clone does **not** contain them, and the scripts
> exit early without them:
>
> | Script | Requires | Why |
> |---|---|---|
> | `print-settings.sh` | `.collector-url` | the endpoint it writes into `settings.json` |
> | `otel-headers-helper.sh` | `.collector-url` **and** `config.env` | the token audience, plus `PROJECT` / `INVOKER_SA_NAME` to impersonate |
>
> Ask your admin for the service URL and either have them share their
> `config.env`, or run `./setup.sh` and enter the same `PROJECT` and
> `INVOKER_SA_NAME` they used. To create `.collector-url` by hand:
> ```bash
> echo "https://claude-otel-collector-XXXX.<region>.run.app" > .collector-url
> ```

1. **Install the Google Cloud SDK** and log in as yourself:
   ```bash
   gcloud auth login
   ```

2. **Update `~/.claude/settings.json`.** Easiest — let the script merge it in for
   you (needs `jq`; backs up the file first):
   ```bash
   ./print-settings.sh you@yourcompany.com --merge
   ```
   Or print the correctly-shaped JSON and merge by hand:
   ```bash
   ./print-settings.sh you@yourcompany.com
   ```
   ```json
   {
     "env": {
       "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
       "OTEL_LOGS_EXPORTER": "otlp",
       "OTEL_METRICS_EXPORTER": "otlp",
       "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
       "OTEL_EXPORTER_OTLP_ENDPOINT": "https://claude-otel-collector-XXXX.<region>.run.app",
       "OTEL_METRIC_EXPORT_INTERVAL": "10000",
       "OTEL_LOGS_EXPORT_INTERVAL": "5000",
       "OTEL_RESOURCE_ATTRIBUTES": "user.email=you@yourcompany.com"
     },
     "otelHeadersHelper": "/absolute/path/to/otel-headers-helper.sh"
   }
   ```
   > ⚠️ `otelHeadersHelper` is a **top-level key, a sibling of `env`** — not one
   > of the keys inside `env`. Putting it inside `env` is the #1 setup mistake and
   > results in an empty `Authorization` header (Cloud Run rejects the telemetry).

3. **Restart Claude Code** so it picks up the new environment.

---

## Authentication

Cloud Run only lets in requests bearing a valid Google-signed **ID token** whose
audience equals the service URL. `otel-headers-helper.sh` produces that token,
trying two methods in order:

1. **Metadata server** — on GCP compute (Cloud Workstations, GCE VMs) the
   machine's attached service account mints the token, no key files. Those
   machines' SAs must be listed in `INVOKER_MEMBERS` (granted `run.invoker`).
2. **gcloud impersonation** — on a laptop there is no metadata server, so the
   helper runs `gcloud auth print-identity-token` **impersonating the shared
   invoker SA**. The developer must have run `gcloud auth login` and hold
   `roles/iam.serviceAccountTokenCreator` on that SA (granted by `deploy.sh` for
   everyone in `DEVELOPERS`).

The helper auto-detects, so the same script works in both environments.

## Verify

```bash
source ./config.env

# 1. Service is up
gcloud run services describe "${SERVICE}" --region "${REGION}" \
  --format='value(status.url)'

# 2. Header helper produces a token
./otel-headers-helper.sh          # expect {"Authorization": "Bearer <token>"}

# 3. Auth + ingest probe (expect HTTP 200 and {"partialSuccess":{}})
URL=$(cat .collector-url)
TOK=$(./otel-headers-helper.sh | sed -E 's/.*Bearer (.*)".*/\1/')
curl -i -X POST "$URL/v1/logs" -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"probe"}}]}]}]}'

# 4. Real telemetry (after running a Claude Code prompt)
gcloud logging read 'logName:"claude-code"' --project "${PROJECT}" \
  --freshness=10m --limit 5

# 5. Collector health
gcloud run services logs read "${SERVICE}" --region "${REGION}" --limit 50
```

Metrics: Cloud Monitoring → Metrics Explorer → `prometheus/claude_code_*`
(Managed Prometheus), a couple minutes after the first export interval.

Troubleshooting the probe: `401/403` ⇒ IAM (invoker binding / token-creator
grant / token audience); `404` ⇒ wrong path or container port.

## Per-user identity (email instead of an anonymous ID)

Under Vertex auth, Claude Code emits only an anonymous `user.id` — a random
identifier generated on first run and persisted in `~/.claude.json`, not derived
from any account — and no `user.email`.
To attribute telemetry to a real person, each developer sets their email as a
resource attribute (see the developer setup above):

```json
"OTEL_RESOURCE_ATTRIBUTES": "user.email=someone@example.com"
```

The collector's `transform` processor (see `collector-config.yaml`) promotes that
attribute onto every record as a **`user_email`** label, queryable in both Cloud
Logging (`labels.user_email`) and Cloud Monitoring (metric label `user_email`).
The SQL queries group by it, falling back to `user.id` for older telemetry.

> **Note:** `user_email` is **self-declared** — the collector trusts whatever the
> developer sets. It's fine for cost attribution but is not a verified identity.
> (GCP's own audit logs still record the real authenticated principal.)

## Traces (beta)

The collector already has a traces pipeline and the runtime SA already holds
`roles/cloudtrace.agent`, so **no server-side change is needed** — spans land in
Cloud Trace as soon as a developer opts in.

Span export is a Claude Code **beta** and is off by default. To turn it on, add
to the `env` block in `~/.claude/settings.json` and restart Claude Code:

```json
"CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
"OTEL_TRACES_EXPORTER": "otlp"
```

Traces reuse the OTLP endpoint, protocol and auth header already configured for
logs and metrics. Being a beta, the span schema may change — treat it as
opt-in per developer rather than a fleet-wide default.

## Cost accuracy (important)

The native Cloud Monitoring metric `claude_code_cost_usage_USD_total` is a
**per-session counter that resets**, so it is unreliable for totals: summing the
raw counter under-counts, and `increase()` over-extrapolates across resets. The
**authoritative cost source is the `cost_usd` label on each `api_request` log
event** — which is exactly what the SQL queries read (via Log Analytics), so they
are exact and cover full history.

## Cost queries (ad-hoc)

`setup.sh` renders `daily-spend.local.sql` (per user) and
`spend-by-model.local.sql` (per model) from the templates, substituting your
project ID. Paste the rendered file into **Logging → Observability Analytics → Query**.
(If you didn't run `setup.sh`, edit the `*.sql` template and replace
`YOUR_PROJECT_ID` yourself.) The console time-range picker controls the window.

These queries read `_Default._AllLogs`, which requires the `_Default` log bucket
to be **upgraded to Log Analytics**. `deploy.sh` does this for you (via
`gcloud logging buckets update _Default --location=global --enable-analytics`);
to do it by hand, use **Logging → Logs Storage → `_Default` → Upgrade**.

## Dashboards

Two optional dashboards. Cost and productivity come from **different signals**:
productivity metrics (commits, PRs, lines, sessions, tokens) are **Cloud
Monitoring metrics**; exact cost lives in the **log events** (`cost_usd`), which
is why exact cost is served from Log Analytics / BigQuery, not from a metric.

### 1. Developer productivity (Cloud Monitoring)
Commits · pull requests · lines added/removed · sessions · active hours ·
token usage · edit-tool accept rate. Deploy:
```bash
gcloud monitoring dashboards create --project "$PROJECT" \
  --config-from-file=productivity-dashboard.json
```
> Counters reset per session, so the tiles use `increase()`/`rate()` over a
> window. `commit`/`pull_request` only increment for git actions taken **through
> Claude Code**.

### 2. Cost & spend — exact (Looker Studio on BigQuery)
Reads the raw `cost_usd` on every event, so figures match the SQL to the cent.
```bash
./cost-dashboard-setup.sh
```
This creates a BigQuery **linked dataset** over the `_Default` Log Analytics
bucket and two views (`<BQ_DATASET>.daily_spend`, `.spend_by_model`). Then open
either view in BigQuery → **Export → Explore with Looker Studio**, and add charts
(time series `day` vs `cost_usd`, table by `user`, pie by `model`). The linked
dataset reads **live** log data; Looker Studio caches results (set *Data
freshness* to 15 min, or hit Refresh). Tunables live in `config.env`
(`LOGLINK_ID`, `BQ_DATASET`, `BQ_LOCATION`).

> Why not a Cloud Monitoring cost dashboard? Cost as a metric relies on a
> log-based *distribution*, which buckets values — so totals are only approximate
> (~±few %). For dollars you can trust, read the log events directly, which is
> exactly what these BigQuery views (and the SQL queries) do.

## Cost notes

`MIN_INSTANCES=0` scales to zero (no idle cost), but a cold start can drop the
first telemetry batch after idle. `MIN_INSTANCES=1` (the default) guarantees
capture at a small always-on cost. Cloud Logging/Monitoring ingestion is billed
per usage.

## Teardown

```bash
source ./config.env
gcloud run services delete "${SERVICE}" --region "${REGION}" --quiet
gcloud secrets delete "${SECRET}" --quiet
gcloud iam service-accounts delete "${RUNTIME_SA_NAME}@${PROJECT}.iam.gserviceaccount.com" --quiet
gcloud iam service-accounts delete "${INVOKER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com" --quiet
```
Then remove the OTel keys / `otelHeadersHelper` from `~/.claude/settings.json`.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](../../LICENSE).
