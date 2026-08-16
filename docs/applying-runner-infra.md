# Applying runner infra automatically

## The gap this closes

Merging a version bump changes what the *next* apply will build. It does not
change anything that is running.

For the whole life of this fleet, "the next apply" meant a person, on a laptop,
with a gitignored `terraform.tfvars`. What that cost, measured on 2026-08-15:
v5.7.0 — the release that stops a job inheriting the previous job's cloud
credentials — merged into **nine** repositories the same day and reached
**one** pool, the one whose apply somebody ran by hand.

Nothing was red. Every pin was current, every gate green, every PR merged.
**A pin that is merged and never applied is indistinguishable, from the
outside, from a pin that was never bumped.**

## The two halves

| | mechanism | what it delivers |
|---|---|---|
| publish | `publish-tag.yml` in this repo | the tag exists the moment `VERSION` says it does |
| adopt | `?ref=v5` in the consumer | the consumer resolves the newest v5 at its next `init` |
| apply | `apply-runner-pool.yml`, or `modules/ci-runner-apply-trigger` | the newest v5 actually reaches machines |

Each is useless without the next. A published tag nobody pins is a tag; a pin
nobody applies is a diff.

## Two ways to run the apply, and which one to pick

The apply half has two implementations. They do the same terraform — the same
`init -upgrade`, the same printed plan, the same apply of the *saved* plan —
and they differ entirely in **where the credential comes from**.

| | `apply-runner-pool.yml` (GitHub Actions) | `modules/ci-runner-apply-trigger` (Cloud Build) |
|---|---|---|
| trigger | the consumer's own workflow triggers | a Cloud Build trigger on push to `main` |
| credential | workload identity federation | none — the build runs inside the project |
| per-repo setup | pool, provider, `attribute.ref` mapping, a bound SA | a trigger, and the GitHub App connection the project already has |
| identity | `modules/ci-runner-apply-identity` creates one | **reuses the project's existing CD account; creates nothing** |
| assumable from CI | yes, by design — that is what federation is | no |

**Prefer Cloud Build wherever the project already runs its CD on it.** Not
because federation is misconfigured — because the whole trust boundary stops
existing rather than being defended. There is no provider to map, no
`principalSet` to widen by accident, and no account that a `.github/workflows`
file can assume. The push that fires it is observed by the same GitHub App
connection that already deploys every service in the project.

**Use the GitHub Actions workflow when the project has no Cloud Build** — a
repository deploying somewhere else, or to more than one project. Then
federation is the mechanism, and `ci-runner-apply-identity` plus a
ref-scoped `principalSet` is how it is bounded. Read the section below.

### The Cloud Build caller

```hcl
module "ci_runner_apply_trigger" {
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-apply-trigger?ref=v5.22.1"

  project_id     = var.project_id
  region         = "<region>"
  github_owner   = "<owner>"
  github_repo    = "<repo>"
  terraform_root = "customer/<customer>/terraform/ci-runner-hosts"

  # The project's EXISTING CD account. This module mints no identity.
  service_account = "<existing-cd-sa>@<project>.iam.gserviceaccount.com"

  # The run that no push produces — see below. Not the hour, and not the same
  # minute as any other repository in the fleet.
  apply_schedule = "23 4 * * *"
}
```

**If the root does not name its backend fully in `backend.tf`, add
`backend_config`.** Most roots bake the bucket in and need nothing here. The
Specaria-owned CI roots deliberately do not — the bucket is a vendor resource,
not a customer literal, so it is supplied at init time — and against one of
those a bare `terraform init` fails with "querying Cloud Storage failed:
storage: bucket doesn't exist" — which reads as a deleted or misnamed bucket,
not as one that was never passed. Nothing in it points at this trigger.

```hcl
  backend_config = {
    bucket = "<state-bucket>"
  }
```

Not a place for a secret: every value is rendered into the trigger's stored
build config and printed in the build log. Credential keys — `credentials`,
`access_token`, `encryption_key` and the rest — are rejected at plan time
rather than left to the reader, because nothing about the leak goes red. The
build authenticates to the backend as the service account you already gave it;
grant that account access to the state bucket.

Three prerequisites, and the first is the same one the workflow has:

**1. The variables must be in git** — see below; it is not specific to either
path. An unattended apply has no `terraform.tfvars` either way.

**2. The project must already be connected to GitHub — and you have to know
which of the two ways.** This module wires a trigger; it does not authorize a
GitHub account. If the project already has push-to-main triggers for its
services, it is connected, and the remaining question is the generation:

