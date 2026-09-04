#!/usr/bin/env bash
# Self-test for the controller's recycle rule — the bounded cordon-then-retire
# path for a host that cannot be repaired in place, for either of its two
# reasons: a template the apply has moved past, and registered capacity the host
# has lost and cannot get back.
#
# This rule DELETES MACHINES on nobody's trigger. Every other deletion in this
# pool is answering a question about the host itself — is it dead, is it idle,
# is it terminal. This one answers a question about the FLEET: an apply has
# moved on and this host has not. So it can be wrong in a way the others cannot:
# a single bad read, applied uniformly, takes out every host at once, because
# every host is stale by the same reasoning.
#
# The cases below are therefore weighted toward what a WRONG verdict destroys,
# not toward what a right one achieves. Fail-safe first, budget second, and the
# recycle itself last.
#
# Every case is a real failure mode of this pool, not a synthetic input.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/recycle-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(recycle_decision "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: status template busy reg age reg_grace in_flight max_unavail cordoned partial_for

# --- the kill switch -----------------------------------------------------------
# A mechanism that deletes hosts on a schedule nobody triggered must be
# stoppable without a rollback, and must be OFF for any caller that has not
# opted in — every existing consumer of this module predates the feature.
expect skip:disabled "max_unavailable=0 disables recycling entirely" \
  RUNNING stale 0 present 9999 600 0 0 0
expect skip:disabled "disabled outranks every reason to recycle" \
  RUNNING stale 0 absent 9999 600 0 0 1
expect skip:disabled "no arguments at all must not authorise a deletion" \
  ""

# --- fail-safe: the read that could take out the pool --------------------------
# `unknown` is what a gcloud hiccup, a quota error or a renamed API field reads
# as. Treated as stale it would cordon EVERY host in one tick, because they
# would all read unknown together. Recycling late costs a release cycle;
# recycling on a bad read costs the pool.
expect skip:template "an unreadable template is never stale" \
  RUNNING unknown 0 present 9999 600 0 1 0
expect skip:template "a current-template host is left alone" \
  RUNNING current 0 present 9999 600 0 1 0
expect skip:template "current outranks an empty, ancient, idle host" \
  RUNNING current 0 absent 99999 600 0 4 0

# GitHub unreachable means busy=0 is evidence of nothing. Cordoning on it would
# deregister slots that are executing jobs.
expect skip:registration-unknown "GitHub unreachable: never cordon on an unproven idle" \
  RUNNING stale 0 unknown 9999 600 0 1 0
expect skip:registration-unknown "registration-unknown outranks a stale template" \
  RUNNING stale 0 unknown 9999 600 0 4 1

# A non-RUNNING host is drain_decision's unconditional delete already; racing it
# for the same instance in the same tick is how one delete fails noisily.
expect skip:not-running "a TERMINATED host is drain's business, not recycle's" \
  TERMINATED stale 0 present 9999 600 0 1 0
expect skip:not-running "a stopping Spot host is not recycled" \
  STOPPING stale 1 present 9999 600 0 1 0

# --- the churn loop this rule must not create ----------------------------------
# A booting host reads absent + busy=0, which is indistinguishable from an empty
# host ready to retire. Retire it there and the MIG recreates, the replacement
# boots, reads absent, and is shot in turn — forever, while every metric reports
# healthy recycling. This is the DataRetrival 2026-08-13 failure, in a new rule.
expect skip:booting "a 44s-old host is never retired as empty" \
  RUNNING stale 0 absent 44 600 0 1 0
expect skip:booting "booting outranks an available budget" \
  RUNNING stale 0 absent 599 600 0 4 0
expect retire "past the register grace, an empty stale host retires" \
  RUNNING stale 0 absent 601 600 0 1 0

# --- the budget: rolling, not all at once --------------------------------------
# A cordoned host's idle slots leave the pool immediately. Cordon every stale
# host at once and the fleet's whole spare capacity is gone in one tick, with
# every queued job waiting on a boot.
expect skip:at-capacity "one recycle already in flight blocks a second host" \
  RUNNING stale 2 present 9999 600 1 1 0
expect skip:at-capacity "the budget bounds retirement too, not only cordoning" \
  RUNNING stale 0 present 9999 600 2 2 0
expect cordon "budget with room left permits the next host" \
  RUNNING stale 2 present 9999 600 1 2 0

