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

"""Hand-rolled MCP <-> Claude tool loop.

Claude on Vertex AI does NOT support Anthropic's native `mcp_servers` connector,
so we are the connector: discover MCP tools, translate them into Claude's tool
schema, dispatch each tool_use over the MCP session, feed results back, and loop
until Claude stops asking for tools.

Verified against mcp==1.28.0 / anthropic==0.109.2:
  - MCP Tool exposes .name / .description / .inputSchema (camelCase)
  - MCP CallToolResult exposes .content (list) / .isError
  - Claude tool schema wants input_schema (snake_case)
"""


def translate_tools(mcp_tools) -> list[dict]:
    """Translate MCP tool definitions into Claude tool-use definitions.

    The only field that needs renaming is MCP's `inputSchema` (camelCase) into
    Claude's `input_schema` (snake_case); both are JSON Schema, so the value is
    passed through unchanged.
    """
    return [
        {
            "name": tool.name,
            "description": tool.description or "",
            "input_schema": tool.inputSchema,
        }
        for tool in mcp_tools
    ]


def _result_to_text(call_result) -> tuple[str, bool]:
    """Flatten an MCP CallToolResult into (text, is_error) for a Claude tool_result."""
    parts = [
        block.text
        for block in call_result.content
        if getattr(block, "type", None) == "text"
    ]
    return "\n".join(parts), bool(call_result.isError)


async def run_bridge(client, session, model, query, *, max_tokens=1024, max_turns=10):
    """Drive the agentic loop between Claude-on-Vertex and an MCP session.

    Args:
        client: an anthropic.AnthropicVertex instance (sync SDK).
        session: an initialized mcp.ClientSession (see src.mcp_client.bq_mcp_session).
        model: the Vertex Claude model id, e.g. "claude-opus-4-8".
        query: the natural-language user question.

    Returns:
        (final_answer_text, trace) where trace is a list of (kind, payload) tuples
        capturing each tool_use request, tool_result, and the final answer so the
        notebook can print the full exchange.
    """
    # 1. Discover MCP tools and translate them into Claude's tool schema.
    tools = translate_tools((await session.list_tools()).tools)

    messages = [{"role": "user", "content": query}]
    trace = []

    for _turn in range(max_turns):
        # 2. Ask Claude on Vertex, advertising the MCP tools.
        #    NOTE: AnthropicVertex is a synchronous client; calling it inside this
        #    async function blocks the event loop. Fine for a single-user tutorial;
        #    a server would offload it (e.g. anyio.to_thread.run_sync).
        resp = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            tools=tools,
            messages=messages,
        )
        messages.append({"role": "assistant", "content": resp.content})

        # 3. If Claude is done asking for tools, return the final text answer.
        if resp.stop_reason != "tool_use":
            final = "".join(b.text for b in resp.content if b.type == "text")
            trace.append(("final", final))
            return final, trace

        # 4. Otherwise run each requested tool over MCP and append the results.
        tool_results = []
        for block in resp.content:
            if block.type == "tool_use":
                trace.append(("tool_use", {"name": block.name, "input": block.input}))
                call_result = await session.call_tool(block.name, block.input)
                text, is_error = _result_to_text(call_result)
                trace.append(
                    ("tool_result", {"name": block.name, "text": text, "is_error": is_error})
                )
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": text,
                        "is_error": is_error,
                    }
                )
        messages.append({"role": "user", "content": tool_results})

    raise RuntimeError(f"Bridge did not converge within {max_turns} turns")
