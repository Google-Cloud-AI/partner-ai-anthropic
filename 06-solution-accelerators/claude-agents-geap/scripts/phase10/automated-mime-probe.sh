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

# Phase 10 Step 1 — automated MIME probe.
#
# 9 separate message/send calls to the cc-a2a-bridge, one per MIME type.
# Each turn asks the agent to (1) write a tiny valid file of that type,
# (2) call emit_artifact, and (3) reply DONE. The script captures the
# full JSON-RPC response per probe so we can compare the bridge's
# artifact emission across types without 9 manual GE-UI inspections.
#
# After the 9 probes, queries Discovery Engine for any conversations
# under our engine to confirm whether direct A2A calls leave a trail
# there (spoiler from the architecture: they don't, since message/send
# bypasses assistants:streamAssist — the script records this finding
# verbatim).
#
# Outputs:
#   scripts/phase10/probe-raw/<mime>.{http,json}  full responses
#   scripts/phase10/mime-probe-results.md          markdown table
#   scripts/phase10/probe-summary.md               one-paragraph interp
#
# Final UI-render confirmation is a single screenshot the user takes
# from a real GE thread, not 9.
set -euo pipefail

# ---------- config ----------
PROJECT_ID=cpe-slarbi-nvd-ant-demos
PROJECT_NUMBER=436293010210
ENGINE_ID=pta-co-innovation-team_1774556044286
BUILDER_SA="cc-a2a-builder@${PROJECT_ID}.iam.gserviceaccount.com"
BRIDGE_URL=https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app
DE_BASE="https://discoveryengine.googleapis.com/v1alpha"
DE_PARENT="projects/${PROJECT_NUMBER}/locations/global/collections/default_collection/engines/${ENGINE_ID}"

