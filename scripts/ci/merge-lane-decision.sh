# shellcheck shell=bash
# merge-lane — what to do with one candidate pull request, as PURE functions.
#
# WHY THIS FILE EXISTS
#
# This repository ran Mergify, and the thing Mergify could not be made to do is
# merge a green pull request promptly. Measured here on 2026-08-23, from the
# last required check reporting success to Mergify acting:
#
#   #328  11m06s      #332   8m55s
#   #326  17m24s      #333  20m01s
#
# and on a consumer repository over 2026-08-22..23 two pull requests that were
# green, unconflicted and unreviewed took 17h11m and 18h00m. The cause was never
# Mergify being slow to think: it reacts to its OWN merges in 13-14 seconds,
# measured three times out of three. It is slow to be TOLD. Mergify is a third
# party that learns about a check-run over a webhook, and a webhook that is
# missed or late leaves a fully green pull request sitting on "under evaluation"
# until a periodic re-evaluation minutes — sometimes tens of minutes — later.
#
# `mergify-nudge` was the attempt to fix that from outside, and it worked as far
# as it could: it capped the stall at roughly three and a half minutes by
# sleeping on a runner and then posting `@mergifyio refresh`. It could not do
# better, because a nudge cannot be sent before you have waited long enough to
# know a nudge is needed. Paying a runner to sleep in order to tell a vendor
# something GitHub already knows is the shape of the problem, not a fix for it.
#
# The second cost was worse than the latency. Mergify validates a queued pull
# request on a THROWAWAY DRAFT pushed to `mergify/merge-queue/<sha>` unless the
# queue is serial, unbatched and single-step — and every one of those drafts is
# a second full CI run. On the consumer repository above, 87 of 122 queue-draft
# runs FAILED, almost all of them at `Set up runner`, `Initialize containers` or
# `Complete runner`. That is the fleet, not the diff. A dequeue is terminal, so
# each of those failures parked a good pull request until a human typed
# `@mergifyio queue`. The speculative-draft model took the fleet's flakiness and
# multiplied it by the queue depth.
#
# So the queue moves into the repository. GitHub already knows CI finished — it
# is the thing that finished it — and a `workflow_run` trigger in the same
# repository is dispatched by GitHub itself, with no webhook to a third party in
# the path. The decision below is what that workflow asks about each candidate.
#
# WHY THE LOGIC IS HERE AND NOT IN THE WORKFLOW
#
# The same argument every other `*-decision.sh` in this fleet makes. A
# `workflow_run` workflow runs only from the DEFAULT BRANCH, so the pull request
# that changes it proves nothing about it and cannot: the first run is the first
# CI completion after the merge. Logic that lives in YAML is therefore logic
# that ships untested. Everything that DECIDES anything lives in these
# functions, `merge-lane-decision.selftest.sh` asserts them on a pull request
# that can actually run, and the workflow is left holding only the API calls.
#
# THE INVARIANTS
#
#  A. NEVER merge on anything but a required check that is GREEN ON THE HEAD SHA
#     that is about to be merged. Not "green recently", not "green on an earlier
#     push". `required_green` is counted by the caller against the head sha and
#     nothing else.
#
#  B. A MISSING required check is not a passing one. The most dangerous shape
#     here is a repository that renames a required check: every check present is
#     green, none is failing, and the gate silently stops gating. `missing` is
#     therefore a first-class input and it blocks.
#
#  C. NEVER merge a pull request whose base has moved without re-running its CI
#     against the moved base. That re-run is the ENTIRE reason a queue exists
#     rather than plain auto-merge, and it is what catches two sessions whose
#     changes pass alone and break together.
#
#  D. Validation happens IN PLACE, on the pull request's own branch. There is no
#     speculative draft, no `merge-queue/<sha>` ref, and therefore no second CI
#     run for a pull request whose base never moved — which is the common case.
#     A branch that is already current merges on the run that saw it go green.
#
# Tenancy-agnostic — no customer literals, no repository knowledge, no branch
# name beyond the base the caller passes in. Every threshold is an argument.

