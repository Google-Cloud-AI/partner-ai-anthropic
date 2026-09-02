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

"""Vogue Concierge — configuration.

This is the single place to change *which* Claude models power *which* agent, and
where the supporting data services (RAG corpus, BigQuery, MCP Toolbox) live.

KEY IDEA: "the right model for the right agent."
------------------------------------------------
Rather than one model doing everything, each agent is matched to a Claude model
that fits its job. You can retune the whole system by editing the four model
constants below (or by setting the matching environment variables at deploy
time — handy for A/B testing models without changing code).

AUTH NOTE
---------
Claude runs on Agent Platform and authenticates with Google Application Default
Credentials (ADC). There is no Anthropic API key here — the previous per-request
token-refresh plumbing (refreshing an ``OPENAI_API_KEY`` every turn) is gone.
"""

import os


# --- GCP project / regions -------------------------------------------------
# The project that owns Agent Runtime, BigQuery, GCS, and the RAG corpus.
# Required — set VERTEXAI_PROJECT so nothing ever runs against the wrong project.
PROJECT_ID = os.environ.get("VERTEXAI_PROJECT")
if not PROJECT_ID:
    raise RuntimeError(
        "VERTEXAI_PROJECT is not set. Copy .env.example to .env (or export it) and set "
        "it to your GCP project id. See the README 'Setup' section."
    )

# Region for Agent Runtime / BigQuery / Cloud Run.
REGION = "us-central1"

# Region that actually SERVES Claude on Agent Platform. Claude availability AND quota are
# region-specific. We default to "global", which routes to available capacity and
# is the recommended default for Claude on Agent Platform — Sonnet 5, Opus 5 and
# Haiku 4.5 are all GA on the global endpoint, whereas regional endpoints may lack
# quota for the larger models until an increase is granted. Override per your own
# project's Model Garden / quota setup.
CLAUDE_VERTEX_REGION = os.environ.get("CLAUDE_VERTEX_REGION", "global")


# --- The right model for the right agent ------------------------------------
# Bare Vertex model ids for current-generation Claude. If your Model Garden
# requires a dated snapshot, override via env, e.g. "claude-opus-5@<date>".
#
#   Orchestrator  -> Sonnet 5  : fast, excellent tool routing + concierge voice
#   Style Advisor -> Opus 5    : deepest taste / trend reasoning (the showpiece)
#   Inventory     -> Haiku 4.5 : fast, cheap, deterministic stock/price lookups
#   Returns/Care  -> Haiku 4.5 : quick policy answers + empathetic care advice
ORCHESTRATOR_MODEL = os.environ.get("ORCHESTRATOR_MODEL", "claude-sonnet-5")
STYLE_MODEL = os.environ.get("STYLE_MODEL", "claude-opus-5")
INVENTORY_MODEL = os.environ.get("INVENTORY_MODEL", "claude-haiku-4-5")
RETURNS_MODEL = os.environ.get("RETURNS_MODEL", "claude-haiku-4-5")

# Reasoning effort. Sonnet 5 and Opus 5 both have extended thinking ON by
# default and default to "high" effort, so leaving this unset does NOT buy low
# latency — it opts into the deepest setting. Set it explicitly on both agents:
#   * Style Advisor  -> "high"   : richer outfit reasoning, this is the showpiece
#   * Orchestrator   -> "medium" : it routes and relays, so trade depth for speed
# Valid values: low|medium|high|xhigh|max. Haiku 4.5 does not take an effort
# setting, so the two fast specialists leave it unset.
STYLE_EFFORT = os.environ.get("STYLE_EFFORT", "high")
ORCHESTRATOR_EFFORT = os.environ.get("ORCHESTRATOR_EFFORT", "medium")


def vertex_model_path(model_id: str) -> str:
    """Return the fully-qualified Agent Platform resource name for a model id.

    ADK's built-in ``Claude`` class reads the project and the serving region out
    of the model path, which is how each agent can sit on a different region
    without any global environment variable. A value that is already a full
    ``projects/...`` path is passed through untouched, so an env override can
    point a single agent at a different project or endpoint.
    """
    if model_id.startswith("projects/"):
        return model_id
    return (
        f"projects/{PROJECT_ID}/locations/{CLAUDE_VERTEX_REGION}"
        f"/publishers/anthropic/models/{model_id}"
    )


# --- Data plane (unchanged from the original build) -------------------------
# BigQuery dataset holding inventory + loyalty tables (queried via MCP Toolbox).
BQ_DATASET = "vogue_concierge"

# GCS bucket with the 30 generated product images.
GCS_BUCKET = f"{PROJECT_ID}-vogue-concierge"

# Agent Platform RAG corpus (catalog + trend report). Note it lives in its own region.
RAG_REGION = "us-west1"
RAG_CORPUS_DISPLAY_NAME = "vogue-concierge-catalog"
RAG_CORPUS_RESOURCE = os.environ.get(
    "RAG_CORPUS_RESOURCE",
    "projects/YOUR_PROJECT_NUMBER/locations/us-west1/ragCorpora/YOUR_RAG_CORPUS_ID",
)

# MCP Toolbox endpoint that exposes the BigQuery inventory/loyalty tools.
# This is the Cloud Run URL printed by ./deploy_toolbox.sh. There is no localhost
# default: the service is deployed private and callers authenticate against this
# exact URL (it is the ID token's audience), so a wrong value fails as a 403
# rather than anything more useful. Local `adk web` runs point at the deployed
# service too, using your own gcloud credentials.
TOOLBOX_URL = os.environ.get("TOOLBOX_URL", "")
