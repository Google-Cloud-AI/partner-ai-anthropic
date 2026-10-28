# Claude Code telemetry straight to the Telemetry API

Claude Code exports OpenTelemetry to `telemetry.googleapis.com` directly. The
Telemetry API splits the two signals: log records go to Cloud Logging, where a
Log Router sink copies them into BigQuery tables you query with SQL, and metrics
go to Cloud Monitoring, where they feed dashboards. There is nothing to deploy.

```text
                                           ┌─> Cloud Logging ─> sink ─> BigQuery
Claude Code ──OTLP/HTTP──> telemetry.googleapis.com
                                           └─> Cloud Monitoring ─> dashboards
```

One endpoint and one credential carry both signals. If you need a collector in
the path, for a single egress point or so that developers hold no telemetry
permissions of their own, see [`otlp-to-collector/`](../otlp-to-collector/).

## Requirements

- A GCP project for the telemetry to land in.
- `gcloud` and `bq`, authenticated as someone who can enable APIs, grant IAM and
  create BigQuery datasets.
- Claude Code with OpenTelemetry support.

## 1. Set up the project

```bash
./setup.sh              # writes config.env, renders sql/*.local.sql
./enable-and-grant.sh   # APIs, IAM, BigQuery dataset, Log Router sink
```

`enable-and-grant.sh` does everything except one last command, which it prints
for you to run once telemetry is flowing. That command stops you being billed
for the same logs twice; see [Cost](#cost).

## 2. Configure developers

Do your own machine first and confirm the pipeline works, then deploy to
everyone else. Step 3 depends on it, and so does the exclusion in
[Cost](#cost): neither should be done on trust.

### First, your own machine

```bash
./print-settings.sh --merge
```

This merges the right keys into `~/.claude/settings.json`, backing the file up
first. Restart Claude Code afterwards. Run it without `--merge` to print the
file instead of writing it.

You are not asked to type your email. The script takes it from your `gcloud`
credential. Pass one as an argument to override, and it says so.

### Then roll it out with managed settings

Once rows are arriving, deploy to everyone else. Developers do not need to run
anything. Generate the configuration once:

```bash
./print-settings.sh --managed > managed-settings.json
```

Change `otelHeadersHelper` to the path the helper will have **on developer
machines**, not the one it has on yours:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://telemetry.googleapis.com",
    "OTEL_METRIC_EXPORT_INTERVAL": "60000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS": "180000",
    "OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES": "true",
    "OTEL_METRICS_INCLUDE_VERSION": "true"
  },
  "otelHeadersHelper": "/opt/claude-code/otel-headers-helper.sh"
}
```

That half is the same for everyone. One key is still missing, and it is the one
that differs per person.

### The email address

In GCP, Claude Code emits an anonymous `user.id` and no `user.email`. Every
per-developer query groups by the email, so something has to supply it, and it
differs per person. It is the one setting the fleet-wide file above cannot
carry.

Two ways to deliver it, neither of which asks the developer to do anything:

| Where developers work | How to supply the email |
|---|---|
| **Laptops** | Add `OTEL_RESOURCE_ATTRIBUTES` to that machine's `managed-settings.json`, with your MDM substituting the assigned user's address. The managed file then differs per machine. |
| **Google Cloud Workstations** | The image is shared, so nothing can be baked in. Have the workstation's startup script run `./print-settings.sh --merge` at first boot. |

Prefer the first wherever you can. Because managed settings outrank every other
level, an address placed there is one the developer cannot change. The
Workstations route writes `~/.claude/settings.json`, which they can.

`--merge` writes the whole set of keys, not just the address, so a Workstation
ends up with the same values in both files. That is harmless: settings merge
key by key and the managed file wins every key it sets, leaving the address as
the only one that takes effect from the user file.

The value is one string of literal text:

```json
"OTEL_RESOURCE_ATTRIBUTES": "gcp.project_id=your_project_id,location=us-central1,service.instance.id=sams-laptop,user.email=sam@yourcompany.com"
```

Claude Code does not expand anything in it. Write real values, not shell
variables: `$(hostname)` stays the characters `$(hostname)`. If your MDM
substitutes the address when it writes the file, that happens in the MDM, not
here.

It also has to be set as a whole, so the email cannot be split out and layered
on top of a shared value. Whatever you include goes in the per-machine string.

`location` is a label saying where the workload runs. It takes any valid Google
Cloud location, a region or a zone, but not `global`, which the endpoint
rejects. On GCP, `print-settings.sh` reads the machine's zone. On a laptop
there is no true answer, so it falls back to the region in `config.env`: valid,
and geographically meaningless.

### Put the files on each machine

Three files, not one, with whatever already deploys files to your fleet:

| File | Where it goes | Why |
|---|---|---|
| `managed-settings.json` | the system directory for the OS, below | The configuration, including the address above |
| `otel-headers-helper.sh` | wherever `otelHeadersHelper` points, for example `/opt/claude-code/` | Mints an access token for every export |
| `config.env` | **beside the helper** | The helper reads `QUOTA_PROJECT` from it and exits if it is missing |

`setup.sh` writes `config.env` in step 1. Ship that same file.

| OS | System directory |
|---|---|
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux and WSL | `/etc/claude-code/managed-settings.json` |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` |

