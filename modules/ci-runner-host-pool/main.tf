# ci-runner-host-pool — warm container hosts for GitHub Actions self-hosted CI.
#
# WHAT CHANGED FROM THE POOL THIS REPLACES
#
# The predecessor (`ci-runner-pool`, vendored into ~9 repositories) booted ONE
# VM PER JOB. Every job therefore paid, before its first line of work ran:
#   boot + guest agent + runner download/config   ~60-120s
#   toolchain install                             ~1-5 min
#   dependency/cache download                     ~1-4 min
# That cost was paid again for the next job, because the VM deleted itself
# after one job. It is the single largest term in this fleet's CI wall time,
# and it is pure waste — the same work, repeated per job, forever.
#
# Here a host boots ONCE from a golden image that already contains the runner
# agent, the container runtime, the toolchains and pre-warmed caches. It
# registers `slots_per_host` PERSISTENT agents and serves job after job. Jobs
# execute in containers, so they get a clean root filesystem per job while the
# host keeps the expensive state. A warm host starts a job in seconds.
#
# WHAT THAT COSTS, AND HOW IT IS PAID FOR
#
# Persistent agents cannot use the predecessor's scale-down mechanism (a VM
# that deletes itself after its one job), and a host carrying K jobs must never
# be an autoscaler's arbitrary victim — the blast radius is K jobs, not one.
# So:
#   * the autoscaler is ONLY_UP: it may add hosts, it may never choose one to
#     remove;
#   * the CONTROLLER owns every deletion, via drain-decision.sh plus a
#     deregister -> verify -> delete sequence;
#   * scale-to-zero survives, because a fully drained pool is a pool the
#     controller emptied deliberately.
#
# Tenancy-agnostic: no customer, repository, region or project literal below.

locals {
  # `pool` and `repo` label every metric this pool publishes, so a single fleet
  # dashboard can group by either without per-repo dashboard code.
  repo_full = "${var.github_owner}/${var.github_repo}"

  common_labels = merge(var.labels, {
    component = "ci-runner-host-pool"
    pool      = var.name
  })

  # `self-hosted` is what workflows match on today across the fleet; the pool
  # name is what lets a repository address THIS pool specifically.
  runner_labels = join(",", concat(["self-hosted", var.name], var.runner_labels))

  # Controller and hosts SHOULD be different identities: the controller may
  # delete instances, a host executes build input. Falling back keeps existing
  # single-identity pools valid instead of failing their next apply.
  controller_sa = var.controller_service_account_email != "" ? var.controller_service_account_email : var.service_account_email

  # The host script is self-contained — a host makes no drain decisions, it
  # only serves jobs and answers questions about itself.
  host_startup = file("${path.module}/scripts/host-startup.sh")

  # The controller carries the decision rule and the telemetry publisher inline
  # so a running controller never depends on fetching code at runtime. Both are
  # separate files in the repo precisely so they can be unit-tested; embedding
  # them here is what puts the TESTED text on the box.
  controller_startup = join("\n", [
    "#!/usr/bin/env bash",
    file("${path.module}/scripts/drain-decision.sh"),
    file("${path.module}/scripts/telemetry.sh"),
    file("${path.module}/scripts/controller-startup.sh"),
  ])
}

# --- job identity ---------------------------------------------------------------

# The host mints job tokens by impersonation, which needs exactly this grant and
# nothing wider. Without it the broker starts, the host refuses to register, and
# the pool stays empty rather than quietly serving jobs with no credentials.
resource "google_service_account_iam_member" "job_token_creator" {
  count = var.job_service_account_email != "" && var.manage_job_token_creator_binding ? 1 : 0

  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.job_service_account_email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.service_account_email}"
}

# --- host template ------------------------------------------------------------

