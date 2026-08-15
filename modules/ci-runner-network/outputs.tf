output "runner_network_tag" {
  value       = var.runner_network_tag
  description = "Network tag the firewall rules target — pass this to the ci-runner-pool module so its VMs are reachable by IAP and health checks."
}
