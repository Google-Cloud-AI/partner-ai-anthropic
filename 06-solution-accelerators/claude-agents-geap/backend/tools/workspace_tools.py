"""ADK tools for natural-language workspace management.

Phase 9. Five FunctionTools the agent calls when the user wants to
browse, read, rename, or delete files in their /workspace. All tools
respect the Phase 6 isolation invariant: the pod's own SA has zero
bucket IAM, and any storage access uses the per-turn workspace token
(injected by the bridge, fetched via `request_context`).

Tools:
  - list_workspace(path=".") — formatted listing with hints about
    artifact-like vs build-cruft entries
  - read_workspace_file(path) — file contents, truncated to ~4000
    chars; refuses binary
  - delete_workspace_file(path, confirm=False) — SOFT-DELETE on first
    call: moves to /workspace/.trash/<ts>-<basename>, returns confirm
    instructions. Hard-deletes (local + GCS) when called with
    confirm=True. (Lesson: agentic tools mis-target files at non-zero
    rates; a recovery path is essentially free.)
  - move_workspace_file(src, dst) — rename within /workspace; parks
    after.
  - get_download_url is re-exported from tools.artifact_tool for naming
    consistency in adk_agent.py's tool list.

Mutations (delete, move) trigger a background park so the next pod
sees the change. Park also purges /workspace/.trash entries older
than 7 days (cheap, bounds storage growth, no manual cleanup).
"""

from __future__ import annotations

import asyncio
import datetime as _dt
import logging
import os
import shutil
from pathlib import Path
from typing import Any

import request_context
import workspace as workspace_mod
from tools.artifact_tool import sniff_mime, get_download_url  # noqa: F401

log = logging.getLogger("cc-backend.workspace_tools")

WORKSPACE_ROOT = Path("/workspace")
TRASH_DIR = WORKSPACE_ROOT / ".trash"

# Directories never surfaced in list_workspace and never parked.
# Matches workspace.py's EXCLUDE_PATTERNS plus a few more obvious
# build / cache trees.
_HIDDEN_DIRS = {
    "__pycache__", "node_modules", ".venv", "venv", ".git",
    ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next",
    ".cache", "dist", "build", ".tox", ".trash",
}

# Heuristic for which extensions look like deliverables vs cruft.
_ARTIFACT_EXTS = {
    ".html", ".htm", ".csv", ".tsv", ".pdf", ".py", ".js", ".ts",
    ".tsx", ".jsx", ".ipynb", ".json", ".jsonl", ".md", ".sh",
    ".sql", ".yaml", ".yml", ".xml", ".txt", ".rtf", ".docx",
    ".pptx", ".xlsx",
}

# Default max bytes returned by read_workspace_file when the agent
# wants a "peek". Truncate beyond this to keep tool output bounded.
_READ_DEFAULT_MAX = 4000

# Hard ceiling on full-file reads. Above this, refuse with a hint
# pointing at get_download_url — the agent should never need to inline
# a 500 KB file into the LLM context just to "show" it.
_READ_HARD_CEILING = 200_000

# Heuristic: if the first 8 KB contains a NUL byte, call the file binary.
_BINARY_PROBE_BYTES = 8192


# ----- Phase 12 hotfix: ADK function-calling type coercion -----
#
# ADK function-calling delivers tool arguments as JSON values, which
# means everything the LLM emits as a JSON string arrives as a Python
# str — even when our Python signature says `int` or `bool`. Pre-Phase-
# 12 hotfix this caused two production bugs:
#   1. `read_workspace_file.max_bytes` arriving as "4000" crashed every
#      read with `TypeError: '>=' not supported between instances of
#      'str' and 'int'`.
#   2. `delete_workspace_file.confirm` arriving as "false" was treated
#      as truthy by `if confirm:` and HARD-DELETED the file. Silent
#      data loss.
# The fix is two coercion helpers, applied at the top of each tool.


