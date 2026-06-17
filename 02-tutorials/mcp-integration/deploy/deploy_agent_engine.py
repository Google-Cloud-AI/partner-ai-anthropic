# Copyright 2026 Google LLC
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     https://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Deploy the ADK BigQuery agent to Vertex AI Agent Engine.

Run from this tutorial folder (so `agent` is importable and bundled):

    python -m deploy.deploy_agent_engine

All configuration comes from environment variables loaded from .env; nothing is
hardcoded. The agent and its MCPToolset are defined synchronously in agent/agent.py
because Agent Engine cannot build an async toolset factory during the container
build.
"""

import os

from dotenv import load_dotenv

# Load .env BEFORE importing the agent: agent/agent.py reads configuration from
# os.environ at import time, so dotenv must populate it first.
load_dotenv()

import vertexai
from vertexai import agent_engines
from vertexai.preview import reasoning_engines

from agent.agent import root_agent

# Agent Engine deploys to a concrete region (not "global"); the deployed agent
# still calls Claude on the GOOGLE_CLOUD_REGION endpoint passed via env_vars below.
vertexai.init(
    project=os.environ["GOOGLE_CLOUD_PROJECT"],
    location=os.environ.get("AGENT_ENGINE_LOCATION", "us-central1"),
    staging_bucket=os.environ["STAGING_BUCKET"],
)

# Wrap the ADK agent so Agent Engine can serve it.
app = reasoning_engines.AdkApp(agent=root_agent, enable_tracing=True)

remote_app = agent_engines.create(
    agent_engine=app,
    display_name="bigquery-analyst",
    description="ADK agent: Claude on Vertex + managed BigQuery MCP server.",
    requirements=[
        "google-adk==2.2.0",
        "anthropic[vertex]==0.109.2",
        "mcp==1.28.0",
        "google-cloud-aiplatform[agent_engines]==1.158.0",
    ],
    # Bundle the agent package so Agent Engine can import agent.agent server-side.
    extra_packages=["./agent"],
    # The deployed container needs the config the agent reads at import. Note:
    # GOOGLE_CLOUD_PROJECT / GOOGLE_CLOUD_REGION are RESERVED by Agent Engine (the
    # platform injects them), so we must not pass them here. The Claude endpoint
    # region is forwarded under a non-reserved name (CLAUDE_VERTEX_REGION) so the
    # model call targets it rather than the deploy region.
    env_vars={
        "CLAUDE_MODEL_ID": os.environ["CLAUDE_MODEL_ID"],
        "BQ_MCP_ENDPOINT": os.environ["BQ_MCP_ENDPOINT"],
        "CLAUDE_VERTEX_REGION": os.environ["GOOGLE_CLOUD_REGION"],
    },
    # If the MCP toolset needs a build-time install step, add a script and wire it:
    # build_options={"installation": ["installation_scripts/install_mcp.sh"]},
)

if __name__ == "__main__":
    print("Deployed Agent Engine resource:", remote_app.resource_name)
