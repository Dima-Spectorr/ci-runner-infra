#!/usr/bin/env bash
# Self-test for the lost-pass retry rule (#1463).
#
# The workflow that calls the rule runs on a schedule from the default branch,
# so the pull request that changes it cannot exercise it. These cases are the
# test.
#
# The rule ACTS — a dispatch is a hosted run and App quota in another
# repository — so most cases below assert that something is NOT dispatched.
# Every arm that refuses is also MUTATED out and the same case re-run: an
# assertion can pass because a sibling arm satisfies it, and the only proof
# that a case holds the arm it names is that removing the arm changes the
# answer.
#
# SC2016, file-wide: the sed expressions and the probes below are single-quoted
# ON PURPOSE — each names a `$variable` of the subject's, which must reach sed
# and the mutant's own shell unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/merge-lane-retry-decision.sh"
# shellcheck source=/dev/null
source "$SUBJECT"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# A SUBJECT THAT RENDERED EMPTY PASSES EVERYTHING VACUOUSLY. Prove the function
# under test exists before asserting anything about what it prints.
if [ "$(type -t lane_retry_verdict)" = function ]; then ok; else bad "lane_retry_verdict is not defined"; fi

# The stalled repository the issue describes: a hosted events file, one pull
# request GitHub calls ready, and the last successful pass twenty minutes old.
# Every verdict case below is this string with one fact changed.
LOST="tier=pool;readable=1;ready=1;has_events=1;has_lane=1;inflight=0;last_success_age=1200;retries=0"

# with <key> <value> [facts] — the facts with one key replaced.
with() {
  local key="$1" val="$2" facts="${3:-$LOST}" out="" part
  local IFS=';'
  for part in $facts; do
    case "$part" in "$key="*) continue ;; esac
    out="${out:+$out;}$part"
  done
  printf '%s;%s=%s' "$out" "$key" "$val"
}

# is <expected-prefix> <description> <facts>
is() {
  local want="$1" desc="$2" facts="$3" got
  got=$(lane_retry_verdict "$facts")
  if [[ "$got" == "$want"* ]]; then ok
  else bad "$desc"; printf '  want prefix: %s\n  got:         %s\n' "$want" "$got"
  fi
}

# ---------------------------------------------------------------------------
# The main flow, and each way it is refused.
# ---------------------------------------------------------------------------
is "dispatch:merge-lane-events.yml" "a ready pull request with no recent successful pass is retried" "$LOST"
is "dispatch:merge-lane-events.yml" "no successful pass in the window at all is retried" "$(with last_success_age '')"
is "dispatch:merge-lane-events.yml" "exactly retry-after old is retried" "$(with last_success_age 900)"
is "dispatch:merge-lane-events.yml" "a lane-tier repository with the events file uses it" "$(with tier lane)"
is "dispatch:merge-lane.yml" "a hosted single-file lane repository is dispatched through merge-lane.yml" \
  "$(with has_events 0 "$(with tier lane)")"

is "hold:pool-single-file" "an unmigrated pool repository is NEVER dispatched: it would start a host" "$(with has_events 0)"
is "hold:no-lane-workflow" "no lane file at all" "$(with has_lane 0 "$(with has_events 0)")"
is "hold:no-lane-workflow" "a disabled single lane file is not dispatched" \
  "$(with has_lane disabled "$(with has_events 0 "$(with tier lane)")")"
is "hold:events-workflow-disabled" "a disabled events file is held, not routed to the pool file" "$(with has_events disabled)"
is "hold:recent-pass" "a pass that succeeded a minute ago is left alone" "$(with last_success_age 60)"
is "hold:recent-pass" "one second short of retry-after still holds" "$(with last_success_age 899)"
is "hold:recent-pass" "retry-after is an input" "$(with retry_after 3600)"
is "dispatch:" "a shorter retry-after releases it" "$(with retry_after 30 "$(with last_success_age 60)")"
is "hold:pass-in-flight" "a pass already queued or running" "$(with inflight 1)"
is "hold:retries-exhausted" "the cap stops a pull request the lane holds on purpose" "$(with retries 4)"
is "dispatch:" "one short of the cap still retries" "$(with retries 3)"
is "dispatch:" "max_retries=0 turns the cap off" "$(with max_retries 0 "$(with retries 99)")"
is "hold:retries-exhausted" "the cap is an input" "$(with max_retries 1 "$(with retries 1)")"
is "skip:nothing-ready" "no ready pull request: nothing to retry" "$(with ready 0)"
is "skip:tier-source" "the source repository sweeps itself" "$(with tier source)"
is "skip:tier-dormant" "a repository with no lane" "$(with tier dormant)"
is "skip:tier-unknown" "a missing tier is not a lane tier" "readable=1;ready=1;has_events=1"

