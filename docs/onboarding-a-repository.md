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

## Before you start

1. **The GitHub App is installed on the repository.** The fleet authenticates as
   one App, not as a PAT. You need its **app id** and the **installation id**
   for the account that owns the repo — both non-secret. The private key is not
   in any repository or state file; see step 3.
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
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-network?ref=v5.22.0"

  project_id         = var.project_id
  network            = var.network
  name_prefix        = var.pool_name
  runner_network_tag = "${var.pool_name}-host"
}

module "ci_runner_identity" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-identity?ref=v5.22.0"

  project_id        = var.project_id
  name              = var.pool_name
  account_id        = var.runner_account_id   # <= 26 chars; the module suffixes it
  app_key_secret_id = var.app_key_secret_id
}

module "ci_runner_pool" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.22.0"

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

Publishing is a **different identity**, `ci-runner-cache-publisher`, added next to
the pool:

```hcl
module "ci_cache_publisher" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-cache-publisher?ref=v5.22.0"

  project_id             = var.project_id
  name                   = "ci-runner-host-myrepo"   # the SAME pool name
  account_id             = "ci-runner-myrepo"
  cache_snapshot_bucket  = module.ci_cache.bucket_name
  workload_identity_pool = var.github_workload_identity_pool
  repository             = "<org>/<repo>"
}
```

It has no key and is attached to no VM: the only way to hold it is a run of the
**one workflow file** named by `publish_workflow_path`, in that repository, on the
default ref. All three, because neither of the obvious two is enough on its own —
a workload identity pool is normally shared by every repository in the org, and a
`pull_request_target` or `workflow_run` run gets an OIDC token asserting the
default branch while executing fork-authored code. The pool's OIDC provider must
map `attribute.job_workflow_ref` and must pin the org by numeric id; the module
cannot check either.

It may create objects under this pool's prefix and may not overwrite them —
`storage.objects.delete` is absent, which is what keeps the bucket's age bound
real — and it may replace exactly one object, the `current` pointer.

The run that builds and uploads a snapshot is a scheduled workflow in *your*
repository, at the path you gave `publish_workflow_path`.
`docs/publishing-a-cache-snapshot.md` is the whole of it: copy the workflow — it
is deliberately **two jobs**, and the one that installs your dependencies must
never be the one holding the publishing credential — set
`CACHE_PREPARE` to whatever installs your dependencies, and run it once by hand
with `CACHE_DRY_RUN=1` to see the size. Until you add it, a pool configured this
way finds no snapshot and runs on the baked cache — a supported state, not a
misconfiguration.

Three bounds have defaults worth leaving alone unless you have a measurement:
`cache_snapshot_max_age_hours` (168) is a security control and must stay at or
below the bucket's own `snapshot_max_age_days × 24`;
`cache_hydrate_budget_seconds` (60) is the entire time a host will spend on this
before giving up and registering anyway; `cache_snapshot_max_bytes` (4 GiB)
refuses a snapshot too large to unpack safely. Every failure inside that budget
is a log line and a cold first job, never a host that does not come up.

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

The controller counts demand for those same labels. Labels that no workflow asks
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
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-apply-trigger?ref=v5.22.0"

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

## Windows

The fleet's warm-host pool is **Linux only** — the golden image, the per-slot
rootless Docker isolation and the slot model are all Linux. A repository that
needs Windows jobs (today: IntegrateIT, for the WiX/`signtool` MSI build) runs a
separate **ephemeral one-VM-per-job** Windows pool from the retired
`ci-runner-pool` module, off a Windows golden image, in its own root. It works
and it scales to zero, but it pays a full VM boot per job and has no warm cache.
See `customer/mot/terraform/ci-runners/README.md` in IntegrateIT.

Keep Windows jobs on their own labels (`[self-hosted, windows, gcp, <Repo>]`)
and their own demand metric series. The two pools must never answer the same
labels — both would register, and GitHub would dispatch a Linux job to a Windows
host.

## When something is wrong

| symptom | first thing to check |
|---|---|
| jobs queue forever, no error | `runner_labels` vs `runs-on` (§2) |
| hosts run, zero slots registered | `/var/log/ci-host.log` — the fail-closed guards (§5) |
| pool never scales in | the IAP firewall tag: the drain proves a host idle over IAP-SSH, and a host outside the rule fails that probe |
| pool never scales out | the controller's demand labels, and `max_hosts` |
| first host never registers | the App key secret version (§3) |
| a build fails on a different download each run | container MTU. The hosts set the slot daemon's `mtu` from the primary interface, so this should not recur; a fork that dropped it black-holes large TLS responses and reports them as a truncated handshake or a "not found" dependency, never as a size error |
