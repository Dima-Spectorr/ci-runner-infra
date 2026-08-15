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
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.9.0"
  # ...
}
```

A drift gate in each consuming repository fails CI if a local
`infra/terraform/modules/ci-runner-*` directory reappears.

**Putting a new repository on the fleet:**
[`docs/onboarding-a-repository.md`](docs/onboarding-a-repository.md) — the whole
sequence, including the label rule whose failure mode is a pull request that
hangs rather than an error.

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

### Getting a new template onto a busy host

`terraform apply` moves the *definition* of a host. It does not move a host. The
MIG's `update_policy` is `OPPORTUNISTIC` on purpose — `PROACTIVE` would delete
hosts to apply a new template, and an arbitrary victim here carries up to
`slots_per_host` running jobs. So a new template sits there, and hosts adopt it
only when something else happens to delete them.

That "something else" was `drain_decision()`, which knows nothing about
templates: it retires a host for being **idle** past the warm window. A pool with
work never goes idle for fifteen minutes, so it can keep running the previous
startup script indefinitely. Measured on 2026-08-15: v5.7.0 was applied to the
IntegrateIT pool and five hosts created the day before kept serving jobs from the
old template afterwards. The apply reported success. That was true, and it was
not the question anyone was asking.

`recycle_decision()`
(`modules/ci-runner-host-pool/scripts/recycle-decision.sh`, pure and
self-tested like the other two) closes that gap, and it never interrupts a job.
It is two-phase, and the phases are ticks apart:

* **cordon** — deregister the stale host's **idle** agents. GitHub refuses to
  deregister an agent that is executing a job, and that refusal is the guard: the
  working slot survives and its job runs to completion, while every idle slot
  leaves the pool, so no *new* job can ever reach this host again. Agents here
  are not `--ephemeral` and their unit is `Restart=no`, so a deregistered slot
  stays deregistered.
* **retire** — once the last job lands and the host is empty, it goes through the
  ordinary drain sequence: deregister the remainder, verify no `Runner.Worker`
  survives, delete. The autoscaler is `ONLY_UP` with `min_replicas = min_hosts`,
  so it rebuilds the host from the **current** template. Retiring at the floor is
  not churn — it is the replacement.

Bounded by `recycle_max_unavailable`, which is how many hosts may be mid-recycle
at once. A cordoned host's idle slots leave the pool immediately, so cordoning
every stale host at once would remove the fleet's whole spare capacity in one
tick and leave every queued job waiting on a boot. **The default is `0`, which
disables the mechanism entirely** — every existing consumer of this module
predates the feature, and a rule that deletes machines on nobody's trigger needs
a switch that stops it without a rollback. Start at `1`.

Two series make it observable. `ci_hosts_stale_template` climbs when a template
lands and falls back to zero as hosts are replaced; **stuck** above zero is the
state that was invisible on 2026-08-15 — alert on sustained non-zero, not on the
spike, because the spike is a release working. `ci_recycle_verdicts` counts
`cordoned` and `retired` per tick: `cordoned` climbing while `retired` stays flat
means the recycle is working and the hosts are not leaving — jobs that never end.

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
* **The controller has its own identity, and it is not the hosts'.** Scale-in
  is the controller deleting hosts, which needs
  `roles/compute.instanceAdmin.v1`; on a shared account that role rides every
  host VM, so job code out of the container fence could delete the pool it runs
  on — other repositories' in-flight jobs included — or create instances with
  the host identity attached. `ci-runner-identity` creates `<account_id>-ctl`
  and puts the grant there; `ci-runner-host-pool` REQUIRES
  `controller_service_account_email` and rejects a value equal to
  `service_account_email`. It used to default to "reuse the host account", and
  every consumer took that default, so it is no longer a default at all.
* **Each slot is its own Linux user with its own rootless Docker daemon.** Slots
  used to share the `runner` account and the one system daemon, so a job that
  reached `/var/run/docker.sock` — which every job could, because that socket is
  how an agent creates service containers at all — could enumerate the sibling
  slots' containers, `exec` into them, and read their `GITHUB_TOKEN`, their
  workspace and whatever the credential broker minted for them; and because the
  host is warm, later jobs' too. The metadata fence never contained this: it
  blocks the metadata server, not the daemon. Now slot `i` runs as `ci-s<i>`,
  its daemon runs as that user with its socket in a 0700 `/run/ci-s<i>`, and the
  rootful daemon is masked on the host, so there is no shared socket left to
  reach (#10). The same split ends the shared `$HOME` that raced pnpm's store
  install between concurrent slots. **This requires image `v3-11-0` or later** —
  an older image has no `dockerd-rootless.sh`, and a host that boots one refuses
  to register rather than quietly putting every slot back on one daemon.
* **A job never inherits the previous job's cloud credentials.** The slot user
  is a normal Linux account, so its `$HOME` outlives every job the slot serves —
  and `setup-gcloud` persists whatever `google-github-actions/auth` produced as
  gcloud's *active* account. Nothing cleared it, so a deploy workflow left a
  deploy-capable identity in a home that the next pull-request job on that slot
  read as its own. Every pool now runs a root-owned reset hook
  (`ACTIONS_RUNNER_HOOK_JOB_STARTED` and `..._COMPLETED`) that removes
  `~/.config/gcloud` and `~/.gsutil` at both ends of every job, including on
  pools with no job service account, where an inherited credential is worst.
  Found because it also broke the thing nobody was watching: IntegrateIT's
  `pr-check` authenticates nowhere and expects the broker's ADC, picked up the
  stale external account instead, and ran with a permanently cold Turbo remote
  cache — a `token is expired` warning per cache call on every single run.
* **The metadata fence stops at port 80, and that is deliberate.**
  `169.254.169.254` is two services on one address: the metadata server over
  HTTP on port 80, and the VPC resolver on port 53. A container is handed that
  address as its only nameserver, so a blanket per-uid `REJECT` fences the token
  endpoint *and* takes name resolution away from every container a job starts —
  reported inside the container as `Temporary failure in name resolution`, which
  reads as a broken upstream registry rather than as host policy. Port 53 is let
  through per slot uid; port 80 is not, and the token endpoint still times out
  from inside a job's containers.
* **Each slot lingers.** A slot user never logs in, so it has no user systemd
  manager and no user D-Bus. `runc` asks systemd for a cgroup scope in
  `user.slice`; with no user manager to ask, it falls through to the system
  manager, which refuses an unprivileged caller with *Interactive authentication
  required*. Image builds keep working — buildkit needs no scope — and starting
  a container does not. `loginctl enable-linger` plus a per-slot
  `DBUS_SESSION_BUS_ADDRESS` is what makes the two agree.
* **The boot probe asserts the capability, not the daemon.** Both faults above
  left `docker info` answering, so a probe that only asked the daemon whether it
  was up passed on hosts where no job could run a container. It now also
  requires the slot's user bus to exist and the slot user to resolve a name. It
  deliberately does not start a container: that would need an image, and would
  turn a registry outage into a fleet that refuses to register.
* **`/tmp` is per slot, and the slot's daemon shares it.** Slots are separate
  users on one host, so a workflow step naming a fixed path under `/tmp` —
  and CI scripts name fixed paths there constantly — creates it under whichever
  slot ran first, and every later slot gets `Permission denied` on a file it
  believes is its own. It reads as a bug in the repository rather than as host
  policy, and it moves between repositories with whichever slot got there
  first. Each slot's dockerd runs with `PrivateTmp=yes` and its runner agent
  joins that same namespace, so `docker run -v /tmp/x:/x` still mounts the file
  the step just wrote instead of an empty directory.
* **The shared warm cache is still shared, on purpose.** `/opt/ci-cache` is
  group-writable to `ci`, which every slot user joins — **from image `v3-12-0`
  on**. `v3-11-0` warms the tree as root under umask 022, so the slots can read
  it and none can update it; a package manager refreshing a partially warmed
  cache fails there, looking like a flaky upstream repository. That is the
  speed-up, and
  it is why a pool serves one repository (see the first rule) — a poisoned cache
  entry reaches the next job either way.
* **A warm cache is untrusted build input.** A poisoned cache entry survives to
  the next job, which the old destroy-per-job model made impossible. Caches are
  scoped per repository and rebuilt with the image.

## Telemetry

Every pool publishes the same series under `custom.googleapis.com/github/`, on
a `generic_node` resource labelled `repo` and `pool`, through one publisher
(`scripts/telemetry.sh`). One fleet dashboard covers every repository with no
per-repo dashboard code.

**The pool.** `ci_demand` (queued **and** in-progress — counting queued alone
collapses to zero the moment work starts), `ci_demand_queued`,
`ci_hosts_running`, `ci_hosts_max`, `ci_hosts_draining`, `ci_slots_total`,
`ci_slots_busy`, `ci_host_idle_seconds_max`, `ci_queue_wait_seconds_max`,
`ci_job_running_seconds_max`, `ci_mig_target_size`, `ci_drain_verdicts{outcome}`,
`ci_orphan_registrations_reaped`, `ci_hosts_stale_template`,
`ci_recycle_verdicts{outcome}`, `ci_poller_heartbeat`.

**The controller's own health.** `ci_tick_seconds`,
`ci_runner_list_blind_ticks`, `ci_demand_runs_skipped`,
`ci_outcome_runs_skipped`.

**The work, not the pool.** `ci_jobs_completed{workflow,outcome}` and
`ci_job_seconds{workflow}` — per-tick deltas on a gauge, so sum them over a
window rather than averaging, and read them next to `ci_poller_heartbeat`
because both are absent (not zero) when nothing finished.

The full list is `metric_names` on the pool module; `scripts/ci/metric-contract.selftest.sh`
fails if the code and that output ever disagree, in either direction.

`ci_orphan_registrations_reaped` should sit at zero at steady state: a pool that
keeps reaping is losing hosts without going through the drain path.

`ci_queue_wait_seconds_max` and `ci_job_running_seconds_max` are the two halves
of a job's wall clock — how long it waited for a runner, and how long it has
held one. The second is what makes a wedged slot visible: when a runner agent
stops taking steps mid-job, GitHub still reports the job in flight and the
orphan reaper deliberately backs off from a busy runner, so nothing else in the
system can see it until the job's own `timeout-minutes` cancels it and fails a
required check. Threshold it per repository — there is no fleet-wide number that
is right for both a lint job and an integration suite — and alert on it together
with `ci_demand_runs_skipped`, because it rides the same sweep and is a lower
bound whenever that sweep ran out of budget.

`ci_poller_heartbeat` is published on every tick including a failed one:
"no data" there means the controller is down, which no other series can
distinguish from "the pool is idle".

## Layout

```
modules/ci-runner-network/       the per-project firewall posture (no NAT)
modules/ci-runner-host-pool/     the module consumers reference
  scripts/drain-decision.sh      pure scale-in rule (unit-tested)
  scripts/orphan-decision.sh     pure registration-reap rule (unit-tested)
  scripts/recycle-decision.sh    pure stale-template recycle rule (unit-tested)
  scripts/host-startup.sh        registers K agents; installs nothing
  scripts/controller-startup.sh  poll, publish, drain
  scripts/telemetry.sh           the single metric publisher
