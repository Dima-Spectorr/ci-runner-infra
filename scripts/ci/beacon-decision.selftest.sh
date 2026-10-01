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

# --- the read was REFUSED, which is not the read failing ----------------------
# constraints/compute.disableGuestAttributesAccess turns the channel off for the
# whole project. Every read fails, every tick, forever — so "we did not get an
# answer this time" is the wrong sentence: there is no beacon here and there
# never will be. Read as an ordinary failure it shadows all of rule 2, and the
# never-booted arm above becomes unreachable on exactly the projects that need
# it. Measured in production 2026-09-05 on a project that enforces the
# constraint: a host that had denied its own boot sat RUNNING and undeletable
# for hours, alerting twice over.
#
# The twelfth argument is what tells the two apart. Nothing else about the rule
# moves: these cases are the same shapes as the never-booted block, and they
# answer the same way.
expect keep "a refused read still keeps a booting host" \
  1 0 "" 0 "$NOW" "$INT" 60 "$GRACE" 0 9 "$NEED" 1
expect keep "a refused read still keeps a host GitHub knows has agents" \
  1 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 1 99 "$NEED" 1
expect keep "a refused read still needs its confirmations" \
  1 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 0 1 "$NEED" 1
expect delete "a host that can never publish a beacon is reclaimable once confirmed" \
  1 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 0 2 "$NEED" 1

# The distinction has to be the POLICY FLAG and not the non-zero status, or the
# quota case above starts deleting hosts on a busy fleet. Same arguments as the
# delete directly above; only the twelfth changes.
expect keep "an ordinary read failure with the same shape is still a keep" \
  1 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 0 2 "$NEED" 0
expect keep "and a caller that omits the flag entirely gets the old behaviour" \
  1 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 0 2 "$NEED"

# The flag lets the rule reach rule 2. It must not let it reach rule 3d, which
# needs a beacon this project cannot produce — `present` is 0 whenever a read
# was refused, so the affirmative delete stays out of reach by construction.
# Asserted anyway, because a later edit could move the flag test past rule 2.
expect keep "the flag never authorises the idle-beacon delete on a booting host" \
  1 0 0 "$NOW" "$NOW" "$INT" 60 "$GRACE" 0 9 "$NEED" 1

# --- registered, no beacon, and every agent offline ---------------------------
# The host rebooted and its boot script stopped at the missing registration
# token. GitHub still lists its agents, all offline, none busy. Measured
# 2026-10-01: kept forever by the registered-without-beacon row, with the pool's
# only host dead. The thirteenth argument is the offline count.
expect keep:unconfirmed-all-offline "all agents offline still needs its confirmations" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 2 1 "$NEED" 0 2
expect delete:registered-all-offline "all agents offline, confirmed, is reclaimable" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 2 2 "$NEED" 0 2
expect delete:registered-all-offline "and so it is where the org policy refuses the read" \
  1 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 2 2 "$NEED" 1 2
expect keep:registered-without-beacon "one agent still online keeps the host" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 2 99 "$NEED" 0 1
expect keep:registered-without-beacon "a caller that omits the count gets the old keep" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 2 99 "$NEED" 0
expect keep:registered-without-beacon "a malformed count is not evidence" \
  0 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 2 99 "$NEED" 0 "x"
expect keep:booting "all offline inside the grace is a booting host" \
  0 0 "" 0 "$NOW" "$INT" 60 "$GRACE" 2 99 "$NEED" 0 2
expect keep:read-failed "all offline never overrides an ordinary read failure" \
  1 0 "" 0 "$NOW" "$INT" 7200 "$GRACE" 2 99 "$NEED" 0 2
expect keep "all offline never overrides a beacon that reports a worker" \
  0 1 1 "$NOW" "$NOW" "$INT" 7200 "$GRACE" 2 99 "$NEED" 0 2

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

