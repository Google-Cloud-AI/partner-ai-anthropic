#!/usr/bin/env bash
# Phase 5 end-to-end smoke — posts a real A2A message/send to the deployed
# cc-a2a-bridge Cloud Run service and verifies status.state == "completed"
# plus a real Claude Opus response. Second invocation with same x-test-user
# verifies claim reuse (SandboxClaim count stays 1).
#
# Prereqs:
#   - `gcloud auth login` as a user with roles/run.invoker on cc-a2a-bridge
#     (grant temporarily with the SETUP block below).
#
# Assertions:
#   1. GET /.well-known/agent-card.json → 200, JSON includes name "Claude Code"
#   2. POST / (message/send) → 200, JSON-RPC result has status.state == "completed"
#   3. Response message body is non-empty (real Opus output)
#   4. Second call with same x-test-user reuses the SandboxClaim (count stays 1)
set -euo pipefail

PROJECT=cpe-slarbi-nvd-ant-demos
REGION=us-central1
SERVICE=cc-a2a-bridge
NAMESPACE=cc-sandbox
TEST_USER="${TEST_USER:-phase5-smoke}"
RUNSUFFIX="$(date +%s)-$$"

echo "===== resolving bridge URL ====="
BRIDGE_URL=$(gcloud run services describe "$SERVICE" \
  --region="$REGION" --project="$PROJECT" \
  --format='value(status.url)')
echo "  bridge: $BRIDGE_URL"

echo ""
echo "===== SETUP: grant-then-revoke run.invoker to current user ====="
# Lesson learned (post-Phase 8): idempotent IAM grants accumulate on the
# Cloud Run service across smoke runs unless explicitly revoked. We
# grant ONLY for the duration of this script and trap EXIT/INT/TERM
# so the binding is revoked regardless of exit status. Belt: before
# granting, GC any stale binding for $CURR_USER from a prior crash.
CURR_USER=$(gcloud config get-value account 2>/dev/null)

revoke_invoker() {
  # Best-effort cleanup. --condition=None avoids stomping on bindings
  # someone else added with a CEL condition.
  gcloud run services remove-iam-policy-binding "$SERVICE" \
    --region="$REGION" --project="$PROJECT" \
    --member="user:$CURR_USER" \
    --role=roles/run.invoker \
    --condition=None \
    --quiet >/dev/null 2>&1 || true
}

# Belt-and-suspenders: pre-grant GC of stale user-binding from a prior
# crash. We list current run.invoker members and remove ours if present
# BEFORE re-adding fresh.
echo "  GC: removing any stale user:$CURR_USER run.invoker binding"
revoke_invoker

trap revoke_invoker EXIT INT TERM

echo "  granting roles/run.invoker on $SERVICE to user:$CURR_USER (for this run)"
gcloud run services add-iam-policy-binding "$SERVICE" \
  --region="$REGION" --project="$PROJECT" \
  --member="user:$CURR_USER" \
  --role=roles/run.invoker \
  --condition=None \
  --quiet 2>&1 | tail -3

# Smoke takes a few seconds for IAM to propagate.
sleep 5

# ID token bound to the bridge URL's audience.
ID_TOKEN=$(gcloud auth print-identity-token "--audiences=$BRIDGE_URL" 2>/dev/null \
        || gcloud auth print-identity-token 2>/dev/null)

# -------- Assertion 1: agent card --------

echo ""
echo "===== ASSERTION 1: GET /.well-known/agent-card.json ====="
CARD=$(curl -sS -i -H "Authorization: Bearer $ID_TOKEN" \
  "$BRIDGE_URL/.well-known/agent-card.json")
CARD_STATUS=$(echo "$CARD" | head -1 | awk '{print $2}')
CARD_BODY=$(echo "$CARD" | awk 'BEGIN{b=0} /^\r?$/{b=1; next} b{print}')
echo "  status: $CARD_STATUS"
echo "  body (first 200 chars): $(echo "$CARD_BODY" | head -c 200)"
if [[ "$CARD_STATUS" != "200" ]]; then
  echo "  FAIL  agent card returned $CARD_STATUS"
  exit 1
