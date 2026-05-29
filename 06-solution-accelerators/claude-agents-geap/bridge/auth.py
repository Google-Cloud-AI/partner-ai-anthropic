"""End-user identity resolution for cc-a2a-bridge.

Returns a stable `user_key` (short hex hash of email/sub) used for:
  - SandboxClaim name (`cc-u-<user_key>`)
  - Per-user asyncio lock keying
  - User isolation boundary (downscoped tokens, Phase 6)

Identity sources, in order of preference:
  1. `x-test-user` header — TEST ONLY. Hashes the literal value.
  2. `Authorization: Bearer <token>` — Google access token. Resolves via
     `oauth2.googleapis.com/tokeninfo`; extracts `email` (preferred) or
     `sub`.
  3. `x-goog-iap-jwt-assertion` — IAP-fronted deploy. JWT signature
     verification is deferred to Phase 6 hardening; for Phase 5 we
     decode the unverified claims to extract `email`/`sub`. Log loudly
     when this path is used WITHOUT verification.
  4. Fallback: `"anon"`. Degrades isolation, does not fail the turn.
     Log loudly. (Phase 5 scope.)
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
from typing import Optional

import httpx

log = logging.getLogger("cc-bridge.auth")

# tokeninfo endpoint timeout — generous; the bridge's request shouldn't
# wait forever on Google's OAuth service.
_TOKENINFO_TIMEOUT_S = 5.0


def user_key_from_identity(identity: str) -> str:
    """Stable 16-char hex from email/sub. Keeps PII out of K8s names."""
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return digest[:16]


async def resolve_user_key(headers) -> str:
    """Identify the end user from request headers; return a stable user_key.

    `headers` is a mapping-like object (case-insensitive) from FastAPI's
    Request.headers or A2A's RequestContext.
    """
    # Mapping access is case-insensitive in FastAPI/Starlette.

    # 1. x-test-user — test-only direct override.
    test_user = headers.get("x-test-user")
    if test_user:
        log.warning(
            "auth: using x-test-user override: %r (test mode)", test_user,
        )
        return user_key_from_identity(f"test:{test_user}")

    # 2. Authorization: Bearer ... → tokeninfo
    authz = headers.get("authorization")
    if authz and authz.lower().startswith("bearer "):
        token = authz.split(" ", 1)[1].strip()
        identity = await _resolve_via_tokeninfo(token)
        if identity:
            log.info("auth: resolved via tokeninfo: %s", _redact(identity))
            return user_key_from_identity(identity)
        log.warning(
            "auth: tokeninfo returned no usable identity for token; "
            "falling back",
        )

    # 3. IAP-fronted JWT — Phase 5 decodes WITHOUT signature verification.
    # Phase 6 hardening: switch to google.oauth2.id_token.verify_oauth2_token.
    iap_jwt = headers.get("x-goog-iap-jwt-assertion")
    if iap_jwt:
        identity = _peek_jwt_claims(iap_jwt)
        if identity:
            log.warning(
                "auth: using IAP JWT WITHOUT signature verification "
                "(Phase 6 hardens this): %s", _redact(identity),
            )
            return user_key_from_identity(identity)
        log.warning("auth: IAP JWT present but no usable email/sub claim")

    # 4. Anonymous fallback. Log LOUDLY.
    # This is the path GE-routed calls hit in v1 (registration omits
    # authorizationConfig — see PROJECT_PLAN.md "Known limitations").
    log.warning(
        "GE-routed call resolved to anon user_key — per-user isolation "
        "NOT active. See PROJECT_PLAN.md 'Known limitations'.",
    )
    return user_key_from_identity("anon")


async def _resolve_via_tokeninfo(token: str) -> Optional[str]:
    """Call oauth2.googleapis.com/tokeninfo; return email or sub."""
    try:
        async with httpx.AsyncClient(timeout=_TOKENINFO_TIMEOUT_S) as client:
            resp = await client.get(
                "https://oauth2.googleapis.com/tokeninfo",
                params={"access_token": token},
            )
        if resp.status_code != 200:
            log.info(
                "auth.tokeninfo: status=%d body=%r",
                resp.status_code, resp.text[:200],
            )
            return None
        data = resp.json()
        return data.get("email") or data.get("sub")
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("auth.tokeninfo: request failed: %s", exc)
        return None


def _peek_jwt_claims(jwt: str) -> Optional[str]:
    """Decode JWT WITHOUT verifying the signature. Return email or sub."""
    parts = jwt.split(".")
    if len(parts) != 3:
        return None
    try:
        payload_b64 = parts[1]
        # JWTs use URL-safe base64 without padding.
        padding = "=" * ((4 - len(payload_b64) % 4) % 4)
        payload = base64.urlsafe_b64decode(payload_b64 + padding)
        claims = json.loads(payload)
        return claims.get("email") or claims.get("sub")
    except (ValueError, json.JSONDecodeError) as exc:
        log.warning("auth.iap_jwt: parse failed: %s", exc)
        return None


def _redact(identity: str) -> str:
    """Truncate PII for logs."""
    if "@" in identity:
        local, _, domain = identity.partition("@")
        return f"{local[:3]}***@{domain}"
    return f"{identity[:4]}***"
