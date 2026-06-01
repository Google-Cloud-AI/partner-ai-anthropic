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

"""cc-a2a-bridge — Cloud Run A2A adapter for Claude Code on Gemini Enterprise.

Layout:
  GET  /.well-known/agent-card.json    — AgentCard (Discovery Engine reads this)
  GET  /healthz                         — Cloud Run + LB probe
  POST /                                — A2A JSON-RPC (message/send, message/stream)
                                          — mounted by A2AStarletteApplication

The A2A SDK 0.2.13 (Probe A) builds JSON-RPC handlers around our
`CCAgentExecutor`. The executor:
  1. Resolves the end-user identity → user_key (auth.py).
  2. Get-or-creates a SandboxClaim/cc-u-<user_key> (sandbox.py).
  3. POSTs the user's prompt to the in-cluster router with X-Sandbox-ID,
     X-Sandbox-Namespace, X-Sandbox-Port headers so the router proxies
     to the bound backend pod.
  4. Streams the backend SSE response through translate.py, which drives
     A2A TaskUpdater calls so GE renders working/completed states.
"""

from __future__ import annotations

import logging
import os
import uuid
from contextlib import asynccontextmanager
from typing import AsyncIterator

import datetime as _dt

import google.auth
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.cloud import storage as gcs_storage

import httpx
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.apps import A2AStarletteApplication
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import TaskState
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse

from agent_card import build_agent_card
from auth import resolve_user_key
from downscope import broker as workspace_token_broker
from sandbox import broker
from sign_helpers import safe_filename as _safe_filename
from translate import stream_backend_to_a2a

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("cc-bridge")

# Router internal LB IP — passed via env var from Cloud Run.
# Default is the dev IP we observed during Phase 5 verification; Terraform
# overrides this with the actual allocated IP after k8s apply.
ROUTER_HOST = os.environ.get("ROUTER_HOST", "10.128.15.223")
ROUTER_PORT = int(os.environ.get("ROUTER_PORT", "80"))
SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "cc-sandbox")
SANDBOX_PORT = int(os.environ.get("SANDBOX_PORT", "9000"))

# Backend turn budget. Phase 4 set LiteLLM timeout=300s with 2 retries
# per inference call; a multi-tool turn can easily run 5-8 minutes. The
# router has PROXY_TIMEOUT_SECONDS=1800 (30 min); we set a slightly
# tighter ceiling here so we surface a clear error before the router
# itself times out.
BACKEND_TIMEOUT_S = float(os.environ.get("BACKEND_TIMEOUT_S", "1500"))


