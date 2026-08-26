# The CI lane model — published contract

This is the contract consuming repositories adopt. The rule itself is
`scripts/ci/lane-decision.sh`, asserted by `scripts/ci/lane-decision.selftest.sh`
in this repository's CI. The evidence behind it is in
[`ci-optimization-catalog.md`](ci-optimization-catalog.md).

It decides **how much** CI a diff deserves. It does not decide **where** that CI
runs or what it shares — that is [`ci-pr-shared-infra.md`](ci-pr-shared-infra.md)
(one host per pull request, one infrastructure stack on it), which is adopted
*after* this document because it pins the set of jobs this one selects.

Same argument as the Terraform module this repository already publishes: the
lane rule was re-derived independently in four repositories with four different
path lists, and two of them evaluate it in a place that defeats its purpose.
One rule, one test, every repository.

---

## The three lanes

| Lane | What runs | When |
|---|---|---|
| `none` | no self-hosted job; the aggregate check reports success | every changed path is provably non-code |
| `partial` | the affected-area jobs; the rest skip | ordinary code change — the default |
| `full` | everything | the diff can invalidate a check that reads none of the files it changed |

`full` is not a synonym for "big". It is the lane for diffs whose blast radius
is not visible in the diff: a lockfile bump, a Dockerfile edit, a compiler
option, a workflow change, an infrastructure change, a migration. An
affected-only filter is structurally blind to all of these, which is why they
bypass it rather than being widened into it.

## The invariant

The two failure directions are not symmetric, and the rule is tuned accordingly:

- Too **wide** costs runner seconds and shows up in the bill.
- Too **narrow** merges code no job read, and reports green while doing it.

So:

1. `none` requires **every** path to be non-code. One source file among a
   hundred documentation files leaves the lane.
2. Anything **unrecognised** is `partial`, never `none`. A file type the rule
   has not seen yet gets tested by default.
3. An **empty** diff is `full`. Zero changed paths means the caller lost its
   merge base — a failed diff must never read as "nothing changed".

---

## Adoption — four requirements, in order

### 1. One aggregate required check per repository

**This is a prerequisite, not a step.** Until it exists, nothing else here can
be adopted safely.

A job-level `if:` reports `skipped`, and a `skipped` required check dequeues a
pull request in Mergify permanently. That is why two repositories in the fleet
evaluate the lane rule *inside* a self-hosted job — an inefficient shape chosen
to work around a reporting problem, not a preference.

Fix the reporting problem instead. Name exactly one job in the branch ruleset
and in `.mergify.yml`; that job `needs:` every gated job and runs
`if: ${{ !cancelled() }}`:

```yaml
  ci-success:
    name: CI
    needs: [lane, build, test, integration]
    # `!cancelled()`, NOT `always()` — see "A superseded run must not report"
    # below. `always()` also means "run while this workflow run is being
    # cancelled", which turns every superseded suite into a permanent red
    # check-run for the one context the queue reads.
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Fail if any needed job failed or was cancelled
        run: |
          set -euo pipefail
          # `skipped` is a PASS here — that is the entire point. A gated job
          # that did not run because its paths did not change has not failed.
          echo '${{ toJSON(needs) }}' \
            | python3 -c 'import json,sys; r=json.load(sys.stdin); bad={k:v["result"] for k,v in r.items() if v["result"] in ("failure","cancelled")}; print(bad or "all green"); sys.exit(1 if bad else 0)'
```

Specaria-Platform already runs this shape; DataRetrival reached it
independently for `migration-harness` and recorded why in its own comment.

### 2. Classify off the pool

The classifier runs on `ubuntu-latest`. It must never occupy a self-hosted slot,
because its whole job is to decide whether a self-hosted slot is warranted.

