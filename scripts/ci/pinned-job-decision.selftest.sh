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

# --- two pools, one label set, two controllers (#1486) ------------------------
#
# A pool being moved to another project exists twice for a while, with the SAME
# labels and a controller each. The run list is per repository, so each
# controller reads the other pool's pinned jobs, finds every one of its labels
# to be its own, and — with one base name between the two — finds the pinned
# host missing from its own MIG and cancels the run. `instance_base_name` gives
# one side a different base, and rule 5 is then the whole of the separation.
# Same labels on every line below: only the host named by the pin differs.
OTHER_BASE="ci-moved"
OTHER_LIVE="ci-moved-e5f6"

expect ignore: "a pin to a foreign base with OUR labels is the other controller's, however old" \
  queued "self-hosted,linux,gcp,Repo,host-ci-moved-e5f6" "$POOL" "$BASE" "$LIVE" 99999 300
expect ignore: "and it is not ours to cancel as vanished either, with our host list empty" \
  in_progress "self-hosted,linux,gcp,Repo,host-ci-moved-e5f6" "$POOL" "$BASE" "" 99999 300 99999
expect orphan: "while a dead pin on our own base is still orphaned exactly as before" \
  queued "self-hosted,linux,gcp,Repo,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 99999 300
expect ignore: "seen from the other controller, our pinned jobs are the foreign ones" \
  queued "self-hosted,linux,gcp,Repo,host-ci-lin-a1b2" "$POOL" "$OTHER_BASE" "$OTHER_LIVE" 99999 300
expect pinned: "and that controller still sees its own live pin" \
  in_progress "self-hosted,linux,gcp,Repo,host-ci-moved-e5f6" "$POOL" "$OTHER_BASE" "$OTHER_LIVE" 0 300

# WHY THE MODULE REFUSES `<pool name>-<anything>` AS A BASE NAME: rule 5 is a
# prefix test, so a base that extends ours with a hyphen is still inside it and
# its perfectly healthy pinned run is cancelled here as an orphan. Pinned as
# the behaviour it is, so that the precondition on the host MIG is not relaxed
# on the belief that this function would catch it. An exact-match rule 5 flips
# this to `ignore:` and retires the precondition.
expect orphan: "a base that extends ours with a hyphen is still claimed — hence the precondition" \
  queued "self-hosted,linux,gcp,Repo,host-ci-lin-b-e5f6" "$POOL" "$BASE" "$LIVE" 99999 300

# And the base the controller hands rule 5 is the one read off the LIVE group,
# which is what makes a renamed pool need no controller change at all — and a
# hand-written pool table unable to get it wrong. Passing the pool name here
# instead would run every case above green and cancel every renamed pool's
# pinned runs on the fleet.
# shellcheck disable=SC2016  # matching shell source text literally, on purpose.
src_has "the controller bounds a pin by the live group's base name, not the pool name" \
  'pinned_job_decision "$status" "$labels" "$RUNNER_MATCH_LABELS" "$MIG_BASE"'

