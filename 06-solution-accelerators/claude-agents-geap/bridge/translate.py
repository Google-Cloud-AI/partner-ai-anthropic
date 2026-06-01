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

"""Translate backend SSE stream → A2A TaskUpdater events.

Consumes the SSE stream emitted by backend `server.py /execute` (Phase 3+4
event shape) and drives the A2A TaskUpdater so Gemini Enterprise sees
streaming `working` updates, tool activity, and a terminal
`completed`/`failed` status.

Backend SSE schema (Phase 4 commit e85131e):

  event: event
  data: {"type":"event", "author":"...", "partial":<bool>, "parts":[
           {"type":"text", "text":"..."}                      |
           {"type":"tool_use", "name":"...", "args":{...}}    |
           {"type":"tool_result", "name":"...", "response":...}
         ]}

  event: result
  data: {"type":"result", "subtype":"success", "author":"...",
         "result":"<final text>", "firestore_database":"..."}

  event: error
  data: {"type":"error", "message":"..."}

This module's job is to map each of those into one or more
`TaskStatusUpdateEvent`/`TaskArtifactUpdateEvent`s on the A2A
EventQueue. Artifact emission is plumbed but inert for Phase 5
(backend currently emits `emit_artifact` as a `tool_use` event; Phase 6
will introduce a dedicated artifact event).
"""

from __future__ import annotations

import json
import logging
from typing import Any, AsyncIterator

import base64

from a2a.server.tasks import TaskUpdater
from a2a.types import (
    FilePart,
    FileWithBytes,
    Part,
    TaskState,
    TextPart,
)

log = logging.getLogger("cc-bridge.translate")

# Truncate long tool output to keep the working-pane readable. Backend
# returns full output in the underlying event; this is just for the
# rendered activity-line preview.
_TOOL_OUTPUT_PREVIEW_CHARS = 300


async def stream_backend_to_a2a(
    sse_lines: AsyncIterator[bytes], updater: TaskUpdater,
) -> None:
    """Pump backend SSE lines through the A2A TaskUpdater.

    `sse_lines` is an async iterator of raw bytes lines (already split
    on \\n). We accumulate `data:` payloads per event and dispatch when
    we see a blank line (SSE record separator).
    """
    event_type: str | None = None
    data_buf: list[str] = []

    async for raw in sse_lines:
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            # Blank line — record terminator. Dispatch accumulated record.
            if event_type or data_buf:
                await _dispatch(event_type, "\n".join(data_buf), updater)
            event_type = None
            data_buf = []
            continue
        if line.startswith("event:"):
            event_type = line[len("event:"):].strip()
        elif line.startswith("data:"):
            data_buf.append(line[len("data:"):].lstrip())
        # Any other field (`id:`, `retry:`, comments starting with `:`)
        # is ignored — we don't need them.

    # Flush trailing record if backend didn't terminate with a blank line.
    if event_type or data_buf:
        await _dispatch(event_type, "\n".join(data_buf), updater)


async def _dispatch(
    event_type: str | None, data: str, updater: TaskUpdater,
) -> None:
    """Route one SSE record to the right TaskUpdater call."""
    try:
        payload = json.loads(data) if data else {}
    except json.JSONDecodeError:
        log.warning("translate: non-JSON SSE data, dropping: %r", data[:200])
        return

    ptype = payload.get("type") or event_type
    if ptype == "event":
        await _handle_event(payload, updater)
    elif ptype == "artifact":
        await _handle_artifact(payload, updater)
    elif ptype == "result":
        await _handle_result(payload, updater)
    elif ptype == "error":
        await _handle_error(payload, updater)
    else:
        log.debug("translate: unknown event type %r — dropping", ptype)


async def _handle_event(payload: dict, updater: TaskUpdater) -> None:
    """An incremental working update — text, tool call, or tool result."""
    # We deliberately drop `partial` events — backend emits one event per
    # streaming delta and one consolidated non-partial event at the end.
    # Forwarding partials floods GE with redundant `working` updates.
    if payload.get("partial"):
        return

    for part in payload.get("parts", []):
        rendered = _render_part(part)
        if not rendered:
            continue
        await updater.update_status(
            state=TaskState.working,
            message=updater.new_agent_message(
                parts=[Part(root=TextPart(text=rendered))],
            ),
        )


