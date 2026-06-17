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

"""Thin, importable helpers for talking to the managed BigQuery MCP server.

The managed BigQuery MCP server is a remote, streamable-HTTP MCP endpoint that
authenticates with Google Cloud IAM (OAuth2). It rejects API keys, so we send an
Application Default Credentials (ADC) bearer token obtained from gcloud.

Verified against mcp==1.28.0:
  - streamablehttp_client(url, headers=...) yields (read, write, get_session_id)
  - ClientSession.initialize / list_tools / call_tool are coroutines
"""

import os
import subprocess
from contextlib import asynccontextmanager

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


def bearer_token() -> str:
    """Return an ADC access token via gcloud (the BQ MCP server rejects API keys).

    Uses Application Default Credentials specifically: tool *execution* runs a
    BigQuery job server-side, which requires a cloud-platform-scoped token. A
    plain `gcloud auth print-access-token` may lack that scope and is rejected by
    BigQuery with HTTP 401 even though the MCP gateway accepts it for metadata.
    """
    return subprocess.check_output(
        ["gcloud", "auth", "application-default", "print-access-token"], text=True
    ).strip()


@asynccontextmanager
async def bq_mcp_session(endpoint: str | None = None, token: str | None = None):
    """Open an initialized MCP ClientSession against the managed BigQuery MCP endpoint.

    Args:
        endpoint: MCP URL. Defaults to the BQ_MCP_ENDPOINT environment variable so
            nothing is hardcoded in committed source.
        token: Bearer token. Defaults to a fresh ADC token from gcloud.

    Yields:
        An initialized mcp.ClientSession ready for list_tools() / call_tool().
    """
    endpoint = endpoint or os.environ["BQ_MCP_ENDPOINT"]
    headers = {"Authorization": f"Bearer {token or bearer_token()}"}
    # streamablehttp_client returns a 3-tuple; the third value is a session-id getter.
    async with streamablehttp_client(endpoint, headers=headers) as (read, write, _get_session_id):
        async with ClientSession(read, write) as session:
            await session.initialize()
            yield session


async def list_tool_names(session) -> list[str]:
    """Return the names of every tool the MCP server exposes."""
    resp = await session.list_tools()
    return [tool.name for tool in resp.tools]


async def call_tool(session, name: str, arguments: dict):
    """Call one MCP tool by name and return the raw CallToolResult."""
    return await session.call_tool(name, arguments)
