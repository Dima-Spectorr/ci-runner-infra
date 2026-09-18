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
# "absent" is what a DEAD host reads — and equally what a healthy host reads for
# the minutes it spends fetching a registration token and running config.sh per
# slot. Telling them apart is the host's AGE, argument 8, measured against the
# register grace in argument 9.
expect drain "host that never registered is drained without waiting the idle grace" \
  RUNNING 0 5 900 3 0 absent 900 600
expect keep "…but a host still inside the register grace is BOOTING, not dead" \
  RUNNING 0 5 900 3 0 absent 120 600
expect drain "…and is drained once that window passes" \
  RUNNING 0 5 900 3 0 absent 601 600
expect keep "…but not below the floor" \
  RUNNING 0 5 900 1 1 absent 900 600
expect keep "…and not while GitHub is unreachable" \
  RUNNING 0 5 900 3 0 unknown 900 600
# The regression this rule exists for: DataRetrival 2026-08-13T19:00-19:06Z shot
# six freshly-created hosts as never-registered, one of them one second after it
# picked up a job. With a register grace none of those verdicts is reachable.
expect keep "a 44s-old host is never drainable as never-registered" \
  RUNNING 0 0 900 3 0 absent 44 600
# A caller that forgets the new arguments must not silently drain young hosts:
# with no grace passed, absent still means dead, which is the OLD behaviour and
# is why the controller passes both explicitly.
expect drain "no age/grace supplied falls back to the pre-grace rule" \
  RUNNING 0 5 900 3 0 absent

# --- partial registration ------------------------------------------------------
expect keep "partial registration with work in flight is left alone" \
  RUNNING 2 0 900 3 0 partial
expect keep "partial but recently idle stays warm" \
  RUNNING 0 100 900 3 0 partial
expect drain "partial + idle past grace = degraded capacity we are paying for" \
  RUNNING 0 1000 900 3 0 partial

# --- a truncated roster may not be read as absence (issue #17022) ---------------
# The 2026-09-06 kill wave: 176 slots read through a single unpaginated
# 100-record page, so every host past the cut reported present=0 -> absent,
# busy=0, and rule 5 drained hosts that were running jobs. The tenth argument is
# how the caller says "I did not get to the end of the list", and NO amount of
# apparent absence may authorise a delete while it says partial.
expect keep "absent on a truncated roster is unproven, not dead" \
  RUNNING 0 5 900 3 0 absent 900 600 partial
expect keep "…even for a host the controller has known for hours" \
  RUNNING 0 5 900 8 0 absent 86400 600 partial
expect keep "partial registration on a truncated roster is also unproven" \
  RUNNING 0 1000 900 3 0 partial 900 600 partial
expect drain "…and the SAME host drains once the roster is read in full" \
  RUNNING 0 5 900 3 0 absent 900 600 complete
expect drain "…as does the partial-registration host" \
  RUNNING 0 1000 900 3 0 partial 900 600 complete
# A host whose K slots were ALL seen has a whole busy count regardless of who
# else was cut off, so truncation must not pin an idle pool at full size for
# ever — that would trade this defect for the immortal-VM one.
expect drain "a fully-present idle host still drains on a truncated roster" \
  RUNNING 0 1000 900 3 0 present 900 600 partial
expect keep "…and a busy one still does not" \
  RUNNING 2 0 900 3 0 present 900 600 partial
# Rule 1 outranks it: a host in a terminal power state holds no job, whatever
# the roster says, and it is the only path that reclaims one.
expect drain "a TERMINATED host is still reclaimed on a truncated roster" \
  TERMINATED 0 0 900 3 0 absent 900 600 partial
# An unreadable roster stays rule 2's answer, not rule 2b's, so the existing
# blind-tick alerting keeps naming the condition it was written for.
expect keep "an unreadable roster is still registration-unknown" \
  RUNNING 0 5 900 3 0 unknown 900 600 partial
# Anything that is not the word "complete" is treated as incomplete: a caller
# that grows a third roster state must opt IN to draining on absence.
expect keep "an unrecognised roster state is treated as incomplete" \
  RUNNING 0 5 900 3 0 absent 900 600 sometimes

# --- defaults ------------------------------------------------------------------
expect keep "no arguments at all must not authorise a deletion" \
  ""
# The tenth argument defaults to complete so the nine-argument callers and every
# case above it keep their meaning; the controller passes it explicitly.
expect drain "an omitted roster state keeps the pre-#17022 behaviour" \
  RUNNING 0 5 900 3 0 absent 900 600

# --- a delete already in flight ----------------------------------------------
# The regression: drain_host's own delete leaves the host listed as STOPPING,
# rule 1 reads that as a crashed host, and the second delete-instances fails.
# The controller asks mig_action_in_flight BEFORE any verdict, so that host is
# skipped; a STOPPING host with no MIG action is still reaped.
action() { # <want: yes|no> <description> <current_action>
  local got=no
  mig_action_in_flight "$3" && got=yes
  if [ "$got" = "$1" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  action: %s\n  want: %s\n  got:  %s\n' "$2" "$3" "$1" "$got"
  fi
}
action yes "the MIG deleting the host (our own drain) is a delete in flight" DELETING
action yes "the MIG abandoning the host is a delete in flight" ABANDONING
action no "no MIG action: an out-of-band stop is still ours to reap" NONE
action no "a missing column must not exempt a host from reaping" ""
action no "a host being created is not being removed" CREATING
action no "a host being recreated is not being removed" RECREATING
action no "gcloud prints the enum upper-case; nothing else matches" deleting
expect drain "STOPPING with no delete in flight is still a terminal host" \
  STOPPING 0 0 900 1 0 absent

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
