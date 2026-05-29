variable "project_id" {
  description = "GCP project ID. Locked to cpe-slarbi-nvd-ant-demos for v1."
  type        = string
  default     = "cpe-slarbi-nvd-ant-demos"
}

variable "region" {
  description = "Primary GCP region. Locked to us-central1 for v1."
  type        = string
  default     = "us-central1"
}

variable "state_bucket_name" {
  description = "Terraform state bucket name. Consumed by the main root's gcs backend."
  type        = string
  default     = "cpe-slarbi-nvd-ant-demos-tfstate"
}

variable "builder_sa_account_id" {
  description = "Account ID (local part) for the Cloud Build service account."
  type        = string
  default     = "cc-a2a-builder"
}
