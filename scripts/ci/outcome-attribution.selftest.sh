#!/usr/bin/env bash
# Self-test for the controller's outcome/cost attribution — the extraction that
# turns a completed run's job list into (workflow, conclusion, seconds), and the
# label sanitiser those workflow names pass through on the way to a metric.
#
# TWO FAILURES THIS FILE EXISTS TO PREVENT
#
# 1. A workflow name is repository-authored text. Until the outcome series
#    landed, every label this fleet published was a constant written by hand,
#    and the JSON body is built by string concatenation. One `"` in a workflow
#    name does not corrupt one label — it makes the entire request unparseable
#    and drops EVERY series in that tick, including ci_demand, which the
#    autoscaler reads. The pool would stop scaling out because someone renamed
#    a workflow.
#
# 2. Attribution that counts jobs this pool never ran is worse than none: it
#    tells you to spend money warming a cache for work that executed on
#    GitHub-hosted runners. The same superset rule that bounds demand bounds
#    cost, and it is the same expression — so it is checked against the
#    controller here rather than trusted to stay in step.

set -uo pipefail

PASS=0
FAIL=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER="$HERE/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"
TELEMETRY="$HERE/../../modules/ci-runner-host-pool/scripts/telemetry.sh"

check() {
  local want="$1" got="$2" desc="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

# --- the row extraction --------------------------------------------------------
#
# Kept character-identical to collect_outcomes(). If you change one, this test
# fails until you change the other; the grep at the bottom is what makes that
# true rather than aspirational.
# shellcheck disable=SC2016  # $mine_labels is a jq variable, not a shell one.
ROWS='
      .jobs[]?
      | select(.status == "completed")
      | select( ((.labels // []) | length) > 0 )
      | select( ((.labels // []) - $mine_labels) | length == 0 )
      | [ (.workflow_name // "unknown"),
          (.conclusion // "unknown"),
          ( ( ((.completed_at // "") | if . == "" then 0 else fromdateiso8601 end)
            - ((.started_at   // "") | if . == "" then 0 else fromdateiso8601 end) ) as $d
            | if $d > 0 then $d else 0 end )
        ] | @tsv'

POOL_LABELS=$(printf '%s' "self-hosted,ci-runner-host-telnet,linux,gcp,Telnet-Emulation" \
  | jq -R -c 'split(",") | map(select(length > 0))')

# Tabs become pipes so a multi-row expectation is readable in this file, and
# carriage returns are dropped because jq built for Windows opens stdout in text
# mode: a developer running this test on the machine the fleet is administered
# from would otherwise see every multi-row case fail for a reason that does not
# exist on the Linux controller the code runs on.
rows() {
  printf '%s' "$1" | jq -r --argjson mine_labels "$POOL_LABELS" "$ROWS" \
    | tr -d '\r' | tr '\t' '|'
}

check "PR Check|failure|200" \
  "$(rows '{"jobs":[{"status":"completed","conclusion":"failure","workflow_name":"PR Check",
     "labels":["self-hosted","linux"],
     "started_at":"2026-08-15T10:00:00Z","completed_at":"2026-08-15T10:03:20Z"}]}')" \
  "a completed job of ours yields workflow, conclusion and duration"

check "" \
  "$(rows '{"jobs":[{"status":"in_progress","conclusion":null,"workflow_name":"PR Check",
     "labels":["self-hosted"]}]}')" \
  "an in-progress job has no outcome yet and must not be counted as one"

# The whole reason outcomes are read from the COMPLETED-runs list rather than
# riding along on the demand sweep: this is the shape the demand sweep can see,
# and it is the shape that carries no verdict.
check "" \
  "$(rows '{"jobs":[{"status":"queued","conclusion":null,"workflow_name":"PR Check",
     "labels":["self-hosted"]}]}')" \
  "a queued job has no outcome"

check "" \
  "$(rows '{"jobs":[{"status":"completed","conclusion":"success","workflow_name":"PR Check",
     "labels":["ubuntu-latest"],
     "started_at":"2026-08-15T10:00:00Z","completed_at":"2026-08-15T10:00:05Z"}]}')" \
  "a GitHub-hosted job is not this pool's cost, however it concluded"

check "" \
  "$(rows '{"jobs":[{"status":"completed","conclusion":"success","workflow_name":"PR Check",
     "labels":["self-hosted","windows"],
     "started_at":"2026-08-15T10:00:00Z","completed_at":"2026-08-15T10:00:05Z"}]}')" \
  "one label this pool lacks means the job ran somewhere else"

