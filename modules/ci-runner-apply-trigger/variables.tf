variable "project_id" {
  type        = string
  description = "Project holding both the Cloud Build trigger and the runner pool it applies."
}

variable "region" {
  type        = string
  description = "Region for the trigger, the scheduler job, and the instance-group lookup in the report step. Cloud Build triggers are REGIONAL — a trigger created in one region is invisible to `gcloud builds triggers list` run against another, which reads as 'the trigger was never created'."
}

variable "github_owner" {
  type        = string
  description = "GitHub owner of the repository holding the terraform root."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name. The project's GitHub connection must already cover it — this module wires a trigger, it does not authorize a GitHub account."
}

variable "github_connection" {
  type        = string
  default     = null
  description = <<-EOT
    Name of an EXISTING 2nd-gen Cloud Build connection in this project and region, e.g. `<project>-github`. Null (the default) means the project links repositories the 1st-gen way, through the Cloud Build GitHub App, and the trigger is built with a `github {}` block.

    THE TWO GENERATIONS ARE DIFFERENT APIS, NOT A VERSION FLAG. A 1st-gen trigger names owner/repo directly and resolves them against a project-level GitHub App install; a 2nd-gen trigger names a `google_cloudbuildv2_repository` resource under a connection. Neither block works against the other's link, and the failure is not a validation error — it is a trigger that is created successfully and never fires, because the push it is watching for arrives on a link it cannot see.

    Which one a project has is a fact about the project, discovered rather than chosen (`gcloud builds connections list --project=<p> --region=<r>`, PER REGION — 2nd-gen connections are regional and a region-less list returns [] for a project that has several).

    Full resource names are accepted as well as bare names, so `google_cloudbuildv2_connection.x.id` can be passed straight through.
  EOT
}

variable "github_repository" {
  type        = string
  default     = null
  description = <<-EOT
    Full resource name of an EXISTING `google_cloudbuildv2_repository` under `github_connection` — `projects/p/locations/r/connections/c/repositories/x`. Only read when `github_connection` is set.

    Null (the default) registers the repository under the connection instead. That is the common case: a connection is authorized once for a whole GitHub account, and the individual repositories under it are usually registered per trigger. Set this when the repository is already registered — by another root, or by hand — because registering the same remote twice under one connection is an ALREADY_EXISTS error, not a no-op.
  EOT

  validation {
    condition     = var.github_repository == null || can(regex("^projects/[^/]+/locations/[^/]+/connections/[^/]+/repositories/[^/]+$", coalesce(var.github_repository, "x")))
    error_message = "github_repository must be a full resource name: projects/<project>/locations/<region>/connections/<connection>/repositories/<name>."
  }
}

variable "terraform_root" {
  type        = string
  description = "Path to the runner terraform root, from the repository root. Also becomes the trigger's included-files scope, so a push elsewhere in the repo does not queue an apply behind a state lock."

  validation {
    condition     = !startswith(var.terraform_root, "/") && !strcontains(var.terraform_root, "..")
    error_message = "terraform_root is a path INSIDE the repository, relative to its root (e.g. customer/<customer>/terraform/ci-runner-hosts). A leading slash or a .. segment escapes the workspace."
  }
}

variable "backend_config" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Extra `-backend-config=<key>=<value>` pairs for the build's `terraform init`. Empty by default, which is right for any root that names its backend fully in `backend.tf`.

    Set it for a root that deliberately does not. The Specaria-owned CI roots keep the state bucket out of `backend.tf` because it is a vendor resource rather than a customer literal, and pass it at init time — and against such a root a bare `terraform init` fails with "querying Cloud Storage failed: storage: bucket doesn't exist", which reads as a deleted bucket rather than as one that was never passed.

    NOT a place for a secret. Every value here is rendered into the trigger's build config, which is readable by anyone with `cloudbuild.builds.get` and is printed in the build log.
  EOT

  # A key with an `=` in it would produce `-backend-config=a=b=c`, which
  # terraform parses as the value `b=c` for key `a` — accepted, wrong, and
  # invisible until the state lands somewhere nobody looks for it.
  validation {
    condition     = alltrue([for k in keys(var.backend_config) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))])
    error_message = "backend_config keys are terraform backend attribute names (letters, digits and underscores). A key containing '=' silently changes which attribute is set."
  }

  # The paragraph above says "not a place for a secret", and a paragraph is not
  # a control. Every backend has a credential attribute sitting right next to
  # the bucket in its own documentation, so reaching for one here is the
  # obvious next step rather than a careless one — and it is unrecoverable in
  # the quiet way: the value lands in the trigger's stored build config AND in
  # every build log, both of which are readable by every builds.get holder and
  # neither of which is anybody's idea of a secret store. Nothing goes red, so
  # the leak is found by whoever reads a log for an unrelated reason.
  #
  # The build already has an identity — var.service_account — and that is the
  # supported way to authorize the backend. `impersonate_service_account` is
  # deliberately NOT in this list: it names an identity, it does not carry one.
  validation {
    condition = length(setintersection(
      toset([for k in keys(var.backend_config) : lower(k)]),
      toset(["credentials", "access_token", "encryption_key", "secret_key", "access_key", "token", "password", "client_secret", "sas_token"]),
    )) == 0
    error_message = "backend_config must not carry a credential — it is rendered into the trigger's build config and printed in the build log, neither of which is a secret store. The build authenticates to the backend as var.service_account; grant that account access to the state bucket instead."
  }
}

