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

# Cloud Build service account used by Phase 1+ pipelines.
#
# TODO (pre-external-demo): tighten roles. Editor + run.admin + container.admin
# is broad. Target: artifactregistry.writer + run.developer + container.developer
# + iam.serviceAccountUser + storage.objectAdmin (tfstate bucket only).
# Tracked in PROJECT_PLAN.md Phase 0.
resource "google_service_account" "builder" {
  account_id   = var.builder_sa_account_id
  display_name = "Cloud Build SA for cc-on-ge"
  description  = "Builds and deploys cc-a2a-bridge (Cloud Run) and cc-backend (GKE) images."
  project      = var.project_id

  depends_on = [google_project_service.enabled]
}

locals {
  builder_roles_mvp = [
    "roles/editor",
    "roles/run.admin",
    "roles/container.admin",
  ]
}

resource "google_project_iam_member" "builder_roles" {
  for_each = toset(local.builder_roles_mvp)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.builder.email}"
}
