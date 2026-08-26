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
# Provision the EXACT cost-reporting layer for Looker Studio / BigQuery:
#   1. A BigQuery "linked dataset" over the _Default Log Analytics bucket, so
#      Claude Code logs are queryable in BigQuery (and thus Looker Studio).
#   2. A reporting dataset with two views — daily_spend (day x user) and
#      spend_by_model (day x model) — wrapping the same logic as the *.sql files.
#
# These read the raw cost_usd on each api_request log event, so the numbers are
# EXACT. (The Cloud Monitoring log-based cost metric buckets values and is only
# approximate — good for a glance, not for billing.)
#
# Idempotent: safe to re-run (views are CREATE OR REPLACE; link/dataset are
# created only if missing).
#
# Prereqs:
#   - ./deploy.sh has run (Log Analytics is enabled on the _Default bucket).
#   - Some Claude Code telemetry has been ingested.
#   - gcloud + bq authenticated with BigQuery Admin + Logging Admin on PROJECT.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_ENV}" ]]; then
  echo "ERROR: ${CONFIG_ENV} not found. Run ./setup.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG_ENV}"

if [[ -z "${PROJECT:-}" ]]; then
  echo "ERROR: PROJECT is empty in ${CONFIG_ENV}." >&2
  exit 1
fi

# Defaults if an older config.env predates these knobs.
LOGLINK_ID="${LOGLINK_ID:-claude_code_la}"
BQ_DATASET="${BQ_DATASET:-claude_code}"
BQ_LOCATION="${BQ_LOCATION:-US}"

echo "==> Project: ${PROJECT}"
echo "    Linked dataset: ${LOGLINK_ID}   Views: ${BQ_DATASET} (${BQ_LOCATION})"
gcloud config set project "${PROJECT}" >/dev/null

# ---- 1. BigQuery linked dataset over the _Default Log Analytics bucket -------
if gcloud logging links describe "${LOGLINK_ID}" \
     --bucket=_Default --location=global >/dev/null 2>&1; then
  echo "==> Linked dataset ${LOGLINK_ID} already exists"
else
  echo "==> Creating linked dataset ${LOGLINK_ID} (can take a few minutes)..."
  gcloud logging links create "${LOGLINK_ID}" \
    --bucket=_Default --location=global >/dev/null
fi

# ---- 2. Reporting dataset (holds the views) ---------------------------------
if bq --project_id="${PROJECT}" show --dataset "${PROJECT}:${BQ_DATASET}" >/dev/null 2>&1; then
  echo "==> BigQuery dataset ${BQ_DATASET} already exists"
else
  echo "==> Creating BigQuery dataset ${BQ_DATASET} in ${BQ_LOCATION}"
  bq --location="${BQ_LOCATION}" mk --dataset \
    --description="Claude Code exact cost views (from Log Analytics linked dataset)" \
    "${PROJECT}:${BQ_DATASET}" >/dev/null
fi

# ---- 3. Views (exact cost) --------------------------------------------------
# Render the DDL from placeholder templates (same approach as setup.sh's sed),
# so we never wrestle with $ / backticks inside a heredoc.
render() {
  sed -e "s/__PROJECT__/${PROJECT}/g" \
      -e "s/__LINK__/${LOGLINK_ID}/g" \
      -e "s/__DATASET__/${BQ_DATASET}/g"
}

