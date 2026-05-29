output "state_bucket_name" {
  description = "Name of the Terraform state bucket. Use as the main root's gcs backend bucket."
  value       = google_storage_bucket.tfstate.name
}

output "builder_sa_email" {
  description = "Email of the Cloud Build service account."
  value       = google_service_account.builder.email
}

output "enabled_services" {
  description = "Project services enabled by bootstrap."
  value       = sort([for s in google_project_service.enabled : s.service])
}
