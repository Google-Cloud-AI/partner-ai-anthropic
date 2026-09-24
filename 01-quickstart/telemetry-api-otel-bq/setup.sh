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
# Interactive setup: writes config.env (from your answers) and renders the SQL
# templates in sql/ to project-specific *.local.sql files. Safe to re-run —
# existing config.env values become the defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE="${SCRIPT_DIR}/config.env.example"
CONFIG="${SCRIPT_DIR}/config.env"

# Seed defaults from the example, then let an existing config.env override them.
# shellcheck disable=SC1090
source "${EXAMPLE}"
if [[ -f "${CONFIG}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG}"
  echo "==> Found existing config.env; its values are the defaults below."
fi

# ask VAR "Prompt text" — reads into the named variable, showing its current
# value as the default (press Enter to keep).
ask() {
  local var="$1" prompt="$2" current="${!1:-}" answer
  read -r -p "${prompt} [${current}]: " answer
  printf -v "${var}" '%s' "${answer:-${current}}"
}

echo "== Claude Code logs → BigQuery — setup =="
echo "   Logs only — OTEL_METRICS_EXPORTER is set to none."
echo

ask PROJECT       "GCP project ID for telemetry to land in (required)"
while [[ -z "${PROJECT}" ]]; do
  echo "  PROJECT is required."
  ask PROJECT     "GCP project ID for telemetry to land in (required)"
done
# Default the quota project to the destination project — the common case.
QUOTA_PROJECT="${QUOTA_PROJECT:-${PROJECT}}"
ask QUOTA_PROJECT     "Quota project (x-goog-user-project; usually the same)"
ask DEVELOPERS        "Who may send telemetry (prefer domain:yourco.com or group:team@yourco.com, so you never list individuals)"
ask FALLBACK_LOCATION "Region to report when off GCP (must be a real region; 'global' is rejected)"

echo
echo "  Logs are routed to real BigQuery tables by a Log Router sink."
echo "  enable-and-grant.sh creates the dataset, the sink, and the IAM grant it"
echo "  needs. It does NOT add the _Default exclusion: that is the only"
echo "  irreversible step, and it is left for you to run by hand after you have"
echo "  confirmed rows are actually landing in BigQuery."
ask SINK_ID           "Log Router sink name"
ask SINK_DATASET      "BigQuery dataset for routed logs"
ask BQ_LOCATION       "BigQuery location for the dataset (cannot be changed later)"
ask LOG_RETENTION_DAYS "Retention on the _Default log bucket, in days (blank = leave unchanged)"

cat > "${CONFIG}" <<EOF
# Written by setup.sh. Gitignored — safe to hold real values.

# ---- Required ---------------------------------------------------------------
PROJECT="${PROJECT}"
QUOTA_PROJECT="${QUOTA_PROJECT}"
DEVELOPERS="${DEVELOPERS}"

# ---- Resource attributes ------------------------------------------------------
FALLBACK_LOCATION="${FALLBACK_LOCATION}"

# ---- BigQuery -----------------------------------------------------------------
SINK_ID="${SINK_ID}"
SINK_DATASET="${SINK_DATASET}"
BQ_LOCATION="${BQ_LOCATION}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS}"
EOF
echo
echo "==> Wrote ${CONFIG}"

# ---- Render SQL templates ---------------------------------------------------
# Every template is sink-mode, so they all render unconditionally.
shopt -s nullglob
for src in "${SCRIPT_DIR}"/sql/*.sql; do
  case "${src}" in *.local.sql) continue ;; esac
  out="${src%.sql}.local.sql"
  sed -e "s/YOUR_PROJECT_ID/${PROJECT}/g" \
      -e "s/YOUR_SINK_DATASET/${SINK_DATASET}/g" "${src}" > "${out}"
  echo "==> Rendered sql/${out##*/}"
done
shopt -u nullglob

echo
echo "Next: ./enable-and-grant.sh   (enables APIs, grants IAM, creates the sink)"