fi
if ! echo "$CARD_BODY" | grep -q '"name":"Claude Code"'; then
  echo "  FAIL  agent card missing 'Claude Code' name"
  exit 1
fi
echo "  PASS  agent card OK"

# -------- Assertion 2: message/send --------

echo ""
echo "===== ASSERTION 2: POST / (A2A message/send) ====="
CONTEXT_ID="phase5-smoke-${RUNSUFFIX}"
TASK_ID="phase5-task-${RUNSUFFIX}-a"
MSG_ID="phase5-msg-${RUNSUFFIX}-a"

REQUEST=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "message/send",
  "params": {
    "message": {
      "kind": "message",
      "messageId": "$MSG_ID",
      "role": "user",
      "contextId": "$CONTEXT_ID",
      "taskId": "$TASK_ID",
      "parts": [
        {"kind": "text", "text": "Say hello in one short sentence."}
      ]
    }
  }
}
EOF
)

echo "  prompt: 'Say hello in one short sentence.'"
echo "  context_id: $CONTEXT_ID"
echo "  task_id:    $TASK_ID"
RESPONSE=$(curl -sS --max-time 600 -i \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-test-user: $TEST_USER" \
  -d "$REQUEST" \
  "$BRIDGE_URL/")
RESP_STATUS=$(echo "$RESPONSE" | head -1 | awk '{print $2}')
RESP_BODY=$(echo "$RESPONSE" | awk 'BEGIN{b=0} /^\r?$/{b=1; next} b{print}')
echo "  HTTP status: $RESP_STATUS"
echo "  body (first 1500 chars):"
echo "$RESP_BODY" | head -c 1500
echo
echo "  --- end body ---"

if [[ "$RESP_STATUS" != "200" ]]; then
  echo "  FAIL  message/send returned $RESP_STATUS"
  exit 1
fi

# Look for status.state == "completed" in the JSON-RPC result.
if echo "$RESP_BODY" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  PASS  status.state == completed"
else
  echo "  FAIL  status.state != completed (or missing)"
  exit 1
fi

# Real Opus response — body should contain some text part with content.
if echo "$RESP_BODY" | grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^"]'; then
  echo "  PASS  response has non-empty text"
else
  echo "  FAIL  response has no text content"
  exit 1
fi

# -------- Assertion 3: claim reuse on second call --------

echo ""
echo "===== ASSERTION 3: claims for user before second call ====="
CLAIMS_BEFORE=$(kubectl -n "$NAMESPACE" get sandboxclaims -o name 2>/dev/null \
  | grep -c '^sandboxclaim.extensions.agents.x-k8s.io/cc-u-' || true)
echo "  cc-u-* SandboxClaims: $CLAIMS_BEFORE"

echo ""
echo "===== second message/send with same x-test-user ====="
TASK_ID2="phase5-task-${RUNSUFFIX}-b"
MSG_ID2="phase5-msg-${RUNSUFFIX}-b"
REQUEST2=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": "2",
  "method": "message/send",
  "params": {
    "message": {
      "kind": "message",
      "messageId": "$MSG_ID2",
      "role": "user",
      "contextId": "$CONTEXT_ID",
      "taskId": "$TASK_ID2",
      "parts": [
        {"kind": "text", "text": "Reply with the single word 'okay'."}
      ]
    }
  }
}
EOF
)
RESPONSE2=$(curl -sS --max-time 600 -i \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-test-user: $TEST_USER" \
  -d "$REQUEST2" \
  "$BRIDGE_URL/")
RESP_STATUS2=$(echo "$RESPONSE2" | head -1 | awk '{print $2}')
RESP_BODY2=$(echo "$RESPONSE2" | awk 'BEGIN{b=0} /^\r?$/{b=1; next} b{print}')
echo "  HTTP status: $RESP_STATUS2"
echo "  body (first 500 chars): $(echo "$RESP_BODY2" | head -c 500)"
echo

CLAIMS_AFTER=$(kubectl -n "$NAMESPACE" get sandboxclaims -o name 2>/dev/null \
  | grep -c '^sandboxclaim.extensions.agents.x-k8s.io/cc-u-' || true)
echo "  cc-u-* SandboxClaims after: $CLAIMS_AFTER"

if [[ "$CLAIMS_AFTER" == "$CLAIMS_BEFORE" ]]; then
  echo "  PASS  claim count unchanged ($CLAIMS_AFTER) — same pod reused"
else
  echo "  FAIL  claim count changed ($CLAIMS_BEFORE → $CLAIMS_AFTER) — pod NOT reused"
  exit 1
fi

# -------- Assertion 4 (Phase 6): park / restore across pod death --------

# Distinct user so we don't collide with the claim from earlier turns.
PR_USER="phase6-pr-${RUNSUFFIX}"
PR_CTX="phase6-pr-ctx-${RUNSUFFIX}"
PR_USER_KEY=$(printf "test:%s" "$PR_USER" | sha256sum | head -c 16)
PR_CLAIM="cc-u-${PR_USER_KEY}"
PR_SECRET="park-restore-secret-${RUNSUFFIX}"

echo ""
echo "===== ASSERTION 4 (Phase 6): park / restore across pod death ====="
echo "  test user:    $PR_USER"
echo "  user_key:     $PR_USER_KEY"
echo "  claim:        $PR_CLAIM"
echo "  secret:       $PR_SECRET"

# Turn 1: write a file using claude_code.
echo ""
echo "  --- TURN 1: write /workspace/park-test.txt via claude_code ---"
PR_REQ1=$(cat <<EOF
{"jsonrpc":"2.0","id":"pr-1","method":"message/send","params":{"message":{
  "kind":"message","messageId":"pr-msg-1-${RUNSUFFIX}","role":"user",
  "contextId":"$PR_CTX","taskId":"pr-task-1-${RUNSUFFIX}",
  "parts":[{"kind":"text","text":"Use the claude_code tool to write the exact string '${PR_SECRET}' (no trailing newline) to /workspace/park-test.txt. Then confirm the file exists."}]
}}}
EOF
)
PR_RESP1=$(curl -sS --max-time 600 -i \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-test-user: $PR_USER" \
  -d "$PR_REQ1" "$BRIDGE_URL/")
PR_STATUS1=$(echo "$PR_RESP1" | head -1 | awk '{print $2}')
echo "    HTTP $PR_STATUS1; body first 400 chars: $(echo "$PR_RESP1" | awk 'BEGIN{b=0}/^\r?$/{b=1;next}b{print}' | head -c 400)"
if ! echo "$PR_RESP1" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  FAIL  turn 1 did not complete"
  exit 1
fi

# Wait for background park to settle (best-effort; backend does it as asyncio.create_task).
echo ""
echo "  waiting 45s for park to finish + manifest to land in GCS..."
sleep 45

# Sanity: verify the manifest landed.
if gcloud storage ls "gs://cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots/users/${PR_USER_KEY}/_manifest.json" >/dev/null 2>&1; then
  echo "  PASS  park manifest present in GCS"
else
  echo "  FAIL  park manifest NOT in GCS for users/${PR_USER_KEY}/"
  exit 1
fi

# Force pod death: delete the SandboxClaim. The controller destroys the bound pod.
echo ""
echo "  --- forcing pod death: delete SandboxClaim $PR_CLAIM ---"
kubectl -n "$NAMESPACE" delete sandboxclaim "$PR_CLAIM" --wait=true 2>&1 | tail -1
sleep 10
echo "  pod gone; bridge will get-or-create a fresh claim on Turn 2"

# Turn 2 — different pod, same user, ask agent to read the file back.
echo ""
echo "  --- TURN 2: cat /workspace/park-test.txt (expect $PR_SECRET in response) ---"
PR_REQ2=$(cat <<EOF
{"jsonrpc":"2.0","id":"pr-2","method":"message/send","params":{"message":{
  "kind":"message","messageId":"pr-msg-2-${RUNSUFFIX}","role":"user",
  "contextId":"$PR_CTX","taskId":"pr-task-2-${RUNSUFFIX}",
  "parts":[{"kind":"text","text":"Use the claude_code tool to cat /workspace/park-test.txt and return its exact contents verbatim in your reply."}]
}}}
EOF
)
PR_RESP2=$(curl -sS --max-time 600 -i \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-test-user: $PR_USER" \
  -d "$PR_REQ2" "$BRIDGE_URL/")
PR_STATUS2=$(echo "$PR_RESP2" | head -1 | awk '{print $2}')
PR_BODY2=$(echo "$PR_RESP2" | awk 'BEGIN{b=0}/^\r?$/{b=1;next}b{print}')
echo "    HTTP $PR_STATUS2; body first 1000 chars: $(echo "$PR_BODY2" | head -c 1000)"

if ! echo "$PR_BODY2" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  FAIL  turn 2 did not complete"
  exit 1
fi
if echo "$PR_BODY2" | grep -q "$PR_SECRET"; then
  echo "  PASS  turn 2 response contains the parked secret ($PR_SECRET)"
else
  echo "  FAIL  turn 2 response does NOT contain $PR_SECRET — restore failed"
  exit 1
fi

# Cleanup of park-restore prefix
gcloud storage rm "gs://cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots/users/${PR_USER_KEY}/**" --quiet 2>&1 | tail -1 || true
kubectl -n "$NAMESPACE" delete sandboxclaim "$PR_CLAIM" --wait=false 2>&1 | tail -1 || true


# -------- Phase 10 — Path A vs Path B routing through the bridge --------
#
# Two new assertions verify the MIME-allowlist routing landed in
# Phase 10:
#
#   Assertion 5 (text/html): the agent emits an HTML file. The bridge
#     response MUST carry the signed-URL fallback (URL in agent text,
#     no TaskArtifactUpdate). Pre-Phase-10 this was a broken chip;
#     now it should be a clickable link.
#
#   Assertion 6 (text/csv): the agent emits a CSV file. The bridge
#     response MUST still carry a TaskArtifactUpdate with FilePart
#     + FileWithBytes (chip in the GE UI). Regression check that
#     Path A wasn't accidentally broken when adding Path B.

P10_USER="phase10-routing-${RUNSUFFIX}"
P10_CTX="phase10-routing-ctx-${RUNSUFFIX}"

echo ""
echo "===== ASSERTION 5 (Phase 10): text/html → Path B signed URL ====="
P10_HTML_REQ=$(cat <<EOF
{"jsonrpc":"2.0","id":"p10-html","method":"message/send","params":{"message":{
  "kind":"message","messageId":"p10-html-msg-${RUNSUFFIX}","role":"user",
  "contextId":"$P10_CTX","taskId":"p10-html-task-${RUNSUFFIX}",
  "parts":[{"kind":"text","text":"Use the claude_code tool to write a tiny valid HTML file at /workspace/phase10-test.html with content <!DOCTYPE html><html><body>P10</body></html>. Then call emit_artifact on it. In your reply, include the user-facing message verbatim from the emit_artifact tool response."}]
}}}
EOF
)
P10_HTML_RESP=$(curl -sS --max-time 600 -i \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-test-user: $P10_USER" \
  -d "$P10_HTML_REQ" "$BRIDGE_URL/")
P10_HTML_STATUS=$(echo "$P10_HTML_RESP" | head -1 | awk '{print $2}')
P10_HTML_BODY=$(echo "$P10_HTML_RESP" | awk 'BEGIN{b=0}/^\r?$/{b=1;next}b{print}')
echo "  HTTP $P10_HTML_STATUS  body bytes=$(echo -n "$P10_HTML_BODY" | wc -c)"

P10_PASS=true
# Bridge should report state=completed
if ! echo "$P10_HTML_BODY" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  FAIL  state != completed"
  P10_PASS=false
fi
# Critical: response must contain a signed Cloud Storage URL embedded
# in the agent's text reply (Path B signature).
if echo "$P10_HTML_BODY" | grep -qE 'https://storage\.googleapis\.com/[^"[:space:]]+X-Goog-Signature='; then
  echo "  PASS  signed-URL pattern present in response (Path B fired)"
else
  echo "  FAIL  no signed URL in response — Path B did NOT fire for text/html"
  P10_PASS=false
fi
# Critical: response must NOT contain an inline base64 chip with
# text/html mime (would mean Path A still fired, regression).
# The artifact array on the Task should be empty OR not contain a
# text/html FilePart.
if echo "$P10_HTML_BODY" | python3 -c "
import json, sys
data = json.load(sys.stdin)
arts = (data.get('result') or {}).get('artifacts') or []
bad = []
for a in arts:
    for p in a.get('parts', []):
        f = p.get('file') or {}
        if f.get('mimeType') == 'text/html' and f.get('bytes'):
            bad.append(a.get('artifactId','?'))
if bad:
    print('FAIL: text/html chip with bytes was emitted as Path A:', bad)
    sys.exit(1)
print('OK: no text/html inline-bytes chip in Task.artifacts')
sys.exit(0)
"; then
  echo "  PASS  no text/html Path-A chip in Task.artifacts (correct)"
else
  echo "  FAIL  text/html chip was emitted via Path A — regression"
  P10_PASS=false
fi
$P10_PASS || { echo "FAIL — Phase 10 Assertion 5 (text/html → Path B) did not pass"; exit 1; }

echo ""
echo "===== ASSERTION 6 (Phase 10): text/csv → Path A chip preserved ====="
P10_CSV_REQ=$(cat <<EOF
{"jsonrpc":"2.0","id":"p10-csv","method":"message/send","params":{"message":{
  "kind":"message","messageId":"p10-csv-msg-${RUNSUFFIX}","role":"user",
  "contextId":"$P10_CTX","taskId":"p10-csv-task-${RUNSUFFIX}",
  "parts":[{"kind":"text","text":"Use the claude_code tool to write a tiny CSV at /workspace/phase10-test.csv with this content:\ncol1,col2\nv1,v2\nThen call emit_artifact on it."}]
}}}
EOF
)
P10_CSV_RESP=$(curl -sS --max-time 600 -i \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-test-user: $P10_USER" \
  -d "$P10_CSV_REQ" "$BRIDGE_URL/")
P10_CSV_STATUS=$(echo "$P10_CSV_RESP" | head -1 | awk '{print $2}')
P10_CSV_BODY=$(echo "$P10_CSV_RESP" | awk 'BEGIN{b=0}/^\r?$/{b=1;next}b{print}')
echo "  HTTP $P10_CSV_STATUS  body bytes=$(echo -n "$P10_CSV_BODY" | wc -c)"

P10_CSV_PASS=true
if ! echo "$P10_CSV_BODY" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  FAIL  state != completed"
  P10_CSV_PASS=false
fi
# Critical: artifact event with mimeType=text/csv AND non-empty bytes.
if echo "$P10_CSV_BODY" | python3 -c "
import json, sys
data = json.load(sys.stdin)
arts = (data.get('result') or {}).get('artifacts') or []
ok = False
for a in arts:
    for p in a.get('parts', []):
        f = p.get('file') or {}
        if f.get('mimeType') == 'text/csv' and f.get('bytes'):
            print('OK: text/csv chip with', len(f['bytes']), 'b64 chars'); ok = True
if not ok:
    print('FAIL: no text/csv Path-A chip in Task.artifacts')
    sys.exit(1)
sys.exit(0)
"; then
  echo "  PASS  Path-A text/csv chip present (regression check ok)"
else
  echo "  FAIL  text/csv chip missing — Path A regressed"
  P10_CSV_PASS=false
fi
$P10_CSV_PASS || { echo "FAIL — Phase 10 Assertion 6 (text/csv → Path A) did not pass"; exit 1; }

# Cleanup phase10 test prefix
P10_USER_KEY=$(printf "test:%s" "$P10_USER" | sha256sum | head -c 16)
gcloud storage rm "gs://cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots/users/${P10_USER_KEY}/**" --quiet 2>&1 | tail -1 || true
kubectl -n "$NAMESPACE" delete sandboxclaim "cc-u-${P10_USER_KEY}" --wait=false 2>&1 | tail -1 || true

echo ""
echo "===== ALL ASSERTIONS PASSED — Phase 5+6+10 smoke green ====="
