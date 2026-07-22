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

# The gateway runs as a dedicated service account and reaches the model
# upstream with Application Default Credentials. It talks to Cloud SQL over the
# VPC as a password user, so it needs no Cloud SQL IAM role.
resource "google_service_account" "gateway_sa" {
  account_id   = var.service_name
  display_name = "Claude apps gateway"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.gateway_sa.email}"
}
