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
`if: always()`:

```yaml
  ci-success:
    name: CI
    needs: [lane, build, test, integration]
    if: always()
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
          # Only the merge base is needed — not the full history a
          # `fetch-depth: 0` clone pays for on every job.
          fetch-depth: 0
      - id: decide
        run: |
          set -euo pipefail
          curl -fsSL -o /tmp/lane-decision.sh \
            "https://raw.githubusercontent.com/<org>/ci-runner-infra/v3.1.0/scripts/ci/lane-decision.sh"
          # shellcheck source=/dev/null
          source /tmp/lane-decision.sh
          base="${{ github.event.pull_request.base.sha }}"
          verdict=$(git diff --name-only "$base"...HEAD | lane_decision)
          echo "lane=${verdict%%:*}" >> "$GITHUB_OUTPUT"
          echo "::notice::lane $verdict"
```

Pin the tag. An unpinned rule changes what a repository tests without a pull
request in that repository.

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
    types: [opened, synchronize, reopened, ready_for_review]
```

```yaml
    if: >-
      github.event_name != 'pull_request'
      || github.event.pull_request.draft == false
      || startsWith(github.head_ref, 'mergify/merge-queue/')
```

- Without `ready_for_review`, the draft-to-ready transition never re-fires and
  the guarded checks stay `SKIPPED` while the pull request reports
  `mergeStateStatus=CLEAN` — green-looking and untested.
- Without the `mergify/merge-queue/` escape hatch, Mergify's speculative branch
  (itself a draft pull request, not a `merge_group` event) skips every required
  check and **no pull request in the repository can ever merge**.

Apigee-Portal carries both, with the incident references. Copy it whole; do not
re-derive half of it.

---

## Interaction with the merge queue

- Lane `none` enters a `docs` queue with `priority: high` and no batching.
  Still serialized, so merge ordering holds — just never behind a heavy batch.
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

## What a consuming repository must not do

- **Do not vendor the rule.** Reference it by tag. Nine divergent copies of the
  pool module is the mistake this repository was created to undo.
- **Do not widen `none`.** If a path is arguably code, it is `partial`.
- **Do not put the classifier on the pool.**
- **Do not make a gated job a required check directly.** Required checks name
  the aggregate job, and only the aggregate job.