# A host ALREADY mid-recycle is already counted in in_flight. Re-applying the
# budget to it would strand it: no idle slots, no way back, parked forever.
expect cordon "an already-cordoned host finishes its recycle at capacity" \
  RUNNING stale 1 partial 9999 600 3 1 1
expect retire "an already-cordoned host retires once its last job lands" \
  RUNNING stale 0 absent 9999 600 3 1 1

# --- the two phases ------------------------------------------------------------
# Nothing is ever killed. A busy host is cordoned, not retired: GitHub refuses
# to deregister an agent executing a job, so the working slot survives while
# every idle slot leaves the pool — after which no new job can reach this host.
expect cordon "a working stale host is cordoned, never retired" \
  RUNNING stale 1 present 9999 600 0 1 0
expect cordon "a fully busy stale host is cordoned, not interrupted" \
  RUNNING stale 4 present 9999 600 0 1 0
expect cordon "cordoning is re-issued while any slot still works" \
  RUNNING stale 1 partial 9999 600 1 1 1
expect retire "the tick after the last job lands, the host retires" \
  RUNNING stale 0 partial 9999 600 1 1 1

# --- what recycle deliberately ignores ------------------------------------------
# The idle grace window keeps a host WARM for the next job. Keeping a stale host
# warm keeps the wrong startup script warm with it, so recycle does not wait on
# it — that is the whole difference from drain_decision.
expect retire "a stale host does not get the warm-idle grace window" \
  RUNNING stale 0 present 9999 600 0 1 0

# The min_hosts floor exists so the next job finds a hot host. The autoscaler is
# ONLY_UP with min_replicas = min_hosts, so retiring at the floor is not churn —
# it is the replacement, rebuilt from the CURRENT template. A rule that honoured
# the floor would leave a min_hosts=1 pool permanently un-upgradable.
expect retire "the floor does not protect a stale host from replacement" \
  RUNNING stale 0 present 9999 600 0 1 0

# --- the second reason: capacity the host lost and cannot get back --------------
#
# Measured on the Telnet pool, 2026-09-04. A drain was authorised at 13:11:46Z
# on a host idle past the grace window; the loop deregistered the first agent,
# a job arrived in the same tick, GitHub answered the second DELETE with 422,
# and the drain aborted. The guard did its job — the running job finished. What
# it does not do is put back the agent already removed, and agents here are not
# --ephemeral with Restart=no units, so that slot stayed gone: ci_slots_missing
# = 1 for fifty-five minutes, on a host with a perfectly current template.
#
# Nothing was going to repair it. This rule refused it for not being stale, and
# drain_decision's idle-past-grace path was the only one left — which fires only
# if the pool happens to go idle above its min_hosts floor. It did, at 14:05, by
# coincidence. On a pool at its floor the phantom slot lives as long as the host.
expect retire "a host that lost capacity is retired though its template is current" \
  RUNNING current 0 partial 9999 600 0 1 0 961
expect cordon "a working capacity-lost host is cordoned, never interrupted" \
  RUNNING current 2 partial 9999 600 0 1 0 3600
expect retire:capacity-lost "the reason is reported, so the delete can be explained afterwards" \
  RUNNING current 0 partial 9999 600 0 1 0 3600

# HYSTERESIS. ci-slot-sweep stops a dirty slot's agent, resets the workspace and
# starts it again inside about ninety seconds — during which the host reads
# `partial` while doing exactly what it is built to do. A rule that acted on one
# tick's read would delete hosts for sweeping.
# THE WINDOW IS NOT reg_grace. ci-slot-sweep's unit carries TimeoutStartSec=900
# on a 30-second timer — generous on purpose, so one wedged docker call cannot
# stop every later sweep on the host. A slot that IS coming back can therefore be
# missing for ~930s, and the host reads `partial` throughout. A rule that fired
# inside that window would race the host's own repair and win: the slot would
# have returned, and instead the pool cordons the rest and deletes the host.
expect skip:partial-grace "the default grace alone would race the host's own sweep" \
  RUNNING current 0 partial 9999 600 0 1 0 700
expect skip:partial-grace "the sweep's worst case is inside the window, not past it" \
  RUNNING current 0 partial 9999 600 0 1 0 930
expect retire "past the sweep's worst case, the slot is not coming back" \
  RUNNING current 0 partial 9999 600 0 1 0 961
# ...and the floor is a floor, not a replacement: a pool that RAISED reg_grace
# for slow-booting hosts gets its own longer window, not the constant.
expect skip:partial-grace "a longer register grace widens the window with it" \
  RUNNING current 0 partial 9999 1800 0 1 0 1500
