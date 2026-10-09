# Claude Code → Telemetry API → BigQuery + Cloud Monitoring

Claude Code OpenTelemetry straight into Google Cloud. Claude Code exports OTLP
to `telemetry.googleapis.com` directly, which fans out by signal type: log
records go to Cloud Logging, where a Log Router sink writes them into BigQuery
tables you query with SQL; metrics go to Cloud Monitoring, where they feed
dashboards. Nothing to deploy — no collector, no container image, no service
accounts.

```
                                           ┌─> Cloud Logging ─> sink ─> BigQuery
Claude Code ──OTLP/HTTP──> telemetry.googleapis.com
                                           └─> Cloud Monitoring ─> dashboards
```

One endpoint and one credential serve both signals.

## Quickstart

```bash
./setup.sh                              # writes config.env, renders sql/*.local.sql
./enable-and-grant.sh                   # APIs, IAM, BigQuery dataset, Log Router sink
./print-settings.sh --merge             # each developer runs this, then restarts
```

`print-settings.sh` takes no email: it derives your address from your `gcloud`
credential and verifies it with Google, so nobody can be recorded as someone
else by typing the wrong thing. Pass one explicitly to override, and it will
warn that the value is asserted rather than verified.

Then run `sql/00-schema.local.sql` first, and the rest once rows are landing.

### Who needs access, and who actually sends

Two different principals, and granting only the first is the most common way
this fails:

| Where Claude Code runs | Credential used | Grant |
|---|---|---|
| Laptop, off GCP | the developer's own `gcloud auth login` | `DEVELOPERS` |
| GCE VM / Cloud Workstation | the **machine's** service account | `MACHINE_MEMBERS` |

`otel-headers-helper.sh` tries the metadata server first, so on GCP compute the
machine's service account wins even when the developer is signed in with
`gcloud` on that same box. Set both lists in `config.env`;
`enable-and-grant.sh` grants `roles/telemetry.writer` and
`roles/serviceusage.serviceUsageConsumer` to each.

This is purely about *authentication*. Attribution is separate: `print-settings.sh`
derives `user.email` from the developer's own `gcloud` credential and verifies
it against Google's tokeninfo endpoint, independently of whichever credential
later carries the export. So on a Workstation the machine's service account
sends the data while the row still names the developer — and a row's
`user_email` tells you nothing about which token sent it.

## The data

One BigQuery table per event type, named for the bare event. `labels` is a
STRUCT of STRINGs with sanitized keys (`user.email` → `labels.user_email`), so
numerics need `SAFE_CAST`. Tables are partitioned on `timestamp`; every query
filters on it to keep the scan cheap.

| Table | Carries |
|---|---|
| `api_request` | `cost_usd` (an estimate; your Google Cloud bill is authoritative), input/output/cache tokens, `model`, `duration_ms`, `ttft_ms` |
| `tool_decision` | `tool_name`, `decision`, `source`, `tool_source`, `tool_use_id` |
| `tool_result` | `duration_ms`, `success`, `error_type`, input/result size bytes |
| `assistant_response` | `response_length`, `model`, `query_source` |
| `hook_execution_complete` | `hook_name`, `hook_event`, `total_duration_ms`, blocking/cancelled counts |

Three ids stitch them together: `session.id` (a session), `prompt.id` (one user
turn), `tool_use_id` (one tool call).

### Tables and columns appear lazily

The sink creates a table the first time that event type is written, and adds a
label column the first time that label is seen. Both matter on a new deployment:

- **`hook_execution_complete` does not exist** until a hook actually fires. A
  project with no hooks configured never gets the table at all.
- **`tool_result.error_type` does not exist** until a tool actually fails, since
  the label is only emitted on failure.

Referencing a missing table or column is a hard error in BigQuery, not a null —
so `02`–`05` detect both cases via `INFORMATION_SCHEMA` and degrade to zero or a
status message instead of failing. Schema evolution is additive, so once the
column or table appears it stays.

### Delivery is at-least-once

The Log Router does not guarantee exactly-once delivery: the same log entry can
be written to BigQuery more than once, producing duplicate rows that share an
`insertId`. Nothing dedupes them for you, so an unguarded `SUM(cost_usd)` is
inflated by whatever the duplicate rate happens to be. Measured on this project:
7 duplicates in 178 `api_request` rows, overstating spend by 0.6%; the other
four tables had none. The rate is small and not constant — do not assume it.

Every query here therefore keeps one row per `insertId`:

```sql
QUALIFY ROW_NUMBER() OVER (PARTITION BY insertId) = 1
```

`QUALIFY` runs after `GROUP BY`, so where a read aggregates, the dedupe is in a
subquery wrapping the source rather than appended to the outer read.

## The queries

| File | Answers |
|---|---|
| `00-schema.sql` | Which tables and label columns actually exist. **Run first.** |
| `01-spend.sql` | Cost and tokens per day × developer, and per model with cache hit rate and latency. |
| `02-tools.sql` | Per tool: proposed → accepted → succeeded, p50/p95 duration, what fails and how, and which tools flood the context window. |
| `03-hooks.sql` | Per hook: invocations, p50/p95 duration, total seconds developers waited, blocks and cancellations. |
| `04-prompts.sql` | One row per turn across all five event types — cost, tools, response size, and where the wall clock went. |
| `05-sessions.sql` | One row per session — span, turns, cost per turn, reject rate, hook time as a share of the session. |

