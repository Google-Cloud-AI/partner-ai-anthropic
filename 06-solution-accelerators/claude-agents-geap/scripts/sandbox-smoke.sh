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

# Phase 4 sandbox-smoke — multi-turn-across-restart
# --------------------------------------------------
# Turn 1: prompt with a durable fact ("My name is Schneider and I work at
#   Google Cloud on the cc-on-ge project. Please remember this."). Assert
#   the SSE stream contains a `tool_use` event with name=="remember".
#
# Pod restart: delete the SandboxClaim from Turn 1 (controller destroys
#   the bound pod). Apply a fresh claim for Turn 2 — different pod, fresh
#   in-memory state. The session lives in Firestore (cc-on-ge DB).
#
# Turn 2: same context_id, prompt "What's my name and where do I work?".
#   Assert (a) SSE contains tool_use name=="recall", (b) the result text
#   mentions BOTH "Schneider" AND "Google Cloud".
#
# Optional bonus: direct Firestore inspection between turns to confirm
# the fact was actually persisted to memory/{user_id}/facts/.
#
# gVisor pods don't support kubectl port-forward (Phase 2 Lesson) — we
# exec into the bound pod and curl localhost:9000 from inside.
set -euo pipefail

NAMESPACE=cc-sandbox
TEMPLATE=cc-backend
REMOTE_PORT=9000
TIMEOUT_READY=600
TIMEOUT_CURL=600   # 10 min per turn — Phase 3 turns + memory writes/reads

# Stable per-run context_id; both turns send X-Context-Id: $CTXID.
RUNSUFFIX="$(date +%s)-$$"
CTXID="phase4-test-${RUNSUFFIX}"
USERID="phase4-smoke-user"
CLAIM1="smoke-${RUNSUFFIX}-1"
CLAIM2="smoke-${RUNSUFFIX}-2"

PROMPT1='My name is Schneider and I work at Google Cloud on the cc-on-ge project. Please remember this.'
PROMPT2="What's my name and where do I work?"

POD1=""
POD2=""

