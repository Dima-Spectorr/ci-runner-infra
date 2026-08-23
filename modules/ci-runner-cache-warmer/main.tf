# ci-runner-cache-warmer — the fleet-side identity that FILLS the caches a pool
# reads, so no repository has to.
#
# WHAT PROBLEM THIS CLOSES
#
# Two caches make this fleet fast, and until now both were the repository's job
# to fill:
#
#   the dependency snapshot   published by a workflow in the repository, running
#                             as `ci-runner-cache-publisher` through Workload
#                             Identity Federation. Four moving parts per repo: a
#                             workflow file, a WIF binding naming that exact
#                             file, a publisher account, and a schedule.
#   the remote BUILD cache    filled by nothing at all. The host serves reads
#                             (ci-runner-host-pool, turbo-cache-server.py) and
#                             refuses writes on purpose, so without a writer the
#                             store stays empty and every read is a polite miss.
#
# Per-repository wiring is the failure mode this fleet has already paid for: the
# one repository that hand-wired a build cache ran it stone cold for weeks while
# every run stayed green, because a cache that answers nothing looks exactly like
# a build that is merely slow. A capability every consumer opts into by hand is a
# capability most of them have wrong.
#
# So the fleet fills both. This module is a Cloud Build trigger on a schedule
# that checks out the repository's DEFAULT BRANCH, installs its dependencies,
# runs its build, and publishes what that produced: the dependency snapshot to
# `cache/<pool>/`, and the turbo artifacts to `turbo/<owner>/<repo>/`. A
# repository adds nothing, and a repository that already publishes snapshots by
# workflow can delete that workflow (see the README's migration note).
#
# WHY THE WRITER IS HERE AND NOT ON A HOST
#
# A host executes pull-request code. An identity that both runs job code and
# publishes cache content would let one pull request hand build input to every
# later build in the repository — the cross-slot boundary re-opened across hosts
# and across time. That argument is written out in ci-runner-cache-publisher and
# it has not changed; what changes here is only WHERE the trusted writer runs.
# Cloud Build, on the default branch, on a schedule, is an identity no pull
# request can reach.
#
# WHAT IT MAY DO — four grants, and each one is narrower than the obvious one
#
#   1. create objects under `turbo/<owner>/<repo>/`   (objectCreator)
#   2. read objects under the same prefix             (objectViewer)
#   3. create objects under `cache/<pool>/`           (objectCreator)
#   4. replace exactly `cache/<pool>/current`         (objectAdmin, one object)
#
# objectCreator carries create and NOT delete, and in Cloud Storage overwriting
# a live object requires delete — so "written once, never overwritten" stops
# being a convention and becomes something IAM refuses. That matters because the
# bucket's age bound is measured per generation: an object refreshed in place is
# a generation aged zero that never expires, and a poisoned entry inside it
# would be re-served forever. Grant 4 is the single exception, conditioned on
# one object name rather than a prefix, because the pointer must be replaceable
# to point anywhere.
#
# WHAT THIS DOES NOT PROTECT AGAINST, STATED PLAINLY
#
# The install and build steps run the repository's own dependencies, and every
# step in a Cloud Build can reach the metadata server and mint this account's
# token. A malicious dependency in the DEFAULT BRANCH's lockfile could therefore
# publish cache content of its choosing. That is a smaller step than it sounds —
# code in the default branch's dependency tree already runs on every host in the
# pool — and it is bounded by the grants above: create-only, in two prefixes of
# one bucket, for one repository. What it is NOT bounded by is a scrubbed
# environment, so do not add grants here on the assumption that the build steps
# are trusted. They are the repository's code.
#
# That is also why the account that FIRES the schedule is a second, separate
# identity that runs nothing: firing a Cloud Build trigger cannot be scoped to
# one trigger, so the account allowed to fire this one is allowed to fire the
# project's apply trigger too. Give that to the warmer and the bound above stops
# being true.
#
# The workflow-based publisher splits this into two jobs precisely because a
# GitHub OIDC token is exportable by anything in the job; that split does not
# translate to Cloud Build, where the credential is the build's own identity.
#
# Resources:
#   google_service_account            — the warmer, and the account that fires it
#   google_cloudbuildv2_repository    — the repo link, when the project is gen2
#   google_cloudbuild_trigger         — the build, manual-only, fired by the job
#   google_cloud_scheduler_job        — the schedule
#   google_storage_bucket_iam_member  — the four grants above

