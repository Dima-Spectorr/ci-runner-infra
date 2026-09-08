# The scale-down contract

What is allowed to delete a runner host, what must be proven first, and what an
operator should see when a deletion is refused.

This document exists because the contract was implicit, and an implicit
contract cannot be audited. Read it with
[`docs/adr-four-pool-controller.md`](adr-four-pool-controller.md), which says
why a controller owns scale-in at all.

---

## The shape

A warm host carries K concurrent jobs. That single fact is why nothing outside
the controller may choose a victim:

* the regional autoscaler is pinned `mode = "ONLY_UP"`. It may add hosts. It
  may never remove one, and there is no `scale_in_control` because there is no
  scale-in for it to control.
* the MIG's `update_policy` is `OPPORTUNISTIC` with `max_unavailable_fixed = 0`,
  so publishing a new instance template does **not** roll the fleet. Hosts
  adopt a new template by being recycled through the same controller path as
  any other deletion.
* the host MIG carries no health check, so autohealing cannot recreate a host
  under a running job.
* **there is exactly one call in this repository that deletes a runner host**
  — `gcloud compute instance-groups managed delete-instances`, in
  `drain_host()`. Adding a second is a change to this contract, not an
  implementation detail.

## What must be true before a host is deleted

Five gates, in order. Every one of them fails **closed**: an unanswered
question keeps the host. A wrong keep bills for one host until the next tick.
A wrong delete costs up to `slots_per_host` merge-blocking jobs and reports
itself as a test failure, so nobody finds out from here.

| # | Gate | Where | Refuses when |
|---|---|---|---|
| 1 | **The roster was read in full** | `fetch_runner_roster()` → `drain_decision` rule 2b | the runner listing was truncated, capped, or unreadable, and the host is not fully `present` |
| 2 | **The verdict authorises it** | `drain_decision()` | busy slots, inside the idle grace, at the floor, still booting, registration unknown |
| 3 | **No pin hold** | `pin_hold_gate()` | a job is pinned to this host |
| 4 | **GitHub let the agents go** | `drain_host()` DELETE loop | any agent returns HTTP 422 — GitHub refuses to deregister an agent that is executing a job. **This is the mid-job guard.** |
| 5 | **No worker process is alive** | `drain_host()` live-worker probe | a `Runner.Worker` is running, **or the probe could not be answered at all** |

Order matters and is part of the contract: **deregister first, delete second.**
Deregistering is what makes the host ineligible for new work, so gates 4 and 5
are not racing the scheduler while they run.

## Absence is not an observation

Gate 1 is the one that was missing, and it is the subtlest.

`absent` and `partial` registration are not readings. They are the *failure to
find* a reading — computed by counting how many of a host's agents appear in
one GitHub runner listing. So a listing that stops short reports them for a
host whose agents are up and executing jobs, and reports `busy = 0` for the
same reason.

That is worse than a wrong verdict, because it defeats gate 4 in the same
stroke: the mid-job guard is GitHub refusing to deregister a busy agent, and a
host with no visible agent ids has nothing to be refused. **Both halves of the
protection fail on the same input, in the same direction.**

And it fails fleet-wide. A truncated listing is not a property of one host, so
every host past the cut answers identically in the same tick.

> **Measured 2026-09-06.** The roster was read as a single unpaginated
> 100-record page against 176 slots on 45 hosts, 108 of the registrations
> offline — and offline registrations occupy page 1 exactly like live ones, so
> the agents cut off were disproportionately the working ones. Four kill waves
> in 25 minutes hit nine pull requests, several twice. One wave killed shard 1
> of one pull request, shard 5 of another and two unrelated jobs **in the same
> second on different hosts**. Simultaneity across independent hosts is the
> signature of a fleet-uniform input.
>
> **Measured 2026-09-08.** The same signature killed a `main-health` job on the
> tip of the default branch after 613 of 614 tasks had passed, and a build-poll
> check alongside it. The consuming repository's merge lane reads the health of
> the base branch — not only its two required checks — so it refused to merge
> **anything at all** until a human re-ran the job. The blast radius of this
> defect is therefore not "one false red on one pull request"; landed on the
> base branch it is a full merge freeze.

