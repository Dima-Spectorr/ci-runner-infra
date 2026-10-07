# repos-table — which SHAPE a controller was given, and the table it carries.
#
# WHY THIS IS A MODULE OF ITS OWN, WITH NO PROVIDER IN IT
#
# A controller is given either the one repository it always served
# (`github_owner` / `github_repo` / `pools`) or a `repos` table, and never both.
# Everything that decides between them, and everything that refuses a table the
# VM could not serve, is a relation between SEVERAL inputs — which a variable
# `validation` cannot express on the Terraform versions this repository
# supports, and which `terraform validate` never evaluates at all.
#
# Left in the parent it could only be tested by reading the text, because
# planning the parent needs a cloud provider and credentials. Here it is plain
# functions over plain values, so scripts/ci/multi-repo.selftest.sh PLANS it —
# offline, in a second — and every refusal below is a plan it has watched fail.
#
# Tenancy-agnostic — no customer literals.

terraform {
  required_version = ">= 1.5.0"
}

variable "repos" {
  description = "The parent's `repos`, already type-checked there. Empty means the legacy single-repository shape."
  type        = any
  default     = []
}

variable "github_owner" {
  description = "The parent's legacy `github_owner`; null when unset."
  type        = string
  default     = null
}

variable "github_repo" {
  description = "The parent's legacy `github_repo`; null when unset."
  type        = string
  default     = null
}

variable "legacy_pool_count" {
  description = "How many rows the parent's legacy `pools` holds."
  type        = number
  default     = 0
}

variable "github_app_id" {
  description = "Controller-wide App id, the default for a row that names none."
  type        = string
}

variable "github_app_installation_id" {
  description = "Controller-wide installation id, the default for a row that names none."
  type        = string
}

variable "github_app_private_key_secret" {
  description = "Controller-wide key secret, the default for a row that names none."
  type        = string
}

variable "queue_base_branch" {
  description = "Controller-wide queue base branch, the default for a row that names none."
  type        = string
  default     = "main"
}

locals {
  repos_given  = length(var.repos) > 0
  legacy_given = var.github_owner != null || var.github_repo != null || var.legacy_pool_count > 0
  legacy_whole = var.github_owner != null && var.github_repo != null && var.legacy_pool_count > 0

  # THE SLUG, AND THE SAME ONE THE VM COMPUTES. It names a systemd unit instance
  # and a state directory, so it is the repository's whole identity on the
  # machine. controller-startup.sh's repo_slug() must produce exactly this from
  # the same two strings; the self-test feeds both the same pairs and compares.
  #
  # Lower-cased because GitHub compares owner and repository names
  # case-insensitively: `Acme/App` and `acme/app` are ONE repository, and two
  # rows for it would be two processes draining the same hosts.
  rows = [
    for r in var.repos : {
      slug                          = lower(replace("${r.github_owner}-${r.github_repo}", "/[^A-Za-z0-9._-]/", "-"))
      github_owner                  = r.github_owner
      github_repo                   = r.github_repo
      pools                         = r.pools
      queue_base_branch             = try(r.queue_base_branch, null) == null ? var.queue_base_branch : r.queue_base_branch
      github_app_id                 = try(r.github_app_id, null) == null ? var.github_app_id : r.github_app_id
      github_app_installation_id    = try(r.github_app_installation_id, null) == null ? var.github_app_installation_id : r.github_app_installation_id
      github_app_private_key_secret = try(r.github_app_private_key_secret, null) == null ? var.github_app_private_key_secret : r.github_app_private_key_secret
    }
  ]

  slugs      = [for r in local.rows : r.slug]
  pool_names = flatten([for r in local.rows : [for p in r.pools : p.name]])

  # Everything a row hands to a systemd EnvironmentFile, which is read by
  # systemd and not by a shell: a space, a quote or a `$` there is not an
  # injection, it is a value silently cut short — an owner that reads as half
  # its name and a controller sweeping somebody else's repository.
  env_values = flatten([
    for r in local.rows : [r.queue_base_branch, r.github_app_id, r.github_app_installation_id, r.github_app_private_key_secret]
  ])

  repos_json = local.repos_given ? jsonencode(local.rows) : ""

  # FOLDED, for the reason the parent records beside `b64_fold_columns`: GCE
  # accepts a metadata value with one very long line, creates the template, and
  # then fails every instance built from it with an unexplained `Internal
  # error`. A table is one JSON line of roughly 400 characters per pool, so
  # three repositories with four pools each are already past 4096. Compressed
  # and folded it has no long line at any size, and the VM unpacks it with the
  # two tools the boot script already depends on.
  fold_columns = 76
  repos_folded = local.repos_given ? join("\n", regexall(".{1,${local.fold_columns}}", base64gzip(local.repos_json))) : ""
}

output "shape" {
  description = "`repos` when the table is in use, `legacy` for the single-repository inputs."
  value       = local.repos_given ? "repos" : "legacy"

  precondition {
    condition     = !(local.repos_given && local.legacy_given)
    error_message = "give the controller EITHER `repos` OR the single-repository `github_owner` / `github_repo` / `pools`, never both. With both set there are two answers to which repository a pool belongs to, and the one the VM would pick is the table — so the single repository named beside it would silently stop being served."
  }

  precondition {
    condition     = local.repos_given || local.legacy_given
    error_message = "the controller was given no repository: set `repos`, or the single-repository `github_owner` / `github_repo` / `pools`. A controller with an empty table exits on boot having served nothing, and every pool it was meant to serve holds its last size behind an ONLY_UP autoscaler."
  }

  precondition {
    condition     = local.repos_given || !local.legacy_given || local.legacy_whole
    error_message = "the single-repository shape needs all three of `github_owner`, `github_repo` and a non-empty `pools`. A controller missing one of them boots, finds no usable pool or no repository to sweep, and serves nothing."
  }
}

