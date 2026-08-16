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
    Name of an EXISTING 2nd-gen Cloud Build connection in this project and region, e.g. `dataretrieval-github`. Null (the default) means the project links repositories the 1st-gen way, through the Cloud Build GitHub App, and the trigger is built with a `github {}` block.

    THE TWO GENERATIONS ARE DIFFERENT APIS, NOT A VERSION FLAG. A 1st-gen trigger names owner/repo directly and resolves them against a project-level GitHub App install; a 2nd-gen trigger names a `google_cloudbuild_repository` resource under a connection. Neither block works against the other's link, and the failure is not a validation error — it is a trigger that is created successfully and never fires, because the push it is watching for arrives on a link it cannot see.

    Which one a project has is a fact about the project, discovered rather than chosen (`gcloud builds connections list --project=<p> --region=<r>`, PER REGION — 2nd-gen connections are regional and a region-less list returns [] for a project that has several).

    Full resource names are accepted as well as bare names, so `google_cloudbuild_connection.x.id` can be passed straight through.
  EOT
}

variable "github_repository" {
  type        = string
  default     = null
  description = <<-EOT
    Full resource name of an EXISTING `google_cloudbuild_repository` under `github_connection` — `projects/p/locations/r/connections/c/repositories/x`. Only read when `github_connection` is set.

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

variable "service_account" {
  type        = string
  description = <<-EOT
    Email of the EXISTING account the build runs as. This module creates no identity, by design — see the header of main.tf.

    THE ONE SECURITY DECISION IN THIS MODULE. It should be the project's existing CD account, and it should NOT hold roles/iam.serviceAccountAdmin or roles/resourcemanager.projectIamAdmin: an account that can apply the runner root END TO END can grant itself owner, and a compute-scoped account instead stops red on the rare apply that changes an identity, which is the intended behaviour and not a gap.
  EOT

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.service_account))
    error_message = "service_account must be a service account EMAIL (name@project.iam.gserviceaccount.com), not a full projects/.../serviceAccounts/... resource name — the resource name is built from it."
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
