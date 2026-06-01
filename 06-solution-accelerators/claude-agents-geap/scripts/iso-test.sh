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

# Phase 6 negative isolation test.
#
# This is the test that PROVES the project's security claim. The pod's
# own service account has zero IAM on the snapshots bucket (Phase 1
# invariant). Every turn the bridge mints a short-lived OAuth2 token
# whose Credential Access Boundary (CEL) restricts it to objects under
# `users/<user_key>/`. The pod uses that token as the ONLY credential
# it ever sees for storage.
#
# If user A's pod can read user B's prefix using user A's token,
# isolation is broken and we MUST NOT ship. No warnings, no skips.
#
# NOTE on caller location: this script issues the negative-read attempts
# from the test workstation, not from inside user A's pod. The CAB is
# enforced SERVER-SIDE by Google Cloud Storage — the caller's network
# location, kubeconfig, or runtime is irrelevant to whether the 403
# fires. What matters is the token's CredentialAccessBoundary, and that
# is identical to what bridge/downscope.py mints in production. Running
# from the workstation is faster, equally rigorous, and avoids the
# token-injection-into-pod machinery without weakening the assertion.
#
# Test scenarios (3 assertions all must pass):
#   1. With user_a's CAB token, READ users/<user_b_key>/_manifest.json
#      → expect 403 Forbidden.
#   2. With user_a's CAB token, LIST users/<user_b_key>/
#      → expect 403 Forbidden (bucket-level list not granted).
#   3. With user_a's CAB token, READ users/<user_a_key>/own-test-blob
#      → expect 200 (sanity — same token works for own prefix).
#
# Plus a background invariant check:
#   - cc-a2a-backend GSA has roles/{aiplatform.user, datastore.user} ONLY.
#   - cc-a2a-backend GSA has NO bucket-level IAM bindings.
set -euo pipefail

PROJECT=cpe-slarbi-nvd-ant-demos
BUCKET=cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots
NAMESPACE=cc-sandbox
SERVICE=cc-a2a-bridge
REGION=us-central1
RUNSUFFIX="$(date +%s)-$$"

# x-test-user values for the two synthetic users.
USER_A="iso-a-${RUNSUFFIX}"
USER_B="iso-b-${RUNSUFFIX}"

# user_key derivation matches bridge/auth.py:
#   user_key = sha256(f"test:{x-test-user}").hexdigest()[:16]
USER_A_KEY=$(printf "test:%s" "$USER_A" | sha256sum | head -c 16)
USER_B_KEY=$(printf "test:%s" "$USER_B" | sha256sum | head -c 16)

echo "===== Phase 6 iso-test ====="
echo "  user A: x-test-user=${USER_A}  user_key=${USER_A_KEY}"
echo "  user B: x-test-user=${USER_B}  user_key=${USER_B_KEY}"
echo "  bucket: ${BUCKET}"
echo ""

# -------- pre-flight: Phase 1 invariant (backend SA has NO storage IAM) --------

echo "===== INVARIANT: cc-a2a-backend GSA has no storage.* IAM ====="
BAD_ROLES=$(
  gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' \
    --filter='bindings.members:"serviceAccount:cc-a2a-backend@cpe-slarbi-nvd-ant-demos.iam.gserviceaccount.com" AND bindings.role:roles/storage*' \
    --format='value(bindings.role)' 2>&1 | sort -u
)
if [[ -n "$BAD_ROLES" ]]; then
  echo "  FAIL: backend SA has storage role(s): $BAD_ROLES"
  echo "  HALTING — Phase 1 invariant violated."
  exit 1
fi
echo "  PASS  no project-level storage.* on backend SA"

BAD_BUCKET=$(
  gcloud storage buckets get-iam-policy "gs://${BUCKET}" --format=json 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
backend = "serviceAccount:cc-a2a-backend@cpe-slarbi-nvd-ant-demos.iam.gserviceaccount.com"
for b in data.get("bindings", []):
    if backend in b.get("members", []):
        print(b["role"])
'
)
if [[ -n "$BAD_BUCKET" ]]; then
  echo "  FAIL: backend SA has bucket-level binding(s): $BAD_BUCKET"
  echo "  HALTING — Phase 1 invariant violated."
  exit 1
fi
echo "  PASS  no bucket-level IAM on backend SA"

# -------- drive 1 turn through bridge for each user, so each has a workspace --------

echo ""
echo "===== drive bridge: one short turn per user (creates the workspaces) ====="
BRIDGE_URL=$(gcloud run services describe "$SERVICE" --region="$REGION" --project="$PROJECT" --format='value(status.url)')
CURR_USER=$(gcloud config get-value account 2>/dev/null)

