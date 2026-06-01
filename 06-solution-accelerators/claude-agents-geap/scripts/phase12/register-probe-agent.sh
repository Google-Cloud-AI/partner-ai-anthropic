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

# Phase 12 — register the A2UI v0.8 PROBE agent on the PTA Co-Innovation
# Team engine. NEVER touches the production "Claude Code" registration.
#
# This is a deliberately short-lived registration. Operational rule
# (set in scripts/phase12/probe-plan.md §6): the probe agent's lifetime
# is ONE focused session, target ≤15 minutes, then unregister via
# scripts/phase12/unregister-probe-agent.sh --apply IMMEDIATELY. The
# probe is ENABLED + gallery-visible to all PTA users while live.
#
# Default mode is DRY RUN: renders the payload to
# scripts/phase12/probe-agent-payload.json and prints what would be
# sent. Pass --apply to actually POST/PATCH the registration.
#
# Idempotent (LIST → PATCH if displayName matches, else POST) — re-runs
# don't create duplicate probe agents.
set -euo pipefail

PROJECT_ID="cpe-slarbi-nvd-ant-demos"
PROJECT_NUMBER="436293010210"
ENGINE_ID="pta-co-innovation-team_1774556044286"
LOCATION="global"
COLLECTION="default_collection"
ASSISTANT="default_assistant"
BUILDER_SA="cc-a2a-builder@${PROJECT_ID}.iam.gserviceaccount.com"
BRIDGE_URL="https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app"
AGENT_DISPLAY_NAME="Claude Code A2UI v0.8 PROBE"
PAYLOAD_FILE="$(dirname "${BASH_SOURCE[0]}")/probe-agent-payload.json"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

API_BASE="https://discoveryengine.googleapis.com/v1alpha"
PARENT="projects/${PROJECT_NUMBER}/locations/${LOCATION}/collections/${COLLECTION}/engines/${ENGINE_ID}/assistants/${ASSISTANT}"
AGENTS_URL="${API_BASE}/${PARENT}/agents"

mint_token() {
  gcloud auth print-access-token --impersonate-service-account="$BUILDER_SA" 2>/dev/null
}

curl_api() {
  local method="$1"; local url="$2"; local data="${3:-}"
  local token; token=$(mint_token)
  if [[ -n "$data" ]]; then
    curl -sS -w "\n__HTTP_CODE__:%{http_code}__" -X "$method" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "@${data}" "$url"
  else
    curl -sS -w "\n__HTTP_CODE__:%{http_code}__" -X "$method" \
      -H "Authorization: Bearer $token" "$url"
  fi
}

echo "===== Phase 12 PROBE agent registration ====="
echo "  Operational rule: probe lifetime ≤ 15 min. Unregister IMMEDIATELY"
echo "  after the screenshot via scripts/phase12/unregister-probe-agent.sh"
echo "  --apply. Do NOT leave registered while away from keyboard."
echo ""

# ----- Build the probe AgentCard programmatically (not fetched from -----
# the bridge — the bridge's /.well-known/agent-card.json serves the
# production card, which deliberately does NOT advertise A2UI).

echo "===== building probe AgentCard (NOT fetched from bridge) ====="
python3 - <<'PY' > "$PAYLOAD_FILE"
import json
# Phase 12 probe AgentCard. Identical to the production card EXCEPT:
#   - displayName / description / name reflect the probe purpose
#   - capabilities.extensions declares A2UI v0.8
#   - starterPrompts is a single A2UI-PROBE trigger
# protocolVersion stays at "0.2" (matches production; a2a-sdk 0.2.13
# accepts extensions on AgentCapabilities; bump only on registration
# rejection).
probe_card = {
    "protocolVersion": "0.2",
    "name": "Claude Code A2UI v0.8 PROBE",
    "description": (
        "Phase 12 A2UI v0.8 verification probe. Send the literal "
        "trigger phrase 'A2UI-PROBE' to render a hardcoded surface. "
        "Delete immediately after testing — temporary by design."
    ),
    "url": "https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app",
    "version": "0.1.0-probe",
    "capabilities": {
        "streaming": True,
        "pushNotifications": False,
        "stateTransitionHistory": False,
        "extensions": [
            {
                "uri": "https://a2ui.org/a2a-extension/a2ui/v0.8",
                "description": "Ability to render A2UI",
                "required": False,
                "params": {
                    "supportedCatalogIds": [
                        "https://a2ui.org/specification/v0_8/"
                        "standard_catalog_definition.json",
                    ],
                },
            },
        ],
    },
    "defaultInputModes": ["text/plain", "application/octet-stream"],
    "defaultOutputModes": [
        "text/plain", "text/html", "application/octet-stream",
    ],
    "skills": [
        {
            "id": "a2ui-probe",
            "name": "A2UI v0.8 probe",
            "description": (
                "Renders a single hardcoded A2UI surface for verification. "
                "Not a real skill — temporary verification artifact."
            ),
            "tags": ["a2ui", "probe", "temporary"],
            "examples": ["A2UI-PROBE"],
        },
    ],
}