class CCAgentExecutor(AgentExecutor):
    """A2A AgentExecutor — one execute() per inbound A2A turn."""

    async def execute(
        self, context: RequestContext, event_queue: EventQueue,
    ) -> None:
        updater = TaskUpdater(
            event_queue=event_queue,
            task_id=context.task_id or uuid.uuid4().hex,
            context_id=context.context_id or uuid.uuid4().hex,
        )
        # Submit + start_work so GE renders the "working" state ASAP.
        await updater.submit()
        await updater.start_work()

        # 1. Resolve end-user identity from request headers.
        request_headers = _headers_from_context(context)
        user_key = await resolve_user_key(request_headers)
        log.info(
            "execute: user_key=%s context_id=%s task_id=%s",
            user_key, context.context_id, context.task_id,
        )

        # 2. Get-or-create the user's SandboxClaim → returns bound Sandbox name.
        try:
            sandbox_name = await broker().get_or_create_claim(user_key)
        except Exception as exc:  # noqa: BLE001 — translate to A2A failure
            log.exception("execute: claim bind failed for user=%s", user_key)
            await updater.failed(
                message=updater.new_agent_message(
                    parts=[],
                    metadata={
                        "error": f"could not bind sandbox: {exc}",
                    },
                ),
            )
            return

        # 3. Extract the user's prompt.
        prompt = context.get_user_input(delimiter="\n").strip()
        if not prompt:
            await updater.failed(
                message=updater.new_agent_message(
                    parts=[],
                    metadata={"error": "empty prompt"},
                ),
            )
            return

        # 4. Mint per-user workspace token (Phase 6). Scoped via CEL CAB to
        # objects under users/<user_key>/ in the snapshots bucket. The pod's
        # own SA has zero bucket IAM — this is the ONLY credential it ever
        # sees for storage. Bridge SA holds objectAdmin bucket-wide.
        try:
            workspace_token = await workspace_token_broker().mint_user_token(user_key)
        except Exception as exc:  # noqa: BLE001
            log.exception("execute: token mint failed for user=%s", user_key)
            await updater.failed(
                message=updater.new_agent_message(
                    parts=[],
                    metadata={"error": f"workspace token mint failed: {exc}"},
                ),
            )
            return

        # 5. POST /execute to the in-cluster router → backend pod.
        url = f"http://{ROUTER_HOST}:{ROUTER_PORT}/execute"
        headers = {
            "Content-Type": "text/plain",
            "X-Sandbox-ID": sandbox_name,
            "X-Sandbox-Namespace": SANDBOX_NAMESPACE,
            "X-Sandbox-Port": str(SANDBOX_PORT),
            "X-Context-Id": context.context_id or "",
            "X-User-Id": user_key,
            "X-Workspace-Token": workspace_token,
            "Accept": "text/event-stream",
        }
        log.info(
            "execute: → POST %s headers={X-Sandbox-ID=%s, X-User-Id=%s, "
            "X-Workspace-Token=<redacted, %d chars>}",
            url, sandbox_name, user_key, len(workspace_token),
        )
        try:
            async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT_S) as client:
                async with client.stream(
                    "POST", url,
                    content=prompt.encode("utf-8"),
                    headers=headers,
                ) as resp:
                    if resp.status_code != 200:
                        body = await resp.aread()
                        msg = (
                            f"backend returned {resp.status_code}: "
                            f"{body[:200].decode('utf-8', errors='replace')}"
                        )
                        log.error("execute: %s", msg)
                        await updater.failed(
                            message=updater.new_agent_message(
                                parts=[],
                                metadata={"error": msg},
                            ),
                        )
                        return
                    # 5. Stream SSE → A2A TaskUpdater events.
                    await stream_backend_to_a2a(
                        _aiter_lines(resp), updater,
                    )
        except httpx.HTTPError as exc:
            log.exception("execute: HTTP error talking to backend")
            await updater.failed(
                message=updater.new_agent_message(
                    parts=[],
                    metadata={"error": f"backend transport failed: {exc}"},
                ),
            )

    async def cancel(
        self, context: RequestContext, event_queue: EventQueue,
    ) -> None:
        # Phase 5: no-op. Phase 6 deletes the SandboxClaim or signals
        # the backend to abort. For now we let the backend turn run to
        # completion and emit a failed status if the upstream cancel
        # propagates via context.
        updater = TaskUpdater(
            event_queue=event_queue,
            task_id=context.task_id or uuid.uuid4().hex,
            context_id=context.context_id or uuid.uuid4().hex,
        )
        await updater.cancel()


async def _aiter_lines(resp: httpx.Response) -> AsyncIterator[bytes]:
    """Async iterator over raw lines (split on \\n, includes empty lines)."""
    buf = b""
    async for chunk in resp.aiter_bytes():
        buf += chunk
        while b"\n" in buf:
            line, _, buf = buf.partition(b"\n")
            yield line
    if buf:
        yield buf


def _headers_from_context(context: RequestContext):
    """Pull request headers off the RequestContext.

    In a2a-sdk 0.2.13, `DefaultCallContextBuilder.build()` already stashes
    `dict(request.headers)` under `state['headers']` on the ServerCallContext.
    The `SimpleRequestContextBuilder` carries that ServerCallContext through
    as `RequestContext.call_context`. So headers are reachable via:

        context.call_context.state["headers"]

    Phase 5 lesson (commit cc7c7b1) thought we needed a custom
    CallContextBuilder. We didn't — that earlier version stamped
    `request_headers` on a non-standard attribute and was never wired up,
    so every request silently fell back to `anon`. The Phase 6 iso-test
    caught it by detecting all users hashing to sha256(anon)[:16] =
    5430eeed859cad61.
    """
    call_context = getattr(context, "call_context", None)
    if call_context is None:
        return {}
    state = getattr(call_context, "state", None) or {}
    headers = state.get("headers")
    return headers or {}


# ----- FastAPI/A2A app wiring -----