# --- guest_attributes_namespace_absent (#1384) ----------------------------------
# The one 404 that is a successful read with no rows: the namespace was never
# written on this host. Every neighbouring failure must stay a failure, because
# each of those can hide a hold or a beacon that is really there.
absent() { # <description> <expected 0|1> <text> [namespace]
  local got=0
  guest_attributes_namespace_absent "$3" "${4-ci}" || got=1
  if [ "$got" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  text: %s\n  want: %s got: %s\n' "$1" "$3" "$2" "$got"
  fi
}
# Verbatim from a live pool host on 2026-09-29.
NS404="ERROR: (gcloud.compute.instances.get-guest-attributes) HTTPError 404: The resource 'ci/' of type 'Guest Attribute' was not found. This command is authenticated as sa@example.iam.gserviceaccount.com which is the active account specified by the [core/account] property."
absent "the live namespace 404 is recognised" 0 "$NS404"
absent "a line-wrapped namespace 404 is recognised" 0 \
  "$(printf "ERROR: HTTPError 404: The resource 'ci/' of type 'Guest\nAttribute' was not found.")"
absent "a CRLF namespace 404 is recognised" 0 \
  "$(printf "HTTPError 404: The resource 'ci/' of type 'Guest Attribute' was not found.\r\n")"
# Same call, same moment, a host that is gone. Verbatim too.
absent "a missing INSTANCE is not a missing namespace" 1 \
  "ERROR: (gcloud.compute.instances.get-guest-attributes) HTTPError 404: The resource 'projects/p/zones/z/instances/h1' was not found. This command is authenticated as sa@example.iam.gserviceaccount.com"
absent "a missing KEY is not a missing namespace" 1 \
  "ERROR: HTTPError 404: The resource 'ci/pin-hold' of type 'Guest Attribute' was not found."
absent "another namespace is not the one asked for" 1 \
  "ERROR: HTTPError 404: The resource 'other/' of type 'Guest Attribute' was not found."
absent "the right text under another status is not this" 1 \
  "ERROR: HTTPError 403: The resource 'ci/' of type 'Guest Attribute' was not found."
absent "the org-policy refusal is not this" 1 \
  "ERROR: HTTPError 412: Constraint constraints/compute.disableGuestAttributesAccess violated for project 1."
absent "a rate limit is not this" 1 "ERROR: HTTPError 429: Quota exceeded for quota metric 'Guest attribute queries'"
absent "an empty error is not this" 1 ""
# The text names the bare '/' resource, so this fails only because the empty
# namespace is refused -- not because the text happened not to match.
absent "no namespace to match against is never a match" 1 \
  "ERROR: HTTPError 404: The resource '/' of type 'Guest Attribute' was not found." ""
absent "a namespace that is not a plain name is never a match" 1 \
  "ERROR: HTTPError 404: The resource '*/' of type 'Guest Attribute' was not found." '*'

# --- event_throttle_decision / pin_hold_class ------------------------------------
# A gate's event is sent when its class changes and on a heartbeat -- never on
# every tick, and never withheld when the record cannot be trusted.
throttle() { # <description> <expected> <prev> <class> <now> [interval]
  local got
  got=$(event_throttle_decision "$3" "$4" "$5" "${6:-600}")
  if [ "$got" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s got: %s\n' "$1" "$2" "$got"
  fi
}
throttle "the first event of an episode is sent" emit "" read-failed 1000
throttle "the same class inside the heartbeat is quiet" quiet "read-failed 1000" read-failed 1060
throttle "one second short of the heartbeat is still quiet" quiet "read-failed 1000" read-failed 1599
throttle "the heartbeat sends it again" emit "read-failed 1000" read-failed 1600
throttle "a change of class is sent at once" emit "live-published 1000" read-failed 1060
throttle "a record with no time is sent" emit "read-failed" read-failed 1060
throttle "a record with a garbage time is sent" emit "read-failed abc" read-failed 1060
throttle "a clock that went backwards is sent" emit "read-failed 2000" read-failed 1060
throttle "an unreadable clock is sent" emit "read-failed 1000" read-failed ""
throttle "a garbage interval falls back to the default" quiet "read-failed 1000" read-failed 1060 "x"

cls() { # <description> <expected> <verdict>
  local got
  got=$(pin_hold_class "$3")
  if [ "$got" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s got: %s\n' "$1" "$2" "$got"
  fi
}
cls "a live published hold is the mechanism working" "live-published INFO" \
  "hold:run=77 expiry=1600 live published remaining=600s"
cls "a live cached hold is the mechanism working" "live-cached INFO" \
  "hold:run=77 expiry=1600 live cached clamped remaining=60s"
cls "a failed read is a warning" "read-failed WARNING" "hold:run= expiry=0 read-failed status=1"
cls "no zone is a warning" "no-zone WARNING" "hold:run= expiry=0 no-zone"
cls "a malformed publish is a warning" "malformed-hold WARNING" "hold:run= expiry=0 malformed-hold"
cls "anything unrecognised is a warning, never INFO" "other WARNING" "hold:something new"
cls "the class carries no expiry, so a moving deadline is not a change" \
  "$(pin_hold_class "hold:run=77 expiry=1600 live published remaining=600s")" \
  "hold:run=77 expiry=9999 live published remaining=1s"

if [ "$FAIL" -gt 0 ]; then
  echo "beacon-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "beacon-decision: $PASS cases pass"
