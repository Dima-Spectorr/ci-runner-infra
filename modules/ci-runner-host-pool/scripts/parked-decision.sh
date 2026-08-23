#!/usr/bin/env bash
# ci-runner-host-pool — the controller's MERGE-QUEUE PARKING rule, as a PURE
# function.
#
# WHY THIS FILE EXISTS
#
# Every other rule in this directory answers a question about a machine. This
# one answers a question about a pull request, and it is here because twice in
# one week a repository reported "CI is making no progress" and CI was fine.
#
# The merge queue admits a pull request only when its entry conditions hold —
# `base = <the queue's branch>`, `-draft`, `-conflict`. When one of them is
# false Mergify does not report a failure. It reports NEUTRAL, which renders as
# a grey dot beside forty green ticks. There is no red check, no comment and no
# timer, so a pull request that is complete, green and permanently parked looks
# exactly like a pull request that is about to merge. Both repositories found
# out days later, from a human wondering why something had not landed.
#
# One consumer repository had two pull requests parked as green DRAFTS, the
# older of them for three days. This module's own #299 was parked with its BASE
# pointing at a sibling feature branch. Neither repository had a failing job.
#
# WHY THE CONTROLLER AND NOT A WORKFLOW
#
# A scheduled workflow in the consumer repository would be simpler and would
# report where the author is already looking. It would also live in the file
# the misconfigured repository is allowed to edit, which defeats the purpose:
# the contract this fleet offers a consumer repository is minimum configuration
# and no way for that repository to break the mechanism. The controller already
# holds an installation token and already sweeps this repository every tick, so
# the marginal cost is one list call per interval and the repository cannot
# switch it off.
#
# WHAT IT DELIBERATELY DOES NOT DETECT
#
# `-conflict`. Answering it costs a GET per pull request (the list payload has
# no `mergeable`), and a conflicted branch runs no CI at all — zero check runs,
# which this rule already reads as "not green" and stays quiet about. GitHub's
# own merge box says "This branch has conflicts" in red, so it is the one entry
# condition that is not silent.
#
# THE ONE INVARIANT
#
# Silence unless the pull request is FINISHED and STUCK. Anything in flight,
# anything red, and anything with no checks at all is somebody's work in
# progress, and nagging about it is how a signal gets muted. The only reportable
# state is: every check completed, none of them failed, and the queue will never
# take it.
#
# Tenancy-agnostic — no customer literals, no repository knowledge. The queue's
# branch is an argument, not `main`.

# parked_verdict <draft> <base_ref> <queue_base> <checks_total> <checks_failed> \
#                <checks_pending>
#
#   draft         : 1 if the pull request is a draft, 0 if not. Anything else is
#                   read as "we do not know", which is a keep-quiet.
#   base_ref      : the branch the pull request targets.
#   queue_base    : the branch the merge queue admits. Configured per
#                   repository; never a literal in this file.
#   checks_total  : check runs on the head commit.
#   checks_failed : those that concluded failure, cancelled, timed_out or
#                   action_required. Neutral and skipped are NOT failures —
#                   GitHub does not treat them as blocking and neither does the
#                   queue, so counting them here would report a parked pull
#                   request as red and say nothing.
#   checks_pending: those not yet completed.
#
# Echoes "parked:<reason>" or "quiet:<reason>". Always exits 0 — the verdict is
# the output, not the status, exactly like the other rules in this directory.
parked_verdict() {
  local draft="${1:-}"
  local base="${2:-}"
  local queue_base="${3:-}"
  local total="${4:-}"
  local failed="${5:-}"
  local pending="${6:-}"

  # 0. Nothing numeric can be compared, so nothing is claimed. A caller that
  #    passes a malformed count gets silence, not a report — this rule exists to
  #    add a signal, and a signal that fires on its own bugs is worse than the
  #    grey dot it replaces.
  local n
  for n in "$total" "$failed" "$pending"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
      echo "quiet:unparseable-counts total=$total failed=$failed pending=$pending"
      return 0
    fi
  done
  if [ -z "$queue_base" ]; then
    echo "quiet:no-queue-base"
    return 0
  fi
  if [ -z "$base" ]; then
    echo "quiet:no-base"
    return 0
  fi

  # 1. Which entry conditions this pull request fails. Computed BEFORE the green
  #    gate because it is the free half: it comes out of the list payload the
  #    sweep already holds, where the check counts cost a call each. A pull
  #    request that fails nothing is dropped here and never billed for.
  local reason=""
  if [ "$draft" = "1" ]; then
    reason="draft"
  fi
  if [ "$base" != "$queue_base" ]; then
    if [ -n "$reason" ]; then
      reason="draft-and-base"
    else
      reason="base"
    fi
  fi
  if [ -z "$reason" ]; then
    echo "quiet:admissible base=$base draft=$draft"
    return 0
  fi

  # 2. It cannot enter the queue. Now the green gate, and every arm of it is a
  #    reason to say nothing.
  #
  # 2a. No checks ran. Either nothing is wired up, or the branch conflicts and
  #     GitHub refused to run anything — the second is the case this rule leans
  #     on to stay out of the conflict business. A pull request with no CI is
  #     not a pull request whose CI is misleading anyone.
  if [ "$total" -eq 0 ]; then
    echo "quiet:no-checks reason=$reason"
    return 0
  fi

  # 2b. Still running. The author is watching a spinner, which is an honest
  #     report of the state.
  if [ "$pending" -gt 0 ]; then
    echo "quiet:in-flight pending=$pending reason=$reason"
    return 0
  fi

  # 2c. Red. There is already a failure on the page; a second signal saying the
  #     queue will not take it adds nothing and trains people to ignore this
  #     one.
  if [ "$failed" -gt 0 ]; then
    echo "quiet:red failed=$failed reason=$reason"
    return 0
  fi

  # 3. Finished, green, and inadmissible. This is the state that reports as
  #    health from every surface that reports at all.
  echo "parked:$reason base=$base queue_base=$queue_base checks=$total"
  return 0
}
