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
| Actions | Read | the `workflow_run` that dispatched this pass |
| Workflows | Read & write | merging a pull request that touches `.github/workflows/` |

**Workflows is not optional either, on a fleet where most pull requests are
workflow pull requests.** GitHub refuses an App token that writes under
`.github/workflows/` regardless of `Contents: write`, and a squash merge counts
as writing those files. Measured 2026-08-26 on Print-Server and entity-platform:
the lane logged `merge:ready` for every candidate and then `done, 0 action(s)`,
with every pull request reading `mergeable: true` and `mergeable_state: clean`.
The real cause was one line above the annotation, on `gh`'s stderr — *refusing
to allow a GitHub App to create or update workflow ... without `workflows`
permission (HTTP 403)*. The refusal is deterministic, so the same pull request
is refused on every pass. **The permission is per-installation and has to be
accepted on each one**, so a repository onboarded later starts out with this
hole even though the fleet's other installations are fine.

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
    # Must match each workflow's `name:` exactly.
    #
    # LIST THE BASE-HEALTH WORKFLOW HERE TOO if you have armed the gate. On an
    # armed base the lane merges only onto a tip that has answered green, so the
    # completion of that job is precisely the event that unblocks the next
    # merge. Leave it out and the lane still gets there — the cron backstop and
    # the next CI completion both wake it — but a backlog drains at whichever of
    # those happens to fire rather than as fast as the base can vouch for itself.
    workflows: [CI, main-health]
    types: [completed]
  schedule:
    - cron: '*/15 * * * *'   # the backstop — see below
  # `labeled` matters only if you re-narrow with `require-label`, which the
  # fleet default no longer does. Under a label gate, labelling is the last
  # thing to happen on a pull request whose CI is already green, and nothing
  # else dispatches the lane for it. See "A label applied after the green",
  # below. `ready_for_review` is worth keeping either way: leaving draft is
  # also a state change no CI completion follows.
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
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@d8d1e6d8be794657066a8d32a0327b62172ea299 # v5.77.0
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
      # EMPTY IS THE FLEET DEFAULT, since 2026-08-30. Every open, non-draft,
      # unconflicted pull request on the base is a candidate — the behaviour
      # Mergify's `auto_merge_conditions` had, and the standard this fleet
      # migrated onto: auto-merge on green, no required human approval.
      #
      # It used to be a label gate, and that was a MIGRATION guard rather than
      # the end state: a repository arming the lane while still holding a
      # Mergify-era backlog would have merged months of stale work in one pass.
      # Once the backlog is walked, the guard is the only thing left stopping
      # merges.
      #
      # It was removed because a label nobody applies does not make merging
      # careful, it makes it manual — and it fails in the direction that looks
      # healthy. Measured across the fleet on 2026-08-30: pull requests sat
      # green and `clean` for hours while every pass logged `skip:no-label` and
      # ended SUCCESS. A pass that skipped your pull request is indistinguishable
      # from one that took it unless you read the log.
      #
      # IF YOU RE-NARROW IT, THE FALLBACK IS THE LABEL, NOT EMPTY — copy this
      # line exactly, and never the bare variable:
      #
      #   require-label: ${{ vars.MERGE_LANE_REQUIRE_LABEL || 'ready-to-merge' }}
      #
      # `${{ vars.X }}` on its own renders as an empty string when the variable
      # is unset, mistyped, or cleared later by someone tidying settings, and
      # empty means "no label required" — so the bare form fails OPEN and a
      # forgotten setting releases the backlog. With the `|| 'literal'` fallback,
      # widening stays a pull request. That is why THIS file widened by editing
      # the line rather than by clearing the variable.
      #
      # Narrowing does not make the lane a review gate either way: required
      # checks, base health and `review-bots` are what decide.
      require-label: ''
      # Optional, and a no-op unless you re-narrow with a label. Dependabot's
      # weekly bump of the pins above is the update nobody is ever going to
      # label by hand in fourteen repositories — see "Tracking this repository
      # automatically".
      # Waives the LABEL only, and only for a diff in which every changed line
      # names a ci-runner-infra reusable workflow.
      pin-bump-actor: ${{ vars.MERGE_LANE_PIN_BUMP_ACTOR }}
      # Optional. An issue whose body the lane rewrites with the queue after
      # every run — see "Seeing the queue". Unset means the job summary only.
      status-issue: ${{ vars.MERGE_LANE_STATUS_ISSUE }}
      # Hold a green pull request until the robots have read it — see
      # "Waiting for the automated reviewers". Required if this repository asks
      # Codex for a review only once CI is green, which is the fleet default:
      # without it the lane merges while the review is still being written.
      review-bots: |
        chatgpt-codex-connector[bot]
        copilot-pull-request-reviewer[bot]
      review-grace-seconds: 60
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
> ### Tracking this repository automatically
>
> **Only applies under a label gate.** The fleet default is `require-label: ''`,
> where the pin bump is a candidate like any other pull request and none of the
> below is needed.
>
> A label gate and "every repository picks up the shared workflows on its own"
> are in direct conflict, and the conflict is silent. Dependabot opens the pin
> bump, Dependabot does not label, so under `require-label` that pull request
> sits open forever — and the repository quietly stops tracking this one while
> reporting a perfectly healthy lane. The alternative, a human labelling the
> same bump in fourteen repositories every Monday, is the manual step the lane
> exists to remove.
>
> `pin-bump-actor` resolves it, as narrowly as it can be resolved. Set it to
> `dependabot[bot]` and an unlabelled pull request **by that author** whose
> every changed line names a `ci-runner-infra` reusable workflow no longer needs
> the label. Everything else still does: a bot pull request that also edits a
> job, a bump of some other action, a human pull request that only moves a pin.
> And it waives the label ONLY — required checks and base health are unchanged,
> so a pin bump that turns the repository red still does not merge.
>
> Empty is the default, so a repository that has not asked for the waiver keeps
> a pure label gate.
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
candidate set with `require-label` (which reintroduces "A label applied after
the green", below), close what is stale, or raise
`pass-budget-seconds` **together with** the job's `timeout-minutes`. The
self-test refuses a budget that does not leave the lane two minutes to publish
its summary inside the ceiling — a run that merges and then reports nothing
about it is worse than one that merges nothing.

### A label applied after the green

**Only applies under a label gate**, which the fleet default no longer is — see
`require-label` in the caller above. Kept because re-narrowing a single
repository is legitimate, and this is the failure it brings back.

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

### Waiting for the automated reviewers

Codex reviews cost credits, and the fleet was spending them on pull requests
that were about to change. A red pull request gets pushed again; the review of
the version that failed is a review nobody keeps, and the fix then buys a
second one. So the fleet stopped asking at *pull request opened* and started
asking at **CI green** — see `docs/ai-code-review.md` for that half.

That creates the problem this gate solves. The review request and the merge
decision are now dispatched by the *same* `workflow_run` completion, so the
lane, left alone, merges while the reviewer is still reading. The credits then
buy a comment on a closed pull request, which is worse than not asking.

`review-bots` names the logins to wait for. A pull request that is otherwise
`merge:ready` becomes `wait:review` until each of them has published something
about **the head sha** — the queue table says so, nothing is commented, and the
next CI completion or the fifteen-minute sweep asks again.

**Two surfaces are read, and the second one is not optional.** Codex publishes
a review object only when it has findings; when it finds nothing it reacts with
a thumbs-up and edits one summary comment naming the commit it read. A gate
that only knew about `/pulls/<n>/reviews` would hold every clean pull request
for the whole grace and then merge it warning that nobody had reviewed it — so
an issue comment by the same login naming the head sha counts as an answer.

**This is the only gate in the lane that fails open, and that was a decision
rather than an oversight.** The reviewers are third parties. The case that
settles the direction is the ordinary one: a Codex account runs out of credits
and then publishes nothing, for any pull request, until somebody tops it up. A
gate that failed closed there would stop the whole fleet merging and hand a
vendor's billing page authority over this repository. So the wait is bounded by
`review-grace-seconds`, and past it the lane merges and writes a warning
annotation naming the pull request and the sha.

**Sixty seconds, not ten minutes.** The grace closes a *race*, not a think.
The review request and the lane are dispatched by the same `workflow_run`
completion and land within about a second of each other; without a hold the
review is bought and then arrives on a commit already on the default branch.
A minute covers that. It was 600 on the reasoning that it should outlast
a reviewer, which had the clock wrong — Copilot starts at pull-request *open*
and has had the whole CI run to finish before the lane ever looks, so the extra
ten minutes bought nothing and were paid on every pull request in the fleet.

The cost is real and worth stating: Codex *is* only asked at CI-green, so it
starts when this clock does and takes 2-4 minutes. At sixty seconds it will
not be waited for, and its findings will land on a merged pull request. The gate
fails open, so nothing is lost but the ordering. A repository that wants Codex
to land before the merge passes a larger number and pays that latency on every
pull request to get it.

**The grace is measured from the moment the reviewers could have started —
the last *required* check to finish, on either surface.** Not the head commit's
date, which would charge a pull request for the whole of its own CI run and
expire the grace before the first pass on anything opened yesterday. Two things
follow, and both were live defects until #527:

- **A required context can be a legacy commit status**, which `check_counts`
  already accepts. Statuses are a different API and carry no check-run, so a
  repository whose required contexts are statuses had no clock at all: the read
  came back empty, an unreadable clock reads as expired, and the hold ended the
  moment it began — armed, green, and waiting for nobody. Both surfaces are
  read now.
- **Only the configured required contexts count.** Unfiltered, any check run at
  all moved the clock forward — a slow optional job, a coverage bot, a fork's
  leftover — and held a green pull request past the grace you configured.

When neither surface names a required context, the newest timestamp of anything
on the commit is used instead. That fallback is deliberate: a repository whose
required list names something nothing publishes would otherwise be handed an
empty clock, which is the "expired" reading this whole paragraph exists to stop
producing by accident.

The annotation is written **beside the merge**, not during the walk. A pass
classifies every open pull request and merges at most a handful of them, so a
warning written where the verdict is computed would name candidates that were
never merged — including in a dry run, which merges nothing at all. Since this
annotation is what an operator reads to decide the reviewer is down, a warning
for a merge that did not happen is worse than no warning.

That warning is the thing to watch. On one pull request it is a slow reviewer.
On **every** pull request it is a reviewer that is down — credits, most likely
— and the number is not what is wrong.

The gate can only ever delay a merge the required checks have already approved.
It never approves one, and it is asked only of a pull request already ranked
`merge:ready`, so it costs two API reads per merge rather than two per open
pull request per pass. That distinction is #444, and it is what keeps a pass
inside the job's timeout.

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
   resumes on its own as soon as those checks pass. On an armed base the tip is
   re-read between merges too, so a semantic conflict costs the one merge that
   caused it rather than the batch it arrived in — see *once the gate is armed*
   below.

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

**Once the gate is armed, the lane merges only onto a tip that has answered.**
This is the half that makes the gate worth arming, and it is easy to miss why it
is needed: the halt above asks its question *once*, at the top of a pass, and a
pass on a non-strict base then merges several pull requests. The first of them
is exactly the merge that can turn the base red — two branches green alone and
broken together is the case this whole gate exists for — and without a second
look the rest of the batch lands on the break before any post-merge job has
reported. So on an armed base the tip is re-read between merges *and* at the top
of every pass, and nothing is merged onto it until its base-health checks report
green. An unarmed base is untouched by this: nothing answers for it, so there is
nothing to wait for and it drains as before.

Two consequences worth stating plainly:

- **An armed repository merges at the pace its health job answers.** That is the
  cost of the guarantee, and it is why `base-health-checks` exists — point the
  gate at a two-minute job, not a thirty-minute suite, and the pace is fine.
- **The wait has a ceiling, `base-health-grace-seconds` (default 900).** The job
  answering for the tip is keyed to supersede its own runs, which is the only
  shape that can answer for the *current* commit, so on a busy base it is
  routinely cancelled before it reports. Past the grace window the lane proceeds
  with a warning rather than stalling. **Raising it is almost never the fix:** a
  lane warning that it proceeded unvouched on every pass has a health job that
  never finishes, and the number is not what is wrong.
- **That ceiling bounds one wait, not the waiting — and on a fast base the
  difference is a livelock.** The grace is measured from the *tip's* commit
  date, so every merge that lands restarts it from zero. Each wait expires
  correctly and the sequence never does. Measured on IntegrateIT on 2026-08-26:
  a 6–14 minute `main-health` against a `main` advancing every 2–16 minutes, and
  the lane merged nothing for a working day while the backlog went in by hand —
  which is itself what kept `main` moving. **It is silent.** The pass halts
  before it classifies anything, so the run says `success` and `0 action(s)`
  with no `merge:ready` line above it, which is also exactly what an idle,
  healthy lane says. If a repository's lane has never merged anything, read the
  `lane:` notices, not the run conclusion.
- **The fix for that is `base-health-max-staleness-seconds` (default `0`, off).**
  Non-zero lets a green answer on a recent *ancestor* vouch for a tip that has
  not answered yet, which is the question the gate actually asks — is the base
  broken right now. Set it to a small multiple of how long the health job takes.
  It is deliberately opt-in: one repository outrunning its health job is not a
  reason to relax the gate on the twelve that have not.

  What it relaxes is narrow, and each bound is enforced by the self-test rather
  than by this paragraph. The window is consulted **only** when the tip reads
  `unanswered` — a tip that answered red still halts the pass. The walk stops at
  the first ancestor that answered *either way*, so a red ancestor halts the lane
  instead of being searched past for an older green one. It is bounded by age and
  by five hops. And it is **closed for the rest of any run in which the lane has
  merged**, because an ancestor's answer predates that merge by definition and
  must not speak for a tip the lane itself created — which is the whole point of
  the between-merges check above.

  And note what it replaces. Past the grace, the unfixed behaviour is to merge
  *unvouched*, on no answer at all. A green answer from four minutes ago is
  strictly more information than that, not less.
- **Wake the lane on the health job, not only on CI.** Add the health workflow's
  `name:` to your caller's `workflow_run: workflows:` list. Its completion is
  the event that unblocks the next merge, and a caller that only listens to CI
  learns the tip went green whenever the cron backstop next fires — a fifteen
  minute pause between merges on a base that answered in two.
- **Join the names to the jobs, or the gate disarms itself in silence.** The
  names in `base-health-checks` are matched literally against the check-runs on
  the tip, and a name that matches nothing counts as MISSING — which does not
  halt. So a typo, or renaming the job that answers, breaks nothing, fails
  nothing, and leaves a repository merging onto an unverified base while the
  configuration still says otherwise. [`check-base-health-contract.sh`](../scripts/ci/check-base-health-contract.sh)
  is what joins the two files; run it in your own CI beside the other workflow
  gates. It reads the fallback too — **`base-health-checks` unset means
  `required-checks`**, so a caller that never opted in is still armed, against a
  list written for pull requests. A required check that runs only on
  `pull_request` publishes nothing on the tip, which is the same silent disarm
  arrived at without anyone choosing it.

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