def _coerce_max_bytes(value):
    """Normalise the `max_bytes` arg to int | None.

    None       → None (full-read mode)
    int        → int (as-is)
    "1234"     → 1234 (string-encoded int from function-calling)
    "abc"/""   → _READ_DEFAULT_MAX (safe fallback; logged as warning)
    other type → _READ_DEFAULT_MAX

    Never raises. Garbage falls back to the truncated-default rather
    than crashing the agent's read.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        # bool is a subclass of int in Python; surface as int. True→1,
        # False→0. Caller probably didn't intend either; coerce to
        # default and log.
        log.warning(
            "max_bytes arrived as bool (%r); coercing to default %d",
            value, _READ_DEFAULT_MAX,
        )
        return _READ_DEFAULT_MAX
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        s = value.strip()
        if s.lower() == "none":
            return None
        try:
            return int(s)
        except ValueError:
            log.warning(
                "max_bytes arrived as non-numeric string %r; "
                "coercing to default %d",
                value, _READ_DEFAULT_MAX,
            )
            return _READ_DEFAULT_MAX
    log.warning(
        "max_bytes arrived as unexpected type %s (value=%r); "
        "coercing to default %d",
        type(value).__name__, value, _READ_DEFAULT_MAX,
    )
    return _READ_DEFAULT_MAX


# SAFE-BY-DEFAULT confirm coercion (Phase 9 Lesson 8.13 intent):
#
# Truthy (permanent delete) ONLY for explicit confirmation values:
#     True, "true", "True", "1", 1
# Falsy (soft-delete to trash) for EVERYTHING ELSE — including
#     False, "false", "False", "0", "", None, "garbage", unknown types
#
# Rule: if there is ANY ambiguity in the input, the file goes to
# trash, not the void. The default fails toward "recoverable," never
# toward "permanent." Soft-delete is reversible; hard-delete is not.
_CONFIRM_TRUE_VALUES = frozenset({True, "true", "True", "1", 1})


def _coerce_confirm(value) -> bool:
    """Map confirm input to a strict bool per the safe-by-default rule
    above. Returns True ONLY for the explicit confirmation set.
    """
    return value in _CONFIRM_TRUE_VALUES

# .trash auto-purge horizon.
_TRASH_TTL_DAYS = 7


# ----- shared validators -----


def _resolve_within_workspace(path: str) -> Path:
    """Resolve a user-supplied path to an absolute /workspace path.

    Accepts:
      - "foo.html"  (relative; joins under /workspace)
      - "sub/bar.csv"
      - "/workspace/foo.html"  (absolute under /workspace)

    Rejects:
      - "/etc/passwd"  (absolute outside /workspace)
      - "../../../etc/shadow"  (traversal)
      - "" or non-string

    Raises ValueError on anything that escapes /workspace.
    """
    if not isinstance(path, str) or not path:
        raise ValueError(f"path must be a non-empty string, got {path!r}")
    if path.startswith("/workspace"):
        target = Path(path)
    elif path.startswith("/"):
        raise ValueError(f"absolute paths must start with /workspace/, got: {path!r}")
    else:
        target = WORKSPACE_ROOT / path
    real = target.resolve()
    if real != WORKSPACE_ROOT and WORKSPACE_ROOT not in real.parents:
        raise ValueError(f"path escapes /workspace/: {path!r} → {real}")
    return real


def _is_hidden_or_cruft_path(rel: str) -> bool:
    """True if any path segment is one of the EXCLUDE dirs."""
    parts = rel.split("/")
    return any(p in _HIDDEN_DIRS for p in parts)


def _looks_binary(local: Path) -> bool:
    """Heuristic: NUL byte in first 8 KB → binary."""
    try:
        with open(local, "rb") as f:
            chunk = f.read(_BINARY_PROBE_BYTES)
        return b"\x00" in chunk
    except OSError:
        return False


async def _park_after_mutation(reason: str) -> None:
    """Best-effort park after delete/move. Logs and swallows errors."""
    user_id = request_context.current_user_id()
    token = request_context.current_workspace_token()
    if not (user_id and token):
        log.warning(
            "park-after-%s: missing request context "
            "(user_id=%s, token=%s) — skipping",
            reason, bool(user_id), bool(token),
        )
        return
    try:
        manifest = await workspace_mod.park(token=token, user_key=user_id)
        log.info(
            "park-after-%s: user=%s files=%d", reason, user_id,
            len(manifest.get("files", [])),
        )
    except Exception as exc:  # noqa: BLE001
        log.exception("park-after-%s failed: %s", reason, exc)


# ----- tool: list_workspace -----


async def list_workspace(path: str = ".", tool_context: Any = None) -> str:
    """List files in /workspace (or a subdirectory).

    Args:
        path: subdirectory under /workspace. "." (default) lists the
            root. Hidden directories like __pycache__, node_modules,
            .git, .venv, .trash are skipped. Files inside those dirs
            don't appear in the listing.

    Returns:
        A formatted text listing with sizes, mtimes, and an "(artifact)"
        hint next to entries that look like deliverables (.html, .csv,
        .ipynb, etc.). Empty workspace returns a brief note.
    """
    target = _resolve_within_workspace(path)
    if not target.exists():
        return f"(no such path under /workspace: {path!r})"
    if not target.is_dir():
        return f"(not a directory: {path!r} — use read_workspace_file)"

    entries: list[tuple[str, int, float, bool]] = []
    for entry in sorted(target.rglob("*")):
        if not entry.is_file():
            continue
        rel = entry.relative_to(WORKSPACE_ROOT).as_posix()
        if _is_hidden_or_cruft_path(rel):
            continue
        try:
            st = entry.stat()
        except OSError:
            continue
        is_artifact = entry.suffix.lower() in _ARTIFACT_EXTS
        entries.append((rel, st.st_size, st.st_mtime, is_artifact))

    if not entries:
        return f"(no files under /workspace/{path.rstrip('/')})"

    lines = [
        f"/workspace ({len(entries)} files, "
        f"{sum(e[1] for e in entries):,} bytes)",
    ]
    for rel, size, mtime, is_artifact in entries:
        ts = _dt.datetime.fromtimestamp(mtime, _dt.timezone.utc).strftime(
            "%Y-%m-%d %H:%M",
        )
        tag = "  (artifact)" if is_artifact else ""
        lines.append(f"  {rel}\n    {size:>10,} bytes  {ts}{tag}")
    return "\n".join(lines)


# ----- tool: read_workspace_file -----


async def read_workspace_file(
    path: str,
    max_bytes: int | None = _READ_DEFAULT_MAX,
    tool_context: Any = None,
) -> str:
    """Return the contents of a file in /workspace.

    Args:
        path: workspace-relative or absolute /workspace path.
        max_bytes: how much to return. Three modes:
            - default (4000): listing-style peek; truncates with a
              "[truncated, …]" marker if the file is larger.
            - None or value >= file_size: FULL FILE mode, capped at
              the 200_000-byte hard ceiling. Above the ceiling, refuses
              cleanly with a hint pointing at get_download_url.
            - explicit positive int: truncate at that limit.

    Returns:
        File contents (text), or a "(…)" status string for refusals
        (binary files, missing paths, files over the hard ceiling).
    """
    # Phase 12 hotfix: coerce ADK function-calling string arg → int|None
    # BEFORE any arithmetic on it. Pre-fix, this comparison raised
    # TypeError on every call from a real GE thread.
    max_bytes = _coerce_max_bytes(max_bytes)

    target = _resolve_within_workspace(path)
    if not target.exists():
        return f"(no such file: {path!r})"
    if not target.is_file():
        return f"(not a file: {path!r})"
    if _looks_binary(target):
        size = target.stat().st_size
        return (
            f"(binary file refused: {path!r}, {size:,} bytes). "
            "Use get_download_url to share it with the user instead."
        )

    file_size = target.stat().st_size

    # Full-read mode: max_bytes is None OR exceeds the file size.
    if max_bytes is None or max_bytes >= file_size:
        if file_size > _READ_HARD_CEILING:
            kb = file_size / 1000  # decimal KB (matches "200 KB" ceiling label)
            return (
                f"File is {file_size:,} bytes ({kb:.1f} KB) which "
                "exceeds the 200 KB read ceiling. Use "
                "get_download_url instead to give the user a download "
                "link."
            )
        try:
            with open(target, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError as exc:
            return f"(could not read {path!r}: {exc})"

    # Truncated mode (peek).
    try:
        with open(target, "r", encoding="utf-8", errors="replace") as f:
            data = f.read(max_bytes + 1)
    except OSError as exc:
        return f"(could not read {path!r}: {exc})"
    if len(data) > max_bytes:
        more = file_size - max_bytes
        return (
            data[:max_bytes]
            + f"\n\n[truncated, ~{more:,} more bytes — call "
            "read_workspace_file with max_bytes=None for the full "
            "content, or use get_download_url for a download link]"
        )
    return data


# ----- tool: delete_workspace_file -----


async def delete_workspace_file(
    path: str,
    confirm: bool = False,
    tool_context: Any = None,
) -> str:
    """Soft-delete (default) or hard-delete a file in /workspace.

    Two-step pattern (lesson: agentic tools sometimes mis-target):
      1) First call WITHOUT confirm=True: file is moved to
         /workspace/.trash/<ISO-timestamp>-<basename>. Returns a
         message describing what was moved and how to restore.
      2) After the user explicitly confirms ("yes, delete it"), call
         again with confirm=True. The trashed copy is purged AND the
         live file at the original path (if it somehow reappeared)
         is also removed. Local + GCS (next park) both updated.

    Args:
        path: workspace path of the file (absolute /workspace/... or
            relative).
        confirm: False (default) → soft-delete to .trash; True → hard
            purge.

    Returns:
        Human-readable confirmation string. ALWAYS describes what was
        actually done and (on soft-delete) how to undo it.
    """
    # Phase 12 hotfix: coerce confirm via the safe-by-default rule
    # (see _coerce_confirm). Pre-fix, `confirm="false"` from ADK
    # function-calling was treated as truthy by `if confirm:` and
    # silently HARD-DELETED user data. Now: any ambiguity → soft-delete.
    confirm = _coerce_confirm(confirm)

    target = _resolve_within_workspace(path)
    rel = target.relative_to(WORKSPACE_ROOT).as_posix() if target != WORKSPACE_ROOT else ""
    if rel.startswith(".trash/"):
        # Recursing into .trash via this tool would be confusing.
        return (
            f"({rel!r} is already in the trash — call delete_workspace_file"
            f" with confirm=True to purge it permanently)"
        )

    # ---------- HARD DELETE BRANCH (confirm=True) ----------
    if confirm:
        # Remove from live path AND from .trash. We do both so the
        # tool is correct whether the prior call soft-deleted or
        # the user just wants this file gone right now (e.g. cache
        # files which are listed in the system prompt as deletable
        # without confirmation).
        purged_paths: list[str] = []
        if target.exists() and target.is_file():
            try:
                target.unlink()
                purged_paths.append(rel)
            except OSError as exc:
                return f"(failed to unlink {rel!r}: {exc})"
        # Look for any prior soft-delete of this file in .trash.
        base = target.name
        if TRASH_DIR.exists():
            for entry in TRASH_DIR.iterdir():
                # Trash names are <ISO-ts>-<basename>. Match the suffix.
                if entry.is_file() and entry.name.endswith("-" + base):
                    try:
                        entry.unlink()
                        purged_paths.append(
                            entry.relative_to(WORKSPACE_ROOT).as_posix(),
                        )
                    except OSError as exc:
                        log.warning("hard-delete: could not purge %s: %s", entry, exc)
        if not purged_paths:
            return f"(no file found at {rel!r} or in .trash to purge)"
        # Park so the GCS prune step removes these paths from the
        # remote manifest. Fire-and-forget; next turn sees clean state.
        asyncio.create_task(_park_after_mutation("hard-delete"))
        log.info("hard-delete: purged user-confirmed: %s", purged_paths)
        return (
            "Permanently deleted: " + ", ".join(purged_paths)
            + " (local + queued for GCS prune)."
        )

    # ---------- SOFT-DELETE BRANCH (default) ----------
    if not target.exists():
        return f"(no such file: {path!r})"
    if not target.is_file():
        return f"(not a file: {path!r} — only files can be deleted)"

    TRASH_DIR.mkdir(parents=True, exist_ok=True)
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    trash_name = f"{ts}-{target.name}"
    trash_dest = TRASH_DIR / trash_name
    # Make sure we don't clobber an existing trash entry with the
    # same name (highly unlikely but cheap to handle).
    n = 1
    while trash_dest.exists():
        trash_dest = TRASH_DIR / f"{ts}-{n}-{target.name}"
        n += 1
    try:
        shutil.move(str(target), str(trash_dest))
    except OSError as exc:
        return f"(soft-delete failed to move {rel!r} to .trash: {exc})"

    # Park so the GCS object at users/<key>/<rel> is removed via
    # the manifest-prune path. Trash entries are NOT excluded from
    # park (so a fresh pod restoring from GCS still gets a working
    # .trash with the same recoverable copies).
    asyncio.create_task(_park_after_mutation("soft-delete"))

    restore_hint = (
        f'  Restore: ask me to "move {trash_dest.relative_to(WORKSPACE_ROOT).as_posix()} '
        f"back to {rel}\""
    )
    purge_hint = (
        f'  Confirm permanent delete: "delete {rel} permanently" '
        '(I will then call delete_workspace_file with confirm=True)'
    )
    log.info(
        "soft-delete: %s → %s (user_id=%s)",
        rel, trash_dest.relative_to(WORKSPACE_ROOT).as_posix(),
        request_context.current_user_id(),
    )
    return (
        f"Soft-deleted {rel!r} → {trash_dest.relative_to(WORKSPACE_ROOT).as_posix()}.\n"
        + restore_hint + "\n"
        + purge_hint
    )


# ----- tool: move_workspace_file -----


async def move_workspace_file(
    src: str, dst: str, tool_context: Any = None,
) -> str:
    """Rename or relocate a file within /workspace.

    Args:
        src: existing workspace path (absolute /workspace/... or
            relative).
        dst: new workspace path. Parent directory will be created if
            it doesn't exist.

    Returns:
        Confirmation string. Refuses overwrite of an existing
        destination — the user should soft-delete first.
    """
    src_path = _resolve_within_workspace(src)
    dst_path = _resolve_within_workspace(dst)
    if not src_path.exists():
        return f"(no such source: {src!r})"
    if not src_path.is_file():
        return f"(not a file: {src!r})"
    if dst_path.exists():
        return (
            f"(destination already exists: {dst!r}). Soft-delete it "
            "first if you really want to overwrite."
        )
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.move(str(src_path), str(dst_path))
    except OSError as exc:
        return f"(move failed: {exc})"

    src_rel = src_path.relative_to(WORKSPACE_ROOT).as_posix()
    dst_rel = dst_path.relative_to(WORKSPACE_ROOT).as_posix()
    asyncio.create_task(_park_after_mutation("move"))
    log.info(
        "move: %s → %s (user_id=%s)", src_rel, dst_rel,
        request_context.current_user_id(),
    )
    return f"Moved {src_rel!r} → {dst_rel!r}."


# ----- trash auto-purge (called from server.py before park) -----


def purge_old_trash(now: _dt.datetime | None = None) -> int:
    """Delete /workspace/.trash entries older than _TRASH_TTL_DAYS days.

    Returns the count of files removed. Called by server.py before
    each background park so storage doesn't grow unbounded. Failures
    on individual entries are logged but don't break park.
    """
    if not TRASH_DIR.exists():
        return 0
    now = now or _dt.datetime.now(_dt.timezone.utc)
    horizon_epoch = (now - _dt.timedelta(days=_TRASH_TTL_DAYS)).timestamp()
    deleted = 0
    for entry in TRASH_DIR.iterdir():
        if not entry.is_file():
            continue
        try:
            if entry.stat().st_mtime < horizon_epoch:
                entry.unlink()
                deleted += 1
        except OSError as exc:
            log.warning("trash auto-purge: %s skipped: %s", entry, exc)
    if deleted:
        log.info("trash auto-purge: removed %d entries older than %dd",
                 deleted, _TRASH_TTL_DAYS)
    return deleted