- **1st gen** — a project-level GitHub App install. The trigger names
  `owner`/`repo` directly. This is the default; pass nothing extra.
- **2nd gen** — a regional `cloudbuild connection` resource. The trigger names a
  *repository resource* under it. Pass `github_connection = "<name>"` and the
  module registers the repository and wires it.

**Read the generation off the project rather than assuming it.** The two are
separate APIs, and picking the wrong one does not fail validation: the trigger
is created, reports healthy, and never fires, because the push it watches for
arrives on a link it cannot see.

```bash
gcloud builds connections list --project=<project> --region=<region> --quiet
```

A name in the output means 2nd gen. Empty output plus working service triggers
means 1st gen. **Pass `--region` every time** — 2nd-gen connections are
regional, and a region-less list returns `[]` for a project with several, which
reads exactly like "not connected". `--quiet` matters too: the first call in a
project offers to enable the API and waits for an answer that never comes in an
unattended shell.

Surveyed 2026-08-16, the fleet is split: `mot-integrateit` is 1st gen,
`mot-apps-modern` is 2nd gen (`dataretrieval-github`), and most remaining
projects have neither yet.

**3. The account must be the right shape, and that is the only security
decision here.** It should be the project's existing CD account, and it should
**not** hold `roles/iam.serviceAccountAdmin` or
`roles/resourcemanager.projectIamAdmin`. The argument is the same one that
shapes `ci-runner-apply-identity`, and it survives the move to Cloud Build for
free — an account able to apply the runner root *end to end* can grant itself
owner, and a compute-scoped account instead stops **red** on the rare apply
that changes an identity, and a human runs that one. Beyond that it needs
`roles/storage.objectAdmin` on the state bucket, `roles/cloudbuild.builds.builder`
(or equivalent) to run at all, and — only if you set `apply_schedule` —
`roles/cloudscheduler.admin` for the job this module creates beside the
trigger.

**It also needs to READ every resource the root owns, and that is not the same
list as the roles that let it write them.** Learned the expensive way on
IntegrateIT, 2026-08-16: the first three unattended runs all failed **red at
`plan`**, on three separate `403`s, none of which was a permission to change
anything. `google_project_iam_member` calls `projects.getIamPolicy` just to
refresh. `google_secret_manager_secret` calls `secretmanager.secrets.get`, which
`roles/secretmanager.secretAccessor` does **not** grant — accessor reads a
version's payload, not the secret's metadata. A CD account has the write roles
already, because it deploys services; it has none of these, because deploying a
service never refreshes somebody else's IAM binding.

Grant the four read-only roles below **before** the first run, or spend three
red builds rediscovering them one at a time, in the order Terraform happens to
refresh:

```bash
gcloud iam roles create ciRunnerApplyIamReader --project=<project> \
  --title="CI runner apply — IAM policy reader" \
  --permissions=resourcemanager.projects.getIamPolicy --stage=GA

for R in projects/<project>/roles/ciRunnerApplyIamReader \
         roles/secretmanager.viewer roles/iam.serviceAccountViewer roles/monitoring.viewer; do
  gcloud projects add-iam-policy-binding <project> --condition=None \
    --member=serviceAccount:<sa>@<project>.iam.gserviceaccount.com --role="$R"
done
```

The custom role exists rather than `roles/iam.securityReviewer` because
`getIamPolicy` on the project is the single permission the refresh actually
needs, and securityReviewer carries a large read surface for it. **Every one of
these is read-only, so the security property is untouched**: none of them grants
`setIamPolicy`, so an apply that would *change* a binding still stops red, which
is the behaviour the whole design is for. A `viewer` role is what lets the applier
*see* the binding it is not allowed to change — without it, it cannot tell the
difference between "no drift" and "no access", and reports the second as failure.

Verify before wiring it, rather than assuming a CD account is narrow:

```bash
gcloud projects get-iam-policy <project> --flatten="bindings[].members" --filter="bindings.members:<sa>@<project>.iam.gserviceaccount.com" --format="value(bindings.role)"
```

**The scheduled run is not optional on a repository that pins `?ref=v5`.** It
has no commit to push when v5.7.1 ships, so the push trigger never fires and
the release sits in the tag forever. `apply_schedule` is the only trigger that
ever fires for that release — the push trigger cannot see it.

