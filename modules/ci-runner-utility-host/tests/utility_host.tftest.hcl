# ci-runner-utility-host — plan-time tests against a MOCK google provider.
# No credentials, no project, no API call: `terraform test` from the module
# directory. Every value below is a stub; nothing here names a real project,
# region or organisation.

mock_provider "google" {}

variables {
  project_id                    = "stub-project"
  region                        = "stub-region1"
  zone                          = "stub-region1-a"
  github_owner                  = "stub-org"
  github_app_id                 = "1"
  github_app_installation_id    = "2"
  github_app_private_key_secret = "stub-app-key"
  service_account_email         = "host@stub-project.iam.gserviceaccount.com"
  image                         = "projects/stub-project/global/images/family/ci-runner-host"
  network                       = "stub-net"
  subnetwork                    = "stub-subnet"
  repos = {
    beta  = { slots = 1 }
    Alpha = { slots = 2, labels = ["extra"] }
  }
}

run "metadata_binds_each_slot_to_its_repo" {
  command = plan

  assert {
    condition     = google_compute_instance_template.host.metadata["ci-utility"] == "true"
    error_message = "ci-utility must be true"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["ci-cache-seed"] == "off"
    error_message = "ci-cache-seed must be off"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["ci-slots"] == "3"
    error_message = "ci-slots must be the sum of every repo's slots"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["ci-slot-repos"] == "Alpha,Alpha,beta"
    error_message = "ci-slot-repos must be one repo per slot, in repository-name order"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["ci-slot-labels"] == "Alpha-util,extra;Alpha-util,extra;beta-util"
    error_message = "ci-slot-labels must be one `;`-separated set per slot, each led by <Repo>-util"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["ci-runner-labels"] == "self-hosted,linux,gcp"
    error_message = "the host-wide labels must be self-hosted,linux,gcp"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["ci-github-repo"] == "Alpha"
    error_message = "ci-github-repo must be the first repository by name"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["ci-interactive-slots"] == "0"
    error_message = "ci-interactive-slots must be 0 with no autoscaler"
  }
  assert {
    condition     = join(",", output.runs_on["beta"]) == "self-hosted,linux,gcp,beta-util"
    error_message = "runs_on must give each repository its <Repo>-util label set"
  }
}

run "no_job_identity_cache_or_band" {
  command = plan

  assert {
    condition = length(setintersection(keys(google_compute_instance_template.host.metadata), [
      "ci-job-service-account", "ci-cache-bucket", "ci-turbo-bucket", "ci-turbo-cache-py", "ci-job-broker-py",
    ])) == 0
    error_message = "the utility host must carry no job identity, cache bucket or turbo bucket key"
  }
  assert {
    # #1638: no turbo key at all, by prefix, so a key added later is caught too
    condition     = length([for k in keys(google_compute_instance_template.host.metadata) : k if startswith(k, "ci-turbo-")]) == 0
    error_message = "the utility host must carry no ci-turbo-* metadata key: the turbo cache serves every slot, so on this host it is cross-repository (#1638)"
  }
  assert {
    # #1639: no pin hold, and the guest attribute it published is off with it
    condition     = !contains(keys(google_compute_instance_template.host.metadata), "enable-guest-attributes")
    error_message = "the utility host runs no pin hold, so it must not enable guest attributes (#1639)"
  }
  assert {
    condition     = length([for t in google_compute_instance_template.host.tags : t if startswith(t, "ci-shared-infra-")]) == 0
    error_message = "the utility host must carry no shared-infra band tag (ADR B3)"
  }
}

run "boot_script_is_the_folded_gzip_wrapper" {
  command = plan

  assert {
    condition     = strcontains(google_compute_instance_template.host.metadata["startup-script"], "base64 -d <<'CI_HOST_STARTUP_GZ_EOF' | gzip -d > /var/lib/ci-host-startup.sh")
    error_message = "startup-script must be the gzip wrapper around the pool's host-startup.sh"
  }
  assert {
    condition     = length([for l in split("\n", google_compute_instance_template.host.metadata["startup-script"]) : l if length(l) > 4096]) == 0
    error_message = "no line of the boot script may exceed 4096 characters"
  }
}

