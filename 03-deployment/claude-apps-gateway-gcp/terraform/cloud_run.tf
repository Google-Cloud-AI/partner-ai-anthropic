# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

resource "google_cloud_run_v2_service" "gateway" {
  name     = var.service_name
  location = var.region
  ingress  = var.ingress

  template {
    service_account = google_service_account.gateway_sa.email
    timeout         = "${var.request_timeout_seconds}s"

    scaling {
      min_instance_count = var.min_instances
    }

    containers {
      image = local.image_tag

      volume_mounts {
        name       = "config-volume"
        mount_path = "/etc/claude"
      }

      # The rendered gateway.yaml refers to this by ${GATEWAY_PUBLIC_URL}, so
      # correcting the URL after the first apply is an env-var update on the
      # service rather than a new secret version and config reload.
      env {
        name  = "GATEWAY_PUBLIC_URL"
        value = var.gateway_public_url != "" ? var.gateway_public_url : "https://placeholder.invalid"
      }

      dynamic "env" {
        for_each = {
          GATEWAY_JWT_SECRET   = "gateway-jwt-secret"
          OIDC_CLIENT_SECRET   = "gateway-oidc-client-secret"
          GATEWAY_POSTGRES_URL = "gateway-postgres-url"
        }

        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.gateway[env.value].secret_id
              version = "latest"
            }
          }
        }
      }
    }

    volumes {
      name = "config-volume"
      secret {
        secret = google_secret_manager_secret.gateway["gateway-config"].secret_id
        items {
          version = "latest"
          path    = "gateway.yaml"
        }
      }
    }

    # Direct VPC egress reaches the Cloud SQL private IP. Restricting egress to
    # private ranges keeps model-upstream and IdP traffic on the default path,
    # so no Cloud NAT is required.
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc.id
        subnetwork = google_compute_subnetwork.subnet.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }
  }

  lifecycle {
    precondition {
      condition     = var.ingress != "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" || var.gateway_public_url != ""
      error_message = "gateway_public_url is required with INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER: there is no generated URL to fall back to, and the gateway builds its IdP redirect_uri from this value alone."
    }

    precondition {
      condition     = var.ingress != "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" || var.proxy_only_subnet_cidr != ""
      error_message = "proxy_only_subnet_cidr is required with INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER, so the ALB is a trusted hop and client IPs survive into rate limits and audit events."
    }
  }

  depends_on = [
    null_resource.docker_push,
    google_secret_manager_secret_version.gateway,
    google_secret_manager_secret_iam_member.gateway,
  ]
}

# The invoker check must be open or disabled: the gateway runs its own OIDC and
# its clients carry no GCP token, so an enforced check returns 403 before any
# request reaches the container. Reachability is restricted by var.ingress,
# which is an independent layer. See docs/NETWORKING.md.
resource "google_cloud_run_v2_service_iam_member" "public_access" {
  count = var.invoker_mode == "allusers" ? 1 : 0

  project  = google_cloud_run_v2_service.gateway.project
  location = google_cloud_run_v2_service.gateway.location
  name     = google_cloud_run_v2_service.gateway.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
