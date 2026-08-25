# The merge lane — the queue, inside the repository

This is the fleet's merge automation, and it replaces Mergify. It is the
copy-in configuration for every consuming repository, and it is applied here
first: `ci-runner-infra` runs the lane it publishes.

## Why we left Mergify

Not on preference. On one number that never came down.

**A green pull request took between 9 and 25 minutes to merge, and sometimes
hours.** Measured on this repository on 2026-08-23, from the last required check
reporting success to Mergify acting:

| PR | idle |
|---|---|
| #332 | 8m55s |
| #328 | 11m06s |
| #326 | 17m24s |
| #333 | 20m01s |

The cause was never Mergify being slow to think. It reacts to its **own** merges
in 13–14 seconds, measured three times out of three — the next queue entry's CI
run was created 13 seconds after the previous pull request merged. It knows
about that internally. Everything else it learns over a **webhook**, and a
`check_run.completed` that is missed or late leaves a fully green pull request
sitting on *"Your merge queue conditions are under evaluation"* until a periodic
re-evaluation minutes later. Nothing goes red. Nothing says so.

We tried to fix it from outside. `mergify-nudge` waited out a grace period,
asked GitHub whether any Mergify check-run had been touched since CI finished,
and posted `@mergifyio refresh` when the answer was no. It worked — it capped
the stall at about three and a half minutes — and it could not do better,
because **a nudge cannot be sent before you have waited long enough to know a
nudge is needed**. Its own cost was a runner **sleeping on the clock** for up to
2m30s on every CI completion, which is free on a public repository and billed on
every private one.

### The second cost, which was worse

Mergify validates a queued pull request on a **throwaway draft** pushed to
`mergify/merge-queue/<sha>`, unless the queue is serial, unbatched, retry-free
and single-step. Every one of those drafts is a second full CI run.

On one consumer repository over 2026-08-22..23, **87 of 122 queue-draft runs
failed** — almost all at `Set up runner`, `Initialize containers` or `Complete
runner`. That is the fleet, not the diff. A Mergify dequeue is terminal, so each
of those failures parked a good pull request until a human typed
`@mergifyio queue`. Two pull requests that were green, unconflicted and
unreviewed took **17h11m** and **18h00m** to merge.

The speculative-draft model took the fleet's flakiness and multiplied it by the
queue depth. That is the part no amount of tuning was going to fix.

### Why not GitHub's own merge queue

It is not available to us. Merge queue requires an **organization-owned**
repository; personal accounts are excluded, public ones included. Even moving to
a free organization would only cover `ci-runner-infra` — the other 23
repositories are private, and private repositories need Enterprise Cloud. It
would also reintroduce the second full CI run, since GitHub always builds the
`merge_group` ref.

So: Mergify, GitHub, or ours. Only one of the three was available and fast.

## What the lane is

A `workflow_run` workflow in the repository itself. **GitHub does not need to be
told that CI finished — it finished it.** The dispatch is internal, there is no
third party in the path, and the merge happens in the run that observes the
green.

When the lane acquires its lock it recomputes the world and acts on one pull
request:

1. List open, non-draft pull requests on the base.
2. For each, read the facts: mergeability, labels, how far behind the base it
   is, and the state of every **required check on the head sha**.
3. Ask [`merge-lane-decision.sh`](../scripts/ci/merge-lane-decision.sh) for a
   verdict.
4. Rank the actionable ones and take the best.

| verdict | meaning |
|---|---|
| `merge:ready` | green, current with the base — squash it |
| `update:behind` | green, but the base moved — update it in place, let its own CI re-run |
| `drop:budget-exceeded` | checks never concluded within the budget — release it and say so |
| `wait:*` | the answer is not known yet — leave it alone |
| `skip:*` | not a candidate |

### The four invariants

**A. Green means green on the sha being merged.** Not green recently, not green
on an earlier push. The merge call itself passes `sha=`, so a push that lands
mid-pass makes the call *fail* rather than merge code nothing verified.

