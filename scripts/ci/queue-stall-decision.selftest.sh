#!/usr/bin/env bash
# Self-test for the controller's merge-queue STALL rule.
#
# Unlike its neighbour, this rule ACTS: a wrong verdict does not mute an alert,
# it posts a comment on somebody's pull request and can spend a queue CI run.
# So the weighting here is different from parked-decision's. Every case below
# that is not a boundary is a case where the rule must REFUSE to act, because
# the failure that matters is the false positive: a rule that requeues a pull
# request whose diff is genuinely broken turns a slow queue into a wrong one,
# and a rule that comments on a pull request still running its checks trains a
# repository to ignore the one comment that mattered.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/queue-stall-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(stall_verdict "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: draft base queue_base total failed pending mq_state idle after attempts max
QB=main
AFTER=600
MAX=3

# --- the three states this rule exists for ------------------------------------
# Each one is a real incident, named in queue-stall-decision.sh.

expect "nudge:refresh" "Mergify holds the entry and never noticed the last check go green (#11259)" \
  0 "$QB" "$QB" 40 0 0 in_progress 900 "$AFTER" 0 "$MAX"

expect "nudge:queue" "dequeued on a fleet failure and Mergify will never try again (#11025)" \
  0 "$QB" "$QB" 40 0 0 completed 30000 "$AFTER" 0 "$MAX"

expect "nudge:queue" "never entered the queue at all — 'under evaluation' forever" \
  0 "$QB" "$QB" 40 0 0 absent 5000 "$AFTER" 0 "$MAX"

# --- invariant A: never nudge a pull request that is not finished and green ---
# These are the arms that keep the rule from becoming noise, and every one of
# them describes a pull request whose state is honestly reported elsewhere.

expect "quiet:in-flight" "a check still running is a spinner the author can already see" \
  0 "$QB" "$QB" 40 0 1 absent 99999 "$AFTER" 0 "$MAX"

expect "quiet:in-flight" "pending outranks green even when everything else screams stall" \
  0 "$QB" "$QB" 40 0 7 in_progress 99999 "$AFTER" 0 "$MAX"

expect "quiet:red" "a red pull request is the author's to fix, never ours to requeue" \
  0 "$QB" "$QB" 40 1 0 completed 99999 "$AFTER" 0 "$MAX"

expect "quiet:no-checks" "no checks at all is an unwired branch, not a stall" \
  0 "$QB" "$QB" 0 0 0 absent 99999 "$AFTER" 0 "$MAX"

# --- admissibility belongs to parked-decision.sh, not here --------------------
# Nudging either of these would produce a comment every sweep, forever, on a
# repository that already has a signal telling it what to fix.

expect "quiet:draft" "a green draft is parked-decision's to report and never ours to queue" \
  1 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" 0 "$MAX"

expect "quiet:base" "a pull request aimed at a sibling branch is not stalled, it is misaimed" \
  0 feature-x "$QB" 40 0 0 absent 99999 "$AFTER" 0 "$MAX"

expect "quiet:draft" "draft is checked before base, so a doubly-inadmissible one still says draft" \
  1 feature-x "$QB" 40 0 0 absent 99999 "$AFTER" 0 "$MAX"

# --- the settling window ------------------------------------------------------
# Mergify reacts to a completed check in seconds. This window is the entire
# difference between a control plane and a second actor racing Mergify for the
# same pull request, so its boundary is exact.

expect "quiet:settling" "one second inside the window is silence" \
  0 "$QB" "$QB" 40 0 0 absent 599 600 0 "$MAX"

expect "nudge:queue" "exactly at the window it acts — the comparison is not strict" \
  0 "$QB" "$QB" 40 0 0 absent 600 600 0 "$MAX"

expect "quiet:settling" "a pull request that went green this second is never nudged" \
  0 "$QB" "$QB" 40 0 0 in_progress 0 600 0 "$MAX"

# --- the attempt ceiling ------------------------------------------------------
# The backstop for infra_dequeue being drawn wrong. Both nudge kinds share one
# budget on purpose: three refreshes and three requeues is six comments on a
# pull request nobody is helping.

expect "nudge:queue" "two attempts spent, one left" \
  0 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" 2 3

expect "quiet:exhausted" "the third attempt is the last — at the ceiling it stops" \
  0 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" 3 3

expect "quiet:exhausted" "and it stays stopped rather than wrapping" \
  0 "$QB" "$QB" 40 0 0 in_progress 99999 "$AFTER" 9 3

expect "quiet:exhausted" "max=0 disables acting entirely — the shape a read-only installation gets" \
  0 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" 0 0

expect "quiet:exhausted" "the ceiling outranks the queue state, so neither nudge escapes it" \
  0 "$QB" "$QB" 40 0 0 completed 99999 "$AFTER" 3 3

