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
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-cache-warmer?ref=v5.43.0"

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

Those six values plus a bucket are the whole configuration, and every one of
them is a fact the root already knows. **Nothing here describes the repository's
build**, and that is deliberate: the warm reads the repository.

| what | how it is decided |
|---|---|
| package manager | the lockfile — `pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`, else a bare `package.json`. `corepack` is enabled for the first two, so the version the repository pins is the version that installs. |
| the install | that manager's frozen-lockfile install, **without lifecycle scripts** for the snapshot, **with** them for the build step (see below) |
| where turbo writes | the module passes `--cache-dir` itself, from `turbo_cache_dir`, so it cannot drift from where the publishing step looks — a repository whose own CI builds with `--cache-dir=.turbo` still overrides nothing |

The rest of the defaults: nightly at 04:00 UTC, `node:22`, `E2_HIGHCPU_8`, a
one-hour timeout. `build_command = "true"` gives you the dependency snapshot and
no build artifacts, which is the right setting for a repository with no turbo
pipeline.

`prepare_command` and `build_command` are still there, and the honest advice is
not to use them. A command written here is a claim in a Terraform root about a
repository that can change package managers without telling it, and a stale
claim does not fail the apply — it fails inside a nightly build, or succeeds
having installed nothing. Both read from the outside as a cache that is merely
cold. Override only for a repository whose build genuinely is not
`turbo run build`, and expect to revisit it.

**The build step installs twice, on purpose.** The publishing script stages the
package stores under `mktemp -d`, and only `/workspace` survives between Cloud
Build steps. With npm that is invisible; pnpm's `node_modules` is a tree of links
into that store, so the build step would otherwise open a workspace whose every
dependency dangles, fail, and leave the turbo prefix empty without saying so. The
second install is also the one allowed to run lifecycle scripts — it exists to
run the repository's build, which is that repository's code by definition,
whereas the snapshot it does not touch is unpacked as root on every host.

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

The detected install for the **snapshot** runs no lifecycle scripts, for the same
reason. The build step's install does — it is there to run the repository's build
and cannot avoid running its code — but nothing that step installs goes into the
archive a host unpacks as root. A repository that needs lifecycle scripts inside
the snapshot itself overrides `prepare_command`, where the decision is visible in
a plan.

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

### Three refusals that all happen at FIRE time, and the last one says nothing

Every one of these applies green and breaks a build nobody is watching. All
three are fixed in the module and asserted by the self-test; they are written
down because each one, seen live, looks like a cold cache rather than a bug.

| symptom | cause | fixed in |
|---|---|---|
| `invalid value for 'build.substitutions': key in the template "…" is not a valid built-in substitution` | Cloud Build reads `$X` in any config string as a substitution, and the module pastes shell in whole. `$$` escapes it — **not** `substitution_option = "ALLOW_LOOSE"`, which resolves the unmatched keys to empty strings and runs the script with every variable erased. | v5.40.0 |
| `invalid build: invalid .steps field: build step 0 arg 1 too long (max: 10000)` | A step *argument* caps at 10,000 characters. The `script` field has no such cap and honours the file's own shebang; `entrypoint` beside `script` is an error. | v5.41.0 |
| **nothing at all** — a build id, `FETCHSOURCE` and `SETUPBUILD` done, every step `QUEUED`, no `BUILD` phase, no log, no error, until the queue TTL expires an hour later | A build message past roughly **128 KiB** is accepted and then never scheduled. Measured by bisection in one region of this fleet: 125 KB reached `BUILD` in two seconds, 140 KB never reached it; machine type, service account, step images and regional capacity make no difference. The module used to inline the 91 KB publishing script into two steps — a 199 KB config, so **no warm ever ran**. | v5.42.0 |

The last one is why the scripts are handed to the build **once**, gzipped, by a
`stage-scripts` step that unpacks them into `/workspace` — about 55 KB instead of
199 KB — and why the trigger carries a precondition that fails the *apply* if
that total climbs back toward the cliff. Add a script to this module by putting
it through the staging step, never by inlining it into the step that runs it.
