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
# Claude Code `otelHeadersHelper`: prints the Authorization header (as JSON) used
# to authenticate OTLP exports to the IAM-protected Cloud Run collector.
#
# Claude Code runs this at startup and roughly every 29 minutes. It must print a
# single JSON object on stdout, e.g. {"Authorization": "Bearer <token>"}.
#
# The token is a Google-signed ID token whose audience MUST equal the Cloud Run
# service URL exactly, or Cloud Run rejects it with 401/403.
#
# Two ways to mint it, tried in order:
#   1. Metadata server  — on GCP compute (Cloud Workstations, GCE VMs) the
#      attached SA mints the token, no key files. Not available off-GCP.
#   2. gcloud impersonation — on a laptop, `gcloud auth print-identity-token`
#      impersonates the shared invoker SA (from config.env). Requires the dev to
#      have run `gcloud auth login` and to hold serviceAccountTokenCreator on it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL_FILE="${SCRIPT_DIR}/.collector-url"
CONFIG_ENV="${SCRIPT_DIR}/config.env"

if [[ ! -s "${URL_FILE}" ]]; then
  echo "otel-headers-helper: ${URL_FILE} not found; run deploy.sh first" >&2
  exit 1
fi
AUDIENCE="$(cat "${URL_FILE}")"

emit() { printf '{"Authorization": "Bearer %s"}\n' "$1"; }

# ---- 1. Metadata server (GCP compute) ---------------------------------------
# Fail fast (-f, short -m) so laptops fall through quickly to the gcloud path.
TOKEN="$(curl -f -s -m 2 -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${AUDIENCE}&format=full" \
  2>/dev/null || true)"
if [[ -n "${TOKEN}" ]]; then
  emit "${TOKEN}"
  exit 0
fi

# ---- 2. gcloud impersonation (laptop) ---------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
  echo "otel-headers-helper: no metadata server and gcloud is not installed." >&2
  echo "  Install the Google Cloud SDK, then run 'gcloud auth login'." >&2
  exit 1
fi
if [[ ! -f "${CONFIG_ENV}" ]]; then
  echo "otel-headers-helper: ${CONFIG_ENV} not found (needed for the invoker SA)." >&2
  echo "  Run ./setup.sh, or copy config.env.example to config.env." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG_ENV}"
if [[ -z "${PROJECT:-}" || -z "${INVOKER_SA_NAME:-}" ]]; then
  echo "otel-headers-helper: PROJECT / INVOKER_SA_NAME missing in config.env." >&2
  exit 1
fi
INVOKER_SA="${INVOKER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

TOKEN="$(gcloud auth print-identity-token \
  --impersonate-service-account="${INVOKER_SA}" \
  --audiences="${AUDIENCE}" \
  --include-email 2>/dev/null || true)"

if [[ -z "${TOKEN}" ]]; then
  echo "otel-headers-helper: failed to mint an ID token via gcloud." >&2
  echo "  Check: 'gcloud auth login' done, and you hold" >&2
  echo "  roles/iam.serviceAccountTokenCreator on ${INVOKER_SA}." >&2
  exit 1
fi
emit "${TOKEN}"
