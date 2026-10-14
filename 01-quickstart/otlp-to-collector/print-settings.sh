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
# Emit the ~/.claude/settings.json needed to send Claude Code telemetry to this
# collector.
#
# Usage:
#   ./print-settings.sh [email] [--merge]
#
#   (no flag)  Print the complete, correctly-shaped settings.json to stdout.
#              IMPORTANT: `otelHeadersHelper` is a TOP-LEVEL key, a sibling of
#              "env" — NOT one of the env vars inside it.
#   --merge    Merge the keys into ~/.claude/settings.json in place (requires jq;
#              backs the file up first). Foolproof — puts each key where it goes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL_FILE="${SCRIPT_DIR}/.collector-url"
HELPER="${SCRIPT_DIR}/otel-headers-helper.sh"
SETTINGS="${HOME}/.claude/settings.json"

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

if [[ ! -s "${URL_FILE}" ]]; then
  echo "print-settings: ${URL_FILE} not found; ask your admin for the endpoint," >&2
  echo "  or run ./deploy.sh if you are the admin." >&2
  exit 1
fi
ENDPOINT="$(cat "${URL_FILE}")"

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
  # OTEL_METRIC_EXPORT_INTERVAL must stay well above ~15s. Cloud Monitoring
  # enforces a minimum spacing between two points on the SAME time series and
  # rejects anything closer; the SDK surfaces that only as "Bad Request", so the
  # data is dropped silently. Because these metrics are DELTA, a rejected write
  # loses its value permanently — a cumulative counter would self-heal on the
  # next point, a delta cannot. 10000 sat exactly on the floor and under-reported
  # spend by 15-21% under load. 60000 is the OpenTelemetry default.
  jq \
    --arg ep "${ENDPOINT}" --arg email "user.email=${EMAIL}" --arg helper "${HELPER}" '
    .env = ((.env // {}) + {
      "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
      "OTEL_LOGS_EXPORTER": "otlp",
      "OTEL_METRICS_EXPORTER": "otlp",
      "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
      "OTEL_EXPORTER_OTLP_ENDPOINT": $ep,
      "OTEL_METRIC_EXPORT_INTERVAL": "60000",
      "OTEL_LOGS_EXPORT_INTERVAL": "5000",
      "OTEL_RESOURCE_ATTRIBUTES": $email
    })
    | .otelHeadersHelper = $helper
  ' "${SETTINGS}" > "${TMP}"
  mv "${TMP}" "${SETTINGS}"
  echo "==> Updated ${SETTINGS}"
  echo "    Backup: ${BACKUP}"
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
# Do not lower OTEL_METRIC_EXPORT_INTERVAL below 15000. Cloud Monitoring rejects
# a point that lands too soon after the previous one on the same series, the SDK
# reports it only as "Bad Request", and because these metrics are DELTA the
# dropped value is gone for good. Cost then reads low, and worse the busier you
# are. OTEL_LOGS_EXPORT_INTERVAL has no such floor and is fine where it is.

{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "${ENDPOINT}",
    "OTEL_METRIC_EXPORT_INTERVAL": "60000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_RESOURCE_ATTRIBUTES": "user.email=${EMAIL}"
  },
  "otelHeadersHelper": "${HELPER}"
}
EOF
