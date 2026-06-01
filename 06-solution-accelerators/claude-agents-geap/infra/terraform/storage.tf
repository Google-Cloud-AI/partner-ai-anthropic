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
