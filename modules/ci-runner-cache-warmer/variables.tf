# ci-runner-cache-warmer — inputs.
#
# The point of this module is that a repository configures NOTHING, so almost
# everything here has a default and the ones that do not are facts the caller
# already holds because it built the pool: the project, the region, the bucket,
# the pool name and the repository.

variable "project_id" {
  description = "GCP project that owns the trigger, the schedule and the warmer account."
  type        = string
}

variable "region" {
  description = "Region for the Cloud Build trigger and the Cloud Scheduler job. Both are regional and both must name the same one; the scheduler's URI is built from it."
  type        = string
}

variable "pool_name" {
  description = <<-EOT
    Name of the pool whose caches this warms — the same `name` passed to
    `ci-runner-host-pool`. It selects the snapshot prefix, `cache/<pool>/`, which
    is the prefix that pool's hosts read.
  EOT
  type        = string

  validation {
    # This value is interpolated into a CEL string literal on four IAM
    # conditions. A name carrying a double quote would close the literal and
    # could leave a condition that matches every object in the bucket — the
    # isolation between one pool's snapshots and another's rests on it. Same
    # charset ci-runner-host-pool validates for the same reason.
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.pool_name))
    error_message = "pool_name must be 1-63 characters, lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository being warmed."
  type        = string

  validation {
    # Reaches the build cache's object prefix AND the CEL literal on two of the
    # grants. A quote rewrites the condition; a slash moves the prefix, so the
    # warmer would write where no host reads. The charset is GitHub's own.
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_owner))
    error_message = "github_owner must be a GitHub login: 1-39 characters, letters, digits and hyphens, and neither starting nor ending with a hyphen."
  }
}

variable "github_repo" {
  description = "Repository being warmed, without the owner. One repository per warmer, because one repository per pool."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,100}$", var.github_repo))
    error_message = "github_repo must be a repository NAME without the owner: 1-100 characters, letters, digits, dots, hyphens and underscores."
  }
}

variable "cache_bucket" {
  description = <<-EOT
    Bucket holding both caches: `cache/<pool>/` for the dependency snapshot and
    `turbo/<owner>/<repo>/` for the build artifacts. The same bucket
    `ci-runner-host-pool` reads from — pass it the output of
    `ci-runner-cache-bucket`.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.cache_bucket))
    error_message = "cache_bucket must be a bucket NAME, 3-63 characters of lowercase letters, digits, dots, hyphens and underscores — it is interpolated into an IAM condition's CEL literal, so the charset is enforced rather than trusted."
  }
}

variable "account_id" {
  description = <<-EOT
    Base of this module's service-account ids: `-warm` for the account the build
    runs as, `-fire` for the one the schedule presents.

    Validated to 25 characters rather than truncated to them: the cap is 30, and
    two pools whose ids differ only after the 25th would silently resolve to one
    account holding both pools' grants.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,23}[a-z0-9])$", var.account_id))
    error_message = "account_id must be 6-25 characters, lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen — `-warm` and `-fire` are appended and the GCP cap is 30."
  }
}

variable "branch" {
  description = <<-EOT
    Branch the warmer builds. The DEFAULT branch, and the security argument
    depends on it: cache content published from a branch a pull request can push
    to is cache content a pull request chose.

    A literal name, never a regex — `triggers.run` refuses one, and taking both
    a filter and a name as inputs would allow a state where the schedule fires
    on a branch the trigger does not watch.
  EOT
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]{1,255}$", var.branch)) && !can(regex("[*?\\[\\]^$]", var.branch))
    error_message = "branch must be a literal branch name, not a pattern: the trigger is fired through triggers.run, which refuses a regular expression."
  }
}

variable "schedule" {
  description = <<-EOT
    Cron schedule for the warm, in `schedule_time_zone`. Nightly by default,
    early enough that the first working-hours build reads a cache warmed against
    the branch as it stands.

    There is no "off" value. A warmer that never runs is the cold cache this
    module exists to end, and it would look exactly like a healthy one — which
    is the observable that hid the fault this whole layer answers. Use
    `disabled` if you genuinely need to stop it; that at least shows up in a
    plan as a trigger that is off.
  EOT
  type        = string
  default     = "0 4 * * *"
}

