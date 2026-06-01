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

"""SandboxClaim get-or-create for cc-a2a-bridge.

Per-user serialisation via in-process asyncio.Lock keyed on user_key.
This is sufficient as long as the bridge runs as a single Cloud Run
instance (min_instances=1, max_instances may scale up — but each
instance serialises its own users; cross-instance races are tolerable
because the get-or-create is idempotent at the K8s API level).

Phase 6 will switch to a distributed lock (Firestore document with
contention semantics) if we see same-user-collision pressure.

Returns the bound Sandbox CR name (== X-Sandbox-ID for the router).
"""

from __future__ import annotations

import asyncio
import base64
import logging
import os
import time
from collections import defaultdict
from typing import Optional

import google.auth
from google.auth.transport.requests import Request as GoogleAuthRequest
from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

log = logging.getLogger("cc-bridge.sandbox")

NAMESPACE = "cc-sandbox"
TEMPLATE = "cc-backend"
GROUP_EXT = "extensions.agents.x-k8s.io"  # SandboxClaim, SandboxTemplate
GROUP_AGENTS = "agents.x-k8s.io"          # Sandbox (controller-managed)
VERSION = "v1alpha1"

# Verified in Probe B: claim-to-bind is ~1.3s on a warm pool; pod Ready
# typically follows within a few hundred ms. 120s is a generous upper
# bound for the first turn on a cold cluster.
_BIND_TIMEOUT_S = 120
_BIND_POLL_S = 1.0

# Phase 6 idle-cleanup. After IDLE_THRESHOLD without a turn for the user,
# the bridge deletes the SandboxClaim (workspace data was parked on the
# turn that wrote it; restore on the next turn rebuilds /workspace). The
# sweeper is *cross-instance safe*: it reads `cc-a2a/last-use` annotations
# from every claim in the namespace, so any bridge replica can clean up
# claims owned by any other replica (or itself).
_IDLE_THRESHOLD_S = 30 * 60       # 30 min idle → delete
_SWEEPER_INTERVAL_S = 5 * 60      # check every 5 min
_LAST_USE_ANNOTATION = "cc-a2a/last-use"


def claim_name(user_key: str) -> str:
    """Deterministic SandboxClaim name for a given user_key.

    Matches the canonical pattern documented in CLAUDE.md so any bridge
    replica resolves the same user to the same claim.
    """
    return f"cc-u-{user_key}"


