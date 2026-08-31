# AI code review, on green CI only

An automated review costs credits. Configured the way the vendor ships it —
"review every new pull request" — the fleet pays for a review of every version
of every branch:

```
push   CI red     review paid for
fix    CI red     review paid for
fix    CI green   review paid for
```

Two of those three reviewed code that was already known to be wrong, and nobody
read any of them until the last one. The review worth buying is of the version
that is a candidate to **merge**, and the cheapest signal that a version might
be that one is its own CI going green.

So the vendor's automatic switch goes off, and the request moves into the fleet:
**one comment, on a successful CI completion, once per head sha.**

## The two halves, and why they are separate

| | asks | waits |
|---|---|---|
| workflow | `codex-review.yml` | `merge-lane.yml` (`review-bots`) |
| trigger | CI completion | CI completion |
| spends | credits | time |
| fails | closed — an unreadable anything declines to spend | **open** — an unreadable anything merges, and says so |

They are independent. Either works alone. Armed together they are the thing you
actually want: a review that lands **before** the merge instead of after it.

They are separate because the trigger and the lane are dispatched by the *same*
`workflow_run` completion, and the lane wins that race every time. Without the
hold, the review is bought and then arrives on a commit that is already on the
default branch.

## What an operator has to do once, by hand

**Turn OFF automatic reviews, per repository, in the reviewer's own account
settings.** For Codex that is <https://chatgpt.com/codex/settings/code-review>.

This cannot be done from a workflow, a Terraform resource, or an API call — it
is an account-level setting on the vendor's side, not a repository one. **Until
it is off, nothing is saved**: the fleet goes on paying for the red versions and
now pays for a green one on top.

## Arming a repository

Two repository variables, in this order, and the order is the point.

```bash
gh variable set CODEX_REVIEW_ENABLED --body true --repo <owner>/<repo>
```

The workflow now runs on every green CI completion and **logs what it would
have asked for**, without commenting. Read a pass of real verdicts — that is
the only place they can be read, because a `workflow_run` workflow cannot run on
the pull request that adds it.

```bash
gh variable set CODEX_REVIEW_ARMED --body true --repo <owner>/<repo>
```

Now it comments. Unset, or anything but the exact string `true`, is a dry run;
the driver reads it the same way, so a caller that forgets the input, a typo, or
a variable that does not exist all land on "decide and log" rather than on
"spend".

Measured on the first consuming repository, 2026-08-29 — the first time the
**pinned** caller form ran anywhere, since this repository's own caller uses
`uses: ./`. Owner and repository redacted, because the literals gate does not
allow them here:

```
codex-review: repo=<owner>/<repo> sha=94f73e59 conclusion=success armed=false
codex-review: #66 request:green (sha=94f73e59 author=<login>)
dry-run — would ask for a review of #66 at 94f73e59
codex-review: asked for 0 review(s)
```

That run also said *"the token does not resolve to a login — markers are
accepted from any Bot"*, which is the dedupe fallback doing its job and, at the
same time, the reason `review-token` is not optional. See "The identity that
asks", below.

Disarm by setting `CODEX_REVIEW_ARMED` to anything else. Setting
`CODEX_REVIEW_ENABLED` to anything else stops the workflow running at all.

## The caller

