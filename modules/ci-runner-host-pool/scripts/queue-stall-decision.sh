# shellcheck shell=bash
# ci-runner-host-pool — the controller's MERGE-QUEUE STALL rule, as PURE
# functions.
#
# WHY THIS FILE EXISTS
#
# parked-decision.sh next door answers "the queue will never admit this pull
# request". This one answers the opposite and far more common case: the queue
# ADMITTED it, or would, and then stopped moving. Measured on one consumer
# repository over 2026-08-22..23, two pull requests whose own CI was green took
# 17h11m and 18h00m to merge. Neither was waiting on a review, a conflict or a
# red check. Both spent the time in one of exactly three states:
#
#   1. Mergify dequeued the pull request because the speculative draft's CI
#      failed — and on that repository 87 of 122 queue-draft runs failed, almost
#      all of them at `Set up runner`, `Initialize containers` or `Complete
#      runner`, i.e. the FLEET, not the diff. A dequeue is terminal: Mergify
#      says so in a comment and never tries again. One pull request sat 7h41m in
#      that state, another 2h22m, and both moved only when a human typed
#      `@mergifyio queue`.
#
#   2. Mergify held the entry, the draft's last check went green, and Mergify
#      never noticed. #11259 was green at 17:36:57 and still sitting at 17:47;
#      it merged 90 seconds after a human typed `@mergifyio refresh`.
#
#   3. The pull request never entered the queue at all, sitting "under
#      evaluation" indefinitely — the same remedy as 2.
#
# In all three the pull request is OPEN, ADMISSIBLE and GREEN, every surface
# reports health, and the only thing missing is somebody to poke Mergify. That
# is a control-plane job, not a human one.
#
# WHY THE CONTROLLER AND NOT A WORKFLOW
#
# The same reason parked-decision.sh gives, and it applies with more force here
# because this rule ACTS rather than reports. A scheduled workflow in the
# consumer repository would live in the file the stalled repository is allowed
# to edit, would queue for a runner on the very pool whose starvation is one of
# the causes, and would have to be re-adopted by every future repository. The
# controller already holds an installation token, already sweeps this
# repository every tick, and a repository cannot switch it off.
#
# THE TWO INVARIANTS
#
#  A. NEVER nudge a pull request whose own head is not finished and green.
#     Anything pending is somebody watching a spinner; anything red is already
#     reported by a red check and is the author's to fix. Auto-requeueing a
#     genuinely broken pull request is how a queue that was merely slow becomes
#     a queue that is also wrong.
#
#  B. NEVER retry a failure that was the DIFF. A dequeue earns a free requeue
#     only when the draft failed the way a machine fails, not the way a test
#     fails. `infra_dequeue` below is that line, and the attempt ceiling is the
#     backstop for when it is drawn wrong.
#
# Tenancy-agnostic — no customer literals, no repository knowledge, no branch
# name. Every threshold is an argument.

# infra_dequeue <conclusion> <seconds_elapsed> <steps_completed>
#
#   conclusion      : the check run's conclusion — failure, cancelled,
#                     timed_out, action_required, success, …
#   seconds_elapsed : completed_at - started_at for that check run.
#   steps_completed : how many steps the job got through, or the empty string
#                     when the caller could not tell. Empty is NOT zero; see
#                     below.
#
# Answers ONE question: does this failed check bear the signature of the fleet
# rather than the code? Exit 0 = infrastructure, exit 1 = treat as real.
#
# WHY DURATION AND NOT THE STEP NAME
#
# The honest signature is the step that failed — `Set up runner`, `Initialize
# containers`, `Complete runner`, `Set up pnpm`. Reading it costs a
# `runs/{id}/jobs` call per candidate on top of the check-runs call, and the
# duration is a proxy that separates the two populations cleanly on the measured
# data: every infrastructure failure in the sample died in 7–12 seconds, having
# never reached a test, while the fastest genuine failure in the same repository
# takes minutes because the build has to happen first. A job that fails before
# it could plausibly have compiled anything did not fail on the diff.
#
# The threshold is deliberately far below the real gap rather than in the middle
# of it. Being wrong in the "call it real" direction costs a human one
# `@mergifyio queue`; being wrong the other way spends a queue CI run on a
# broken pull request, and there are three of those to spend before the ceiling
# stops it.
#
# The second arm is a job that was CANCELLED having completed no steps. That is
# the shape of a slot that accepted the job and then died holding it — 15
# minutes on `ci-runner-host-iit-pgs8-s1` with not one step recorded, on
# 2026-08-23 — and it has no duration signature at all, because the wall clock
# it burns is the fleet's, not the build's. `steps_completed` empty means the
# caller does not know, and an unknown must not be read as zero: a cancelled job
# that DID run steps was most likely cancelled by a newer commit, which is
# ordinary and not ours to retry.
INFRA_MAX_SECONDS_DEFAULT=90

infra_dequeue() {
  local conclusion="${1:-}"
  local elapsed="${2:-}"
  local steps="${3:-}"
  local max="${4:-$INFRA_MAX_SECONDS_DEFAULT}"

  case "$conclusion" in
    failure | timed_out)
      # Unparseable duration is not a signature. Say "real" and let a human
      # decide, rather than manufacture a retry out of a jq failure.
      [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
      [ "$elapsed" -le "$max" ]
      return
      ;;
    cancelled)
      [ "$steps" = "0" ]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

