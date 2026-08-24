# One workflow run, one host — and one shared infrastructure stack on it

Status: **accepted** 2026-08-22. Implementation lands phase by phase; the
delivery table in §6 is the record of what is live.
Scope: every repository on the fleet, both pools.
Related: [`ci-lane-model.md`](ci-lane-model.md) decides *how much* CI a diff
deserves; this decides *where* that CI runs and *what it shares*.
[`adr-windows-pool.md`](adr-windows-pool.md) §3A and §4 are the constraint this
document's third rule has to live inside.

## The three rules being adopted

1. **One pull request's self-hosted work runs on one host** — except a pull
   request that also needs the Windows pool, which uses two: one Linux host and
   one Windows host.
2. **Infrastructure a suite needs — a database, a broker, a cache — is brought
   up ONCE per pull request** and shared by every test and every container that
   pull request runs.
3. **A job on the Windows host can reach that shared infrastructure**, which
   lives on the Linux host.

They are one decision, not three. Rule 2 is only meaningful if rule 1 holds —
"once per pull request" has no referent while a pull request's jobs are
scattered across whichever hosts the pool happened to have idle. And rule 3 is
the price of rule 1's exception: the moment a pull request legitimately occupies
two hosts, the shared stack is on one of them and the other has to cross a
network boundary this fleet currently denies in both directions.

**The enforceable unit is a workflow run, not a pull request.** `needs:` and job
outputs do not cross workflow runs, so two `pull_request` workflows cannot agree
on a host without a lease store — and §2.2 rejects lease stores. Rule 1 is
therefore delivered as "one workflow run, one host", and a repository gets "one
pull request, one host" by consolidating its `pull_request` CI into one
workflow. That consolidation is step 2 of adoption, before anything else here
takes effect. The title of this document says what is actually true.

---

## Why this is being written

Three separate observations, one cause.

