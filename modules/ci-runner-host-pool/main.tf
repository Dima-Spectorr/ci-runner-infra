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

  # ONE expression for this pool's slice of the shared cache bucket, read by both
  # the IAM condition below and the host that fetches from it. Written twice they
  # would eventually disagree, and the failure is quiet in the worst way: every
  # request would land outside the pool's own grant and come back 403, which the
  # host logs as a snapshot that has not been published yet.
  cache_prefix = "cache/${var.name}/"

  # Controller and hosts are different identities: the controller may delete
  # instances, a host executes build input. There is no fallback — the fallback
  # that used to be here silently chose the weak side of that split for every
  # consumer, so the variable is now required and validated instead.
  controller_sa = var.controller_service_account_email

  # The host script is self-contained — a host makes no drain decisions, it
  # only serves jobs and answers questions about itself.
  host_startup = file("${path.module}/scripts/host-startup.sh")

  # The controller carries its decision rules and the telemetry publisher inline
  # so a running controller never depends on fetching code at runtime. They are
  # separate files in the repo precisely so they can be unit-tested; embedding
  # them here is what puts the TESTED text on the box.
  controller_startup = join("\n", [
    "#!/usr/bin/env bash",
    file("${path.module}/scripts/drain-decision.sh"),
    file("${path.module}/scripts/orphan-decision.sh"),
    file("${path.module}/scripts/recycle-decision.sh"),
    file("${path.module}/scripts/telemetry.sh"),
    file("${path.module}/scripts/watchdog-decision.sh"),
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

# --- the cache snapshot this pool may read ---------------------------------------

# READ, and only inside this pool's own prefix.
#
# `roles/storage.objectViewer` and deliberately not `objectUser` or `objectAdmin`:
# the grant holds no `storage.objects.create` and no `storage.objects.delete`. A
# host executes job code. A host that could publish a snapshot would let whatever
# one job left in a cache become the starting cache of every later host in this
# pool — one job handing code to every future job — which is the cross-slot
# channel the per-slot cache copy closes, re-opened across hosts and across time.
# Publishing belongs to an identity that never runs pull-request code.
#
# The condition is what keeps eight pools in one bucket from being one pool. It
# also, by construction, denies `storage.objects.list`: listing is authorized
# against the BUCKET, whose resource name does not start with an object prefix.
# That is intended — the host fetches a pointer at a known name and then the
# object that pointer names, and a host that cannot enumerate the bucket cannot
# discover another pool's snapshots even if the condition were ever loosened by
# accident.
resource "google_storage_bucket_iam_member" "host_reads_cache" {
  count = var.cache_snapshot_bucket == "" ? 0 : 1

  bucket = var.cache_snapshot_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.service_account_email}"

  condition {
    title       = "only-this-pools-cache-prefix"
    description = "Reads are confined to ${local.cache_prefix}, so one pool's hosts cannot read another pool's cache snapshots out of the shared bucket."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.cache_snapshot_bucket}/objects/${local.cache_prefix}\")"
  }
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

    # The dependency-cache snapshot. Empty bucket = the layer is off, and the
    # host says so in its log rather than failing; every one of these is read
    # with a fallback on the host, so a host booting from an older template
    # simply behaves as it did before the keys existed.
    "ci-cache-bucket"         = var.cache_snapshot_bucket
    "ci-cache-prefix"         = var.cache_snapshot_bucket == "" ? "" : local.cache_prefix
    "ci-cache-max-age-hours"  = tostring(var.cache_snapshot_max_age_hours)
    "ci-cache-budget-seconds" = tostring(var.cache_hydrate_budget_seconds)
    "ci-cache-max-bytes"      = tostring(var.cache_snapshot_max_bytes)

    # Registry hosts a job container may be pulled from as the JOB identity, on
    # TOP of this host's own region and the Container Registry hosts, which the
    # host always configures. Needed only when a repository pulls its builder
    # image from another region or another project.
    "ci-registry-hosts" = join(",", var.extra_registry_hosts)

    # Hosts are cattle managed by the controller; interactive login is not the
    # supported way to inspect one. Logs go to Cloud Logging.
    "block-project-ssh-keys" = "true"
  }

  lifecycle {
    create_before_destroy = true

    # The three identities must be three DIFFERENT accounts. Each variable's own
    # `validation` block can only see itself (cross-variable validation needs
    # Terraform 1.9 and this module supports >= 1.5), so a consumer could pass
    # controller == job and satisfy both checks: each only compares against the
    # host account. That configuration hands workflow code the controller's
    # roles/compute.instanceAdmin.v1 — the exact escalation the split exists to
    # prevent — so the pairing is rejected here, at plan time.
    precondition {
      condition = (
        var.job_service_account_email == "" ||
        var.job_service_account_email != var.controller_service_account_email
      )
      error_message = "job_service_account_email must differ from controller_service_account_email — the controller holds roles/compute.instanceAdmin.v1, and job code receives the job identity through the loopback broker, so sharing them lets a pull request delete the fleet."
    }

    # A demand sweep that can outlast the watchdog window is the silent-controller
    # failure of 2026-08-14: the watchdog restarts the controller mid-tick, the
    # restart prevents the heartbeat that would have stopped the restarting, and
    # nothing is published at all. Blocked at plan time.
    #
    # Here rather than in the variable's own `validation` block because that
    # could not read poll_interval_seconds before Terraform 1.9 and this module
    # supports >= 1.5 — the same boundary the identity check above sits on.
    precondition {
      condition     = var.demand_budget_seconds <= max(300, var.poll_interval_seconds * 10) - 120
      error_message = "demand_budget_seconds must leave at least 120s of the watchdog threshold (max(300, poll_interval_seconds * 10)) for the rest of the tick — otherwise the watchdog restarts the controller mid-tick, the restart prevents the heartbeat, and it never publishes again."
    }
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

# Not every region has an "-a" zone (some start at "-b"), so the
# controller's zone is read from the region rather than assembled by hand — a
# guessed zone name fails the create with a 403 that reads like a permissions
# problem.
data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}

resource "google_compute_instance" "controller" {
  project      = var.project_id
  name         = "${var.name}-controller"
  zone         = length(var.zones) > 0 ? var.zones[0] : data.google_compute_zones.available.names[0]
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
    "ci-pool"                = var.name
    # The same key the hosts read. Demand is counted by GitHub's superset rule
    # against THIS list, so a controller without it matches no job at all,
    # reports zero demand forever, and the pool never leaves zero hosts.
    "ci-runner-labels"           = local.runner_labels
    "ci-mig-name"                = google_compute_region_instance_group_manager.hosts.name
    "ci-region"                  = var.region
    "ci-slots"                   = tostring(var.slots_per_host)
    "ci-min-hosts"               = tostring(var.min_hosts)
    "ci-max-hosts"               = tostring(var.max_hosts)
    "ci-drain-grace-seconds"     = tostring(var.drain_grace_seconds)
    "ci-register-grace-seconds"  = tostring(var.register_grace_seconds)
    "ci-orphan-confirm-ticks"    = tostring(var.orphan_confirm_ticks)
    "ci-recycle-max-unavailable" = tostring(var.recycle_max_unavailable)
    "ci-poll-seconds"            = tostring(var.poll_interval_seconds)
    "ci-demand-budget-seconds"   = tostring(var.demand_budget_seconds)
    "ci-metric-prefix"           = var.metric_prefix

    "block-project-ssh-keys" = "true"
  }

  allow_stopping_for_update = true
}