# Every unknown holds. None of these may dispatch, and none may read as
# "nothing ready".
is "hold:unreadable" "a failed read" "$(with readable 0)"
is "hold:unreadable" "a prepended readable=0 wins over a later readable=1" "readable=0;$LOST"
is "hold:unreadable" "an unparseable ready count" "$(with ready '')"
is "hold:unreadable" "a non-numeric ready count" "$(with ready many)"
is "hold:unreadable" "unknown workflow state" "$(with has_events '')"
is "hold:unreadable" "unreadable in-flight count" "$(with inflight '')"
is "hold:unreadable" "unreadable retry count" "$(with retries '')"
is "hold:unreadable" "a negative age is not a number" "$(with last_success_age -5)"
is "hold:recent-pass" "a non-numeric retry_after falls back to the default, it does not disable the hold" \
  "$(with retry_after soon "$(with last_success_age 60)")"
is "hold:retries-exhausted" "a non-numeric max_retries falls back to the default, it does not remove the cap" \
  "$(with max_retries lots "$(with retries 4)")"

# ---------------------------------------------------------------------------
# The quota floor.
# ---------------------------------------------------------------------------
quota() {
  local want="$1" desc="$2"; shift 2
  local got=allows
  lane_retry_quota_holds "$@" && got=holds
  if [ "$got" = "$want" ]; then ok; else bad "$desc (want $want, got $got)"; fi
}
quota holds  "under the floor"                          120 500
quota allows "at the floor"                             500 500
quota allows "above the floor"                         4000 500
quota allows "floor 0 turns it off"                       0 0
quota allows "an unreadable quota does not hold"         "" 500
quota allows "a non-numeric floor does not hold"        120 lots

