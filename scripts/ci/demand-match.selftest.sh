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
# shellcheck disable=SC2016  # $mine_labels is a jq variable, not a shell one.
FILTER='
  [ .jobs[]?
    | select(.status == "queued" or .status == "in_progress")
    | select( ((.labels // []) | length) > 0 )
    | select( ((.labels // []) | map(select(startswith("host-"))) | length) == 0 )
    | select( ((.labels // []) - $mine_labels) | length == 0 )
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

# --- the two stamp lists the same sweep extracts -------------------------------
#
# The sweep splits its matched jobs into two time series that answer opposite
# questions: field 3 is when the still-QUEUED jobs asked for a runner (how long
# the pool made them wait), field 4 is when the IN-PROGRESS ones got one (how
# long the pool has been running them). Crossing the two wires would be silent —
# both are plausible ISO timestamps and both produce a plausible number of
# seconds — so the split is pinned here rather than read back off the graph.
# shellcheck disable=SC2016  # $mine_labels is a jq variable, not a shell one.
STAMPS='
  [ .jobs[]?
    | select(.status == "queued" or .status == "in_progress")
    | select( ((.labels // []) | length) > 0 )
    | select( ((.labels // []) - $mine_labels) | length == 0 )
  ] as $mine
  | [ ($mine | length),
      ([ $mine[] | select(.status == "queued") ] | length),
      ([ $mine[] | select(.status == "queued") | .started_at // .created_at ] | join(" ")),
      ([ $mine[] | select(.status == "in_progress") | .started_at // empty ] | join(" "))
    ] | @tsv'

# fields <want-pipe-joined> <description> <jobs-json>
fields() {
  local want="$1" desc="$2" jobs="$3" got
  got=$(printf '%s' "$jobs" | jq -r --argjson mine_labels "$POOL_LABELS" "$STAMPS" \
    | tr -d '\r' | tr '\t' '|')
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

fields '2|1|2026-08-15T16:15:00Z|2026-08-15T16:18:09Z' \
  "a queued and a running job land in different fields, never the same one" \
  '{"jobs":[
     {"status":"queued","labels":["self-hosted"],"created_at":"2026-08-15T16:15:00Z"},
     {"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

fields '1|0||2026-08-15T16:18:09Z' \
  "a pool with nothing queued still reports how long its running job has been running" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

# `.started_at // empty` and not `// .created_at`: a job that GitHub has not
# told us started has not been running for the time since it was created, and
# reporting that difference as run time would raise a wedged-slot alert for
# every job still sitting in the queue.
fields '1|0||' \
  "a running job with no start time contributes nothing rather than its queue age" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted"],"created_at":"2026-08-15T16:15:00Z"}]}'

# The incident this field exists for: one slot wedged, every sibling finished.
# The completed jobs must not dilute it — they are not in flight.
fields '1|0||2026-08-15T16:18:09Z' \
  "finished siblings do not enter the in-flight age at all" \
  '{"jobs":[
     {"status":"completed","labels":["self-hosted"],"started_at":"2026-08-15T16:17:48Z"},
     {"status":"completed","labels":["self-hosted"],"started_at":"2026-08-15T16:18:02Z"},
     {"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

fields '1|0||' \
  "a job wedged on ANOTHER pool's runner is not this pool's stuck job" \
  '{"jobs":[
     {"status":"in_progress","labels":["self-hosted","windows"],"started_at":"2026-08-15T16:18:09Z"},
     {"status":"in_progress","labels":["self-hosted"]}]}'

# --- the copy is really a copy -------------------------------------------------
# A test of a copied expression tests nothing once the original moves on, so
# the distinctive line is checked against the controller itself.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER="$HERE/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"
# shellcheck disable=SC2016  # matching jq source text literally, on purpose.
for needle in \
  'select(.status == "in_progress") | .started_at // empty' \
  'running=$(printf '"'"'%s'"'"' "$counted" | cut -f4)' \
  'RUNNING_MAX=$wait' \
  'queue_series "ci_job_running_seconds_max" "$RUNNING_MAX"'
do
  if grep -qF "$needle" "$CONTROLLER"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: `%s` no longer appears in controller-startup.sh\n' "$needle"
  fi
done
# --- host affinity: a pinned job is OURS, and is still not scale-out demand ---
#
# ci_demand is the autoscaler's input, and its one move is to add a host. A job
# pinned to `host-<instance>` can be served by exactly one existing machine, so
# counting it here buys a host per tick that the job cannot use. It is counted
# instead as ci_demand_pinned, by classify_pinned(), which runs after the host
# list exists.
expect 0 "a job pinned to one of our own hosts is excluded from ci_demand" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","gcp","Telnet-Emulation","host-ci-lin-a1b2"]}]}'
expect 0 "label order does not smuggle a pinned job back in" \
  '{"jobs":[{"status":"queued","labels":["host-ci-lin-a1b2","self-hosted","linux"]}]}'
expect 1 "and the unpinned job beside it still counts — the filter excludes, it does not drop the run" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","host-ci-lin-a1b2"]},{"status":"queued","labels":["self-hosted","linux"]}]}'
expect 1 "an in-progress pinned job is excluded too, so the pair of series stays consistent" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted","linux","host-ci-lin-a1b2"]},{"status":"in_progress","labels":["self-hosted","linux"]}]}'

# shellcheck disable=SC2016  # matching jq source text literally, on purpose.
if grep -qF 'select( ((.labels // []) | map(select(startswith("host-"))) | length) == 0 )' "$CONTROLLER"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the pin-exclusion line tested here no longer appears in controller-startup.sh"
fi
# shellcheck disable=SC2016  # matching jq source text literally, on purpose.
if grep -qF 'select( ((.labels // []) - $mine_labels) | length == 0 )' "$CONTROLLER"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the filter tested here no longer appears in controller-startup.sh"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
