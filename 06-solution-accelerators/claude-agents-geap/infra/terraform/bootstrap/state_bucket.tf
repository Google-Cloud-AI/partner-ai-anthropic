resource "google_storage_bucket" "tfstate" {
  name     = var.state_bucket_name
  location = var.region
  project  = var.project_id

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Keep at most 30 noncurrent versions. Lifecycle deletes any beyond that.
  lifecycle_rule {
    condition {
      num_newer_versions = 30
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  force_destroy = false

  depends_on = [google_project_service.enabled]
}