# ---------------------------------------------------------------------------
# lane_verdict — the whole rule, as one function over one pull request.
#
#   lane_verdict <draft> <base> <lane_base> <conflict> <required_total> \
#                <required_green> <missing> <failed> <pending> <behind> \
#                <inflight_age> <inflight_budget> [strict]
#
# draft            1 if the pull request is a draft, else 0
# base             the pull request's base branch
# lane_base        the branch this lane merges into
# conflict         1 if GitHub reports the branch unmergeable, 0 if mergeable,
#                  and "" if GitHub has not computed it yet (it is async)
# required_total   how many checks the lane requires, from configuration
# required_green   how many of them are green ON THE HEAD SHA
# missing          how many of them reported nothing at all on the head sha
# failed           how many of them failed, timed out or were cancelled
# pending          how many are still running
# behind           commits the base has that this branch does not
# inflight_age     seconds since this entry was last updated onto the base,
#                  or "" if it is not in flight
# inflight_budget  seconds an in-flight entry may take before it is dropped
# strict           1 if this base requires a branch to be UP TO DATE before it
#                  may merge, 0 if it does not. Defaults to 1, which is the
#                  behaviour this rule had before the argument existed.
#
#                  This is not a preference. It is GitHub's own
#                  `strict_required_status_checks_policy` on the base, and the
#                  lane must not be stricter than the branch it merges into:
#                  updating a branch that is allowed to merge behind throws away
#                  a green suite, spends a full CI run to rebuild the same
#                  answer, and moves the head sha — so on a busy repository the
#                  base has moved again before the run finishes and the pull
#                  request never converges. Measured on IntegrateIT 2026-08-25:
#                  ~20 of ~70 open pull requests sat in `update:behind` on every
#                  pass of a non-strict base, and the lane spent its whole
#                  action budget re-updating them instead of merging any.
#
# Prints exactly one `verdict:reason key=value...` line and returns 0. The
# caller never has to interpret an exit code, and an unparseable input is a
# verdict rather than a crash — a lane that dies on bad input stops merging
# everything, which is a worse failure than declining one pull request.
#
# Verdicts:
#   skip:*     not a candidate; the lane moves to the next pull request
#   wait:*     a candidate, but the answer is not known yet; leave it alone
#   update:*   a candidate whose base moved; update it and let CI re-run
#   drop:*     in flight for too long; release it and say so
#   merge:*    merge it now
# ---------------------------------------------------------------------------
lane_verdict() {
  local draft="${1:-}"
  local base="${2:-}"
  local lane_base="${3:-}"
  local conflict="${4:-}"
  local required_total="${5:-}"
  local required_green="${6:-}"
  local missing="${7:-}"
  local failed="${8:-}"
  local pending="${9:-}"
  local behind="${10:-}"
  local inflight_age="${11:-}"
  local inflight_budget="${12:-}"
  # Anything that is not an explicit 0 is strict, including an empty argument
  # from a caller that predates this parameter. Fail CLOSED: being needlessly
  # strict costs a CI run, while being wrongly permissive asks GitHub for a
  # merge it will refuse.
  local strict="${13:-1}"
  [ "$strict" = "0" ] || strict=1

  local n
  for n in "$required_total" "$required_green" "$missing" "$failed" "$pending" "$behind"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
      echo "skip:unparseable-counts total=$required_total green=$required_green missing=$missing failed=$failed pending=$pending behind=$behind"
      return 0
    fi
  done

  # A lane with nothing to require would merge on no evidence whatsoever. This
  # is configuration being empty or unreadable, not a pull request being ready,
  # and it fails CLOSED for every pull request until somebody fixes it.
  if [ "$required_total" -eq 0 ]; then
    echo "skip:no-required-checks-configured"
    return 0
  fi

  if [ -z "$base" ] || [ -z "$lane_base" ]; then
    echo "skip:no-base base=$base lane_base=$lane_base"
    return 0
  fi

  if [ "$base" != "$lane_base" ]; then
    echo "skip:base base=$base lane_base=$lane_base"
    return 0
  fi

  # A draft is the author saying "not yet" and it is checked BEFORE the
  # in-flight budget: a pull request converted to draft while the lane held it
  # should be released quietly, not reported as having timed out.
  if [ "$draft" = "1" ]; then
    echo "skip:draft"
    return 0
  fi

  # An entry that has been in flight past its budget is released before any
  # further judgement. Without this a pull request whose re-run never produces a
  # conclusion — a lost runner, a workflow that no longer exists on the moved
  # base — holds a serial lane forever, and everything behind it waits out a
  # decision nobody is going to make. This is `checks_timeout`, kept.
  #
  # `pending + missing > 0` is the load-bearing half of the condition, not a
  # refinement of it. The caller measures `inflight_age` from the head commit's
  # timestamp, because that is the only in-flight clock available without
  # storing state anywhere — and by that clock a pull request that was pushed
  # last week and is green today is very old indeed. Without this term the lane
  # would drop exactly the entries it should merge, and the older and more
  # patient the pull request, the more certainly it would be dropped. The budget
  # bounds WAITING, so it may only fire while something is still being waited
  # on.
  if [ -n "$inflight_age" ] && [ -n "$inflight_budget" ] && [ $((pending + missing)) -gt 0 ]; then
    if [[ "$inflight_age" =~ ^[0-9]+$ ]] && [[ "$inflight_budget" =~ ^[0-9]+$ ]]; then
      if [ "$inflight_age" -gt "$inflight_budget" ]; then
        echo "drop:budget-exceeded age=$inflight_age budget=$inflight_budget"
        return 0
      fi
    fi
  fi

  # GitHub computes mergeability asynchronously and reports null until it has.
  # Treating "not computed yet" as "no conflict" is how a lane merges into a
  # conflict; treating it as a conflict is how a lane skips a good pull request
  # forever. It is neither — it is a wait, and the next CI completion or sweep
  # asks again.
  if [ -z "$conflict" ]; then
    echo "wait:mergeability-unknown"
    return 0
  fi

  if [ "$conflict" = "1" ]; then
    echo "skip:conflict"
    return 0
  fi

  # Red before pending: a pull request with one failure and one still running is
  # not going to merge, and reporting it as `wait` would hold a serial lane for
  # the remaining runtime of a job whose verdict cannot change the outcome.
  if [ "$failed" -gt 0 ]; then
    echo "skip:red failed=$failed"
    return 0
  fi

  if [ "$pending" -gt 0 ]; then
    echo "wait:pending pending=$pending"
    return 0
  fi

  # Invariant B. Distinguished from `wait:pending` deliberately: pending is a
  # check that exists and is running, missing is a check that never reported.
  # The second is usually a renamed job or a path filter that skipped it, and
  # calling it `wait` would hide a permanent condition behind a word that means
  # "ask again later".
  if [ "$missing" -gt 0 ]; then
    echo "skip:missing-required missing=$missing total=$required_total"
    return 0
  fi

  if [ "$required_green" -lt "$required_total" ]; then
    echo "skip:not-all-green green=$required_green total=$required_total"
    return 0
  fi

  # Invariant C. Everything above was true of the head sha as it stands; this
  # asks whether the base it was true AGAINST is still the base it would merge
  # into. If not, the pull request is a candidate but not yet a merge: update it
  # and let its own CI answer the question again.
  #
  # ONLY when the base actually demands it. On a base whose required checks are
  # not strict, GitHub will merge a branch that is behind, so an update here
  # would be the lane inventing a rule the repository does not have — see the
  # `strict` argument for what that costs.
  if [ "$strict" = "1" ] && [ "$behind" -gt 0 ]; then
    echo "update:behind behind=$behind"
    return 0
  fi

  echo "merge:ready green=$required_green total=$required_total"
  return 0
}

