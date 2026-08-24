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
  # Shared-infrastructure band tags. See var.shared_infra_id: the first is
  # carried by BOTH pools of a pair and is the ingress source, the second is
  # carried by the Linux pool ONLY and is the ingress target. The Windows host
  # therefore matches no ingress rule anywhere, which is the property
  # docs/adr-windows-pool.md is protecting. The controller carries neither: it
  # publishes no stack and consumes none.
  shared_infra_tags = var.shared_infra_id == "" ? [] : concat(
    ["ci-shared-infra-src-${var.shared_infra_id}"],
    var.host_os == "linux" ? ["ci-shared-infra-stack-${var.shared_infra_id}"] : [],
  )

  # The complete set the template carries, named once so the count can be
  # checked against GCP's 64-tag limit rather than discovered at the API.
  host_network_tags = distinct(concat(["ci-runner-host", var.name], var.network_tags, local.shared_infra_tags))

  # `pool` and `repo` label every metric this pool publishes, so a single fleet
  # dashboard can group by either without per-repo dashboard code.
  repo_full = "${var.github_owner}/${var.github_repo}"

  common_labels = merge(var.labels, {
    component = "ci-runner-host-pool"
    pool      = var.name
  })

  # `self-hosted` is what workflows match on today across the fleet; the pool
  # name is what lets a repository address THIS pool specifically.
  #
  # THIS IS NOT THE SET A JOB IS ROUTED AGAINST, and the difference cost this
  # fleet every scale-out it never performed. The agent registers three labels
  # of its own that no `--labels` argument produces and none of these can
  # remove — GitHub calls them `read-only`: `self-hosted`, the OS (`Linux` /
  # `Windows`) and the architecture (`X64`). No pool here is configured with an
  # OS label because of that, and every workflow in the fleet asks for one, so
  # the controller — which subtracted this list and only this list — had a
  # label left over on every job and counted none of them. The controller now
  # derives its own match set from this plus `ci-host-os`; see P_MATCH_JSON in
  # controller-startup.sh. Adding an OS label HERE would be the wrong fix: it
  # would be passed to `config.sh --labels` as a custom label and duplicate the
  # read-only one.
  runner_labels = join(",", concat(["self-hosted", var.name], var.runner_labels))

  # ONE expression for this pool's slice of the shared cache bucket, read by both
  # the IAM condition below and the host that fetches from it. Written twice they
  # would eventually disagree, and the failure is quiet in the worst way: every
  # request would land outside the pool's own grant and come back 403, which the
  # host logs as a snapshot that has not been published yet.
  cache_prefix = "cache/${var.name}/"

  # WHERE THE BUILD CACHE LIVES, AND WHY NOT SAYING IS THE COMMON CASE.
  #
  # `null` — the default — means "the bucket this pool already hydrates from".
  # A project that runs `ci-runner-cache-bucket` therefore gets the remote build
  # cache by adding nothing at all, which is the entire point of the layer: the
  # one repository in this fleet that wired a build cache by hand ran it stone
  # cold for weeks and every run stayed green. A capability every consumer has
  # to opt into by hand is a capability most of them will have wrong.
  #
  # An explicit "" turns it off for a pool that hydrates dependencies but must
  # not serve build artifacts, and an explicit name points it at a different
  # bucket. Both are unusual and both are stated.
  turbo_bucket = var.turbo_cache_bucket == null ? var.cache_snapshot_bucket : var.turbo_cache_bucket

  # The remote BUILD cache's slice, and it is keyed by REPOSITORY where the
  # dependency snapshot is keyed by pool. The difference is the point of the
  # layer: a turbo artifact is named by the hash of its inputs, so two pools
  # serving the same repository — a Linux pool and a shard pool, say — compute
  # the same names and should hit each other's entries. Two pools serving
  # DIFFERENT repositories must never share, which is what the owner and repo in
  # the path guarantee and what the IAM condition below enforces.
  turbo_prefix = "turbo/${var.github_owner}/${var.github_repo}/"

  # Controller and hosts are different identities: the controller may delete
  # instances, a host executes build input. There is no fallback — the fallback
  # that used to be here silently chose the weak side of that split for every
  # consumer, so the variable is now required and validated instead.
  controller_sa = var.controller_service_account_email

  # A host makes no drain decisions — it only serves jobs and answers questions
  # about itself. It does carry the telemetry publisher, and that is the one
  # thing it cannot delegate: the cache hydrate happens once, before the agent
  # registers, and the controller never sees it. A controller that reported on a
  # hydrate would be reporting on something it did not watch.
  host_startup_source = join("\n", [
    "#!/usr/bin/env bash",
    file("${path.module}/scripts/telemetry.sh"),
    file("${path.module}/scripts/host-startup.sh"),
  ])

  # AND IT TRAVELS COMPRESSED, BECAUSE THE PLAIN TEXT NO LONGER FITS.
  #
  # A GCE metadata VALUE is capped at 256 KiB. The two scripts above render to
  # about 271 KiB, so `startup-script` stopped being a valid metadata value —
  # and the way that presents is the reason this is worth the wrapper. Nothing
  # warns: `terraform plan` is clean, and the APPLY fails at create time with
  #
  #   Error 413: Value for field 'resource.properties.metadata.items[N].value'
  #   is too large: maximum size 262144 character(s); actual size 277764
  #
  # on a nightly unattended apply nobody reads. The pool keeps its previous
  # template, the group keeps serving whatever it already booted, and the fleet
  # silently stops taking new module code — which is exactly what happened:
  # three pools sat on a template with a known-broken boot script for a day
  # while every merged fix looked shipped.
  #
  # gzip, then base64, inlined in a quoted heredoc — the same shape the cache
  # warmer already uses for its three staged scripts, for the same reason. It
  # takes the value from ~271 KiB to ~125 KiB, which is not merely under the cap
  # but leaves the script room to roughly double before it matters again. Doing
  # it as a SECOND metadata key and fetching that key at boot would have been the
  # other option; it is worse, because it adds a metadata round trip to the boot
  # path and a new way to boot with no script at all.
  #
  # It unpacks OUTSIDE anything host-startup.sh manages. bash reads a script
  # incrementally as it executes, so a boot script living under a directory its
  # own code recreates could be truncated mid-run by its own housekeeping.
  #
  # `set -euo pipefail` is deliberate for the four lines it covers: a truncated
  # blob must fail the boot loudly and let the register grace drain the host,
  # never leave a host up running half a script.
  host_startup_gz = base64gzip(local.host_startup_source)

  host_startup = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    base64 -d <<'CI_HOST_STARTUP_GZ_EOF' | gzip -d > /var/lib/ci-host-startup.sh
    ${local.host_startup_gz}
    CI_HOST_STARTUP_GZ_EOF
    chmod 0700 /var/lib/ci-host-startup.sh
    exec /var/lib/ci-host-startup.sh
  EOT

  # The Windows boot script. Terraform evaluates both arms of a conditional, so
  # this is read whatever the pool's OS is; one name for the text is worth the
  # read.
  windows_host_startup = file("${path.module}/scripts/windows-host-startup.ps1")

  # AND IT TRAVELS COMPRESSED TOO — by MORE than the Linux one does, and it has
  # never once said so. `windows-host-startup.ps1` renders to 366,591
  # characters, 140% of the cap, against Linux's 106%. The reason nothing ever
  # reported it is that no Windows pool has ever been applied: the arm was
  # written, reviewed and merged, and the first operator to set
  # `host_os = "windows"` would have met #378's Error 413 on the other operating
  # system, months later, with "the boot-script size problem was fixed" in the
  # history to mislead them (#395).
  #
  # The loader is a FILE rather than a heredoc here, unlike the four Linux
  # lines above: unpacking on Windows is not four lines. It has to restrict the
  # file's ACL before writing it — C:\Windows\Temp is writable by the slot users
  # on a warm host's reboot — decode gzip through .NET streams, and hand off to
  # a child powershell.exe with a stated execution policy. That belongs in a
  # file the PowerShell analyzer and Pester can both read, not in a Terraform
  # string.
  #
  # `replace`, not `templatefile`: PowerShell's `${name}` is Terraform template
  # syntax, so a `templatefile` loader would be one ordinary PowerShell edit
  # away from failing the plan — or worse, interpolating.
  windows_host_startup_gz = base64gzip(local.windows_host_startup)

  windows_boot_loader = replace(
    file("${path.module}/scripts/windows-boot-loader.ps1"),
    "__CI_BOOT_SCRIPT_GZ__",
    local.windows_host_startup_gz,
  )

  # EXACTLY ONE boot-script key, chosen by OS. This is the only thing `host_os`
  # switches on the template itself; everything else it does is a refusal below.
  #
  # Getting the pair wrong is the worst-behaved failure in this system, and it
  # does not present as a failure at all: the guest agent looks for the key that
  # belongs to ITS platform and no other, so a Windows instance carrying
  # `startup-script`, or a Linux one carrying `windows-startup-script-ps1`, runs
  # NO boot script whatsoever. The host comes up healthy, registers zero agents,
  # is drained at `register_grace_seconds` as a failed boot, is rebuilt from the
  # same template, and the pool churns hosts at full price forever while every
  # metric reads "hosts running". A script that never started cannot assert
  # anything about the mistake, which is why the image pairing is refused at
  # plan time instead.
  boot_script_metadata = var.host_os == "windows" ? {
    "windows-startup-script-ps1" = local.windows_boot_loader
    } : {
    "startup-script" = local.host_startup
  }

  # Windows-only keys, MERGED IN rather than written with an empty value, so a
  # Linux pool renders the same key set it renders today.
  windows_host_metadata = var.host_os == "windows" ? {
    # Guest attributes are off unless the instance asks for them, and the
    # liveness beacon is a PUT to that namespace. Without this the host's first
    # beacon write fails and it refuses to register — the designed outcome, for
    # a reason nobody would find from the boot log alone.
    "enable-guest-attributes" = "TRUE"

    # The publisher travels as metadata for the same reason the broker source
    # does: ONE image keeps serving every pool while the code stays versioned
    # with the module and covered by the module's own tests.
    "ci-beacon-script" = file("${path.module}/scripts/windows-beacon-publisher.ps1")

    # The image CONTRACT floor. Absent, the boot script falls back to 1 and a
    # host will boot from an image predating whatever the script now assumes,
    # failing at the first service install rather than at phase 0 by name.
    "ci-image-min-version" = tostring(var.windows_image_min_version)
  } : {}

  # A string check on the family name is a heuristic, not a proof. It catches
  # the one mistake that actually happens — a consumer duplicates the Linux
  # module block, sets `host_os`, and forgets the image — and its alternative is
  # the silent churn loop above. `ci-runner-host-win` contains the Linux family
  # as a substring, so the Windows test runs first and the Linux one is its
  # complement; testing them independently would score every Windows image as
  # both.
  image_names_windows_family = can(regex("ci-runner-host-win", var.image))
  image_names_linux_family   = can(regex("ci-runner-host", var.image)) && !local.image_names_windows_family

  # The controller carries its decision rules and the telemetry publisher inline
  # so a running controller never depends on fetching code at runtime. They are
  # separate files in the repo precisely so they can be unit-tested; embedding
  # them here is what puts the TESTED text on the box.
  controller_startup_source = join("\n", [
    "#!/usr/bin/env bash",
    file("${path.module}/scripts/drain-decision.sh"),
    file("${path.module}/scripts/orphan-decision.sh"),
    file("${path.module}/scripts/pinned-job-decision.sh"),
    file("${path.module}/scripts/recycle-decision.sh"),
    # The Windows half of the second delete gate. Concatenated on EVERY pool,
    # Linux included, and inert on one: nothing calls beacon_decision() unless a
    # host reports `ci-host-os = windows`. Shipping it conditionally would make
    # the controller a per-deployment variant, and the branch that decides
    # whether a machine is deleted would then differ from the branch that was
    # tested.
    file("${path.module}/scripts/beacon-decision.sh"),
    # The pin-hold veto's rule. Concatenated on EVERY pool for the same reason
    # the beacon's is: the branch that decides whether a machine is deleted must
    # be the branch that was tested, and a pool that ships it conditionally is a
    # per-deployment variant of the controller.
    file("${path.module}/scripts/pin-hold-decision.sh"),
    # The merge-queue parking rule. Concatenated on EVERY pool for the third
    # time the same reason applies: the controller is ONE binary, and a decision
    # rule shipped selectively is a per-deployment variant of it. It happens to
    # be repository-wide rather than pool-wide, which changes where it is CALLED
    # from and not what is delivered.
    file("${path.module}/scripts/parked-decision.sh"),
    # The merge-queue STALL rule, the parking rule's complement and the only one
    # in this list whose verdict causes a WRITE. Concatenated on every pool for
    # the same one-binary reason — and note that shipping it here does not by
    # itself let it act: the write needs `pull requests: write` on the App, so a
    # fleet whose installation was never upgraded runs this exact code and
    # reports its own denial instead of acting.
    file("${path.module}/scripts/queue-stall-decision.sh"),
    file("${path.module}/scripts/telemetry.sh"),
    file("${path.module}/scripts/watchdog-decision.sh"),
    # The merge-queue pool's ceiling rule. On EVERY pool, like the two above:
    # nothing calls it unless a pool's role is `merge-queue`, and shipping it
    # selectively would make the controller a per-deployment variant.
    file("${path.module}/scripts/mergify-capacity.sh"),
    # Ahead of the controller itself, and not merely by convention: the
    # controller calls pool_table_parse at FILE SCOPE, before its first tick,
    # to learn which pools it serves. Concatenated after, the call would run
    # against an undefined function and the controller would exit on boot
    # having served nothing.
    file("${path.module}/scripts/pool-table.sh"),
    file("${path.module}/scripts/controller-startup.sh"),
  ])

  # AND IT TRAVELS COMPRESSED, FOR THE REASON THE HOST'S DOES.
  #
  # Fourteen files concatenated render to about 305 KiB, past the 256 KiB cap on
  # a GCE metadata value. This is the SECOND half of the same outage: gzipping
  # only the host's script got the host template created and moved the identical
  # Error 413 one resource down, onto `google_compute_instance_template.controller`
  #
  #   Error 413: Value for field 'resource.properties.metadata.items[25].value'
  #   is too large: maximum size 262144 character(s); actual size 311914
  #
  # and a controller that cannot be created is a pool that never scales off zero
  # no matter how healthy its hosts are. Both halves now carry the wrapper, and
  # the precondition below covers this one so the next script added to the list
  # above is a red plan rather than a failed nightly apply.
  #
  # Same shape as the host's, and the same two deliberate choices: it unpacks to
  # /var/lib, outside anything the controller manages, because bash reads a
  # script incrementally as it runs; and `set -euo pipefail` makes a truncated
  # blob a loud boot failure rather than a controller running a prefix of its
  # own decision rules — half of which decide whether a machine is deleted.
  controller_startup_gz = base64gzip(local.controller_startup_source)

  controller_startup = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    base64 -d <<'CI_CONTROLLER_STARTUP_GZ_EOF' | gzip -d > /var/lib/ci-controller-startup.sh
    ${local.controller_startup_gz}
    CI_CONTROLLER_STARTUP_GZ_EOF
    chmod 0700 /var/lib/ci-controller-startup.sh
    exec /var/lib/ci-controller-startup.sh
  EOT

  # Merged into the controller's metadata rather than written as a `"false"`
  # key, so a pool that has not opted in renders the SAME key set it renders
  # today and plans no change at all. A key whose value is the default is still
  # a diff on every existing controller.
  controller_registration_metadata = var.controller_mints_registration_token ? {
    "ci-mint-registration-token" = "true"
  } : {}
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