resource "google_compute_instance_template" "host" {
  project     = var.project_id
  name_prefix = "${var.name}-host-"
  region      = var.region

  machine_type = var.machine_type
  labels       = local.common_labels
  tags         = concat(["ci-runner-host", var.name], var.network_tags)

  disk {
    source_image = var.image
    auto_delete  = true
    boot         = true
    disk_size_gb = var.boot_disk_size_gb
    disk_type    = var.boot_disk_type
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork

    # Present only when explicitly asked for. The default path is Cloud NAT:
    # a host needs outbound reach to GitHub and registries and nothing inbound.
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
    # Spot is opt-in per pool: preemption kills every slot on the host at once.
    provisioning_model = var.spot ? "SPOT" : "STANDARD"
    preemptible        = var.spot
    automatic_restart  = !var.spot

    # A host must never silently come back from under the controller after the
    # controller decided to remove it.
    on_host_maintenance = var.spot ? "TERMINATE" : "MIGRATE"

    # On preemption, DELETE rather than STOP: a stopped Spot host holds its
    # registrations and its disk while serving nothing. The controller reaps
    # terminal-state hosts anyway (drain rule 1), but deleting is immediate.
    instance_termination_action = var.spot ? "DELETE" : null
  }

  metadata = {
    startup-script = local.host_startup

    # Everything the host needs to know about itself arrives as metadata, so
    # ONE image serves every pool in every repository and every project. There
    # is no per-repo image and no per-repo build flag.
    "ci-github-owner"        = var.github_owner
    "ci-github-repo"         = var.github_repo
    "ci-app-id"              = var.github_app_id
    "ci-app-installation-id" = var.github_app_installation_id
    "ci-app-key-secret"      = var.github_app_private_key_secret
    "ci-runner-labels"       = local.runner_labels
    "ci-runner-group"        = var.runner_group
    "ci-slots"               = tostring(var.slots_per_host)
    "ci-pool"                = var.name
    "ci-metric-prefix"       = var.metric_prefix

    # Job credentials. The broker source travels as metadata rather than being
    # baked into the image, so ONE image keeps serving every pool while the
    # broker stays reviewable and versioned with the module.
    "ci-job-service-account" = var.job_service_account_email
    "ci-job-broker-port"     = tostring(var.job_broker_port)
    "ci-job-broker-py"       = file("${path.module}/scripts/job-metadata-broker.py")

    # Hosts are cattle managed by the controller; interactive login is not the
    # supported way to inspect one. Logs go to Cloud Logging.
    "block-project-ssh-keys" = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- the pool -----------------------------------------------------------------

resource "google_compute_region_instance_group_manager" "hosts" {
  project = var.project_id
  region  = var.region
  name    = "${var.name}-hosts"

  base_instance_name        = var.name
  distribution_policy_zones = length(var.zones) > 0 ? var.zones : null

  version {
    instance_template = google_compute_instance_template.host.id
  }

  # The autoscaler owns the size. Terraform must not fight it: a `target_size`
  # here would reset the pool on every apply, mid-job.
  lifecycle {
    ignore_changes = [target_size]
  }

  update_policy {
    # OPPORTUNISTIC, not PROACTIVE: a rolling update on PROACTIVE would delete
    # hosts to apply a new template, which is exactly the arbitrary mid-job
    # deletion this design exists to prevent. New template = new hosts only as
    # the controller drains old ones.
    type                  = "OPPORTUNISTIC"
    minimal_action        = "REPLACE"
    replacement_method    = "SUBSTITUTE"
    max_surge_fixed       = length(var.zones) > 0 ? length(var.zones) : 3
    max_unavailable_fixed = 0
  }

  # No health check: "healthy" for a CI host means "its agents are registered
  # and it is not stuck", which only the controller can evaluate against
  # GitHub. An HTTP health check here would authorise the MIG to recreate a
  # busy host.
}

resource "google_compute_region_autoscaler" "hosts" {
  project = var.project_id
  region  = var.region
  name    = "${var.name}-autoscaler"
  target  = google_compute_region_instance_group_manager.hosts.id

  autoscaling_policy {
    min_replicas    = var.min_hosts
    max_replicas    = var.max_hosts
    cooldown_period = var.cooldown_period_sec

    # ONLY_UP is deliberate and is NOT the mistake that pinned an earlier pool
    # at max_runners.
    #
    # That earlier failure (one VM per job) had ONLY_UP with NOTHING on the VM
    # side able to remove an idle VM, so the target ratcheted to max and stayed
    # there. Here the controller removes hosts continuously and the MIG target
    # follows, so the ratchet has a counterparty.
    #
    # The alternative — mode = ON with scale_in_control — is right for
    # one-VM-per-job and wrong here: scale-in picks an arbitrary victim, and an
    # arbitrary victim now carries up to `slots_per_host` running jobs.
    mode = "ONLY_UP"

    metric {
      name = "${var.metric_prefix}/ci_demand"
      # No `type`: it maps to utilizationTargetType, which the API rejects
      # outright alongside single_instance_assignment ("can't be set when
      # single_instance_assignment is used") — the autoscaler create fails and
      # the pool is left with a MIG and no scaling policy.
      filter = "resource.type = \"generic_node\" AND metric.labels.repo = \"${local.repo_full}\" AND metric.labels.pool = \"${var.name}\""

      # Demand is counted in JOBS; a host serves `slots_per_host` of them.
      single_instance_assignment = var.slots_per_host
    }

    dynamic "scaling_schedules" {
      for_each = var.warm_schedules
      content {
        name                  = scaling_schedules.key
        min_required_replicas = scaling_schedules.value.min_required_replicas
        schedule              = scaling_schedules.value.schedule
        duration_sec          = scaling_schedules.value.duration_sec
        time_zone             = scaling_schedules.value.time_zone
        description           = scaling_schedules.value.description
        disabled              = scaling_schedules.value.disabled
      }
    }
  }
}

# --- controller ---------------------------------------------------------------

resource "google_compute_instance" "controller" {
  project      = var.project_id
  name         = "${var.name}-controller"
  zone         = length(var.zones) > 0 ? var.zones[0] : "${var.region}-a"
  machine_type = var.controller_machine_type
  labels       = local.common_labels
  tags         = concat(["ci-runner-controller", var.name], var.network_tags)

  # A controller stopped by hand, by a maintenance action or by anything outside
  # Terraform does NOT come back on its own — automatic_restart only covers host
  # failures. Declaring the desired lifecycle state means the next apply repairs
  # a stopped control plane instead of reporting no changes while nothing polls
  # demand and nothing ever drains a host (SOAP-To-REST #1994, carried up from
  # the copy that fix landed in).
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
    email  = local.controller_sa
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # The controller is the pool's only always-on cost and its only source of
  # truth. It must survive a maintenance event without a human.
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  metadata = {
    startup-script = local.controller_startup

    "ci-github-owner"        = var.github_owner
    "ci-github-repo"         = var.github_repo
    "ci-app-id"              = var.github_app_id
    "ci-app-installation-id" = var.github_app_installation_id
    "ci-app-key-secret"      = var.github_app_private_key_secret
    "ci-pool" = var.name
    # The same key the hosts read. Demand is counted by GitHub's superset rule
    # against THIS list, so a controller without it matches no job at all,
    # reports zero demand forever, and the pool never leaves zero hosts.
    "ci-runner-labels" = local.runner_labels
    "ci-mig-name"      = google_compute_region_instance_group_manager.hosts.name
    "ci-region"              = var.region
    "ci-slots"               = tostring(var.slots_per_host)
    "ci-min-hosts"           = tostring(var.min_hosts)
    "ci-max-hosts"           = tostring(var.max_hosts)
    "ci-drain-grace-seconds" = tostring(var.drain_grace_seconds)
    "ci-poll-seconds"        = tostring(var.poll_interval_seconds)
    "ci-metric-prefix"       = var.metric_prefix

    "block-project-ssh-keys" = "true"
  }

  allow_stopping_for_update = true
}
