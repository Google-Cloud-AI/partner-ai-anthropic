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

"""Regression tests for workspace_tools.py — Phase 12 hotfix.

Two production bugs discovered via real-GE testing:

1. `read_workspace_file.max_bytes` arrives from ADK function-calling as
   a STRING (e.g. "4000"), not an int. The full-read-mode logic does
   `max_bytes >= file_size` → TypeError. Every read crashes regardless
   of file size — the screenshot showed a 12-byte file failing.

2. `delete_workspace_file.confirm` arrives as a string (e.g. "false")
   from the same path. The current `if confirm:` check is truthy for
   ANY non-empty string, so `confirm="false"` HARD-DELETES instead of
   soft-deleting. Silent data loss bug.

These tests prove BEHAVIOR, not just absence of crash. Each delete
test asserts filesystem state (file moved to .trash vs. permanently
gone), not just the return value.

Run inside a warm pod where deps are present:
    kubectl -n cc-sandbox cp test_workspace_tools.py POD:/tmp/
    kubectl -n cc-sandbox exec POD -- python3 /tmp/test_workspace_tools.py

Exits 0 on green, 1 if any test fails.
"""

from __future__ import annotations

import asyncio
import shutil
import sys
import tempfile
import traceback
from pathlib import Path

sys.path.insert(0, "/app")
import tools.workspace_tools as wst  # noqa: E402


# --- per-test scaffolding ---


def _fresh_tempdir() -> Path:
    """Allocate a fresh tempdir and rebind the module's WORKSPACE_ROOT.

    workspace_tools reads WORKSPACE_ROOT at function-call time (module-
    level name lookup is late-bound), so reassigning the module
    attribute redirects every tool call without monkey-import.
    """
    root = Path(tempfile.mkdtemp(prefix="wst-test-"))
    wst.WORKSPACE_ROOT = root
    wst.TRASH_DIR = root / ".trash"
    return root


def _cleanup(root: Path) -> None:
    try:
        shutil.rmtree(root)
    except OSError:
        pass


def _run(coro):
    """Run an async coroutine and swallow the cosmetic pending-task
    warning that fires when delete_workspace_file's fire-and-forget
    park task is cancelled at loop close (we don't care about park in
    the unit tests; it has no user_id/token to act on anyway)."""
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", ResourceWarning)
        return asyncio.run(coro)


# ============ read_workspace_file tests ============


def test_read_max_bytes_string_4000():
    """The screenshot bug: max_bytes='4000' must NOT raise TypeError."""
    root = _fresh_tempdir()
    try:
        (root / "hello.txt").write_text("hello world\n")
        out = _run(wst.read_workspace_file("hello.txt", max_bytes="4000"))
        assert out == "hello world\n", (
            f"expected 'hello world\\n', got {out!r}"
        )
    finally:
        _cleanup(root)


def test_read_max_bytes_none_full_read():
    """max_bytes=None → full content (<= 200 KB ceiling)."""
    root = _fresh_tempdir()
    try:
        body = "line\n" * 50  # 250 bytes, well under ceiling
        (root / "small.txt").write_text(body)
        out = _run(wst.read_workspace_file("small.txt", max_bytes=None))
        assert out == body, f"expected full body, got {out[:80]!r}"
    finally:
        _cleanup(root)


def test_read_max_bytes_string_200000_small_file():
    """max_bytes='200000' on a tiny file → returns the full small content
    (string value parses to 200000, which exceeds the file size, so
    full-read mode kicks in)."""
    root = _fresh_tempdir()
    try:
        body = "tiny content"
        (root / "tiny.txt").write_text(body)
        out = _run(
            wst.read_workspace_file("tiny.txt", max_bytes="200000"),
        )
        assert out == body, f"expected {body!r}, got {out!r}"
    finally:
        _cleanup(root)


def test_read_12_byte_secret_b_string_max_bytes():
    """Exact screenshot case: 12-byte file, agent passes string max_bytes."""
    root = _fresh_tempdir()
    try:
        body = "hello-from-b"  # exactly 12 bytes
        assert len(body) == 12
        (root / "secret-b.txt").write_text(body)
        out = _run(
            wst.read_workspace_file("secret-b.txt", max_bytes="4000"),
        )
        assert out == body, f"expected {body!r}, got {out!r}"
    finally:
        _cleanup(root)


def test_read_max_bytes_garbage_string_recovers_gracefully():
    """Non-numeric max_bytes ('abc') must not crash — falls back to
    safe default (truncated read at 4000) and the read still returns
    the file's content."""
    root = _fresh_tempdir()
    try:
        body = "small body for garbage-string test"
        (root / "tiny.txt").write_text(body)
        out = _run(wst.read_workspace_file("tiny.txt", max_bytes="abc"))
        assert out == body, f"expected {body!r}, got {out!r}"
    finally:
        _cleanup(root)


# ============ delete_workspace_file tests — behavior, not just no-crash ============


def _trash_entries(root: Path, basename: str) -> list[Path]:
    """All .trash entries whose name ends with '-<basename>'."""
    trash = root / ".trash"
    if not trash.exists():
        return []
    return sorted(
        p for p in trash.iterdir()
        if p.is_file() and p.name.endswith("-" + basename)
    )


