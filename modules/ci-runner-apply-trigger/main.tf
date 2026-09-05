# ci-runner-apply-trigger — the unattended apply, run by the project's OWN
# Cloud Build.
#
# The problem is the one `apply-runner-pool.yml` was written for: a merged
# version bump changes what the NEXT apply will build and changes nothing that
# is running, so a pin that is merged and never applied looks, from outside,
# exactly like a pin that was never bumped. Measured cost, 2026-08-15: v5.7.0
# merged into nine repositories the same day and reached one pool.
#
# WHY THIS EXISTS ALONGSIDE THAT WORKFLOW, which is the whole argument for the
# module: the GitHub Actions path has to get a credential from GitHub into
# Google, and the only sound way to do that is workload identity federation —
# a pool, a provider, an attribute mapping, and a service account bound to a
# principalSet. Every one of those is a thing to configure correctly per
# repository, and the account at the end of it is, by construction,
# ASSUMABLE FROM A WORKFLOW FILE. Everything it can do, a `.github/workflows`
# file can do. That is not a flaw in the workflow; it is what federation means.
#
# Cloud Build runs INSIDE the project. There is no federation, no provider, no
# principalSet, and no externally-assumable account — an entire trust boundary
# stops existing rather than being defended. The push that triggers it is
# observed by the GitHub App connection the project already uses to deploy
# every one of its services. Nothing here is a new mechanism for these projects;
# it is the mechanism they already run their CD on, pointed at their own infra.
#
# WHAT THIS MODULE DELIBERATELY DOES NOT DO: create a service account.
#
# It takes `service_account` as a required input and mints nothing. A module
# that creates the identity its own builds run as is a module that decides its
# own privileges, and the decision lands in whatever apply happens to run it.
# The projects this targets already have a CD service account, already reviewed,
# already used by every other trigger in the project — and, where it has been
# checked, already WITHOUT `serviceAccountAdmin` or `projectIamAdmin`. That
# matters more than the saved resource: it is the same property
# `ci-runner-apply-identity` was built to construct. An apply that changes
# compute succeeds; an apply that would change an identity stops red, naming
# the resource, and a human runs that one. Preserved here for free, by reusing
# an account that already cannot escalate, instead of granting anything new.
#
# The reviewer's obligation, therefore, moves rather than disappearing:
# `service_account` is the security decision of this module, and the checklist
# for it is in docs/applying-runner-infra.md.
#
# THE BUILD IS INLINE, not a `cloudbuild.*.yaml` in the consumer repository, and
# for the same reason there is one reusable workflow instead of nine copies:
# nine repositories carrying nine copies of the same apply steps is nine places
# for a fix to land and eight places for it to be forgotten. The steps below
# reproduce `apply-runner-pool.yml` deliberately — init -upgrade, a plan that is
# printed, an apply of the SAVED plan, and a report that an apply is not the
# same thing as in effect.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

