#!/usr/bin/env bash
# Self-test for pinned_job_decision (modules/ci-runner-host-pool/scripts/pinned-job-decision.sh).
#
# Two of the five verdicts act on somebody's workflow run — `orphan` cancels it
# — and the function is the only thing standing between a MIG listing that
# blipped and a cancelled build. The cases below are written around that: most
# of them assert what must NOT happen.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../modules/ci-runner-host-pool/scripts/pinned-job-decision.sh
. "$here/../../modules/ci-runner-host-pool/scripts/pinned-job-decision.sh"

fail=0
POOL="self-hosted,linux,gcp,Repo"
BASE="ci-lin"
LIVE="ci-lin-a1b2,ci-lin-c3d4"

expect() {
  local want="$1" desc="$2"; shift 2
  local got; got="$(pinned_job_decision "$@")"
  case "$got" in
    "$want"*) printf 'ok   %s\n' "$desc" ;;
    *) printf 'FAIL %s\n       want %s...\n       got  %s\n' "$desc" "$want" "$got"; fail=1 ;;
  esac
}

# --- not ours -----------------------------------------------------------------
expect ignore: "a GitHub-hosted job has no labels at all" \
  queued "" "$POOL" "$BASE" "$LIVE" 0 300
expect ignore: "another pool's job (a label we do not carry)" \
  queued "self-hosted,windows,gcp,Repo" "$POOL" "$BASE" "$LIVE" 0 300
expect ignore: "a subset of our labels is still not ours if one label is foreign" \
  queued "self-hosted,linux,arm64" "$POOL" "$BASE" "$LIVE" 0 300

# --- ordinary demand ----------------------------------------------------------
expect demand: "an unpinned job asking for a strict subset is demand" \
  queued "self-hosted,linux" "$POOL" "$BASE" "$LIVE" 0 300
expect demand: "the anchor — unpinned, full label set — is demand, so scale-out survives" \
  queued "$POOL" "$POOL" "$BASE" "$LIVE" 0 300

# --- pinned, and therefore NOT scale-out demand -------------------------------
expect pinned: "pinned to a live host: counted busy, never a reason to add a host" \
  queued "self-hosted,linux,gcp,Repo,host-ci-lin-a1b2" "$POOL" "$BASE" "$LIVE" 0 300
expect pinned: "the affinity label is stripped before the subset test, not after" \
  queued "self-hosted,linux,host-ci-lin-c3d4" "$POOL" "$BASE" "$LIVE" 0 300
expect pinned: "label order does not matter — the pin may come first" \
  queued "host-ci-lin-a1b2,self-hosted,linux" "$POOL" "$BASE" "$LIVE" 0 300

# --- the labels are attacker-controlled on a fork PR --------------------------
# Both membership tests are `case` patterns, so glob syntax in a label would
# match things the label does not name. Refused rather than classified.
expect ignore: "a label of * does not match every pool label" \
  queued "self-hosted,*" "$POOL" "$BASE" "$LIVE" 0 300
expect ignore: "a pin of host-ci-lin-* does not match a live host it does not name" \
  queued "self-hosted,linux,host-ci-lin-*" "$POOL" "$BASE" "$LIVE" 0 300
expect ignore: "a bracket expression is refused too" \
  queued "self-hosted,linu[x]" "$POOL" "$BASE" "$LIVE" 0 300

# --- membership is fenced, not substring --------------------------------------
expect ignore: "a job label that merely EXTENDS one of ours is not one of ours" \
  queued "self-hosted,linux-arm64" "$POOL" "$BASE" "$LIVE" 0 300
expect orphan: "a pin that is a PREFIX of a live host is not that host" \
  queued "self-hosted,linux,host-ci-lin-a1" "$POOL" "$BASE" "$LIVE" 301 300

# --- the guards that stop a wrong cancellation --------------------------------
expect pinned: "an in-flight job is never orphaned, even against an empty host list" \
  in_progress "self-hosted,linux,host-ci-lin-a1b2" "$POOL" "$BASE" "" 99999 300
expect ignore: "a pin naming another pool's host is not ours to judge" \
  queued "self-hosted,linux,host-ci-win-9z8y" "$POOL" "$BASE" "$LIVE" 99999 300
expect ignore: "and prefix similarity is not membership: ci-linux-* is not ci-lin-*" \
  queued "self-hosted,linux,host-ci-linux-0000" "$POOL" "$BASE" "$LIVE" 99999 300
expect wait: "a host mid-boot is waited on, not cancelled" \
  queued "self-hosted,linux,host-ci-lin-new1" "$POOL" "$BASE" "$LIVE" 30 300
expect wait: "the first tick's empty host list cancels nothing" \
  queued "self-hosted,linux,host-ci-lin-a1b2" "$POOL" "$BASE" "" 30 300
expect wait: "an unreadable age waits rather than erroring the tick" \
  queued "self-hosted,linux,host-ci-lin-new1" "$POOL" "$BASE" "$LIVE" "" 300
expect wait: "the boundary is exclusive: at exactly grace it is still waiting" \
  queued "self-hosted,linux,host-ci-lin-new1" "$POOL" "$BASE" "$LIVE" 300 300

# --- and the cases that must be cancelled -------------------------------------
expect orphan: "past grace, a host of ours that no longer exists is unservable" \
  queued "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 301 300
expect orphan: "two host labels can never be a superset of any runner's — a workflow bug" \
  queued "self-hosted,linux,host-ci-lin-a1b2,host-ci-lin-c3d4" "$POOL" "$BASE" "$LIVE" 0 300
expect orphan: "and two pins are called immediately, not after a pointless grace wait" \
  queued "self-hosted,linux,host-ci-lin-a1b2,host-ci-lin-c3d4" "$POOL" "$BASE" "$LIVE" 0 99999

# --- the trap the implementation must not fall into ---------------------------
# `local IFS=,` + `unset IFS` unshadows the caller's IFS instead of restoring the
# default, which would corrupt the controller loop that calls this per job.
_ifs_before="${IFS}"
pinned_job_decision queued "self-hosted,linux" "$POOL" "$BASE" "$LIVE" 0 300 >/dev/null
if [ "${IFS}" = "$_ifs_before" ]; then
  printf 'ok   %s\n' "the caller's IFS survives a call"
else
  printf 'FAIL %s\n' "the caller's IFS was clobbered"; fail=1
fi

[ "$fail" = 0 ] && printf '\npinned-job-decision: all cases pass\n'
exit "$fail"
