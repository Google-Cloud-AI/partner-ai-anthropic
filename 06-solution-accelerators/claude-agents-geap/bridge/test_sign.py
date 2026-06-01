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

"""Regression tests for bridge signing — Phase 12 hotfix #2.

Production defect: `_sign_blob_url` was calling `blob.generate_signed_url`
WITHOUT `response_disposition`. The resulting v4-signed URL relied on
the object's stored Content-Type — HTML files rendered inline in the
browser instead of downloading. The agent had been working around this
with "Right-click → Save link as..." apologies in its replies.

Fix: pass `response_disposition='attachment; filename="<safe>"'` to
generate_signed_url, with the filename sanitized to ASCII basename so
it can't escape the quoted-string in the header.

These tests cover:

  1. `safe_filename` happy path — "deploy.sh" → "deploy.sh"
  2. Header-injection guard — '"; rm -rf /; x="' → underscored
  3. Degenerate basename — "" / "." / ".." → "download"
  4. Long basename — 300 chars → truncated to 200, extension preserved,
     '..' prefix signals truncation from the start
  5. Unicode basename — "résumé.pdf" → ASCII-only
  6. End-to-end signing call — `generate_signed_url` is called with a
     `response_disposition` kwarg containing 'attachment; filename="…"'
     (mocked at the GCS-client boundary)

Pure tests (1-5) only need stdlib + sign_helpers.py. E2E test (6) needs
the bridge's runtime deps (fastapi, a2a-sdk, google-cloud-storage); if
those aren't importable in this environment, those cases are skipped
and reported as SKIP, not failure — they should be run inside a bridge
container or in CI.

Run from anywhere with bridge/ on PYTHONPATH (or from bridge/ directly):
    python3 test_sign.py

Exits 0 on green (all non-skipped pass), 1 on any failure.
"""

from __future__ import annotations

import os
import re as _re
import sys
import traceback
from unittest import mock

# Make `import sign_helpers` and `import main` work from bridge/.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sign_helpers import safe_filename  # noqa: E402 — pure module, always importable

# Try to import main for the E2E test. If bridge runtime deps are missing
# (no PyPI in this env), mark the E2E tests as skip rather than fail.
try:
    import main  # noqa: E402
    _MAIN_AVAILABLE = True
    _MAIN_IMPORT_ERR = None
except Exception as e:  # noqa: BLE001
    main = None  # type: ignore[assignment]
    _MAIN_AVAILABLE = False
    _MAIN_IMPORT_ERR = f"{type(e).__name__}: {e}"


# ============================================================================
# safe_filename — pure function (no bridge deps)
# ============================================================================


def test_normal_filename_passes_through():
    assert safe_filename("deploy.sh") == "deploy.sh"
    assert safe_filename("out/dashboard.html") == "dashboard.html"
    assert safe_filename("users/abc/data.csv") == "data.csv"


def test_quoted_filename_in_disposition_contains_filename():
    """Step 4 test 1: 'deploy.sh' resolves into a header that quotes it
    as filename="deploy.sh" (no escaping needed)."""
    safe = safe_filename("path/to/deploy.sh")
    disposition = f'attachment; filename="{safe}"'
    assert 'filename="deploy.sh"' in disposition, disposition


def test_header_injection_sanitized():
    """Step 4 test 2: a basename of '"; rm -rf /; x="' must have ALL
    injection chars replaced with '_'. No quote, semicolon, comma, or
    space may survive — those are the chars that could escape the
    quoted-string in `filename="..."`."""
    nasty = 'users/x/"; rm -rf /; x="'
    safe = safe_filename(nasty)
    for forbidden in ('"', ";", ",", " ", "/", "\\", "\n", "\r"):
        assert forbidden not in safe, (
            f"forbidden char {forbidden!r} survived sanitization in {safe!r}"
        )
    assert _re.fullmatch(r"[A-Za-z0-9._-]+", safe), (
        f"sanitized result {safe!r} contains chars outside the safe set"
    )


def test_empty_basename_falls_back_to_download():
    """Step 4 test 3a: trailing-slash path → empty basename → 'download'."""
    assert safe_filename("users/x/") == "download"