```yaml
  lane:
    name: Lane
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      lane: ${{ steps.decide.outputs.lane }}
    steps:
      - uses: actions/checkout@v4
        with:
          # Shallow on purpose, and 2 rather than 1: the classifier diffs the
          # merge commit against its base parent, so that parent has to be in
          # the clone — but nothing older than it does, and this job runs on
          # every pull request. `fetch-depth: 0` here is the full-clone cost
          # the catalog recommends removing, paid to compute a filename list.
          fetch-depth: 2
      - id: decide
        run: |
          set -euo pipefail
          # Pinned to an immutable commit, NOT a tag. This shell is downloaded
          # and SOURCED inside a checked-out CI job that may hold credentials;
          # a moved or recreated tag would change executing code in every
          # consuming repository with no pull request in any of them. The
          # digest check is what makes the pin worth anything.
          sha=<40-char-commit-sha>
          curl -fsSL -o /tmp/lane-decision.sh \
            "https://raw.githubusercontent.com/<org>/ci-runner-infra/$sha/scripts/ci/lane-decision.sh"
          echo "<sha256>  /tmp/lane-decision.sh" | sha256sum -c -
          # shellcheck source=/dev/null
          source /tmp/lane-decision.sh
          # On a `pull_request` event HEAD is the merge commit GitHub built, so
          # HEAD^1 IS the base and HEAD^1..HEAD is exactly the pull request's
          # changes — no network round trip and no merge base to compute.
          #
          # The triple-dot form (`git diff "$base"...HEAD`) is what NOT to do
          # here: it asks git for the merge base of two commits, and in a
          # shallow clone each fetch creates its own grafted root with no
          # shared ancestry. It fails with `fatal: ... no merge base`, and
          # under `set -euo pipefail` that kills the classifier — on every
          # pull request, in every adopting repository. `--depth` deepens an
          # existing shallow history; it does not reconnect two roots.
          verdict=$(git diff --name-only HEAD^1 HEAD | lane_decision)
          echo "lane=${verdict%%:*}" >> "$GITHUB_OUTPUT"
          echo "::notice::lane $verdict"
```

Pin the COMMIT, and check the digest. A tag is mutable: pinning one still lets
whoever can move it change what every consuming repository tests — and what
code it sources into a credentialed job — with no pull request anywhere.

### 3. Gate at job level, never inside the job

```yaml
  test:
    needs: lane
    if: needs.lane.outputs.lane != 'none'
    runs-on: [self-hosted, linux, gcp, <Repo>]
```

A step-level `if:` inside a self-hosted job has already spent the thing the lane
exists to protect.

### 4. Keep the always-run guards, and move them off the pool

Some checks must report on **every** pull request, including the `none` lane —
a one-line comment edit is exactly the diff they exist to catch. In
Apigee-Portal these are the documentation-claims, resident-context-budget,
source-map and workflow-shell guards.

They are correct to be unfiltered. They are wrong to be on the pool: they are
pure standard-library shell or Node with no install and no build. Run them
unfiltered on `ubuntu-latest`.

---

## Interaction with drafts

The lane rule answers *which* checks a diff deserves. It does not answer *when*.
Draft status answers that, and the two compose:

| | draft | ready |
|---|---|---|
| `none` | aggregate check only | aggregate check only |
| `partial` | fast tier only | fast + heavy, affected areas |
| `full` | fast tier only | everything |

The draft mechanism has two halves and both are load-bearing:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review, converted_to_draft]
```

```yaml
    if: >-
      github.event_name != 'pull_request'
      || github.event.pull_request.draft == false
      || startsWith(github.head_ref, 'mergify/merge-queue/')
