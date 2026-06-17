# Tool Use with Claude

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Give Claude the ability to call tools. Covers declaring tool schemas, interpreting tool-use requests, executing them, and returning results so Claude can complete the loop.

## Prerequisites
- Completed [claude-on-agent-platform module 00 (setup & first call)](../claude-on-agent-platform/00-setup-and-logging.ipynb)
- Familiarity with JSON schema

## What You'll Learn / What This Demonstrates
- Define tools with input schemas
- Detect and parse `tool_use` blocks in responses
- Return `tool_result` content back to Claude
- Run a multi-turn tool-use loop to completion

## Quick Start
```bash
# See the runnable example in this module.
# Core loop: send tools -> receive tool_use -> execute ->
# return tool_result -> repeat until stop.
```

## Architecture
A local client and one or more local tool functions. Claude decides when to call a tool; your code executes it and returns the result.

## Cost Considerations
Per-token billing. Tool-use conversations are multi-turn, so token usage accumulates across the loop.

## References
- [Tool use](https://docs.claude.com/en/docs/build-with-claude/tool-use)
