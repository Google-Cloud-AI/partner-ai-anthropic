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

# ============================================================================
# In-cluster manifests for cc-backend (Phase 2)
# ----------------------------------------------------------------------------
# Resources:
#   - Namespace cc-sandbox
#   - ServiceAccount cc-sandbox-sa (Workload Identity → backend GSA)
#   - SandboxTemplate cc-backend (gVisor, /workspace, FIRESTORE_DATABASE env,
#     inline networkPolicy)
#   - SandboxWarmPool cc-backend-warm (replicas: 2)
#
# Phase 5: sandbox-router (mirrored from upstream kubernetes-sigs/agent-sandbox).
# - ClusterIP `sandbox-router-svc` (matches upstream's name)
# - Deployment `sandbox-router-deployment` (replicas: 2, zone-spread)
# - Internal LB `sandbox-router-internal` so Cloud Run reaches it via Direct VPC egress
# - Standalone NetworkPolicy `allow-router-to-cc-backend` (defense in depth)
#
# CRD apiGroup notes (per Phase 1 + Phase 2 lessons):
#   - SandboxTemplate / SandboxWarmPool / SandboxClaim — `extensions.agents.x-k8s.io/v1alpha1`
#   - Sandbox itself                                    — `agents.x-k8s.io/v1alpha1` (controller-managed, we never author)
# ============================================================================

# ============================================================================
# Phase 6 — noexec /workspace via custom StorageClass
# ----------------------------------------------------------------------------
# Autopilot Warden blocks SYS_ADMIN capability (Phase 6 Probe B), so an
# init-container `mount --bind ... -o noexec` is not viable. Instead we
# create a dedicated StorageClass whose `mountOptions` carry noexec (plus
# nodev + nosuid for defense in depth), and switch the SandboxTemplate's
# ephemeral PVC template to use it.
#
# Verified in Probe B: under this StorageClass, `chmod +x /workspace/myecho
# && /workspace/myecho` fails with EACCES (PASS). `mount` output doesn't
# always list the option (containerd quirk) but the enforcement is real.
# ============================================================================

resource "kubectl_manifest" "sc_standard_rwo_noexec" {
  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: standard-rwo-noexec
      labels:
        app.kubernetes.io/part-of: cc-on-ge
    provisioner: pd.csi.storage.gke.io
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    mountOptions:
      - noexec
      - nodev
      - nosuid
    parameters:
      type: pd-balanced
  YAML
}

resource "kubectl_manifest" "ns_cc_sandbox" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${var.sandbox_namespace}
      labels:
        app.kubernetes.io/part-of: cc-on-ge
  YAML

  depends_on = [null_resource.enable_agent_sandbox]
}

resource "kubectl_manifest" "ksa_cc_sandbox_sa" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: ${var.sandbox_ksa_name}
      namespace: ${var.sandbox_namespace}
      annotations:
        iam.gke.io/gcp-service-account: ${google_service_account.backend.email}
  YAML

  depends_on = [kubectl_manifest.ns_cc_sandbox]
}