```yaml
name: Codex review

on:
  workflow_run:
    workflows: [CI]
    types: [completed]

  # So the dry run can be asked for, rather than waited for. Without this the
  # only way to produce a verdict is for somebody to open a pull request.
  workflow_dispatch:
    inputs:
      head-sha:
        # No `${{ }}` in this description: Actions PARSES input descriptions,
        # and an expression in one is a startup failure — zero jobs, no log.
        description: The head sha to ask for a review of, for a manual run.
        required: true
        type: string

permissions:
  contents: read

concurrency:
  # The manual leg is keyed on `github.run_id`, NOT on the sha. With
  # `cancel-in-progress: false` only one run may be pending per group, so a
  # third manual request for one sha would evict the queued second — gone with
  # no log and no conclusion. What stops a repeat purchase is the marker, not
  # this group.
  group: codex-review-${{ github.event_name == 'workflow_dispatch' && github.run_id || github.event.workflow_run.head_sha }}
  cancel-in-progress: false

jobs:
  review:
    if: >-
      vars.CODEX_REVIEW_ENABLED == 'true' &&
      (github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success')
    # `check-runner-policy.sh` RUNNER7 refuses to decide the runner scope and
    # timeouts of a workflow it cannot read, and this one is in another
    # repository. The marker records that a human read it — one job,
    # `timeout-minutes: 10`, `contents: read` + `pull-requests: write`, and a
    # `runs-on` YOUR file supplies — and points at the issue where that reading
    # lives. Open one; the gate rejects a marker without an issue number.
    # remote-reusable-allowed(Dima-Spectorr/ci-runner-infra/.github/workflows/codex-review.yml, #<issue>): read and recorded there
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/codex-review.yml@d8d1e6d8be794657066a8d32a0327b62172ea299 # v5.77.0
    permissions:
      contents: read
      pull-requests: write
    with:
      head-sha: ${{ github.event.workflow_run.head_sha || inputs.head-sha }}
      # A manual run ASSERTS the green rather than reading it — there is no run
      # to read it from — and that is the operator's call. Not a constant: pass
      # one and every CI completion asks for a review again.
      conclusion: ${{ github.event.workflow_run.conclusion || 'success' }}
      skip-authors: dependabot[bot]
      # The same label your CI jobs use. On a private repository `ubuntu-latest`
      # bills GitHub-hosted minutes; on a repository with a pool, use the pool.
      runs-on: ubuntu-latest
      dry-run: ${{ vars.CODEX_REVIEW_ARMED != 'true' }}
    secrets:
      # NOT OPTIONAL IN PRACTICE — see "The identity that asks", below. Omit it
      # and this runs green, comments, is refused, and writes the dedupe marker
      # anyway.
      review-token: ${{ secrets.CODEX_REVIEW_TOKEN }}
```

Four things about that file are load-bearing:

- **`workflow_run`, never `pull_request`.** A `pull_request` trigger here is the
  vendor's automatic review rebuilt in YAML — it asks before CI has said
  anything, which is the entire behaviour being removed. `codex-review.selftest.sh`
  asserts, with a mutation, that this trigger cannot be swapped silently.
- **`conclusion` is passed to the callee.** The `if:` above is a noise filter,
  so a red completion does not start a job whose only output is
  `skip:not-green`. The gate is the driver's own check, and it needs the real
  value: pass a constant and every completion asks for a review again.
- **The concurrency group is the caller's.** A reusable workflow's job belongs
  to the caller's run, so a group declared in the callee can cancel the run that
  called it — a job that finishes in one second, before it started, with no log.
- **The dispatch is what makes the dry run readable.** `CODEX_REVIEW_ENABLED`
  logs verdicts without commenting, and that pass is the only place they can be
  read — but with `workflow_run` as the sole trigger, producing one means waiting
  for somebody to open a pull request. On the pilot repository there were none
  open, so setting the variable produced nothing and there was no way to ask.
  `inputs.head-sha` therefore appears in three places — the trigger, the
  concurrency group (empty there means every manual run shares one group), and
  the `if:` — and the description carries no `${{ }}`, because Actions parses
  input descriptions and an expression in one is a startup failure with zero jobs
  and no log.

There is **no schedule**. The merge lane has one because a merge moves the base
and nothing announces that; nothing equivalent is true here. A version that has
gone green has already produced the one event that matters, and a sweep would
put the whole open backlog one API read away from a repeat purchase.

## The rules, in one place

`scripts/ci/codex-review-decision.sh` is the whole decision, as pure functions,
for the same reason every other `*-decision.sh` in this repository is: a
`workflow_run` workflow runs only from the default branch, so logic in YAML is
logic that ships untested.

| verdict | when |
|---|---|
| `skip:not-green` | the conclusion is anything but `success` — including `cancelled`, `timed_out`, `neutral`, `skipped`, and empty |
| `skip:not-open` | merged or closed while its CI was finishing |
| `skip:draft` | the author said "not yet" |
| `skip:already-requested` | a request is already recorded for this head sha |
| `skip:author` | the author is in `skip-authors` |
| `request:green` | the only verdict that spends |

**The record is a marker in the comment itself** —
`<!-- codex-review:requested:<sha> -->` — because this fleet keeps no state of
its own, and a marker in a comment survives a run, a restart, a re-installation
and a change of runner. It names the sha and nothing else, which is the
operator's decision recorded: *a new green version is a new review*. A fix made
in response to a review is itself reviewed; the same version never is twice.