body = {
    "displayName": "Claude Code A2UI v0.8 PROBE",
    "description": (
        "Phase 12 A2UI v0.8 probe. Send 'A2UI-PROBE' to render a "
        "hardcoded surface. Delete immediately after testing."
    ),
    "a2aAgentDefinition": {
        "jsonAgentCard": json.dumps(probe_card),
    },
    "starterPrompts": [
        {"text": "A2UI-PROBE"},
    ],
    "customPlaceholderText": "Send A2UI-PROBE to render the probe surface.",
    "languageCode": "en",
}
print(json.dumps(body, indent=2))
PY

echo "  wrote: $PAYLOAD_FILE"
echo ""
echo "===== PROBE REGISTRATION PAYLOAD (body sent to POST/PATCH) ====="
cat "$PAYLOAD_FILE"
echo ""
echo "===== Target URL ====="
echo "  $AGENTS_URL"
echo ""

if [[ $APPLY -eq 0 ]]; then
  echo "===== DRY RUN ====="
  echo "  This was a dry run. To apply (only after sign-off):"
  echo "    $0 --apply"
  echo ""
  echo "  Reminder: bridge MUST have A2UI_PROBE_ENABLED=true env set"
  echo "  AND be running an image that includes the probe code path."
  exit 0
fi

# ----- --apply mode: idempotent POST or PATCH -----

echo "===== --apply: idempotent register-or-update ====="
list_out=$(curl_api GET "$AGENTS_URL")
list_code=$(echo "$list_out" | grep -oE '__HTTP_CODE__:[0-9]+__' | grep -oE '[0-9]+')
if [[ "$list_code" != "200" ]]; then
  echo "  FAIL agents.list returned $list_code"
  echo "$list_out" | sed 's/__HTTP_CODE__.*//' | head -20
  exit 1
fi
existing_name=$(echo "$list_out" | sed 's/__HTTP_CODE__.*//' \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for a in d.get('agents', []):
    if a.get('displayName') == '${AGENT_DISPLAY_NAME}':
        print(a['name'])
        break
")

if [[ -n "$existing_name" ]]; then
  echo "  found existing PROBE agent: ${existing_name} — PATCHing"
  patch_url="${API_BASE}/${existing_name}?updateMask=displayName,description,a2aAgentDefinition,starterPrompts,customPlaceholderText,languageCode"
  out=$(curl_api PATCH "$patch_url" "$PAYLOAD_FILE")
  ACTION="updated"
else
  echo "  no existing PROBE agent — POSTing"
  out=$(curl_api POST "$AGENTS_URL" "$PAYLOAD_FILE")
  ACTION="created"
fi

code=$(echo "$out" | grep -oE '__HTTP_CODE__:[0-9]+__' | grep -oE '[0-9]+')
body=$(echo "$out" | sed 's/__HTTP_CODE__.*//')
echo ""
echo "  HTTP $code"
echo "$body" | python3 -m json.tool 2>/dev/null | head -50 || echo "$body" | head -50

if [[ "$code" != "200" && "$code" != "201" ]]; then
  echo ""
  echo "===== PROBE REGISTRATION FAILED — verdict FAIL-REGISTRATION per the rubric ====="
  exit 1
fi

agent_name=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
echo ""
echo "===== Phase 12 probe registration: ${ACTION} ====="
echo "  resource name: ${agent_name}"
echo ""
echo "  ⏰ START THE 15-MINUTE TIMER NOW."
echo ""
echo "  Next steps:"
echo "    1. Open PTA Co-Innovation Team in GE"
echo "    2. Select 'Claude Code A2UI v0.8 PROBE' from the Agent Gallery"
echo "    3. Send the literal message: A2UI-PROBE"
echo "    4. Apply the rubric from scripts/phase12/probe-plan.md §6"
echo "    5. Screenshot"
echo "    6. IMMEDIATELY run:"
echo "         scripts/phase12/unregister-probe-agent.sh --apply"