Things to know:

- **Managed settings win.** No user, project, local or `--settings` value
  overrides them, so developers cannot redirect the export somewhere else.
- **The helper path must exist before Claude Code starts.** If it is missing,
  exports fail and Claude Code reports it in `/status`.

## 3. Check that rows arrive

Start a session, send a prompt, then run `sql/00-schema.local.sql`. It lists the
tables and label columns that exist so far. Once rows are landing, the other
queries work.

## Authentication

`otel-headers-helper.sh` mints a short-lived access token for each export. It
tries two sources, in order:

1. **The metadata server**, on GCE and Google Cloud Workstations. The machine's service
   account, no keys, nothing to distribute.
2. **`gcloud auth print-access-token`**, on laptops. The developer's own
   credential, after `gcloud auth login`.

The first wins whenever it answers, so on GCP compute the export authenticates
as the machine, even when a developer is signed in with `gcloud` on the same
box.

### Workload Identity Federation

Recommended when you do not want to grant telemetry roles to individual users,
or when developers have no Google identity at all.

Federate from the identity provider you already run. Grant
`roles/telemetry.writer` once, to a service account the pool can impersonate or
to the federated `principalSet://` directly, and no individual user needs the
role. Create the pool and provider following
[Google's Workload Identity Federation setup](https://docs.cloud.google.com/iam/docs/workload-identity-federation),
then ship the credential configuration file alongside the managed settings.

No change to the helper is needed. A credential configuration activates through
Application Default Credentials, and `gcloud auth print-access-token` then
returns a short-lived federated token like any other.

This path was not exercised in this project, which has no pool and no external
identity provider. The rest of this README describes behaviour that was run.

### Service account keys

Avoid them. A key file does not expire, has to be copied to every laptop, and
cannot be revoked for one person without rotating it for everyone. Audit logs
name the service account rather than whoever used it.

Many organisations block them outright. The organisation behind this project
enforces both `iam.disableServiceAccountKeyCreation` and
`iam.disableServiceAccountKeyUpload`, so the option does not exist there at all.

### Authentication and attribution are separate

The credential that carries an export has nothing to do with the email on the
rows. On a Google Cloud Workstation the machine's service account sends the data while
the rows still name the developer. A row's `user_email` tells you nothing about
which token sent it, and reviewers get this wrong often enough to be worth
stating twice.

## Permissions

Two different principals send telemetry, and granting only the first is the
usual reason a new deployment writes nothing:

| Where Claude Code runs | Who authenticates | `config.env` list |
|---|---|---|
| Laptop, off GCP | the developer | `DEVELOPERS` |
| GCE VM, Google Cloud Workstation | the machine's service account | `MACHINE_MEMBERS` |

`otel-headers-helper.sh` asks the metadata server first, and on GCP compute it
always answers, so the export is authenticated by the machine even when the
developer is signed in with `gcloud` on that same box. Leave `MACHINE_MEMBERS`
empty if everyone works on laptops.

`enable-and-grant.sh` grants both lists `roles/telemetry.writer` on the
destination project and `roles/serviceusage.serviceUsageConsumer` on the quota
project. `roles/monitoring.metricWriter` is neither needed nor sufficient: it
covers `monitoring.googleapis.com`, which these clients never call.

Reading the data is a separate grant that these scripts do not make. BigQuery
needs `roles/bigquery.dataViewer` and `roles/bigquery.jobUser`; the dashboards
need `roles/monitoring.viewer`.

## Query the data

One BigQuery table per event type, named for the bare event. `labels` is a
STRUCT of STRINGs with sanitized keys, so `user.email` becomes
`labels.user_email` and numerics need `SAFE_CAST`. Tables are partitioned on
`timestamp`, and every query filters on it to keep the scan cheap.

| File | Answers |
|---|---|
| `00-schema.sql` | Which tables and label columns exist. **Run first.** |
| `01-spend.sql` | Cost and tokens per day and developer, and per model with cache hit rate and latency. |
| `02-tools.sql` | Per tool: proposed, accepted, succeeded; p50 and p95 duration; what fails; which tools flood the context window. |
| `03-hooks.sql` | Per hook: invocations, duration, total seconds developers waited, blocks and cancellations. |
| `04-prompts.sql` | One row per turn across all five event types. |
| `05-sessions.sql` | One row per session: span, turns, cost per turn, reject rate, hook time. |

Three ids join them: `session.id`, `prompt.id` and `tool_use_id`.

### Which signal answers what

| Question | Where |
|---|---|
| Cost per developer, model or turn | BigQuery |
| Which tools run, fail or flood the context | BigQuery |
| Hook time developers wait on | BigQuery |
| Commits, PRs, lines of code, active time | Cloud Monitoring |
| Sessions started | Cloud Monitoring |

The last two have no log equivalent. Metrics hydrate the Claude Code dashboard
from
[monitoring-dashboard-samples#1254](https://github.com/GoogleCloudPlatform/monitoring-dashboard-samples/pull/1254)
with no extra pipeline.

## Cost

The sink copies logs to BigQuery, it does not divert them. They stay in Cloud
Logging as well, so until you act you pay twice: Cloud Logging ingestion at
$0.50/GiB above the free 50 GiB a month, and BigQuery storage.

Every Google Cloud project has a log bucket called `_Default` that logs go to
automatically. You can give it an *exclusion*, a rule telling it not to store
entries matching a filter. Adding one for Claude Code's logs stops the Cloud
Logging charge, and BigQuery still gets everything, because the Log Router sink
takes its copy before the bucket decides what to keep.

`enable-and-grant.sh` prints that command rather than running it. Run it once
you have confirmed rows are arriving in BigQuery: from then on the tables are
the only copy, and anything the exclusion drops cannot be recovered.

Metrics are billed separately as Managed Service for Prometheus samples, which
at one series per developer per metric is small.

## Privacy

Three settings control what is captured, and `print-settings.sh` leaves all
three unset, which means off:

| Setting | Off (the default) | On |
|---|---|---|
| `OTEL_LOG_USER_PROMPTS` | `user_prompt` carries a length only | Prompt text lands in the tables |
| `OTEL_LOG_ASSISTANT_RESPONSES` | `labels.response` is always `<REDACTED>`; use `labels.response_length` | Response text lands in the tables |
| `OTEL_LOG_TOOL_DETAILS` | Tool events carry no commands or inputs | Bash commands and tool input land in the tables |

When `OTEL_LOG_ASSISTANT_RESPONSES` is unset it follows `OTEL_LOG_USER_PROMPTS`.
Turning any of them on through managed settings puts that content in BigQuery
for everyone.

`user.id` is a random per-install identifier rather than a hash, so it cannot be
traced to a person on its own. `user.email` is the only field that names
someone.

## Limitations

**The sink delivers at least once.** The same entry can be written to BigQuery
more than once, as duplicate rows sharing an `insertId`. Nothing dedupes them,
so an unguarded `SUM(cost_usd)` runs high. Every query here keeps one row per
`insertId`:

```sql
QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId) = 1
```

`QUALIFY` runs after `GROUP BY`, so where a query aggregates, the dedupe sits in
a subquery around the source instead.

**Tables and columns appear only once written.** The sink creates a table the
first time that event type is written and adds a label column the first time
that label is seen. A project with no hooks has no `hook_execution_complete`
table; `tool_result.error_type` does not exist until a tool fails. Referencing a
missing table or column is an error in BigQuery rather than a null, so `02`
through `05` check `INFORMATION_SCHEMA` first and degrade instead of failing.
Schema changes are additive, so once something appears it stays.

**Metric cost reads lower than log cost.** Cloud Monitoring enforces a minimum
spacing between points on one time series and rejects anything closer. These
metrics are DELTA, so a rejected point is lost rather than corrected by the next
one. Measured over three days at a 10-second export interval, the metric total
came in about 15% under the logs, worst on the busiest day. Hence
`OTEL_METRIC_EXPORT_INTERVAL` of 60000. **Do not set it below 15000.** Sparse
series such as `commit.count` are unaffected; dense ones such as `cost.usage`
and `token.usage` are where the loss falls.

**Cost appears on both sides and the two will not match.**
`claude_code.cost.usage` and `api_request.cost_usd` describe the same calls but
travel independently. Prefer BigQuery. Both are Claude Code's own estimates, and
your Google Cloud bill is authoritative over either.

**Dynamic headers need HTTP.** `otelHeadersHelper` works with `http/protobuf`
and `http/json` only. Under `grpc`, Claude Code uses static headers, the token
is never refreshed, and exports fail about an hour in.

**How much `user.email` can be trusted depends on where you put it.** In a
machine's `managed-settings.json` it outranks every other level, so the
developer cannot change it. Anywhere else, including the
`~/.claude/settings.json` that `print-settings.sh --merge` writes, it is a
string they can edit. Either way it is good enough to attribute spend, and
neither proves who did something. For an address no developer can set at all,
use [`bigquery-mod/`](../bigquery-mod/), which ignores
`OTEL_RESOURCE_ATTRIBUTES` for this and reads the credential each session.

## Files

| File | What it does |
|---|---|
| `setup.sh` | Asks for configuration, writes `config.env`, renders `sql/*.local.sql` |
| `enable-and-grant.sh` | Enables APIs, grants IAM, creates the dataset and sink, prints the exclusion |
| `print-settings.sh` | Produces developer or fleet-wide Claude Code settings |
| `otel-headers-helper.sh` | Mints the access token for each export |
| `sql/` | The six queries |

## License

Apache License 2.0 — see the [LICENSE](../../LICENSE) at the repository root.
Copyright 2026 The "Anthropic on Google Cloud" Authors.
