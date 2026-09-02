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

# =============================================================================
# Vogue Concierge — interactive one-command installer.
#
# Deploys the whole thing into YOUR Google Cloud project from a clean clone:
#   preflight -> auth -> config -> enable APIs -> Model Garden gate -> IAM ->
#   seed data (catalog images, BigQuery, RAG) -> deploy toolbox -> agents ->
#   React UI -> (A2A bridge, if this is the full build).
#
# Designed to run in Google Cloud Shell (or any machine with gcloud + python3).
# It writes/updates a .env as it captures generated ids, so it is safe to re-run:
# each step is idempotent (setup scripts skip existing resources; the agent
# engine updates in place).
#
#   ./bootstrap.sh            # interactive
#   ./bootstrap.sh --yes      # accept defaults / skip confirmations (best-effort)
#
# The one thing it cannot automate is enabling the Claude + image models in
# Agent Platform Model Garden (a console click-through) and registering the A2A bridge
# in Gemini Enterprise — it pauses and walks you through both.
# =============================================================================

set -euo pipefail

# --- pretty output ----------------------------------------------------------
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; DIM="$(printf '\033[2m')"; RED="$(printf '\033[31m')"
  GRN="$(printf '\033[32m')"; YEL="$(printf '\033[33m')"; BLU="$(printf '\033[36m')"
  RST="$(printf '\033[0m')"
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; RST=""
fi
step() { printf '\n%s==> %s%s\n' "${BOLD}${BLU}" "$*" "${RST}"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓ %s%s\n' "${GRN}" "$*" "${RST}"; }
warn() { printf '    %s! %s%s\n' "${YEL}" "$*" "${RST}"; }
die()  { printf '\n%sERROR: %s%s\n' "${RED}" "$*" "${RST}" >&2; exit 1; }

ASSUME_YES=0
case "${1:-}" in --yes|-y) ASSUME_YES=1 ;; esac

# ask VAR "Prompt" "default"  -> reads into VAR, honoring --yes
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
  if [ "$ASSUME_YES" = "1" ] && [ -n "$__default" ]; then
    printf -v "$__var" '%s' "$__default"; return
  fi
  if [ -n "$__default" ]; then
    read -r -p "    ${__prompt} [${__default}]: " __reply || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
  else
    read -r -p "    ${__prompt}: " __reply || true
    printf -v "$__var" '%s' "$__reply"
  fi
}

# confirm "Question"  -> returns 0 for yes
confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local __reply=""
  read -r -p "    ${1} [y/N]: " __reply || true
  case "$__reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

ENV_FILE=".env"
# set_env KEY VALUE  -> upsert into .env and export for the rest of this run
set_env() {
  local k="$1" v="$2"
  touch "$ENV_FILE"
  if grep -qE "^${k}=" "$ENV_FILE" 2>/dev/null; then
    grep -vE "^${k}=" "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  export "${k}=${v}"
}

# --- 0. banner + repo variant ----------------------------------------------
HAS_A2A=0
[ -f deploy_a2a.sh ] && HAS_A2A=1
printf '%s\n' "${BOLD}${BLU}"
cat <<'BANNER'
  ┌───────────────────────────────────────────────┐
  │        Vogue Concierge — installer             │
  │  Claude on Agent Platform · Agent Runtime│
  └───────────────────────────────────────────────┘
BANNER
printf '%s' "${RST}"
if [ "$HAS_A2A" = "1" ]; then
  info "Detected the ${BOLD}full${RST} build (React UI + Gemini Enterprise A2A bridge)."
else
  info "Detected the ${BOLD}React-only${RST} build."
fi

[ -f deploy.sh ] && [ -f deploy_agent_engine.py ] || \
  die "Run this from the repo root (deploy.sh / deploy_agent_engine.py not found)."

# --- 1. preflight -----------------------------------------------------------
step "Preflight — checking tooling"
command -v gcloud >/dev/null 2>&1 || die "gcloud not found. Install the Google Cloud SDK (or use Cloud Shell)."
ok "gcloud found"
PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || die "python3 not found. Install Python 3.11+ (or use Cloud Shell)."
ok "python found ($PYTHON)"