class SandboxBroker:
    """Async wrapper around the Kubernetes API for SandboxClaim lifecycle.

    A single instance lives on the bridge module. Lazy-initialises its
    K8s API clients on first use (Cloud Run will set up in-cluster
    credentials via the Workload Identity binding configured in
    cloudrun.tf).
    """

    def __init__(self) -> None:
        self._co: Optional[client.CustomObjectsApi] = None
        self._v1: Optional[client.CoreV1Api] = None
        # Per-user lock — coalesces concurrent turns from the same user.
        self._locks: dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)
        self._sweeper_task: Optional[asyncio.Task] = None

    def _build_api_client(self) -> client.ApiClient:
        """Build an authenticated API client.

        Order of preference:
          1. Cloud Run: explicit env vars `GKE_CLUSTER_ENDPOINT` + `GKE_CLUSTER_CA`
             + GSA ADC. Refreshes the token on every call (creds are short-lived;
             this also lets us pick up GSA rotation).
          2. In-cluster: standard kubelet-served service-account token.
          3. Local kubeconfig (dev mode).
        """
        endpoint = os.environ.get("GKE_CLUSTER_ENDPOINT")
        ca_b64 = os.environ.get("GKE_CLUSTER_CA")
        if endpoint and ca_b64:
            return self._build_gke_client_from_env(endpoint, ca_b64)
        try:
            config.load_incluster_config()
            log.info("k8s: in-cluster config loaded")
        except config.ConfigException:
            try:
                config.load_kube_config()
                log.info("k8s: local kubeconfig loaded (dev mode)")
            except Exception as exc:
                log.error("k8s: no kubeconfig available: %s", exc)
                raise
        return client.ApiClient()

    def _build_gke_client_from_env(
        self, endpoint: str, ca_b64: str,
    ) -> client.ApiClient:
        """Build an ApiClient against a GKE cluster from env-injected details.

        - endpoint: bare IP/host (no scheme)
        - ca_b64: base64-encoded cluster CA PEM
        Token comes from google.auth default credentials (the Cloud Run
        runtime SA, which has roles/container.developer per iam.tf).
        """
        # Write the CA cert to a temp file (Configuration.ssl_ca_cert wants a path).
        ca_path = "/tmp/gke-cluster-ca.crt"
        if not os.path.exists(ca_path):
            with open(ca_path, "wb") as f:
                f.write(base64.b64decode(ca_b64))

        # Mint a fresh OAuth2 access token from ADC.
        creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"],
        )
        creds.refresh(GoogleAuthRequest())

        cfg = client.Configuration()
        cfg.host = f"https://{endpoint}"
        cfg.ssl_ca_cert = ca_path
        cfg.api_key = {"authorization": f"Bearer {creds.token}"}
        # Force Configuration.verify_ssl on (default but explicit).
        cfg.verify_ssl = True
        return client.ApiClient(cfg)

    def _ensure_clients(self) -> None:
        # NOTE: we deliberately REBUILD the clients on every call. GSA
        # tokens expire ~1h; building fresh per-turn avoids the case where
        # a long-lived Cloud Run instance attempts API calls after token
        # expiry. The cost is negligible — Configuration construction is
        # microseconds. The asyncio lock above already serialises per user.
        api = self._build_api_client()
        self._co = client.CustomObjectsApi(api)
        self._v1 = client.CoreV1Api(api)

    async def get_or_create_claim(self, user_key: str) -> str:
        """Idempotent: returns the bound Sandbox name, creating if needed.

        Serialised per user via asyncio.Lock so concurrent turns from
        the same user don't race to create duplicate claims.
        """
        self._ensure_clients()
        cname = claim_name(user_key)
        async with self._locks[user_key]:
            return await asyncio.to_thread(self._sync_get_or_create, cname)

    def _sync_get_or_create(self, cname: str) -> str:
        """Sync impl that runs in a worker thread under the per-user lock."""
        # Try to GET the claim first — idempotent path.
        try:
            existing = self._co.get_namespaced_custom_object(
                group=GROUP_EXT, version=VERSION, namespace=NAMESPACE,
                plural="sandboxclaims", name=cname,
            )
            log.info("sandbox: existing claim found: %s", cname)
        except ApiException as exc:
            if exc.status != 404:
                raise
            existing = None

        if existing is None:
            body = {
                "apiVersion": f"{GROUP_EXT}/{VERSION}",
                "kind": "SandboxClaim",
                "metadata": {
                    "name": cname,
                    "namespace": NAMESPACE,
                    "labels": {"cc-a2a/user": cname},
                },
                "spec": {"sandboxTemplateRef": {"name": TEMPLATE}},
            }
            try:
                self._co.create_namespaced_custom_object(
                    group=GROUP_EXT, version=VERSION, namespace=NAMESPACE,
                    plural="sandboxclaims", body=body,
                )
                log.info("sandbox: claim created: %s", cname)
            except ApiException as exc:
                # Concurrent create on the SAME bridge instance is
                # prevented by the asyncio lock; CROSS-INSTANCE
                # concurrent create is rare but possible — a 409 means
                # another replica won the race, which is fine.
                if exc.status != 409:
                    raise
                log.info("sandbox: claim already exists (409 race): %s", cname)

        # Stamp the last-use annotation BEFORE waiting on Ready — the
        # sweeper sees the timestamp even on partial binds. patch is
        # idempotent (just overwrites the annotation).
        try:
            self._co.patch_namespaced_custom_object(
                group=GROUP_EXT, version=VERSION, namespace=NAMESPACE,
                plural="sandboxclaims", name=cname,
                body={
                    "metadata": {
                        "annotations": {_LAST_USE_ANNOTATION: str(time.time())},
                    },
                },
            )
        except ApiException as exc:
            log.warning("sandbox: patch last-use on %s failed: %s", cname, exc)

        # Poll until bound.
        return self._wait_until_bound(cname)

    def _wait_until_bound(self, cname: str) -> str:
        deadline = time.time() + _BIND_TIMEOUT_S
        sandbox_name: Optional[str] = None
        while time.time() < deadline:
            obj = self._co.get_namespaced_custom_object(
                group=GROUP_EXT, version=VERSION, namespace=NAMESPACE,
                plural="sandboxclaims", name=cname,
            )
            sb = (obj or {}).get("status", {}).get("sandbox") or {}
            sandbox_name = sb.get("Name")
            if sandbox_name:
                break
            time.sleep(_BIND_POLL_S)
        if not sandbox_name:
            raise RuntimeError(
                f"SandboxClaim {cname} did not bind within {_BIND_TIMEOUT_S}s"
            )

        # Verify pod readiness — claim status.sandbox.Name only tells us
        # the Sandbox CR was created. Production traffic needs the pod
        # itself in Ready state so the router's proxy succeeds.
        self._wait_pod_ready(sandbox_name)
        return sandbox_name

    def _wait_pod_ready(self, sandbox_name: str) -> None:
        # Read Sandbox.status.selector → label selector for the bound pod.
        sandbox = self._co.get_namespaced_custom_object(
            group=GROUP_AGENTS, version=VERSION, namespace=NAMESPACE,
            plural="sandboxes", name=sandbox_name,
        )
        selector = (sandbox or {}).get("status", {}).get("selector")
        if not selector:
            raise RuntimeError(
                f"Sandbox {sandbox_name} has no .status.selector"
            )
        deadline = time.time() + _BIND_TIMEOUT_S
        while time.time() < deadline:
            pods = self._v1.list_namespaced_pod(
                namespace=NAMESPACE, label_selector=selector,
            )
            if pods.items:
                pod = pods.items[0]
                conds = {c.type: c.status for c in (pod.status.conditions or [])}
                if conds.get("Ready") == "True":
                    log.info(
                        "sandbox: pod Ready: name=%s ip=%s",
                        pod.metadata.name, pod.status.pod_ip,
                    )
                    return
            time.sleep(_BIND_POLL_S)
        raise RuntimeError(
            f"Sandbox {sandbox_name} pod not Ready within {_BIND_TIMEOUT_S}s"
        )

    # ----- idle sweeper (Phase 6) -----

    async def start_sweeper(self) -> None:
        """Idempotent: start the background idle-cleanup loop if not running."""
        if self._sweeper_task is None or self._sweeper_task.done():
            self._sweeper_task = asyncio.create_task(self._sweep_loop())
            log.info(
                "sweeper: started (interval=%ds, idle_threshold=%ds)",
                _SWEEPER_INTERVAL_S, _IDLE_THRESHOLD_S,
            )

    async def _sweep_loop(self) -> None:
        # Sleep first so a freshly-deployed bridge doesn't immediately
        # delete claims of users that just got their pods.
        try:
            while True:
                await asyncio.sleep(_SWEEPER_INTERVAL_S)
                try:
                    deleted = await asyncio.to_thread(self._sync_sweep, time.time())
                    if deleted:
                        log.info("sweeper: pass deleted %d idle claims", deleted)
                except Exception:  # noqa: BLE001
                    log.exception("sweeper: pass failed; continuing loop")
        except asyncio.CancelledError:
            log.info("sweeper: cancelled, exiting")
            raise

    def _sync_sweep(self, now: float) -> int:
        self._ensure_clients()
        try:
            claims = self._co.list_namespaced_custom_object(
                group=GROUP_EXT, version=VERSION, namespace=NAMESPACE,
                plural="sandboxclaims",
            )
        except ApiException as exc:
            log.warning("sweeper: list failed: %s", exc)
            return 0

        deleted = 0
        for claim in claims.get("items", []):
            meta = claim.get("metadata", {}) or {}
            name = meta.get("name", "")
            if not name.startswith("cc-u-"):
                continue  # not one we manage
            annotations = meta.get("annotations", {}) or {}
            last_use_raw = annotations.get(_LAST_USE_ANNOTATION)
            if not last_use_raw:
                continue
            try:
                last_use = float(last_use_raw)
            except ValueError:
                continue
            age = now - last_use
            if age < _IDLE_THRESHOLD_S:
                continue
            try:
                self._co.delete_namespaced_custom_object(
                    group=GROUP_EXT, version=VERSION, namespace=NAMESPACE,
                    plural="sandboxclaims", name=name,
                )
                deleted += 1
                log.info(
                    "sweeper: deleted idle claim %s (age=%.0fs)", name, age,
                )
            except ApiException as exc:
                if exc.status != 404:
                    log.warning("sweeper: delete %s failed: %s", name, exc)
        return deleted


# Module singleton — every bridge request shares this broker.
_BROKER: Optional[SandboxBroker] = None


def broker() -> SandboxBroker:
    global _BROKER
    if _BROKER is None:
        _BROKER = SandboxBroker()
    return _BROKER