# --- the name that becomes a path ---------------------------------------------
#
# pin_host_of is the one helper here whose answer a caller turns into a file
# path, and it does so BEFORE any verdict exists — so rule 1b, which lives
# inside the decision function, has not run and cannot be the thing relied on.
# The input is `runs-on`, authored in the pull request. These assert the name
# handed out is always one GCE could have issued.
pin_is() { # <desc> <expected> <job_labels>
  local got; got="$(pin_host_of "$3" "$POOL")"
  if [ "$got" = "$2" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n       want [%s]\n       got  [%s]\n' "$1" "$2" "$got"; fail=1; fi
}

pin_is "an ordinary pin is handed back as the instance name" \
  "ci-lin-a1b2" "self-hosted,linux,host-ci-lin-a1b2"
pin_is "a traversal in the label yields NO pin, so no path is built from it" \
  "" "self-hosted,linux,host-../../../etc/passwd"
pin_is "a bare parent reference yields no pin either" "" "self-hosted,linux,host-.."
pin_is "a separator anywhere in the name is refused" "" "self-hosted,linux,host-a/b"
pin_is "so is an empty pin, which would name the state directory itself" \
  "" "self-hosted,linux,host-"
# Whitespace never reaches the charset check: pin_split iterates an UNQUOTED
# expansion, so `host-a b` is already two labels by the time anything looks at
# it, and the pin is the first of them. Asserted because the safety here is a
# property of that splitting rather than of the check — quoting the expansion
# would be a reasonable-looking tidy-up that reintroduced a name with a space
# in it, and this case is what would object.
pin_is "whitespace splits into two labels rather than surviving inside a name" \
  "a" "self-hosted,linux,host-a b"
# pin_split folds case itself, for the same reason the decision function does:
# GitHub dispatches case-insensitively and GCE instance names are lowercase. So
# an upper-case pin is a legitimate pin, and the charset check must see the
# folded form or it would reject every workflow that shouts.
pin_is "an upper-case pin is folded, not refused" \
  "ci-lin-a1b2" "self-hosted,linux,host-CI-LIN-A1B2"
# And the refusal must not become a verdict of its own: a job whose pin is
# unusable is still classified by every rule that follows, on the labels
# themselves rather than on the cleaned name.
expect ignore: "a label carrying pattern syntax is still refused by rule 1b" \
  queued "self-hosted,linux,host-ci-lin-*" "$POOL" "$BASE" "$LIVE" 99999 300

# --- #490: a re-run pinned to a host that no longer exists --------------------
#
# Live 2026-09-29 on a consumer repository: `gh run rerun --failed` on a run from
# that morning re-queued its jobs with the ORIGINAL `host-*` pin, naming a host
# drained and deleted hours earlier. The pool was at zero, nothing served the
# label, the base stayed red, and the merge lane held every PR in the repo. Two
# separate things kept the sweep from ever reaping it, and each has a rule here.

is() { # <desc> <expected-prefix> <got>
  case "$3" in
    "$2"*) printf 'ok   %s\n' "$1" ;;
    *) printf 'FAIL %s\n       want %s...\n       got  %s\n' "$1" "$2" "$3"; fail=1 ;;
  esac
}

# 1. The sweep never SAW the run: the queued list is filtered on created_at, and
#    a re-run keeps it. rerun_run_decision decides which attempts to fetch anyway.
NOW=1000000; MAX=21600
is "a re-run of a run created before the window, started inside it, is fetched" fetch: \
  "$(rerun_run_decision 2 $((NOW - 30000)) $((NOW - 60)) $NOW $MAX)"
is "the live shape: attempt 3, created 6h12m before its re-run started" fetch: \
  "$(rerun_run_decision 3 $((NOW - 22320)) $((NOW - 60)) $NOW $MAX)"
is "a first attempt outside the window is a corpse, never fetched" skip: \
  "$(rerun_run_decision 1 $((NOW - 30000)) $((NOW - 30000)) $NOW $MAX)"
is "a re-run whose own start is also outside the window is a corpse" skip: \
  "$(rerun_run_decision 2 $((NOW - 90000)) $((NOW - 30000)) $NOW $MAX)"
is "a re-run created inside the window is already listed, not fetched twice" skip: \
  "$(rerun_run_decision 2 $((NOW - 60)) $((NOW - 30)) $NOW $MAX)"
is "the window edge matches the server filter: created exactly at the cutoff is listed" skip: \
  "$(rerun_run_decision 2 $((NOW - MAX)) $((NOW - 30)) $NOW $MAX)"
is "a start exactly at the cutoff is still inside the window" fetch: \
  "$(rerun_run_decision 2 $((NOW - 90000)) $((NOW - MAX)) $NOW $MAX)"
is "an unreadable start on a re-run is fetched, not dropped (fail-safe)" fetch: \
  "$(rerun_run_decision 2 $((NOW - 90000)) - $NOW $MAX)"
is "an unreadable created on a re-run falls through to its start" fetch: \
  "$(rerun_run_decision 2 - $((NOW - 60)) $NOW $MAX)"
is "an unreadable attempt cannot tell a re-run from a corpse, so it is skipped" skip: \
  "$(rerun_run_decision x $((NOW - 90000)) $((NOW - 60)) $NOW $MAX)"
