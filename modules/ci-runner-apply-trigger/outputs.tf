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

output "github_generation" {
  value       = local.gen2 ? "2nd-gen" : "1st-gen"
  description = "Which GitHub link this trigger was built against. Worth surfacing: a trigger built against the generation the project does not use is created successfully and simply never fires, so the generation is not visible in any success signal."
}

output "repository_id" {
  value       = local.repository_id
  description = "The 2nd-gen repository resource the trigger watches, or null on a 1st-gen project. Pass it as github_repository to a second root onboarding the same repository — the second registration of one remote is an ALREADY_EXISTS error."
}

output "scheduled_job_name" {
  value       = one(google_cloud_scheduler_job.daily_apply[*].name)
  description = "Name of the scheduler job, or null when apply_schedule is unset — in which case a new module version reaches this repository only when something else pushes to its terraform root."
}
