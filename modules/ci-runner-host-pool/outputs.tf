output "mig_name" {
  description = "Name of the regional MIG holding the hosts."
  value       = google_compute_region_instance_group_manager.hosts.name
}

output "mig_self_link" {
  description = "Self-link of the regional MIG."
  value       = google_compute_region_instance_group_manager.hosts.self_link
}

output "instance_group" {
  description = "Instance group self-link, for attaching external monitoring."
  value       = google_compute_region_instance_group_manager.hosts.instance_group
}

output "autoscaler_name" {
  description = "Name of the autoscaler. Verify with the compute REST API — the installed gcloud has no `compute autoscalers` subcommand."
  value       = google_compute_region_autoscaler.hosts.name
}

output "controller_instance" {
  description = "Name of the always-on controller VM (poller, drainer, metric publisher)."
  value       = google_compute_instance.controller.name
}

output "controller_zone" {
  description = "Zone of the controller VM."
  value       = google_compute_instance.controller.zone
}

output "runner_labels" {
  description = "Exact label set the agents register with. Workflows must match a subset of this."
  value       = local.runner_labels
}

output "job_concurrency" {
  description = "Maximum concurrent jobs this pool can serve: max_hosts * slots_per_host."
  value       = var.max_hosts * var.slots_per_host
}

output "metric_names" {
  description = "Fully-qualified custom metrics this pool publishes, for dashboards and alert policies."
  value = {
    for m in [
      "ci_demand",
      "ci_demand_queued",
      "ci_hosts_running",
      "ci_hosts_max",
      "ci_hosts_draining",
      "ci_slots_total",
      "ci_slots_busy",
      "ci_host_idle_seconds_max",
      "ci_queue_wait_seconds_max",
      "ci_job_startup_seconds",
      "ci_mig_target_size",
      "ci_drain_verdicts",
      "ci_poller_heartbeat",
    ] : m => "${var.metric_prefix}/${m}"
  }
}
