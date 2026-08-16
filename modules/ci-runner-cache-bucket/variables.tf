variable "project_id" {
  description = "GCP project that owns the snapshot bucket."
  type        = string
}

variable "name" {
  description = <<-EOT
    Bucket name. Globally unique across all of Google Cloud, so prefix it with
    something project-specific — `<project>-ci-cache` is the usual shape.

    Deliberately NOT derived from the project id by this module. A generated
    name is unreadable in a bill, and a bucket whose name changes when a module
    input changes is a bucket that gets recreated empty under a running pool.
  EOT
  type        = string

  validation {
    # The service rejects the rest at apply time with a clear message; these two
    # are the ones that produce a confusing failure much later instead. An
    # underscore is legal in a bucket name but makes the bucket unreachable over
    # HTTPS with a virtual-hosted style URL, and a name with a dot is treated as
    # a domain and demands domain verification before it can be created at all.
    condition     = !strcontains(var.name, "_") && !strcontains(var.name, ".")
    error_message = "Bucket name must not contain '_' or '.': an underscore breaks virtual-hosted HTTPS access, and a dot makes the name a domain that must be verified before creation."
  }
}

variable "location" {
  description = <<-EOT
    Bucket location. Use the region the pools run in — a host hydrates its
    cache over this path at boot, and a cross-region read is the difference
    between the snapshot being faster than a cold start and being slower.

    Regional, not multi-region: this is a cache, so the extra durability of a
    multi-region buys nothing and the egress does cost something.
  EOT
  type        = string

  validation {
    # The prose above says regional; this makes it true. A multi-region name is
    # accepted by the service without complaint, so the only sign of the
    # mistake would be hydrate times that are slower than a cold start — the
    # exact failure this module exists to avoid, and an invisible one.
    condition     = length(regexall("^[a-z]+-[a-z]+[0-9]+$", var.location)) > 0
    error_message = "location must be a single region ('<continent>-<direction><n>'), not a multi-region ('US', 'EU', 'ASIA') or dual-region: a host hydrates over this path at boot, and a cross-region read makes the snapshot slower than starting cold."
  }
}

variable "snapshot_max_age_days" {
  description = <<-EOT
    Delete any object older than this many days.

    This is the bound on how long a poisoned cache entry can survive, not a
    housekeeping setting — see the comment on the lifecycle rule. Before the
    snapshot layer existed, a cache died with its host, and that was the bound.

    Keep it at or above the pool's own boot-time limit; a host that refuses
    snapshots older than its limit will simply start cold, whereas a bucket
    that expires them sooner than the host expects means every host starts
    cold and the layer silently does nothing.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.snapshot_max_age_days >= 1 && var.snapshot_max_age_days <= 30
    error_message = "snapshot_max_age_days must be between 1 and 30: below 1 the rule cannot express 'today', and above 30 the cache outlives any plausible dependency refresh while a poisoned entry keeps being served."
  }
}

variable "force_destroy" {
  description = <<-EOT
    Allow `terraform destroy` to delete the bucket with objects still in it.

    Default true because the contents are regenerable by definition. Set false
    only if this bucket has been given a second job, which is itself the thing
    to reconsider.
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Extra resource labels applied to the bucket."
  type        = map(string)
  default     = {}
}
