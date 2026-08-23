# ci-runner-controller — ONE control plane for a repository's pools.
#
# WHY THIS MODULE EXISTS
#
# A repository needs four pools: Linux CI, Windows CI, and a merge-queue pool
# for each — because Mergify validates a queued pull request by re-running the
# same `pull_request` workflows on a `mergify/merge-queue/<sha>` branch, against
# the same `runs-on` labels, at exactly the moment the CI pools are full of the
# next pull requests. Green CI then waits behind no free runner, which is the
# bottleneck this whole delivery exists to remove.
#
# Four pools with a controller each is four controllers sweeping the SAME
# repository's run list every tick. That is the one thing that does not divide:
# at the default 20s poll it is 720 list calls an hour for one answer, against
# an installation budget all four share, and the fourth copy is what meets the
# secondary rate limit and blinds all four at once.
#
# So this module builds ONE controller and hands it a table. It sweeps GitHub
# once per tick and then ticks each pool against that one answer.
#
# WHAT IT DOES NOT DO. It does not create pools. Each pool is still a
# ci-runner-host-pool with `manage_controller = false`, and the wiring between
# them is that module's `pool_descriptor` output — never a hand-written table.
# The MIG name in a descriptor is GENERATED, and a hand-written one that gets it
# wrong yields a controller listing an empty instance group forever, reporting a
# pool that is perfectly healthy and completely empty.
#
# Tenancy-agnostic — no customer literals, no repository knowledge beyond the
# owner/repo it is given.

locals {
  # THE SAME FILES, IN THE SAME ORDER, AS ci-runner-host-pool's own controller.
  # Two copies of a list is a list that drifts, so it is not left to care:
  # scripts/ci/controller-module.selftest.sh reads both `join` blocks and fails
  # when they stop naming the same scripts. A controller missing one decision
  # rule does not fail to boot — it runs, and silently never drains, never
  # recycles, or never reaps, depending on which file went missing.
  #
  # `../ci-runner-host-pool/scripts/` resolves because a `git::…//modules/x`
  # source clones the WHOLE repository and roots the module inside it, so the
  # sibling is on disk. That is true of every source this repository publishes
  # and NOT true of a registry or archive source, which packs one subdirectory.
  # The self-test asserts the path exists so the failure is a red gate rather
  # than a controller that boots into an empty startup script.
  pool_scripts = "${path.module}/../ci-runner-host-pool/scripts"

  controller_startup = join("\n", [
    "#!/usr/bin/env bash",
    file("${local.pool_scripts}/drain-decision.sh"),
    file("${local.pool_scripts}/orphan-decision.sh"),
    file("${local.pool_scripts}/pinned-job-decision.sh"),
    file("${local.pool_scripts}/recycle-decision.sh"),
    file("${local.pool_scripts}/beacon-decision.sh"),
    # The pin-hold veto, on every controller for the same reason the pool module
    # concatenates it on every pool: the branch that decides whether a machine is
    # deleted must be the branch that was tested. A shared controller that shipped
    # it selectively would delete a held host for one pool and not another.
    file("${local.pool_scripts}/pin-hold-decision.sh"),
    file("${local.pool_scripts}/telemetry.sh"),
    file("${local.pool_scripts}/watchdog-decision.sh"),
    # Before the controller, always: pool_table_parse is called at FILE SCOPE,
    # before the first tick. Concatenated after, the call runs against an
    # undefined function and the controller exits on boot having served nothing.
    file("${local.pool_scripts}/pool-table.sh"),
    file("${local.pool_scripts}/controller-startup.sh"),
  ])

  # `jsonencode` writes an unset optional attribute as JSON `null`, and null is
  # exactly what the parser's `//` defaults are for — `null // 900` is 900,
  # where `"" // 900` would be `""`, because an empty string is truthy in jq.
  # So the omitted columns default correctly WITHOUT this module pruning them,
  # and the defaults stay in one file. The one column that is compared rather
  # than defaulted, `mints_registration_token`, reads null as false, which is
  # the safe direction: a pool that does not ask for token minting does not get
  # it.
  pools_json = jsonencode(var.pools)
}

# Not every region has an "-a" zone, so the zone is read rather than assembled —
# a guessed zone name fails the create with a 403 that reads like a permissions
# problem.
data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}

resource "google_compute_instance" "controller" {
  project      = var.project_id
  name         = var.name
  zone         = length(var.zones) > 0 ? var.zones[0] : data.google_compute_zones.available.names[0]
  machine_type = var.controller_machine_type
  labels       = var.labels
  tags         = concat(["ci-runner-controller"], var.network_tags)

  # A controller stopped by hand, by a maintenance action, or by anything
  # outside Terraform does NOT come back on its own — automatic_restart covers
  # host failures only. Declaring the state means the next apply repairs a
  # stopped control plane instead of reporting no changes while FOUR pools go
  # unpolled and undrained.
  desired_status = "RUNNING"

  boot_disk {
    initialize_params {
      image = var.controller_image
      size  = 20
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork

    dynamic "access_config" {
      for_each = var.assign_external_ip ? [1] : []
      content {}
    }
  }

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  metadata = {
    startup-script = local.controller_startup

    # Per REPOSITORY. Everything per-pool is in the table below.
    "ci-github-owner"          = var.github_owner
    "ci-github-repo"           = var.github_repo
    "ci-app-id"                = var.github_app_id
    "ci-app-installation-id"   = var.github_app_installation_id
    "ci-app-key-secret"        = var.github_app_private_key_secret
    "ci-poll-seconds"          = tostring(var.poll_interval_seconds)
    "ci-demand-budget-seconds" = tostring(var.demand_budget_seconds)
    "ci-metric-prefix"         = var.metric_prefix

    # The table. Present, so the controller does NOT fall back to synthesising a
    # one-row table from the single-pool keys — which is exactly what it would
    # do here, and it would find none of them and serve nothing.
    "ci-pools" = local.pools_json

    "block-project-ssh-keys" = "true"
  }

  allow_stopping_for_update = true
}
