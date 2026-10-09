#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Admin setup for the logs-to-BigQuery path.
#
# There is nothing to deploy — no collector, no Cloud Run service, no container
# image, no Secret Manager entry, no service accounts. Claude Code talks to
# telemetry.googleapis.com directly. This script only:
#   1. enables the APIs
#   2. grants developers permission to write telemetry
#   3. creates the BigQuery dataset and the Log Router sink that fills it
#
# It deliberately does NOT apply the _Default exclusion. That is the only
# irreversible step; see the end of this file.
#
# Idempotent — safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG}" ]]; then
  echo "enable-and-grant: ${CONFIG} not found. Run ./setup.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG}"

: "${PROJECT:?PROJECT is required in config.env}"
: "${SINK_ID:?SINK_ID is required in config.env}"
: "${SINK_DATASET:?SINK_DATASET is required in config.env}"
QUOTA_PROJECT="${QUOTA_PROJECT:-${PROJECT}}"
BQ_LOCATION="${BQ_LOCATION:-US}"

echo "== Claude Code logs → BigQuery — admin setup =="
echo "   destination project: ${PROJECT}"
echo "   quota project:       ${QUOTA_PROJECT}"
echo "   sink / dataset:      ${SINK_ID} → ${SINK_DATASET} (${BQ_LOCATION})"
echo

# ---- 1. Enable APIs ---------------------------------------------------------
# monitoring.googleapis.com is needed to STORE and READ the metrics, even though
# clients never call it directly — they export everything to
# telemetry.googleapis.com, which fans out to Logging and Monitoring.
echo "==> Enabling APIs (idempotent)"
gcloud services enable \
  telemetry.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  bigquery.googleapis.com \
  --project="${PROJECT}" --quiet
# The quota project needs Service Usage reachable even when it is a different
# project from the destination.
if [[ "${QUOTA_PROJECT}" != "${PROJECT}" ]]; then
  gcloud services enable serviceusage.googleapis.com \
    --project="${QUOTA_PROJECT}" --quiet
fi

# ---- 2. Grant the principals that actually send ------------------------------
# Two roles on (potentially) two different projects:
#   roles/telemetry.writer                    on the DESTINATION project
#   roles/serviceusage.serviceUsageConsumer   on the QUOTA project
# roles/monitoring.metricWriter is NOT sufficient and is NOT required, even now
# that metrics are enabled: it authorises monitoring.googleapis.com, which
# clients never call. Everything goes to telemetry.googleapis.com, so
# roles/telemetry.writer covers both signals.
#
# TWO LISTS, because the sender is not always the developer. On a laptop
# otel-headers-helper.sh falls through to `gcloud auth print-access-token` and
# the developer's own credential is used, so DEVELOPERS is what matters. On GCE
# and Cloud Workstations the metadata server answers first and the MACHINE's
# service account is used instead — even for a developer signed in with gcloud.
# Granting only DEVELOPERS leaves every export from GCP compute rejected.
# Attribution is unaffected either way: user.email is resolved per developer by
# print-settings.sh and is independent of whoever holds the token.
TELEMETRY_MEMBERS="${DEVELOPERS:-} ${MACHINE_MEMBERS:-}"
if [[ -z "${TELEMETRY_MEMBERS// /}" ]]; then
  echo "==> No DEVELOPERS or MACHINE_MEMBERS set; skipping IAM grants"
else
  echo "==> Granting telemetry access"
  for member in ${TELEMETRY_MEMBERS}; do
    gcloud projects add-iam-policy-binding "${PROJECT}" \
      --member="${member}" \
      --role="roles/telemetry.writer" \
      --condition=None --quiet >/dev/null
    gcloud projects add-iam-policy-binding "${QUOTA_PROJECT}" \
      --member="${member}" \
      --role="roles/serviceusage.serviceUsageConsumer" \
      --condition=None --quiet >/dev/null
    echo "   - ${member}"
  done
fi

# ---- 3. BigQuery dataset ----------------------------------------------------
echo "==> Creating BigQuery dataset '${SINK_DATASET}'"
if bq --project_id="${PROJECT}" show --dataset "${SINK_DATASET}" >/dev/null 2>&1; then
  echo "   - already exists"
else
  bq --project_id="${PROJECT}" --location="${BQ_LOCATION}" mk \
    --dataset --description="Claude Code telemetry logs (Log Router sink)" \
    "${SINK_DATASET}" >/dev/null
  echo "   - created"
fi

