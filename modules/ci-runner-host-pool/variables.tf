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

  validation {
    # This is the string the cache prefix is built from, and that prefix is
    # interpolated into a CEL expression inside a quoted literal on the read
    # grant. A name carrying a double quote would close that literal and could
    # rewrite the condition into one that matches everything — the isolation
    # between one pool's snapshots and another's rests on this one value. The same
    # name also reaches a URL the host builds at boot, where `?`, `&` and `#`
    # would each mean something. So it is confined to the shape GCP resource names
    # take anyway, which every existing pool already satisfies.
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.name))
    error_message = "name must be 1-63 characters, lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen."
  }

  validation {
    # The pool name is applied to the hosts as a network tag, and
    # `ci-shared-infra-` is the namespace the shared-infra firewall rules are
    # keyed on. A pool named `ci-shared-infra-src-checkout` is therefore an
    # authorized source for pair `checkout` -- and `ci-shared-infra-stack-...`
    # an ingress target -- in a pull request that never asked for it and a
    # repository it may not belong to. Nothing else in the module notices,
    # because the tag is perfectly well-formed; the boundary is the tag string
    # and only reserving the prefix keeps ordinary naming from spelling it.
    condition     = !startswith(var.name, "ci-shared-infra-")
    error_message = "name must not start with \"ci-shared-infra-\" — that prefix is reserved for the tags shared_infra_id mints, and a pool wearing one joins that pair's firewall rules as a source or a target."
  }
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

variable "host_os" {
  description = <<-EOT
    Operating system of the HOSTS in this pool: "linux" or "windows". A pool has
    an OS; the module does not. A consumer that wants both instantiates this
    module twice, each with its own name, MIG, controller and labels — the two
    pools must never answer the same labels, or GitHub hands a Linux job to a
    Windows host.

    In the template this selects exactly one thing: which metadata key carries
    the boot script. `startup-script` on linux, `windows-startup-script-ps1` on
    windows. It is also published as `ci-host-os`, so the host and the
    controller read what they are instead of inferring it.

    Everything else host_os does is a REFUSAL at plan time (main.tf). A Windows
    pool has no container runtime, no metadata fence, no inbound path from the
    controller and no Secret Manager grant on its host account, so several
    inputs that are merely unwise on Linux are meaningless or unsafe here, and
    each is rejected by name rather than accepted and ignored.

    Pair it with `ci-runner-identity`'s `host_os` of the same value: that is
    what strips the host account down to nothing worth stealing, which on
    Windows is the whole security argument (docs/adr-windows-pool.md §3A).
  EOT
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.host_os)
    error_message = "host_os must be \"linux\" or \"windows\"."
  }
}

variable "windows_image_min_version" {
  description = <<-EOT
    Minimum golden-image CONTRACT version a Windows host may boot from,
    published as `ci-image-min-version`. Ignored on linux.

    The Windows Packer template writes an integer to the image; the boot script
    reads it and refuses anything below this floor. It is a different number
    from the image's own version suffix: that one names the artifact, this one
    states which contract the artifact satisfies. Raise it in the same change
    that makes the boot script assume a component — and never before an image
    carrying that number exists, which is how a fleet stops booting.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.windows_image_min_version >= 1 && floor(var.windows_image_min_version) == var.windows_image_min_version
    error_message = "windows_image_min_version must be a whole number of at least 1 — the boot script compares it against an integer marker and refuses anything it cannot parse."
  }
}

