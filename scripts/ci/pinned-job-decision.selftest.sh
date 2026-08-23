#!/usr/bin/env bash
# Self-test for pinned_job_decision (modules/ci-runner-host-pool/scripts/pinned-job-decision.sh).
#
# Two of the six verdicts act on somebody's workflow run — `orphan` cancels a
# queued one and `vanished` cancels a RUNNING one — and the function is the only
# thing standing between a MIG listing that blipped and a cancelled build. The
# cases below are written around that: most of them assert what must NOT happen.
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

# --- a pool label that merely shares the prefix -------------------------------
# A pool configured with `host-large` predates affinity, and `runner_labels`
# accepted it. Read as a pin it would name an instance called `large`, no live
# host would answer, and the controller would cancel a schedulable run while
# also dropping it from demand -- wrong twice, and silently. The pool's own
# list is the authority on which of its labels are its own.
POOL_HL="self-hosted,linux,gcp,Repo,host-large"
expect demand: "a pool label that starts with host- is a label, not a pin"   queued "self-hosted,linux,host-large" "$POOL_HL" "$BASE" "$LIVE" 99999 300
expect pinned: "a real pin still reads as a pin on a pool that has such a label"   in_progress "self-hosted,linux,host-large,host-ci-lin-a1b2" "$POOL_HL" "$BASE" "$LIVE" 0 300
expect orphan: "and a dead pin on that pool is still orphaned"   queued "self-hosted,linux,host-large,host-ci-lin-dead" "$POOL_HL" "$BASE" "$LIVE" 99999 300
expect ignore: "a host- label this pool does NOT carry is a pin, not a label"   queued "self-hosted,linux,host-large" "$POOL" "$BASE" "$LIVE" 99999 300

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
expect pinned: "an in-flight job is never cancelled on age alone, whatever the host list says" \
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

# --- a host that went away UNDER a running job --------------------------------
#
# The state this rule was extended for. A slot that dies holding a job leaves
# the job `in_progress` at GitHub with nothing behind it, and it reports no
# conclusion at all — not success, not failure, not cancelled — until GitHub's
# own 24-hour timeout. A merge queue does not read a missing status as a
# problem; it reads it as "still checking" and holds the entry until ITS
# timeout, which is how a green pull request waits two and a half hours to be
# dequeued for a reason that names nothing.
#
# Cancelling live work is the most expensive mistake this function can make, so
# it is fenced harder than the queued case: the absence clock is REQUIRED, and
# both clocks have to run out.

expect vanished: "past both clocks, a host gone from under a running job is cancelled" \
  in_progress "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300 301

expect pinned: "but never on age alone — no ledger, no vanished verdict, ever" \
  in_progress "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300

expect wait: "a host absent for one tick is a blip, not a dead slot" \
  in_progress "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300 30

expect wait: "and at exactly the grace it still resolves in favour of the run" \
  in_progress "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300 300

expect wait: "an unreadable absence clock waits, it does not error the tick" \
  in_progress "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300 abc

expect pinned: "a live host is live however long the ledger claims — liveness comes first" \
  in_progress "self-hosted,linux,host-ci-lin-a1b2" "$POOL" "$BASE" "$LIVE" 99999 300 99999

expect ignore: "and the pool bound still comes first: another pool's host is not ours to cancel" \
  in_progress "self-hosted,linux,host-ci-win-9z8y" "$POOL" "$BASE" "$LIVE" 99999 300 99999

# BOTH clocks, which is the whole point of there being two. A job created two
# minutes ago whose host has somehow been absent for an hour has not yet earned
# a cancellation on its own age — the smaller clock governs.
expect wait: "a young job is not cancelled because its host has a long absence record" \
  in_progress "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 120 300 99999

# The queued path keeps its second clock too, and gains the tolerance it never
# had: a job that spent twenty minutes in a queue used to be cancellable by a
# single blipped listing, because `age` had already run out before the host went
# anywhere.
expect wait: "a long-queued job survives one blipped listing" \
  queued "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300 30
expect orphan: "and is still orphaned once the host has really been gone" \
  queued "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300 301

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

# --- the caller, which is not a pure function and so is read rather than run ---
#
# Every case above is about the DECISION. These are about the loop around it,
# and each one is a bug that shipped: none can be reached by calling
# pinned_job_decision, and all of them cost either a live controller or a metric.

CONTROLLER="$(dirname "$0")/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"

src_has() {
  if grep -qF -- "$2" "$CONTROLLER"; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n' "$1"; fail=1
  fi
}

# THE ORDER IS LOAD-BEARING, not stylistic. classify_pinned reads MIG_BASE, the
# controller runs under `set -u`, and collect_mig is the only thing that assigns
# it -- so `classify_pinned` first is not a misjudged pin, it is a dead process
# that systemd restarts straight back into the same tick.
_mig_at=$(grep -n '^  collect_mig$' "$CONTROLLER" | tail -1 | cut -d: -f1)
_cls_at=$(grep -n '^  classify_pinned$' "$CONTROLLER" | tail -1 | cut -d: -f1)
if [ -n "$_mig_at" ] && [ -n "$_cls_at" ] && [ "$_mig_at" -lt "$_cls_at" ]; then
  printf 'ok   %s\n' "the MIG is described before anything classifies a pin"
