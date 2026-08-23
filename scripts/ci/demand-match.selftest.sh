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
  def jlabels: ((.labels // []) | map(ascii_downcase));
  [ .jobs[]?
    | select(.status == "queued" or .status == "in_progress")
    | select( ((.labels // []) | length) > 0 )
    | select( ((jlabels | map(select(startswith("host-")))) - $mine_labels | length) == 0 )
    | select( (jlabels - $mine_labels) | length == 0 )
  ] | length'

# WHAT THE POOL IS CONFIGURED WITH, exactly as `ci-runner-labels` carries it and
# exactly as `config.sh --labels` receives it. Note what is NOT in it: `linux`.
# No pool in this fleet is configured with an OS label, because the agent
# registers one itself -- and the fixture that used to sit here invented one.
# That is why this file was green for months while `ci_demand` was structurally
# 0 on every pool in the fleet: every real workflow asks for `linux`, no pool
# was configured with it, the subset test had `["linux"]` left over, and nothing
# was ever counted. A fixture that is not what production sends is not a test.
POOL_CONFIGURED="self-hosted,ci-runner-host-telnet,gcp,Telnet-Emulation"

# WHAT THE AGENT ANSWERS TO. Derived here the way controller-startup.sh derives
# P_MATCH_JSON: the configured list plus the three labels the runner registers
# on its own (`self-hosted`, the OS, the architecture), folded, because GitHub
# routes case-insensitively and a jq `-` does not.
match_set() { # <configured-csv> <host_os>
  printf '%s' "$1" | jq -R -c --arg os "$2" '
    (if ($os | ascii_downcase) == "windows" then "Windows" else "Linux" end) as $osl
    | split(",") + ["self-hosted", $osl, "X64"]
    | map(select(length > 0) | ascii_downcase) | unique'
}
POOL_LABELS=$(match_set "$POOL_CONFIGURED" linux)

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
  def jlabels: ((.labels // []) | map(ascii_downcase));
  def expired:
    .status == "queued"
    and (((((.started_at // .created_at) // "") | fromdateiso8601?) // $now)
          < ($now - $maxage));
  [ .jobs[]?
    | select(.status == "queued" or .status == "in_progress")
    | select( ((.labels // []) | length) > 0 )
    | select( (jlabels | map(select(startswith("host-"))) | length) == 0 )
  ] as $candidates
  | $pools | to_entries[]
  | .key as $pool
  | .value as $mine_labels
  | [ $candidates[] | select( (jlabels - $mine_labels) | length == 0 ) ] as $matched
  | [ $matched[] | select(expired | not) ] as $mine
  | ([ $matched[] | select(expired) ] | length) as $expired_n
  | [ $pool,
      ($mine | length),
      ([ $mine[] | select(.status == "queued") ] | length),
      ([ $mine[] | select(.status == "queued") | .started_at // .created_at ]
         | join(" ") | if . == "" then "-" else . end),
      ([ $mine[] | select(.status == "in_progress") | .started_at // empty ]
         | join(" ") | if . == "" then "-" else . end),
      $expired_n
    ] | @tsv'

# The sweep clock, fixed so the age cases read the same on every run, and the
# shelf life the controller applies to a queued job. Every stamp in this file is
# minutes before NOW, so no case written before the shelf life existed ages out.
NOW=$(jq -n '"2026-08-15T17:00:00Z" | fromdateiso8601')
MAXAGE=21600

# One pool for the stamp cases, so their expectations stay readable. The
# multi-pool cases at the end of the file build their own map.
POOLS_MAP=$(jq -n --argjson l "$POOL_LABELS" '{telnet: $l}')

# fields <want-pipe-joined> <description> <jobs-json>
fields() {
  local want="$1" desc="$2" jobs="$3" got
  got=$(printf '%s' "$jobs" | jq -r --argjson pools "$POOLS_MAP" \
    --argjson now "$NOW" --argjson maxage "$MAXAGE" "$STAMPS" \
    | tr -d '\r' | tr '\t' '|' | paste -sd';' -)
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

fields 'telnet|2|1|2026-08-15T16:15:00Z|2026-08-15T16:18:09Z|0' \
  "a queued and a running job land in different fields, never the same one" \
  '{"jobs":[
     {"status":"queued","labels":["self-hosted"],"created_at":"2026-08-15T16:15:00Z"},
     {"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

fields 'telnet|1|0|-|2026-08-15T16:18:09Z|0' \
  "a pool with nothing queued still reports how long its running job has been running" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

# `.started_at // empty` and not `// .created_at`: a job that GitHub has not
# told us started has not been running for the time since it was created, and
# reporting that difference as run time would raise a wedged-slot alert for
# every job still sitting in the queue.
fields 'telnet|1|0|-|-|0' \
  "a running job with no start time contributes nothing rather than its queue age" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted"],"created_at":"2026-08-15T16:15:00Z"}]}'

# The incident this field exists for: one slot wedged, every sibling finished.
# The completed jobs must not dilute it — they are not in flight.
fields 'telnet|1|0|-|2026-08-15T16:18:09Z|0' \
  "finished siblings do not enter the in-flight age at all" \
  '{"jobs":[
     {"status":"completed","labels":["self-hosted"],"started_at":"2026-08-15T16:17:48Z"},
     {"status":"completed","labels":["self-hosted"],"started_at":"2026-08-15T16:18:02Z"},
     {"status":"in_progress","labels":["self-hosted"],"started_at":"2026-08-15T16:18:09Z"}]}'

fields 'telnet|1|0|-|-|0' \
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
  got=$(printf '%s' "$jobs" | jq -r --argjson pools "$MULTI" \
    --argjson now "$NOW" --argjson maxage "$MAXAGE" "$STAMPS" \
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
  'while IFS=$'"'"'\t'"'"' read -r c_pool n q stamps running expired_n; do' \
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

# --- a reserved prefix is not an owned one ------------------------------------
#
# `host-` is reserved for affinity FROM THIS ADR ONWARD; a pool configured
# before it may already carry a label like `host-large`, and a job asking for it
# is an ordinary job this pool can serve. Excluding it here while the pin filter
# reads it as unpinned is how a job leaves ci_demand and ci_demand_pinned at the
# same time -- counted nowhere, scaling nothing, and invisible on both charts.
POOL_LABELS=$(match_set "$POOL_CONFIGURED,host-large" linux)
expect 1 "a host- label that is one of THIS pool's own labels is ordinary demand" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","host-large"]}]}'
expect 0 "a host- label this pool does not carry is still a pin, and still excluded" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","host-large","host-ci-lin-a1b2"]}]}'
POOL_LABELS=$(match_set "$POOL_CONFIGURED" linux)

# shellcheck disable=SC2016  # matching jq source text literally, on purpose.
if grep -qF 'select( ((jlabels | map(select(startswith("host-")))) - $mine_labels | length) == 0 )' "$CONTROLLER"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the pin-exclusion line tested here no longer appears in controller-startup.sh"
fi
# shellcheck disable=SC2016  # matching jq source text literally, on purpose.
if grep -qF 'select( (jlabels - $mine_labels) | length == 0 )' "$CONTROLLER"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the filter tested here no longer appears in controller-startup.sh"
fi

# --- the labels the runner registers, and the case nobody controls ------------
#
# THE OUTAGE THIS SECTION EXISTS FOR. Every pool in the fleet reported
# `ci_demand` 0 while jobs queued for hours in front of idle slots, and the
# autoscaler — whose input that gauge IS — did exactly what a zero asks for.
# Two independent reasons, and fixing either alone still counts nothing:
#
#   * The agent registers `self-hosted`, the OS and the architecture ITSELF.
#     GitHub calls them read-only; no `--labels` produces them and none of ours
#     removes them. The configured list has no OS label in it, so a `runs-on`
#     naming one had a label left over and fell out of the subset test.
#   * GitHub matches case-insensitively. The agent registers `Linux`; every
#     workflow in the fleet writes `linux`. To a jq `-` those are two labels.
#
# So both sides are folded and the read-only three are added, and each half is
# pinned separately below — a fix that quietly loses one half is the outage
# again, and it looks exactly as healthy on the way in as it did the first time.
expect 1 "the OS label a workflow always writes and no pool is ever configured with" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","gcp","Telnet-Emulation"]}]}'
expect 1 "the same label as the agent spells it" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","Linux"]}]}'
expect 1 "SHOUTED, because GitHub does not care and neither may we" \
  '{"jobs":[{"status":"queued","labels":["SELF-HOSTED","LINUX","GCP"]}]}'
expect 1 "the architecture is registered too, in either case" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","x64"]}]}'
expect 1 "a configured label in the wrong case is still ours" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","TELNET-EMULATION"]}]}'
# Folding must not make everything match everything: the read-only labels are
# the runner's THREE, not a licence to answer for any OS or architecture.
expect 0 "arm64 is not this pool's architecture, folded or not" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","ARM64"]}]}'
expect 0 "macOS belongs to nobody here" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","macos"]}]}'

# The OS half is per-pool and comes from `host_os`, so a Windows pool must not
# answer for `linux` — which, with the read-only labels added but the derivation
# wrong, is precisely how one pool ends up buying hosts for another's work.
WIN_LABELS=$(match_set "self-hosted,ci-runner-host-win,gcp,Telnet-Emulation" windows)
win() { # <want> <description> <jobs-json>
  local want="$1" desc="$2" jobs="$3" got
  got=$(printf '%s' "$jobs" | jq -r --argjson mine_labels "$WIN_LABELS" "$FILTER")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}
win 1 "a Windows pool answers for a Windows job" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","windows","gcp"]}]}'
win 0 "a Windows pool does not answer for a Linux job" \
  '{"jobs":[{"status":"queued","labels":["self-hosted","linux","gcp"]}]}'

# A fixture that derives the match set the way the controller does proves
# nothing once the controller stops doing it, so the derivation is pinned too.
# shellcheck disable=SC2016  # matching jq source text literally, on purpose.
for needle in \
  'split(",") + ["self-hosted", $osl, "X64"]' \
  'map(select(length > 0) | ascii_downcase) | unique' \
  'def jlabels: ((.labels // []) | map(ascii_downcase));'
do
  if grep -qF "$needle" "$CONTROLLER"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: `%s` no longer appears in controller-startup.sh\n' "$needle"
  fi
done

# --- a queued job has a shelf life --------------------------------------------
#
# GitHub never takes a run out of `queued` on its own. A run held by an
# unapproved environment, blocked on a `concurrency` group, or abandoned on a
# dead branch keeps asking this pool for a host forever. Apigee-Portal had three
# from 2026-08-19 still queued on 2026-08-23. The cost is not academic: one
# corpse times `single_instance_assignment` pins a host warm for good, and the
# wait gauge pegs at the corpse's age, so the one series that would show a real
# queue underneath it is saturated. Both halves are asserted — dropped from the
# count AND from the stamps — and what was dropped is published as its own
# series rather than silently subtracted out of the one the operator watches.
STALE='2026-08-15T09:00:00Z'   # 8h before NOW, past the 6h shelf life
FRESH='2026-08-15T16:30:00Z'   # 30m before NOW

fields "telnet|0|0|-|-|1" \
  "a queued job older than the shelf life is not demand" \
  '{"jobs":[{"status":"queued","labels":["self-hosted"],"created_at":"'"$STALE"'"}]}'
fields "telnet|1|1|$FRESH|-|1" \
  "the fresh job beside it still counts, and the corpse is reported separately" \
  '{"jobs":[
     {"status":"queued","labels":["self-hosted"],"created_at":"'"$STALE"'"},
     {"status":"queued","labels":["self-hosted"],"created_at":"'"$FRESH"'"}]}'
# The stamps matter as much as the count: leaving the corpse's timestamp in the
# queued list would peg ci_demand_wait_seconds at eight hours and hold it there.
fields "telnet|1|1|$FRESH|-|1" \
  "the expired job's timestamp is not in the wait series either" \
  '{"jobs":[
     {"status":"queued","labels":["self-hosted"],"created_at":"'"$FRESH"'"},
     {"status":"queued","labels":["self-hosted"],"created_at":"'"$STALE"'"}]}'
# In-flight, not queued. A job that has been RUNNING for eight hours is a wedged
# slot, and dropping it would hide the incident the running series exists to
# report — it is the QUEUE that has a shelf life, not the work.
fields "telnet|1|0|-|$STALE|0" \
  "an old RUNNING job is not expired — that is a wedged slot, not a corpse" \
  '{"jobs":[{"status":"in_progress","labels":["self-hosted"],"started_at":"'"$STALE"'"}]}'
# An unreadable timestamp reads as "just now" and is never aged out. The costs
# are asymmetric: keeping a corpse buys a warm host, while dropping a live job
# stops the pool scaling out for work that is really waiting.
fields "telnet|1|1|not-a-date|-|0" \
  "an unparseable timestamp is kept, not aged out" \
  '{"jobs":[{"status":"queued","labels":["self-hosted"],"created_at":"not-a-date"}]}'
# shellcheck disable=SC2016  # matching shell source text literally, on purpose.
for needle in \
  'DEMAND_MAX_AGE=21600' \
  'queue_series "ci_demand_expired" "$DEMAND_EXPIRED"'
do
  if grep -qF "$needle" "$CONTROLLER"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: `%s` no longer appears in controller-startup.sh\n' "$needle"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