# ---------------------------------------------------------------------------
# lane_admits — is this verdict one the lane acts on?
#
# The lane processes ONE pull request per acquisition of the lock, and this is
# how it picks. `merge` and `update` are actions; `drop` is an action too, since
# releasing a stuck entry is what lets the lane make progress next time.
# ---------------------------------------------------------------------------
lane_admits() {
  case "${1%%:*}" in
    merge | update | drop) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# lane_rank — the order candidates are considered in.
#
#   lane_rank <verdict> <priority> <age_seconds>
#
# Prints a sortable key, lowest first. Three fields, fixed width, so a plain
# `sort` orders them:
#
#   1. action class — an entry already in flight (`drop`) is resolved before a
#      fresh `merge`, and a `merge` before an `update`. Merging what is ready
#      before starting a re-run is what keeps a serial lane's throughput up: the
#      merge takes seconds, the update takes a CI run, and doing the update
#      first would make the ready pull request wait for it.
#   2. priority — the lane's own, which is a thing Mergify's serial queue could
#      not express and GitHub's cannot either. A docs-only fix does not queue
#      behind an infrastructure change.
#   3. age — oldest first, so nothing starves.
# ---------------------------------------------------------------------------
lane_rank() {
  local verdict="${1:-}"
  local priority="${2:-50}"
  local age="${3:-0}"
  local class

  case "${verdict%%:*}" in
    drop) class=0 ;;
    merge) class=1 ;;
    update) class=2 ;;
    *) class=9 ;;
  esac

  [[ "$priority" =~ ^[0-9]+$ ]] || priority=50
  [[ "$age" =~ ^[0-9]+$ ]] || age=0

  # Age descends so that oldest sorts first, and it is clamped rather than
  # allowed to underflow: a clock skew that made `age` larger than the ceiling
  # would otherwise wrap and send the newest pull request to the front.
  local inverted=$((99999999 - age))
  [ "$inverted" -ge 0 ] || inverted=0

  printf '%d:%03d:%08d\n' "$class" "$priority" "$inverted"
}

