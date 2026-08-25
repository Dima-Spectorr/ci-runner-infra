# The branch reaper

Deletes branches that were merged, have not moved since, and are older than a
grace period. Runs daily. Defaults to deleting nothing.

It is the other half of [the merge lane](merge-lane.md): the lane squash-merges
and leaves the head branch behind, and every session in this fleet works on its
own branch in its own worktree, so branches accumulate here faster than in a
repository with one contributor. `ci-runner-infra` reached **256 remote
branches in about ten days**. That is not untidiness — `git branch -r` is how a
session finds out whether another session already has its task in flight, and a
list nobody can read stops answering that question.

## The rule

A branch is deleted only when **all** of these hold:

1. It is not the default branch.
2. GitHub does not report it protected.
3. It does not match one of the operator's `keep-patterns` globs.
4. No **open** pull request targets it as a base.
5. No **open** pull request has it as a head.
6. Some pull request with it as a head was **merged**.
7. The branch tip is **still exactly the head sha that was merged**.
8. That merge was at least `min-age-days` days ago (strictly: `age >= min`).

Everything else is a keep, and so is every fact the run could not establish.
There is no arm that deletes on an unknown.

### Why "merged" is not enough on its own

Under a squash merge the branch tip is **not** an ancestor of the default
branch, so the usual "is it reachable from `main`" test cannot be used — it
would answer *no* for every branch this repository has ever merged. The
analogue that does hold, and the one GitHub's own **Delete branch** button
uses, is rule 7: the tip is still the sha that was merged. If someone pushed
after the merge, those commits were never merged and never reviewed, and the
branch is live work that happens to have a merged pull request behind it.

The cost of that conservatism is visible in the first live sweep of this
repository: **11 of 256 branches** came back `keep:moved-since-merge` and will
never be reaped automatically. Most are Mergify-era branches that the old queue
pushed to after the merge. Delete them by hand, or add them to
`keep-patterns` — do not loosen rule 7 to make the report tidier.

### Why the grace period

A branch merged this morning is a branch someone may still be reading,
cherry-picking from, or about to reopen. Fourteen days is the fleet default and
is deliberately far longer than anyone's working memory of a merge.

## Where the code lives

| File | What it is |
|---|---|
| [`scripts/ci/branch-reaper-decision.sh`](../scripts/ci/branch-reaper-decision.sh) | The whole rule, as one pure function. No API calls. |
| [`scripts/ci/branch-reaper-decision.selftest.sh`](../scripts/ci/branch-reaper-decision.selftest.sh) | 26 cases. Nearly all of them assert that something is **not** deleted. |
| [`scripts/ci/branch-reaper.sh`](../scripts/ci/branch-reaper.sh) | The API half — reads facts, acts on a verdict, writes the report. |
| [`scripts/ci/branch-reaper.selftest.sh`](../scripts/ci/branch-reaper.selftest.sh) | Structural assertions on the workflows and the driver, each with a paired mutation. |
| [`.github/workflows/branch-reaper.yml`](../.github/workflows/branch-reaper.yml) | The reusable workflow consumers call. |
| [`.github/workflows/branch-reaper-self.yml`](../.github/workflows/branch-reaper-self.yml) | This repository's own caller. |

The split is the same one the merge lane makes, for the same reason: a
`schedule` workflow is dispatched from the **default branch only**, so nothing
in the two workflow files runs on the pull request that changes them.
Everything that *decides* therefore lives in pure functions with cases against
it, and the structural self-test asserts the wiring with mutations so a property
silently removed fails a check that **can** run on a pull request.

## Safety, and how it differs from the lane

Blast radius runs the opposite way. A wrong merge writes something you can
revert out of the history it just wrote; a wrong delete destroys commits that
may exist nowhere else. GitHub keeps unreachable objects for a while and will
restore a ref from the UI for a while, but neither is a guarantee. So:

- **`dry-run` defaults to `true`** here, and to `false` in the lane. Anything
  other than the exact string `false` is a dry run — unset, `TRUE`, `1`, a
  trailing space.
- **`max-deletions` caps one run at 20.** Not a performance knob. The first
  armed run against a repository nobody has ever pruned is both the run that
  would delete the most and the run most likely to be acting on a keep-list
  somebody got wrong; the cap turns that from a repository-wide event into
  twenty branches and a report, with everything else still there tomorrow.
- **The pull request index fails closed globally.** If it does not load, the run
  aborts rather than sweeping a repository in which every branch reads as
  unmerged.
- **The job's `GITHUB_TOKEN` holds `contents: read`.** The App token is the only
  write path, so there is exactly one and it is the audited one.

## Seeing what it did

Every run writes a table to its **job summary**: one row per branch *including
the ones nothing happened to*, because the question an operator actually has is
never "what did you delete" — the log says that — it is "why is this branch
still here". Rows are ordered so the near misses read first: what the job would
delete next, then the moved and unknown tips, then unmerged branches, with the
structural keeps at the bottom.

There is no pinned-issue equivalent of the lane's queue view. The lane's queue
is a *live* thing worth bookmarking; a daily sweep's report is a log entry.

## Enabling it on a repository

