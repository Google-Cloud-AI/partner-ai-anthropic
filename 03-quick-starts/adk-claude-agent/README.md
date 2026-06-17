# Quick Start — ADK + Claude Agent

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Build and run a minimal Google Agent Development Kit (ADK) agent backed by Claude, locally. A starting point for agentic patterns before deploying to managed runtimes.

## Prerequisites
- Completed [claude-on-agent-platform module 00 (setup & first call)](../../02-tutorials/claude-on-agent-platform/00-setup-and-logging.ipynb)
- Python 3.11+ and the ADK installed

## What You'll Learn / What This Demonstrates
- Define a simple ADK agent that uses Claude as its model
- Register a tool with the agent
- Run the agent locally and inspect its turns

## Quick Start
```bash
pip install google-adk
# See the example agent in this module, then run it locally
# with the ADK runner.
```

## Architecture
A local ADK agent using Claude on Vertex AI as its model backend. No managed runtime is provisioned in this quick start.

## Cost Considerations
Per-token billing for model calls. Local execution has no additional infrastructure cost.

## References
- [Agent Development Kit](https://google.github.io/adk-docs/)
- [Anthropic on Vertex AI](https://docs.claude.com/en/api/claude-on-vertex-ai)
