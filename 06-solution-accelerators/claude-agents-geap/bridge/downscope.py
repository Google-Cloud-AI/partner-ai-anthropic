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

"""STS exchange for per-user workspace tokens.

This is the foundation of the Phase 6 isolation story. The bridge holds
`roles/storage.objectAdmin` bucket-wide; the per-user pod holds zero
storage IAM. On every turn the bridge mints a short-lived OAuth2 access
token whose Credential Access Boundary (CEL) restricts it to objects
under `users/<user_key>/`. That token is the only credential the pod
ever sees for the snapshots bucket.

Probe A (Phase 6) proved the CEL pattern is enforced server-side:
  - Scoped read/write under users/<user_key>/    → 200
  - Read another user's prefix with the same token → 403
  - List the bucket (even own prefix) with the token → 403
  (Last one is why workspace restore is manifest-driven; no bucket list.)

Token caching: per-user in-process cache. STS tokens last ~1h; we
refresh when within 5 minutes of expiry. Per-bridge-instance state is
fine; cross-instance correctness is preserved because each instance
mints its own tokens.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from dataclasses import dataclass
from typing import Optional

import google.auth
from google.auth import downscoped
from google.auth.transport.requests import Request as GoogleAuthRequest

log = logging.getLogger("cc-bridge.downscope")

# Refresh `REFRESH_MARGIN_S` before expiry so callers never serve a token
# that's about to die mid-turn. Production GSA-impersonation tokens last
# ~3600s; CAB-derived tokens inherit the source's TTL (currently observed
# at ~3600s in Probe A).
REFRESH_MARGIN_S = 5 * 60   # 5 min

# Bucket comes from env so the bridge configuration is single-source-of-truth.
SNAPSHOTS_BUCKET = os.environ.get(
    "SNAPSHOTS_BUCKET", "cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots",
)


@dataclass
class CachedToken:
    token: str
    expiry_epoch: float  # absolute unix time

    def is_fresh(self) -> bool:
        return time.time() < (self.expiry_epoch - REFRESH_MARGIN_S)


class WorkspaceTokenBroker:
    """Mints and caches downscoped workspace tokens per user_key."""

    def __init__(self, bucket: str = SNAPSHOTS_BUCKET) -> None:
        self.bucket = bucket
        self._cache: dict[str, CachedToken] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    def _lock_for(self, user_key: str) -> asyncio.Lock:
        lock = self._locks.get(user_key)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[user_key] = lock
        return lock

    async def mint_user_token(self, user_key: str) -> str:
        """Return a downscoped OAuth2 token for `users/<user_key>/`."""
        async with self._lock_for(user_key):
            cached = self._cache.get(user_key)
            if cached is not None and cached.is_fresh():
                return cached.token
            log.info(
                "downscope: minting fresh token for user_key=%s (cache=%s)",
                user_key,
                "stale" if cached else "miss",
            )
            # google.auth.downscoped is synchronous and does network I/O —
            # run in a thread so we don't block the asyncio loop.
            cached = await asyncio.to_thread(self._sync_mint, user_key)
            self._cache[user_key] = cached
            return cached.token

    def _sync_mint(self, user_key: str) -> CachedToken:
        # Source creds = bridge ADC. The Cloud Run runtime SA has
        # `roles/storage.objectAdmin` bucket-wide (iam.tf:bridge_snapshots_admin).
        source_creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"],
        )
        rules = [
            downscoped.AccessBoundaryRule(
                available_resource=(
                    f"//storage.googleapis.com/projects/_/buckets/{self.bucket}"
                ),
                available_permissions=["inRole:roles/storage.objectAdmin"],
                availability_condition=downscoped.AvailabilityCondition(
                    # NOTE: object names use the literal user_key — no path
                    # traversal because user_key is a 16-char hex (sha256
                    # prefix); no slashes, no dot-dots possible.
                    expression=(
                        f"resource.name.startsWith("
                        f"'projects/_/buckets/{self.bucket}/objects/"
                        f"users/{user_key}/'"
                        f")"
                    ),
                    title=f"scope-to-{user_key}",
                ),
            )
        ]
        cab = downscoped.CredentialAccessBoundary(rules=rules)
        creds = downscoped.Credentials(
            source_credentials=source_creds,
            credential_access_boundary=cab,
        )
        creds.refresh(GoogleAuthRequest())
        # expiry is a datetime; convert to epoch.
        expiry_epoch = (
            creds.expiry.timestamp()
            if creds.expiry is not None
            else (time.time() + 3600)  # defensive fallback
        )
        return CachedToken(token=creds.token, expiry_epoch=expiry_epoch)


# Module singleton — every bridge request shares this broker.
_BROKER: Optional[WorkspaceTokenBroker] = None


def broker() -> WorkspaceTokenBroker:
    global _BROKER
    if _BROKER is None:
        _BROKER = WorkspaceTokenBroker()
    return _BROKER
