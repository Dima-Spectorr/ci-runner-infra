# ci-runner-infra

Shared Terraform module and golden-image definition for self-hosted GitHub
Actions CI across the fleet. **One module, one image, every repository.**

## Why this repo exists

The module this replaces (`ci-runner-pool`) was *vendored* — copied into each
repository's `infra/terraform/modules/`. Nine copies, nine independent edits,
and they disagreed on the safety-critical scale-in contract. A fix for the
autoscaler deleting a VM mid-job landed in one copy; a fix for a pool pinned at
maximum landed in another; several copies had neither. Nothing was wrong with
any single fix. Vendoring was wrong.

Consumers now reference this module by tag:

```hcl
module "ci" {
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v3.0.0"
  # ...
}
```

A drift gate in each consuming repository fails CI if a local
`infra/terraform/modules/ci-runner-*` directory reappears.

## What changed, and what it buys

| | old: one VM per job | new: warm container hosts |
|---|---|---|
| VM lifetime | one job | many jobs, hours |
| per-job boot | 60–120 s | 0 |
| per-job toolchain install | 1–5 min | 0 (baked) |
| per-job dependency download | 1–4 min | ~0 (warm cache) |
| isolation | destroy the VM | run the job in a container |
| scale-out | autoscaler on job demand | same |
| scale-in | VM self-deletes after its job | controller drains idle hosts |
| scale to zero | yes | yes |
| autoscaler mode | `ON` + `scale_in_control`, or `ONLY_UP` | `ONLY_UP` only |

The two changes that matter are on the same line of the table: a host is reused
(so the boot and install cost is paid once instead of per job), and because a
host is reused it now carries up to `slots_per_host` jobs at a time — which is
why no autoscaler is allowed to pick one to delete.

## Architecture

```
GitHub  <--poll(outbound)--  controller (e2-micro, always on)
                                 |  publishes ci_demand + telemetry
                                 v
                            autoscaler (ONLY_UP)
                                 |  adds hosts only
                                 v
                            regional MIG of warm hosts
                            each: K persistent runner agents
                                  jobs execute in containers
                                 ^
                                 |  deregister -> verify -> delete
                            controller owns every deletion
```

No inbound webhook is permitted into these projects, so demand is polled. The
controller is the only always-on cost per pool.

### Scale-in, precisely

1. The controller polls GitHub for each host's agents and their busy state.
2. `drain_decision()` (`modules/ci-runner-host-pool/scripts/drain-decision.sh`)
   returns `drain:` or `keep:` from already-observed facts. It is a pure
   function with a self-test — the predecessor of this rule shipped inverted
   once, and an untestable rule is a rule that ships wrong.
3. On `drain:`, the controller **deregisters** the host's agents. GitHub
   *refuses* to remove an agent that is executing a job; that refusal is the
   mid-job guard, and it aborts the whole drain for that host.
4. It then verifies no `Runner.Worker` process remains, and only then deletes
   the instance from the MIG.

5. Registrations left behind by a host that died *outside* this path — an
   operator `delete-instances`, a MIG recreate, host maintenance, a controller
   restart mid-drain — are reclaimed by `orphan_decision()`
   (`scripts/orphan-decision.sh`, also pure and self-tested). It deletes a
   registration only when the agent is offline, not busy, named for an instance
   this MIG could have created, and has had no instance behind it for
   `orphan_confirm_ticks` consecutive ticks. That last condition is the guard
   against a failed `list-instances` — which returns an empty host list,
   indistinguishable from a pool at zero — deregistering a live fleet.

A `keep:` verdict is never an error. A host is kept when it is busy, when the
pool is at its floor, when GitHub could not be asked, or when it is idle but
still inside its warm window.

## Isolation rules (not optional)

* **One repository per pool.** Warm hosts share caches between jobs; that
  sharing is the speed-up. Two repositories on one pool would let one
  repository's build read the other's caches, credentials and workspace
  remnants.
* **Fork pull requests never run on a warm host.** Untrusted code plus a warm,
  credentialed, reused machine is the whole attack. Route them to
  GitHub-hosted runners.
* **Never mount the Docker socket into a job container.** It is a
  host-root escape and it defeats the container boundary that replaced
  "destroy the VM".
* **The host service account is a job's service account.** Anything it can
  reach, a build can reach. Grant only: read the App key secret, write metrics,
  write logs.
* **A warm cache is untrusted build input.** A poisoned cache entry survives to
  the next job, which the old destroy-per-job model made impossible. Caches are
  scoped per repository and rebuilt with the image.

## Telemetry

Every pool publishes the same series under `custom.googleapis.com/github/`, on
a `generic_node` resource labelled `repo` and `pool`, through one publisher
(`scripts/telemetry.sh`). One fleet dashboard covers every repository with no
per-repo dashboard code.

`ci_demand` (queued **and** in-progress — counting queued alone collapses to
zero the moment work starts), `ci_demand_queued`, `ci_hosts_running`,
`ci_hosts_draining`, `ci_slots_total`, `ci_slots_busy`,
`ci_host_idle_seconds_max`, `ci_queue_wait_seconds_max`, `ci_mig_target_size`,
`ci_drain_verdicts{outcome}`, `ci_orphan_registrations_reaped`,
`ci_poller_heartbeat`.

`ci_orphan_registrations_reaped` should sit at zero at steady state: a pool that
keeps reaping is losing hosts without going through the drain path.

`ci_poller_heartbeat` is published on every tick including a failed one:
"no data" there means the controller is down, which no other series can
distinguish from "the pool is idle".

## Layout

```
modules/ci-runner-host-pool/     the module consumers reference
  scripts/drain-decision.sh      pure scale-in rule (unit-tested)
  scripts/orphan-decision.sh     pure registration-reap rule (unit-tested)
  scripts/host-startup.sh        registers K agents; installs nothing
  scripts/controller-startup.sh  poll, publish, drain
  scripts/telemetry.sh           the single metric publisher
packer/ci-host-image.pkr.hcl     the golden image; repo-agnostic
scripts/ci/lane-decision.sh      pure CI-lane rule (unit-tested)
scripts/ci/                      self-tests
docs/ci-lane-model.md            the lane contract consumers adopt
docs/ci-optimization-catalog.md  the fleet audit behind that contract
```

## The CI lane model

This repository also publishes *how much CI a pull request deserves*, for the
same reason it publishes the pool: the rule had been re-derived in four
repositories with four different path lists, and two of them evaluate it inside
a `runs-on: [self-hosted, ...]` job — so a documentation-only pull request
claims a pool slot in order to decide it has nothing to do.

`scripts/ci/lane-decision.sh` is that rule as a pure function, asserted by
`scripts/ci/lane-decision.selftest.sh` on every change here. Three lanes:
`none` (no self-hosted job at all), `partial` (affected areas), `full` (diffs
whose blast radius is not visible in the diff — lockfiles, Dockerfiles,
workflows, infrastructure, migrations).

Consumers adopt it by tag, never by copying — see
[`docs/ci-lane-model.md`](docs/ci-lane-model.md) for the four adoption
requirements and the order they must be done in. The audit that produced it,
with per-repository measurements, is in
[`docs/ci-optimization-catalog.md`](docs/ci-optimization-catalog.md).

## Genericity

No customer, repository, project or region literal appears anywhere in this
repo. One image and one module serve every consumer; everything a host needs to
know about who it serves arrives as instance metadata at boot. A build flag
that made the image "the X image" would recreate, in the artifact, the drift
that vendoring created in the module.