# --- the remote build cache this pool may read -----------------------------------

# The same grant, the same shape, and the same refusal to widen it: READ, inside
# this REPOSITORY's prefix, and nothing else.
#
# It is a second binding rather than a widened condition on the one above,
# because the two prefixes answer to different keys — `cache/<pool>/` is per
# pool, `turbo/<owner>/<repo>/` is per repository — and a single condition
# spelling both would be a condition nobody can read at 2am. The cost of the
# split is one more binding on the same bucket; the benefit is that revoking
# either layer is deleting one resource.
#
# `objectViewer`, never `objectUser`: no `storage.objects.create`, no
# `storage.objects.delete`. What writes here is the warmer, from the default
# branch, on a schedule — never a host, because a host runs pull-request code
# and a build artifact is a tarball the next build unpacks into its output tree
# and reports as its own result.
resource "google_storage_bucket_iam_member" "host_reads_turbo_cache" {
  count = local.turbo_bucket == "" ? 0 : 1

  bucket = local.turbo_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.service_account_email}"

  condition {
    title       = "only-this-repositorys-build-cache"
    description = "Reads are confined to ${local.turbo_prefix}, so a pool serving one repository cannot read another repository's build artifacts out of the shared bucket."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${local.turbo_bucket}/objects/${local.turbo_prefix}\")"
  }
}