**`tf-apply-guard.sh` does not run here, and that is deliberate.** The guard
refuses an apply whose checkout is not the remote default branch, and demands a
plan-derived token before a destroy — a human-at-a-laptop defence, and the
right one for that case. Inside a build fired by a push to `main` the checkout
*is* the merged commit, and no one can type a confirmation token. What bounds
destruction instead is the account: the protected kinds the guard names —
service accounts and secrets — are exactly what a compute-scoped CD account
cannot delete. Which is why prerequisite 3 is not merely tidiness about where
identities get created.

## The GitHub Actions caller

`apply-runner-pool.yml` is a reusable workflow — **the consumer owns the
triggers**, and it needs three:

```yaml
name: Apply runner pool

on:
  # 1. the root itself changed — new machine type, new slot count
  push:
    branches: [main]
    paths: ['customer/<customer>/terraform/ci-runner-hosts/**']
  # 2. somebody wants it now
  workflow_dispatch:
  # 3. NOTHING changed here and a new module version is waiting.
  #    A repo pinning ?ref=v5 has no diff to merge when v5.7.1 ships, so the
  #    push trigger never fires and the release would sit forever. THIS is the
  #    trigger that makes "follow the major tag" mean anything.
  schedule:
    - cron: '17 4 * * *'

permissions:
  contents: read
  id-token: write

jobs:
  apply:
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/apply-runner-pool.yml@v5
    with:
      terraform_root: customer/<customer>/terraform/ci-runner-hosts
      region: <region>
      workload_identity_provider: projects/<num>/locations/global/workloadIdentityPools/<pool>/providers/<provider>
      service_account: <ci-runner-infra-apply-sa>@<project>.iam.gserviceaccount.com
```

Pick a cron minute that is not `0`, and a different one per repository. Every
scheduled workflow in the fleet firing on the hour is how a rate limit becomes
a fleet-wide outage.

**Do not add a `pull_request` trigger.** The workflow refuses one, on purpose.
Wanting a plan on the PR is reasonable; getting it by pointing *this* workflow
at a PR is not, because the terraform it applies would come from the branch —
a floating module ref and a branch `.auto.tfvars` both resolve from the
checkout, so the reviewer's diff is not what runs. A plan-on-PR job is a
separate workflow with a read-only identity.

## Prerequisites per repository

Two, and neither is optional.

**1. The variables must be in git.** `terraform.tfvars` is gitignored in every
consumer, so an unattended apply has no inputs. Move the non-secret values —
project, region, pool name, machine type, slot count, bounds — into a tracked
`*.auto.tfvars`, which terraform loads with no flag. Nothing in that file is a
secret: it is the shape of the pool, and the pool is described in this
repository's README anyway. Anything that *is* a secret stays where it is.

**2. A dedicated apply identity** — `modules/ci-runner-apply-identity`.

```hcl
module "ci_runner_apply_identity" {
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-apply-identity?ref=v5.22.1"

  project_id             = var.project_id
  name                   = var.pool_name
  account_id             = "${var.pool_name}-apply"
  state_bucket           = "<the bucket holding this root's tfstate>"
  workload_identity_pool = "projects/<num>/locations/global/workloadIdentityPools/<pool>"

  # the accounts the apply attaches to instances — the pool's own, and no others
  impersonable_service_accounts = [
    module.ci_runner_identity.service_account_email,
    module.ci_runner_identity.controller_service_account_email,
  ]
}
```

**Not the runtime service account.** A runtime SA is bound to what the
application may touch; handing it authority to rebuild the compute the
application runs on inverts that, and gives a data-plane credential a
control-plane blast radius.

**And not an account that can apply the whole root, either** — which is the part
worth reading twice. This identity is assumable by a GitHub Actions run, so
everything it can do, a workflow file can do. The root creates service accounts
and project IAM bindings, so an account able to apply it end to end holds
`resourcemanager.projectIamAdmin` — "can grant itself owner" — reachable from
CI, in a fleet whose pull requests auto-merge on green.

So the module grants **compute and nothing else**: instance templates, the
group, the autoscaler, `actAs` on the pool's own accounts only, read-only on
identity and secret *metadata* so terraform can refresh, and `objectAdmin` on
one bucket. It is deliberately incomplete, and the split it relies on is the
one the modules already have — `ci-runner-identity` exists to survive pool
replacement and changes almost never; `ci-runner-host-pool` is what every
release changes, and it is compute.

**When an identity change does ship, the apply fails.** That is the design. It
stops red, naming the resource, and a human runs that one apply. An account that
never needs a human is an account that can grant itself anything.