locals {
  # Both prefixes are written the same way in three modules — here, the host
  # pool's read grants, and the publisher's write grants. Spelled differently
  # anywhere and the failure is silent: the warmer writes where no host looks,
  # and every host logs a cache that has not been published yet.
  cache_prefix = "cache/${var.pool_name}/"
  turbo_prefix = "turbo/${var.github_owner}/${var.github_repo}/"

  bucket_resource  = "projects/_/buckets/${var.cache_bucket}/objects/"
  pointer_resource = "${local.bucket_resource}${local.cache_prefix}current"

  trigger_name = coalesce(var.name, "ci-cache-warmer-${lower(replace(var.github_repo, "_", "-"))}")

  # 2nd gen if the project has a connection, 1st gen otherwise — a read of what
  # the project already has, not a preference. The two are separate APIs and a
  # trigger built against the generation the project does NOT use is created
  # without complaint and never fires. Same determination as
  # ci-runner-apply-trigger, deliberately spelled the same way.
  gen2 = var.github_connection != null

  connection_id = local.gen2 ? (
    startswith(coalesce(var.github_connection, ""), "projects/")
    ? var.github_connection
    : "projects/${var.project_id}/locations/${var.region}/connections/${var.github_connection}"
  ) : null

  repository_id = local.gen2 ? coalesce(var.github_repository, try(google_cloudbuildv2_repository.repo[0].id, "")) : null

  # The publishing script the snapshot half runs. It is READ FROM THE REPOSITORY
  # ROOT rather than copied into this module, and that is on purpose: it is the
  # same file the workflow-based publisher runs, it encodes the archive layout
  # and the scan rules a host applies on arrival, and a second copy would drift
  # from the host's expectations without anything failing until a hydrate
  # silently stops working. scripts/ci/cache-warmer.selftest.sh asserts the path
  # still resolves, because a module vendored without its repository root would
  # otherwise fail at plan time with a message about a missing file and nothing
  # about why this module wants one two directories up.
  #
  # EVERY `$` GOES IN DOUBLED, and that is not cosmetic. Cloud Build reads `$X`
  # and `${X}` in every string of a build config — args, env, anywhere — as a
  # SUBSTITUTION, before the container ever sees them. A shell script pasted in
  # whole is dense with both, and the trigger accepts it happily: the refusal
  # comes at FIRE time, from the API, as
  #
  #   invalid value for 'build.substitutions': key in the template
  #   "CACHE_EXPAND_FLOOR_BYTES" is not a valid built-in substitution
  #
  # …in a nightly build nobody is watching, on a warmer that applied cleanly
  # months earlier. `$$` is Cloud Build's escape for a literal `$`, so doubling
  # every one hands the container the script it was written as.
  #
  # NOT `substitution_option = "ALLOW_LOOSE"`, which is the fix this error's
  # first search result suggests: that makes the unmatched keys resolve to the
  # EMPTY STRING instead of failing, so the build starts and runs a script whose
  # every variable reference has been erased. This is one of the few places
  # where the loud failure is the good outcome.
  escape_dollars = "$$"

  # TWO files, concatenated, because the step runs `bash -c "<text>"` and there
  # is no scripts/ci on that disk to source from. The publisher sources
  # `scan-cache-credentials.sh` when it can find it and uses what is already
  # defined when it cannot, so prepending the library's text is the same program
  # by a different route — and the publisher refuses outright if the scan
  # function is missing, which is what stops a broken concatenation from
  # publishing an unscanned snapshot.
  #
  # SCAN_INLINE_LIBRARY suppresses the library's standalone entry point. Without
  # it the library's own `usage:` check runs against the step's argv and kills
  # the build before the publisher's first line.
  #
  # Escaped as ONE string after the join, not file by file: the escape is a
  # property of what Cloud Build receives, and escaping the parts separately is
  # the same result by a route where a later part can be added unescaped.
  publish_script = replace(join("\n", [
    "SCAN_INLINE_LIBRARY=1",
    file("${path.module}/../../scripts/ci/scan-cache-credentials.sh"),
    file("${path.module}/../../scripts/ci/publish-cache-snapshot.sh"),
  ]), "$", local.escape_dollars)
  turbo_script = replace(file("${path.module}/scripts/warm-turbo.sh"), "$", local.escape_dollars)

  # HOW THE REPOSITORY IS INSTALLED AND BUILT — WORKED OUT AT WARM TIME, FROM THE
  # REPOSITORY, RATHER THAN STATED BY WHOEVER WIRES THE WARMER UP.
  #
  # These defaults are the difference between a capability every consumer opts
  # into by hand and one that is simply on. An input like `prepare_command` looks
  # harmless — it is one line of tfvars — but it is one line that must be RIGHT,
  # in a root nobody revisits, about a repository whose package manager changes
  # without telling Terraform. Wrong, it does not fail the apply: the install
  # fails inside a nightly build, or worse succeeds and builds nothing, and both
  # read from the outside as a cache that is merely cold.
  #
  # So the ladder below asks the repository. A lockfile is the one statement
  # about package managers every repository already makes, keeps current, and
  # commits — the same fact the repository's own CI reads.
  #
  # ONE LINE, deliberately: the prepare half crosses into the build as a Cloud
  # Build environment entry (`CACHE_PREPARE=…`), and an entry carrying newlines is
  # a thing to find out about in a nightly log. `join(" ", …)` is what keeps the
  # ladder readable here and a single line there.
  install_ladder = join(" ", [
    "if [ -f pnpm-lock.yaml ]; then corepack enable >/dev/null 2>&1 || true; pnpm install --frozen-lockfile @FLAGS@;",
    # Berry and classic disagree on both flags, and which one a repository is on
    # is not knowable from the lockfile name. Berry first, classic as the fallback.
    "elif [ -f yarn.lock ]; then corepack enable >/dev/null 2>&1 || true; yarn install --immutable @YARN@ || yarn install --frozen-lockfile @FLAGS@;",
    "elif [ -f package-lock.json ]; then npm ci @FLAGS@;",
    "elif [ -f package.json ]; then npm install --no-audit --no-fund @FLAGS@;",
    "else echo '[warm] no lockfile and no package.json at the repository root; nothing to install'; fi",
  ])

  # THE SNAPSHOT'S INSTALL RUNS NO LIFECYCLE SCRIPTS. It is unpacked as root on
  # every host in the pool, and install-time scripts are the cheapest place to
  # put code in someone else's build.
  install_scriptfree = replace(replace(local.install_ladder, "@FLAGS@", "--ignore-scripts"), "@YARN@", "--mode=skip-build")

  # THE BUILD'S INSTALL DOES run them, and that is not an inconsistency. This step
  # exists to run the repository's build — arbitrary code from the default branch,
  # by definition — so refusing its lifecycle scripts buys nothing and stops most
  # workspaces from building at all, which was the single most common reason a
  # consumer had to override anything here.
  #
  # It re-installs rather than inheriting the step above because the publishing
  # script stages the package stores under `mktemp -d`, and only `/workspace`
  # survives between Cloud Build steps. With npm that is invisible; pnpm's
  # `node_modules` is a tree of links INTO that store, so the build would open a
  # workspace whose every dependency dangles, fail, and leave the turbo prefix
  # empty — silently. One extra install a night is the cheaper side of that.
  install_full = replace(replace(local.install_ladder, "@FLAGS@", ""), "@YARN@", "")

  # Escaped for the same reason the scripts are, and a repository's OWN override
  # is escaped too: a `build_command` holding `$(git rev-parse HEAD)` or a plain
  # `$HOME` is not an unreasonable thing to write, and unescaped it takes the
  # whole warmer down at fire time rather than in the plan that accepted it.
  prepare_command = replace(coalesce(var.prepare_command, local.install_scriptfree), "$", local.escape_dollars)

  # `--cache-dir` is passed from the same variable the publishing step reads, so
  # the two cannot drift. The old default relied on turbo's own default matching
  # whatever `--cache-dir` the repository's CI happened to pass; when it did not,
  # the warm published an empty directory and reported success.
  #
  # The `;` is load-bearing and is asserted by the self-test: the ladder ends in
  # `fi`, and `fi npx …` is a syntax error the whole build step dies on before
  # anything runs — a green apply, a red nightly build, an empty cache.
  build_command = replace(coalesce(var.build_command, join(" ", [
    "${local.install_full};",
    "npx --no-install turbo run build --cache-dir=\"$WARM_TURBO_DIR\"",
  ])), "$", local.escape_dollars)

  # WHO FIRES THE TRIGGER IS A DIFFERENT IDENTITY FROM WHO RUNS THE BUILD, and
  # this is not symmetry for its own sake. `cloudbuild.builds.create` — the
  # permission a scheduler needs to fire anything — has no resource-level
  # binding for a single trigger: the narrowest grant that fires THIS build also
  # fires every other trigger in the project, and in these projects that
  # includes ci-runner-apply-trigger, which runs terraform as an account with
  # real authority. Held by the warmer, that permission would be reachable by
  # the repository's own dependency tree (see WHAT THIS DOES NOT PROTECT
  # AGAINST), and the honest bound above — create-only, two prefixes, one bucket
  # — would simply not be true.
  scheduler_email = coalesce(var.scheduler_service_account, try(google_service_account.firer[0].email, ""))
}

