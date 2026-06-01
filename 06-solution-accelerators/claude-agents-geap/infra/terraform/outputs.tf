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

output "cluster_name" {
  description = "GKE Autopilot cluster name."
  value       = google_container_cluster.cc_sandbox.name
}

output "cluster_location" {
  description = "GKE Autopilot cluster region."
  value       = google_container_cluster.cc_sandbox.location
}

output "cluster_endpoint" {
  description = "GKE Autopilot cluster API endpoint. Marked sensitive — used by Phase 2 kubectl provider."
  value       = google_container_cluster.cc_sandbox.endpoint
  sensitive   = true
}

output "snapshots_bucket_name" {
  description = "GCS bucket holding per-user workspace snapshots."
  value       = google_storage_bucket.snapshots.name
}

output "artifact_registry_repo_url" {
  description = "Artifact Registry Docker repository URL (used as image push target)."
  value       = "${google_artifact_registry_repository.cc_on_ge.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.cc_on_ge.repository_id}"
}

output "bridge_sa_email" {
  description = "cc-a2a-bridge (Cloud Run) service account email."
  value       = google_service_account.bridge.email
}

output "backend_sa_email" {
  description = "cc-a2a-backend (GKE per-user pod) service account email."
  value       = google_service_account.backend.email
}

output "firestore_database_name" {
  description = "Firestore native database name (cc-on-ge — named, not the project's `(default)`)."
  value       = google_firestore_database.cc_on_ge.name
}