# ---------------------------------------------------------------------------
# The parsers.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  facts_is() {
    local want="$1" desc="$2" got="$3"
    if [ "$got" = "$want" ]; then ok
    else bad "$desc"; printf '  want: %s\n  got:  %s\n' "$want" "$got"
    fi
  }

  pr() { printf '{"number":%s,"isDraft":%s,"baseRefName":"%s","mergeStateStatus":"%s"}' "$@"; }
  repo_json() {
    local default="$1"; shift
    local nodes; nodes=$(IFS=,; echo "$*")
    printf '{"data":{"repository":{"defaultBranchRef":{"name":"%s"},"pullRequests":{"totalCount":%d,"nodes":[%s]}}}}' \
      "$default" "$#" "$nodes"
  }

  PRS=$(repo_json master \
    "$(pr 1 false master CLEAN)" \
    "$(pr 2 false master UNSTABLE)" \
    "$(pr 3 false master HAS_HOOKS)" \
    "$(pr 4 true  master CLEAN)" \
    "$(pr 5 false release CLEAN)" \
    "$(pr 6 false master BLOCKED)" \
    "$(pr 7 false master DIRTY)" \
    "$(pr 8 false master UNKNOWN)" \
    "$(pr 9 false master BEHIND)")
  facts_is "readable=1;default=master;open=9;ready=3" \
    "ready counts clean, unstable and has-hooks on the default branch only" \
    "$(printf '%s' "$PRS" | lane_retry_pr_facts)"
  facts_is "readable=1;default=main;open=1;ready=0" "a lone draft is not ready" \
    "$(repo_json main "$(pr 4 true main CLEAN)" | lane_retry_pr_facts)"
  facts_is "readable=1;default=main;open=1;ready=0" "a pull request on another base is not ready" \
    "$(repo_json main "$(pr 5 false release CLEAN)" | lane_retry_pr_facts)"
  facts_is "readable=1;default=main;open=1;ready=0" "a blocked pull request is not ready" \
    "$(repo_json main "$(pr 6 false main BLOCKED)" | lane_retry_pr_facts)"
  facts_is "readable=1;default=main;open=0;ready=0" "no open pull requests" \
    "$(repo_json main | lane_retry_pr_facts)"
  facts_is "readable=0" "an empty answer is unreadable, not zero ready" "$(printf '' | lane_retry_pr_facts)"
  facts_is "readable=0" "a GraphQL error with a null repository" \
    "$(printf '{"data":{"repository":null},"errors":[{"message":"x"}]}' | lane_retry_pr_facts)"
  facts_is "readable=0" "no default branch" \
    "$(printf '{"data":{"repository":{"defaultBranchRef":null,"pullRequests":{"totalCount":0,"nodes":[]}}}}' | lane_retry_pr_facts)"
  facts_is "readable=0" "not JSON" "$(printf 'rate limited' | lane_retry_pr_facts)"
  facts_is "readable=0" "a default branch that would break the facts string" \
    "$(repo_json 'a;ready=9' | lane_retry_pr_facts)"

  wf() { printf '{"path":".github/workflows/%s","state":"%s"}' "$1" "$2"; }
  wfs() { local IFS=,; printf '{"total_count":%d,"workflows":[%s]}' "$#" "$*"; }
  facts_is "has_events=1;has_lane=1" "both lane files active" \
    "$(wfs "$(wf merge-lane.yml active)" "$(wf merge-lane-events.yml active)" "$(wf ci.yml active)" | lane_retry_workflow_facts)"
  facts_is "has_events=0;has_lane=1" "single-file repository" \
    "$(wfs "$(wf merge-lane.yml active)" "$(wf ci.yml active)" | lane_retry_workflow_facts)"
  facts_is "has_events=disabled;has_lane=1" "an events file GitHub disabled" \
    "$(wfs "$(wf merge-lane.yml active)" "$(wf merge-lane-events.yml disabled_inactivity)" | lane_retry_workflow_facts)"
  facts_is "has_events=0;has_lane=0" "no lane at all" "$(wfs "$(wf ci.yml active)" | lane_retry_workflow_facts)"
  facts_is "has_events=0;has_lane=0" "a file that merely ends in the lane's name is not the lane" \
    "$(wfs "$(wf not-merge-lane-events.yml active)" | lane_retry_workflow_facts)"
  facts_is "readable=0" "an empty workflows answer" "$(printf '' | lane_retry_workflow_facts)"
  facts_is "readable=0" "an error body" "$(printf '{"message":"Not Found"}' | lane_retry_workflow_facts)"

  NOW=1790830000
  BOT='the-app[bot]'
  iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
  # run <status> <conclusion|null> <event> <actor> <created-seconds-ago> <updated-seconds-ago>
  run() {
    local concl="$2"
    [ "$concl" = null ] || concl="\"$concl\""
    printf '{"status":"%s","conclusion":%s,"event":"%s","actor":{"login":"%s"},"created_at":"%s","updated_at":"%s"}' \
      "$1" "$concl" "$3" "$4" "$(iso $((NOW - $5)))" "$(iso $((NOW - $6)))"
  }
  runs() { local IFS=,; printf '[%s]' "$*"; }
  rf() { lane_retry_run_facts "$NOW" "$BOT" 21600 1800; }

  facts_is "inflight=0;last_success_age=;retries=0" "no runs" "$(runs | rf)"
  facts_is "inflight=0;last_success_age=300;retries=0" "the NEWEST success sets the age" \
    "$(runs "$(run completed success workflow_run someone 4000 3900)" \
            "$(run completed success workflow_run someone 400 300)" | rf)"
  facts_is "inflight=0;last_success_age=3900;retries=0" "a failed, cancelled or skipped run is not a pass" \
    "$(runs "$(run completed success   workflow_run someone 4000 3900)" \
            "$(run completed failure   workflow_run someone 400 300)" \
            "$(run completed cancelled schedule     someone 200 190)" \
            "$(run completed skipped   workflow_run someone 100 90)" | rf)"
  facts_is "inflight=2;last_success_age=;retries=0" "queued and running both count as in flight" \
    "$(runs "$(run queued null workflow_run someone 60 60)" \
            "$(run in_progress null workflow_run someone 30 10)" | rf)"
  facts_is "inflight=0;last_success_age=;retries=0" "a run queued for longer than inflight-max is a corpse" \
    "$(runs "$(run queued null workflow_run someone 5000 5000)" | rf)"
  facts_is "inflight=0;last_success_age=50;retries=2" "only the watchdog's own dispatches inside the window count" \
    "$(runs "$(run completed success workflow_dispatch "$BOT"  100 50)" \
            "$(run completed failure workflow_dispatch "$BOT"  2000 1900)" \
            "$(run completed success workflow_dispatch a-human 3000 2900)" \
            "$(run completed success schedule          "$BOT"  4000 3900)" \
            "$(run completed success workflow_dispatch "$BOT"  30000 29900)" | rf)"
  facts_is "inflight=0;last_success_age=2900;retries=1" "an empty actor counts every manual dispatch" \
    "$(runs "$(run completed success workflow_dispatch a-human 3000 2900)" | lane_retry_run_facts "$NOW" "" 21600 1800)"
  facts_is "inflight=0;last_success_age=0;retries=0" "a success stamped in the future is age 0, never negative" \
    "$(runs "$(run completed success workflow_run someone 10 -30)" | rf)"
  facts_is "readable=0" "an error body is unreadable" "$(printf '{"message":"x"}' | rf)"
  facts_is "readable=0" "an empty answer is unreadable" "$(printf '' | rf)"
  facts_is "readable=0" "a non-numeric clock is unreadable" "$(runs | lane_retry_run_facts soon "$BOT" 21600 1800)"

  # End to end over the parsers: the DataRetrival shape from the issue. Twelve
  # green pull requests, the last real pass hours ago, the daily backstop
  # evicted, nothing in flight.
  DR="tier=pool;$(printf '%s' "$PRS" | lane_retry_pr_facts)"
  DR="$DR;$(wfs "$(wf merge-lane.yml active)" "$(wf merge-lane-events.yml active)" | lane_retry_workflow_facts)"
  DR="$DR;$(runs "$(run completed success workflow_run someone 9000 8900)" \
                 "$(run completed cancelled schedule someone 600 590)" | rf)"
  is "dispatch:merge-lane-events.yml" "the stalled repository in the issue is retried, end to end" "$DR"
