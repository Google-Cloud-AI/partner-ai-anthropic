# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""AgentCard definition for cc-a2a-bridge.

Served at /.well-known/agent-card.json (the canonical A2A path, with the
HYPHEN — Probe A and the a2a-protocol skill both confirm). Gemini
Enterprise's Discovery Engine registration points at this URL.

Phase 5 capabilities: streaming = True. `artifacts` is NOT a field on
AgentCapabilities in a2a-sdk 0.2.13 — artifact support is signaled
implicitly by emitting `TaskArtifactUpdateEvent` events, not via a
capability flag. (Documented drift from the original skill.)
"""

from __future__ import annotations

import os

from a2a.types import AgentCapabilities, AgentCard, AgentSkill


def build_agent_card() -> AgentCard:
    """Construct the AgentCard. Called once at server startup."""
    # PUBLIC_URL is the URL Gemini Enterprise (and any A2A client) should
    # POST to. Cloud Run injects K_SERVICE/etc but the URL itself only
    # exists after first deploy — pass it in explicitly via env var so
    # the agent card never lies about its own endpoint.
    public_url = os.environ.get(
        "PUBLIC_URL", "https://cc-a2a-bridge.example.invalid"
    )

    return AgentCard(
        name="Claude Code",
        description=(
            "Build scripts, dashboards, and prototypes from plain English. "
            "Reads files, runs commands, writes code in an isolated workspace, "
            "and returns the result as a downloadable file artifact."
        ),
        version="0.1.0",
        url=public_url,
        protocolVersion="0.2",
        capabilities=AgentCapabilities(
            streaming=True,
            pushNotifications=False,
            stateTransitionHistory=False,
        ),
        defaultInputModes=["text/plain", "application/octet-stream"],
        defaultOutputModes=[
            "text/plain",
            "text/html",
            "application/octet-stream",
        ],
        skills=[
            AgentSkill(
                id="code-from-english",
                name="Build software from plain English",
                description=(
                    "Describe a script, dashboard, prototype, or analysis "
                    "in plain English. The agent reads any files you "
                    "attach, runs commands in an isolated workspace, and "
                    "returns the finished output as a file artifact."
                ),
                tags=["coding", "data-analysis", "prototyping"],
                examples=[
                    "Build an interactive HTML dashboard from this billing CSV.",
                    "Find the bottom-quartile headlines in this ad CSV and "
                    "write 50 new variants under 30 characters.",
                    "Turn this PRD into a clickable HTML prototype.",
                ],
            ),
        ],
    )
