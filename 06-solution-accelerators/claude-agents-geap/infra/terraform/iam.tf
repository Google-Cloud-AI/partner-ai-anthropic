# ============================================================================
# Service accounts and IAM bindings
# ----------------------------------------------------------------------------
# Two GSAs:
#   - cc-a2a-bridge   (Cloud Run): brokers A2A traffic; mints STS tokens.
#   - cc-a2a-backend  (GKE pod):   runs ADK + Claude Code; Vertex + Firestore.
#
# CRITICAL — the backend SA has ZERO bucket IAM. The whole storage-isolation
# model depends on this: each turn the bridge mints a short-lived STS token
# downscoped (CEL CAB) to `users/<user_key>/`, and that token is the only
# credential the pod ever sees. Granting backend any storage.* role here
# would collapse the isolation. See downscoped-tokens skill.
# ============================================================================

# ---------------------------------------------------------------------------
# Bridge SA — Cloud Run
# ---------------------------------------------------------------------------

resource "google_service_account" "bridge" {
  account_id   = var.bridge_sa_account_id
  display_name = "cc-a2a-bridge (Cloud Run)"
  description  = "A2A adapter; mints downscoped STS tokens; brokers backend traffic."
  project      = var.project_id
}

# Bucket-wide objectAdmin so the bridge can read/write any user prefix when
# minting downscoped tokens (the downscoping is what enforces the per-user
# boundary; the bridge's source credential is broad).
resource "google_storage_bucket_iam_member" "bridge_snapshots_admin" {
  bucket = google_storage_bucket.snapshots.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.bridge.email}"
}

# Required to mint short-lived tokens via the STS API.
resource "google_project_iam_member" "bridge_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.bridge.email}"
}

# Read/write SandboxClaim CRDs (and other in-cluster resources) via the
# Kubernetes API. RBAC inside the cluster is wired separately (Phase 5).
# TODO (pre-external-demo): tighten to a custom role limited to CRDs.
resource "google_project_iam_member" "bridge_container_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.bridge.email}"
}

# ---------------------------------------------------------------------------
# Backend SA — GKE per-user pod
# ---------------------------------------------------------------------------

resource "google_service_account" "backend" {
  account_id   = var.backend_sa_account_id
  display_name = "cc-a2a-backend (GKE per-user pod)"
  description  = "Sandbox pod identity. Vertex + Firestore only; NO direct GCS access."
  project      = var.project_id
}

# Vertex AI calls (claude-opus-4-7 inference for ADK + claude-agent-sdk).
resource "google_project_iam_member" "backend_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

# Firestore (sessions, memory) — `datastore.user` is the Firestore-compat role.
resource "google_project_iam_member" "backend_datastore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

# Workload Identity binding: KSA cc-sandbox/cc-sandbox-sa impersonates the
# backend GSA. The KSA itself is created in Phase 2's k8s.tf — the binding
# is forward-declared and inert until then.
resource "google_service_account_iam_member" "backend_wi_binding" {
  service_account_id = google_service_account.backend.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.sandbox_namespace}/${var.sandbox_ksa_name}]"
}

# DELIBERATE NO-GRANT: backend SA has NO binding on
# google_storage_bucket.snapshots. This is the entire point of the
# downscoped-token model. Do not add a bucket binding here for the backend
# SA without rereading downscoped-tokens skill and re-doing the threat model.
