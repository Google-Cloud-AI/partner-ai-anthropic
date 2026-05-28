# Anthropic × Google Cloud Co-Innovation

---

### ⚠️ DISCLAIMER — USE AT YOUR OWN RISK

This repository is provided **"AS IS"**, without warranty of any kind, express or implied. The code, configurations, architectures, and guidance contained herein are shared for **educational and demonstration purposes only**.

- This is **NOT** an officially supported Anthropic or Google Cloud product.
- Content represents **individual contributor work** and does not necessarily reflect the views, positions, or roadmap of Anthropic, Google Cloud, or any affiliated organization.
- Running these workloads on Google Cloud **will incur costs** — you are solely responsible for any charges, quota consumption, or resource usage on your own GCP projects.
- Examples may use **preview, experimental, or rapidly changing APIs** that can break without notice.
- **Do not deploy any code from this repository directly to production** without your own review, testing, hardening, and security validation.
- **Authors and contributors accept no liability** for any damages, data loss, security incidents, or costs arising from the use of this material.

By using this repository, you acknowledge and accept these terms.

---

## About

This repository is a curated collection of co-innovation work spanning **Claude on Google Cloud**, covering Gemini Enterprise Agent Platform integrations, agentic AI patterns with ADK, MCP, A2A, Claude Code workflows, and deployment of Claude-powered agents to the **Gemini Enterprise Agent Platform (GEAP)**.

It is organized as a **progressive learning path** — from environment setup to production-oriented solution accelerators.

## Repository Structure

| Section | Description |
|---|---|
| [`01-getting-started/`](./01-getting-started/) | Environment setup: Vertex AI, Claude Code, multi-region endpoints |
| [`02-tutorials/`](./02-tutorials/) | Step-by-step learning modules on core Claude + Google Cloud patterns |
| [`03-quick-starts/`](./03-quick-starts/) | Minimal runnable examples to get up and running fast |
| [`04-demos/`](./04-demos/) | End-to-end demonstration applications |
| [`05-best-practices/`](./05-best-practices/) | Prompt engineering, cost optimization, VPC-SC, and security guidance |
| [`06-solution-accelerators/`](./06-solution-accelerators/) | Production-oriented blueprints for common enterprise patterns |
| [`07-reference-architectures/`](./07-reference-architectures/) | Diagrams and architectural decision records |

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/PTA-Co-innovation-Team/partner-ai-anthropic.git
   cd partner-ai-anthropic
   ```
2. Start with [`01-getting-started/`](./01-getting-started/) to configure your environment.
3. Follow the numbered learning path, or jump to a specific demo in [`04-demos/`](./04-demos/).

## Prerequisites

- A Google Cloud project with billing enabled
- Access to **Claude models on Vertex AI** (see [Anthropic on Vertex AI docs](https://docs.claude.com/en/api/claude-on-vertex-ai))
- `gcloud` CLI installed and authenticated
- Python 3.11+ and Node.js 20+ for most modules

## Technology Stack

- **Models:** Claude (via Anthropic API and Vertex AI), Gemini
- **Agent frameworks:** Google ADK, A2A, MCP, Vertex AI Agent Engine, Gemini Enterprise Agent Platform (GEAP)
- **Infrastructure:** GKE, Cloud Run, Vertex AI, BigQuery, AlloyDB
- **Tooling:** Claude Code, gcloud, Terraform (where applicable)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines. All contributors must agree to the [Code of Conduct](./CODE_OF_CONDUCT.md).

## License

This project is licensed under the Apache License 2.0 — see [LICENSE](./LICENSE) for details.

## Maintainer

**Partner Technical Architecture Team**

---

*This repository is a personal/team co-innovation effort and is not an official product of Anthropic or Google Cloud.*

Onward. 🚀
