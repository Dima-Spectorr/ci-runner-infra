# ci-runner-cache-bucket — where a pool's dependency cache lives between hosts.
#
# A host pool's warm cache is per-slot and dies with the host (see the host-pool
# module's README). That is correct for isolation and useless for a scale-out:
# the moment the pool grows under load — exactly when the cache is worth the
# most — every new host starts cold. This bucket is where a snapshot of that
# cache survives a host, so a booting host can hydrate from it instead.
#
# ONE bucket serves MANY pools, and that is deliberate. A bucket created per
# pool would be destroyed with its pool, so tearing down pool A would take
# pool B's cache with it if they were ever consolidated later; and a project
# with eight repositories would carry eight buckets, eight lifecycle rules and
# eight chances for one of them to be configured differently from the rest.
# Pools are separated INSIDE the bucket, by object prefix, with the IAM grant
# conditioned on that prefix — that separation lives in the host-pool module,
# because it is a property of the identity, not of the bucket.
#
# This module is therefore created ONCE per project, like ci-runner-network,
# and its name is passed to every pool in that project.
#
# Resources:
#   google_storage_bucket — the snapshot bucket, with the age bound that keeps
#                           a poisoned cache entry from living forever

resource "google_storage_bucket" "cache" {
  project  = var.project_id
  name     = var.name
  location = var.location

  labels = merge(var.labels, {
    component = "ci-runner-cache-bucket"
  })

  storage_class = "STANDARD"

  # THE AGE BOUND, AND IT IS A SECURITY CONTROL RATHER THAN A COST ONE.
  #
  # A dependency cache is untrusted build input — every package manager treats
  # its own cache as already-verified, which is the whole argument in the
  # host-pool README. Until this bucket existed, the bound on how long a
  # poisoned entry could survive was "until the host is recycled", because the
  # cache died with the host. A snapshot that outlives hosts removes that bound
  # and puts nothing in its place, so the bound is restored here explicitly:
  # every object is deleted at this age whether or not anything replaced it.
  #
  # A host applies the same bound again on the read side, refusing a snapshot
  # older than its own limit and starting cold instead. Two bounds rather than
  # one because they fail differently: this one is enforced by the storage
  # service and survives a broken host script, while the host-side one still
  # holds if this rule is edited away in the console.
  #
  # THIS RULE CONSTRAINS THE WRITE PATH THAT DOES NOT EXIST YET. Age is measured
  # per generation, from that generation's creation, and an overwrite does not
  # carry the old generation's age forward: with versioning off, writing over an
  # object replaces it with a generation aged zero. So a publisher that keeps
  # refreshing one stable key — `cache/<pool>/snapshot.tar.gz`, the obvious way
  # to spell "latest" — produces an object this rule can never expire, and a
  # poisoned entry inside it would be re-served indefinitely. Snapshot objects
  # must therefore be written under content- or timestamp-qualified names and
  # never overwritten in place; only the small pointer object naming the current
  # snapshot is rewritten, and it carries no cache content.
  lifecycle_rule {
    condition {
      age = var.snapshot_max_age_days
    }
    action {
      type = "Delete"
    }
  }

  # OFF, and NOT the default. Soft delete retains every deleted object for its
  # retention window, which would keep a snapshot readable — and billable —
  # past the age bound above, defeating the one control this bucket has. It is
  # also the wrong shape for the content: snapshots are large, fully
  # regenerable, and replaced constantly, so retaining a copy of each deletion
  # roughly doubles the bill to protect data nobody would ever restore.
  #
  # Zero is how the API spells "disabled". Omitting this block does NOT mean
  # off: Google enabled soft delete by default on new buckets, so an unset
  # policy is a 7-day retention nobody asked for.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # Off for the same reason. Versioning keeps superseded generations, and a
  # superseded generation of a cache snapshot is exactly the poisoned copy the
  # age bound exists to expire. The pointer object's atomicity comes from a
  # generation precondition on write, not from retaining old generations.
  versioning {
    enabled = false
  }

  # No ACLs. With uniform access, the prefix-conditioned IAM grant the host-pool
  # module creates is the ONLY thing that decides who reads which pool's cache;
  # with ACLs available, a single object written with a permissive ACL would
  # quietly route around it.
  uniform_bucket_level_access = true

  # A cache snapshot is build output from a private CI pool. There is no reading
  # public and no accidental-exposure story worth having.
  public_access_prevention = "enforced"

  # True, and it is the safe direction here rather than the reckless one.
  # Everything in this bucket is regenerable by definition — a cache whose loss
  # costs anything but time is not a cache. Left false, destroying a project's
  # pools leaves a bucket Terraform refuses to remove and a human deletes by
  # hand, which is how a stale bucket with an old lifecycle rule outlives the
  # configuration that documented it.
  force_destroy = var.force_destroy
}