variable "service_account" {
  type        = string
  description = <<-EOT
    Email of the EXISTING account the build runs as. This module creates no identity, by design — see the header of main.tf.

    THE ONE SECURITY DECISION IN THIS MODULE. It should be the project's existing CD account, and it should NOT hold roles/iam.serviceAccountAdmin or roles/resourcemanager.projectIamAdmin: an account that can apply the runner root END TO END can grant itself owner, and a compute-scoped account instead stops red on the rare apply that changes an identity, which is the intended behaviour and not a gap.
  EOT

  # The job here is to reject a RESOURCE NAME — `projects/p/serviceAccounts/x` —
  # because the resource name is built from this value and a doubled prefix
  # fails at apply with a message about a malformed path rather than about the
  # input that produced it.
  #
  # The first spelling of it also rejected the DEFAULT COMPUTE account, which is
  # a legal service account with a different shape: a numeric prefix, and
  # `developer.gserviceaccount.com` rather than `<project>.iam.`. That was an
  # accident of writing the pattern from the one example to hand, and it is not
  # a security control standing in for a role check — a project whose CD runs as
  # its default compute account typically holds compute.instanceAdmin.v1 and
  # cloudscheduler.admin and neither serviceAccountAdmin nor projectIamAdmin,
  # which is exactly the shape this module asks for. A validation that rejects
  # a correct input teaches the reader to work around the validation.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.service_account)) || can(regex("^[0-9]+-compute@developer\\.gserviceaccount\\.com$", var.service_account))
    error_message = "service_account must be a service account EMAIL — name@project.iam.gserviceaccount.com, or <number>-compute@developer.gserviceaccount.com for a project's default compute account — not a full projects/.../serviceAccounts/... resource name, which is built from it."
  }
}

variable "branch" {
  type        = string
  default     = "main"
  description = "The branch whose pushes apply, as a LITERAL name. The push filter's regex and the scheduled run's branch are both derived from it; the run API rejects a regex, so taking one input removes the state where the schedule fires on a branch the trigger does not watch."

  validation {
    # `^main$` is the plausible mistake, carried over from a trigger yaml, and
    # it is the quiet kind: the push filter accepts it and keeps working, while
    # the scheduled run asks for a branch literally named "^main$" and fails
    # with a not-found on a branch nobody typed.
    condition     = !can(regex("[\\^$*+?()\\[\\]{}|\\\\]", var.branch))
    error_message = "branch takes a literal branch name (main), not a regex (^main$). The regex form is derived for the push filter; the run API matches this value literally."
  }
}

variable "name" {
  type        = string
  default     = null
  description = "Trigger name. Defaults to ci-runner-apply-<repo>. Set it when one project applies more than one runner root, or the second trigger collides with the first."

  validation {
    condition     = var.name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]$", coalesce(var.name, "x-x")))
    error_message = "name must start with a letter and contain only letters, digits and hyphens (Cloud Build trigger naming)."
  }
}

variable "terraform_version" {
  type        = string
  default     = "1.15.2"
  description = "Pinned, and matched to apply-runner-pool.yml, so a provider-side change never arrives with an apply nobody triggered. Floating this is how an unattended apply starts failing on a morning when nothing was merged."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.terraform_version))
    error_message = "terraform_version must be an exact x.y.z version — it names a container image tag, and a floating tag defeats the point of pinning it."
  }
}

variable "lock_timeout" {
  type        = string
  default     = "5m"
  description = "How long terraform waits for the state lock. Long enough to outlast a concurrent apply, short enough that a lock left by a killed process is reported the same day."
}

variable "build_timeout" {
  type        = string
  default     = "1800s"
  description = "Build timeout. Generous: an apply that replaces an instance template and waits on a managed instance group is slow, and a timeout mid-apply is how a state lock is left behind."
}

variable "extra_included_files" {
  type        = list(string)
  default     = []
  description = "Extra glob patterns that should also trigger an apply — a shared tfvars file outside the root, a script the root reads."
}

