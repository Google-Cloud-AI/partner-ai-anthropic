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

"""Deploy Vogue Concierge to Agent Runtime (the agent runtime).

WHAT THIS DOES
--------------
Packages the ``agents/`` team + the ``data/`` catalog and uploads it to Agent Platform
Agent Runtime, which then hosts and serves the multi-agent system for you (no
servers to run). The FastAPI app (``app.py``) and the A2A bridge both call this
deployed engine via ``stream_query``.

PREREQUISITES (one-time, in your own project)
---------------------------------------------
  * Enable the Claude models in Agent Platform Model Garden for your project + the
    region in CLAUDE_VERTEX_REGION (see agents/config.py).
  * Create the staging bucket below (or point STAGING_BUCKET at an existing one).
  * Have Application Default Credentials available (gcloud auth or a deploy SA).

RUN
---
    python deploy_agent_engine.py

It prints the new Agent Engine ID; set that as AGENT_ENGINE_ID on the Cloud Run
service that serves the UI (the printed gcloud command does this for you).
"""

import os

import vertexai
from vertexai import agent_engines
from vertexai.preview import reasoning_engines

PROJECT_ID = os.environ.get("VERTEXAI_PROJECT")
if not PROJECT_ID:
    raise RuntimeError(
        "VERTEXAI_PROJECT is not set. Export it (or copy .env.example to .env) with your "
        "GCP project id before deploying. See the README 'Setup' section."
    )
LOCATION = os.environ.get("AGENT_ENGINE_LOCATION", "us-central1")
STAGING_BUCKET = os.environ.get("STAGING_BUCKET", f"gs://{PROJECT_ID}-vogue-staging")

# Both of these are printed by earlier setup steps and are required: without them
# the deployed agents come up with no grounding and no BigQuery tools, which only
# shows up as bad answers at runtime. Fail here instead.
RAG_CORPUS_RESOURCE = os.environ.get("RAG_CORPUS_RESOURCE")
if not RAG_CORPUS_RESOURCE:
    raise RuntimeError(
        "RAG_CORPUS_RESOURCE is not set. Run scripts/setup_rag.py first (it prints the "
        "corpus resource name), then export it or add it to .env before deploying."
    )
TOOLBOX_URL = os.environ.get("TOOLBOX_URL")
if not TOOLBOX_URL:
    raise RuntimeError(
        "TOOLBOX_URL is not set. Run ./deploy_toolbox.sh first (it prints the Cloud Run "
        "URL), then export it or add it to .env before deploying."
    )

vertexai.init(
    project=PROJECT_ID,
    location=LOCATION,
    staging_bucket=STAGING_BUCKET,
)

# Import after vertexai.init so the agent builds in the right context.
from agents import config as agent_config
from agents.agent import create_agent

agent = create_agent()

# AdkApp wraps the ADK agent so Agent Runtime can serve it. Tracing on gives you
# per-turn spans in Cloud Trace, which pairs nicely with the A2A timeline view.
app = reasoning_engines.AdkApp(agent=agent, enable_tracing=True)

# Runtime dependencies installed inside the Agent Runtime container. This is only
# what the packaged agents/ tree imports: ADK and the RAG client come from
# google-cloud-aiplatform, anthropic[vertex] backs ADK's built-in Claude model,
# and toolbox-adk calls the MCP Toolbox. The agents never touch BigQuery or GCS
# directly — reads go through the Toolbox, and the writes run on the Cloud Run
# layer from checkout.py, which is not deployed here — so those clients are not
# listed. Keep this in step with requirements.txt.
#
# The floors are spelled out rather than left to the extras. The [adk] extra only
# asks for google-adk>=1.27,<3, which admits releases without
# AnthropicGenerateContentConfig/`effort` and without the thinking-block
# round-trip inside a tool-use turn; and `agentplatform.rag`, which the RAG tools
# import, first shipped in google-cloud-aiplatform 1.151.0 (1.150.0 raises
# ImportError). Pip happens to pick new enough versions today — these floors make
# that a guarantee instead of a coincidence.
REQUIREMENTS = [
    "google-cloud-aiplatform[adk,agent_engines]>=1.151",
    "google-adk>=2.4",
    "anthropic[vertex]>=0.78",
    "httpx>=0.27.0",
    "toolbox-adk>=1.3.0",
]
# Environment for the deployed agents. No API key — Claude on Agent Platform uses the
# Agent Runtime service account's ADC.
#
# These are read back out of agents/config.py rather than repeated here, so the
# deployed engine runs the same models as a local `adk web` run. To change one,
# set the env var (or edit agents/config.py) — don't add a second source of truth.
ENV_VARS = {
    "VERTEXAI_PROJECT": PROJECT_ID,
    "CLAUDE_VERTEX_REGION": agent_config.CLAUDE_VERTEX_REGION,
    "ORCHESTRATOR_MODEL": agent_config.ORCHESTRATOR_MODEL,
    "STYLE_MODEL": agent_config.STYLE_MODEL,
    "INVENTORY_MODEL": agent_config.INVENTORY_MODEL,
    "RETURNS_MODEL": agent_config.RETURNS_MODEL,
    "ORCHESTRATOR_EFFORT": agent_config.ORCHESTRATOR_EFFORT,
    "STYLE_EFFORT": agent_config.STYLE_EFFORT,
    "TOOLBOX_URL": TOOLBOX_URL,
    "RAG_CORPUS_RESOURCE": RAG_CORPUS_RESOURCE,
}
EXTRA_PACKAGES = ["agents/", "data/"]  # ship the agent package + catalog data

# UPDATE IN PLACE vs CREATE NEW: if AGENT_ENGINE_ID is set we update the existing
# engine (keeping the same ID, so the UI and A2A bridge don't need re-pointing).
# Otherwise we create a fresh engine. This avoids accumulating orphaned engines.
PROJECT_NUMBER = os.environ.get("PROJECT_NUMBER", "YOUR_PROJECT_NUMBER")
EXISTING_ID = os.environ.get("AGENT_ENGINE_ID", "").strip()

if EXISTING_ID:
    resource = f"projects/{PROJECT_NUMBER}/locations/{LOCATION}/reasoningEngines/{EXISTING_ID}"
    print(f"Updating existing Agent Runtime {EXISTING_ID} in place...")
    remote_app = agent_engines.update(
        resource_name=resource,
        agent_engine=app,
        requirements=REQUIREMENTS,
        env_vars=ENV_VARS,
        extra_packages=EXTRA_PACKAGES,
    )
else:
    print("Creating a new Agent Runtime...")
    remote_app = agent_engines.create(
        agent_engine=app,
        requirements=REQUIREMENTS,
        env_vars=ENV_VARS,
        extra_packages=EXTRA_PACKAGES,
    )

agent_engine_id = remote_app.gca_resource.name.split("/")[-1]
print(f"\n{'=' * 60}")
print("Agent Runtime deployed.")
print(f"Resource:        {remote_app.gca_resource.name}")
print(f"Agent Runtime ID: {agent_engine_id}")
print(f"{'=' * 60}")
# Machine-readable line — bootstrap.sh greps for '^AGENT_ENGINE_ID='.
print(f"AGENT_ENGINE_ID={agent_engine_id}")
print("\nPoint the Cloud Run UI service at the new engine:")
print(
    f'gcloud run services update vogue-concierge --region {LOCATION} '
    f'--project {PROJECT_ID} --set-env-vars "AGENT_ENGINE_ID={agent_engine_id}"'
)
