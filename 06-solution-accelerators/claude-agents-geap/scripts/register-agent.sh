#!/usr/bin/env bash
# Phase 7 — register `cc-a2a-bridge` as an A2A agent on the Gemini
# Enterprise PTA Co-Innovation Team engine.
#
# Default mode: DRY RUN. Renders `scripts/register-agent-payload.json`
# and prints what would be sent. Pass `--apply` to actually call
# Discovery Engine. This is the Gate 2 boundary.
#
# Idempotent: on `--apply`, GETs the engine's agent list, matches by
# displayName == "Claude Code", and PATCHes if found, POSTs otherwise.
#
# Auth: SA-impersonation via cc-a2a-builder@... (user accounts are
# org-blocked for Discovery Engine API; verified 2026-05-15). The
# current gcloud user needs roles/iam.serviceAccountTokenCreator on
# the builder SA.
set -euo pipefail

PROJECT_ID="cpe-slarbi-nvd-ant-demos"
PROJECT_NUMBER="436293010210"
ENGINE_ID="pta-co-innovation-team_1774556044286"
LOCATION="global"
COLLECTION="default_collection"
ASSISTANT="default_assistant"
BUILDER_SA="cc-a2a-builder@${PROJECT_ID}.iam.gserviceaccount.com"
BRIDGE_URL="https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app"
AGENT_DISPLAY_NAME="Claude Code"
PAYLOAD_FILE="$(dirname "${BASH_SOURCE[0]}")/register-agent-payload.json"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

API_BASE="https://discoveryengine.googleapis.com/v1alpha"
PARENT="projects/${PROJECT_NUMBER}/locations/${LOCATION}/collections/${COLLECTION}/engines/${ENGINE_ID}/assistants/${ASSISTANT}"
AGENTS_URL="${API_BASE}/${PARENT}/agents"

mint_token() {
  gcloud auth print-access-token --impersonate-service-account="$BUILDER_SA" 2>/dev/null
}

