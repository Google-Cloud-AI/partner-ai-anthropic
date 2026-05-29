# Claude Code on the Gemini Enterprise Agent Platform

> ⚠️ **Use at your own risk.** See [root disclaimer](../../README.md).

A production-oriented blueprint for packaging the **Claude Code** coding harness as a
first-party-quality agent in the **Gemini Enterprise Agent Platform (GEAP)** Agent Gallery —
running entirely inside the customer's own GCP project, with inference on Vertex AI and
per-user data isolation enforced by IAM.

A non-engineer (PM, growth marketer, designer, analyst, legal) selects the agent in any
Gemini Enterprise thread, describes what they want built in plain English, watches the agent
read files, run commands, and write code, and downloads the result as a file artifact in the
same chat thread. Inference and source data **never leave the customer's GCP project**.

## Overview

The system is built on a single load-bearing architectural decision (**Option A**): a Google
**Agent Development Kit (ADK)** orchestrator is the brain, and **Claude Code is one of its
tools**, alongside memory, artifact-emission, and workspace-management tools. This keeps user
identity, model choice, and tool surface orthogonal — adding a second coding harness later is a
new tool, not a new architecture.

Three layers:

- **Gemini Enterprise** — the user's chat surface and the source of identity.
- **`cc-a2a-bridge`** (Cloud Run, stateless) — an A2A (Agent-to-Agent) protocol adapter that
  resolves the user's identity, claims a per-user sandbox pod, mints downscoped storage
  credentials, and translates the backend event stream into GEAP working/thought/response
  panes.
- **`cc-backend`** (GKE Agent Sandbox, per-user pod) — a gVisor-isolated pod that hosts the ADK
  orchestrator and the Claude Code subprocess against an ephemeral `/workspace`.

## What This Demonstrates

- Packaging Claude Code as an ADK tool and registering the resulting agent to GEAP via
  Discovery Engine.
- Per-user execution and storage isolation: gVisor sandboxing, default-deny networking, and
  Cloud Storage access scoped per user via **downscoped STS tokens** (Credential Access
  Boundary), enforced by IAM rather than application code.
- Streaming translation from a backend SSE event stream into native GEAP UI events, with file
  artifacts delivered either as native download chips (Path A) or signed Cloud Storage URLs
  (Path B) with `Content-Disposition: attachment`.
- Multi-turn memory and workspace persistence: Firestore-backed sessions per chat thread and
  cross-thread facts per user, with `/workspace` parked to GCS and restored across pod cycles.

## Architecture

```
Gemini Enterprise (A2A turn + user OAuth token)
        |
        v
+------------------------------------------------+
|  cc-a2a-bridge  (Cloud Run, stateless)         |
|  - A2A JSON-RPC adapter only                   |
|  - Resolves token -> user_key                  |
|  - Gets-or-creates SandboxClaim/cc-u-<key>     |
|  - Mints downscoped STS token for user prefix  |
|  - Streams events <-> A2A working/thought/result|
+----------------------+-------------------------+
                       | (internal LB, X-Sandbox-* headers)
                       v
+------------------------------------------------+
|  cc-backend  (GKE Agent Sandbox, per-user pod) |
|  - gVisor-isolated, default-deny networking    |
|  - /workspace = 20Gi ephemeral, noexec         |
|  - ADK orchestrator (Python)                   |
|      claude_code tool (drives CLI subproc)     |
|      workspace tools (list/read/move/del)      |
|      memory tools (remember/recall)            |
|      emit_artifact tool                        |
|  - One ADK Session per A2A context_id          |
|  - Park/restore /workspace to GCS              |
+------------------------------------------------+
```

A full treatment — component deep-dives, the request lifecycle, deployment, and hard-won
deployment learnings — is in the engineering reference under [`docs/`](./docs/).

## Repository Layout

| Path | Contents |
|---|---|
| [`backend/`](./backend/) | GKE pod runtime: ADK orchestrator (`adk_agent.py`), HTTP server, Firestore session/memory services, Claude Code + workspace + memory tools, park/restore, Dockerfile |
| [`bridge/`](./bridge/) | Cloud Run A2A adapter: `main.py`, token resolution (`auth.py`), STS downscoping (`downscope.py`), signed-URL helpers (`sign_helpers.py`), sandbox claim lifecycle, tests |
| [`infra/`](./infra/) | Terraform IaC (`terraform/`) and `cloudbuild.yaml` for both images |
| [`scripts/`](./scripts/) | Smoke tests, isolation negative test, agent registration, deployment helpers |
| [`docs/`](./docs/) | Engineering reference design document (`.docx`) and its `python-docx` build script |
| [`PROJECT_PLAN.md`](./PROJECT_PLAN.md) | Milestones, v1 scope, and the full Critical User Journey catalogue |

## Prerequisites