**B. A missing required check is not a passing one.** Rename a job and the lane
counts its check as missing and **stops**, rather than silently ungating.
`merge-lane.selftest.sh` also asserts every name in the caller against the job
names in `ci.yml`, so the rename fails on the pull request that does it.

**C. A base that moved must be re-validated.** This is the entire reason a queue
exists rather than plain auto-merge: it is what catches two sessions whose
changes pass alone and break together.

**D. Validation happens in place.** No speculative draft, no
`merge-queue/<sha>`, no second CI run for a pull request whose base never moved
— which is the common case. One whose base did move gets exactly one re-run, on
its own branch, where a failure is legible and is the author's to read.

### Serialisation

GitHub's `concurrency` holds one running run and one pending run; a third
arrival cancels the pending one. That is **mutual exclusion, not a FIFO**, and
using it as a queue would silently drop entries.

It does not need to be a queue. The lane keeps no list — it recomputes the
candidate set every time it acquires the lock — so a pending run that gets
cancelled loses nothing. `cancel-in-progress: false` is load-bearing: cancelling
a lane mid-merge is how a branch gets updated and then abandoned.

## What you must provide: a second GitHub App

The lane authenticates as a **GitHub App**, and this is not a convenience.

> A merge or a branch update performed with the built-in `GITHUB_TOKEN`
> **triggers no further workflow.** The re-run the lane depends on would never
> start, and every release and deploy workflow that fires on a push to the
> default branch would silently stop firing. It does not fail. It quietly does
> half the job.

It is **deliberately not the fleet's runner App**.
[`github-app-permissions.md`](github-app-permissions.md) argues that that App
must never hold `Contents: write`, and that argument is still correct — merge
authority gets its own identity and its own blast radius. The fleet is already
more than one App, so this is the established pattern.

| Permission | Level | Why |
|---|---|---|
| Metadata | Read | mandatory for every App |
| Contents | Read & write | the squash merge, and the branch update |
| Pull requests | Read & write | list, read mergeability, comment on a release |
| Checks | Read | the required-check state on the head sha |

Everything in `github-app-permissions.md` about **how grants work** applies
unchanged, and is the usual way this goes wrong: a permission added to an App is
a *request* until the installation owner accepts it, and until then the App
behaves exactly as though it had never been added.

Store the credentials as repository (or account-level) secrets:
`MERGE_APP_ID` and `MERGE_APP_PRIVATE_KEY`.

## Wiring a repository

One file. The reusable half lives here; `workflow_call` is the only trigger a
callee may declare, so the `workflow_run` half is necessarily yours.

```yaml
name: Merge lane

on:
  workflow_run:
    workflows: [CI]          # must match your CI workflow's `name:` exactly
    types: [completed]
  schedule:
    - cron: '*/15 * * * *'   # the backstop — see below
  workflow_dispatch:

permissions:
  contents: read

jobs:
  lane:
    # Off until an operator confirms the App secrets exist — a dry run still
    # mints the token, so without this the job is red on every CI completion.
    if: vars.MERGE_LANE_ENABLED == 'true'
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@22549049f59ee3c67f04221c6b1a17d72ec6d83a # v5.53.0
    permissions:
      contents: read
    with:
      base: main
      required-checks: |
        Your required check
        Your other required check
      # A LINUX label. `self-hosted` alone matches the fleet's Windows pool too,
      # and the lane is bash: `mapfile`, `date -u -d`, `jq`. Use the same
      # Linux-scoped label your CI jobs use. See "minutes", below.
      #
      # NOT A YAML SEQUENCE. This is a `type: string` input, so
      # `runs-on: [self-hosted, linux]` here is a parse error and the workflow
      # never starts — "A sequence was not expected". One label as a bare
      # string, or several as a JSON array inside a string:
      # `runs-on: '["self-hosted", "linux"]'`.
      runs-on: your-linux-pool-label
      inflight-budget-seconds: 1800
      # Optional. An issue whose body the lane rewrites with the queue after
      # every run — see "Seeing the queue". Unset means the job summary only.
      status-issue: ${{ vars.MERGE_LANE_STATUS_ISSUE }}
      dry-run: ${{ vars.MERGE_LANE_ARMED != 'true' }}
    secrets:
      app-id: ${{ secrets.MERGE_APP_ID }}
      app-private-key: ${{ secrets.MERGE_APP_PRIVATE_KEY }}
```