else
  printf 'FAIL %s\n' "classify_pinned runs before collect_mig (mig=$_mig_at cls=$_cls_at) -- under set -u the first pinned job kills the controller"; fail=1
fi

src_has "MIG_BASE has a value before any function runs" 'MIG_BASE=""'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "a run already cancelled this tick is not cancelled again" 'case "$gone" in *" $run "*) continue ;; esac'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "a run already tried this tick is not posted to again" 'case "$tried" in'
# Every path out of the orphan branch that leaves the run in the queue has to
# count it: no token, already tried this tick, and a refused cancel -- plus the
# blind tick and the ordinary pinned/wait case. Five increments, and a missing
# one is a wedged run that ci_demand_pinned reports as zero.
# shellcheck disable=SC2016  # the controller source is the literal under test
_inc=$(grep -cF 'DEMAND_PINNED=$((DEMAND_PINNED + 1))' "$CONTROLLER")
if [ "$_inc" -ge 5 ]; then
  printf 'ok   %s
' "every path that leaves a pinned run queued counts it ($_inc)"
else
  printf 'FAIL %s
' "only $_inc paths count pinned demand -- a refused or un-retried cancel reports zero"; fail=1
fi
# BOTH SIDES SUBTRACT A LABEL SET before calling a job pinned, and neither reads
# a bare `host-` prefix as one. They subtract different sets on purpose: demand
# is computed per pool and asks about THIS pool's labels, while the pin sweep
# runs once for every pool in the table and so asks about their union. A pool
# that carries `host-large` therefore keeps its jobs on ci_demand, and the sweep
# does not report them as pins on nobody's behalf.
# shellcheck disable=SC2016  # a jq fragment: `$mine_labels` is jq's variable, not the shell's
src_has "the demand filter subtracts this pool's own labels" '- $mine_labels | length) == 0 )'
# shellcheck disable=SC2016  # a jq fragment: `$known_labels` is jq's variable, not the shell's
src_has "the pin filter subtracts every label the pool table knows" '- $known_labels | length) > 0 )'
# shellcheck disable=SC2016  # a jq fragment: `$pools` is jq's variable, not the shell's
src_has "and that set is the union over the pool table" '([ $pools | to_entries[] | .value[] ] | unique) as $known_labels'
src_has "a pinned record falls back to started_at when created_at is absent" '(.created_at // .started_at // "")'

# --- case, which nobody in the pipeline controls ------------------------------
#
# GitHub dispatches a job case-insensitively; every membership test in this
# function is a comma-fenced `case`, which is exact. Unfolded, a workflow saying
# `linux` against agents registering `Linux` falls out at rule 3 as another
# pool's job — and then a job pinned to a host THIS pool owns is neither counted
# as work in flight nor ever orphaned when its host dies: it waits out GitHub's
# 24 hours in silence, on a controller reporting perfect health. That is not a
# hypothetical spelling; it is what every workflow in this fleet writes, against
# a label the agent supplies itself and always capitalises.
#
# The pool side is folded here too, so the caller may hand this function the
# agent's own spelling without the verdict depending on which one it picked.
POOL_CASED="self-hosted,Linux,gcp,Repo,X64"
expect demand: "the workflow's lowercase OS label against the agent's capital one" \
  queued "self-hosted,linux,gcp,Repo" "$POOL_CASED" "$BASE" "$LIVE" 0 300
expect demand: "and shouted, because GitHub does not care and neither may we" \
  queued "SELF-HOSTED,LINUX,X64" "$POOL_CASED" "$BASE" "$LIVE" 0 300
expect pinned: "a pin is found on a folded label too, so a live host is seen as live" \
  queued "self-hosted,LINUX,HOST-CI-LIN-A1B2" "$POOL_CASED" "$BASE" "$LIVE" 0 300
expect orphan: "and a dead pin is still cancelled rather than left to time out" \
  queued "self-hosted,LINUX,HOST-CI-LIN-DEAD" "$POOL_CASED" "$BASE" "$LIVE" 99999 300
# Folding must not turn the subset test into a wildcard: a foreign label is
# still foreign whatever case it arrives in.
expect ignore: "a Windows job is not a Linux pool's, in any case" \
  queued "self-hosted,WINDOWS" "$POOL_CASED" "$BASE" "$LIVE" 0 300

# The cases above prove the function folds. This proves the CONTROLLER hands it
# the right set to fold: the configured list alone is missing the three labels
# the agent registers itself, and every real workflow names one of them.
# shellcheck disable=SC2016  # matching shell source text literally, on purpose.
src_has "the controller passes the set its agents answer to, not the configured one" \
  'pinned_job_decision "$status" "$labels" "$RUNNER_MATCH_LABELS"'

[ "$fail" = 0 ] && printf '\npinned-job-decision: all cases pass\n'
exit "$fail"
