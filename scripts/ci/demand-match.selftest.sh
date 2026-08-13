#!/usr/bin/env bash
# Self-test for the controller's demand-matching filter.
#
# This test exists because the first version of the filter counted only jobs
# whose labels contained the POOL NAME. No workflow in this fleet asks for a
# pool name — they ask for sets like [self-hosted, linux, gcp, <Repo>] — so
# demand would have been 0 forever. The autoscaler scales out on that metric,
# so the pool would never have added a host while reporting perfect health:
# a silent, total failure that a live pool would have shown only as "CI is
# mysteriously slow".
#
# The rule under test is GitHub's own: a job runs on an agent whose label set
# is a SUPERSET of the job's `runs-on`.

set -uo pipefail

PASS=0
FAIL=0

# The filter, kept character-identical to controller-startup.sh. If you change
# one, this test fails until you change the other — which is the point.
FILTER='
  [ .jobs[]?
    | select(.status == "queued" or .status == "in_progress")
    | select( ((.labels // []) | length) > 0 )
    | select( [ (.labels // [])[] | select( ($mine_labels | index(.)) == null ) ] | length == 0 )
  ] | length'

POOL_LABELS=$(printf '%s' "self-hosted,ci-runner-host-telnet,linux,gcp,Telnet-Emulation" \
  | jq -R -c 'split(",") | map(select(length > 0))')

# expect <count> <description> <jobs-json>
expect() {
  local want="$1" desc="$2" jobs="$3"
  local got
  got=$(printf '%s' "$jobs" | jq -r --argjson mine_labels "$POOL_LABELS" "$FILTER")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

# --- the bug this file exists to prevent --------------------------------------
expect 1 "a real fleet workflow's runs-on is counted (no pool name anywhere in it)" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","gcp","Telnet-Emulation"]}]}'

# --- demand is queued AND in progress -----------------------------------------
expect 2 "in-progress jobs count too — counting queued alone reads a fully busy pool as idle" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux"]},{"status":"in_progress","labels":["self-hosted","gcp"]}]}'
expect 0 "completed jobs are not demand" \
  '{"jobs":[{"status":"completed","labels":["self-hosted","linux"]}]}'

# --- the superset rule ---------------------------------------------------------
expect 0 "a job needing a label this pool lacks belongs to another pool" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","windows"]}]}'
expect 0 "one unmatched label disqualifies the whole job, even with three matches" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","gcp","arm64"]}]}'
expect 1 "a subset of the pool label set matches" \
  '{"jobs":[{"status":"queued","labels":["self-hosted"]}]}'
expect 1 "the full pool label set matches" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","ci-runner-host-telnet","linux","gcp","Telnet-Emulation"]}]}'

# --- GitHub-hosted jobs are not this pool's demand -----------------------------
expect 0 "ubuntu-latest is not ours" \
  '{"jobs":[{"status":"queued","labels":["ubuntu-latest"]}]}'
expect 1 "a mixed run counts only the self-hosted job" \
  '{"jobs":[{"status":"queued","labels":["ubuntu-latest"]},{"status":"queued","labels":["self-hosted","linux"]}]}'

# --- degenerate input ----------------------------------------------------------
expect 0 "a job with no labels at all is not counted (it cannot be routed here)" \
  '{"jobs":[{"status":"queued","labels":[]}]}'
expect 0 "empty job list" '{"jobs":[]}'
expect 0 "missing jobs key does not crash the tick" '{}'

# --- the copy is really a copy -------------------------------------------------
# A test of a copied expression tests nothing once the original moves on, so
# the distinctive line is checked against the controller itself.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER="$HERE/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"
if grep -qF 'select( [ (.labels // [])[] | select( ($mine_labels | index(.)) == null ) ] | length == 0 )' "$CONTROLLER"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the filter tested here no longer appears in controller-startup.sh"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
