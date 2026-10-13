# 01 — Quickstart

Minimal, runnable quickstarts for getting up and running with Claude on Google Cloud.

| Quickstart | Description |
|---|---|
| [`otlp-to-collector/`](./otlp-to-collector/) | Send Claude Code usage, cost and productivity telemetry into Google Cloud Observability through the Google-built OpenTelemetry Collector on Cloud Run — Cloud Logging and Cloud Monitoring, with BigQuery as an optional downstream |
| [`otlp-to-telemetry-api/`](./otlp-to-telemetry-api/) | Send the same telemetry straight to the Telemetry API with no collector to deploy. Metrics feed Cloud Monitoring dashboards; logs route on to BigQuery for cost, tool, hook and session analytics in SQL |