variable "schedule_time_zone" {
  description = "IANA time zone the schedule is read in. UTC by default so a fleet spanning regions warms at one moment rather than at each region's idea of 4am."
  type        = string
  default     = "Etc/UTC"
}

variable "scheduler_service_account" {
  description = <<-EOT
    Account the scheduler presents when it fires the trigger. Leave it null and
    this module makes one, `<account_id>-fire`, whose entire authority is "may
    fire a trigger" and "may act as the warmer".

    It is deliberately NOT the warmer. `cloudbuild.builds.create` cannot be
    scoped to a single trigger, so the account allowed to fire this build is
    allowed to fire every trigger in the project — and the warmer's build runs
    the repository's own dependency code.

    It must live in `project_id`: Cloud Scheduler mints its token through a
    per-project service agent, so a cross-project account fails at fire time
    with an error naming the agent rather than the account.
  EOT
  type        = string
  default     = null
}

variable "prepare_command" {
  description = <<-EOT
    How this repository installs its dependencies. LEAVE THIS UNSET.

    Unset, the warm works it out from the repository's own lockfile —
    pnpm-lock.yaml, yarn.lock, package-lock.json, or a bare package.json — which
    is the one statement about package managers a repository already makes,
    keeps current, and commits. Set, it is a claim in a Terraform root that has
    to stay true about a repository that can switch package managers without
    telling it, and a stale claim here does not fail an apply: it fails inside a
    nightly build, or succeeds and installs nothing, and both look from the
    outside like a cache that is merely cold.

    The detected install runs NO lifecycle scripts. That is not decoration:
    install-time scripts are the cheapest place to run code inside someone
    else's build, and this snapshot is unpacked as ROOT on every host in the
    pool. An override is where a repository accepts that trade in writing.
  EOT
  type        = string
  default     = null
}

