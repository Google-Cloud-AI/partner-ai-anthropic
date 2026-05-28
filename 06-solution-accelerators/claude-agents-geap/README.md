# Claude Agents on GEAP

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
A production-oriented blueprint for packaging Claude-powered agents and registering them to the Gemini Enterprise Agent Platform (GEAP), including discovery and governance considerations.

## Prerequisites
- A working Claude-backed agent (see [adk-claude-agent](../../03-quick-starts/adk-claude-agent/))
- Access to register agents in your Gemini Enterprise environment

## What You'll Learn / What This Demonstrates
- Package an agent for registration
- Register and make an agent discoverable in GEAP
- Apply governance and access controls to published agents

## Quick Start
```bash
# Blueprint module. Follow the packaging and registration
# steps described here, adapting to your environment.
```

## Architecture
Claude-backed agents (built with ADK or directly) deployed to a managed runtime and registered to the Gemini Enterprise Agent Platform for discovery and governed access.

## Cost Considerations
Costs include per-token model calls plus any managed runtime (e.g. Vertex AI Agent Engine, Cloud Run) hosting the agents.

## References
- [Agent Development Kit](https://google.github.io/adk-docs/)
- [Vertex AI Agent Engine](https://cloud.google.com/vertex-ai/generative-ai/docs/agent-engine/overview)
