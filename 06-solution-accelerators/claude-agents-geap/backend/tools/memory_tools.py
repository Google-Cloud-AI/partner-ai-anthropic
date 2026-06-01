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

"""ADK memory tools: remember() and recall().

Both tools use the module-singleton FirestoreMemoryService from
backend/firestore_memory.py so they share the AsyncClient with the
ADK Runner (server.py injects the same instance).

The system prompt in adk_agent.py teaches the agent *when* to call
each: recall at the start of every turn; remember ONLY for durable
user/project facts (name, role, company, preferences, recurring
needs) — never for conversational ephemera.
"""

from __future__ import annotations

import logging
from typing import Any

from firestore_memory import memory_service

log = logging.getLogger(__name__)


async def remember(fact: str, tool_context: Any) -> str:
    """Persist a durable fact about the current user for future turns.

    Use this ONLY when the user shares a stable fact about themselves,
    their preferences, or their project — name, role, company,
    recurring needs, format preferences. Do NOT remember conversational
    ephemera (small talk, ad-hoc requests, debugging back-and-forth).
    One concise self-contained fact per call.

    Args:
        fact: The natural-language fact to persist. Keep it short and
            self-contained so a future turn can use it without context.

    Returns:
        Confirmation string with the fact text.
    """
    user_id = tool_context.session.user_id
    session_id = tool_context.session.id
    ms = memory_service()
    fact_id = await ms.write_fact(
        user_id=user_id, text=fact, source=session_id,
    )
    log.info(
        "remember: user=%s session=%s fact_id=%s text=%r",
        user_id, session_id, fact_id, fact[:120],
    )
    return f"Remembered: {fact}"


async def recall(query: str, tool_context: Any) -> str:
    """Retrieve facts relevant to the query.

    Call this at the start of every turn with a short query summarizing
    what context might help — e.g., "user name and role", "project
    preferences", "what was discussed earlier".

    Returns:
        Newline-joined fact texts, or "No relevant memories." if empty.
    """
    user_id = tool_context.session.user_id
    app_name = tool_context.session.app_name
    ms = memory_service()
    response = await ms.search_memory(
        app_name=app_name, user_id=user_id, query=query,
    )
    if not response.memories:
        log.info("recall: user=%s query=%r → 0 memories", user_id, query)
        return "No relevant memories."

    lines: list[str] = []
    for entry in response.memories:
        for part in (entry.content.parts or []):
            text = getattr(part, "text", None)
            if text:
                lines.append(text)
    log.info(
        "recall: user=%s query=%r → %d memories, %d lines",
        user_id, query, len(response.memories), len(lines),
    )
    return "\n".join(lines) or "No relevant memories."
