# Multi-Region Endpoints

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Configure and use Claude multi-region endpoints on Vertex AI. Explains why multi-region routing matters for availability and quota, and how to set the region for your clients.

## Prerequisites
- Completed [vertex-ai-setup](../vertex-ai-setup/)
- Quota granted for the target Claude models in the relevant regions

## What You'll Learn / What This Demonstrates
- Understand the difference between regional and `global` endpoints
- Configure the region for SDK and Claude Code clients
- Diagnose quota and availability errors related to region selection

## Quick Start
```bash
# Route through the global endpoint
export CLOUD_ML_REGION=global

# Or target a specific region
export CLOUD_ML_REGION=us-east5
```

## Architecture
Client requests are routed to Claude models hosted across one or more Vertex AI regions. Using `global` lets Vertex AI manage routing; pinning a region gives explicit control.

## Cost Considerations
No infrastructure cost. Per-token billing applies. Be aware that quota is granted per model per region — preflight failures often trace to a missing regional quota.

## References
- [Anthropic on Vertex AI](https://docs.claude.com/en/api/claude-on-vertex-ai)
- [Vertex AI locations](https://cloud.google.com/vertex-ai/docs/general/locations)
