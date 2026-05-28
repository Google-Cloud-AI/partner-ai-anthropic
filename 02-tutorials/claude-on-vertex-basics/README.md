# Claude on Vertex AI — Basics

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Make your first calls to Claude on Vertex AI. Covers the messages API, model identifiers, request structure, and streaming responses.

## Prerequisites
- Completed the getting-started setup
- Python 3.11+ with the Anthropic SDK installed

## What You'll Learn / What This Demonstrates
- Construct a basic messages request to Claude on Vertex AI
- Select the correct model string
- Read both complete and streamed responses
- Handle common request parameters (max_tokens, system prompt)

## Quick Start
```bash
pip install 'anthropic[vertex]'
python - <<'PY'
from anthropic import AnthropicVertex
client = AnthropicVertex(region="global", project_id="YOUR_PROJECT")
msg = client.messages.create(
    model="claude-opus-4-6",
    max_tokens=512,
    messages=[{"role": "user", "content": "Hello from Vertex AI"}],
)
print(msg.content[0].text)
PY
```

## Architecture
A local client calling Claude on Vertex AI through the Anthropic Vertex SDK. No server-side components are deployed.

## Cost Considerations
Per-token billing on Vertex AI. Keep `max_tokens` modest while experimenting.

## References
- [Messages API](https://docs.claude.com/en/api/messages)
- [Anthropic on Vertex AI](https://docs.claude.com/en/api/claude-on-vertex-ai)
