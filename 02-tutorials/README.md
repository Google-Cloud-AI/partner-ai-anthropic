# 02 — Tutorials

> ⚠️ **Use at your own risk.** See [root disclaimer](../README.md).

Step-by-step learning modules covering the core patterns for building with Claude on Google Cloud.

| Module | Description |
|---|---|
| [`tool-use-with-claude/`](./tool-use-with-claude/) | Defining tools and running the tool-use loop |
| [`mcp-integration/`](./mcp-integration/) | Connecting Claude to MCP servers: a worked example wiring Claude on Vertex to Google's managed BigQuery MCP server, by hand and with ADK / Agent Engine |
| [`claude-on-agent-platform/`](./claude-on-agent-platform/) | One small notebook per Claude Opus 4.8 capability on the Agent Platform (modules 00–12) — setup & logging, text, vision, PDF, tool use, extended thinking, web search, computer use, memory, prompt caching, token counting, batch, usage types |

**Recommended order:** `tool-use-with-claude` → `mcp-integration`. For setup and a complete per-feature reference, see [`claude-on-agent-platform`](./claude-on-agent-platform/).
