output "trigger_id" {
  value       = google_cloudbuild_trigger.image.trigger_id
  description = "The trigger's id. This, not its name, is what the run API takes — and running it by hand is how you build an image without waiting for a merge."
}

output "trigger_name" {
  value       = google_cloudbuild_trigger.image.name
  description = "Trigger name, for `gcloud builds triggers describe <name> --region=<region>` — the --region is not optional, triggers are regional."
}

output "github_generation" {
  value       = local.gen2 ? "2nd-gen" : "1st-gen"
  description = "Which GitHub link this trigger was built against. Worth surfacing: a trigger built against the generation the project does not use is created successfully and simply never fires, so the generation is not visible in any success signal."
}

output "repository_id" {
  value       = local.repository_id
  description = "The 2nd-gen repository resource the trigger watches, or null on a 1st-gen project. Pass it as github_repository to a second root onboarding the same repository — the second registration of one remote is an ALREADY_EXISTS error."
}

output "image_family" {
  value       = var.image_family
  description = "The family this trigger stamps. Echoed so a root can state which family it feeds — pools pin an exact image NAME, so this is what to list images of when picking the next pin: `gcloud compute images list --filter=family=<this> --project=<project>`."
}
