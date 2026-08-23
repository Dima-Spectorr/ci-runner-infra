# One controller, four pools — and the merge queue sized by its own configuration

Status: **accepted** 2026-08-23, rollout in progress. The decision is settled;
the capability is being delivered in five pull requests and adopted repository
by repository after that. The delivery table in §7 is the record of what has
actually landed — read it before assuming any part of this is live.
Scope: every repository on the fleet.
Related: [`ci-lane-model.md`](ci-lane-model.md) is the operational description of
the same thing and is where the routing contract and the capacity formula are
kept current. [`ci-merge-queue-baseline.md`](ci-merge-queue-baseline.md) §"The
fleet runner budget" is amended by this decision.
[`adr-windows-pool.md`](adr-windows-pool.md) §1 is amended by it too: a pool no
longer gets its own controller.

## The decision

1. **One controller serves a table of pools**, not one pool. A repository runs
   **four**: Linux CI, Windows CI, Linux merge-queue, Windows merge-queue.
2. **A pool declares a `role`.** `ci` and `merge-queue` answer disjoint label
   sets, and a workflow's `runs-on` chooses between them conditionally.
3. **The merge-queue pool's size is derived from the repository's own
   `.mergify.yml`**, read live by the controller. Nobody types it.
4. **The Windows pair ships at `max_hosts = 0`** — declared everywhere,
   provisioned nowhere, until a repository actually needs Windows in the queue.

## Why

### The reported problem: green CI, and then nothing

A pull request passes CI, enters the Mergify queue, and Mergify runs the same
workflows again as a speculative check. Those runs need runners, and there were
none left — the CI pool was busy serving the pushes of everybody else. The queue
did not fail. **Its checks sat pending**, on a pull request whose own CI was
green, for as long as it took. Nothing anywhere was red.

Two properties of that failure decided the shape of everything below:

- **It is invisible.** A throttled queue reports *pending*, never *failed*.
  Every rule here therefore fails open — an unknown resolves to the ceiling
  Terraform already gave the pool, never to a smaller one.
- **It is a contention problem, not a capacity problem.** Adding hosts to the
  one shared pool would have worked, at the cost of paying for the peak of two
  workloads that peak at different times. Separating the two consumers costs
  nothing and makes each one's demand legible on its own.

### Why four pools and not two

The OS axis and the role axis are independent, and the fleet already had the OS
one. Windows CI exists ([`adr-windows-pool.md`](adr-windows-pool.md)); a Windows
job that has gone green must be re-run by the queue on a Windows host. Declaring
only the Linux pair would have left the Windows queue lane to be retrofitted
later into a routing contract that had already shipped, which is the expensive
order to do it in.

Declared at zero hosts, the Windows pair costs a table row. What it buys is that
the four-pool shape is the *same* shape in every repository — so the routing
rule, the label sets and the migration are one thing to learn rather than two,
and turning Windows on later is a `max_hosts` change rather than a design.

### Why one controller and not four

The controller is a 2-vCPU always-on VM whose per-tick work is a GitHub sweep.
Four controllers means four VMs, four sweeps against a shared installation rate
limit, and four copies of state that must agree about the same repository. One
controller with a pool table means one sweep whose results are partitioned per
pool — measurably cheaper, and the *only* version in which one pool's view of
the repository cannot disagree with another's.

The cost is real and was accepted: the controller is now a single point of
failure for four pools instead of one. It is mitigated by the pool table being
data rather than code (a pool is added by a Terraform variable, not a rewrite),
and by every per-pool global being reset on selection — a contamination class
that `scripts/ci/multi-pool.selftest.sh` exists to gate, because it did not
exist while there was only ever one pool.

### Why the queue's size is read and not configured

`max_parallel_checks` is the number Mergify acts on. It lives in the served
repository's `.mergify.yml`; the pool that has to satisfy it is created by
Terraform in *this* repository. Any configured ceiling is therefore a copy of
somebody else's number, made at apply time, in a different repository, and
correct only until they change theirs. Eight repositories had eight of those,
and no mechanism existed to notice that one had drifted.

