"""Per-request context for tools running inside an ADK turn.

ADK tool functions receive `tool_context` but it's tied to the
SESSION's persistent state, not the in-flight HTTP request. Tools that
need per-turn data like the workspace token (Phase 6) or the user_key
(Phase 7+) get them from contextvars set by server.py at /execute
entry — contextvars propagate cleanly through asyncio task boundaries.

Don't reach for session.state for these — they MUST be ephemeral.
Persisting a workspace token across turns would mean re-using an
expired CAB token; the bridge mints fresh ones each turn.
"""

from __future__ import annotations

import contextvars
from typing import Optional

_user_id: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    "cc_user_id", default=None,
)
_workspace_token: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    "cc_workspace_token", default=None,
)


def set_for_request(*, user_id: str, workspace_token: Optional[str]) -> None:
    _user_id.set(user_id)
    _workspace_token.set(workspace_token)


def current_user_id() -> Optional[str]:
    return _user_id.get()


def current_workspace_token() -> Optional[str]:
    return _workspace_token.get()
