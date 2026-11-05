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
# Claude Code `otelHeadersHelper`: prints the headers (as JSON) used to
# authenticate OTLP exports directly to telemetry.googleapis.com.
#
# Claude Code runs this at startup and then every
# CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS (default ~29 minutes; this folder
# sets 3 minutes — see below). It must print a single JSON object on stdout.
#
# Usage: otel-headers-helper.sh QUOTA_PROJECT
# managed-settings.json passes the project, so this script needs no config file
# on the developer's machine.
#
# WHY THIS SCRIPT EXISTS
#   Google access tokens expire after 60 minutes, and an exporter handed a
#   static token just starts failing when the hour is up. Re-running a helper is
#   what avoids needing a sidecar, daemon or Cloud Run service purely to refresh
#   a credential.
#
#   WHAT MATTERS IS THE TOKEN'S REMAINING LIFETIME, NOT ITS AGE. Neither source
#   below mints a fresh token per call: the metadata server and
#   `gcloud auth print-access-token` both return a CACHED token, replacing it
#   only once it is within ~5 minutes of expiry. Measured here, three successive
#   calls returned expires_in of 2675, 2660 and 2619 seconds — one token,
#   ageing. A call can therefore hand back a token with five minutes of life
#   left, and "we re-run every 29 minutes" does not bound the age of the token
#   actually in use.
#
#   That is why managed-settings.json sets the debounce to 180000 (3 minutes).
#   Because any token handed out has at least ~5 minutes left, re-running inside
#   that window means the token in use never expires. At the 29-minute default a
#   worst-case token dies ~24 minutes before its replacement arrives and every
#   export in the gap is rejected — intermittent, phase-dependent, and invisible
#   unless you go looking.
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
#   2. gcloud           — on a laptop, the developer's own credentials: those of
#      `gcloud auth login`, or else of `gcloud auth application-default login`,
#      which Claude Code on Vertex AI already needs.
#
# WHO IS ACTUALLY AUTHENTICATED, which is easy to get wrong:
#   Metadata wins whenever it answers, so on GCE and Cloud Workstations the
#   export is authenticated by the MACHINE's service account — even if the
#   developer is signed in with gcloud on that same box. Only off GCP does the
#   developer's own credential get used. Both principals therefore need
#   roles/telemetry.writer: config.env has DEVELOPERS for the humans and
#   MACHINE_MEMBERS for the VM/Workstation service accounts, and
#   enable-and-grant.sh grants both.
#
#   Metadata is tried first deliberately. It is a local call on a link-local
#   address, whereas gcloud is a subprocess that costs the better part of a
#   second — and with the 3-minute debounce above this script runs around twenty
#   times an hour.
#
#   None of this affects attribution. user.email is resolved separately by
#   policy-helper.sh and is not derived from whoever holds this token; the two
#   are independent by design. Do not read a row's user_email as evidence of
#   which credential sent it.

set -euo pipefail

# Claude Code started from an IDE or the desktop app may have a shorter PATH than
# a terminal, so add the usual install locations for gcloud.
PATH="${PATH}:/usr/local/bin:/opt/homebrew/bin:${HOME:-}/google-cloud-sdk/bin"

QUOTA="${1:-}"
if [[ -z "${QUOTA}" ]]; then
  echo "otel-headers-helper: no quota project was given, so telemetry is not being sent." >&2
  echo "  Add the project after the script path in the otelHeadersHelper setting." >&2
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
  echo "otel-headers-helper: gcloud is not installed, so telemetry is not being sent." >&2
  echo "  Install the Google Cloud SDK, then run 'gcloud auth login'." >&2
  exit 1
fi

TOKEN="$(gcloud auth print-access-token 2>/dev/null \
  || gcloud auth application-default print-access-token 2>/dev/null || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "otel-headers-helper: no current Google sign-in found, so telemetry is not being sent." >&2
  echo "  Run 'gcloud auth login' or 'gcloud auth application-default login'." >&2
  exit 1
fi
emit "${TOKEN}"
