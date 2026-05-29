"""FirestoreMemoryService — ADK BaseMemoryService backed by Firestore.

Implements the two abstract async methods (add_session_to_memory,
search_memory) per ADK 1.33's interface against the `cc-on-ge` named DB.
(Lesson B: the SDK silently defaults to `(default)`, unrelated data in
this project; always pass database=cc-on-ge.)

Recall strategy — Phase 4 MVP (per user spec):
  - Lowercase the query, tokenize on whitespace/word boundaries
  - Drop stopwords: a, an, the, is, are, my, me, i
  - Score each fact by how many query keywords appear as
    case-insensitive substrings of fact.text
  - Sort by (match_count DESC, created_at DESC)
  - Return top K=10
  - If zero keyword matches, fall back to the 5 most-recent facts
  - About 15 lines of scoring; ~200-fact scan cap

Phase v2 (TODO): replace with Firestore vector search over an
`embedding` field populated by `remember()` on write.

Data model (see firestore-sessions skill):
  memory/{user_key}/facts/{fact_id}
    text: str           — the fact text
    source: str         — context_id (session id) where it was learned
    created_at: ts      — Firestore server timestamp
"""

from __future__ import annotations

import logging
import os
import re
import uuid
from typing import Optional

from google.cloud.firestore import AsyncClient, SERVER_TIMESTAMP, Query
from google.adk.memory import BaseMemoryService
from google.adk.memory.memory_entry import MemoryEntry
from google.adk.memory.base_memory_service import SearchMemoryResponse
from google.adk.sessions import Session
from google.genai import types

log = logging.getLogger(__name__)

# Stopwords filtered out of recall queries (user-specified Phase 4 MVP).
STOPWORDS = frozenset({"a", "an", "the", "is", "are", "my", "me", "i"})

# Top-K for keyword matches.
_RECALL_TOP_K = 10
# Fallback K when zero keyword matches — return N most-recent facts.
_RECALL_FALLBACK_K = 5
# Cap on facts considered for scoring (avoid unbounded scan).
_RECALL_SCAN_CAP = 200


class FirestoreMemoryService(BaseMemoryService):
    """Per-user fact storage with keyword-scoring recall.

    Facts live at memory/{user_key}/facts/{fact_id}, populated by the
    agent's remember() tool. search_memory ranks by case-insensitive
    keyword-substring matches with stopword filtering, falling back
    to most-recent when no keywords match.
    """

    def __init__(self, project: str, database: str = "cc-on-ge"):
        # NAMED DB — see firestore-sessions skill, Lesson B.
        self.db = AsyncClient(project=project, database=database)
        log.info(
            "FirestoreMemoryService init: db=%s", self.db._database_string,
        )

    async def add_session_to_memory(self, session: Session) -> None:
        """Phase 4 MVP: rely on the remember() tool for explicit facts.

        ADK calls this when a Session is being committed to long-term
        memory. For now we do nothing — facts come from the agent's
        explicit remember() calls, not from auto-summarization.
        Phase v2 will add a summarization pass here.
        """
        log.debug(
            "add_session_to_memory: noop for Phase 4 MVP (session_id=%s)",
            session.id,
        )

    async def search_memory(
        self,
        *,
        app_name: str,
        user_id: str,
        query: str,
    ) -> SearchMemoryResponse:
        """Keyword-substring scoring; fallback to most-recent on zero matches."""
        log.info("search_memory: user=%s query=%r", user_id, query)
        # Tokenize + dedupe + drop stopwords.
        tokens = re.findall(r"\w+", (query or "").lower())
        keywords = [t for t in tokens if t not in STOPWORDS]
        keywords = list(dict.fromkeys(keywords))  # dedupe, preserve order
        log.debug("search_memory: keywords=%s", keywords)

        # Pull facts for this user, most-recent first (single-field index
        # auto-managed by Firestore; no composite needed for this query).
        facts_ref = (
            self.db.collection("memory")
            .document(user_id)
            .collection("facts")
            .order_by("created_at", direction=Query.DESCENDING)
            .limit(_RECALL_SCAN_CAP)
        )

        # candidates: list of (match_count, fact_data, fact_id)
        # (rely on Firestore's order_by to break match-count ties by
        # created_at DESC, since we preserve insertion order).
        candidates: list[tuple[int, dict, str]] = []
        async for snap in facts_ref.stream():
            data = snap.to_dict() or {}
            text_lower = (data.get("text", "") or "").lower()
            count = sum(1 for k in keywords if k in text_lower)
            candidates.append((count, data, snap.id))

        # Stable sort by match_count DESC (created_at order preserved
        # from Firestore for same count).
        candidates.sort(key=lambda c: c[0], reverse=True)

        # Pick top-K if any matches; else fallback to recent N.
        with_matches = [c for c in candidates if c[0] > 0]
        if with_matches:
            chosen = with_matches[:_RECALL_TOP_K]
            log.info(
                "search_memory: %d matches, returning top %d",
                len(with_matches), len(chosen),
            )
        else:
            chosen = candidates[:_RECALL_FALLBACK_K]
            log.info(
                "search_memory: 0 keyword matches, fallback to %d most-recent",
                len(chosen),
            )

        memories = [
            _memory_entry_from_fact(data, fact_id, user_id)
            for (_, data, fact_id) in chosen
        ]
        return SearchMemoryResponse(memories=memories)

    # ----- helper API used by the remember() tool -----

    async def write_fact(self, *, user_id: str, text: str, source: str) -> str:
        """Write a fact for `user_id`. Returns the new fact_id."""
        fact_id = uuid.uuid4().hex
        await (
            self.db.collection("memory")
            .document(user_id)
            .collection("facts")
            .document(fact_id)
            .set({
                "text": text,
                "source": source,
                "created_at": SERVER_TIMESTAMP,
            })
        )
        log.info(
            "write_fact: user=%s id=%s text=%r",
            user_id, fact_id, text[:80],
        )
        return fact_id


def _memory_entry_from_fact(
    fact: dict, fact_id: str, user_id: str,
) -> MemoryEntry:
    text = fact.get("text", "") or ""
    content = types.Content(role="user", parts=[types.Part(text=text)])
    return MemoryEntry(
        content=content,
        id=fact_id,
        author=user_id,
        timestamp=str(fact.get("created_at") or ""),
    )


# ----- module-level singleton accessor -----

_SINGLETON: Optional[FirestoreMemoryService] = None


def memory_service() -> FirestoreMemoryService:
    """Module-singleton FirestoreMemoryService instance.

    Both `backend/server.py` (for ADK Runner injection) and
    `backend/tools/memory_tools.py` (for remember/recall) import this
    accessor so they share a single AsyncClient.
    """
    global _SINGLETON
    if _SINGLETON is None:
        project = os.environ.get(
            "VERTEXAI_PROJECT", "cpe-slarbi-nvd-ant-demos",
        )
        database = os.environ.get("FIRESTORE_DATABASE", "cc-on-ge")
        _SINGLETON = FirestoreMemoryService(project=project, database=database)
    return _SINGLETON