resource "google_service_account" "warmer" {
  project = var.project_id
  # 30 characters is the cap; `-warm` costs five, so the base is VALIDATED to 25
  # rather than truncated to it. Truncation is the silent failure: two pools
  # whose ids differ only after the 25th character would resolve to one account
  # holding both prefixes' grants.
  account_id   = "${var.account_id}-warm"
  display_name = "CI cache warmer (${var.pool_name})"
  description  = "Builds ${var.github_owner}/${var.github_repo}@${var.branch} on a schedule and publishes the dependency snapshot and the Turborepo artifacts the ${var.pool_name} pool reads. Must NEVER be attached to a host, which executes pull-request code."
}

# It holds nothing but the right to fire the trigger and to act as the warmer,
# and it runs no code at all — nothing in this build ever presents it.
resource "google_service_account" "firer" {
  count = var.scheduler_service_account == null ? 1 : 0

  project      = var.project_id
  account_id   = "${var.account_id}-fire"
  display_name = "CI cache warmer scheduler (${var.pool_name})"
  description  = "Fires ${local.trigger_name} on a schedule and nothing else. Separate from the warmer because firing a trigger cannot be scoped to one trigger, and the warmer runs the repository's own dependency code."
}

# --- what it may write --------------------------------------------------------

resource "google_storage_bucket_iam_member" "warmer_creates_turbo_artifacts" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-repositorys-build-cache"
    description = "Create objects under ${local.turbo_prefix} only. Create and not delete: a turbo hash names the digest of its inputs, so a name is only ever written once and an attempt to replace one is a 403 rather than a generation aged zero that outlives the bucket's age bound."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.turbo_prefix}\")"
  }
}

