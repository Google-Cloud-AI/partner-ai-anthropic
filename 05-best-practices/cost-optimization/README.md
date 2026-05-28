# Cost Optimization

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Techniques for controlling spend when running Claude on Vertex AI: right-sizing model selection, prompt caching, batching, controlling output length, and monitoring usage.

## Prerequisites
- A workload already calling Claude
- Access to billing and monitoring in your GCP project

## What You'll Learn / What This Demonstrates
- Choose the right model for each task
- Apply prompt caching and batching where appropriate
- Constrain output length to reduce token usage
- Monitor and attribute spend

## Quick Start
```bash
# Guidance module. Apply the techniques described here
# to your own workloads and measure with Cloud Billing
# and Vertex AI monitoring.
```

## Architecture
Not applicable — guidance module. Techniques apply across the other modules' workloads.

## Cost Considerations
Token usage is the primary cost driver. Model choice, caching, and output limits have the largest impact.

## References
- [Prompt caching](https://docs.claude.com/en/docs/build-with-claude/prompt-caching)
- [Vertex AI pricing](https://cloud.google.com/vertex-ai/pricing)
