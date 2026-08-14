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

The self-test plants 34 fixtures and asserts, for each one, the **set of check
ids** it raises — not how many diagnostics appeared. A count-only assertion is
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
document that does not load.

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

The paths come from a **real YAML parser** (`python3` + PyYAML, which the gate
pip-installs if the runner lacks it), and that is not an optimization — it is
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
- **Do not raise `batch_size` to drain a backlog.** It re-introduces the
  throwaway draft, so the backlog is then draining at two CI runs per merge.

---

## Fleet status (2026-08-14)

Every repository in the fleet that runs a Mergify queue has been converted, or
has the conversion open as a draft pull request: DataRetrival (#2384, landed),
Apigee-Portal #2329, IntegrateIT #7778, Specaria-Platform #3225, Print-Server
#1833, CarListPrice #14, SOAP-To-REST #2036, entity-platform #269, Atlas #1945,
Telnet-Emulation #710, mot-face-blur #56.