curl_api() {
  # $1=method, $2=url, optional $3=data file path
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

# ----- Pre-flight: Probes A, B, C -----

probe_a() {
  echo "[probe A] GET engine ${ENGINE_ID}"
  local out; out=$(curl_api GET "${API_BASE}/projects/${PROJECT_NUMBER}/locations/${LOCATION}/collections/${COLLECTION}/engines/${ENGINE_ID}")
  local code; code=$(echo "$out" | grep -oE '__HTTP_CODE__:[0-9]+__' | grep -oE '[0-9]+')
  if [[ "$code" != "200" ]]; then
    echo "  FAIL Probe A: engine GET returned $code — broken impersonation or wrong engine ID"
    echo "$out" | sed 's/__HTTP_CODE__.*//' | head -10
    exit 2
  fi
  local engine_name; engine_name=$(echo "$out" | sed 's/__HTTP_CODE__.*//' | python3 -c 'import json,sys; print(json.load(sys.stdin)["displayName"])')
  echo "  PASS engine display name: ${engine_name}"
}

probe_b() {
  echo "[probe B] agent card reachability"
  # (b) unauthenticated → should be 401/403 (Cloud Run guards before us).
  local unauth_code
  unauth_code=$(curl -sS -o /dev/null -w "%{http_code}" "${BRIDGE_URL}/.well-known/agent-card.json" || true)
  if [[ "$unauth_code" != "401" && "$unauth_code" != "403" ]]; then
    echo "  FAIL Probe B(b): unauthed got $unauth_code (expected 401/403) — security posture issue"
    exit 2
  fi
  echo "  PASS unauthed → $unauth_code"
  # (a) authenticated (my user) → 200 with valid agent card.
  local id_token; id_token=$(gcloud auth print-identity-token 2>/dev/null)
  local auth_body; auth_body=$(curl -sS -w "\n__HTTP_CODE__:%{http_code}__" \
    -H "Authorization: Bearer ${id_token}" \
    "${BRIDGE_URL}/.well-known/agent-card.json")
  local auth_code; auth_code=$(echo "$auth_body" | grep -oE '__HTTP_CODE__:[0-9]+__' | grep -oE '[0-9]+')
  if [[ "$auth_code" != "200" ]]; then
    echo "  FAIL Probe B(a): authed got $auth_code"
    echo "$auth_body" | head -10
    exit 2
  fi
  local card_url; card_url=$(echo "$auth_body" | sed 's/__HTTP_CODE__.*//' | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
  if [[ "$card_url" == *"example.invalid"* ]]; then
    echo "  FAIL Probe B: agent card URL is the placeholder ($card_url)."
    echo "                Set PUBLIC_URL on the Cloud Run service and redeploy."
    exit 2
  fi
  echo "  PASS authed → 200, url=${card_url}"
}

probe_c() {
  echo "[probe C] run.invoker on cc-a2a-bridge includes DE service agent"
  local de_sa="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
  local present
  present=$(gcloud run services get-iam-policy cc-a2a-bridge \
    --region=us-central1 --project="$PROJECT_ID" --format=json 2>&1 \
    | python3 -c "
import json,sys
data = json.load(sys.stdin)
target = '${de_sa}'
for b in data.get('bindings', []):
    if b.get('role') == 'roles/run.invoker' and target in b.get('members', []):
        print('yes'); sys.exit(0)
print('no')")
  if [[ "$present" != "yes" ]]; then
    echo "  FAIL Probe C: ${de_sa} does NOT have roles/run.invoker on cc-a2a-bridge"
    echo "                GE registration will succeed but invocations will 401."
    exit 2
  fi
  echo "  PASS DE service agent has run.invoker"
}

probe_a
probe_b
probe_c

# ----- Probe D: build payload + show it -----

echo ""
echo "[probe D] fetching live AgentCard from bridge and embedding into payload"
ID_TOKEN=$(gcloud auth print-identity-token 2>/dev/null)
AGENT_CARD_JSON=$(curl -sS -H "Authorization: Bearer $ID_TOKEN" \
  "${BRIDGE_URL}/.well-known/agent-card.json")
# Sanity check it parsed.
echo "$AGENT_CARD_JSON" | python3 -m json.tool >/dev/null || {
  echo "  FAIL agent card did not parse as JSON"; exit 2;
}

# Build the Agent resource body.
# `a2aAgentDefinition.jsonAgentCard` is a STRING containing the full
# card JSON (discovered via Discovery Engine v1alpha schema).
# `authorizationConfig` is OMITTED for v1 — see "Open question 2" in
# Phase 7 confirm bullet. GE will run the agent under its service-agent
# identity only; no end-user OAuth consent flow is triggered. The bridge
# can still resolve identity via x-goog-iap-jwt-assertion or x-test-user.
python3 - <<PY > "$PAYLOAD_FILE"
import json
agent_card = json.loads('''$(echo "$AGENT_CARD_JSON" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)).replace("\\\\","\\\\\\\\").replace("'\''", "\\\\'\''"))')''')
# Inline the card as a JSON STRING (per A2AAgentDefinition.jsonAgentCard).
body = {
    "displayName": "${AGENT_DISPLAY_NAME}",
    "description": "Build scripts, dashboards, and prototypes from plain English. Reads files, runs commands, writes code in an isolated workspace, returns the result as a downloadable file artifact. v1 demo (single-user mode).",
    "a2aAgentDefinition": {
        "jsonAgentCard": json.dumps(agent_card),
    },
    "starterPrompts": [
        {"text": "Build me an interactive HTML dashboard from a CSV I paste."},
        {"text": "Turn this PRD into a clickable HTML prototype."},
        {"text": "Find the bottom-quartile headlines in this ad CSV and write 50 new variants under 30 characters."},
    ],
    "customPlaceholderText": "Describe the script, dashboard, or prototype you want…",
    "languageCode": "en",
}
print(json.dumps(body, indent=2))
PY

echo "  wrote: $PAYLOAD_FILE"
echo ""
echo "===== REGISTRATION PAYLOAD (the body sent to POST/PATCH) ====="
cat "$PAYLOAD_FILE"
echo ""
echo "===== Target URL ====="
echo "  $AGENTS_URL"
echo ""

if [[ $APPLY -eq 0 ]]; then
  echo "===== DRY RUN — Gate 2 ====="
  echo "  This was a dry run. To apply:"
  echo "    $0 --apply"
  echo "  or:"
  echo "    make register-agent-apply"
  exit 0
fi

# ----- --apply mode: idempotent POST or PATCH -----

echo "===== --apply: idempotent register-or-update ====="
# 1. LIST current agents, find one with our displayName.
existing_name=""
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
  echo "  found existing agent: ${existing_name} — PATCHing"
  patch_url="${API_BASE}/${existing_name}?updateMask=displayName,description,a2aAgentDefinition,starterPrompts,customPlaceholderText,languageCode"
  out=$(curl_api PATCH "$patch_url" "$PAYLOAD_FILE")
  ACTION="updated"
else
  echo "  no existing 'Claude Code' agent — POSTing"
  out=$(curl_api POST "$AGENTS_URL" "$PAYLOAD_FILE")
  ACTION="created"
fi

code=$(echo "$out" | grep -oE '__HTTP_CODE__:[0-9]+__' | grep -oE '[0-9]+')
body=$(echo "$out" | sed 's/__HTTP_CODE__.*//')
echo ""
echo "  HTTP $code"
echo "$body" | python3 -m json.tool 2>/dev/null | head -40 || echo "$body" | head -40

if [[ "$code" != "200" && "$code" != "201" ]]; then
  echo ""
  echo "===== REGISTRATION FAILED — halt ====="
  exit 1
fi

agent_name=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
echo ""
echo "===== Phase 7 registration: ${ACTION} ====="
echo "  resource name: ${agent_name}"
echo ""
echo "  To revoke (de-register):"
echo "    scripts/unregister-agent.sh --apply"
echo "  or:"
echo "    make unregister-agent"
