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
# Emit the ~/.claude/settings.json needed to send Claude Code telemetry straight
# to telemetry.googleapis.com — both logs and metrics.
#
# Usage:
#   ./print-settings.sh [email] [--merge]
#
#   (no args)  Derive your identity from your gcloud credential and print the
#              complete, correctly-shaped settings.json to stdout.
#              IMPORTANT: `otelHeadersHelper` is a TOP-LEVEL key, a sibling of
#              "env" — NOT one of the env vars inside it.
#   [email]    Override the derived identity. Warns, because the value is then
#              asserted rather than verified.
#   --merge    Merge the keys into ~/.claude/settings.json in place (requires jq;
#              backs the file up first). Foolproof — puts each key where it goes.
#
# TWO SIGNALS, TWO BACKENDS. telemetry.googleapis.com fans out by signal type:
# log records reach Cloud Logging (and from there the sink and BigQuery), metrics
# reach Cloud Monitoring. One endpoint, one credential, two destinations. The
# metrics are what hydrate the Cloud Monitoring dashboard; BigQuery is the more
# complete record of cost (both are estimates — the bill is authoritative).
# See README.md.
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

# Parse args: an optional email override (anything not starting with --) and
# --merge.
EMAIL_ARG=""
MERGE=0
for arg in "$@"; do
  case "${arg}" in
    --merge) MERGE=1 ;;
    --*)     echo "print-settings: unknown flag ${arg}" >&2; exit 1 ;;
    *)       EMAIL_ARG="${arg}" ;;
  esac
done

# ---- Resolve user.email: verified, not asserted -----------------------------
# user.email is what every per-developer query groups by, and nothing
# downstream can check it. The exporter sends whatever string sits in
# OTEL_RESOURCE_ATTRIBUTES, and the credential that authenticates the export is
# a separate thing entirely (see otel-headers-helper.sh). A typo quietly
# misattributes one developer's spend; an edit attributes it to someone else.
# Log entries cannot be rewritten afterwards, so neither is recoverable.
#
# So ask Google who you are instead of letting you type it. tokeninfo reports
# the principal an access token was issued to, which for a `gcloud auth login`
# credential is the developer's verified address.
#
# Deliberately the gcloud credential and NOT the metadata server, even on GCE
# where the HELPER prefers metadata. A metadata token belongs to the VM's
# service account, so deriving identity from it would stamp every developer on
# a shared Workstation image with the same address. The runtime credential and
# the identity label answer different questions, so they come from different
# places on purpose.
verified_email() {
  command -v gcloud >/dev/null 2>&1 || return 1
  local tok
  tok="$(gcloud auth print-access-token 2>/dev/null)" || return 1
  [[ -n "${tok}" ]] || return 1
  # -f makes a non-200 (expired or malformed token) a non-zero exit rather than
  # a body we would go on to misparse.
  curl -f -s -m 5 \
    --data-urlencode "access_token=${tok}" \
    --get "https://oauth2.googleapis.com/tokeninfo" 2>/dev/null \
    | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

VERIFIED="$(verified_email || true)"
# A service-account principal is not a developer. This shows up when gcloud is
# configured with an activated or impersonated SA, and it is the same collapse
# the metadata server would cause, so treat it as unknown and make the caller
# be explicit.
case "${VERIFIED}" in
  *gserviceaccount.com) VERIFIED="" ;;
esac

if [[ -n "${EMAIL_ARG}" ]]; then
  EMAIL="${EMAIL_ARG}"
  if [[ -n "${VERIFIED}" && "${EMAIL_ARG}" != "${VERIFIED}" ]]; then
    echo "print-settings: WARNING - you passed '${EMAIL_ARG}' but your gcloud" >&2
    echo "  credential is '${VERIFIED}'. Using '${EMAIL_ARG}' as asked; it is an" >&2
    echo "  assertion, not a verified identity." >&2
  elif [[ -z "${VERIFIED}" ]]; then
    echo "print-settings: WARNING - could not verify '${EMAIL_ARG}' (no usable" >&2
    echo "  gcloud credential). Recording it unverified." >&2
  fi
elif [[ -n "${VERIFIED}" ]]; then
  EMAIL="${VERIFIED}"
  echo "print-settings: identity verified as ${EMAIL}" >&2
