# ci-runner-utility-host — inputs.
#
# Every value here is a variable on purpose: like ci-runner-host-pool, this
# module is consumed by roots in more than one organisation, region and cloud
# project. No customer, repository, region or project literal may appear in it.
# See docs/adr-utility-host.md (#1635) for why the module exists.

variable "project_id" {
  description = "GCP project that owns the utility host (template and zonal MIG)."
  type        = string

  validation {
    condition     = trimspace(var.project_id) != ""
    error_message = "project_id must not be empty."
  }
}

variable "region" {
  description = "Region of the instance template. `zone` must be a zone of this region."
  type        = string

  validation {
    condition     = trimspace(var.region) != ""
    error_message = "region must not be empty."
  }
}

variable "zone" {
  description = <<-EOT
    Zone of the managed instance group. ONE zone: the group holds exactly one
    always-on host, and a regional group would gain nothing but a second place
    for the MIG to put it.
  EOT
  type        = string

  validation {
    condition     = trimspace(var.zone) != ""
    error_message = "zone must not be empty."
  }
}

variable "name" {
  description = <<-EOT
    Name of the utility host. Used as the resource name prefix, the `pool` label
    on every series the host publishes, and the BASE INSTANCE NAME of the group:
    the host is `<name>-<4 characters>` and its agents are `<host>-s<N>`.

    It must differ from every pool's base name in the same project and
    repositories. A controller recognises its own hosts by the exact grammar
    `<base>-<4 characters>` (ci-runner-host-pool/scripts/host-ownership.sh), so a
    utility host sharing a pool's base name would be drained and deleted by that
    pool's controller as one of its own. The default ends in `-utility`, which no
    pool name in the fleet does.
  EOT
  type        = string
  default     = "ci-utility"

  validation {
    # Same shape as ci-runner-host-pool's `name`: GCP resource names, and the
    # string interpolated into the telemetry labels and the host's own logs.
    condition     = can(regex("^[a-z]([-a-z0-9]{0,56}[a-z0-9])?$", var.name))
    error_message = "name must be 1-58 characters (the MIG appends a 5-character suffix to it), lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen."
  }

  validation {
    # The name is a network tag on the host; `ci-shared-infra-` is the namespace
    # the shared-infra firewall rules key on. The utility host must never join a
    # pair's band (docs/adr-utility-host.md B3), so the prefix is refused here as
    # it is on a pool.
    condition     = !startswith(var.name, "ci-shared-infra-")
    error_message = "name must not start with \"ci-shared-infra-\" — that prefix is reserved for shared-infrastructure tags, and the utility host must carry no shared port band (docs/adr-utility-host.md B3)."
  }
}

variable "github_owner" {
  description = "GitHub organisation or user that owns every repository in `repos`. Tokens are minted per slot, scoped to that slot's one repository."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_owner))
    error_message = "github_owner must be a GitHub login: 1-39 characters, letters, digits and hyphens, and neither starting nor ending with a hyphen."
  }
}

