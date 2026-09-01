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
# templates to project-specific *.local.sql files. Safe to re-run — existing
# config.env values become the defaults.

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

echo "== Claude Code OTel Collector — setup =="
echo

ask PROJECT         "GCP project ID (required)"
while [[ -z "${PROJECT}" ]]; do
  echo "  PROJECT is required."
  ask PROJECT       "GCP project ID (required)"
done
ask REGION          "Cloud Run region"
ask SERVICE         "Cloud Run service name"
ask RUNTIME_SA_NAME "Collector runtime SA name"
ask INVOKER_SA_NAME "Shared invoker SA name (laptop devs impersonate this)"
ask DEVELOPERS      "Who may send telemetry (prefer domain:yourco.com or group:team@yourco.com, so you never list individuals)"
ask INVOKER_MEMBERS "Direct-invoker machines' SAs (metadata path; serviceAccount:...)"
ask MIN_INSTANCES   "Min instances (1 = always-on capture, 0 = scale to zero)"

# Keep the less-frequently-changed knobs at their sourced values.
cat > "${CONFIG}" <<EOF
# Written by setup.sh. Gitignored — safe to hold real values.

# ---- Required ---------------------------------------------------------------
PROJECT="${PROJECT}"

# ---- Cloud Run service ------------------------------------------------------
REGION="${REGION}"
SERVICE="${SERVICE}"
SECRET="${SECRET}"
CONTAINER_PORT="${CONTAINER_PORT}"
IMAGE="${IMAGE}"
MIN_INSTANCES="${MIN_INSTANCES}"
MAX_INSTANCES="${MAX_INSTANCES}"
MEMORY="${MEMORY}"

# ---- Identities -------------------------------------------------------------
RUNTIME_SA_NAME="${RUNTIME_SA_NAME}"
INVOKER_SA_NAME="${INVOKER_SA_NAME}"
DEVELOPERS="${DEVELOPERS}"
INVOKER_MEMBERS="${INVOKER_MEMBERS}"

# ---- Cost reporting (BigQuery + Looker Studio; optional) --------------------
LOGLINK_ID="${LOGLINK_ID}"
BQ_DATASET="${BQ_DATASET}"
BQ_LOCATION="${BQ_LOCATION}"
EOF
echo
echo "==> Wrote ${CONFIG}"

# ---- Render SQL templates ---------------------------------------------------
for tpl in daily-spend.sql spend-by-model.sql; do
  src="${SCRIPT_DIR}/${tpl}"
  out="${SCRIPT_DIR}/${tpl%.sql}.local.sql"
  [[ -f "${src}" ]] || continue
  sed "s/YOUR_PROJECT_ID/${PROJECT}/g" "${src}" > "${out}"
  echo "==> Rendered ${out##*/}"
done

echo
echo "Next: ./deploy.sh   (provisions APIs, SAs, IAM, secret, and the Cloud Run service)"
