# ci-runner-cache-warmer

The half of the caching layer that **writes**. One scheduled Cloud Build that
builds your default branch and publishes what it produced, into the two prefixes
every host in the pool already reads:

| prefix | what lands there | who reads it |
|---|---|---|
| `cache/<pool>/` | the dependency snapshot (`~/.npm`, `~/go/pkg/mod`, `~/.m2`, …) | a host, once, at boot |
| `turbo/<owner>/<repo>/` | turbo's finished task artifacts, one object per hash | the host's cache server, per task |

A repository configures nothing for either. That is the whole point of the
module, and it is not a convenience argument — see *Why this is fleet-side*.

## Using it

Next to the pool, once per repository:

```hcl
module "ci_cache_warmer" {
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-cache-warmer?ref=v5.39.0"

  project_id   = var.project_id
  region       = var.region
  pool_name    = "ci-runner-host-myrepo"      # the SAME name the pool has
  account_id   = "ci-runner-myrepo"           # `-warm` and `-fire` are appended
  cache_bucket = module.ci_cache.bucket_name
  github_owner = "my-org"
  github_repo  = "myrepo"

  # 2nd-generation projects only; omit on a project using gen1 triggers.
  github_connection = var.cloudbuild_github_connection
}
```

Everything else has a default: nightly at 04:00 UTC, `npm ci --ignore-scripts`,
`npx --no-install turbo run build`, `node:22`, `E2_HIGHCPU_8`, a one-hour
timeout. `prepare_command` is the one input a non-npm repository is likely to
have to state; `build_command = "true"` gives you the dependency snapshot and no
build artifacts, which is the right setting for a repository with no turbo
pipeline.

Run the first warm by hand rather than waiting for 04:00 — until one completes,
both caches are empty, which is a supported state and looks exactly like a warm
that is failing:

```bash
gcloud builds triggers run <trigger-name> --branch=main --region=<region> --project=<project>
```

## Why this is fleet-side, and not a workflow in your repository

Because the identity that writes cache content must never be one that runs
pull-request code, and it must never be one a repository can hold.

A turbo artifact is a tarball the next build unpacks into its output tree and
reports as its own result. A dependency snapshot is unpacked **as root** on every
host in the pool. Both are inputs to other people's builds, so whoever may write
them decides what those builds run. Publishing therefore happens in one place,
from one branch, under one account attached to no VM.

The previous answer to this was `ci-runner-cache-publisher`: workload-identity
federation, an OIDC provider mapping `attribute.job_workflow_ref`, a workflow
file in the consuming repository, and a schedule there too. It was correct and it
was four things a repository had to get right, one of which (the provider's
attribute mapping) the module could not check. This module needs none of them —
Cloud Build runs in the project that owns the bucket, so the account is local and
there is no federation to misconfigure.

### What it can do, stated plainly

Cloud Build cannot scope a *step's* identity: every step in the build can reach
the metadata server, so the step that runs `npm ci` can mint the warmer's token.
That is why the grants are what they are, and why they are worth reading:

* `objectCreator` on `turbo/<owner>/<repo>/` and on `cache/<pool>/` — create,
  **not** delete. Overwriting a live GCS object requires a delete, so published
  cache content is write-once by IAM rather than by convention. That is also
  what keeps the bucket's age bound meaningful: the bound is per generation, and
  an object replaced in place is a generation aged zero.
* `objectAdmin` on exactly one object, `cache/<pool>/current`, the pointer — with
  `resource.name ==`, never a prefix. A prefix condition there hands back the
  delete authority the split just removed.
* `roles/logging.logWriter` on the project, because a build naming its own
  service account must write its own logs.

Nothing else — and in particular **not** the right to start a build. Firing a
Cloud Build trigger cannot be scoped to one trigger, so the account allowed to
fire the warm is allowed to fire every trigger in the project, `ci-runner-apply-
trigger` included. That grant goes to a second account, `<account_id>-fire`,
which runs no code and is never presented by anything inside the build. Override
it with `scheduler_service_account` if the project already has an account for
this; it must live in the same project, which the module checks.

Nothing in any other pool's prefix or any other repository's.
The residual is that a compromised dependency in your default branch could
publish cache content — which is a dependency that is already installed on every
host in the pool, and would already be running there.

`prepare_command` defaults to `npm ci --ignore-scripts` for the same reason.
A repository that genuinely needs its install scripts overrides it in its own
tfvars, where the decision is visible in a plan.

### Two phases

The step that installs and builds does **not** upload. It writes the archive to
`/workspace`, and two later steps in a different image publish it. This does not
change what a compromised install *could* do — see above — but it keeps the
publishing steps small enough to read, and it is the same shape the workflow it
replaces used, for the same reason.

Step 3 also refuses to publish what the host-side server would refuse to serve:
a name that is not a hash, an artifact over `max_artifact_bytes`, or a prefix
missing its trailing slash. Publishing those costs storage and answers no read.

## Migrating off `ci-runner-cache-publisher`

For a repository already publishing snapshots by workflow:

1. Add this module. Run one warm by hand and confirm `cache/<pool>/current`
   moved and `turbo/<owner>/<repo>/` filled.
2. Delete the scheduled workflow from your repository.
3. Remove the `ci-runner-cache-publisher` module. Its account, its grants and its
   federation binding go with it — that is the point of removing it, and leaving
   it applied leaves an identity a workflow file can still assume.

The snapshot format is identical because both run the same script: this module
reads `scripts/ci/publish-cache-snapshot.sh` out of the repository root rather
than carrying a copy, so a host cannot start refusing hydrates because two
copies of the archive rules drifted. `scripts/ci/cache-warmer.selftest.sh` pins
that reference.

## Gen1 and gen2

`github_connection` is a read of what the project already has, not a preference.
The two are separate APIs and a trigger built against the generation a project
does *not* use is created without complaint and never fires. If another module
(`ci-runner-apply-trigger`, typically) already registered this repository under
the same connection, pass its id as `github_repository` — registering the same
remote twice is `ALREADY_EXISTS`, not a no-op.

Known gate: only some projects in this fleet have a Cloud Build GitHub
connection at all. Where there is none, this module is applied and inert until an
operator links one.

## Failure is silent, by construction

There is no run for a repository to watch and no check that turns red. A warmer
that publishes to the wrong prefix, publishes nothing, or is never fired all
present as "the cache is cold" — the same observable as a fleet that never had
one. That is why `scripts/ci/cache-warmer.selftest.sh` asserts the structure
(the prefixes, the write-once grants, the pointer condition, the schedule and
the account allowed to fire it) with a mutation proof behind each one, and why
`schedule` has no "off" value: use `disabled`, which at least shows up in a plan.
