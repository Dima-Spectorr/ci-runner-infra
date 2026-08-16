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
  description = "Base for the service account id. `-cache` is appended and the base is truncated to fit the 30-character cap."

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,28}[a-z0-9])$", var.account_id))
    error_message = "account_id must be 6-30 characters, lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen."
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

variable "workload_identity_pool" {
  type        = string
  description = "Full resource name of the Workload Identity POOL that federates the repository's GitHub OIDC tokens, e.g. projects/123/locations/global/workloadIdentityPools/github. The provider under it must map `attribute.ref`."

  validation {
    condition     = can(regex("^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+$", var.workload_identity_pool))
    error_message = "workload_identity_pool must be the pool's full resource name — projects/<number>/locations/global/workloadIdentityPools/<pool-id> — using the project NUMBER, not the project id, and naming the pool rather than a provider under it."
  }
}

variable "allowed_ref" {
  type        = string
  default     = "refs/heads/main"
  description = "The one git ref whose runs may assume the publisher. The repository's default branch, and nothing else: a snapshot is trusted because the code that produced it was reviewed and merged."

  # `refs/heads/` and not `refs/pull/`, `refs/tags/` or a bare branch name. A tag
  # is movable by anyone who can push one, a bare name does not match what the
  # OIDC token asserts and would bind to nothing, and `refs/pull/*` is precisely
  # the identity this whole module exists to keep out of the write path.
  validation {
    condition     = can(regex("^refs/heads/[A-Za-z0-9._/-]+$", var.allowed_ref))
    error_message = "allowed_ref must be a branch ref — refs/heads/<branch>. Tags are movable and pull-request refs carry unreviewed code, so neither may hold the write grant."
  }
}