async def _handle_artifact(payload: dict, updater: TaskUpdater) -> None:
    """Phase 8: backend `event: artifact` → A2A TaskArtifactUpdateEvent.

    Must fire BEFORE the terminal `complete()`/`failed()` event — the
    a2a-protocol skill notes that artifacts after a terminal status are
    ignored by the host. server.py guarantees ordering by emitting the
    artifact SSE chunk inside the same iteration of _format_event where
    the tool_result carrying _cc_artifact appears, well before the
    final response event.

    Inline-bytes path (small files, base64 in `bytes_b64`):
      FilePart(file=FileWithBytes(bytes=b64, name=display_name, mimeType=...))

    Truncated path (large files, no bytes): we emit a TextPart with a
    user-facing hint. The agent's response in the same turn can use
    `get_download_url` to provide a signed URL.
    """
    display_name = payload.get("display_name") or "artifact"
    mime = payload.get("mime_type") or "application/octet-stream"
    size = int(payload.get("size") or 0)
    b64 = payload.get("bytes_b64")
    truncated = bool(payload.get("truncated"))
    err = payload.get("error")

    if err:
        log.warning(
            "translate.artifact: backend emitted error for %s: %s",
            display_name, err,
        )
        # Surface as a working-status text part — the chip itself is gone,
        # but the user sees what went wrong without failing the turn.
        await updater.update_status(
            state=TaskState.working,
            message=updater.new_agent_message(
                parts=[Part(root=TextPart(
                    text=f"⚠ artifact '{display_name}' unavailable: {err}",
                ))],
            ),
        )
        return

    if b64 and not truncated:
        # Inline: build a FilePart with FileWithBytes.
        try:
            # Sanity-validate the base64 (catches truncation/corruption).
            base64.b64decode(b64, validate=True)
        except (ValueError, base64.binascii.Error) as exc:
            log.warning(
                "translate.artifact: invalid base64 for %s: %s",
                display_name, exc,
            )
            return
        log.info(
            "translate.artifact: emitting inline chip name=%s size=%d mime=%s",
            display_name, size, mime,
        )
        await updater.add_artifact(
            parts=[Part(root=FilePart(file=FileWithBytes(
                bytes=b64, name=display_name, mimeType=mime,
            )))],
            name=display_name,
        )
        return

    # Truncated / metadata-only: emit a text hint instead of a chip.
    hint = (
        f"📎 {display_name} ({size:,} bytes, {mime}) — too large to "
        "inline. Ask the agent for a signed download URL "
        "(e.g. \"give me a download link for that file\")."
    )
    log.info(
        "translate.artifact: emitting truncated hint name=%s size=%d",
        display_name, size,
    )
    await updater.update_status(
        state=TaskState.working,
        message=updater.new_agent_message(
            parts=[Part(root=TextPart(text=hint))],
        ),
    )


async def _handle_result(payload: dict, updater: TaskUpdater) -> None:
    text = payload.get("result") or "(empty)"
    msg = updater.new_agent_message(
        parts=[Part(root=TextPart(text=text))],
    )
    await updater.complete(message=msg)


async def _handle_error(payload: dict, updater: TaskUpdater) -> None:
    text = payload.get("message") or "(no message)"
    msg = updater.new_agent_message(
        parts=[Part(root=TextPart(text=f"Error: {text}"))],
    )
    await updater.failed(message=msg)


def _render_part(part: dict[str, Any]) -> str | None:
    """Render one backend `parts[]` entry into a human-readable line."""
    pt = part.get("type")
    if pt == "text":
        return part.get("text") or None
    if pt == "tool_use":
        name = part.get("name", "?")
        args = part.get("args") or {}
        args_str = _format_args(args)
        return f"⏵ {name}({args_str})"
    if pt == "tool_result":
        name = part.get("name", "?")
        resp = part.get("response")
        # Backend wraps tool returns as `{"result": "..."}` — render that
        # if present, else show the whole response.
        if isinstance(resp, dict) and "result" in resp:
            text = str(resp["result"])
        else:
            text = json.dumps(resp, default=str) if resp is not None else ""
        if len(text) > _TOOL_OUTPUT_PREVIEW_CHARS:
            text = text[: _TOOL_OUTPUT_PREVIEW_CHARS] + " …"
        return f"✓ {name} → {text}"
    return None


def _format_args(args: dict) -> str:
    """Compact one-line args repr for the activity line."""
    if not args:
        return ""
    parts = []
    for k, v in args.items():
        vs = json.dumps(v, default=str)
        if len(vs) > 80:
            vs = vs[:77] + "..."
        parts.append(f"{k}={vs}")
    return ", ".join(parts)
