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

# Creates what the bigquery-telemetry mod writes to, and the views that read it:
#   1. A dataset for the tables (default claude_code_telemetry), and a separate
#      dataset for the views (default claude_code_telemetry_reporting), so that
#      people who may write rows don't need any access to the views.
#   2. One table per kind of Claude Code event (api_request, tool_result, ...),
#      in the layout a Cloud Logging sink with partitioned tables uses: the
#      camelCase columns in schema.json, a labels RECORD with one STRING field
#      per attribute in event-labels.json and EXTRA_LABELS, plus a JSON field
#      extra_labels where the mod puts every other attribute, partitioned by
#      day on timestamp.
#   3. Views daily_spend and spend_by_model over the api_request table, with
#      the columns of the otel-bq quickstart's views of those names.
#
# Usage:
#   PROJECT=your-project-id ./setup.sh
# Optional settings (environment variables):
#   BQ_DATASET     dataset for the tables (default claude_code_telemetry)
#   VIEWS_DATASET  dataset for the views  (default ${BQ_DATASET}_reporting)
#   BQ_LOCATION    BigQuery location      (default US)
#   TABLE_PREFIX   added to the front of every table name (default none);
#                  set the mod's table_prefix option to the same value
#   EXTRA_LABELS   comma-separated attribute names to add to every table,
#                  such as keys you set in OTEL_RESOURCE_ATTRIBUTES
#                  (for example EXTRA_LABELS=team.id,department)
#
# Safe to re-run, and worth re-running after upgrading Claude Code: tables
# are created if missing, existing tables get any label fields they lack,
# and the views are replaced. Nothing is removed.
# Needs the bq CLI, signed in with permission to create datasets, tables and
# views in PROJECT (for example BigQuery Admin), and jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT="${PROJECT:?Set PROJECT to your Google Cloud project ID, e.g. PROJECT=my-project ./setup.sh}"
BQ_DATASET="${BQ_DATASET:-claude_code_telemetry}"
VIEWS_DATASET="${VIEWS_DATASET:-${BQ_DATASET}_reporting}"
BQ_LOCATION="${BQ_LOCATION:-US}"
TABLE_PREFIX="${TABLE_PREFIX:-}"
EXTRA_LABELS="${EXTRA_LABELS:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "setup.sh needs jq to build the table schemas; install it and run again." >&2
  exit 1
fi
# These names go into sed and SQL below, so only plain names are accepted.
if [[ ! "${PROJECT}" =~ ^[a-z][a-z0-9.:-]*$ ]]; then
  echo "PROJECT must be a Google Cloud project ID, such as my-project." >&2
  exit 1
