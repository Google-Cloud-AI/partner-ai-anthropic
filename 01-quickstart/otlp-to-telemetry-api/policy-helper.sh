#!/bin/bash -p
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
# Claude Code `policyHelper`: fills in the two values in managed-settings.json
# that differ from one machine or developer to the next.
#
# OTEL_RESOURCE_ATTRIBUTES is a static string, and Claude Code does not expand
# it, so "$(hostname)" inside it stays literal. Claude Code runs this script as
# the developer, at every start, and uses its output as the managed settings for
# that session. It prints managed-settings.json with
# "service.instance.id=unknown" replaced by this machine's hostname and the
# developer's verified user.email. Everything else stays in that one file.
#
# `--try` prints the same settings for `claude --settings`, to try them without
# installing anything. It reads managed-settings.json from this script's folder,
# leaves out the {"managedSettings": ...} envelope, and points otelHeadersHelper
# at the copy in this folder if it still uses the install path from
# managed-settings.example.json.
#
# NEVER EXIT NON-ZERO when Claude Code runs this. Only --try, which a person
# runs by hand, may fail, when this folder has no managed-settings.json. A
# helper that fails, times out, prints invalid JSON or emits a setting that
# fails validation stops Claude Code from starting, so nothing here is worth
# failing for. If the email cannot be verified, rows go out without it. That is
# why this script does not use `set -e`.
#
# What this prints replaces every managed setting, so `bash -p` on line 1, which
# ignores BASH_ENV and exported functions, and the fixed PATH below keep a stray
# tool in the developer's environment from changing it. This reduces accidents;
# it does not stop a developer who sets out to change it.

set -u

# Only gcloud uses the developer's PATH. Claude Code started from an IDE or the
# desktop app may have a shorter one, so add the usual install locations.
GCLOUD_PATH="${PATH}:/usr/local/bin:/opt/homebrew/bin:${HOME:-}/google-cloud-sdk/bin"
PATH="/usr/bin:/bin"

# ---- Find managed-settings.json ---------------------------------------------
# HERE is this script's folder under --try and empty otherwise. It is cleared
# first so that a HERE exported in the environment cannot change a normal run.
HERE=""
if [[ "${1:-}" == "--try" ]]; then
  HERE="$(cd "$(dirname "$0")" >/dev/null && pwd)"
  if [[ ! -r "${HERE}/managed-settings.json" ]]; then
    echo "policy-helper: ${HERE}/managed-settings.json not found. Run ./setup.sh first." >&2
    exit 1
  fi
fi
for MANAGED in \
  "${HERE:+${HERE}/managed-settings.json}" \
  "/Library/Application Support/ClaudeCode/managed-settings.json" \
  "/etc/claude-code/managed-settings.json"; do
  [[ -r "${MANAGED}" ]] && break
done
if [[ ! -r "${MANAGED}" ]]; then
  # No file to re-emit, for example when an MDM policy itself names this script.
  # An envelope with no managedSettings leaves the other managed sources in force.
  echo '{}'
  exit 0
fi

# ---- Resolve service.instance.id --------------------------------------------
# Deliberately the hostname, NOT the metadata instance ID. Workstation VMs are
# recreated on restart, so the instance ID churns; the hostname is stable per
# machine and still unique per developer. It also becomes resource.labels.task_id
# on the log entry, which is the `host` column in sql/.
#
# One character the attribute format rejects discards the whole variable, with
# no error, so anything unexpected is removed here.
INSTANCE="$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-')"

# ---- Resolve user.email: verified, not asserted -----------------------------
# user.email is what every per-developer query groups by, and nothing downstream
# can check it. The exporter sends whatever string sits in
# OTEL_RESOURCE_ATTRIBUTES, and log entries cannot be rewritten afterwards. So
# ask Google who the developer is: tokeninfo reports the principal an access
# token was issued to.
#
# Deliberately a developer's credential and NOT the metadata server, even on GCE
# where otel-headers-helper.sh prefers metadata. A metadata token belongs to the
# VM's service account, so deriving identity from it would stamp every developer
# on a shared Workstation image with the same address.
#
# A service-account principal is not a developer, so it is skipped. On GCE, gcloud
# falls back to the VM's service account when nobody has run `gcloud auth login`,
# and an activated or impersonated service account looks the same.
email_from() {
  local tok email
  tok="$(PATH="${GCLOUD_PATH}"; gcloud "$@" 2>/dev/null)" || return
  # -f makes a non-200 (expired or malformed token) a non-zero exit rather than a
  # body we would go on to misparse. The token goes in on stdin so that it never
  # appears in a process listing.
  email="$(printf '%s' "${tok}" | curl -f -s -m 3 \
    --data-urlencode "access_token@-" \
    --get "https://oauth2.googleapis.com/tokeninfo" 2>/dev/null \
    | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  case "${email}" in
    "" | *gserviceaccount.com) return 1 ;;
  esac
  echo "${email}"
}

verified_email() {
  email_from auth print-access-token \
    || email_from auth application-default print-access-token
}

# gcloud can hang when the network is down, and Claude Code allows this script
# 10 seconds in total, so give up after 5. A slow gcloud then costs that session
# its user.email, which is better than stopping Claude Code from starting.
#
# No `trap ... EXIT` for the temp file: a background subshell inherits it, and
# macOS's bash 3.2 then holds the watchdog's kill until gcloud returns, which is
# the hang this is meant to cut short. The file is removed below instead.
EMAIL_FILE="$(mktemp)"
verified_email >"${EMAIL_FILE}" 2>/dev/null &
LOOKUP=$!
(sleep 5; kill "${LOOKUP}") >/dev/null 2>&1 &
WATCHDOG=$!
wait "${LOOKUP}" 2>/dev/null
# Reaped inside the redirect, or bash 3.2 prints "Terminated: 15 ( sleep 5; ...)"
# on stderr, which reads like a failure when a person runs --try.
{ kill "${WATCHDOG}"; wait "${WATCHDOG}"; } 2>/dev/null
EMAIL="$(cat "${EMAIL_FILE}")"
rm -f "${EMAIL_FILE}"

# Anything that is not a plain address is dropped for the same reason as the
# hostname above. When Claude Code runs this script, it shows this message in
# its debug log.
if [[ ! "${EMAIL}" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+$ ]]; then
  EMAIL=""
  echo "policy-helper: could not confirm your Google sign-in, so this session's telemetry will not include your email address. Run 'gcloud auth login'." >&2
fi

# ---- Print the managed settings ---------------------------------------------
ATTRS="service.instance.id=${INSTANCE:-unknown}${EMAIL:+,user.email=${EMAIL}}"
SETTINGS="$(sed "s/service\.instance\.id=unknown/${ATTRS}/" "${MANAGED}")"
if [[ -n "${HERE}" ]]; then
  # The path is quoted because Claude Code runs the setting as a shell command.
  # A folder path containing ' " or \ is not supported.
  ESCAPED="$(printf '%s' "${HERE}" | sed 's/[&|\\]/\\&/g')"
  printf '%s\n' "${SETTINGS}" | sed "s|/usr/local/libexec/claude-code-telemetry/otel-headers-helper.sh|'${ESCAPED}/otel-headers-helper.sh'|"
  exit 0
fi
printf '{"managedSettings": %s}\n' "${SETTINGS}"
