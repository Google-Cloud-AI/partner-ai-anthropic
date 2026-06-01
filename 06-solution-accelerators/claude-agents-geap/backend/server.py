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

"""cc-backend — FastAPI + uvicorn (Phase 4 step 1).

Replaces the stdlib HTTPServer from Phase 3 with an async-native server:

- All request handlers run on the main asyncio event loop (no worker
  thread + asyncio bridge — see PROJECT_PLAN.md "Phase 3 Lesson 3":
  ThreadingHTTPServer + asyncio + gVisor + google.auth metadata fetch
  was flaky; this commit eliminates the thread-bridge variable entirely).
- Multiple concurrent requests are coroutines on the same loop, scaling
  with `uvicorn`'s default worker model.
- SSE via `StreamingResponse` — proven Cloud Run-compatible for Phase 5.

This commit preserves the InMemorySessionService behavior of Phase 3;
the FirestoreSessionService + FirestoreMemoryService swap is the
following commit.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import PlainTextResponse, StreamingResponse

from google.adk.runners import Runner
from google.genai import types

from adk_agent import build_agent
from firestore_session import FirestoreSessionService
from firestore_memory import memory_service as _shared_memory_service
import request_context
import workspace

PORT = int(os.environ.get("PORT", "9000"))
APP_NAME = "cc-backend"
ORCHESTRATOR_NAME = "claude_code_orchestrator"

# Lesson B (Phase 1): the named DB is the single source of truth.
# Surfaced in logs and in the `/execute` SSE result payload.
FIRESTORE_DATABASE = os.environ.get("FIRESTORE_DATABASE", "cc-on-ge")

log = logging.getLogger("cc-backend")


def _prewarm_adc() -> None:
    """Force a metadata-server fetch at module load to cache ADC.

    Phase 3 Lesson 3 mitigation: under gVisor, `asyncio` + worker-thread
    HTTP handlers + google.auth's urllib3-based metadata fetch was flaky
    for `metadata.google.internal`. FastAPI's main-loop model removes the
    thread bridge; ADC prewarm still helps by exercising the metadata
    path at known-good startup time.
    """
    try:
        import google.auth

        creds, project = google.auth.default()
        log.info(
            "ADC pre-warmed: project=%s creds_type=%s",
            project,
            type(creds).__name__,
        )
    except Exception as exc:  # noqa: BLE001 — log and continue
        log.warning("ADC pre-warm failed (non-fatal): %s", exc)


_prewarm_adc()

# Phase 4: Firestore-backed Session + Memory. Sessions key on
# A2A context_id (passed via X-Context-Id header). Memory keys on
# user_id (X-User-Id). Both target the named `cc-on-ge` DB
# (Phase 1 Lesson B). Pod restart is transparent — the next turn for
# the same context_id replays events from Firestore.
PROJECT = os.environ.get("VERTEXAI_PROJECT", "cpe-slarbi-nvd-ant-demos")

SESSION_SERVICE = FirestoreSessionService(
    project=PROJECT, database=FIRESTORE_DATABASE,
)
MEMORY_SERVICE = _shared_memory_service()  # singleton from firestore_memory.py

AGENT = build_agent()
RUNNER = Runner(
    app_name=APP_NAME,
    agent=AGENT,
    session_service=SESSION_SERVICE,
    memory_service=MEMORY_SERVICE,
)


app = FastAPI(
    title="cc-backend",
    description="Claude Code on Gemini Enterprise — backend pod",
)


@app.get("/healthz", response_class=PlainTextResponse)
async def healthz() -> str:
    return "ok\n"


@app.get("/", response_class=PlainTextResponse)
async def root() -> str:
    return (
        "cc-backend (FastAPI). POST /execute with prompt body and "
        "optional X-Context-Id + X-User-Id headers.\n"
    )


# Per-user lock for park operations — avoid two concurrent parks racing
# on the same /workspace tree (turns won't actually overlap because the
# bridge serialises per user with an asyncio.Lock, but this is belt-and-
# suspenders inside the pod).
_PARK_LOCKS: dict[str, asyncio.Lock] = {}


def _park_lock(user_id: str) -> asyncio.Lock:
    lock = _PARK_LOCKS.get(user_id)
    if lock is None:
        lock = asyncio.Lock()
        _PARK_LOCKS[user_id] = lock
    return lock


@app.post("/execute")
async def execute(
    request: Request,
    x_context_id: str | None = Header(default=None),
    x_user_id: str | None = Header(default=None),
    x_workspace_token: str | None = Header(default=None),
):
    body = await request.body()
    prompt = body.decode("utf-8", errors="replace").strip()
    if not prompt:
        raise HTTPException(
            status_code=400,
            detail="POST body must contain the prompt as plain text",
        )

    # Phase 5's bridge will set X-Context-Id (== A2A context_id) and
    # X-User-Id (== user_key). For local smoke we generate stable enough
    # defaults.
    context_id = x_context_id or f"smoke-{uuid.uuid4().hex[:12]}"
    user_id = x_user_id or "phase4-smoke-user"

    # Phase 8: contextvars carry per-turn identity to tool functions
    # (workspace_tools, artifact_tool.get_download_url) without
    # polluting persistent session state.
    request_context.set_for_request(
        user_id=user_id, workspace_token=x_workspace_token,
    )

    # Phase 6: restore on first turn of a fresh claim. The pod's own SA
    # has zero bucket IAM; x_workspace_token is the ONLY storage credential.
    # If absent (legacy smoke without the bridge), skip — workspace stays
    # empty/local-only.
    if x_workspace_token and workspace.needs_restore():
        log.info(
            "execute: first turn on fresh pod — restoring workspace for user=%s",
            user_id,
        )
        try:
            await workspace.restore(token=x_workspace_token, user_key=user_id)
        except Exception as exc:  # noqa: BLE001 — surface but don't fail turn
            log.exception("execute: workspace restore failed: %s", exc)

    return StreamingResponse(
        _run_turn_with_park(
            context_id=context_id, user_id=user_id, prompt=prompt,
            workspace_token=x_workspace_token,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


async def _run_turn_with_park(
    *, context_id: str, user_id: str, prompt: str,
    workspace_token: str | None,
):
    """Run the turn, then fire a background park task after streaming completes."""
    async for chunk in _run_turn(
        context_id=context_id, user_id=user_id, prompt=prompt,
    ):
        yield chunk
    # Streaming complete — schedule park as a background task. Best-effort;
    # if the pod dies before park finishes, the next turn just won't see
    # the latest changes. Cloud Run worker stays alive on the bridge; the
    # backend pod has no idle timeout that would cancel this.
    if workspace_token:
        asyncio.create_task(
            _background_park(user_id=user_id, token=workspace_token),
        )


async def _background_park(*, user_id: str, token: str) -> None:
    async with _park_lock(user_id):
        # Phase 9 — purge /workspace/.trash entries older than 7 days
        # BEFORE parking so the manifest stays clean and GCS doesn't
        # accumulate stale soft-deleted copies. Pure local op; safe
        # to run inside the per-user lock.
        try:
            from tools.workspace_tools import purge_old_trash
            purged = purge_old_trash()
            if purged:
                log.info("trash purge before park: user=%s removed=%d", user_id, purged)
        except Exception:  # noqa: BLE001
            log.exception("trash purge before park failed; continuing")

        try:
            manifest = await workspace.park(token=token, user_key=user_id)
            log.info(
                "park complete: user=%s files=%d",
                user_id, len(manifest.get("files", [])),
            )
        except Exception:  # noqa: BLE001
            log.exception("park failed for user=%s", user_id)


async def _run_turn(*, context_id: str, user_id: str, prompt: str):
    """Drive the ADK Runner for one turn, yielding SSE chunks."""
    # Get-or-create the session keyed on context_id (Phase 5 bridge =>
    # A2A context_id). InMemorySessionService for this commit; Firestore
    # next commit.
    session = await SESSION_SERVICE.get_session(
        app_name=APP_NAME, user_id=user_id, session_id=context_id,
    )
    if session is None:
        await SESSION_SERVICE.create_session(
            app_name=APP_NAME, user_id=user_id, session_id=context_id,
        )

    new_message = types.Content(role="user", parts=[types.Part(text=prompt)])
    try:
        async for event in RUNNER.run_async(
            user_id=user_id, session_id=context_id, new_message=new_message,
        ):
            for chunk in _format_event(event):
                yield chunk
    except Exception as exc:  # noqa: BLE001 — surface as SSE error
        log.exception("turn failed for context_id=%s", context_id)
        yield _sse("error", {"type": "error", "message": str(exc)})


def _format_event(event):
    """Convert one ADK event into one or more SSE chunks (str).

    Phase 8: if any tool_result carries the `_cc_artifact` sentinel,
    emit a SSE `event: artifact` chunk for each one BEFORE the regular
    working `event` chunk. This guarantees artifacts arrive before any
    terminal `event: result` (a2a-protocol skill: "artifacts after a
    terminal event are ignored"). The artifact chunk includes
    base64-encoded file bytes for files <= MAX_INLINE_BYTES.
    """
    author = getattr(event, "author", None)
    partial = bool(getattr(event, "partial", False))
    parts_out = _serialize_parts(event)

    # 1. Artifact chunks first (if any tool_result has _cc_artifact).
    for part in parts_out:
        if part.get("type") != "tool_result":
            continue
        resp = part.get("response") or {}
        if not isinstance(resp, dict):
            continue
        art = resp.get("_cc_artifact")
        if not art:
            continue
        yield _sse_artifact(art)

    # 2. The regular event chunk (text / tool_use / tool_result lines).
    yield _sse(
        "event",
        {
            "type": "event",
            "author": author,
            "partial": partial,
            "parts": parts_out,
        },
    )

    try:
        is_final = bool(event.is_final_response())
    except (AttributeError, TypeError):
        is_final = (
            not partial
            and author == ORCHESTRATOR_NAME
            and any(p.get("type") == "text" for p in parts_out)
        )

    # 3. Terminal result LAST (after artifacts + working event).
    if is_final:
        text = "".join(p["text"] for p in parts_out if p.get("type") == "text")
        yield _sse(
            "result",
            {
                "type": "result",
                "subtype": "success",
                "author": author,
                "result": text,
                "firestore_database": FIRESTORE_DATABASE,
            },
        )


def _sse_artifact(art: dict) -> str:
    """Render one artifact entry as a SSE `event: artifact` chunk.

    Inlines file bytes as base64 if size <= MAX_INLINE_BYTES; otherwise
    omits bytes and signals `truncated=true` so the bridge can surface
    a "request a signed URL" hint.
    """
    import base64

    payload = {
        "type": "artifact",
        "display_name": art.get("display_name") or "",
        "mime_type": art.get("mime_type") or "application/octet-stream",
        "size": int(art.get("size") or 0),
        "inline_eligible": bool(art.get("inline_eligible")),
    }
    path = art.get("path") or ""
    if payload["inline_eligible"] and path:
        try:
            with open(path, "rb") as f:
                data = f.read()
            payload["bytes_b64"] = base64.b64encode(data).decode("ascii")
            log.info(
                "artifact: emitting inline name=%s size=%d mime=%s",
                payload["display_name"], payload["size"], payload["mime_type"],
            )
        except OSError as exc:
            log.warning(
                "artifact: failed to read %s for inline emit: %s",
                path, exc,
            )
            payload["error"] = f"could not read file: {exc}"
    else:
        payload["truncated"] = True
        log.info(
            "artifact: emitting metadata-only (too large) name=%s size=%d",
            payload["display_name"], payload["size"],
        )
    return _sse("artifact", payload)


def _serialize_parts(event):
    out: list[dict] = []
    content = getattr(event, "content", None)
    if not content:
        return out
    for p in getattr(content, "parts", None) or []:
        if getattr(p, "text", None):
            out.append({"type": "text", "text": p.text})
        elif getattr(p, "function_call", None):
            fc = p.function_call
            args = dict(fc.args) if getattr(fc, "args", None) else {}
            out.append({"type": "tool_use", "name": fc.name, "args": args})
        elif getattr(p, "function_response", None):
            fr = p.function_response
            resp = dict(fr.response) if getattr(fr, "response", None) else {}
            out.append({"type": "tool_result", "name": fr.name, "response": resp})
    return out


def _sse(event_name: str, payload: dict) -> str:
    return f"event: {event_name}\ndata: {json.dumps(payload)}\n\n"


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    log.info(
        "cc-backend (FastAPI) starting on :%d (FIRESTORE_DATABASE=%s)",
        PORT,
        FIRESTORE_DATABASE,
    )
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=PORT,
        log_level="info",
        access_log=True,
    )


if __name__ == "__main__":
    main()
