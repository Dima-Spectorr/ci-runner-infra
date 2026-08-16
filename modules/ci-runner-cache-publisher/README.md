# ci-runner-cache-publisher

The identity allowed to **write** one pool's cache snapshots — and the reason a
host is not it.

Create it **once per pool**, next to the pool, and point a scheduled workflow on
the default branch at its service account.

```hcl
module "ci_cache_publisher" {
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-cache-publisher?ref=v5.18.0"

  project_id            = var.project_id
  name                  = "ci-runner-host-myrepo"       # the SAME pool name
  account_id            = "ci-runner-myrepo"
  cache_snapshot_bucket = module.ci_cache.bucket_name
  workload_identity_pool = "projects/123456789/locations/global/workloadIdentityPools/github"
  allowed_ref            = "refs/heads/main"
}
```

## Why the write side is a different identity

A host executes pull-request code. If a host could publish, whatever a job left
in a cache would become the starting cache of every later host in that pool, for
as long as the age bound allows — one job handing code to every future job. That
is the per-slot boundary re-opened across hosts and across time, and a fork PR
would need to run once.

What keeps this account away from job code is not a rule in a workflow file. The
account has no key and is not attached to any VM; the only way in is Workload
Identity Federation, bound to `attribute.ref` of the repository's default branch.
A pull-request run's OIDC token asserts `refs/pull/<n>/merge`, which nothing here
names, so the exchange fails before any grant is consulted.

## Three grants, because one would be wrong

| Grant | Scope | Carries |
|---|---|---|
| `roles/storage.objectCreator` | `cache/<pool>/` | create — **no delete** |
| `roles/storage.objectViewer` | `cache/<pool>/` | read |
| `roles/storage.objectAdmin` | `cache/<pool>/current` **only** | replace the pointer |

Overwriting a live object in Cloud Storage needs `storage.objects.delete`. The
publisher does not have it under the prefix, so **"snapshots are written once"
stops being a convention and becomes something IAM refuses.** That is load
bearing: the bucket's age bound is per generation, so an object refreshed in
place is a generation aged zero that never expires — the control would still be
configured and would be doing nothing.

The one object that must be rewritten is the pointer, and its grant names that
object with `==` rather than a prefix. Swap it with `--if-generation-match` so
two publishers racing produce one winner and one loud failure, never a pointer
naming a half-written snapshot.

## What a snapshot must be built from

**Install dependencies from the default branch into a clean tree, and archive
that.** Never archive a host's live cache:

- a **slot's** cache holds whatever job last ran there, including a fork's pull
  request — archiving it walks pull-request output into the trusted path through
  the front door, which is the whole thing this module prevents;
- a **host's master** cache holds only what the image baked plus what a previous
  snapshot brought, so archiving it adds nothing and slowly compounds whatever
  an earlier snapshot got wrong.

The publishing script that does this is not in this repo yet. Until it exists the
grants sit unused, every pool finds no snapshot, and hosts run on the cache their
image baked — a supported state, not a misconfiguration.

## Size is a contract, not an accident

A host refuses a snapshot larger than its `cache_snapshot_max_bytes` (default 4
GiB, compressed) and needs eight times that free on `/opt` to unpack it. A
publisher that quietly grows past the bound produces snapshots every host
silently refuses, which reads in the logs as "no snapshot published". Keep the
archive comfortably under the pools' bound, and raise the pools first when it
must grow.

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `project_id` | string | — | Same project as the pool. |
| `name` | string | — | The pool name. Decides the prefix; must match the pool's. |
| `account_id` | string | — | Base for the account id; `-cache` is appended, base truncated to fit 30 characters. |
| `cache_snapshot_bucket` | string | — | Bucket **name**, not a `gs://` URL. Validated, because it is interpolated into an IAM condition. |
| `workload_identity_pool` | string | — | Full pool resource name, using the project **number**. Its provider must map `attribute.ref`. |
| `allowed_ref` | string | `refs/heads/main` | Branch refs only — a tag is movable and a pull-request ref carries unreviewed code. |

## Outputs

| Name | Notes |
|---|---|
| `service_account_email` | For `google-github-actions/auth` in the publish workflow. |
| `cache_prefix` | `cache/<pool>/` — the prefix both sides derive from the pool name. |
| `pointer_object` | The one object that may be replaced. |