# stall_verdict <draft> <base> <queue_base> <total> <failed> <pending> \
#               <mq_state> <idle_seconds> <stall_after> <attempts> <max_attempts> \
#               [behind]
#
#   draft, base, queue_base, total, failed, pending
#                 : exactly as parked_verdict takes them, and read the same way.
#   mq_state      : the state of Mergify's own check run on this head —
#                   `absent`, `in_progress`, or `completed`. Anything else is
#                   read as "we do not know", which is a keep-quiet.
#   idle_seconds  : how long since the NEWEST non-Mergify check run on this head
#                   completed. This is the clock that matters: it starts when
#                   the pull request became fully green, not when it was opened,
#                   so a pull request that has just gone green is never nudged
#                   and a queue working normally always wins the race.
#   stall_after   : how long that may last before this is a stall.
#   attempts      : nudges already spent on THIS head sha.
#   max_attempts  : the ceiling. Zero disables acting entirely, which is the
#                   configuration a repository gets when the installation holds
#                   no write permission.
#   behind        : accepted and deliberately IGNORED. It is the shape of the
#                   escalation this rule declines to make: rebasing a stalled
#                   pull request would produce a new head commit that the queue
#                   cannot miss, and it would also discard a green suite, spend
#                   a full re-run, and put the fleet in the business of writing
#                   to somebody's branch. The fleet does not touch git.
#
#                   It is accepted rather than rejected because the question it
#                   answers is a real one and will be asked again: when a status
#                   never arrives at all, the queue is not stalled, it is
#                   waiting, and the answer there is to make the JOB report —
#                   never to rewrite the branch under it.
#
# Echoes one of:
#   nudge:refresh <detail>   — Mergify holds the entry and has not looked
#   nudge:queue <detail>     — nothing holds it; ask for a place in the queue
#   quiet:<reason> <detail>  — say nothing, do nothing
#
# Always exits 0: the verdict is the output, like every other rule here.
stall_verdict() {
  local draft="${1:-}"
  local base="${2:-}"
  local queue_base="${3:-}"
  local total="${4:-}"
  local failed="${5:-}"
  local pending="${6:-}"
  local mq_state="${7:-}"
  local idle="${8:-}"
  local stall_after="${9:-}"
  local attempts="${10:-}"
  local max_attempts="${11:-}"
  # shellcheck disable=SC2034  # accepted and deliberately unread; see the
  # header. Bound rather than dropped so the signature keeps a place for the
  # question, and so a caller that passes it gets the documented no-op instead
  # of silently shifting an argument onto some other parameter.
  local behind="${12:-}"

  local n
  for n in "$total" "$failed" "$pending" "$idle" "$stall_after" "$attempts" "$max_attempts"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
      echo "quiet:unparseable-counts total=$total failed=$failed pending=$pending idle=$idle after=$stall_after attempts=$attempts max=$max_attempts"
      return 0
    fi
  done
  if [ -z "$queue_base" ] || [ -z "$base" ]; then
    echo "quiet:no-base base=$base queue_base=$queue_base"
    return 0
  fi

  # 1. Admissibility, which is parked_verdict's job and not this one's. A draft
  #    or a wrong base is REPORTED next door and must not be nudged here: asking
  #    Mergify to queue a pull request it has correctly refused would produce a
  #    comment every sweep forever, on a repository that already has a signal
  #    telling it what to fix.
  if [ "$draft" = "1" ]; then
    echo "quiet:draft"
    return 0
  fi
  if [ "$base" != "$queue_base" ]; then
    echo "quiet:base base=$base queue_base=$queue_base"
    return 0
  fi

  # 2. Invariant A. Every arm is a reason to stay out of the way.
  if [ "$total" -eq 0 ]; then
    echo "quiet:no-checks"
    return 0
  fi
  if [ "$pending" -gt 0 ]; then
    echo "quiet:in-flight pending=$pending"
    return 0
  fi
  if [ "$failed" -gt 0 ]; then
    echo "quiet:red failed=$failed"
    return 0
  fi

  # 3. Green. Has it been green long enough that the queue not having moved is a
  #    fact rather than a race? Mergify reacts to a check completing in seconds,
  #    so this threshold is not tuning — it is the whole difference between a
  #    control plane and a second thing fighting Mergify for the same pull
  #    request.
  if [ "$idle" -lt "$stall_after" ]; then
    echo "quiet:settling idle=$idle after=$stall_after"
    return 0
  fi

  # 4. The ceiling, checked BEFORE the state split so that both nudges share
  #    one budget. Three refreshes and three requeues on one head sha is six
  #    comments on a pull request nobody is helping.
  if [ "$attempts" -ge "$max_attempts" ]; then
    echo "quiet:exhausted attempts=$attempts max=$max_attempts"
    return 0
  fi

  case "$mq_state" in
    in_progress)
      # Mergify believes it is still checking this entry, and the thing it is
      # waiting for finished $idle seconds ago. Refresh, which is the cheap
      # nudge: it re-evaluates the existing entry and keeps its place in line.
      echo "nudge:refresh mq=in_progress idle=$idle attempts=$attempts"
      ;;
    absent | completed)
      # No live entry. Either it was dequeued and Mergify will never try again,
      # or it never entered. Both want the same command, and asking for a place
      # a pull request already holds is a no-op on Mergify's side.
      echo "nudge:queue mq=$mq_state idle=$idle attempts=$attempts"
      ;;
    *)
      echo "quiet:unknown-queue-state mq=$mq_state"
      ;;
  esac
  return 0
}
