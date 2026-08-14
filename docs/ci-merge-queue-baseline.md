# The merge-queue baseline — one CI run per pull request

The lane model in [`ci-lane-model.md`](ci-lane-model.md) decides *how much* CI a
pull request deserves. This decides *how many times it runs*. They are
independent: a repository can classify lanes perfectly and still pay for every
pull request twice, because the second run is not started by the workflow — it
is started by Mergify.

Adopt this together with the lane model. It is copy-in, not by-tag: the file it
governs (`.mergify.yml`) lives in the consuming repository, so what is published
here is the required shape, the gate that asserts it, and where the gate must
sit.

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

## The five properties

In-place checking requires ALL of these. Break any one and the queue silently
moves to the throwaway draft — merges keep working, only the runner bill
changes.

1. **`merge_queue.max_parallel_checks: 1`, as a TOP-LEVEL key.** Inside a queue
   rule it is not ignored — Mergify rejects the whole file with
   `Extra inputs are not permitted @ root → queue_rules → item 0 →
   max_parallel_checks` and the queue then fails **closed**: every pull request
   sits unmergeable behind a red check whose reason is a config error rather
   than anything about the branch. Found in that state in one fleet repository
   (Atlas, fixed in its #1945); the file had looked correct for months.
2. **`batch_size: 1` in every queue rule.** A batch has to be assembled
   somewhere, and that somewhere is a branch.
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
asserts the **anchor spelling**, per rule, not the values — a value comparison
passes the exact file that is about to regress.

A `pull_request_rules` queue action is the same failure in another spelling: its
`conditions:` are a third list, different by construction since it must carry
`base`/`-draft`. Queue via `auto_merge_conditions` instead. Non-queue
`pull_request_rules` entries — labels, comments, branch cleanup — are unaffected
and should stay.

`auto_merge_conditions` carries only the base/draft/label facts. It must **not**
restate the required checks: those live once, in the anchored list, which is
what decides when a queued pull request embarks.

---

## The reference configuration

```yaml
merge_queue:
  max_parallel_checks: 1

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

The condition list mirrors the branch ruleset's required checks **exactly**, and
each of them must be an always-completing context — the aggregate job of the
lane model, which reports `success` when its area was untouched. A check that
*skips* leaves the queue waiting for a conclusion that never comes.

---

## Where the gate goes

`scripts/ci/check-merge-queue-single-step.sh` (published here; copy it in, same
filename, so a diff against this copy is a one-liner) asserts all five
properties plus the queue-action ban. Two rules about where it runs:

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

The self-test plants 13 fixtures and asserts each detector on its own count,
because a config gate's characteristic failure is a **vacuous pass** — it reads
a file it never matches and reports clean. The fixtures include a
commented-out queue action (must satisfy neither the ban nor the
something-queues check) and a two-rule file with one rule unanchored (a
whole-file "an anchor exists" test passes it).

---

## What a consuming repository must not do

- **Do not remove the queue action without adding `auto_merge_conditions`.**
  The two halves land in one commit or not at all.
- **Do not put `max_parallel_checks` inside a queue rule.** It rejects the file
  and the queue fails closed.
- **Do not write `merge_conditions` out as a second list**, however carefully it
  matches today.
- **Do not restate `check-success` conditions in `auto_merge_conditions`.**
- **Do not host the gate in a path-filtered job.** It is the one gate whose
  subject matter guarantees the filter excludes it.
- **Do not raise `batch_size` to drain a backlog.** It re-introduces the
  throwaway draft, so the backlog is then draining at two CI runs per merge.

---

## Fleet status (2026-08-14)

Every repository in the fleet that runs a Mergify queue has been converted, or
has the conversion open as a draft pull request: DataRetrival (#2384, landed),
Apigee-Portal #2329, IntegrateIT #7778, Specaria-Platform #3225, Print-Server
#1833, CarListPrice #14, SOAP-To-REST #2036, entity-platform #269, Atlas #1945,
Telnet-Emulation #710, mot-face-blur #56.