run "one_standard_host_never_spot" {
  command = plan

  assert {
    condition     = google_compute_instance_group_manager.host.target_size == 1
    error_message = "the group must hold exactly one host"
  }
  assert {
    condition     = google_compute_instance_template.host.scheduling[0].provisioning_model == "STANDARD" && google_compute_instance_template.host.scheduling[0].preemptible == false
    error_message = "the host must be standard GCE, never Spot"
  }
  assert {
    condition     = google_compute_instance_template.host.machine_type == "e2-standard-2"
    error_message = "default machine type must be e2-standard-2"
  }
  assert {
    condition     = google_compute_instance_template.host.disk[0].disk_size_gb >= 200
    error_message = "boot disk must be at least 200 GB"
  }
  assert {
    condition     = google_compute_instance_group_manager.host.base_instance_name == "ci-utility"
    error_message = "base instance name must be the module name"
  }
}

# #1650: nothing reaches the host from outside, no project-wide SSH key logs in,
# and the attached account is the one passed in, with the single scope.
run "no_external_ip_no_project_ssh_one_scope" {
  command = plan

  assert {
    condition     = length(google_compute_instance_template.host.network_interface) == 1 && length(google_compute_instance_template.host.network_interface[0].access_config) == 0
    error_message = "the utility host must have one interface and no access_config (no external IP; egress through Cloud NAT)"
  }
  assert {
    condition     = length(google_compute_instance_template.host.network_interface[0].ipv6_access_config) == 0
    error_message = "the utility host must have no external IPv6 access config either"
  }
  assert {
    condition     = google_compute_instance_template.host.metadata["block-project-ssh-keys"] == "true"
    error_message = "block-project-ssh-keys must be \"true\" on the utility host"
  }
  assert {
    condition     = length(google_compute_instance_template.host.service_account) == 1 && google_compute_instance_template.host.service_account[0].email == "host@stub-project.iam.gserviceaccount.com"
    error_message = "the host must attach exactly the service_account_email it was given"
  }
  assert {
    condition     = length(google_compute_instance_template.host.service_account[0].scopes) == 1 && contains(google_compute_instance_template.host.service_account[0].scopes, "https://www.googleapis.com/auth/cloud-platform")
    error_message = "the host account must carry exactly the cloud-platform scope (IAM on the account is the boundary; no extra legacy scopes)"
  }
}

run "refuses_controller_service_account" {
  command = plan
  variables {
    service_account_email = "ci-runner-alpha-ctl@stub-project.iam.gserviceaccount.com"
  }
  expect_failures = [var.service_account_email]
}

run "refuses_default_compute_service_account" {
  command = plan
  variables {
    service_account_email = "123456789-compute@developer.gserviceaccount.com"
  }
  expect_failures = [var.service_account_email]
}

run "accepts_a_ctl_lookalike_only_when_it_does_not_end_the_name" {
  command = plan
  variables {
    service_account_email = "ci-ctl-reader-host@stub-project.iam.gserviceaccount.com"
  }
  assert {
    condition     = google_compute_instance_template.host.service_account[0].email == "ci-ctl-reader-host@stub-project.iam.gserviceaccount.com"
    error_message = "only a name ENDING in -ctl is a controller account"
  }
}

run "refuses_shared_repo_label" {
  command = plan
  variables {
    repos = { alpha = { slots = 1, labels = ["Alpha-Shared"] } }
  }
  expect_failures = [var.repos]
}

run "refuses_shared_runner_label" {
  command = plan
  variables {
    runner_labels = ["linux", "gcp", "alpha-shared"]
  }
  expect_failures = [var.runner_labels]
}

