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

# Service APIs. disable_on_destroy stays false so teardown never disables an
# API that other workloads in a shared project depend on.
resource "google_project_service" "apis" {
  for_each = toset([
    "aiplatform.googleapis.com",       # model upstream
    "artifactregistry.googleapis.com", # container image
    "cloudbuild.googleapis.com",       # image build
    "sqladmin.googleapis.com",         # session store
    "secretmanager.googleapis.com",    # config and secrets
    "iamcredentials.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",             # VPC for private-IP Cloud SQL
    "servicenetworking.googleapis.com",   # Private Services Access peering
    "run.googleapis.com",                 # compute
  ])

  service            = each.key
  disable_on_destroy = false
}