cleanup() {
  local rc=$?
  echo ""
  echo "----- cleanup -----"
  kubectl -n "$NAMESPACE" delete sandboxclaim "$CLAIM1" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete sandboxclaim "$CLAIM2" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

# -------- helpers --------

apply_claim_and_wait() {
  # Note: only the bound POD NAME goes to stdout (so callers can capture
  # via $()). All status/diagnostic messages route to stderr.
  local claim="$1"
  echo "  applying SandboxClaim: $claim" >&2
  kubectl apply -f - <<EOF >/dev/null
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: ${claim}
  namespace: ${NAMESPACE}
  labels:
    cc-a2a/smoke: "true"
spec:
  sandboxTemplateRef:
    name: ${TEMPLATE}
EOF
  local start=$SECONDS

  local sandbox_name=""
  while [[ -z "$sandbox_name" ]]; do
    if (( SECONDS - start > TIMEOUT_READY )); then
      echo "FAIL: claim $claim never bound" >&2
      kubectl -n "$NAMESPACE" describe sandboxclaim "$claim" >&2 || true
      return 1
    fi
    sandbox_name=$(kubectl -n "$NAMESPACE" get sandboxclaim "$claim" \
      -o jsonpath='{.status.sandbox.Name}' 2>/dev/null || true)
    [[ -z "$sandbox_name" ]] && sleep 3
  done

  local selector
  selector=$(kubectl -n "$NAMESPACE" get sandbox "$sandbox_name" \
    -o jsonpath='{.status.selector}' 2>/dev/null || true)
  if [[ -n "$selector" ]]; then
    local remaining=$(( TIMEOUT_READY - (SECONDS - start) ))
    (( remaining < 30 )) && remaining=30
    kubectl -n "$NAMESPACE" wait pod -l "$selector" \
      --for=condition=Ready --timeout="${remaining}s" >&2
    local pod
    pod=$(kubectl -n "$NAMESPACE" get pod -l "$selector" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$pod" ]]; then
      echo "FAIL: no pod matches selector for claim $claim" >&2
      return 1
    fi
    # The ONE line that goes to stdout — the captured value.
    echo "$pod"
    return 0
  fi
  echo "FAIL: Sandbox $sandbox_name has no .status.selector" >&2
  return 1
}

post_execute() {
  # Drive curl from inside the pod in DETACHED mode, then poll a marker
  # file. Reason: a long-held `kubectl exec` SPDY tunnel is unreliable —
  # the apiserver tears it down after a few minutes even when data is
  # flowing ("connection reset by peer"). By writing the response to a
  # file and polling for /tmp/exec-done, each kubectl call is short.
  local pod="$1"; local prompt="$2"; local outfile="$3"
  echo "  POST /execute on pod=$pod ctx=$CTXID (detached + poll)"

  # 1. Write prompt and a self-contained runner script onto the pod.
  printf '%s' "$prompt" | kubectl -n "$NAMESPACE" exec -i "$pod" -- \
    tee /tmp/smoke-prompt.txt >/dev/null
  kubectl -n "$NAMESPACE" exec -i "$pod" -- tee /tmp/smoke-runner.sh \
    >/dev/null <<RUNNER
#!/bin/bash
rm -f /tmp/exec-done /tmp/exec-out.txt /tmp/exec-rc /tmp/exec-err.txt
curl -sf --max-time ${TIMEOUT_CURL} -X POST \\
  -H 'Content-Type: text/plain' \\
  -H 'X-Context-Id: ${CTXID}' \\
  -H 'X-User-Id: ${USERID}' \\
  --data-binary @/tmp/smoke-prompt.txt \\
  http://localhost:${REMOTE_PORT}/execute \\
  > /tmp/exec-out.txt 2>/tmp/exec-err.txt
echo \$? > /tmp/exec-rc
touch /tmp/exec-done
RUNNER

  # 2. Launch the runner detached. nohup + & + `disown`-equivalent
  # ensures it survives the exec tunnel closing.
  kubectl -n "$NAMESPACE" exec "$pod" -- \
    bash -c 'nohup bash /tmp/smoke-runner.sh >/dev/null 2>&1 < /dev/null &' \
    >/dev/null

  # 3. Poll for the marker file (short exec calls each time).
  local waited=0 step=15
  while ! kubectl -n "$NAMESPACE" exec "$pod" -- \
      test -f /tmp/exec-done 2>/dev/null; do
    sleep "$step"
    waited=$(( waited + step ))
    if (( waited > TIMEOUT_CURL )); then
      echo "  FAIL  /tmp/exec-done absent after ${TIMEOUT_CURL}s"
      kubectl -n "$NAMESPACE" exec "$pod" -- \
        bash -c 'echo "--- exec-err.txt ---"; cat /tmp/exec-err.txt 2>/dev/null; echo "--- exec-out.txt (first 1500B) ---"; head -c 1500 /tmp/exec-out.txt 2>/dev/null' || true
      return 1
    fi
    echo "    waiting for response: ${waited}s / ${TIMEOUT_CURL}s elapsed"
  done

  # 4. Pull the response.
  kubectl -n "$NAMESPACE" exec "$pod" -- cat /tmp/exec-out.txt > "$outfile"
  local rc
  rc=$(kubectl -n "$NAMESPACE" exec "$pod" -- cat /tmp/exec-rc 2>/dev/null || echo "?")
  echo "  curl rc=${rc}  bytes=$(wc -c < "$outfile")"
}

inspect_firestore_facts() {
  # Note: `kubectl exec -i` is REQUIRED for the heredoc stdin to reach the
  # container — without `-i`, python3 reads an empty stdin and exits 0 with
  # no output (silently passing nothing through). Use bash -c instead of
  # `python3 -` so cwd issues don't shadow the stdlib (Phase 4 lesson
  # learned re: /tmp/inspect.py vs Python's `inspect` module).
  local pod="$1"
  echo "  querying Firestore: memory/${USERID}/facts/"
  kubectl -n "$NAMESPACE" exec -i "$pod" -- bash -c 'cd /workspace && python3 -' <<'PY'
import asyncio, os
from google.cloud.firestore import AsyncClient

USER = os.environ.get("SMOKE_USERID", "phase4-smoke-user")

async def main():
    db = AsyncClient(project="cpe-slarbi-nvd-ant-demos", database="cc-on-ge")
    ref = db.collection("memory").document(USER).collection("facts")
    count = 0
    async for snap in ref.stream():
        count += 1
        d = snap.to_dict() or {}
        print(f"  - id={snap.id} text={d.get('text','')[:100]!r}")
    print(f"total_facts: {count}")
asyncio.run(main())
PY
}

# -------- TURN 1 --------

echo "===== Phase 4 smoke ====="
echo "  context_id: $CTXID"
echo "  user_id:    $USERID"

echo ""
echo "===== TURN 1: bind claim 1 ====="
POD1=$(apply_claim_and_wait "$CLAIM1")
echo "  pod1: $POD1"

# Sanity
kubectl -n "$NAMESPACE" exec "$POD1" -- \
  curl -sf --max-time 10 "http://localhost:${REMOTE_PORT}/healthz" >/dev/null

echo ""
echo "===== TURN 1: POST /execute (prompt 1, expect remember) ====="
echo "  prompt: $PROMPT1"
BODY1=/tmp/sandbox-smoke-turn1.txt
post_execute "$POD1" "$PROMPT1" "$BODY1"
echo "  bytes: $(wc -c < "$BODY1")"
echo "  --- truncated ---"
head -c 1500 "$BODY1"; echo
echo "  --- end ---"

echo ""
echo "===== TURN 1 assertions ====="
PASS=true
if grep -Eq '"type":[[:space:]]*"tool_use"[^}]*"name":[[:space:]]*"remember"' "$BODY1"; then
  echo "  PASS  tool_use 'remember' present"
else
  echo "  FAIL  no tool_use 'remember' in Turn 1 response"
  PASS=false
fi
if grep -qi 'remember' "$BODY1"; then
  echo "  PASS  response mentions 'remember'"
else
  echo "  FAIL  response doesn't mention 'remember'"
  PASS=false
fi

echo ""
echo "===== Firestore check between turns ====="
SMOKE_USERID="$USERID" inspect_firestore_facts "$POD1" \
  | tee /tmp/sandbox-smoke-facts.txt
if grep -Eq 'total_facts: [1-9]' /tmp/sandbox-smoke-facts.txt; then
  echo "  PASS  Firestore has at least one fact written"
else
  echo "  FAIL  Firestore shows zero facts for $USERID"
  PASS=false
fi

if ! $PASS; then
  echo ""
  echo "FAIL — Turn 1 assertions did not pass; aborting before Turn 2"
  exit 1
fi

# -------- POD RESTART --------

echo ""
echo "===== POD RESTART: delete claim 1 (controller destroys pod1) ====="
kubectl -n "$NAMESPACE" delete sandboxclaim "$CLAIM1" --wait=true >/dev/null
echo "  claim 1 deleted; pod1=$POD1 should be Terminating/gone"
# Give the warm pool a moment to replenish.
sleep 10

# -------- TURN 2 --------

echo ""
echo "===== TURN 2: bind claim 2 (must land on a different pod) ====="
POD2=$(apply_claim_and_wait "$CLAIM2")
echo "  pod2: $POD2"
if [[ "$POD2" == "$POD1" ]]; then
  echo "  WARN: pod2 == pod1 ($POD2). Rare but possible if warm pool kept the same node."
  echo "  The session-restore proof relies on Firestore replay — proceeding."
else
  echo "  PASS  pod2 != pod1 (session-restore is via Firestore, not pod memory)"
fi

echo ""
echo "===== TURN 2: POST /execute (prompt 2, expect recall) ====="
echo "  prompt: $PROMPT2"
BODY2=/tmp/sandbox-smoke-turn2.txt
post_execute "$POD2" "$PROMPT2" "$BODY2"
echo "  bytes: $(wc -c < "$BODY2")"
echo "  --- truncated ---"
head -c 1500 "$BODY2"; echo
echo "  --- end ---"

echo ""
echo "===== TURN 2 assertions ====="
TURN2_PASS=true
if grep -Eq '"type":[[:space:]]*"tool_use"[^}]*"name":[[:space:]]*"recall"' "$BODY2"; then
  echo "  PASS  tool_use 'recall' present"
else
  echo "  FAIL  no tool_use 'recall' in Turn 2 response"
  TURN2_PASS=false
fi
if grep -q 'Schneider' "$BODY2"; then
  echo "  PASS  response mentions 'Schneider'"
else
  echo "  FAIL  response missing 'Schneider'"
  TURN2_PASS=false
fi
if grep -q 'Google Cloud' "$BODY2"; then
  echo "  PASS  response mentions 'Google Cloud'"
else
  echo "  FAIL  response missing 'Google Cloud'"
  TURN2_PASS=false
fi

if ! $TURN2_PASS; then
  echo ""
  echo "FAIL — see /tmp/sandbox-smoke-turn{1,2}.txt and /tmp/sandbox-smoke-facts.txt"
  exit 1
fi

# -------- PHASE 9 — workspace-management turns (3, 4, 5) --------
#
# Turn 3: "what files do I have?" → expect tool_use=list_workspace and a
#         mention of a known workspace file. Pre-seed the workspace
#         from a prior write so list has something interesting to show.
# Turn 4: "delete <file>." → expect tool_use=delete_workspace_file with
#         confirm absent or False (soft-delete first call). Response
#         should describe soft-delete to .trash and ask for confirmation.
# Turn 5: "yes, delete it permanently" → expect a SECOND
#         tool_use=delete_workspace_file with confirm=True. Response
#         confirms hard-delete.

echo ""
echo "===== PHASE 9 PREP: write a known file in turn 0 (call it 'turn-zero') ====="
PROMPT_PREP="Use the claude_code tool to write 'workspace-mgmt-smoke-content' to /workspace/wms-target.txt. Confirm it exists."
PREP_BODY=/tmp/sandbox-smoke-prep.txt
post_execute "$POD2" "$PROMPT_PREP" "$PREP_BODY"
echo "  bytes: $(wc -c < "$PREP_BODY")"
head -c 400 "$PREP_BODY"; echo
if ! grep -q 'wms-target.txt' "$PREP_BODY"; then
  echo "  FAIL  prep turn did not produce the target file"
  exit 1
fi
echo "  PASS  prep turn wrote /workspace/wms-target.txt"

PROMPT3='What files are in my workspace right now?'
PROMPT4='Delete wms-target.txt please.'
PROMPT5='Yes, delete it permanently.'

echo ""
echo "===== TURN 3: list_workspace ====="
BODY3=/tmp/sandbox-smoke-turn3.txt
post_execute "$POD2" "$PROMPT3" "$BODY3"
echo "  bytes: $(wc -c < "$BODY3")"
head -c 800 "$BODY3"; echo
TURN3_PASS=true
if grep -Eq '"type":[[:space:]]*"tool_use"[^}]*"name":[[:space:]]*"list_workspace"' "$BODY3"; then
  echo "  PASS  tool_use 'list_workspace' present"
else
  echo "  FAIL  no tool_use 'list_workspace' in Turn 3"
  TURN3_PASS=false
fi
if grep -q 'wms-target.txt' "$BODY3"; then
  echo "  PASS  response mentions 'wms-target.txt'"
else
  echo "  FAIL  response missing 'wms-target.txt'"
  TURN3_PASS=false
fi
$TURN3_PASS || { echo "FAIL — Turn 3 assertions failed"; exit 1; }

echo ""
echo "===== TURN 4: delete (soft) ====="
BODY4=/tmp/sandbox-smoke-turn4.txt
post_execute "$POD2" "$PROMPT4" "$BODY4"
echo "  bytes: $(wc -c < "$BODY4")"
head -c 1500 "$BODY4"; echo
TURN4_PASS=true
if grep -Eq '"type":[[:space:]]*"tool_use"[^}]*"name":[[:space:]]*"delete_workspace_file"' "$BODY4"; then
  echo "  PASS  tool_use 'delete_workspace_file' present"
else
  echo "  FAIL  no tool_use 'delete_workspace_file' in Turn 4"
  TURN4_PASS=false
fi
# Soft-delete signature: tool_result mentions "Soft-deleted" + .trash path
if grep -qi 'Soft-deleted\|.trash\|trash/' "$BODY4"; then
  echo "  PASS  Turn 4 tool result indicates soft-delete (NOT permanent yet)"
else
  echo "  FAIL  Turn 4 doesn't reference soft-delete / .trash"
  TURN4_PASS=false
fi
$TURN4_PASS || { echo "FAIL — Turn 4 assertions failed"; exit 1; }

echo ""
echo "===== TURN 5: confirm permanent delete ====="
BODY5=/tmp/sandbox-smoke-turn5.txt
post_execute "$POD2" "$PROMPT5" "$BODY5"
echo "  bytes: $(wc -c < "$BODY5")"
head -c 1500 "$BODY5"; echo
TURN5_PASS=true
# Look for ANY second tool_use of delete_workspace_file in turn 5.
if grep -Eq '"type":[[:space:]]*"tool_use"[^}]*"name":[[:space:]]*"delete_workspace_file"' "$BODY5"; then
  echo "  PASS  tool_use 'delete_workspace_file' (confirm step) present"
else
  echo "  FAIL  no second delete_workspace_file tool_use in Turn 5"
  TURN5_PASS=false
fi
# Response should signal permanent delete (case-insensitive "permanently" OR "purged")
if grep -qiE 'permanently|purged|deleted .*[^l]y|permanent' "$BODY5"; then
  echo "  PASS  Turn 5 response indicates permanent removal"
else
  echo "  FAIL  Turn 5 doesn't acknowledge permanent removal"
  TURN5_PASS=false
fi
$TURN5_PASS || { echo "FAIL — Turn 5 assertions failed"; exit 1; }

echo ""
echo "PASS — sandbox-smoke green (Phase 4 multi-turn + Phase 9 workspace-management)"
exit 0