The request and the marker go in **one** comment. Two writes would be two things
that can half-happen: a marker without a request is a review nobody ever asks
for, and a request without a marker is one paid review per CI completion for as
long as the pull request stays open.

**Only the requester's own marker counts.** A comment is something a stranger
can write on a public repository, so a marker matched by text alone is a
suppression anyone can post: comment `<!-- codex-review:requested:<sha> -->`
before CI finishes and the green run concludes `skip:already-requested` for a
review that was never asked for. Nothing goes red on that path — the merge lane
simply waits out its grace and merges unreviewed.

So the driver asks the token who it is, once, and filters the comment read by
the answer:

| the token | `/user` says | markers accepted from |
|---|---|---|
| `review-token` (a PAT) | that login | **that login only** |
| an App installation token | refuses | any Bot |
| the built-in `GITHUB_TOKEN` | refuses | any Bot |

The fallback is deliberately generous rather than empty. A filter that stopped
matching the workflow's *own* marker would buy a review on every CI completion
for the life of the pull request — a louder failure than the one being fixed —
and both bot-identity cases genuinely cannot resolve a login. "Any Bot" still
excludes every human account, which is the reported hole closed; a different
App posting the exact marker would still pass, and under `review-token` (which
Codex requires anyway) none of that applies.

## The fleet gates on Copilot alone

`review-bots` names `copilot-pull-request-reviewer[bot]` and nothing else. Codex
was on that list from the day the gate shipped, and taking it off was the fix to
a fault that had been running for two weeks.

**The list is what the gate EXPECTS.** A login on it that cannot answer is not a
harmless extra — it is a permanent shortfall. Two independent reasons made Codex
one:

1. **It was never asked.** `codex-review-self.yml` computes
   `dry-run: ${{ vars.CODEX_REVIEW_ARMED != 'true' }}`, and that variable is
   `false` in this repository and unset in the other sixteen. The workflow ran
   on every green CI completion in the fleet, decided, and commented nothing.
   Codex last spoke on 2026-08-15.
2. **Asked, it would have refused.** Codex bills a requested review to the
   asker's own Codex account. `github-actions[bot]` has none and an App cannot
   have one, so it answers the request with a refusal rather than a review. See
   *Who asks matters* above.

So `answered=1 expected=2` was permanent, and every merge in all seventeen
repositories carried `::warning::lane: #<n> merging UNREVIEWED` — the annotation
this document calls *the one thing worth alerting a human about*. Firing it on
every merge is how it stopped being worth reading.

**To put Codex back**, all three of these, together:

| | |
|---|---|
| `CODEX_REVIEW_TOKEN` (secret) | a fine-grained PAT — Pull requests: read and write — belonging to the account that pays for Codex. Not an App: an App token fails for the same billing reason `github-actions[bot]` does. |
| `CODEX_REVIEW_ARMED` (variable) | `true`, which is what takes `codex-review.yml` out of dry-run and lets it spend. |
| `review-bots` | add `chatgpt-codex-connector[bot]` back to the caller. |

Arming the first two without the third means Codex reviews and the lane does not
wait for it. The third without the first two is the fault described above. Also
raise `review-grace-seconds` if the review is meant to land *before* the merge:
Codex is only asked at CI-green, so it starts when the grace clock starts and
takes 2-4 minutes.

None of this affects `@codex review` typed by a human on a pull request, which
works now and always did — a person has a Codex account to bill.

## The wait, on the merge lane's side

`review-bots` on `merge-lane.yml`, documented in
[`docs/merge-lane.md`](merge-lane.md). The short version:

- It waits for a named set of reviewer logins, bounded by `review-grace-seconds`
  (default 60 — see *The grace closes a race, not a think* in
  [`docs/merge-lane.md`](merge-lane.md)).
- **This fleet names one login: `copilot-pull-request-reviewer[bot]`.** Why not
  Codex, and how to put it back, is the section below.
- **It fails open, and it is the only gate in that lane that does.** Codex runs
  out of credits; when it does no review is ever published, and a fail-closed
  hold would stop the fleet merging anything at all, indefinitely, with nothing
  red to explain why.
