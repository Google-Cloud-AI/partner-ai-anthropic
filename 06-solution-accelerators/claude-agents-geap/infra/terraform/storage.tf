# ============================================================================
# Snapshots bucket — per-user workspace park/restore
# ----------------------------------------------------------------------------
# Bridge SA gets bucket-wide objectAdmin (see iam.tf). Backend SA has
# DELIBERATELY ZERO IAM here — pods receive a downscoped STS token scoped
# to users/<user_key>/ at request time. See downscoped-tokens skill.
# ============================================================================

resource "google_storage_bucket" "snapshots" {
  name     = var.snapshots_bucket_name
  location = var.region
  project  = var.project_id

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Park-on-every-turn churns versions. Prune noncurrent versions aggressively;
  # 10 is enough rollback for any sane debugging window.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  force_destroy = false
}
