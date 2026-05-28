# Quick Start — Claude Code

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Get a working Claude Code session against Claude on Vertex AI in a few minutes. The fastest path from zero to a productive coding session.

## Prerequisites
- Completed [claude-code-setup](../../01-getting-started/claude-code-setup/)
- A project directory to work in

## What You'll Learn / What This Demonstrates
- Launch Claude Code pointed at Vertex AI
- Run a first task end to end
- Understand session basics and configuration overrides

## Quick Start
```bash
export CLAUDE_CODE_USE_VERTEX=1
export CLOUD_ML_REGION=global
export ANTHROPIC_VERTEX_PROJECT_ID="$PROJECT_ID"
cd your-project && claude
```

## Architecture
Claude Code running locally, routing to Claude on Vertex AI via Application Default Credentials.

## Cost Considerations
Per-token billing for model calls made during the session.

## References
- [Claude Code documentation](https://docs.claude.com/en/docs/claude-code)
