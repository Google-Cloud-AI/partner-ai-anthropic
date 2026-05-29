"""Pure helpers for bridge signed-URL generation.

Lives in its own module so it can be unit-tested without importing the
bridge's runtime stack (fastapi, a2a-sdk, google-cloud-storage, etc.).
Phase 12 signed-URL hotfix.
"""

from __future__ import annotations

import os
import re

# Filename-sanitization for the signed URL's Content-Disposition header.
# Approach (A) from the Phase 12 signed-URL hotfix: ASCII-only basename
# with [A-Za-z0-9._-]; everything else replaced with '_'. This implicitly
# closes the header-injection surface (no quote, semicolon, comma, or
# newline can survive sanitization) so a hostile basename can't escape
# the quoted-string in `filename="..."`.
_SAFE_FILENAME_RE = re.compile(r"[^A-Za-z0-9._-]")
_SAFE_FILENAME_MAX_LEN = 200


def safe_filename(rel_or_object_path: str, max_len: int = _SAFE_FILENAME_MAX_LEN) -> str:
    """Sanitize a path into an ASCII-only filename for Content-Disposition.

    Rules (Phase 12 hotfix, approach A):
      - Take the basename. Replace any char outside [A-Za-z0-9._-] with '_'.
      - If the result is empty, just dots ('.', '..'), or only-dots after
        sanitization → fall back to 'download' (malformed otherwise).
      - If the result exceeds max_len chars, truncate from the START while
        preserving the extension, prefixed with '..' to signal truncation.
    """
    base = os.path.basename(rel_or_object_path) or "download"
    sanitized = _SAFE_FILENAME_RE.sub("_", base)
    if not sanitized or sanitized.strip(".") == "":
        return "download"
    if len(sanitized) > max_len:
        name, ext = os.path.splitext(sanitized)
        keep = max_len - len(ext)
        if keep > 2:
            sanitized = ".." + name[-(keep - 2):] + ext
        else:
            sanitized = sanitized[:max_len]
    return sanitized