# Read, so the warmer can tell an artifact it has already published from one it
# has not and skip the upload. Viewer carries no create and no delete, so this
# widens nothing the grant above did not already decide.
resource "google_storage_bucket_iam_member" "warmer_reads_turbo_artifacts" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-repositorys-build-cache"
    description = "Read objects under ${local.turbo_prefix} only."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.turbo_prefix}\")"
  }
}

# The snapshot half. Identical in shape and in reasoning to
# ci-runner-cache-publisher's grants, because it is the same write against the
# same prefix by a different identity — see that module's header for why the
# authority to create and the authority to replace the pointer are two
# resources rather than one objectAdmin.
resource "google_storage_bucket_iam_member" "warmer_creates_snapshots" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-pools-cache-prefix"
    description = "Create objects under ${local.cache_prefix} only. No other pool's snapshots, and nothing outside the cache tree."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.cache_prefix}\")"
  }
}

resource "google_storage_bucket_iam_member" "warmer_reads_snapshots" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-pools-cache-prefix"
    description = "Read objects under ${local.cache_prefix} only — the pointer's current generation, before swapping it."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.cache_prefix}\")"
  }
}

# `==` and not `startsWith`, and the difference is the whole point: a prefix
# condition here would hand back the delete authority the split above spent two
# resources removing.
resource "google_storage_bucket_iam_member" "warmer_replaces_pointer" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-pools-current-pointer"
    description = "Replace ${local.cache_prefix}current only. The pointer holds no cache content; the snapshots it names are write-once."
    expression  = "resource.name == \"${local.pointer_resource}\""
  }
}

# A build that names its own service account writes its logs nowhere by default
# and Cloud Build refuses it at submit time. The bucket-free spelling is
# CLOUD_LOGGING_ONLY on the build (below); this grant is what lets the account
# actually write them.
resource "google_project_iam_member" "warmer_writes_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.warmer.email}"
}

# --- where the source comes from ----------------------------------------------

# Registered here rather than required as an input, because a connection is
# authorized once for a whole GitHub account and its repositories are then
# registered one at a time. Skipped when the caller names an existing link:
# registering the same remote twice under one connection is an ALREADY_EXISTS
# error rather than a no-op, and this module and ci-runner-apply-trigger will
# routinely be pointed at the same repository.
resource "google_cloudbuildv2_repository" "repo" {
  count = local.gen2 && var.github_repository == null ? 1 : 0

  project           = var.project_id
  location          = var.region
  name              = lower(replace("${var.github_owner}-${var.github_repo}-warm", "/[^a-zA-Z0-9-]/", "-"))
  parent_connection = local.connection_id
  remote_uri        = "https://github.com/${var.github_owner}/${var.github_repo}.git"
}

