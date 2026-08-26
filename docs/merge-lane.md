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

When the lane acquires its lock it recomputes the world and acts on the best
candidate it finds — on a base that requires branches to be up to date, exactly
one, because the merge invalidates everything else it just read; on one that
does not, up to `max-actions` of them, for the reasons under
[Behind the base is only a problem if the base says so](#behind-the-base-is-only-a-problem-if-the-base-says-so):

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
| Commit statuses | Read | the OTHER surface a required context can live on |

**Commit statuses is not optional padding, and leaving it out has a measured
cost.** A required context may be a legacy commit status rather than a
check-run, so the lane reads both surfaces. Without this grant the status read
returns `403` — and until 2026-08-25 the driver swallowed that failure into the
same stream it parsed the check-runs from, so the aggregation collapsed and
**every required check on a green pull request counted as FAILED**. Six
repositories reported `skip:red failed=2` over two check-runs that were both
`success`. The driver now fails loudly instead, but a lane without this
permission still cannot satisfy a required check that is a commit status, and
will hold every such pull request forever.

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
  # Only if you gate on a label (`MERGE_LANE_REQUIRE_LABEL`). Labelling is the
  # last thing to happen on a pull request whose CI is already green, and
  # nothing else dispatches the lane for it. See "A label applied after the
  # green", below.
  pull_request_target:
    types: [labeled, ready_for_review]
  workflow_dispatch:

permissions:
  contents: read

# Serialization is the point, not a concession: two lane runs read the same list
# of open pull requests and could both act on it. The marker is what
# `check-workflow-concurrency.sh` requires in exchange for a constant group key
# — it accepts that a third request evicts the pending run, which costs nothing
# here because the lane re-reads live state on the next CI completion or cron.
# concurrency-serialization: intentional — one merge decision at a time
concurrency:
  group: merge-lane
  cancel-in-progress: false

jobs:
  lane:
    # Off until an operator confirms the App secrets exist — a dry run still
    # mints the token, so without this the job is red on every CI completion.
    if: vars.MERGE_LANE_ENABLED == 'true'
    # `check-runner-policy.sh` RUNNER7 refuses to decide the runner scope and
    # timeouts of a workflow it cannot read, and this one is in another
    # repository. The marker records that a human read it — one job,
    # `timeout-minutes: 15`, `contents: read`, and a `runs-on` YOUR file
    # supplies — and points at the issue where that reading lives. Open one;
    # the gate rejects a marker without an issue number, on purpose.
    # remote-reusable-allowed(Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml, #<issue>): read and recorded there
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@7dbfb9a5d0ab96f2a05b417024721a621ab67796 # v5.66.0
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
      # How long the lane may spend WALKING, as opposed to how long a pull
      # request may sit in flight. It must expire before the job's
      # `timeout-minutes` does — see "What a pass costs".
      pass-budget-seconds: 600
      # OPT-IN FOR THE FIRST ARMED WEEK. An armed lane merges every open pull
      # request that is green, and a repository migrating off Mergify is holding
      # a backlog of exactly those — arming wide open merges months of stale work
      # in one pass.
      #
      # THE FALLBACK IS THE LABEL, NOT EMPTY. `${{ vars.X }}` renders as an empty
      # string when the variable is unset, mistyped, or cleared later, and empty
      # means "no label required" — so wiring it bare fails OPEN, and a forgotten
      # setting releases the backlog. Widening is a pull request, deliberately.
      require-label: ${{ vars.MERGE_LANE_REQUIRE_LABEL || 'ready-to-merge' }}
      # Optional. An issue whose body the lane rewrites with the queue after
      # every run — see "Seeing the queue". Unset means the job summary only.
      status-issue: ${{ vars.MERGE_LANE_STATUS_ISSUE }}
      dry-run: ${{ vars.MERGE_LANE_ARMED != 'true' }}
    secrets:
      app-id: ${{ secrets.MERGE_APP_ID }}
      app-private-key: ${{ secrets.MERGE_APP_PRIVATE_KEY }}
```

> **The two markers in that example are not decoration, and admin merge will
> not tell you so.** A caller without them is rejected by gates several repos in
> this fleet already vendor: `check-workflow-concurrency.sh` wants the top-level
> `concurrency:` block, and `check-runner-policy.sh` RUNNER7 wants a
> `remote-reusable-allowed` marker naming an issue, because it cannot read a
> callee that lives here. The original cutover landed by admin merge — the one
> path that skips those gates — so thirteen repositories reported a healthy
> setup and then failed their next ordinary pull request. Open the issue, paste
> its number into the marker, and the first PR after onboarding is green.
>
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

**A required check that SKIPPED counts as satisfied**, which is what GitHub's own
branch protection does with one and what Mergify did. A job behind a path filter
did not run because the diff never reached it. The lane's first position was the
opposite, and the fleet showed why that is wrong: on 2026-08-25 a pull request
touching one Markdown file skipped `Web production build` on Apigee-Portal and
*both* required jobs on CarListPrice, and the lane held both repositories on a
change nothing could have broken while GitHub reported them mergeable — nothing
red, nothing merging, which is the Mergify failure this lane exists to end.

`neutral` is still not a pass: a check that ran and declined to judge has said
something different from one that never had to run. And a skipped requirement is
never silent — the names are printed with the verdict, so a job that skipped
because someone broke its `if:` stays visible instead of being absorbed.

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
unmetered, and the lane holds a slot for as long as the walk takes — seconds on
a quiet base, minutes on a busy one, and never more than `pass-budget-seconds`.
That is still not the runner-hour `mergify-nudge` spent deliberately asleep, but
it is not free either, which is the next section.

### What a pass costs, and why it has a deadline

A pass reads the open list once, then spends per candidate: a detail read, a
base comparison, a head-commit read, and two paginated check reads — five or six
calls, plus up to four seconds of sleep when GitHub has not computed
mergeability yet. **The label gate is applied to the list read**, before any of
that, so a pull request that is not a candidate costs nothing at all. That
ordering is the whole of issue #444 and it is asserted by the self-test; if it
regresses, the cost of a pass goes back to tracking the number of open pull
requests in the repository rather than the number the lane could act on.

It matters because the job has a `timeout-minutes` ceiling, and:

> **A `timeout-minutes` kill is reported by GitHub as `cancelled`, not as
> `failure`.**

which is also what an operator pressing *Cancel* produces, and what the
`concurrency` group produces when a third arrival evicts the pending run. There
is no annotation, no job summary, and no queue update. A lane dying of its own
weight is therefore indistinguishable from a lane behaving correctly under load.

Measured on `IntegrateIT` on 2026-08-25, with roughly thirty-five open pull
requests: **thirty consecutive runs, none of them reaching a merge, every one
reported `cancelled`.** #11682 was green, labelled and clean throughout and had
to be merged by hand.

So the lane carries a deadline of its own that expires first. When
`pass-budget-seconds` runs out mid-walk the lane stops between candidates, still
acts on the best one it read, and writes a warning naming *how many of how many*
it got through — and every pull request it did not reach gets a
`wait:not-read-this-pass` row in the queue snapshot, because a candidate simply
missing from the table reads as "not in the queue", which nobody can catch. The
run then ends **green**: a repository with more open pull requests than one pass
can walk is busy, not broken, and the next CI completion or cron tick starts a
fresh walk.

If you see that warning regularly, the answers in order are: narrow the
candidate set with `require-label`, close what is stale, or raise
`pass-budget-seconds` **together with** the job's `timeout-minutes`. The
self-test refuses a budget that does not leave the lane two minutes to publish
its summary inside the ceiling — a run that merges and then reports nothing
about it is worse than one that merges nothing.

### A label applied after the green

The two triggers above answer *CI finished* and *time passed*. Neither answers
**a human labelled it**, and under `MERGE_LANE_REQUIRE_LABEL` that is the event
that arms a pull request — routinely the LAST thing to happen, because the
reviewer labels once the checks are already green.

So the ordinary sequence is: CI completes, the lane runs, logs
`skip:no-label`, and stops. The label arrives a minute later and dispatches
nothing. The pull request is then green, labelled, `mergeable_state: clean`,
and waiting on the schedule — which reads as a broken lane, because every
visible signal says it should have merged. On `*/15` that is a quarter of an
hour and merely annoying. On the daily cron a repository on hosted runners uses
to stay cheap, it is **up to 24 hours**, which is worse than the Mergify
latency this lane was built to remove.

`pull_request_target: [labeled, ready_for_review]` closes it, and it is the
cheap fix rather than the thorough one on purpose: it dispatches once per label
event instead of every fifteen minutes forever, so a repository paying for
hosted minutes gets seconds of latency for a few seconds of billing. Tightening
the cron instead buys the same latency at 96 runs a day.

Two things make `pull_request_target` safe here, and both must stay true:

- **The lane never checks out the pull request.** Its one `actions/checkout`
  clones `implementation-repository` at `github.job_workflow_sha` — this
  repository, at the pinned release. No code from the pull request is read,
  let alone run, so the usual `pull_request_target` hazard (a privileged token
  handed to a fork's tree) has nothing to act on.
- **Labelling requires write access.** A fork author cannot dispatch this;
  only someone who could already merge can.

`check-runner-policy.sh` RUNNER4 sees `pull_request_target` and marks the
workflow fork-reachable, which means any **fleet-reachable** job in it needs a
fork guard. The repositories that need this trigger are the ones on
`ubuntu-latest`, so nothing in the file is fleet-reachable and the rule is
already satisfied. If you add the trigger to a lane running on a pool label,
RUNNER4 will stop you, and it is right to.

### Behind the base is only a problem if the base says so

The lane used to refuse to merge anything that was behind its base, full stop,
and update the branch instead. That is correct on a base that sets GitHub's
**strict** required-status-checks policy — "require branches to be up to date
before merging" — and it is a self-inflicted wound on a base that does not.

On a non-strict base GitHub will merge a branch that is behind. Updating it
anyway:

* throws away a green suite and spends a **full CI run** rebuilding the same
  answer,
* moves the head sha, so the pull request needs a fresh label event or CI
  completion to be looked at again, and
* loses the race on a busy repository — the base moves again before the
  re-run lands, so the pull request goes straight back to being behind and
  **never converges**.

Measured on IntegrateIT, 2026-08-25: about twenty of roughly seventy open pull
requests sat in `update:behind` on every pass of a base whose ruleset reported
`strict_required_status_checks_policy: false`. The lane spent its entire
`max-actions` budget updating branches that had been mergeable the whole time,
merged nothing, and — because each pass re-reads the world once per action —
ran for fourteen and a half minutes against a `timeout-minutes: 15`. The
symptom an operator sees is "lots of green pull requests, nothing merging", and
every individual verdict in the log looks reasonable.

So the lane now **asks the base** rather than assuming. Once per run it reads
`repos/{owner}/{repo}/rules/branches/{base}` — the *effective* rules for that
branch, so one call covers every ruleset that matches it, plus classic branch
protection — and only emits `update:behind` when that base is strict. The log
says which answer it got:

```
lane: main does not require a branch to be up to date — behind still merges
```

It **fails closed**: an unreadable answer is treated as strict, because being
needlessly strict costs one CI run while being wrongly permissive asks GitHub
for a merge it will refuse. The `require-up-to-date` input pins it to `true` or
`false` for a base whose rules the lane's token cannot read; leave it at `auto`
otherwise. Auto-detection is deliberate rather than a per-repository input: a
copied setting is a second statement of a fact GitHub already publishes, and
this lane has already been bitten once by two lists that had to be kept equal by
hand (see the phantom required check, above).

If you *want* linear history, set the policy on the branch. The lane will see
it and go back to updating.

#### What a non-strict base also buys: a pass that finishes

The same answer changes how much work a pass has to do, and on a large backlog
that is the difference between draining and stalling.

The lane normally acts on **one** candidate and then reads the entire world
again, because a merge moves the base and every `behind_by` it computed a moment
ago is now stale. With `max-actions: 4` that is five full walks of the open pull
request list per run. On a repository with ~86 open candidates each walk is
minutes, the run hits `timeout-minutes: 15` part-way through, and the
`concurrency` group cancels whatever queued behind it — a lane that looks dead
while every individual verdict in its log is correct.

On a base that does **not** require a branch to be up to date, the re-walk buys
nothing:

- a merge cannot make another pull request's required checks less green — they
  were reported against *its* head, which the merge did not touch;
- being behind is not a condition the repository imposes, so a moved base
  changes no verdict;
- the one thing a merge *can* change is whether another branch still applies
  cleanly, and the merge API refuses that itself with a `405`.

So on a non-strict base the lane spends its whole `max-actions` budget from a
single reading of the ranking, stopping the moment GitHub refuses anything —
that refusal is the signal the world moved, and the next pass reads the world it
moved to. On a strict base the behaviour is unchanged: one action, then re-read.

For the same reason the lane **skips the `behind_by` comparison entirely** when
the base is non-strict — one API call per pull request per pass that no verdict
consults. The queue table then shows `n/a` in the *behind* column rather than
`0`, because "not asked" and "up to date" are different facts and the table is
what an operator reads to decide whether the lane is working.

#### What a non-strict base costs, and the gate that bounds it

Everything above says what a merge *cannot* break. There is one thing it can,
and it is worth stating without hedging: **two pull requests that touch
different files can each be green alone and broken together.** Neither one's
checks were rebuilt against the other, so nothing in the lane, and nothing in
GitHub, notices before both are in.

This is a property of the base being non-strict, not of batching. Merging those
same two an hour apart, without re-running either one's checks, lands exactly
the same commit. Batching changes how *soon* it surfaces, not whether it can.
The only thing that removes it is turning
`strict_required_status_checks_policy` on for the base — the lane reads that and
reverts to one-action-then-re-read by itself — and the price is a full CI run
per open pull request per merge. On a repository with 90 open pull requests that
is thousands of Actions minutes to drain a backlog once.

So the lane does not try to prevent it. It **bounds** it, with two things:

1. **`max-actions` is the blast radius.** A pass merges at most that many before
   the world is read again, so it is also the most that can land on top of a
   break before anything can notice. Raise it to drain a backlog; bring it back
   down for steady state.
2. **The lane refuses to merge onto a base that is already red.** Before it
   reads a single pull request, every pass reads the *required checks on the
   base tip* — the same read it does on a head — and if one of them has
   **failed**, the pass stops there. The reason is logged as a workflow
   annotation and written across the top of the queue snapshot, and the lane
   resumes on its own as soon as those checks pass. So a semantic conflict costs
   one batch, not the whole backlog.

**The gate fails open, deliberately, and it is only as good as your post-merge
CI.** Only a definite failure halts it. A check that is *missing* or *pending*
on the base tip does not, because most repositories run their required checks on
`pull_request` only — every required check is then permanently absent on the
base tip, and a gate that halted on that would deadlock the lane everywhere the
day it shipped. An unreadable check surface lands in the same arm for the same
reason.

Which means: **if nothing runs the required checks on a push to the base, there
is nothing on the tip to read and the gate is inert.** To arm it, give the base
a post-merge run of the same checks:

```yaml
on:
  pull_request:
  push:
    branches: [main]
```

on whichever workflow emits the contexts named in `required-checks`. That is one
CI run per merge, against a strict base's one run per *open pull request* per
merge — the cheap end of the trade, and the whole reason the gate is shaped this
way.

**When one run per merge is still too much, narrow what the gate reads.** On
IntegrateIT the required `ci` takes about thirty minutes, and at the rate the
lane now drains a backlog that is roughly twenty half-hour runs an hour to power
a gate that asks a single yes/no question. `base-health-checks` points the gate
at a different, cheaper list:

```yaml
    with:
      required-checks: |
        ci
        generic-binary
      # What gates a MERGE is above. What the base-health gate reads is this: a
      # fast post-merge job, not the full suite.
      base-health-checks: |
        main-health
```

`required-checks` goes on gating the merges themselves; only the base-tip read
changes. Leave it unset and the gate reads `required-checks`, which is the strict
reading and the right default for a repository that has not thought about it.

One warning, because it points the other way from everything else in the lane: a
name here that matches nothing counts as **missing**, and missing does not halt —
this gate fails open. A typo will not deadlock the lane; it will quietly disarm
the gate. Read the queue snapshot after changing it.

#### And the half that runs before the lane: `pr-guard`

The base-health gate is a backstop — it acts after something has already
landed. The two things a non-strict base stops GitHub from telling an author
*while they can still do something about it* are handled by a separate reusable
workflow, [`pr-guard.yml`](../.github/workflows/pr-guard.yml):

1. **Is this branch looking at the current base?** `compare/<base>...<head>`
   gives `behind_by`; past `max-behind` the guard says so. A branch that is
   twenty commits behind has green checks that were reported against a world
   that no longer exists, and on a non-strict base nothing else will mention it.
2. **Is anyone else rewriting these files?** The changed-file list of this pull
   request, intersected with the changed-file list of every other open one
   against the same base. Overlaps are reported as a table naming the other pull
   request and the shared paths.

It runs on `pull_request` — `opened`, `synchronize`, `reopened`,
`ready_for_review` — so the answer is re-computed on every push, and it leaves
**one** comment that it edits rather than a new one each time. Drafts are
skipped. It needs no App: it writes nothing to a branch, so the caller's own
`GITHUB_TOKEN` with `pull-requests: write` is enough.

**Advisory by default, and both switches are separate.** A repository turning
this on has a backlog of pull requests that were all opened before the rule
existed, and a gate whose first act is to fail every one of them is a gate
everyone learns to ignore. So `enforce-freshness` and `enforce-overlap` each
default to `false`: advise while you drain, enforce once you are current.
`enforce-overlap` is the harsher of the two and should stay off in most
repositories — a shared lockfile, a changelog or a barrel file makes overlap
routine, and the useful output there is the comment naming who else is in the
file, not a red check.

**`max-behind: 0` is usually the wrong number.** It is the strict reading, and
on a base that merges every few minutes it marks nearly every open pull request
the moment anything lands: true, and useless as a signal. A small non-zero
tolerance asks the question people actually mean.

**What it cannot see** is the semantic conflict: two pull requests that break
each other through entirely separate files share no path, and the guard reports
them as distinct. That is deliberate — claiming otherwise would make a green
"no overlap" read as "safe to land". That case is what the base-health gate
above bounds, after the fact.

A minimal caller. The `uses:` line is deliberately not written out here: take the
one from the merge-lane caller above — same tag, same sha, both workflows ship
from the same release — and change the filename to `pr-guard.yml`. One pin to
keep current instead of two that drift apart, which is the same reasoning as
`implementation-ref`.

```yaml
name: PR guard
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
permissions:
  contents: read
# NOT `pr-guard-<number>`. See below — that is the callee's own group name.
concurrency:
  group: pr-guard-caller-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  guard:
    # uses: …/.github/workflows/pr-guard.yml@<the sha from the lane example>
    permissions:
      contents: read
      pull-requests: write
    with:
      runs-on: my-pool-label   # a private repository: self-hosted minutes are not billed
      max-behind: 10
      enforce-freshness: false
      enforce-overlap: false
```

**Do not give the caller the callee's concurrency group.** `pr-guard.yml`
declares `pr-guard-job-<number>` on its own job, and that expression is evaluated
in *your* repository's context. Several repositories require every workflow to
declare a top-level `concurrency:` — and the obvious name to reach for there is
`pr-guard-<number>`, which is one rename away from what the callee used to use.
When the two groups match and one of them cancels in progress, the called job
cancels the run that called it. What you see is a job with **zero steps, no log,
no annotation, and `completed_at` one second before `started_at`** — which is
byte-for-byte what a lost runner looks like, and sends you to the pool to
investigate a workflow bug. The `job-` infix exists to make the collision
impossible rather than merely documented; keep the caller's name distinct anyway.

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
| [`merge-lane.selftest.sh`](../scripts/ci/merge-lane.selftest.sh) | Structural assertions on the workflows and the driver, each with a paired mutation |
| [`merge-lane.yml`](../.github/workflows/merge-lane.yml) | the reusable callee |
| [`merge-lane-self.yml`](../.github/workflows/merge-lane-self.yml) | this repository's caller |

The structural test asserts on the *text*, with mutations, because a property
silently removed has to fail a check that can actually run on a pull request.
The alternative is finding out when the lane merges something it should not
have.
