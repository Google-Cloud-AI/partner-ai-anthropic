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

"""ADK agent that uses Claude on Vertex with the managed BigQuery MCP server.

This collapses the hand-rolled loop from notebook 03 into a declarative agent:
ADK discovers the MCP tools, advertises them to Claude, and runs the tool loop.

GOTCHA (Agent Engine): the agent and its MCPToolset MUST be constructed
synchronously at import time. Agent Engine imports this module and cannot
initialize an async toolset factory during the build, so everything below runs
at module load. See deploy/deploy_agent_engine.py.

GOTCHA (deployed identity): running this agent locally uses your end-user (ADC)
identity, which the managed BigQuery MCP server authorizes. Deployed to Agent
Engine it runs as the runtime *service account*, and the managed MCP server
currently returns HTTP 403 for that service-account identity even with
`mcp.toolUser` + BigQuery roles granted. See the README "Remote MCP from inside
Agent Engine" gotcha. The local path is verified; treat the deploy as a
structural reference.
"""

import os

import google.auth
import google.auth.transport.requests
import httpx
from google.adk.agents import LlmAgent
from google.adk.models.anthropic_llm import Claude
from google.adk.models.registry import LLMRegistry
from google.adk.tools.mcp_tool import MCPToolset, StreamableHTTPConnectionParams

# Region for Claude-on-Vertex calls, kept independent of the Agent Engine deploy
# region. In a deployed container the platform may inject GOOGLE_CLOUD_REGION as
# the deploy region (e.g. us-central1), so we force the Claude endpoint to
# CLAUDE_VERTEX_REGION (default "global") and don't let the model follow it.
_CLAUDE_REGION = (
    os.environ.get("CLAUDE_VERTEX_REGION")
    or os.environ.get("GOOGLE_CLOUD_REGION")
    or "global"
)
os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "TRUE"
os.environ["GOOGLE_CLOUD_LOCATION"] = _CLAUDE_REGION
os.environ["CLOUD_ML_REGION"] = _CLAUDE_REGION
_project = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
if _project:
    os.environ.setdefault("ANTHROPIC_VERTEX_PROJECT_ID", _project)

# Register the native Claude model so LlmAgent accepts "claude-*" ids on Vertex.
# The Claude class talks to Vertex via AnthropicVertex and ADC (no API key).
LLMRegistry.register(Claude)


# Authenticate the MCP transport with Application Default Credentials, refreshed
# at request time. This works both locally (your gcloud ADC) and inside Agent
# Engine (the runtime service-account identity from the metadata server), and it
# never shells out to gcloud -- which is absent in the deployed container. The
# BigQuery MCP server rejects API keys and needs a cloud-platform-scoped token.
_SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]
_CREDENTIALS, _ = google.auth.default(scopes=_SCOPES)
_AUTH_REQUEST = google.auth.transport.requests.Request()


class _GoogleADCAuth(httpx.Auth):
    """Inject a fresh ADC bearer token on every request (refreshes on expiry)."""

    def auth_flow(self, request):
        if not _CREDENTIALS.valid:
            _CREDENTIALS.refresh(_AUTH_REQUEST)
        request.headers["Authorization"] = f"Bearer {_CREDENTIALS.token}"
        yield request


def _mcp_http_client_factory(headers=None, timeout=None, auth=None) -> httpx.AsyncClient:
    """Build the httpx client the MCP transport uses, authenticated via ADC."""
    return httpx.AsyncClient(
        headers=headers,
        timeout=timeout if timeout is not None else httpx.Timeout(60.0),
        auth=_GoogleADCAuth(),
        follow_redirects=True,
    )


# Built synchronously at import time (Agent Engine requires this; see GOTCHA).
bigquery_mcp = MCPToolset(
    connection_params=StreamableHTTPConnectionParams(
        url=os.environ["BQ_MCP_ENDPOINT"],
        httpx_client_factory=_mcp_http_client_factory,
    ),
    # tool_filter=[...],  # In production, restrict to the read-only tools you need.
)

root_agent = LlmAgent(
    model=os.environ["CLAUDE_MODEL_ID"],
    name="bigquery_analyst",
    instruction=(
        "You answer questions about BigQuery public datasets using the BigQuery "
        "MCP tools. Run BigQuery jobs in project "
        f"'{os.environ.get('GOOGLE_CLOUD_PROJECT', '')}' using the "
        "execute_sql_readonly tool, and cite the dataset you queried."
    ),
    tools=[bigquery_mcp],
)