else
  echo "print-settings: cannot determine who you are." >&2
  echo "  Run 'gcloud auth login' so your address can be verified, or pass one" >&2
  echo "  explicitly: ./print-settings.sh you@yourco.com" >&2
  echo "  Refusing to guess - a wrong or placeholder user.email silently" >&2
  echo "  misreports someone's spend and cannot be corrected afterwards." >&2
  exit 1
fi

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
  #  - OTEL_METRIC_EXPORT_INTERVAL must stay well above ~15s. Cloud Monitoring
  #    enforces a minimum spacing between two points on the SAME time series and
  #    rejects anything closer; the SDK surfaces that only as "Bad Request", so
  #    the data is dropped silently. Because these metrics are DELTA, a rejected
  #    write loses its value permanently — a cumulative counter would self-heal
  #    on the next point, a delta cannot. 10000 sits exactly on the floor:
  #    measured 2026-09-30 over three days, metric spend read 15.5% under the
  #    logs ($15.5625 vs $18.4073), worst on the busiest day. The loss scales
  #    with request density, so it looks fine when idle and worst under load.
  #    60000 is the OpenTelemetry default and leaves 6x headroom.
  #  - OTEL_LOGS_EXPORT_INTERVAL is deliberately left low. The floor is a
  #    per-series constraint and log entries are not a time series, so nothing is
  #    gained by slowing logs down.
  #  - CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS must stay UNDER 5 minutes.
  #    Neither credential source mints a fresh token per call — both cache and
  #    only replace within ~5 minutes of expiry — so the helper can be handed a
  #    token with five minutes of life left. At the ~29-minute default that
  #    token dies ~24 minutes before its replacement and every export in the gap
  #    is rejected. See otel-headers-helper.sh.
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
      "OTEL_METRICS_EXPORTER": "otlp",
      "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
      "OTEL_EXPORTER_OTLP_ENDPOINT": $ep,
      "OTEL_METRIC_EXPORT_INTERVAL": "60000",
      "OTEL_LOGS_EXPORT_INTERVAL": "5000",
      "CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS": "180000",
      "OTEL_RESOURCE_ATTRIBUTES": $attrs,
      "OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES": "true",
      "OTEL_METRICS_INCLUDE_VERSION": "true"
    })
    | .otelHeadersHelper = $helper
  ' "${SETTINGS}" > "${TMP}"
  mv "${TMP}" "${SETTINGS}"
  echo "==> Updated ${SETTINGS}"
  echo "    Backup:   ${BACKUP}"
  echo "    location: ${LOCATION}"
  echo "    instance: ${INSTANCE}"
  echo "    metrics:  on (export interval 60000ms -> Cloud Monitoring)"
  echo "    (otelHeadersHelper set at top level; OTEL_* keys merged into .env)"
  echo "    Restart Claude Code to apply."
  exit 0
fi

# ---- default: print the complete, correctly-shaped settings.json ------------
# The commentary goes to STDERR and only the JSON to STDOUT, so that
#   ./print-settings.sh > ~/.claude/settings.json
# writes a file that actually parses. You still see the notes on a terminal.
cat >&2 <<'NOTES'
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
# Do not lower OTEL_METRIC_EXPORT_INTERVAL below 15000. Cloud Monitoring rejects
# a point that lands too soon after the previous one on the same series, the SDK
# reports it only as "Bad Request", and because these metrics are DELTA the
# dropped value is gone for good. Cost then reads low, and worse the busier you
# are. OTEL_LOGS_EXPORT_INTERVAL has no such floor and is fine where it is.
#
# Do not raise CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS to 5 minutes or more.
# Both credential sources hand back a CACHED access token and only replace it
# within ~5 minutes of expiry, so the helper must re-run inside that window or
# the token in use can expire mid-flight. See otel-headers-helper.sh.
NOTES
cat <<EOF
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "${ENDPOINT}",
    "OTEL_METRIC_EXPORT_INTERVAL": "60000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS": "180000",
    "OTEL_RESOURCE_ATTRIBUTES": "${RESOURCE_ATTRS}",
    "OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES": "true",
    "OTEL_METRICS_INCLUDE_VERSION": "true"
  },
  "otelHeadersHelper": "${HELPER}"
}
EOF
