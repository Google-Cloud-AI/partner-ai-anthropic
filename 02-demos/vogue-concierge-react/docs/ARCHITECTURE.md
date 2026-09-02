<!-- Copyright 2026 The "Anthropic on Google Cloud" Authors -->

# Vogue Concierge — System Architecture & Multi-Agent Design

This document provides a comprehensive technical overview of the **Vogue Concierge** multi-agent retail platform built on **Google Cloud Platform (GCP)** and powered by **Anthropic Claude models** via **Agent Platform Model Garden**.

---

## 🏛️ System Architecture Diagram

![Vogue Concierge Architecture](architecture.png)

---

## 1. Executive Summary

Vogue Concierge is an enterprise AI luxury boutique concierge platform. The application combines:
* **Frontend UI:** A Next.js / React storefront (`/ui`).
* **FastAPI Backend Relay:** A Python FastAPI server (`app.py`) running on Google Cloud Run that handles REST/SSE chat streaming, user session management, and transactional database actions.
* **Agent Runtime:** A multi-agent ecosystem hosted on **Agent Runtime** using **Google Agent Development Kit (ADK)** and the official Anthropic SDK (`anthropic[vertex]`).
* **Data Layer:** A dual data architecture separating unstructured semantic search (**Agent Platform RAG Engine**) from structured database transactions (**Google BigQuery**).

---

## 2. Multi-Agent Orchestration Strategy

The system utilizes a **Hub-and-Spoke Orchestrator** pattern:

```
[ User / React UI ]
        │
        ▼ (REST / SSE)
 [ FastAPI Relay ]
        │
        ▼ (Agent Runtime Event Stream)
 [ Lead Orchestrator (Sonnet 5) ]
        │
        ├─────── Tool_call (Sequential) ───────┐
        ▼                                       ▼
  Style Advisor                      Inventory & Pricing                  Returns & Care
   (Opus 5)                            (Haiku 4.5)                       (Haiku 4.5)
```

### Key Orchestration Behaviors:
* **Hub-and-Spoke Hierarchy:** The Lead Orchestrator (`vogue_concierge`) receives incoming customer queries and delegates work to specialized sub-agents using ADK `AgentTool` definitions (native tool calls).
* **Sequential Turn Execution:** Inter-agent communication is sequential per conversation turn. Specialists return their findings back to the Orchestrator, which maintains a unified, polished concierge voice.
* **Parallel Tool Execution:** Within an individual specialist's execution loop, the underlying Claude model can issue parallel tool calls (e.g., querying product catalog and fashion trends simultaneously).

---

## 3. Agent Roster & Model-per-Agent Strategy

Each agent runs on the Claude model tier best optimized for its specific workload:

| Agent Name | LLM Model Tier | Assigned Tools | Functional Responsibility |
| :--- | :--- | :--- | :--- |
| **Vogue Concierge**<br>*(Lead Orchestrator)* | `claude-sonnet-5` | • `AgentTool(Style)`<br>• `AgentTool(Inventory)`<br>• `AgentTool(Returns)`<br>• Signal Tools (`place_order`, `check_stock`, `check_loyalty`, `quote_order`, `get_order`, `enroll_loyalty`) | Primary entry point. Handles greetings, maintains concierge voice, delegates to specialists, and manages top-level checkout signals. |
| **Style Advisor** | `claude-opus-5`<br>*(Effort: High)* | • `catalog_search`<br>• `trend_search` | Expert fashion stylist. Handles outfit composition, style trends, and personalized recommendations using high reasoning. |
| **Inventory & Pricing** | `claude-haiku-4-5` | • `catalog_search`<br>• `check_inventory` (MCP Toolbox → BigQuery)<br>• `get_loyalty_discount` (MCP Toolbox → BigQuery) | Fast, deterministic lookups for product specifications, catalog pricing, live per-size stock, and loyalty tier. |
| **Returns & Care** | `claude-haiku-4-5` | • `catalog_search` | Garment policy, returns, exchanges, and material-specific care advice. |

---

## 4. Data Plane Architecture: RAG vs. BigQuery

