variable "project_id" {
  description = "GCP project ID."
  type        = string
  default     = "cpe-slarbi-nvd-ant-demos"
}

variable "region" {
  description = "Primary GCP region."
  type        = string
  default     = "us-central1"
}

# ---------------------------------------------------------------------------
# Phase 1 — Infra slice
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "GKE Autopilot cluster name."
  type        = string
  default     = "cc-sandbox"
}

variable "snapshots_bucket_name" {
  description = "GCS bucket for per-user workspace snapshots (park/restore)."
  type        = string
  default     = "cpe-slarbi-nvd-ant-demos-cc-a2a-snapshots"
}

variable "firestore_database_name" {
  description = "Firestore database name. NAMED database (not '(default)') so it does not conflict with the project's pre-existing default DB."
  type        = string
  default     = "cc-on-ge"
}

variable "artifact_registry_repo" {
  description = "Artifact Registry Docker repo holding cc-bridge and cc-backend images."
  type        = string
  default     = "cc-on-ge"
}

variable "bridge_sa_account_id" {
  description = "Account ID (local part) for the Cloud Run cc-a2a-bridge service account."
  type        = string
  default     = "cc-a2a-bridge"
}

variable "backend_sa_account_id" {
  description = "Account ID (local part) for the GKE cc-a2a-backend service account."
  type        = string
  default     = "cc-a2a-backend"
}

variable "gke_release_channel" {
  description = "GKE release channel. Locked to RAPID for Agent Sandbox availability."
  type        = string
  default     = "RAPID"
}

variable "gke_min_version" {
  description = "Minimum GKE control-plane version. Must include Agent Sandbox addon support (>= 1.35.2-gke.1269000)."
  type        = string
  default     = "1.35.2-gke.1269000"
}

variable "sandbox_namespace" {
  description = "Kubernetes namespace that holds sandbox workloads."
  type        = string
  default     = "cc-sandbox"
}

variable "sandbox_ksa_name" {
  description = "Kubernetes ServiceAccount in the sandbox namespace, bound to the backend GSA via Workload Identity."
  type        = string
  default     = "cc-sandbox-sa"
}
