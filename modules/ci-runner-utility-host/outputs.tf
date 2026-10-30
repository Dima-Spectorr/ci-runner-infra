output "mig_name" {
  description = "Name of the zonal managed instance group holding the utility host."
  value       = google_compute_instance_group_manager.host.name
}

output "mig_self_link" {
  description = "Self-link of the zonal managed instance group."
  value       = google_compute_instance_group_manager.host.self_link
}

output "instance_group" {
  description = "Instance group self-link, for attaching external monitoring."
  value       = google_compute_instance_group_manager.host.instance_group
}

output "zone" {
  description = "Zone of the group. List the host with `gcloud compute instance-groups managed list-instances <mig_name> --zone=<zone> --project=<project>`."
  value       = google_compute_instance_group_manager.host.zone
}

output "instance_template" {
  description = "Self-link of the host template currently in the group's version."
  value       = google_compute_instance_template.host.self_link
}

output "base_instance_name" {
  description = "Base name of the host and its agents (`<base>-<4 chars>`, `<host>-s<N>`). Must not equal any pool's base name in the same project."
  value       = google_compute_instance_group_manager.host.base_instance_name
}

output "slot_repos" {
  description = "Repository each slot serves, slot 1 first — the value published as `ci-slot-repos`."
  value       = local.slot_repos
}

output "runs_on" {
  description = "Per repository, the `runs-on` label list a workflow uses to send a job to this host."
  value       = { for r in local.repo_names : r => distinct(concat(["self-hosted"], var.runner_labels, ["${r}-util"])) }
}