is "an unreadable clock acts on nothing" skip: \
  "$(rerun_run_decision 2 $((NOW - 90000)) $((NOW - 60)) "" $MAX)"

# ...and once seen, its re-queued job is judged on its OWN age: the jobs of a
# re-run are fresh objects, so the grace window still protects a booting host.
expect wait: "a re-run's fresh pinned job gets the grace window like any other" \
  queued "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 60 300
expect orphan: "and a re-run pinned to a host that is gone is reaped after it" \
  queued "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "$LIVE" 301 300

# 2. The sweep was BLIND: a pool at zero lists nothing, and an empty list was
#    always read as a failed listing. pin_sight_decision tells the two apart.
is "a listed host is sight, as before" sighted: \
  "$(pin_sight_decision 1 "$LIVE" "$BASE" 2)"
is "a pool at zero with a good listing and a good describe is sight" sighted: \
  "$(pin_sight_decision 1 "" "$BASE" 0)"
is "a failed listing is blind, whatever the MIG says" blind: \
  "$(pin_sight_decision 0 "" "$BASE" 0)"
is "a failed describe is blind (MIG_TARGET defaults to 0 on failure)" blind: \
  "$(pin_sight_decision 1 "" "" 0)"
is "a MIG creating a host but listing none yet is blind, not empty" blind: \
  "$(pin_sight_decision 1 "" "$BASE" 1)"
is "an unreadable target is blind" blind: \
  "$(pin_sight_decision 1 "" "$BASE" "")"
expect orphan: "so a pool at zero reaps a job pinned to its deleted host after grace" \
  queued "self-hosted,linux,host-ci-lin-dead" "$POOL" "$BASE" "" 301 300 30000

# 3. What must NOT be reaped, unchanged by any of the above.
#    A host that exists but whose agents are offline is still LISTED by the MIG,
#    so the job is pinned work (reported on ci_demand_pinned), never an orphan:
#    the pin-hold and drain paths own that host, not this sweep.
expect pinned: "a host present in the MIG with its agents offline is not reaped" \
  queued "self-hosted,linux,host-ci-lin-a1b2" "$POOL" "$BASE" "$LIVE" 99999 300
#    A booting host is listed while CREATING (empty status), so it is live too.
expect pinned: "a host the MIG is still creating is live, not gone" \
  queued "self-hosted,linux,host-ci-lin-boot" "$POOL" "$BASE" "$LIVE,ci-lin-boot" 99999 300
expect wait: "a host not listed yet is waited on inside the grace window" \
  queued "self-hosted,linux,host-ci-lin-boot" "$POOL" "$BASE" "$LIVE" 120 300

# 4. Cancel, then ONE full re-run by the controller (owner decision 2026-09-29:
#    the App gets Actions: write). A re-run needs a completed run, so the cancel
#    comes first and the re-run follows on a later tick.
is "an unservable run never acted on is cancelled, then re-run" cancel-then-rerun: \
  "$(pin_orphan_action "")"
is "a run still queued after its cancel is cancelled again, still owed its re-run" cancel-then-rerun: \
  "$(pin_orphan_action cancelled)"
is "the cap: a run the controller already re-ran is only cancelled, never re-run again" cancel-only: \
  "$(pin_orphan_action rerun)"
is "a 403 falls back to cancel plus WARNING" cancel-only: \
  "$(pin_orphan_action refused)"
is "a cancel that never completed is not retried into a re-run" cancel-only: \
  "$(pin_orphan_action gaveup)"
is "cancel-then-rerun: re-run once the cancelled run has completed" rerun: \
  "$(pin_rerun_decision cancelled 60 completed 900 1 1 cancelled push 0)"
is "cancel-then-rerun: wait while the cancel is still landing" wait: \
  "$(pin_rerun_decision cancelled 60 in_progress 900 1 1)"
is "and at exactly max wait it still waits" wait: \
  "$(pin_rerun_decision cancelled 900 queued 900 1 1)"
is "give up when the cancel never completes" give-up: \
  "$(pin_rerun_decision cancelled 901 queued 900 1 1)"