packer/ci-host-image.pkr.hcl     the golden image; repo-agnostic
scripts/ci/lane-decision.sh      pure CI-lane rule (unit-tested)
scripts/ci/                      self-tests
docs/onboarding-a-repository.md  how to put a NEW repo on the fleet
scripts/ci/check-merge-queue-single-step.sh
                                 the merge-queue rule consumers copy in
scripts/ci/check-runner-policy.sh
                                 which pool a job may claim, and for how long
scripts/ci/check-action-pins.sh  every third-party action pinned to a commit
docs/ci-workflow-gates.md        those two gates: rules, flags, how to adopt
docs/ci-lane-model.md            the lane contract consumers adopt
docs/ci-merge-queue-baseline.md  one CI run per PR: the queue config + gate
docs/ci-optimization-catalog.md  the fleet audit behind that contract
packer/warm-cache/                optional baked caches, chosen per pool
.github/actions/playwright-ui/   the steps a repo's browser suite runs
docs/ui-testing-on-the-fleet.md  running Playwright UI tests on the fleet
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

## One CI run per pull request

The lane model decides how much CI a pull request deserves; it does not decide
how many times that CI runs. Mergify validates a queued pull request on a
throwaway `mergify/merge-queue/<sha>` branch — firing every `pull_request`
workflow a **second** time, on the fleet — unless the queue is serial,
unbatched, retry-free and single-step, and the fleet was in that state on
2026-08-14 (one repository's config was rejected outright and its queue was
failing closed).