locals {
  # One literal branch in, both spellings derived. The push filter takes a
  # REGEX and the triggers.run API refuses one ("Branch and tag names cannot
  # consist of regular expressions"), so a module taking both as inputs has a
  # state where the schedule fires on a branch the trigger does not watch —
  # silently, because each field is individually valid. Deriving them makes
  # that state unreachable.
  branch_regex = "^${var.branch}$"

  trigger_name = coalesce(var.name, "ci-runner-apply-${lower(replace(var.github_repo, "_", "-"))}")

  # The root's own tree, plus anything the caller names. Scoped rather than
  # firing on every commit: this trigger takes a terraform state lock, and a
  # busy repository would queue applies behind each other all day to discover
  # each time that nothing changed.
  included_files = concat(["${trim(var.terraform_root, "/")}/**"], var.extra_included_files)

  # 2nd gen if the project has a connection, 1st gen otherwise. Not a preference
  # and not a migration: it is a read of what the project already has. See the
  # `github_connection` description — the two are separate APIs, and a trigger
  # built against the generation the project does NOT use is created without
  # complaint and never fires.
  gen2 = var.github_connection != null

  # A bare name or a full resource id, both accepted, so a caller holding
  # `google_cloudbuildv2_connection.x.id` can pass it straight through without
  # slicing the last segment off it.
  connection_id = local.gen2 ? (
    startswith(coalesce(var.github_connection, ""), "projects/")
    ? var.github_connection
    : "projects/${var.project_id}/locations/${var.region}/connections/${var.github_connection}"
  ) : null

  repository_id = local.gen2 ? coalesce(var.github_repository, try(google_cloudbuildv2_repository.repo[0].id, "")) : null

  # The alerting script, carried into the build rather than fetched at build
  # time. Same construction as ci-runner-cache-warmer: ONE copy in
  # scripts/ci/, embedded from there, so the build cannot run a version that
  # drifted from the one CI tests. A `curl` of the raw file would be the other
  # option and is strictly worse — it makes every apply depend on github.com
  # being reachable from inside the project, and it runs whatever that URL
  # serves at the moment of the build rather than what this module was pinned
  # to.
  alert_script_gz = base64gzip(file("${path.module}/../../scripts/ci/ensure-alert-policies.sh"))

  # Hoisted out of the step so the precondition on the trigger can MEASURE it.
  # Inline in the resource it was unmeasurable, and unmeasurable is how a 25 KB
  # blob sat in a 10,000-character argument through a review and an apply.
  alert_step_script = <<-EOT
    #!/usr/bin/env bash
    set -u
    printf '%s' '${local.alert_script_gz}' | base64 -d | gzip -d > /workspace/ensure-alert-policies.sh
    chmod +x /workspace/ensure-alert-policies.sh
    rc=0
    bash /workspace/ensure-alert-policies.sh --project '${var.project_id}' ${local.alert_flags} || rc=$?
    if [ "$rc" = "0" ]; then
      echo "alert policies: this project matches the fleet set"
    else
      echo "WARNING: could not bring the alert policies up to date (exit $rc)."
      echo "This does NOT fail the apply. The usual cause is that the build"
      echo "account lacks roles/monitoring.alertPolicyEditor and"
      echo "roles/monitoring.notificationChannelEditor in this project; the"
      echo "other is a project with no email notification channel yet, which"
      echo "needs one manual run with --email <addr> to bootstrap."
    fi
  EOT

  # Only the flags the caller actually set. The script's own defaults mirror the
  # ci-runner-host-pool defaults, so a pool that has not overridden anything
  # wants NO flags here — passing the numbers again from a second place is how
  # the two fall out of step.
  alert_flags = join(" ", compact([
    var.alert_notification_email == null ? "" : "--email '${var.alert_notification_email}'",
    var.alert_poll_interval_seconds == null ? "" : "--poll-interval-seconds ${var.alert_poll_interval_seconds}",
    var.alert_register_grace_seconds == null ? "" : "--register-grace-seconds ${var.alert_register_grace_seconds}",
    var.alert_drain_grace_seconds == null ? "" : "--drain-grace-seconds ${var.alert_drain_grace_seconds}",
    var.alert_cache_stale_hours == null ? "" : "--cache-stale-hours ${var.alert_cache_stale_hours}",
    # Repeated once per pool rather than a comma list: the script validates each
    # name on its own, so a bad one names itself instead of failing the batch.
    join(" ", [for p in var.alert_muted_pools : "--muted-pool '${p}'"]),
  ]))
}

# Registered here rather than required as an input, because a connection is
# authorized once for a whole GitHub account and its repositories are then
# registered one at a time — so for a project that HAS a connection, this is the
# only remaining step, and requiring it as a prerequisite would put a manual
# action back in the path the connection was supposed to remove.
#
# Skipped when the caller names an existing one: registering the same remote
# twice under one connection is an ALREADY_EXISTS error rather than a no-op, and
# a second root onboarding the same repository would otherwise fail on a
# resource it did not know had been created.
resource "google_cloudbuildv2_repository" "repo" {
  count = local.gen2 && var.github_repository == null ? 1 : 0

  project  = var.project_id
  location = var.region
  # Every character GitHub allows in a repository name that a Google resource id
  # does not — `_` and `.` are both common and both rejected. Folded rather than
  # validated against, because the input is a real repository name the caller
  # cannot change: `Some_Repo.v2` is a legal remote and an illegal resource id.
  name              = lower(replace("${var.github_owner}-${var.github_repo}", "/[^a-zA-Z0-9-]/", "-"))
  parent_connection = local.connection_id
  remote_uri        = "https://github.com/${var.github_owner}/${var.github_repo}.git"
}

