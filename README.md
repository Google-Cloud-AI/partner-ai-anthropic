# Anthropic on Google Cloud

---

### ⚠️ Disclaimer

This is not an officially supported Google product, nor an official Anthropic product. This project is not eligible for the [Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).

This project is intended for demonstration and educational purposes only — it is not intended for use in a production environment. The code, configurations, and architectures here are provided **"as is"**, without warranty of any kind, and may rely on preview or rapidly changing APIs. Running these workloads on Google Cloud will incur costs for which you are solely responsible. Review, test, and harden anything here before depending on it.

---

## About

This repository is a curated collection of co-innovation work spanning **Claude on Google Cloud**, covering Gemini Enterprise Agent Platform integrations, agentic AI patterns with ADK, MCP, A2A, Claude Code workflows, and deployment of Claude-powered agents to the **Gemini Enterprise Agent Platform (GEAP)**.

It starts with a minimal two-section structure — quickstarts and demos — and will grow as needed.

## Repository Structure

| Section | Description |
|---|---|
| [`01-quickstart/`](./01-quickstart/) | Minimal, runnable quickstarts to get up and running fast |
| [`02-demos/`](./02-demos/) | End-to-end demonstration applications |

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/PTA-Co-innovation-Team/partner-ai-anthropic.git
   cd partner-ai-anthropic
   ```
2. Start with [`01-quickstart/`](./01-quickstart/) to get up and running.
3. Explore end-to-end examples in [`02-demos/`](./02-demos/).

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

*This repository is a team co-innovation effort and is not an official product of Anthropic or Google Cloud.*

Onward. 🚀
