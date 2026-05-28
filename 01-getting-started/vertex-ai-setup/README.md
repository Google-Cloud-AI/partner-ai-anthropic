# Vertex AI Setup

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Prepare a Google Cloud project to run Claude on Vertex AI. Covers enabling the Vertex AI API, configuring IAM, selecting regions, and requesting access to Claude models in Model Garden.

## Prerequisites
- A Google Cloud project with billing enabled
- `gcloud` CLI installed and authenticated
- Owner or equivalent IAM on the project for initial setup

## What You'll Learn / What This Demonstrates
- Enable the Vertex AI API and required services
- Assign the IAM roles needed to call Claude models
- Request and confirm access to Claude in Vertex AI Model Garden
- Choose an appropriate region for your workloads

## Quick Start
```bash
gcloud services enable aiplatform.googleapis.com
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:you@example.com" \
  --role="roles/aiplatform.user"
```

## Architecture
A single Google Cloud project with the Vertex AI API enabled. Claude models are served through Vertex AI Model Garden; no GPUs are provisioned by you for inference.

## Cost Considerations
Vertex AI model calls are billed per token. There is no standing infrastructure cost for enabling the API — you pay for what you call.

## References
- [Anthropic on Vertex AI](https://docs.claude.com/en/api/claude-on-vertex-ai)
- [Vertex AI documentation](https://cloud.google.com/vertex-ai/docs)