fi
for name in "${BQ_DATASET}" "${VIEWS_DATASET}"; do
  if [[ ! "${name}" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Dataset name \"${name}\" may contain only letters, digits and underscores." >&2
    exit 1
  fi
done
if [[ ! "${TABLE_PREFIX}" =~ ^[A-Za-z0-9_]*$ ]]; then
  echo "TABLE_PREFIX may contain only letters, digits and underscores." >&2
  exit 1
fi

echo "==> Project ${PROJECT} (${BQ_LOCATION}): tables in ${BQ_DATASET}, views in ${VIEWS_DATASET}"

# ---- 1. Datasets ---------------------------------------------------------------
create_dataset() {
  if bq --project_id="${PROJECT}" show --dataset "${PROJECT}:$1" >/dev/null 2>&1; then
    echo "==> Dataset $1 already exists"
  else
    echo "==> Creating dataset $1"
    bq --project_id="${PROJECT}" --location="${BQ_LOCATION}" mk --dataset \
      --description="$2" "${PROJECT}:$1" >/dev/null
  fi
}
create_dataset "${BQ_DATASET}" "Claude Code telemetry written by the bigquery-telemetry mod"
create_dataset "${VIEWS_DATASET}" "Views over the Claude Code telemetry in ${BQ_DATASET}"

# ---- 2. Tables ---------------------------------------------------------------
# The columns one event's table needs: schema.json with one STRING field under
# labels for each attribute in event-labels.json and EXTRA_LABELS, named as a sink names it ("session.id" becomes
# session_id: other characters become "_", leading "_" are removed, lowercase).
want_schema() {
  jq --arg event "$1" --arg extra "${EXTRA_LABELS}" --slurpfile names "${SCRIPT_DIR}/event-labels.json" '
    def field_name: gsub("[^A-Za-z0-9_]"; "_") | sub("^_+"; "") | ascii_downcase | .[0:128];
    (($names[0].every_event + $names[0].events[$event] + ["extra_labels"] + ($extra | split(",") | map(gsub("^ +| +$"; ""))))
    | map(field_name | select(. != "")) | unique
    | map({name: ., type: (if . == "extra_labels" then "JSON" else "STRING" end), mode: "NULLABLE"})
    ) as $labels
    | map(if .name == "labels" then .fields = $labels else . end)
  ' "${SCRIPT_DIR}/schema.json"
}

# The table's current fields plus any wanted field it lacks, at any depth.
# Existing fields are kept as they are.
merge_schema() {
  jq --argjson want "$2" '
    def merge($want):
      (map(.name)) as $have
      | map(. as $f
          | ($want | map(select(.name == $f.name)) | .[0]) as $w
          | if $f.type == "RECORD" and ($w.fields // null) != null then .fields = (.fields | merge($w.fields)) else . end)
        + [$want[] | select(.name as $n | $have | index($n) | not)];
    merge($want)
  ' <<<"$1"
}

count_fields() {
  jq '[.. | objects | select(has("name"))] | length' <<<"$1"
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

string_extra=0
for event in $(jq -r '.events | keys[]' "${SCRIPT_DIR}/event-labels.json"); do
  table="${TABLE_PREFIX}${event}"
  want="$(want_schema "${event}")"
  if have="$(bq --project_id="${PROJECT}" show --schema --format=json "${PROJECT}:${BQ_DATASET}.${table}" 2>/dev/null)"; then
    merged="$(merge_schema "${have}" "${want}")"
    # BigQuery can't change a field's type, so an extra_labels made as STRING
    # by an earlier setup.sh stays STRING (the mod writes the same JSON text).
    if [[ "$(jq -r '.[] | select(.name == "labels") | .fields[]? | select(.name == "extra_labels") | .type' <<<"${have}")" == "STRING" ]]; then
      string_extra=$((string_extra + 1))
    fi
    if [[ "$(count_fields "${merged}")" == "$(count_fields "${have}")" ]]; then
      echo "==> Table ${table} is up to date"
    else
      echo "==> Adding fields to table ${table}"
      printf '%s\n' "${merged}" >"${tmp}"
      bq --project_id="${PROJECT}" update "${PROJECT}:${BQ_DATASET}.${table}" "${tmp}" >/dev/null
    fi
  else
    echo "==> Creating table ${table}"
    printf '%s\n' "${want}" >"${tmp}"
    bq --project_id="${PROJECT}" mk --table \
      --description="Claude Code ${event} events, one row per record" \
      --time_partitioning_field=timestamp \
      --time_partitioning_type=DAY \
      "${PROJECT}:${BQ_DATASET}.${table}" \
      "${tmp}" >/dev/null
  fi
done

if ((string_extra > 0)); then
  echo "    Note: labels.extra_labels is STRING, not JSON, in ${string_extra} table(s) an earlier setup.sh made;"
  echo "    read it there with JSON_VALUE(labels.extra_labels, '\$.key')."
fi

# ---- 3. Views -----------------------------------------------------------------
render() {
  sed -e "s/__TABLE_DATASET__/${BQ_DATASET}/g" \
      -e "s/__TABLE_PREFIX__/${TABLE_PREFIX}/g" \
      -e "s/__DATASET__/${VIEWS_DATASET}/g" \
      -e "s/__PROJECT__/${PROJECT}/g" \
      "$1"
}

for view in daily_spend spend_by_model; do
  echo "==> Creating or replacing view ${VIEWS_DATASET}.${view}"
  render "${SCRIPT_DIR}/sql/${view}.sql" |
    bq --project_id="${PROJECT}" query --nouse_legacy_sql >/dev/null
done

echo
echo "Done. Point the mod at the tables with these plugin options:"
echo "  project: ${PROJECT}"
echo "  dataset: ${BQ_DATASET}"
if [[ -n "${TABLE_PREFIX}" ]]; then
  echo "  table_prefix: ${TABLE_PREFIX}"
fi
