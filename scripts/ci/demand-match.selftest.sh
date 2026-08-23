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
# The expression emits ONE LINE PER POOL now, because one controller serves the
# whole repository and sweeps its runs once. Field 1 is the pool the line
# belongs to; the four that follow are the same four as before, and the lines
# are joined with `;` below so a multi-pool expectation is still one string.
#
# An empty stamp list is written as `-`, not as "". Tab is IFS whitespace, so
# `read` COLLAPSES a run of empty fields: a pool with running jobs and nothing
# queued would hand its in-progress stamps to the queued column and report a job
# that started ten minutes ago as having waited ten minutes for a runner. That
# is the same wire-crossing this block exists to pin, arriving by another route.
# `date -d -` fails, so the sentinel is skipped by the reader.
# shellcheck disable=SC2016  # $pools is a jq variable, not a shell one.
STAMPS='
  [ .jobs[]?
    | select(.status == "queued" or .status == "in_progress")
    | select( ((.labels // []) | length) > 0 )
    | select( ((.labels // []) | map(select(startswith("host-"))) | length) == 0 )
  ] as $candidates
  | $pools | to_entries[]
  | .key as $pool
  | .value as $mine_labels
  | [ $candidates[] | select( ((.labels // []) - $mine_labels) | length == 0 ) ] as $mine
  | [ $pool,
      ($mine | length),
      ([ $mine[] | select(.status == "queued") ] | length),
      ([ $mine[] | select(.status == "queued") | .started_at // .created_at ]
         | join(" ") | if . == "" then "-" else . end),
      ([ $mine[] | select(.status == "in_progress") | .started_at // empty ]
         | join(" ") | if . == "" then "-" else . end)
    ] | @tsv'

# One pool for the stamp cases, so their expectations stay readable. The
# multi-pool cases at the end of the file build their own map.
POOLS_MAP=$(jq -n --argjson l "$POOL_LABELS" '{telnet: $l}')

# fields <want-pipe-joined> <description> <jobs-json>
fields() {
  local want="$1" desc="$2" jobs="$3" got
  got=$(printf '%s' "$jobs" | jq -r --argjson pools "$POOLS_MAP" "$STAMPS" \
    | tr -d '\r' | tr '\t' '|' | paste -sd';' -)
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

fields 'telnet|2|1|2026-08-15T16:15:00Z|2026-08-15T16:18:09Z' \
  "a queued and a running job land in different fields, never the same one" \
  '{"jobs":[
     {"status":"queued","labels":["self-hosted"],"created_at":"2026-08-15T16:15:00Z"},
     {"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

fields 'telnet|1|0|-|2026-08-15T16:18:09Z' \
  "a pool with nothing queued still reports how long its running job has been running" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

# `.started_at // empty` and not `// .created_at`: a job that GitHub has not
# told us started has not been running for the time since it was created, and
# reporting that difference as run time would raise a wedged-slot alert for
# every job still sitting in the queue.
fields 'telnet|1|0|-|-' \
  "a running job with no start time contributes nothing rather than its queue age" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted"],"created_at":"2026-08-15T16:15:00Z"}]}'

# The incident this field exists for: one slot wedged, every sibling finished.
# The completed jobs must not dilute it — they are not in flight.
fields 'telnet|1|0|-|2026-08-15T16:18:09Z' \
  "finished siblings do not enter the in-flight age at all" \
  '{"jobs":[
     {"status":"completed","labels":["self-hosted"],"started_at":"2026-08-15T16:17:48Z"},
     {"status":"completed","labels":["self-hosted"],"started_at":"2026-08-15T16:18:02Z"},
     {"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

fields 'telnet|1|0|-|-' \
  "a job wedged on ANOTHER pool's runner is not this pool's stuck job" \
  '{"jobs":[
     {"status":"in_progress","labels":["self-hosted","windows"],"started_at":"2026-08-15T16:18:09Z"},
     {"status":"in_progress","labels":["self-hosted"]}]}'

# --- four pools, one sweep ------------------------------------------------------
#
# The reason this expression grew a pool column at all: a repository needs a
# Linux CI pool, a Windows CI pool and a merge-queue pool for each, and four
# controllers polling one repository's run list would spend 720 list calls an
# hour against an installation budget all four share. So one sweep scores every
# pool, and the cases below are the ones that go wrong when it does not.

MULTI=$(jq -n '{
  "lin-ci":    ["self-hosted","linux","gcp","Telnet-Emulation"],
  "win-ci":    ["self-hosted","windows","gcp","Telnet-Emulation"],
  "lin-queue": ["self-hosted","merge-queue","linux-mq","Telnet-Emulation"]
}')

# multi <want> <description> <jobs-json> — same reader, an explicit pool map.
multi() {
  local want="$1" desc="$2" jobs="$3" got
  got=$(printf '%s' "$jobs" | jq -r --argjson pools "$MULTI" "$STAMPS" \
    | tr -d '\r' | cut -f1,2 | tr '\t' '|' | paste -sd';' -)
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

# EVERY pool gets a line, including the ones that matched nothing. A pool that
# emitted no line at all would keep the previous tick's demand — the sweep
# accumulates into one array per pool across every run it examines — and a pool
# whose work has finished would go on asking for the hosts it no longer needs.
multi 'lin-ci|0;win-ci|0;lin-queue|0' \
  "a pool that matched nothing still reports itself, at zero" \
  '{"jobs":[{"status":"queued","labels":["ubuntu-latest"]}]}'

# The routing the whole four-pool design rests on. The merge-queue pool does not
# carry the generic `linux`/`gcp` labels, and the CI pools do not carry
# `merge-queue`, so the label sets are DISJOINT and a job is demand for exactly
# one of them. If that ever stops being true this line is what fails.
multi 'lin-ci|1;win-ci|0;lin-queue|0' \
  "an ordinary Linux CI job is demand for the Linux CI pool alone" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","gcp"]}]}'

multi 'lin-ci|0;win-ci|0;lin-queue|1' \
  "a merge-queue job is demand for the merge-queue pool alone" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","merge-queue","linux-mq"]}]}'

multi 'lin-ci|0;win-ci|1;lin-queue|0' \
  "a Windows job does not scale out the Linux pools" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","windows"]}]}'

# The one case where a job counts twice, asserted rather than avoided: under
# GitHub's superset rule BOTH pools really can pick up a job whose labels every
# pool satisfies, so both scaling out is correct, not a bug. It is also why a
# pool must never be given a label set that is a superset of another's by
# accident — the cost of that mistake is double the machines, and it is visible
# here and nowhere else.
multi 'lin-ci|1;win-ci|1;lin-queue|1' \
  "a job asking only for self-hosted is genuinely demand for every pool" \
  '{"jobs":[{"status":"queued","labels":["self-hosted"]}]}'

# A pinned job is not scale-out demand for ANY pool — buying a host cannot help
# a job only one existing machine can run. Excluded once, in the candidate set,
# rather than once per pool.
multi 'lin-ci|0;win-ci|0;lin-queue|0' \
  "a pinned job is excluded before the pools are scored, not after" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","host-ci-lin-a1b2"]}]}'

# --- the copy is really a copy -------------------------------------------------
# A test of a copied expression tests nothing once the original moves on, so
# the distinctive line is checked against the controller itself.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER="$HERE/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"
# shellcheck disable=SC2016  # matching jq source text literally, on purpose.
for needle in \
  'select(.status == "in_progress") | .started_at // empty' \
  'while IFS=$'"'"'\t'"'"' read -r c_pool n q stamps running; do' \
  'D_RUNNING["$c_pool"]=$wait' \
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
