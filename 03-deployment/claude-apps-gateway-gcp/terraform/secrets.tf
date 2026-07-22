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

# Four secrets. Cloud Run cannot mount multiple secrets into one directory, so
# gateway.yaml mounts as a file and the other three inject as environment
# variables that the YAML references with ${VAR} expansion.

locals {
  secrets = {
    gateway-config = {
      data        = local.gateway_yaml
      description = "Rendered gateway.yaml, mounted at /etc/claude/gateway.yaml"
    }
    gateway-jwt-secret = {
      data        = random_id.jwt_secret.b64_std
      description = "Signing key for gateway session JWTs"
    }
    gateway-oidc-client-secret = {
      data        = var.oauth_client_secret
      description = "OAuth client secret for the IdP"
    }
    gateway-postgres-url = {
      data        = local.postgres_url
      description = "Connection string for the session store"
    }
  }
}

resource "random_id" "jwt_secret" {
  byte_length = 32
}

resource "google_secret_manager_secret" "gateway" {
  for_each = local.secrets

  secret_id = each.key

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "gateway" {
  for_each = local.secrets

  secret      = google_secret_manager_secret.gateway[each.key].id
  secret_data = each.value.data
}

resource "google_secret_manager_secret_iam_member" "gateway" {
  for_each = local.secrets

  secret_id = google_secret_manager_secret.gateway[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.gateway_sa.email}"
}
