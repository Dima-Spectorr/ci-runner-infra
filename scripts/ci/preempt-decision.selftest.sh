#!/usr/bin/env bash
# The re-run rule for a job lost to a reclaimed Spot host (preempt-decision.sh).
#
# Two ways to get it wrong, and both are silent. Too eager, and a genuine red
# build is hidden behind a second attempt that may pass by luck. Too shy, and a
# Spot pool loses jobs the way it did before this existed: a red pull request
# for a reason that has nothing to do with its code, and nobody told.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../../modules/ci-runner-host-pool/scripts"
# shellcheck source=../../modules/ci-runner-host-pool/scripts/host-ownership.sh
source "$SCRIPTS/host-ownership.sh"
# shellcheck source=../../modules/ci-runner-host-pool/scripts/preempt-decision.sh
source "$SCRIPTS/preempt-decision.sh"

PASS=0
FAIL=0
expect() { # expect <want-prefix> <desc> <actual>
  case "$3" in
    "$1"*) printf 'ok   %s\n' "$2"; PASS=$((PASS + 1)) ;;
    *) printf 'FAIL %s — expected %s*, got %s\n' "$2" "$1" "$3"; FAIL=$((FAIL + 1)) ;;
  esac
}

B=ci-pool
H=ci-pool-ab12
R=ci-pool-ab12-s2
STARTED=1000
DONE=1600
NOW=2000
SETTLE=180

v() { preempt_host_verdict "$@"; }

# --- the host verdict ----------------------------------------------------------
expect lost: "a host the MIG no longer lists is lost" \
  "$(v "$B" "$R" 1 "" "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"
# The MIG recreates a deleted instance under the SAME name, so most reclaims
# look like a host that is still there. Its boot time gives it away.
expect lost: "a host recreated under the same name after the job began is lost" \
  "$(v "$B" "$R" 1 RUNNING 1700 "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect lost: "a recreated host still being created is lost too" \
  "$(v "$B" "$R" 1 CREATING 1700 "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect alive: "the same boot, still RUNNING after the settle: a real failure" \
  "$(v "$B" "$R" 1 RUNNING 900 "$STARTED" "$DONE" "$NOW" "$SETTLE")"
# Inside the 30-second notice the doomed host still lists RUNNING.
expect wait: "the same boot, but the job only just finished: not yet" \
  "$(v "$B" "$R" 1 RUNNING 900 "$STARTED" 1900 "$NOW" "$SETTLE")"
expect wait: "a host STOPPING on its original boot is not called alive" \
  "$(v "$B" "$R" 1 STOPPING 900 "$STARTED" "$DONE" "$NOW" "$SETTLE")"
# A failed listing is indistinguishable from an empty pool by its output.
expect wait: "an unread MIG list is never read as the host being gone" \
  "$(v "$B" "$R" 0 "" "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect wait: "an unread boot time on a listed host waits" \
  "$(v "$B" "$R" 1 RUNNING "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect wait: "an unreadable job start waits" \
  "$(v "$B" "$R" 1 RUNNING 900 "" "$DONE" "$NOW" "$SETTLE")"
expect wait: "no MIG base name waits" \
  "$(v "" "$R" 1 "" "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect foreign: "a runner of another pool is not this pool's business" \
  "$(v "$B" "other-pool-ab12-s2" 1 "" "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect foreign: "a bare host name is not a slot" \
  "$(v "$B" "$H" 1 "" "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect foreign: "a hosted runner name is foreign" \
  "$(v "$B" "GitHub Actions 12" 1 "" "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"
expect lost: "a nonce-suffixed slot name still attributes to its host" \
  "$(v "$B" "$H-s0-1f2e" 1 "" "" "$STARTED" "$DONE" "$NOW" "$SETTLE")"

# --- the re-run decision ---------------------------------------------------------
d() { preempt_rerun_decision "$@"; }
expect rerun-failed: "attempt 1 lost a job: re-run the failed jobs only" \
  "$(d completed failure 1 1 - 3 0)"
expect rerun-failed: "attempt 2 (the controller re-ran 1) lost again: re-run" \
  "$(d completed failure 2 2 1 3 0)"
expect declined: "attempt 3 reached the cap: say so, do not re-run" \
  "$(d completed failure 3 3 2 3 0)"
expect rerun-full: "a host-pinned run is re-run in full" \
  "$(d completed failure 1 1 - 3 1)"
expect done: "already re-run by this controller for this attempt" \
  "$(d completed failure 1 1 1 3 0)"
# GitHub is the record: a re-run that happened before a restart erased the
# ledger shows up as a newer attempt.
expect done: "the run moved to a newer attempt: somebody re-ran it" \
  "$(d completed failure 2 1 - 3 0)"
expect done: "a run that is running again is left alone" \
  "$(d in_progress "" 1 1 - 3 0)"
expect done: "a run that now concludes success is left alone" \
  "$(d completed success 1 1 - 3 0)"
expect wait: "an unread run waits" \
  "$(d "" "" "" 1 - 3 0)"
expect wait: "an unreadable attempt waits" \
  "$(d completed failure x 1 - 3 0)"
expect done: "no recorded attempt for the candidate is nothing to do" \
  "$(d completed failure 1 "" - 3 0)"
expect declined: "a malformed cap falls back to 3" \
  "$(d completed failure 3 3 - abc 0)"

# --- the controller carries this file -------------------------------------------
for tf in modules/ci-runner-host-pool/main.tf modules/ci-runner-controller/main.tf; do
  if grep -q 'preempt-decision.sh' "$HERE/../../$tf"; then
    printf 'ok   %s concatenates preempt-decision.sh\n' "$tf"; PASS=$((PASS + 1))
  else
    printf 'FAIL %s does not concatenate preempt-decision.sh — the functions would be undefined on the box\n' "$tf"
    FAIL=$((FAIL + 1))
  fi
done
STARTUP="$SCRIPTS/controller-startup.sh"
for fn in preempt_host_verdict preempt_rerun_decision; do
  if grep -q "$fn " "$STARTUP"; then
    printf 'ok   the controller calls %s\n' "$fn"; PASS=$((PASS + 1))
  else
    printf 'FAIL the controller never calls %s\n' "$fn"; FAIL=$((FAIL + 1))
  fi
done
# shellcheck disable=SC2016  # the literal call text, $-signs included, is what is grepped for.
if grep -q 'gh_actions_post "$id" "$verb"' "$STARTUP" && grep -q 'verb=rerun-failed-jobs' "$STARTUP"; then
  printf 'ok   the controller posts rerun-failed-jobs\n'; PASS=$((PASS + 1))
else
  printf 'FAIL the controller does not post rerun-failed-jobs\n'; FAIL=$((FAIL + 1))
fi

printf 'preempt-decision selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
