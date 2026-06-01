# Repo guidance

Guidance for anyone — including AI coding tools — working in this repo.

## Git & attribution policy

- **Commits are authored solely by the repo owner.**
- **Do not add any AI attribution anywhere.** No `Co-Authored-By` trailers, no "Generated with Claude Code" (or similar) footers in commit messages, and no AI-attribution lines in file contents or docs.
- **Do not commit or push unless explicitly asked.**

## Conventions (claude-on-agent-platform tutorials)

- **Route every Claude call through the Agent Platform** via the `AnthropicVertex` client with **ADC** auth — never the first-party Anthropic API, and never an `ANTHROPIC_API_KEY`. (The one exception is the batch module, which uses the Vertex batch-job interface via the Google Gen AI SDK but still targets Claude on the platform.)
- **Model string is exactly `claude-opus-4-8`.** `LOCATION` defaults to `global` (batch uses a **regional** endpoint).
- **Use placeholders/sentinels** (e.g. `<YOUR_PROJECT_ID>`, `<YOUR_BUCKET>`) with **auto-detect + a guard** assertion. Never hardcode real project IDs, emails, or bucket names.
- **Prefer paste-ready commands**, and keep notebooks **self-contained** (generate any sample assets locally; no external or copyrighted inputs).