Access is bound to a single ref, not to the repository:

```
principalSet://iam.googleapis.com/<pool>/attribute.ref/refs/heads/main
```

`attribute.repository` binds *every* branch — including one pushed by anyone
with write access, running a workflow file they wrote, which never goes near
`main` and so never meets branch protection. If the shared provider does not map
`attribute.ref` yet, add it: the mapping is additive, existing principalSets keep
resolving, and it is a one-command fix rather than a reason to widen this.

```bash
gcloud iam workload-identity-pools providers update-oidc <provider> --project=<project> --location=global --workload-identity-pool=<pool> --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref"
```

The module itself is created by the **one** apply a human still runs — the
bootstrap. After that the automation owns the pool.

(The pin above is exact because this repo's docs are asserted against `VERSION`.
Consumers pin the floating major, `?ref=v5`, so a release reaches them without a
per-repo bump; that is the adoption half of the table at the top.)

## Rebuilding the host image on merge

Everything above is about applying *terraform*. The other artifact this fleet
runs on is the golden host image, and until now it had no automation at all: it
came from a person typing `gcloud builds submit --config cloudbuild.yaml` with
five substitutions, and it came out subtly different depending on which five
they remembered. Forgetting `_IMAGE_STORAGE_LOCATION` is the expensive one —
`constraints/gcp.resourceLocations` rejects the multi-region GCE picks by
default, and it rejects it at *image creation*, an hour in, after every
provisioner has already run.

`modules/ci-host-image-trigger` makes a merge to this repository do it.

```hcl
module "ci_host_image_trigger" {
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-host-image-trigger?ref=v5.22.1"

  project_id   = var.project_id
  region       = "<region>"
  github_owner = "<owner>"
  # github_repo defaults to ci-runner-infra — the repo the image build lives in.

  # 2nd-gen projects only. Omit it entirely on a 1st-gen project; see below,
  # and read the generation off the project rather than copying this line.
  github_connection = "<connection>"

  # The EXISTING account the build runs as. This module mints no identity.
  service_account = "<existing-image-builder-sa>@<project>.iam.gserviceaccount.com"

  # Where Packer's build VM runs, and which network it must sit on for the
  # project's IAP-SSH rule to reach it.
  zone        = "<zone>"
  network     = var.network
  subnetwork  = var.subnet_name
  network_tag = module.ci_runner_network.runner_network_tag

  # Required. Empty is the failure that arrives at the END of the build.
  image_storage_location = "<region>"
}
```

**It runs this repository's own root `cloudbuild.yaml`, it does not reimplement
it.** The trigger sets `filename` and passes substitutions; the steps stay next
to the packer template they drive. That is the deliberate difference from
`ci-runner-apply-trigger`, whose steps *are* inlined — there the alternative was
nine copies in nine consumer repositories, here the original already lives in
one place.

### The image name, and why every build gets its own

Leave `image_version` unset. The module then passes `_IMAGE_VERSION=g$SHORT_SHA`,
so each merge produces `ci-runner-host-g<sha>` — unique, immutable, and traceable
to the commit that built it. Two merges can never race for one name, and a
rebuild of an old commit cannot overwrite the image somebody is running. The `g`
prefix is git's own convention for an abbreviated object name (`git describe`
prints `v1.2.3-4-gabc1234`) and it keeps the suffix starting with a letter, which
a GCE image name must.

That expansion works because Cloud Build resolves a substitution referenced
inside another substitution's value when `dynamicSubstitutions` is on, and for a
build invoked by a trigger it is always on. Typed into a manual
`gcloud builds submit` the same value is literal text and produces an image
named `ci-runner-host-g$SHORT_SHA` — which is why the manual path in the config
file's header still passes an explicit `_IMAGE_VERSION`.

### Two prerequisites, and the first is easy to assume satisfied

**1. The project must be connected to GitHub, and the connection must cover
`ci-runner-infra` — not merely the consumer's own repository.** Every other
trigger in these projects watches the project's own service repo, so "the
project is connected" is true and insufficient: this trigger watches a
*different* repository, and it has to be authorized under the same connection.
Read the generation off the project exactly as for the apply trigger
(`gcloud builds connections list --project=<project> --region=<region> --quiet`);
1st gen needs the Cloud Build GitHub App installed on `ci-runner-infra`, 2nd gen
needs it registered under the connection, which the module does for you unless
you pass `github_repository`. If another root registered it already, pass that
root's `repository_id` output — a second registration of one remote is an
`ALREADY_EXISTS` error, not a no-op. **This module exports `repository_id` for
exactly that hand-off**, and the collision is likelier here than anywhere else
in this repo, because the repository being registered is `ci-runner-infra`
itself: a project that also runs `ci-runner-apply-trigger` against it, or two
roots sharing one connection, hits it on the second apply rather than the first.

