output "runner_network_tag" {
  value       = var.runner_network_tag
  description = "Network tag the firewall rules target — pass this to the ci-runner-pool module so its VMs are reachable by IAP and health checks."
}

output "image_builder_network_tag" {
  value       = local.image_builder_network_tag
  description = "Network tag tcp:5986 is opened to. Pass it to the Windows image build as _IMAGE_BUILDER_NETWORK_TAG; no runner host may carry it."
}
