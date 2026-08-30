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
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-apply-trigger?ref=v5.79.0"

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

### The WRITE grants, and why they are separate

These are the only grants in this document that are not read-only — so they are
listed apart from the four above rather than folded into the same loop, where
they would inherit their "the security property is untouched" sentence and stop
being a decision.

```bash
for R in roles/monitoring.alertPolicyEditor roles/monitoring.notificationChannelEditor; do
  gcloud projects add-iam-policy-binding <project> --condition=None \
    --member=serviceAccount:<sa>@<project>.iam.gserviceaccount.com --role="$R"
done
```

**Two narrow roles rather than `roles/monitoring.editor`,** which is what this
document asked for until 2026-08-29 (#548). The step writes exactly two kinds of
object: the alert policies, and — on the first run in a project, where none
exists yet — the one email notification channel they all point at. `editor`
grants both of those and also dashboards, uptime checks, log-based metrics,
monitoring groups, and services/SLOs, none of which `ensure-alert-policies.sh`
touches. The pair above is the same capability with none of that surface.

The channel half is easy to miss, and missing it is worse than over-granting:
`monitoring.viewer` (already in the loop above) can *read* channels, so a project
that already has one works fine on `alertPolicyEditor` alone — and the first
project that does not have one fails, in the step whose whole design is that it
must not fail loudly.

It is genuinely optional. Without it the apply still succeeds and prints a
warning naming this role — that is deliberate, because a missing observability
grant must not turn an infrastructure apply red. What you lose is the property
the step was added for: the project's alert policies stop being reconciled, and
drift there is invisible from inside the project, since a project with no
policies and a project with nothing wrong look identical.

The scope is narrow in the way that matters here: neither role can read or write
anything outside Cloud Monitoring, and neither can touch IAM — so the property
the four read-only roles preserve, that an apply which would change an identity
stops red, is unaffected.

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
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/apply-runner-pool.yml@00d3aec8adc67275fe2189c635bdf25cf66bc696 # v5.46.0
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
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-apply-identity?ref=v5.79.0"

  project_id             = var.project_id
  name                   = var.pool_name
  account_id             = "${var.pool_name}-apply"
  state_bucket           = "<the bucket holding this root's tfstate>"
  workload_identity_pool = "projects/<num>/locations/global/workloadIdentityPools/<pool>"

  # who may assume it: this repository's apply workflow, on the default ref.
  # Required, and there is no default — see below for why a ref alone is not it.
  repository = "<owner>/<repo>"

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

Access is bound to **one repository, one workflow file, one ref** — a single
`job_workflow_ref` claim carrying all three:

```
principalSet://iam.googleapis.com/<pool>/attribute.job_workflow_ref/<owner>/<repo>/.github/workflows/apply-runner-pool.yml@refs/heads/main
```

Neither half of that is optional, and it is worth saying why, because both of
the obvious simpler bindings are open:

- `attribute.repository` binds *every* branch — including one pushed by anyone
  with write access, running a workflow file they wrote, which never goes near
  `main` and so never meets branch protection.
- `attribute.ref` is **not** the narrower one. It is a different axis, and this
  module bound it alone until #111. A pool is normally shared by every
  repository in the org — this doc calls it "the shared provider" — so
  `attribute.ref/refs/heads/main` matches a run on *any* of their default
  branches, and with no attribute condition on the provider, any repository on
  GitHub. And `refs/heads/main` is reachable from a pull request: for
  `pull_request_target`, `workflow_run`, `issue_comment` and `schedule`,
  `GITHUB_REF` — which the `ref` claim mirrors — is the default branch, so the
  ordinary `pull_request_target` + checkout-the-head-sha pattern runs
  fork-authored code in a run whose token asserts `refs/heads/main`.

For this identity the payoff is project-wide `compute.admin` plus `actAs` on the
pool's accounts, so neither is a theoretical concern.

Two prerequisites on the provider, both one-off. Adding a mapping is additive —
existing principalSets keep resolving — so a provider that does not map the
claim yet is a one-command fix rather than a reason to widen the binding:

```bash
gcloud iam workload-identity-pools providers update-oidc <provider> --project=<project> --location=global --workload-identity-pool=<pool> --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.job_workflow_ref=assertion.job_workflow_ref"
```

And an attribute condition pinning the org by **numeric** id — an org *name* is
renameable, and a freed name is re-registrable by whoever gets there first, so
the numeric id is the only durable pin:

```bash
gcloud iam workload-identity-pools providers update-oidc <provider> --project=<project> --location=global --workload-identity-pool=<pool> --attribute-condition="assertion.repository_owner_id == '<numeric-owner-id>'"
```

Read the current mapping and condition before sending either — `update-oidc`
replaces them wholesale, so a mapping sent without the entries already there
breaks every principalSet that depends on them:

```bash
gcloud iam workload-identity-pools providers describe <provider> --project=<project> --location=global --workload-identity-pool=<pool> --format="value(attributeMapping,attributeCondition)"
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
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-host-image-trigger?ref=v5.79.0"

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

### A trigger can be refused before it starts, and it looks like a slow queue

A trigger's build config is validated when a build FIRES, not when terraform
creates it. So a trigger can plan clean, apply clean, look correct in the
console, and refuse every build it ever fires. What you see from GitHub is a
commit that merged with its `ci-runner-apply-*` check-run sitting `queued`, and
what you see in Cloud Build is a sub-second `FAILURE` with no trigger name and
no streamable log. Nothing anywhere is red.

Read `statusDetail`, which is the only place the reason appears:

```bash
gcloud builds list --project <id> --region <region> --limit 5 --format='value(id,status,statusDetail)'
```

This happened on 2026-08-29 across the fleet: the `alert-policies` step carried
a ~25 KB script in a build-step **argument**, which caps at 10,000 characters,
so every apply in every project was refused at fire time. For as long as it was
live NOTHING applied anywhere — each project kept whatever runner configuration
it had when the step landed, while its merges read as delivered.

**A refused trigger cannot repair itself.** The build that would apply the fix
is the build that is refused, so recovering needs one out-of-band apply per
project — run the root by hand, or from a build submitted directly rather than
through the trigger — after which the replaced trigger fires normally again.

Two limits produce this shape and the module now guards both: a step argument
is refused above 10,000 characters, and a whole build config above roughly
128 KiB is *accepted*, given an id, and never scheduled — no BUILD phase, no
log, every step `QUEUED` until the queue TTL expires. `script` escapes the
first and not the second, which is why the step uses `script` and a
`precondition` measures it.

---

## The controller is a managed group of size 1 (#308)

Until v5.39 the controller was the one pet in a design made of managed groups.
It carried `desired_status = "RUNNING"`, which repairs a controller somebody
**stopped** — on the next apply, whenever that is — and does nothing at all for
one somebody **deleted**.

That failure is quiet in the worst possible way. Every fact the fleet publishes
about its own capacity comes out of the controller tick: `ci_demand`,
`ci_slots_registered`, `ci_slots_missing`, `ci_poller_heartbeat`. A controller
that is gone does not produce an outage signal — it produces the **absence of
every signal** — and the autoscaler is `ONLY_UP` on a metric nobody is writing,
so the pool freezes at whatever size it happened to be and every job queues.

Both modules now build the controller from an instance template held by a
`google_compute_instance_group_manager` of `target_size = 1`. A deleted
controller, or one whose VM is gone, is rebuilt without a human.

### The first apply replaces your controller. Read the plan.

There is no in-place path from a standalone instance to a managed one, so the
plan shows a **destroy and a create**:

```
- google_compute_instance.controller
+ google_compute_instance_template.controller
+ google_compute_instance_group_manager.controller
```

`tf-apply-guard.sh` will **refuse** that apply and print a
`TF_GUARD_CONFIRM_DESTROY=<digest>` token, which is correct and is the point:
the destroy of a control plane should be something an operator retyped, not
something that scrolled past. Re-run with the token.

What the gap costs: a couple of minutes with nothing polling. Hosts keep running
the jobs they already hold — the controller executes none of them — and every
tick recomputes from live GitHub and MIG state, so there is no controller-side
state to carry across. Queued jobs wait; they are not lost.

**The instance name changes.** It gains the group's suffix — `<name>-controller`
becomes `<name>-controller-a1b2`, and it changes again every time the group
rebuilds it. The `controller_instance` output now names the **group**, which is
stable. Anything that SSHes to the controller by a hardcoded name needs:

```bash
gcloud compute instance-groups managed list-instances <name>-controller \
  --project=<project> --zone=<zone> --format="value(instance.basename())"
```

### Two controllers at once is the thing to never allow

`max_surge_fixed = 0` on the group's `update_policy` is an invariant, not a
tuning choice. Two controllers serving one repository both count demand, both
resize the MIG and both drain hosts, each against a GitHub view the other is
already acting on. The group replaces one-at-a-time with a gap, deliberately.

Unlike the hosts' group, the update policy is `PROACTIVE`: an `OPPORTUNISTIC`
controller would sit on the old startup script until something else happened to
replace it, which is the rollout shape that once put a new version on disk and
left the old one running the pool.

### Autohealing is off by default — and turning it on has a prerequisite

`controller_autohealing = false` is the considered answer, not an unfinished
one. Autohealing on a group of size 1 is not "recover faster"; it is "grant a
health probe the authority to delete the fleet's control plane, repeatedly, on
no other evidence". If the probe cannot reach the controller — health-check
ranges not open to its tag, a central firewall dropping them, the wrong port —
the group reads a healthy controller as dead and loops: delete, rebuild, cannot
reach, delete. **That is strictly worse than a pet, because a pet that is up
stays up.**

The wedge case it is usually bought for is already covered in-guest:
`ci-controller-watchdog.timer` compares the tick heartbeat's age against ten
poll intervals and restarts the unit — the exact 2h55m stall of 2026-08-14,
caught with no network path and without deleting anything. What autohealing adds
is the narrow case of a guest too broken to run its own watchdog.

If you want it, turn it on in this order — never in one apply:

1. **Open the path first.** The `ci-runner-network` module now targets the
   `ci-runner-controller` tag with its health-check rule alongside the runner
   tag. If your VPC's ingress is governed elsewhere (in the MOT projects, the
   central firewall), confirm `130.211.0.0/22` and `35.191.0.0/16` reach the
   controller on the port before anything else.
2. **Apply the firewall change with autohealing still off.** Note that this does
   not yet give you anything to probe: the responder starts only when
   `controller_autohealing` is true, because the port reaches the VM as an empty
   string otherwise — no listening socket on the one machine in the fleet
   holding the App installation token until somebody asks for one.
3. **Set `controller_autohealing = true` and apply.** The controller is replaced
   (new metadata → new template), boots, and starts
   `ci-controller-livez.service`.
4. **Confirm the probe is actually green before trusting it:**

   ```bash
   gcloud compute instance-groups managed describe <name>-controller \
     --project=<project> --zone=<zone> \
     --format="value(status.isStable)"

   gcloud compute instance-groups managed list-instances <name>-controller \
     --project=<project> --zone=<zone> \
     --format="csv[no-heading](name,instanceHealth[0].detailedHealthState)"
   ```

   `HEALTHY` is the answer you need. `UNHEALTHY` or `UNKNOWN` past the
   ten-minute `initial_delay_sec` means the probe is not landing — set
   `controller_autohealing = false` and apply again **now**, before the group
   starts rebuilding a controller that is fine.

### What the probe actually answers

`/livez` on port `controller_health_port` (default 8008) returns 200 only while
the tick heartbeat file is fresh, and 503 otherwise. A TCP check would pass for
a controller whose tick loop has stopped — the wedge keeps the socket open —
which is exactly the state worth catching.

Its threshold is **three times** the watchdog's, deliberately. The watchdog
restarts a unit; this deletes a machine. The cheaper remedy gets first refusal.

### The responder is the only unprivileged process on the controller

Before autohealing existed, the controller ran nothing but root's own loop and
listened on no port. The responder is the first process on that machine that is
both network-facing and not root, and it is on the one VM in the fleet that can
mint a GitHub App installation token — so it is confined rather than merely
demoted:

- it runs as `nobody`, with an empty `CapabilityBoundingSet` and
  `NoNewPrivileges`;
- `TemporaryFileSystem=/var/lib:ro` plus a single `BindReadOnlyPaths` entry mean
  it sees the heartbeat file and **nothing else** under `/var/lib` — not
  `api.body`, which holds the last GitHub response and on a private repository
  is repository data;
- `RestrictAddressFamilies` leaves it IP only, and `SystemCallFilter` leaves it
  `@system-service`.

`MemoryDenyWriteExecute` is deliberately absent: it is the one setting on that
list that breaks interpreters rather than constraining them, and a responder
that will not start is a probe that never answers, which is a group deleting a
healthy controller every few minutes. The same reasoning explains why the
startup script `touch`es the heartbeat before writing the unit — a bind source
that is missing at unit start is missing for the life of the process, and the
process never exits, so `Restart=always` would never recover it.

`controller-module.selftest.sh` asserts the three couplings this path holds by
literal rather than by variable: the firewall tag matches the tag on both
controller templates, the bind path matches `STATE_DIR`, and the `touch`
precedes the unit.
