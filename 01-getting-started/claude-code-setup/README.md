# Claude Code Setup

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Install and configure Claude Code, and point it at either Claude on Vertex AI or the Anthropic direct API. Covers authentication and the environment variables that control model routing.

## Prerequisites
- Node.js 20+ installed
- Completed [vertex-ai-setup](../vertex-ai-setup/) if using Vertex AI
- `gcloud` authenticated for Application Default Credentials

## What You'll Learn / What This Demonstrates
- Install Claude Code
- Authenticate against Vertex AI or the Anthropic API
- Configure the region and model environment variables
- Verify the setup with a first session

## Quick Start
```bash
npm install -g @anthropic-ai/claude-code
export CLAUDE_CODE_USE_VERTEX=1
export CLOUD_ML_REGION=global
export ANTHROPIC_VERTEX_PROJECT_ID="$PROJECT_ID"
claude
```

## Architecture
Claude Code runs locally and routes model calls to Claude on Vertex AI (or the Anthropic API). Authentication to Vertex AI uses Application Default Credentials.

## Cost Considerations
No cost to install. Model calls during sessions are billed per token via your chosen backend.

## References
- [Claude Code documentation](https://docs.claude.com/en/docs/claude-code)
- [Claude Code on Vertex AI](https://docs.claude.com/en/docs/claude-code/google-vertex-ai)