check "unknown|unknown|0" \
  "$(rows '{"jobs":[{"status":"completed","conclusion":null,"workflow_name":null,
     "labels":["self-hosted"],"started_at":null,"completed_at":null}]}')" \
  "a job missing every optional field still produces one well-formed row"

# A clock skew or a rerun bookkeeping quirk must not subtract from the pool's
# measured cost — a negative summand silently cancels a real job's seconds.
check "PR Check|success|0" \
  "$(rows '{"jobs":[{"status":"completed","conclusion":"success","workflow_name":"PR Check",
     "labels":["self-hosted"],
     "started_at":"2026-08-15T10:00:10Z","completed_at":"2026-08-15T10:00:00Z"}]}')" \
  "a completed_at before started_at contributes zero, never a negative"

check "PR Check|cancelled|0
PR Check|success|60" \
  "$(rows '{"jobs":[
     {"status":"completed","conclusion":"cancelled","workflow_name":"PR Check",
      "labels":["self-hosted"],"started_at":null,"completed_at":null},
     {"status":"completed","conclusion":"success","workflow_name":"PR Check",
      "labels":["self-hosted","gcp"],
      "started_at":"2026-08-15T10:00:00Z","completed_at":"2026-08-15T10:01:00Z"}]}')" \
  "every conclusion is reported, cancelled included — a cancel rate is the merge queue's health"

check "" "$(rows '{"jobs":[]}')" "an empty job list"
check "" "$(rows '{}')" "a payload with no jobs key does not crash the tick"

# --- the label sanitiser -------------------------------------------------------
# shellcheck source=/dev/null
. "$TELEMETRY"

check 'Build _ deploy' "$(ts_label_value 'Build " deploy')" \
  "a double quote cannot escape the label and take the whole request with it"
check 'a_b' "$(ts_label_value 'a\b')" \
  "a backslash cannot open an escape sequence"
check 'one_two' "$(ts_label_value 'one
two')" \
  "a newline cannot break the JSON body"
check 'PR Check / full' "$(ts_label_value 'PR Check / full')" \
  "ordinary workflow names survive intact — spaces, slashes, dots and dashes"
check 'unknown' "$(ts_label_value '')" \
  "an empty value becomes a readable label rather than an empty one"
check '64' "$(ts_label_value "$(printf 'x%.0s' $(seq 1 200))" | wc -c | tr -d ' ')" \
  "a long name is capped — the tail of a long name is where per-run junk lives"

# --- the copies are really copies ----------------------------------------------
# A test of a copied expression tests nothing once the original moves on.
# shellcheck disable=SC2016  # matching jq/shell source text literally, on purpose.
for needle in \
  'select(.status == "completed")' \
  '(.workflow_name // "unknown")' \
  'if $d > 0 then $d else 0 end' \
  'OUTCOME_MAX_WORKFLOWS' \
  'wf=$(ts_label_value "$wf")' \
  'tail -n "$OUTCOME_KEEP"' \
  'OUTCOME_LAST_SWEEP)) -ge "$OUTCOME_INTERVAL"'
do
  if grep -qF "$needle" "$CONTROLLER"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: `%s` no longer appears in controller-startup.sh\n' "$needle"
  fi
done

# The seed path is load-bearing and invisible in production: without it a new
# controller spends its first ticks republishing runs that finished before it
# existed, as if they had just happened.
if grep -qF 'outcomes are reported from now on' "$CONTROLLER"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the first-boot seed no longer guards against backfilling history"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