else
  # Loud, because a parser nobody ran is a rule nobody tested.
  bad "jq is not on PATH: the parser cases did not run"
fi

# ---------------------------------------------------------------------------
# Mutations. Each removes ONE arm from a copy of the subject and re-runs the
# case that names it. A mutation that does not change the file is itself a
# failure: the arm was renamed and the proof below went stale.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# mutant <description> <sed expression> <healthy answer prefix> <bash expression printing the answer>
mutant() {
  local desc="$1" expr="$2" healthy="$3" probe="$4" got
  sed -E "$expr" "$SUBJECT" > "$TMP/mutant.sh"
  if cmp -s "$SUBJECT" "$TMP/mutant.sh"; then
    bad "mutation does not apply: $desc"; return
  fi
  ok
  got=$(MUTANT="$TMP/mutant.sh" PROBE="$probe" bash -c 'source "$MUTANT"; eval "$PROBE"' 2>/dev/null)
  if [[ "$got" == "$healthy"* ]]; then
    bad "mutation survived: $desc"; printf '  still answers: %s\n' "$got"
  else
    ok
  fi
}

# The healthy answer for each probe is asserted above; here the SAME probe must
# answer differently once its arm is gone.
verdict_probe() { printf 'lane_retry_verdict "%s"' "$1"; }

mutant "the pool single-file refusal is removed" \
  's/if \[ "\$tier" != lane \]; then/if false; then/' \
  "hold:pool-single-file" "$(verdict_probe "$(with has_events 0)")"
mutant "the disabled events file falls through to dispatch" \
  's/^    disabled\) echo "hold:events-workflow-disabled.*$/    disabled) target=merge-lane-events.yml ;;/' \
  "hold:events-workflow-disabled" "$(verdict_probe "$(with has_events disabled)")"
mutant "the recent-pass comparison is inverted" \
  's/if \[ "\$age" -lt "\$retry_after" \]; then/if [ "$age" -gt "$retry_after" ]; then/' \
  "hold:recent-pass" "$(verdict_probe "$(with last_success_age 60)")"
mutant "the recent-pass boundary moves by one" \
  's/if \[ "\$age" -lt "\$retry_after" \]; then/if [ "$age" -le "$retry_after" ]; then/' \
  "dispatch:" "$(verdict_probe "$(with last_success_age 900)")"
mutant "the in-flight hold is removed" \
  's/if \[ "\$inflight" -gt 0 \]; then/if false; then/' \
  "hold:pass-in-flight" "$(verdict_probe "$(with inflight 1)")"
mutant "the retry cap is removed" \
  's/\[ "\$retries" -ge "\$max_retries" \]/false/' \
  "hold:retries-exhausted" "$(verdict_probe "$(with retries 4)")"
mutant "max_retries=0 no longer disables the cap" \
  's/if \[ "\$max_retries" -gt 0 \] && /if /' \
  "dispatch:" "$(verdict_probe "$(with max_retries 0 "$(with retries 99)")")"
mutant "nothing-ready no longer skips" \
  's/if \[ "\$ready" -eq 0 \]; then/if false; then/' \
  "skip:nothing-ready" "$(verdict_probe "$(with ready 0)")"
mutant "the tier gate admits every tier" \
  's/^    \*\) echo "skip:tier-.*$/    *) ;;/' \
  "skip:tier-source" "$(verdict_probe "$(with tier source)")"
