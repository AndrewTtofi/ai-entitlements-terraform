output "workload_identity_provider" {
  description = "Set as the repository variable GCP_WORKLOAD_IDENTITY_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "service_account" {
  description = "Set as the repository variable GCP_SERVICE_ACCOUNT."
  value       = google_service_account.terraform.email
}
