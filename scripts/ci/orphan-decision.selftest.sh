#!/usr/bin/env bash
# Self-test for the controller's orphan-registration rule.
#
# This rule deletes GitHub runner registrations. Getting it wrong in the
# permissive direction removes a LIVE slot from the pool (or kills a running
# job) and is only visible hours later as "the pool lost capacity", so every
# guard below is asserted here rather than on the fleet.
#
# Every case is a real situation this fleet has produced, not a synthetic input.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/orphan-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(orphan_decision "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

BASE=ci-runner-host-dataretrival

# args: name status busy base live_hosts_csv misses required_misses

# --- what the reaper exists to clean up ---------------------------------------
# 2026-08-13: the fleet was recycled onto a new golden image with
# `delete-instances`, which bypasses drain_host() and its deregister loop. 24
# registrations for six long-gone hosts were left behind in this repo alone.
expect reap "offline slot whose instance is gone is reaped once confirmed" \
  "$BASE-0ff6-s1" offline 0 "$BASE" "$BASE-pnph" 2 2
expect reap "reaped even when the pool is now genuinely empty" \
  "$BASE-52wl-s3" offline 0 "$BASE" "" 3 2

# --- the guards that make it safe ---------------------------------------------
# A failed `gcloud list-instances` returns an EMPTY host list, which reads
# exactly like a pool at zero. One bad tick must not deregister a live fleet.
expect keep "a single hostless tick is not enough" \
  "$BASE-0ff6-s1" offline 0 "$BASE" "" 0 2
expect keep "still not enough one tick later" \
  "$BASE-0ff6-s1" offline 0 "$BASE" "" 1 2

expect keep "an agent whose instance is alive is never touched" \
  "$BASE-pnph-s2" offline 0 "$BASE" "$BASE-pnph,$BASE-abcd" 9 2
expect keep "online agents are left alone" \
  "$BASE-0ff6-s1" online 0 "$BASE" "" 9 2
expect keep "a busy agent is never deregistered, whatever the MIG says" \
  "$BASE-0ff6-s1" offline 1 "$BASE" "" 9 2

# --- bounding the reaper to THIS pool -----------------------------------------
# A repo's runner list also carries the windows pool and whatever a retired
# one-VM-per-job pool left behind (SOAP-To-REST still had ci-runner-soap-to-rest-*
# entries). Those are someone else's to reclaim.
expect keep "another pool's agent in the same repo is not ours" \
  ci-runner-integrateit-windows-4bc1 offline 0 "$BASE" "" 9 2
expect keep "the retired pool's naming does not match the MIG base" \
  ci-runner-soap-to-rest-890v offline 0 ci-runner-host-soap "" 9 2
expect keep "an empty baseInstanceName reaps NOTHING rather than everything" \
  "$BASE-0ff6-s1" offline 0 "" "" 9 2

# The controller itself registers no agent, but a name without the "-s<N>" slot
# suffix has no host to join back to and must not be guessed at.
expect keep "a non-slot name is not resolvable to an instance" \
  "$BASE-controller" offline 0 "$BASE" "" 9 2

# A host name that merely PREFIXES a live one must not read as alive.
expect reap "prefix collision does not count as a live host" \
  "$BASE-ab-s1" offline 0 "$BASE" "$BASE-abcd" 2 2

printf 'orphan-decision selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
