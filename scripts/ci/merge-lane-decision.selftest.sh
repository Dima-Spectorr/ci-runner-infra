#!/usr/bin/env bash
# Self-test for the merge lane's per-pull-request rule.
#
# This rule MERGES. It is the only decision in this repository whose wrong
# answer lands code on the default branch, and the workflow that calls it runs
# only from the default branch — so the pull request that changes it cannot
# exercise it even once. These cases are the entire test.
#
# The weighting follows the blast radius rather than the code paths. Every arm
# that returns `merge` is tested against the ONE-OFF of each count it compares,
# because the interesting bug here is not "does a green pull request merge" but
# "does a pull request that is one check short of green merge anyway". The
# `skip` and `wait` arms are cheap to get wrong and cheap to fix; `merge` is
# neither.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/merge-lane-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(lane_verdict "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: draft base lane_base conflict total green missing failed pending behind
#       inflight_age inflight_budget
LB=main

# --- the one verdict that lands code ------------------------------------------
expect "merge:ready" "three required checks green, current with the base, nothing pending" \
  0 "$LB" "$LB" 0 3 3 0 0 0 0 "" 1800
expect "merge:ready" "a single required check is a legitimate configuration" \
  0 "$LB" "$LB" 0 1 1 0 0 0 0 "" 1800
expect "merge:ready" "in flight, within budget, and now green — the second half of an update" \
  0 "$LB" "$LB" 0 3 3 0 0 0 0 60 1800

# --- one off each count, where a wrong comparison would merge -----------------
# Invariant A. Each of these differs from the merge case above by exactly one.
expect "skip:not-all-green" "two of three green is not green, and > would merge it" \
  0 "$LB" "$LB" 0 3 2 0 0 0 0 "" 1800
expect "skip:missing-required" "a renamed required check reports nothing and must not pass" \
  0 "$LB" "$LB" 0 3 2 1 0 0 0 "" 1800
expect "skip:red" "one failure among greens" \
  0 "$LB" "$LB" 0 3 2 0 1 0 0 "" 1800
expect "wait:pending" "one still running" \
  0 "$LB" "$LB" 0 3 2 0 0 1 0 "" 1800
expect "update:behind" "one commit behind is behind — >0, not some tolerance" \
  0 "$LB" "$LB" 0 3 3 0 0 0 1 "" 1800

# --- strict, and only as strict as the base -----------------------------------
# The lane must not invent a rule the repository does not have. A base whose
# required checks are not strict merges a branch that is behind, so updating it
# would discard a green suite and spend a full CI run to rebuild the same
# answer — which on a busy repository is a pull request that never converges.
# Measured on IntegrateIT 2026-08-25: the whole action budget went on updates
# and nothing merged.
expect "merge:ready" "green and behind merges when the base is not strict" \
  0 "$LB" "$LB" 0 3 3 0 0 0 60 "" 1800 0
expect "update:behind" "green and behind updates when the base IS strict" \
  0 "$LB" "$LB" 0 3 3 0 0 0 60 "" 1800 1
# Fail closed, in both of the ways a caller can decline to answer.
expect "update:behind" "an omitted strict argument is strict — the old signature" \
  0 "$LB" "$LB" 0 3 3 0 0 0 60 "" 1800
expect "update:behind" "an empty strict argument is strict, not permissive" \
  0 "$LB" "$LB" 0 3 3 0 0 0 60 "" 1800 ""
# Strictness is the LAST question, never a way past a red or a missing check.
expect "skip:red" "a non-strict base does not merge something red" \
  0 "$LB" "$LB" 0 3 2 0 1 0 60 "" 1800 0
expect "skip:missing-required" "a non-strict base does not merge a missing check" \
  0 "$LB" "$LB" 0 3 2 1 0 0 60 "" 1800 0
expect "wait:pending" "a non-strict base still waits on a running check" \
  0 "$LB" "$LB" 0 3 2 0 0 1 60 "" 1800 0
expect "skip:conflict" "a non-strict base does not merge a conflict" \
  0 "$LB" "$LB" 1 3 3 0 0 0 60 "" 1800 0

# Invariant B, stated on its own. This is the shape that makes a gate stop
# gating in silence: nothing is failing, nothing is running, and the checks the
# lane was told to require simply are not there.
expect "skip:missing-required" "every check missing, none red — the silent ungating" \
  0 "$LB" "$LB" 0 3 0 3 0 0 0 "" 1800

# --- fail closed --------------------------------------------------------------
# A lane that requires nothing merges on no evidence. Configuration that failed
# to load looks exactly like this, and it must stop the lane rather than open it.
expect "skip:no-required-checks-configured" "zero required checks is broken config, not consent" \
  0 "$LB" "$LB" 0 0 0 0 0 0 0 "" 1800

