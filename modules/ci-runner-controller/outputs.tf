output "controller_instance" {
  description = "Name of the always-on controller VM serving every pool in the table."
  value       = google_compute_instance.controller.name
}

output "controller_zone" {
  description = "Zone of the controller VM."
  value       = google_compute_instance.controller.zone
}

output "pools_served" {
  description = "Names of the pools this controller ticks, in table order. Compare against ci_pool_table_rejected: a pool listed here and rejected on the VM is being served by nobody."
  value       = [for p in var.pools : p.name]
}

# The rendered table, so an operator can diff what the VM was told against what
# the pools actually are without reading instance metadata off a live machine.
# Metric names are NOT re-exported here — they belong to ci-runner-host-pool's
# `metric_names`, which the metric contract gate holds to the publisher.
output "pool_table_json" {
  description = "The exact `ci-pools` metadata value this controller carries."
  value       = local.pools_json
}
