# Vogue Concierge — AI Boutique (Claude on Agent Platform, React edition)

An elite AI fashion concierge built with **Claude models on Agent Platform**,
**Google ADK**, and **Agent Runtime**, fronted by a **React**
storefront.

This is an Anthropic + Google "better together" build: Claude does the reasoning,
Google Cloud provides the runtime (Agent Runtime), retrieval (Vertex RAG), and
structured data (BigQuery).

> **This demo is the React-only build.** It serves the concierge through a React
> UI and a FastAPI relay. A separate build adds a **Gemini Enterprise** surface
> (A2A + inline A2UI cards) on top of the same agent team.

## Quickstart — one command

The fastest path is the interactive installer. It deploys the whole thing into
**your own** Google Cloud project: it collects your config, enables APIs, seeds
the data plane (catalog images, BigQuery, RAG), and deploys the MCP Toolbox, the
agent team, and the React UI — capturing every generated id into `.env` as it goes.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://console.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/Google-Cloud-AI/partner-ai-anthropic.git&cloudshell_git_branch=main&cloudshell_workspace=02-demos/vogue-concierge-react&cloudshell_tutorial=02-demos/vogue-concierge-react/README.md)

```bash
# In Cloud Shell (or any machine with gcloud + python3), from this demo's
# directory (02-demos/vogue-concierge-react):
./bootstrap.sh
```

The installer is **interactive and safe to re-run** — each step is idempotent, so
if something fails (a missing model, a quota bump) you fix it and run it again to
resume. The one thing it can't automate and will pause to walk you through is
enabling the Claude + image models in Agent Platform Model Garden.