# --- 2. authentication ------------------------------------------------------
step "Authentication"
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
  warn "No active gcloud account."
  if confirm "Run 'gcloud auth login' now?"; then gcloud auth login; else die "Authenticate first, then re-run."; fi
fi
ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
ok "Signed in as ${ACCOUNT}"
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  warn "No Application Default Credentials (the scripts + Vertex SDK need these)."
  if confirm "Run 'gcloud auth application-default login' now?"; then
    gcloud auth application-default login
  else
    die "ADC required. Run 'gcloud auth application-default login', then re-run."
  fi
fi
ok "Application Default Credentials present"

# --- 3. configuration -------------------------------------------------------
step "Configuration"
# Reuse an existing .env so re-runs keep captured ids.
if [ -f "$ENV_FILE" ]; then
  info "Loading existing ${ENV_FILE}"
  set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a
fi
DEFAULT_PROJECT="${VERTEXAI_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
[ "$DEFAULT_PROJECT" = "(unset)" ] && DEFAULT_PROJECT=""
ask VERTEXAI_PROJECT "GCP project id" "$DEFAULT_PROJECT"
[ -n "$VERTEXAI_PROJECT" ] || die "A project id is required."

DERIVED_NUMBER="$(gcloud projects describe "$VERTEXAI_PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
ask PROJECT_NUMBER "GCP project number" "${DERIVED_NUMBER:-${PROJECT_NUMBER:-}}"
[ -n "$PROJECT_NUMBER" ] || die "Could not determine the project number (check the project id / your access)."
# The deploy scripts + setup scripts are pinned to us-central1 (RAG uses us-west1),
# so keep Cloud Run / Agent Runtime / BigQuery there to avoid a split-region deploy.
REGION="${REGION:-us-central1}"
ask CLAUDE_VERTEX_REGION "Region that serves Claude on Agent Platform" "${CLAUDE_VERTEX_REGION:-global}"

echo ""
info "${BOLD}Project:${RST}       ${VERTEXAI_PROJECT} (#${PROJECT_NUMBER})"
info "${BOLD}Region:${RST}        ${REGION}"
info "${BOLD}Claude region:${RST} ${CLAUDE_VERTEX_REGION}"
info "${BOLD}Build:${RST}         $([ "$HAS_A2A" = 1 ] && echo 'full (UI + A2A)' || echo 'React-only')"
confirm "Proceed with this configuration?" || die "Aborted."

# Seed .env from the template on first run so comments + model ids are preserved.
if [ ! -s "$ENV_FILE" ] && [ -f .env.example ]; then cp .env.example "$ENV_FILE"; fi
set_env VERTEXAI_PROJECT "$VERTEXAI_PROJECT"
set_env PROJECT_NUMBER   "$PROJECT_NUMBER"
set_env REGION           "$REGION"
set_env CLAUDE_VERTEX_REGION "$CLAUDE_VERTEX_REGION"
gcloud config set project "$VERTEXAI_PROJECT" >/dev/null 2>&1 || true
RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# --- 4. enable APIs ---------------------------------------------------------
step "Enabling required Google Cloud APIs"
info "This can take a minute the first time…"
gcloud services enable \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  --project "$VERTEXAI_PROJECT"
ok "APIs enabled"

