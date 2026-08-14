output "service_account_email" {
  description = "Pass to ci-runner-host-pool as `service_account_email`."
  value       = google_service_account.runner.email
}

output "controller_service_account_email" {
  description = <<-EOT
    Pass to ci-runner-host-pool as `controller_service_account_email`. This is
    the account holding instance-admin; passing it is what keeps that grant off
    the hosts. Equal to `service_account_email` when the split is disabled.
  EOT
  value       = local.controller_email
}

output "app_key_secret_name" {
  description = "Pass to ci-runner-host-pool as `github_app_private_key_secret`. The value must be added out of band before a host can register."
  value       = google_secret_manager_secret.app_key.secret_id
}

output "job_service_account_email" {
  description = "Pass to ci-runner-host-pool as `job_service_account_email`. Empty when no job identity is created, which means jobs on that pool get no Google credentials."
  value       = var.create_job_service_account ? google_service_account.job[0].email : ""
}