variable "image" {
  description = <<-EOT
    Self-link or family reference of the GOLDEN image the hosts boot from. The
    image is expected to already contain the runner agent, the container
    runtime, and the pre-warmed toolchain/dependency caches. Build it with
    packer/ci-host-image.pkr.hcl — or, for `host_os = "windows"`, with
    packer/ci-host-image-win.pkr.hcl, whose family is `ci-runner-host-win` and
    is deliberately never the Linux one: a family points at its newest member,
    so sharing one would let build order hand a pool the wrong kernel. Naming
    the family of the other OS is refused at plan time (main.tf), because the
    guest agent's response to the mispairing is to run no boot script at all.

    The entire point of this module is that a host does not install anything at
    boot. Pointing this at a bare distro image silently reintroduces the
    per-job install cost the pool exists to remove.

    Minimum v3-11-0: from that image on, every slot gets its own rootless Docker
    daemon (README.md, isolation rules). An older image has no
    dockerd-rootless.sh, and a host booting one now fails closed — it refuses to
    register instead of silently returning every slot to a shared daemon.

    Prefer v3-12-0 or later, which is the first image that ships /opt/ci-cache
    at all. That directory is the read-only MASTER dependency cache: the host
    copies it into a private per-slot cache at boot and points each slot's
    package managers there. An older image simply has no master to copy, so its
    jobs download every dependency from upstream — slower, never broken, and not
    fail-closed: v3-11-0 boots, registers and serves jobs.

    Images built before module v5.12.0 ship that tree group-writable, which is
    the design this module has since rejected (a cache several slot users can
    write is a channel for one job to hand another job code to run). A host
    booting one of them re-owns the tree to root and strips its write bits before
    seeding, so an old image is corrected at boot rather than trusted — no image
    rebuild is required to get the fix.
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

    On `host_os = "linux"`, each slot is a separate Linux user with its own
    rootless Docker daemon and its own dependency cache, so concurrent slots
    share no socket, no $HOME, no workspace and nothing writable at all. This
    needs image v3-11-0 or later; on an older image the host refuses to register
    rather than putting every slot back on one daemon.

    On `host_os = "windows"` the first half survives verbatim and the second has
    no analogue: each slot is a separate local Windows account with its own
    profile, workspace and TEMP, and there is NO container runtime at all. A
    reader who carries the Linux sentence across concludes that jobs are
    container-isolated on Windows, and they are not. Two consequences a Windows
    consumer decides on rather than inherits: concurrent slots share one
    loopback and one port space (Windows has no per-slot network namespace), so
    two jobs binding the same fixed port collide and report it as a flaky test;
    and a build slot's memory floor is set by MSBuild, not by a shell. The
    default of 4 is shared and therefore unchanged — the Windows guidance is 2,
    and 1 for a pool whose jobs bind fixed ports, which is where the first
    Windows pool starts.

    Note that the cache is per-slot COPIES of one master, so K slots hold K
    copies of the warmed tree — this variable multiplies the cache's disk cost,
    and `boot_disk_size_gb` has to carry it — there is no quota on the cache, so
    a slot that fills the disk degrades every other slot on the host. See `image`
    and the isolation rules in README.md.
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

    Refused outright on `host_os = "windows"`. Windows adds two reasons to the
    fleet-wide one: a preemption takes K slots with it on a host whose boot is
    measured in minutes, and Windows Server is licensed per vCPU-hour whatever
    the provisioning model, so the saving is smaller than it looks. Removing it
    from the Linux path is a breaking input change for every existing consumer
    and is deliberately a separate change.
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

  # Whole seconds only: the controller does bash integer arithmetic on this
  # value (`deadline=$((now + DEMAND_BUDGET))`), which fails outright on 90.5 —
  # and it fails inside the tick, where the consequence is the silent controller
  # this variable exists to prevent.
  validation {
    condition     = var.demand_budget_seconds >= 10 && floor(var.demand_budget_seconds) == var.demand_budget_seconds
    error_message = "demand_budget_seconds must be a whole number of seconds, at least 10: a smaller budget can expire before the first run's job list returns, so demand would read 0 on every tick and the pool would never scale out, and a fractional value breaks the controller's integer arithmetic."
  }

  # The cross-variable check (against poll_interval_seconds) is NOT here: a
  # variable validation may reference another variable only from Terraform 1.9,
  # and this module supports >= 1.5. It lives as a precondition in main.tf,
  # beside the identity-split check that hit the same boundary.
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

variable "manage_controller" {
  description = "Whether this module creates the pool's controller VM. Set false for every pool served by a shared modules/ci-runner-controller."
  type        = bool
  default     = true

  # DEFAULT TRUE, AND THE DEFAULT IS THE WHOLE COMPATIBILITY STORY. A pool that
  # says nothing keeps the controller it has, keeps its name, keeps its metadata
  # key set, and plans no change — no state move, no VM replaced, nothing to
  # coordinate across fourteen repositories on one afternoon.
  #
  # Set false and this module builds a pool with NO control plane of its own. It
  # is then inert until some controller is told about it: an ONLY_UP autoscaler
  # holds whatever size it last had and nothing ever drains a host, which from
  # every dashboard looks like a quiet pool rather than an abandoned one. The
  # only safe way to set it is together with a modules/ci-runner-controller that
  # carries this pool's descriptor in its `pools` list — which is why the
  # descriptor is an output of this module rather than something a consumer
  # retypes.
}

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

variable "extra_registry_hosts" {
  description = <<-EOT
    Extra container-registry hostnames the job identity authenticates to, e.g.
    an Artifact Registry in another region or project. The host's OWN regional
    Artifact Registry and the Container Registry hosts are always configured, so
    this is empty for the usual case of a repository pulling an image published
    next to its runners. Hostnames only — docker matches these EXACTLY, and a
    pattern like `*.pkg.dev` is silently never consulted, which shows up as a
    job failing its pull rather than as a configuration error.

    Refused outright on `host_os = "windows"`: there is no docker on a Windows
    host and nothing reads the list. Accepting it would be the worst kind of
    no-op — a consumer configures a private registry, Terraform applies clean,
    and the failure arrives later as an unauthenticated pull inside a job.
  EOT
  type        = list(string)
  default     = []
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

variable "controller_mints_registration_token" {
  description = <<-EOT
    Have the CONTROLLER mint each host's runner registration token and deliver
    it as a per-instance metadata key, instead of each host reading the GitHub
    App key from Secret Manager and minting its own.

    REQUIRED for a Windows pool: a Windows host account holds no Secret Manager
    grant (ci-runner-identity's `host_os`), so it cannot mint anything — the safe
    configuration and the working configuration are the same configuration.

    Leave false on Linux. This path necessarily parks a credential in instance
    metadata from the controller's write until its delete, and that window is
    the host's whole boot — minutes, not seconds, and up to the register grace
    for a host that only partly registers. It is bounded, not absent, and it is
    read by anything holding compute.instances.get on the PROJECT, not only by
    that host. A Linux host's metadata fence makes the trade pointless, and the
    host-minted path is proved on a live fleet. The controller reads the App key
    already, for the queue poll, so this moves a call rather than granting a new
    capability.
  EOT
  type        = bool
  default     = false
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

    `host-` is a RESERVED prefix: every agent already registers
    `host-<instance-name>`, and the controller reads a `host-*` entry in a job's
    `runs-on` as an affinity pin to one machine. A pool label sharing that
    prefix would be read as a pin to a host that does not exist.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for l in var.runner_labels : !startswith(l, "host-")])
    error_message = "runner_labels may not start with `host-`: that prefix is reserved for the per-instance affinity label, and a pool label using it would be read as a pin to a host that does not exist."
  }
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

    Pass the tag the project's firewall rules target. On `host_os = "linux"` it
    is not decoration: the controller verifies a host is truly idle over IAP-SSH
    before deleting it, so a host the IAP rule does not reach fails that check,
    the drain aborts, and the pool never scales in — the exact failure this
    module exists to fix.

    That contract is Linux-only. A Windows pool's liveness gate is outbound —
    the host publishes what it knows about itself to guest attributes and the
    controller reads it through the compute API — so a Windows host needs NO
    inbound path from the controller at all: no IAP-SSH rule, no tag, no
    listener. A reader of a Windows pool should not go hunting for a firewall
    rule that must not exist.

    Reserved: no tag here may start with `ci-shared-infra-`. That namespace
    belongs to `shared_infra_id`, and a tag passed in by hand is the other way
    a pool can be enrolled in a pair it does not belong to.
  EOT

  validation {
    # Same boundary as var.name, reached through the other door. A caller
    # naming the tag directly does not even need a plausible pool name.
    condition     = alltrue([for t in var.network_tags : !startswith(t, "ci-shared-infra-")])
    error_message = "network_tags must not contain a tag starting with \"ci-shared-infra-\" — that prefix is minted from shared_infra_id, and passing one by hand puts this pool inside another pair's firewall rules."
  }
}

