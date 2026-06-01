# Claude Opus 4.8 on the Gemini Enterprise Agent Platform

A hands-on tutorial series showing each **Claude Opus 4.8** capability on the **Gemini Enterprise Agent Platform** (formerly Vertex AI) — one small, runnable notebook per feature. It's aimed at **ISVs and partners** who want to adopt these features fast: start at module 00, then jump to whichever capability you need.

## Core principle

> **Every Claude call routes through the Agent Platform via the `AnthropicVertex` client with ADC auth** — never the first-party Anthropic API, and never an `ANTHROPIC_API_KEY`.

The one deliberate exception is **module 11 (batch)**, which uses the **Vertex batch-job interface via the Google Gen AI SDK**. That still targets Claude on the platform — just through the batch interface rather than the synchronous client.

## Prerequisites

- A **GCP project** with the **Agent Platform / Vertex AI** enabled and **Claude Opus 4.8 enabled in Model Garden**.
- **ADC** configured: `gcloud auth application-default login` (automatic in Cloud Shell / Workbench).
- **Python** with `anthropic[vertex]`.
- **Per-module extras:**
  - Module 02 / 07 — `pillow` (and `matplotlib` for module 02's sample image).
  - Module 03 — `reportlab`.
  - Module 11 — `google-genai`, `google-cloud-storage`, and a **GCS bucket**.

**Conventions:** the model string is `claude-opus-4-8`; `LOCATION` defaults to `global` (module 11 batch uses a **regional** endpoint). **Start with module 00.**

## Module index

| # | Module | What it covers |
|---|--------|----------------|
| 00 | [Setup & logging](00-setup-and-logging.ipynb) | ADC, the `AnthropicVertex` client, request/response logging to BigQuery |
| 01 | [Text generation](01-text-generation.ipynb) | System prompts, multi-turn, generation params, streaming, prefill |
| 02 | [Vision](02-vision.ipynb) | Image inputs |
| 03 | [PDF / document input](03-pdf-document-input.ipynb) | Document inputs |
| 04 | [Function calling](04-function-calling.ipynb) | The local tool-use loop |
| 05 | [Extended thinking](05-extended-thinking.ipynb) | Step-by-step reasoning with a thinking budget |
| 06 | [Web search](06-web-search.ipynb) | Server-side web search tool |
| 07 | [Computer use](07-computer-use.ipynb) | Action loop — plus the Tier-2 environment under [`04-demos/claude-computer-use-env/`](../../04-demos/claude-computer-use-env/) |
| 08 | [Memory tool](08-memory-tool.ipynb) | Cross-conversation persistence |
| 09 | [Prompt caching](09-prompt-caching.ipynb) | Caching a reused prefix |
| 10 | [Count tokens](10-count-tokens.ipynb) | Pre-flight input-token estimation |
| 11 | [Batch predictions](11-batch-predictions.ipynb) | Vertex batch job; GCS/BigQuery I/O; regional endpoint |
| 12 | [Usage types](12-usage-types.ipynb) | Provisioned Throughput & Shared Model Lineage Quota |

## How to run

Open the notebooks in **Colab Enterprise** / **Vertex AI Workbench**, or in **local Jupyter** with **ADC configured**. **Run module 00 first** — it sets up auth and the client conventions every later module relies on.