```

- Without `converted_to_draft`, a pull request pushed back to draft leaves its
  in-flight heavy run going: nothing re-fires, so concurrency has nothing to
  supersede it with, and the pool keeps paying for a tier the pull request no
  longer qualifies for. This only works if the consuming workflow declares a
  `concurrency` group keyed on the head ref **with `cancel-in-progress` true
  for `pull_request`** — the type merely produces the newer run; cancellation
  is what stops the old one. With `cancel-in-progress` unset the redundant run
  holds its slot to completion and the type buys nothing.
- Without `ready_for_review`, the draft-to-ready transition never re-fires and
  the guarded checks stay `SKIPPED` while the pull request reports
  `mergeStateStatus=CLEAN` — green-looking and untested.
- Without the `mergify/merge-queue/` escape hatch, Mergify's speculative branch
  (itself a draft pull request, not a `merge_group` event) skips every required
  check and **no pull request in the repository can ever merge**.

Apigee-Portal carries both, with the incident references. Copy it whole; do not
re-derive half of it.

### The stale-`skipped` trap, and why requirement 1 is not optional

Observed on DataRetrival #2338 (2026-08-14), and it is the concrete cost of
naming a *gated* job as a required check:

A job skipped by that `if:` is not absent. GitHub records a real check-run with
conclusion `skipped`, attached to the head sha. Marking the pull request ready
fires a **second** check suite on the **same sha**, and that one succeeds — but
the `skipped` run stays. The sha now carries two check-runs per context, one
`skipped` and one `success`, and Mergify reads the skipped one:

```
The merge conditions cannot be satisfied due to failing checks
- `lint` - `typecheck` - `generic-binary` - `migrations` - `test` - `migration-harness`
```

with every one of those jobs green in the second suite. `@mergifyio refresh`
does not clear it. Only a new head sha does.

It bites when `ready_for_review` is the **last** event on the sha. A pull
request that gets one more commit after being marked ready produces a clean
single-suite sha and never sees it — which is why the trap hides: it spares the
hand-edited pull request and catches the agent-authored one that was complete
when opened and simply flipped to ready.

The fix is requirement 1, applied properly: the required NAME belongs to a
cheap **always-running** aggregate that reports success, and the expensive work
sits in a separate, differently-named job behind the draft/lane condition. Then
a draft emits `success` for the context, the ready re-run emits `success` again,
and the two suites cannot disagree. DataRetrival's `migration-harness` is the
worked example, and its `.mergify.yml` states the reason in place.

Do **not** instead relax the queue conditions to accept `skipped`. That makes a
genuinely-unrun gate count as green, which is the failure mode the required
check exists to prevent — and on the `none` lane every heavy check is skipped
by design, so the relaxation would apply exactly where it is least safe.

### A superseded run must not report — `!cancelled()`, never `always()`

Observed on DataRetrival #2350 (2026-08-14), immediately after the fix above
was applied, and it is the same trap wearing a different conclusion.

`always()` does not mean "after the needed jobs finish". It means "run even
while this workflow run is being cancelled". Marking a pull request ready fires
a second check suite on the same head sha, and `concurrency.cancel-in-progress`
cancels the first — so every aggregate in the dying suite still executes, reads
`cancelled` from its upstream jobs, and writes a terminal **failure** check-run
for the required context:

```
Rule: Auto-queue non-draft PRs once required checks are green (queue)   fail
```

The second suite's `success` lands eight seconds later and does **not** displace
it. Mergify sees both conclusions on the sha and reports the context failing —
exactly the deadlock the aggregate was introduced to remove, with `cancelled`
where `skipped` used to be.

The scope is **same-sha supersession**, and that is the whole hazard: an
ordinary push moves the head, so the cancelled suite's red stays attached to the
*previous* sha and the queue — which evaluates the head — never sees it. What
starts a second suite on the SAME sha is `ready_for_review`, a re-run, a
`workflow_dispatch` on that ref, or a queue re-entry. Diagnosing this by
looking at the newest commit's checks will therefore find nothing; read the
check-runs of the sha Mergify names.

`if: ${{ !cancelled() }}` fixes it. The aggregate is then cancelled together
with its run rather than rendering a verdict on it, and it still runs for every
real outcome — success, failure, skip — which is the case `always()` was there
for. `!cancelled()` is itself a status-check function, so it replaces the
implicit `success()` exactly as `always()` does: the aggregate still runs when a
needed job FAILED or was SKIPPED. `always() && !cancelled()` is the same
condition written twice. An upstream job cancelled on its own while its run
continues still reports red, so nothing is loosened.

---

## Interaction with the merge queue

- Lane `none` enters a `docs` queue with `priority: high` and no batching.
  Still serialized, so merge ordering holds — just never behind a heavy batch.
- **A second queue rule is a second place to lose in-place checking.** Every
  rule needs its own `batch_size` **and** its own `queue_conditions: &anchor` /
  `merge_conditions: *anchor`; one unanchored rule means every pull request
  that rule admits pays a second full CI pass, on a file that reads as
  compliant. Batching is inherited PER RULE, so a rule that simply omits
  `batch_size` batches at the vendor default however carefully its neighbours
  are pinned. The whole contract, and the gate that asserts it, is in
  [`ci-merge-queue-baseline.md`](ci-merge-queue-baseline.md) — adopt it with
  this model, not after it.
- **`batch_size: 1` is the Tier 0 value, not a universal one.** A repository
  whose merge cadence is slower than one CI run has the queue, not CI, as its
  bottleneck, and batches up to five — paired with a
  `batch_max_failure_resolution_attempts` of at least `ceil(log2(max))` so a
  failed batch bisects to the culprit instead of dequeuing its neighbours. The
  measurement that justifies the move, and the reason the knob to raise is
  `batch_size` and never `max_parallel_checks`, are in the same document.
- **A base move re-checks the lanes it can affect, not all of them.** The lane
  rule answers how much CI a *diff* deserves; it does not answer what a move of
  the default branch under an in-flight pull request deserves. That is the
  per-lane suite reuse key in [`ci-suite-reuse.md`](ci-suite-reuse.md), which is
  computed over the same `dorny/paths-filter` document the lane is gated on —
  adopt this model first, it is where those declared paths come from.
- `checks_timeout` must be **pinned** in every `queue_rules` entry. Unpinned, it
  inherits an undeclared vendor default of roughly 42 minutes, so a hung job
  surfaces as a silent dequeue rather than a red check.
- The ordering invariant, which Apigee-Portal pinned after PR #1429:

  ```
  per-workspace timeout  <  job timeout-minutes  <  checks_timeout
  ```

  Raising a gating job past `checks_timeout` without raising `checks_timeout`
  re-creates that dequeue.

### Routing the queue's own runs to their own pool

The lane rule decides **how much** CI a change deserves. It does not decide
**where** that CI runs, and on a repository with a merge-queue pool those are
two different questions arriving at the same job.

Mergify validates a queued pull request by re-running the same `pull_request`
workflows on a `mergify/merge-queue/<sha>` branch, against the same labels, at
the moment the pull-request pool is busiest — which is the bottleneck this
split exists to remove. So the lane job publishes a second output naming the
label set, and every self-hosted job resolves `runs-on` from it:

```yaml
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      lane: ${{ steps.decide.outputs.lane }}
      runner: >-
        ${{ (github.event.pull_request.head.repo.full_name == github.repository
             && github.event.pull_request.user.login == 'mergify[bot]'
             && startsWith(github.head_ref, 'mergify/merge-queue/'))
            && '["self-hosted","linux","gcp","<Repo>-merge-queue"]'
            || '["self-hosted","linux","gcp","<Repo>"]' }}

  test:
    needs: lane
    if: needs.lane.outputs.lane != 'none'
    runs-on: ${{ fromJSON(needs.lane.outputs.runner) }}
