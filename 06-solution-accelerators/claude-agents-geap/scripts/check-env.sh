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

# Fail-fast preflight before any Terraform or gcloud action.
set -euo pipefail

EXPECTED_PROJECT="${PROJECT_ID:-cpe-slarbi-nvd-ant-demos}"

fail() { echo "check-env FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "check-env: verifying local toolchain and gcloud context"

# Required CLIs on PATH
for tool in gcloud terraform gh jq ruff; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found at $(command -v "$tool")"
  else
    fail "$tool not on PATH"
  fi
done

# gcloud authenticated
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
[[ -n "$ACTIVE_ACCOUNT" ]] || fail "no active gcloud account (run: gcloud auth login)"
ok "gcloud active account: $ACTIVE_ACCOUNT"

# Application Default Credentials present (Terraform uses ADC)
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || fail "Application Default Credentials missing (run: gcloud auth application-default login)"
ok "ADC present"

# Project matches the locked value
CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ "$CURRENT_PROJECT" == "$EXPECTED_PROJECT" ]] \
  || fail "gcloud project is '$CURRENT_PROJECT', expected '$EXPECTED_PROJECT' (run: gcloud config set project $EXPECTED_PROJECT)"
ok "gcloud project: $CURRENT_PROJECT"

# Phase 1+: 'beta' gcloud component required for Agent Sandbox enable step.
if ! gcloud beta --help >/dev/null 2>&1; then
  GCLOUD_PATH="$(command -v gcloud)"
  case "$GCLOUD_PATH" in
    /usr/bin/*|/usr/lib/*|/usr/share/google-cloud-sdk/*)
      cat >&2 <<MSG
check-env FAIL: 'beta' gcloud component missing, and your gcloud appears
to be apt-installed ('$GCLOUD_PATH'). apt-installed gcloud cannot use
'gcloud components install'. Fix one of:
  - sudo apt-get install google-cloud-cli  (apt path; bundles beta)
  - install official SDK: https://cloud.google.com/sdk/docs/install
MSG
      exit 1
      ;;
    *)
      cat >&2 <<MSG
check-env FAIL: 'beta' gcloud component missing.
Required by Phase 1+ (Agent Sandbox addon enable runs 'gcloud beta').
Fix: gcloud components install beta
MSG
      exit 1
      ;;
  esac
fi
ok "gcloud beta component installed"

# Phase 1+: gcloud beta must be recent enough to include --enable-agent-sandbox.
# The flag landed in gcloud beta ~2026.05.08; older betas (e.g. 2026.01.02) lack it.
if ! gcloud beta container clusters update --help 2>&1 | grep -q -- '--enable-agent-sandbox'; then
  cat >&2 <<MSG
check-env FAIL: gcloud beta is installed but too old — missing
'--enable-agent-sandbox' flag on 'gcloud beta container clusters update'.
This will cause Phase 1 apply to fail at the addon-enable step.

Fix: gcloud components update
MSG
  exit 1
fi
ok "gcloud beta has --enable-agent-sandbox flag"

echo "check-env: PASS"
