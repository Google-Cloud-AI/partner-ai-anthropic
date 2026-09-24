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
# No monitoring.googleapis.com: this path writes no metrics.
echo "==> Enabling APIs (idempotent)"
gcloud services enable \
  telemetry.googleapis.com \
  logging.googleapis.com \
  bigquery.googleapis.com \
  --project="${PROJECT}" --quiet
# The quota project needs Service Usage reachable even when it is a different
# project from the destination.
if [[ "${QUOTA_PROJECT}" != "${PROJECT}" ]]; then
  gcloud services enable serviceusage.googleapis.com \
    --project="${QUOTA_PROJECT}" --quiet
fi

# ---- 2. Retention -----------------------------------------------------------
# Only relevant until the exclusion is applied; after that BigQuery holds the
# logs and you set retention on the dataset/partitions instead.
if [[ -n "${LOG_RETENTION_DAYS:-}" ]]; then
  echo "==> Setting _Default bucket retention to ${LOG_RETENTION_DAYS} days"
  gcloud logging buckets update _Default \
    --location=global \
    --retention-days="${LOG_RETENTION_DAYS}" \
    --project="${PROJECT}" \
    --quiet >/dev/null
fi

# ---- 3. Grant developers ----------------------------------------------------
# Two roles on (potentially) two different projects:
#   roles/telemetry.writer                    on the DESTINATION project
#   roles/serviceusage.serviceUsageConsumer   on the QUOTA project
# roles/monitoring.metricWriter is NOT sufficient — it authorises
# monitoring.googleapis.com, which this path never calls.
if [[ -z "${DEVELOPERS:-}" ]]; then
  echo "==> No DEVELOPERS set; skipping IAM grants"
else
  echo "==> Granting telemetry access"
  for member in ${DEVELOPERS}; do
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

# ---- 4. BigQuery dataset ----------------------------------------------------
echo "==> Creating BigQuery dataset '${SINK_DATASET}'"
if bq --project_id="${PROJECT}" show --dataset "${SINK_DATASET}" >/dev/null 2>&1; then
  echo "   - already exists"
else
  bq --project_id="${PROJECT}" --location="${BQ_LOCATION}" mk \
    --dataset --description="Claude Code telemetry logs (Log Router sink)" \
    "${SINK_DATASET}" >/dev/null
  echo "   - created"
fi

# ---- 5. Log Router sink -----------------------------------------------------
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
  echo "   ! could not read writerIdentity; grant roles/bigquery.dataEditor by hand" >&2
else
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="${WRITER}" \
    --role="roles/bigquery.dataEditor" \
    --condition=None --quiet >/dev/null
  echo "   - ${WRITER}"
fi

# ---- 6. The exclusion, last and only on request -----------------------------
# This is the step that actually stops the $0.50/GiB ingestion charge, and the
# only irreversible one. It is deliberately NOT automatic: run traffic first,
# confirm rows are landing in BigQuery, and only then exclude. A dropped log
# entry cannot be recovered.
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
   the Logs Explorer stops showing it. Exclusions are irreversible.
EOF
fi

echo
echo "Developers now run: ./print-settings.sh <their-email> --merge"
echo "Then restart Claude Code. Query with the rendered sql/*.local.sql files."
