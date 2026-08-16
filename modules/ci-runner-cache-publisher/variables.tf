variable "project_id" {
  type        = string
  description = "Project that owns the publisher service account. The same project as the pool it publishes for."
}

variable "name" {
  type        = string
  description = "Pool name. Decides the object prefix this publisher may write, and must be the same value the pool module was given — a mismatch publishes where no host looks."

  # The same constraint the pool module applies to its own name, and for the same
  # reason: this value is interpolated into a CEL string literal in an IAM
  # condition. A name carrying a quote or a backslash would end the literal early
  # and write a condition that means something else.
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.name))
    error_message = "name must be 1-63 characters, lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "account_id" {
  type        = string
  description = "Base for the service account id. `-cache` is appended, so this is capped at 24 characters rather than truncated to fit — two bases differing only past the cap would otherwise resolve to one account holding two pools' grants."

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,22}[a-z0-9])$", var.account_id))
    error_message = "account_id must be 6-24 characters, lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen. 24 and not 30: `-cache` is appended and the id cap is 30."
  }
}

variable "cache_snapshot_bucket" {
  type        = string
  description = "Name of the shared snapshot bucket (ci-runner-cache-bucket's `bucket_name` output). A bucket NAME, not a gs:// URL."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.cache_snapshot_bucket))
    error_message = "cache_snapshot_bucket must be a bucket NAME (3-63 characters, lowercase letters, digits, dots, hyphens and underscores), not a gs:// URL."
  }
}

variable "repository" {
  type        = string
  description = "The repository whose publish workflow may assume this account, as `<owner>/<repo>`. Required, and it is half the boundary: a pool is normally shared by every repository in the org, so a binding that names only a ref matches a run on ANY of their default branches."

  # Interpolated into the principalSet, whose parts are separated by `/` and `@`.
  # GitHub's own charset for owner and repo names is narrower than this; what
  # matters here is that neither may carry a separator and change what the
  # principalSet names.
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$", var.repository))
    error_message = "repository must be <owner>/<repo> — exactly one slash, and no @ or other separator in either part."
  }
}

variable "publish_workflow_path" {
  type        = string
  default     = ".github/workflows/publish-cache-snapshot.yml"
  description = "Path of the ONE workflow file whose runs may assume this account, relative to the repository root. Pinning the file is what keeps a `pull_request_target` workflow — whose token also asserts the default ref — from reaching the write grant."

  validation {
    condition     = can(regex("^\\.github/workflows/[A-Za-z0-9._-]+\\.ya?ml$", var.publish_workflow_path))
    error_message = "publish_workflow_path must be a workflow file under .github/workflows/, e.g. .github/workflows/publish-cache-snapshot.yml. GitHub reports no other location in job_workflow_ref."
  }
}

variable "workload_identity_pool" {
  type        = string
  description = "Full resource name of the Workload Identity POOL that federates the repository's GitHub OIDC tokens, e.g. projects/123/locations/global/workloadIdentityPools/github. Its provider MUST map `attribute.job_workflow_ref` and MUST carry an attribute condition pinning the org by numeric id."

  validation {
    condition     = can(regex("^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+$", var.workload_identity_pool))
    error_message = "workload_identity_pool must be the pool's full resource name — projects/<number>/locations/global/workloadIdentityPools/<pool-id> — using the project NUMBER, not the project id, and naming the pool rather than a provider under it."
  }
}

variable "allowed_ref" {
  type        = string
  default     = "refs/heads/main"
  description = "The one git ref whose runs may assume the publisher. The repository's default branch, and nothing else. Note this is the WEAKEST of the three parts of the binding — a ref alone is reachable from pull_request_target and workflow_run — so it is the repository and the workflow file beside it that carry the boundary."

  # `refs/heads/` and not `refs/pull/`, `refs/tags/` or a bare branch name. A tag
  # is movable by anyone who can push one, a bare name does not match what the
  # OIDC token asserts and would bind to nothing, and `refs/pull/*` is precisely
  # the identity this whole module exists to keep out of the write path.
  validation {
    condition     = can(regex("^refs/heads/[A-Za-z0-9._/-]+$", var.allowed_ref))
    error_message = "allowed_ref must be a branch ref — refs/heads/<branch>. Tags are movable and pull-request refs carry unreviewed code, so neither may hold the write grant."
  }
}
