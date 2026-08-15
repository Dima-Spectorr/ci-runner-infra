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
| apply | `apply-runner-pool.yml`, called by the consumer | the newest v5 actually reaches machines |

Each is useless without the next. A published tag nobody pins is a tag; a pin
nobody applies is a diff.

## The caller

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
  source = "git::https://github.com/<owner>/ci-runner-infra.git//modules/ci-runner-apply-identity?ref=v5.10.0"

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