resource "google_cloudbuild_trigger" "apply" {
  project     = var.project_id
  location    = var.region
  name        = local.trigger_name
  description = "Unattended terraform apply of ${var.terraform_root} on push to ${var.branch}. Runner infra: a merged module pin only reaches machines when something applies it."
  disabled    = var.disabled

  # Exactly one of these exists per trigger — `dynamic` with a 0/1 iterator is
  # the terraform spelling of "this block, conditionally", and both are written
  # that way so neither reads as the special case.
  dynamic "github" {
    for_each = local.gen2 ? [] : [1]
    content {
      owner = var.github_owner
      name  = var.github_repo
      push {
        branch = local.branch_regex
      }
    }
  }

  dynamic "repository_event_config" {
    for_each = local.gen2 ? [1] : []
    content {
      repository = local.repository_id
      push {
        branch = local.branch_regex
      }
    }
  }

  included_files = local.included_files
  ignored_files  = var.ignored_files

  # The account this runs as — an input, never created here. See the header.
  service_account = "projects/${var.project_id}/serviceAccounts/${var.service_account}"

  build {
    timeout = var.build_timeout

    # Not a default, and not optional: a build that names its own service
    # account has no default log destination, and Cloud Build REFUSES it at
    # submit time rather than running it and dropping the logs. The failure is
    # legible enough ("build.service_account requires ... logging") but it
    # arrives on the first push, which is the worst moment to learn it.
    options {
      logging = "CLOUD_LOGGING_ONLY"
    }

    # -upgrade, not a plain init. A consumer pinning the floating major (?ref=v5)
    # has no diff when v5.7.1 ships; a plain init keeps whatever it resolved
    # last and would re-apply the same module forever, reporting success every
    # time. Cloud Build starts each build on a fresh workspace, so this is
    # belt-and-braces here — and it is the line that would matter the day a
    # cache is introduced, which is exactly when nobody re-reads this file.
    #
    # `backend_config` is appended because not every root bakes its backend into
    # `backend.tf`. Two of the Specaria-owned roots deliberately leave the state
    # bucket out of the file — it is a vendor resource, not a customer literal,
    # and keeping it out is what lets the same root serve more than one estate —
    # and supply it at init with `-backend-config=bucket=...`. Against a root
    # like that a bare `terraform init` does not fail in a way anybody would
    # connect to this module. The observed message — recorded in
    # docs/onboarding-a-repository.md from the manual init that hits the same
    # wall — is "querying Cloud Storage failed: storage: bucket doesn't exist",
    # which reads as a deleted or misnamed bucket rather than as one that was
    # never passed. Empty by default, so a root that does bake its bucket in is
    # unchanged.
    step {
      id         = "init"
      name       = "hashicorp/terraform:${var.terraform_version}"
      entrypoint = "terraform"
      dir        = var.terraform_root
      args = concat(
        ["init", "-input=false", "-upgrade"],
        [for k in sort(keys(var.backend_config)) : "-backend-config=${k}=${var.backend_config[k]}"],
      )
    }

    # Separate from the apply so the log shows what was ABOUT to change even
    # when the apply then fails. A failed apply with no plan above it says only
    # that something went wrong.
    #
    # The marker file carries the "there are changes" answer to the next step:
    # Cloud Build steps have no conditionals, so the decision has to be data on
    # the shared workspace rather than control flow.
    step {
      id         = "plan"
      name       = "hashicorp/terraform:${var.terraform_version}"
      entrypoint = "sh"
      dir        = var.terraform_root
      args = ["-c", <<-EOT
        set -u
        terraform plan -input=false -lock-timeout=${var.lock_timeout} -detailed-exitcode -out=tf.plan
        rc=$?
        case "$rc" in
          0) echo "no changes — nothing to apply"; rm -f /workspace/.apply-pending ;;
          2) echo "changes pending"; : > /workspace/.apply-pending ;;
          *) echo "terraform plan failed (exit $rc)"; exit "$rc" ;;
        esac
      EOT
      ]
    }

    # Applies the SAVED plan, never a re-planned one: between plan and apply a
    # floating tag can move, and applying something nobody printed is the
    # failure mode this whole arrangement exists to remove.
    step {
      id         = "apply"
      name       = "hashicorp/terraform:${var.terraform_version}"
      entrypoint = "sh"
      dir        = var.terraform_root
      args = ["-c", <<-EOT
        set -eu
        if [ ! -f /workspace/.apply-pending ]; then
          echo "plan reported no changes — skipping apply"
          exit 0
        fi
        terraform apply -input=false -lock-timeout=${var.lock_timeout} tf.plan
      EOT
      ]
    }

    # `terraform output` needs terraform, and the step that reads the instance
    # group needs gcloud — no image on either side of this repository has both.
    # So the value crosses on the workspace rather than the tool crossing into
    # the wrong image. This is the failure that would have looked like a broken
    # summary and been "fixed" by dropping the report: `terraform: not found`,
    # in a step whose whole job is to print a sentence.
    #
    # Never fatal. A root with no `mig_name` output is a root this module can
    # still apply.
    step {
      id         = "mig-name"
      name       = "hashicorp/terraform:${var.terraform_version}"
      entrypoint = "sh"
      dir        = var.terraform_root
      args = ["-c", <<-EOT
        set -u
        terraform output -raw mig_name > /workspace/.mig-name 2>/dev/null || : > /workspace/.mig-name
      EOT
      ]
    }

    # The managed instance group updates OPPORTUNISTICally: a new instance
    # template does NOT replace running hosts, so an apply that "succeeded" can
    # leave every host on the previous startup script until the controller
    # drains them on idleness. Reporting the gap is the difference between
    # "applied" and "in effect", and it is the sentence most often misread.
    #
    # Best-effort by design — it reports, it does not gate. A root with no
    # `mig_name` output still gets a successful apply, because failing here
    # would report "the apply failed" over a missing summary.
    step {
      id         = "report"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "sh"
      args = ["-c", <<-EOT
        set -u
        echo "Hosts do not restart on an apply. The group replaces them opportunistically,"
        echo "as the controller drains idle ones, so until that happens they keep running"
        echo "the PREVIOUS startup script — an apply is not the same thing as in effect."
        mig=$(cat /workspace/.mig-name 2>/dev/null || true)
        if [ -z "$mig" ]; then
          echo "Hosts currently up: (no mig_name output in this root — not counted)"
          exit 0
        fi
        # gcloud's success is tested separately from the count: `grep -c` exits
        # 1 on zero matches, so folding them together would report a genuinely
        # empty pool as "could not read" — the reading that sends somebody to
        # debug credentials over a pool sitting at min_hosts=0.
        if out=$(gcloud compute instance-groups managed list-instances "$mig" \
                   --region='${var.region}' --project='${var.project_id}' --format='value(name)' 2>/dev/null); then
          echo "Hosts currently up: $(printf '%s' "$out" | grep -c . || true)"
        else
          echo "Hosts currently up: (could not read the instance group)"
        fi
      EOT
      ]
    }

    # The alert policies, brought up to the fleet's set on every apply.
    #
    # WHY THIS IS A BUILD STEP AND NOT A RUNBOOK LINE: it was a runbook line,
    # and the measurement is in issue #531. `ensure-alert-policies.sh` was the
    # only thing that ever created these policies and nothing called it, so what
    # a project had was whatever an operator last remembered to run there. On
    # 2026-08-29, of the ten pool projects, three were current, three were two
    # policies behind under their old names, and FOUR HAD NONE AT ALL — no
    # controller-dead alert, no drain-failing alert, no host-went-away alert.
    # That is the opposite failure from an alert flood and it is the more
    # expensive one, because a project with no policies looks exactly like a
    # project with nothing wrong.
    #
    # It runs here, in the trigger that already holds project-scoped
    # credentials, rather than in the daily GitHub audit — which would need a
    # workload identity federation provider and a monitoring account per
    # project, i.e. the IAM surface this module's header explains it will not
    # create.
    #
    # BEST-EFFORT, DELIBERATELY, and this is the load-bearing decision. The
    # account is the project's existing CD account, chosen because it CANNOT
    # escalate; monitoring.alertPolicies is not among the things it can
    # necessarily do. Failing the build on that would turn "your alerting is one
    # policy behind" into "your infrastructure apply is red", in every project
    # that has not been granted the role — a red build over a warning, which is
    # how a fleet learns to ignore red builds. So it prints what to grant and
    # exits 0.
    #
    # AND IT CARRIES ITS SCRIPT IN `script`, NEVER IN `args`. A build step
    # ARGUMENT is capped at 10,000 characters; `script` has no such cap. The
    # blob below is ~25 KB, so as an argument it made every build the trigger
    # fired invalid — and the refusal happens at FIRE time, not at apply time,
    # so terraform is green, the trigger exists, and each build dies in under a
    # second with
    #
    #   invalid build: invalid .steps field: build step 5 arg 1 too long
    #   (max: 10000)
    #
    # which no amount of escaping fixes. That is not a hypothetical: it shipped,
    # and for as long as it was live NOTHING in the fleet applied. Every project
    # in it kept whatever runner configuration it had when the step landed, and
    # the failure is invisible from GitHub — the commit merges, the check-run
    # sits `queued`, and the pins look delivered. `ci-runner-cache-warmer` hit
    # this same cap first and its header records the same three limits; this
    # step was written afterwards and reintroduced the one it warns about.
    #
    # Setting `entrypoint` beside `script` is an error, so this step has none.
    # `script` honours the shebang, which is why there is one.
    dynamic "step" {
      for_each = var.manage_alert_policies ? [1] : []
      content {
        id     = "alert-policies"
        name   = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
        script = local.alert_step_script
      }
    }
  }

  # THE OTHER CLIFF, TURNED INTO A PLAN FAILURE.
  #
  # The 10,000-character ARGUMENT cap is now prevented by construction — the one
  # step with an unbounded body carries it in `script`, which has no cap. What
  # `script` does NOT escape is the whole-build size limit `ci-runner-cache-warmer`
  # measured: past roughly 128 KiB Cloud Build accepts the build, hands back an
  # id, and never schedules it. No BUILD phase, no log, no error, until the queue
  # TTL expires.
  #
  # Both failures are invisible from the outside — the trigger exists, terraform
  # is green, the merge looks delivered, and the runner configuration silently
  # stops reaching any machine. So the growing input is measured here, where
  # somebody is reading the output. `ensure-alert-policies.sh` is the input that
  # grows; every other step in this build is a fixed handful of lines.
  # It binds only when the step is actually in the build. `local.alert_step_script`
  # is computed either way — a local has no `count` — so an unconditional guard
  # would fail the plan of a root that opted OUT of the step, over the size of a
  # body its build does not contain. The measurement is of what ships, not of
  # what was rendered.
  #
  # 100000 rather than 131072 because the guard's job is to be hit while there is
  # still somewhere to go: the cliff is the size of the WHOLE build config, and
  # this local is only its largest part. The ~28 KiB of headroom is the rest of
  # the steps, the substitutions and the options — which grow too, and which no
  # single number here can see.
  lifecycle {
    precondition {
      condition     = !var.manage_alert_policies || length(local.alert_step_script) < 100000
      error_message = "the alert-policies step is ${length(local.alert_step_script)} bytes of embedded script. Cloud Build silently never schedules a build once the whole config passes roughly 128 KiB — it fetches source, finishes SETUPBUILD, and sits with every step QUEUED until the queue TTL expires, with no error anywhere. This guard trips at 100000 to leave room for the rest of the config, which is why the number is lower than the cliff. Fetch ensure-alert-policies.sh from a bucket at build time instead of embedding it, or split the policies across steps."
    }
  }
}