Prerequisite: the repository already runs the merge lane, so the merge App is
installed and `MERGE_APP_ID` / `MERGE_APP_PRIVATE_KEY` exist. The reaper needs
**no permission the lane does not already have** — `Contents: write` covers
both merging and deleting a ref.

1. **Land the caller switched off.** Add `.github/workflows/branch-reaper-self.yml`
   (below). With `MERGE_LANE_ENABLED` unset the job does not run at all.
2. **Set `MERGE_LANE_ENABLED=true`** if it is not already. The reaper is now in
   dry run: it computes every verdict and deletes nothing.
3. **Read a report.** Run the workflow by hand (`workflow_dispatch`) and read
   the job summary. Every row marked *would delete* is a branch that will go on
   the first armed run.
4. **Add `keep-patterns` for anything in that list you want to keep**, and
   re-run step 3 until the report is boring.
5. **Set `BRANCH_REAPER_ARMED=true`.** This is a repository variable, not a
   commit, so arming does not need another pull request.

Steps 3–5 are the whole point of the two-variable design: reading real verdicts
before granting delete authority is the only honest order, and a scheduled
workflow cannot run on the pull request that adds it.

**Arm it as part of the cutover, not "later".** A repository left in dry run
accumulates merged branches at exactly the rate of one with no reaper at all,
while reading as configured. `ci-runner-infra` itself has been armed since
2026-08-25 (`dry-run=false`, 257 examined, 0 deleted — nothing in it is
fourteen days old yet), which is the cheapest moment there is to arm: the
first armed run against a repository is far less alarming when its would-delete
list is empty, and the `max-deletions` cap then meters the backlog as branches
age in rather than clearing it in one sweep.

**Check `max-deletions` against the repository's merge rate.** The cap bounds a
mistake, but a cap below the rate at which branches age past the threshold is
not a bound — it is a permanent deficit, and it hides as a green sweep every
morning while the backlog grows. Count merges per day
(`gh api --paginate 'repos/OWNER/REPO/pulls?state=closed&per_page=100' --jq
'.[] | select(.merged_at != null) | .merged_at[0:10]' | sort | uniq -c`) and set
the cap above the peak, not the average. The default 20 suits a repository
merging a handful a day; `ci-runner-infra` measured ~25/day with peaks of 50 and
passes 60.

### The consumer's caller

```yaml
name: Branch reaper

on:
  schedule:
    - cron: '17 4 * * *'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  reap:
    # Off until the merge App secrets exist — a dry run still mints the token,
    # so without this the job is red every day.
    if: vars.MERGE_LANE_ENABLED == 'true'
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/branch-reaper.yml@22549049f59ee3c67f04221c6b1a17d72ec6d83a # v5.53.0
    permissions:
      contents: read
    with:
      min-age-days: 14
      # A LINUX label. `self-hosted` alone matches the fleet's Windows pool too,
      # and the driver is bash: `mapfile`, `declare -A`, `date -u -d`, `jq`.
      #
      # NOT A YAML SEQUENCE. This is a `type: string` input, so a list here is a
      # parse error and the workflow never starts. One label as a bare string,
      # or several as a JSON array inside a string:
      # `runs-on: '["self-hosted", "linux"]'`.
      runs-on: your-linux-pool-label
      keep-patterns: |
        release/*
      # The SAME sha as the `uses:` pin above. The reusable workflow's own
      # `actions/checkout` clones YOUR repository, so the reaper has to be told
      # where its driver lives; left at the default it runs the tip of our
      # default branch under a pinned workflow.
      implementation-ref: 22549049f59ee3c67f04221c6b1a17d72ec6d83a
      dry-run: ${{ vars.BRANCH_REAPER_ARMED != 'true' }}
    secrets:
      app-id: ${{ secrets.MERGE_APP_ID }}
      app-private-key: ${{ secrets.MERGE_APP_PRIVATE_KEY }}
```

A **public** repository should use `runs-on: ubuntu-latest` instead — hosted
minutes are unmetered there, and the repository that defines the self-hosted
fleet must not need the fleet healthy in order to tidy itself.

## Cost

One run is a handful of API calls: the repository, the open pull requests, the
full pull request history paginated, and the branch list paginated. On
`ci-runner-infra` — 256 branches, 303 branch names in the pull request history —
that is about ten calls, and the job finishes in seconds.

It reads the **whole pull request history once and indexes it**, rather than
asking `pulls?head=owner:<branch>` per branch. The per-branch shape was measured
and did not finish in five minutes against 256 branches; worse, it scales the
wrong way, because the repositories with the most branches to prune are exactly
the ones where it would exhaust the hourly rate limit — and a failed read is a
keep, so the job would quietly stop pruning precisely where it is needed most.

## Known limitations

- **A branch whose tip moved after the merge is never reaped.** By design; see
  rule 7. Eleven such branches exist here today.
- **A branch that never had a pull request is never reaped**, however old. It is
  unreviewed work that exists nowhere else, and it is the single most likely
  thing in the list to be somebody's session in progress.
- **Only one deletion cap, per run, not per day.** A repository with 500
  reapable branches drains at 20 a day. That is intentional: it is 25 days of
  daily reports in which someone can notice a mistake.