Prefer to run the steps yourself? See [Manual setup](#manual-setup) below.

## Architecture

![Vogue Concierge Agent Architecture](docs/architecture.png)

> For a detailed technical deep dive into the multi-agent design, tools, and data flows, see [**docs/ARCHITECTURE.md**](docs/ARCHITECTURE.md).

```
React UI ──FastAPI (Cloud Run)──▶  Agent Runtime
                                        │
                                Orchestrator  (Claude Sonnet 5)
                                   ├─ Style Advisor       (Claude Opus 5)
                                   ├─ Inventory & Pricing  (Claude Haiku 4.5)
                                   └─ Returns & Care        (Claude Haiku 4.5)
                                        │
                          Vertex RAG · BigQuery (MCP Toolbox) · Catalog (GCS)
```

The **React UI** talks to `app.py` (REST/SSE) on Cloud Run, which relays to the
agent team on Agent Runtime.

## The right model for the right agent

Each agent runs on the Claude model that fits its job (configured in
`agents/config.py`, overridable by env var):

| Agent | Model | Why |
|---|---|---|
| Orchestrator / Concierge | `claude-sonnet-5` | Fast, excellent tool routing + a consistent concierge voice, `effort=medium` |
| Style Advisor | `claude-opus-5` | Deepest taste and trend reasoning (the showpiece), `effort=high` |
| Inventory & Pricing | `claude-haiku-4-5` | Fast, cheap, deterministic stock/price lookups |
| Returns & Care | `claude-haiku-4-5` | Quick policy answers and garment-care advice |

Sonnet 5 and Opus 5 have extended thinking on by default and default to `high`
effort, so both are set explicitly — `medium` on the orchestrator, which routes
and relays rather than reasons deeply, and `high` on the Style Advisor. Haiku 4.5
does not take an effort setting.

Claude runs on Agent Platform via `AnthropicVertex`, authenticated with Google
Application Default Credentials — **there is no Anthropic API key**.

## Prerequisites

You deploy this into **your own** Google Cloud project. Nothing here ships with
working defaults — the scripts fail fast until you configure the values below.

**1. Google Cloud project**
- A GCP project with **billing enabled**, and the `gcloud` CLI installed and
  initialized (`gcloud init`).
- Note your **project id** and **project number**
  (`gcloud projects describe <id> --format="value(projectNumber)"`).

**2. Enable APIs**
```bash
gcloud services enable \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  --project "$VERTEXAI_PROJECT"
```

**3. Claude on Agent Platform (Model Garden + quota)**
- In **Agent Platform → Model Garden**, enable each Claude model you use: **Sonnet
  5**, **Opus 5**, and **Haiku 4.5**.
- Confirm you have **quota** for them. `CLAUDE_VERTEX_REGION=global` routes to
  available capacity and is recommended; regional endpoints may lack Opus 5
  quota until you request an increase.

**4. Gemini 3.1 Flash Image (required)**
- `scripts/setup_catalog.py` generates the 30 product images with
  **`gemini-3.1-flash-image`** on Agent Platform, which must be
  **enabled/allowlisted** for your project. Without
  it, catalog setup will not complete — this is a hard requirement, not optional.

**5. Authentication & IAM**
- `gcloud auth application-default login` (ADC — no API keys anywhere).
- The identity running setup/deploy needs, at minimum: **Vertex AI User**,
  **Storage Admin**, **BigQuery Admin**, **Cloud Run Admin**, **Cloud Build
  Editor**, **Service Account Admin**, and **Service Account User**.
- The deploy scripts create the runtime identities for you:
  - `vogue-toolbox-sa` runs the MCP Toolbox with only **BigQuery Data Viewer** +
    **BigQuery Job User** — it reads the two tables and nothing else.
  - The Agent Runtime service agent
    (`service-<project-number>@gcp-sa-aiplatform-re.iam.gserviceaccount.com`)
    is granted **Cloud Run Invoker** on the private Toolbox service.
  - The Cloud Run UI service account needs **Vertex AI User** and **BigQuery
    Data Editor/User**, since `checkout.py` writes orders from there.

**6. Local tooling**
- **Python 3.11+**, **Node.js 20+** (for the React UI), and **Docker**.

## Manual setup

`./bootstrap.sh` (see [Quickstart](#quickstart--one-command)) runs all of this for
you. Do it by hand if you want step-by-step control. Run from the repo root; the
scripts read configuration from environment variables, so export your `.env` first.

```bash
# 0. Configure — copy the template, fill in your values, and export them.
cp .env.example .env
#   edit .env: set VERTEXAI_PROJECT and PROJECT_NUMBER (at least)
set -a; source .env; set +a

# 1. Verify Claude is reachable on Vertex in your project
python tests/test_connection.py

# 2. Build the data plane (order matters)
python scripts/setup_catalog.py     # product images -> GCS, rewrites data/products.json
python scripts/setup_bigquery.py    # inventory + loyalty tables from the catalog
python scripts/setup_orders.py      # append-only orders table
python scripts/setup_rag.py         # RAG corpus; PRINTS RAG_CORPUS_RESOURCE=<name>
#   -> copy the printed resource into .env as RAG_CORPUS_RESOURCE, then re-export:
set -a; source .env; set +a

# 3. Deploy the MCP Toolbox to Cloud Run (the deployed agents call it for the
#    BigQuery inventory/loyalty tools). PRINTS TOOLBOX_URL=<url>.
./deploy_toolbox.sh
#   -> set TOOLBOX_URL in .env, then re-export:
set -a; source .env; set +a

# 4. (Optional) run the agents locally with the ADK dev UI. The Toolbox from
#    step 3 is called over the network, so TOOLBOX_URL must be set here too —
#    your own ADC signs the ID token.
adk web agents

# 5. Deploy the agent team to Agent Runtime (needs RAG_CORPUS_RESOURCE + TOOLBOX_URL)
python deploy_agent_engine.py       # PRINTS AGENT_ENGINE_ID=<id>
#   -> set AGENT_ENGINE_ID in .env, then re-export
set -a; source .env; set +a

# 6. Deploy the React UI (Cloud Run)
./deploy.sh
```

`deploy.sh` and `deploy_toolbox.sh` require `VERTEXAI_PROJECT` and `PROJECT_NUMBER`
in the environment (the UI deploy also needs `AGENT_ENGINE_ID`) and will refuse to
run without them. When `deploy.sh` finishes it prints the public URL of your
storefront.

## What's exposed, and tearing it down

> **This is a demo, not a hardened deployment.** Two things it creates are
> reachable by anyone who has the URL:
>
> * **The storefront** — `deploy.sh` deploys the UI to Cloud Run with
>   `--allow-unauthenticated`, because the point is to hand someone a link. That
>   endpoint relays to the agents, so anyone who finds it can spend your Claude
>   and Agent Runtime quota. It has no login and no rate limit.
> * **The product images** — `scripts/setup_catalog.py` grants `allUsers` read on
>   the `<project>-vogue-concierge` bucket so the `<img>` tags resolve without
>   signed URLs. The bucket holds only generated catalog images, but it is public.
>
> The MCP Toolbox and BigQuery are *not* public — the Toolbox is deployed
> `--no-allow-unauthenticated` and reachable only by the Agent Runtime service
> agent. If you want the storefront closed too, drop `--allow-unauthenticated`
> from `deploy.sh` and put IAP or your own auth in front of it.
>
> **Delete everything when you're done** — the Cloud Run services, the Agent
> Runtime engine, and the RAG corpus all bill while they exist:
>
> ```bash
> gcloud run services delete vogue-concierge --region "$REGION" --project "$VERTEXAI_PROJECT" --quiet
> gcloud run services delete vogue-toolbox   --region "$REGION" --project "$VERTEXAI_PROJECT" --quiet
> python -c "import vertexai; from vertexai import agent_engines; import os; \
>   vertexai.init(project=os.environ['VERTEXAI_PROJECT'], location=os.environ.get('REGION','us-central1')); \
>   agent_engines.get(os.environ['AGENT_ENGINE_ID']).delete(force=True)"
> python -c "from agentplatform import rag; import vertexai, os; \
>   vertexai.init(project=os.environ['VERTEXAI_PROJECT'], location='us-west1'); \
>   rag.delete_corpus(os.environ['RAG_CORPUS_RESOURCE'])"
> bq rm -r -f --dataset "$VERTEXAI_PROJECT:vogue_concierge"
> gcloud storage rm -r "gs://${VERTEXAI_PROJECT}-vogue-concierge"
> gcloud iam service-accounts delete "vogue-toolbox-sa@${VERTEXAI_PROJECT}.iam.gserviceaccount.com" --quiet
> ```
>
> The surest cleanup is to delete the whole project, if you made one for this.

## Payment is simulated — you have to build that part

Checkout writes a real order to BigQuery, applies the real loyalty discount and
credits real points. **The payment step is the one thing that is faked.** There is
no payment service provider wired in: `checkout.py` shows a stand-in card
(`MOCK_CARD = "Visa •••• 4242"`, Stripe's canonical test number) on the quote and
the receipt, mints a `payment_id`, and writes `payment_status = "paid"`
unconditionally. Nobody is ever asked for card details, nothing is authorised, and
no money moves. Every order "succeeds".

To take this to production, replace that step with a real PSP — Stripe, Adyen,
Checkout.com, Google Pay, whichever you use — and note that *where* you collect the
card matters as much as the integration itself:

* **Collect the card in the browser, with the provider's hosted fields or SDK**, so
  the number is tokenised client-side and never reaches this service. Do **not**
  have the customer type a card number into the chat box: that text is persisted in
  the Agent Runtime session history, passed to the model, and can land in Cloud Run
  request logs.
* **Send only the token** to the backend, authorise against it, and write the order
  row *from the authorisation result* rather than ahead of it — today `place_order`
  assumes success.
* **Persist only the brand and last four digits** plus the provider's charge id.
  Never store the full number, and add the decline, retry and refund paths the demo
  has no concept of.

Keeping the card out of your own servers is also what keeps your PCI DSS obligation
at SAQ A instead of pulling this whole deployment into scope.

## How it's built

- **`agents/agent.py`** — the team: an orchestrator that delegates to specialists
  via ADK `AgentTool`. Each agent runs on ADK's built-in
  [`Claude`](https://google.github.io/adk-docs/agents/models/anthropic/) model
  class, which speaks the Anthropic Messages API natively — tool-calling and the
  thinking-block round-trip a tool-use turn requires — and authenticates with
  ADC. Reasoning depth is set per agent with
  `AnthropicGenerateContentConfig(effort=...)`. That's the whole Claude
  integration: no custom `BaseLlm` to maintain.
- **`agents/prompt.py`** — one system prompt per agent.
- **`toolbox/tools.yaml`** — the BigQuery **reads**, declared as parameterised
  SQL and served by the MCP Toolbox on Cloud Run. `inventory_specialist` calls
  them through `ToolboxToolset`, authenticating with a Google-signed ID token,
  so the queries live outside the model and the service stays private.
- **`checkout.py`** — the BigQuery **writes** (loyalty discount → simulated
  payment, see the section above → write order → credit points), run on the Cloud
  Run layer. The agent
  only *signals* intent; this is the "signal/execute" pattern. It's a deliberate
  split — money-moving logic stays off the model, and the storefront needs the
  result to render a confirmation — not a reachability limit.
- **`app.py`** — FastAPI server for the React UI; relays chat to Agent Runtime.

## Project structure

```
vogue-concierge/
├── agents/                  # ADK agent team (runs on Agent Runtime)
│   ├── agent.py             # orchestrator + specialists (AgentTool)
│   ├── config.py            # model-per-agent mapping + data config
│   ├── prompt.py            # one prompt per agent
│   └── tools/               # catalog_search, trend_rag, order/inventory tools
├── toolbox/                 # MCP Toolbox config (BigQuery inventory/loyalty)
├── data/                    # products.json (30 items) + trend_report.md
├── scripts/                 # one-time data setup (catalog, RAG, BigQuery, orders)
├── ui/                      # Next.js / React storefront
├── app.py                   # FastAPI server for the React UI
├── checkout.py              # real BigQuery checkout (Cloud Run layer)
├── bootstrap.sh             # interactive one-command installer
├── deploy_agent_engine.py   # deploy agents to Agent Engine
├── deploy_toolbox.sh        # deploy the MCP Toolbox to Cloud Run
└── deploy.sh                # deploy the UI to Cloud Run
```

## License

Apache License 2.0 — see the [LICENSE](../../LICENSE) at the repository root.
Copyright 2026 The "Anthropic on Google Cloud" Authors.