is "an unreadable run status waits rather than re-running blind" wait: \
  "$(pin_rerun_decision cancelled 60 "" 900)"
is "the cap again: a ledger saying rerun is never re-run a second time" skip: \
  "$(pin_rerun_decision rerun 60 completed 900)"
is "a 403 recorded on the ledger is never re-run" skip: \
  "$(pin_rerun_decision refused 60 completed 900)"
is "no ledger, no re-run" skip: \
  "$(pin_rerun_decision "" 60 completed 900)"
is "an unreadable cancel stamp waits, it does not error" wait: \
  "$(pin_rerun_decision cancelled x queued 900)"

# 5. Security review F1: the re-run is keyed on the ATTEMPT the controller
#    cancelled, and on a `cancelled` conclusion. Anything else was somebody
#    else's doing, and is closed silently.
is "F1: a person re-ran it since (attempt moved on): done, silently" done: \
  "$(pin_rerun_decision cancelled 60 completed 900 1 2 success push 0)"
is "F1: and a moved attempt still running is done too, not waited on" done: \
  "$(pin_rerun_decision cancelled 60 in_progress 900 1 2 "" push 0)"
is "F1: the same attempt that finished on its own is not replayed" done: \
  "$(pin_rerun_decision cancelled 60 completed 900 1 1 failure push 0)"
is "F1: no recorded attempt, no proof, no re-run" done: \
  "$(pin_rerun_decision cancelled 60 completed 900 "" 1 cancelled push 0)"
is "F1: an unreadable current attempt, no proof, no re-run" done: \
  "$(pin_rerun_decision cancelled 60 completed 900 1 "" cancelled push 0)"

# F4: unstick CI, never replay old code.
is "F4: a newer run of the same workflow on the branch: superseded, not re-run" superseded: \
  "$(pin_rerun_decision cancelled 60 completed 900 1 1 cancelled push 1)"
is "F4: the newer-run check could not be answered: wait, never assume no" wait: \
  "$(pin_rerun_decision cancelled 60 completed 900 1 1 cancelled push "")"
is "F4: and that wait is still bounded" give-up: \
  "$(pin_rerun_decision cancelled 901 completed 900 1 1 cancelled push "")"
for _ev in push pull_request merge_group; do
  is "F4: event $_ev is on the allowlist" rerun: \
    "$(pin_rerun_decision cancelled 60 completed 900 1 1 cancelled "$_ev" 0)"
done
for _ev in workflow_dispatch schedule deployment release workflow_run repository_dispatch "" pull_request_target; do
  is "F4: event [${_ev}] is never re-run automatically" declined: \
    "$(pin_rerun_decision cancelled 60 completed 900 1 1 cancelled "$_ev" 0)"
done
is "the later states are cancel-only too: done" cancel-only: "$(pin_orphan_action "done")"
is "the later states are cancel-only too: superseded" cancel-only: "$(pin_orphan_action superseded)"
is "the later states are cancel-only too: declined" cancel-only: "$(pin_orphan_action declined)"

# F2 + N1: a 403 is a permission refusal only when GitHub's body says so, and no
# rate-limit signal contradicts it. Everything else is a limit, retried later.
DENY='{"message":"Resource not accessible by integration","documentation_url":"x","status":"403"}'
LIMIT='{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","status":"403"}'
is "N1: 403 saying Resource not accessible by integration is a refusal" refused \
  "$(actions_write_class 403 4999 "" "$DENY")"
is "N1: and it is a refusal even when the rate-limit header is missing" refused \
  "$(actions_write_class 403 "" "" "$DENY")"
is "N1: a secondary-limit 403 with requests left and NO retry-after is transient" transient \
  "$(actions_write_class 403 4999 "" "$LIMIT")"
is "N1: a 403 with an empty body is transient" transient \
  "$(actions_write_class 403 4999 "" "")"
is "F2: 403 with the primary limit exhausted is transient, whatever the body" transient \
  "$(actions_write_class 403 0 "" "$DENY")"
is "F2: 403 with retry-after is transient, whatever the body" transient \
  "$(actions_write_class 403 4999 60 "$DENY")"