**The pool is the binding constraint and the arithmetic is not close.** Issue
[#205](https://github.com/Dima-Spectorr/ci-runner-infra/issues/205) measured it:
`max_hosts 3` × `slots_per_host 4` = 12 concurrent slots, against ~25 jobs for a
single Apigee-Portal pull request with three to four pull requests routinely in
flight. Measured queue waits of 50 s, 98 s, 180 s and 291 s, and — the part that
matters here — *displacement*: `TypeScript type-check` finished at 139 s on one
head and at 310 s and 406 s on two others, because unrelated pull requests were
eating the slots. A pull request's cost today is unbounded in the one dimension
the pool cannot grow.

**Every job that needs a database builds its own.** GitHub's `services:` are
per-job by construction: the agent creates them at "Initialize containers" and
destroys them when the job ends. A pull request with six jobs that each need
Postgres starts Postgres six times, migrates it six times, and seeds it six
times — on six slots that may be on three different hosts. Nothing about that is
a bug in any one workflow. It is what the primitive does.

**And the Windows pool cannot use that primitive at all.** `container:` and
`services:` fail at "Initialize containers" on a Windows host, which has no
container runtime by design — the pool exists for a WiX/`signtool` packaging
build that needs the host's real Win32 surface, and a Windows container is
precisely what breaks it (`adr-windows-pool.md` §4). `check-runner-policy.sh`
`RUNNER8` refuses the declaration so it fails in the consuming repository's own
CI rather than on the pool. That is the right refusal and it leaves a hole: a
Windows job that needs a database has, today, no supported way to get one.

---

## 1. What "one host" has to mean, given the isolation model

This is the part that cannot be decided by preference, because the host is not a
flat machine. `host-startup.sh` gives every slot its own uid, its own network
namespace, and its own rootless Docker daemon on a socket in a 0700
`/run/ci-s<i>`. The namespaces are `10.99.<idx>.2/30` on a veth to a
`10.99.<idx>.1` host end, NAT'd out of the primary interface.

So "one host" admits two readings, and they cost differently:

| reading | a pull request gets | shared infra reachable by |
|---|---|---|
| one **slot** | 1 concurrent job | that job only |
| one **host** | up to `slots_per_host` concurrent jobs | every slot on the host, *if* a path exists |

**One slot is rejected.** It makes rule 2 trivial — one daemon, one Docker
network, `localhost` everywhere — and it collapses a 25-job Apigee-Portal pull
request into a single serialized job. Measured against #205's own numbers that
trades a 291 s queue wait for a wall-clock several times worse, and it destroys
the per-check granularity the merge queue reads. The cure would be worse than
the disease it is prescribed for.

**One host is adopted.** A pull request occupies at most `slots_per_host` slots,
which is a *bound* where today there is none — that is the whole win against
#205 — and it keeps intra-pull-request parallelism at four-wide.

It also fixes the thing #205 describes and does not name: displacement is
unbounded because nothing associates a job with its pull request. Pinning makes
the association explicit, and the pool's contention moves from "every job
against every other job" to "at most three pull requests against each other",
which is a queue an operator can reason about.

### The consequence rule 2 has to absorb

Two slots on one host do **not** share a Docker daemon, a network namespace, or
a `localhost`. A stack brought up in slot 1 is invisible to slot 2 at
`127.0.0.1`, and that is deliberate: the slot fence exists because a shared
daemon socket let one job enumerate a sibling's containers, `exec` into them,
and read its `GITHUB_TOKEN` (README, "Each slot is its own Linux user with its
own rootless Docker daemon").

So sharing across slots needs a *sanctioned* path, and §3 builds exactly one.
What it must not do is rely on the path that already exists by accident — see
"Residual risk" below.

The same fence decides **who may tear a stack down**: only the owning slot's uid
can open its own daemon socket, so teardown cannot be a downstream job's
`if: always()` step — and it cannot be the owner's either, because the owner is
a job, and a job that has ended cannot run a cleanup for the jobs that follow
it. Teardown therefore belongs to the only actor that outlives every job on the
host and can still enter a slot's uid: the host-side sweeper of §3.5.

---

## 2. Pinning a workflow run to a host

### 2.1 Hosts get an affinity label

Today every agent on a pool registers the same label set, read from
`instance/attributes/ci-runner-labels` — a template attribute, identical across
the MIG. There is nothing in a `runs-on` that can name one host.

Each agent additionally registers `host-<instance-name>`, composed at boot from
`instance/name` rather than from Terraform, because a MIG generates the name and
Terraform does not know it. Both boot scripts do it — `host-startup.sh` before
`--labels "$LABELS"`, `windows-host-startup.ps1` before its `--labels` argument.
The same value is exported into every slot's job environment as
`CI_HOST_LABEL`, which is what §2.2 reads.

This is additive. A `runs-on` that names only the pool labels keeps matching
every host, because GitHub routes to any runner whose label set is a superset of
what the job asks for. Nothing that exists today changes behaviour.

### 2.2 An anchor job resolves the label — no API, no lease

The first fleet job of a workflow run is the **anchor**. It runs deliberately
**unpinned**, and whichever host answers it becomes this run's host: the anchor
reads `CI_HOST_LABEL` from its own environment and publishes the complete
`runs-on` array as a job output. Every later fleet Linux job consumes it.

**Why not a runner-list lookup.** The rejected design had a lease job list
`repos/{owner}/{repo}/actions/runners` and pick `pr_number % count`. Reading the
runner list is repository administration, `administration` is not a valid
job-level `permissions:` key, and `GITHUB_TOKEN` cannot be granted repo-admin
read at all. The mechanism was not adoptable; it was only plausible. The
fallback — a PAT — is worse than the problem, in a repository that runs
pull-request code.

**Why not a lease store.** A registry, a lock, and a lock's failure modes, to
solve a problem the anchor solves with an environment variable.

**What the anchor buys beyond removing the API call:**

- The host it names is **demonstrably alive and busy**, because a job of yours
  is on it. An out-of-band pick can name a host that drains before the first
  pinned job arrives.
- The **pin hold (§2.4) is written by the anchor itself**, so it exists before
  any job that depends on it. There is no window between selection and
  protection.
- A pinned job never has to be scheduled onto a host that might not exist, so
  the empty-pool case is not a special path — it is just the anchor queueing
  like any unpinned job does today, and the autoscaler scaling out for it.

**A host that predates this contract is a supported answer, and it is `""`.**
`CI_HOST_LABEL` unset means an older boot script. The anchor emits the unpinned
label array, downstream `runs-on` degrades to exactly today's behaviour, and the
pull request runs — unpinned, and therefore with per-job infrastructure. **The
contract degrades; it does not deadlock.** This is the single most important
property in this document, because it is the one whose absence is unrecoverable
without an operator.

### 2.3 Downstream jobs consume it

```yaml
  test:
    needs: [lane, anchor]
    if: needs.lane.outputs.lane != 'none'
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
```

`fromJSON` of a whole array, not a label appended to a literal list: an empty
affinity label appended to a list produces `[self-hosted, linux, gcp, Repo, ""]`,
and an empty-string label matches no runner at all. The anchor emits the
complete array — pinned or unpinned — so the degraded case is expressed by the
array being shorter rather than by a label being blank.

### 2.4 The controller must not remove a pinned host — by either path

A pull request between its fast tier and its heavy tier is a host that is idle
and must not be taken away: the run's remaining jobs name that host by label,
and a host that is gone is a label nothing answers.

There are **two** paths that remove a host, and the hold has to block both. The
controller's tick calls `recycle_decision()` first and `continue`s on a
`cordon:` or `retire:` verdict, so `drain_decision()` is never consulted for
that host on that tick. A hold wired only into `drain_decision()` would be
bypassed entirely by a stale-template recycle — which cordons by deregistering
idle agents, and a cordoned host stops answering its own affinity label while
the run pinned to it still has jobs to place.

So: a host carries a **pin hold** — a marker naming the workflow run and an
expiry, written by the anchor job. The hold is a **veto on the verdict**, not an
argument to it: `recycle_decision()` and `drain_decision()` keep their current
signatures and stay pure functions of their arguments, and the controller,
having reached a `cordon:`, `retire:` or `drain:` verdict for a host, reads that
host's hold and downgrades the verdict to a no-op when the hold is live. Both
paths are covered because both funnel through the same veto.

Placing it after the verdict rather than inside it is what makes the cost
bounded. A hold passed as an argument would have to be read for **every** host on
**every** tick, since `recycle_decision()` is consulted for every host; read as a
veto it is fetched only for a host the controller is about to remove, which is
rare. That is the same shape as the existing `beacon_gate()`, which vetoes a
delete rather than feeding the decision that produced it.

The expiry is what makes the hold safe to write from job context: the worst a
forged or abandoned hold can do is keep one host warm until it lapses, which is
the same cost as a slow job, and the orphan rules are unchanged above it.

**Something has to write it.** A guarantee with no writer is a sentence, so the
hold is a concrete pair: `ci-pin-hold --run <id> --ttl <duration>`, a bounded
host helper on `PATH` in every slot, which the anchor invokes before it
publishes the label — with `--reserve-slot` when it also owns shared
infrastructure (§3.1); and a reader in the controller.

**The helper publishes the hold as a guest attribute**, and the controller reads
it with `gcloud compute instances get-guest-attributes` — the same channel and
the same call `beacon_gate()` already uses (`controller-startup.sh:1388`). Three
reasons it is that and not an SSH read. Guest attributes are writable by any
process on the VM, job code included, so the helper needs no privilege the job
does not already have — which is the whole premise of §3.4. The controller needs
no shell on the host to answer a question about it. And the mechanism is already
in the module, already gated, already tested.

An earlier draft claimed the read was free because the controller already
SSHes to each host. It is not: that probe (`pgrep -fc Runner.Worker`,
`controller-startup.sh:1579`) lives **inside** `drain_host()`, which runs *after*
the verdict and *after* the host's agents have been deregistered. It could not
inform a decision that had already been made, and by the time it ran the host
had already stopped answering its affinity label. The veto owns a real round
trip — one per host being removed, per the paragraph above.

**The reader is monotonic, and that is not the beacon's rule.** A guest
attribute is writable by every process on the VM, so a co-tenant job — another
pull request's job, on another slot of the same host — can PUT a syntactically
valid but *already expired* value over the live one. `beacon_gate()`'s
first-occurrence-wins rule does not help here: it settles duplicate rows in one
read, and cannot recover a value that was overwritten before the read happened.
Left as it was, the cheapest attack on this design would be to shorten somebody
else's hold and have the controller delete the host and the shared stack for
you, during a gap between that run's jobs, with no forged privilege at all.

So the controller keeps **the greatest expiry it has ever seen for that host**,
in the `$STATE_DIR` it already uses for beacon misses, and vetoes against that
rather than against the value in front of it. A co-tenant can then only ever
extend a hold, never shorten one, and extending is already the bounded,
argued-for cost above — a host kept warm until the ceiling. The two remaining
defences are what bound it: the expiry is **clamped to a configured maximum** on
read, because job code can also write one ten years out, and a malformed hold
means keeping the host rather than dropping it — a broken publisher must not
read as consent to delete.

The same cache is what makes §2.6 work after the last Linux job has finished;
it records the run the hold names, not only the deadline. **That second reader
is not built yet** — the veto writes the record, and nothing reads it back. It
is deliberately a separate change, because it is not a veto: it decides whether
to CANCEL a run whose Linux host went away underneath a Windows tail, which is
cross-pool, irreversible, and answerable only for a hold that has already
lapsed. Tracked as [#270](https://github.com/Dima-Spectorr/ci-runner-infra/issues/270)
rather than left as an implied half of this one.

The helper ships with the host in phase 3, the veto in phase 4 — the delivery
table says so, because a hold whose writer is nobody's phase is how this arrives
half-built.

**What the veto costs when nothing goes wrong: one guest-attribute read, for a
host the controller was about to remove.** It is not asked for every host on
every tick — that is the difference between a veto on the verdict and an
argument to the rule, and at fleet scale it is also the difference between
staying inside the per-instance rate limit and manufacturing the failure that
reads as "keep everything".

### 2.6 A host that disappears must fail the run, not hang it

The hold covers the two *intentional* removals. It does not cover a crash, a
manual delete, or a MIG replacement — and a replacement comes back under a new
instance name, so it answers a different label. §2.5 then makes the failure
silent by design: the pinned jobs are excluded from scale-out demand, so nothing
even tries to serve them, and the run sits in GitHub's queue until the 24-hour
cancellation. That is exactly the unrecoverable-without-an-operator shape §2.2
exists to avoid, arriving through a different door.

So the controller — which already lists queued jobs and already knows its live
hosts — treats *a pinned queued job whose `host-*` label matches no live host*
as a bounded, reportable fault: surfaced on the existing demand series, and the
run failed within a small multiple of a tick rather than a day. Failing fast is
the whole point; a re-run anchors somewhere alive.

*(The word `queued` in that sentence was load-bearing and is no longer the whole
rule — a job that was already RUNNING when its host went away is covered by
§2.6b, under stricter conditions.)*

**A queued pinned job is not the only way a run depends on a host.** A supported
workflow finishes every Linux consumer and then spends a long tail in the
unpinned Windows job, still talking to the Linux stack across the band. If the
Linux host dies during that tail there is no queued `host-*` label anywhere to
notice, and the Windows job discovers it as a dropped connection at whatever
point it next queries — the failure this section exists to make legible,
arriving after the detector has stopped looking.

The hold cache of §2.4 is what closes it, and it closes it precisely because it
lives in the **controller's** state and not on the host: a hold that is only a
guest attribute disappears with the machine that published it. Having recorded
`run → host` while the host was alive, the controller can still answer the
question after the host is gone. A recorded host that is no longer live, whose
run is still in progress and whose hold has not lapsed, is the same bounded
fault as above and takes the same exit. The cache entry is dropped when the run
ends or the hold lapses, so it is bounded by the ceiling like everything else
here.

### 2.6b The same host, but the job was already running — and then nothing is red at all

§2.6 as originally shipped looked only at **queued** pinned jobs, and the
controller's rule said so in as many words: anything not `queued` returned "in
flight" and was never examined again, on the reasoning that a running job *has*
a host and a MIG listing that lags a boot is not evidence to cancel on.

The first half of that is only true while the host exists. When a slot dies
holding a job — a host deleted under it, an agent that stops answering, a slot
poisoned mid-run — GitHub leaves the job `in_progress` with nothing behind it,
and the check run reaches **no conclusion at all**: not success, not failure,
not cancelled, until GitHub's own 24-hour timeout.

That is a strictly worse failure than the queued one §2.6 was written for, and
it is worse in a way that is easy to miss. A queued pinned job at least sits
visibly in a queue. A job in this state produces *no signal*: nothing is red,
nothing is queued, the pool reports healthy, and the run simply never finishes.
Everything downstream then waits out **its own** timeout instead of reacting to
a result — and a merge queue is the expensive case, because it does not read a
missing status as a failure. It reads it as "still checking" and holds the entry
for its full window before dequeuing on a timeout that names no cause. Measured
on a consumer repository on 2026-08-23, that is 150 minutes spent on a pull
request whose own CI had been green for hours, and the dequeue message blames
nothing an author can act on.

So the detector now asks the liveness question of a running job too, and a job
whose host is gone is cancelled — which is the point. **A cancelled run has a
conclusion; a run whose host evaporated has none and never will.** The fix for
"the queue never got a status" is to make the job report.

**Cancelling live work is the most expensive mistake this detector can make, so
it is fenced harder than the queued case, by two clocks that must both run out.**

The clock §2.6 already had is the job's age, measured from its creation. That is
not evidence about a *host*: a job that queued for twenty minutes and then lost
its host has already spent its whole grace allowance before the host went
anywhere, so a single blipped MIG listing was enough to cancel it. Tolerable
when the cost was a re-run of something that had not started; not tolerable for
work in progress.

The second clock is an **absence ledger** in the controller's state — one file
per host, refreshed every tick for every live host, so "the file is old" and
"the host is missing" are the same statement. The effective clock is the smaller
of the two, which is exactly "both have run out", and three fail-safes sit
around it:

* **The absence clock is required for a running job.** Without a ledger there is
  no `vanished` verdict at all, only the old count-it-and-say-nothing. A caller
  that cannot answer "how long has that host been gone" does not get to cancel
  live work.
* **A tick with no host list resets every clock rather than advancing them.** An
  empty list means the list call failed or the pool is genuinely at zero, and
  those are indistinguishable — the same ambiguity §2.6 already refuses to act
  on. Letting the clocks run through a listing outage would mean the outage
  *caused* the damage rather than merely hiding it.
* **The pool bound and the two-pin rule still come first**, unchanged. A
  controller never cancels over a host it does not own.

The ledger also moves an instance name across a boundary it had never crossed
before: the absence clock is a **file named after the host**, so for the first
time a string taken from `runs-on` — text authored in a pull request — decides a
path. §2.6's rule 1b already refuses labels carrying `case`-pattern syntax, but
it lives inside the decision function, and a caller needs the host name *before*
there is a verdict, so rule 1b is not the thing standing there. `pin_host_of`
therefore enforces GCE's own instance-name charset at the point it hands the
name out, and the controller re-checks before building a path — the two live in
different files joined only at apply time, and a future caller arriving with a
name from somewhere else is exactly the change that would not look wrong. A name
that fails is simply no pin, which every caller already reads as "no absence
clock", and it could not have named a live host in any event.

The verdict is separate from §2.6's (`vanished` rather than `orphan`) and so is
its series, `ci_pinned_jobs_host_vanished` — counted per **job** and before the
per-run de-duplication, because a matrix of eight jobs on one dead host really
is eight jobs that lost their host, and because it survives a refused cancel,
which is the case where an operator most needs the number. It is the only series
the controller publishes that reports a job producing no signal whatsoever, so a
non-zero reading is never routine tidying: it is live work that lost its
machine, and sustained non-zero is a slot-health problem.

### 2.4b `host-` is a reserved label prefix

The whole of §2.5 and §2.6 reads a `host-*` entry in a job's `runs-on` as a pin
to one machine. `runner_labels` has never restricted what a pool may register,
so a pool configured long before affinity with something like `host-large` would
have had that label parsed as a pin to an instance named `large`: no live host
answers it, so the run is cancelled by §2.6 — and, worse, excluded from scale-out
demand by §2.5, so nothing is even built for it. A schedulable run, cancelled,
for a label its author chose legitimately.

Two changes, because one of them cannot reach the pools that already exist.
`runner_labels` now **refuses** a `host-`-prefixed entry, which stops a new pool
creating the collision; and the classifier treats a `host-*` label that appears
in *the pool's own registered list* as an ordinary label rather than a pin, which
is what keeps an existing pool from being cancelled on the way to fixing it. The
pool's list is the authority on which of its labels are its own; a `host-*`
label it does not carry is still a pin.

### 2.5 The controller must not go blind to pinned work

`collect_demand()` classifies a queued job as this pool's by subtracting the
pool's template label set from the job's labels and requiring the remainder to
be empty. `host-<instance-name>` is by construction **not** in the template set,
so an affinity-pinned job leaves a non-empty remainder and is dropped from both
`DEMAND_TOTAL` and `DEMAND_QUEUED`. The pool would go invisible to its own
autoscaler exactly when it is busiest.

The matcher must therefore recognise the affinity label — strip a `host-*` label
before the subset test — and then classify rather than simply count:

- **Pinned queued work is not scale-out demand.** A new host cannot serve it;
  only the named host can. Counting it would drive an `ONLY_UP` autoscaler to
  `max_hosts` for jobs no new host can take.
- **Pinned work does mark its host busy**, which is what keeps drain, recycle
  and the published series honest.

Genuine scale-out demand still exists, and it comes from the anchors — which are
unpinned by design. This is a phase-2 obligation, listed in §6, and it is not
optional: shipping the label without it degrades the autoscaler.

---

## 3. One shared stack per workflow run, reachable from both hosts

### 3.1 The owner job brings it up; nobody else does

Exactly one job owns the stack, and it is the anchor — the anchor occupies a
slot either way, so a repository with shared infrastructure should not pay for a
second job that only echoes a variable. It brings the stack up on its own slot's
rootless daemon with a compose project name derived from the pull-request
number, migrates and seeds it once, publishes the endpoints as job outputs, and
every other job — Linux or Windows — consumes those outputs.

**And then it exits — while its slot stays reserved.** Those are two separate
requirements, and the obvious way to satisfy the second breaks the first.

A slot is released the instant its job ends, and the next job to land there runs
as the *same uid against the same rootless daemon* — free to list, `exec` into,
mutate or stop a stack that other jobs are still using; the slot's between-jobs
reset would destroy it outright. Host affinity does not help: it pins a host,
and this is a *slot* problem.

The tempting reservation — keep the owner job running — is unbuildable. Job
outputs reach `needs.<job>.outputs.*` only on completion, and a dependent job
waits for its whole `needs:` list to complete. An owner that lingers to guard
the stack is holding the endpoints its consumers are queued for, while waiting
for those same consumers: every adopting workflow deadlocks on its first run.
This is the same failure shape as the runner-list lease in §2.2 — a mechanism
whose description reads fine and which cannot exist — and it is worth stating
plainly rather than quietly replacing.

So the reservation is host-side, where slots are actually a concept. It is two
mechanisms, and the split is forced rather than chosen.

The owner calls `ci-pin-hold --reserve-slot`, which writes a record into the
slot's own state directory. **Unprivileged, deliberately.** A slot's sudoers
grant is an allowlist of two literal command lines (`slot-reset.sh started`,
`slot-reset.sh completed`), and the index is taken from `SUDO_UID` so a slot
cannot even name another. Adding a rule that lets PR-authored code stop a
systemd unit would undo the most carefully argued fence on the host to save
writing a file.

`slot-reset.sh` — already root, already invoked before and after every job —
reads that record and spares this slot's containers while performing its wipe of
the workspace, home and credentials unchanged.

**The agent is stopped by the host-side sweeper**, the same root timer that owns
teardown (§3.5) and the TTL sweep. Not by the hook and not by the controller,
and neither omission is an oversight:

* **Not the hook.** `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` executes inside
  `ci-runner@<idx>.service`; a hook that stopped its own unit would have systemd
  SIGTERM the agent mid-report, so the slot would be reserved and the job lost.
* **Not the controller.** The controller has no probe that would find a
  reservation. Its only per-host shell is inside `drain_host()`, which runs after
  a removal verdict — see §2.4 — and the hold's guest attribute is read only on
  that same removal path. A host that is healthy, current-template and busy is
  never probed at all, so a controller-owned stop would simply never fire on the
  hosts this matters for. Giving it one would mean a new per-host round trip on
  every tick, paid by every host in the fleet to serve the rare reserved one.

The sweeper already runs on every host on a fixed interval and already has the
privilege, so the stop costs nothing new. The window in which a job can still
land on the reserved slot is therefore **one sweep interval**, and it is a real
window rather than a theoretical one — which is exactly why the reset half is
load-bearing and not an optimisation: the newcomer gets a clean tree, and the
stack survives it.

**One reservation per host, first anchor wins.** Several workflow runs starting
together can each have their unpinned anchor scheduled onto a different idle
agent of the *same* host. If each then reserved a slot, `slots_per_host` anchors
would between them leave the host with no agent for any of their pinned
consumers, and every one of those runs would wait for a TTL to tear down the
stack it was waiting for — a deadlock built entirely out of successful steps.
The hold does not prevent this: it blocks removal, not scheduling.

So `--reserve-slot` is an **admission decision, not a request**. It fails when
the host already carries a reservation naming a different run, and the losing
anchor reports it and continues **unpinned** — which is a supported answer this
design already has, the same one a host predating the contract gives. One run
per host gets the stack; the others degrade to today's behaviour instead of
waiting for a deadline. The record is written under the host's root-owned
reservation directory with `O_EXCL`, so two anchors racing on one host resolve
to one winner rather than two half-reservations.

One of `slots_per_host` is unavailable for the run either way; that is the price
of the stack existing at all, and it is inside the budget rule 1 already sets.

**Which makes `slots_per_host = 1` unadoptable.** On a one-slot host the owner
reserves the only agent, every consumer is pinned to that host, and nothing can
run until the TTL sweep releases the slot — at which point it tears down the
stack those consumers were queued for. A deadlock resolved by destroying its own
subject.

It is refused twice, because two different actors can be the first to know.

`ci-runner-network`'s `shared_infra_pairs` validation refuses it at PLAN time.
That map is the adoption declaration: a repository that has entered a pair has
said it intends to run the contract, and the pair carries the Linux pool's
`slots_per_host` as its own input. So the two facts a refusal needs are in one
place, and the answer arrives before anything is built. (The bound is `>= 2`
there and only there. The Windows guidance of one slot per host is about a
different variable on a different module — a Windows pool's jobs bind fixed
ports — and a Windows pool is never the pair's `slots_per_host`.)

`ci-pin-hold --reserve-slot` refuses it at RUN time, for the case the plan-time
check structurally cannot see: a pool that never declared a pair, reached by a
workflow that adopted the contract anyway. It fails the run in the anchor, with
the pool's name and the reason, rather than letting the deadlock above play out.

Adoption therefore requires `slots_per_host >= 2`, and consumer concurrency is
`slots_per_host - 1`, which is the number the budget in §1 should be read
against for an adopting repository.

`services:` is the shape being replaced. A `services:` block is per-job by
definition and there is no version of it that is shared, so a repository that
has adopted this contract declares infrastructure in exactly one place. That is
what `RUNNER10` (§4) asserts.

### 3.2 The port band, and the DNAT that makes it reachable

A slot's published port lands in the slot's network namespace. From outside the
host — and from a sibling slot — it does not exist. Two things are added:

**A per-slot port band.** Slot `idx` owns host ports `35000 + idx*100` through
`35000 + idx*100 + 99`. Slot indices start at **one** (`seq 1 "$SLOTS"`), so the
lowest band is 35100 and the **band span** — the range the firewall and the
conntrack allow are written against — is `35100` through
`35000 + slots_per_host*100 + 99`. It is computed from the same two functions
that place each band rather than restated as a formula: a firewall range and a
DNAT range that disagree fail as "the connection hangs", which is unreadable.
Disjoint by construction, so two slots publishing the
"same" service never collide — the collision that
[`setup_slot_netns`](../modules/ci-runner-host-pool/scripts/host-startup.sh)
was written for in the first place. The number of bands follows
`slots_per_host`; no part of this design may hardcode four slots, and the
firewall range in §3.3 is computed from the same variable.

**A 1:1 DNAT per band**, installed at boot beside the existing MASQUERADE:

```
-t nat -A PREROUTING -d <host primary address> -p tcp --dport <band> \
       -j DNAT --to 10.99.<idx>.2
```

**Matched on destination address, not on `-i <primary_if>`.** The main consumer
of this path is a *sibling slot on the same host*, whose packets arrive on
`cis<N>`, not on the primary interface; an input-interface match would silently
exclude the traffic the rule exists for — handing the Windows case a working
path and the same-host case a connection refused. Matching the host's own
address instead admits both while still declining anything not addressed to this
host.

**And a hairpin SNAT, because the DNAT alone is broken for exactly one slot: the
one that owns the band.**

```
-t nat -A POSTROUTING -s 10.99.<idx>.2 -d 10.99.<idx>.2 -p tcp --dport <band> \
       -j MASQUERADE
```

A consumer in slot `idx` dialling `<host address>:<its own band port>` is not a
special case on the way *in*. Its packet is not locally generated as far as the
host namespace is concerned: it leaves over `cis<idx>`, arrives as forwarded
traffic, and `PREROUTING` rewrites it like anybody else's. It is a special case
on the way *back*. The address it is rewritten to is `10.99.<idx>.2` — the
address the packet came from — so post-DNAT source and destination are equal and
the packet is routed straight back out `cis<idx>`. The slot discards it as a
martian, its own address arriving on an external interface; and even accepted,
the reply would be namespace-local, never re-enter this host's conntrack, and
never be un-DNATed into something the client's socket recognises. The general
egress MASQUERADE does not cover this: that rule is `-o <primary_if>`, and a
hairpin leaves by the veth. Scoping the SNAT to one slot's own /30 and its own
band keeps a *sibling* — which needs no help and whose real address the band's
`FORWARD` accept is written against — untouched.

Without it the connection never completes and the consumer sits until its own
timeout, which is why this presented as slow, intermittent flakiness rather than
a connection refused: it bites only the consumer jobs that happen to land on the
anchor's own slot, roughly one in `slots_per_host`. Measured in DataRetrival run
32755968066, where the anchor held slot 3, a consumer on slot 4 connected and a
consumer on slot 3 timed out against the identical URL.

**A host only gets that rule when it is rolled onto the new boot script**, so
[`shared-infra-db`](../.github/actions/shared-infra-db/resolve.sh) also resolves
the stack to loopback when `pg` falls inside the *consuming slot's own* band —
disjoint per slot, and published to the slot as `CI_SHARED_INFRA_PORT_MIN`/`MAX`,
which is the same band the anchor drew the port from. That covers the fleet
before it rolls; it cannot cover a `container:` consumer, whose steps do not
inherit the runner service's environment, nor a consumer that hand-rolls the URL
from the anchor's outputs. Those two need the kernel rule, which is the reason
it exists rather than leaving the whole fix in the action.

The `FORWARD` chain already accepts `-o cis<idx>`, so nothing in the forwarding
policy loosens today. What is new is one PREROUTING entry per slot, bounded to
100 ports, and nothing else on the host becomes reachable.

**But "already accepts" is exactly what [#249](https://github.com/Dima-Spectorr/ci-runner-infra/issues/249)
removes, and this path depends on it.** A sibling slot's packet to the host
address is DNATed in `PREROUTING` and then traverses `FORWARD` from its own
`cis<N>` to the owner's veth — the same forward that #249 exists to reject. The
two changes therefore cannot be sequenced independently: closing the broad
accepts first makes every same-host Linux consumer unable to reach the stack,
and shipping the band first leaves #249 with a path it must not simply keep
open.

The band needs its own allow, scoped to what the DNAT actually produced rather
than to an interface pair:

```
FORWARD -m conntrack --ctstate DNAT \
        --ctorigdst <host primary address> \
        --ctorigdstport <band span>                       -j ACCEPT
FORWARD -m conntrack --ctstate ESTABLISHED,RELATED        -j ACCEPT
```

Original-destination matching is the point: it admits precisely the traffic that
entered through a band DNAT and nothing that a slot addressed to a sibling's
`10.99.<n>.2` directly. That rule is installed **before** #249's reject, and
#249's own acceptance criterion becomes "a sibling reaches the band, and reaches
nothing else" — which is stronger than what either change asserts alone.

The slot learns its own band, its host label and the host's address the same way
it learns its cache paths — environment, set by the boot script:

```
CI_HOST_LABEL              host-<instance-name>
CI_SHARED_INFRA_ADDR       the host's primary VPC address
CI_SHARED_INFRA_PORT_MIN   35000 + idx*100
CI_SHARED_INFRA_PORT_MAX   35000 + idx*100 + 99
```

A job that publishes outside its band gets a port that resolves on the slot's
own `localhost` and nowhere else — which fails as "the Windows job cannot
connect" rather than as anything readable, so the owner job asserts the range
before it publishes.

### 3.3 The firewall, which is currently closed in both directions

`ci-runner-network` today grants ingress for IAP SSH (22) and health checks, and
egress for 443, 53, and `database_egress_ports` to RFC1918. There is **no**
ingress rule permitting one pool host to reach another, and the explicit
`deny-egress` at priority 65534 takes everything the allows do not name.

So rule 3 needs two narrow rules, not a posture change — and they are **not
symmetrical**, because GCP's two directions do not offer the same controls:

```
INGRESS  source_tags        = [ci-shared-infra-src-<id>]        # both pools
         target_tags        = [ci-shared-infra-stack-<id>]  # Linux pool only
         tcp: <band span>

EGRESS   target_tags        = [ci-shared-infra-src-<id>]  # the SOURCE VMs
         destination_ranges = [the pool subnet's CIDR] # ranges only
         tcp: <band span>
```

**A dedicated tag, not `network_tags`.** Both rules select VMs by tag, and a
Windows host carries no tag at all — deliberately: `adr-windows-pool.md` scopes
the `network_tags` contract to Linux precisely so a Windows host has **no
inbound path from anywhere**, no IAP-SSH rule and no listener. Reusing that tag
would have left the Windows host matching neither rule, so `deny-egress` at
65534 would take every connection to the stack and rule 3 — the whole reason
this section exists — would fail closed on the one case it was written for.

So the band gets its own tags — **two** of them, and both scoped to the
repository's pool pair rather than to the fleet.

**Scoped by an explicit shared identifier, never derived from the module's own
name.** Linux and Windows are separate module instances with separate `name`
values and separate MIGs (`modules/ci-runner-host-pool/variables.tf`), so a tag
derived per module would give the paired hosts *different* tags and the
source-tagged ingress rule would reject exactly the Windows-to-Linux traffic
rule 3 is about. Both instances therefore take the **same** `shared_infra_id`
input — one value per repository, supplied where the pair is declared — and the
tags are built from it.

**Two tags, because one tag cannot be both ends of an ingress rule.** With a
single tag on both pools, `target_tags` would name the Windows hosts as well,
and the rule would permit every tagged host in the pool pair to open TCP
connections *to* the Windows band — the inbound path `adr-windows-pool.md`
exists to deny, reintroduced by the rule that was supposed to preserve it. So:

* `ci-shared-infra-src-<id>` — the **source** tag, carried by both pools. It says
  "a host of this repository's pair may originate band traffic".
* `ci-shared-infra-stack-<id>` — the **destination** tag, carried by the Linux
  pool only. It says "a stack may be reached here".

The ingress rule is source → destination across those two. A Windows host
carries the first and not the second, so it may reach a Linux stack and nothing
may reach it. A literal `ci-shared-infra` would have been a fleet-wide tag, and
network tags match across every VM in the VPC that carries them: two
repositories whose pools share a network — which is the normal deployment, since
the module takes the network as an input — would each match the other's ingress
rule, and one repository's job could open a socket on another repository's
database. The tag must name *these* hosts. The Linux and Windows pools of one
repository deliberately share it, because rule 3 is precisely the statement that
those two may reach each other's band.

No ingress rule anywhere targets a Windows host — the only tag a Windows host
carries appears as an ingress *source* and as an egress *target*, and an egress
target selects the sending VM. The Windows ADR's decision stands unchanged.

**An egress rule cannot scope its destination by network tag.** GCP egress
destinations are IP ranges, full stop; `target_tags` on an egress rule selects
the VMs the rule applies *from*. An earlier draft of this document specified
"tag-to-tag" in both directions and was simply not expressible. The egress side
is therefore scoped to the pool's own subnet range, which the module already
knows, and the ingress side keeps `source_tags` — the narrowest statement of "a
host in this pool" that is available where it is available.

The Windows side's egress is already permitted **if** the band falls inside
`database_egress_ports`, and it does not — that list is real database ports.
Rather than widen a variable whose meaning is "a database somewhere in the
estate", the band gets its own rule. Two narrow rules that state what they are
beat one wide rule that has to be explained.

### 3.4 The Windows job reads an address, never `localhost`

There is no container runtime and no shared stack on the Windows host. A Windows
job connects to `${{ needs.anchor.outputs.addr }}:${{ needs.anchor.outputs.pg }}`.

`localhost` on a Windows fleet job is the copy-paste failure this contract
manufactures — the Linux snippet is correct on Linux and silently wrong here —
so `RUNNER11` (§4) refuses it rather than leaving it to a reviewer.

Windows jobs are **not** pinned by this contract. `slots_per_host` is 1 on that
pool, so pinning would serialize them onto one machine, while leaving them
unpinned spends one host per concurrent Windows job. The pool exists for a
single packaging build, so both answers are defensible and neither is imposed:
`RUNNER9` covers Linux jobs only. A repository that runs several Windows jobs
chooses in its own workflow.

### 3.4a A reboot ends the run; it must not quietly resume it

A reservation that lives only in a stopped unit does not survive a restart.
`ci-runner@<idx>` is `systemctl enable`d, so a rebooted host starts it again,
and its `ExecStartPre=+slot-reset.sh boot <idx>` wipes the slot before the agent
becomes schedulable. Nothing in that sequence knows a hold existed: the slot
comes back schedulable, another pull request's job lands on the owner's uid and
daemon, and the run that was pinned there is still waiting for a stack that a
reboot destroyed anyway — rootless containers do not survive the guest.

So the hold is a file, not a process state, and it records the boot it was
written under. The `boot` path of the reset — which already runs before the
agent can take work, and is therefore the right place — compares them. A hold
from a previous boot is not honoured and not silently dropped either: the host
performs the full reset, releases the slot, and marks the hold **orphaned** for
the controller to read on the probe it already makes.

That last step matters because §2.6 would otherwise miss this. §2.6 fires when
no live host answers a pinned label, and after a reboot the label is answered
again by the same instance. The orphan mark is what turns "the stack you were
promised no longer exists" into a failed run in a bounded window instead of a
pinned queue that drains at GitHub's 24-hour timeout.

### 3.5 Teardown is host-side, and so is the release

A downstream job cannot do it: different uid, and the owner's daemon socket is
in a mode-0700 `/run/ci-s<i>`. An `if: always()` teardown step in the last
consuming job fails silently, which is worse than no teardown at all. Nor can
the owner do it, for the reason §3.1 gives: it has to exit for its consumers to
start, so it is long gone before the last of them finishes.

The host owns both ends. Releasing the slot hold *is* the teardown: the sweeper
brings the stack down as the slot's own user, runs the container reset that the
hold had been sparing, and starts the agent again.

**And it needs a terminal branch, because those three steps can fail.** A daemon
that will not stop, a compose project that will not come down, a reset that
returns non-zero: each leaves the slot in a state with no good local move.
Restarting the agent would hand the next job a live stack and an unreset tree.
Leaving it stopped strands capacity past the TTL the contract advertises, and
expiring the *host* pin does not recover it — ordinary drain holds the fleet at
`min_hosts`, so the host stays, broken, with one slot fewer.

So release fails closed to host replacement: the host marks itself unhealthy
with the failing step named, the controller retires it — the `retire:` branch of
`recycle_decision`, which replaces rather than drains and is therefore not
bounded by `min_hosts` — and the MIG brings up a clean one. Bounded: one sweep
interval to detect, one recycle to replace. Visible: the failure is a reason
string on the same series as the holds, not a slot that silently stopped
existing. A host that cannot clean a slot is a host, and hosts here are
disposable; a slot is not. It fires when the controller observes
the run finished — it already lists that run's jobs — or when the TTL lapses,
whichever comes first. The TTL is the backstop that keeps a controller outage
from stranding a slot, and a band sweep catches a stack whose hold record was
lost.

---

## 4. The gate

Three rules join `check-runner-policy.sh`, which every consuming repository
already runs, so adoption needs no new wiring.

| id | Rule |
|---|---|
| `RUNNER9` | a fleet-reachable **Linux** job in a `pull_request` workflow resolves its `runs-on` from the anchor job's output, or — in a called workflow that opens no pull-request run of its own — from a **required** `workflow_call` input, or is the anchor, or carries a declared exemption |
| `RUNNER10` | at most **one** job across a repository's `pull_request` workflows is an infrastructure owner — counting `services:` blocks *and* `# shared-infra-owner(<job>): …` markers together |
| `RUNNER11` | a **Windows** fleet job does not name `localhost`/`127.0.0.1` on a shared-infrastructure port — there is nothing listening there |

`RUNNER10` counts the marker as well as `services:` for a reason that only shows
up after adoption: a repository that has moved its database into
`ci/compose.yaml` has **zero** `services:` blocks, so a rule counting only those
passes vacuously while nothing at all enforces "brought up once". The marker is
what the rule can still see once the primitive it replaced is gone.

`RUNNER9` has to tolerate `RUNNER5`. Resolving `runs-on` from a job output *is*
dynamic runner selection, which `RUNNER5` reports as UNDECIDED unless
`--allow-dynamic-runner` is passed. A repository that has adopted this contract
passes it, and `RUNNER9` then supplies the specificity `RUNNER5` gave up: not
merely "an expression", but an expression naming the anchor job's output.

Exemptions are **declared, not inferred**, in the workflow where a reviewer sees
them — the same posture as `--forks=blocked` and `remote-reusable-allowed`. A
release job that must not share a host with a pull request's test stack is a
legitimate exemption; "this one was awkward" is not, and the marker carries the
reason so the difference is legible.

---

## 5. Residual risk, honestly

**Rule 3 is built and unexercised, and nothing in the fleet is currently able to
exercise it.** Every piece of it has shipped — the band, the per-slot DNAT, the
`shared_infra_id`-scoped tag pair, `CI_SHARED_INFRA_*`, and RUNNER11 to keep a
Windows job from reading `localhost`. What has not happened is a Windows job
opening a connection to a Linux host's stack, because **no such job exists**: no
adopting repository has a Windows job that wants a database, which §"Why this is
being written" gives as the reason none was ever written. RUNNER11 is therefore
passing **vacuously** in every repository that has adopted, and a vacuous gate
proves the absence of a subject, not the presence of a working path.

Concretely, the first Windows job to try it is the integration test. Read the
band arithmetic, the DNAT and the two firewall rules as a design that has been
reviewed and not as one that has been observed — and expect the first adopter to
find something, because that is what the first adopter of rules 1 and 2 did.

This is recorded rather than resolved on purpose. Manufacturing a Windows job
solely to prove the path would prove a fixture, and the fixture is the part
least likely to resemble the real one.

**Two workflows on one pull request get two hosts and two stacks.** Job outputs
do not cross runs, so each workflow anchors independently. The mitigation is
organisational, not technical — consolidate `pull_request` CI into one workflow,
which the lane model already wants — and the failure mode is the status quo
rather than a regression: two stacks with distinct compose project names, which
is exactly what happens today.

**A re-run, or a second workflow, brings the stack up twice.** The compose
project name is derived from the pull-request number, so the second stack is a
second complete stack rather than a half-initialised shared one. It costs a band
until the TTL sweep (§3.5) reclaims it.

**Slots on one host can already reach each other, and this document must not be
read as granting that.** `setup_slot_netns` appends `FORWARD -i cis<idx> ACCEPT`
and `FORWARD -o cis<idx> ACCEPT`, so a packet from `10.99.2.2` to `10.99.1.2` is
forwarded today. The daemon sockets are 0700 and unaffected, so this is
network-level reach and not container control — but it is reach that nothing
decided to grant, and it is not the mechanism §3.2 uses. §3.2 goes through a
named port band on the host address precisely so that the sanctioned path is the
one workflows are written against, and so that closing the accidental one later
breaks nothing. **Filed as
[#249](https://github.com/Dima-Spectorr/ci-runner-infra/issues/249); it lands
before or with phase 3, and §3.2's conntrack allow lands with it** — the two are
one change in two files, because the band's same-host path runs through the
forward that #249 closes.

**The reservation is not instant, so a stack can briefly have a co-tenant.**
Between the owner's exit and the controller's next tick, another pull request's
job can be scheduled onto the reserved slot and will share that slot's daemon
for its duration. The reset protects the newcomer's workspace and the hold
protects the stack from the reset, but nothing stops that job from reaching the
daemon socket it legitimately owns. The exposure is bounded by the same rule
that bounds the port band — one repository per pool — and it is the reason a
shared stack must never hold a secret. Shrinking the window means the controller
learning about a hold sooner than its tick, which is a cost this design declines
to pay for a risk this rule already contains.

**A shared stack is a shared mutable object.** Six jobs against one Postgres can
race in ways six private Postgres instances cannot, and the failure looks like
flake. The contract is that suites sharing a stack are schema- or
database-per-suite inside it; that is a per-repository obligation this document
states and no gate can check.

**The port band is reachable by every host in the pool, not only by the pull
request's Windows host.** Tag scoping on the ingress side is the narrowest
control the firewall offers, and the egress side cannot even do that (§3.3) —
distinguishing "this pull request's Windows host" from "another pull request's
Linux host" is not expressible there. The pool already serves one repository
(README, "Isolation rules"), so the exposure is bounded by that rule and not by
this one — which is another way of saying the one-repository-per-pool rule is
load-bearing here in the same way `adr-windows-pool.md` §3A says it is
load-bearing there.

**A pull request is now bounded to `slots_per_host` concurrent slots.** For a
pull request that today briefly gets eight slots because the fleet was quiet,
this is slower. That is the trade being made deliberately: #205's evidence is
that the unbounded case is what produces the 291 s waits and the displaced
required checks, and a predictable four is worth more than an occasional eight.

**The owner's slot is reserved and idle.** For the length of the run, one of
`slots_per_host` accepts no work. The alternatives are a stack that dies when
its owner exits, or one a stranger's job can reach on the recycled slot; both
are worse. It also means a repository whose stack is needed by one job should
not adopt the owner pattern at all — a plain `services:` block on that job is
cheaper and this contract is not for it.

**A reserved slot depends on the release path running.** The agent is stopped by
the controller and started by the sweeper, so a bug or an outage between the two
subtracts a slot from the pool until the TTL fires. The TTL is what bounds it,
and the reserved-slot count belongs on the same demand series as the pin holds
so a leak is visible rather than inferred from capacity that quietly went
missing.

**The anchor serializes the start of a run.** Nothing pinned can begin until the
anchor has landed on a host, so a cold pool pays one boot before any pinned job
starts, where today several jobs would queue in parallel for the same boot. The
anchor is also the owner job, whose work has to happen first anyway, so what is
added is an environment read and not a job's worth of scheduling.

---

## 6. Delivery

Each phase is independently landable and independently useful. Nothing before
phase 5 changes any consuming repository's behaviour.

| # | Phase | Touches | Ships without | Status |
|---|---|---|---|---|
| 1 | This ADR and the published contract | `docs/` | — | [#247](https://github.com/Dima-Spectorr/ci-runner-infra/pull/247) merged; the rest in [#255](https://github.com/Dima-Spectorr/ci-runner-infra/pull/255) |
| 2 | Affinity label at boot + `CI_HOST_LABEL`, both pools; **`collect_demand` recognises it (§2.5)**; **orphaned-pin detection (§2.6)** | `host-startup.sh`, `windows-host-startup.ps1`, `controller-startup.sh`, self-tests | any workflow using it | [#253](https://github.com/Dima-Spectorr/ci-runner-infra/pull/253) for the label; [#256](https://github.com/Dima-Spectorr/ci-runner-infra/pull/256) for §2.5 + §2.6 |
| 3 | Port band, per-slot DNAT, **the conntrack band allow paired with [#249](https://github.com/Dima-Spectorr/ci-runner-infra/issues/249) in one change**, `CI_SHARED_INFRA_*`, **the unprivileged `ci-pin-hold` helper, publishing the hold as a guest attribute, and its `--reserve-slot` record** (refusing a one-slot host), **`slot-reset.sh` sparing a held slot's containers and releasing a hold from a previous boot as orphaned** (root, max-TTL enforced, slot named by `SUDO_UID` and never by an argument), **the job-started hook that renews the hold (§4 of the contract) — the host renews, never the workflow, because a consumer inside a `container:` cannot reach the binary**, sweeper teardown + reset + **stopping a reserved slot's agent (§3.1)** + agent start with **fail-closed retire** when any of the three fails, TTL sweep | `host-startup.sh`, `job-hooks/`, self-tests | any firewall change; **`security-reviewer` on the reset change** | [#258](https://github.com/Dima-Spectorr/ci-runner-infra/pull/258) for the port band, DNAT and `CI_SHARED_INFRA_*`; [#264](https://github.com/Dima-Spectorr/ci-runner-infra/pull/264) for the pin hold, the reservation and the sweeper |
| 4 | Ingress/egress band rules on the new `shared_infra_id`-scoped tag pair — `ci-shared-infra-src-<id>` **on both pools** as the source, `ci-shared-infra-stack-<id>` **on Linux only** as the ingress target (§3.3); pin-hold veto read from guest attributes, **monotonic in the controller's `$STATE_DIR`** so a co-tenant can only extend a hold (§2.4), applied to the `cordon:`/`retire:`/`drain:` verdicts of **both** `recycle_decision` and `drain_decision`, and the same cache read by the §2.6 detector so a Windows-only tail is still covered | `ci-runner-network`, `ci-runner-host-pool`, the Windows pool, `controller-startup.sh`, self-tests | any workflow using it | [#260](https://github.com/Dima-Spectorr/ci-runner-infra/pull/260) merged for the band rules; [#269](https://github.com/Dima-Spectorr/ci-runner-infra/pull/269) for the veto |
| 5 | `RUNNER9`/`RUNNER10`/`RUNNER11` + fixtures | `check-runner-policy.sh`, `docs/ci-workflow-gates.md` | adoption (rules are opt-in by flag) | [#261](https://github.com/Dima-Spectorr/ci-runner-infra/pull/261) merged |
| 6 | Reference anchor/owner job, published as `shared-infra-db` | `docs/ci-pr-shared-infra.md`, `.github/actions/shared-infra-db`, this repo's own workflows | — | [#322](https://github.com/Dima-Spectorr/ci-runner-infra/pull/322) merged; the fallback corrected in [#337](https://github.com/Dima-Spectorr/ci-runner-infra/pull/337) and [#367](https://github.com/Dima-Spectorr/ci-runner-infra/pull/367) |
| 7 | Per-repository adoption, workflow consolidation first | consuming repositories, one pull request each | — | in flight, one pull request per repository; the ledger is [#248](https://github.com/Dima-Spectorr/ci-runner-infra/issues/248) |

Phase 5 lands the rules behind a flag for the same reason `--forks` is a flag: a
gate that fails every repository on the day it merges is a gate that gets
disabled in every repository on the day after.

That is true of `--shared-infra`, which turns `RUNNER9`/`RUNNER10`/`RUNNER11`
**on**, and it is not true of `--allow-dynamic-runner`, which turns `RUNNER5`
**off**. `RUNNER5` is on by default and fires on any expression in `runs-on`, so
an adopting repository must pass the flag in the same pull request that first
resolves `runs-on` from the anchor — step 4 of the contract's adoption order,
not the last step. Deferring it produces the very red gate the deferral is here
to avoid.

---

## 7. Decided

- One **workflow run** occupies one Linux host, and one Windows host only if it
  needs one. Not one slot. "One pull request, one host" follows from
  consolidating a repository's `pull_request` CI into one workflow, which is
  step 2 of adoption.
- Pinning is an affinity label plus an **anchor job**: the run's first fleet job
  is unpinned and publishes the host it landed on. No runner-list API, no token,
  no lease store. A host that predates the contract is a **supported answer**
  that degrades to today's behaviour.
- The controller will not drain **or cordon-for-recycle** a host holding an
  unexpired pin hold. The hold has a named writer (`ci-pin-hold`, invoked by the
  anchor, renewed by the host's job-started hook rather than by a workflow step
  a containerised job could not run) and a named reader (a guest-attribute read
  on the removal path, one round trip per host being removed). The reader is
  **monotonic in the controller's own state**: a guest attribute is writable by
  every job on the VM, so a co-tenant must be able to extend a hold and must not
  be able to shorten one.
- `host-` is a **reserved label prefix**: `runner_labels` refuses it, and the
  classifier reads a `host-*` label the pool itself registers as an ordinary
  label rather than as a pin — otherwise a pool label like `host-large` would
  cancel a schedulable run.
- `collect_demand` must recognise the affinity label before the label ships, and
  a pinned job whose host no longer exists fails its run within a bounded window
  instead of queueing for a day.
- Shared infrastructure is owned by exactly one job — the anchor — published
  into a per-slot port band, DNAT'd on the host address, and reached by everyone
  else at that address. **The owner exits immediately** (its outputs are
  unreadable until it does, so a lingering owner deadlocks its consumers) and
  **the host reserves its slot for the run** — root's reset spares the held
  slot's containers, and the host-side sweeper stops that slot's agent — because
  a released slot is reused by the next job under the same uid and the same
  daemon. One reservation per host: a second run's anchor landing on the same
  host is refused and continues unpinned, rather than the two of them exhausting
  the host's slots and deadlocking on each other. The hold itself is unprivileged; job code gains no new sudo rule.
  Teardown and release are the same host-side act, and a release that cannot
  complete retires the host rather than restarting the agent over a stack it
  failed to remove.
- Adoption requires `slots_per_host >= 2` — a one-slot pool would reserve its
  only agent — and consumer concurrency is `slots_per_host - 1`. A reboot
  releases the hold as orphaned and fails the run, because the stack did not
  survive it either.
- The Windows pool gets no container runtime. This was reconsidered as part of
  this decision and re-affirmed: `adr-windows-pool.md` §4's reasoning is
  unchanged, and rule 3 is satisfied by reachability, not by a runtime. Windows
  jobs are not pinned.
- The firewall gains two narrow rules for the band on a **new pair of tags
  scoped by an explicit `shared_infra_id` — one value per repository, passed to
  both module instances, never derived from a module's own name, which differs
  between the two pools**. `ci-shared-infra-src-<id>` on both pools is the ingress
  source and the egress target; `ci-shared-infra-stack-<id>` on Linux only is
  the ingress target. Egress is scoped by the pool subnet's range because GCP
  egress cannot scope by tag, and `database_egress_ports` is not widened.
  Windows gains no inbound path: the only tag it carries is an ingress source
  and an egress target, and an egress target selects the sending VM.
- The **new** gate rules are opt-in by flag until phase 7 completes. The
  pre-existing `RUNNER5` is not: adoption trips it, and `--allow-dynamic-runner`
  goes in with the first dynamic `runs-on`.