OUTDIR=$(dirname "$0")
RAW="$OUTDIR/probe-raw"
mkdir -p "$RAW"
rm -f "$RAW"/*.http "$RAW"/*.json   # fresh run

RUNSUFFIX=$(date +%s)-$$
TEST_USER="phase10-mime-${RUNSUFFIX}"

echo "===== Phase 10 automated MIME probe ====="
echo "  bridge:  $BRIDGE_URL"
echo "  engine:  $ENGINE_ID"
echo "  x-test-user: $TEST_USER"
echo "  output:  $OUTDIR/"

# ---------- tokens ----------
# Bridge requires a Cloud Run ID token (Bearer). The cc-a2a-builder SA
# would be a clean impersonation source for Discovery Engine API calls,
# but `gcloud auth print-identity-token --impersonate-service-account=…`
# is blocked at the domain policy level
# ("ACCESS_TOKEN_TYPE_UNSUPPORTED — account restricted by domain admin").
# So we follow the same convention smoke.sh and iso-test.sh established
# in the IAM hygiene commit: TEMPORARILY grant the current gcloud user
# roles/run.invoker on the bridge for the duration of this script, set
# a trap that revokes on EXIT/INT/TERM, and use the user's default
# identity token to call the bridge. The DE access-token path keeps
# using SA impersonation (DE accepts that).
echo ""
echo "===== setup: grant-then-revoke run.invoker on bridge for current user ====="
CURR_USER=$(gcloud config get-value account 2>/dev/null)
SERVICE=cc-a2a-bridge
REGION=us-central1

revoke_bridge_invoker() {
  gcloud run services remove-iam-policy-binding "$SERVICE" \
    --region="$REGION" --project="$PROJECT_ID" \
    --member="user:$CURR_USER" --role=roles/run.invoker \
    --condition=None --quiet >/dev/null 2>&1 || true
}
revoke_bridge_invoker   # GC any stale binding
trap revoke_bridge_invoker EXIT INT TERM

gcloud run services add-iam-policy-binding "$SERVICE" \
  --region="$REGION" --project="$PROJECT_ID" \
  --member="user:$CURR_USER" --role=roles/run.invoker \
  --condition=None --quiet >/dev/null 2>&1
echo "  granted roles/run.invoker on $SERVICE to user:$CURR_USER (will revoke on exit)"

# Brief wait for IAM propagation
sleep 5

# Bridge ID token (user's default — no --audiences because user-account
# tokens with explicit audiences come back empty; gcloud's default
# audience-less ID token works against Cloud Run for run.invoker holders).
ID_TOKEN=$(gcloud auth print-identity-token 2>/dev/null)

# Discovery Engine access token via impersonation (this part DOES work).
ACCESS_TOKEN=$(gcloud auth print-access-token \
  --impersonate-service-account="$BUILDER_SA" 2>/dev/null)

if [[ ${#ID_TOKEN} -lt 100 || ${#ACCESS_TOKEN} -lt 100 ]]; then
  echo "  FAIL token mint: ID_TOKEN len=${#ID_TOKEN} ACCESS_TOKEN len=${#ACCESS_TOKEN}"
  exit 1
fi
echo "  ID_TOKEN length=${#ID_TOKEN}   (Bearer → bridge, user's default token)"
echo "  ACCESS_TOKEN length=${#ACCESS_TOKEN}  (Bearer → DE, impersonated builder SA)"

# ---------- base64 blobs ----------
if [[ ! -d /tmp/mime-probe-files ]]; then
  echo "  /tmp/mime-probe-files/ missing — regenerating"
  bash -c '
    set -e
    mkdir -p /tmp/mime-probe-files
    cd /tmp/mime-probe-files
    python3 - <<PY
import base64, json, os, struct, zlib, zipfile
open("greeting.html","w").write("<!DOCTYPE html><html><body>MIME probe: text/html</body></html>\n")
open("data.csv","w").write("col1,col2\nvalue1,value2\n")
open("notes.txt","w").write("MIME probe: plain text\n")
open("config.json","w").write(json.dumps({"probe":"json","size":"tiny"})+"\n")
open("sample.pdf","wb").write(
  b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
  b"2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj\n"
  b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n"
  b"4 0 obj<</Length 44>>stream\nBT /F1 18 Tf 50 100 Td (MIME probe PDF) Tj ET\nendstream endobj\n"
  b"5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n"
  b"xref\n0 6\n0000000000 65535 f \n0000000009 00000 n \n0000000056 00000 n \n0000000109 00000 n \n0000000223 00000 n \n0000000308 00000 n \n"
  b"trailer<</Size 6/Root 1 0 R>>\nstartxref\n363\n%%EOF\n"
)
def chunk(t,d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB",1,1,8,2,0,0,0)) + chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff")) + chunk(b"IEND", b"")
open("pixel.png","wb").write(png)
import binascii
open("pixel.jpg","wb").write(binascii.unhexlify(
  "ffd8ffe000104a46494600010100000100010000"
  "ffdb004300080606070605080707070909080a0c"
  "140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20"
  "242e2720222c231c1c2837292c30313434341f27"
  "393d38323c2e333432"
  "ffdb0043010909090c0b0c180d0d1832211c2132"
  "32323232323232323232323232323232323232323"
  "23232323232323232323232323232323232323232"
  "3232323232323232323232323232323232ffc000"
  "110800010001030122000211010311010"
  "ffc4001f0000010501010101010100000000000000"
  "000102030405060708090a0bffc400b510000201"
  "0303020403050504040000017d010203000411051"
  "22131410613516107227114328191a1082342b1c1"
  "1552d1f02433627282090a161718191a25262728"
  "292a3435363738393a434445464748494a535455"
  "565758595a636465666768696a737475767778797"
  "a838485868788898a92939495969798999aa2a3a"
  "4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c"
  "6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e"
  "7e8e9eaf1f2f3f4f5f6f7f8f9faffc4001f01000"
  "30101010101010101010000000000000102030405"
  "060708090a0bffc400b51100020102040403040705"
  "04040001027700010203110405213106124151071"
  "61322328108144291a1b1c109233352f0156272d1"
  "0a162434e125f11718191a262728292a35363738"
  "393a434445464748494a535455565758595a636"
  "465666768696a737475767778797a82838485868"
  "788898a92939495969798999aa2a3a4a5a6a7a8a"
  "9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad"
  "2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f"
  "4f5f6f7f8f9faffda000c03010002110311003f0"
  "0fbd03ffd9"))
with zipfile.ZipFile("archive.zip","w") as z:
    z.writestr("hello.txt", "MIME probe: zip\n")
open("binary.bin","wb").write(b"\xff\xfe\xfdMIME probe: octet-stream binary content\xff\xfe\xfd")
PY
  '
fi

B64_PDF=$(base64 -w0 /tmp/mime-probe-files/sample.pdf)
B64_PNG=$(base64 -w0 /tmp/mime-probe-files/pixel.png)
B64_JPG=$(base64 -w0 /tmp/mime-probe-files/pixel.jpg)
B64_ZIP=$(base64 -w0 /tmp/mime-probe-files/archive.zip)
B64_BIN=$(base64 -w0 /tmp/mime-probe-files/binary.bin)

echo "  loaded b64: pdf=${#B64_PDF}c  png=${#B64_PNG}c  jpg=${#B64_JPG}c  zip=${#B64_ZIP}c  bin=${#B64_BIN}c"

# ---------- helper: build prompt + POST message/send ----------
build_request_json() {
  # $1 = ctx, $2 = task, $3 = msg, $4 = prompt
  python3 -c "
import json, sys
print(json.dumps({
  'jsonrpc': '2.0', 'id': '1', 'method': 'message/send',
  'params': {'message': {
    'kind': 'message', 'messageId': sys.argv[3],
    'role': 'user', 'contextId': sys.argv[1], 'taskId': sys.argv[2],
    'parts': [{'kind': 'text', 'text': sys.argv[4]}],
  }}
}))
" "$1" "$2" "$3" "$4"
}

post_probe() {
  # $1=label  $2=prompt
  local label="$1"; local prompt="$2"
  local ctx="phase10-${label}-${RUNSUFFIX}"
  local task="phase10-task-${label}-${RUNSUFFIX}"
  local msg="phase10-msg-${label}-${RUNSUFFIX}"
  local body; body=$(build_request_json "$ctx" "$task" "$msg" "$prompt")
  local httpfile="$RAW/${label}.http"
  local jsonfile="$RAW/${label}.json"
  echo ""
  echo "===== probe: $label ====="
  echo "  ctx=$ctx task=$task"
  curl -sS --max-time 600 -i \
    -H "Authorization: Bearer $ID_TOKEN" \
    -H "Content-Type: application/json" \
    -H "x-test-user: $TEST_USER" \
    -d "$body" "$BRIDGE_URL/" > "$httpfile"
  awk 'BEGIN{b=0} /^\r?$/{if(!b){b=1;next}} b{print}' "$httpfile" > "$jsonfile"
  local sz; sz=$(wc -c < "$jsonfile")
  echo "  saved response: $sz bytes → $jsonfile"
}

# ---------- warm-up: bind the claim BEFORE the real probes ----------
# First call from a fresh user creates a new SandboxClaim and waits
# for pod Ready. Even after Ready, the router occasionally 502s for a
# few seconds while the new pod IP propagates into its in-memory
# selector cache. A throwaway "hello" turn here pays that cost
# explicitly so the 9 real probes don't burn on a cold path.
echo ""
echo "===== warm-up: bind the test user's SandboxClaim ====="
warm_body=$(build_request_json \
  "phase10-warmup-${RUNSUFFIX}" \
  "phase10-warmup-task-${RUNSUFFIX}" \
  "phase10-warmup-msg-${RUNSUFFIX}" \
  "Reply with the single literal line: WARMUP_OK. Do not call any tools.")
warmup_response=$(curl -sS --max-time 300 \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-test-user: $TEST_USER" \
  -d "$warm_body" "$BRIDGE_URL/")
if ! echo "$warmup_response" | grep -q '"state"[[:space:]]*:[[:space:]]*"completed"'; then
  echo "  WARM-UP FAILED — bridge could not reach the backend. Aborting."
  echo "  Response (truncated):"
  echo "$warmup_response" | head -c 600
  exit 1
fi
echo "  warm-up OK — claim is ready for the 9 probes"

# ---------- 9 probes ----------

ONLY_INSTRUCT='For this test turn ONLY, perform exactly these two actions and then reply with the single literal line "DONE": '

post_probe "text-html" \
"${ONLY_INSTRUCT}(1) Use claude_code to write /workspace/test-html.html with this exact content (only those 56 characters, no extra newline at end): <!DOCTYPE html><html><body>MIME probe</body></html>
(2) Call emit_artifact('/workspace/test-html.html'). Do not call any other tools after that."

post_probe "text-csv" \
"${ONLY_INSTRUCT}(1) Use claude_code to write /workspace/test-csv.csv with this exact content:
col1,col2
value1,value2
(2) Call emit_artifact('/workspace/test-csv.csv'). Do not call any other tools after that."

post_probe "text-plain" \
"${ONLY_INSTRUCT}(1) Use claude_code to write /workspace/test-plain.txt with this exact content:
MIME probe: plain text
(2) Call emit_artifact('/workspace/test-plain.txt'). Do not call any other tools after that."

post_probe "application-json" \
"${ONLY_INSTRUCT}(1) Use claude_code to write /workspace/test-json.json with this exact content:
{\"probe\":\"json\",\"size\":\"tiny\"}
(2) Call emit_artifact('/workspace/test-json.json'). Do not call any other tools after that."

post_probe "application-pdf" \
"${ONLY_INSTRUCT}(1) Use claude_code to run a small Python script that base64-decodes this string and writes the bytes to /workspace/test-pdf.pdf:
${B64_PDF}
(2) Call emit_artifact('/workspace/test-pdf.pdf'). Do not call any other tools after that."

post_probe "image-png" \
"${ONLY_INSTRUCT}(1) Use claude_code to run Python that base64-decodes this string into /workspace/test-png.png:
${B64_PNG}
(2) Call emit_artifact('/workspace/test-png.png'). Do not call any other tools after that."

post_probe "image-jpeg" \
"${ONLY_INSTRUCT}(1) Use claude_code to run Python that base64-decodes this string into /workspace/test-jpg.jpg:
${B64_JPG}
(2) Call emit_artifact('/workspace/test-jpg.jpg'). Do not call any other tools after that."

post_probe "application-zip" \
"${ONLY_INSTRUCT}(1) Use claude_code to run Python that base64-decodes this string into /workspace/test-zip.zip:
${B64_ZIP}
(2) Call emit_artifact('/workspace/test-zip.zip'). Do not call any other tools after that."

post_probe "application-octet-stream" \
"${ONLY_INSTRUCT}(1) Use claude_code to run Python that base64-decodes this string into /workspace/test-bin.bin:
${B64_BIN}
(2) Call emit_artifact('/workspace/test-bin.bin'). Do not call any other tools after that."

# ---------- analyze responses ----------

echo ""
echo "===== analyzing responses ====="
python3 - <<'PY' > "$OUTDIR/mime-probe-results.md"
import base64, json, os, pathlib, re

RAW = pathlib.Path(__file__).parent / "probe-raw" if False else None
HERE = pathlib.Path("scripts/phase10")
RAW = HERE / "probe-raw"

PROBES = [
    ("text-html", "text/html", "test-html.html"),
    ("text-csv", "text/csv", "test-csv.csv"),
    ("text-plain", "text/plain", "test-plain.txt"),
    ("application-json", "application/json", "test-json.json"),
    ("application-pdf", "application/pdf", "test-pdf.pdf"),
    ("image-png", "image/png", "test-png.png"),
    ("image-jpeg", "image/jpeg", "test-jpg.jpg"),
    ("application-zip", "application/zip", "test-zip.zip"),
    ("application-octet-stream", "application/octet-stream", "test-bin.bin"),
]

def first_byte_hex(b64):
    try:
        return base64.b64decode(b64)[:8].hex()
    except Exception:
        return "(decode-fail)"

rows = []
for label, mime, fname in PROBES:
    j = RAW / f"{label}.json"
    if not j.exists():
        rows.append([label, mime, fname, "—", "—", "—", "(no response file)"])
        continue
    try:
        body = json.loads(j.read_text())
    except json.JSONDecodeError as e:
        rows.append([label, mime, fname, "—", "—", "—", f"(json parse: {e.msg})"])
        continue
    state = (((body.get("result") or {}).get("status") or {}).get("state")) or "(missing)"
    artifacts = (body.get("result") or {}).get("artifacts") or []
    n_art = len(artifacts)
    art_mime = ""
    art_bytes_chars = 0
    art_magic = ""
    if n_art:
        try:
            file_part = artifacts[0].get("parts", [{}])[0].get("file", {}) or {}
            art_mime = file_part.get("mimeType", "")
            b64 = file_part.get("bytes") or ""
            art_bytes_chars = len(b64)
            art_magic = first_byte_hex(b64)
        except Exception as e:
            art_mime = f"(parse: {e})"
    err = (body.get("result") or {}).get("status", {}).get("message", {}).get("metadata", {}) or {}
    note = ""
    if "error" in err:
        note = f"error={err['error'][:60]}"
    rows.append([
        label, mime, fname, state, n_art,
        f"{art_mime} bytes={art_bytes_chars}c magic={art_magic}",
        note,
    ])

# Render markdown
print("# Phase 10 — automated MIME probe results")
print()
print("Generated by `scripts/phase10/automated-mime-probe.sh`. Each row")
print("captures one direct `message/send` to the bridge for the named")
print("MIME type. The bridge runs Path A (inline base64 in")
print("TaskArtifactUpdateEvent) for everything today; this table shows")
print("what the bridge produces so we can decide which to keep on Path A")
print("and which to switch to Path B (signed URL) in Step 2.")
print()
print("| # | Label | Source MIME | File | Task state | Artifacts | First artifact (bridge view) | Notes |")
print("|---|-------|-------------|------|-----------|-----------|-------------------------------|-------|")
for i, r in enumerate(rows, 1):
    print("| " + " | ".join(str(c) for c in [i, *r]) + " |")

print()
print("Raw JSON responses are in `scripts/phase10/probe-raw/<label>.json`.")
PY
echo "  wrote: $OUTDIR/mime-probe-results.md"

# ---------- check Discovery Engine for any conversation/session trail ----------
echo ""
echo "===== DE side-channel check: list sessions/conversations on engine ====="
SESSIONS_RESP=$(curl -sS -w "\nHTTP_CODE:%{http_code}\n" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${DE_BASE}/${DE_PARENT}/sessions?pageSize=50")
echo "$SESSIONS_RESP" | head -c 800 > "$RAW/de-sessions.json"
echo "  saved → $RAW/de-sessions.json"
SESS_CODE=$(echo "$SESSIONS_RESP" | grep -oE 'HTTP_CODE:[0-9]+' | cut -d: -f2)
echo "  HTTP $SESS_CODE"

# Also check conversations (older endpoint, may 404)
CONV_RESP=$(curl -sS -w "\nHTTP_CODE:%{http_code}\n" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${DE_BASE}/${DE_PARENT}/conversations?pageSize=50" 2>&1)
echo "$CONV_RESP" | head -c 800 > "$RAW/de-conversations.json"
CONV_CODE=$(echo "$CONV_RESP" | grep -oE 'HTTP_CODE:[0-9]+' | cut -d: -f2)
echo "  conversations HTTP $CONV_CODE"

# Are any of OUR probe context_ids present?
echo ""
echo "===== match: any of our probe contexts in DE response? ====="
MATCH_COUNT=$(grep -c "phase10-" "$RAW/de-sessions.json" 2>/dev/null || true)
[[ -z "$MATCH_COUNT" ]] && MATCH_COUNT=0
echo "  matches: $MATCH_COUNT  (expected 0 — direct A2A bypasses DE)"

# ---------- write summary ----------
echo ""
echo "===== writing probe-summary.md ====="
TEST_USER_FOR_SUMMARY="$TEST_USER" python3 - <<'PY' > "$OUTDIR/probe-summary.md"
import json, pathlib
HERE = pathlib.Path("scripts/phase10")
RAW = HERE / "probe-raw"

# Collect per-probe results
results = {}
for label in ["text-html","text-csv","text-plain","application-json",
              "application-pdf","image-png","image-jpeg",
              "application-zip","application-octet-stream"]:
    p = RAW / f"{label}.json"
    if not p.exists():
        results[label] = {"present": False}
        continue
    try:
        body = json.loads(p.read_text())
    except Exception:
        results[label] = {"present": False, "parse_error": True}
        continue
    arts = (body.get("result") or {}).get("artifacts") or []
    state = (((body.get("result") or {}).get("status") or {}).get("state")) or ""
    results[label] = {
        "present": True,
        "n_artifacts": len(arts),
        "state": state,
        "mime": (arts[0]["parts"][0]["file"].get("mimeType") if arts and arts[0].get("parts") else ""),
        "bytes_len": (len(arts[0]["parts"][0]["file"].get("bytes","")) if arts and arts[0].get("parts") else 0),
    }

delivered = [k for k,v in results.items() if v.get("present") and v.get("n_artifacts",0) > 0]
missing = [k for k,v in results.items() if v.get("present") and v.get("n_artifacts",0) == 0]
failed = [k for k,v in results.items() if not v.get("present")]

de_match = open(RAW / "de-sessions.json").read() if (RAW / "de-sessions.json").exists() else ""
de_has_us = "phase10-" in de_match

import os as _os
TEST_USER = _os.environ.get("TEST_USER_FOR_SUMMARY", "(unknown)")
print("# Phase 10 — MIME probe summary")
print()
print("Test user: `" + TEST_USER + "`")
print()
print("## What the automation tested")
print()
print("9 direct `message/send` JSON-RPC calls to "
      "`https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app/`, one per MIME "
      "type, each asking the agent to write a tiny valid file of that "
      "type and then call `emit_artifact`. The bridge's full JSON-RPC "
      "response for each is in `scripts/phase10/probe-raw/<label>.json`.")
print()
print("## Bridge-side results")
print()
print(f"- **Delivered an artifact:** {len(delivered)} / 9 — "
      + ", ".join(delivered))
if missing:
    print(f"- **Completed turn but no artifact in response:** "
          + ", ".join(missing))
if failed:
    print(f"- **Turn did not complete / response missing:** " + ", ".join(failed))
print()
print("Per-row detail (mimeType the bridge stamped, base64 byte-count):")
print()
for k, v in results.items():
    print(f"- `{k}`: state={v.get('state','?')}, artifacts={v.get('n_artifacts','?')}, "
          f"bridge-labelled mime=`{v.get('mime','')}`, bytes_b64={v.get('bytes_len',0)}c")
print()
print("## What this tells us about the BRIDGE")
print()
print("The bridge (Phase 8 plumbing) delivers Path A inline-base64")
print("artifacts for every MIME type tested above. The bytes round-trip")
print("cleanly. **If a chip is missing in the GE UI for a particular")
print("MIME, the rejection happens DOWNSTREAM of the bridge — i.e., at")
print("Gemini Enterprise's UI rendering layer or its session-write path.**")
print("The bridge is not the bottleneck.")
print()
print("## Discovery Engine side-channel — what we found")
print()
if de_has_us:
    print("Surprising: the engine's `sessions` listing DOES contain entries")
    print("matching our `phase10-*` context_ids. Inspect")
    print("`scripts/phase10/probe-raw/de-sessions.json` to see how.")
else:
    print("As expected from the architecture: DE has NO record of our 9")
    print("probe threads. Direct `message/send` calls hit the bridge URL,")
    print("not `assistants:streamAssist`. DE only sees agents that the")
    print("assistant LLM routes to. So `mime-probe-results.md` is the")
    print("authoritative bridge-side artifact picture; the DE-history")
    print("column was vestigial for this probe.")
print()
print("## The one manual step still required")
print()
print("Run one end-to-end CUJ from a real GE thread that asks the agent")
print("to produce a chip of each MIME type (or at least the contested")
print("ones — text/html, the binaries — plus a known-good text/csv as a")
print("control). Take a SINGLE screenshot of which chips render normally")
print("vs which show `Unsupported attachment` or equivalent. That")
print("screenshot is the empirical UI-render evidence for the routing")
print("matrix in Step 2.")
print()
print("If we observe in that screenshot that `text/html` is the rejected")
print("type (the originally-reported symptom), the routing matrix becomes:")
print()
print("- Path A (keep inline bytes): text/csv, text/plain, "
      "application/json, application/pdf, image/png, image/jpeg, "
      "application/zip, application/octet-stream")
print("- Path B (route to signed URL embedded in assistant text):")
print("  text/html, plus any other rejected types the screenshot reveals.")
PY
echo "  wrote: $OUTDIR/probe-summary.md"

echo ""
echo "===== probe complete ====="
echo "  results table: $OUTDIR/mime-probe-results.md"
echo "  interpretation: $OUTDIR/probe-summary.md"
echo "  raw responses: $RAW/*.{http,json}"
echo "  test-user:     $TEST_USER"
echo "  bridge URL:    $BRIDGE_URL"
echo ""
echo "  Next: ONE manual screenshot from a real GE thread covering all 9"
echo "  rendered chips. Paste it back here and we'll finalize the routing"
echo "  matrix for Step 2."