is "F2: 403 with no rate-limit header and no permission message is transient" transient \
  "$(actions_write_class 403 "" "" "")"
is "F2: 429 is transient" transient "$(actions_write_class 429 4999 "")"
is "F2: a 5xx is transient" transient "$(actions_write_class 502 4999 "")"
is "F2: no response at all is transient" transient "$(actions_write_class 000 "" "")"
is "F2: 202 (cancel accepted) is ok" ok "$(actions_write_class 202 4999 "")"
is "F2: 201 (re-run accepted) is ok" ok "$(actions_write_class 201 4999 "")"
is "F2: 404 is a failure, not a refusal" failed "$(actions_write_class 404 4999 "")"
# F3: the down-scoped token is refused at MINT when the permission is missing.
is "F3: a 422 at mint is the missing permission" refused "$(actions_token_mint_class 422)"
is "F3: a 201 at mint is a token" ok "$(actions_token_mint_class 201)"
is "F3: anything else at mint is transient" transient "$(actions_token_mint_class 403)"

# --- #490, the caller -----------------------------------------------------------
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "the controller re-runs in FULL, never rerun-failed-jobs" 'gh_actions_post "$pr_id" rerun'
# F3: writes go through the down-scoped token, reads keep the installation one.
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "F3: the Actions token is scoped to this repository and actions:write alone" \
  '{repositories: [$r], permissions: {actions: "write"}}'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "F3: the cancel and re-run POST carry the scoped token" 'Authorization: Bearer $GH_ACT_TOKEN'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "F3: the cancel goes through gh_actions_post" 'gh_actions_post "$run" cancel'
# The pattern matches the literal $run / $pr_id spellings in the controller source.
# shellcheck disable=SC2016
_unscoped_writes=$(grep -cE 'actions/runs/\$(run|pr_id)/(cancel|rerun)' "$CONTROLLER" || true)
if [ "$_unscoped_writes" = 0 ]; then
  printf 'ok   %s\n' "F3: no cancel or re-run URL is built outside gh_actions_post"
else
  printf 'FAIL %s\n' "F3: $_unscoped_writes cancel/re-run call(s) bypass the scoped token"; fail=1
fi
# F2: the headers that tell a rate limit from a refusal are captured.
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "F2: the write captures its response headers" '-D "$hdr"'
src_has "F2: and reads x-ratelimit-remaining" '"x-ratelimit-remaining"'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "N1: the write captures its response body for the classifier" '-o "$bodyf" -D "$hdr"'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "N1: and hands it to actions_write_class" 'actions_write_class "$ACT_CODE" "$rem" "$ra" "$body"'
src_has "F2: and retry-after" '"retry-after"'
# F1: the cancelled attempt is recorded.
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "F1: the ledger records the cancelled attempt" 'pin_ledger_write "$run" cancelled "$attempt"'
src_has "F4: a superseded run is a WARNING of its own kind" 'WARNING pinned-run-superseded'
if grep -F 'rerun-failed-jobs"' "$CONTROLLER" >/dev/null; then
  printf 'FAIL %s\n' "the controller calls rerun-failed-jobs, which keeps the dead pin"; fail=1
else
  printf 'ok   %s\n' "the controller never calls rerun-failed-jobs"
fi
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "a 201 records the cap before anything else" 'pin_ledger_write "$pr_id" rerun'
src_has "a successful re-run is an INFO event" 'event INFO pinned-run-rerun'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "a refused re-run is recorded and warned about" 'pin_ledger_write "$pr_id" refused'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "the cancel stamp is written once, not per tick" '[ -n "$ledger" ] || pin_ledger_write "$run" cancelled'
_cls_at=$(grep -n '^  classify_pinned$' "$CONTROLLER" | tail -1 | cut -d: -f1)
_rr_at=$(grep -n '^  rerun_cancelled_pinned$' "$CONTROLLER" | tail -1 | cut -d: -f1)
if [ -n "$_cls_at" ] && [ -n "$_rr_at" ] && [ "$_rr_at" -gt "$_cls_at" ]; then
  printf 'ok   %s\n' "the pending re-runs are finished every tick, after the sweep"
