# Claude Code → Telemetry API → BigQuery (logs only)

Claude Code OpenTelemetry **logs** straight into BigQuery. Claude Code exports
OTLP to `telemetry.googleapis.com` directly, a Log Router sink writes the
entries into BigQuery tables, and you query them with SQL. Nothing to deploy —
no collector, no container image, no service accounts.

```
Claude Code ──OTLP/HTTP──> telemetry.googleapis.com ──> Cloud Logging
                                                             │
                                                     Log Router sink
                                                             │
                                                        BigQuery
```

## Quickstart

```bash
./setup.sh                              # writes config.env, renders sql/*.local.sql
./enable-and-grant.sh                   # APIs, IAM, BigQuery dataset, Log Router sink
./print-settings.sh you@yourco.com --merge   # each developer runs this, then restarts
```

Then run `sql/00-schema.local.sql` first, and the rest once rows are landing.

## The data

One BigQuery table per event type, named for the bare event. `labels` is a
STRUCT of STRINGs with sanitized keys (`user.email` → `labels.user_email`), so
numerics need `SAFE_CAST`. Tables are partitioned on `timestamp`; every query
filters on it to keep the scan cheap.

| Table | Carries |
|---|---|
| `api_request` | `cost_usd`, input/output/cache tokens, `model`, `duration_ms`, `ttft_ms` |
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

It is **not applied automatically**, and it is irreversible. Run traffic,
confirm rows are in BigQuery, confirm `labels.user_email` and
`labels.app_version` are populated (`00-schema.sql`), and only then exclude.
Afterwards these tables are the only copy and log entries cannot be rewritten.

## Scope

Claude Code emits some signals only as metrics, so they are not in these tables:
`lines_of_code.count`, `active_time.total`, `commit.count`,
`pull_request.count`. `session.count` is partly recoverable — distinct
`session.id` in the logs undercounts sessions that made no API call.

If you need those as well, run a metrics pipeline alongside this one; see
[`otel-bq/`](../otel-bq/) for the collector-based setup.

## Privacy

`OTEL_LOG_USER_PROMPTS` is left off. Prompt text never leaves the machine;
`user_prompt` entries carry a length only. `user.id` is a hash;
`user.email` is present because `OTEL_RESOURCE_ATTRIBUTES` sets it explicitly.

`assistant_response` has a `labels.response` column, which looks alarming but is
not: Claude Code redacts it at source and every value is the literal string
`<REDACTED>`. The usable field is `labels.response_length`. Verified 2026-09-24 —
max `LENGTH(labels.response)` was 10 while `response_length` reported 222.
