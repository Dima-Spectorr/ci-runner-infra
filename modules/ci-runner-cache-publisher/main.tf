# ci-runner-cache-publisher — the identity allowed to write one pool's snapshots.
#
# The host-pool module gave a booting host a READ grant on `cache/<pool>/` and
# stopped there, deliberately: a host executes pull-request code, and an identity
# that both runs job code and publishes snapshots would let one job hand code to
# every later host in the pool, for as long as the age bound allows. That is the
# cross-slot boundary re-opened across hosts and across time.
#
# So the write side is a SEPARATE identity that never runs pull-request code, and
# what makes that true is not a promise in a workflow file — it is where the
# credential comes from. This account is assumable only through Workload Identity
# Federation, and only by a run whose OIDC token asserts the repository's default
# ref. A pull-request run's token asserts `refs/pull/<n>/merge`, which no binding
# here names, so a fork PR that adds a publish step to its own workflow gets a
# token GCP will not exchange.
#
# WHAT THE PUBLISHER MAY DO, AND WHY IT IS THREE GRANTS RATHER THAN ONE
#
#   1. create objects under `cache/<pool>/` — and nothing else. objectCreator
#      carries storage.objects.create and NOT storage.objects.delete, and in
#      Cloud Storage overwriting a live object requires delete. So "snapshots are
#      written once, never overwritten" stops being a convention the publisher is
#      trusted to honour and becomes something IAM refuses. That matters because
#      the bucket's age bound is measured per generation: an overwrite starts a
#      new generation aged zero, so an object refreshed in place never expires,
#      and a poisoned entry inside it would be re-served forever.
#   2. read what it wrote, under the same prefix — needed to fetch the pointer's
#      current generation before swapping it.
#   3. replace exactly ONE object: the pointer, `cache/<pool>/current`. This is
#      the only grant that carries delete, and its condition names a single
#      object rather than a prefix, so the authority to overwrite cannot reach a
#      snapshot even by naming one.
#
# The pointer swap is conditional on that generation (`--if-generation-match`),
# which is what makes two publishers racing produce one winner and one loud
# failure rather than a pointer naming a snapshot that was never fully written.
#
# WHAT THIS MODULE DOES NOT DO: it does not decide what goes INTO a snapshot.
# That is the publishing script's job, and the rule it must follow is stated here
# because the grant is worthless without it — the snapshot is built by installing
# dependencies from the DEFAULT BRANCH into a clean tree, never by archiving a
# host's live cache. A host's master cache is fed by snapshots and the image, and
# a slot's cache is fed by whatever job ran there; archiving either would put
# pull-request output back into the trusted path through the front door.
#
# Resources:
#   google_service_account            — the publisher, holding nothing else
#   google_service_account_iam_member — who may assume it (the default ref only)
#   google_storage_bucket_iam_member  — create+read on the prefix, replace on the
#                                       pointer

locals {
  # The same expression the host-pool module builds for the read side. Written
  # twice they would eventually disagree, and the failure would be quiet: the
  # publisher would write where no host looks, and every host would log a
  # snapshot that has not been published yet.
  cache_prefix = "cache/${var.name}/"

  # Fully qualified object names, the shape IAM conditions compare against.
  # `projects/_` is not a placeholder to be filled in — it is how a bucket is
  # addressed in a condition, because bucket names are global.
  prefix_resource  = "projects/_/buckets/${var.cache_snapshot_bucket}/objects/${local.cache_prefix}"
  pointer_resource = "projects/_/buckets/${var.cache_snapshot_bucket}/objects/${local.cache_prefix}current"
}

resource "google_service_account" "publisher" {
  project = var.project_id
  # 30 characters is the cap, and `-cache` costs six. Truncated the same way the
  # controller account is, so a long pool name fails at neither plan nor apply.
  account_id   = "${substr(var.account_id, 0, min(24, length(var.account_id)))}-cache"
  display_name = "CI cache publisher (${var.name})"
  description  = "Publishes dependency-cache snapshots for the ${var.name} pool. Assumable only by a run on the repository's default ref; must NEVER be attached to a host, which executes pull-request code."
}

# WHO MAY BECOME THE PUBLISHER. This is the security boundary of the whole
# snapshot layer, and it is one line, so it is the line most likely to be widened
# by someone whose workflow will not run.
#
# `attribute.ref` and not `attribute.repository`: binding to the repository as a
# whole would admit every branch and every workflow file in it, including one
# pushed to a branch by anyone who can open a pull request — which is exactly the
# identity this module exists to keep away from the write side. If a provider
# does not map `attribute.ref` yet, adding `attribute.ref: assertion.ref` to its
# mapping is additive and existing principalSets keep resolving; that is a
# one-command fix, not a reason to bind wider.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${var.workload_identity_pool}/attribute.ref/${var.allowed_ref}"
}

# Create, and only create. See the header: no delete means no overwrite, which is
# what keeps the bucket's age bound from being quietly defeated.
resource "google_storage_bucket_iam_member" "publisher_creates_snapshots" {
  bucket = var.cache_snapshot_bucket
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.publisher.email}"

  condition {
    title       = "only-this-pools-cache-prefix"
    description = "Create objects under ${local.cache_prefix} only. No other pool's snapshots, and nothing outside the cache tree."
    expression  = "resource.name.startsWith(\"${local.prefix_resource}\")"
  }
}

# Read, so the publisher can fetch the pointer's generation before swapping it
# and can confirm what it just uploaded. Viewer carries no create and no delete,
# so this widens nothing the grant above did not already decide.
resource "google_storage_bucket_iam_member" "publisher_reads_prefix" {
  bucket = var.cache_snapshot_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.publisher.email}"

  condition {
    title       = "only-this-pools-cache-prefix"
    description = "Read objects under ${local.cache_prefix} only."
    expression  = "resource.name.startsWith(\"${local.prefix_resource}\")"
  }
}

# The ONE object that may be replaced. `==` and not `startsWith`, and the
# difference is the whole point: a prefix condition here would hand back the
# delete authority the split above spent two resources removing.
#
# `var.name` and `var.cache_snapshot_bucket` are both interpolated into a CEL
# string literal, so both are validated to a charset that cannot carry a quote or
# a backslash — otherwise a pool named `x") || true || ("` would write a
# condition that is true for every object in the bucket.
resource "google_storage_bucket_iam_member" "publisher_replaces_pointer" {
  bucket = var.cache_snapshot_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.publisher.email}"

  condition {
    title       = "only-this-pools-current-pointer"
    description = "Replace ${local.cache_prefix}current only. The pointer holds no cache content; the snapshots it names are write-once."
    expression  = "resource.name == \"${local.pointer_resource}\""
  }
}