> **`v5.53.0` is the first release you may pin.** `v5.52.0` also contains
> `merge-lane.yml` and you must not use it: the driver in it loses the head sha
> of any pull request that carries no label, which is nearly all of them, so the
> lane merges nothing and reports it as an unreadable API comparison — the same
> line, every fifteen minutes, forever. Fixed in #409, released in `v5.53.0`.
>
> **There is one sha, and you do not repeat it.** A reusable workflow's
> `actions/checkout` clones the CALLER, so the lane does have to be told where
> its driver lives — but only the *repository*, not the ref. The ref defaults to
> `github.job_workflow_sha`, the commit this workflow file was called at, which
> is by definition the sha your `uses:` line resolved to.
>
> Callers used to repeat that sha as `implementation-ref`, and that is now
> wrong rather than merely redundant. Two shas that must agree is a rule a
> person has to keep, and the bot we delegated updates to cannot keep it:
> Dependabot rewrites a `uses:` line and cannot see an input value, so an
> automatic bump moved the workflow and left the driver a release behind. If you
> are migrating an older caller, **delete the `implementation-ref` line**.
>
> **Pin the COMMIT, not the tag object.** This repository's release tags are
> *annotated*, so `git/ref/tags/v5.54.0` gives you the sha of the tag object and
> the commit is one dereference further in. The contents API dereferences that
> for you, so a file read back at the tag-object sha looks perfectly correct —
> but the Actions resolver does not, and `uses: …@<tag-object-sha>` resolves to
> nothing. The run fails as `startup_failure` with no jobs and no annotation,
> which points at your caller rather than at the pin. Read it as:
>
> ```bash
> gh api repos/Dima-Spectorr/ci-runner-infra/git/ref/tags/v5.54.0 --jq '.object | if .type == "tag" then .url else .sha end'
> ```
>
> A `"tag"` type means one more hop through `git/tags/<sha>`; `gh api
> repos/OWNER/ci-runner-infra/commits/<sha>` returning 422 is the cheap check
> that whatever you are about to paste is a commit at all.

**The schedule is a backstop, not the mechanism.** A merge moves the base, which
makes every other open pull request one commit behind — and that is not a CI
completion, so nothing would dispatch the lane to notice. It is also what
recovers a missed dispatch. Do not drop it.

**`required-checks` must name checks that exist.** A name matching nothing is
counted as missing and blocks every merge. That is the safe direction, but it is
a total stop, so keep it in step with your CI.

### Seeing the queue

Mergify had a dashboard, and losing it without replacing it would be a real
regression — "what is the queue doing" is the question you ask exactly when
something is wrong.

The lane answers it differently, and the difference is worth understanding
before you go looking for a list. **There is no stored queue.** The lane
recomputes the candidate set from the API on every pass; that is what makes a
cancelled pending run cost nothing, and it means there is no position-in-a-line
to display. What it publishes instead is the **verdict it reached for every open
pull request on the pass that just ran** — which is strictly more useful than a
position, because it says what each one is waiting for.

Two surfaces, and the first is not optional:

- **The job summary on every lane run.** Free, native, no API call and no
  permission. Open the newest `Merge lane` run in the Actions tab and the table
  is on the run page. This is always written.
