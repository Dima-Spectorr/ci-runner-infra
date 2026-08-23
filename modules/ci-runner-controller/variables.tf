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

variable "metric_prefix" {
  description = "Custom-metric prefix. Series are labelled with `pool`, so all four pools publish under one prefix."
  type        = string
  default     = "custom.googleapis.com/ci"
}

# --- the VM ------------------------------------------------------------------------

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
