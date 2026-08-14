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
module "ci_runner_identity" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-identity?ref=v5.1.4"

  project_id        = var.project_id
  name              = var.pool_name
  account_id        = var.runner_account_id   # <= 26 chars; the module suffixes it
  app_key_secret_id = var.app_key_secret_id
}

module "ci_runner_pool" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.1.4"

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
}
```

`module.ci_runner_network` (IAP-SSH + health-check firewall rules) is per
*project*, not per pool. Instantiate it once; if the project already runs a pool,
reuse the existing tag instead of declaring a second copy.

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

## 6. Adopt the lane model

Not required for the pool to work, but it is the other half of the cost saving:
a documentation-only pull request should not claim a slot in order to discover
it has nothing to do. Four adoption requirements, in order, in
[`ci-lane-model.md`](ci-lane-model.md).

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
