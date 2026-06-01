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

"""ADK tool: queue a /workspace file for delivery as a downloadable artifact.

Phase 10 — MIME-aware routing.

The bridge can deliver any MIME via Path A (inline FilePart/FileWithBytes
as a TaskArtifactUpdateEvent), but the Gemini Enterprise UI applies a
MIME ALLOWLIST on the rendering side, INDEPENDENT of the A2A protocol.
Empirical probe 2026-05-15 showed text/html, application/zip, and
application/octet-stream all surface "Unsupported attachment" in the
UI, while text/csv, text/plain, application/json, application/pdf,
image/png, image/jpeg render cleanly. The probe results live in
`scripts/phase10/mime-probe-results.md`.

Routing rule:
  - If sniffed MIME is in ALLOWLIST_MIMES → Path A (inline chip).
  - Otherwise → Path B (signed URL embedded in assistant text).
    This is the SAFE DEFAULT: "if we haven't verified the GE UI
    renders this type, use a signed URL."

Path B mechanism:
  - emit_artifact calls get_download_url internally to mint a 15-min
    v4 signed URL via the bridge's /workspace/sign endpoint.
  - The tool returns a dict WITHOUT the _cc_artifact sentinel that
    server.py uses to emit SSE artifact events. So no
    TaskArtifactUpdateEvent fires — the URL is just a tool return
    value that the agent surfaces in its reply text per the system
    prompt's instructions.

Constraints (unchanged from Phase 8):
  - Path MUST start with /workspace/ — no traversal, no absolute paths
    outside the workspace tree.
  - File must exist at call time.
  - Max inline size (Path A) = 5 MB. Larger files fall through to
    Path B regardless of MIME.
"""

from __future__ import annotations

import logging
import mimetypes
import os
from typing import Any

import httpx

import request_context
import workspace as workspace_mod

log = logging.getLogger("cc-backend.artifact_tool")

# Max size we'll inline as base64 in a TaskArtifactUpdateEvent. Above
# this, the user should use the get_download_url tool to get a signed
# URL — keeps the SSE payload bounded and GE rendering snappy.
MAX_INLINE_BYTES = 5 * 1024 * 1024

# Belt-and-suspenders mimetype map for extensions Python's stdlib
# `mimetypes` doesn't always agree on. Order matters — first match wins.
_EXTRA_MIME = {
    ".ipynb": "application/x-ipynb+json",
    ".md": "text/markdown",
    ".tsv": "text/tab-separated-values",
    ".jsonl": "application/x-jsonlines",
    ".yaml": "application/x-yaml",
    ".yml": "application/x-yaml",
}

# Phase 10 — GE UI MIME allowlist (verified 2026-05-15 via the
# empirical probe in scripts/phase10/mime-probe-results.md). MIMEs in
# this set render as native download chips in the Gemini Enterprise UI.
# Everything else surfaces "Unsupported attachment" — we route those
# through Path B (signed URL embedded in assistant text). When in
# doubt, route to Path B; that's the safe default.
ALLOWLIST_MIMES = frozenset({
    "text/csv",
    "text/plain",
    "application/json",
    "application/pdf",
    "image/png",
    "image/jpeg",
})


def sniff_mime(path: str) -> str:
    """Return a sensible Content-Type for `path`.

    Lookup order:
      1. Per-extension override map (handles .ipynb, .md, etc.)
      2. Python stdlib `mimetypes.guess_type` (extension-based)
      3. python-magic libmagic sniffing of the first few KB (only used
         when 1+2 returned None — handles files with missing/wrong
         extensions; libmagic doesn't execute the file, just reads
         leading bytes, safe under noexec mounts)
      4. application/octet-stream (final fallback)
    """
    ext = os.path.splitext(path)[1].lower()
    if ext in _EXTRA_MIME:
        return _EXTRA_MIME[ext]
    guessed, _ = mimetypes.guess_type(path)
    if guessed:
        return guessed
    # Magic-byte fallback. Wrapped in a guard so a libmagic install
    # hiccup doesn't break artifact emission entirely — we degrade to
    # octet-stream (which routes to Path B safely).
    try:
        import magic  # python-magic, requires libmagic1
        m = magic.Magic(mime=True)
        sniffed = m.from_file(path)
        if sniffed:
            return sniffed
    except Exception:  # noqa: BLE001
        pass
    return "application/octet-stream"


