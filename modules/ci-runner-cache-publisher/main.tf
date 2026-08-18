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
# Federation, and only by a run of ONE named workflow file, in ONE named
# repository, on that repository's default ref. Everything else in the federation
# — another repository under the same pool, another workflow in this one, the
# same workflow on a branch — gets a token GCP will not exchange.
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
# The pointer swap is conditional on that generation (`ifGenerationMatch`),
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
  # 30 characters is the cap and `-cache` costs six, so the base is VALIDATED to
  # 24 rather than truncated to it. Truncation is the silent failure: two pools
  # whose ids differ only after the 24th character would resolve to one account,
  # and whichever applied second would either collide or — if the account were
  # ever adopted — hold both pools' prefix grants at once.
  account_id   = "${var.account_id}-cache"
  display_name = "CI cache publisher (${var.name})"
  description  = "Publishes dependency-cache snapshots for the ${var.name} pool. Assumable only by a run on the repository's default ref; must NEVER be attached to a host, which executes pull-request code."
}

# WHO MAY BECOME THE PUBLISHER. This is the security boundary of the whole
# snapshot layer, and it is one line, so it is the line most likely to be widened
# by someone whose workflow will not run.
#
# `attribute.job_workflow_ref`, and NEITHER `attribute.repository` NOR
# `attribute.ref` — because each of those alone is open in a direction that is
# easy to miss:
#
#   attribute.repository admits every branch and every workflow file in the
#   repository, including one pushed to a branch by anyone who can open a pull
#   request. That is the identity this module exists to exclude.
#
#   attribute.ref is not "narrower than repository" — it is a DIFFERENT axis, and
#   binding it alone is open twice over. GitHub uses one OIDC issuer for all of
#   github.com and a pool is normally shared by every repository in the org, so
#   `attribute.ref/refs/heads/main` matches a run on ANY of their default
#   branches; and if the provider carries no attribute condition, any repository
#   on GitHub. Worse, `refs/heads/main` is reachable from attacker-triggered
#   events: for `pull_request_target`, `workflow_run`, `issue_comment` and
#   `schedule`, GITHUB_REF — which the `ref` claim mirrors — is the DEFAULT
#   BRANCH. The standard `pull_request_target` + checkout-the-head-sha pattern
#   therefore runs fork-authored code inside a run whose token asserts
#   refs/heads/main. Binding on ref alone hands that run the write grant.
#
# `job_workflow_ref` closes both, because one claim carries all three facts:
# `<owner>/<repo>/.github/workflows/<file>@<ref>`. A fork cannot change that file
# on the default ref, another repository cannot produce this repository's value,
# and another workflow in this repository — including a `pull_request_target` one
# — produces a different filename.
#
# TWO PREREQUISITES ON THE PROVIDER, which this module cannot express and does
# not silently assume (see the README):
#   1. the provider maps `attribute.job_workflow_ref = assertion.job_workflow_ref`.
#      Adding a mapping is additive; existing principalSets keep resolving.
#   2. the provider carries an attribute condition pinning the org, by NUMERIC id
#      (`assertion.repository_owner_id == '<id>'`). Without it the pool federates
#      all of GitHub, and the pin below is the only thing standing in the way.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${var.workload_identity_pool}/attribute.job_workflow_ref/${var.repository}/${var.publish_workflow_path}@${var.allowed_ref}"
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
# objectAdmin on this one object also carries storage.objects.update and the
# retention permissions, so a compromised publisher can pin a hold on the pointer
# and stop the next legitimate publish from replacing it. That is availability
# only — it cannot make a host read anything the publisher did not already write
# — and it is the price of the object needing to be replaceable at all.
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