variable "repos" {
  description = <<-EOT
    The repositories this host serves, keyed by bare repository NAME (no owner).
    Each gets `slots` job slots of its own; every one of them registers a
    just-in-time runner IN THAT REPOSITORY ONLY, with the labels

      [self-hosted, <runner_labels...>, <Repo>-util, <labels...>]

    so a workflow moves a gatekeeper job here with `runs-on: [self-hosted, linux,
    gcp, <Repo>-util]`. Slots are laid out in repository-name order, and a slot
    whose repository changes is wiped before it serves the new one
    (host-startup.sh `bind_slot`, ADR B4).

    Size `slots` from the repository's measured gatekeeper concurrency: a job that
    finds every slot of its repository busy queues, it does not borrow another
    repository's slot.

    Only repositories with fork pull-request workflows disabled belong here, and
    never a job that is given the merge App key or runs `pull_request_target`
    (docs/adr-utility-host.md, Security). Terraform cannot see either property;
    the repository's own policy check is what enforces it.
  EOT
  type = map(object({
    slots  = number
    labels = optional(list(string), [])
  }))

  validation {
    condition     = length(var.repos) > 0
    error_message = "repos must name at least one repository — a utility host with no slots registers nothing and is paid for anyway."
  }

  validation {
    # The host refuses any other character in ci-slot-repos, and the name is
    # interpolated into the GitHub API path each slot mints against.
    condition     = alltrue([for r in keys(var.repos) : can(regex("^[A-Za-z0-9_.-]{1,100}$", r))])
    error_message = "every key of repos must be a repository NAME without the owner: 1-100 characters, letters, digits, dots, hyphens and underscores."
  }

  validation {
    # The slot label is `<Repo>-util`. A repository named `host-x` would make it
    # `host-x-util`, which the controller reads in a job's runs-on as an affinity
    # pin to an instance called `x-util` — one that does not exist.
    condition     = alltrue([for r in keys(var.repos) : !startswith(lower(r), "host-")])
    error_message = "a repository whose name starts with `host-` cannot be served here: its slot label `<Repo>-util` would carry the reserved `host-` prefix, which the controller reads as a pin to a host that does not exist."
  }

  validation {
    condition     = alltrue([for r in values(var.repos) : r.slots >= 1 && floor(r.slots) == r.slots])
    error_message = "every repos entry needs a whole number of slots, at least 1."
  }

  validation {
    # Slot <n> is addressed as 10.99.<n>.0/30 on the host (host-startup.sh
    # slot_gw_ip), so the slot index is one octet.
    condition     = sum(concat([0], [for r in values(var.repos) : r.slots])) <= 254
    error_message = "repos asks for more than 254 slots in total; each slot's network is 10.99.<slot>.0/30, so the slot index must fit one octet."
  }

  validation {
    # Labels reach ci-slot-labels, which the host splits on `;` then `,`, and
    # whose charset it checks before putting a label in a JSON body.
    condition = alltrue(flatten([for r in values(var.repos) : [
      for l in r.labels : can(regex("^[A-Za-z0-9_.:-]+$", l))
    ]]))
    error_message = "repos[*].labels entries may contain only letters, digits, `_`, `.`, `:` and `-` — no commas, semicolons or whitespace, which would split one label into several."
  }

  validation {
    condition = alltrue(flatten([for r in values(var.repos) : [
      for l in r.labels : !startswith(lower(l), "host-") && lower(l) != "background"
    ]]))
    error_message = "repos[*].labels may not use the reserved `host-` prefix (an affinity pin) or `background` (the host's own push-run label)."
  }
}

variable "image" {
  description = <<-EOT
    Self-link or family reference of the Linux GOLDEN image (packer/
    ci-host-image.pkr.hcl, family `ci-runner-host`). The same image every Linux
    pool boots: the utility host differs only in metadata. The image's disk is
    200 GB, which is why `boot_disk_size_gb` cannot go below it.
  EOT
  type        = string

  validation {
    # host-startup.sh is the Linux boot script; a Windows image would run no
    # boot script at all and the host would serve nothing, forever, at full price.
    condition     = !can(regex("ci-runner-host-win", var.image))
    error_message = "image names the Windows golden image family (ci-runner-host-win). The utility host is Linux only: a Windows instance carrying `startup-script` runs no boot script and registers nothing."
  }
}

variable "machine_type" {
  description = "Machine type. A gatekeeper job is a 30-second script, so the default is small; size up only from measured contention. Standard GCE only — this module has no Spot option."
  type        = string
  default     = "e2-standard-2"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size. At least 200: the golden image itself is 200 GB, and GCE refuses a disk smaller than its image."
  type        = number
  default     = 200

  validation {
    condition     = var.boot_disk_size_gb >= 200
    error_message = "boot_disk_size_gb must be at least 200 — the golden image is 200 GB and a smaller boot disk fails at instance creation."
  }
}

variable "boot_disk_type" {
  description = "Boot disk type."
  type        = string
  default     = "pd-balanced"
}

variable "service_account_email" {
  description = <<-EOT
    Service account attached to the host. It needs exactly what a Linux pool
    HOST account has (ci-runner-identity's host account): read the GitHub App key
    secret, write custom metrics and logs. Nothing more: there is no job
    identity on this host, no cache bucket and no turbo bucket (ADR decision 2).
    This module creates NO IAM binding; it only attaches the account.

    Never the controller's account: that one holds
    roles/compute.instanceAdmin.v1, and this host runs workflow code.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+$", var.service_account_email))
    error_message = "service_account_email must be a service account email."
  }
}

