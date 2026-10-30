# ci-runner-utility-host — ONE always-on host whose slots serve SEVERAL
# repositories, one repository per slot, for short gatekeeper jobs that would
# otherwise bill a GitHub-hosted minute each (docs/adr-utility-host.md, #1635).
#
# What it is NOT, each on purpose:
#   - no autoscaler and no controller: a zonal group of exactly one host;
#   - no Spot: standard provisioning, live-migrated on host maintenance;
#   - no job service account, no cache bucket, no turbo bucket, no shared port
#     band: none of those keys is in the metadata, and the host reads an absent
#     key as "off";
#   - no IAM binding: the host account is passed in and only attached.

locals {
  # The boot script is ci-runner-host-pool's, read from the sibling module rather
  # than copied: ONE host-startup.sh serves pools and this host, and the utility
  # behaviour is switched on by `ci-utility=true` (host-startup.sh, #1642). The
  # sibling path resolves for every source this repository publishes — a
  # `git::…//modules/x` source clones the whole repository — exactly as it does
  # for modules/ci-runner-controller.
  pool_scripts = "${path.module}/../ci-runner-host-pool/scripts"

  # The same two files in the same order as the pool's own host template:
  # host-startup.sh calls the telemetry publisher concatenated above it.
  host_startup_source = join("\n", [
    "#!/usr/bin/env bash",
    file("${local.pool_scripts}/telemetry.sh"),
    file("${local.pool_scripts}/host-startup.sh"),
  ])

  # Gzipped, base64'd and FOLDED to 76 columns, for the two reasons the pool
  # module documents at length: the plain text is over GCE's 256 KiB metadata
  # value cap (an Error 413 at create time), and a single enormous base64 line is
  # accepted by the template insert and then fails every instance insert with an
  # unexplained `Internal error` (#434). Same wrapper as the pool, byte for byte.
  b64_fold_columns = 76
  host_startup_gz  = join("\n", regexall(".{1,${local.b64_fold_columns}}", base64gzip(local.host_startup_source)))

  host_startup = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    base64 -d <<'CI_HOST_STARTUP_GZ_EOF' | gzip -d > /var/lib/ci-host-startup.sh
    ${local.host_startup_gz}
    CI_HOST_STARTUP_GZ_EOF
    chmod 0700 /var/lib/ci-host-startup.sh
    exec /var/lib/ci-host-startup.sh
  EOT

  # One entry per slot, in repository-name order (`keys` is sorted). Slot <n>
  # serves slot_repos[n-1] and adds slot_label_sets[n-1] to the host's labels.
  repo_names = sort(keys(var.repos))

  slot_repos = flatten([
    for r in local.repo_names : [for i in range(var.repos[r].slots) : r]
  ])

  slot_label_sets = flatten([
    for r in local.repo_names : [
      for i in range(var.repos[r].slots) : join(",", distinct(concat(["${r}-util"], var.repos[r].labels)))
    ]
  ])

  total_slots = length(local.slot_repos)

  # `ci-github-repo` is still required by host-startup.sh. On a utility host it
  # serves no slot (each slot mints in its own ci-slot-repos entry); it is the
  # host's nominal repository: the `repo` label on its telemetry and the
  # repository the pin-hold sweep asks about (#1639). The first by name, so it
  # does not move when an unrelated repository is added.
  nominal_repo = local.repo_names[0]

  # Host-wide labels, joined into `ci-runner-labels`. `self-hosted` first, as on
  # every pool; the per-slot `<Repo>-util` comes from ci-slot-labels, and the
  # host itself appends `host-<instance>` and `background`.
  runner_labels = join(",", distinct(concat(["self-hosted"], var.runner_labels)))

  host_network_tags = distinct(concat(["ci-runner-host", var.name], var.network_tags))

  common_labels = merge(var.labels, {
    component = "ci-runner-utility-host"
    pool      = var.name
  })
}

# --- host template ------------------------------------------------------------

