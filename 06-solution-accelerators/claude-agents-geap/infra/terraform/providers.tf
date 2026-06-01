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

provider "google" {
  project = var.project_id
  region  = var.region
}

# kubectl provider (gavinbunney/kubectl) — Phase 2 wires it against the
# cc-sandbox cluster. The data source has no inputs; it returns an OAuth2
# access token from the current ADC, which terraform's google provider
# already authenticates.
data "google_client_config" "default" {}

provider "kubectl" {
  host                   = "https://${google_container_cluster.cc_sandbox.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.cc_sandbox.master_auth[0].cluster_ca_certificate)
  load_config_file       = false
}

# Phase 5: read-only access to live Service status (Internal LB IP).
provider "kubernetes" {
  host                   = "https://${google_container_cluster.cc_sandbox.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.cc_sandbox.master_auth[0].cluster_ca_certificate)
}