variable "github_app_id" {
  description = "GitHub App id used to mint the per-slot, per-repository registration tokens."
  type        = string
}

variable "github_app_installation_id" {
  description = "Installation id of that App on `github_owner`. Every repository in `repos` must be in the installation."
  type        = string
}

variable "github_app_private_key_secret" {
  description = "Secret Manager secret NAME (never the value) holding the GitHub App private key. Read by the host as root at runtime; never placed in metadata, state or the image."
  type        = string

  validation {
    condition     = trimspace(var.github_app_private_key_secret) != ""
    error_message = "github_app_private_key_secret must name a secret."
  }
}

variable "runner_group" {
  description = "Numeric id of the GitHub runner group to register into. Empty = each repository's default group."
  type        = string
  default     = ""

  validation {
    # A repository-scoped token cannot resolve a group NAME (host-startup.sh
    # runner_group_id), so a name would fail every registration at boot.
    condition     = can(regex("^[0-9]*$", var.runner_group))
    error_message = "runner_group must be empty or a numeric runner group id."
  }
}

variable "runner_labels" {
  description = <<-EOT
    Labels EVERY slot registers with, after `self-hosted` and before the slot's
    own `<Repo>-util`. The default is the ADR's `[linux, gcp]`, the same base set
    the fleet's workflows already ask for.
  EOT
  type        = list(string)
  default     = ["linux", "gcp"]

  validation {
    condition     = alltrue([for l in var.runner_labels : can(regex("^[A-Za-z0-9_.:-]+$", l))])
    error_message = "runner_labels entries may contain only letters, digits, `_`, `.`, `:` and `-`."
  }

  validation {
    # `-util` is the whole of what keeps a utility slot out of a pool's routing
    # and a pool's controller out of this host's demand. A host-wide label that
    # a pool also answers to would let a pool job land here (and vice versa).
    condition     = alltrue([for l in var.runner_labels : !startswith(lower(l), "host-") && lower(l) != "background" && !endswith(lower(l), "-util")])
    error_message = "runner_labels may not use the reserved `host-` prefix, `background`, or a `-util` suffix — the per-repository `<Repo>-util` label is added per slot, never host-wide."
  }
}

variable "network" {
  description = "VPC self-link or name."
  type        = string
}

variable "subnetwork" {
  description = "Subnetwork self-link or name in `region`. Egress through Cloud NAT; the host needs nothing inbound."
  type        = string
}

variable "network_tags" {
  description = <<-EOT
    Extra network tags, on top of `ci-runner-host` and `name`. Pass the tag the
    project's runner firewall rules target (ci-runner-network
    `runner_network_tag`). No `ci-shared-infra-` tag: the utility host has no
    shared port band (ADR B3).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.network_tags : !startswith(t, "ci-shared-infra-")])
    error_message = "network_tags must not contain a `ci-shared-infra-` tag — the utility host carries no shared port band, since the cross-slot band accept would bypass the inter-slot DROP (docs/adr-utility-host.md B2/B3)."
  }
}

variable "metric_prefix" {
  description = "Custom-metric prefix for the series the host publishes. Same default as ci-runner-host-pool, so one fleet dashboard covers both."
  type        = string
  default     = "custom.googleapis.com/ci"
}

variable "labels" {
  description = "Extra resource labels applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "update_policy_type" {
  description = <<-EOT
    How a NEW template (a changed `repos`, a new image, a module release) reaches
    the host. No controller drains this host, so:

    - `PROACTIVE` (default): the group surges a replacement, then deletes the
      old host. A gatekeeper job running on the old host at that moment is
      killed and must be re-run; the jobs are one or two minutes long.
    - `OPPORTUNISTIC`: nothing is replaced until the host is recreated by hand
      or by repair, so an apply alone changes nothing on the running host.
  EOT
  type        = string
  default     = "PROACTIVE"

  validation {
    condition     = contains(["PROACTIVE", "OPPORTUNISTIC"], var.update_policy_type)
    error_message = "update_policy_type must be PROACTIVE or OPPORTUNISTIC."
  }
}
