#!/usr/bin/env bash
# Self-test for the controller's drain rule.
#
# This exists because the one-VM-per-job predecessor of this rule SHIPPED
# INVERTED — an online-but-idle runner was read as "still working", so nothing
# was ever reaped and the MIG pinned at max. That bug was untestable in place:
# it only manifested on a controller VM, against a live GitHub org, hours after
# an apply. The rule is a pure function here so a wrong verdict is caught in CI
# instead of on the fleet's bill.
#
# Every case below is a real failure mode of this pool, not a synthetic input.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/drain-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(drain_decision "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: status busy idle grace pool floor reg

# --- the mid-job kill this design exists to prevent ---------------------------
expect keep "busy host is never drained, however long idle-looking the pool is" \
  RUNNING 1 0 900 5 0 present
expect keep "one busy slot protects all K slots on the host" \
  RUNNING 1 0 900 8 0 present
expect keep "a job past any grace window is still protected — no TTL on work" \
  RUNNING 3 99999 900 5 0 present

# --- fail-safe ----------------------------------------------------------------
expect keep "GitHub unreachable: cannot prove idle, so keep (never guess a host is free)" \
  RUNNING 0 99999 900 5 0 unknown
expect keep "unknown outranks past-grace" \
  RUNNING 0 100000 60 9 0 unknown

# --- terminal state -----------------------------------------------------------
expect drain "TERMINATED host holds no job and cannot leave the MIG itself" \
  TERMINATED 0 0 900 5 0 present
expect drain "preempted Spot host is reclaimed even mid-'busy' bookkeeping" \
  STOPPING 2 0 900 5 0 present
expect drain "terminal state outranks the floor — a dead host is not warm capacity" \
  TERMINATED 0 0 900 1 1 present

# --- warm window (the wall-time feature) --------------------------------------
expect keep "idle inside the grace window stays WARM — this is 'no boot between runs'" \
  RUNNING 0 60 900 5 0 present
expect keep "idle one second short of grace is still warm" \
  RUNNING 0 899 900 5 0 present
expect drain "idle past grace above the floor is drained — this is the idle tail" \
  RUNNING 0 900 900 5 0 present
expect drain "long-idle host is drained" \
  RUNNING 0 5400 900 2 0 present

# --- floor --------------------------------------------------------------------
expect keep "never drain below the floor: the autoscaler would just recreate it" \
  RUNNING 0 99999 900 1 1 present
expect keep "at floor with pool below floor (transient) is still kept" \
  RUNNING 0 99999 900 0 2 present
expect drain "one above the floor may be drained" \
  RUNNING 0 99999 900 2 1 present

# --- scale to zero ------------------------------------------------------------
expect drain "floor 0: the last idle host IS drained — scale-to-zero survives" \
  RUNNING 0 1200 900 1 0 present

# --- never-registered host (the reachable hazard in the old fleet) ------------
expect drain "host that never registered is drained at once, not after grace" \
  RUNNING 0 5 900 3 0 absent
expect keep "…but not below the floor" \
  RUNNING 0 5 900 1 1 absent
expect keep "…and not while GitHub is unreachable" \
  RUNNING 0 5 900 3 0 unknown

# --- partial registration ------------------------------------------------------
expect keep "partial registration with work in flight is left alone" \
  RUNNING 2 0 900 3 0 partial
expect keep "partial but recently idle stays warm" \
  RUNNING 0 100 900 3 0 partial
expect drain "partial + idle past grace = degraded capacity we are paying for" \
  RUNNING 0 1000 900 3 0 partial

# --- defaults ------------------------------------------------------------------
expect keep "no arguments at all must not authorise a deletion" \
  ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
