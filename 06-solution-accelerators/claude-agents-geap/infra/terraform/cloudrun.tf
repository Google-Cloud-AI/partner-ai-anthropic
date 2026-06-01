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
# cc-a2a-bridge — Cloud Run service (Phase 5)
# ----------------------------------------------------------------------------
# Pure A2A adapter. Receives JSON-RPC from Gemini Enterprise, resolves the
# end-user identity, get-or-creates a SandboxClaim for that user, and
# proxies the prompt to the in-cluster router via Direct VPC egress.
#
# Network model:
#   - ingress = INGRESS_TRAFFIC_ALL so Discovery Engine (out-of-VPC) can call.
#   - allow_unauthenticated = false (IAM-gated via run.invoker; granted to
#     the Discovery Engine service agent in iam.tf).
#   - Direct VPC egress on the default network/subnetwork → reaches the
#     internal-LB Service `sandbox-router-internal` at 10.128.15.223.
#
# Identity: cc-a2a-bridge GSA (defined in iam.tf, granted container.developer
# project-wide so it can create SandboxClaims via the Kubernetes API).
# ============================================================================

# Project number — Discovery Engine service-agent email format needs it.
data "google_project" "current" {
  project_id = var.project_id
}

# Internal-LB IP for the in-cluster sandbox-router. Read from the live
# Service status after k8s apply so a fresh deploy picks up whatever GKE
# allocated. The IP is stable until the Service is deleted.
data "kubernetes_service_v1" "sandbox_router_internal" {
  metadata {
    name      = "sandbox-router-internal"
    namespace = var.sandbox_namespace
  }
  depends_on = [kubectl_manifest.sandbox_router_internal_lb]
}

locals {
  router_internal_ip = (
    length(data.kubernetes_service_v1.sandbox_router_internal.status) > 0
    && length(data.kubernetes_service_v1.sandbox_router_internal.status[0].load_balancer) > 0
    && length(data.kubernetes_service_v1.sandbox_router_internal.status[0].load_balancer[0].ingress) > 0
  ) ? data.kubernetes_service_v1.sandbox_router_internal.status[0].load_balancer[0].ingress[0].ip : ""
}

resource "google_cloud_run_v2_service" "cc_a2a_bridge" {
  name     = "cc-a2a-bridge"
  location = var.region
  project  = var.project_id

  ingress      = "INGRESS_TRAFFIC_ALL"
  launch_stage = "GA"

  template {
    service_account                  = google_service_account.bridge.email
    timeout                          = "3600s"      # 1h — per CLAUDE.md
    max_instance_request_concurrency = 80
    scaling {
      min_instance_count = 1   # keep one warm so Discovery Engine never cold-starts
      max_instance_count = 10
    }

    # Direct VPC egress. Routes egress through default subnet so the
    # bridge can reach the internal-LB sandbox-router-internal Service.
    vpc_access {
      network_interfaces {
        network    = "default"
        subnetwork = "default"
      }
      egress = "ALL_TRAFFIC"
    }

    containers {
      image = "us-central1-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}/cc-a2a-bridge:phase12-r5"

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "1Gi"
        }
        cpu_idle          = false   # min=1 → keep CPU allocated for fast first turn
        startup_cpu_boost = true
      }

      env {
        name  = "ROUTER_HOST"
        value = local.router_internal_ip
      }
      env {
        name  = "ROUTER_PORT"
        value = "80"
      }
      env {
        name  = "SANDBOX_NAMESPACE"
        value = var.sandbox_namespace
      }
      env {
        name  = "SANDBOX_PORT"
        value = "9000"
      }
      # Cluster endpoint + name so the in-pod kubeconfig path works.
      env {
        name  = "GKE_CLUSTER_NAME"
        value = google_container_cluster.cc_sandbox.name
      }
      env {
        name  = "GKE_CLUSTER_LOCATION"
        value = google_container_cluster.cc_sandbox.location
      }
      env {
        # Cluster API server endpoint (no scheme; sandbox.py prepends https://).
        name  = "GKE_CLUSTER_ENDPOINT"
        value = google_container_cluster.cc_sandbox.endpoint
      }
      env {
        # Cluster CA cert (PEM, base64). sandbox.py decodes + writes to /tmp.
        name  = "GKE_CLUSTER_CA"
        value = google_container_cluster.cc_sandbox.master_auth[0].cluster_ca_certificate
      }
      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      # Phase 4 lesson — bypass DNS for metadata fetches under any
      # constrained runtime. Cloud Run is fine but keeping this for
      # parity with the backend Sandbox.
      env {
        name  = "GCE_METADATA_HOST"
        value = "169.254.169.254"
      }
      env {
        # Phase 7: the public URL that the AgentCard advertises and that
        # gets embedded into the Discovery Engine A2A registration as
        # jsonAgentCard.url. MUST match the live Cloud Run URL so
        # Gemini Enterprise calls back to the right place.
        name  = "PUBLIC_URL"
        value = "https://cc-a2a-bridge-qrr3gkz3tq-uc.a.run.app"
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 30   # 30 * 5s = 150s for cold start
      }

      liveness_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        period_seconds  = 30
        timeout_seconds = 5
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    kubectl_manifest.sandbox_router_internal_lb,
    google_project_iam_member.bridge_container_developer,
  ]
}

# ---------------------------------------------------------------------------
# run.invoker grants
# ---------------------------------------------------------------------------

# Phase 8 — backend GSA needs run.invoker on the bridge so the pod's
# `get_download_url` tool can POST to /workspace/sign. This is a
# narrowly-scoped grant: the backend SA can only hit endpoints the
# bridge exposes, and /workspace/sign itself defends in depth by
# requiring X-User-Id to match the requested object's prefix.
resource "google_cloud_run_v2_service_iam_member" "bridge_invoker_backend" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.cc_a2a_bridge.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.backend.email}"
}

# Allow the Discovery Engine service agent to invoke the bridge. This is
# the IAM hook that lets Gemini Enterprise call the agent once registration
# completes (Phase 7). Granting it now keeps the IAM-as-code authoritative;
# the agent simply remains unreachable from GE until registration.
#
# Service agent email format (Discovery Engine):
#   service-<projectNumber>@gcp-sa-discoveryengine.iam.gserviceaccount.com
resource "google_cloud_run_v2_service_iam_member" "bridge_invoker_discoveryengine" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.cc_a2a_bridge.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "bridge_url" {
  value       = google_cloud_run_v2_service.cc_a2a_bridge.uri
  description = "Cloud Run URL for cc-a2a-bridge. Discovery Engine registers this."
}

output "router_internal_lb_ip" {
  value       = local.router_internal_ip
  description = "Internal LB IP for sandbox-router (used by the bridge)."
}
