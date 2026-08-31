#!/usr/bin/env bash
# Self-test for the rule that decides whether a project is still receiving
# runner infrastructure.
#
# The third acceptance condition on the issue this came from is that the check
# be exercised against a deliberately BROKEN trigger and not only against
# healthy ones, "because the failure mode here is a check that reports green on
# a project it never read". That is what this file is. Every arm that has to
# raise something is driven with the shape that actually occurred, and the
# healthy arm is one case out of the set rather than the whole set.
#
# The states below are not invented. One pool project's apply trigger was
# refused at submit from 2026-08-30: a FAILURE lasting under a second, no build
# log, no steps, the explanation only in statusDetail.
# From this rule's side that is indistinguishable from any other failure, which
# is the point — the rule does not need to understand the refusal, it needs to
# stop calling it green.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/apply-decision.sh"

PASS=0
FAIL=0

# expect <expected> <description> <found> <status> <age>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(apply_verdict "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# --- the states that must raise something -------------------------------------
# The refusal this whole check exists for. Sub-second, no log, no steps.
expect "failed:FAILURE" "a build refused at submit is a failure like any other" \
  1 FAILURE 3600
# The other terminal statuses. Listed individually rather than trusted to one
# catch-all, because a rule that passes only the status it was written against
# is a rule that will pass the next one it has not met.
expect "failed:TIMEOUT" "a timed-out apply did not land" 1 TIMEOUT 3600
expect "failed:CANCELLED" "a cancelled apply did not land" 1 CANCELLED 3600
expect "failed:EXPIRED" "an expired apply did not land" 1 EXPIRED 3600
expect "failed:INTERNAL_ERROR" "an internal error did not land" 1 INTERNAL_ERROR 60
expect "failed:STATUS_UNKNOWN" "an unknown status is not a success" 1 STATUS_UNKNOWN 60
# The arm that matters most for the future: a status Cloud Build adds after this
# file was written must not fall through to ok.
expect "failed:SOMETHING_NEW" "an unrecognised status takes the failing arm" \
  1 SOMETHING_NEW 60
# The half a status check alone cannot see. A trigger that stops firing produces
# no failed build at all, so "nothing found" has to be its own verdict — this is
# the condition that would have caught a trigger deleted or unscheduled.
expect "missing" "no apply build at all is the trigger not firing" 0 "" -1
expect "missing" "not-found wins even if a status came along with it" 0 SUCCESS 10

# --- the ambiguous inputs -----------------------------------------------------
# Everything unclear takes an arm that raises something. A check whose degraded
# path is silence is the failure it was built to prevent.
expect "missing" "an empty found flag is not a healthy project" "" SUCCESS 10
expect "missing" "a non-numeric found flag is not a healthy project" x SUCCESS 10
expect "missing" "found=2 is not found=1" 2 SUCCESS 10
expect "failed:unknown" "a build found with no status is not a pass" 1 "" 10
expect "missing" "no arguments at all does not report a healthy project" ""

# --- in flight is not green ---------------------------------------------------
# Reporting a success that has not happened yet is how a watcher ends up
# confirming the state it was meant to question. These arms are deliberately
# neither ok nor failed, and the caller leaves the previous verdict standing.
expect "inflight:WORKING" "a running apply has not succeeded yet" 1 WORKING 30
expect "inflight:QUEUED" "a queued apply has not succeeded yet" 1 QUEUED 30
expect "inflight:PENDING" "a pending apply has not succeeded yet" 1 PENDING 30

# --- and the one healthy state ------------------------------------------------
expect "ok" "a successful apply is the only thing that reads as ok" 1 SUCCESS 60
# Age does NOT change the verdict, and that is the design: staleness is a
# threshold, and it belongs in the alert policy where a project can pick its own
# rather than compiled into every controller in the fleet. A year-old success is
# still `ok` here, and ci_apply_build_age_seconds is what raises it.
expect "ok" "a very old success is still ok to this rule — age is the policy's job" \
  1 SUCCESS 31536000
expect "ok" "an unparseable create time does not change the status verdict" \
  1 SUCCESS -1

printf 'apply-decision: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
