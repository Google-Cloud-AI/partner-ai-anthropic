"""FirestoreSessionService — ADK BaseSessionService backed by Firestore.

Implements the four abstract async methods on ADK 1.33's
BaseSessionService against the `cc-on-ge` named database (Lesson B).
Overrides `append_event` to persist durable (non-partial) events to
Firestore on each append; without this override, the default impl
stores events only in-memory and pod restart loses everything.

Data model (see firestore-sessions skill):
  sessions/{context_id}                    — root doc (user_key, app_name, state, ts)
  sessions/{context_id}/events/{event_id}  — event subcollection (Pydantic model_dump)
"""

from __future__ import annotations

import logging
import uuid
from typing import Any, Optional

from google.cloud.firestore import AsyncClient, SERVER_TIMESTAMP
from google.adk.events import Event
from google.adk.sessions import BaseSessionService, Session
from google.adk.sessions.base_session_service import (
    GetSessionConfig,
    ListSessionsResponse,
)

log = logging.getLogger(__name__)

# Cap on events fetched per session — Firestore docs are 1 MB max each;
# the runner replays events on get_session, so very long sessions get a
# soft cap here. Tune for cost / context-window pressure later.
_MAX_EVENTS = 1000


class FirestoreSessionService(BaseSessionService):
    """Persists ADK Sessions in Firestore.

    Each ADK Session maps 1:1 to a Firestore doc at sessions/{session_id}
    (where session_id == A2A context_id). Events live in the
    sessions/{session_id}/events/ subcollection, ordered by `timestamp`.
    """

    def __init__(self, project: str, database: str = "cc-on-ge"):
        # NAMED DB — see firestore-sessions skill, Lesson B.
        self.db = AsyncClient(project=project, database=database)
        log.info(
            "FirestoreSessionService init: db=%s", self.db._database_string,
        )

    async def create_session(
        self,
        *,
        app_name: str,
        user_id: str,
        state: Optional[dict[str, Any]] = None,
        session_id: Optional[str] = None,
    ) -> Session:
        sid = session_id or uuid.uuid4().hex
        doc = self.db.collection("sessions").document(sid)
        await doc.set({
            "user_key": user_id,
            "app_name": app_name,
            "state": state or {},
            "created_at": SERVER_TIMESTAMP,
            "updated_at": SERVER_TIMESTAMP,
        })
        log.info(
            "create_session: app=%s user=%s id=%s", app_name, user_id, sid,
        )
        return Session(
            app_name=app_name,
            user_id=user_id,
            id=sid,
            state=state or {},
            events=[],
        )

    async def get_session(
        self,
        *,
        app_name: str,
        user_id: str,
        session_id: str,
        config: Optional[GetSessionConfig] = None,
    ) -> Optional[Session]:
        doc_ref = self.db.collection("sessions").document(session_id)
        snap = await doc_ref.get()
        if not snap.exists:
            log.info(
                "get_session: not found (app=%s user=%s id=%s)",
                app_name, user_id, session_id,
            )
            return None
        data = snap.to_dict() or {}

        # Replay events in timestamp order. Skip rows we can't deserialize
        # rather than failing the whole turn (we'd rather have partial
        # history than no history on schema drift).
        events: list[Event] = []
        events_ref = (
            doc_ref.collection("events")
            .order_by("timestamp")
            .limit(_MAX_EVENTS)
        )
        async for ev_snap in events_ref.stream():
            event = _event_from_doc(ev_snap.to_dict() or {})
            if event is not None:
                events.append(event)
        log.info(
            "get_session: app=%s user=%s id=%s events_replayed=%d",
            app_name, user_id, session_id, len(events),
        )
        return Session(
            app_name=app_name,
            user_id=user_id,
            id=session_id,
            state=data.get("state") or {},
            events=events,
        )

    async def list_sessions(
        self,
        *,
        app_name: str,
        user_id: Optional[str] = None,
    ) -> ListSessionsResponse:
        q = self.db.collection("sessions").where("app_name", "==", app_name)
        if user_id is not None:
            q = q.where("user_key", "==", user_id)
        sessions: list[Session] = []
        async for snap in q.stream():
            data = snap.to_dict() or {}
            sessions.append(Session(
                app_name=app_name,
                user_id=data.get("user_key", "") or "",
                id=snap.id,
                state=data.get("state") or {},
                events=[],  # don't replay on list — that's get_session's job
            ))
        log.info(
            "list_sessions: app=%s user=%s count=%d",
            app_name, user_id, len(sessions),
        )
        return ListSessionsResponse(sessions=sessions)

    async def delete_session(
        self,
        *,
        app_name: str,
        user_id: str,
        session_id: str,
    ) -> None:
        doc_ref = self.db.collection("sessions").document(session_id)
        # Wipe the events subcollection first.
        async for ev_snap in doc_ref.collection("events").stream():
            await ev_snap.reference.delete()
        await doc_ref.delete()
        log.info("delete_session: id=%s", session_id)

    async def append_event(self, session: Session, event: Event) -> Event:
        """Persist durable events to Firestore on each append.

        Overrides BaseSessionService.append_event (default impl stores
        in-memory only). We:
          1. Forward to super() to keep ADK's in-memory model consistent.
          2. Skip partial/streaming deltas (avoid 1000s of writes/turn).
          3. Add the event doc to the subcollection + update root timestamps.
        """
        result = await super().append_event(session, event)

        if getattr(event, "partial", False):
            return result  # streaming delta, do not persist

        try:
            doc_ref = self.db.collection("sessions").document(session.id)
            await doc_ref.collection("events").add(_event_to_doc(event))
            await doc_ref.update({
                "updated_at": SERVER_TIMESTAMP,
                "state": session.state or {},
            })
        except Exception as exc:  # noqa: BLE001 — log, don't break the turn
            log.warning(
                "append_event: persist failed for session=%s: %s",
                session.id, exc,
            )
        return result


# ----- (de)serialization helpers -----


def _event_to_doc(event: Event) -> dict:
    """Serialize an ADK Event to a Firestore-friendly dict."""
    if hasattr(event, "model_dump"):
        # Pydantic v2 path — handles Content / Part / FunctionCall etc.
        data = event.model_dump(mode="json", exclude_none=True)
    else:
        # Defensive fallback for older / non-Pydantic Event types.
        data = {
            "author": getattr(event, "author", None),
            "partial": getattr(event, "partial", False),
        }
    data["timestamp"] = SERVER_TIMESTAMP
    return data


def _event_from_doc(data: dict) -> Optional[Event]:
    """Best-effort reconstruct an ADK Event from a Firestore doc."""
    try:
        if hasattr(Event, "model_validate"):
            stripped = {k: v for k, v in data.items() if k != "timestamp"}
            return Event.model_validate(stripped)
        return None
    except Exception as exc:  # noqa: BLE001
        log.warning("event_from_doc: skipping malformed event: %s", exc)
        return None