def test_dot_basename_falls_back_to_download():
    """Step 4 test 3b: '.' basename → 'download' (single dot is degenerate)."""
    assert safe_filename("users/x/.") == "download"


def test_double_dot_basename_falls_back_to_download():
    """Step 4 test 3c: '..' basename → 'download'.

    Note: the /workspace/sign endpoint itself rejects rel_path containing
    '..' BEFORE this helper is called, so this is defense-in-depth.
    """
    assert safe_filename("..") == "download"
    assert safe_filename("...") == "download"


def test_long_filename_truncated_extension_preserved():
    """Step 4 test 4: 300-char basename → truncated to 200, '.pdf' kept,
    '..' prefix signals truncation happened at the start."""
    long_name = "x" * 300 + ".pdf"
    safe = safe_filename(long_name)
    assert len(safe) == 200, f"expected len 200, got {len(safe)}: {safe!r}"
    assert safe.endswith(".pdf"), f"expected .pdf suffix, got {safe!r}"
    assert safe.startswith(".."), f"expected '..' prefix, got {safe[:5]!r}"


def test_unicode_basename_replaced_with_underscores():
    """Step 4 test 5: 'résumé.pdf' → non-ASCII replaced with '_'."""
    safe = safe_filename("résumé.pdf")
    assert _re.fullmatch(r"[A-Za-z0-9._-]+", safe), (
        f"unicode survived: {safe!r}"
    )
    assert safe == "r_sum_.pdf", f"unexpected sanitization: {safe!r}"


def test_consecutive_unsafe_chars_each_replaced():
    """Each unsafe char becomes a separate underscore (no collapsing).
    Documents the behavior so future readers don't assume collapsing."""
    assert safe_filename("a b c.txt") == "a_b_c.txt"
    assert safe_filename("a   b.txt") == "a___b.txt"


def test_only_unsafe_chars_falls_back():
    """If sanitization wipes everything to underscores (no allowlist
    chars at all), the result is still a valid name (all underscores).
    This is documented behavior — not 'download' — because the input
    wasn't degenerate, just exotic. Distinguishes from empty/dot cases."""
    safe = safe_filename("@@@")
    assert safe == "___", f"expected '___', got {safe!r}"


# ============================================================================
# End-to-end: _sign_blob_url passes response_disposition through
# (requires bridge runtime deps — skipped if main can't import)
# ============================================================================


def _build_fake_gcs_and_creds():
    """Helper: shared scaffolding for the two E2E tests."""
    captured_kwargs: dict = {}

    def fake_generate_signed_url(*args, **kwargs):
        captured_kwargs.update(kwargs)
        return "https://storage.googleapis.com/fake-signed-url?response-content-disposition=attachment"

    fake_blob = mock.MagicMock()
    fake_blob.generate_signed_url.side_effect = fake_generate_signed_url
    fake_bucket = mock.MagicMock()
    fake_bucket.blob.return_value = fake_blob
    fake_client = mock.MagicMock()
    fake_client.bucket.return_value = fake_bucket

    fake_creds = mock.MagicMock()
    fake_creds.service_account_email = "test-signer@example.iam.gserviceaccount.com"
    fake_creds.token = "fake-token"

    return captured_kwargs, fake_client, fake_creds


def test_response_disposition_passed_to_generate_signed_url():
    """Step 4 test 6: confirm `generate_signed_url` receives a
    `response_disposition` kwarg with 'attachment; filename="…"' and
    the filename derives from the object basename.
    """
    if not _MAIN_AVAILABLE:
        raise SkipTest(f"main not importable: {_MAIN_IMPORT_ERR}")

    object_name = "users/abc/out/dashboard.html"
    captured_kwargs, fake_client, fake_creds = _build_fake_gcs_and_creds()

    with mock.patch.object(main, "gcs_storage") as m_gcs, \
         mock.patch.object(main.google.auth, "default", return_value=(fake_creds, "p")):
        m_gcs.Client.return_value = fake_client
        url, expires_at = main._sign_blob_url(object_name, 5)

    assert "response_disposition" in captured_kwargs, (
        f"response_disposition missing from kwargs: {list(captured_kwargs.keys())}"
    )
    disp = captured_kwargs["response_disposition"]
    assert "attachment" in disp, f"disposition missing 'attachment': {disp!r}"
    assert 'filename="dashboard.html"' in disp, (
        f"disposition missing filename=\"dashboard.html\": {disp!r}"
    )
    assert captured_kwargs.get("version") == "v4"
    assert captured_kwargs.get("method") == "GET"
    assert url.startswith("https://"), f"expected https URL, got {url!r}"


