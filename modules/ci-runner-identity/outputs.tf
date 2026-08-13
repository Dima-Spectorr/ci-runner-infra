output "service_account_email" {
  description = "Pass to ci-runner-host-pool as `service_account_email`."
  value       = google_service_account.runner.email
}

output "app_key_secret_name" {
  description = "Pass to ci-runner-host-pool as `github_app_private_key_secret`. The value must be added out of band before a host can register."
  value       = google_secret_manager_secret.app_key.secret_id
}
