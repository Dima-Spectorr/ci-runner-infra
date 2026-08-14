# ci-runner-host-pool — inputs.
#
# Every value here is a variable on purpose: this module is consumed by many
# repositories in more than one organisation, region and cloud project. No
# customer, repository, region or project literal may appear in this module.

variable "project_id" {
  description = "GCP project that owns the pool (hosts, controller, MIG, autoscaler)."
  type        = string
}

variable "region" {
  description = "Region for the regional MIG and the controller VM."
  type        = string
}

variable "zones" {
  description = "Zones the regional MIG may place hosts in. Empty = all zones in the region."
  type        = list(string)
  default     = []
}

variable "name" {
  description = <<-EOT
    Pool name. Used as the resource name prefix and as the `pool` label on every
    published metric. Must be unique within the project.
  EOT
  type        = string
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository this pool serves."
  type        = string
}

variable "github_repo" {
  description = <<-EOT
    Repository this pool serves. ONE repo per pool — see the isolation rules in
    README.md. A warm host is reused across jobs, so a pool shared by two
    repositories would let one repository's build observe the other's caches,
    credentials and workspace remnants.
  EOT
  type        = string
}

# --- the host -----------------------------------------------------------------

variable "image" {
  description = <<-EOT
    Self-link or family reference of the GOLDEN image the hosts boot from. The
    image is expected to already contain the runner agent, the container
    runtime, and the pre-warmed toolchain/dependency caches. Build it with
    packer/ci-host-image.pkr.hcl.

    The entire point of this module is that a host does not install anything at
    boot. Pointing this at a bare distro image silently reintroduces the
    per-job install cost the pool exists to remove.

    Minimum v3-11-0: from that image on, every slot gets its own rootless Docker
    daemon (README.md, isolation rules). An older image has no
    dockerd-rootless.sh, and a host booting one now fails closed — it refuses to
    register instead of silently returning every slot to a shared daemon.

    Prefer v3-12-0 or later. v3-11-0 warms /opt/ci-cache as root under umask
    022, so the slots can read the warmed tree and none of them can update it —
    a package manager refreshing a partially warmed cache fails, and it fails
    looking like a flaky upstream repository rather than like a bad image. This
    is not fail-closed: v3-11-0 boots, registers and serves jobs.
  EOT
  type        = string
}

variable "machine_type" {
  description = "Host machine type. Sized to carry `slots_per_host` concurrent jobs."
  type        = string
  default     = "n2-standard-16"
}

variable "slots_per_host" {
  description = <<-EOT
    Concurrent job slots per host — the number of runner agents each host
    registers. Also the autoscaler's `single_instance_assignment`, so demand of
    N jobs asks for ceil(N / slots_per_host) hosts.

    Each slot is a separate Linux user with its own rootless Docker daemon, so
    concurrent slots share no socket, no $HOME and no workspace — only the
    read-mostly cache at /opt/ci-cache. This needs image v3-11-0 or later; on an
    older image the host refuses to register rather than putting every slot back
    on one daemon. The cache is only WRITABLE by the slots from v3-12-0 on —
    see `image`. See the isolation rules in README.md.
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.slots_per_host >= 1
    error_message = "slots_per_host must be at least 1."
  }
}

variable "boot_disk_size_gb" {
  description = "Host boot disk size. Must hold the baked caches plus job workspaces."
  type        = number
  default     = 200
}

variable "boot_disk_type" {
  description = "Host boot disk type. pd-balanced is the floor; pd-ssd if I/O-bound."
  type        = string
  default     = "pd-balanced"
}

variable "spot" {
  description = <<-EOT
    Run hosts as Spot VMs (60-70% cheaper, preemptible at any moment).

    Only safe for pools whose jobs are NOT merge-blocking: a preemption kills
    every job on the host at once, and with K slots the blast radius is K jobs,
    not one. Leave false for the pool that gates merges.
  EOT
  type        = bool
  default     = false
}

# --- scaling ------------------------------------------------------------------

variable "min_hosts" {
  description = <<-EOT
    Floor of RUNNING hosts. 0 = scale to zero when idle.

    Above 0 this is a WARM FLOOR: it buys "the next push finds a hot host" at
    the price of that many hosts billed around the clock. Prefer 0 plus
    `warm_schedules` for pools with a predictable working day.
  EOT
  type        = number
  default     = 0
}

variable "max_hosts" {
  description = "Ceiling of hosts. max_hosts * slots_per_host is the pool's real job concurrency."
  type        = number
  default     = 4
}

variable "drain_grace_seconds" {
  description = <<-EOT
    How long a host may sit with zero busy slots before the controller drains
    it. THIS is the pool's drain latency and its warm window at the same time:
    it should comfortably exceed the gap between a push and its review round so
    the host survives to serve the next run without a boot.
  EOT
  type        = number
  default     = 900
}

