output "service_account_email" {
  description = "The warmer's account. It is the only identity in this fleet allowed to write cache content, and it must never be attached to a host."
  value       = google_service_account.warmer.email
}

output "scheduler_service_account_email" {
  description = "The account that fires the trigger. It runs no code; it exists so the account that DOES run code is not the one holding a project-wide right to start builds."
  value       = local.scheduler_email
}

output "trigger_id" {
  description = "Cloud Build trigger id, for an operator running a warm by hand before the first schedule fires."
  value       = google_cloudbuild_trigger.warm.trigger_id
}

output "turbo_prefix" {
  description = "Object prefix the build artifacts are published under. The same value ci-runner-host-pool grants its hosts read on — compare them if a pool reports a cache that never hits."
  value       = local.turbo_prefix
}

output "cache_prefix" {
  description = "Object prefix the dependency snapshot is published under."
  value       = local.cache_prefix
}
