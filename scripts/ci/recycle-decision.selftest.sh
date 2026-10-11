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

# args: status template busy reg age reg_grace in_flight max_unavail cordoned partial_for reserved_for

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
expect reserve "budget with room left permits the next host" \
  RUNNING stale 2 present 9999 600 1 2 0
# A RESERVED host is in flight too: its replacement is already bought. Dropping
# it at the budget would pay for the surge and never cordon the old host.
expect reserve "an already-reserved host keeps its reservation at capacity" \
  RUNNING stale 2 present 9999 600 4 4 0 0 120
expect cordon "an already-reserved host is cordoned at capacity once due" \
  RUNNING stale 2 present 9999 600 4 4 0 0 600

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
expect reserve "a working stale host is reserved first, never retired" \
  RUNNING stale 1 present 9999 600 0 1 0
expect reserve "a fully busy stale host is reserved, not interrupted" \
  RUNNING stale 4 present 9999 600 0 1 0

# --- make before break ---------------------------------------------------------
# Measured 2026-10-11 on a 20-host pool at max_hosts with max_unavailable=4:
# four hosts cordoned with 2-3 jobs each, runs queued, and the autoscaler could
# buy nothing — the idle slots the cordons removed were simply lost, for a
# two-hour rollout. So a working host is RESERVED first: it keeps serving while
# its replacement is bought, and is cordoned only once register_grace — the
# module's own bound on a new host booting and registering — has passed.
expect reserve:stale-template "the first tick of a recycle reserves, it does not cordon" \
  RUNNING stale 2 present 9999 600 0 4 0 0 -1
expect reserve "a reservation younger than register_grace keeps serving" \
  RUNNING stale 2 present 9999 600 1 4 0 0 599
expect cordon:stale-template "at register_grace the replacement has had its boot: cordon" \
  RUNNING stale 2 present 9999 600 1 4 0 0 600
expect cordon "a replacement that never arrived does not hold the cordon forever" \
  RUNNING stale 2 present 9999 600 1 4 0 0 86400
expect reserve "the Windows grace is the Windows window" \
  RUNNING stale 1 present 9999 1200 1 4 0 0 900
expect retire "a reserved host whose last job lands retires without a cordon" \
  RUNNING stale 0 present 9999 600 1 4 0 0 120
# A cordon is never walked back into a reservation: its deregistered slots do
# not come back, so the host must keep moving towards retirement.
expect cordon "a cordoned host stays cordoned whatever its reservation reads" \
  RUNNING stale 2 partial 9999 600 1 4 1 0 0
expect cordon "a cordoned host with no reservation (pre-upgrade marker) stays cordoned" \
  RUNNING stale 2 partial 9999 600 1 4 1 0 -1
# The fail-safes still outrank the reservation.
expect skip:registration-unknown "a reserved host is never cordoned on an unreadable registration" \
  RUNNING stale 2 unknown 9999 600 1 4 0 0 9999
expect skip:disabled "the kill switch stops a reserved host too" \
  RUNNING stale 2 present 9999 600 1 0 0 0 9999
expect reserve "garbage in the reservation clock reads as no reservation" \
  RUNNING stale 2 present 9999 600 0 4 0 0 abc
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
expect reserve:capacity-lost "a working capacity-lost host is reserved, never interrupted" \
  RUNNING current 2 partial 9999 600 0 1 0 3600
expect cordon:capacity-lost "and cordoned once its replacement has had its boot" \
  RUNNING current 2 partial 9999 600 1 1 0 3600 600
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
# shellcheck disable=SC2016  # the $window is the shipping source text being matched, not a variable to expand.
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

# --- the surge: what the autoscaler is told while hosts are replaced ------------
# args: demand recycling_hosts recycling_busy max_hosts jobs_per_host
# The autoscaler buys ceil(published / jobs_per_host) hosts, ceiling
# max_hosts + recycle_max_unavailable. These pin the arithmetic that makes the
# replacement get bought, and the cap that makes the surge end.
surge() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(recycle_surge_demand "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
# The measured incident: 20 hosts x 4 slots, headroom 1 (3 jobs per host), at
# max_hosts with a queue, four hosts recycling with 10 jobs between them.
# Before: the autoscaler was told 90 jobs = 30 hosts, capped at 20 — nothing
# bought. Now: 60 shared (capped at 20 hosts) + 4 hosts' worth = 72 = 24 hosts.
surge 72 "a saturated pool at max_hosts buys one replacement per recycling host" \
  90 4 10 20 3
# Nothing recycling: the controller enforces max_hosts itself, because the
# autoscaler's max_replicas now carries the surge headroom.
surge 60 "with nothing recycling the demand is capped at max_hosts" \
  90 0 0 20 3
surge 7 "a pool under its ceiling is told its plain demand" \
  7 0 0 20 3
# A quiet pool: the recycling host carries its own 2 jobs and still asks for
# exactly one host's worth beside the shared 1 job: 1 + 3 = 4 = 2 hosts.
surge 4 "a recycling host counts as one host, its jobs carried by itself" \
  3 1 2 20 3
# The last warm host recycling: min_hosts 1, its 2 jobs are all the demand.
# The warm floor joins the shared part, so the replacement is bought first:
# 3 + 3 = 6 = 2 hosts, not 1 host and a pool that touches zero on retire.
surge 6 "recycling the last warm host buys its replacement before it goes" \
  2 1 2 20 3 1
surge 2 "the warm floor is not added while nothing recycles" \
  2 0 0 20 3 1
surge 63 "a warm floor above max_hosts is clamped to max_hosts" \
  0 1 0 20 3 99
# Busy reported above demand (a run listed late) must not go negative.
surge 3 "recycling busy above demand never subtracts below zero" \
  2 1 5 20 3
surge 0 "an empty pool with nothing recycling asks for nothing" \
  0 0 0 20 3
surge 60 "garbage in the recycle set degrades to the capped plain demand" \
  90 x 10 20 3
surge 90 "jobs_per_host 0 is floored at 1, never a division by zero downstream" \
  90 0 0 90 0
# The cap holds the WHOLE pool at max_hosts + recycling: here 20 + 4 = 24 hosts.
_p=$(recycle_surge_demand 500 4 12 20 3)
if [ $(((_p + 2) / 3)) -le 24 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL: surge exceeded max_hosts + recycling: %s jobs = %s hosts\n' "$_p" $(((_p + 2) / 3))
fi

# --- the idle-drain floor while a recycle is live -------------------------------
# args: published jobs_per_host min_hosts. The pool size the autoscaler is being
# told to hold; an idle drain below it is bought straight back next tick.
floor() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(recycle_surge_floor "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}
floor 2 "an old host plus its replacement are both kept" 6 3 1
floor 24 "a saturated pool keeps max_hosts + recycling" 72 3 0
floor 2 "a part-filled host still rounds up" 4 3 0
floor 5 "never below the warm floor" 3 3 5
floor 0 "garbage published keeps nothing extra" x 3 0
floor 7 "jobs_per_host 0 is floored at 1" 7 0 0

# The autoscaler's ceiling is the other half of the surge. Read from the shipping
# Terraform, so a revert of max_replicas to max_hosts — which would silently cap
# the surge at zero on any pool already at its ceiling — fails here.
if grep -qE 'max_replicas[[:space:]]*=[[:space:]]*var\.max_hosts[[:space:]]*\+[[:space:]]*var\.recycle_max_unavailable' \
  "$HERE/../../modules/ci-runner-host-pool/main.tf"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL: the autoscaler max_replicas is not max_hosts + recycle_max_unavailable\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
