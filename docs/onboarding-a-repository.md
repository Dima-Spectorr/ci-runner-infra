# Putting a repository on the shared CI fleet

Everything a new consumer needs, in the order it has to happen. Written because
the answer previously lived only in six already-onboarded roots — readable, but
only if you already knew which one was current.

Budget roughly an hour, most of it waiting on a first `terraform apply`.

## What you get

A per-repository pool of **warm hosts**: persistent VMs booted from the shared
golden image, each running `slots_per_host` runner agents, each agent with its
own Linux user and its own rootless Docker daemon. Jobs run on a host that is
already booted, already has the toolchain, and already has a warm cache. The
pool scales to **zero** when the repository is idle — the only always-on cost is
one `e2-micro` controller.

Concurrency is `max_hosts × slots_per_host`, **not** `max_hosts`. Two hosts of
four slots serve eight concurrent jobs.

The same module also serves **Windows** hosts (`host_os = "windows"`), warm and
scaling to zero like these — but with a different isolation model and a security
posture you opt into knowingly. Read [Windows](#windows) before you declare one.

## Before you start

1. **The GitHub App is installed on the repository.** The fleet authenticates as
   one App, not as a PAT. You need its **app id** and the **installation id**
   for the account that owns the repo — both non-secret. The private key is not
   in any repository or state file; see step 3.

   Its installation needs **`checks: read`** in addition to the permissions the
   runners themselves use. Nothing about job execution depends on it — without
   it the pool scales, registers and runs jobs exactly as it does with it. The
   one thing it buys is the merge-queue parking detector below: the controller
   reads each open pull request's check runs to decide whether a pull request
   the queue will never admit is nevertheless finished and green. Missing the
   permission does not fail an apply or a job, and `ci_prs_green_and_unqueued`
   then publishes an unbroken zero — which is exactly what a repository with
   nothing parked publishes. So the controller says so in its own right:
   `ci_parked_sweep_denied` goes non-zero, the log line reads `parked sweep:
   DENIED`, and the `parkeddenied` alert fires after 30 minutes. If you see
   either, grant the permission on the App **and accept it on the installation**
   — a permission added to an App stays pending until the installation approves
   it, and a pending permission behaves exactly like one that was never
   granted.

   It needs **`Contents: read`** as well if you are standing up a merge-queue
   pool (step 8): that is how the controller reads the repository's own
   `.mergify.yml` to size the pool. This one fails the same quiet way — without
   it the pool keeps the Terraform ceiling you typed and says nothing, and
   `ci_queue_config_age_seconds` climbing is the only sign.
2. **A GCP project, a VPC and a subnet** in the region the pool will run in.
   Hosts get no external IP: egress must already work from that subnet (in the
   MOT projects it is the peering to `mot-lz-vpc` through the central firewall —
   **do not add a Cloud NAT**, it would bypass that firewall).
3. **Terraform ≥ 1.5**, and credentials for the project. Never mutate the
   ambient `GOOGLE_APPLICATION_CREDENTIALS`: it is shared. Point Terraform at a
   different identity process-locally, for the one command.

## 1. Create the Terraform root

One root per repository, with its own state. Convention is
`infra/terraform/ci-runners/` (some repos use
`customer/<customer>/terraform/ci-runner-hosts/` — either is fine, keep it
separate from the application's root so the pool can be replaced independently).

Copy `main.tf` from any current consumer — the shape is identical everywhere —
or start from this minimum:

```hcl
module "ci_runner_network" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-network?ref=v5.40.0"

  project_id         = var.project_id
  network            = var.network
  name_prefix        = var.pool_name
  runner_network_tag = "${var.pool_name}-host"
}

module "ci_runner_identity" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-identity?ref=v5.40.0"

  project_id        = var.project_id
  name              = var.pool_name
  account_id        = var.runner_account_id   # <= 26 chars; the module suffixes it
  app_key_secret_id = var.app_key_secret_id
}

module "ci_runner_pool" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.40.0"

  project_id = var.project_id
  region     = var.region
  name       = var.pool_name

  github_owner = var.github_owner
  github_repo  = var.github_repo

  github_app_id                 = var.github_app_id
  github_app_installation_id    = var.github_installation_id
  github_app_private_key_secret = module.ci_runner_identity.app_key_secret_name

  # Three identities, deliberately. The HOST account can read the App key; the
  # CONTROLLER account can delete instances (that is what scale-in is); the JOB
  # account is what pull-request code gets, and starts with nothing. The module
  # rejects any two of them being the same account — see "Isolation rules" in
  # the README for why that is a hard failure and not a warning.
  service_account_email            = module.ci_runner_identity.service_account_email
  controller_service_account_email = module.ci_runner_identity.controller_service_account_email
  job_service_account_email        = module.ci_runner_identity.job_service_account_email

  network      = var.network
  subnetwork   = var.subnet_self_link
  network_tags = [module.ci_runner_network.runner_network_tag]

  image          = var.host_image        # e.g. ci-runner-host-v3-12-0
  machine_type   = var.host_machine_type
  slots_per_host = var.slots_per_host

  runner_labels = var.runner_labels
  min_hosts     = 0
  max_hosts     = var.max_hosts

  # How many hosts may be mid-recycle at once when an apply changes the
  # instance template. 0 — the default — means a busy pool NEVER adopts a new
  # template, because the only other thing that replaces a host is the idle
  # timeout and a pool with work does not go idle. Set it to 1 unless you have a
  # reason not to; see "Getting a new template onto a busy host" in the README
  # for the two-phase cordon/retire and why no running job is ever interrupted.
  recycle_max_unavailable = 1
}
```

`module.ci_runner_network` (IAP-SSH + health-check ingress, narrowed egress, an
explicit deny-all, and database egress to private addresses only) is per
*project*, not per pool. Instantiate it once; if the project already runs a pool,
reuse the existing tag instead of declaring a second copy.

Its `database_egress_ports` default is the common set — SQL Server, Oracle,
MySQL, PostgreSQL, Redis, Cassandra, MongoDB — and not any one repository's
port, because the failure it prevents is invisible: the egress allow is narrowed
to 443 and DNS, so an integration test whose port is missing does not get a
refusal, it gets a client that hangs until the job times out. The destination is
what keeps it safe (`database_egress_ranges`, RFC1918 only), so adding a port is
routine and widening the ranges is not. A project whose runners must reach no
database at all sets `database_egress_ports = []` and no rule is created.

### If the project has a cache-snapshot bucket

A host boots with the cache its image baked, which ages with the image. If the
project runs `ci-runner-cache-bucket` (once per project, like the network), point
the pool at it and a booting host hydrates from this pool's current snapshot
instead:

```hcl
  cache_snapshot_bucket = module.ci_cache.bucket_name
```

That is the whole change. The module then grants this pool's HOST account
`roles/storage.objectViewer` **conditioned on `cache/<pool>/`** — read only, this
pool only. Nothing on a host ever writes there.

Publishing is a **different identity**, and it is not yours: add
`ci-runner-cache-warmer` next to the pool and it produces the snapshot for you,
nightly, from your default branch.

```hcl
module "ci_cache_warmer" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-cache-warmer?ref=v5.40.0"

  project_id   = var.project_id
  region       = var.region
  pool_name    = "ci-runner-host-myrepo"   # the SAME pool name
  account_id   = "ci-runner-myrepo"
  cache_bucket = module.ci_cache.bucket_name
  github_owner = "<org>"
  github_repo  = "<repo>"

  github_connection = var.cloudbuild_github_connection # gen2 projects only
}
```

**Nothing there describes your build, and nothing should.** The warm reads your
lockfile — pnpm, yarn, npm, in that order — installs the way that manager
installs, and runs `turbo run build` with a `--cache-dir` it passes itself. A
repository that builds with pnpm and `--cache-dir=.turbo` sets none of it. The
`prepare_command` / `build_command` inputs exist for a build that genuinely is
not that, and a command written into a Terraform root is a claim about a
repository that can change package managers without telling the root — stale, it
does not fail the apply, it fails at 04:00 into a log nobody reads.

That is a Cloud Build in *this project*, so there is no federation, no OIDC
provider to map, no credential in your repository and no workflow file to keep.
The account it runs as is attached to no VM, may create objects under this pool's
prefix and may not overwrite them — `storage.objects.delete` is absent, which is
what keeps the bucket's age bound real — and may replace exactly one object, the
`current` pointer.

Run one by hand rather than waiting for 04:00:
`gcloud builds triggers run <name> --branch=main --region=<region>`. Until a warm
completes, a pool configured this way finds no snapshot and runs on the baked
cache — a supported state, not a misconfiguration.

`modules/ci-runner-cache-warmer/README.md` has the rest, including what to do if
you already publish snapshots from a workflow of your own: that path
(`ci-runner-cache-publisher` plus `docs/publishing-a-cache-snapshot.md`) still
works and is now the fallback, for a repository whose build genuinely cannot run
in Cloud Build.

Three bounds have defaults worth leaving alone unless you have a measurement:
`cache_snapshot_max_age_hours` (168) is a security control and must stay at or
below the bucket's own `snapshot_max_age_days × 24`;
`cache_hydrate_budget_seconds` (60) is the entire time a host will spend on this
before giving up and registering anyway; `cache_snapshot_max_bytes` (4 GiB)
refuses a snapshot too large to unpack safely. Every failure inside that budget
is a log line and a cold first job, never a host that does not come up.

### The remote build cache, which you configure by not configuring it

A dependency cache saves downloading; a **build** cache saves building, and it
does it *across* pull requests — where a path filter only ever helps inside one.
On a monorepo that is the largest remaining term in a run (see
`ci-optimization-catalog.md` 4.4).

If your pool has `cache_snapshot_bucket`, you already have it. The host runs a
Turborepo remote cache server and sets `TURBO_API`, `TURBO_TOKEN` and
`TURBO_TEAM` for every slot, so `turbo` finds it with **no workflow change, no
bucket of your own, no token to rotate and no `gcloud` call in your build**.
Artifacts live under `turbo/<owner>/<repo>/` in the same bucket, so two pools
serving one repository share hits and two repositories share nothing.

That default is deliberate and it is the point of the layer. The one repository
in this fleet that wired a build cache into its own workflows ran it **stone cold
for weeks** while every run stayed green: a hand-wired cache fails as one warning
per artifact, and nobody reads two hundred of those. A capability every
repository has to assemble by hand is a capability most of them will have
subtly, invisibly wrong.

Three things worth knowing before you look for a knob:

* **Your jobs cannot write to it, and the misses you see on a new branch are
  correct.** A host runs pull-request code, and a turbo artifact is a tarball
  the next build unpacks into its output tree and reports as its own result — so
  a job that could publish one would hand every later build in the repository
  its output. Uploads are accepted and discarded, which is why your build log
  says it uploaded and a later run still misses. The store is filled from your
  **default branch**, by an identity that never runs pull-request code — the
  same `ci-runner-cache-warmer` that publishes your dependency snapshot. One
  module fills both caches; if you added it above, this one is already warm.
* **Nothing about it can fail your job.** A server that does not start, a bucket
  that cannot be read, an artifact over the size bound: every one of them is a
  cache miss and a task that builds normally. The host logs the verdict.
* **`turbo_cache_bucket` exists, and you should not need it.** Unset follows
  `cache_snapshot_bucket`; `""` turns the layer off for a pool that must hydrate
  dependencies but serve no build artifacts; a name points it somewhere else.

### If your jobs run in a container from a private registry

`jobs.<id>.container` and `services:` images are pulled by the slot's own
rootless daemon, which authenticates as the **JOB** account — the same identity
the job itself gets, not the host's. The hosts install a credential helper for
their own region's Artifact Registry and the Container Registry hosts
automatically, so nothing is needed in the workflow, but the JOB account still
needs read access to the registry:

```hcl
resource "google_artifact_registry_repository_iam_member" "job_pull" {
  project    = var.project_id
  location   = var.region
  repository = var.container_repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${module.ci_runner_identity.job_service_account_email}"
}
```

Without it the job fails at **Initialize containers**, before any step runs, with
`Unauthenticated request ... "artifactregistry.repositories.downloadArtifacts"`.
Grant it to the JOB account and never to the host account — that one can read the
GitHub App private key.

If the image lives in **another region or project**, add its hostname to the pool
module's `extra_registry_hosts`. Docker matches credential helpers by exact
hostname, so a pattern (`*.pkg.dev`) is never consulted — the pull goes out
anonymous and fails with the same message as a missing grant, which is the more
expensive of the two to diagnose.

**Do not vendor the modules.** A drift gate
(`scripts/ci/check-no-vendored-ci-module.sh`) fails CI if a local
`infra/terraform/modules/ci-runner-*` reappears. Vendoring is what put nine
divergent copies of the scale-in rule in the fleet.

## 2. Pick the labels — this is the step that silently fails

`runner_labels` must be exactly what the repository's workflows already ask for:

```yaml
runs-on: [self-hosted, linux, gcp, <Repo>]
```

GitHub dispatches on a **superset** rule, and a job whose `runs-on` matches no
registered runner **does not fail — it queues until it times out**. So a typo
here does not produce an error you can read; it produces a pull request that
appears to hang. Register the labels the workflows already use and no workflow
edit is needed at all.

**Three of those labels are not yours to register.** The agent adds
`self-hosted`, the OS (`Linux` or `Windows`) and the architecture (`X64`) by
itself; GitHub marks them `read-only` and no `--labels` argument creates or
removes them. So `runner_labels` in the example above is `gcp, <Repo>` — the
module prepends `self-hosted` and the pool name, and the OS comes from
`host_os`. Listing `linux` yourself is not an error, only a duplicate.

Case is not yours either: GitHub routes case-insensitively, so a workflow saying
`linux` reaches an agent registering `Linux`. The controller folds both sides
before it counts, which it did not always do: every pool in the fleet reported
0 demand and never scaled out until #284, because the configured list had no OS
label in it and every workflow asked for one.

The controller counts demand against that same set. Labels that no workflow asks
for produce a pool that never scales out; labels asked for but never registered
produce jobs that never start.

## 3. Put the App private key in Secret Manager

The identity module creates the secret **container**; the value is added out of
band so it appears in no state file and no repository:

```bash
gcloud secrets versions add <app_key_secret_id> --project=<project> --data-file=<key.pem>
```

Do this before the first apply, or the first host will boot, fail to mint a
token, and register nothing.

## 4. Apply, and read the plan

The guard is **not** part of your repository — it ships with the modules, in
`ci-runner-infra`. Clone that once and run it against your root; every git and
terraform call it makes is `-C`/`-chdir`-scoped to the directory you pass, so it
does not matter where you stand:

```bash
ROOT=~/src/<your-repo>/infra/terraform/ci-runners
terraform -chdir="$ROOT" init -input=false     # add -backend-config below if partial
~/src/ci-runner-infra/scripts/ci/tf-apply-guard.sh "$ROOT"
```

It plans, shows you the plan, refuses the ways this has actually gone wrong, and
only then applies **that** plan file:

| refusal | meaning | override |
|---|---|---|
| `dirty` | uncommitted changes in the root (including `.terraform.lock.hcl`) | commit them |
| `stale` | HEAD is not `origin/HEAD` | fix the checkout; `TF_GUARD_ALLOW_UNMERGED=1` only to test a branch |
| `refuse-protected` | the plan destroys a service account or the App-key secret | `TF_GUARD_CONFIRM_PROTECTED=<digest>` — decommissioning a pool is legitimate, but it takes its own token |
| `refuse-destroy` | the plan destroys other resources | `TF_GUARD_CONFIRM_DESTROY=<digest>` after reading every address it printed |

Both tokens are a **hash of the destroyed addresses**, printed by the refusal
that asks for them, not a count or a yes. A confirmation left exported by an
earlier run therefore cannot wave through a different plan, and a plan that grows
a resource between reading and confirming stops matching.

**Never `apply -auto-approve` on a plan nobody read.** On 2026-08-14 a `git pull`
failed inside a loop, the loop continued, and `terraform apply -auto-approve` ran
against a months-old commit: 35 resources destroyed, including the Secret Manager
secret holding the GitHub App key. The tree was *clean* — clean is not current.
`prevent_destroy` was live on that secret and did nothing, because a configuration
that has no module block has no lifecycle guard either. That is why the check sits
in a wrapper above Terraform rather than inside the module.

Some roots use a **partial backend** (`backend.tf` omits `bucket`); those need
`-backend-config=bucket=<state-bucket>` on `init`. Without it, `init` fails with
the misleading "querying Cloud Storage failed: storage: bucket doesn't exist".

## 5. Verify — three checks, in this order

```bash
# 1. hosts exist and carry the template you just applied
gcloud compute instance-groups managed list-instances <name>-hosts \
  --project=<project> --region=<region> \
  --format="csv[no-heading](name,instanceStatus,version.instanceTemplate.basename())"

# 2. every slot registered
gh api repos/<owner>/<repo>/actions/runners \
  --jq '.runners[]|"\(.name) \(.status) busy=\(.busy)"'

# 3. the pool goes back to zero when the queue drains
gcloud compute instance-groups managed describe <name>-hosts \
  --project=<project> --region=<region> --format="value(targetSize)"
```

A host that boots but registers **zero** slots is the expected shape of a
*safety* failure, not a mystery: the startup script refuses to register agents if
it cannot mask the rootful Docker daemon or cannot install the metadata fence.
Read `/var/log/ci-host.log` on the host over IAP-SSH.

`0` in check 3 on an idle repository is scale-to-zero working, not a broken
pool. Compare against the queue before treating it as an outage.

## Hand the root to an unattended apply — do not skip this

The apply above is the **only** one a human is supposed to run. If it is also the
last one, the pool is frozen at whatever `ci-runner-infra` looked like today: a
release that fixes a host defect lands in a tag and never reaches a machine, and
nobody notices until the defect does something. A root pinned to `?ref=v5` is the
sharper case — it has **no commit to make** when v5.7.1 ships, so there is not
even a push to react to.

Add the trigger to the same root, and let the project's own Cloud Build own every
later apply:

```hcl
module "ci_runner_apply_trigger" {
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-apply-trigger?ref=v5.40.0"

  project_id     = var.project_id
  region         = var.region
  github_owner   = var.github_owner
  github_repo    = var.github_repo
  terraform_root = "infra/terraform/ci-runners"   # this root, repo-relative

  # The project's EXISTING CD account. This module creates no identity.
  service_account = "<cd-sa>@<project>.iam.gserviceaccount.com"

  # Pick a minute no other repository in the fleet uses. Every scheduled apply
  # firing on the hour is how a provider rate limit becomes a fleet-wide outage.
  apply_schedule = "23 4 * * *"
}
```

**If this root uses the partial backend described in step 4, pass the bucket
here too** — the build's `init` hits the same wall the manual one did, with the
same misleading message, on a schedule nobody is watching:

```hcl
  backend_config = { bucket = "<state-bucket>" }
```

Bucket and prefix only. Credential keys are rejected at plan time: the value
would be stored in the trigger and printed in every build log, and the build
already authenticates as the service account above.

**If the project links GitHub the 2nd-gen way, add its connection**, and the
module registers the repository under it rather than expecting a GitHub App
install:

```hcl
  github_connection = "dataretrieval-github"
```

Which one the project has is a fact to read, not a choice — a trigger built for
the wrong generation is created successfully and never fires. One command
answers it, and `--region` is not optional:

```bash
gcloud builds connections list --project=<project> --region=<region> --quiet
```

Then grant that account what a *refresh* needs — this is the step that gets
skipped, and it fails at `plan` rather than at `apply`, so it looks like the
module is broken when it is the grants that are missing. The full list, the
reasoning, and why none of it widens the security boundary are in
[`applying-runner-infra.md`](applying-runner-infra.md#the-cloud-build-caller).

**Then run it once, by hand, and read the result.** A trigger that exists is not
a trigger that works, and the difference is only visible if you look:

```bash
gcloud builds triggers run ci-runner-apply-<repo> --project=<project> --region=<region> --branch=main
```

Run it a **second** time and confirm it reports no changes. A run that keeps
replacing the same resource is a perpetual diff, and on a nightly schedule that
is not a cosmetic wart — it recreates that resource every night, forever.

## 6. Adopt the lane model

Not required for the pool to work, but it is the other half of the cost saving:
a documentation-only pull request should not claim a slot in order to discover
it has nothing to do. Four adoption requirements, in order, in
[`ci-lane-model.md`](ci-lane-model.md).

## 7. If the repository has browser tests

Copy `scripts/ci/check-e2e-policy.sh` in alongside the other two workflow gates
and wire it fixtures-first, per [`ci-workflow-gates.md`](ci-workflow-gates.md).

Do this before the first suite lands, not after. Every failure it catches is one
that keeps the check green — a committed `test.only`, a suite with no ceiling of
its own being silently dequeued from the merge queue, browsers re-downloaded
every job because the container tag drifted from the dependency pin. A suite
that has been running for a month has already normalised whichever of those it
has, and by then the evidence that it was ever faster is gone.

Run the suite in the baked Playwright container rather than installing browsers
on the pool — [`ui-testing-on-the-fleet.md`](ui-testing-on-the-fleet.md) is the
consumer guide for that half — and tier it: `@smoke` on every pull request, the
full suite on the merge queue.

## 8. The four pools — the fleet standard

Everything above stands up **one** pool, and one pool is the shape a repository
starts in, not the shape it stays in. The fleet standard is **four pools behind
one controller**: Linux CI, Windows CI, Linux merge-queue, Windows merge-queue.
The decision is [`adr-four-pool-controller.md`](adr-four-pool-controller.md);
the operational detail — the routing contract and the capacity formula — is in
[`ci-lane-model.md`](ci-lane-model.md).

**Why the merge queue gets its own pool.** Mergify validates a queued pull
request by re-running the same `pull_request` workflows, against the same
labels, at exactly the moment the CI pool is busiest with the *next* pull
requests. Sharing one pool between the two means a pull request that has already
gone green sits in the queue waiting for a runner — and it does not fail, it
sits *pending*, which no red check anywhere reports.

**Why the Windows pair is declared even at zero.** `max_hosts = 0` costs a table
row and nothing else. What it buys is that the shape is identical in every
repository, so turning Windows on later is a number change rather than a
retrofit into a routing contract that has already shipped.

### The Terraform delta

Each pool keeps its own `ci-runner-host-pool` block with **its controller turned
off**, and hands its descriptor to one `ci-runner-controller`:

```hcl
module "ci_runner_pool" {           # the Linux CI pool from step 1, unchanged
  # …
  manage_controller = false
  role              = "ci"          # the default; written out for symmetry
  runner_labels     = var.runner_labels
}

module "ci_runner_pool_mq" {        # the Linux merge-queue pool
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.40.0"
  # …every argument of the CI pool, with three differences:
  name              = "${var.pool_name}-mq"
  manage_controller = false
  role              = "merge-queue"

  # DISJOINT, never a superset. GitHub schedules a self-hosted runner by label
  # superset, so a queue pool that also carries the CI label is dedicated in
  # name only. The controller asserts this across its whole table at plan time.
  runner_labels = ["self-hosted", "linux", "gcp", "${var.github_repo}-merge-queue"]

  max_hosts = var.mq_max_hosts   # the hard stop, not the size — see below
}

module "ci_runner_controller" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-controller?ref=v5.40.0"

  name  = "${var.pool_name}-controller"
  pools = [
    module.ci_runner_pool.pool_descriptor,
    module.ci_runner_pool_mq.pool_descriptor,
    module.ci_runner_pool_win.pool_descriptor,      # max_hosts = 0
    module.ci_runner_pool_win_mq.pool_descriptor,   # max_hosts = 0
  ]
  # …the same github app, network and controller service account the pool used
}
```

Never write the controller's table by hand: `mig` is a *generated* name, and a
wrong one gives you a controller that lists an empty instance group forever and
reports a perfectly healthy, permanently empty pool. Pass `pool_descriptor`.

### `mq_max_hosts` is a hard stop, not the size

The merge-queue pool sizes itself. The controller reads `max_parallel_checks`
out of the repository's own `.mergify.yml`, live, and derives the ceiling:

```
hosts = ceil( Σ max_parallel_checks × jobs per check ÷ slots per host )
```

`max_hosts` remains the MIG's maximum underneath that, so set it to something
the derivation will not routinely hit — and then watch, rather than calculate:
`ci_queue_capacity_wanted_hosts` above `ci_queue_capacity_hosts` is the
controller telling you your Terraform ceiling has become the bottleneck. It is a
comparison, so it needs no threshold of your own.

### The order, which is not optional

1. **Apply the Terraform** that creates the merge-queue pool.
2. **Then** merge the workflow change that routes to it.

The commit that introduces the route cannot be merged *through* the queue:
Mergify's speculative draft of that very commit runs under the new routing and
asks for a label no runner carries yet.

### One extra App permission

The controller now needs **`Contents: read`** on the GitHub App, to read
`.mergify.yml`. Without it the read is a 403 and the merge-queue pool silently
keeps its Terraform `max_hosts` instead of a derived ceiling — it fails open, so
nothing breaks and nothing says so. The one signal is
`ci_queue_config_age_seconds` climbing past 300; on a healthy controller it
stays under it, and `-1` means the configuration has never been read at all.

## Windows

Windows is a **first-class pool of the same module**. There is no separate
Windows module and no vendored root: `ci-runner-host-pool` with
`host_os = "windows"` gives you warm Windows hosts off a Windows golden image,
with the same controller, the same autoscaler and the same scale-in path.
The design, and every trade behind it, is [`adr-windows-pool.md`](adr-windows-pool.md).

A Windows pool is **not** a Linux pool with a different image, and the four
differences below are decisions rather than gaps. Read them before you decide to
opt in, not after the first job.

**Job isolation is one local Windows account per slot — there is no container
anywhere.** On Linux each slot is a Linux user with its own rootless Docker
daemon, and a job runs inside a container it cannot escape. On Windows each slot
is a separate local Windows account with its own profile, workspace and TEMP,
and that is the whole boundary. Everything below the account — installed SDKs,
the registry, `C:\ProgramData`, the certificate stores, anything a job writes
with the privileges it has — persists across jobs and is shared between slots.
This is weaker than the Linux pool, and weaker than the ephemeral
one-VM-per-job Windows pool it replaces, which destroyed the machine. It is the
price of warmth and it was paid deliberately. Consequence for a job author:
`container:` and `services:` in a workflow job **cannot** run on this pool.
`scripts/ci/check-runner-policy.sh` refuses them (`RUNNER8`) in your own CI, so
the answer arrives in a pull request rather than as an "Initialize containers"
error about docker on a host that has none.

That refusal is correct and it leaves a hole: a Windows job that needs a
database has no supported way to get one. The answer is *reachability, not a
runtime* — the pull request's shared stack lives on its Linux host and the
Windows job connects to it over the VPC. Designed in
[`adr-pr-host-affinity.md`](adr-pr-host-affinity.md), specified in
[`ci-pr-shared-infra.md`](ci-pr-shared-infra.md), **proposed and not yet
implemented**. Until it is, a Windows job's dependencies have to be native.

**`slots_per_host = 1`.** Windows has no per-slot network namespace, so two
concurrent slots share one loopback and one port space, and two jobs binding the
same fixed port collide with no host-side fix — reported forever as a flaky
build, never as host policy. One slot keeps every part of the warm-host saving
and none of that risk. Two is expressible and is not where a first pool starts.

**`min_hosts = 0`, always, with no warm schedule.** Windows Server is licensed
per vCPU-hour on top of the machine, so a warm window pays that licence for
every hour of the working day whether or not anyone pushes. The cost of the
choice is real and you should expect it: the first Windows job after a quiet
spell pays a full Windows boot, and `ci_queue_wait_seconds_max` on the pool will
show it. What survives scale-to-zero is the saving that mattered anyway — the
toolchain install and the warm cache, which a reused host keeps and a per-job VM
never had. `warm_schedules` stays available and unset.

**Windows Server with Desktop Experience, not Server Core.** CI job code is
written against GitHub-hosted `windows-latest`, which is a Desktop Experience
image, and the installers and test runners that assume a GUI subsystem is
present fail on Core in ways that read as repository faults. The image is built
by `packer/ci-host-image-win.pkr.hcl` into its own family, `ci-runner-host-win`,
which is deliberately never the Linux family — a family points at its newest
member, so sharing one would let build order hand a pool the wrong OS. The
module refuses the mispairing at plan time, because the guest agent's answer to
a Windows instance carrying a Linux boot key is to run **no boot script at all**
and look healthy while it does it.

### Two rules that stop being advice

The README's [isolation rules](../README.md#isolation-rules-not-optional) apply
to every pool. On a Windows pool, two of them are **requirements**, because they
are the only isolation boundary left:

* **One repository per pool.** Not one repository per pool *by convention* — a
  second repository on a Windows pool has no boundary between it and the first.
* **Fork pull requests never run on a warm host.** Route them to GitHub-hosted
  runners. On Linux this is defence in depth behind the container and the
  metadata fence; on Windows there is nothing behind it.

Both are enforceable from your own repository, and should be: `RUNNER1` scopes
each job to one pool label and `RUNNER4` demands a fork guard, both in
[`ci-workflow-gates.md`](ci-workflow-gates.md).

### What a Windows job can read, in plain terms

This is the paragraph an estate has to weigh before opting in, and it is stated
here rather than in the design because the operator is the person it concerns.

**A build job on a Windows host can reach the machine's cloud identity, and no
design in this repository stops it.** Windows has no working per-process egress
filter — an explicit block outranks every conflicting allow, and the one
documented override needs a protocol the metadata server does not speak — so job
code can call the metadata server directly. Concretely, a Windows CI job can:

* mint an access token for the **host** service account (which is why that
  account is stripped down to almost nothing — see below);
* read every instance attribute **and every project-level metadata attribute**.
  That last one is not this module's to control: project-wide SSH keys and any
  custom project metadata your estate has set are readable by any Windows CI
  job. **An estate that keeps anything sensitive in project metadata must not
  put a Windows pool in that project.**
* read the host's Google-signed identity token, so any service that trusts the
  host service account's OIDC identity effectively trusts a pull request;
* write and forge its own liveness beacon.

What it can **not** do is read the GitHub App private key, write the demand
metric the autoscaler reads, or touch any repository other than the one its own
pool serves.

**The Windows host service account must never be granted Secret Manager
access — not "should not", must not.** `ci-runner-identity` with
`host_os = "windows"` strips that grant, leaving only
`roles/iam.serviceAccountTokenCreator` on the job account, which is exactly what
the credential broker was going to hand the job anyway. Do not restore the grant
"for convenience" on a Windows pool, and do not attach a Windows host to a
service account that holds it for some other reason. The reason is specific:
**every host template carries the App key secret's address in metadata**
(`ci-app-key-secret`), on Windows as on Linux, and a Windows job can read
metadata. Today that is harmless — the value is a resource path, not key
material, and the account holding it can access nothing. Grant the account
Secret Manager and the address is already sitting where every job on the host
can find it. The two halves of that safety property live in different modules,
so nothing links them at review time; this paragraph is the link.

The host's own boot probe is the enforcement. It runs as a slot user and asserts
a **403** on the secret named by `ci-app-key-secret`, a **403** on writing a
time series, and — the one assertion that runs the other way — a **200** on
minting a token for the job service account, which is the single capability a
Windows host account is supposed to keep. A Windows pool whose host identity was
not reduced fails that probe and refuses to register — deliberately, because
Terraform cannot see what IAM a passed-in service account holds elsewhere.

The positive assertion is not a nicety. Two `403`s prove a reduced identity only
if the token could have done something in the first place: an account whose
bindings were all stripped, or a host that cannot reach Google at all, answers
`403` to both. So if you deliberately run a Windows pool with **no** job service
account, that pool's probe has no positive control left, and its two refusals
are correspondingly weaker evidence.

### The Terraform

Alongside the Linux blocks in §1, not instead of them — the two pools are two
instantiations with their own names, MIGs, controllers and labels.

```hcl
module "ci_runner_identity_win" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-identity?ref=v5.40.0"

  project_id        = var.project_id
  name              = var.win_pool_name
  account_id        = var.win_runner_account_id
  app_key_secret_id = var.app_key_secret_id

  # THE security input. It removes the Secret Manager grant from the host
  # account, because a Windows host cannot defend it.
  host_os = "windows"
}

module "ci_runner_pool_win" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.40.0"

  # ... project_id, region, github_*, network, subnetwork and the three
  # identities exactly as the Linux pool above, from the _win modules ...

  host_os = "windows"
  image   = var.win_host_image     # the ci-runner-host-win family, never ci-runner-host

  # The host account cannot mint its own registration token — it has no Secret
  # Manager grant. The CONTROLLER mints it and writes it to a per-instance
  # metadata key, then deletes the key once the agents appear. Required on
  # windows: the safe configuration and the working configuration are the same
  # configuration, and the module refuses the pool without it.
  controller_mints_registration_token = true

  slots_per_host = 1
  min_hosts      = 0
  max_hosts      = var.win_max_hosts

  # A Windows first boot plus account creation plus per-slot service
  # registration does not fit the Linux 600s grace, and not fitting IS a churn
  # loop that never reaches usable capacity. Floor of 1200, refused below it.
  register_grace_seconds = 1200

  # Windows, plus toolchains, plus the warm cache, plus workspaces, plus a
  # pagefile. Floor of 200, refused below it.
  boot_disk_size_gb = 200

  # Its OWN labels. The two pools must never answer the same set — both would
  # register, and GitHub would hand a Linux job to a Windows host.
  runner_labels = ["windows", "gcp", var.repo_label]
}
```

Four more inputs are **refused at plan time** on a Windows pool rather than
accepted and ignored, so a copy-pasted Linux block fails in the plan and not in
a job: `spot` (a preemption takes every slot with it, and the licence is per
vCPU-hour whichever way the machine was bought), `extra_registry_hosts` (nothing
on the host reads it — there is no container runtime and no credential helper),
and the two floors above. `machine_type` has no Windows default of its own: the
Linux default is sized for four concurrent slots, so a one-slot Windows pool
should name something smaller in its own root rather than inherit a number
chosen for a different shape.

### A rebooted Windows host comes back dead, and that is the design

Windows hosts reboot for updates. This is ordinary behaviour on the platform,
not an edge case, so it is written down here rather than discovered.

The controller mints a host's registration token **once** and deletes the
metadata key as soon as GitHub reports the host registered. A host that reboots
after that point finds no key, blocks at the wait for it, and never
re-registers. Nothing is exposed — the credential is gone, which is the point —
and it is self-healing: the host shows zero agents, passes
`register_grace_seconds`, and the controller retires it; the MIG replaces it
with a host that gets a fresh token. What you will see is a host that "came back
wrong" and a short capacity dip, and the boot log says so by name. Do not treat
it as a broken image.

### Adoption sequence

1. Build the Windows image (`packer/ci-host-image-win.pkr.hcl`) and note both
   its `image_version` (the artifact) and its `image_contract_version` (the
   contract the boot script asserts against `windows_image_min_version`).
2. Stand the pool up **alongside** whatever runs your Windows jobs today, on its
   own labels, with `min_hosts = 0` and `slots_per_host = 1`.
3. Apply, and watch the first host register. A Windows host that boots silently
   is the failure this module spends most of its refusals on; if it never
   registers, the boot log names the phase.
4. Move **one** workflow onto the new labels. Confirm it carries a fork guard
   and a repository-scoped label first.
5. Cut over the rest, then delete the old pool — in your repository, as the last
   step rather than the first.

## When something is wrong

| symptom | first thing to check |
|---|---|
| jobs queue forever, no error | `runner_labels` vs `runs-on` (§2) |
| hosts run, zero slots registered | `/var/log/ci-host.log` — the fail-closed guards (§5) |
| pool never scales in | the IAP firewall tag: the drain proves a host idle over IAP-SSH, and a host outside the rule fails that probe |
| pool never scales out | `ci_demand` on the pool. A flat 0 with jobs queued is a label-set mismatch, not a quiet fleet — the controller matches the configured labels PLUS the agent's read-only three (§2), folded. `ci_demand` non-zero and hosts flat is `max_hosts`, or an expired queue: check `ci_demand_expired` |
| first host never registers | the App key secret version (§3) |
| a Windows job fails at "Initialize containers" | `container:`/`services:` on a Windows pool — there is no container runtime. `check-runner-policy.sh` (`RUNNER8`) catches this in your own CI |
| a Windows host registers, reboots, and never comes back | expected after the registration token expires — the MIG replaces it at `register_grace_seconds` (see "A rebooted Windows host comes back dead") |
| a Windows host boots, looks healthy, registers nothing | the image family. A Windows instance carrying the Linux boot key runs no boot script at all; the module refuses the mispairing at plan time, so check the `image` a running pool was applied with |
| a build fails on a different download each run | container MTU. The hosts set the slot daemon's `mtu` from the primary interface, so this should not recur; a fork that dropped it black-holes large TLS responses and reports them as a truncated handshake or a "not found" dependency, never as a size error |
| `go clean -modcache` or `uv cache clean` fails with `EACCES` | the warm cache, working as designed — see "Cleaning a warm cache" below |

### Cleaning a warm cache

A slot's dependency cache is seeded by copying the host's sealed master, and it
arrives with the seal's modes: every **file** read-only, every **directory**
writable, all of it owned by the slot. So the cache works normally — tools add,
replace and remove entries, which needs write on the parent directory — but a
command that rewrites cached content *in place* gets a permission error on files
it can see it owns. `go clean -modcache` and `uv cache clean` are the cases
repositories have hit.

Nothing is broken, and the read-only mode is not incidental: `go.sum`
authenticates the module zip at download and the build compiles from the
extracted tree without re-hashing it, so those file modes are the only thing
between one job's write and the next job's compile.

If a job genuinely needs to clean, make the tree writable first. The slot owns
every file, so this always succeeds:

```yaml
- name: Clean the Go module cache
  run: |
    chmod -R u+w "$GOMODCACHE"
    go clean -modcache
```

Keep it in the job that needs it. The modes are per-slot, the next boot re-seeds
from the master regardless, and a repository that cleans on every run is paying
for the warm cache and then throwing it away.