for bad in "" x -1 3.5 " " 1e2; do
  expect "skip:unparseable-counts" "a non-integer green count ('$bad') declines, never crashes" \
    0 "$LB" "$LB" 0 3 "$bad" 0 0 0 0 "" 1800
  expect "skip:unparseable-counts" "a non-integer behind count ('$bad') declines too" \
    0 "$LB" "$LB" 0 3 3 0 0 0 "$bad" "" 1800
done

# --- ordering of the guards ---------------------------------------------------
# Each of these is green-and-current on every axis except one, so the verdict
# names which guard fired. Getting the ORDER wrong is how a draft gets reported
# as a timeout, or a conflicted pull request gets updated pointlessly.
expect "skip:base" "a pull request onto a sibling branch is not this lane's" \
  0 release/9 "$LB" 0 3 3 0 0 0 0 "" 1800
expect "skip:draft" "a green draft is the author saying not yet" \
  1 "$LB" "$LB" 0 3 3 0 0 0 0 "" 1800
expect "skip:draft" "drafting a pull request the lane holds releases it quietly, not as a drop" \
  1 "$LB" "$LB" 0 3 3 0 0 0 9999 1800
expect "drop:budget-exceeded" "an in-flight entry past budget is released before anything else" \
  0 "$LB" "$LB" 0 3 0 3 0 1 1 9999 1800
# Exactly at budget is within it. Tested with a check still pending, because
# that is the only state in which the budget arm is reachable at all.
expect "wait:pending" "exactly at budget is within it — > not >=, so a boundary tick does not drop" \
  0 "$LB" "$LB" 0 3 2 0 0 1 0 1800 1800
expect "drop:budget-exceeded" "one second past it does drop" \
  0 "$LB" "$LB" 0 3 2 0 0 1 0 1801 1800

# The budget bounds WAITING, and the caller's only in-flight clock is the head
# commit's timestamp — so a pull request pushed long ago and green today is
# ancient by that clock. If the budget could fire without something outstanding,
# the lane would drop precisely the entries it exists to merge, and the longer a
# pull request had waited the more certainly it would be dropped.
expect "merge:ready" "an old but finished-and-green pull request merges; age alone is not a drop" \
  0 "$LB" "$LB" 0 3 3 0 0 0 0 987654 1800
expect "drop:budget-exceeded" "the same age with one check still pending IS a drop" \
  0 "$LB" "$LB" 0 3 2 0 0 1 0 987654 1800
expect "drop:budget-exceeded" "and with a required check that never reported" \
  0 "$LB" "$LB" 0 3 2 1 0 0 0 987654 1800
expect "skip:red" "a red pull request is skipped on its own terms, not dropped for age" \
  0 "$LB" "$LB" 0 3 2 0 1 0 0 987654 1800
expect "skip:red" "red outranks pending: the outcome cannot change, so do not hold the lane" \
  0 "$LB" "$LB" 0 3 1 0 1 1 0 "" 1800
expect "skip:conflict" "a conflict is skipped before its checks are consulted" \
  0 "$LB" "$LB" 1 3 3 0 0 0 0 "" 1800

# --- mergeability is a tri-state, and the middle value is the dangerous one ---
# GitHub computes this asynchronously and answers null until it has. Reading
# null as "mergeable" merges into a conflict; reading it as "conflict" skips a
# good pull request forever. It is a wait.
expect "wait:mergeability-unknown" "null mergeability is not a green light" \
  0 "$LB" "$LB" "" 3 3 0 0 0 0 "" 1800
expect "wait:mergeability-unknown" "and not a red one either, even with everything else ready" \
  0 "$LB" "$LB" "" 3 3 0 0 0 5 "" 1800

# --- an absent in-flight budget must not become a drop ------------------------
expect "merge:ready" "no in-flight age means not in flight, not infinitely old" \
  0 "$LB" "$LB" 0 3 3 0 0 0 0 "" 1800
expect "merge:ready" "an unparseable age is ignored rather than treated as expired" \
  0 "$LB" "$LB" 0 3 3 0 0 0 0 abc 1800
expect "merge:ready" "no budget configured means no budget enforced" \
  0 "$LB" "$LB" 0 3 3 0 0 0 0 99999 ""

# --- lane_admits --------------------------------------------------------------
admits() {
  local want="$1" desc="$2" verdict="$3"
  local got=no
  lane_admits "$verdict" && got=yes
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  verdict: %s\n  want: %s\n  got: %s\n' "$desc" "$verdict" "$want" "$got"
  fi
}