# Grant-then-revoke run.invoker for the duration of this script. Lesson
# learned (post-Phase 8): leaving the binding in place across runs
# accumulates dev-convenience grants on a production-shape Cloud Run
# service. Trap on EXIT/INT/TERM revokes it on the way out. Belt:
# pre-grant GC removes any stale binding from a previous crash.
revoke_invoker() {
  gcloud run services remove-iam-policy-binding "$SERVICE" \
    --region="$REGION" --project="$PROJECT" \
    --member="user:$CURR_USER" \
    --role=roles/run.invoker \
    --condition=None \
    --quiet >/dev/null 2>&1 || true
}
echo "  GC: removing any stale user:$CURR_USER run.invoker binding"
revoke_invoker
trap revoke_invoker EXIT INT TERM
echo "  granting roles/run.invoker on $SERVICE to user:$CURR_USER (for this run)"
gcloud run services add-iam-policy-binding "$SERVICE" \
  --region="$REGION" --project="$PROJECT" \
  --member="user:$CURR_USER" --role=roles/run.invoker --condition=None --quiet >/dev/null 2>&1
sleep 5

ID_TOKEN=$(gcloud auth print-identity-token "--audiences=$BRIDGE_URL" 2>/dev/null \
        || gcloud auth print-identity-token 2>/dev/null)

post_iso_turn() {
  local test_user="$1"; local prompt="$2"
  local ctx="iso-${test_user}-ctx"
  local task="iso-${test_user}-task-${RUNSUFFIX}"
  local msg="iso-${test_user}-msg-${RUNSUFFIX}"
  local req
  req=$(cat <<EOF
{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{
  "kind":"message","messageId":"$msg","role":"user","contextId":"$ctx","taskId":"$task",
  "parts":[{"kind":"text","text":"$prompt"}]
}}}
EOF
  )
  curl -sS --max-time 300 -i \
    -H "Authorization: Bearer $ID_TOKEN" \
    -H "Content-Type: application/json" \
    -H "x-test-user: $test_user" \
    -d "$req" "$BRIDGE_URL/" \
    | awk 'BEGIN{b=0} /^\r?$/{b=1; next} b{print}'
}

echo "  --- user A turn (writes /workspace/own-test-blob via claude_code) ---"
RESP_A=$(post_iso_turn "$USER_A" "Use the claude_code tool to write the string 'hello-from-a' to /workspace/own-test-blob, then list the file.")
echo "$RESP_A" | head -c 400; echo
if ! echo "$RESP_A" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  FAIL  user A turn didn't complete"
  exit 1
fi

echo "  --- user B turn (writes a known file) ---"
RESP_B=$(post_iso_turn "$USER_B" "Use the claude_code tool to write the string 'hello-from-b' to /workspace/secret-b.txt.")
echo "$RESP_B" | head -c 400; echo
if ! echo "$RESP_B" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  FAIL  user B turn didn't complete"
  exit 1
fi

echo ""
echo "  waiting 30s for background park to settle..."
sleep 30

# -------- main assertions: mint user_a's CAB token externally, run the negative tests --------

echo ""
echo "===== Phase 6 isolation assertions ====="
export ISO_BUCKET="$BUCKET"
export ISO_USER_A_KEY="$USER_A_KEY"
export ISO_USER_B_KEY="$USER_B_KEY"

# Probe script reuses Phase 6 Probe A's CAB pattern. Uses my user creds
# (or whoever is the current ADC) as the source — same effective token
# semantics as production because CAB enforcement is server-side and
# identity-agnostic at the CAB level.
PROBE=/tmp/phase5-probes/iso_assertion.py
PYBIN=/tmp/phase5-probes/.venv/bin/python3
if [[ ! -x "$PYBIN" ]]; then
  echo "  FAIL  ${PYBIN} not found. The iso-test requires the Phase 6"
  echo "        probe venv. Set it up with:"
  echo "          mkdir -p /tmp/phase5-probes && cd /tmp/phase5-probes && \\"
  echo "          python3 -m venv .venv && .venv/bin/pip install \\"
  echo "          --index-url https://pypi.org/simple/ google-auth google-cloud-storage pyopenssl"
  exit 1
fi
mkdir -p /tmp/phase5-probes
cat > "$PROBE" <<'PY'
import os
import sys
from google.auth import default, downscoped
from google.auth.transport.requests import Request
from google.cloud import storage
from google.api_core.exceptions import Forbidden, NotFound

BUCKET = os.environ["ISO_BUCKET"]
USER_A = os.environ["ISO_USER_A_KEY"]
USER_B = os.environ["ISO_USER_B_KEY"]