resource "kubectl_manifest" "sandbox_template_cc_backend" {
  yaml_body = <<-YAML
    apiVersion: extensions.agents.x-k8s.io/v1alpha1
    kind: SandboxTemplate
    metadata:
      name: cc-backend
      namespace: ${var.sandbox_namespace}
    spec:
      podTemplate:
        metadata:
          labels:
            # `app: cc-backend` is used by the standalone allow-router-to-cc-backend
            # NetworkPolicy (below) to select all backend pods — warm AND claimed.
            # The SandboxTemplate's inline networkPolicy already covers claimed
            # pods specifically; this label keeps warm pods tight too.
            app: cc-backend
        spec:
          runtimeClassName: gvisor
          serviceAccountName: ${var.sandbox_ksa_name}
          containers:
            - name: backend
              image: us-central1-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}/cc-backend:phase12-r4
              ports:
                - containerPort: 9000
              env:
                - {name: CLAUDE_CODE_USE_VERTEX, value: "1"}
                - {name: ANTHROPIC_VERTEX_PROJECT_ID, value: "${var.project_id}"}
                - {name: CLOUD_ML_REGION, value: "global"}
                - {name: ANTHROPIC_MODEL, value: "claude-opus-4-7"}
                - {name: IS_SANDBOX, value: "1"}
                # LiteLLM (ADK orchestrator) reads VERTEXAI_*, not ANTHROPIC_VERTEX_*.
                # The two SDKs target the same Vertex global endpoint but require
                # different env-var schemes. See vertex-claude skill.
                - {name: VERTEXAI_PROJECT, value: "${var.project_id}"}
                - {name: VERTEXAI_LOCATION, value: "global"}
                - {name: FIRESTORE_DATABASE, value: "${var.firestore_database_name}"}
                # Bypass DNS for metadata fetches. Phase 4 Lesson: under
                # gVisor, DNS for `metadata.google.internal` is flaky. The
                # ADC prewarm at module load only caches OUR credentials
                # object — LiteLLM's Vertex client instantiates its OWN
                # google.auth.compute_engine.Credentials mid-turn, hitting
                # the metadata server again and failing on DNS. The link-
                # local IP 169.254.169.254 is the documented stable address
                # for GCE metadata; pointing GCE_METADATA_HOST at it skips
                # DNS for all google.auth metadata fetches.
                - {name: GCE_METADATA_HOST, value: "169.254.169.254"}
                # Phase 8 — backend get_download_url tool calls the
                # bridge's /workspace/sign endpoint for the signed-URL
                # fallback (artifacts >5 MB).
                - {name: BRIDGE_URL, value: "https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app"}
              volumeMounts:
                - {name: workspace, mountPath: /workspace}
          volumes:
            - name: workspace
              ephemeral:
                volumeClaimTemplate:
                  spec:
                    accessModes: [ReadWriteOnce]
                    # Phase 6: dedicated StorageClass with noexec/nodev/nosuid
                    # mount options. See `sc_standard_rwo_noexec` above.
                    storageClassName: standard-rwo-noexec
                    resources:
                      requests:
                        storage: 20Gi
      networkPolicy:
        # Allow ingress only from the sandbox-router pod (Phase 5). Until
        # the router exists this evaluates to "deny all ingress", which is
        # the correct posture. Smoke tests `kubectl exec` into the bound
        # pod and curl localhost:9000 from inside (NetworkPolicy doesn't
        # restrict loopback or apiserver-tunneled exec).
        ingress:
          - from:
              - podSelector:
                  matchLabels:
                    app: sandbox-router
            ports:
              - {port: 9000, protocol: TCP}
        # Allow all egress. PHASE 4 LESSON: the Agent Sandbox controller
        # auto-promotes policyTypes to [Ingress, Egress] when you specify
        # ANY ingress block. With no `egress:` rules listed, that becomes
        # "deny ALL egress" — including the GCE metadata server (169.254
        # .169.254), kube-dns, Vertex, and Firestore. That broke the
        # remember/recall tools mid-turn and the LiteLLM credentials
        # refresh. v1 scope keeps the isolation guarantees via gVisor +
        # Workload Identity + downscoped STS tokens (Phase 6); network-
        # level egress lockdown is deferred to Production hardening
        # (per CLAUDE.md "Out of scope" list).
        egress:
          - {}
  YAML

  depends_on = [kubectl_manifest.ksa_cc_sandbox_sa]
}

resource "kubectl_manifest" "sandbox_warmpool_cc_backend" {
  yaml_body = <<-YAML
    apiVersion: extensions.agents.x-k8s.io/v1alpha1
    kind: SandboxWarmPool
    metadata:
      name: cc-backend-warm
      namespace: ${var.sandbox_namespace}
    spec:
      sandboxTemplateRef:
        name: cc-backend
      replicas: 2
  YAML

  depends_on = [kubectl_manifest.sandbox_template_cc_backend]
}

# ============================================================================
# Phase 5 — sandbox-router (mirrored from kubernetes-sigs/agent-sandbox)
# ----------------------------------------------------------------------------
# Manifests follow upstream `sandbox_router.yaml` from
# clients/python/agentic-sandbox-client/sandbox-router/ with three project
# modifications:
#   1. Image pinned to our AR mirror (scripts/mirror-sandbox-router.sh).
#   2. PROXY_TIMEOUT_SECONDS=1800 (upstream default of 180s is too short
#      for our typical multi-tool agent turns).
#   3. Internal LB Service in front so Cloud Run reaches the router via
#      Direct VPC egress without a public IP. The upstream ClusterIP
#      service stays for in-cluster verification.
# ============================================================================