def build_app() -> FastAPI:
    card = build_agent_card()
    task_store = InMemoryTaskStore()
    handler = DefaultRequestHandler(
        agent_executor=CCAgentExecutor(),
        task_store=task_store,
    )
    a2a_app = A2AStarletteApplication(
        agent_card=card,
        http_handler=handler,
    )

    app = FastAPI(
        title="cc-a2a-bridge",
        description="A2A adapter for Claude Code on Gemini Enterprise.",
    )

    @app.get("/healthz", response_class=PlainTextResponse)
    async def healthz() -> str:
        return "ok\n"

    @app.post("/workspace/sign")
    async def workspace_sign(
        request: Request,
        x_user_id: str | None = Header(default=None),
    ) -> JSONResponse:
        """Mint a 15-min v4 signed URL for users/<x_user_id>/<rel-path>.

        Phase 8 Path B fallback for artifacts that don't fit inline
        (>5 MB). Called by the backend pod's `get_download_url` ADK
        tool. Caller authentication is via Cloud Run IAM
        (run.invoker grant to cc-a2a-backend GSA — see iam.tf).

        Defense in depth: the object path MUST start with
        users/<x_user_id>/. We never sign anywhere else. We also CAP
        the TTL at 15 min (caller can request shorter; longer is
        rejected).

        Logging policy: log user_id, object path, TTL — NEVER the
        signed URL itself. The URL grants read access without further
        auth for the TTL.
        """
        if not x_user_id:
            raise HTTPException(status_code=400, detail="X-User-Id required")
        body = await request.json()
        rel = body.get("rel_path") or ""
        ttl_minutes = int(body.get("ttl_minutes") or 15)
        ttl_minutes = max(1, min(ttl_minutes, 15))

        if not rel or rel.startswith("/") or ".." in rel.split("/"):
            raise HTTPException(
                status_code=400,
                detail=f"rel_path must be relative, no '..': {rel!r}",
            )
        object_name = f"users/{x_user_id}/{rel}"

        try:
            url, expires_iso = _sign_blob_url(object_name, ttl_minutes)
        except Exception as exc:  # noqa: BLE001 — surface clearly
            log.exception(
                "workspace_sign: failed to mint URL for user=%s rel=%s",
                x_user_id, rel,
            )
            raise HTTPException(
                status_code=500, detail=f"sign failed: {type(exc).__name__}",
            )
        log.info(
            "workspace_sign: signed user=%s object=%s ttl_min=%d expires=%s",
            x_user_id, object_name, ttl_minutes, expires_iso,
        )
        return JSONResponse(content={
            "url": url,
            "expires_at": expires_iso,
            "ttl_minutes": ttl_minutes,
        })

    @app.get("/.well-known/agent-card.json")
    async def agent_card_json() -> JSONResponse:
        # a2a-sdk's AgentCard serialises cleanly with model_dump_json.
        return JSONResponse(content=card.model_dump(mode="json", exclude_none=True))

    # Mount the A2A Starlette app at root (handles POST / and SSE).
    app.mount("/", a2a_app.build())

    return app


def _sign_blob_url(object_name: str, ttl_minutes: int) -> tuple[str, str]:
    """Mint a v4 signed READ URL for a GCS object.

    Uses the bridge's ADC source credentials + IAM signBlob (the bridge
    GSA already has `serviceAccountTokenCreator` on itself from Phase 1,
    which subsumes signBlob). Generates a fresh access token each call
    — signed URLs need a current OAuth2 token to sign with.

    Forces browser-download behavior via Content-Disposition=attachment
    (Phase 12 hotfix). Without this, HTML files render inline in the
    browser instead of downloading — breaking the Path B UX claim.
    """
    bucket_name = os.environ.get(
        "SNAPSHOTS_BUCKET", "cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots",
    )
    creds, _project = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )
    creds.refresh(GoogleAuthRequest())
    signer_email = (
        getattr(creds, "service_account_email", None)
        or os.environ.get(
            "BRIDGE_SA",
            "cc-a2a-bridge@cpe-slarbi-nvd-ant-demos.iam.gserviceaccount.com",
        )
    )
    client = gcs_storage.Client(credentials=creds)
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(object_name)
    expiration = _dt.timedelta(minutes=ttl_minutes)
    safe_name = _safe_filename(object_name)
    url = blob.generate_signed_url(
        version="v4",
        method="GET",
        expiration=expiration,
        service_account_email=signer_email,
        access_token=creds.token,
        response_disposition=f'attachment; filename="{safe_name}"',
    )
    expires_at = (_dt.datetime.now(_dt.timezone.utc) + expiration).isoformat()
    return url, expires_at


app = build_app()


@app.on_event("startup")
async def _start_bg_tasks():
    """Kick off the idle-claim sweeper (Phase 6).

    Cloud Run keeps CPU allocated between requests because cloudrun.tf
    sets `cpu_idle = false` and `min_instance_count = 1`; the asyncio
    background task survives between requests on the warm instance.
    """
    await broker().start_sweeper()


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