# --- the build ----------------------------------------------------------------

# MANUAL, and fired only by the scheduler below. Not a push trigger: warming is
# not a per-commit job. A busy repository would run one of these per merge, each
# one a full install and a full build, to publish artifacts the next one
# recomputes — and the snapshot half would write a new write-once object every
# time, which the bucket's age bound cannot clean up any faster than they arrive.
resource "google_cloudbuild_trigger" "warm" {
  project     = var.project_id
  location    = var.region
  name        = local.trigger_name
  description = "Build ${var.github_owner}/${var.github_repo}@${var.branch} on a schedule and publish the dependency snapshot and Turborepo artifacts for the ${var.pool_name} pool."
  disabled    = var.disabled

  dynamic "source_to_build" {
    for_each = local.gen2 ? [1] : []
    content {
      repository = local.repository_id
      ref        = "refs/heads/${var.branch}"
      repo_type  = "GITHUB"
    }
  }

  dynamic "source_to_build" {
    for_each = local.gen2 ? [] : [1]
    content {
      uri       = "https://github.com/${var.github_owner}/${var.github_repo}.git"
      ref       = "refs/heads/${var.branch}"
      repo_type = "GITHUB"
    }
  }

  service_account = google_service_account.warmer.id

  build {
    timeout = var.build_timeout

    options {
      logging      = "CLOUD_LOGGING_ONLY"
      machine_type = var.machine_type
    }

    # 1. DEPENDENCIES, AND THE SNAPSHOT PACKED BUT NOT PUBLISHED.
    #
    #    This is the publishing script's BUILD phase, and running it here rather
    #    than reimplementing an install is the whole reason the script is shared:
    #    it exports the cache variables the prepare command must honour, stages
    #    exactly the tool directories a host will accept, and applies the same
    #    scan rules the host applies on arrival — so a snapshot a host would
    #    refuse fails here, loudly, once, instead of silently on every boot.
    #
    #    The prepare also leaves the workspace installed, which is what the build
    #    step below needs. Cloud Build carries /workspace between steps; nothing
    #    else survives.
    #
    #    No credential is needed to pack, and the step that runs third-party
    #    install code is deliberately not the step that uploads. That is the same
    #    two-job split the workflow-based publisher documents, mapped onto two
    #    steps — weaker here, because every step in a build can still reach the
    #    metadata server, but the ordering costs nothing and the day Cloud Build
    #    can scope a step's identity this is already the right shape.
    step {
      id         = "dependencies"
      name       = var.build_image
      entrypoint = "bash"
      args       = ["-c", local.publish_script]
      env = [
        "CACHE_PREPARE=${local.prepare_command}",
        "CACHE_ARCHIVE_OUT=/workspace/ci-cache-snapshot.tar.gz",
        "CACHE_MAX_BYTES=${var.snapshot_max_bytes}",
      ]
    }

    # 2. THE BUILD, whose only purpose here is the artifacts it leaves behind.
    #    It is allowed to fail: a default branch that is briefly broken should
    #    not also stop the dependency snapshot from being published, and the
    #    turbo step below simply finds fewer artifacts. The exit code is logged
    #    by Cloud Build either way, so a permanently broken default branch is
    #    still visible.
    #
    #    WARM_TURBO_DIR is the same value the publishing step reads, and the
    #    default build command passes it to turbo as `--cache-dir`: where the
    #    artifacts are written and where they are looked for are one input, not
    #    two that have to be kept equal by whoever wires this up. TURBO_CACHE_DIR
    #    carries the same value to a build_command a repository overrode, which
    #    turbo honours without a flag.
    step {
      id         = "build"
      name       = var.build_image
      entrypoint = "bash"
      args       = ["-c", "${local.build_command} || echo '[warm] build failed; publishing what it produced'"]
      env = [
        "TURBO_TELEMETRY_DISABLED=1",
        "CI=true",
        "WARM_TURBO_DIR=${var.turbo_cache_dir}",
        "TURBO_CACHE_DIR=${var.turbo_cache_dir}",
      ]
    }

    # 3. THE TURBO ARTIFACTS.
    step {
      id         = "publish-turbo"
      name       = var.gcloud_image
      entrypoint = "bash"
      args       = ["-c", local.turbo_script]
      env = [
        "WARM_BUCKET=${var.cache_bucket}",
        "WARM_TURBO_PREFIX=${local.turbo_prefix}",
        "WARM_TURBO_DIR=${var.turbo_cache_dir}",
        "WARM_MAX_BYTES=${var.max_artifact_bytes}",
      ]
    }

    # 4. THE DEPENDENCY SNAPSHOT, published — the same script again, in its
    #    PUBLISH phase, which re-scans the archive it is handed rather than
    #    trusting the phase that produced it. An artifact that crossed a step
    #    boundary is input.
    step {
      id         = "publish-snapshot"
      name       = var.gcloud_image
      entrypoint = "bash"
      args       = ["-c", local.publish_script]
      env = [
        "CACHE_ARCHIVE_IN=/workspace/ci-cache-snapshot.tar.gz",
        "CACHE_POOL=${var.pool_name}",
        "CACHE_BUCKET=${var.cache_bucket}",
        "CACHE_MAX_BYTES=${var.snapshot_max_bytes}",
      ]
    }
  }

  lifecycle {
    precondition {
      # A gen2 project must resolve to a repository link, and an unresolved one
      # is an empty string rather than an error — which applies cleanly and
      # produces a trigger with no source that fails at fire time, hours later,
      # in a log nobody is reading.
      condition     = !local.gen2 || local.repository_id != ""
      error_message = "the warmer for '${var.pool_name}' is configured for a 2nd-generation connection but no repository link resolved: pass github_repository, or let this module register one by leaving it null."
    }
  }
}

