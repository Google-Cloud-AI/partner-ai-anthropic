# 03 — Deployment

> ⚠️ **Use at your own risk.** See [root disclaimer](../README.md).

Infrastructure automation for running Claude platform components on Google
Cloud. Where `01-quickstart/` gets you running fast and `02-demos/` shows
end-to-end applications, this section covers the provisioning underneath them:
Terraform and `gcloud` automation for services an organization operates itself.

| Module | Description |
|---|---|
| [`claude-apps-gateway-gcp/`](./claude-apps-gateway-gcp/) | Deploys the Claude apps gateway on Cloud Run with a private-IP Cloud SQL session store, Secret Manager, and the VPC it requires. Developers sign in through your IdP instead of holding API keys. |