variable "register_grace_seconds" {
  description = <<-EOT
    How long a host may show ZERO registered agents before the controller reads
    that as a failed boot rather than a boot in progress. A booting host is
    indistinguishable from a dead one by registration alone, and draining on
    that read is a churn loop that never reaches usable capacity — and kills
    jobs outright when the agents come up between the verdict and the delete.
    Must stay above the worst-case time from instance creation to the last
    agent registering (token fetch + config.sh per slot).
  EOT
  type        = number
  default     = 600
}

variable "orphan_confirm_ticks" {
  description = <<-EOT
    How many CONSECUTIVE ticks a GitHub runner registration must be offline
    with no instance behind it before the controller deletes it. Registrations
    are left behind by every host death that does not go through the
    controller's own drain — an operator `delete-instances`, a MIG recreate,
    host maintenance — and they consume the repo's runner list, which is the
    controller's own view of the pool.

    The floor exists because a failed `list-instances` returns an EMPTY host
    list, indistinguishable from a pool at zero. Requiring N ticks means one
    bad API call cannot deregister a live fleet. Raise it if this project's
    compute API is flaky; do not set it to 0.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.orphan_confirm_ticks >= 1
    error_message = "orphan_confirm_ticks must be at least 1: a single failed list-instances call would otherwise deregister every live agent in the pool."
  }
}

variable "demand_budget_seconds" {
  description = <<-EOT
    Seconds the controller may spend counting demand in one tick. Demand costs
    one GitHub API call per active workflow run, so its cost is set by how busy
    the repository is, not by anything this module controls — one pool in this
    fleet measured a 212s tick against a 300s watchdog threshold on 2026-08-14.

    A tick that outruns the watchdog is fatal rather than slow: the watchdog
    restarts the controller, the restart kills the tick before it writes the
    heartbeat, and the controller is restarted forever without publishing a
    single metric. Keep this well under `poll_interval_seconds * 10` (the
    watchdog threshold, floor 300s) with room for the rest of the tick.

    Queued runs are counted first, so what an exhausted budget drops is
    in-progress work — demand becomes a lower bound, never a wrong scale-out
    signal. `ci_demand_runs_skipped` reports when that happens.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.demand_budget_seconds >= 10
    error_message = "demand_budget_seconds must be at least 10: a smaller budget can expire before the first run's job list returns, so demand would read 0 on every tick and the pool would never scale out."
  }

  # The failure mode this variable exists to prevent, blocked at plan time
  # instead of discovered as a controller that publishes nothing.
  validation {
    condition     = var.demand_budget_seconds <= max(300, var.poll_interval_seconds * 10) - 120
    error_message = "demand_budget_seconds must leave at least 120s of the watchdog threshold (max(300, poll_interval_seconds * 10)) for the rest of the tick — otherwise the watchdog restarts the controller mid-tick, the restart prevents the heartbeat, and it never publishes again."
  }
}

variable "warm_schedules" {
  description = <<-EOT
    Optional autoscaler scaling schedules — a warm floor that applies only
    during declared windows (e.g. working hours) instead of around the clock.
    Outside every window the pool falls back to `min_hosts`.
  EOT
  type = map(object({
    min_required_replicas = number
    schedule              = string # cron, in `time_zone`
    duration_sec          = number
    time_zone             = optional(string, "UTC")
    description           = optional(string)
    disabled              = optional(bool, false)
  }))
  default = {}
}

variable "cooldown_period_sec" {
  description = "Autoscaler cooldown. A warm host needs no boot warm-up, so this is short."
  type        = number
  default     = 60
}

# --- controller ---------------------------------------------------------------

variable "controller_machine_type" {
  description = <<-EOT
    Always-on controller VM. It polls GitHub outbound (no inbound webhook is
    permitted), publishes the demand metric the autoscaler reads, publishes the
    telemetry series, and owns every host deletion.
  EOT
  type        = string
  default     = "e2-micro"
}

variable "controller_image" {
  description = "Boot image for the controller VM. A small, current LTS image is sufficient."
  type        = string
  default     = "projects/debian-cloud/global/images/family/debian-12"
}

variable "poll_interval_seconds" {
  description = <<-EOT
    Controller poll period. This is the pool's reaction time to a queued job,
    so it is the dominant term in queue wait once hosts are warm. Below ~15s
    the GitHub API rate limit becomes the binding constraint.
  EOT
  type        = number
  default     = 20
}

# --- auth ---------------------------------------------------------------------

variable "github_app_id" {
  description = "GitHub App id used to mint installation tokens for runner registration."
  type        = string
}