else
  printf 'FAIL %s\n' "rerun_cancelled_pinned is not called after classify_pinned (cls=$_cls_at rr=$_rr_at)"; fail=1
fi
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "collect_hosts records whether the listing succeeded" 'HOSTS_LISTED=1'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "classify_pinned asks pin_sight_decision, with the listing's success" \
  'sight=$(pin_sight_decision "${HOSTS_LISTED:-0}" "$live" "$MIG_BASE" "$MIG_TARGET")'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "the demand sweep reads an UNFILTERED queued page for re-runs" \
  'actions/runs?per_page=100&status=queued"'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "and asks rerun_run_decision which of them to fetch" \
  'rerun_run_decision "$rr_attempt" "$rr_created" "$rr_started" "$sweep_start" "$DEMAND_MAX_AGE"'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "the re-run ids join the fetch list" 'printf '"'"'%s'"'"' "$rr_ids"'
src_has "a cancelled pinned run tells the operator to re-run it in full" 'never --failed'
# shellcheck disable=SC2016  # the controller source is the literal under test
src_has "and so does a refused one, as an event rather than a log line" 'pin_run_warning "$run" "refused-$code"'

# The re-run page must never carry the created filter: that filter is the bug.
_rr_line=$(grep -F 'actions/runs?per_page=100&status=queued' "$CONTROLLER" || true)
case "$_rr_line" in
  *created=*) printf 'FAIL %s\n' "the re-run page is filtered on created_at -- it would miss every re-run of an old run"; fail=1 ;;
  "") printf 'FAIL %s\n' "the re-run page is missing"; fail=1 ;;
  *) printf 'ok   %s\n' "the re-run page is not filtered on created_at" ;;
esac

# --- mutants: each rule above must fail when the one line that makes it true is broken
#
# Each mutant rewrites the decision file, sources the copy in a subshell, and
# asserts the case it targets now gives the WRONG answer. A mutant that still
# passes means the case above is not actually testing that line.
DECISION="$here/../../modules/ci-runner-host-pool/scripts/pinned-job-decision.sh"
mutant() { # <desc> <sed-expr> <call...> -- <prefix the ORIGINAL gives>
  local desc="$1" expr="$2"; shift 2
  local want="${*: -1}" call=("${@:1:$#-1}") m got
  m=$(mktemp)
  sed -e "$expr" "$DECISION" >"$m"
  if cmp -s "$m" "$DECISION"; then
    printf 'FAIL mutant did not apply: %s\n' "$desc"; fail=1; rm -f "$m"; return
  fi
  got=$( . "$m"; "${call[@]}" )
  rm -f "$m"
  case "$got" in
    "$want"*) printf 'FAIL mutant survived: %s (still %s)\n' "$desc" "$got"; fail=1 ;;
    *) printf 'ok   mutant killed: %s\n' "$desc" ;;
  esac
}
# shellcheck disable=SC2016  # sed expressions: every $ is text in the decision file
mutant "an empty pool read as blind again (the #490 wedge)" \
  's/    0) echo "sighted:pool at zero/    0) echo "blind:pool at zero/' \
  pin_sight_decision 1 "" "$BASE" 0 sighted:
# shellcheck disable=SC2016
mutant "the listing's success ignored" \
  's/\[ "\$ok" = 1 \] || {/true || {/' \
  pin_sight_decision 0 "" "$BASE" 0 blind:
mutant "a target above zero trusted as empty" \
  's/    \*) echo "blind:MIG target/    *) echo "sighted:MIG target/' \
  pin_sight_decision 1 "" "$BASE" 1 blind:
# shellcheck disable=SC2016
mutant "re-runs judged on created_at instead of their own start" \
  's/if \[ "\$started" -ge "\$since" \]; then/if [ "$created" -ge "$since" ]; then/' \
  rerun_run_decision 2 $((NOW - 30000)) $((NOW - 60)) $NOW $MAX fetch:
