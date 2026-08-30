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
  description = <<-EOT
    Pass to ci-runner-host-pool as `github_app_private_key_secret`.

    When this module creates the secret (`create_app_key_secret`, the default)
    it is created EMPTY, and the PEM must be added out of band with
    `gcloud secrets versions add` before a host can register. With the flag
    false the name refers to a secret another root owns, which already has its
    version — there is nothing to add, and adding one would be a second key on
    a secret a live pool is reading.
  EOT
  value       = local.app_key_secret_id
}

output "job_service_account_email" {
  description = "Pass to ci-runner-host-pool as `job_service_account_email`. Empty when no job identity is created, which means jobs on that pool get no Google credentials."
  value       = var.create_job_service_account ? google_service_account.job[0].email : ""
}