`scripts/ci/check-merge-queue-single-step.sh` is that rule, self-tested here on
13 fixtures and copied into each consuming repository under the same name.
[`docs/ci-merge-queue-baseline.md`](docs/ci-merge-queue-baseline.md) has the
reference `.mergify.yml`, the five properties, and where the gate must sit for
a `.mergify.yml`-only change to reach it.

## Releasing a version

`VERSION` holds the tag this repository currently publishes. Bump it **in the
same pull request as the change being released**. CI asserts that every module
pin printed in the documentation names the version in `VERSION`
(`scripts/ci/docs-pins.selftest.sh`) — the README quickstart had otherwise sat
three minor versions behind the fleet, in the one line a new consumer is most
likely to paste verbatim.

**The tag is created for you.** On every push to main, `publish-tag.yml` reads
`VERSION` and creates that annotated tag at the merge commit if it does not
already exist, then advances the floating major tag (`v5`) to it. Tagging was a
human step until v5.7.0 and it lapsed: tags stopped at v5.3.2 while `VERSION`
said v5.7.0, so v5.4.0, v5.5.0 and v5.6.0 merged, passed every gate, updated
every documented pin — and could not be pinned by anyone. Nothing went red,
because every gate that could have seen it compares the docs to `VERSION`, and
`VERSION` was right the whole time.

A published exact tag is never moved: it is what a consumer pinned. Only the
major tag floats, and it floats **forward only**. `publish-tag.yml` reads the
`VERSION` at the commit `v5` currently resolves to and refuses to move the tag to
anything older — a revert, a bad cherry-pick or a merge restoring an older
`VERSION` would otherwise walk the floating tag backwards, and that is a
fleet-wide downgrade that arrives at every consumer on its next apply with no
pull request anywhere and nothing red. An unreadable current version fails the
release rather than moving the tag blind; the next push to main retries it.

Consumers choose how they adopt:

| pin | adopts | costs |
|---|---|---|
| `?ref=v5.7.0` | when the repository opens and merges a bump | one pull request per release, per repository |
| `?ref=v5` | at its next `terraform apply` | nothing, and no review of what changed |

Either way a release does not repin anybody, and **nothing applies Terraform** —
a merged bump changes what the next apply will build, not what is running.

## Genericity

No customer, repository, project or region literal appears anywhere in this
repo. One image and one module serve every consumer; everything a host needs to
know about who it serves arrives as instance metadata at boot. A build flag
that made the image "the X image" would recreate, in the artifact, the drift
that vendoring created in the module.
