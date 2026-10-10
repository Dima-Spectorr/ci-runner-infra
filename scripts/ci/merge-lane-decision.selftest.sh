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

# AND IT RIDES THE VERDICTS THAT ARE NOT `answered`, which is where an operator
# most needs it: a merge annotated `UNREVIEWED` reads as a reviewer that never
# spoke, and `unavailable=` is what says one of them spoke by declining. It was
# on `review:answered` alone — the one line whose reader is least likely to go
# looking — so all four now carry it, in the same order every time.
review "review:unreviewed reason=grace-expired answered=1 expected=2 age=900 grace=60 unavailable=1" \
  "a decline is named on the line that produces the annotation" 2 1 900 60 1
review "review:hold answered=1 expected=2 age=10 grace=900 unavailable=1" \
  "and while the lane is still waiting" 2 1 10 900 1
review "review:unreviewed reason=no-clock answered=1 expected=2 unavailable=1" \
  "and when the clock could not be read" 2 1 x 900 1
# Both counters on one line, in a fixed order, so a log grep is stable.
review "review:hold answered=0 expected=2 age=10 grace=900 unavailable=1 stale=1" \
  "unavailable comes before stale, always" 2 0 10 900 1 1
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

# --- a short clock is waited out in the run, a long one is not (#1402) ---------
# The review grace clears with no event behind it, so a run that ended on a
# `wait:review` hold left a green pull request for the daily backstop.
# `clock` compares the WHOLE line: the seconds value is the sleep itself, and a
# wrong one either re-reads before the clock clears or overshoots the budget.
clock() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(lane_clock_wait "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
# args: clears_at now started budget last_pass cap waits_done max_waits
T=1000000
# The live shape that found this: age=21 of grace=60, so the clock clears 39s from now.
clock "wait:clock seconds=40" "the 60s review grace with 39s left is waited out, plus one second" \
  $((T + 39)) "$T" $((T - 20)) 600 20 180 0 3
clock "wait:clock seconds=1" "a clock that already cleared during the walk re-reads at once" \
  $((T - 5)) "$T" $((T - 20)) 600 20 180 0 3
clock "wait:clock seconds=180" "exactly the cap is still short" \
  $((T + 179)) "$T" "$T" 600 20 180 0 3
clock "nowait:over-cap seconds=181 cap=180" "one second past the cap is a long clock" \
  $((T + 180)) "$T" "$T" 600 20 180 0 3
clock "nowait:over-cap seconds=841 cap=180" "the 900s base-health grace from a fresh tip is left to its event" \
  $((T + 840)) "$T" "$T" 600 20 180 0 3
# The budget must hold the wait AND the read after it, or the run truncates the
# read it waited for, or outlives the job.
clock "wait:clock seconds=40" "wait plus walk exactly at the budget still fits" \
  $((T + 39)) "$T" $((T - 540)) 600 20 180 0 3
clock "nowait:over-budget seconds=40 spent=541 walk=20 budget=600" "one second over the budget does not" \
  $((T + 39)) "$T" $((T - 541)) 600 20 180 0 3
clock "nowait:over-budget seconds=40 spent=0 walk=580 budget=600" "a slow walk is counted, not assumed free" \
  $((T + 39)) "$T" "$T" 600 580 180 0 3
clock "nowait:no-deadline budget=0" "a budget of 0 bounds nothing, so nothing is waited" \
  $((T + 39)) "$T" "$T" 0 20 180 0 3
clock "nowait:no-deadline budget=ten" "a garbled budget is not a deadline" \
  $((T + 39)) "$T" "$T" ten 20 180 0 3
clock "wait:clock seconds=40" "a clock read backwards counts as no time spent" \
  $((T + 39)) "$T" $((T + 50)) 600 20 180 0 3
clock "nowait:over-budget seconds=40 spent=0 walk=20 budget=59" "and never as time given back" \
  $((T + 39)) "$T" $((T + 50)) 59 20 180 0 3
# Bounded in count as well as in time.
clock "wait:clock seconds=40" "the last permitted wait" \
  $((T + 39)) "$T" "$T" 600 20 180 2 3
clock "nowait:waits-spent waits=3 max=3" "no fourth wait" \
  $((T + 39)) "$T" "$T" 600 20 180 3 3
clock "nowait:waits-spent waits=0 max=" "no limit given is no wait" \
  $((T + 39)) "$T" "$T" 600 20 180 0 ""
# Nothing held, or nothing readable: the run ends exactly as it always did.
clock "nowait:no-clock" "no clock-held pull request" "" "$T" "$T" 600 20 180 0 3
clock "nowait:no-clock" "a garbled clock" soon "$T" "$T" 600 20 180 0 3
clock "nowait:unreadable now=$T started=$T last-pass=" "an unmeasured walk" \
  $((T + 39)) "$T" "$T" 600 "" 180 0 3
clock "nowait:no-cap cap=x" "a garbled cap" $((T + 39)) "$T" "$T" 600 20 x 0 3

# lane_clock_earliest: the first clock to clear is the one worth waiting for.
earliest() {
  local want="$1" desc="$2" got
  shift 2
  got=$(lane_clock_earliest "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
earliest 100 "the sooner of two" 200 100
earliest 100 "whichever side it is on" 100 200
earliest 100 "equal is equal" 100 100
earliest 300 "first clock of the pass" "" 300
earliest 300 "a garbled candidate is ignored" 300 soon
earliest "" "nothing held" "" ""

# lane_walk_estimate: the read after a wait is budgeted as a full walk.
walk() {
  local want="$1" desc="$2" got
  shift 2
  got=$(lane_walk_estimate "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
# A base-health halt returns before the walk: two seconds measured, a
# 200-second walk earlier in the run. Budgeting two would let the wait crowd
# out the read it waits for.
walk 200 "a halted pass is budgeted as the last full walk, not its own two seconds" 2 200 30
walk 30 "with no walk yet, the floor" 2 "" 30
walk 95 "a pass that walked longer than the last one counts in full" 95 40 30
walk 30 "the floor holds when every walk was quick" 5 10 30
walk 30 "garbled values are ignored, never read as zero cost" x y 30
walk 30 "a garbled value after a good one does not replace it" 30 x ""
walk 0 "nothing readable and no floor is zero, not an invented cost" "" "" ""
# Wired into the wait: the same halted pass, budgeted as a full walk, no
# longer fits a wait that a two-second estimate would have allowed.
clock "nowait:over-budget seconds=40 spent=400 walk=200 budget=600" \
  "the walk estimate, not the halted pass, decides whether the wait fits" \
  $((T + 39)) "$T" $((T - 400)) 600 "$(lane_walk_estimate 2 200 30)" 180 0 3

# ---------------------------------------------------------------------------
# #1443 — A RED BASE ADMITS ITS OWN FIX, AND NOTHING ELSE.
# args: verdict behind fixed failing. Every wait arm starts `wait:base-red`, so
# each case pins the field that names WHICH arm answered — a trailing space
# after a number, so `behind=1` cannot be satisfied by `behind=10`.
basefix() {
  local want="$1" desc="$2" got
  shift 2
  got=$(lane_base_fix_verdict "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
basefix "merge:base-fix fixes=2/2" "red base + green PR up to date that passes what fails there merges" \
  "merge:ready" 0 2 2
basefix "wait:base-red behind=1 " "red base + green PR behind the red tip halts" "merge:ready" 1 2 2
basefix "wait:base-red behind=unknown " "an unread comparison is not up to date" "merge:ready" "" 2 2
basefix "wait:base-red behind=x " "a garbled comparison is not up to date" "merge:ready" x 2 2
basefix "wait:base-red fixes=1/2 " "red base + PR still failing one of the base's failing checks halts" \
  "merge:ready" 0 1 2
basefix "wait:base-red fixes=0/0 " "an empty failing set admits nothing" "merge:ready" 0 0 0
basefix "wait:base-red fixes=?/2 " "an unread fix count admits nothing" "merge:ready" 0 "" 2
basefix "wait:base-red holds update:behind" "an update waits: the run it starts is not a fix" \
  "update:behind" 0 2 2
basefix "wait:base-red holds drop:expired" "a drop waits too, so a red base comments nothing" \
  "drop:expired in-flight" 0 2 2
basefix "skip:red" "a verdict that was never going to act passes through unchanged" "skip:red" 0 2 2
basefix "wait:review" "a review hold stays a review hold" "wait:review grace" 0 2 2

# ---------------------------------------------------------------------------
# #1482 — A PUSH-ONLY BASE-HEALTH CHECK IS SHOWN FIXED BY THE REQUIRED CHECKS.
# IntegrateIT: `main-health` runs on a push to main and never on a pull request,
# so no head reports it. fixcount runs `lane_base_fix_count` on a head-states
# file and feeds its count to `lane_base_fix_verdict`, exactly as the driver
# does. args: head-states-lines failing base-required-failing required
FIXDIR="$(mktemp -d)"
trap 'rm -rf "$FIXDIR"' EXIT
fixcount() {
  local want="$1" desc="$2" states="$FIXDIR/states" failing="$4" fixed got nfail
  printf '%b' "$3" >"$states"
  fixed=$(lane_base_fix_count "$states" "$failing" "$5" "$6")
  nfail=$(printf '%s\n' "$failing" | grep -c . || true)
  got=$(lane_base_fix_verdict "merge:ready" 0 "$fixed" "$nfail")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  states: %s\n  want: %s*\n  got:  %s\n' "$desc" "$3" "$want" "$got"
  fi
}
REQ=$'ci\ngeneric-binary'
GREEN_HEAD='success ci\nsuccess generic-binary\nabsent main-health\n'
fixcount "merge:base-fix fixes=1/1" \
  "push-only base-health red + required ci red on the base + PR ci success merges" \
  "$GREEN_HEAD" main-health ci "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "the same, but the PR's ci is failing: it waits" \
  'failed ci\nsuccess generic-binary\nabsent main-health\n' main-health ci "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "base-health red with no required check failing on the base waits (fail closed)" \
  "$GREEN_HEAD" main-health "" "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "a skipped required check is not a demonstration, even standing in" \
  'skipped ci\nsuccess generic-binary\nabsent main-health\n' main-health ci "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "every required check failing on the base must pass, not just one" \
  'success ci\nfailed generic-binary\nabsent main-health\n' main-health $'ci\ngeneric-binary' "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "a base-health check the head has not reported YET is pending, not push-only" \
  'success ci\nsuccess generic-binary\npending main-health\n' main-health ci "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "a base-health check that RAN on the head and failed is not stood in for" \
  'success ci\nsuccess generic-binary\nfailed main-health\n' main-health ci "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "an absent REQUIRED check never stands in for itself" \
  'absent ci\nsuccess generic-binary\n' ci ci "$REQ"
fixcount "wait:base-red fixes=0/1 " \
  "an unreadable head (no states at all) counts nothing" \
  '' main-health ci "$REQ"
fixcount "merge:base-fix fixes=2/2" \
  "a failing required check is still counted on its own success beside a push-only one" \
  "$GREEN_HEAD" $'ci\nmain-health' ci "$REQ"
fixcount "wait:base-red fixes=1/2 " \
  "a skipped base-health check that ran on PRs is still not a pass (#1443)" \
  'success ci\nsuccess generic-binary\nskipped lint\n' $'ci\nlint' ci "$REQ"

# How many of the ranking a pass may act on. args: strict max acted red.
batch() {
  local want="$1" desc="$2" got
  shift 2
  got=$(lane_batch_size "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
batch 1 "red base, two eligible: only one merges, even on a non-strict base" 0 4 0 1
batch 4 "a green non-strict base drains the rest of the run's budget" 0 4 0 ""
batch 2 "the budget already spent is not spent again" 0 4 2 ""
batch 1 "a strict base acts once and re-reads" 1 4 0 ""
batch 1 "a spent budget still allows the pass its one action" 0 4 4 ""
batch 1 "a garbled budget acts once" 0 x 0 ""

# --- lane_premerge_verdict: the fresh read right before the merge call (#1514) --
# args: require_label waived_sha verified_sha state draft head_sha labels
premerge() {
  local want="$1" desc="$2" got
  shift 2
  got=$(lane_premerge_verdict "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
PM=aaaaaaaa1111
premerge ok "labelled, open, not draft, same head merges" ready-to-merge '' "$PM" open false "$PM" "x,ready-to-merge"
premerge skip:label-removed "#1514: the label removed after the walk read it is not merged" ready-to-merge '' "$PM" open false "$PM" ""
premerge skip:label-removed "a different label left behind is still no label" ready-to-merge '' "$PM" open false "$PM" "ready-to-merge-later"
premerge skip:draft "flipped to draft after the walk read it" ready-to-merge '' "$PM" open true "$PM" "ready-to-merge"
premerge skip:draft "draft holds without a label gate too" '' '' "$PM" open true "$PM" ""
premerge skip:head-moved "a push after the checks were read" ready-to-merge '' "$PM" open false bbbbbbbb2222 "ready-to-merge"
premerge skip:not-open "closed meanwhile" ready-to-merge '' "$PM" closed false "$PM" "ready-to-merge"
premerge skip:fresh-read-unreadable "an empty read fails closed" ready-to-merge '' "$PM" '' '' '' ''
premerge skip:fresh-read-unreadable "a garbled draft field fails closed" '' '' "$PM" open null "$PM" ''
premerge ok "no label gate: an unlabelled pull request is not held by the label" '' '' "$PM" open false "$PM" ""
premerge ok "a pin-bump waiver for THIS head still waives the label" ready-to-merge "$PM" "$PM" open false "$PM" ""
premerge skip:label-removed "a waiver granted for another head does not" ready-to-merge bbbbbbbb2222 "$PM" open false "$PM" ""

# --- lane_settled_red: which heads may skip the rest of the reads --------------
# args: green missing failed pending
settled() {
  local want="$1" desc="$2" got=no
  shift 2
  lane_settled_red "$@" && got=yes
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
settled yes "every required check finished and one failed" 1 0 1 0
settled yes "all of them failed" 0 0 3 0
settled no  "all green is the merge case, and must be read in full" 2 0 0 0
settled no  "a failure with one still RUNNING can outlive the budget and become a drop" 0 0 1 1
settled no  "a failure with one MISSING can outlive the budget and become a drop" 0 1 1 0
settled no  "nothing failed, one pending" 1 0 0 1
settled no  "nothing failed, one missing" 1 1 0 0
settled no  "an unreadable count proves nothing" 1 0 x 0
settled no  "an empty read proves nothing" "" "" "" ""

# THE PROOF THE SHORT CUT RESTS ON, BY ENUMERATION. For every count the
# predicate accepts, no value of the three facts the lane then declines to read
# — mergeability, distance from the base, head age — yields a verdict the lane
# acts on, on either kind of base. If `lane_verdict` ever grows an arm that
# could, this fails before the driver starts skipping a candidate.
_sr_bad=0
for _sr_counts in "1 0 1 0" "0 0 2 0" "5 0 1 0"; do
  read -r _g _m _f _p <<<"$_sr_counts"
  _t=$((_g + _m + _f + _p))
  lane_settled_red "$_g" "$_m" "$_f" "$_p" || _sr_bad=$((_sr_bad + 1))
  for _conflict in "" 0 1; do
    for _behind in 0 7; do
      for _age in "" 0 999999; do
        for _strict in 0 1; do
          _v=$(lane_verdict 0 "$LB" "$LB" "$_conflict" "$_t" "$_g" "$_m" "$_f" "$_p" "$_behind" "$_age" 1800 "$_strict")
          if lane_admits "$_v"; then
            _sr_bad=$((_sr_bad + 1))
            printf 'FAIL: a settled-red head was admitted\n  counts: %s conflict=%s behind=%s age=%s strict=%s\n  got: %s\n' \
              "$_sr_counts" "$_conflict" "$_behind" "$_age" "$_strict" "$_v"
          fi
        done
      done
    done
  done
done
if [ "$_sr_bad" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# --- lane_priority_of ----------------------------------------------------------
prio() {
  local want="$1" desc="$2" got
  shift 2
  got=$(lane_priority_of "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
prio 50 "no label at all is the default" "" "lane/priority-"
prio 50 "labels, none of them a priority" "bug,ready" "lane/priority-"
prio 10 "a priority label among others" "bug,lane/priority-10,ready" "lane/priority-"
prio 50 "a suffix that is not a number is not a priority" "lane/priority-high" "lane/priority-"
prio 20 "the last numeric priority label wins, as it always did" "lane/priority-10,lane/priority-20" "lane/priority-"
prio 50 "a label that is a bare number, without the prefix, is not a priority" "10,bug" "lane/priority-"
prio 10 "a garbled label after a good one does not reset it" "lane/priority-10,lane/priority-x" "lane/priority-"

# --- THE WINNER IS UNCHANGED ---------------------------------------------------
# Two walks over the same open list. `full` is the walk as it was: every pull
# request that is not a draft is read in full, judged and ranked. `short` is the
# walk as it is now: a head `lane_settled_red` accepts is dismissed on its check
# counts alone and never judged. The property is that both pick the SAME pull
# request, in the same order behind it — not that either picks a particular one,
# though each case names it so a fixture that drifted cannot pass by agreeing
# with itself.
#
# One row per pull request:
#   num draft conflict green missing failed pending behind age labels
# `-` stands for an empty field. Required total is green+missing+failed+pending.
_walk() { # <mode> <strict> <row>...
  local mode="$1" strict="$2" row num draft conflict g m f p behind age labels v prio out=''
  shift 2
  for row in "$@"; do
    read -r num draft conflict g m f p behind age labels <<<"$row"
    [ "$conflict" = "-" ] && conflict=''
    [ "$age" = "-" ] && age=''
    [ "$labels" = "-" ] && labels=''
    [ "$draft" = "1" ] && continue
    if [ "$mode" = short ] && lane_settled_red "$g" "$m" "$f" "$p"; then continue; fi
    v=$(lane_verdict 0 "$LB" "$LB" "$conflict" "$((g + m + f + p))" "$g" "$m" "$f" "$p" "$behind" "$age" 1800 "$strict")
    lane_admits "$v" || continue
    prio=$(lane_priority_of "$labels" "lane/priority-")
    out+="$(lane_rank "$v" "$prio" "${age:-0}")	$num	${v%% *}"$'\n'
  done
  printf '%s' "$out" | LC_ALL=C sort | cut -f2,3 | tr '\t\n' '= '
}
same_winner() { # <want-order> <description> <strict> <row>...
  local want="$1" desc="$2" strict="$3" full short
  shift 3
  full="$(_walk full "$strict" "$@")"
  short="$(_walk short "$strict" "$@")"
  if [ "$full" = "$short" ] && [ "$short" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want:  %s\n  full:  %s\n  short: %s\n' "$desc" "$want" "$full" "$short"
  fi
}

same_winner "104=merge:ready " "one ready among red, draft and conflicted" 0 \
  "101 0 0 1 0 1 0 0 90000 -" \
  "102 1 0 2 0 0 0 0 90000 -" \
  "103 0 1 2 0 0 0 0 90000 -" \
  "104 0 0 2 0 0 0 0 60 -" \
  "105 0 - 1 0 1 0 0 90000 -" \
  "106 0 1 0 0 2 0 0 90000 -"
same_winner "203=merge:ready 201=merge:ready " "a priority label outranks an older ready one, and a red one with the best priority is no candidate" 0 \
  "201 0 0 2 0 0 0 0 9000 -" \
  "202 0 0 1 0 1 0 0 9000 lane/priority-1" \
  "203 0 0 2 0 0 0 0 10 bug,lane/priority-10"
same_winner "302=merge:ready 301=merge:ready 303=merge:ready " "a tie on priority goes to the oldest head, with red ones on both sides of it" 0 \
  "300 0 0 1 0 1 0 0 99999 -" \
  "301 0 0 2 0 0 0 0 500 -" \
  "302 0 0 2 0 0 0 0 7000 -" \
  "303 0 0 2 0 0 0 0 20 -" \
  "304 0 0 0 0 2 0 0 5 -"
same_winner "402=drop:budget-exceeded 403=merge:ready " "a failed head with a check still MISSING past the budget is a drop, ranks first, and is not dismissed" 0 \
  "401 0 0 1 0 1 0 0 90000 -" \
  "402 0 0 0 1 1 0 0 90000 -" \
  "403 0 0 2 0 0 0 0 60 -"
same_winner "502=drop:budget-exceeded 503=merge:ready " "and so is one with a check still PENDING past the budget" 0 \
  "501 0 0 1 0 1 0 0 90000 -" \
  "502 0 0 0 0 1 1 0 90000 -" \
  "503 0 0 2 0 0 0 0 60 -"
same_winner "602=merge:ready 601=update:behind " "on a strict base a ready one goes before a behind one, and a red behind one is neither" 1 \
  "600 0 0 1 0 1 0 4 90000 -" \
  "601 0 0 2 0 0 0 3 90000 -" \
  "602 0 0 2 0 0 0 0 60 -"
same_winner "" "nothing but red, draft and conflicted leaves nothing to act on" 0 \
  "701 0 0 1 0 1 0 0 90000 -" \
  "702 1 0 2 0 0 0 0 60 -" \
  "703 0 1 2 0 0 0 0 60 -"

if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "merge-lane-decision: $PASS cases pass"
