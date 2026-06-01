# 01 — Getting Started

> ⚠️ **Use at your own risk.** See [root disclaimer](../README.md).

Set up everything you need to run Claude on Google Cloud: project and IAM configuration, Claude Code, and multi-region endpoints on Vertex AI.

| Module | Description |
|---|---|
| [`vertex-ai-setup/`](./vertex-ai-setup/) | Enable Vertex AI, configure IAM, request access to Claude models |
| [`claude-code-setup/`](./claude-code-setup/) | Install and configure Claude Code against Vertex AI or the Anthropic API |
| [`multi-region-endpoints/`](./multi-region-endpoints/) | Configure Claude multi-region endpoints for availability and quota |

**Recommended order:** `vertex-ai-setup` → `claude-code-setup` → `multi-region-endpoints`.

**Next:** once you're set up, work through the [`claude-on-agent-platform`](../02-tutorials/claude-on-agent-platform/) tutorial series — begin with **module 00 (setup & logging)**.