resource "google_compute_instance_template" "host" {
  project     = var.project_id
  name_prefix = "${var.name}-host-"
  region      = var.region

  machine_type = var.machine_type
  labels       = local.common_labels
  tags         = local.host_network_tags

  disk {
    source_image = var.image
    auto_delete  = true
    boot         = true
    disk_size_gb = var.boot_disk_size_gb
    disk_type    = var.boot_disk_type
  }

  # No access_config: egress through Cloud NAT, nothing inbound.
  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
  }

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # Never Spot. A preemption takes every repository's gatekeepers at once, and
  # the fleet's runners are standard GCE by policy. Live-migrated on host
  # maintenance, restarted if GCE stops it.
  scheduling {
    provisioning_model  = "STANDARD"
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  metadata = {
    "startup-script" = local.host_startup

    # The pin hold publishes to guest attributes, as on every Linux pool host.
    "enable-guest-attributes" = "TRUE"
    "ci-host-os"              = "linux"

    "ci-github-owner"        = var.github_owner
    "ci-github-repo"         = local.nominal_repo
    "ci-app-id"              = var.github_app_id
    "ci-app-installation-id" = var.github_app_installation_id
    "ci-app-key-secret"      = var.github_app_private_key_secret
    "ci-runner-labels"       = local.runner_labels
    "ci-runner-group"        = var.runner_group
    "ci-slots"               = tostring(local.total_slots)
    "ci-pool"                = var.name
    "ci-metric-prefix"       = var.metric_prefix

    # No slot is reserved for pull-request work: with no autoscaler there is no
    # headroom to give that job, so every slot also answers `background`.
    "ci-interactive-slots" = "0"

    # Declared empty so the key exists from boot; read by the slot loop's gate.
    # Nothing sets it on this host (no controller), but a human cordon can.
    "ci-cordon" = ""

    # THE UTILITY KEYS (host-startup.sh, #1635/#1642). `ci-utility=true` is what
    # turns on the per-slot repository binding and the co-tenancy hardening
    # (B1 hidepid=2 and no container/service jobs, B2 inter-slot DROP, B3 no
    # band, B4 rebind wipe). The host refuses to boot on a slot count that does
    # not match either list.
    "ci-utility"     = "true"
    "ci-slot-repos"  = join(",", local.slot_repos)
    "ci-slot-labels" = join(";", local.slot_label_sets)
    # The image's dependency caches are built from ONE pool repository's
    # lockfiles; seeding them here would hand that tree to every other slot.
    "ci-cache-seed" = "off"

    "block-project-ssh-keys" = "true"
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = startswith(var.zone, "${var.region}-")
      error_message = "zone '${var.zone}' is not a zone of region '${var.region}' — the template is regional and the group zonal, and they must agree."
    }

    # The two plan-time guards the pool carries on the same script, for the same
    # failures: a 413 at create time, and an instance insert that dies two
    # minutes in with an `Internal error` naming nothing.
    precondition {
      condition     = length(local.host_startup) < 262144
      error_message = "the utility host renders a ${length(local.host_startup)}-character boot script and a GCE metadata value is capped at 262144. Shorten modules/ci-runner-host-pool/scripts/host-startup.sh or move part of it onto the golden image."
    }

    precondition {
      condition     = length([for line in split("\n", local.host_startup) : line if length(line) > 4096]) == 0
      error_message = "the utility host's boot script contains a line of more than 4096 characters; every instance created from the template would fail with an unexplained `Internal error`. Fold the base64 blob."
    }

    precondition {
      condition     = length(local.host_network_tags) <= 64
      error_message = "the utility host would carry ${length(local.host_network_tags)} distinct network tags and GCP allows 64; drop entries from var.network_tags."
    }
  }
}

# --- the group ----------------------------------------------------------------

resource "google_compute_instance_group_manager" "host" {
  project = var.project_id
  zone    = var.zone
  name    = "${var.name}-hosts"

  # The host is `<name>-<4 chars>`; its agents `<host>-s<N>`; its affinity label
  # `host-<host>`. A pool controller owns exactly `<its base>-<4 chars>`, so a
  # distinct `name` is what keeps every controller's hands off this host.
  base_instance_name = var.name

  version {
    instance_template = google_compute_instance_template.host.id
  }

  # Exactly one, always on. No autoscaler owns the size, so Terraform does.
  target_size = 1

  # No auto_healing_policies and no health check, as on the pools: "healthy"
  # for a runner host is "its agents are registered", which an HTTP probe cannot
  # see, and a probe that guessed wrong would recreate a busy host. The group
  # still REPAIRS a host that stops or is deleted, which is the replacement the
  # ADR relies on.
  update_policy {
    type                  = var.update_policy_type
    minimal_action        = "REPLACE"
    replacement_method    = "SUBSTITUTE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }
}