- Merging without an answer prints `::warning::lane: #<n> merging UNREVIEWED`.
  **That annotation appearing on every pull request means the reviewer is down —
  credits, almost always — not that it is slow.** It is the one thing worth
  alerting a human about in this whole design.
- A **clean** review counts. Codex publishes no review object when it has no
  findings, only a reaction and a summary comment naming the commit, so the lane
  reads both surfaces.
- **A reviewer that reports it cannot review counts too, and this is the third
  surface.** Copilot answers a rate limit by concluding *its own* check run red
  against the head sha — `copilot-pull-request-reviewer`, `failure`, an HTTP 429
  in the body — and publishing neither a review nor a comment. On the two
  surfaces above that is indistinguishable from "still reading", so the lane used
  to hold the pull request for the whole grace and then merge it with a warning
  naming a cause that was not the cause. Measured 2026-08-30: the limit is
  **account-wide and lasted seven hours**, so it hit every open pull request in
  every repository in the fleet simultaneously.

  The lane now reads the head sha's check runs and treats a **non-green
  conclusion on a check run named for one of the `review-bots`** (the login
  without its `[bot]` suffix — the mapping GitHub uses for a reviewer App) as an
  answer. It is: the reviewer looked at this commit and said it cannot review it,
  and that answer will not change on its own.

  Only a **non-green** conclusion counts. A reviewer that ran and had findings
  also concludes its check run, green, and those findings land on one of the two
  surfaces a moment later — counting that would discharge the gate ahead of the
  review it exists to wait for. The gate is not weakened for a reviewer that is
  actually available.

  The pass log says so: `lane: #<n> — 1 of 2 reviewer(s) answered ... by
  reporting they could not review it`. A **notice**, not the `UNREVIEWED`
  warning, which stays reserved for a merge that genuinely went out with nobody
  having looked.

### Copilot does not re-review a head that moved — so `pr-guard` asks again

The third surface above fixed a reviewer that was *down*. This is the other half,
and it was the more common one by far: a reviewer in perfect health that was
never asked a second time.

**Copilot reviews the first push to a pull request and then stops.** Measured
across the fleet on 2026-08-30: **fourteen of fifteen merged multi-commit pull
requests had no Copilot review on the head that actually landed.** On the first
push it is not slow — it answered a median of **1580 seconds before** the last
required check finished, and 11 out of 11 times within 60 seconds of being asked.
So the grace was never the problem, and raising it fixes nothing: on
IntegrateIT #14070 the head moved nine minutes after the review, and the merge
came 22 minutes later — the old 600-second grace would have produced the
identical annotation.

What the lane saw was `answered=0 expected=1`, permanently, for any pull request
whose head moved after its first review. It waited out the grace and stamped
`UNREVIEWED` — the annotation documented three bullets up as *the reviewer is
down, go look*. It was pointing at a vendor outage that was not happening, on
most merges in the fleet, which is exactly how such a warning stops being read.