```

Five properties, each of which has already failed somewhere on this fleet:

- **An expression, not a step.** A step can fail, and a failed step leaves every
  downstream job with an empty `runs-on`, which GitHub queues forever against a
  label no runner carries. There is no red check for that — the pull request
  simply stops moving.
- **The branch name alone decides nothing.** `github.head_ref` is chosen by
  whoever opened the pull request, so keyed on the prefix alone the pool
  reserved for the queue is available to anyone — a fork included — willing to
  name a branch after it. Two facts nobody outside the repository can forge are
  required with it: the head branch lives in **this** repository, and the pull
  request was opened by Mergify. `check-runner-policy.sh` used to fail this as
  **RUNNER12**; that rule retired with Mergify
  ([#434](https://github.com/Dima-Spectorr/ci-runner-infra/issues/434)), so
  nothing checks it automatically any more — which is safe only for as long as
  no repository has a merge-queue route at all.
- **The two label sets must be disjoint.** GitHub schedules a self-hosted runner
  by *superset*, so a queue arm that carries `<Repo>` *as well as*
  `<Repo>-merge-queue` is dedicated in name only — every ordinary job is
  eligible for the queue's hosts, and the split buys nothing. Covered the other
  way round and the queue cannot be addressed at all. The queue pool carries its
  own label **instead of** the pull-request pool's, never in addition to it.
  **RUNNER13** enforced this over the workflow until it retired with Mergify
  (#434). The controller module still asserts the same property across its
  `pools` table at plan time, and is now the only end that does — the pair
  existed because either end alone is a rule the other end drifts away from,
  and one end is what is left.
- **`github.head_ref` is empty on `push`,** so a push to the default branch
  resolves to the pull-request pool. Correct: a push is not a speculative check.
- **EVERY self-hosted job takes the route, in every workflow file.** This is the
  property that gets half-done, because half-done reports nothing: a job left
  naming `<Repo>` literally still finds a runner and still passes. It just finds
  it in the **pull-request** pool, on every queue draft, competing with exactly
  the traffic the split was built to keep away from the queue. On IntegrateIT a
  65-second `generic-binary` job — a *required* check, in the one workflow that
  was not repointed — waited 31m06s on a queue draft, while Mergify displayed
  "waiting for generic-binary", which reads as slow rather than as stuck.
  **RUNNER14** caught this, opted into by the route existing anywhere in the
  repository, so the second workflow could not quietly stay behind. It retired
  with Mergify (#434) — the failure it describes needs a merge-queue draft, and
  nothing creates one now. Restoring a queue pool means restoring the rule with
  it; the 31m06s above is what the repository gets otherwise, and it reads as a
  slow check rather than a stuck one.

**Turning the route on is order-dependent, once, per repository.** The commit
that introduces it cannot be merged *through* the queue: Mergify's speculative
draft of that very commit runs under the new routing and asks for a label no
runner carries yet. Apply the Terraform that creates the queue pool first, then
merge the workflow change.

A repository with no merge-queue pool writes none of this and neither rule
applies to it — they are opted into by the route existing, not by a flag.

### How big that pool is allowed to get

The route decides *where* the queue's runs go. It says nothing about *how many*
hosts may be there, and the answer is now short: **Terraform's `max_hosts`, and
nothing else.**

It used to be derived. Mergify ran at most `max_parallel_checks` speculative
check runs per queue, so that number was a real ceiling published by a real
producer, and the controller read it live out of the served repository's
`.mergify.yml` — `ceil( Σ max_parallel_checks × jobs per check ÷ slots per host )`
— rather than making an operator type a number they could not know.

Mergify is gone from every repository in the fleet (#434). The merge lane that
replaced it publishes no concurrency for anything to read: it merges what is
ready, one candidate at a time. There is no file to fetch, so the derivation and
everything it needed retired with it — the `Contents: read` grant on the App, the
`python3-yaml` dependency on the controller, and six of the seven metrics. The
rule had been failing open to `max_hosts` since the last `.mergify.yml` was
deleted, so nothing about a running pool changed when it went.

**Sizing it by hand is a one-line calculation, and the input is still published.**
`ci_queue_jobs_per_check` is the observed high-water number of this pool's jobs in
one check run — a property of the workflow file, counted during the demand sweep,
never configured. Multiply it by how many merges you want validated at once and
divide by the pool's slots per host:

```
max_hosts = ceil( ci_queue_jobs_per_check × parallel merges ÷ slots per host )
```

Getting it too low is the direction that hides: a queue throttled by runner
capacity has checks that are **pending**, never failed, on a pull request whose
own CI is already green. Nothing goes red and nothing pages. That was the reason
to derive the number in the first place, and it is the reason to review this one
when a repository's workflows grow.


---

## Where a browser suite sits in the lanes

An end-to-end suite is the most expensive thing a pull request can run and the
only thing that proves a user journey still works. Tiering it is not a nicety —
an undifferentiated suite forces a choice between a gate nobody waits for and no
gate at all, and repositories always pick the second.

| Lane | Browser suite |
|---|---|
| `none` | none. A documentation edit cannot break a journey. |
| `partial` | the `@smoke` tier: chromium only, sharded, budgeted at ≤3 min. |
| `full` | `@smoke` on the pull request; the complete suite on the merge queue. |
| merge queue | the complete suite, all browsers, once — the last point before `main`. |
| nightly | the complete suite plus the slow matrix nobody should wait on. |

Two things about this are easy to get wrong.

**E2E is not path-scoped to `e2e/**`.** Scoping the suite to the directory the
specs live in is the narrow-lane failure this whole document is about, wearing a
plausible disguise: the change that breaks a journey is a change to the
application, and the specs are the only files that did *not* change. The tier is
chosen by lane, not by whether the diff touched a test.

**The tier is chosen at the command, not in the config.** Tag at the test
(`test('submits the application @smoke', …)`) and select at the invocation
(`--grep @smoke --shard=…`). A config that hard-codes which tier it is has to be
edited to run the other one, and a config edited per invocation is a config no
gate can read — which is what `check-e2e-policy.sh` reads
([`ci-workflow-gates.md`](ci-workflow-gates.md)).

The `globalTimeout` rung in that gate is the same dequeue hazard as above,
arriving through a file the queue never looks at: a suite with no ceiling of its
own outlives `checks_timeout` and the pull request leaves the queue without a
red check anywhere.

---

## What a consuming repository must not do

- **Do not vendor the rule.** Reference it by tag. Nine divergent copies of the
  pool module is the mistake this repository was created to undo.
- **Do not widen `none`.** If a path is arguably code, it is `partial`.
- **Do not put the classifier on the pool.**
- **Do not write the aggregate `if: always()`.** Use `!cancelled()`. `always()`
  runs the job while its own run is being cancelled, so every superseded suite
  leaves a terminal red on the required context — see "A superseded run must not
  report".
- **Do not make a gated job a required check directly.** Required checks name
  the aggregate job, and only the aggregate job. A gated job's `skipped`
  check-run outlives the draft phase and blocks the queue after
  `ready_for_review` — see the stale-`skipped` trap above.
