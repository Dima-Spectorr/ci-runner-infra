# ci-runner-cache-bucket

Where a pool's dependency cache lives **between hosts**.

Create it **once per project**, like `ci-runner-network`, and pass its name to
every pool in that project.

```hcl
module "ci_cache" {
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-cache-bucket?ref=v5.72.0"

  project_id = var.project_id
  name       = "${var.project_id}-ci-cache"
  location   = var.region
}
```

## Why this exists

A host's warm cache is private per slot and dies with the host — that is what
makes it safe, and it is documented in the host-pool README. The cost is that a
scale-out starts cold, which is precisely the moment the cache was worth the
most: the pool grew because jobs were queuing.

A snapshot in this bucket is what survives a host, so a booting host can hydrate
from it instead of downloading the internet again.

## One bucket, many pools

Pools are separated **inside** the bucket by object prefix, not by having a
bucket each. Two reasons:

- A bucket created per pool is destroyed with its pool. Consolidating two pools
  later, or renaming one, then takes the other's cache with it.
- A project with eight repositories would carry eight lifecycle rules, and the
  interesting failure is the one where seven of them agree.

The separation itself — the IAM grant conditioned on `cache/<pool>/` so one
pool cannot read another's cache — belongs to the **host-pool** module, because
it is a property of the identity doing the reading, not of the bucket.

The price of sharing is that `force_destroy` is project-wide: destroying this
module, or making a change that forces the bucket to be replaced, drops every
pool's cache at once and not just the pool being worked on. Nothing breaks —
the next boot of every host in the project starts cold — but the blast radius
is the project, and it is deliberately wider than the per-slot isolation the
rest of the design is built on.

That grant now exists: set `cache_snapshot_bucket` on a pool and the host-pool
module creates a `roles/storage.objectViewer` binding conditioned on
`cache/<pool>/`. Do not hand any identity a bucket-wide
`roles/storage.objectAdmin` as a stopgap — that is precisely the grant the prefix
condition exists to avoid, and it is much harder to take back once a pool depends
on it.

## Who may write here — decided, and it is not the hosts

**A host reads this bucket and never writes it.** That is the whole security
argument for the snapshot layer, so it is worth stating before any grant exists
to get wrong.

A host executes job code. If a host could publish a snapshot, then whatever a
job left in a cache would become the starting cache of every later host in that
pool — one job handing code to every future job, for as long as the age bound
allows. That is the same channel the per-slot isolation closed *within* a host
(host-pool README), re-opened across hosts and across time, and the per-slot
boundary would be worth nothing with it there. A pull request from a fork makes
it concrete: it would need only to run once.

So the write side belongs to a **separate identity that never runs pull-request
code**, publishing from the repository's default branch on a schedule. Jobs get a
warm cache and leave nothing behind.

Two grants, therefore, not one:

| Identity | Grant | Scope |
|---|---|---|
| pool host | read only | conditioned on that pool's prefix |
| snapshot producer | write | conditioned on that pool's prefix |

The host's grant is built by the host-pool module and is asserted by
`scripts/ci/shared-cache.selftest.sh`: `roles/storage.objectViewer`, never
`objectUser` or `objectAdmin`, so it carries no `storage.objects.create` and no
`storage.objects.delete`.

The producer's grant is now `ci-runner-cache-publisher`: an account with no key,
attached to no VM, assumable only through Workload Identity Federation by a run
of one named workflow file, in one named repository, on the default ref. It holds
create — not overwrite — under its own pool's prefix, and may replace exactly one
object, the pointer. What it runs is `scripts/ci/publish-cache-snapshot.sh`, from
a scheduled workflow in the consuming repository. Until that repository adds the
workflow nothing writes here, and a pool configured to read simply finds no
snapshot and runs on the cache its image baked.

**The other half — *and no one else* — this module does not state, and it says so
in the code rather than implying it.** Only an authoritative binding with an empty
member list could say it, and `setIamPolicy` has historically rejected a
memberless binding, so shipping one unverified would trade a control this module
does not have for an apply every consumer would have to fix. A bucket-wide
`objectAdmin` added by hand — the 2am stopgap for a failing publish — is therefore
still invisible to Terraform. Detect it with a periodic policy check or deny it
above the bucket with an IAM deny policy; the role list to cover is wider than it
looks, because `roles/storage.admin` and the legacy bucket/object roles also carry
`storage.objects.create`/`delete` (uniform bucket-level access disables ACLs, not
IAM roles), and project-level `roles/editor` confers two of them where no
bucket-level binding could reach.

