# Merge-queue stall recovery — RETIRED

**This layer no longer exists. Nothing in the fleet implements it.**

## What it was

Mergify would accept a pull request into its queue and then stop moving it. The
pull request was open, admissible and fully green; the merge box said ready;
the pool was idle; nothing anywhere was red. The only surface that ever noticed
was a human wondering why something had not landed — which on this fleet took
17 and 18 hours on two pull requests in a single day.

So the controller swept for that shape and posted `@mergifyio refresh` or
`@mergifyio queue` on the offender. It was a chaperone for a queue that could
not be relied on to look at its own entries.

## Why it is gone

Mergify is gone. Every repository in the fleet now merges through
[the merge lane](merge-lane.md), which is triggered by `workflow_run` in the
same repository: GitHub dispatches the lane itself the moment CI completes, so
there is no webhook to miss and no third party to remind. A queue that cannot
fail to be told that CI finished does not need a sweep telling it again.

Retiring the sweep removed, in one change:

* `collect_queue_stalls` and `gh_api_post` from the controller — `gh_api_post`
  was the **only** call in the control plane that wrote anything to a consumer
  repository;
* `queue-stall-decision.sh` and its self-test;
* five `ci_queue_stall_*` / `ci_queue_nudges` metric series and their
  descriptors;
* two alert policies (`the merge queue is stalled and the fleet cannot clear
  it`, `the stall sweep is being refused`);
* `Pull requests: write` from the fleet App. See
  [`github-app-permissions.md`](github-app-permissions.md) — the App's only
  remaining write is `Administration`, which buys a runner registration token
  and nothing else.

`queue_stall_after_seconds` and `queue_stall_max_attempts` survive as deprecated,
unwired variables in both modules so that a root still assigning them continues
to plan. Drop the assignment; the variables go with the next major.

## If a pull request is green and not merging now

It is not this. Read [the merge lane's](merge-lane.md) job summary or the
repository's pinned queue issue, which name what each waiting pull request is
waiting on. The lane halts deliberately on a base whose own health is unvouched
for, and a required check that no workflow emits blocks every merge silently —
both are lane concerns, and both are diagnosed there.
