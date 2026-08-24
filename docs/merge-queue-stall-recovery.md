# When a green pull request stops merging

This page is about one failure class, and it is the most expensive one this
fleet produces: a pull request that is **open, mergeable, and fully green**, and
that does not merge, for hours, because nothing is going to notice.

It is not a theory. On one consumer repository over 2026-08-22..23, two pull
requests took **17h11m** and **18h00m** to merge. Neither was waiting on a
review. Neither had a conflict. Neither had a single red check on it at the time
it was waiting. Both merged within minutes of a human typing one word in a
comment box.

The reason this is worth a document rather than a line in a runbook is the
detection problem, not the fix. **The fix is a comment.** The problem is that
nothing anywhere reports the state: GitHub's merge box says the pull request is
ready, every check is a green tick, Mergify's status comment describes a queue
that is doing something, and the fleet's own dashboards show a healthy pool. The
only surface that reports the truth is a human wondering why something has not
landed yet.

## The three states, and how to tell them apart

Every measured instance was one of exactly three. They look identical from the
pull request page and they have two different remedies.

### 1. Dequeued, terminally, on a failure that was not the diff

Mergify tests a queued pull request on a speculative draft branch —
`mergify/merge-queue/<sha>` — rebased on the queue's head. If that draft's CI
fails, Mergify **removes the pull request from the queue and does not try
again**. It says so, in a comment, once. There is no retry, no timer, and no
red check on the original pull request, because the failure happened on a
different branch.

That is correct behaviour when the draft failed because the code is broken. On
this fleet it usually did not. Measured over the same window on the same
repository, **87 of 122 merge-queue draft runs failed — 71%** — and sampling the
failures, they died at `Set up runner`, `Initialize containers`, `Complete
runner` or `Set up pnpm`. Not one of those is the diff. They are the fleet:
runner slots that accept a job and die holding it, in seven to twelve seconds,
having reached no test.

So the common case is a pull request evicted from the queue by a machine
failure, permanently, in silence. One sat **7h41m** in that state and another
**2h22m**; both moved only when somebody typed `@mergifyio queue`.

The related sub-case has no duration signature at all: a job **cancelled after
fifteen minutes with zero steps recorded**, which is a slot that took the job
and never ran it. Observed on `ci-runner-host-iit-pgs8-s1`, 2026-08-23.

**Remedy:** `@mergifyio queue`.

### 2. Still queued, and Mergify never noticed the last check go green

Mergify holds the entry, the draft's checks all complete, and Mergify does not
re-evaluate. Its own check run sits `in_progress` indefinitely.

PR #11259: last check green at **17:36:57**, Mergify's status comment last
updated at **17:33:01**, still open at **17:47**. It merged at **17:48:44** — 90
seconds after a `@mergifyio refresh`.

The tell, if you are looking by hand, is that Mergify's comment is *older* than
the newest completed check. There is no other one.

**Remedy:** `@mergifyio refresh`. This is the cheap nudge: it re-evaluates the
existing entry and keeps its place in line.

### 3. Never entered the queue at all

The pull request sits "under evaluation" indefinitely and no "Entered queue"
line ever appears. Same shape as 2 from the outside.

**Remedy:** `@mergifyio queue`, same as 1. Asking for a place a pull request
already holds is a no-op on Mergify's side, which is why the automation below
does not have to distinguish 1 from 3.

## A cause worth fixing separately: the queue draft on the wrong pool

Not a stall so much as a starvation, and it produces the same "waiting on a
check that finished" appearance.

A required `pull_request` workflow that hardcodes `runs-on: [self-hosted, linux,
gcp, <repo>]` targets the **CI pool**. On a Mergify draft that workflow still
runs, and it now competes for capacity with every ordinary pull request in the
repository. Measured on PR #11307: the `generic-binary` job was created at
**17:04:46** and started at **17:35:52** — **31 minutes 6 seconds queued** — for
a job that then took 65 seconds.

This is what the four-pool standard in
[`onboarding-a-repository.md`](onboarding-a-repository.md) exists to prevent,
and the reason that page says a queue pull request sharing the CI pool "does not
fail, it sits *pending*, which no red check anywhere reports."

**Remedy:** route it through the lane model like every other required workflow —
`runs-on: ${{ fromJSON(needs.lane.outputs.runner) }}` — and give it a
`timeout-minutes` tight enough that a starved job fails loudly instead of
waiting.

## What the fleet now does about it, without being asked

The controller sweeps every open pull request in its repository each tick
already, for the [parking detector](github-app-permissions.md). The stall rule
is that sweep's complement, in
`modules/ci-runner-host-pool/scripts/queue-stall-decision.sh`, and it **acts**:
it posts the nudge itself.