# ---------------------------------------------------------------------------
# lane_pass_expired — has this pass spent its walking budget?
#
#   lane_pass_expired <started_epoch> <budget_seconds> <now_epoch>
#
# Returns 0 (expired) or 1 (keep going).
#
# WHY A PASS NEEDS A BUDGET OF ITS OWN.
#
# The lane reads the WHOLE open list on every pass and spends roughly five API
# calls on each candidate it does not skip early. That cost tracks the size of
# the repository, not the depth of the queue, and the job it runs in has a
# `timeout-minutes` ceiling. Measured on `IntegrateIT` on 2026-08-25 with ~35
# open pull requests: every single pass ran past fifteen minutes and was killed
# — thirty runs in a row, not one of them reaching the merge call.
#
# A killed job is the worst possible way for this to end, and not because of the
# lost work. **A `timeout-minutes` kill is reported by GitHub as `cancelled`, not
# as `failure`** — the same conclusion an operator pressing the button produces,
# and the same one the `concurrency` group produces when it evicts a pending
# run. So a lane dying of its own weight looks exactly like a lane behaving
# correctly under load, no annotation is written, no summary is published, and
# the queue issue keeps whatever it last said. It is invisible by construction.
#
# The fix is for the lane to run out of time BEFORE the job does, so that it
# ends on its own terms: it stops walking, says how much of the list it read,
# still acts on the best candidate it found, publishes the queue and exits
# green. A truncated pass is not an error — it is a busy repository — but it
# must be a truncated pass that SAYS SO.
#
# A budget of 0 disables the deadline, for a repository that would rather the
# job's own ceiling be the only limit. That is the old behaviour, available on
# purpose, and it is not the default.
#
# Everything is validated rather than trusted: a non-numeric budget is a
# misconfigured input, and the safe reading of one is "no deadline", never "the
# deadline already passed" — an accidental 0-second budget that expired on the
# first candidate would make the lane read nothing and merge nothing, silently,
# which is the failure this function exists to end.
# ---------------------------------------------------------------------------
lane_pass_expired() {
  local started="${1:-}" budget="${2:-}" now="${3:-}"

  [[ "$budget" =~ ^[0-9]+$ ]] || return 1
  [ "$budget" -gt 0 ] || return 1
  [[ "$started" =~ ^[0-9]+$ ]] || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1

  local spent=$((now - started))
  # A clock that went backwards reads as "no time has passed", never as an
  # expiry: the runner's clock stepping is not a reason to stop reading.
  [ "$spent" -ge 0 ] || return 1

  [ "$spent" -ge "$budget" ]
}

