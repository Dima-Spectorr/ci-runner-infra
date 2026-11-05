# `ci-runner-utility-host`

ONE always-on Linux host whose job slots serve **several** repositories, one
repository per slot, for the short gatekeeper jobs (policy, checks) that would
otherwise each bill a GitHub-hosted minute — or, as a second instance with
`label_suffix = "lane"`, for each repository's merge-lane job alone. Design,
measurements and the security review: [`docs/adr-utility-host.md`](../../docs/adr-utility-host.md) (#1635).

## What it builds

- A **zonal managed instance group of exactly one host** (`target_size = 1`), with
  no autoscaler and no controller. A host that stops or is deleted is repaired by
  the group.
- **Standard GCE, never Spot.** `e2-standard-2` and a 200 GB `pd-balanced` boot
  disk by default; the disk cannot go below 200 GB because the golden image is
  200 GB.
- The **same boot script as every Linux pool**: `ci-runner-host-pool`'s
  `telemetry.sh` + `host-startup.sh`, read from the sibling module (not copied)
  and shipped as the folded gzip wrapper the pool uses. The utility behaviour is
  switched on by metadata alone.

It creates **no IAM binding**, no service account, no bucket and no firewall rule.

## Metadata it sets

| Key | Value |
|---|---|
| `ci-utility` | `true` — per-slot repositories plus the co-tenancy hardening (ADR B1–B4) |
| `ci-slot-repos` | comma list, one repository per slot, in repository-name order |
| `ci-slot-labels` | `;`-separated per-slot label sets, each led by `<Repo>-<label_suffix>` (`-util` or `-lane`) |
| `ci-cache-seed` | `off` — no shared dependency or tool cache |
| `ci-slots` | total slots across `repos` |
| `ci-runner-labels` | `self-hosted` + `runner_labels` (default `linux,gcp`) |
| `ci-github-repo` | the first repository by name: the telemetry `repo` label only |
| `ci-interactive-slots` | `0` — no autoscaler headroom to reserve |

Absent on purpose, so the host reads them as off: `ci-job-service-account`, every
`ci-cache-*` and `ci-turbo-*` key (a plan-time guard refuses `ci-turbo-*`, the job
identity and the cache bucket, #1638), `enable-guest-attributes` (no pin hold on
this host, #1639), and any `ci-shared-infra-*` network tag.

`ci-utility=true` also gives every slot unit its own `/dev/shm` (#1637) and skips
the pin hold with its `ci-pin-hold` sudoers drop-in (#1639).

## Usage

```hcl
module "utility_host" {
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-utility-host?ref=v5.155.1"

  project_id = var.project_id
  region     = var.region
  zone       = var.utility_zone
  name       = "ci-utility"            # must differ from every pool's base name

  github_owner                  = var.github_owner
  github_app_id                 = var.github_app_id
  github_app_installation_id    = var.github_app_installation_id
  github_app_private_key_secret = var.github_app_private_key_secret

  repos = {
    "<repo-a>" = { slots = 2 }
    "<repo-b>" = { slots = 1 }
  }

  image                 = var.host_image
  service_account_email = module.identity.service_account_email # the HOST account
  network               = var.network
  subnetwork            = var.subnetwork
  network_tags          = [var.runner_network_tag]
}
```

A workflow then moves one gatekeeper job with
`runs-on: [self-hosted, linux, gcp, <Repo>-util]` (the `runs_on` output). Check
names do not change.

### The lane host — a second instance

The merge-lane job carries the merge App key, so it does not share the gatekeeper
host. A second instance with `label_suffix = "lane"` serves only that job, on
`<Repo>-lane` (ADR, "Lane host"). Do not move a lane job onto it before #1694
(only the merge-lane workflow from the default branch may run there) is fixed.

```hcl
module "lane_host" {
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-utility-host?ref=v5.155.1"

  # ...the same inputs as module.utility_host, plus:
  name         = "ci-lane" # differs from the gatekeeper host and every pool base name
  label_suffix = "lane"

  repos = {
    "<repo-a>" = { slots = 1 }
  }
}
```

## What must stay true

- **Only repositories with fork pull-request workflows disabled.** Never a job
  that runs `pull_request_target`, runs fork code, or is given the merge App key
  (`merge-lane-events`, `merge-lane-review-relay`, `branch-reaper-self`), and never
  `ci-module-drift`, which must run when the fleet is broken. Terraform cannot see
  any of this; it is the repository's policy to keep.
- **No `container:` or `services:` jobs** — the host refuses them (ADR B1).
- **`name` differs from every pool's base name** in the same project. A pool
  controller owns exactly `<its base>-<4 chars>`, so a shared base name would let
  it drain and delete this host.
- **`service_account_email` is a host account**, never the controller's: it needs
  only the App key secret read plus metric and log writes. The module refuses a
  `*-ctl@` account and the default compute account (#1647).
- **No pool label.** `repos[*].labels` and `runner_labels` refuse `-shared`,
  `-util` and `-lane`: the scope label comes from `label_suffix` (#1648).

## Rolling a change onto the host

`update_policy_type = "PROACTIVE"` (default): a new template — a changed `repos`,
image or module release — surges a replacement host and then deletes the old one;
a gatekeeper running on the old host at that moment is killed and must be re-run.
`OPPORTUNISTIC` replaces nothing until the host is recreated.

## Tests

`terraform test` in this directory runs `tests/*.tftest.hcl` against a mock
`google` provider — no credentials and no API calls.