expect retire "and the longer window still ends" \
  RUNNING current 0 partial 9999 1800 0 1 0 1801

expect skip:partial-grace "a slot mid-sweep is not capacity loss" \
  RUNNING current 0 partial 9999 600 0 1 0 90
expect skip:partial-grace "one tick of partial is never enough" \
  RUNNING current 0 partial 9999 600 0 1 0 0
expect skip:partial-grace "the boundary belongs to the window, not past it" \
  RUNNING current 0 partial 9999 600 0 1 0 959

# THE CALLER THAT DOES NOT TRACK IT. The parameter is tenth and defaults to 0,
# so an older caller — or one that cannot keep the clock — gets exactly the
# behaviour it had before this reason existed. Absence means "never", the same
# way max_unavailable=0 does.
expect skip:partial-grace "a caller that omits the clock never recycles for capacity" \
  RUNNING current 0 partial 9999 600 0 1 0

# The safety rules still outrank it — the reason is new, the fail-safes are not.
expect skip:disabled "the kill switch stops a capacity-lost recycle too" \
  RUNNING current 0 partial 9999 600 0 0 0 9999
expect skip:booting "the booting guard outranks the capacity reason too" \
  RUNNING current 0 partial 300 600 0 1 0 9999
expect skip:at-capacity "capacity-lost recycles are rolled, not done at once" \
  RUNNING current 0 partial 9999 600 1 1 0 9999
expect skip:not-running "a TERMINATED host is not recycled for missing slots" \
  TERMINATED current 0 partial 9999 600 0 1 0 9999

# `absent` is NOT this rule's business. A host with no agents at all is either
# still booting or already drain_decision's — and treating it here would put the
# churn loop back: retire, MIG recreates, replacement reads absent, shot in turn.
expect skip:template "a host with no agents at all is left to drain_decision" \
  RUNNING current 0 absent 9999 600 0 1 0 9999
# ...and `unknown` cannot manufacture the reason either. partial_seconds() clears
# the clock on any non-partial read, but the rule must not depend on it doing so.
expect skip:template "an unreadable registration is not capacity loss" \
  RUNNING current 0 unknown 9999 600 0 1 0 9999

# A stale template still wins the naming when both are true: it is the reason
# that also requires the host to be rebuilt, not merely replaced.
expect retire:stale-template "stale template outranks capacity-lost in the reason" \
  RUNNING stale 0 partial 9999 600 0 1 0 9999

# --- and the number is not a magic number --------------------------------------
#
# The 960s floor is DERIVED: ci-slot-sweep's TimeoutStartSec plus its timer
# interval, both declared in host-startup.sh. Those two live in a different file
# from the rule that depends on them, so nothing but this check stops somebody
# raising the sweep's timeout to 1800 and, in the same release, teaching the
# controller to delete every host whose sweep takes longer than sixteen minutes.
# Read out of the shipping text rather than restated, so the drift is the failure.
HOST_STARTUP="$HERE/../../modules/ci-runner-host-pool/scripts/host-startup.sh"
_sweep_timeout=$(sed -n '/ci-slot-sweep.service/,/^EOF$/p' "$HOST_STARTUP" |
  sed -n 's/^TimeoutStartSec=\([0-9]*\).*/\1/p' | head -1)
_sweep_interval=$(sed -n '/ci-slot-sweep.timer/,/^EOF$/p' "$HOST_STARTUP" |
  sed -n 's/^OnUnitActiveSec=\([0-9]*\).*/\1/p' | head -1)
_floor=$(sed -n 's/.*\$window" -lt \([0-9]*\).*/\1/p' \
  "$HERE/../../modules/ci-runner-host-pool/scripts/recycle-decision.sh" | head -1)

if [ -z "$_sweep_timeout" ] || [ -z "$_sweep_interval" ] || [ -z "$_floor" ]; then
  FAIL=$((FAIL + 1))
  printf 'FAIL: could not read the sweep bound or the rule floor — timeout=[%s] interval=[%s] floor=[%s]\n' \
    "$_sweep_timeout" "$_sweep_interval" "$_floor"
elif [ "$_floor" -ge $((_sweep_timeout + _sweep_interval)) ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL: the hysteresis floor (%ss) no longer outlasts the slot sweep (%ss + %ss)\n' \
    "$_floor" "$_sweep_timeout" "$_sweep_interval"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
