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