# --- the run nothing pushes -----------------------------------------------------
#
# THE TRIGGER ABOVE CANNOT DELIVER A RELEASE ON ITS OWN, and this is the half
# that is easy to leave out because everything looks green without it.
#
# A consumer pinning `?ref=v5` has NO DIFF when v5.7.1 ships. Nothing is pushed,
# so a push trigger never fires, and the release sits in the tag forever. The
# schedule is what makes "follow the floating major" mean anything at all — it
# is not a redundant safety net over the push, it is the only path for the
# release the push cannot see.
#
# Optional, and off by default, for one honest reason: creating this job needs
# `cloudscheduler.jobs.create`, which a compute-scoped CD account does not have.
# Leaving it on by default would make the FIRST apply of this module fail on
# every project in the fleet, and a module whose default configuration cannot
# apply teaches people to skim the error. Turn it on with the role in hand;
# docs/applying-runner-infra.md names it.
resource "google_cloud_scheduler_job" "daily_apply" {
  count = var.apply_schedule == null ? 0 : 1

  project     = var.project_id
  region      = var.region
  name        = "${local.trigger_name}-scheduled"
  description = "Run ${local.trigger_name} on a schedule. A consumer pinning a floating module tag has no commit to push when a new version ships, so this is the only trigger that ever fires for it."
  schedule    = var.apply_schedule
  time_zone   = var.schedule_time_zone

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/triggers/${google_cloudbuild_trigger.apply.trigger_id}:run"

    # A LITERAL branch, derived from the same input as the push regex above.
    # The API rejects a regex here, and `^main$` as a branch name resolves to
    # nothing — see local.branch_regex.
    body = base64encode(jsonencode({
      projectId = var.project_id
      triggerId = google_cloudbuild_trigger.apply.trigger_id
      source    = { branchName = var.branch }
    }))

    headers = {
      "Content-Type" = "application/json"
    }

    # An OAuth token, not OIDC: this calls a Google API, which authenticates
    # access tokens. The scope is the only one cloudbuild.googleapis.com
    # accepts. The Cloud Scheduler service agent's ability to mint this token
    # comes from roles/cloudscheduler.serviceAgent, granted automatically when
    # the API is enabled — which is why the account must live in THIS project
    # (validated in variables.tf) rather than being any account that happens to
    # have build permissions.
    oauth_token {
      service_account_email = coalesce(var.scheduler_service_account, var.service_account)
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  # A missed run is not worth retrying hard. The next tick is at most a day
  # away, and a build that failed because terraform held a lock will fail the
  # same way three minutes later — retries here turn one red build into four.
  retry_config {
    retry_count = 1
  }

  # STATED, BECAUSE A PAUSE IS OTHERWISE INVISIBLE TO EVERY APPLY THAT FOLLOWS.
  #
  # `paused` is optional, and omitting it does not mean "running" — it means
  # terraform has no opinion, so a job paused by hand stays paused through every
  # subsequent apply and no plan ever shows a diff. Nothing else notices either:
  # the job still exists, the trigger still exists, the console shows both, and
  # the only symptom is a release that stops arriving.
  #
  # Measured: `ci-runner-apply-integrateit-scheduled` was paused by hand at
  # 2026-09-02T16:18Z, after twelve consecutive green hourly applies. For two
  # days after that, that project received no runner infrastructure at all —
  # including the fix for the false "controller dead" alert that project itself
  # had raised. The controller reported it correctly the whole time
  # (`ci_apply_build_missing = 1`, which is what the "stopped receiving runner
  # infrastructure" policy watches); what was missing was any path back. This
  # line is that path: the next apply from ANY source — a push to the root, a
  # manual run — resumes the schedule instead of preserving the pause.
  #
  # It also makes the pause a decision with a name on it. Silencing this job for
  # real maintenance is now a commit, not a click — a click is undone by the next
  # apply that touches this resource, whenever that is. How soon depends on the
  # root: a push to it applies immediately, and `var.apply_schedule` may be
  # hourly or weekly. What the pause can no longer do is outlive every apply.
  paused = false

  # Cross-variable, so it cannot be a `validation` block on either one — and it
  # only has to hold when the job is actually created, which a precondition on
  # this resource expresses exactly.
  #
  # Cloud Scheduler mints the OAuth token through its own per-project service
  # agent. An account in another project is accepted by terraform, accepted by
  # the API, and then fails at every fire with a permission error naming the
  # service agent rather than the account — a message that sends the reader to
  # the wrong project.
  #
  # The default compute account is the one shape this cannot prove. Its email
  # carries the project NUMBER, not the project id, and resolving one to the
  # other needs a `google_project` data source — a read this module does not
  # otherwise perform, and adding it would make every already-working consumer
  # depend on a permission it has never needed. So that shape is accepted on its
  # form alone, and the residual gap is real and small: passing ANOTHER
  # project's default compute account gets through here and fails at fire time
  # with exactly the service-agent error this precondition exists to pre-empt —
  # which the message below already explains.
  lifecycle {
    precondition {
      condition     = endswith(coalesce(var.scheduler_service_account, var.service_account), "@${var.project_id}.iam.gserviceaccount.com") || can(regex("^[0-9]+-compute@developer\\.gserviceaccount\\.com$", coalesce(var.scheduler_service_account, var.service_account)))
      error_message = "The scheduler's account must live in ${var.project_id}: Cloud Scheduler mints its token through a per-project service agent, so a cross-project account fails at fire time with an error naming the service agent, not the account."
    }
  }
}