admits yes "merge is an action" "merge:ready green=3 total=3"
admits yes "update is an action — it starts a CI run" "update:behind behind=2"
admits yes "drop is an action — releasing a stuck entry is progress" "drop:budget-exceeded age=2 budget=1"
admits no  "wait is explicitly not an action" "wait:pending pending=1"
admits no  "nor is an unknown mergeability" "wait:mergeability-unknown"
admits no  "skip is not an action" "skip:draft"
admits no  "and neither is an empty verdict" ""
admits no  "a verdict that merely CONTAINS merge is not a merge" "skip:premerge-hook"

# --- lane_rank ----------------------------------------------------------------
# Asserted as ORDERINGS rather than as literal keys, so the format can change
# without rewriting the test and the property under test stays the property.
lt() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" < "$b" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected %s to sort before %s\n' "$desc" "$a" "$b"
  fi
}

lt "a stuck entry is resolved before a fresh merge" \
  "$(lane_rank "drop:budget-exceeded" 50 10)" "$(lane_rank "merge:ready" 50 10)"
lt "a ready merge goes before an update — seconds of work before a whole CI run" \
  "$(lane_rank "merge:ready" 50 10)" "$(lane_rank "update:behind" 50 10)"
lt "priority beats age within one class" \
  "$(lane_rank "merge:ready" 10 1)" "$(lane_rank "merge:ready" 90 99999)"
lt "at equal priority the oldest goes first, so nothing starves" \
  "$(lane_rank "merge:ready" 50 9000)" "$(lane_rank "merge:ready" 50 10)"
lt "class outranks priority: an urgent update still yields to a ready merge" \
  "$(lane_rank "merge:ready" 99 0)" "$(lane_rank "update:behind" 0 99999)"
lt "an unactionable verdict sorts last whatever its priority" \
  "$(lane_rank "update:behind" 99 0)" "$(lane_rank "wait:pending" 0 99999)"

# Bad inputs must not reorder the lane. A garbage priority that sorted to the
# front would let a malformed label jump the queue.
lt "a non-numeric priority falls back to the default, not to the front" \
  "$(lane_rank "merge:ready" 10 5)" "$(lane_rank "merge:ready" abc 5)"
lt "an absurd age clamps instead of wrapping past zero" \
  "$(lane_rank "merge:ready" 50 999999999)" "$(lane_rank "merge:ready" 50 1)"

