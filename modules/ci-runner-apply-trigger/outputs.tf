output "trigger_id" {
  value       = google_cloudbuild_trigger.apply.trigger_id
  description = "The trigger's id. This, not its name, is what the run API takes."
}

output "trigger_name" {
  value       = google_cloudbuild_trigger.apply.name
  description = "Trigger name, for `gcloud builds triggers describe <name> --region=<region>` — the --region is not optional, triggers are regional."
}

output "service_account" {
  value       = var.service_account
  description = "Echoed back so a root's outputs state which identity applies it. The account is an input; this module creates none."
}

output "scheduled_job_name" {
  value       = one(google_cloud_scheduler_job.daily_apply[*].name)
  description = "Name of the scheduler job, or null when apply_schedule is unset — in which case a new module version reaches this repository only when something else pushes to its terraform root."
}
