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

output "cloud_run_url" {
  description = "Cloud Run's generated URL for the service. Reachable only from inside the network perimeter set by var.ingress."
  value       = google_cloud_run_v2_service.gateway.uri
}

output "gateway_public_url" {
  description = "The origin developers sign in against, and the value to put in forceLoginGatewayUrl."
  value       = var.gateway_public_url != "" ? var.gateway_public_url : google_cloud_run_v2_service.gateway.uri
}

output "oauth_redirect_uri" {
  description = "Add this exact URI to the IdP OAuth client's authorized redirect URIs before the first sign-in."
  value       = "${var.gateway_public_url != "" ? var.gateway_public_url : google_cloud_run_v2_service.gateway.uri}/oauth/callback"
}

output "service_account_email" {
  description = "Runtime service account. Grant it any additional access the gateway needs."
  value       = google_service_account.gateway_sa.email
}

output "vpc_name" {
  description = "VPC hosting the gateway and its private-IP Cloud SQL instance."
  value       = google_compute_network.vpc.name
}

output "managed_settings_snippet" {
  description = "Drop this into each developer machine's managed settings file, via MDM. Without it there is no way for a developer to select the gateway at /login."
  value = jsonencode({
    forceLoginMethod       = "gateway"
    forceLoginGatewayUrl   = var.gateway_public_url != "" ? var.gateway_public_url : google_cloud_run_v2_service.gateway.uri
    parentSettingsBehavior = "merge"
  })
}

output "next_steps" {
  description = "Ordered follow-up actions after a successful apply."
  value = <<-EOT
    1. Add ${var.gateway_public_url != "" ? var.gateway_public_url : google_cloud_run_v2_service.gateway.uri}/oauth/callback
       to the OAuth client's authorized redirect URIs.
    2. Confirm the gateway host resolves to private addresses only, or /login
       will reject it. See docs/NETWORKING.md.
    3. Push the managed_settings_snippet output to developer machines via MDM.
    4. Verify sign-in from a machine on the corporate network.
  EOT
}