# --- the schedule -------------------------------------------------------------

# The only thing that ever fires this trigger. A warmer nobody runs is the cold
# cache this module exists to end, so the schedule is not optional and has no
# "null means never" spelling.
resource "google_cloud_scheduler_job" "warm" {
  project     = var.project_id
  region      = var.region
  name        = "${local.trigger_name}-scheduled"
  description = "Run ${local.trigger_name}. The warmer has no push trigger — this is the only thing that fires it."
  schedule    = var.schedule
  time_zone   = var.schedule_time_zone

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/triggers/${google_cloudbuild_trigger.warm.trigger_id}:run"

    # The branch the trigger already names. `:run` takes a plain branch name and
    # refuses a regex, which is why this module takes the branch as a literal
    # and derives everything else from it.
    body = base64encode(jsonencode({
      source = {
        branchName = var.branch
      }
    }))

    headers = {
      "Content-Type" = "application/json"
    }

    # Cloud Scheduler mints this token through a per-project service agent, so a
    # cross-project account fails at fire time with an error naming the agent
    # rather than the account.
    oauth_token {
      service_account_email = local.scheduler_email
    }
  }

  # A warm that is still running when the next one fires is a warm that is
  # taking longer than its period, not one that needs a second copy competing
  # for the same write-once object names.
  retry_config {
    retry_count = 0
  }

  lifecycle {
    precondition {
      # Same check, same wording, same reason as ci-runner-apply-trigger's: the
      # token is minted by a per-project service agent, so a cross-project
      # account applies cleanly and fails at fire time naming the agent.
      condition     = endswith(local.scheduler_email, "@${var.project_id}.iam.gserviceaccount.com") || can(regex("^[0-9]+-compute@developer\\.gserviceaccount\\.com$", local.scheduler_email))
      error_message = "the warmer's scheduler account must live in ${var.project_id}: Cloud Scheduler mints its token through a per-project service agent, so a cross-project account fails at fire time with an error naming the service agent, not the account."
    }
  }
}

# Firing a trigger is an API call like any other, and the account making it needs
# to be allowed to make it. Left out, the schedule applies cleanly and every fire
# is a 403 in the scheduler's log — a warmer that has never run, reported
# nowhere the cache's readers can see.
#
# It is granted to the FIRER and never to the warmer: the permission cannot be
# scoped to one trigger, so whoever holds it can run every trigger in the
# project — including the one that applies terraform.
resource "google_project_iam_member" "scheduler_runs_the_trigger" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${local.scheduler_email}"
}

# The build runs AS the warmer, so whoever fires it must be allowed to act as
# the warmer. One account, named — not a project-level serviceAccountUser, which
# would be "may act as every account in the project" and is the usual way this
# grant is written.
resource "google_service_account_iam_member" "scheduler_acts_as_warmer" {
  service_account_id = google_service_account.warmer.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.scheduler_email}"
}
