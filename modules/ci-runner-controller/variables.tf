variable "project_id" {
  description = "Project the controller VM lives in."
  type        = string
}

variable "region" {
  description = "Region the controller VM lives in. The POOLS it serves may be elsewhere — each pool's descriptor names its own region."
  type        = string
}

variable "zones" {
  description = "Optional zone pin for the controller. Empty means the first UP zone of var.region."
  type        = list(string)
  default     = []
}

variable "name" {
  description = "Name of the controller VM. One per repository, so a repository slug reads better here than a pool name."
  type        = string
}

# --- the pools ------------------------------------------------------------------

variable "pools" {
  description = "The pools this controller serves, as ci-runner-host-pool `pool_descriptor` outputs."

  # `optional()` mirrors pool-table.sh column by column, and the defaults are
  # deliberately NOT restated here: an omitted key reaches the parser as an
  # absent field and the parser supplies the one default there is. Two copies of
  # a default is two answers to "how long before a host may be drained", and the
  # one that loses is always the one somebody read.
  type = list(object({
    name                     = string
    mig                      = string
    region                   = string
    runner_labels            = string
    slots                    = optional(number)
    min_hosts                = optional(number)
    max_hosts                = optional(number)
    drain_grace_seconds      = optional(number)
    register_grace_seconds   = optional(number)
    orphan_confirm_ticks     = optional(number)
    recycle_max_unavailable  = optional(number)
    host_os                  = optional(string)
    mints_registration_token = optional(bool)
    role                     = optional(string)
    beacon_interval          = optional(number)
    pin_orphan_grace_seconds = optional(number)
  }))

  validation {
    condition     = length(var.pools) > 0
    error_message = "pools must name at least one pool — a controller with an empty table exits on boot having served nothing, and every pool it was meant to serve holds its last size behind an ONLY_UP autoscaler."
  }

  validation {
    condition     = length(distinct([for p in var.pools : p.name])) == length(var.pools)
    error_message = "each pool name must be unique on a controller — the name keys the per-pool state arrays and the metric label, so a duplicate silently makes two pools into one and the second one's hosts are never drained."
  }

  # The parser refuses these too, per row and on the running VM. Refusing them
  # at plan time is the difference between a typo you fix now and a typo that
  # reaches a boot log nobody reads, on a pool that then looks idle forever.
  validation {
    condition     = alltrue([for p in var.pools : can(regex("^[A-Za-z0-9._-]+$", p.name))])
    error_message = "a pool name may use only letters, digits, dot, dash and underscore — it is interpolated raw into the JSON of every metric point and used as a glob when per-pool outcomes are separated."
  }

  validation {
    condition     = alltrue([for p in var.pools : contains(["linux", "windows"], coalesce(p.host_os, "linux"))])
    error_message = "each pool's host_os must be linux or windows."
  }

  validation {
    condition     = alltrue([for p in var.pools : contains(["ci", "merge-queue"], coalesce(p.role, "ci"))])
    error_message = "each pool's role must be `ci` or `merge-queue`. The table parser rejects any other value and a rejected row is a pool that is never ticked."
  }

  # LABEL ISOLATION, ASSERTED WHERE BOTH POOLS ARE FINALLY IN ONE PLACE.
  #
  # GitHub schedules a self-hosted runner by SUPERSET: a job asking for
  # [self-hosted, linux, gcp, Repo] runs on ANY runner carrying at least those
  # labels. So a merge-queue pool that also carried the CI pool's selector
  # labels would be dedicated in name only — every ordinary pull-request job
  # would be eligible for it, and the split that exists to stop the two
  # workloads starving each other would buy nothing.
  #
  # The property is mutual, and both directions fail silently in opposite ways:
  #
  #   queue labels ⊇ ci labels   the pools merge. Queue hosts serve ordinary
  #                              jobs, and the queue is starved by the very
  #                              pull requests feeding it.
  #   queue labels ⊆ ci labels   the queue cannot be addressed at all. Its jobs
  #                              ask for a label no runner carries and queue
  #                              against it forever rather than failing.
  #
  # It is a relation BETWEEN pools, which is why it could not live in the pool
  # module: one instance there cannot see the other. Here the whole table is one
  # variable, so the relation is checkable at plan time — before an instance
  # moves — instead of being a paragraph in a comment that an override edits out.
  #
  # `self-hosted` and the pool's own name are excluded on both sides. Every pool
  # registers its own name and every name is unique, so leaving them in would
  # make the difference set non-empty for ANY pair and the check vacuous — it
  # would pass on the addressing label while the selector labels were identical,
  # which is the exact failure it is here to catch.
  #
  # Compared lower-cased and trimmed, because that is how GitHub compares them:
  # `Repo` and `repo` are ONE label. This check once had a counterpart in
  # `check-runner-policy.sh` (RUNNER13) that asserted the same property over the
  # workflow ADDRESSING the pools; that rule retired with Mergify (#434), so
  # this plan-time validation is now the only place the property is enforced —
  # do not relax it on the assumption that the gate still catches it. Left
  # case-sensitive, two spellings of one pool
  # would read here as two pools, this check would pass, and the pools would
  # still merge at scheduling time — a green plan over the exact overlap the
  # rule exists to refuse.
  validation {
    condition = alltrue(flatten([
      for q in var.pools : [
        for c in var.pools : (
          length(setsubtract(
            setsubtract(toset([for l in split(",", c.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(c.name)])),
            setsubtract(toset([for l in split(",", q.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(q.name)])),
            )) > 0 && length(setsubtract(
            setsubtract(toset([for l in split(",", q.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(q.name)])),
            setsubtract(toset([for l in split(",", c.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(c.name)])),
          )) > 0
        )
        if coalesce(c.role, "ci") == "ci" && coalesce(c.host_os, "linux") == coalesce(q.host_os, "linux")
      ]
      if coalesce(q.role, "ci") == "merge-queue"
    ]))
    error_message = "a merge-queue pool and the CI pool on the same OS must each carry a selector label the other does not. GitHub matches a runner by superset: if the queue pool's labels cover the CI pool's, every ordinary job becomes eligible for the queue's hosts; if they are covered BY the CI pool's, queue jobs ask for a label nothing carries and wait against it forever. The queue pool carries its own label INSTEAD OF the CI pool's, never in addition to it."
  }
}

# --- what the whole repository shares ---------------------------------------------

# These are the reason one controller is worth building. Four controllers would
# each sweep the SAME repository's run list every tick — 720 list calls an hour
# at the default poll against an installation budget all four share, for one
# answer — and the copy that trips the secondary rate limit blinds the others.
variable "github_owner" {
  description = "Owner of the repository whose runs this controller sweeps."
  type        = string
}

variable "github_repo" {
  description = "Repository whose runs this controller sweeps. ONE — every pool in the table belongs to it."
  type        = string
}

variable "github_app_id" {
  description = "GitHub App id the controller authenticates as."
  type        = string
}

variable "github_app_installation_id" {
  description = "Installation id of that App on the repository."
  type        = string
}

variable "github_app_private_key_secret" {
  description = "Secret Manager resource holding the App private key."
  type        = string
}

variable "poll_interval_seconds" {
  description = "Seconds between ticks. One tick now sweeps GitHub once and then ticks every pool, so this is a per-repository rate, not a per-pool one."
  type        = number
  default     = 20
}

variable "demand_budget_seconds" {
  description = "Wall-clock ceiling on the demand sweep."
  type        = number
  default     = 45
}

variable "queue_base_branch" {
  description = "The branch the merge queue admits. The controller compares every open pull request's base against it and reports one that is green and can never be queued (ci_prs_green_and_unqueued). Never a literal in the controller: a repository whose queue targets something else would otherwise read as entirely parked."
  type        = string
  default     = "main"
}

variable "queue_stall_after_seconds" {
  description = "How long an open, admissible, fully-green pull request may sit with the merge queue not moving before the controller posts a Mergify nudge. The clock starts when the LAST check on the head commit completed. Mergify reacts to a completed check in seconds, so the default of 600 cannot race it — being late costs nothing, being early duplicates a comment on every healthy merge."
  type        = number
  default     = 600
}

variable "queue_stall_max_attempts" {
  description = "Nudges the controller may spend on ONE head commit before leaving the pull request for a human; refreshes and requeues share the budget. This is the backstop for the infrastructure-versus-diff classification being wrong: a misjudged pull request burns three queue runs and then stops rather than looping. Set to 0 to observe and publish without ever commenting — also the correct setting when the App installation holds only `pull requests: read`."
  type        = number
  default     = 3
}

variable "metric_prefix" {
  description = "Custom-metric prefix. Series are labelled with `pool`, so all four pools publish under one prefix."
  type        = string
  default     = "custom.googleapis.com/ci"
}

# --- the VM ------------------------------------------------------------------------

variable "controller_autohealing" {
  description = <<-EOT
    Let the controller's managed group DELETE and rebuild the controller when a
    health probe says it is not answering.

    Off by default, deliberately. The group itself is always on and already
    rebuilds a controller that is deleted or whose VM is gone, which is the
    failure this exists for. This flag adds the probe-driven half, and a probe
    that cannot reach the controller — health-check ranges not open to its tag,
    a central firewall dropping them, the wrong port — reads a healthy machine
    as dead and loops: delete, rebuild, cannot reach, delete. That is worse
    than a pet, because a pet that is up stays up.

    The in-guest watchdog already restarts a wedged tick loop without deleting
    anything, so what this adds is the narrow case of a guest too broken to run
    its own watchdog.

    Turn it on only after confirming the health check reports HEALTHY against
    the running controller. The sequence is in docs/applying-runner-infra.md.
  EOT
  type        = bool
  default     = false
}

variable "controller_health_port" {
  description = <<-EOT
    Port the controller's liveness responder listens on when
    `controller_autohealing` is set. It answers 200 on /livez only while the
    tick heartbeat is fresh, so the probe distinguishes a stalled controller
    from a live one rather than merely confirming something is listening.

    With autohealing off nothing listens on it at all: the port is passed to
    the VM as an empty string and the responder is never started.
  EOT
  type        = number
  default     = 8008
}

variable "controller_machine_type" {
  description = "Machine type for the controller VM."
  type        = string
  default     = "e2-small"
}

variable "controller_image" {
  description = "Boot image for the controller VM."
  type        = string
  default     = "projects/debian-cloud/global/images/family/debian-12"
}

variable "service_account_email" {
  description = "Controller identity. Holds roles/compute.instanceAdmin.v1 over the host pools, so it must never be a pool's host or job identity."
  type        = string
}

variable "network" {
  description = "Network the controller attaches to."
  type        = string
}

variable "subnetwork" {
  description = "Subnetwork the controller attaches to."
  type        = string
}

variable "assign_external_ip" {
  description = "Give the controller a public address. Prefer Cloud NAT."
  type        = bool
  default     = false
}

variable "network_tags" {
  description = "Extra network tags for the controller VM."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Resource labels applied to the controller VM."
  type        = map(string)
  default     = {}
}
