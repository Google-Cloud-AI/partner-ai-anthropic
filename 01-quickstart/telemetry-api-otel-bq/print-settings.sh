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
# Emit the ~/.claude/settings.json needed to send Claude Code LOG telemetry
# straight to telemetry.googleapis.com. Logs only — no metrics exporter.
#
# Usage:
#   ./print-settings.sh [email] [--merge]
#
#   (no flag)  Print the complete, correctly-shaped settings.json to stdout.
#              IMPORTANT: `otelHeadersHelper` is a TOP-LEVEL key, a sibling of
#              "env" — NOT one of the env vars inside it.
#   --merge    Merge the keys into ~/.claude/settings.json in place (requires jq;
#              backs the file up first). Foolproof — puts each key where it goes.
#
# LOGS ONLY: OTEL_METRICS_EXPORTER is set to "none" — this path exports log
# records and nothing else. See README.md.
#
# Values are resolved at generation time because OTEL_RESOURCE_ATTRIBUTES is a
# static string with no interpolation — "$(hostname)" inside it stays literal.
# Re-run this script if the machine or region changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
HELPER="${SCRIPT_DIR}/otel-headers-helper.sh"
SETTINGS="${HOME}/.claude/settings.json"
ENDPOINT="https://telemetry.googleapis.com"

if [[ ! -f "${CONFIG_ENV}" ]]; then
  echo "print-settings: ${CONFIG_ENV} not found; run ./setup.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG_ENV}"

if [[ -z "${PROJECT:-}" ]]; then
  echo "print-settings: PROJECT is not set in config.env." >&2
  exit 1
fi

# Parse args: an email (anything not starting with --) and/or --merge.
EMAIL="you@example.com"
MERGE=0
for arg in "$@"; do
  case "${arg}" in
    --merge) MERGE=1 ;;
    --*)     echo "print-settings: unknown flag ${arg}" >&2; exit 1 ;;
    *)       EMAIL="${arg}" ;;
  esac
done

# ---- Resolve `location` -----------------------------------------------------
# Prefer the real zone from the metadata server (zones such as us-central1-a are
# accepted). Off GCP there is no honest answer, so fall back to the configured
# region: syntactically valid, geographically meaningless. "global" is rejected
# by the endpoint, so it is never a valid fallback.
LOCATION="$(curl -f -s -m 2 -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/zone" \
  2>/dev/null | awk -F/ '{print $NF}' || true)"
if [[ -z "${LOCATION}" ]]; then
  LOCATION="${FALLBACK_LOCATION:-us-central1}"
fi

# ---- Resolve `service.instance.id` ------------------------------------------
# Deliberately the hostname, NOT the metadata instance ID. Workstation VMs are
# recreated on restart, so the instance ID churns; the hostname is stable per
# machine and still unique per developer. It also becomes resource.labels.task_id
# on the log entry, which is the `host` column in every query in sql/.
INSTANCE="$(hostname)"

RESOURCE_ATTRS="gcp.project_id=${PROJECT},location=${LOCATION},service.instance.id=${INSTANCE},user.email=${EMAIL}"

# ---- --merge: edit ~/.claude/settings.json in place -------------------------
if [[ "${MERGE}" -eq 1 ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "print-settings: --merge requires jq (not found). Install jq, or run" >&2
    echo "  without --merge and paste the printed JSON yourself." >&2
    exit 1
  fi
  mkdir -p "$(dirname "${SETTINGS}")"
  [[ -s "${SETTINGS}" ]] || echo '{}' > "${SETTINGS}"
  BACKUP="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "${SETTINGS}" "${BACKUP}"
  TMP="$(mktemp)"
  # Gotchas, each one already paid for:
  #  - OTEL_METRICS_EXPORTER is "none" rather than omitted, so merging over an
  #    existing metrics-enabled settings.json actually turns metrics off.
  #  - The OTEL_METRICS_INCLUDE_* keys govern LOG RECORDS too, despite the prefix.
  #    ..._RESOURCE_ATTRIBUTES is a BOOLEAN (default true); naming an attribute
  #    reads as not-true and silently drops user.email from every entry.
  #    ..._VERSION defaults to FALSE. Neither is retroactive.
  #  - OTEL_LOG_USER_PROMPTS is left unset (off): prompt text never leaves the
  #    machine, user_prompt entries carry a length only.
  jq \
    --arg ep "${ENDPOINT}" --arg attrs "${RESOURCE_ATTRS}" --arg helper "${HELPER}" '
    .env = ((.env // {}) + {
      "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
      "OTEL_LOGS_EXPORTER": "otlp",
      "OTEL_METRICS_EXPORTER": "none",
      "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
      "OTEL_EXPORTER_OTLP_ENDPOINT": $ep,
      "OTEL_LOGS_EXPORT_INTERVAL": "5000",
      "OTEL_RESOURCE_ATTRIBUTES": $attrs,
      "OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES": "true",
      "OTEL_METRICS_INCLUDE_VERSION": "true"
    })
    | del(.env.OTEL_METRIC_EXPORT_INTERVAL)
    | .otelHeadersHelper = $helper
  ' "${SETTINGS}" > "${TMP}"
  mv "${TMP}" "${SETTINGS}"
  echo "==> Updated ${SETTINGS}"
  echo "    Backup:   ${BACKUP}"
  echo "    location: ${LOCATION}"
  echo "    instance: ${INSTANCE}"
  echo "    metrics:  off (OTEL_METRICS_EXPORTER=none; export interval removed)"
  echo "    (otelHeadersHelper set at top level; OTEL_* keys merged into .env)"
  echo "    Restart Claude Code to apply."
  exit 0
fi

# ---- default: print the complete, correctly-shaped settings.json ------------
cat <<EOF
# Complete ~/.claude/settings.json shape. Note the structure:
#   - the OTEL_* keys go INSIDE "env"
#   - "otelHeadersHelper" is a TOP-LEVEL key, a SIBLING of "env" (not inside it)
# If you already have a settings.json, merge these in (or re-run with --merge to
# do it automatically). Then restart Claude Code.
#
# Do not change OTEL_EXPORTER_OTLP_PROTOCOL to grpc: dynamic header refresh only
# works over http/protobuf and http/json, and without it exports fail after an
# hour when the access token expires.
#
# OTEL_METRICS_EXPORTER stays "none" and OTEL_METRIC_EXPORT_INTERVAL is omitted:
# this path consumes log records only, and the queries in sql/ read nothing else.

{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_METRICS_EXPORTER": "none",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "${ENDPOINT}",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_RESOURCE_ATTRIBUTES": "${RESOURCE_ATTRS}",
    "OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES": "true",
    "OTEL_METRICS_INCLUDE_VERSION": "true"
  },
  "otelHeadersHelper": "${HELPER}"
}
EOF
