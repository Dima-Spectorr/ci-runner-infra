# The CI lane model — published contract

This is the contract consuming repositories adopt. The rule itself is
`scripts/ci/lane-decision.sh`, asserted by `scripts/ci/lane-decision.selftest.sh`
in this repository's CI. The evidence behind it is in
[`ci-optimization-catalog.md`](ci-optimization-catalog.md).

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
  rule needs its own `batch_size: 1` and its own `queue_conditions: &anchor` /
  `merge_conditions: *anchor`; one unanchored rule means every pull request
  that rule admits pays a second full CI pass, on a file that reads as
  compliant. The whole contract, and the gate that asserts it, is in
  [`ci-merge-queue-baseline.md`](ci-merge-queue-baseline.md) — adopt it with
  this model, not after it.
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