async def emit_artifact(path: str, tool_context: Any = None) -> dict:
    """Surface a file in /workspace as a downloadable artifact for the user.

    Call this AFTER `claude_code` reports a meaningful file was written —
    HTML prototypes, dashboards, CSV outputs, generated scripts, notebooks.

    Returns a structured dict with a `_cc_artifact` sentinel that
    `server.py` recognizes inside the tool's `function_response` event
    and translates into a SSE `event: artifact` chunk. That chunk is
    sent BEFORE the terminal `event: result`, so `bridge/translate.py`
    can call `TaskUpdater.add_artifact()` while the task is still in
    the `working` state — the GE UI then renders a downloadable chip.

    Args:
        path: Absolute path of the file. Must start with `/workspace/`.

    Returns:
        {
          "_cc_artifact": {path, display_name, mime_type, size, inline_eligible},
          "message": "<human-readable confirmation>"
        }
    """
    if not isinstance(path, str) or not path.startswith("/workspace/"):
        raise ValueError(f"path must start with /workspace/, got: {path!r}")
    abs_real = os.path.realpath(path)
    if not abs_real.startswith("/workspace/"):
        raise ValueError(f"path escapes /workspace/: {path!r}")
    if not os.path.isfile(abs_real):
        raise FileNotFoundError(f"file does not exist: {path}")

    size = os.path.getsize(abs_real)
    rel = os.path.relpath(abs_real, "/workspace")
    mime = sniff_mime(abs_real)
    inline_eligible = size <= MAX_INLINE_BYTES
    in_allowlist = mime in ALLOWLIST_MIMES

    # Path A — chip. Allowed MIME AND under inline cap.
    if in_allowlist and inline_eligible:
        log.info(
            "Path A (inline chip) for mime=%s path=%s size=%d",
            mime, rel, size,
        )
        return {
            "_cc_artifact": {
                "path": abs_real,
                "display_name": rel,
                "mime_type": mime,
                "size": size,
                "inline_eligible": True,
            },
            "message": f"Artifact queued: {rel} ({size} bytes, {mime})",
        }

    # Path B — signed URL. Either MIME not on the verified GE allowlist
    # OR the file is too big to inline. We log the reason loudly (but
    # NEVER the URL itself; signed URLs are sensitive — see Phase 6
    # downscoped-tokens skill).
    if not in_allowlist:
        reason = "not in verified GE allowlist"
    else:
        reason = f"file too large for inline ({size} > {MAX_INLINE_BYTES})"
    log.warning(
        "Path B (signed URL) used for mime=%s path=%s size=%d; reason=%s",
        mime, rel, size, reason,
    )
    url_obj = await get_download_url(path, tool_context=tool_context)
    return {
        "message": (
            f"File ready: {rel} ({size} bytes, {mime}). "
            f"Download URL (valid 15 min): {url_obj['url']}"
        ),
        "download_url": url_obj["url"],
        "expires_at": url_obj["expires_at"],
        "display_name": rel,
        "mime_type": mime,
        "size": size,
        "path_b_reason": reason,
        # Deliberately NO `_cc_artifact` key — that's what tells
        # server.py to emit an SSE artifact event. Without it, the
        # response is plain text the agent inlines in its reply per
        # the system prompt.
    }


# ----- Phase 8 Path B: signed-URL download fallback -----

# The bridge's /workspace/sign endpoint. Set by Cloud Run env in
# infra/terraform/k8s.tf — overridable for tests.
_BRIDGE_SIGN_URL_ENV = "BRIDGE_SIGN_URL"
_BRIDGE_URL_ENV = "BRIDGE_URL"


