#!/usr/bin/env bash
# Self-test for the controller's Windows liveness rule.
#
# This rule DELETES MACHINES. On Linux the same question is answered by an SSH
# call the controller makes itself; on Windows it is answered by a value the
# HOST publishes, which means every failure mode of the publisher, the clock and
# the API is an input to the verdict rather than an exception around it.
#
# So the cases below are not a sample. They are every branch of the rule, plus
# the boundaries of each numeric comparison in it, plus the three degraded
# states that a naive implementation reads as "idle": a failed read, an absent
# key, and a stale value. Each of those three deletes a host that may be running
# somebody's merge-blocking job, and none of them is visible until it has.
#
# The rule ships one pull request before anything calls it, on purpose: the
# predicate that authorises a deletion should be proven before the code path
# that acts on it exists, not alongside it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/beacon-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(beacon_decision "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: read_status present workers ts now interval age grace regs misses need
#
# A fixed clock, so the arithmetic in each case is readable rather than relative
# to when the suite happens to run. INT=30 makes the staleness ceiling 90s.
NOW=1000000
INT=30
GRACE=600
NEED=2

# --- the ONE affirmative case -------------------------------------------------
# Read worked, beacon present, fresh, zero workers. This is the only shape in
# the entire rule that authorises deleting a host on positive evidence.
expect delete "a fresh beacon reporting zero workers is the delete case" \
  0 1 0 "$NOW" "$NOW" "$INT" 3600 "$GRACE" 2 0 "$NEED"
expect delete "still deletable at the last fresh second (age == 3x interval)" \
  0 1 0 "$((NOW - 90))" "$NOW" "$INT" 3600 "$GRACE" 2 0 "$NEED"

# --- a worker is alive --------------------------------------------------------
expect keep "one worker keeps the host" \
  0 1 1 "$NOW" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"
expect keep "several workers keep the host" \
  0 1 4 "$NOW" "$NOW" "$INT" 3600 "$GRACE" 4 9 "$NEED"

# --- degraded state 1: the read failed ----------------------------------------
# A non-zero exit from get-guest-attributes is NOT "no workers". Guest
# attributes are capped at 10 queries per minute per instance, so the way this
# case arrives at scale is a busy fleet — deleting hosts because the pool got
# busy is the worst possible correlation.
expect keep "an API error is not an idle host" \
  1 0 "" 0 "$NOW" "$INT" 3600 "$GRACE" 0 9 "$NEED"
expect keep "a read failure outranks every other input, including a zero count" \
  1 1 0 "$NOW" "$NOW" "$INT" 3600 "$GRACE" 0 9 "$NEED"

# --- degraded state 2: no beacon ----------------------------------------------
expect keep "a booting host has not published yet" \
  0 0 "" 0 "$NOW" "$INT" 60 "$GRACE" 0 9 "$NEED"
expect keep "the grace floor is not open at its own boundary" \
  0 0 "" 0 "$NOW" "$INT" 599 "$GRACE" 0 9 "$NEED"

# Registered but silent: the boot script ran far enough to install a runner, so
# the publisher is what broke — and a worker can exist behind it. This is the
# guard that keeps "never-booted" meaning what it says.
expect keep "a host GitHub knows about is never deleted for a missing beacon" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 1 99 "$NEED"
expect keep "still kept when it holds a full complement of agents" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 4 99 "$NEED"

# Never booted: old enough, no beacon, and no agent in GitHub's list. No runner
# was ever installed, so no worker can exist. Without this the host is
# undeletable forever and bills until somebody notices by hand.
expect keep "one silent tick is not enough to call a host never-booted" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 0 0 "$NEED"
expect keep "nor is the second-to-last one" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 0 1 "$NEED"
expect delete "confirmed never-booted is reclaimed" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 0 2 "$NEED"

# --- degraded state 3: the beacon is stale ------------------------------------
# The publisher died. The host may be perfectly busy; we simply no longer know,
# and "no longer know" is a keep.
expect keep "a stale beacon is not an idle host, whatever it last said" \
  0 1 0 "$((NOW - 91))" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"
expect keep "an hour-old zero is still not an idle host" \
  0 1 0 "$((NOW - 3600))" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"

# --- a malformed beacon is a broken publisher, not an idle host ---------------
# These also protect the arithmetic below them: an unvalidated non-numeric value
# in a bash `-gt` is a syntax error whose failure mode is a wrong verdict.
expect keep "a non-numeric worker count decides nothing" \
  0 1 "many" "$NOW" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"
expect keep "an empty worker count decides nothing" \
  0 1 "" "$NOW" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"
expect keep "a negative worker count is not a valid count" \
  0 1 -1 "$NOW" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"
expect keep "an unparsed timestamp decides nothing" \
  0 1 0 0 "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"
expect keep "a non-numeric timestamp decides nothing" \
  0 1 0 "2026-08-15T10:00:00Z" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"

# A future timestamp is the one value that makes a dead publisher look
# permanently fresh, and Google documents guest attributes as writable by ANY
# process on the VM, job code included. Ordinary clock skew gets one interval of
# slack; beyond that the reading cannot be dated and is not used.
expect keep "a timestamp far in the future cannot be aged" \
  0 1 0 "$((NOW + 86400))" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"
expect delete "modest skew inside one interval is still usable" \
  0 1 0 "$((NOW + 20))" "$NOW" "$INT" 3600 "$GRACE" 2 9 "$NEED"

# --- defaults ------------------------------------------------------------------
# Called with nothing, the rule must keep. A future caller that forgets an
# argument gets the safe verdict, not the destructive one.
expect keep "no arguments at all is a keep" # (no args)

if [ "$FAIL" -gt 0 ]; then
  echo "beacon-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "beacon-decision: $PASS cases pass"
