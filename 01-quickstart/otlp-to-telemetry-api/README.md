# Claude Code → Telemetry API → BigQuery + Cloud Monitoring

Claude Code OpenTelemetry straight into Google Cloud. Claude Code exports OTLP
to `telemetry.googleapis.com` directly, which fans out by signal type: log
records go to Cloud Logging, where a Log Router sink writes them into BigQuery
tables you query with SQL; metrics go to Cloud Monitoring, where they feed
dashboards. No server to deploy — no collector, no container image, no service
accounts to create.

```
                                           ┌─> Cloud Logging ─> sink ─> BigQuery
Claude Code ──OTLP/HTTP──> telemetry.googleapis.com
                                           └─> Cloud Monitoring ─> dashboards
```

One endpoint and one credential serve both signals.

## Quickstart

An org admin does all of this once. Developers run no scripts.

```bash
./setup.sh              # writes config.env and managed-settings.json, renders sql/*.local.sql
./enable-and-grant.sh   # APIs, IAM, BigQuery dataset, Log Router sink
```

Then [roll out the managed settings](#roll-out-with-managed-settings). After a
developer has run a few turns, check that rows arrive:

```bash
bq query --use_legacy_sql=false 'SELECT COUNT(*) FROM `YOUR_PROJECT_ID.YOUR_SINK_DATASET.api_request`'
```

A new sink takes a few minutes to start routing, and entries that arrive before
then never reach BigQuery. If that query finds no table a few minutes after the
first turns, run a few more and check again.

Run `sql/00-schema.local.sql` in the BigQuery console first, then the other
`.local.sql` files. Once rows are landing, including some tool use, run
`./create-views.sh` for the [reporting views](#the-views); it skips any view
whose tables the sink has not created yet. Last,
[decide on the exclusion](#cost): until you apply it, these logs are billed
twice.

To try the pipeline on your own machine before the fleet rollout, see
[Try it without installing](#try-it-without-installing).

### Who needs access, and who actually sends

Two different principals, and granting only the first is the most common way
this fails:

| Where Claude Code runs | Credential used | Grant |
|---|---|---|
| Laptop, off GCP | the developer's own `gcloud` sign-in | `DEVELOPERS` |
| GCE VM / Cloud Workstation | the **machine's** service account | `MACHINE_MEMBERS` |

`otel-headers-helper.sh` tries the metadata server first, so on GCP compute the
machine's service account wins even when the developer is signed in with
`gcloud` on that same box. Set both lists in `config.env`;
`enable-and-grant.sh` grants `roles/telemetry.writer` and
`roles/serviceusage.serviceUsageConsumer` to each.

Attribution is separate: `policy-helper.sh` takes `user.email` from the
developer's own `gcloud` sign-in, whichever credential sends the export. So on a
Workstation the row names the developer only if they have signed in there, and a
row's `user_email` says nothing about which token sent it.

Whatever you put in `DEVELOPERS` and `MACHINE_MEMBERS` has to exist in Google
Cloud, because IAM grants roles to real identities. Four forms work:

| Prefix | Means |
|---|---|
| `user:` | one Google account |
| `group:` | a Google group |
| `domain:` | a Cloud Identity domain, so everyone in it |
| `serviceAccount:` | a service account, which is what `MACHINE_MEMBERS` holds |

A group that exists only in Okta or Entra, and has not been synced to Cloud
Identity, will not resolve.

### Workload Identity Federation

Use it when the above does not fit: developers with no Google identity, or a
policy against granting telemetry roles to people at all.

Federate from the identity provider you already run, grant
`roles/telemetry.writer` once to a service account the pool can impersonate or
to the federated `principalSet://` directly, and put that one principal in
`DEVELOPERS`. No individual appears in IAM. Create the pool and provider with
[Google's setup guide](https://docs.cloud.google.com/iam/docs/workload-identity-federation),
then ship the credential configuration alongside the managed settings.

`otel-headers-helper.sh` needs no change: a credential configuration activates
through Application Default Credentials, and the helper's `gcloud` path then
returns a short-lived federated token like any other.

Attribution still comes from each developer's own `gcloud` sign-in, so a
federated token belonging to a service account leaves `user.email` empty unless
they have also signed in.

The scripts here are unchanged by this path, but none of them set the pool up
for you; follow Google's guide above.

### Service account keys

Avoid them. A key file does not expire, has to be copied to every laptop, and
cannot be revoked for one person without rotating it for everyone. Many
organisations block them outright.

## Roll out with managed settings

Claude Code reads
[managed settings](https://code.claude.com/docs/en/managed-settings) above every
other settings level, so one deployment
[turns telemetry on for every developer](https://code.claude.com/docs/en/monitoring-usage#administrator-configuration)
and
[developers can't redirect it](https://code.claude.com/docs/en/monitoring-usage#how-managed-settings-lock-the-otlp-destination).
Developers need Claude Code 2.1.257 or later, which supports the
[`policyHelper`](https://code.claude.com/docs/en/settings-reference#policyhelper)
setting this rollout relies on. An admin deploys three files to each machine,
which also needs `gcloud` installed:

| File | macOS | Linux and WSL |
|---|---|---|
| `managed-settings.json` | `/Library/Application Support/ClaudeCode/` | `/etc/claude-code/` |
| `policy-helper.sh` | `/usr/local/libexec/claude-code-telemetry/` | same |
| `otel-headers-helper.sh` | `/usr/local/libexec/claude-code-telemetry/` | same |

Both scripts must be executable. Make them owned by root and not writable by
developers too: what `policy-helper.sh` prints becomes the managed settings. Push all three as files with
the tool that already manages your fleet: Jamf, Intune, Ansible, or the image for
your Cloud Workstations. With an MDM, use its file or script delivery, not a
configuration profile: a profile outranks this file, so the helper does not run
and nothing reaches Google. Move any keys from an existing profile into this
file. Each developer picks up the change at their next Claude Code start.

**A mistake here stops Claude Code from starting on every machine it reaches.** It
refuses to start if the file names a `policyHelper` that is missing or not
executable, so deliver the scripts before the file, and when removing this setup,
remove the file first. It also refuses if a key holds an invalid value it can't repair: without a
helper it would only drop that key, but helper output is checked more strictly. Test
every edit first with [Try it without installing](#try-it-without-installing),
then install it on one machine and [check the rollout](#check-the-rollout).

On one Linux machine, the install looks like this. If the machine already has a
`managed-settings.json`, merge these keys into it instead of replacing it.

```bash
sudo install -d /etc/claude-code /usr/local/libexec/claude-code-telemetry
sudo install -m 755 policy-helper.sh otel-headers-helper.sh /usr/local/libexec/claude-code-telemetry/
sudo install -m 644 managed-settings.json /etc/claude-code/
```

### What developers still do

Each developer signs in to Google, and again when that session expires, with
`gcloud auth login` or `gcloud auth application-default login`. Claude Code on
Google Cloud already needs the second, and both helpers accept either. Until a
developer signs in, Claude Code works normally but exports nothing, and shows a
warning. On GCP compute the machine's service account sends the data without a
sign-in, but the row names the developer only if they have signed in.
On a GCE VM or Cloud Workstation that means running `gcloud auth login` on the
machine itself; without it, rows go out with no `user_email`. Use
`gcloud auth login` there rather than `gcloud auth application-default login`,
which would also move Claude Code's model calls from the machine's service
account to the developer.

### Try it without installing

To try `managed-settings.json` and check the sink, the SQL and the views before
touching any developer machine, run this command in this folder after
`./setup.sh` and `./enable-and-grant.sh`. It needs no `sudo` and installs nothing.
No rows arrive unless the credential that sends them has the access described in
[Who needs access](#who-needs-access-and-who-actually-sends):

```bash
settings="$(./policy-helper.sh --try)" \
  && printf '%s\n' "${settings}" > try-settings.json \
  && alias claude="claude --settings '${PWD}/try-settings.json'"
```

The command runs `policy-helper.sh` on this folder's `managed-settings.json`,
writes the result to `try-settings.json`, and makes every `claude` you start in
this shell use that file, so those sessions send what a rollout would send. That
includes your address if Google can verify your `gcloud` sign-in. If it can't,
the command warns you and rows go out without it, so sign in and run the command
again if you want to check the SQL and the views. The command doesn't change
`~/.claude/settings.json`, and other shells and scripts run `claude` without this
file. The sessions use `otel-headers-helper.sh` in this folder, so keep the folder
where it is. Start `claude`, run a few turns, then check for rows with the query
in the [Quickstart](#quickstart). Close the shell or run `unalias claude` to stop.

To see the settings, open `try-settings.json`. Claude Code ignores its
`policyHelper` entry, which only takes effect in managed settings. An edit
reaches the next `claude` you start, not one already running. The file keeps your
email address and hostname from when it was written, so run the command again
after you change your `gcloud` sign-in or `managed-settings.json`. That overwrites
your edits to `try-settings.json`, so make any change you want to keep in
`managed-settings.json`.

If Claude Code reports a settings error in `try-settings.json`, the session can
carry on but sends nothing. Make the fix in `managed-settings.json` and run the
command again, because the same mistake there stops Claude Code from starting once
the file is deployed. Trying the settings this way does not test the installed
files, so still check one machine as in [Check the rollout](#check-the-rollout).
On a machine that already has the managed settings, they take priority and
`try-settings.json` has no effect; `/status` then lists
`Enterprise managed settings (helper)` under setting sources.
The path to this folder can't contain `'`, `"` or `\`.

### Example `managed-settings.json`

`setup.sh` renders this from
[`managed-settings.example.json`](./managed-settings.example.json), filling in
your project, quota project and region. It has the same shape as a
`settings.json`, but it must be named `managed-settings.json` and sit in the
system folder above, not in `~/.claude/`.

```json
{
  "policyHelper": {
    "path": "/usr/local/libexec/claude-code-telemetry/policy-helper.sh"
  },
  "otelHeadersHelper": "/usr/local/libexec/claude-code-telemetry/otel-headers-helper.sh YOUR_QUOTA_PROJECT",
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://telemetry.googleapis.com",
    "OTEL_SERVICE_NAME": "claude-code",
    "OTEL_METRIC_EXPORT_INTERVAL": "60000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS": "180000",
    "OTEL_RESOURCE_ATTRIBUTES": "gcp.project_id=YOUR_PROJECT_ID,location=YOUR_LOCATION,service.instance.id=unknown",
    "OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES": "true",
    "OTEL_METRICS_INCLUDE_VERSION": "true"
  }
}
```

Some of these values are easy to get wrong:

| Key | Why it is set this way |
|---|---|
| `otelHeadersHelper` | A top-level key, a sibling of `env`. Google access tokens expire after an hour, so Claude Code re-runs this [dynamic headers](https://code.claude.com/docs/en/monitoring-usage#dynamic-headers) script instead of sending a static token. |
| `OTEL_SERVICE_NAME` | Already the default. It is set so that a developer's own value can't take their logs out of the sink, which matches on it. |
| `OTEL_RESOURCE_ATTRIBUTES` | Leave `service.instance.id=unknown` exactly as it is: `policy-helper.sh` replaces that text. You can add other attributes beside it. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Keep `http/protobuf`. Under `grpc`, Claude Code ignores `otelHeadersHelper`, so exports start failing when the first token expires. |
| `CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS` | Keep it under 5 minutes. The helper can be handed a cached token with only 5 minutes left, and at the 29-minute default that token expires long before the next refresh. See `otel-headers-helper.sh`. |
| `OTEL_METRIC_EXPORT_INTERVAL` | Do not lower it below 15000. See the cost warning under [Signals](#signals-which-side-answers-what). `OTEL_LOGS_EXPORT_INTERVAL` has no such floor. |
| `OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES` | A boolean, and it governs log records too. Naming attributes in it reads as false and drops `user.email` from every entry. |
| `OTEL_METRICS_INCLUDE_VERSION` | Defaults to false. It also governs log records, and it produces `labels.app_version`. |

### Why there is a policy helper

Two values in `OTEL_RESOURCE_ATTRIBUTES` differ from machine to machine, and
Claude Code does not expand that string, so `$(hostname)` would stay literal:

| Attribute | Value | Source |
|---|---|---|
| `gcp.project_id` | Same for everyone | `managed-settings.json` |
| `location` | Same for everyone, so pick the region deliberately. The endpoint requires a real region and rejects `global` | `managed-settings.json` |
| `service.instance.id` | The hostname; required by the endpoint, and the `host` column in `sql/` | `policy-helper.sh` |
| `user.email` | The developer's address, verified with Google | `policy-helper.sh` |

On Google Cloud there is no Claude account in the session, so Claude Code cannot
fill in `user.email` itself. A
[`policyHelper`](https://code.claude.com/docs/en/managed-settings#compute-the-policy-with-a-helper-program)
closes the gap. Claude Code runs `policy-helper.sh` as the developer at every
start, and it prints `managed-settings.json` back with
`service.instance.id=unknown` replaced by the real values.

Keep all of your managed settings in this one `managed-settings.json`. The helper
re-emits that file and nothing else, so keys in `managed-settings.d/` stop
applying.

Each start waits for the helper, usually 1 to 3 seconds and at most 5.
If it can't verify a person's address in that time, Claude Code still starts and
rows go out without `user.email`. The queries in `sql/` then show `user.id` instead,
prefixed `id:`, but they need the `labels.user_email` column to exist, so at least
one signed-in developer has to send traffic first.

### Where this does not reach

- **Server-managed settings** from the claude.ai admin console
  [don't reach sessions that use Google Cloud models](https://code.claude.com/docs/en/server-managed-settings#platform-availability).
  Where they do apply, such as a developer signed in to a Team or Enterprise
  account, they take precedence, so the helper does not run and nothing reaches
  Google.
- **Native Windows** is not covered by this quickstart: both scripts are bash, and a
  `policyHelper` must be an `.exe` there.

### Check the rollout

On one machine, as a developer rather than with `sudo`, print what the helper
computes (this needs `jq`), then confirm it in Claude Code:

```bash
/usr/local/libexec/claude-code-telemetry/policy-helper.sh | jq -r .managedSettings.env.OTEL_RESOURCE_ATTRIBUTES
```

Expect `gcp.project_id=...,location=...,service.instance.id=<hostname>,user.email=<address>`.

In Claude Code, `/status` should list `Enterprise managed settings (helper)`
under setting sources. It also shows any `otelHeadersHelper` failure. In the
`sql/` results, a `host` of `unknown` means the helper did not run on that
machine, for example on a Claude Code version without `policyHelper`. A `user_key`
(the developer column) starting `id:` means no address was verified. If no rows
reach BigQuery, start Claude Code with
`claude --debug-file <path>` and look for `[3P telemetry]` errors, or see the
[monitoring docs](https://code.claude.com/docs/en/monitoring-usage).

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
inflated by whatever the duplicate rate happens to be. The rate is usually
well under 1%, but it is not constant and not worth assuming.

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

Run the `.local.sql` copies that `setup.sh` renders.

`04` and `05` pre-aggregate each event family to one row per join key *before*
joining. Joining the raw tables fans out — a turn with six tool calls would
count its cost six times.

## The views

`create-views.sh` adds three views in their own dataset (`VIEWS_DATASET`,
default `<SINK_DATASET>_reporting`), so people who read them need no access to
the raw log tables. Each keeps one row per `insertId`, like the queries above.

| View | One row per | Columns |
|---|---|---|
| `daily_spend` | day × user | `api_requests`, `cost_usd`, input/output/cache tokens |
| `spend_by_model` | day × model | the same |
| `daily_usage` | day × user × model | the same, plus `sessions`, `tool_calls_proposed`, `tool_calls_rejected`, `tool_calls`, `tool_calls_failed` |

A user is `labels.user_email`, or `id:` and the anonymous `user.id` when that
is empty.

Tool events carry no model, so `daily_usage` gives each tool call the model of
the API request that asked for it, matched on `labels.request_id`.

Run the script once rows are landing. The sink creates each table the first time
that event type arrives, and BigQuery will not create a view over a missing
table, so `daily_usage` waits for the first tool use (`tool_decision`,
`tool_result`). A view whose tables are missing is skipped with a message;
re-run the script later. It is safe to re-run and only replaces the views.

## Cost

Until you exclude them, these logs are billed twice: Cloud Logging ingestion
($0.50/GiB above the free 50 GiB/month) plus BigQuery storage. The exclusion at
the end of `enable-and-grant.sh` stops the Logging charge; re-run that script to
print the exact command.

It is **not applied automatically**, and what it drops is gone for good. Run
traffic, confirm rows are in BigQuery, confirm `labels.user_email` and
`labels.app_version` exist (`00-schema.sql`), and only then exclude.
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
> At a 10s export interval the metric total has been measured around 15% under
> the logs, and the gap widens the busier the day. That is why
> `managed-settings.json` sets `OTEL_METRIC_EXPORT_INTERVAL` to 60000 — **do not
> lower it below 15000.** Sparse series (`commit.count`, `pull_request.count`) are
> unaffected either way; dense ones (`cost.usage`, `token.usage`) are where the
> loss lands.

## Privacy

What is and is not captured follows four settings, so read them rather than the
sample data: `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`,
`OTEL_LOG_TOOL_DETAILS` and `OTEL_LOG_RAW_API_BODIES`. All default to off, and
`managed-settings.json` leaves them unset, so a developer can still turn one on
for their own sessions, and that content then lands in these tables. You can
prevent that by setting them to `"0"` in `managed-settings.json`. With them off, `user_prompt` entries carry a length only, `labels.response` on `assistant_response` is always
`<REDACTED>` (use `labels.response_length`), and tool events carry no commands or
inputs. When `OTEL_LOG_ASSISTANT_RESPONSES` is unset it follows
`OTEL_LOG_USER_PROMPTS`.

`user.id` is a random per-install identifier, not a hash of anything —
reinstalling generates a new unrelated value, so it cannot be traced back to a
person on its own. `user.email` is the only field in these tables that names
someone. It is present because `OTEL_RESOURCE_ATTRIBUTES` sets it, and
`policy-helper.sh` fills that in from the developer's verified `gcloud` identity
rather than from free text, at every start. Managed settings override these keys in a developer's own `settings.json` or
shell, so where an address is present it is reliable enough to bill against. It
is still an accuracy control, not a security boundary: the helper runs as the
developer, so a developer who sets out to change it can.

Treat that as the behaviour of the defaults rather than a guarantee: the
settings above decide it, so check them rather than the sample data.

## License

Apache License 2.0 — see the [LICENSE](../../LICENSE) at the repository root.
Copyright 2026 The "Anthropic on Google Cloud" Authors.
