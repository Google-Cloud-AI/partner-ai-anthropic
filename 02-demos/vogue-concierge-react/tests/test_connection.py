# Copyright 2026 The "Anthropic on Google Cloud" Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Test connection — Vogue Concierge (Claude on Agent Platform).

Validates that Claude is reachable on Agent Platform in your project. Run this FIRST,
before deploying anything else — if this fails, check that you enabled the Claude
models in Vertex AI Model Garden and that CLAUDE_VERTEX_REGION is correct.

Usage:
    python tests/test_connection.py

Auth: uses Google Application Default Credentials (no Anthropic API key). Run
`gcloud auth application-default login` locally first.
"""

import os
import sys

# Import agents/config.py as a STANDALONE module. We add the agents/ directory
# (not the project root) to the path and import `config` directly, so we do NOT
# trigger agents/__init__.py — which would pull in the full ADK stack. The whole
# point of this test is to verify Claude on Agent Platform BEFORE installing the runtime,
# so it should only need the `anthropic` package.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "agents"))

import config  # noqa: E402  (this is agents/config.py)


def test_claude_on_vertex() -> bool:
    """Ping every agent's model so we know the whole team can run.

    Each agent uses a specific Claude model (see agents/config.py). We send one
    tiny message per UNIQUE model (so we don't pay for duplicate calls when two
    agents share a model) and report the result for each agent. All four agents
    must pass for the deployed team to work.
    """
    from anthropic import AnthropicVertex

    # One client for the Claude-serving region. ADC handles auth.
    client = AnthropicVertex(project_id=config.PROJECT_ID, region=config.CLAUDE_VERTEX_REGION)

    # The agent -> model mapping we are validating.
    agents = [
        ("Orchestrator / Concierge", config.ORCHESTRATOR_MODEL),
        ("Style Advisor", config.STYLE_MODEL),
        ("Inventory & Pricing", config.INVENTORY_MODEL),
        ("Returns & Care", config.RETURNS_MODEL),
    ]

    print("Testing Claude on Agent Platform...")
    print(f"  project = {config.PROJECT_ID}")
    print(f"  region  = {config.CLAUDE_VERTEX_REGION}\n")

    # Call each distinct model once, cache the (ok, detail) result.
    results: dict = {}

    def check(model: str):
        if model in results:
            return results[model]
        try:
            message = client.messages.create(
                model=model,
                max_tokens=20,
                messages=[{"role": "user", "content": "Reply with exactly: OK"}],
            )
            text = "".join(b.text for b in message.content if b.type == "text").strip()
            results[model] = (bool(text), text or "(empty reply)")
        except Exception as e:  # noqa: BLE001 - report per-model, keep going
            results[model] = (False, str(e).splitlines()[0][:120])
        return results[model]

    all_ok = True
    for agent_name, model in agents:
        ok, detail = check(model)
        all_ok = all_ok and ok
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {agent_name:<26} {model:<20} -> {detail}")

    print("\n" + ("All four agents can reach their models." if all_ok
                  else "One or more models failed — enable them in Vertex Model Garden."))
    return all_ok


if __name__ == "__main__":
    try:
        ok = test_claude_on_vertex()
    except Exception as e:  # noqa: BLE001
        print(f"FAILED: {e}")
        print(
            "\nChecklist:\n"
            "  - Enabled Claude models in Agent Platform Model Garden for this project?\n"
            "  - Is CLAUDE_VERTEX_REGION a region that serves the model?\n"
            "  - Did you run `gcloud auth application-default login`?\n"
            "  - Installed deps? `pip install \"anthropic[vertex]\"`"
        )
        ok = False
    exit(0 if ok else 1)