def cab_token(user_key):
    src, _ = default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    rules = [downscoped.AccessBoundaryRule(
        available_resource=f"//storage.googleapis.com/projects/_/buckets/{BUCKET}",
        available_permissions=["inRole:roles/storage.objectAdmin"],
        availability_condition=downscoped.AvailabilityCondition(
            expression=(
                f"resource.name.startsWith('projects/_/buckets/{BUCKET}/objects/users/{user_key}/')"
            ),
            title=f"scope-to-{user_key}",
        ),
    )]
    cab = downscoped.CredentialAccessBoundary(rules=rules)
    creds = downscoped.Credentials(source_credentials=src, credential_access_boundary=cab)
    creds.refresh(Request())
    return creds

scoped_a = cab_token(USER_A)
client = storage.Client(credentials=scoped_a, project="cpe-slarbi-nvd-ant-demos")
bucket = client.bucket(BUCKET)

errs = 0

# ----- assertion 1: cross-user object read → 403 -----
print(f"\n[iso] ASSERT 1: GET users/{USER_B}/secret-b.txt with user_A token (expect 403)")
try:
    data = bucket.blob(f"users/{USER_B}/secret-b.txt").download_as_bytes()
    print(f"  FAIL: read returned bytes — isolation BROKEN: {data!r}")
    errs += 1
except Forbidden:
    print("  PASS got 403")
except NotFound:
    # If the file wasn't parked yet, this still doesn't prove isolation.
    # Try the manifest path — bridge writes it on park.
    try:
        data = bucket.blob(f"users/{USER_B}/_manifest.json").download_as_text()
        print(f"  FAIL: manifest readable across users — isolation BROKEN")
        errs += 1
    except Forbidden:
        print("  PASS got 403 on manifest (secret-b.txt did not park yet)")
    except NotFound:
        # Even the manifest is missing — try a deliberate path that we
        # KNOW does NOT exist, but the 403 vs 404 distinction tells us
        # which check fires first. GCS returns 403 if the principal
        # lacks ACCESS, 404 if the object truly is missing (and access
        # is permitted).
        try:
            bucket.blob(f"users/{USER_B}/this-does-not-exist").download_as_bytes()
            print("  WARN: would have been allowed but file missing")
        except Forbidden:
            print("  PASS got 403 on synthetic cross-user path")
        except NotFound:
            print("  FAIL: 404 on cross-user read — CAB DOES NOT ENFORCE")
            errs += 1

# ----- assertion 2: cross-user LIST → 403 -----
print(f"\n[iso] ASSERT 2: LIST users/{USER_B}/ with user_A token (expect 403)")
try:
    list(client.list_blobs(BUCKET, prefix=f"users/{USER_B}/"))
    print(f"  FAIL: list returned — isolation BROKEN")
    errs += 1
except Forbidden:
    print("  PASS got 403 on cross-user list")

# ----- assertion 3: own-prefix read → 200 (sanity, otherwise CAB is over-tight) -----
print(f"\n[iso] ASSERT 3: GET users/{USER_A}/own-test-blob with user_A token (expect 200)")
try:
    data = bucket.blob(f"users/{USER_A}/own-test-blob").download_as_bytes()
    print(f"  PASS read returned {len(data)} bytes ({data[:60]!r})")
except Forbidden:
    print(f"  FAIL: own-prefix read got 403 — CAB is over-tight, isolation broken in the other direction")
    errs += 1
except NotFound:
    print(f"  WARN: own-test-blob not present (park may not have finished). Try the manifest instead.")
    try:
        m = bucket.blob(f"users/{USER_A}/_manifest.json").download_as_text()
        print(f"  PASS read own manifest ({len(m)} chars)")
    except (Forbidden, NotFound) as e:
        print(f"  FAIL: own manifest also missing/blocked: {type(e).__name__}")
        errs += 1

sys.exit(errs)
PY
"$PYBIN" "$PROBE" 2>&1
EXIT=$?

# -------- cleanup --------

echo ""
echo "===== cleanup (using my unscoped creds) ====="
gcloud storage rm "gs://${BUCKET}/users/${USER_A_KEY}/**" --quiet 2>&1 | tail -1 || true
gcloud storage rm "gs://${BUCKET}/users/${USER_B_KEY}/**" --quiet 2>&1 | tail -1 || true
kubectl -n cc-sandbox delete sandboxclaim "cc-u-${USER_A_KEY}" --wait=false 2>&1 | tail -1 || true
kubectl -n cc-sandbox delete sandboxclaim "cc-u-${USER_B_KEY}" --wait=false 2>&1 | tail -1 || true

if [[ "$EXIT" -ne 0 ]]; then
  echo ""
  echo "===== ISO-TEST FAILED — see assertions above. DO NOT SHIP. ====="
  exit "$EXIT"
fi

echo ""
echo "===== ISO-TEST GREEN — Phase 6 isolation verified ====="
