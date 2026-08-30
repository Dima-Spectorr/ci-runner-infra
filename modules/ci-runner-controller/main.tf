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

  controller_startup_source = join("\n", [
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
    # The merge-queue parking rule — repository-wide, and the only rule here
    # that is. A shared controller serving four pools sweeps one repository, so
    # it asks this question once and publishes the answer under every pool.
    file("${local.pool_scripts}/parked-decision.sh"),
    file("${local.pool_scripts}/telemetry.sh"),
    file("${local.pool_scripts}/watchdog-decision.sh"),
    # Before the controller, always: pool_table_parse is called at FILE SCOPE,
    # before the first tick. Concatenated after, the call runs against an
    # undefined function and the controller exits on boot having served nothing.
    file("${local.pool_scripts}/pool-table.sh"),
    file("${local.pool_scripts}/controller-startup.sh"),
  ])

  # AND IT TRAVELS COMPRESSED, exactly as the pool module's copy does and for
  # the identical reason: fourteen files concatenated render past the 256 KiB
  # cap on a GCE metadata value, `terraform plan` does not check the length, and
  # the apply then dies with an Error 413 at create time. This module is not yet
  # in service anywhere, so it has never hit it — which is precisely why it gets
  # the wrapper now rather than after its first deployment discovers it.
  #
  # The unpack path is outside anything the controller manages, because bash
  # reads a script incrementally as it runs; `set -euo pipefail` makes a
  # truncated blob a loud boot failure rather than a controller running a prefix
  # of its own decision rules.
  # AND IT IS FOLDED, FOR THE REASON `ci-runner-host-pool` RECORDS AT LENGTH.
  #
  # `base64gzip` returns ONE line. GCE accepts a metadata value whose longest
  # line runs to six figures — the template is created, the plan and the apply
  # are green — and then every `instances.insert` from that template hangs about
  # two minutes and fails with an unexplained `Internal error`. See #434 and the
  # measurement in `ci-runner-host-pool`'s `b64_fold_columns`.
  #
  # This module shipped without the fold, and the margin it was living on is
  # the point. The two templates that bracketed the limit in August were 130,244
  # characters (created fine) and 142,189 (every create failed); this module
  # renders 127,328. That is under three thousand characters of headroom — ONE
  # more decision-rule script in the concatenation — and neither `plan` nor
  # `apply` reads a line length, so the first thing that would say so is a
  # controller MIG stuck at `creating` and every pool it serves at zero hosts.
  #
  # The v5.85.0 apply on 2026-08-30 did hit an `Internal error` inserting the
  # controller from the unfolded template. It retried and came up, so that one
  # was the transient kind and NOT this failure; what it showed is how little is
  # left between the two. The pool module reached the same conclusion about its
  # own 130,244 and folded rather than trimmed.
  b64_fold_columns = 76

  controller_startup_gz = join("\n", regexall(".{1,${local.b64_fold_columns}}", base64gzip(local.controller_startup_source)))

  controller_startup = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    base64 -d <<'CI_CONTROLLER_STARTUP_GZ_EOF' | gzip -d > /var/lib/ci-controller-startup.sh
    ${local.controller_startup_gz}
    CI_CONTROLLER_STARTUP_GZ_EOF
    chmod 0700 /var/lib/ci-controller-startup.sh
    exec /var/lib/ci-controller-startup.sh
  EOT

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