# ---------------------------------------------------------------------------
# lane_review_gate — may a green pull request merge before the automated
# reviewers have said anything about the code that is about to land?
#
#   lane_review_gate <expected> <answered> <age> <grace> [unavailable]
#
# expected   how many reviewer identities this repository waits for, from
#            configuration. 0 means the gate is not armed.
# answered   how many of them have published something ABOUT THE HEAD SHA.
#            Includes `unavailable`: reporting that you cannot review is an
#            answer, and it is the one answer that will never change on its own.
# age        seconds since the review could have started — the moment the last
#            required check finished, not the moment the branch was pushed.
#            "" when the caller could not read it.
# grace      seconds to wait before merging unreviewed anyway.
# unavailable how many of `answered` answered by declining — optional, defaults
#            to 0, and it changes no decision. It rides through so the verdict
#            line distinguishes "reviewed" from "nobody could review", which are
#            the same merge and completely different operationally.
# stale      how many EXPECTED reviewers reviewed an earlier commit on this pull
#            request and were never asked about this head — optional, defaults
#            to 0, and it too changes no decision. It is disjoint from
#            `answered`: a review of an older tree says nothing about the new
#            one. It rides through because `answered=0` alone cannot tell an
#            operator tell a reviewer that is DOWN apart from one that is
#            healthy and was simply not asked, and the annotation this feeds is
#            documented to mean the first.
#
# WHY THIS EXISTS
#
# Codex reviews cost credits, so this fleet stopped asking for one until CI is
# green: a red pull request is going to be pushed again, and a review of code
# nobody will keep is a review paid for twice. That change moves the review to
# the same instant the lane decides to merge — both are dispatched by the same
# `workflow_run` on CI completion — and a review that arrives after the merge
# is not a review. Hence a gate: green is necessary, no longer sufficient.
#
# AND WHY IT FAILS OPEN, WHICH IS UNLIKE EVERYTHING ELSE IN THIS FILE.
#
# Every other gate here fails CLOSED, because the cost of being wrong is
# merging something unchecked. This one cannot. The reviewers are third parties
# outside the repository, and the operator was explicit about the case that
# decides the direction: Codex runs out of credits and then NOTHING is ever
# published, for any pull request, indefinitely. A gate that failed closed on
# that would stop the fleet merging until somebody noticed and reached for the
# variable — a vendor's billing page silently becoming this repository's merge
# authority.
#
# So the wait is bounded and the expiry is loud. Past `grace` the lane merges
# and says it merged unreviewed, which is a line an operator can find. The
# required checks have not moved: this gate only ever delays a merge that
# invariants A through D have already approved.
#
# An unreadable clock is treated as EXPIRED for the same reason. The failure
# mode of the other reading is a lane that holds every green pull request
# forever over a missing timestamp, and nothing in a hold announces itself the
# way a merge does.
#
# Prints one `review:reason key=value...` line and returns 0. `hold` is the only
# verdict that stops a merge.
#
# Verdicts:
#   review:off              nothing configured; the gate is not armed
#   review:answered         every expected reviewer has answered this sha —
#                           with `unavailable=n` when n of them answered by
#                           reporting they could not review it
#   review:hold             still waiting, inside the grace
#   review:unreviewed       the grace is spent; merge anyway, and say so
# ---------------------------------------------------------------------------
lane_review_gate() {
  local expected="${1:-}" answered="${2:-}" age="${3:-}" grace="${4:-}" unavailable="${5:-0}" stale="${6:-0}"
  local unavail_note='' stale_note=''
  # Same shape and same reason as `unavail_note`: a count, carried into the
  # verdict line, deciding nothing. It is the difference between "no reviewer
  # answered" and "the reviewer answered an earlier commit and was not asked
  # about this one", which are the same merge and completely different things
  # for an operator to go and look at.
  if [[ "$stale" =~ ^[0-9]+$ ]] && [ "$stale" -gt 0 ]; then
    stale_note=" stale=$stale"
  fi
  # Reported only when it is a number and non-zero. A garbled value must not
  # appear in a verdict line that an operator reads as fact. An `if`, not a
  # `&&` chain: this file is sourced into `set -e`, where a chain that ends
  # false is a non-zero command and would abort the pass.
  if [[ "$unavailable" =~ ^[0-9]+$ ]] && [ "$unavailable" -gt 0 ]; then
    unavail_note=" unavailable=$unavailable"
  fi

  # Not armed, or armed with something unreadable. A repository that has not
  # asked for this gate must not have it, and a garbled count is not a request.
  if ! [[ "$expected" =~ ^[0-9]+$ ]] || [ "$expected" -eq 0 ]; then
    echo "review:off"
    return 0
  fi

  # An unreadable answer count is not "nobody answered" — it is the caller
  # having failed to read the API, and holding on that is the deadlock this
  # gate must never produce.
  if ! [[ "$answered" =~ ^[0-9]+$ ]]; then
    echo "review:unreviewed reason=unreadable expected=$expected"
    return 0
  fi

  if [ "$answered" -ge "$expected" ]; then
    echo "review:answered answered=$answered expected=$expected$unavail_note"
    return 0
  fi

  # Fail open, both ways: a clock the caller could not read and a grace that is
  # not a number both mean the lane proceeds rather than stalls.
  if ! [[ "$age" =~ ^[0-9]+$ ]] || ! [[ "$grace" =~ ^[0-9]+$ ]]; then
    echo "review:unreviewed reason=no-clock answered=$answered expected=$expected$unavail_note$stale_note"
    return 0
  fi

  if [ "$age" -ge "$grace" ]; then
    echo "review:unreviewed reason=grace-expired answered=$answered expected=$expected age=$age grace=$grace$unavail_note$stale_note"
    return 0
  fi

  echo "review:hold answered=$answered expected=$expected age=$age grace=$grace$unavail_note$stale_note"
  return 0
}
