output "runner_network_tag" {
  value       = var.runner_network_tag
  description = "Network tag the firewall rules target — pass this to the ci-runner-pool module so the egress and health-check rules apply to its VMs (and IAP-SSH, only when iap_ssh_to_runner_hosts)."
}

output "image_builder_network_tag" {
  value       = local.image_builder_network_tag
  description = "Network tag the image-build VM carries; tcp:22 and tcp:5986 from IAP are opened to it. Pass it to every image build, Linux and Windows, as _IMAGE_BUILDER_NETWORK_TAG (ci-host-image-trigger's image_builder_network_tag). No runner host may carry it."
}