- A Google Cloud project with billing enabled.
- Access to **Claude models on Vertex AI** (see
  [Anthropic on Vertex AI docs](https://docs.claude.com/en/api/claude-on-vertex-ai)).
- `gcloud` CLI installed and authenticated; Terraform; Python 3.11+ and Node.js 20 (for the
  bundled Claude Code CLI).
- A GKE Autopilot cluster with the **Agent Sandbox** addon, provisioned by the included
  Terraform.

## Configuration — what to replace before redeploying

This blueprint ships with the original demo project's identifiers intact so the code is
verifiably the working version. Before deploying into **your** project, replace the following
(they appear in the `Makefile`, `infra/terraform/*.tf`, `infra/cloudbuild.yaml`, and the
backend and bridge source):

| Identifier | Demo value | Replace with |
|---|---|---|
| GCP project ID | `cpe-slarbi-nvd-ant-demos` | your project ID |
| Workspace bucket | `<project>-cc-a2a-snapshots` | your bucket (project-prefixed) |
| Terraform state bucket | `<project>-tfstate` | your state bucket |
| Bridge service account | `cc-a2a-bridge@<project>.iam.gserviceaccount.com` | your SA |
| Backend service account | `cc-a2a-backend@<project>.iam.gserviceaccount.com` | your SA |
| Firestore database (named) | `cc-on-ge` | your database name |
| Artifact Registry | `us-central1-docker.pkg.dev/<project>/cc-on-ge/` | your AR repo |

Region (`us-central1`) and the Vertex `global` endpoint are also assumed; adjust if needed. No
secrets, keys, or service-account JSON files are included in this blueprint.

## Quick Start

> There is no single `make deploy` target yet — deployment is the sequence below. Replace the
> demo identifiers first (see the **Configuration** section above).

```bash
# 1. Bootstrap: Terraform state bucket, builder service account, enabled APIs.
make bootstrap

# 2. Create the Artifact Registry repo first — Cloud Run requires the images to exist.
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform apply -target=google_artifact_registry_repository.cc_on_ge

# 3. Build and push the bridge and backend images to Artifact Registry.
gcloud builds submit bridge/  --config infra/cloudbuild.yaml --substitutions=_IMAGE=cc-a2a-bridge,_TAG=v1
gcloud builds submit backend/ --config infra/cloudbuild.yaml --substitutions=_IMAGE=cc-backend,_TAG=v1

# 4. Apply the full stack: GKE + Agent Sandbox, Cloud Run bridge, Firestore,
#    snapshots bucket, IAM, and the sandbox router / template / warm pool.
terraform -chdir=infra/terraform apply

# 5. Register the agent with Gemini Enterprise Discovery Engine.
make register-agent-apply
```

See [`PROJECT_PLAN.md`](./PROJECT_PLAN.md) for v1 scope, milestones, and the phase-by-phase
build plan.

## Critical User Journeys

The blueprint is verified end-to-end against three non-engineer journeys:

1. **PM: spec -> prototype.** Paste a PRD link, receive a working HTML prototype as a file
   artifact, iterate in the same thread ("make the empty state friendlier").
2. **Growth marketer: CSV -> ad copy.** Upload an ad-performance CSV; the agent finds the
   bottom-quartile headlines and writes 50 variants, returning a spreadsheet.
3. **Analyst: messy CSV -> dashboard.** Drop a billing export, receive a self-contained
   interactive HTML dashboard (delivered via a signed download URL).

## Testing

| Test | Command | Covers |
|---|---|---|
| In-cluster smoke | `make sandbox-smoke` | Warm pool, gVisor, router, cc-backend, Vertex |
| End-to-end smoke | `make smoke` | Cloud Run, bridge, A2A round-trip |
| Isolation negative test | `make iso-test` | User A's pod cannot read user B's GCS prefix |
| Static checks | `make lint` | `py_compile`, `terraform validate`, formatter |

## Cost Considerations

Costs include per-token Claude inference on Vertex AI, GKE Autopilot node-hours (driven by the
warm-pool size and idle-teardown threshold), Cloud Run request time on the bridge, Cloud
Storage for workspace snapshots, and Firestore reads/writes for sessions and memory. Idle pods
are torn down after 30 minutes; the warm-pool size (default 2) trades node cost for first-turn
latency.

## Engineering Reference

The full engineering design document — executive summary, component deep-dives, the request
lifecycle, deployment, and best-practices / deployment learnings — is included as a Word
document under [`docs/`](./docs/), regenerable with the included `python-docx` build script.

## References

- [Agent Development Kit (ADK)](https://google.github.io/adk-docs/)
- [Anthropic on Vertex AI](https://docs.claude.com/en/api/claude-on-vertex-ai)
- [Vertex AI Agent Engine](https://cloud.google.com/vertex-ai/generative-ai/docs/agent-engine/overview)
