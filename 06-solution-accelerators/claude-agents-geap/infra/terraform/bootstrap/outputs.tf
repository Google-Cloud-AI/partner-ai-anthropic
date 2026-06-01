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

output "state_bucket_name" {
  description = "Name of the Terraform state bucket. Use as the main root's gcs backend bucket."
  value       = google_storage_bucket.tfstate.name
}

output "builder_sa_email" {
  description = "Email of the Cloud Build service account."
  value       = google_service_account.builder.email
}

output "enabled_services" {
  description = "Project services enabled by bootstrap."
  value       = sort([for s in google_project_service.enabled : s.service])
}
