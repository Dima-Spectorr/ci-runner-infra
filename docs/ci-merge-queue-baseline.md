# The merge-queue baseline — one CI run per pull request, one pull request per batch

**Revised 2026-08-19: a THIRD dimension, which this document had never named.**
Everything below was written about two numbers — `max_parallel_checks` (how many
speculative checks at once) and `batch_size` (how many pull requests share one).
There is a third setting, `merge_queue.mode`, and every repository in the fleet
had it at its default (`serial`) without ever declaring it. It decides whether
the N checks a width of N buys are **a stack or N independent tests**, and it is
the only throughput knob that costs **no runners at all**. Read
[Scheduling mode](#scheduling-mode-the-third-number) before touching either of
the other two. It does not reopen the `batch_size: 1` decision.

The lane model in [`ci-lane-model.md`](ci-lane-model.md) decides *how much* CI a
pull request deserves. This decides *how many times it runs*. They are
independent: a repository can classify lanes perfectly and still pay for every
pull request twice, because the second run is not started by the workflow — it
is started by Mergify.

Adopt this together with the lane model. It is copy-in, not by-tag: the file it
governs (`.mergify.yml`) lives in the consuming repository, so what is published
here is the required shape, the gate that asserts it, and where the gate must
sit.

**Revised 2026-08-18. `batch_size: 1` IN EVERY REPOSITORY, AND THAT IS NOT A
PER-REPOSITORY CHOICE.** One pull request per batch, so no pull request can be
delayed, bisected or dequeued by a failure in somebody else's change. Tier 1
below — batched drafts — is **retired**, not deleted: it is kept in full because
none of its reasoning was found wrong, it was traded away for that isolation,
and a rule whose reasoning is deleted is the one that gets re-derived. **Raising
`batch_size` anywhere is a change to this document first.**

*Revised 2026-08-17, superseded above.* This document used to say one thing —
*one CI run per pull request* — so a repository whose queue had become its
bottleneck could only obey it or leave it. Twelve of the thirteen fleet
repositories were still exactly right to obey it. The thirteenth (IntegrateIT)
found the way out, and the way out was much narrower than "raise something": the
number to raise is `batch_size`, not the one that looks obvious. That remains
true as an argument, and it is the argument to make here if the queue becomes a
bottleneck again. Read
[Two tiers](#two-tiers-and-the-only-way-to-move-between-them) before changing
any value in this file.

---

## What the second run is

Mergify validates a queued pull request in one of two places.

**In place** — on the pull request's own branch, reading the check-runs that
already exist. Nothing new executes. The pull request reports
`speculative_check_pr: null` and "Checks skipped · PR is already up-to-date".

**On a throwaway draft** pushed to `mergify/merge-queue/<sha>` — a real branch,
which fires every `pull_request` workflow in the repository a second time, on
the self-hosted fleet, for every pull request that merges. The pull request
carries `speculative_check_pr: <n>` in its Mergify payload and shows a
`mergify/merge-queue/*` workflow run beside its own. Measured on DataRetrival
#2383 (2026-08-14): the whole suite, twice, per merge.

The queue is not opting into the second run for safety. It falls back to it
whenever the configuration cannot guarantee the first run is still valid.

---

## Two tiers, and the only way to move between them

### Tier 0 — in place. The default, and where every repository belongs.

`max_parallel_checks: 1`, `batch_size: 1`. One CI run per pull request. The five
properties below are its definition. **Do not leave this tier to be faster in
principle.**

Since 2026-08-18 `batch_size: 1` is not the tier's choice to reverse: it holds
account-wide even in the one repository that keeps a width above 1. IntegrateIT
sits at `max_parallel_checks: 4` with `batch_size: 1` — outside Tier 0 on
property 1, inside it on property 2.

**`mode` is orthogonal to the tier.** At width 1 it is inert — there is nothing
concurrent to schedule — so a Tier 0 repository may declare `mode: serial` or say
nothing and be identical either way. It becomes load-bearing the moment the width
rises, and from 2026-08-19 **any repository at a width above 1 must declare
`mode` explicitly**, with the scope map that
[Scheduling mode](#scheduling-mode-the-third-number) requires. Inheriting
`serial` by silence is how the fleet spent a month paying for width and
collecting only pipelining.

### Tier 1 — batched drafts. RETIRED 2026-08-18; kept as the argument, not as an option.

**Nothing may move to this tier without changing the revision note at the top of
this document.** It is recorded because it was right about the shape of the
trade — the knob to raise is `batch_size`, never `max_parallel_checks` — and
that is the reasoning any future queue-bottleneck argument has to start from.
What it was for:

The trigger is one specific, measurable thing, and it is not "CI is slow" or
"there are a lot of PRs":

> A strict queue re-validates its front entry against a main that every merge
> has just moved, so at width 1 the next entry starts a **cold** run after each
> merge. When *merge cadence is slower than one CI run*, the queue — not CI —
> is what pull requests are waiting on.

Measured on IntegrateIT #5293 (2026-07-31): its own CI was green at 15:47, it
entered the queue at 15:49, and by 16:01 two successive queue drafts had each
re-run the whole suite. The pull request was not slow; the queue was serialised
behind its own merges.

If merges keep up with CI, you are in Tier 0 and raising anything buys nothing.

### The knob to raise is `batch_size`. It is not `max_parallel_checks`.

This is the whole point of the tier, and the version of this document that
existed before 2026-08-17 pushed readers the wrong way (see the retracted bullet
under [What a consuming repository must not do](#what-a-consuming-repository-must-not-do)).

|  | pull requests validated at once | concurrent CI runs |
|---|---|---|
| `max_parallel_checks: N` | ×N | **×N** |
| `batch_size: N` | ×N | **×1** |

A batch is validated by **one** draft run whatever its size, so each extra pull
request in a batch rides a run that is already happening. Width buys the same
throughput and bills a full CI run for each step. **Throughput is the product;
the runner bill is the width alone.**

IntegrateIT went 5/1 → 3/`{min: 1, max: 5}` on 2026-08-17: in-flight capacity 5
→ 15 pull requests, peak runner demand ~25 → ~15, second-CI cost per pull
request 1 → as little as 0.2 runs. It got three times the queue capacity while
*returning* runners to the fleet.

**It went back to 3/1 on 2026-08-18** (IntegrateIT #9023), in the account-wide
move to one pull request per batch. The measurement above was never
contradicted; the capacity it bought was given up for isolation. What that
costs, so the next argument starts from the real number: in-flight capacity
15 → 3, second-CI cost 0.2 → 1 run per pull request. The width was **not** raised
back to 5 to compensate — the fleet figure in the next section, not the batch
size, is what bounds it.

### Tier 1's mandatory companion: bound the bisect

Batching's risk is not cost, it is **blame** — a batch fails as a unit. Mergify
answers this by bisecting: it splits a failed batch and re-checks the halves
until a single-PR batch fails, and that one is the culprit. The budget for that
is `batch_max_failure_resolution_attempts`, and **both of its defaults are wrong
for every repository here**:

- unset → `null` → unlimited splits, so one flaky test becomes an unbounded
  chain of draft runs while everything behind it waits;
- `0` → the whole batch is dequeued on the first failure, punishing four pull
  requests for a fifth.

**The invariant is `attempts >= ceil(log2(batch_size.max))`**, per queue rule.
Below it the bisect can end with pull requests still unseparated and all of them
are dequeued for a failure one of them caused. `batch_size: {max: 5}` therefore
requires `attempts: 3`.

Do **not** reach for a second queue or for `scopes` as the isolation mechanism.
`scopes` makes batches more *coherent*; **under `mode: serial` it is a
preference, not isolation**, and Mergify will still batch across scopes when that
is what the ready pool offers.

> **Amended 2026-08-19.** That sentence is true of batching and false of
> scheduling. Under `mode: parallel` the same `scopes` block stops being a
> preference and becomes the thing that decides which entries may run at the same
> time — see [Scheduling mode](#scheduling-mode-the-third-number). Both readings
> are live at once in a `parallel` repository, and they are not in tension: the
> block still only *prefers* coherent batches, and it now *determines*
> concurrency. Do not carry the "preference, not isolation" line over to a
> question about the mode.

A second queue is worse: its routing predicate lives in the condition list,
which Mergify re-evaluates **at merge time against the speculative draft** — a
branch carrying the other entries' files. IntegrateIT #8318 was dequeued twice,
four hours apart, on `-files~=^(apps|packages|tests)/` for files it did not
have.

### The fleet runner budget — the invariant no single repository can see

The self-hosted fleet is **shared**. Each repository's `max_parallel_checks`
spends from the same pool, and a `.mergify.yml` reviewed inside one repository
cannot see the others' claims. So:

> **`Σ over repositories (max_parallel_checks × peak runners per CI run)` must
> stay at or under the runners ONLINE, not under the autoscaler ceiling.**

Online, not the ceiling: the MIG is `OPPORTUNISTIC` and scale-up lags a burst.
On 2026-08-13 the fleet was ten online with nine busy while 42 ready pull
requests competed for it, and four speculative validations were enough to starve
ordinary PR CI into mass cancellation and queue churn. The autoscaler being
allowed to reach 32 did not help, because it had not.

Thirteen repositories at width 1 are a small, roughly constant claim, and one
(IntegrateIT) is at 4. **A width above 1 in a second repository is a fleet-level
change and needs the sum recomputed, in the pull request that makes it.** This
is also the reason Tier 1 preferred batch size: raising `batch_size` does not
appear in that sum at all. Since 2026-08-18 that escape is closed by policy
rather than by arithmetic — `batch_size` is 1 everywhere.

**Corrected 2026-08-19 — "shared" is one pool short of the truth, and it changes
who may raise what.** Runners are registered **per repository**, not into one
GitHub-wide pool. Each repository stands up its own `ci-runner-host-<slug>` pool
from the `ci-runner-host-pool` module in this repository.

**Corrected again 2026-08-20, and this is the correction that matters — the
first survey counted the wrong thing.** It asked GitHub
`GET /repos/{owner}/{repo}/actions/runners` for each repository and read the
registered count. **Every pool in the fleet runs `min_hosts = 0`** — scale to
zero when idle — and a scaled-to-zero pool has *deregistered every runner*, so
that endpoint returns `total_count: 0` for a pool that is fully provisioned and
will have sixteen agents up two minutes into the next push. The survey therefore
reported "eleven repositories have no self-hosted runners" when in fact eleven
repositories *have pools* and were merely idle at the moment they were asked.
Everything the first correction concluded from that zero — that those
repositories run GitHub-hosted, that raising their width is a billing question,
that they cannot starve anything — was **wrong**.

> **Never size a queue against a live runner count.** It measures the weather.
> Size it against `slots_per_host × max_hosts` from the pool's `.tfvars`, which
> is the pool's real job concurrency and is what the module's own `max_hosts`
> description calls it.

Re-derived from Terraform (`slots_per_host × max_hosts`, every pool at
`min_hosts = 0`):

| repository | pool `.tfvars` | slots × hosts | **job ceiling** |
|---|---|---|---|
| IntegrateIT | `customer/mot/terraform/ci-runner-hosts` | 4 × 8 | **32** |
| entity-platform | `infra/ci-runners` | 4 × 6 | 24 |
| Print-Server | `infra/terraform/ci-runners` | 4 × 6 | 24 |
| Specaria-Platform | `infra/terraform/ci-runners` | 4 × 4 | 16 |
| DataRetrival | `infra/terraform/ci-runners` | 4 × 3 | 12 |
| SOAP-To-REST | `infra/terraform/envs/specaria-soap-to-rest-deploy` | 4 × 3 | 12 |
| Apigee-Portal | `infra/terraform/envs/specaria-apigee-portal-deploy` | 4 × 3 | 12 |
| Telnet-Emulation | `infra/terraform/ci-runners` | 4 × 2 | 8 |
| mot-claude | `infra/terraform/ci-runners` | 4 × 2 | 8 |
| Borsh-Tablet-App | `infra/ci-runners` | 2 × 3 | 6 |
| ci-runner-infra | *(none — GitHub-hosted)* | — | — |
| Manar | **none, and its CI demands `self-hosted`** | — | see below |
| Atlas | **none, and its CI demands `self-hosted`** | — | see below |

The `29 / 28 / 22` figures in the first correction were not false, only
incidental: IntegrateIT's ceiling is 32 and seven of its eight hosts happened to
be up when it was sampled.

So the sum above is not a single global constraint. It decomposes:

- **A repository with its own pool** spends only its own ceiling. The budget is
  real, local, and computable — width × peak runners per CI run against
  `slots_per_host × max_hosts`. What *is* still shared underneath is the GCP
  quota the managed instance groups draw from, which is what actually bit on
  2026-08-13; that is a slower, coarser bound than a runner count.
- **A width raise is bounded by that number and nothing else** — not by a
  neighbouring repository, and not by a live count taken while the pool was
  asleep.

**Manar and Atlas are the genuine defect this survey found.** Both name
`runs-on: [self-hosted, linux, gcp, <Repo>]` in `.github/workflows/ci.yml`, and
neither instantiates `ci-runner-host-pool` anywhere. There is no pool to scale
up, so those jobs are not slow — they are **unassignable**. They queue with no
runner, never start, and therefore never reach a conclusion, which is
indistinguishable at the pull-request level from a check that is simply taking a
long time. This is the actual root cause of Manar pull request #25 sitting
`BLOCKED` for two days with twenty-seven contexts showing an empty conclusion;
an earlier reading of the same symptom blamed path filters, and that reading was
wrong. **A `runs-on` label with no pool behind it is a silent, permanent block,
and nothing in GitHub's UI names it.**

The rule that survives: **state which ceiling you are spending, and show the
`slots_per_host × max_hosts` arithmetic, in the pull request that raises the
width.** What no longer holds is the blanket claim that a repository under queue
pressure has no local move — since 2026-08-19 it has one, and it is free:
declare `mode: parallel` with a covering scope map before arguing for runners.

---

## Scheduling mode: the third number

`merge_queue.mode` is a **top-level** key, alongside `max_parallel_checks`, with
three values. Left undeclared it is `serial`, which is where every repository in
this fleet sat until 2026-08-19 — not by decision, by omission.

| mode | scopes needed | batches depend on each other | safety |
|---|---|---|---|
| `serial` | no | **always** — every entry is tested on top of the one before it | highest |
| `parallel` | **yes** | only when their scopes overlap | high |
| `isolated` | no | **never** | **too low — do not use** |

### What `serial` actually costs at a width above 1

This is the part the document got wrong by omission: it treated
`max_parallel_checks: N` as "N pull requests validated at once", which is true,
and left the reader to assume those N are independent, which is **not**. Under
`serial` they are a **stack**: draft 2 carries entry 1's commits, draft 3 carries
1 and 2. A dequeue at the front invalidates everything behind it, and those runs
restart **cold**. Width buys pipelining; it does not buy independence.

That is also why the "the queue was serialised behind its own merges" measurement
(IntegrateIT #5293, 2026-07-31) was only half-fixed by raising the width. Raising
it made the next entry *already running*; it did not stop that entry being thrown
away when the one in front of it failed.

### Why `parallel` is free, and what it is not

`max_parallel_checks` remains the **global ceiling** on concurrent speculative
checks. Parallel mode adds **not one draft** and therefore **not one runner**. It
changes only which entries may hold those slots at the same time, and whether one
entry's failure poisons the others. It does not appear in the fleet runner-budget
sum below, in exactly the way `batch_size` does not.

So the guidance in [the knob to raise](#the-knob-to-raise-is-batch_size-it-is-not-max_parallel_checks)
gains a term. The order to reach for throughput is now:

1. **`mode: parallel` + a covering scope map** — free, and does not touch the
   account-wide `batch_size: 1` decision.
2. `batch_size` — free in runners, **closed by policy** since 2026-08-18.
3. `max_parallel_checks` — the only one that bills runners. Last resort, and a
   fleet-level change.

`mode` and `batch_size` are not alternatives; they answer different questions and
compose:

- `batch_size` — may two pull requests share **one test run**? No (account-wide).
- `mode` — may two pull requests be tested **at the same time, in separate
  runs**? Yes, when their scopes do not overlap.

### `isolated` is banned

It removes the dependency between batches **entirely**, scopes or not, so two
entries that pass alone and conflict together both merge and break the base
branch. That is the one property a merge queue exists to provide. It is not a
"faster tier" — it is the absence of the queue's purpose, and it must be rejected
by a gate rather than by a reviewer noticing a one-word diff.

### Parallel mode's mandatory companion: total scope coverage

**This is the part that makes `mode: parallel` a correctness change rather than a
tuning change, and it points the opposite way from intuition.**

In parallel mode Mergify groups entries by their **exact set of scopes**. A pull
request whose files match no scope carries the **empty set**. An empty set
overlaps nothing — so that pull request runs concurrently with *every* other
entry in the queue.

> **Unscoped is the MOST parallel state a pull request can be in, not the safest
> one.** Partial coverage is not partial safety; it is full parallelism over the
> part you did not describe.

Nothing in Mergify reports this. The queue stays green, the dashboard shows the
scopes that were declared, and the uncovered part of the repository quietly stops
being serialised against anything.

Found on IntegrateIT 2026-08-19, in a scope block that had been in the repository
since 2026-08-17: **21 of 34 directories under `apps/` and 62 of 68 under
`packages/` matched no scope.** The block was correct as what it was written to
be — a *batching preference*, where partial coverage is merely a partial
optimisation — and wrong the moment the mode changed underneath it.

`scripts/ci/check-mergify-scopes.sh` (published here, copy it in, same filename)
is the gate. It asserts, from a real YAML parse plus the workspace manifest:

1. `mode` is `serial` or `parallel`, never `isolated`;
2. `parallel` declares scopes at all — with none, every entry carries the empty
   set and `parallel` degrades to `isolated` **by omission**;
3. `parallel` declares `barrier_files`;
4. **every workspace package is named by a scope or by a barrier** — the check
   above, and it is deliberately inert under `serial` so it does not block a
   repository that has not migrated;
5. no scope capacity exceeds `max_parallel_checks` (a capacity is a sub-limit
   inside the global width, so a larger number reads like a raise and does
   nothing);
6. no capacity names a scope that does not exist (silently ignored, and that
   scope then runs at the full width);
7. `merge_queue_scope` does not collide with a declared scope.

It matches **paths, not key names**, and its glob translation is deliberately not
`fnmatch.translate`: `*` must not cross `/`, or `packages/*` would report
`packages/connectors/aws-sqs` as covered by a pattern Mergify does not match it
with — every coverage answer wrong in the permissive direction. A fixture pins
that.

### Wide fan-out is a barrier, not a scope

A scope **asserts independence**. A package that most of the repository imports is
independent of nothing, and giving it a scope of its own states the opposite.
Run `check-mergify-scopes.sh --fanout` and read the transitive-dependent counts;
in practice there is a cliff, and the packages above it are barriers. On
IntegrateIT (294 packages): 84%, 82%, 74%, 70% — then nothing until 7%.

`barrier_files` must also carry two categories the dependency graph **cannot
see**, so they are enumerated by hand:

- **build and toolchain configuration** — the lockfile, the workspace manifest,
  the root `tsconfig`, the task runner config, the shared test config. Nothing
  depends on them and they change how everything compiles;
- **the gate machinery** — `.github/workflows/**`, `.github/actions/**`, the
  repo-gate scripts, the shared test package, and `.mergify.yml` itself. A change
  here alters what *green means* for every entry in flight, so it must not be
  validated alongside entries still being judged by the old definition.

### A scope that is most of the repository is not a scope

If one scope holds the majority of the packages, parallel mode buys close to
nothing: most entries share it and chain anyway. Split it. Where the members are
genuine leaves that do not import each other, an **arbitrary** split is legitimate
and should be labelled as arbitrary — IntegrateIT splits 189 connector packages
into five alphabetical buckets precisely because no semantic grouping survives
contact with the next connector. Cap the result with `scopes.default_capacity` so
one busy area cannot hold every slot.

---

## The five properties (Tier 0)

In-place checking requires ALL of these. Break any one and the queue silently
moves to the throwaway draft — merges keep working, only the runner bill
changes. A Tier 1 repository deliberately gives up 1 and 2 and **still owes 3,
4 and 5**: those are about gates that must not disagree, which is a correctness
property at any width.

1. **`merge_queue.max_parallel_checks: 1`, as a TOP-LEVEL key.** Inside a queue
   rule it is not ignored — Mergify rejects the whole file with
   `Extra inputs are not permitted @ root → queue_rules → item 0 →
   max_parallel_checks` and the queue then fails **closed**: every pull request
   sits unmergeable behind a red check whose reason is a config error rather
   than anything about the branch. Found in that state in one fleet repository
   (Atlas, fixed in its #1945); the file had looked correct for months.
2. **`batch_size: 1` in every queue rule.** A batch has to be assembled
   somewhere, and that somewhere is a branch. `batch_size` also accepts a
   `{min, max}` mapping (dynamic batching), which counts as 1 only when both
   bounds are 1 — a gate that understands only the integer form silently
   accepts an unbounded range.
3. **No `max_checks_retries`.** Retrying a check needs a branch to retry it ON.
4. **Single-step CI** — Mergify's schema defines this as `merge_conditions`
   being EMPTY or IDENTICAL to `queue_conditions`.
5. **Something must still put a green pull request into the queue without a
   human** — `merge_protections_settings.auto_merge_conditions`.

Property 5 is not part of in-place checking; it is the half that gets dropped
while fixing properties 1–4, and its failure mode is worse than double CI.
With no queue action and no `auto_merge_conditions`, nothing auto-queues:
Mergify posts a "tick the box to queue" comment and waits, so pull requests sit
green and unmerged with **no red check anywhere** to say why. That shipped once
(DataRetrival #2378, fixed in #2384), which is why the gate asserts 5 as a pair
with the queue-action ban.

Property 5 has three spellings that satisfy the key and not the behaviour, so
the gate rejects each of them: `auto_merge_conditions` present but **empty or
null** (nothing matches an empty list), `autoqueue: false` on a queue rule
(present, disabled), and an `auto_merge_conditions` whose `base = X` names a
branch **no queue rule admits** — pull requests are then queued into a rule that
cannot take them, or matched by nothing at all. The base is compared against the
rules rather than against a literal, so `main` and `master` repositories share
one gate.

Alongside them the gate asserts what the condition list must still **contain**:
every queue rule needs `queue_conditions` naming at least one `check-*`
condition. Since `merge_conditions` is empty or identical by construction, that
list is the only thing standing between a pull request and a merge — a rule that
lost its checks admits on base/draft state alone and merges before CI has
succeeded. Skip-aware requirements written as `or: [check-success = X,
check-skipped = X]` satisfy it: the check is looked for anywhere in the
condition subtree, not only at its top level.

---

## Identity is spelled as an anchor, not as two equal lists

```yaml
queue_conditions: &gate
  - base = main
  - -draft
  - check-success = "CI summary (rollup)"
merge_conditions: *gate
```

Two separately written lists that agree today drift the next time a required
check is added to one of them, and the drift is invisible: no error, no dequeue,
every pull request merely pays a second full pass. The anchor makes them the
same YAML node, so drift is impossible rather than unlikely. The gate therefore
asserts **node identity**, per rule — the two keys resolving to the same object
after the parser expands aliases, which is what Mergify's schema means by
"identical". A value comparison passes the exact file that is about to regress,
and a text search for `&`/`*` passes a rule that aliases *another* rule's anchor.

A `pull_request_rules` queue action is the same failure in another spelling: its
`conditions:` are a third list, different by construction since it must carry
`base`/`-draft`. Queue via `auto_merge_conditions` instead. Non-queue
`pull_request_rules` entries — labels, comments, branch cleanup — are unaffected
and should stay.

`auto_merge_conditions` carries only the base/draft/label facts. It must **not**
restate the required checks: those live once, in the anchored list, which is
what decides when a queued pull request embarks.

---

## The reference configuration (Tier 0)

```yaml
merge_queue:
  max_parallel_checks: 1
  # Inert at width 1 and therefore optional here — but write it. It is the one
  # setting the whole fleet held by silence rather than by decision, and the
  # next person to raise the width should have to edit a line that exists.
  # `isolated` is banned outright; the gate rejects it.
  mode: serial

queue_rules:
  - name: default
    queue_conditions: &gate
      - base = main
      - -draft
      - check-success = "<the required context>"
    merge_conditions: *gate
    merge_method: squash
    batch_size: 1
    # Pin it. Unset, it inherits an undeclared vendor default of roughly 42
    # minutes, so a hung job surfaces as a silent dequeue rather than a red
    # check. Keep the ordering invariant of the lane model:
    #   per-workspace timeout < job timeout-minutes < checks_timeout
    checks_timeout: 30 min

merge_protections_settings:
  reporting_method: check-runs
  auto_merge_conditions:
    - base = main
    - -draft
```

### …and the Tier 1 delta — RETIRED, do not apply

Kept as the record of what the delta *was*. Since 2026-08-18 no repository may
carry it without changing the revision note at the top of this document first.
Only the two values changed, and only together with the third:

```yaml
merge_queue:
  # A FLEET-LEVEL number. Recompute the runner budget in the PR that moves it.
  # Reaching for throughput? Raise batch_size instead — it is not in that sum.
  max_parallel_checks: 3

queue_rules:
  - name: default
    # ... everything above is unchanged ...
    batch_size:
      min: 1          # a light queue keeps single-PR latency
      max: 5
    # ceil(log2(max)). Unset means unlimited bisect splits; 0 dequeues the whole
    # batch on first failure. Raise this WITH batch_size.max, never after.
    batch_max_failure_resolution_attempts: 3
```

### The width-above-1 delta — the one that IS current (2026-08-19)

This replaces the retired Tier 1 delta as the only sanctioned way to be faster
than Tier 0. It leaves `batch_size: 1` untouched and adds **no runners**.

```yaml
# TOP-LEVEL, a sibling of merge_queue and queue_rules — not nested under either.
scopes:
  # Mergify's own draft branches. Must not collide with a scope name below, or
  # every draft joins that scope and chains against it.
  merge_queue_scope: merge-queue

  # Impacts every scope: never batched with others, never run beside another
  # batch. Three categories, and the last two are invisible to a dependency
  # graph, so enumerate them by hand.
  barrier_files:
    include:
      - <packages above the fan-out cliff — see `--fanout`>
      - package.json
      - <lockfile>
      - <workspace manifest, root tsconfig, task-runner and shared test config>
      - .github/workflows/**
      - .github/actions/**
      - .mergify.yml
      - scripts/**
      - tests/**

  # A sub-limit INSIDE max_parallel_checks, so it must never exceed it. Stops
  # one busy area holding every slot.
  default_capacity: 2

  source:
    files:
      <area>: [<paths>]
      # ... every workspace package must match one of these or a barrier.
      # An unmatched PR carries the EMPTY scope set, which overlaps nothing and
      # therefore runs beside EVERYTHING. Partial coverage is not partial
      # safety. check-mergify-scopes.sh enforces totality.

merge_queue:
  # A per-repository number now, not a blanket fleet one: show the arithmetic
  # against this repository's own `slots_per_host * max_hosts` in the PR. Never
  # against a live runner count — every pool scales to zero, so a count taken
  # while the pool is idle reads 0 for a fully provisioned pool.
  max_parallel_checks: 4
  # Load-bearing above width 1. `serial` makes those 4 a stack; `parallel` makes
  # them 4 independent tests grouped by exact scope set.
  mode: parallel

queue_rules:
  - name: default
    # ... unchanged, and batch_size STAYS 1 ...
    batch_size: 1
    # Harmless at batch_size 1 (ceil(log2(1)) = 0), kept so that raising the
    # batch size can never land without its companion already present.
    batch_max_failure_resolution_attempts: 3
```

The condition list mirrors the branch ruleset's required checks **exactly**, and
each of them must be an always-completing context — the aggregate job of the
lane model, which reports `success` when its area was untouched. A check that
*skips* leaves the queue waiting for a conclusion that never comes.

---

## Where the gate goes

`scripts/ci/check-merge-queue-single-step.sh` (published here; copy it in, same
filename, so a diff against this copy is a one-liner) asserts all five
properties plus the queue-action ban. A repository that already asserts them in
its own suite keeps that instead of carrying both — DataRetrival does, in
`Modernization/scripts/ci-gates.test.mjs` (tightened in its #2387 to node
identity, non-empty `auto_merge_conditions`, and a base the queue rules admit).
What is not optional is that something asserts them somewhere the required check
reaches. Two rules about where it runs:

- **An always-on job.** A `.mergify.yml` regression touches no service, so a
  path-filtered or draft-gated job never sees the change the gate exists to
  catch. In practice this is the lane classifier / `changes` job — the one job
  with no `if:` and no path filter. Where that job is itself gated on a
  full-run flag (Atlas), its checkout step is made unconditional so the gate
  still runs.
- **Covered by a required check.** The hosting job's failure must reach the
  required context, directly or through the aggregate's `needs:`.

Run `--selftest` immediately before the real invocation:

```yaml
      - name: Merge-queue single-step gate self-test
        run: bash scripts/ci/check-merge-queue-single-step.sh --selftest

      - name: Merge-queue single-step gate
        run: bash scripts/ci/check-merge-queue-single-step.sh
```

The self-test plants a fixture per detector and asserts, for each one, the **set
of check ids** it raises — not how many diagnostics appeared. A count-only assertion is
itself a vacuous test: delete the queue-action detector and the fixture that
exists to prove it stays green, because a different check emits one error
instead. And a vacuous pass is this gate's characteristic failure — it reads a
file it never matches and reports clean.

The fixtures include a commented-out queue action (must satisfy neither the ban
nor the something-queues check), a two-rule file with one rule unanchored (a
whole-file "an anchor exists" test passes it), and one fixture per spelling that
only a parser resolves: an inline `queue: {name: default}`, a quoted
`"max_checks_retries"`, a `max_checks_retries` spliced in through a `<<` merge
key, an `auto_merge_conditions` reached through an alias, a duplicate key, and a
document that does not load. Two more cover documents that are legal YAML and
still not addressable: a top-level key literally named
`merge_queue.max_parallel_checks` (which would read here exactly like the nested
mapping, while Mergify sees an unknown key and refuses the file), and a
recursive alias (which walked naively dies *after* printing every record the
checks read).

The count is deliberately not written down anywhere: the self-test prints its
own, and a number repeated in prose is a second source of truth that goes stale
the next time a detector gains a fixture.

### It parses the file, and then matches paths, not key names

Every assertion names an exact YAML path — `merge_queue.max_parallel_checks`,
`queue_rules[1].batch_size` — never a key found somewhere in the text. The
distinction is the gate: a key written one level too deep is not a value in an
odd spot, it is a **file Mergify refuses to load**, and a keyword scan finds the
value it was hoping for and reports in-place checking over a repository where
nothing queues at all. The same shape recurs four ways, and each has a fixture:

| written as | keyword scan says | actually |
|---|---|---|
| `max_parallel_checks` inside a queue rule | serial checking | file rejected, no rule loads |
| `auto_merge_conditions` inside a queue rule | green PRs auto-queue | unknown key; nothing queues |
| rule B omits `batch_size` while rule A declares `1` | unbatched | rule B batches on a throwaway branch |
| rule B aliases rule A's anchor (`&low` / `*low`) | anchors and aliases balance | rule B's two lists are different nodes |

The paths come from a **real YAML parser** (`python3` + PyYAML, which the runner
image is expected to carry — the gate installs nothing, because a required check
that pip-installs an unpinned package puts every merge in every consuming
repository behind PyPI, on hosts holding a service identity), and that is not an
optimization — it is
what makes the table above true. Reading the text structurally gets every row
wrong in the same direction, the safe-looking one:

- `queue: {name: default}` and `actions: {queue: …}` are the banned action, in
  flow style. A line-oriented reader sees a scalar and reports clean.
- `"max_checks_retries": 2` is the key, quoted.
- `<<: *shared` splices keys into a rule from somewhere else in the file
  entirely.
- an alias is not a copy of a list, it is the SAME list — which is exactly the
  distinction property 4 is about.
- a mapping that declares the same key twice has one effective value, and it is
  not the first one.

So the parser is a **hard dependency**: without it the gate fails rather than
degrading to a structural scan. A gate that reports PASS over a file Mergify
cannot load is worse than no gate, and CHECK 0 also fails the run outright on a
load error — an unterminated flow sequence three keys away leaves every other
invariant matching while Mergify loads nothing at all.

One thing is still read from the text: nothing else can be. The parser resolves
aliases, so by the time the document exists the anchor names are gone — node
identity is asserted on the constructed objects instead, which is the stronger
statement anyway.

### And the conditions are read as a tree, not as a list of strings

A Mergify condition list is a **conjunction**, and `or:` / `and:` / `not:` are
structure inside it. Flattening it to the scalars underneath — which is what
"find a `base = …` anywhere below this path" does — gets two readings wrong, in
opposite directions and both silently:

| written as | flattened reading | actually |
|---|---|---|
| `or: [base = main, base = develop]` | two ANDed bases; impossible list | the ordinary way to serve two branches |
| `or: [-draft, check-success = ci]` | the rule gates on CI | a non-draft PR takes the other branch and merges ungated |

The first is a **false failure**, and a gate that fails a correct configuration
teaches its next reader that the gate can be deleted. The second is the
dangerous direction: it reports a queue gated on CI over one that is not.

So the base constraint is computed as an **admissible set with a complement** on
the tree — `("in", {…})` for the branches a condition names, `("out", {…})` for
`base != x`, intersection across ANDed items and union across `or:` branches —
and the check requirement is "**every satisfiable conjunctive term** names a
`check-success`/`check-neutral`/`check-skipped`". The tree is expanded to those
terms rather than reduced branch by branch, because two disjunctions can imply a
check *jointly*: `(base = main or check) and (base = develop or check)` requires
it on every satisfiable path, since no pull request targets two branches, while
neither `or:` requires it alone. Terms that contradict themselves — two distinct
bases, or both `draft` and `-draft` — are discarded before the question is asked.
That keeps the skip-aware form the fleet actually uses
(`or: [check-success = X, check-skipped = X]`) passing.

Both sides of the comparison are then sets, so the ways a queue can admit
nothing are one question rather than several spellings: an **empty** admissible
set, an admission base **no rule admits**, or an admission list and a rule set
that are simply **disjoint** — which is where `base != main` against a rule
serving only `main`, and a rule whose own bases are ANDed together, both land.
`base ~=` names a set that cannot be enumerated, but it is still a **predicate**,
and it is kept as one: applied to the branches the other side does enumerate it
decides the question — `base = develop` ANDed with `base ~= ^release/` admits
nothing, and a rule serving `^release/` does not stand in for the missing `main`
rule. Only where there is nothing to apply it to, a regex against a complement
(`base != main`), does the comparison decline rather than guess.

An admission list can also queue nothing while every base it names is served, by
contradicting **itself** on every path: `base = main` beside both `draft` and
`-draft` leaves a non-empty base set and no satisfiable term, and each condition
read alone looks fine. That is the same finding as an empty set, and reported as
one.

Whether a term contradicts itself is answered by the **same set algebra**, not by
counting `base =` clauses: `base = main` beside `base != main`, or beside
`base ~= ^release/`, admits nothing though neither pair is two positive
equalities. This matters in both directions — a dead term left alive is compared
against rules on behalf of pull requests that cannot exist (a `-draft` rule
reported as deadlocked against an impossible `draft` path), and a live term
wrongly dropped takes a real requirement with it.

`not:` is **inverted, not declined**. Negation pushes down to the leaves by De
Morgan, and a leaf inverts with the same leading `-` Mergify itself uses, so
`not: {base = main}` is the complement of `main` rather than an unreadable
subtree. Read as unreadable it was previously called *unconstrained*, which is an
assertion that the rule serves every branch: a rule serving everything except
`main` then overlapped an admission list of exactly `main`, and a queue that
could take nothing passed. An unknown connective still declines — but it now
declines rather than claiming the universe.

Draft polarity is read the same way — **per satisfiable term**, not once for the
whole tree. An admission list spelled `(base = main and draft) or (base = main
and -draft)` pins no polarity as a whole, so a single question answers
"unpinned" and says nothing, while its `draft` branch is deadlocked against a
`-draft` rule exactly as if it had been written alone. Each term carries its own
base set, and only rules whose admissible base overlaps that set are compared.

What the reader **cannot** read, it does not assert: an expansion past the term
budget, or a tree nested past the read depth. The first answers
"requirement satisfied" — silence rather than a finding, because the alternative
is failing a configuration the gate merely could not parse. Depth is the
exception and fails closed: a `check-success` under 65 nested `and:` nodes is
really in the file, so a reader that stopped before reaching it says so.

Conditions are also split on the **attribute**, never matched as a substring:
`label != check-success-waived` names a label and restates no check, while
`check-success != X` and `-check-success = X` are restated checks whose operator
an anchored `[=:~]` character class does not match.

Three failures around the parse rather than in it, each with a fixture:

- **The interpreter is chosen, not assumed.** `actions/setup-python` prepends a
  Python that does not carry the image's `python3-yaml`, so a workflow that sets
  up Python for an unrelated step turns this gate into "no YAML parser
  available" on a runner that has one. The gate takes the first interpreter that
  can actually `import yaml`.
- **A key one or two edits from a guarded one is a finding.** `merge_conditons:
  *gate` leaves `merge_conditions` *absent*, which is one of the two spellings
  the identity check accepts — while Mergify refuses the file on the unknown key
  and nothing queues at all. The test is a near miss, not a schema: rejecting
  every unlisted key would fail configurations that use Mergify keys this gate
  has never heard of. Both this test and its mirror image below are asked **only
  at the schema positions Mergify defines** — the top level, `merge_queue`, a
  `queue_rules` entry, `merge_protections_settings`. A key two edits from
  `merge_queue` inside some unrelated mapping is a misspelling of nothing,
  because the correctly spelled key would mean nothing there either.
- **A guarded key spelled correctly, in a position Mergify refuses, is the same
  finding.** A top-level `merge_conditions: []` or `batch_size: 1` is not the
  queue rule's setting "declared globally": the file is rejected on the unknown
  top-level key, and every reader here — each of which asserts on an exact path —
  sees the key as merely absent.
- **A condition list must be a sequence.** An alias pointing at a scalar anchor
  loads as a one-condition tree that reads like an ordinary, well-gated rule,
  while Mergify refuses the file on the type and nothing queues.
- **`check-skipped` alone is not a gate.** It says the check did not run, so
  every path through such a rule is satisfied by a workflow that never reported.
  It is safe only beside the success form (`or: [check-success = X,
  check-skipped = X]`), which is how a path-filtered workflow is admitted — so
  the question asked is whether the rule names a success *anywhere*, not what any
  single branch holds.
- **Traversal is budgeted.** The cycle guard stops a recursive alias, not an
  acyclic one: aliases that reference each other double the traversal per level,
  so a sub-kilobyte file expands past any timeout the job is given — and a gate
  that runs out of time reads as infrastructure flakiness rather than as a
  finding.

### The second gate: `check-mergify-scopes.sh` (2026-08-19)

The single-step gate above reads `.mergify.yml` alone, and scope coverage is not
a property of that file — it is a property of the file **against the repository's
package layout**. That needs a second script, published here on the same terms
(copy it in, same filename, same `--selftest`-then-real pairing, same always-on
job).

```yaml
      - name: Mergify scope-coverage gate self-test
        run: bash scripts/ci/check-mergify-scopes.sh --selftest

      - name: Mergify scope-coverage gate
        run: bash scripts/ci/check-mergify-scopes.sh
```

Its seven checks are listed under
[Scheduling mode](#scheduling-mode-the-third-number). Four things about how it
behaves that a consuming repository needs to know before copying it in:

- **It is inert under `mode: serial`.** Coverage is only enforced where coverage
  decides concurrency. A Tier 0 repository can carry the gate from day one and it
  will pass, which is the point — it is in place *before* the width rises, not
  added in the same pull request that makes it matter.
- **Its inventory is now six discoveries, and PARTIAL discovery is the failure
  to fear** (revised 2026-08-21). The original text here warned about a *vacuous*
  pass — pnpm-only inventory finding nothing at all. `CHECK 8
  discovery-non-vacuous` closed that: it fails when the walk finds zero units but
  a manifest exists anywhere. What it does **not** catch is the halfway case, and
  that turned out to be the common one — discovery that sees *some* of a tree
  reports OK over the rest, and CHECK 8 stays quiet because it did find
  something.

  Six blind spots were found in three days, each looking exactly like a pass:

  | found | blind spot | what it silently approved |
  |---|---|---|
  | 2026-08-19 | pnpm workspaces only | every Go multi-module repository |
  | 2026-08-20 | no Go module walk | — |
  | 2026-08-21 | no Maven reactor walk | seven Java services, most of one tree |
  | 2026-08-21 | no Gradle build-file walk | a whole Android repository, both halves blind |
  | 2026-08-21 | `requirements.txt` matched exactly | `requirements-gpu.txt`, i.e. a Python service |
  | 2026-08-21 | no Dockerfile walk | three deployed containers with no other manifest |
  | 2026-08-21 | Gradle read only build files | a subproject `settings.gradle` includes but the root build configures |

  Discovery now walks, in order: pnpm workspace packages → `go.mod` → `pom.xml` →
  `build.gradle[.kts]` → Python manifests (`pyproject.toml`, `setup.py`,
  `Pipfile`, any `requirements*.txt`) → **Dockerfiles**. The Dockerfile walk runs
  **last**, via `setdefault`, so a directory a real toolchain already claimed
  keeps that kind; it is a language-agnostic backstop, not a competing answer,
  and it earns its place because on this fleet the OCI image is the deployable
  unit by policy.

  Gradle is read from **both** sides: the build-file walk, and the `include`
  declarations of `settings.gradle[.kts]`. A subproject is a module because the
  settings file declares it, not because it happens to hold a `build.gradle` —
  one configured entirely from the root build has none, and a sibling that does
  keeps CHECK 8 quiet about it. The declarations are matched **across lines**,
  because the ordinary Kotlin form is `include(` with one project per following
  line, and a reader anchored to the `include` line finds nothing there. A
  settings file that exists but cannot be read **fails the build**
  (`CHECK 11 gradle-settings-readable`): "unreadable" yields the same empty
  answer as "no subprojects", which is the whole failure family in one line.

  A **root** manifest is never a unit — a root `go.mod`, root `pom.xml` or root
  `requirements.txt` is not an area, it is what every area is part of, so it
  belongs in the barrier. **The vacuity check follows the same rule** (fixed
  2026-08-21): counting a root manifest there while discovery refuses to made an
  ordinary single-package repository — one root `pom.xml`, one root Dockerfile —
  fail CHECK 8 with a correct catch-all barrier in place and no way to satisfy
  the message. Unsatisfiable red is how a real detector gets weakened to quieten
  it. What the root actually requires is asserted positively instead, in two
  checks that are deliberately separate:

  - **CHECK 9 `root-build-barriered`** — the root manifests (`pom.xml`,
    `go.mod`, `package.json`, `pnpm-workspace.yaml`, `settings.gradle[.kts]`,
    root `build.gradle`) must be **barriered**, in every repository, not only
    root-only ones. A root manifest belongs to no area, so unbarriered it
    carries the empty scope set and is tested beside the very builds it just
    changed. Conditioning this on "no sub-units" — the first version did —
    switched it off precisely in the multi-module repositories where it matters.
  - **CHECK 10 `root-build-covered`** — in a root-only build, barriering the
    manifest is *not* coverage. `src/Main.java` is still unscoped, and source
    changes are what most pull requests carry. So there, and only there, the
    sweep is over **files**: a root-only build is small by definition, and a
    sampled answer would be the partial coverage this gate exists to refuse.

  Two consequences for anyone extending this:

  1. **Fixtures in both directions, per language.** A covered fixture and an
     uncovered one. The uncovered one is the only thing that proves discovery
     actually ran, since a covered fixture passes just as happily when nothing
     was found.
  2. **Measure a discovery change against every configured repository before
     committing it.** The Python + Dockerfile change was run against all eleven:
     no repository regressed, and unit counts rose materially (Specaria-Platform
     6 → 59, entity-platform 4 → 10, Print-Server 38 → 44, IntegrateIT 301 →
     310). Every newly discovered unit was already covered by its catch-all
     barrier — which is exactly what a catch-all is for, and why the fail-safe
     barrier shape must land *before* discovery is widened. The Gradle-settings
     + root-manifest change was measured the same way: all eleven repositories,
     every unit count byte-identical, no repository regressed.
  3. **A fixture that cannot fail is not a fixture.** Two of the originals could
     not: the generated `target/classes/pom.xml` sat inside the same scope as
     the real module, so deleting the `target` exclusion left it green, and the
     flavoured-requirements probe shared a directory with a Dockerfile that
     produced the same unit either way. Both were re-placed where only the
     behaviour under test decides the outcome, and each detector is now
     mutation-checked — break it, watch the named fixture go red.
- **`*` does not cross `/`; `**` does.** `fnmatch.translate` gets this wrong, and
  wrong permissively — `packages/*` would report `packages/connectors/aws-sqs` as
  covered by a pattern Mergify never matches it with. A fixture pins the
  distinction.
- **Self-test fixtures assert the set of check ids**, not a diagnostic count, for
  the same reason the single-step gate's do.

Run `--fanout` when authoring or revising the barrier list. It prints transitive
dependent counts per package, which is what turns "which packages are barriers"
from a judgement call into a reading of a cliff.

---

## What a consuming repository must not do

- **Do not remove the queue action without adding `auto_merge_conditions`.**
  The two halves land in one commit or not at all.
- **Do not put `max_parallel_checks` inside a queue rule.** It rejects the file
  and the queue fails closed.
- **Do not declare an invariant once and assume it covers every queue rule.**
  `batch_size` and the anchor are per rule; a second rule that omits either is a
  second place to lose in-place checking.
- **Do not write `merge_conditions` out as a second list**, however carefully it
  matches today.
- **Do not restate `check-success` conditions in `auto_merge_conditions`.**
- **Do not host the gate in a path-filtered job.** It is the one gate whose
  subject matter guarantees the filter excludes it.
- **Do not set `batch_size` above 1 at all** — one pull request per batch is an
  account-wide decision (2026-08-18), so raising it is a change to the revision
  note at the top of this document, not to a repository's `.mergify.yml`.
- **And if it is ever raised, never without
  `batch_max_failure_resolution_attempts >= ceil(log2(max))`.** The bisect
  otherwise ends with pull requests unseparated and dequeues ones that did not
  fail. This is the shape found live in Manar on 2026-08-17: `batch_size: 5`, no
  attempt bound, and `max_parallel_checks` unset so the width was the vendor's
  too — and **it is still live there on 2026-08-19**. The pull request that was
  recorded as fixing it never merged; see the fleet table.
- **Do not raise `max_parallel_checks` to go faster.** It is the one knob whose
  cost is linear in runners, it spends from a pool shared with every other
  repository, and `batch_size` buys the same throughput for free. A width above
  1 is a fleet-level change; recompute the runner budget in the same pull
  request.

Added 2026-08-19, all four about `mode`:

- **Do not use `mode: isolated`.** Ever. It removes the dependency between
  batches entirely, so two entries that pass alone and conflict together both
  merge — the one property a merge queue exists to provide. The gate rejects it.
- **Do not raise `max_parallel_checks` above 1 without declaring `mode`.** An
  undeclared mode is `serial`, which makes the extra checks a **stack**: a
  dequeue at the front throws away everything behind it, and each of those
  restarts cold. That is width bought and independence not received, which is
  what the whole fleet was doing until 2026-08-19.
- **Do not set `mode: parallel` with partial scope coverage.** A pull request
  matching no scope carries the empty set, overlaps nothing, and therefore runs
  beside **everything**. Unscoped is the most parallel state, not the safest one,
  and nothing in Mergify reports it. Total coverage or stay `serial`.
- **Do not give a wide-fan-out package its own scope.** A scope asserts
  independence; a package most of the repository imports is independent of
  nothing. It belongs in `barrier_files`, together with the build/toolchain
  configuration and the CI and gate machinery — neither of which a dependency
  graph can see, so both are enumerated by hand.
- **Do not set a `capacity` above `max_parallel_checks`.** It is a sub-limit
  *inside* the global width, so a larger number reads like a raise and does
  nothing. A capacity naming a scope that does not exist is worse: silently
  ignored, and that scope then runs at the full width.

> **Retracted 2026-08-17:** this list used to read *"Do not raise `batch_size`
> to drain a backlog — it re-introduces the throwaway draft, so the backlog is
> then draining at two CI runs per merge."* The premise was right and the
> conclusion was backwards. A draft validates the whole **batch** in one run, so
> a batch of five drains at 0.2 second-CI runs per merge, not two — and a reader
> who accepted the bullet was left reaching for `max_parallel_checks`, which
> genuinely does cost a full run per step. IntegrateIT sat at width 5 with
> `batch_size: 1` for exactly this reason. Kept visible rather than deleted,
> because the deleted version of a rule is the one that gets re-derived.

---

## Fleet status (2026-08-21) — the scopes pass, completed

Every repository that has a Mergify queue now **declares** `merge_queue.mode`,
carries a **catch-all barrier plus a total scope map**, and runs
`check-mergify-scopes.sh` fixtures-then-real as an always-on required check. The
2026-08-19 survey below is kept as the before picture.

Read live from each `.mergify.yml`, and the unit counts from the gate itself.
`job ceiling` is `slots_per_host × max_hosts` from the pool's `.tfvars`, never a
live runner count.

| repository | job ceiling | peak pool jobs | width | mode | units |
|---|---|---|---|---|---|
| IntegrateIT | 32 (4 × 8) | 5 | **4** | parallel | 310 |
| Print-Server | 24 (4 × 6) | 6 | **3** | parallel | 44 |
| entity-platform | 24 (4 × 6) | 3 scoped | **3** | parallel | 10 |
| DataRetrival | 16 (4 × 4) | 6 | **2** | parallel | 28 |
| Specaria-Platform | 16 (4 × 4) | — | **2** | parallel | 59 |
| Apigee-Portal | 12 (4 × 3) | 13 | 1 *(pool-blocked)* | parallel | 31 |
| SOAP-To-REST | 12 (4 × 3) | 17 | 1 *(pool-blocked)* | parallel | 19 |
| Telnet-Emulation | 8 (4 × 2) | 8 | 1 *(pool-blocked)* | parallel | 8 |
| Borsh-Tablet-App | 6 (2 × 3) | 5 | 1 *(pool-blocked)* | parallel | 9 |
| CarListPrice | *(GitHub-hosted)* | n/a | 1 *(by choice)* | parallel | 2 |
| mot-face-blur | *(GitHub-hosted)* | n/a | 1 *(by choice)* | parallel | 3 |
| mot-claude | 8 (4 × 2) | 6 | — | **no queue at all** | — |

Three things this table is saying that are easy to misread:

- **"pool-blocked" is a capacity fact, not a preference.** Those four repositories
  have a *correct* scope map that is currently **inert**: one check already
  oversubscribes the pool, so a second would queue behind the first rather than
  run beside it. Raising the width there means raising `max_hosts` first, and each
  has an issue filed against it. The map is what must already be true *before*
  the width rises — which is the whole reason it lands first.
- **"by choice" is the other constraint entirely.** CarListPrice and mot-face-blur
  run every job on GitHub-hosted runners, so there is no pool to exhaust. What a
  width above 1 costs them is **in-place checking**: every merging pull request
  would pay a second full CI run on a throwaway draft. At their merge rate that is
  a straight doubling of hosted minutes to buy concurrency nobody is waiting on,
  so the width stays 1 and `check-merge-queue-single-step.sh` enforces it.
- **mot-claude was deliberately left alone.** It has no `.mergify.yml` *and no
  rulesets at all* — `gh api repos/.../rulesets` returns an empty list. Adding a
  queue there would introduce merge governance where there is none rather than
  optimise an existing queue, which is a decision to take and not a change to slip
  in behind a config-only pull request. Proposed as an issue instead.

Atlas and Manar are unchanged and still out of scope for this pass: both name
`runs-on: [self-hosted, linux, gcp, <Repo>]` while instantiating no
`ci-runner-host-pool`, so their jobs are unassignable and no queue setting can
help until that is fixed.

## Fleet status (re-surveyed 2026-08-19)

Read live from each repository's `.mergify.yml`, not from the conversion PR list
— a landed conversion is not evidence the file still says what it said.

The table gains a **mode** column, and every cell in it was empty at the survey:
no repository in the fleet had ever declared `merge_queue.mode`. Fourteen
defaults, zero decisions.

The **job ceiling** column is `slots_per_host × max_hosts` from the pool's
`.tfvars` — *not* a live runner count, for the reason given in
[the fleet runner budget](#the-fleet-runner-budget--the-invariant-no-single-repository-can-see).

| repository | job ceiling | width | mode | batch | tier |
|---|---|---|---|---|---|
| IntegrateIT | **32** (4 × 8) | 3 → **4** | *(none)* → **parallel** | 1 | **0** on batch; width by own-pool ceiling |
| entity-platform | 24 (4 × 6) | 1 | *(none)* = serial | 1 | **0**, correctly |
| Print-Server | 24 (4 × 6) | 1 | *(none)* = serial | 1 | **0**, correctly |
| Specaria-Platform | 16 (4 × 4) | 1 | *(none)* = serial | 1 | **0**, correctly |
| DataRetrival | 12 (4 × 3) | 1 | *(none)* = serial | 1 | **0**, correctly |
| SOAP-To-REST | 12 (4 × 3) | 1 | *(none)* = serial | 1 | **0**, correctly |
| Apigee-Portal | 12 (4 × 3) | 1 | *(none)* = serial | 1 | **0**, correctly |
| Telnet-Emulation | 8 (4 × 2) | 1 | *(none)* = serial | 1 | **0**, correctly |
| mot-claude | 8 (4 × 2) | 1 | *(none)* = serial | 1 | **0**, correctly |
| Borsh-Tablet-App | 6 (2 × 3) | 1 | *(none)* = serial | 1 | **0**, correctly |
| ci-runner-infra, CarListPrice, mot-face-blur | *(no pool — GitHub-hosted)* | 1 | *(none)* = serial | 1 | **0**, correctly |
| Atlas | **no pool, CI demands `self-hosted`** | 1 | *(none)* = serial | 1 | **0** on batch; **unassignable jobs** |
| Manar | **no pool, CI demands `self-hosted`** | **unset** | *(none)* = serial | **5** | **NOT converted — see below** |

Thirteen of the fourteen repositories merge **one pull request per batch**.

**Manar does not, and this document said it did.** The 2026-08-18 survey recorded
"Manar #25 (5 → 1)" as landed. It was not: **PR #25 is still OPEN**, verified
against the live file on 2026-08-19. That is precisely the failure this section
opens by warning about — *read live from each repository's `.mergify.yml`, not
from the conversion PR list* — committed by the survey that wrote the warning.

Manar's live `.mergify.yml` has never been converted at all. Every defect is
present at once:

| defect | consequence |
|---|---|
| `batch_size: 5` | four pull requests can be delayed or dequeued by a fifth |
| no `batch_max_failure_resolution_attempts` | **unlimited** bisect splits — one flaky test becomes an unbounded chain of draft runs while everything behind it waits |
| `max_parallel_checks` unset | the width is the vendor's, not a number anyone here chose |
| the banned `pull_request_rules` → `actions.queue` action | a **third** condition list, so checking is two-step by construction |
| `merge_conditions` with no `queue_conditions` | no anchored single list; the identity property cannot hold |
| no `checks_timeout` | a hung job surfaces as a silent dequeue rather than a red check |

It is the only repository in the fleet still on the pre-baseline shape, and it is
the one place where a width raise would be actively wrong: pinning the width is
the smaller half of what it needs.

**And none of those six defects is why #25 is stuck.** Manar's `ci.yml` runs both
its jobs on `[self-hosted, linux, gcp, Manar]`, and no `ci-runner-host-pool` is
instantiated anywhere in the repository. The twenty-seven contexts with an empty
conclusion are not slow and not path-filtered — they are **unassignable**, and
they will stay pending forever. Fix the pool first; the `.mergify.yml` conversion
cannot land until something can report a conclusion on a config-only diff.
Atlas has the same missing pool against the same labels and should be checked in
the same pass.

The general lesson, since this document has now made the mistake it warns about:
**an open pull request is not a landed change, and a survey that reads the PR
list rather than the file will report the intention as the state.** Every row in
this table was re-read from the live file on 2026-08-19.

**The job-ceiling column is the correction of record, and it has now been wrong
once.** Runners are registered per repository, not into one fleet-wide pool, and
**ten of the fourteen repositories have their own pool** — see
[the fleet runner budget](#the-fleet-runner-budget--the-invariant-no-single-repository-can-see)
for why the first survey read eleven of them as zero. A width raise is bounded by
that repository's own `slots_per_host × max_hosts` and by nothing else; it cannot
starve IntegrateIT's pool, and it is a capacity argument, not a cost one.

**Nothing yet PREVENTS a repository-local raise back above 1.**
`check-merge-queue-single-step.sh` enforces `BATCH_MAX` as a *ceiling* (5), so a
repository setting `batch_size: 3` with the paired attempt bound passes the
gate. Until the gate asserts the value rather than a ceiling, this document is
the only thing holding the decision, and a document is not an enforcement
mechanism.

Landed conversions, for history: DataRetrival #2384, IntegrateIT #7778,
Specaria-Platform #3225, Print-Server #1833, CarListPrice #14, SOAP-To-REST
#2036, mot-face-blur #56, Telnet-Emulation #710, entity-platform #269,
Apigee-Portal #2329, Atlas #1945.

The gate itself keeps moving, and a copy that stopped moving with it is the
failure this whole document is about — a file that looks enforced. The version
in this repository is canonical; the repositories that took an earlier copy are
being resynced by a one-file pull request each (IntegrateIT #7814, Print-Server
#1855, Specaria-Platform #3244, mot-face-blur #61, CarListPrice #16,
SOAP-To-REST #2052).

Two findings that came out of the conversion and are NOT fixed by it, tracked
separately because they are properties of a repository's ruleset rather than of
`.mergify.yml`:

- **A required context with no producer** — Telnet-Emulation's ruleset requires
  `generic-binary`, which no workflow in that repository emits, so every pull
  request sits `BLOCKED` waiting for a conclusion that cannot arrive while
  `gh pr checks` shows nothing failing. Filed as Telnet-Emulation #712. The
  routine workaround is an admin bypass, which skips the gates that DO exist.
- **A repository with no ruleset at all** — this one, until 2026-08-14. The
  repository that publishes the fleet's CI rules was the one repository where
  `main` took any push. Now `main-guardrails`: squash-only, linear history, no
  deletion, no force-push, and the three CI contexts required, with
  `strict_required_status_checks_policy` OFF so the queue can check in place.
