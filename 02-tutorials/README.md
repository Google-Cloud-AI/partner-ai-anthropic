# 02 — Tutorials

> ⚠️ **Use at your own risk.** See [root disclaimer](../README.md).

Step-by-step learning modules covering the core patterns for building with Claude on Google Cloud.

| Module | Description |
|---|---|
| [`claude-on-vertex-basics/`](./claude-on-vertex-basics/) | First calls to Claude on Vertex AI: messages API, model strings, streaming |
| [`tool-use-with-claude/`](./tool-use-with-claude/) | Defining tools and running the tool-use loop |
| [`mcp-integration/`](./mcp-integration/) | Connecting Claude to MCP servers: a worked example wiring Claude on Vertex to Google's managed BigQuery MCP server, by hand and with ADK / Agent Engine |
| [`claude-on-agent-platform/`](./claude-on-agent-platform/) | One small notebook per Claude Opus 4.8 capability on the Agent Platform (modules 00–12) — setup & logging, text, vision, PDF, tool use, extended thinking, web search, computer use, memory, prompt caching, token counting, batch, usage types |

**Recommended order:** `claude-on-vertex-basics` → `tool-use-with-claude` → `mcp-integration`. For a complete per-feature reference, see [`claude-on-agent-platform`](./claude-on-agent-platform/).
