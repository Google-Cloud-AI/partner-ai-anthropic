# MCP Integration

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Connect Claude to external systems through the Model Context Protocol (MCP). Covers the protocol basics and a worked example wiring Claude to an MCP server.

## Prerequisites
- Completed [tool-use-with-claude](../tool-use-with-claude/)
- An MCP server to connect to (sample provided)

## What You'll Learn / What This Demonstrates
- Understand what MCP provides over hand-rolled tool use
- Connect a client to an MCP server
- Expose MCP tools to Claude and handle results

## Quick Start
```bash
# Start a sample MCP server, then point your client at it.
# See the example in this module for the full flow.
```

## Architecture
A Claude client connected to one or more MCP servers. Each server exposes tools and resources over the protocol; Claude invokes them through the standard tool-use mechanism.

## Cost Considerations
Per-token billing for model calls. Any cost of the MCP server itself depends on where you host it.

## References
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [MCP with Claude](https://docs.claude.com/en/docs/mcp)
