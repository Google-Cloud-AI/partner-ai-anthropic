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

# ---------------------------------------------------------------------------
# Project
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "The GCP project ID to deploy into."
  type        = string
}

variable "region" {
  description = <<-EOT
    The GCP region for Cloud Run, Cloud SQL, and Artifact Registry.

    This must be a region where the Claude models you need are published in
    Model Garden — model availability is per-region and is the binding
    constraint here, not latency. Check each model card before changing it.
  EOT
  type        = string
  default     = "us-east5"
}

# ---------------------------------------------------------------------------
# Gateway version
# ---------------------------------------------------------------------------

variable "gateway_version" {
  description = <<-EOT
    Pinned Claude Code release whose `claude` binary is baked into the image.
    The gateway server ships inside the standard binary, so this is a Claude
    Code version string. Also used as the container image tag, so bumping it
    forces a rebuild and a new Cloud Run revision.
  EOT
  type        = string
  default     = "2.1.206"
}

# ---------------------------------------------------------------------------
# Identity provider (OIDC)
# ---------------------------------------------------------------------------

variable "oauth_client_id" {
  description = "OAuth 2.0 web-application client ID from your IdP (Google Workspace in the default config)."
  type        = string
}

variable "oauth_client_secret" {
  description = "OAuth 2.0 client secret matching oauth_client_id."
  type        = string
  sensitive   = true
}

variable "allowed_email_domain" {
  description = <<-EOT
    Email domain permitted to sign in, e.g. "example.com".

    This is the gateway's entire access-control list: id_tokens outside this
    domain are rejected. It has no safe default, so there is none.
  EOT
  type        = string

  validation {
    condition     = var.allowed_email_domain != "example.com"
    error_message = "allowed_email_domain is still the placeholder 'example.com'. Set it to your real Workspace domain."
  }
}

# ---------------------------------------------------------------------------
# Network exposure
# ---------------------------------------------------------------------------
# See docs/NETWORKING.md. Claude Code's /login refuses any self-hosted gateway
# whose hostname resolves to a public address, so both supported topologies are
# private; the choice is which private topology you already have plumbing for.

variable "ingress" {
  description = <<-EOT
    Cloud Run ingress setting. Two supported topologies:

      INGRESS_TRAFFIC_INTERNAL_ONLY (default)
        No load balancer. public_url stays the *.run.app URL, which only
        resolves privately if your org already runs a Private Service Connect
        endpoint for Google APIs plus a Cloud DNS private zone.

      INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER
        Behind an internal Application Load Balancer that you provision
        separately, with your own internal DNS name and TLS certificate.
        Requires gateway_public_url and proxy_only_subnet_cidr.

    INGRESS_TRAFFIC_ALL is deliberately not offered: it deploys cleanly and
    then fails at developer sign-in.
  EOT
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  validation {
    condition = contains([
      "INGRESS_TRAFFIC_INTERNAL_ONLY",
      "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
    ], var.ingress)
    error_message = "ingress must be INGRESS_TRAFFIC_INTERNAL_ONLY or INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER. INGRESS_TRAFFIC_ALL is unsupported: /login rejects publicly-resolving gateways."
  }
}

variable "gateway_public_url" {
  description = <<-EOT
    The origin developers reach the gateway at. The gateway builds its IdP
    redirect_uri and discovery document from this value alone, never from
    X-Forwarded-* headers, so it must match the OAuth client's authorized
    redirect URI (<public_url>/oauth/callback).

    Leave empty with internal-only ingress: the first apply populates it with
    the generated *.run.app URL, breaking the chicken-and-egg. Required when
    ingress is INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER.
  EOT
  type        = string
  default     = ""
}

variable "proxy_only_subnet_cidr" {
  description = <<-EOT
    CIDR of the region's proxy-only subnet, added to listen.trusted_proxies
    when running behind an internal ALB. Without it the gateway attributes
    every request to the load balancer, so per-IP sign-in rate limits and
    audit events lose the developer's real IP.
  EOT
  type        = string
  default     = ""
}

variable "invoker_mode" {
  description = <<-EOT
    How Cloud Run's invoker IAM check is satisfied. The check must be open or
    disabled either way: the gateway runs its own OIDC and its clients carry no
    GCP token, so an enforced invoker check returns 403 before any request
    reaches the container. Ingress is the independent layer that restricts
    reachability.

      allusers  (default) Grants allUsers roles/run.invoker. Matches the
                upstream reference assets. Blocked by Domain Restricted Sharing
                (constraints/iam.allowedPolicyMemberDomains).

      external  Creates no binding. Use when DRS blocks allUsers: disable the
                check out of band with
                  gcloud run services update claude-gateway \
                    --region=<region> --no-invoker-iam-check
                or manage it with the google-beta provider, whose
                invoker_iam_disabled attribute the stable provider lacks.
  EOT
  type        = string
  default     = "allusers"

  validation {
    condition     = contains(["allusers", "external"], var.invoker_mode)
    error_message = "invoker_mode must be \"allusers\" or \"external\"."
  }
}

# ---------------------------------------------------------------------------
# Runtime sizing
# ---------------------------------------------------------------------------

variable "min_instances" {
  description = <<-EOT
    Minimum Cloud Run instances. Keep at 1: gateway boot is fail-closed and
    gives Postgres a 5-second connection timeout, so scale-to-zero turns every
    cold start into a sign-in failure risk.
  EOT
  type        = number
  default     = 1
}

variable "request_timeout_seconds" {
  description = "Cloud Run request timeout. Streaming responses are cut off at this bound; the platform default of 300s is too low."
  type        = number
  default     = 3600
}

variable "db_tier" {
  description = "Cloud SQL machine tier. The gateway stores short-lived auth state and rate-limit counters, so the smallest tier is sufficient unless spend limits are enabled."
  type        = string
  default     = "db-g1-small"
}

variable "db_deletion_protection" {
  description = "Cloud SQL deletion protection. Defaults false so teardown.sh can complete unattended; set true for anything long-lived."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Networking names
# ---------------------------------------------------------------------------

variable "vpc_name" {
  description = "Name of the VPC hosting Cloud Run's direct egress and the private-IP Cloud SQL instance."
  type        = string
  default     = "cc-gateway-vpc"
}

variable "subnet_name" {
  description = "Name of the gateway subnet. Matches the name used in the upstream documentation; changing it on an existing deployment forces the subnet to be replaced."
  type        = string
  default     = "cc-gateway-subnet"
}

variable "subnet_cidr" {
  description = "CIDR for the gateway subnet used by Cloud Run direct VPC egress."
  type        = string
  default     = "10.0.0.0/24"
}

variable "service_name" {
  description = "Name shared by the Cloud Run service, service account, and Artifact Registry repository."
  type        = string
  default     = "claude-gateway"
}

# ---------------------------------------------------------------------------
# Image build
# ---------------------------------------------------------------------------

variable "build_image" {
  description = <<-EOT
    Whether Terraform should build and push the container image via Cloud Build
    before deploying. Set false in CI where the image is built by a separate
    pipeline stage; the image must already exist at the expected tag.
  EOT
  type        = bool
  default     = true
}