**The re-request happens at push time, in `pr-guard`, and that is the design.**
`pr-guard` already runs on `synchronize` for every open pull request in the
fleet, needs no App — the caller's own `GITHUB_TOKEN` with `pull-requests:
write` is enough — and, decisively, a review requested on the push runs *beside*
CI. CI here takes tens of minutes and a review takes a few, so the review has
landed long before the lane asks. **It adds nothing to the time a green pull
request waits**, which is the constraint the last three releases were spent on.

Its `review-bots` input defaults to `copilot-pull-request-reviewer[bot]` and
should match the lane's. Only a reviewer that has published a review on an
**earlier commit of this same pull request** is asked again:

| state | what it means | what happens |
|---|---|---|
| `answered` | it reviewed this exact head | nothing |
| `pending`  | it has an outstanding request | nothing — re-asking **replaces** the request in flight, so a branch pushed twice would cancel its own review |
| `stale`    | it reviewed an earlier commit here | re-requested |
| `absent`   | it has never reviewed this pull request | nothing — it is either still on its first pass or not configured here, and asking would be a poke in the dark on every push |

The request goes through the GraphQL `requestReviews` mutation with `botIds` and
`union: true`. **REST cannot do it**: `POST /pulls/{n}/requested_reviewers`
refuses a bot login outright with `422 Reviews may only be requested from
collaborators`. The reviewer's node id is only reachable as the **author of a
review it has already published** — `suggestedActors` returns
`copilot-swe-agent`, which is the coding agent and a different bot.

Every call fails soft and says so in the log. A fork's token is read-only and a
caller may not hold `pull-requests: write`; a guard that went red because it
could not *ask* for a review would be a worse version of the problem it fixes.
The lane's grace is still the fallback.

**Confirmed live on the pull request that introduced it** (#595, 2026-08-31).
The second push classified `copilot-pull-request-reviewer=stale`, logged `asked
copilot-pull-request-reviewer to review 166b42f5`, and Copilot published a review
on that head minutes later. So `github-actions[bot]`'s own `GITHUB_TOKEN` does
carry enough authority for the mutation — no App and no PAT — which is the part
that could not be established without running it.

**And the lane now says which failure it is.** `review_answered` counts a review
of an earlier commit as `stale` — never as an answer, because a review of an
older tree says nothing about the new one — and that count rides into the
verdict line as `stale=<n>`. Where it appears, the annotation reads *a reviewer
reviewed an EARLIER commit and was never asked about this head … that is not an
outage*, and points at `pr-guard` instead of at a vendor status page. Without
`stale=`, the wording is unchanged and still means what it always did.

### The red check itself stays red, and that is not ours to fix

`copilot-pull-request-reviewer` is a check run published by GitHub's own Copilot
App. No workflow in this repository creates it and nothing here can change its
conclusion, so during a rate limit it will show red on the pull request. What
this repository controls is that the red **costs nothing**: it is not in
`required-checks`, so it never blocks a merge, and as of the surface above it no
longer holds the lane either. If an operator wants the red gone entirely, the
only lever is disabling automatic Copilot review in the repository's settings —
which removes the reviewer, not the outage.

## The identity that asks — measured, not guessed

**The built-in token does not work, and neither does an App.** This was an open
question in the design and it is now answered, live, on
[#529](https://github.com/Dima-Spectorr/ci-runner-infra/pull/529): the request
was posted as `github-actions[bot]`, Codex answered within seconds, and the
answer was

> To use Codex here, create a Codex account and connect to github.

Codex attributes a requested review to **the Codex account of the GitHub user
who asked for it**, and charges that account. `github-actions[bot]` has no Codex
account and cannot be given one; nor can a GitHub App, for the same reason. The
failure is not a loop guard ignoring bots — the App replies, it just declines.

So `review-token` is not a fallback, it is **the** configuration:

1. On the GitHub account whose Codex account pays for reviews, create a
   fine-grained personal access token scoped to the repositories being armed,
   with **pull requests: read and write** and nothing else.
2. Store it as the repository secret `CODEX_REVIEW_TOKEN`.
3. Pass it to the callee as `review-token`.

Without it the workflow runs green, posts its comment, gets the refusal above,
and no review happens — and because the request *was* posted, the dedupe marker
was written too, so it will not be retried for that commit. **A repository armed
without the token is a repository that is silently not reviewed.**

`review-app-id` / `review-app-private-key` remain declared and remain preferred
for any *other* reviewer that does honour App identities; they are simply not a
solution for Codex.

## Your CI must run when a draft is marked ready

The rule declines to spend on a draft, and this trigger is dispatched by CI
completions only. `opened, synchronize, reopened` — the default `pull_request`
activity types — contain no event for *marked ready*. Put together, a draft
whose last push went green sits at that same green sha when it becomes ready,
produces no further completion, and is never reviewed; the merge lane then holds
it for its grace and merges it unreviewed, which reads as a slow reviewer rather
than as a request nobody made.

So a repository arming this needs its CI workflow to say:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
```

It costs one extra run per draft that becomes ready — the same work the pull
request needed anyway, moved earlier. This repository's own `ci.yml` says it,
and `codex-review.selftest.sh` asserts it there with a mutation; for a consuming
repository, whose CI workflow this fleet does not own, it is this paragraph.

## Self-tests

- `scripts/ci/codex-review.selftest.sh` — the decision cases and the structural
  properties of the two workflow files and the driver, with mutations.

Both halves are workflows that cannot be exercised by the pull request that
changes them. The self-tests are what stands in for the run that cannot happen,
and for the trigger half the cost of being wrong is billed to an account.
