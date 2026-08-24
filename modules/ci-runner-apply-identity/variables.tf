variable "project_id" {
  type        = string
  description = "Project holding the runner pool this identity applies."
}

variable "name" {
  type        = string
  description = "Pool name, used in the display name so an audit log entry names the pool without a lookup."
}

variable "account_id" {
  type        = string
  description = "Account id for the apply service account. Keep it recognisably an apply identity — it appears in every audit entry for a change nobody watched happen."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.account_id))
    error_message = "account_id must be 6-30 characters, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "state_bucket" {
  type        = string
  description = "Bucket holding this root's terraform state. Granted objectAdmin on the BUCKET, never project-wide storage admin."
}

variable "workload_identity_pool" {
  type        = string
  description = "Full resource name of the workload identity POOL (not the provider): projects/<number>/locations/global/workloadIdentityPools/<pool>."

  validation {
    condition     = can(regex("^projects/[0-9]+/locations/global/workloadIdentityPools/[^/]+$", var.workload_identity_pool))
    error_message = "workload_identity_pool must be the pool resource name (projects/<number>/locations/global/workloadIdentityPools/<pool>) — a provider path ending in /providers/<name> is a different resource and produces a principalSet that matches nothing, which fails CLOSED at assume time and reads as a broken deploy rather than a wrong binding."
  }
}

variable "repository" {
  type        = string
  description = "The repository whose apply workflow may assume this identity, as `<owner>/<repo>`. Required, and no default: a pool is normally shared by every repository in the org, so a binding that names only a ref matches a run on ANY of their default branches, and guessing somebody else's repository here would be worse than failing."

  # Interpolated into the principalSet, whose parts are separated by `/` and `@`.
  # GitHub's own charset is narrower than this; what matters here is that neither
  # part may carry a separator and change what the principalSet names.
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$", var.repository))
    error_message = "repository must be <owner>/<repo> — exactly one slash, and no @ or other separator in either part."
  }
}

variable "apply_workflow_path" {
  type        = string
  default     = ".github/workflows/apply-runner-pool.yml"
  description = "Path of the ONE workflow file whose runs may assume this identity, relative to the repository root. Pinning the file is what keeps a `pull_request_target` workflow — whose token also asserts the default ref — from reaching project-wide compute.admin."

  validation {
    condition     = can(regex("^\\.github/workflows/[A-Za-z0-9._-]+\\.ya?ml$", var.apply_workflow_path))
    error_message = "apply_workflow_path must be a workflow file under .github/workflows/, e.g. .github/workflows/apply-runner-pool.yml. GitHub reports no other location in job_workflow_ref."
  }
}

variable "allowed_ref" {
  type        = string
  default     = "refs/heads/main"
  description = "The one git ref whose runs may assume this identity. Note this is the WEAKEST of the three parts of the binding — a ref alone is reachable from pull_request_target and workflow_run — so it is the repository and the workflow file beside it that carry the boundary. Requires the provider to map attribute.job_workflow_ref (assertion.job_workflow_ref); adding that mapping is additive and does not disturb existing bindings."

  validation {
    # A bare "main" is the plausible mistake, and it is the DANGEROUS kind: it
    # produces a syntactically valid principalSet that matches no ref, so the
    # binding silently authorises nobody and the failure appears at assume time
    # as an opaque permission error. Refusing it here names the real problem.
    condition     = startswith(var.allowed_ref, "refs/")
    error_message = "allowed_ref must be a full git ref such as refs/heads/main. A bare branch name matches nothing, and the resulting failure surfaces as an unrelated-looking permission error when the workflow runs."
  }

  validation {
    # The claim carries one ref. A wildcard is not expanded by IAM — it is
    # matched literally — so "refs/heads/*" authorises a branch named "*".
    condition     = !can(regex("[*?]", var.allowed_ref))
    error_message = "allowed_ref takes ONE ref; IAM matches it literally and does not expand wildcards, so refs/heads/* authorises a branch literally named '*' and nothing else."
  }
}

variable "impersonable_service_accounts" {
  type        = list(string)
  description = "Emails of the service accounts this identity may attach to instances (the pool's host and job accounts). Enumerated rather than granted project-wide: actAs on the project turns compute.admin into 'act as the most privileged account in the project'."

  validation {
    condition     = length(var.impersonable_service_accounts) > 0
    error_message = "At least the pool's host service account must be listed, or every apply fails at the instance template — the one resource a release always changes."
  }
}