variable "recycle_max_unavailable" {
  description = <<-EOT
    How many hosts may be MID-RECYCLE at once — cordoned, or being retired —
    when their instance template no longer matches the one the MIG builds.

    Why this exists: `terraform apply` moves the definition of a host, not a
    host. `update_policy` is OPPORTUNISTIC on purpose (PROACTIVE would delete
    hosts to apply a template, and an arbitrary victim here carries up to
    `slots_per_host` running jobs), so a new template is adopted only when
    something deletes the old hosts. Nothing did: the controller retires a host
    for being IDLE past the grace window, and a pool with work never goes idle
    for fifteen minutes. On 2026-08-15 v5.7.0 — the release that stops a job
    inheriting the previous job's cloud credentials — was applied to a pool and
    five hosts kept serving jobs from the previous template afterwards. The
    apply reported success, and it was telling the truth.

    No job is ever interrupted. A stale host is CORDONED — its idle agents are
    deregistered, so it can never receive another job, while GitHub's refusal to
    deregister an agent that is executing one keeps the working slot alive — and
    it is deleted on a later tick, once that job lands.

    Why the default is 0 (OFF): this is the only rule in the module that deletes
    a host for a reason that is not about the host. A controller running against
    an unexpected template — restarted from an old image, or handed a metadata
    key that failed to render — must not start deleting hosts because a field
    was missing. Opt in per pool.

    1 is the value to start with: cordoning removes a host's idle slots from the
    pool immediately, so recycling every stale host at once takes out the
    fleet's whole spare capacity in a single tick and every queued job waits for
    a boot. Raise it only on a pool with headroom.

    Watch `ci_hosts_stale_template`: it climbs to the pool size when a release
    lands and falls back to zero as hosts are replaced. Stuck above zero means a
    pool that keeps being told to upgrade and never does.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.recycle_max_unavailable >= 0
    error_message = "recycle_max_unavailable cannot be negative; 0 disables stale-template recycling."
  }
}

