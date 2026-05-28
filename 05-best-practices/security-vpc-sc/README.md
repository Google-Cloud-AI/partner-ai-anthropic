# Security & VPC Service Controls

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
Run Claude on Vertex AI inside a secured perimeter. Covers VPC Service Controls perimeter design, private connectivity, and data-governance considerations for enterprise deployments.

## Prerequisites
- A GCP organization with the ability to configure VPC Service Controls
- Completed [vertex-ai-setup](../../01-getting-started/vertex-ai-setup/)

## What You'll Learn / What This Demonstrates
- Design a service perimeter that includes Vertex AI
- Restrict egress and enforce private access
- Reason about data residency and governance for model traffic

## Quick Start
```bash
# Guidance module. Perimeter and access-policy configuration
# is environment-specific — see the design notes in this README.
```

## Architecture
A VPC Service Controls perimeter enclosing Vertex AI and related services, with private connectivity from your workloads.

## Cost Considerations
VPC-SC itself has no per-use charge. Underlying Vertex AI calls are billed per token as usual.

## References
- [VPC Service Controls](https://cloud.google.com/vpc-service-controls/docs)
- [Vertex AI security](https://cloud.google.com/vertex-ai/docs/general/vpc-service-controls)