# ---- 4. Log Router sink -----------------------------------------------------
# Match every Claude Code log, whatever the event type. Key on the RESOURCE, not
# the log name: log names on this path are the bare event name (`api_request`),
# not `claude_code.api_request` — the dotted string is the entry's text_payload,
# so a logName-prefix filter matches nothing, silently. The resource labels come
# from the OTLP attributes: job=claude-code (service.name), task_id (hostname).
# The per-event log names still give the sink one table per event type.
SINK_FILTER='resource.type="generic_task" AND resource.labels.job="claude-code"'

echo "==> Creating Log Router sink '${SINK_ID}'"
DEST="bigquery.googleapis.com/projects/${PROJECT}/datasets/${SINK_DATASET}"
if gcloud logging sinks describe "${SINK_ID}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud logging sinks update "${SINK_ID}" "${DEST}" \
    --log-filter="${SINK_FILTER}" \
    --use-partitioned-tables \
    --project="${PROJECT}" --quiet >/dev/null
  echo "   - updated"
else
  # --use-partitioned-tables matters: without it you get date-sharded
  # api_request_YYYYMMDD tables needing a wildcard union in every query.
  gcloud logging sinks create "${SINK_ID}" "${DEST}" \
    --log-filter="${SINK_FILTER}" \
    --use-partitioned-tables \
    --project="${PROJECT}" --quiet >/dev/null
  echo "   - created"
fi

# The sink writes as its own service identity, which has no access to the
# dataset by default. Without this grant the sink fails silently: no error
# anywhere, just no rows.
echo "==> Granting the sink's writer identity access to the dataset"
WRITER="$(gcloud logging sinks describe "${SINK_ID}" \
  --project="${PROJECT}" --format='value(writerIdentity)')"
if [[ -z "${WRITER}" ]]; then
  echo "   ! could not read writerIdentity; grant roles/bigquery.dataEditor and" >&2
  echo "     roles/logging.logWriter by hand" >&2
else
  # Both roles are what Google documents for a sink destination:
  # bigquery.dataEditor to write the rows, and logging.logWriter for
  # logging.logEntries.route. Rows did land here without logWriter, but an
  # undocumented permission that happens to work today is not something to
  # depend on.
  for role in roles/bigquery.dataEditor roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "${PROJECT}" \
      --member="${WRITER}" \
      --role="${role}" \
      --condition=None --quiet >/dev/null
  done
  echo "   - ${WRITER}"
fi

# ---- 5. The exclusion, last and only on request -----------------------------
# This is the step that actually stops the $0.50/GiB ingestion charge. The
# exclusion itself can be lifted later:
#   gcloud logging sinks update _Default --remove-exclusions=claude-code-excluded
# What cannot be undone is the data: entries dropped while it is on never reach
# _Default and cannot be recovered. So it is deliberately NOT automatic — run
# traffic first, confirm rows are landing in BigQuery, and only then exclude.
echo
echo "==> Log Router exclusion (the part that stops the ingestion charge)"
if gcloud logging sinks describe _Default --project="${PROJECT}" \
     --format='value(exclusions.name)' 2>/dev/null | grep -q 'claude-code-excluded'; then
  echo "   - already excluded from _Default"
else
  cat <<EOF
   NOT applied automatically. Verify the sink works first:

     1. Run some Claude Code traffic (a few turns, with tool use).
     2. Confirm rows are arriving:
          bq query --use_legacy_sql=false \\
            'SELECT COUNT(*) FROM \`${PROJECT}.${SINK_DATASET}.api_request\`'
     3. Confirm the identity labels made it into the schema — run
          sql/00-schema.local.sql
        and check for labels.user_email and labels.app_version. If they are
        absent, the two settings that produce them are off (see
        print-settings.sh) — fix those and let NEW traffic land before going on.
        Log entries cannot be rewritten after the fact.
     4. Only then exclude them from the _Default bucket:
          gcloud logging sinks update _Default \\
            --add-exclusion=name=claude-code-excluded,filter='${SINK_FILTER}' \\
            --project=${PROJECT}

   After step 4 these BigQuery tables are the ONLY copy of this telemetry, and
   the Logs Explorer stops showing it. The exclusion can be lifted again with
   --remove-exclusions=claude-code-excluded, but whatever it dropped while it
   was on is gone for good.
EOF
fi

echo
echo "Developers now run: ./print-settings.sh --merge"
echo "Then restart Claude Code. Query with the rendered sql/*.local.sql files."
