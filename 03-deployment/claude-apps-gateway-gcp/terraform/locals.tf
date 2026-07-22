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

locals {
  image_tag = "${var.region}-docker.pkg.dev/${var.project_id}/${var.service_name}/gateway:${var.gateway_version}"

  # The Cloud Run front end reaches containers over the link-local range. Behind
  # an internal ALB the proxy-only subnet is an additional trusted hop. The
  # gateway walks X-Forwarded-For past trusted hops to recover the developer's
  # IP for rate limiting and audit events; untrusted peers are ignored entirely.
  trusted_proxies = compact(concat(
    ["169.254.0.0/16"],
    var.ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" ? [var.proxy_only_subnet_cidr] : [],
  ))

  # sslmode=require, not disable: the hop is inside the VPC but the session
  # store carries auth state, and Cloud SQL terminates TLS for free.
  postgres_url = join("", [
    "postgres://gateway:",
    random_password.pg_pass.result,
    "@", google_sql_database_instance.gateway_db.private_ip_address,
    ":5432/claude_gateway?sslmode=require",
  ])

  # public_url and the three secret references stay as ${VAR} placeholders in
  # the rendered YAML: the gateway expands them from the environment at boot.
  # Keeping public_url out of the file means the post-deploy URL fixup is an
  # env-var update on the service rather than a new secret version.
  gateway_yaml = templatefile("${path.module}/../templates/gateway.yaml.template", {
    REGION          = var.region
    PROJECT_ID      = var.project_id
    OAUTH_CLIENT_ID = var.oauth_client_id
    ALLOWED_DOMAIN  = var.allowed_email_domain
    TRUSTED_PROXIES = jsonencode(local.trusted_proxies)
  })
}