- **A pinned issue, if you want a bookmark.** Set `MERGE_LANE_STATUS_ISSUE` to
  the number of an issue and the lane **rewrites its body** after every run. The
  body, never a comment: an edit notifies nobody, where a comment every fifteen
  minutes would make the issue unreadable within a day. Create the issue, pin
  it, set the variable — no code change. It must be a plain **issue**: issues
  and pull requests share one number space, so the lane confirms what the
  number points at before writing and refuses rather than overwrite a pull
  request's description.

The table is ordered by the lane's own ranking, so the **top row is the pull
request the next action would touch**. Below the actionable rows come the ones
the lane could not read, then the ones it deliberately skipped. Everything the
pass saw gets a row, including the failures: a view that quietly omitted the
pull requests the lane choked on would render "the queue is empty" over "the
lane is broken", and that exact confusion cost an hour during the cutover.

> **The pinned issue needs `Issues: write` on the merge App**, which GitHub
> treats as a **separate** permission from `Pull requests: write` even though a
> pull request is an issue — the lane's release comment goes through the
> pull-request grant and will keep working without this one. A permission added
> to an already-installed App stays **pending until the installation owner
> accepts it** in the repository's app settings. Until then the lane logs a
> warning once per run and keeps merging: a queue view that cannot be published
> is not a reason to stop merging.

### Minutes

`ci-runner-infra` is **public**, so GitHub-hosted minutes are free and unmetered
— and it deliberately runs its lane on `ubuntu-latest` for the same reason
`ci.yml` does: *the repository that defines the self-hosted fleet must not need
the fleet to be healthy in order to merge a fix to the fleet.*

Every other repository in the fleet is **private**, where GitHub-hosted minutes
are billed. Those should pass `runs-on: self-hosted`: fleet minutes are free and
unmetered, and the lane is a handful of API calls with **no sleeps**, so it holds
a slot for seconds rather than the minutes `mergify-nudge` spent asleep.

### The pool images do not ship `gh`

GitHub-hosted images carry the CLI; the fleet's self-hosted images do not. That
matters more than a missing tool usually does, because the lane reads **every**
fact through `gh api ... || true` — so a missing binary reads as *no facts
available*, the lane concludes there is nothing to merge, and the job goes
**green**. Seven repositories reported a healthy lane for a morning while
merging nothing.

Two things fix it, and both are in the workflow already:

- [`scripts/ci/ensure-gh.sh`](../scripts/ci/ensure-gh.sh) runs before the token
  step and installs the CLI when it is absent — by **digest**, not by tag, into
  `$RUNNER_TEMP/bin` rather than `/usr/local/bin`, because the pool runs several
  slots per host as an unprivileged user. On a host that already has `gh` it
  exits immediately.
- Failing to read the tip of the base is now **fatal**. Every other early return
  in the driver means *looked, found nothing*; that one means *could not look at
  all*, and the two must never render identically.

Baking `gh` into the pool image would make the first of those a no-op. Until
then, do not remove the step: a lane that cannot read is the one failure mode
this design cannot tolerate quietly.

## Landing it: three steps, not one

A `workflow_run` workflow **cannot run on the pull request that adds it** —
GitHub dispatches it from the default branch only, so the first live execution
is the first CI completion after it merges. That is a property of the trigger,
not a gap in the testing, and it dictates the order.

There are **two** repository variables, and they are separate on purpose.
`MERGE_LANE_ENABLED` says the App exists; `MERGE_LANE_ARMED` says it may act.
A dry run still mints the App token and reads the API, so a caller left on
before the secrets are in place fails on every CI completion — a red that means
"setup unfinished" and is indistinguishable from a red that means "the lane is
broken". Conflating the two into one switch would mean the only way to see a
verdict is to grant merge authority first.

1. **Merge the lane, switched off, alongside Mergify.** The caller is gated on
   `MERGE_LANE_ENABLED`, so nothing runs and nothing goes red.
2. **Provision the App and its secrets**, then set `MERGE_LANE_ENABLED=true`.
   `dry-run` is still on: every verdict is computed and logged, nothing is
   acted on.