The architecture strictly delineates unstructured vector search from structured relational queries:

```
                          ┌──────────────────────────┐
                          │   Agent Platform RAG Engine   │
                          │  (Catalog Copy & Trends) │
                          └────────────▲─────────────┘
                                       │
                                       │ (Semantic Vector Queries)
                                       │
┌─────────────────────────┐   ┌────────┴─────────┐   ┌─────────────────────────┐
│   Style Advisor Agent   │   │ Inventory Agent  │   │  Returns & Care Agent   │
└─────────────────────────┘   └────────┬─────────┘   └─────────────────────────┘
                                       │
                                       │ (ToolboxToolset — HTTP + ID token)
                                       ▼
                          ┌──────────────────────────┐
                          │    MCP Toolbox Service   │
                          │  (Cloud Run, private)    │
                          └────────────┬─────────────┘
                                       │
                                       │ (SQL)
                                       ▼
                          ┌──────────────────────────┐
                          │     Google BigQuery      │
                          │ (Orders/Stock/Loyalty)   │
                          └──────────────────────────┘
```

### 1. Agent Platform RAG Engine
* **Purpose:** Stores vector embeddings of unstructured text assets, including seasonal trend reports (`trend_report.md`) and product catalog descriptions (`products.json`).
* **Access:** Accessed via python tool functions (`catalog_search` and `trend_search`) in all three specialist agents, which retrieve through the shared `agents/tools/rag_retrieval.py` helper via `agentplatform.rag.retrieval_query`.

### 2. MCP Toolbox Cloud Run Service (`vogue-toolbox`)
* **Purpose:** A standalone Cloud Run microservice exposing Model Context Protocol (MCP) tool endpoints. The SQL is declared in `toolbox/tools.yaml`, so the queries are fixed server-side and the model only supplies bound parameters.
* **Access:** Used by `inventory_specialist` (via `toolbox_adk.ToolboxToolset`) to execute parameterized SQL lookups against the BigQuery `inventory` and `loyalty_program` tables.
* **Security:** The service is deployed **private** (`--no-allow-unauthenticated`). `CredentialStrategy.workload_identity` mints a Google-signed ID token for the service URL from the caller's ADC — the Agent Runtime service agent (`service-<project-number>@gcp-sa-aiplatform-re.iam.gserviceaccount.com`) in production, or the developer's own credentials for a local `adk web` run. That identity holds `roles/run.invoker` on the service. The toolbox itself runs as a dedicated least-privilege service account (`vogue-toolbox-sa`) with only `bigquery.dataViewer` + `bigquery.jobUser` — it can read the two tables and nothing else.

### 3. Signal / Execute Pattern (`checkout.py`)
* **Purpose:** Executes transactional orders and account updates outside the agent.
* **Access:** Reads reach BigQuery from the agent itself, through the Toolbox above. The transactional path is separated on purpose, for two reasons: money-moving logic — discount maths, payment, the order row — stays off the model and runs as ordinary deterministic server code, and the storefront needs the outcome in order to render a confirmation. So `place_order`, `check_stock`, `check_loyalty`, `quote_order`, `get_order`, and `enroll_loyalty` emit **signals** in the event stream; the FastAPI relay on Cloud Run intercepts them and executes the real BigQuery work via `checkout.py`.
* **Payment is mocked — this is the one step that is not real.** The discount, the order row and the points are genuine BigQuery writes, but there is no PSP behind the charge: `checkout.py` displays a stand-in card (`MOCK_CARD = "Visa •••• 4242"`), mints a `payment_id`, and writes `payment_status = "paid"` unconditionally, so every order succeeds. Nobody is asked for card details. A production build has to add a real provider, and the deterministic server layer described here is exactly where that integration belongs — with one caveat about the boundary: the card must be tokenised **in the browser** by the provider's SDK, never typed into the chat, or the number ends up in the Agent Runtime session transcript and the Cloud Run logs. Only the token should cross into this layer; only the brand, last four digits and charge id should be persisted. See the README's *"Payment is simulated"* section for the full checklist.