It lives in the control plane rather than in a scheduled workflow in each
consumer repository for three reasons, all of them the same reasons the parking
detector gives, with more force:

1. A workflow lives in the file the stalled repository is allowed to edit.
2. A workflow has to queue for a runner — on the very pool whose starvation is
   one of the causes.
3. A workflow has to be adopted by every future repository, one at a time. The
   controller covers a repository the moment the fleet serves it, with zero
   per-repository configuration, and a repository cannot switch it off.

### The two invariants

**A. Never nudge a pull request whose own head is not finished and green.**
Anything pending is somebody watching a spinner. Anything red is already
reported by a red check and is the author's to fix. The rule stays out of the
way for: a draft, a wrong base (both of which are the parking detector's to
report), zero checks, any pending check, any failed check, and any pull request
whose newest check completed less than `queue_stall_after_seconds` ago.

That last one is the whole difference between a control plane and a second actor
racing Mergify for the same pull request. Mergify reacts to a completed check in
seconds; the default settling window is **600 seconds**, generous on purpose,
because the failure being recovered from lasted hours.

**B. Never retry a failure that was the diff.** A dequeue earns an automatic
requeue only when the draft failed the way a machine fails. The signature is
`infra_dequeue`: a `failure`/`timed_out` that died in **90 seconds or less**, or
a `cancelled` job that completed **zero** steps.

Ninety seconds is far below the real gap rather than in the middle of it. Every
infrastructure failure in the measured sample died in 7–12 seconds having
reached no test; the fastest genuine failure in the same repository takes
minutes, because the build has to happen first. A job that fails before it could
plausibly have compiled anything did not fail on the diff. Being wrong in the
"call it real" direction costs a human one comment; being wrong the other way
spends a queue CI run.

An unknown is never a signature. An unparseable duration, an unreadable step
count, a conclusion the rule does not recognise — all of them mean "treat as
real" and leave it to a person.

**And the backstop:** three nudges per head commit, refreshes and requeues
sharing one budget. If the classification in B is ever drawn wrong, the pull
request burns three queue runs and then stops. It does not loop.

### What it needs from GitHub

`Pull requests: **Read & write**` on the fleet's App — the single upgrade
described in [`github-app-permissions.md`](github-app-permissions.md). It buys
exactly one endpoint, `POST /repos/{owner}/{repo}/issues/{number}/comments`.

It does **not** buy merging (that is `Contents: write`, which the App does not
hold and must not be given), pushing, or editing code. The worst a bug in this
rule can do is post a comment, and the ceiling bounds that at three.

Until the installation *accepts* the upgrade, the controller runs this exact
code and publishes its own denial rather than acting. Setting
`queue_stall_max_attempts = 0` produces the same observe-only behaviour
deliberately.

### What it publishes

Every series, every tick, zeros included — a metric that is absent when nothing
is wrong cannot be alerted on.

| Series | Read it as |
|---|---|
| `ci_queue_nudges{kind="refresh"\|"queue"}` | Merges that would otherwise have waited for somebody to notice. **Healthy at zero and expected to be non-zero anyway** — this is the size of the problem being absorbed, not an error count. Watch the trend: if it does not fall after a fleet fix, the fleet was not fixed. |
| `ci_queue_stalls_unresolved` | Stalls seen and not cleared — the comment was refused, or the queue run failed the way a build fails. **This is the one a human acts on**, because everything it counts stays stuck. |
| `ci_queue_stall_attempts_exhausted` | A pull request burned the whole budget on one head commit. Non-zero means invariant B let something through, or a repository is genuinely broken against its own base. Either way the automation has stopped and is saying so. |
| `ci_queue_stall_prs_skipped` | Pull requests the sweep did not examine this pass. Non-zero makes every number above a lower bound. |
| `ci_queue_stall_sweep_denied` | The App cannot do this. Almost always `Pull requests: write` missing or pending acceptance. |

## Doing it by hand

Still worth knowing, because the automation waits ten minutes and a human at a
keyboard does not have to.

1. Is every check on the head commit green? If no, this page does not apply.
2. Does Mergify's status comment have an "Entered queue" line, and is that
   comment **newer** than the newest completed check?
   * Comment older than the last green check → **`@mergifyio refresh`**.
   * No entry, or a dequeue comment → **`@mergifyio queue`**.
3. If it dequeued, open the `mergify/merge-queue/<sha>` draft's failed run
   before requeueing. If the failing step is `Set up runner`, `Initialize
   containers`, `Complete runner` or `Set up pnpm`, it was the fleet — requeue
   freely. If it is a test, it was the diff, and requeueing it just wastes a
   queue slot.
4. If a required job spent tens of minutes *queued* rather than running, the
   workflow is on the wrong pool. Fix the routing; requeueing will only buy the
   same wait again.
