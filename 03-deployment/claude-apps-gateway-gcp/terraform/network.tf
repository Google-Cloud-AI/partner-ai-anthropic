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

resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

# Cloud Run attaches here via direct VPC egress to reach the Cloud SQL private
# IP. Egress is PRIVATE_RANGES_ONLY, so traffic to the model upstream and to
# accounts.google.com leaves directly over the internet and no Cloud NAT is
# needed.
resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Private Services Access: a one-time-per-VPC peering that lets Cloud SQL exist
# with a private IP and no public address. This also satisfies projects that
# enforce constraints/sql.restrictPublicIp.
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "google-managed-services-${var.vpc_name}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "default" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

# NOTE ON TEARDOWN
# Destroying a service networking connection is the one step in this stack that
# routinely fails: the API rejects the delete while any producer resource still
# holds an address in the peered range, and Cloud SQL instances linger briefly
# after their own delete returns. A failed destroy here strands the VPC, the
# subnet, and the reserved range, because none of them can be removed while the
# peering exists.
#
# teardown.sh handles this: it retries, then falls back to
#   gcloud services vpc-peerings delete \
#     --service=servicenetworking.googleapis.com --network=<vpc>
# and re-runs destroy. Do not paper over it with deletion_policy = "ABANDON" —
# that drops the peering from state without deleting it, which turns a retryable
# failure into permanent orphaned infrastructure.