echo "==> Creating/replacing view ${BQ_DATASET}.daily_spend"
render <<'DDL' | bq query --project_id="${PROJECT}" --nouse_legacy_sql >/dev/null
CREATE OR REPLACE VIEW `__PROJECT__.__DATASET__.daily_spend` AS
WITH events AS (
  SELECT
    timestamp,
    COALESCE(JSON_VALUE(labels,'$.user_email'),
             CONCAT('id:', JSON_VALUE(labels,'$."user.id"'))) AS user_key,
    JSON_VALUE(labels,'$.model')                              AS model,
    SAFE_CAST(JSON_VALUE(labels,'$.cost_usd')               AS FLOAT64) AS cost_usd,
    SAFE_CAST(JSON_VALUE(labels,'$.input_tokens')          AS INT64)   AS input_tokens,
    SAFE_CAST(JSON_VALUE(labels,'$.output_tokens')         AS INT64)   AS output_tokens,
    SAFE_CAST(JSON_VALUE(labels,'$.cache_creation_tokens') AS INT64)   AS cache_creation_tokens,
    SAFE_CAST(JSON_VALUE(labels,'$.cache_read_tokens')     AS INT64)   AS cache_read_tokens
  FROM `__PROJECT__.__LINK__._AllLogs`
  WHERE log_name = 'projects/__PROJECT__/logs/claude-code'
    AND JSON_VALUE(labels,'$."event.name"') = 'api_request'
)
SELECT
  DATE(timestamp)             AS day,
  user_key                    AS user,
  COUNT(*)                    AS api_requests,
  ROUND(SUM(cost_usd), 6)     AS cost_usd,
  SUM(input_tokens)           AS input_tokens,
  SUM(output_tokens)          AS output_tokens,
  SUM(cache_creation_tokens)  AS cache_creation_tokens,
  SUM(cache_read_tokens)      AS cache_read_tokens
FROM events
GROUP BY day, user;
DDL

echo "==> Creating/replacing view ${BQ_DATASET}.spend_by_model"
render <<'DDL' | bq query --project_id="${PROJECT}" --nouse_legacy_sql >/dev/null
CREATE OR REPLACE VIEW `__PROJECT__.__DATASET__.spend_by_model` AS
WITH events AS (
  SELECT
    timestamp,
    COALESCE(JSON_VALUE(labels,'$.model'), '(unknown)')     AS model,
    SAFE_CAST(JSON_VALUE(labels,'$.cost_usd')               AS FLOAT64) AS cost_usd,
    SAFE_CAST(JSON_VALUE(labels,'$.input_tokens')          AS INT64)   AS input_tokens,
    SAFE_CAST(JSON_VALUE(labels,'$.output_tokens')         AS INT64)   AS output_tokens,
    SAFE_CAST(JSON_VALUE(labels,'$.cache_creation_tokens') AS INT64)   AS cache_creation_tokens,
    SAFE_CAST(JSON_VALUE(labels,'$.cache_read_tokens')     AS INT64)   AS cache_read_tokens
  FROM `__PROJECT__.__LINK__._AllLogs`
  WHERE log_name = 'projects/__PROJECT__/logs/claude-code'
    AND JSON_VALUE(labels,'$."event.name"') = 'api_request'
)
SELECT
  DATE(timestamp)             AS day,
  model,
  COUNT(*)                    AS api_requests,
  ROUND(SUM(cost_usd), 6)     AS cost_usd,
  SUM(input_tokens)           AS input_tokens,
  SUM(output_tokens)          AS output_tokens,
  SUM(cache_creation_tokens)  AS cache_creation_tokens,
  SUM(cache_read_tokens)      AS cache_read_tokens
FROM events
GROUP BY day, model;
DDL

echo
echo "============================================================"
echo " Exact cost views ready:"
echo "   ${PROJECT}.${BQ_DATASET}.daily_spend      (day x user)"
echo "   ${PROJECT}.${BQ_DATASET}.spend_by_model   (day x model)"
echo
echo " Build a Looker Studio dashboard:"
echo "   1. Open the view in BigQuery:"
echo "      https://console.cloud.google.com/bigquery?project=${PROJECT}&ws=!1m5!1m4!4m3!1s${PROJECT}!2s${BQ_DATASET}!3sdaily_spend"
echo "   2. Click  Export -> Explore with Looker Studio."
echo "   3. Add charts: time series (day vs cost_usd), table by user,"
echo "      and a pie by model (add spend_by_model as a second source)."
echo
echo " Note: the linked dataset reads live log data (near real-time). Looker"
echo " Studio caches results — set Data freshness to 15 min, or hit Refresh."
echo "============================================================"