async def get_download_url(path: str, tool_context: Any = None) -> dict:
    """Return a 15-min signed Cloud Storage URL for a /workspace file.

    Path B fallback for the GE artifact chip. Use this when:
      - the file is too large to inline as a base64-encoded chip
        (over 5 MB; emit_artifact will say so explicitly), OR
      - the user explicitly asks for a download link.

    Mechanism (preserves Phase 1 storage-isolation invariant):
      - The pod's own service account has zero bucket IAM. It cannot
        sign URLs itself.
      - The pod calls the bridge's `/workspace/sign` endpoint via
        Direct VPC egress + a Google-minted ID token (backend GSA has
        roles/run.invoker on the bridge — Phase 8 IAM grant).
      - The bridge signs the URL using IAM signBlob backed by its own
        GSA's `serviceAccountTokenCreator` self-grant. The signed URL
        is scoped to `users/<user_key>/<rel-path>` — never elsewhere.
      - URL TTL is 15 minutes maximum, read-only, single-object.

    Args:
        path: a workspace path. Accepts absolute (/workspace/foo.html)
              or relative (foo.html, sub/bar.csv).

    Returns:
        {"url": "<signed url>", "expires_at": "<iso>",
         "display_name": "<rel path>", "mime_type": "<sniffed>"}
    """
    # 1. Normalize + validate the path.
    if not isinstance(path, str) or not path:
        raise ValueError(f"path must be a non-empty string, got {path!r}")
    if path.startswith("/workspace/"):
        abs_real = os.path.realpath(path)
    elif path.startswith("/"):
        raise ValueError(
            f"absolute paths must start with /workspace/, got: {path!r}"
        )
    else:
        abs_real = os.path.realpath(os.path.join("/workspace", path))
    if not abs_real.startswith("/workspace/"):
        raise ValueError(f"path escapes /workspace/: {path!r}")
    if not os.path.isfile(abs_real):
        raise FileNotFoundError(f"file does not exist: {path}")

    rel = os.path.relpath(abs_real, "/workspace")
    mime = sniff_mime(abs_real)

    # 2. Per-turn identity from contextvars.
    user_id = request_context.current_user_id()
    workspace_token = request_context.current_workspace_token()
    if not user_id:
        raise RuntimeError("no user_id in request context; cannot sign")
    if not workspace_token:
        raise RuntimeError(
            "no X-Workspace-Token in request context; cannot park-before-sign"
        )

    # 3. Park-on-demand. Manifest is the source of truth for what's in
    # GCS; if the file isn't there yet (e.g. the agent just wrote it,
    # background park hasn't fired), park synchronously now so the
    # signed URL points at an existing object.
    log.info(
        "get_download_url: park-on-demand before sign user=%s rel=%s",
        user_id, rel,
    )
    try:
        await workspace_mod.park(token=workspace_token, user_key=user_id)
    except Exception as exc:  # noqa: BLE001
        log.warning(
            "get_download_url: park-on-demand failed (continuing): %s", exc,
        )

    # 4. Mint a Google ID token bound to the bridge audience, then call
    # the bridge's /workspace/sign endpoint.
    bridge_url = os.environ.get(_BRIDGE_URL_ENV, "")
    sign_url = os.environ.get(_BRIDGE_SIGN_URL_ENV, "")
    if not sign_url and bridge_url:
        sign_url = bridge_url.rstrip("/") + "/workspace/sign"
    if not sign_url:
        raise RuntimeError(
            f"neither {_BRIDGE_SIGN_URL_ENV} nor {_BRIDGE_URL_ENV} env set"
        )
    audience = bridge_url or sign_url.rsplit("/workspace/sign", 1)[0]
    id_token = await _fetch_id_token_for(audience)

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            sign_url,
            json={"rel_path": rel, "ttl_minutes": 15},
            headers={
                "Authorization": f"Bearer {id_token}",
                "X-User-Id": user_id,
                "Content-Type": "application/json",
            },
        )
    if resp.status_code != 200:
        log.warning(
            "get_download_url: bridge sign returned %d: %s",
            resp.status_code, resp.text[:200],
        )
        raise RuntimeError(
            f"bridge sign failed: {resp.status_code} {resp.text[:200]}"
        )
    data = resp.json()
    url = data["url"]
    log.info(
        "get_download_url: signed user=%s rel=%s ttl=%dm expires=%s "
        "(url redacted)",
        user_id, rel, data.get("ttl_minutes", 15), data.get("expires_at"),
    )
    return {
        "url": url,
        "expires_at": data.get("expires_at"),
        "display_name": rel,
        "mime_type": mime,
    }


async def _fetch_id_token_for(audience: str) -> str:
    """Fetch a Google-minted ID token bound to `audience` via ADC."""
    import asyncio
    return await asyncio.to_thread(_sync_fetch_id_token, audience)


def _sync_fetch_id_token(audience: str) -> str:
    from google.auth.transport.requests import Request as GAuthRequest
    from google.oauth2 import id_token as _id_token
    return _id_token.fetch_id_token(GAuthRequest(), audience)
