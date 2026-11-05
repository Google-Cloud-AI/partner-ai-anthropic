#!/usr/bin/env bash
# Copyright 2026 The "Anthropic on Google Cloud" Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Creates reporting views over the tables the Log Router sink writes:
#   daily_spend     day x user
#   spend_by_model  day x model
#   daily_usage     day x user x model, with sessions and tool calls
#
# They go in their own dataset (VIEWS_DATASET, default ${SINK_DATASET}_reporting),
# so readers of the views need no access to the raw log tables.
#
# RUN THIS ONCE ROWS ARE LANDING, not straight after enable-and-grant.sh. The
# sink creates each table the first time that event type is written, and
# BigQuery refuses to create a view over a table that does not exist yet. A
# view whose tables are missing is skipped with a message; run this again
# later and it is created then.
#
# Safe to re-run: views are replaced, nothing is removed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG}" ]]; then
  echo "create-views: ${CONFIG} not found. Run ./setup.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG}"

: "${PROJECT:?PROJECT is required in config.env}"
: "${SINK_DATASET:?SINK_DATASET is required in config.env}"
VIEWS_DATASET="${VIEWS_DATASET:-${SINK_DATASET}_reporting}"
BQ_LOCATION="${BQ_LOCATION:-US}"

echo "== Claude Code reporting views =="
echo "   tables: ${PROJECT}.${SINK_DATASET}"
echo "   views:  ${PROJECT}.${VIEWS_DATASET} (${BQ_LOCATION})"
echo

if bq --project_id="${PROJECT}" show --dataset "${PROJECT}:${VIEWS_DATASET}" >/dev/null 2>&1; then
  echo "==> Dataset ${VIEWS_DATASET} already exists"
else
  echo "==> Creating dataset ${VIEWS_DATASET}"
  bq --project_id="${PROJECT}" --location="${BQ_LOCATION}" mk --dataset \
    --description="Views over the Claude Code telemetry in ${SINK_DATASET}" \
    "${PROJECT}:${VIEWS_DATASET}" >/dev/null
fi

table_exists() {
  bq --project_id="${PROJECT}" show "${PROJECT}:${SINK_DATASET}.$1" >/dev/null 2>&1
}

render() {
  sed -e "s/__TABLE_DATASET__/${SINK_DATASET}/g" \
      -e "s/__DATASET__/${VIEWS_DATASET}/g" \
      -e "s/__PROJECT__/${PROJECT}/g" \
      "$1"
}

skipped=0
for view in daily_spend spend_by_model daily_usage; do
  case "${view}" in
    daily_usage) needs=(api_request tool_decision tool_result) ;;
    *)           needs=(api_request) ;;
  esac
  missing=()
  for t in "${needs[@]}"; do
    table_exists "${t}" || missing+=("${t}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "==> Skipping ${view}: table(s) not created yet: ${missing[*]}"
    skipped=1
    continue
  fi
  echo "==> Creating or replacing view ${VIEWS_DATASET}.${view}"
  render "${SCRIPT_DIR}/views/${view}.sql" |
    bq --quiet --project_id="${PROJECT}" query --nouse_legacy_sql >/dev/null
done

echo
if [[ "${skipped}" -eq 1 ]]; then
  echo "Some views were skipped. The sink creates tool_decision and tool_result"
  echo "the first time a tool is used: run some Claude Code traffic with tool"
  echo "use, then run ./create-views.sh again."
else
  echo "Done. Query, for example:"
  echo "  SELECT * FROM \`${PROJECT}.${VIEWS_DATASET}.daily_usage\` ORDER BY day DESC"
fi