3. **Read real verdicts, then arm it.** Set `MERGE_LANE_ARMED=true`. Confirm a
   real merge and a real `update:behind`. Neither step needs a code change, so
   no pull request has to go through the very queue being replaced.
4. **Only then remove Mergify.** Not before: until the lane has merged
   something, removing Mergify leaves the repository with no automation at all.
5. **Wire the branch reaper and arm it too.** Mergify's `delete_head_branch`
   goes away with `.mergify.yml`, so a repository cut over and left there stops
   cleaning up merged branches entirely — the one capability regression this
   migration can cause. The reaper needs no new App permission and no new
   secret; it reuses `MERGE_LANE_ENABLED` plus its own `BRANCH_REAPER_ARMED`.
   Procedure in [the branch reaper](branch-reaper.md#enabling-it-on-a-repository).
   **A cutover is not finished until the reaper is armed**, not merely landed:
   a repository sitting in dry run accumulates branches exactly like one with
   no reaper at all, and looks configured while doing it.

### Removing Mergify from a repository

Once the lane has merged in anger:

- delete `.mergify.yml`
- delete `.github/workflows/mergify-nudge.yml` (the caller) and any repository-
  specific relatives — `queue-stall-check.yml`, `mergify-stale-context.yml`
- remove the Mergify GitHub App installation
- drop any Mergify-specific CI gates that no longer describe anything

Track the fleet rollout in GitHub Issues, one per repository, not in a file
here.

## What the lane does not carry over

Stated plainly, because a migration that quietly drops a capability is how you
find out about it later.

- **Batching and bisection.** Not implemented. `batch_size` was 1 in every
  repository in the fleet, so nothing in production depended on it.
- **`@mergifyio` commands.** Obsolete rather than missing: `refresh` and
  `requeue` existed to resynchronise a third party that had fallen behind, and
  there is no longer a third party. The manual equivalent is
  `workflow_dispatch`.
- **A hosted UI.** Replaced rather than dropped: the job summary on every lane
  run, plus an optional pinned issue kept current. See
  [Seeing the queue](#seeing-the-queue). What is genuinely gone is the
  cross-repository view — each repository's lane shows its own queue only.
- **Deleting the head branch after a merge.** Mergify's `delete_head_branch`
  ran at merge time; the lane leaves the branch. That is deliberate — a branch
  deleted seconds after a squash merge is a branch nobody can cherry-pick from
  — and it is picked up instead by [the branch reaper](branch-reaper.md), which
  sweeps daily and only touches branches merged at least fourteen days ago.

And one thing it adds that neither Mergify's serial queue nor GitHub's native
queue can express: **priority**. A label like `merge-lane/priority-10` orders
the lane ahead of the default 50, so a docs-only fix does not queue behind an
infrastructure change.

## Where the logic lives, and why it is testable

Neither the workflow nor the API driver can be exercised by the pull request
that changes them. So nothing that decides anything lives in either:

| file | what it is |
|---|---|
| [`merge-lane-decision.sh`](../scripts/ci/merge-lane-decision.sh) | every decision, as pure functions |
| [`merge-lane-decision.selftest.sh`](../scripts/ci/merge-lane-decision.selftest.sh) | 55 cases, weighted towards the arms that merge |
| [`merge-lane.sh`](../scripts/ci/merge-lane.sh) | the API calls, deliberately dull |
| [`merge-lane.selftest.sh`](../scripts/ci/merge-lane.selftest.sh) | 36 structural assertions with mutations |
| [`merge-lane.yml`](../.github/workflows/merge-lane.yml) | the reusable callee |
| [`merge-lane-self.yml`](../.github/workflows/merge-lane-self.yml) | this repository's caller |

The structural test asserts on the *text*, with mutations, because a property
silently removed has to fail a check that can actually run on a pull request.
The alternative is finding out when the lane merges something it should not
have.