variable "github_app_installation_id" {
  description = "Installation id of that App on `github_owner`."
  type        = string
}

variable "github_app_private_key_secret" {
  description = <<-EOT
    Secret Manager secret NAME (not the value) holding the GitHub App private
    key. The controller and the hosts read it at runtime via their service
    account; no key material is ever placed in metadata, in Terraform state, or
    in the image.
  EOT
  type        = string
}

variable "service_account_email" {
  description = <<-EOT
    Service account for the HOSTS. Scope it to the minimum: read the App key
    secret (registration), write custom metrics and logs, and mint tokens for
    `job_service_account_email`. It must NOT be able to delete instances —
    deletion is the controller's job, and a host runs build input.
  EOT
  type        = string
}

variable "controller_service_account_email" {
  description = <<-EOT
    Service account for the CONTROLLER. REQUIRED, and it must differ from
    `service_account_email`.

    This used to default to empty, meaning "reuse the host account", described
    as acceptable-but-discouraged. Every consumer took the default, so the
    instance-admin grant the controller needs in order to delete hosts sat on
    the account attached to every host VM — machines whose purpose is to run
    pull-request code. The permissive default WAS the deployed configuration in
    every pool in the fleet; no consumer ever opted out of it. So it is not a default
    any more: a root that does not answer the question fails at plan time rather
    than silently choosing the weak side of it.

    `ci-runner-identity` emits the right value as
    `controller_service_account_email`.
  EOT
  type        = string

  validation {
    condition     = var.controller_service_account_email != "" && var.controller_service_account_email != var.service_account_email
    error_message = "controller_service_account_email is required and must differ from service_account_email — sharing one account puts roles/compute.instanceAdmin.v1 on hosts that execute build input. Pass module.<identity>.controller_service_account_email."
  }
}

variable "job_service_account_email" {
  description = <<-EOT
    Identity that JOB code gets, via the loopback credential broker on each host
    (scripts/job-metadata-broker.py). Job code is fenced off the real metadata
    server, so this — and only this — is what a workflow's `gcloud` sees.

    Empty = jobs get no Google credentials at all. Correct for a repository
    whose CI never touches GCP; wrong for one that deploys, where it turns every
    deploy step into an auth failure.

    NEVER set this to `service_account_email`: that hands build input the host
    identity and undoes the fence.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.job_service_account_email == "" || var.job_service_account_email != var.service_account_email
    error_message = "job_service_account_email must differ from service_account_email — otherwise job code holds the host identity, which can read the GitHub App key."
  }
}

variable "job_broker_port" {
  description = "Loopback port the job credential broker listens on."
  type        = number
  default     = 8081
}

variable "manage_job_token_creator_binding" {
  description = <<-EOT
    Let this module grant the host account `roles/iam.serviceAccountTokenCreator`
    on `job_service_account_email`. Set false when that grant is owned elsewhere
    (a central IAM module); the broker cannot mint job tokens without it.
  EOT
  type        = bool
  default     = true
}

# --- network ------------------------------------------------------------------

variable "network" {
  description = "VPC self-link or name for hosts and controller."
  type        = string
}

variable "subnetwork" {
  description = "Subnetwork self-link or name in `region`."
  type        = string
}

variable "assign_external_ip" {
  description = <<-EOT
    Give hosts a public IP. Leave false and route egress through Cloud NAT —
    hosts need outbound access to GitHub and registries, never inbound.
  EOT
  type        = bool
  default     = false
}

# --- runner registration ------------------------------------------------------

variable "runner_labels" {
  description = <<-EOT
    Extra labels each agent registers with, on top of the always-applied
    `self-hosted` and the pool name. Workflows select the pool through these.
  EOT
  type        = list(string)
  default     = []
}

variable "runner_group" {
  description = "GitHub runner group to register into. Empty = the repository default."
  type        = string
  default     = ""
}

# --- telemetry ----------------------------------------------------------------

variable "metric_prefix" {
  description = <<-EOT
    Custom-metric prefix. Every series this pool publishes is
    `<metric_prefix>/<name>` on a `generic_node` resource labelled with the repo
    and the pool, so one dashboard covers the whole fleet.
  EOT
  type        = string
  default     = "custom.googleapis.com/github"
}

variable "labels" {
  description = "Extra resource labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "network_tags" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Extra network tags for BOTH the hosts and the controller, on top of the
    tags this module always applies ("ci-runner-host" / "ci-runner-controller"
    and the pool name).

    Pass the tag the project's firewall rules target. It is not decoration: the
    controller verifies a host is truly idle over IAP-SSH before deleting it, so
    a host the IAP rule does not reach fails that check, the drain aborts, and
    the pool never scales in — the exact failure this module exists to fix.
  EOT
}