# --- 5. Model Garden gate (manual) -----------------------------------------
step "Enable the Claude + image models (one-time, console)"
cat <<EOF
    Vogue Concierge needs these models enabled in Agent Platform Model Garden for
    project ${BOLD}${VERTEXAI_PROJECT}${RST}:
      • Claude Sonnet 5, Claude Opus 5, Claude Haiku 4.5
      • Gemini 3.1 Flash Image (gemini-3.1-flash-image) — generates the catalog images
    Open: ${BLU}https://console.cloud.google.com/vertex-ai/model-garden?project=${VERTEXAI_PROJECT}${RST}
    (Search each model, click "Enable" / accept terms. This can't be scripted.)
EOF
if ! confirm "Have you enabled the Claude models AND Gemini 3.1 Flash Image?"; then
  warn "Enable them in the console, then re-run ./bootstrap.sh (it will resume)."
  exit 0
fi
ok "Models confirmed enabled"

# --- 6. IAM for the runtime service account --------------------------------
step "Granting IAM to the runtime service account"
info "${RUNTIME_SA}"
grant() {
  if gcloud projects add-iam-policy-binding "$VERTEXAI_PROJECT" \
      --member="serviceAccount:${RUNTIME_SA}" --role="$1" \
      --condition=None --quiet >/dev/null 2>&1; then
    ok "granted $1"
  else
    warn "could not grant $1 (grant it manually if a deploy step fails)"
  fi
}
grant roles/aiplatform.user
grant roles/bigquery.dataEditor
grant roles/bigquery.jobUser
grant roles/storage.objectViewer

# --- 7. staging bucket ------------------------------------------------------
step "Creating the Agent Runtime staging bucket"
STAGING_BUCKET="gs://${VERTEXAI_PROJECT}-vogue-staging"
if gsutil ls -b "$STAGING_BUCKET" >/dev/null 2>&1; then
  ok "${STAGING_BUCKET} already exists"
else
  gsutil mb -l "$REGION" -p "$VERTEXAI_PROJECT" "$STAGING_BUCKET" \
    || die "Failed to create ${STAGING_BUCKET} (bucket names are globally unique — set STAGING_BUCKET in .env to override)."
  ok "created ${STAGING_BUCKET}"
fi
set_env STAGING_BUCKET "$STAGING_BUCKET"

# --- 8. python dependencies -------------------------------------------------
step "Installing Python dependencies"
if confirm "Install requirements.txt with pip now? (needed to run the setup scripts)"; then
  "$PYTHON" -m pip install -q --upgrade pip
  "$PYTHON" -m pip install -q -r requirements.txt
  ok "dependencies installed"
else
  warn "Skipped — make sure requirements.txt is already installed."
fi

# --- 9. verify Claude on Agent Platform --------------------------------------------
step "Verifying Claude is reachable on Vertex"
if "$PYTHON" tests/test_connection.py; then
  ok "Claude reachable"
else
  warn "Connection test failed — usually a Model Garden enablement or quota issue."
  confirm "Continue anyway?" || die "Resolve the connection issue, then re-run."
fi

# --- 10. seed the data plane -----------------------------------------------
step "Building the data plane (catalog images, BigQuery, RAG)"
warn "setup_catalog.py generates 30 images — this costs money and takes several minutes."
if confirm "Run data setup now?"; then
  info "→ catalog + product images"
  "$PYTHON" scripts/setup_catalog.py
  info "→ BigQuery inventory + loyalty"
  "$PYTHON" scripts/setup_bigquery.py
  info "→ orders table"
  "$PYTHON" scripts/setup_orders.py
  info "→ RAG corpus (capturing the resource name)"
  RAG_LOG="$(mktemp)"
  "$PYTHON" scripts/setup_rag.py 2>&1 | tee "$RAG_LOG"
  RAG_RES="$(grep -E '^RAG_CORPUS_RESOURCE=' "$RAG_LOG" | tail -1 | cut -d= -f2- || true)"
  rm -f "$RAG_LOG"
  [ -n "$RAG_RES" ] || die "Could not capture RAG_CORPUS_RESOURCE from setup_rag.py output."
  set_env RAG_CORPUS_RESOURCE "$RAG_RES"
  ok "RAG_CORPUS_RESOURCE=${RAG_RES}"
else
  [ -n "${RAG_CORPUS_RESOURCE:-}" ] || die "Data setup skipped and no RAG_CORPUS_RESOURCE in .env — cannot deploy the agents."
  warn "Skipped data setup; using RAG_CORPUS_RESOURCE from .env."
fi

# --- 11. deploy the MCP Toolbox --------------------------------------------
step "Deploying the MCP Toolbox to Cloud Run"
TB_LOG="$(mktemp)"
bash deploy_toolbox.sh 2>&1 | tee "$TB_LOG"
TOOLBOX_URL="$(grep -E '^TOOLBOX_URL=' "$TB_LOG" | tail -1 | cut -d= -f2- || true)"
rm -f "$TB_LOG"
[ -n "$TOOLBOX_URL" ] || die "Could not capture TOOLBOX_URL from deploy_toolbox.sh output."
set_env TOOLBOX_URL "$TOOLBOX_URL"
ok "TOOLBOX_URL=${TOOLBOX_URL}"

# --- 12. deploy the agent team ---------------------------------------------
step "Deploying the agent team to Agent Runtime"
info "(reuses AGENT_ENGINE_ID from .env to update in place, if present)"
AE_LOG="$(mktemp)"
"$PYTHON" deploy_agent_engine.py 2>&1 | tee "$AE_LOG"
AE_ID="$(grep -E '^AGENT_ENGINE_ID=' "$AE_LOG" | tail -1 | cut -d= -f2- || true)"
rm -f "$AE_LOG"
[ -n "$AE_ID" ] || die "Could not capture AGENT_ENGINE_ID from deploy_agent_engine.py output."
set_env AGENT_ENGINE_ID "$AE_ID"
ok "AGENT_ENGINE_ID=${AE_ID}"

# --- 12b. let the deployed agents call the MCP Toolbox ----------------------
# The toolbox is deployed private, so the identity the agents run as needs
# roles/run.invoker on it. deploy_toolbox.sh attempts this too, but on a fresh
# project the Agent Runtime service agent does not exist until the deploy above
# has run — so we repeat it here, where it is guaranteed to resolve.
step "Authorising the agents to call the MCP Toolbox"
ENGINE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
info "${ENGINE_SA}"
if gcloud run services add-iam-policy-binding vogue-toolbox \
     --region "$REGION" --project "$VERTEXAI_PROJECT" \
     --member="serviceAccount:${ENGINE_SA}" \
     --role="roles/run.invoker" --quiet >/dev/null 2>&1; then
  ok "granted roles/run.invoker on vogue-toolbox"
else
  warn "could not grant roles/run.invoker on vogue-toolbox — the Inventory agent's BigQuery tools will fail until this is granted."
fi

# --- 13. deploy the React UI -----------------------------------------------
step "Deploying the React UI to Cloud Run"
bash deploy.sh
UI_URL="$(gcloud run services describe vogue-concierge --region "$REGION" \
  --project "$VERTEXAI_PROJECT" --format='value(status.url)' 2>/dev/null || true)"
[ -n "$UI_URL" ] && ok "UI URL: ${UI_URL}"

# --- 14. deploy the A2A bridge (full build only) ---------------------------
BRIDGE_URL=""
if [ "$HAS_A2A" = "1" ]; then
  step "Deploying the A2A bridge to Cloud Run"
  bash deploy_a2a.sh
  BRIDGE_URL="$(gcloud run services describe vogue-a2a --region "$REGION" \
    --project "$VERTEXAI_PROJECT" --format='value(status.url)' 2>/dev/null || true)"
  [ -n "$BRIDGE_URL" ] && ok "Bridge URL: ${BRIDGE_URL}"
fi

# --- done -------------------------------------------------------------------
printf '\n%s' "${BOLD}${GRN}"
cat <<'DONE'
  ┌───────────────────────────────────────────────┐
  │   Vogue Concierge is deployed. 🎉               │
  └───────────────────────────────────────────────┘
DONE
printf '%s' "${RST}"
[ -n "$UI_URL" ]     && info "${BOLD}Storefront:${RST} ${UI_URL}"
if [ "$HAS_A2A" = "1" ] && [ -n "$BRIDGE_URL" ]; then
  info "${BOLD}A2A bridge:${RST} ${BRIDGE_URL}"
  info "${BOLD}AgentCard:${RST}  ${BRIDGE_URL}/.well-known/agent.json"
  echo ""
  info "${BOLD}Last manual step — register in Gemini Enterprise:${RST}"
  info "  Gemini Enterprise / Agentspace console → Agents → Add agent → A2A"
  info "  Paste the AgentCard URL above; GE reads the skills and wires it up."
fi
echo ""
info "All generated ids were saved to ${BOLD}${ENV_FILE}${RST}. Re-run ./bootstrap.sh anytime to update."