Reading it live removes the copy. The formula is

```
hosts = ceil( Σ max_parallel_checks × jobs per check ÷ slots per host )
```

and it is the same formula on every controller in the fleet, which is what makes
it a standard rather than eight numbers to keep in step.

Three sub-decisions inside it are worth naming, because each had a plausible
alternative:

- **Jobs per check is observed, not configured.** It is however many of a pool's
  jobs one workflow run contains — a property of the workflow file that changes
  whenever anybody edits it, and one no operator can state correctly for long.
  The demand sweep already counts exactly that, per run and per pool, so the
  controller keeps the high-water mark for free. Its error direction is safe:
  too high only authorises hosts that real demand never asks for, because the
  ceiling caps demand and does not create it.
- **`batch_size` is read and does not multiply.** In `parallel` mode a batch is
  validated as ONE speculative pull request. It is nonetheless read and
  published, because "ten queued pull requests need ten runners" is the natural
  intuition and a metric settles that argument where a comment does not.
- **The ceiling is applied by clamping published demand.** The controller never
  scales out — a regional autoscaler pinned `ONLY_UP` consumes `ci_demand`, and
  the controller owns only scale-in. Published demand is therefore the one lever
  a derived ceiling can pull. Terraform's `max_hosts` stays the hard stop
  underneath it, so the derived number is a *soft* ceiling and the platform's
  answer is unchanged when the two disagree.

### What is deliberately not done

- **A CI pool is never clamped.** Its work comes from people pushing commits,
  which no configuration file bounds. Deriving a ceiling for it would be
  inventing a limit.
- **No new operator knob.** The whole point is that the four-pool shape and its
  sizing are standard. A repository differs from its neighbours only in the
  numbers already in its `.mergify.yml` and its pool `.tfvars`.
- **No cross-repository read at apply time.** Terraform would have to fetch the
  served repository's configuration at plan time, and the result would be stale
  on the next merge into it.

## Consequences

**New GitHub App permission: `Contents: read`.** This is the one that can make
the derivation fail open *permanently* rather than transiently, so it is called
out here and in the onboarding steps. Without it the read is a 403, the pool
keeps its Terraform ceiling, and `ci_queue_config_age_seconds` climbing past the
300-second read interval is the only sign. That is also why a non-2xx which is
not a 404 keeps the previous facts rather than being recorded as "this
repository has no queue".

**A new runtime dependency, `python3-yaml`**, installed by the controller on
first boot alongside `jq`. Its absence is not fatal by design: the reader exits
non-zero, the rule fails open, and the pool keeps its configured ceiling.

**Seven new metrics**, published only by a merge-queue pool — absence is normal
on a CI pool. `ci_queue_capacity_wanted_hosts` above `ci_queue_capacity_hosts`
is the alert, as a comparison rather than a threshold. `ci_queue_demand_clamped`
should sit flat at zero: it bounds a fault, not a routine throttle.

**Migration is per repository and not optional.** Every repository on the fleet
moves to four pools; a repository left on the old single-pool shape keeps the
bottleneck this decision exists to remove, and keeps a controller whose
behaviour differs from every other one.

## Delivery

| # | what | state |
|---|---|---|
| 1 | Controller reads a table of pools; one GitHub sweep per tick | merged (#266) |
| 2 | Terraform surface — `manage_controller`, `pool_descriptor`, `modules/ci-runner-controller` | merged (#267) |
| 3 | Routing contract — pool `role`, a disjoint label set, the conditional `runs-on` | merged (#298) |
| 4 | Auto-size the merge-queue pool from the repository's Mergify config | open (#305) |
| 5 | This ADR, and the docs it amends | this pull request |
| 6 | Fleet migration — one pull request per repository, four pools each | tracked in #274 |