# The lane host: a second instance whose slots answer `<Repo>-lane`.
run "lane_suffix_threads_through_labels_and_runs_on" {
  command = plan
  variables {
    name         = "ci-lane"
    label_suffix = "lane"
  }

  assert {
    condition     = google_compute_instance_template.host.metadata["ci-slot-labels"] == "Alpha-lane,extra;Alpha-lane,extra;beta-lane"
    error_message = "ci-slot-labels must lead each slot with <Repo>-lane on a lane host"
  }
  assert {
    condition     = join(",", output.runs_on["beta"]) == "self-hosted,linux,gcp,beta-lane"
    error_message = "runs_on must give each repository its <Repo>-lane label set on a lane host"
  }
  assert {
    condition     = !strcontains(google_compute_instance_template.host.metadata["ci-slot-labels"], "-util")
    error_message = "a lane host must not answer any <Repo>-util label"
  }
  assert {
    condition     = google_compute_instance_group_manager.host.base_instance_name == "ci-lane"
    error_message = "the lane host keeps its own base name"
  }
}

run "default_suffix_is_util" {
  command = plan

  assert {
    condition     = !strcontains(google_compute_instance_template.host.metadata["ci-slot-labels"], "-lane")
    error_message = "the gatekeeper host must not answer any <Repo>-lane label"
  }
}

run "refuses_unknown_suffix" {
  command = plan
  variables {
    label_suffix = "shared"
  }
  expect_failures = [var.label_suffix]
}

run "refuses_lane_host_on_the_gatekeeper_name" {
  command = plan
  variables {
    label_suffix = "lane"
  }
  expect_failures = [google_compute_instance_template.host]
}

run "refuses_lane_label_on_the_gatekeeper_host" {
  command = plan
  variables {
    repos = { alpha = { slots = 1, labels = ["alpha-lane"] } }
  }
  expect_failures = [var.repos]
}

run "refuses_util_label_on_the_lane_host" {
  command = plan
  variables {
    name         = "ci-lane"
    label_suffix = "lane"
    repos        = { alpha = { slots = 1, labels = ["alpha-util"] } }
  }
  expect_failures = [var.repos]
}

run "refuses_lane_runner_label" {
  command = plan
  variables {
    runner_labels = ["linux", "gcp", "x-lane"]
  }
  expect_failures = [var.runner_labels]
}

run "refuses_small_disk" {
  command = plan
  variables {
    boot_disk_size_gb = 100
  }
  expect_failures = [var.boot_disk_size_gb]
}

run "refuses_empty_repos" {
  command = plan
  variables {
    repos = {}
  }
  expect_failures = [var.repos]
}

run "refuses_owner_qualified_repo" {
  command = plan
  variables {
    repos = { "stub-org/alpha" = { slots = 1 } }
  }
  expect_failures = [var.repos]
}

run "refuses_host_prefixed_repo" {
  command = plan
  variables {
    repos = { "host-alpha" = { slots = 1 } }
  }
  expect_failures = [var.repos]
}

run "refuses_zero_slots" {
  command = plan
  variables {
    repos = { alpha = { slots = 0 } }
  }
  expect_failures = [var.repos]
}

run "refuses_label_with_separator" {
  command = plan
  variables {
    repos = { alpha = { slots = 1, labels = ["a,b"] } }
  }
  expect_failures = [var.repos]
}

run "refuses_reserved_label" {
  command = plan
  variables {
    repos = { alpha = { slots = 1, labels = ["background"] } }
  }
  expect_failures = [var.repos]
}

run "refuses_shared_infra_tag" {
  command = plan
  variables {
    network_tags = ["ci-shared-infra-src-x"]
  }
  expect_failures = [var.network_tags]
}

run "refuses_windows_image" {
  command = plan
  variables {
    image = "projects/stub-project/global/images/family/ci-runner-host-win"
  }
  expect_failures = [var.image]
}

run "refuses_zone_outside_region" {
  command = plan
  variables {
    zone = "other-region1-a"
  }
  expect_failures = [google_compute_instance_template.host]
}