# --- the fleet does not touch git ---------------------------------------------
# A rebase would produce a new head commit the queue cannot possibly miss, and
# it is still the wrong answer: it discards a green suite, spends a full re-run,
# and puts the control plane in the business of writing to somebody's branch. So
# a caller that reports the branch as stale gets the SAME verdict as one that
# does not, and these cases exist to keep it that way.

expect "nudge:queue" "a stale branch is still just a comment, on the first stall" \
  0 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" 0 "$MAX" 1

expect "nudge:queue" "and on the second, and the third — staleness never escalates" \
  0 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" 2 "$MAX" 1

expect "nudge:refresh" "a held entry on a stale branch is refreshed, not rebased" \
  0 "$QB" "$QB" 40 0 0 in_progress 99999 "$AFTER" 2 "$MAX" 1

expect "quiet:exhausted" "the ceiling still outranks everything" \
  0 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" 3 3 1

# --- unknowns are silence, never a guess --------------------------------------
# A rule that acts on its own parse failures is worse than the grey dot it
# replaces, and every one of these is something GitHub or jq can hand the sweep
# on a bad day.

expect "quiet:unknown-queue-state" "a queue state this rule does not know is not an invitation" \
  0 "$QB" "$QB" 40 0 0 something-new 99999 "$AFTER" 0 "$MAX"

expect "quiet:unparseable-counts" "a jq failure must not become 'green, nothing failed'" \
  0 "$QB" "$QB" "" 0 0 absent 99999 "$AFTER" 0 "$MAX"

expect "quiet:unparseable-counts" "nor may an unreadable idle clock become a stall" \
  0 "$QB" "$QB" 40 0 0 absent "" "$AFTER" 0 "$MAX"

expect "quiet:unparseable-counts" "nor an unreadable attempt count become a free attempt" \
  0 "$QB" "$QB" 40 0 0 absent 99999 "$AFTER" "" "$MAX"

expect "quiet:unparseable-counts" "a negative count is not a number this rule accepts" \
  0 "$QB" "$QB" 40 -1 0 absent 99999 "$AFTER" 0 "$MAX"

expect "quiet:no-base" "no queue base configured is no comparison to make" \
  0 "$QB" "" 40 0 0 absent 99999 "$AFTER" 0 "$MAX"

expect "quiet:no-base" "and a pull request with no base of its own likewise" \
  0 "" "$QB" 40 0 0 absent 99999 "$AFTER" 0 "$MAX"

expect "quiet:unparseable-counts" "no arguments at all is silence, like every other rule here" \
  ""

# --- infra_dequeue ------------------------------------------------------------
# Invariant B. This is the line between "the fleet dropped it" and "the diff is
# broken", and it is the only thing that makes an automatic requeue defensible.

# infra <yes|no> <description> <conclusion> <elapsed> <steps> [max]
infra() {
  local want="$1" desc="$2"
  shift 2
  local got=no
  infra_dequeue "$@" && got=yes
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# The measured population, 2026-08-23. Every infrastructure failure in the
# sample died in 7-12 seconds having reached no test.
infra yes "typecheck+lint dead at 'Set up runner' in 7s (draft #11158)" failure 7 ""
infra yes "test 2 dead at 'Set up runner' in 12s" failure 12 ""
infra yes "generic-binary cancelled after 15m with not one step run (slot s1)" cancelled 900 0

# The other population: a failure that had to build something first.
infra no  "a real test failure takes minutes, because the build happens first" failure 840 ""
infra no  "and a slow one even more so" failure 3600 ""

# The boundary, stated exactly. It sits far below the gap rather than in the
# middle of it — see the reasoning in queue-stall-decision.sh.
infra yes "90s is inside the signature" failure 90 ""
infra no  "91s is outside it" failure 91 ""
infra yes "a caller may narrow the threshold" failure 30 "" 30
infra no  "and narrowing it excludes what it should" failure 31 "" 30

# A cancelled job that RAN steps was most likely superseded by a newer commit.
# That is ordinary, it is not the fleet, and retrying it is not ours to do.
infra no  "cancelled after running steps is a supersede, not a dead slot" cancelled 900 4
infra no  "unknown step count is not zero — an unknown must never buy a retry" cancelled 900 ""

# Everything else is not a dequeue signature at all.
infra no  "success is not a failure to classify" success 5 ""
infra no  "neutral is not blocking and never reaches here" neutral 5 ""
infra no  "action_required wants a human, by definition" action_required 5 ""
infra no  "an unparseable duration is not a signature, it is a jq failure" failure "" ""
infra no  "nor is a non-numeric one" failure "abc" ""
infra no  "no arguments at all is not infrastructure"

if [ "$FAIL" -gt 0 ]; then
  echo "queue-stall-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "queue-stall-decision: $PASS cases pass"
