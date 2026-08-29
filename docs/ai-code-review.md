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

Disarm by setting `CODEX_REVIEW_ARMED` to anything else. Setting
`CODEX_REVIEW_ENABLED` to anything else stops the workflow running at all.

## The caller

```yaml
name: Codex review

on:
  workflow_run:
    workflows: [CI]
    types: [completed]

permissions:
  contents: read

concurrency:
  group: codex-review-${{ github.event.workflow_run.head_sha }}
  cancel-in-progress: false

jobs:
  review:
    if: >-
      vars.CODEX_REVIEW_ENABLED == 'true' &&
      github.event.workflow_run.conclusion == 'success'
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/codex-review.yml@d8d1e6d8be794657066a8d32a0327b62172ea299 # v5.77.0
    permissions:
      contents: read
      pull-requests: write
    with:
      head-sha: ${{ github.event.workflow_run.head_sha }}
      conclusion: ${{ github.event.workflow_run.conclusion }}
      skip-authors: dependabot[bot]
      runs-on: ubuntu-latest
      dry-run: ${{ vars.CODEX_REVIEW_ARMED != 'true' }}
```

Three things about that file are load-bearing:

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

## The wait, on the merge lane's side

`review-bots` on `merge-lane.yml`, documented in
[`docs/merge-lane.md`](merge-lane.md). The short version:

- It waits for a named set of reviewer logins, bounded by `review-grace-seconds`
  (default 600).
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