# --- the cache snapshot ---------------------------------------------------------

variable "cache_snapshot_bucket" {
  description = <<-EOT
    Name of the `ci-runner-cache-bucket` this pool hydrates its dependency cache
    from at boot. Empty (the default) turns the whole snapshot layer off: no IAM
    grant is created, no metadata is passed, and hosts run on the cache their
    image baked.

    Setting it grants this pool's HOST service account
    `roles/storage.objectViewer` on that bucket, conditioned on this pool's own
    object prefix. Read only, and never write: a host executes job code, so a
    host that could publish a snapshot would let whatever one job left in a cache
    become the starting cache of every later host in the pool. Publishing belongs
    to a separate identity that never runs pull-request code.
  EOT
  type        = string
  default     = ""

  validation {
    # The other half of the same door `name` closes. This value is interpolated
    # into the read grant's CEL condition inside a quoted literal, so a bucket
    # name carrying a double quote could close that literal and rewrite the
    # expression into one that is unconditionally true — turning a grant scoped to
    # this pool's prefix into bucket-wide `objectViewer` over every pool's
    # snapshots. Validating the pool name and not this one would close one of two
    # identical doors. The shape is GCS's own, which every real bucket satisfies.
    condition     = var.cache_snapshot_bucket == "" || can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.cache_snapshot_bucket))
    error_message = "cache_snapshot_bucket must be a bucket NAME (3-63 characters, lowercase letters, digits, dots, hyphens and underscores), not a gs:// URL, or empty to turn the snapshot layer off."
  }
}

variable "cache_snapshot_max_age_hours" {
  description = <<-EOT
    Refuse a snapshot older than this at boot and start cold instead.

    The second of two bounds on how long a poisoned cache entry can be served.
    The bucket's lifecycle rule is the first; this one exists because the two
    fail differently — the bucket's holds if the host script is broken, this one
    holds if the lifecycle rule is edited away in the console, and lifecycle
    deletion is asynchronous, so on its own the bucket's bound is soft by up to a
    day.

    Keep it at or below the bucket's `snapshot_max_age_days`. Above it the bound
    is the bucket's and this number is decoration.
  EOT
  type        = number
  default     = 168

  validation {
    condition     = var.cache_snapshot_max_age_hours >= 1 && var.cache_snapshot_max_age_hours <= 720
    error_message = "cache_snapshot_max_age_hours must be between 1 and 720 (30 days), the range the bucket's own age bound can be set to."
  }
}