**Creating the 2nd-gen connection itself is a step before any of this, and it
fails with the wrong error message.** The connection stores its GitHub OAuth
token in Secret Manager, and it is the *Cloud Build service agent* — not you and
not the build account — that must be able to create it:

```bash
gcloud projects add-iam-policy-binding <project> --condition=None \
  --member="serviceAccount:service-<project-number>@gcp-sa-cloudbuild.iam.gserviceaccount.com" \
  --role=roles/secretmanager.admin
```

Without it the create fails with `could not assert Secret Manager permissions`,
which reads as a problem with *your* permissions and sends you to check your own
roles. A freshly created connection also sits in `PENDING_USER_OAUTH` until
somebody completes the GitHub authorization in a browser — terraform will happily
build a trigger against a connection in that state, and it will not fire until
the authorization lands.

**2. The build account needs the roles a Packer build actually uses, which are
not the apply account's roles.** This build creates a GCE VM, logs into it, and
creates an image; it never touches terraform state, IAM or secrets. Read that
list off `packer/ci-host-image.pkr.hcl` rather than off the apply trigger:

| role | why, in one line |
|---|---|
| `roles/compute.instanceAdmin.v1` | creates and deletes the build VM — and `compute.images.create`, which is in this role, is what produces the artifact |
| `roles/iap.tunnelResourceAccessor` | `omit_external_ip = true`; Packer reaches the VM over an IAP tunnel, and without this it waits out its SSH timeout |
| `roles/compute.osAdminLogin` | `use_os_login = true` (org policy enforces it), so the build account *is* the SSH identity, and the provisioners `sudo` |
| `roles/iam.serviceAccountUser` | on the account attached to the build VM — creating a VM with a service account is `actAs` on that account |
| `roles/logging.logWriter` | a build naming its own service account must write to Cloud Logging; without it the submission is refused, not merely quiet |

The project also needs an IAP-SSH firewall rule targeting `network_tag` —
`ci-runner-network` already creates one, and `network_tag` defaults to the tag
it applies. A build VM on the wrong network or without the tag fails after boot,
as an SSH timeout that reads like a broken image.

### The third prerequisite is a branch rule, not a permission

Say it plainly, because automation moves it and nothing in Google will enforce
it: **after this, merge access to `ci-runner-infra`'s `main` is write access to
the image every CI host in the fleet boots from.** That was true before too — a
person with merge access could always change `packer/` and then ask for a
rebuild — but the rebuild was a separate, deliberate act by a second person with
build permissions, and this removes that step by design.

What replaces it is the branch rule. Required review on `main` is the control
here, not a nicety, and `included_files` is what decides which merges even reach
the builder. The trigger itself watches ONE branch (`branch`, literal, `main` by
default), so nothing on a fork or a feature branch can build an image; and every
image is immutable and sha-named, so a bad one is identifiable and cannot
overwrite a good one. What none of that does is stop a reviewed-by-nobody merge.

### What a merge does to a running fleet: nothing

This is the part to say out loud, because it looks like a gap. **A new image
appears; no pool changes.** Pools pin an exact image *name* — `image =
var.host_image` — never the family. So the trigger fires, an hour later
`ci-runner-host-g<sha>` exists, and every host in the fleet keeps running
whatever it was running until somebody bumps `host_image` in a consumer root and
that root applies. An image that reached every pool the moment it built would be
an untested image on every pool.

List what is available before picking the next pin:

```bash
gcloud compute images list --project=<project> --filter="family=ci-runner-host" --sort-by=~creationTimestamp --format="table(name,creationTimestamp,status)"
```

## What "applied" does and does not mean

The apply reports a summary saying so, because it is the thing most likely to
be misread:

> Hosts do not restart on an apply.

The MIG's `update_policy` is `OPPORTUNISTIC`. A new instance template does
**not** replace running hosts — they keep running the previous startup script
until the controller drains them, and the controller drains on idleness. A busy
pool can therefore stay on the old template for as long as it stays busy.

So an apply moves the *definition*. Getting it onto machines is a separate
concern, and it belongs to the controller.