# --- host template ------------------------------------------------------------

resource "google_compute_instance_template" "host" {
  project     = var.project_id
  name_prefix = "${var.name}-host-"
  region      = var.region

  machine_type = var.machine_type
  labels       = local.common_labels
  tags         = local.host_network_tags

  # GCP caps an instance at 64 network tags. Nothing here approached it until
  # `shared_infra_id` started ADDING tags to a set the caller already controls:
  # a pool passing 62 of its own network_tags was valid, and turning the pair on
  # made it invalid — on a Linux host, which gains two — with no plan-time
  # signal. The apply reached the API and failed there, on a change whose plan
  # said "one instance template". Deduplicated, because GCP counts the set and
  # `concat` does not. The check itself lives in the resource's one `lifecycle`
  # block further down -- Terraform allows exactly one per resource.
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

  metadata = merge(local.boot_script_metadata, local.windows_host_metadata, {
    # What this host IS, said rather than inferred. The boot script asserts it
    # against the platform it is actually running on, and the controller reads
    # it to choose which liveness gate applies to the host it is about to
    # delete. Inferring an OS from the absence of a key is how a mis-wired pool
    # gets a confident wrong answer.
    "ci-host-os" = var.host_os

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

    # The remote BUILD cache the host serves to its slots. Empty bucket = the
    # layer is off, hosts start no server and set no TURBO_* variables, and a
    # repository's builds behave exactly as they did before these keys existed.
    # The server source travels as metadata for the same reason the broker's
    # does: one image, every pool, and the code stays reviewable and versioned
    # with the module rather than baked into an image nobody re-reads.
    "ci-turbo-bucket"             = local.turbo_bucket
    "ci-turbo-prefix"             = local.turbo_bucket == "" ? "" : local.turbo_prefix
    "ci-turbo-port"               = tostring(var.turbo_cache_port)
    "ci-turbo-disk-budget-bytes"  = tostring(var.turbo_cache_disk_budget_bytes)
    "ci-turbo-max-artifact-bytes" = tostring(var.turbo_cache_max_artifact_bytes)
    "ci-turbo-cache-py"           = local.turbo_bucket == "" ? "" : file("${path.module}/scripts/turbo-cache-server.py")

    # Registry hosts a job container may be pulled from as the JOB identity, on
    # TOP of this host's own region and the Container Registry hosts, which the
    # host always configures. Needed only when a repository pulls its builder
    # image from another region or another project.
    "ci-registry-hosts" = join(",", var.extra_registry_hosts)

    # Hosts are cattle managed by the controller; interactive login is not the
    # supported way to inspect one. Logs go to Cloud Logging.
    "block-project-ssh-keys" = "true"
  })

  lifecycle {
    create_before_destroy = true

    # Two host services, one port, and the loser is chosen by boot ordering. The
    # broker is the one that must never lose — a host whose credential broker did
    # not start refuses to register at all — so this is refused at plan time
    # rather than discovered as a pool that stops taking work.
    precondition {
      condition     = local.turbo_bucket == "" || var.turbo_cache_port != var.job_broker_port
      error_message = "pool '${var.name}' would run the build-cache server and the job credential broker on the same port (${var.job_broker_port}). One of the two would fail to bind, and which one depends on boot ordering; give turbo_cache_port a port of its own."
    }

    # Same class of failure as the tag limit below, and the one that actually
    # bit: a metadata value over 256 KiB is refused by the API at CREATE time,
    # so it costs a plan that reads clean and an apply that dies after the run
    # has already started. Asserted here, the boot script's growth is a red plan
    # with a number in it instead of a 413 in a nightly build log.
    precondition {
      condition     = length(local.boot_script_metadata[var.host_os == "windows" ? "windows-startup-script-ps1" : "startup-script"]) < 262144
      error_message = "pool '${var.name}' renders a ${length(local.boot_script_metadata[var.host_os == "windows" ? "windows-startup-script-ps1" : "startup-script"])}-character boot script and a GCE metadata value is capped at 262144. Both arms are already gzipped into their loaders, so this means the SOURCE has outgrown even the compressed form: shorten modules/ci-runner-host-pool/scripts/${var.host_os == "windows" ? "windows-host-startup.ps1" : "host-startup.sh"}, or move a part of it onto the golden image. Left to the apply this is an Error 413 at create time, on a plan that read clean."
    }

    precondition {
      condition     = length(local.host_network_tags) <= 64
      error_message = "pool '${var.name}' would carry ${length(local.host_network_tags)} distinct network tags and GCP allows 64. The two built-in tags plus var.network_tags${var.shared_infra_id == "" ? "" : " plus the ${var.host_os == "linux" ? "two" : "one"} shared_infra_id tag(s)"} exceed the limit; drop entries from var.network_tags. Left to the apply this fails at the API, after the plan looked clean."
    }

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

    # --- what a Windows pool must refuse to plan with -------------------------
    #
    # A failure at plan costs a review comment; the same mistake at boot costs a
    # churning MIG that reports itself as a healthy pool. Every one of these is
    # here rather than in the variable's own `validation` block for the reason
    # the two above are: cross-variable validation needs Terraform 1.9 and this
    # module supports >= 1.5.

    # The copy-paste error, in both directions. Neither host runs the other's
    # boot script — it runs NOTHING, because the guest agent finds no key for
    # its platform, and the pool churns hosts forever at full price while every
    # metric reads "hosts running".
    precondition {
      condition     = var.host_os != "windows" || !local.image_names_linux_family
      error_message = "host_os = \"windows\" was given the Linux golden image family — build the Windows image from packer/ci-host-image-win.pkr.hcl (family ci-runner-host-win). A Windows instance whose image expects `startup-script` runs no boot script at all, registers nothing, and is drained and rebuilt from the same template forever."
    }

    precondition {
      condition     = var.host_os != "linux" || !local.image_names_windows_family
      error_message = "host_os = \"linux\" was given the Windows golden image family (ci-runner-host-win) — a Linux instance carrying `windows-startup-script-ps1` runs no boot script at all, so the host boots healthy, registers zero agents, and the pool churns hosts at full price."
    }

    # Nothing on a Windows host reads this list: there is no container runtime,
    # so no credential helper and no docker config to write it into. Accepting
    # it would be the worst kind of no-op — the apply is clean and the failure
    # arrives inside a job as an unauthenticated pull.
    precondition {
      condition     = var.host_os != "windows" || length(var.extra_registry_hosts) == 0
      error_message = "extra_registry_hosts is not supported on host_os = \"windows\" — a Windows pool has no container runtime and nothing reads the list, so accepting it would apply clean and fail later as an unauthenticated pull inside a job."
    }

    # Spot is wrong for CI on any OS and is only being narrowed here, where no
    # existing pool can break: a preemption takes every slot on the host with
    # it, on a machine whose boot is measured in minutes, and Windows Server is
    # billed per vCPU-hour whatever the provisioning model.
    precondition {
      condition     = var.host_os != "windows" || !var.spot
      error_message = "spot = true is refused on host_os = \"windows\" — a preemption kills every slot on a host whose boot costs minutes, and Windows Server is licensed per vCPU-hour regardless of provisioning model, so the saving is smaller than the jobs it destroys."
    }

    # The 600s default is calibrated to a Linux boot plus K x config.sh. A
    # Windows first boot plus K local-account creations plus K x
    # `config.cmd --runasservice` does not fit in it, and the consequence of not
    # fitting is precisely the churn loop this input exists to prevent — the
    # controller reads a booting host as a dead one, sometimes between the
    # verdict and the agents coming up.
    precondition {
      condition     = var.host_os != "windows" || var.register_grace_seconds >= 1200
      error_message = "register_grace_seconds must be at least 1200 on host_os = \"windows\" — the default of 600 is calibrated to a Linux boot, and a controller that reads a still-booting Windows host as a dead one drains it, sometimes between the verdict and its agents coming up."
    }

    # Windows, plus the build toolchains, plus the warm cache, plus K
    # workspaces, plus a pagefile. A host that fills its disk mid-job fails
    # every slot at once and reports it as a repository problem.
    precondition {
      condition     = var.host_os != "windows" || var.boot_disk_size_gb >= 200
      error_message = "boot_disk_size_gb must be at least 200 on host_os = \"windows\" — Windows plus the toolchains plus the warm cache plus a workspace per slot plus a pagefile does not fit below that, and a host that fills its disk mid-job fails every slot at once and reports it as a repository problem."
    }

    # The one guard available at plan time for the §3A reduction. A Windows host
    # account holds no Secret Manager grant, so it cannot mint its own
    # registration token — and a pool that DOES leave that grant in place is the
    # one that happens to work today, which is exactly why it has to be refused
    # deliberately rather than left to fail. Terraform cannot see what IAM a
    # passed-in account holds; the real check is the host's own boot probe.
    precondition {
      condition     = var.host_os != "windows" || var.controller_mints_registration_token
      error_message = "host_os = \"windows\" requires controller_mints_registration_token = true — a Windows host account is stripped of the App-key read (ci-runner-identity's host_os) because job code on a Windows host can mint a token for it, so a host left to mint its own registration token never registers, and one that CAN is the pool that hands a pull request the GitHub App private key."
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

# THE CONTROLLER IS NO LONGER A PET (#308).
#
# It used to be a bare `google_compute_instance` with `desired_status =
# "RUNNING"`, which repairs a controller somebody STOPPED — on the next apply,
# whenever that is — and does nothing at all for one somebody DELETED. The
# hosts it drives have been in a MIG behind an autoscaler since the beginning;
# the thing driving them was the one machine in the design that could vanish
# and stay vanished.
#
# The failure is quiet in the worst way. Every fact the fleet publishes about
# its own capacity comes out of the controller tick, so a missing controller
# does not produce an outage signal — it produces the ABSENCE of every signal,
# and the autoscaler is `ONLY_UP` on a metric nobody is writing, so the pool
# freezes at whatever size it happened to be and every job queues.
#
# WHAT THIS BUYS AND WHAT IT DOES NOT
#
# A managed group of size 1 recreates an instance that is deleted or whose VM
# is gone. That is the whole default. It is deliberately NOT autohealing: see
# `controller_autohealing` below for why the health-check-driven half is opt-in
# rather than the default it looks like it should be.
#
# THE FIRST APPLY REPLACES THE CONTROLLER. There is no in-place path from a
# standalone instance to a managed one, so the plan will show a destroy and a
# create, and the fleet runs without a control plane for the couple of minutes
# the new one takes to boot and install. Nothing is lost: hosts keep running
# the jobs they hold — the controller executes none of them — and every tick
# recomputes from live GitHub and MIG state, so there is no controller-side
# state to carry across (`controller-markers-are-not-durable-state`: the boot
# path already assumes its own markers do not survive). What DOES change is the
# instance name, which gains the group's suffix: `<name>-controller-a1b2`.
resource "google_compute_instance_template" "controller" {
  count = var.manage_controller ? 1 : 0

  project      = var.project_id
  name_prefix  = "${var.name}-controller-"
  region       = var.region
  machine_type = var.controller_machine_type
  labels       = local.common_labels
  tags         = concat(["ci-runner-controller", var.name], var.network_tags)

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
    email  = local.controller_sa
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # The controller is the pool's only always-on cost and its only source of
  # truth. It must survive a maintenance event without a human.
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  # STILL ONE KEY PER FIELD, deliberately, even though the controller now reads
  # a `ci-pools` table. This controller serves exactly one pool — its own — and
  # the controller synthesises a one-row table from these keys when `ci-pools`
  # is absent. Rendering the table here instead would rewrite the metadata of
  # every controller in the fleet to say what it already says, for no behaviour
  # change, on the same apply that is trying to change something else.
  metadata = merge(local.controller_registration_metadata, {
    startup-script = local.controller_startup

    "ci-github-owner"        = var.github_owner
    "ci-github-repo"         = var.github_repo
    "ci-app-id"              = var.github_app_id
    "ci-app-installation-id" = var.github_app_installation_id
    "ci-app-key-secret"      = var.github_app_private_key_secret
    "ci-pool"                = var.name
    # The same key the hosts read, and the base of the set demand is counted
    # against — the controller adds the agent's read-only labels to it and folds
    # the case before it applies GitHub's superset rule. A controller without
    # this key matches no job at all, reports zero demand forever, and the pool
    # never leaves zero hosts.
    "ci-runner-labels"           = local.runner_labels
    "ci-host-os"                 = var.host_os
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
    # The queue's branch, so the parking sweep can tell a pull request that will
    # never be admitted from one that is simply waiting its turn.
    "ci-queue-base" = var.queue_base_branch

    # The stall sweep's two thresholds, alongside the branch it compares against.
    # `max-attempts` doubles as the switch: zero makes the sweep observe and
    # publish and never comment, which is the shape a fleet runs in until its
    # App installation accepts `pull requests: write`.
    "ci-queue-stall-after-seconds" = tostring(var.queue_stall_after_seconds)
    "ci-queue-stall-max-attempts"  = tostring(var.queue_stall_max_attempts)

    # Empty unless autohealing is on. The startup script starts the liveness
    # responder only when this key has a value, so the default path opens no
    # port at all — the responder is a listening socket on the one machine that
    # holds the App installation token, and it exists to answer a probe nobody
    # is sending unless an operator asked for one.
    "ci-health-port" = var.controller_autohealing ? tostring(var.controller_health_port) : ""

    "block-project-ssh-keys" = "true"
  })

  # The group below refers to this template by id, so the new one must exist
  # before the old one can go.
  lifecycle {
    create_before_destroy = true

    # The controller's half of the metadata-size gate. Same cap, same silence:
    # the length is checked by the API and not by the plan, so without this the
    # first sign is a 413 on an unattended apply, and the pool it belongs to
    # keeps whatever controller it already had while every merged fix reads as
    # shipped.
    precondition {
      condition     = length(local.controller_startup) < 262144
      error_message = "pool '${var.name}' renders a ${length(local.controller_startup)}-character controller boot script and a GCE metadata value is capped at 262144. The script is already gzipped into its wrapper, so the SOURCE has outgrown even the compressed form: shorten the decision-rule scripts under modules/ci-runner-host-pool/scripts/, or move part of the controller onto the golden image. Left to the apply this is an Error 413 at create time, on a plan that read clean — and a controller that cannot be created is a pool that never leaves zero hosts."
    }
  }
}

# AUTOHEALING IS OFF BY DEFAULT, AND THAT IS THE CONSIDERED ANSWER, NOT A TODO.
#
# Autohealing on a group of size 1 is not "recover faster". It is "grant a
# health probe the authority to delete the fleet's control plane, repeatedly,
# on no other evidence". If the probe cannot reach the controller — the
# health-check ranges are not open to its tag, a central firewall drops them, a
# port is wrong — the group concludes the controller is dead, deletes it,
# builds another, cannot reach that one either, and loops. That state is
# strictly worse than the pet: a pet that is up stays up.
#
# And the wedge case autohealing is usually bought for is already covered
# in-guest. `ci-controller-watchdog.timer` compares the tick heartbeat's age
# against ten poll intervals and restarts the unit — the exact 2h55m stall of
# 2026-08-14, caught without a network path and without deleting anything. What
# autohealing adds on top is narrow: a guest whose OS is dead enough that
# systemd cannot run the watchdog. Real, but not worth a recreate loop by
# default.
#
# So: the group is the default (it recovers a DELETED controller, which is what
# #308 is about, and it can do that with no health check at all), and the
# probe-driven half is a flag an operator turns on after confirming the probe
# actually reports HEALTHY. `docs/applying-runner-infra.md` has the sequence.
resource "google_compute_health_check" "controller" {
  count = var.manage_controller && var.controller_autohealing ? 1 : 0

  project = var.project_id
  name    = "${var.name}-controller-live"

  # 3 × 30s to condemn. Below that a slow tick starts looking like a dead
  # machine, and the cost of being wrong here is a rebuilt control plane.
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  # HTTP, not TCP. A TCP check passes as long as something is listening, which
  # is true of a controller whose tick loop has stopped — the responder answers
  # 200 only while the heartbeat is fresh, and that distinction is the entire
  # reason for having a check rather than relying on "the VM exists".
  http_health_check {
    port         = var.controller_health_port
    request_path = "/livez"
  }
}

resource "google_compute_instance_group_manager" "controller" {
  count = var.manage_controller ? 1 : 0

  project = var.project_id
  name    = "${var.name}-controller"
  zone    = length(var.zones) > 0 ? var.zones[0] : data.google_compute_zones.available.names[0]

  base_instance_name = "${var.name}-controller"
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.controller[0].id
  }

  # `max_surge_fixed = 0` IS THE INVARIANT, NOT A TUNING CHOICE. Two
  # controllers serving one repository at the same time both count demand,
  # both resize the MIG and both drain hosts, against a GitHub view neither
  # knows the other is acting on. Surging to two for a template change would
  # do exactly that, briefly, on every apply that touches the startup script —
  # which is most of them. One at a time, with a gap, is correct.
  #
  # PROACTIVE, unlike the hosts' group: an OPPORTUNISTIC controller would sit
  # on the old startup script until something else replaced it, which is the
  # rollout shape that put v5.1.0 on disk and left v5.0 running the pool.
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
      health_check = google_compute_health_check.controller[0].id

      # Ten minutes. The controller installs packages, mints a token and walks
      # the whole repository before its first heartbeat; a delay shorter than
      # the slowest legitimate boot turns autohealing into a boot loop that
      # never reaches a first tick.
      initial_delay_sec = 600
    }
  }
}
