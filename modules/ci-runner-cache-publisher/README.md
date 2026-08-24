# ci-runner-cache-publisher

The identity allowed to **write** one pool's cache snapshots — and the reason a
host is not it.

Create it **once per pool**, next to the pool, and point a scheduled workflow on
the default branch at its service account.

```hcl
module "ci_cache_publisher" {
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-cache-publisher?ref=v5.45.0"

  project_id             = var.project_id
  name                   = "ci-runner-host-myrepo"      # the SAME pool name
  account_id             = "ci-runner-myrepo"
  cache_snapshot_bucket  = module.ci_cache.bucket_name
  workload_identity_pool = "projects/123456789/locations/global/workloadIdentityPools/github"
  repository             = "<org>/<repo>"
  publish_workflow_path  = ".github/workflows/publish-cache-snapshot.yml"
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
Identity Federation, bound to **one workflow file, in one repository, on one
ref** — a single `job_workflow_ref` claim carrying all three.

### Why not just the ref

Because `attribute.ref` alone is open in two directions that are easy to miss,
and both were found in review of this module before it shipped:

- **A pool is shared.** GitHub uses one OIDC issuer for all of github.com, and a
  workload identity pool normally federates every repository in the org. So
  `attribute.ref/refs/heads/main` matches a run on **any** of their default
  branches — and if the provider carries no attribute condition, any repository
  on GitHub.
- **`refs/heads/main` is reachable from a pull request.** For
  `pull_request_target`, `workflow_run`, `issue_comment` and `schedule`,
  `GITHUB_REF` — which the `ref` claim mirrors — is the **default branch**. The
  ordinary `pull_request_target` + check-out-the-head-sha pattern therefore runs
  fork-authored code inside a run whose token asserts `refs/heads/main`.

Pinning the workflow file closes both: a fork cannot change that file on the
default ref, another repository cannot produce this repository's claim, and a
`pull_request_target` workflow in this repository has a different filename.

### Two things the provider must do, which this module cannot

The module creates no provider, so it cannot enforce either — check both before
believing the boundary above:

1. **Map the claim.** `attribute.job_workflow_ref = assertion.job_workflow_ref`.
   Adding a mapping is additive; existing principalSets keep resolving.
2. **Pin the org, by numeric id.** An attribute condition such as
   `assertion.repository_owner_id == '<numeric id>'`. The name is renameable and
   re-registrable; the id is not. Without a condition the pool federates all of
   GitHub, and only the principalSet stands in the way.

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
object with `==` rather than a prefix. Swap it with a generation precondition so
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

The script that does this is `scripts/ci/publish-cache-snapshot.sh`, and
`docs/publishing-a-cache-snapshot.md` is the workflow that runs it — two jobs,
because the phase that installs dependencies runs third-party code and must not
be the phase holding this identity's token. Until a
repository adds that workflow the grants sit unused, every pool finds no
snapshot, and hosts run on the cache their image baked — a supported state, not a
misconfiguration.

The script refuses to run from a `pull_request_target`, `workflow_run` or
`issue_comment` event. That is not redundant with the binding: the binding pins
repository, workflow file and ref, and cannot pin the **event** — those three
assert the default ref while running untrusted code, so without the check an edit
to the trigger would be handed a working credential.

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
| `account_id` | string | — | Base for the account id; `-cache` is appended. 6–24 characters, validated rather than truncated — two bases differing past a truncation point would silently share one account. |
| `cache_snapshot_bucket` | string | — | Bucket **name**, not a `gs://` URL. Validated, because it is interpolated into an IAM condition. |
| `workload_identity_pool` | string | — | Full pool resource name, using the project **number**. Its provider must map `attribute.job_workflow_ref` and pin the org by numeric id. |
| `repository` | string | — | `<owner>/<repo>`. No default: a guess would bind to somebody else's repository. |
| `publish_workflow_path` | string | `.github/workflows/publish-cache-snapshot.yml` | The one workflow file that may publish. |
| `allowed_ref` | string | `refs/heads/main` | Branch refs only — a tag is movable and a pull-request ref carries unreviewed code. The weakest of the three parts; see above. |

## Outputs

| Name | Notes |
|---|---|
| `service_account_email` | For `google-github-actions/auth` in the publish workflow. |
| `cache_prefix` | `cache/<pool>/` — the prefix both sides derive from the pool name. |
| `pointer_object` | The one object that may be replaced. |