So the roster is now walked to its end, and when it cannot be, the controller
says so and no host is drained on an absent or partial registration that tick.
A host that was seen **completely** — all K slots — is still drainable, because
its busy count is whole regardless of who else was cut off. Truncation must not
pin an idle pool at full size for ever; that would trade this defect for the
immortal-VM one.

## No answer is not a "no"

Gate 5 asks the host, over an IAP-tunnelled ssh, how many `Runner.Worker`
processes are alive. It used to read an empty reply — a failed tunnel, a
missing firewall rule, a permission error, a hang — as *zero workers*, and fall
through to the delete. It was also the only such call with no timeout, so the
failure it could not distinguish was the failure it invited.

The probe is now bounded (`WORKER_GATE_SSH_TIMEOUT`), and an answer is a
**count** or it is not an answer. Empty, non-numeric, or a non-zero exit are
all `undetermined`, and `undetermined` keeps the host.

## What an operator should see

**Time series** (`ci_worker_gate_verdicts`, `ci_drain_verdicts`):

* `outcome="undetermined"` rising — the live-worker probe is not getting
  answers. Usually IAP, a firewall rule, or the controller's service account.
  The fleet is **safe** while this is high, and **oversized**: nothing is being
  deleted. This is the series that tells a broken probe apart from a genuinely
  busy fleet, which is `outcome="held"`.
* `outcome="aborted"` rising — drains are being started and refused.
* `ci_hosts_running` flat at max while demand is low, with either of the above
  elevated, is a stuck scale-in rather than a healthy warm pool.

**Log lines**, on the controller:

```
runner roster hit the <N>-page cap — the listing is TRUNCATED, so no host will be drained ...
drain <host>: could not read the runner roster in full (rc=<n> status=<s>) — absence is unproven, aborting
drain <host>: the live-worker probe returned no usable count (...) — cannot prove this host is idle, leaving host up
drain <host>: runner <id> refused deregistration (HTTP 422) — host is working, aborting
GitHub runner list unavailable this tick (status=..., consecutive=<n>) — ... nothing will be drained (fail-safe)
```

Every one of those is a **refusal to delete**. None is an incident on its own;
a *run* of them is a pool that has stopped scaling in.

**The signature this contract exists to eliminate**, in a consuming
repository's job log:

```
##[error]Process completed with exit code 143.
##[error]The runner has received a shutdown signal. ...
```

with no test or assertion named, sibling shards `cancelled`, and — the part
that distinguishes it from an ordinary cancellation — **the same second across
unrelated jobs on different hosts**. Two corroborating reads, both cheap:

* the job's log blob may be missing entirely (`BlobNotFound`) or the job may
  have no step output at all — a job killed before or during upload cannot have
  written one, whereas a job that failed an assertion always has;
* the controller log at that timestamp names the host and the verdict. If it
  names none, the deletion did not come from here.

## Changing this contract

* A new call that deletes, resizes, abandons or rolls a host is a change to the
  contract. Say so in the pull request.
* A gate may be added. A gate may not be made to fail open — including "just
  for the degraded case", which is how gate 5 acquired the behaviour above.
* Every gate is exercised by a self-test that can fail:
  `scripts/ci/drain-decision.selftest.sh` for the pure rule,
  `scripts/ci/controller-scope.selftest.sh` for the I/O gates. A rule that
  cannot be tested is a rule that ships wrong.

## Known, and deliberately not fixed here

The drain arm of the controller's host loop has **no per-tick cap**, unlike the
recycle arm's `RECYCLE_MAX_UNAVAILABLE`. That is what turned one bad read into
a four-host wave rather than a one-host mistake. With gate 1 in place a
fleet-uniform false `absent` is no longer reachable, so a cap is defence in
depth rather than a fix, and it needs a variable and its plumbing. Tracked
separately.