## The age bound is a security control

Every object is deleted at `snapshot_max_age_days` (default 7) whether or not
anything replaced it, and that rule is not housekeeping.

A dependency cache is untrusted build input: every package manager treats its own
cache as already-verified, which is why `npx` executes straight out of the npm
cache and Maven skips checksums for an artifact already in the local repository.
Before this bucket existed, the bound on how long a poisoned entry could survive
was *"until the host is recycled"* — the cache died with the host, and hosts are
cattle. A snapshot that outlives hosts removes that bound. This rule puts it
back.

The intent is that a host applies the same bound again on the read side and
starts cold rather than accept a snapshot older than its own limit — two bounds,
because they fail differently: this one is enforced by the storage service and
holds even if the host script is broken, and the host-side one holds even if this
rule is edited away in the console.

Both bounds now exist. The host's is `cache_snapshot_max_age_hours` on the pool;
keep it at or below `snapshot_max_age_days × 24`, or the host's number is
decoration and the bucket's is the only one doing anything.

### What this demands of the publisher

Age is per generation, counted from when that generation was created, and an
overwrite does not inherit the age of what it replaced — with versioning off,
writing over an object leaves a generation aged zero. A publisher that refreshes
one stable key, `cache/<pool>/snapshot.tar.gz`, which is the obvious way to spell
"latest", therefore produces an object that **never** reaches the age bound and
never expires. The control would still be configured and would still be doing
nothing.

So the publisher owes this module two things, and the first is now enforced
rather than owed: its grant carries `storage.objects.create` and not
`storage.objects.delete` under the prefix, and an overwrite in Cloud Storage
needs delete — so a publisher that tries to refresh a stable key gets a 403
instead of quietly producing an object that never expires.

- snapshot objects carry a content hash or a timestamp in their name and are
  **written once, never overwritten**;
- the only rewritten object is the small pointer naming the current snapshot,
  which holds no cache content — its atomicity comes from an
  `ifGenerationMatch` precondition, not from retaining generations.

Expiry is also not instantaneous: Cloud Storage evaluates lifecycle rules
asynchronously and an object can outlive its rule by up to a day. The host-side
bound is what makes the boundary sharp.

Three settings exist to keep that bound from being quietly undone, and each is
set explicitly rather than left to a default:

| Setting | Value | Why not the default |
|---|---|---|
| `soft_delete_policy` | `0` (off) | Google enables soft delete by default on new buckets. An unset policy is a 7-day retention that keeps expired snapshots readable and billable *past* the age bound. |
| `versioning` | off | A superseded generation of a cache snapshot is exactly the poisoned copy the age bound expires. |
| `uniform_bucket_level_access` | on | With ACLs available, one object written with a permissive ACL routes around the prefix-conditioned IAM grant entirely. |

`public_access_prevention` is `enforced`: this is build output from a private CI
pool, and there is no reading public.

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `project_id` | string | — | Project that owns the bucket. |
| `name` | string | — | Globally unique. `<project>-ci-cache` is the usual shape. Not generated, so it stays readable in a bill and does not churn when an input changes. |
| `location` | string | — | The region the pools run in. Validated to be a region: a multi-region is accepted by the service and shows up only as a hydrate slower than the cold start it was meant to beat. |
| `snapshot_max_age_days` | number | `7` | 1–30. Keep at or above the pool's own boot-time limit. |
| `force_destroy` | bool | `true` | The contents are regenerable by definition. |
| `labels` | map(string) | `{}` | Merged with `component = ci-runner-cache-bucket`. |

## Outputs

| Name | Notes |
|---|---|
| `bucket_name` | Pass to each pool's `cache_snapshot_bucket`. |
| `bucket_url` | `gs://` URL, for inspecting snapshots by hand. |
| `snapshot_max_age_days` | So a pool can be configured to agree with the bucket rather than guess. |

## Provider version

This module requires **google >= 5.34.0**, where the other modules require
>= 5.0. `soft_delete_policy` was added to `google_storage_bucket` in 5.34.0, so
>= 5.0 would admit a provider that cannot express it — and on a provider that
merely ignores the argument, the bucket silently keeps Google's 7-day
soft-delete default and the age bound stops being true. Both floors are open, so
a configuration sharing one provider with the other modules simply resolves to
this one.