variable "cache_hydrate_budget_seconds" {
  description = <<-EOT
    Total time a booting host may spend fetching, unpacking and inspecting a
    snapshot before it gives up and registers with the cache it already has.

    A missing or slow snapshot costs the FIRST job on this host a cold cache. A
    host that waits on one costs the pool a host, and the pool answers a missing
    host by queueing jobs — so the budget is deliberately small, and every step
    inside it fails open.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.cache_hydrate_budget_seconds >= 10 && var.cache_hydrate_budget_seconds <= 300
    error_message = "cache_hydrate_budget_seconds must be between 10 and 300: below 10 no snapshot of a useful size can arrive, and above 300 a stuck download delays registration by longer than a cold boot would have cost."
  }
}

variable "cache_snapshot_max_bytes" {
  description = <<-EOT
    Refuse a snapshot larger than this.

    The archive, the tree it unpacks into and the tree already in the master all
    sit on the boot disk at once, so this and `boot_disk_size_gb` are one
    decision. Filling the disk to warm a cache costs the host every job it was
    about to run, which is a far worse trade than starting cold.
  EOT
  type        = number
  default     = 4294967296

  validation {
    # An upper bound as well as a lower one, so that the host's own clamp and this
    # validation agree on the range rather than the host quietly being the only
    # real bound. 32 GiB is past any dependency cache and short of any plausible
    # boot disk.
    condition     = var.cache_snapshot_max_bytes >= 1048576 && var.cache_snapshot_max_bytes <= 34359738368
    error_message = "cache_snapshot_max_bytes must be between 1 MiB and 32 GiB; below that no real dependency cache fits, above it no boot disk does."
  }
}

variable "shared_infra_id" {
  description = <<-EOT
    Identifier of the shared-infrastructure PAIR this pool belongs to — one
    value per consuming repository, passed IDENTICALLY to that repository's
    Linux and Windows pool instances.

    It exists because the two pools are separate module instances with separate
    `name` values, so anything derived from a pool's own name gives the paired
    hosts DIFFERENT tags — and the ingress rule below would then reject exactly
    the Windows-to-Linux traffic the shared-infrastructure contract is about
    (docs/adr-pr-host-affinity.md §3.3). The pair has to be named by whoever
    declares the pair, because only they know it is a pair.

    Set, this pool's hosts carry:

      ci-shared-infra-src-<id>    both pools — the ingress SOURCE and the
                                  egress target (which selects the SENDING VM)
      ci-shared-infra-stack-<id>  linux only — the ingress TARGET

    Two tags rather than one, because with a single tag on both pools the
    ingress rule's target_tags would name the Windows hosts too, permitting
    inbound connections to them: the path docs/adr-windows-pool.md exists to
    deny, reintroduced by the rule meant to preserve it. A Windows host carries
    the first tag and not the second, so it may reach a Linux stack and nothing
    may reach it.

    Empty (the default) means this pool takes part in no shared-infrastructure
    pair and carries neither tag. The matching rules live in
    `ci-runner-network`; a tag with no rule does nothing.

    SETTING THIS ON A POOL THAT IS ALREADY RUNNING DOES NOT TAG ITS HOSTS. The
    tags live on the instance template, the MIG's update policy is
    OPPORTUNISTIC, and OPPORTUNISTIC means "next time the instance is replaced
    anyway" — so the apply goes green, the new template is correct, and every
    host currently up keeps the old one. The rules then match nothing, and the
    symptom is not an error: it is a connection that hangs until the job's
    timeout, on a pair the operator has every reason to believe is configured.

    So adopting a pair on a live pool is a two-step change: apply, then recycle.
    Either scale the pool to zero and let it come back (cheapest on a pool that
    scales to zero already, which these do), or let the controller's ordinary
    age-based recycle roll the fleet over and accept that the pair does not work
    until the last pre-change host is gone. There is no third option that leaves
    a running host correct, because a network tag cannot be changed on a VM the
    MIG owns without the MIG replacing it.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.shared_infra_id == "" || can(regex("^[a-z]([-a-z0-9]{0,39}[a-z0-9])?$", var.shared_infra_id))
    error_message = "shared_infra_id must be a valid GCP network-tag component: lowercase letters, digits and dashes, starting with a letter, at most 41 characters. 41 and not 63 because it is concatenated into `ci-shared-infra-stack-<id>`, whose 22-character prefix has to fit inside the 63-character tag limit alongside it — 22 + 41 = 63 exactly, and the shorter `ci-shared-infra-src-` prefix has room to spare. An invalid or over-long one fails the apply at the API rather than at the plan."
  }
}
