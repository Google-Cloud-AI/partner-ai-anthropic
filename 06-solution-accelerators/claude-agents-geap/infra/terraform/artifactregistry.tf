# ============================================================================
# Artifact Registry — Docker repo for cc-bridge and cc-backend images
# ============================================================================

resource "google_artifact_registry_repository" "cc_on_ge" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repo
  description   = "Container images for cc-a2a-bridge (Cloud Run) and cc-backend (GKE)."
  format        = "DOCKER"
}
