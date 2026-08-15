#!/usr/bin/env bash
# Self-test for the controller's stale-template recycle rule.
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

# args: status template busy reg age reg_grace in_flight max_unavail cordoned

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