# shellcheck disable=SC2016
mutant "first attempts fetched too (every corpse costs a job call)" \
  's/\[ "\$attempt" -gt 1 \]/[ "$attempt" -gt 0 ]/' \
  rerun_run_decision 1 $((NOW - 30000)) $((NOW - 60)) $NOW $MAX skip:
# shellcheck disable=SC2016
mutant "a re-run created inside the window fetched twice" \
  's/if \[ "\$created" -ge "\$since" \]; then/if false; then/' \
  rerun_run_decision 2 $((NOW - 60)) $((NOW - 30)) $NOW $MAX skip:

mutant "the cap removed: a run already re-run is re-run again" \
  's/    rerun) echo "cancel-only:the controller already re-ran/    rerun) echo "cancel-then-rerun:the controller already re-ran/' \
  pin_orphan_action rerun cancel-only:
mutant "a 403 no longer falls back" \
  's/    refused) echo "cancel-only:/    refused) echo "cancel-then-rerun:/' \
  pin_orphan_action refused cancel-only:
# shellcheck disable=SC2016
mutant "the re-run no longer waits for a completed run" \
  's/if \[ "\$status" = completed \]; then/if true; then/' \
  pin_rerun_decision cancelled 60 in_progress 900 1 1 cancelled push 0 wait:
mutant "the re-run cap in the pending step removed" \
  's/    rerun) echo "skip:already re-run once/    rerun) echo "rerun:already re-run once/' \
  pin_rerun_decision rerun 60 completed 900 skip:
# shellcheck disable=SC2016
mutant "the give-up bound removed" \
  's/if \[ "\$since" -gt "\$max" \]; then/if false; then/' \
  pin_rerun_decision cancelled 901 queued 900 give-up:

# shellcheck disable=SC2016
mutant "F1: the attempt check removed (a human's re-run overridden)" \
  's/if \[ "\$cur" != "\$rec" \]; then/if false; then/' \
  pin_rerun_decision cancelled 60 completed 900 1 2 cancelled push 0 done:
# shellcheck disable=SC2016
mutant "F1: any conclusion re-run, not only cancelled" \
  's/\[ "\$concl" = cancelled \] || {/true || {/' \
  pin_rerun_decision cancelled 60 completed 900 1 1 failure push 0 done:
mutant "F4: the allowlist widened to workflow_dispatch" \
  's/    push | pull_request | merge_group) return 0 ;;/    push | pull_request | merge_group | workflow_dispatch) return 0 ;;/' \
  pin_rerun_decision cancelled 60 completed 900 1 1 cancelled workflow_dispatch 0 declined:
mutant "F4: a superseded run re-run anyway" \
  's/      1) echo "superseded:/      1) echo "rerun:/' \
  pin_rerun_decision cancelled 60 completed 900 1 1 cancelled push 1 superseded:
mutant "F4: an unanswered newer-run check read as none" \
  's/    # Unknown: fall through to the clock/    echo "rerun:assumed"; return 0\n    # Unknown: fall through to the clock/' \
  pin_rerun_decision cancelled 60 completed 900 1 1 cancelled push "" wait:
mutant "N1: the body check dropped (a secondary-limit 403 read as a refusal)" \
  's/        \*) echo transient; return 0 ;;/        *) ;;/' \
  actions_write_class 403 4999 "" "$LIMIT" transient
# shellcheck disable=SC2016
mutant "F2: the primary limit ignored" \
  's/if \[ -n "\$ra" \] || \[ "\$rem" = 0 \]; then/if [ -n "$ra" ]; then/' \
  actions_write_class 403 0 "" "$DENY" transient
# shellcheck disable=SC2016
mutant "F2: retry-after ignored" \
  's/if \[ -n "\$ra" \] || \[ "\$rem" = 0 \]; then/if [ "$rem" = 0 ]; then/' \
  actions_write_class 403 4999 60 "$DENY" transient
mutant "F3: a mint 422 read as transient (the missing permission never surfaced)" \
  's/    422) echo refused ;;/    422) echo transient ;;/' \
  actions_token_mint_class 422 refused

[ "$fail" = 0 ] && printf '\npinned-job-decision: all cases pass\n'
exit "$fail"
