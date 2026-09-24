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
# Claude Code `otelHeadersHelper`: prints the headers (as JSON) used to
# authenticate OTLP exports directly to telemetry.googleapis.com.
#
# Claude Code runs this at startup and roughly every 29 minutes thereafter
# (tunable with CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS). It must print a
# single JSON object on stdout.
#
# WHY THIS SCRIPT EXISTS
#   Google access tokens expire after 60 minutes. Because Claude Code re-runs
#   this helper every ~29 minutes, the token in use is never more than ~29
#   minutes old, so the expiry is never reached. That is what makes the
#   collectorless design viable — no sidecar, daemon or Cloud Run service is
#   needed just to refresh a credential.
#
#   This only holds over http/protobuf or http/json. Under the grpc protocol
#   Claude Code ignores this helper and uses the static OTEL_EXPORTER_OTLP_HEADERS
#   variables only — the token then never refreshes and every export starts
#   failing at the one-hour mark. Do not change OTEL_EXPORTER_OTLP_PROTOCOL to
#   grpc. (Google's own Telemetry API docs recommend grpc for direct SDK export,
#   because most SDK exporters cannot refresh tokens. Claude Code is the
#   exception, so that advice is inverted here.)
#
# Two headers are emitted:
#   Authorization       — a short-lived OAuth access token
#   x-goog-user-project — the quota project
#
# Google's migration guide discourages setting x-goog-user-project through the
# OTEL_EXPORTER_OTLP_HEADERS environment variable. We set it here in the helper
# instead, which was verified working against telemetry.googleapis.com.
#
# Two ways to mint the token, tried in order:
#   1. Metadata server  — on GCP compute (Cloud Workstations, GCE VMs) the
#      attached SA mints the token, no key files. Not available off-GCP.
#   2. gcloud           — on a laptop, `gcloud auth print-access-token` uses the
#      developer's own credentials. Requires `gcloud auth login`.
#
# Unlike the collector path, no service-account impersonation is involved: the
# developer's own identity needs roles/telemetry.writer on the destination
# project, so there is no invoker SA to stand in for them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_ENV}" ]]; then
  echo "otel-headers-helper: ${CONFIG_ENV} not found (needed for the quota project)." >&2
  echo "  Run ./setup.sh, or copy config.env.example to config.env." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG_ENV}"

QUOTA="${QUOTA_PROJECT:-${PROJECT:-}}"
if [[ -z "${QUOTA}" ]]; then
  echo "otel-headers-helper: neither QUOTA_PROJECT nor PROJECT is set in config.env." >&2
  exit 1
fi

emit() {
  printf '{"Authorization": "Bearer %s", "x-goog-user-project": "%s"}\n' "$1" "${QUOTA}"
}

# ---- 1. Metadata server (GCP compute) ---------------------------------------
# Fail fast (-f, short -m) so laptops fall through quickly to the gcloud path.
TOKEN="$(curl -f -s -m 2 -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  2>/dev/null | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
if [[ -n "${TOKEN}" ]]; then
  emit "${TOKEN}"
  exit 0
fi

# ---- 2. gcloud (laptop) -----------------------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
  echo "otel-headers-helper: no metadata server and gcloud is not installed." >&2
  echo "  Install the Google Cloud SDK, then run 'gcloud auth login'." >&2
  exit 1
fi

TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "otel-headers-helper: failed to mint an access token via gcloud." >&2
  echo "  Check that 'gcloud auth login' has been run, and that you hold" >&2
  echo "  roles/telemetry.writer on ${PROJECT:-the destination project} and" >&2
  echo "  roles/serviceusage.serviceUsageConsumer on ${QUOTA}." >&2
  exit 1
fi
emit "${TOKEN}"