variable "build_command" {
  description = <<-EOT
    The build whose artifacts are published. LEAVE THIS UNSET.

    Its output is not kept and its exit code does not fail the warm — only the
    files it leaves in `turbo_cache_dir` matter. Unset, the warm re-installs
    (detected the same way, and with lifecycle scripts, because this step exists
    to run the repository's own build) and then runs every `build` task through
    turbo with `--cache-dir` pointed at `turbo_cache_dir`, so where artifacts are
    written and where they are collected cannot drift apart.

    A repository with no turbo pipeline can set this to `true` and still get the
    dependency snapshot. An override is handed `WARM_TURBO_DIR` and
    `TURBO_CACHE_DIR` and must honour one of them.

    `$WARM_TURBO_DIR` in an override means what it says. It did not until
    v5.67.0: every `$` was doubled on its way into the step, which is Cloud
    Build's escape for the `args` field and is corruption in the `script` field
    this module uses — the shell saw its own PID followed by a literal. Measured
    (`8f91196b`, `f314e153`, 2026-08-26): the substitution pass does not read a
    `script` field at all, under strict substitution or loose, so nothing is
    escaped now. It is the same defect that made the default command publish
    nothing for months.
  EOT
  type        = string
  default     = null
}

variable "turbo_cache_dir" {
  description = <<-EOT
    Where turbo leaves its finished task artifacts. The default is turbo's own
    default inside a workspace, and the default `build_command` PASSES this
    value to turbo as `--cache-dir` — so this does not have to match anything
    the repository's own CI does, and a repository that builds with
    `--cache-dir=.turbo` still needs no override here. It only matters when
    `build_command` is overridden with something that ignores both
    `WARM_TURBO_DIR` and `TURBO_CACHE_DIR`.

    Each file there is `<hash>.tar.zst`, and the artifact a remote cache serves
    for `<hash>` is that same file byte for byte — which is why publishing is a
    copy and this module needs no write path in the host-side server.
  EOT
  type        = string
  default     = "node_modules/.cache/turbo"
}

variable "snapshot_max_bytes" {
  description = <<-EOT
    Refuse a dependency snapshot larger than this, as the publishing script's
    `CACHE_MAX_BYTES`. Its own default, restated here so the warm and the pools
    can be raised together: a snapshot over a pool's bound is not a slow
    hydrate, it is one every host in that pool silently refuses.
  EOT
  type        = number
  default     = 4294967296
}

variable "max_artifact_bytes" {
  description = <<-EOT
    Refuse to publish a single build artifact larger than this.

    It matches the host-side server's own bound by default. An artifact over
    that bound is served as a miss, so publishing one costs storage and answers
    no read; refusing it here is the cheaper half of the same decision.
  EOT
  type        = number
  default     = 536870912
}

variable "build_image" {
  description = "Image the dependency and build steps run in. Pin it: a floating tag turns an unattended nightly job into an unannounced toolchain upgrade, and the first thing it changes is what goes into the snapshot every host unpacks."
  type        = string
  default     = "node:22"
}

variable "cache_scan_allow_file" {
  description = "Repository-relative path to the credential-scan allowlist, whose commented digests name the dependency files the scan may excuse (a package's PEM test fixture, a README quoting a URL with basic auth). `null`, the default, uses `.github/cache-scan-allow.txt` if the checkout has one and no allowlist otherwise — so an ordinary repository sets nothing. A path named here must exist, because an allowlist that is not there excuses nothing and reads exactly like one that worked. `\"\"` disables the lookup."
  type        = string
  default     = null

  # The value is pasted into a single-quoted shell string inside a step that can
  # reach the metadata server and mint the warmer's write token, so it is checked
  # here rather than trusted: a quote ends that string, a `$` is read by Cloud
  # Build as a substitution key and refuses the whole build, and an absolute or
  # `..` path resolves outside the checkout the allowlist is supposed to come
  # from.
  validation {
    condition = var.cache_scan_allow_file == null || (
      length(regexall("['\"$`\\\\]|\\.\\.", coalesce(var.cache_scan_allow_file, "x"))) == 0
      && !startswith(coalesce(var.cache_scan_allow_file, "x"), "/")
    )
    error_message = "cache_scan_allow_file must be a repository-relative path with no quote, dollar, backtick, backslash or `..` — it is pasted into a shell string in a step that holds the warmer's write credential."
  }
}

variable "gcloud_image" {
  description = "Image the two publishing steps run in. Needs `gcloud storage` and the shell utilities the publishing script uses."
  type        = string
  default     = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
}

variable "machine_type" {
  description = "Cloud Build machine type. A monorepo build on the default worker is the difference between a warm that finishes before the working day and one that is still running when the next fires."
  type        = string
  default     = "E2_HIGHCPU_8"
}

variable "build_timeout" {
  description = "How long one warm may take. Past it the build is killed and nothing is published, which is the right outcome: a warm that runs into the next one publishes write-once objects nobody asked for."
  type        = string
  default     = "3600s"
}

variable "github_connection" {
  description = <<-EOT
    2nd-generation Cloud Build connection to GitHub — a bare name or a full
    resource id. Null means the project uses 1st-generation triggers.

    This is a read of what the project already has, not a preference. The two
    are separate APIs, and a trigger built against the generation the project
    does NOT use is created without complaint and never fires.
  EOT
  type        = string
  default     = null
}

variable "github_repository" {
  description = "Existing `google_cloudbuildv2_repository` id to reuse. Leave null and this module registers one; pass it when another module (ci-runner-apply-trigger, typically) already registered this repository under the same connection, because registering the same remote twice is an ALREADY_EXISTS error rather than a no-op."
  type        = string
  default     = null
}

variable "name" {
  description = "Trigger name. Defaults to `ci-cache-warmer-<repo>`."
  type        = string
  default     = null
}

variable "disabled" {
  description = "Create the trigger but do not let it fire. The honest way to stop warming — unlike removing the schedule, it is visible in a plan."
  type        = bool
  default     = false
}