# THE CONTROLLER IS NO LONGER A PET (#308). Same change as the pool module's,
# and it matters more here: this one serves FOUR pools, so a controller that is
# deleted and stays deleted freezes four autoscalers at once. It used to be a
# bare instance with `desired_status = "RUNNING"`, which repairs one somebody
# STOPPED, on the next apply, and does nothing at all for one somebody DELETED.
#
# A missing controller does not produce an outage signal; it produces the
# absence of every signal, because every capacity fact the fleet has comes out
# of its tick.
#
# THE FIRST APPLY REPLACES THE CONTROLLER — there is no in-place path from a
# standalone instance to a managed one. Expect a destroy and a create, and a
# couple of minutes with no control plane. Nothing is lost: hosts keep running
# their jobs, and every tick recomputes from live GitHub and MIG state. The
# instance name gains the group's suffix: `<name>-a1b2`.
#
# Autohealing is a separate, off-by-default flag; the reasoning is in the pool
# module beside the health check, and it is the same reasoning here.
resource "google_compute_instance_template" "controller" {
  project      = var.project_id
  name_prefix  = "${var.name}-"
  region       = var.region
  machine_type = var.controller_machine_type
  labels       = var.labels
  tags         = concat(["ci-runner-controller"], var.network_tags)

  disk {
    source_image = var.controller_image
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
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
    # How much of that budget's work fits in it. This module sweeps once for the
    # WHOLE repository rather than once per pool, so it has the most runs to get
    # through and the least budget to do it in.
    "ci-demand-fetch-concurrency" = tostring(var.demand_fetch_concurrency)
    "ci-metric-prefix"            = var.metric_prefix
    # The queue's branch, so the parking sweep can tell a pull request that will
    # never be admitted from one that is simply waiting its turn.
    "ci-queue-base" = var.queue_base_branch

    # The table. Present, so the controller does NOT fall back to synthesising a
    # one-row table from the single-pool keys — which is exactly what it would
    # do here, and it would find none of them and serve nothing.
    "ci-pools" = local.pools_json

    # Empty unless autohealing is on, so the default path opens no port on the
    # one machine in the fleet that holds the App installation token.
    "ci-health-port" = var.controller_autohealing ? tostring(var.controller_health_port) : ""

    "block-project-ssh-keys" = "true"
  }

  lifecycle {
    create_before_destroy = true

    # The same gate the pool module's controller carries. Stated here too rather
    # than inherited, because this module renders its own metadata and a shared
    # controller that cannot be created is FOUR pools that never leave zero.
    precondition {
      condition     = length(local.controller_startup) < 262144
      error_message = "controller '${var.name}' renders a ${length(local.controller_startup)}-character boot script and a GCE metadata value is capped at 262144. The script is already gzipped into its wrapper, so the SOURCE has outgrown even the compressed form: shorten the decision-rule scripts under modules/ci-runner-host-pool/scripts/, or move part of the controller onto the golden image. Left to the apply this is an Error 413 at create time, on a plan that read clean."
    }

    # And the LINE-length gate, which the size gate above cannot stand in for:
    # the value that took three controller MIGs down in August was 142 KiB,
    # comfortably inside the 256 KiB cap this precondition checks. The size gate
    # was copied here when this module was written and the line gate was not,
    # which is how the module came to render an unfolded blob and pass its own
    # plan.
    precondition {
      condition     = length([for line in split("\n", local.controller_startup) : line if length(line) > 4096]) == 0
      error_message = "controller '${var.name}' renders a boot script containing a line of more than 4096 characters. The template is created and the apply is green; every instance built FROM it then hangs about two minutes and fails with an unexplained `Internal error` (measured 2026-08-26, and again on 2026-08-30 when this module rendered the blob unfolded), which is a controller MIG stuck at `creating` and every pool it serves sitting at zero hosts. Fold the base64 blob: join(\"\\n\", regexall(\".{1,76}\", base64gzip(...)))."
    }
  }
}

# Off by default. The full argument lives once, in ci-runner-host-pool/main.tf
# beside its copy of this resource: a probe that cannot reach the controller
# reads a healthy machine as dead and loops delete/rebuild/delete, which is
# worse than a pet, and the in-guest watchdog already restarts a wedged tick
# loop without deleting anything.
resource "google_compute_health_check" "controller" {
  count = var.controller_autohealing ? 1 : 0

  project = var.project_id
  name    = "${var.name}-live"

  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  # HTTP, not TCP: a TCP check passes for a controller whose tick loop has
  # stopped, which is the state worth catching.
  http_health_check {
    port         = var.controller_health_port
    request_path = "/livez"
  }
}

resource "google_compute_instance_group_manager" "controller" {
  project = var.project_id
  name    = var.name
  zone    = length(var.zones) > 0 ? var.zones[0] : data.google_compute_zones.available.names[0]

  base_instance_name = var.name
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.controller.id
  }

  # `max_surge_fixed = 0` is the invariant: two controllers serving one
  # repository both count demand, both resize four MIGs and both drain hosts,
  # each against a GitHub view the other is already acting on. One at a time,
  # with a gap, is correct. PROACTIVE because an OPPORTUNISTIC controller would
  # sit on the old startup script indefinitely.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    replacement_method    = "SUBSTITUTE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
  }

  dynamic "auto_healing_policies" {
    for_each = var.controller_autohealing ? [1] : []
    content {
      health_check      = google_compute_health_check.controller[0].id
      initial_delay_sec = 600
    }
  }
}
