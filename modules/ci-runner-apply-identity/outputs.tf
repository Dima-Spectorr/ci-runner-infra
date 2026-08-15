output "service_account_email" {
  value       = google_service_account.apply.email
  description = "Pass to apply-runner-pool.yml as `service_account`."
}

output "principal_set" {
  value       = google_service_account_iam_member.workload_identity.member
  description = "The exact principalSet permitted to assume this identity. Output so the binding is visible in a plan and in `terraform output`, rather than only inside a module a reviewer has to open."
}