def _delete_soft_check(confirm_value, label: str):
    """Assert: target.txt is moved to .trash AND survives in trash
    (recoverable). Used for all confirm-input values that MUST resolve
    to soft-delete per the safe-default rule."""
    root = _fresh_tempdir()
    try:
        live = root / "target.txt"
        live.write_text("save me")
        _run(wst.delete_workspace_file(
            "target.txt", confirm=confirm_value,
        ))
        # Live file gone (soft-delete moves it out)
        assert not live.exists(), (
            f"[{label}] live file should be moved out of /workspace, "
            "but it's still there — that means the delete didn't run"
        )
        # .trash has the file (CRITICAL: proves it's recoverable, not gone)
        trashed = _trash_entries(root, "target.txt")
        assert len(trashed) == 1, (
            f"[{label}] expected exactly 1 trash entry for target.txt; "
            f"got {[p.name for p in trashed]}. If empty, the file was "
            f"HARD-DELETED — this is the silent bug we're guarding against."
        )
        assert trashed[0].read_text() == "save me", (
            f"[{label}] trash content corrupted: {trashed[0].read_text()!r}"
        )
    finally:
        _cleanup(root)


def _delete_hard_check(confirm_value, label: str):
    """Assert: target.txt is permanently gone — NOT in live path AND
    NOT in .trash."""
    root = _fresh_tempdir()
    try:
        live = root / "target.txt"
        live.write_text("destroy me")
        _run(wst.delete_workspace_file(
            "target.txt", confirm=confirm_value,
        ))
        assert not live.exists(), (
            f"[{label}] live file should be gone after hard delete"
        )
        trashed = _trash_entries(root, "target.txt")
        assert len(trashed) == 0, (
            f"[{label}] confirm={confirm_value!r} should hard-delete "
            f"(no trash entry), but trash has: {[p.name for p in trashed]}"
        )
    finally:
        _cleanup(root)


def test_delete_confirm_string_false_safe_default():
    """THE silent bug: confirm='false' (string) MUST go to trash, not be
    permanently deleted. Pre-fix: `if confirm:` is truthy for any non-
    empty string → hard delete. Post-fix: only specific truthy values
    map to True; everything else (including 'false') maps to False."""
    _delete_soft_check("false", "confirm='false' (str)")


def test_delete_confirm_bool_false_safe():
    """Bool False → soft-delete. The base case."""
    _delete_soft_check(False, "confirm=False (bool)")


def test_delete_confirm_string_true_hard():
    """confirm='true' (str) → permanent. Explicit user intent."""
    _delete_hard_check("true", "confirm='true' (str)")


def test_delete_confirm_bool_true_hard():
    """confirm=True (bool) → permanent. Explicit programmatic intent."""
    _delete_hard_check(True, "confirm=True (bool)")


def test_delete_confirm_empty_string_safe_default():
    """confirm='' → soft-delete. Empty string is NOT a confirmation."""
    _delete_soft_check("", "confirm='' (empty str)")


def test_delete_confirm_none_safe_default():
    """confirm=None → soft-delete. None is NOT a confirmation."""
    _delete_soft_check(None, "confirm=None")


def test_delete_confirm_garbage_string_safe_default():
    """confirm='garbage' → soft-delete. Unknown values fail toward
    safe, never toward permanent."""
    _delete_soft_check("garbage", "confirm='garbage' (str)")


def test_delete_confirm_string_zero_safe_default():
    """confirm='0' → soft-delete. Common string-false representation."""
    _delete_soft_check("0", "confirm='0' (str)")


def test_delete_confirm_string_one_hard():
    """confirm='1' → permanent. Common string-true representation."""
    _delete_hard_check("1", "confirm='1' (str)")


def test_delete_confirm_int_one_hard():
    """confirm=1 (int) → permanent. Sibling of '1' string."""
    _delete_hard_check(1, "confirm=1 (int)")


# ============ runner ============


TESTS = [
    # read
    ("read max_bytes='4000' (the screenshot bug)",
     test_read_max_bytes_string_4000),
    ("read max_bytes=None full read",
     test_read_max_bytes_none_full_read),
    ("read max_bytes='200000' small file",
     test_read_max_bytes_string_200000_small_file),
    ("read 12-byte file (secret-b.txt) with string max_bytes",
     test_read_12_byte_secret_b_string_max_bytes),
    ("read max_bytes='abc' (garbage) recovers gracefully",
     test_read_max_bytes_garbage_string_recovers_gracefully),
    # delete — the silent bug
    ("delete confirm='false' (str) → TRASH not void",
     test_delete_confirm_string_false_safe_default),
    ("delete confirm=False (bool) → trash",
     test_delete_confirm_bool_false_safe),
    ("delete confirm='true' (str) → permanent",
     test_delete_confirm_string_true_hard),
    ("delete confirm=True (bool) → permanent",
     test_delete_confirm_bool_true_hard),
    ("delete confirm='' → trash (safe default)",
     test_delete_confirm_empty_string_safe_default),
    ("delete confirm=None → trash (safe default)",
     test_delete_confirm_none_safe_default),
    ("delete confirm='garbage' → trash (safe default)",
     test_delete_confirm_garbage_string_safe_default),
    ("delete confirm='0' → trash (safe default)",
     test_delete_confirm_string_zero_safe_default),
    ("delete confirm='1' → permanent",
     test_delete_confirm_string_one_hard),
    ("delete confirm=1 (int) → permanent",
     test_delete_confirm_int_one_hard),
]


def main() -> int:
    fails: list[tuple[str, str]] = []
    for name, fn in TESTS:
        try:
            fn()
            print(f"  PASS  {name}")
        except AssertionError as e:
            print(f"  FAIL  {name}")
            print(f"        {e}")
            fails.append((name, str(e)))
        except Exception as e:
            tb_last = traceback.format_exc().splitlines()[-1]
            print(f"  ERROR {name}")
            print(f"        {tb_last}")
            fails.append((name, tb_last))
    print()
    print(f"Results: {len(TESTS) - len(fails)}/{len(TESTS)} passed")
    if fails:
        print()
        print("Failing tests (regression bugs the fix must fix):")
        for n, msg in fails:
            print(f"  - {n}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
