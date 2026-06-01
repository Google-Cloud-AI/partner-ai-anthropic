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

# Phase 7 — un-register the Claude Code agent from the PTA Co-Innovation
# Team engine.
#
# Default: DRY RUN. Prints the resource name that WOULD be deleted.
# Pass `--apply` to actually call DELETE.
set -euo pipefail

PROJECT_ID="cpe-slarbi-nvd-ant-demos"
PROJECT_NUMBER="436293010210"
ENGINE_ID="pta-co-innovation-team_1774556044286"
LOCATION="global"
COLLECTION="default_collection"
ASSISTANT="default_assistant"
BUILDER_SA="cc-a2a-builder@${PROJECT_ID}.iam.gserviceaccount.com"
AGENT_DISPLAY_NAME="Claude Code"

API_BASE="https://discoveryengine.googleapis.com/v1alpha"
PARENT="projects/${PROJECT_NUMBER}/locations/${LOCATION}/collections/${COLLECTION}/engines/${ENGINE_ID}/assistants/${ASSISTANT}"
AGENTS_URL="${API_BASE}/${PARENT}/agents"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$BUILDER_SA" 2>/dev/null)
list_out=$(curl -sS -w "\n__HTTP_CODE__:%{http_code}__" \
  -H "Authorization: Bearer $TOKEN" "$AGENTS_URL")
code=$(echo "$list_out" | grep -oE '__HTTP_CODE__:[0-9]+__' | grep -oE '[0-9]+')
if [[ "$code" != "200" ]]; then
  echo "FAIL agents.list returned $code"
  echo "$list_out" | head -20
  exit 1
fi

target=$(echo "$list_out" | sed 's/__HTTP_CODE__.*//' \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for a in d.get('agents', []):
    if a.get('displayName') == '${AGENT_DISPLAY_NAME}':
        print(a['name']); break
")
if [[ -z "$target" ]]; then
  echo "no 'Claude Code' agent found — nothing to unregister"
  exit 0
fi

if [[ $APPLY -eq 0 ]]; then
  echo "DRY RUN — would DELETE: $target"
  echo "  run with --apply to actually delete"
  exit 0
fi

echo "DELETE $target"
out=$(curl -sS -w "\n__HTTP_CODE__:%{http_code}__" -X DELETE \
  -H "Authorization: Bearer $TOKEN" "${API_BASE}/${target}")
code=$(echo "$out" | grep -oE '__HTTP_CODE__:[0-9]+__' | grep -oE '[0-9]+')
echo "HTTP $code"
echo "$out" | sed 's/__HTTP_CODE__.*//' | head -20
[[ "$code" == "200" || "$code" == "204" ]]
