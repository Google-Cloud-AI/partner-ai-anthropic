# 01 — Quickstart

Minimal, runnable quickstarts for getting up and running with Claude on Google Cloud.

| Quickstart | Description |
|---|---|
| [`otlp-to-telemetry-api/`](./otlp-to-telemetry-api/) | Send Claude Code usage, cost and productivity telemetry into Google Cloud Observability straight through the Telemetry API, with no collector to deploy. Metrics feed Cloud Monitoring dashboards; logs route on to BigQuery for cost, tool, hook and session analytics in SQL |
| [`otlp-to-collector/`](./otlp-to-collector/) | Send the same telemetry via the Google-built OpenTelemetry Collector on Cloud Run — Cloud Logging and Cloud Monitoring, with BigQuery as an optional downstream. Use when you need a collector in the path |
| [`bigquery-mod/`](./bigquery-mod/) | Write Claude Code's telemetry events straight to BigQuery with a Claude Code mod, one table per event, with no collector to deploy |