# --- the pass deadline --------------------------------------------------------
#
# The asymmetry is the whole point: a wrong "keep going" costs one more
# candidate, and a wrong "expired" costs the entire pass — the lane reads
# nothing and merges nothing, green, forever. So every malformed input is
# asserted to read as "keep going".
deadline() { # <expect: expired|running> <desc> <started> <budget> <now>
  local want="$1" desc="$2" got
  shift 2
  if lane_pass_expired "$@"; then got=expired; else got=running; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

deadline running "a fresh pass has its whole budget" 1000 600 1000
deadline running "one second short of the budget still walks" 1000 600 1599
deadline expired "the budget is spent at exactly the boundary, not one second after" 1000 600 1600
deadline expired "a pass well past its budget stops" 1000 600 9999

# A budget of 0 is the documented way to ask for no deadline at all. It must not
# read as "expired immediately", which would be a lane that reads nothing.
deadline running "a budget of 0 disables the deadline rather than expiring at once" 1000 0 9999
deadline running "an empty budget is a missing input, not an expired pass" 1000 "" 9999
deadline running "a non-numeric budget is a typo, not an expired pass" 1000 "ten minutes" 9999
deadline running "a negative-looking budget is not a number and does not expire" 1000 -- -600 9999
deadline running "an unreadable start time does not expire the pass" "" 600 9999
deadline running "an unreadable clock does not expire the pass" 1000 600 ""
deadline running "a clock that went backwards is not an expiry" 9999 600 1000

# --- the automated-review gate ------------------------------------------------
#
# The asymmetry is the OPPOSITE of every other rule in this file, and that is
# deliberate rather than sloppy: the reviewers are third parties, and the case
# the operator named — Codex out of credits, so nothing is ever published for
# any pull request — makes a gate that fails closed into a vendor's billing
# page holding merge authority over the whole fleet. Every malformed input is
# therefore asserted to read as "merge, and say it was unreviewed".
#
# What keeps that honest is that the gate can only ever DELAY a merge the
# required checks have already approved. It never approves one.
review() { # <expected-prefix> <desc> <args...>
  local want="$1" desc="$2" got
  shift 2
  got=$(lane_review_gate "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: expected answered age grace
review "review:off" "a repository that never asked for the gate does not get it" 0 0 10 900
review "review:off" "an unreadable expected count is not a request for a gate" "" 0 10 900
review "review:off" "a garbled expected count does not arm anything" two 0 10 900

review "review:answered" "both reviewers answered this sha" 2 2 10 900
review "review:answered" "more answers than expected is still answered" 2 3 10 900
review "review:hold" "one of two answered, well inside the grace" 2 1 10 900
review "review:hold" "nobody has answered yet, one second short of the grace" 2 0 899 900
# The boundary, in the direction that merges: at exactly the grace the wait is
# over. A `>` here would hold one pass longer on every unanswered pull request.
review "review:unreviewed" "the grace is spent at the boundary, not one second after" 2 0 900 900
review "review:unreviewed" "long past the grace" 2 0 99999 900

# Never a deadlock. Each of these is a way the caller can fail to know
# something, and none of them may stop the fleet merging.
review "review:unreviewed" "an unreadable answer count merges rather than holds" 2 "" 10 900
review "review:unreviewed" "an unreadable clock merges rather than holds forever" 2 0 "" 900
review "review:unreviewed" "a missing grace merges rather than holds forever" 2 0 10 ""
review "review:unreviewed" "a garbled grace is a typo, not an unbounded hold" 2 0 10 "fifteen minutes"
# A grace of 0 is the documented way to arm the trigger and none of the wait.
review "review:unreviewed" "a grace of 0 never holds" 2 0 0 0

# A REVIEWER THAT ANSWERED BY DECLINING. It counts toward `answered` — that is
# the caller's job, not the gate's — and the gate's only duty is to say so, so
# that "reviewed" and "nobody could review" do not read identically in a log.
# The distinction is the whole point: the merge is the same either way, and one
# of them is a fleet-wide outage of the reviewer.
review "review:answered answered=2 expected=2 unavailable=1" \
  "one reviewer answered and one declined; the verdict names the decline" 2 2 10 900 1
review "review:answered answered=2 expected=2 unavailable=2" \
  "both reviewers declined, so nothing waits on either" 2 2 10 900 2
# Silent when there is nothing to report, so the common line does not grow a
# `unavailable=0` that an operator has to learn to ignore.
review "review:answered answered=2 expected=2" \
  "a normal review says nothing about availability" 2 2 10 900 0
review "review:answered answered=2 expected=2" \
  "the argument is optional, and its absence is not a decline" 2 2 10 900
# Malformed input follows this file's rule: it changes no decision, and it does
# not get to put a number into a verdict line.
review "review:answered answered=2 expected=2" \
  "a garbled count is dropped rather than printed as fact" 2 2 10 900 some
# It rides through `answered`, so it can never by itself release a hold.
review "review:hold" "a decline the caller did not count still holds" 2 1 10 900 0

# A REVIEWER THAT READ AN EARLIER COMMIT. Not an answer — a review of an older
# tree says nothing about the new one — and not an outage either. Until this
# rode through, both printed `answered=0` and the `UNREVIEWED` annotation sent
# an operator to check a vendor status page over a Copilot that simply does not
# re-review a moved head. The merge is identical; where you go to look is not.
review "review:unreviewed reason=grace-expired answered=0 expected=1 age=900 grace=60 stale=1" \
  "the expired verdict names the reviewer that read an earlier commit" 1 0 900 60 0 1
review "review:hold answered=0 expected=1 age=10 grace=900 stale=1" \
  "so does a hold, so the queue table says which wait this is" 1 0 10 900 0 1
review "review:unreviewed reason=no-clock answered=0 expected=1 stale=1" \
  "and the no-clock arm, which is the one that fires on a fresh repository" 1 0 "" 900 0 1
# It decides NOTHING. A stale review is not an answer and must never release a
# hold or satisfy the expectation on its own.
review "review:hold answered=0 expected=2 age=10 grace=900 stale=2" \
  "two stale reviews still hold; a reviewer that read an older tree has not answered" 2 0 10 900 0 2
# Silent at zero, and a garbled count is dropped rather than printed as fact —
# the same two rules `unavailable` follows, for the same reason.
review "review:unreviewed reason=grace-expired answered=0 expected=1 age=900 grace=60" \
  "nothing stale, nothing said" 1 0 900 60 0 0
review "review:unreviewed reason=grace-expired answered=0 expected=1 age=900 grace=60" \
  "the argument is optional" 1 0 900 60 0
review "review:unreviewed reason=grace-expired answered=0 expected=1 age=900 grace=60" \
  "a garbled stale count does not reach the verdict line" 1 0 900 60 0 lots
# NOT on the `answered` arm, and the omission is deliberate rather than missed:
# `stale` is disjoint from `answered`, so every expected reviewer having
# answered leaves nothing stale to report. Printing it there would be a number
# that can only ever be zero.
review "review:answered answered=2 expected=2 unavailable=1" \
  "a fully answered pull request has nothing stale left to say" 2 2 10 900 1 1

if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "merge-lane-decision: $PASS cases pass"