def test_response_disposition_uses_sanitized_filename_for_hostile_object_name():
    """If the object name contains injection chars, the disposition
    header carries the SANITIZED form — not the raw basename."""
    if not _MAIN_AVAILABLE:
        raise SkipTest(f"main not importable: {_MAIN_IMPORT_ERR}")

    object_name = 'users/abc/"; evil="'
    captured_kwargs, fake_client, fake_creds = _build_fake_gcs_and_creds()

    with mock.patch.object(main, "gcs_storage") as m_gcs, \
         mock.patch.object(main.google.auth, "default", return_value=(fake_creds, "p")):
        m_gcs.Client.return_value = fake_client
        main._sign_blob_url(object_name, 5)

    disp = captured_kwargs["response_disposition"]
    # Exactly TWO quote chars in the entire disposition string — opener
    # and closer around the sanitized filename. Anything else would
    # mean an injected quote survived sanitization.
    quote_count = disp.count('"')
    assert quote_count == 2, (
        f"expected exactly 2 quote chars (filename delimiters); got "
        f"{quote_count} in {disp!r}. Injection guard failed."
    )


# ============================================================================
# Runner
# ============================================================================


class SkipTest(Exception):
    """Raised by a test to indicate it should be skipped, not failed."""


TESTS = [
    ("normal filename passes through", test_normal_filename_passes_through),
    ("disposition contains filename for 'deploy.sh'",
     test_quoted_filename_in_disposition_contains_filename),
    ("header-injection attempt fully sanitized",
     test_header_injection_sanitized),
    ("empty basename → 'download'", test_empty_basename_falls_back_to_download),
    ("'.' basename → 'download'", test_dot_basename_falls_back_to_download),
    ("'..' basename → 'download'",
     test_double_dot_basename_falls_back_to_download),
    ("300-char basename truncated to 200, ext preserved",
     test_long_filename_truncated_extension_preserved),
    ("unicode 'résumé.pdf' → ASCII underscores",
     test_unicode_basename_replaced_with_underscores),
    ("consecutive unsafe chars each → '_' (no collapsing)",
     test_consecutive_unsafe_chars_each_replaced),
    ("all-unsafe input → string of underscores (not 'download')",
     test_only_unsafe_chars_falls_back),
    ("[E2E] generate_signed_url receives response_disposition kwarg",
     test_response_disposition_passed_to_generate_signed_url),
    ("[E2E] hostile object name → exactly 2 quote chars in disposition",
     test_response_disposition_uses_sanitized_filename_for_hostile_object_name),
]


def main_runner() -> int:
    fails: list[tuple[str, str]] = []
    skips: list[tuple[str, str]] = []
    for name, fn in TESTS:
        try:
            fn()
            print(f"  PASS  {name}")
        except SkipTest as e:
            print(f"  SKIP  {name}")
            print(f"        {e}")
            skips.append((name, str(e)))
        except AssertionError as e:
            print(f"  FAIL  {name}")
            print(f"        {e}")
            fails.append((name, str(e)))
        except Exception as e:
            tb_last = traceback.format_exc().splitlines()[-1]
            print(f"  ERROR {name}")
            print(f"        {tb_last}")
            fails.append((name, tb_last))
    total = len(TESTS)
    passed = total - len(fails) - len(skips)
    print()
    print(f"Results: {passed} passed, {len(fails)} failed, {len(skips)} skipped (total {total})")
    if fails:
        print()
        print("Failing tests:")
        for n, msg in fails:
            print(f"  - {n}: {msg}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main_runner())