output "rows" {
  description = "The table with every per-row default resolved, in input order. Empty in the legacy shape."
  value       = local.rows

  precondition {
    condition     = alltrue([for r in local.rows : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", r.github_owner)) && can(regex("^[A-Za-z0-9._-]+$", r.github_repo))])
    error_message = "each row's github_owner and github_repo may use only letters, digits, dot, dash and underscore. They name a systemd unit instance and a state directory on the controller, and are written into the unit's environment file."
  }

  precondition {
    condition     = length(distinct(local.slugs)) == length(local.slugs)
    error_message = "two rows of `repos` resolve to the same repository slug (`<owner>-<repo>`, lower-cased). Either one repository is listed twice — GitHub compares names case-insensitively — or two different repositories collide, as `a-b/c` and `a/b-c` do. One slug is one process and one state directory, so the second row would share the first one's drain counters and markers. Slugs: ${join(", ", local.slugs)}"
  }

  precondition {
    condition     = alltrue([for r in local.rows : length(r.pools) > 0])
    error_message = "every row of `repos` must name at least one pool — a repository process with an empty table exits on start having served nothing, and systemd restarts it for ever."
  }

  precondition {
    condition     = length(distinct(local.pool_names)) == length(local.pool_names)
    error_message = "each pool name must be unique across the WHOLE `repos` table, not only inside one repository. The name is the `pool` metric label the autoscalers filter on and the prefix of the hosts' names, so one name under two repositories is two processes publishing one series and each reading the other's hosts."
  }

  precondition {
    condition     = alltrue([for n in local.pool_names : can(regex("^[A-Za-z0-9._-]+$", n))])
    error_message = "a pool name may use only letters, digits, dot, dash and underscore — it is interpolated raw into the JSON of every metric point and used as a glob when per-pool outcomes are separated."
  }

  precondition {
    condition = alltrue(flatten([
      for r in local.rows : [
        for p in r.pools : contains(["linux", "windows"], try(p.host_os, null) == null ? "linux" : p.host_os) && contains(["ci", "merge-queue"], try(p.role, null) == null ? "ci" : p.role)
      ]
    ]))
    error_message = "each pool's host_os must be linux or windows, and its role `ci` or `merge-queue`. The table parser rejects any other value and a rejected row is a pool that is never ticked."
  }

  precondition {
    condition     = alltrue([for v in local.env_values : can(regex("^[A-Za-z0-9._/@:+-]+$", v))])
    error_message = "a row's queue_base_branch, App id, installation id and key secret (or the controller-wide value it defaults to) may use only letters, digits and . _ / @ : + - . They are written to the repository unit's environment file, where a space or a quote would cut the value short rather than fail."
  }

  # LABEL ISOLATION, PER REPOSITORY. The same relation the parent asserts over
  # its single `pools` table, and for the reason recorded there at length:
  # GitHub schedules a self-hosted runner by label SUPERSET, so a merge-queue
  # pool and the CI pool on the same OS must each carry a selector label the
  # other does not.
  #
  # It is asked inside one repository and never across two. Runners are
  # registered to a repository, so a job of one can never reach another's
  # hosts whatever the labels say — and two repositories using the same
  # `[self-hosted, linux, gcp]` selector is the ordinary case, not a collision.
  precondition {
    condition = alltrue(flatten([
      for r in local.rows : [
        for q in r.pools : [
          for c in r.pools : (
            length(setsubtract(
              setsubtract(toset([for l in split(",", c.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(c.name)])),
              setsubtract(toset([for l in split(",", q.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(q.name)])),
              )) > 0 && length(setsubtract(
              setsubtract(toset([for l in split(",", q.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(q.name)])),
              setsubtract(toset([for l in split(",", c.runner_labels) : lower(trimspace(l))]), toset(["self-hosted", lower(c.name)])),
            )) > 0
          )
          if(try(c.role, null) == null ? "ci" : c.role) == "ci" && (try(c.host_os, null) == null ? "linux" : c.host_os) == (try(q.host_os, null) == null ? "linux" : q.host_os)
        ]
        if(try(q.role, null) == null ? "ci" : q.role) == "merge-queue"
      ]
    ]))
    error_message = "inside one repository of `repos`, a merge-queue pool and the CI pool on the same OS must each carry a selector label the other does not. GitHub matches a runner by superset: if the queue pool's labels cover the CI pool's, every ordinary job becomes eligible for the queue's hosts; if they are covered BY the CI pool's, queue jobs ask for a label nothing carries and wait against it forever."
  }
}

output "slugs" {
  description = "One slug per row, in input order: the systemd instance name and state directory of that repository's process."
  value       = local.slugs
}

output "pool_names" {
  description = "Every pool name in the table, in row order."
  value       = local.pool_names
}

output "repos_json" {
  description = "The table as the JSON the VM parses, before compression. Empty in the legacy shape."
  value       = local.repos_json
}

output "metadata_value" {
  description = "The `ci-repos` metadata value: the JSON gzipped, base64-encoded and folded. Empty in the legacy shape, where the key must not be rendered at all."
  value       = local.repos_folded
}
