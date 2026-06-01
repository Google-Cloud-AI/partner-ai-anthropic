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

"""Workspace park/restore for cc-backend.

The pod has zero storage IAM (Phase 1 invariant). Every workspace
operation uses the per-turn `X-Workspace-Token` minted by the bridge,
which is scoped via Credential Access Boundary to objects under
`users/<user_key>/` (proven in Phase 6 Probe A).

Restore is **manifest-driven** because the CAB-scoped token can't list
the bucket (Probe C verified the 403 on `list_blobs`). The manifest at
`gs://<bucket>/users/<user_key>/_manifest.json` is the authoritative
inventory:

    {
      "version": 1,
      "user_key": "<16-hex>",
      "updated_at": "<ISO-8601>",
      "files": [
        {"path": "rel/path.txt", "size": 123, "mtime": 1.7e9, "sha256": "..."}
      ]
    }

Park algorithm:
  1. Read old manifest (single GET; allowed by CAB).
  2. Walk /workspace, hash each file, build new manifest.
  3. For each new/changed file (compared by sha256), upload.
  4. For each path in old_manifest but not in new_manifest, delete remote.
  5. Write new manifest.

No bucket-level list anywhere. Restore reads the manifest and downloads
each listed file.

CACHE/IGNORE patterns:
  We skip common pollution: __pycache__, node_modules, .git/objects.
  Tune EXCLUDE_PATTERNS as we learn what user workflows produce.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import json
import logging
import os
from pathlib import Path
from typing import Optional

from google.cloud import storage
from google.cloud.exceptions import NotFound
from google.oauth2.credentials import Credentials

log = logging.getLogger("cc-backend.workspace")

WORKSPACE_ROOT = Path(os.environ.get("WORKSPACE_PATH", "/workspace"))
RESTORE_SENTINEL = WORKSPACE_ROOT / ".cc-restored"

SNAPSHOTS_BUCKET = os.environ.get(
    "SNAPSHOTS_BUCKET", "cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots",
)

# Paths excluded from park. Match against POSIX path strings relative to
# WORKSPACE_ROOT.
EXCLUDE_PATTERNS = (
    "__pycache__/",
    "/node_modules/",
    "node_modules/",
    "/.git/objects/",
    ".cc-restored",  # the sentinel itself
)


def _client_from_token(token: str) -> storage.Client:
    """Build a google-cloud-storage Client from a raw OAuth2 access token.

    The pod never sees the bridge's source credentials, only the CAB-
    derived short-lived token. Cred type is plain OAuth2 (no refresh
    function); the bridge will mint a fresh one on each turn.
    """
    creds = Credentials(token=token)
    return storage.Client(credentials=creds)


def _sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _included(rel_posix: str) -> bool:
    return not any(pat in rel_posix or rel_posix.endswith(pat.rstrip("/"))
                   for pat in EXCLUDE_PATTERNS)


def _scan_local(root: Path) -> list[dict]:
    files: list[dict] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if not _included(rel):
            continue
        try:
            st = path.stat()
            files.append({
                "path": rel,
                "size": st.st_size,
                "mtime": st.st_mtime,
                "sha256": _sha256_of(path),
            })
        except (FileNotFoundError, PermissionError) as exc:
            log.warning("workspace: skipping %s: %s", rel, exc)
    return files


def _manifest_blob_name(user_key: str) -> str:
    return f"users/{user_key}/_manifest.json"


def _object_blob_name(user_key: str, rel: str) -> str:
    return f"users/{user_key}/{rel}"


async def restore(*, token: str, user_key: str) -> dict:
    """Manifest-driven download to WORKSPACE_ROOT. Sync work in a thread."""
    return await asyncio.to_thread(_sync_restore, token, user_key)


def _sync_restore(token: str, user_key: str) -> dict:
    client = _client_from_token(token)
    bucket = client.bucket(SNAPSHOTS_BUCKET)
    mref = bucket.blob(_manifest_blob_name(user_key))
    try:
        manifest = json.loads(mref.download_as_text())
    except NotFound:
        log.info("workspace.restore: no manifest for user=%s — fresh workspace", user_key)
        WORKSPACE_ROOT.mkdir(parents=True, exist_ok=True)
        RESTORE_SENTINEL.touch()
        return {"version": 1, "user_key": user_key, "files": []}

    log.info(
        "workspace.restore: user=%s manifest_files=%d", user_key,
        len(manifest.get("files", [])),
    )
    WORKSPACE_ROOT.mkdir(parents=True, exist_ok=True)
    for entry in manifest.get("files", []):
        rel = entry["path"]
        target = WORKSPACE_ROOT / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        bucket.blob(_object_blob_name(user_key, rel)).download_to_filename(str(target))
    RESTORE_SENTINEL.touch()
    return manifest


async def park(*, token: str, user_key: str) -> dict:
    """Idempotent park: diff against old manifest, upload only what changed."""
    return await asyncio.to_thread(_sync_park, token, user_key)


def _sweep_scratchpad_temps(local_root: Path) -> int:
    """Remove agent-side scratchpad temp files before park.

    Phase 10 sweep: pre-Phase-10, when read_workspace_file truncated
    universally at 4000 chars, the agent occasionally worked around the
    truncation by asking claude_code to write `_user_form_part1.txt`,
    `_user_form_part2.txt` etc. Phase 10 Step 3 fixed the root cause
    (full-file read mode with `max_bytes=None`), but old workspaces may
    have left residue. This sweep makes park idempotently clean — the
    next manifest won't carry over these scratchpad files, and they
    won't propagate to a fresh pod via restore.

    Pattern: top-level files matching `_<anything>_part<anything>` with
    extension .txt | .html | .json | .md. Only top-level — nested
    `_part` files are presumably user intentional.
    """
    import re
    pattern = re.compile(r'^_.+_part.*\.(txt|html|json|md)$', re.IGNORECASE)
    removed = 0
    if not local_root.exists() or not local_root.is_dir():
        return 0
    for entry in local_root.iterdir():
        if entry.is_file() and pattern.match(entry.name):
            try:
                entry.unlink()
                log.info("workspace.park: swept scratchpad temp %s", entry.name)
                removed += 1
            except OSError as exc:
                log.warning(
                    "workspace.park: failed to sweep %s: %s",
                    entry.name, exc,
                )
    if removed:
        log.info("workspace.park: scratchpad sweep removed %d files", removed)
    return removed


def _sync_park(token: str, user_key: str) -> dict:
    if not WORKSPACE_ROOT.exists():
        log.info("workspace.park: %s missing — nothing to park", WORKSPACE_ROOT)
        return {"version": 1, "user_key": user_key, "files": []}

    # Phase 10 — sweep agent-side scratchpad temp files BEFORE we
    # build the new manifest. Pre-sweep means the manifest reflects
    # the cleaned workspace; post-park prune step (using OLD manifest
    # vs new) doesn't see these files at all.
    _sweep_scratchpad_temps(WORKSPACE_ROOT)

    client = _client_from_token(token)
    bucket = client.bucket(SNAPSHOTS_BUCKET)

    # 1. Read OLD manifest (for diff/prune). If missing, this is the first park.
    mref = bucket.blob(_manifest_blob_name(user_key))
    try:
        old_manifest = json.loads(mref.download_as_text())
        old_by_path = {e["path"]: e for e in old_manifest.get("files", [])}
    except NotFound:
        old_manifest = None
        old_by_path = {}

    # 2. Walk current workspace.
    new_files = _scan_local(WORKSPACE_ROOT)
    new_by_path = {e["path"]: e for e in new_files}

    # 3. Upload changed/new (sha256-based diff).
    uploaded = 0
    for entry in new_files:
        rel = entry["path"]
        prev = old_by_path.get(rel)
        if prev and prev.get("sha256") == entry["sha256"]:
            continue  # unchanged
        local = WORKSPACE_ROOT / rel
        bucket.blob(_object_blob_name(user_key, rel)).upload_from_filename(str(local))
        uploaded += 1

    # 4. Prune remote files in old manifest but not in new.
    deleted = 0
    for rel in old_by_path.keys() - new_by_path.keys():
        try:
            bucket.blob(_object_blob_name(user_key, rel)).delete()
            deleted += 1
        except NotFound:
            pass  # already gone

    # 5. Write new manifest.
    new_manifest = {
        "version": 1,
        "user_key": user_key,
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "files": new_files,
    }
    mref.upload_from_string(
        json.dumps(new_manifest, indent=2),
        content_type="application/json",
    )
    log.info(
        "workspace.park: user=%s total=%d uploaded=%d deleted=%d",
        user_key, len(new_files), uploaded, deleted,
    )
    return new_manifest


def needs_restore() -> bool:
    """True if /workspace has never been restored on this pod."""
    return not RESTORE_SENTINEL.exists()
