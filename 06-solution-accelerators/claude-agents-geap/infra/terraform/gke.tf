# ============================================================================
# GKE Autopilot cluster — cc-sandbox
# ----------------------------------------------------------------------------
# Phase 1 creates the Autopilot cluster bare. The Agent Sandbox addon is
# enabled by a follow-on null_resource (below) because the provider has no
# native field for it yet.
#
# See PROJECT_PLAN.md → "Known deferrals" → "GKE Agent Sandbox addon".
# ============================================================================

resource "google_container_cluster" "cc_sandbox" {
  name             = var.cluster_name
  location         = var.region
  project          = var.project_id
  enable_autopilot = true

  release_channel {
    channel = var.gke_release_channel
  }

  min_master_version = var.gke_min_version

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Allow Terraform to destroy the cluster during dev iteration.
  # TODO (pre-production): set to true.
  deletion_protection = false
}

# ============================================================================
# WORKAROUND — enable Agent Sandbox addon via gcloud beta
# ----------------------------------------------------------------------------
# hashicorp/google ~> 5.45 has NO field for the Agent Sandbox addon on
# google_container_cluster. Verified: provider docs (GA + beta) show no
# `agent_sandbox_config`, no `enable_agent_sandbox`, no equivalent. The
# Agent Sandbox feature is Preview at GKE and provider support lags.
#
# This null_resource runs the gcloud beta update command after cluster
# creation. scripts/check-env.sh enforces that the 'beta' gcloud component
# is installed on the apply host.
#
# FORWARD MIGRATION (remove this entire block when the provider catches up):
#   1. Add to google_container_cluster.cc_sandbox above:
#        addons_config { agent_sandbox_config { enabled = true } }
#      (or whatever the final shape is — confirm against provider changelog)
#   2. Delete this null_resource.
#   3. Delete the 'gcloud beta --help' check from scripts/check-env.sh.
#   4. Update PROJECT_PLAN.md → "Known deferrals" to mark this resolved.
#
# Tracked: PROJECT_PLAN.md → "Known deferrals" → "GKE Agent Sandbox addon".
# Provider upstream: https://github.com/hashicorp/terraform-provider-google
# ============================================================================

resource "null_resource" "enable_agent_sandbox" {
  triggers = {
    cluster_id = google_container_cluster.cc_sandbox.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      gcloud beta container clusters update ${google_container_cluster.cc_sandbox.name} \
        --location ${google_container_cluster.cc_sandbox.location} \
        --project ${var.project_id} \
        --enable-agent-sandbox \
        --quiet
    EOT
  }
}
