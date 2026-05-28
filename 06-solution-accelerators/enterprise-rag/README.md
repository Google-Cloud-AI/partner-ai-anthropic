# Enterprise RAG

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

## Overview
A retrieval-augmented generation blueprint using Claude on Vertex AI as the reasoning model, with BigQuery and/or AlloyDB as the knowledge store for grounding responses in enterprise data.

## Prerequisites
- Completed the tutorials section
- A BigQuery dataset and/or AlloyDB instance with your corpus

## What You'll Learn / What This Demonstrates
- Design a RAG pipeline grounded in BigQuery / AlloyDB
- Embed and retrieve relevant context
- Ground Claude's responses and cite sources
- Reason about freshness, chunking, and retrieval quality

## Quick Start
```bash
# Blueprint module. See the architecture and the reference
# pipeline described here; adapt connectors to your data.
```

## Architecture
A retrieval layer over BigQuery and/or AlloyDB feeding grounded context to Claude on Vertex AI, with an application tier orchestrating retrieval and generation.

## Cost Considerations
Costs span per-token Claude calls, embedding generation, BigQuery query/storage, and AlloyDB instance time. Retrieval volume drives most variable cost.

## References
- [BigQuery](https://cloud.google.com/bigquery/docs)
- [AlloyDB](https://cloud.google.com/alloydb/docs)
- [Anthropic on Vertex AI](https://docs.claude.com/en/api/claude-on-vertex-ai)