variable "ignored_files" {
  type        = list(string)
  default     = ["**/*.md"]
  description = "Globs that never trigger an apply even inside the root. Documentation only, by default: anything else in a terraform root is terraform."
}

variable "disabled" {
  type        = bool
  default     = false
  description = "Create the trigger disabled. For onboarding a repository whose root is not ready to apply unattended yet — the trigger exists and is reviewable, and nothing runs."
}

variable "apply_schedule" {
  type        = string
  default     = null
  description = <<-EOT
    Unix cron for the run that no push produces. Null (the default) creates no scheduler job.

    A consumer pinning a floating module tag has NO commit to push when a new version ships, so this is the only trigger that ever fires for that release. Set it on any repository that pins `?ref=v5`.

    Pick a minute that is not 0, and a different one per repository — every scheduled job in a fleet firing on the hour is how a rate limit becomes a fleet-wide outage.
  EOT

  validation {
    condition     = var.apply_schedule == null || length(split(" ", trimspace(coalesce(var.apply_schedule, "x")))) == 5
    error_message = "apply_schedule must be a 5-field unix cron (minute hour day-of-month month day-of-week)."
  }
}

variable "schedule_time_zone" {
  type        = string
  default     = "Etc/UTC"
  description = "Time zone for apply_schedule. UTC by default so the fleet's applies do not all move an hour twice a year, in opposite directions, depending on where each project's author lives."
}

variable "scheduler_service_account" {
  type        = string
  default     = null
  description = "Account the scheduler authenticates as when it calls the run API. Defaults to service_account. Needs cloudbuild.builds.create on the trigger, and must live in THIS project — Cloud Scheduler mints its token through its own service agent, which is per-project."
}

# --- alert policies ------------------------------------------------------------
#
# The apply is the only thing in these projects that runs with project-scoped
# credentials on a schedule, which is why the fleet's alerting is reconciled
# from here. See the `alert-policies` step in main.tf for why it is best-effort.

variable "manage_alert_policies" {
  type        = bool
  default     = true
  description = <<-EOT
    Bring this project's CI alert policies up to the fleet's set on every apply.

    On by default, and that default is the point: measured on 2026-08-29, four of the ten pool projects had NO CI alert policies at all, because the script that creates them was operator-run and nobody had run it there. Opt-out rather than opt-in, because a project that forgets is exactly the project that needs it.

    The step never fails the build — a project whose build account cannot write monitoring policies gets a warning naming the role, not a red apply.
  EOT
}

variable "alert_notification_email" {
  type        = string
  default     = null
  description = <<-EOT
    Address every policy in this project pages. Null (the default) ADOPTS the email notification channel the project already has, which is what makes this work unattended in ten roots without an inbox literal in any of them.

    Set it only to bootstrap a project that has never had a channel, or to disambiguate one that has more than one — the script refuses to choose in both cases rather than pointing thirteen policies at an inbox nobody reads.
  EOT

  # This value is interpolated into a shell command in the build step, inside
  # single quotes. An address containing a quote would close them and run the
  # rest as a command, AS THE PROJECT'S BUILD ACCOUNT — the one identity in this
  # design that can write infrastructure. Validated to an address shape here
  # rather than escaped there, because the escaping would live in a heredoc that
  # nobody re-reads and the shape is what the input is supposed to be anyway.
  validation {
    condition     = var.alert_notification_email == null || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", coalesce(var.alert_notification_email, "x@y.zz")))
    error_message = "alert_notification_email must be a plain email address — it is interpolated into the build's shell command, so anything else is refused here rather than quoted there."
  }
}

variable "alert_poll_interval_seconds" {
  type        = number
  default     = null
  description = "The pool's poll_interval_seconds, when it is not the module default. The slow-tick threshold is derived from it, so a value that disagrees with the pool pages on supported behaviour. Null passes nothing and the script uses the same default the pool does."
}

variable "alert_register_grace_seconds" {
  type        = number
  default     = null
  description = "The pool's register_grace_seconds, when it is not the module default. It is a statement about how long a host is ALLOWED to take to register, so a threshold below it pages for a pool behaving as configured."
}

variable "alert_drain_grace_seconds" {
  type        = number
  default     = null
  description = "The pool's drain_grace_seconds, when it is not the module default. Same reasoning as register grace: the alert must not fire inside the window the pool is permitted to use."
}

variable "alert_cache_stale_hours" {
  type        = number
  default     = null
  description = "Snapshot age that pages, which must stay BELOW the pool's cache_snapshot_max_age_hours. At or above it, the first notification anyone gets is every host in the pool starting cold — the outage, not the warning."
}