resource "kubectl_manifest" "sandbox_router_svc" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: sandbox-router-svc
      namespace: ${var.sandbox_namespace}
      labels:
        app.kubernetes.io/name: sandbox-router
        app.kubernetes.io/part-of: cc-on-ge
    spec:
      type: ClusterIP
      selector:
        app: sandbox-router
      ports:
        - {name: http, protocol: TCP, port: 8080, targetPort: 8080}
  YAML

  depends_on = [kubectl_manifest.ns_cc_sandbox]
}

resource "kubectl_manifest" "sandbox_router_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: sandbox-router-deployment
      namespace: ${var.sandbox_namespace}
      labels:
        app.kubernetes.io/name: sandbox-router
        app.kubernetes.io/part-of: cc-on-ge
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: sandbox-router
      template:
        metadata:
          labels:
            app: sandbox-router
            app.kubernetes.io/name: sandbox-router
            app.kubernetes.io/part-of: cc-on-ge
        spec:
          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: ScheduleAnyway
              labelSelector:
                matchLabels:
                  app: sandbox-router
          containers:
            - name: router
              image: us-central1-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}/sandbox-router:upstream-v0.1.1.post3-10-ga5bcb57
              env:
                # Upstream default is 180s; we run multi-tool agent turns
                # that legitimately exceed that. 30 min == the effective
                # ceiling between GE's host timeout (~10 min, hard) and
                # the pod (unbounded). See gke-agent-sandbox skill,
                # "Timeout hierarchy".
                - {name: PROXY_TIMEOUT_SECONDS, value: "1800"}
              ports:
                - {containerPort: 8080}
              readinessProbe:
                httpGet: {path: /healthz, port: 8080}
                initialDelaySeconds: 5
                periodSeconds: 5
              livenessProbe:
                httpGet: {path: /healthz, port: 8080}
                initialDelaySeconds: 10
                periodSeconds: 10
              resources:
                requests: {cpu: "250m", memory: "512Mi"}
                limits:   {cpu: "1000m", memory: "1Gi"}
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
  YAML

  depends_on = [kubectl_manifest.sandbox_router_svc]
}

resource "kubectl_manifest" "sandbox_router_internal_lb" {
  # Internal-only LoadBalancer Service. Cloud Run will reach this address
  # via Direct VPC egress (configured in cloudrun.tf, Phase 5). The
  # internal IP is allocated by GKE — read it from kubectl after apply.
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: sandbox-router-internal
      namespace: ${var.sandbox_namespace}
      labels:
        app.kubernetes.io/name: sandbox-router
        app.kubernetes.io/part-of: cc-on-ge
      annotations:
        networking.gke.io/load-balancer-type: "Internal"
    spec:
      type: LoadBalancer
      selector:
        app: sandbox-router
      ports:
        - {name: http, protocol: TCP, port: 80, targetPort: 8080}
  YAML

  depends_on = [kubectl_manifest.sandbox_router_deployment]
}

resource "kubectl_manifest" "allow_router_to_cc_backend" {
  # Standalone NetworkPolicy. The SandboxTemplate's inline networkPolicy
  # only applies to CLAIMED pods (via the controller-injected claim-uid
  # label selector). This standalone policy selects every pod labeled
  # `app: cc-backend` — warm AND claimed — and admits only the router
  # on TCP/9000.
  #
  # CRITICAL (Phase 4 lesson): `policyTypes: [Ingress]` is set
  # EXPLICITLY so the controller does not auto-promote to
  # [Ingress, Egress]. With no `egress:` rules, that auto-promotion
  # would deny ALL egress — including the metadata server. This rule
  # governs ingress only; egress stays under the SandboxTemplate's
  # inline rule (which allows all egress).
  yaml_body = <<-YAML
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-router-to-cc-backend
      namespace: ${var.sandbox_namespace}
      labels:
        app.kubernetes.io/part-of: cc-on-ge
    spec:
      podSelector:
        matchLabels:
          app: cc-backend
      policyTypes:
        - Ingress
      ingress:
        - from:
            - podSelector:
                matchLabels:
                  app: sandbox-router
          ports:
            - {port: 9000, protocol: TCP}
  YAML

  depends_on = [kubectl_manifest.sandbox_router_deployment]
}
