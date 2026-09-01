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
# Deploy the Google-built OpenTelemetry Collector to Cloud Run as a standalone,
# IAM-authenticated OTLP/HTTP endpoint for Claude Code telemetry.
#
# Idempotent: safe to re-run. Re-running picks up edits to collector-config.yaml.
#
# All deployment-specific values come from config.env (run ./setup.sh first).
#
# Prereq: `gcloud` authenticated as an identity with deploy rights on the project
# (run admin, secret admin, service-account admin/user). The collector's *runtime*
# identity and the *invoker* identities are handled below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/collector-config.yaml"
URL_FILE="${SCRIPT_DIR}/.collector-url"
CONFIG_ENV="${SCRIPT_DIR}/config.env"

# ---- Load configuration -----------------------------------------------------
if [[ ! -f "${CONFIG_ENV}" ]]; then
  echo "ERROR: ${CONFIG_ENV} not found. Run ./setup.sh (or copy config.env.example" >&2
  echo "       to config.env and edit it) before deploying." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG_ENV}"

if [[ -z "${PROJECT:-}" ]]; then
  echo "ERROR: PROJECT is empty in ${CONFIG_ENV}. Set it and re-run." >&2
  exit 1
fi

RUNTIME_SA="${RUNTIME_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
INVOKER_SA="${INVOKER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "==> Project: ${PROJECT}  Region: ${REGION}  Service: ${SERVICE}"
gcloud config set project "${PROJECT}" >/dev/null

# ---- 0. Sanity: can we talk to the project? ---------------------------------
if ! gcloud projects describe "${PROJECT}" >/dev/null 2>&1; then
  echo "ERROR: cannot access project ${PROJECT}. Run 'gcloud auth login' with an" >&2
  echo "       account that has deploy rights, then re-run this script." >&2
  exit 1
fi

# ---- 1. Enable APIs ---------------------------------------------------------
echo "==> Enabling APIs (idempotent)..."
gcloud services enable \
  run.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  cloudtrace.googleapis.com \
  secretmanager.googleapis.com

# ---- 1b. Enable Log Analytics on the _Default bucket ------------------------
# The SQL queries read _Default._AllLogs, which only exists once the _Default
# log bucket is upgraded to Log Analytics. Idempotent (no-op if already on).
echo "==> Enabling Log Analytics on the _Default log bucket"
gcloud logging buckets update _Default \
  --location=global \
  --enable-analytics \
  --quiet >/dev/null || echo "   (warning: could not enable Log Analytics; enable it manually if the SQL fails)"

# ---- 2. Runtime service account + roles -------------------------------------
if ! gcloud iam service-accounts describe "${RUNTIME_SA}" >/dev/null 2>&1; then
  echo "==> Creating runtime service account ${RUNTIME_SA}"
  gcloud iam service-accounts create "${RUNTIME_SA_NAME}" \
    --display-name="Claude Code OTel Collector (Cloud Run)"
else
  echo "==> Runtime service account ${RUNTIME_SA} already exists"
fi

echo "==> Granting export roles to runtime SA"
for ROLE in roles/logging.logWriter roles/monitoring.metricWriter roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null
done

# ---- 3. Shared invoker service account --------------------------------------
# Laptop developers have no metadata server, so they mint an ID token by
# impersonating this SA. It holds run.invoker (granted after the service exists,
# in step 6); developers get serviceAccountTokenCreator on it (step 7).
if ! gcloud iam service-accounts describe "${INVOKER_SA}" >/dev/null 2>&1; then
  echo "==> Creating invoker service account ${INVOKER_SA}"
  gcloud iam service-accounts create "${INVOKER_SA_NAME}" \
    --display-name="Claude Code OTel invoker (impersonated by developers)"
else
  echo "==> Invoker service account ${INVOKER_SA} already exists"
fi

# ---- 4. Collector config -> Secret Manager ----------------------------------
if ! gcloud secrets describe "${SECRET}" >/dev/null 2>&1; then
  echo "==> Creating secret ${SECRET} from collector-config.yaml"
  gcloud secrets create "${SECRET}" --data-file="${CONFIG_FILE}"
else
  echo "==> Adding new version to secret ${SECRET}"
  gcloud secrets versions add "${SECRET}" --data-file="${CONFIG_FILE}" >/dev/null
fi
# Let the runtime SA read the mounted secret.
gcloud secrets add-iam-policy-binding "${SECRET}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet >/dev/null

# ---- 5. Deploy Cloud Run service --------------------------------------------
echo "==> Deploying Cloud Run service ${SERVICE}"
gcloud run deploy "${SERVICE}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --service-account="${RUNTIME_SA}" \
  --no-allow-unauthenticated \
  --port="${CONTAINER_PORT}" \
  --args="--config=/etc/otelcol-google/config.yaml" \
  --update-secrets="/etc/otelcol-google/config.yaml=${SECRET}:latest" \
  --min-instances="${MIN_INSTANCES}" \
  --max-instances="${MAX_INSTANCES}" \
  --memory="${MEMORY}" \
  --quiet

# ---- 6. Invoker identities (who may SEND telemetry) -------------------------
# 6a. The shared invoker SA (laptop path) can invoke the service.
echo "==> Granting roles/run.invoker to invoker SA ${INVOKER_SA}"
gcloud run services add-iam-policy-binding "${SERVICE}" \
  --region="${REGION}" \
  --member="serviceAccount:${INVOKER_SA}" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

# 6b. Direct-invoker machines (metadata path, e.g. Cloud Workstations) whose
#     attached SA presents its own token — granted run.invoker directly.
for MEMBER in ${INVOKER_MEMBERS}; do
  echo "==> Granting roles/run.invoker to ${MEMBER} (direct/metadata path)"
  gcloud run services add-iam-policy-binding "${SERVICE}" \
    --region="${REGION}" \
    --member="${MEMBER}" \
    --role="roles/run.invoker" \
    --quiet >/dev/null
done

# ---- 7. Let developers impersonate the invoker SA (laptop path) -------------
for MEMBER in ${DEVELOPERS}; do
  echo "==> Granting roles/iam.serviceAccountTokenCreator on ${INVOKER_SA} to ${MEMBER}"
  gcloud iam service-accounts add-iam-policy-binding "${INVOKER_SA}" \
    --member="${MEMBER}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet >/dev/null
done

# ---- 8. Capture the URL -----------------------------------------------------
URL="$(gcloud run services describe "${SERVICE}" --region="${REGION}" \
  --format='value(status.url)')"
printf '%s' "${URL}" > "${URL_FILE}"

echo
echo "============================================================"
echo " Collector deployed."
echo "   Service URL : ${URL}"
echo "   Saved to    : ${URL_FILE}"
echo
echo " Set this in each developer's ~/.claude/settings.json env:"
echo "   OTEL_EXPORTER_OTLP_ENDPOINT = ${URL}"
echo " (or run ./print-settings.sh to emit the full block)"
echo "============================================================"