`04` and `05` pre-aggregate each event family to one row per join key *before*
joining. Joining the raw tables fans out — a turn with six tool calls would
count its cost six times.

## Cost

Until you exclude them, these logs are billed twice: Cloud Logging ingestion
($0.50/GiB above the free 50 GiB/month) plus BigQuery storage. The exclusion at
the end of `enable-and-grant.sh` stops the Logging charge.

It is **not applied automatically**, and what it drops is gone for good. Run
traffic, confirm rows are in BigQuery, confirm `labels.user_email` and
`labels.app_version` are populated (`00-schema.sql`), and only then exclude.
Afterwards these tables are the only copy and log entries cannot be rewritten.
The exclusion itself can be lifted later
(`gcloud logging sinks update _Default --remove-exclusions=claude-code-excluded`);
the entries it dropped while on cannot be brought back.

Log *retention* is deliberately left alone. It is a property of the `_Default`
bucket, which holds every other service's logs in the project, so tuning it for
Claude Code would shorten or bill everyone else's too. The exclusion is the cost
control here.

Metrics are billed separately, as Managed Service for Prometheus samples. At one
series per developer per metric this is negligible, and the 60s export interval
cuts sample volume six-fold against a 10s one — the accuracy fix and the cost
fix are the same change.

## Signals: which side answers what

Both signals ride the same export. They do not overlap in storage, and neither
is derived from the other.

| Question | Where | Why |
|---|---|---|
| What did it cost, per developer / model / turn? | **BigQuery** | Exact. Every API call is a row. |
| Which tools run, fail, or flood the context? | **BigQuery** | No metric equivalent exists. |
| How much hook time are developers waiting on? | **BigQuery** | No metric equivalent exists. |
| Commits, PRs, lines of code, active time | **Cloud Monitoring** | Emitted *only* as metrics — they never appear as log records, so they are not in these tables. |
| Sessions started | **Cloud Monitoring** | Distinct `session.id` in the logs undercounts sessions that made no API call. |

The metric side hydrates the Claude Code dashboard from
[monitoring-dashboard-samples#1254](https://github.com/GoogleCloudPlatform/monitoring-dashboard-samples/pull/1254)
with no extra pipeline — its widgets are PromQL over the `claude_code.*`
descriptors this export already produces.

> ⚠️ **Cost appears on both sides, and the two numbers will not match.**
> `claude_code.cost.usage` (metric) and `api_request.cost_usd` (log) describe the
> same API calls but travel independently. **Prefer BigQuery** — it is the more
> complete of the two, though both are Claude Code's own estimates and your
> Google Cloud bill is authoritative over either. Cloud Monitoring enforces a
> minimum spacing between points on the same
> time series and silently rejects anything closer; because these metrics are
> DELTA, a rejected point is lost for good rather than healing on the next write.
> Measured here over three days at a 10s export interval, the metric read 15.5%
> under the logs ($15.5625 vs $18.4073), worst on the busiest day. That is why
> `print-settings.sh` emits `OTEL_METRIC_EXPORT_INTERVAL: 60000` — **do not lower
> it below 15000.** Sparse series (`commit.count`, `pull_request.count`) are
> unaffected either way; dense ones (`cost.usage`, `token.usage`) are where the
> loss lands.

For the collector-based alternative, see [`otel-bq/`](../otel-bq/).

## Privacy

What is and is not captured follows three settings, so read them rather than
the sample data. `print-settings.sh` leaves `OTEL_LOG_USER_PROMPTS`,
`OTEL_LOG_ASSISTANT_RESPONSES` and `OTEL_LOG_TOOL_DETAILS` unset, and all three
default to off. With them off, `user_prompt` entries carry a length only,
`labels.response` on `assistant_response` is always `<REDACTED>` (use
`labels.response_length`), and tool events carry no commands or inputs. If any
of them is turned on — through managed settings, for example — that content
lands in these tables. When `OTEL_LOG_ASSISTANT_RESPONSES` is unset it follows
`OTEL_LOG_USER_PROMPTS`.

`user.id` is a random per-install identifier, not a hash of anything —
reinstalling generates a new unrelated value, so it cannot be traced back to a
person on its own. `user.email` is the only field in these tables that names
someone. It is present because `OTEL_RESOURCE_ATTRIBUTES` sets it, and
`print-settings.sh` fills that in from the developer's verified `gcloud`
identity rather than from free text — so it is reliable enough to bill against,
but note that a developer with write access to their own `settings.json` can
still change it afterwards. It is an accuracy control, not a security boundary.

The redaction above was confirmed on this deployment on 2026-09-24: max
`LENGTH(labels.response)` was 10 (the literal `<REDACTED>`) while
`response_length` reported 222. That is a check of the default, not a guarantee
independent of the settings.
