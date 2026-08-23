# The GROUP, not the instance. Since #308 the controller is a managed group of
# size 1 and the VM inside it is `<group>-<suffix>`, a name that changes every
# time the group rebuilds it — which is the point. The group is the stable
# handle.
output "controller_instance" {
  description = "Name of the managed group holding the controller VM that serves every pool in the table. The VM itself is <this>-<suffix>; list it with `gcloud compute instance-groups managed list-instances`."
  value       = google_compute_instance_group_manager.controller.name
}

output "controller_zone" {
  description = "Zone of the controller's managed group."
  value       = google_compute_instance_group_manager.controller.zone
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