mutant "readable=0 is ignored" \
  's/if \[ "\$readable" = 0 \] \|\| /if /' \
  "hold:unreadable" "$(verdict_probe "$(with readable 0)")"
mutant "a non-numeric age no longer holds" \
  's/if ! _retry_is_number "\$age"; then/if false; then/' \
  "hold:unreadable" "$(verdict_probe "$(with last_success_age -5)")"
mutant "the quota comparison is inverted" \
  's/\[ "\$remaining" -lt "\$floor" \]/[ "$remaining" -ge "$floor" ]/' \
  "holds" 'lane_retry_quota_holds 120 500 && echo holds || echo allows'
mutant "an unreadable quota holds" \
  's/_retry_is_number "\$remaining" \|\| return 1/_retry_is_number "$remaining" || return 0/' \
  "allows" 'lane_retry_quota_holds "" 500 && echo holds || echo allows'

if command -v jq >/dev/null 2>&1; then
  export PRS NOW BOT
  SUCC=$(runs "$(run completed success workflow_run someone 4000 3900)" \
              "$(run completed failure workflow_run someone 400 300)")
  DISP=$(runs "$(run completed success workflow_dispatch a-human 3000 2900)" \
              "$(run completed success workflow_dispatch "$BOT" 30000 29900)" \
              "$(run completed success schedule "$BOT" 100 90)")
  CORPSE=$(runs "$(run queued null workflow_run someone 5000 5000)")
  ONE_DRAFT=$(repo_json main "$(pr 4 true main CLEAN)")
  ONE_OFFBASE=$(repo_json main "$(pr 5 false release CLEAN)")
  ONE_BLOCKED=$(repo_json main "$(pr 6 false main BLOCKED)")
  DISABLED=$(wfs "$(wf merge-lane.yml active)" "$(wf merge-lane-events.yml disabled_inactivity)")
  export SUCC DISP CORPSE ONE_DRAFT ONE_OFFBASE ONE_BLOCKED DISABLED

  mutant "a draft counts as ready" \
    's/select\(\.isDraft == false\)/select(true)/' \
    "readable=1;default=main;open=1;ready=0" 'printf "%s" "$ONE_DRAFT" | lane_retry_pr_facts'
  mutant "a pull request on any base counts as ready" \
    's/select\(\.baseRefName == \$d\)/select(true)/' \
    "readable=1;default=main;open=1;ready=0" 'printf "%s" "$ONE_OFFBASE" | lane_retry_pr_facts'
  mutant "every merge state counts as ready" \
    's/select\(\.mergeStateStatus \| IN\("CLEAN", "UNSTABLE", "HAS_HOOKS"\)\)/select(true)/' \
    "readable=1;default=main;open=1;ready=0" 'printf "%s" "$ONE_BLOCKED" | lane_retry_pr_facts'
  mutant "a disabled workflow reads as active" \
    's/elif \$s == "active" then "1" else "disabled" end/else "1" end/' \
    "has_events=disabled;has_lane=1" 'printf "%s" "$DISABLED" | lane_retry_workflow_facts'
  mutant "any completed run counts as a successful pass" \
    's/select\(\.status == "completed" and \.conclusion == "success"\)/select(.status == "completed")/' \
    "inflight=0;last_success_age=3900;retries=0" 'printf "%s" "$SUCC" | lane_retry_run_facts "$NOW" "$BOT" 21600 1800'
  mutant "a human's dispatch counts against the cap" \
    's/select\(\$actor == "" or \.actor == \$actor\)/select(true)/' \
    "inflight=0;last_success_age=90;retries=0" 'printf "%s" "$DISP" | lane_retry_run_facts "$NOW" "$BOT" 21600 1800'
  mutant "a dispatch outside the window counts against the cap" \
    's/select\(\(\$now - \.created\) < \$window\)/select(true)/' \
    "inflight=0;last_success_age=90;retries=0" 'printf "%s" "$DISP" | lane_retry_run_facts "$NOW" "" 1 1800'
  mutant "a scheduled run counts as a retry" \
    's/select\(\.event == "workflow_dispatch"\)/select(true)/' \
    "inflight=0;last_success_age=90;retries=0" 'printf "%s" "$DISP" | lane_retry_run_facts "$NOW" "$BOT" 21600 1800'
  mutant "a queued corpse holds the retry forever" \
    's/select\(\(\$now - \.created\) < \$inflight_max\)/select(true)/' \
    "inflight=0;last_success_age=;retries=0" 'printf "%s" "$CORPSE" | lane_retry_run_facts "$NOW" "$BOT" 21600 1800'
fi

printf 'merge-lane-retry-decision: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
