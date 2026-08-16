# shellcheck shell=bash
# ci-runner-host-pool — the controller.
#
# No shebang on purpose: this file is CONCATENATED after drain-decision.sh and
# telemetry.sh at apply time, and the shebang belongs to the combined script.
#
# WHY A CONTROLLER EXISTS AT ALL
#
# Two constraints, together, leave no other shape:
#
#  1. No inbound webhooks are permitted into these projects, so nothing can
#     push "a job was queued" at us. Demand must be POLLED outbound.
#  2. A warm host carries K jobs, so no autoscaler may ever choose which host
#     to remove. Deletion must be a decision made by something that can ask
#     GitHub what each host is doing.
#
# So one always-on e2-micro per pool polls GitHub, publishes the demand metric
# the autoscaler scales OUT on, and owns every scale-IN itself.
#
# This file is appended to drain-decision.sh and telemetry.sh at apply time and
# delivered as the controller's startup-script. On first boot it installs
# ITSELF as a systemd service and then runs the tick loop forever.
#
# Tenancy-agnostic — every repo, project, region and pool value is metadata.

set -uo pipefail

STATE_DIR="/var/lib/ci-controller"
SELF_INSTALL="/opt/ci-controller/controller.sh"
LOG=/var/log/ci-controller.log

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >>"$LOG"
  logger -t ci-controller -- "$*" 2>/dev/null || true
}

# Every outbound call in this file is bounded by these. The controller is a
# `Type=simple` unit running `while true; do tick; sleep POLL; done`, so an
# unbounded socket does not fail — it STOPS THE LOOP. The process stays alive, so
# `Restart=always` never fires; the metric keeps its last published value, so
# nothing looks absent; and the pool neither scales out for queued jobs nor
# drains idle hosts, for as long as the connection hangs.
#
# This is not hypothetical. On 2026-08-14 the equivalent poller in the
# IntegrateIT vendored pool (a `Type=oneshot` timer unit, where systemd will not
# fire the next tick while the previous activation is still starting) sat in
# `activating (start)` for 2h55m: `NEXT n/a`, MIG pinned at targetSize 0, a
# windows job queued the whole time, and no alert anywhere — because a stale
# metric reads as a value, not as a gap. The watchdog installed further down is
# the second half of this fix: bounds stop one call from hanging, the watchdog
# recovers the loop if anything else does.
CURL_MAX_TIME=30   # keep in step with --max-time below; the demand budget
                   # reserves one of these before starting another call
CURL_TIMEOUTS=(--connect-timeout 10 --max-time "$CURL_MAX_TIME")

md() {
  curl "${CURL_TIMEOUTS[@]}" -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null
}

PROJECT=$(md "project/project-id")
OWNER=$(md "instance/attributes/ci-github-owner")
REPO=$(md "instance/attributes/ci-github-repo")
APP_ID=$(md "instance/attributes/ci-app-id")
INSTALL_ID=$(md "instance/attributes/ci-app-installation-id")
KEY_SECRET=$(md "instance/attributes/ci-app-key-secret")
POOL=$(md "instance/attributes/ci-pool")
MIG=$(md "instance/attributes/ci-mig-name")
REGION=$(md "instance/attributes/ci-region")
SLOTS=$(md "instance/attributes/ci-slots")
MIN_HOSTS=$(md "instance/attributes/ci-min-hosts")
MAX_HOSTS=$(md "instance/attributes/ci-max-hosts")
GRACE=$(md "instance/attributes/ci-drain-grace-seconds")
POLL=$(md "instance/attributes/ci-poll-seconds")
METRIC_PREFIX=$(md "instance/attributes/ci-metric-prefix")
RUNNER_LABELS=$(md "instance/attributes/ci-runner-labels")
REGISTER_GRACE=$(md "instance/attributes/ci-register-grace-seconds")
ORPHAN_CONFIRM_TICKS=$(md "instance/attributes/ci-orphan-confirm-ticks")
RECYCLE_MAX_UNAVAILABLE=$(md "instance/attributes/ci-recycle-max-unavailable")
MINT_REG=$(md "instance/attributes/ci-mint-registration-token")

SLOTS=${SLOTS:-1}
MIN_HOSTS=${MIN_HOSTS:-0}
MAX_HOSTS=${MAX_HOSTS:-0}
GRACE=${GRACE:-900}
# How long a host may read reg=absent before it counts as a failed boot rather
# than a booting one. A golden-image host registers in well under two minutes;
# 600s leaves room for a slow image pull or an API retry without letting a truly
# dead host bill all night.
REGISTER_GRACE=${REGISTER_GRACE:-600}
# Consecutive ticks an offline agent must have NO instance behind it before its
# registration is deleted. 3 ticks (~1 min at the default poll) is far longer
# than a transient gcloud failure and far shorter than the hours a dead
# registration otherwise occupies the repo's runner list.
ORPHAN_CONFIRM_TICKS=${ORPHAN_CONFIRM_TICKS:-3}
# Hosts that may be mid-recycle at once. The default is 0 — OFF — and that is
# not timidity, it is the only correct default for a controller that may be
# running against a template it did not expect: a controller restarted from an
# old image, or a metadata key that failed to render, must not start deleting
# hosts because a field was missing. Consumers opt in.
RECYCLE_MAX_UNAVAILABLE=${RECYCLE_MAX_UNAVAILABLE:-0}
# Whether THIS controller mints its hosts' runner registration tokens. Absent
# metadata reads empty, which is `false`, which is every pool that exists today:
# a Linux host mints its own from Secret Manager and this whole path is inert.
# See ci-runner-host-pool's `controller_mints_registration_token`.
MINT_REG=${MINT_REG:-false}
# The per-instance metadata key a minted token is written to, and DELETED from.
# Hard-coded rather than an input: it is a contract between this file and the
# host boot script in the same module, and a configurable name is one more way
# for the delete to miss the key the write created.
REG_TOKEN_KEY="ci-registration-token"
POLL=${POLL:-20}
# Seconds the demand sweep may spend walking per-run job lists. It must stay far
# below the watchdog threshold (10 polls, min 300s): a tick that outruns the
# watchdog is restarted before it can write the heartbeat, and then restarted
# again forever. 90s leaves room for the rest of the tick — the host walk, the
# drains, the orphan reap and the flush — inside any legitimate threshold.
DEMAND_BUDGET=$(md "instance/attributes/ci-demand-budget-seconds")
DEMAND_BUDGET=${DEMAND_BUDGET:-90}
DEMAND_RUNS_SKIPPED=0
METRIC_PREFIX=${METRIC_PREFIX:-custom.googleapis.com/github}
REPO_FULL="$OWNER/$REPO"

# The exact label set this pool's agents register with, as a JSON array — the
# left-hand side of GitHub's superset rule. Must stay identical to what
# host-startup.sh passes to config.sh, which is why both read the same
# metadata key rather than each building their own list.
POOL_LABELS_JSON=$(printf '%s' "$RUNNER_LABELS" | jq -R -c 'split(",") | map(select(length > 0))')

# An empty label set silently matches NOTHING: every queued job is discarded as
# "not mine", demand reads 0 on every tick, and the pool sits at zero hosts
# while jobs queue. Fail loudly instead — a controller that cannot count demand
# has no job to do.
if [ "$POOL_LABELS_JSON" = "[]" ]; then
  echo "ci-runner-labels metadata is missing or empty — cannot count demand" >&2
  exit 1
fi

# --- GitHub ------------------------------------------------------------------

GH_TOKEN=""
GH_TOKEN_EXPIRY=0
RUNNER_LIST_STATUS="ok"
# Consecutive ticks that could not read the runner list. Reset on the first
# successful read, published every tick. In-memory on purpose: a controller
# restart genuinely starts a new run of ticks, and a counter surviving on disk
# would report a suspension that is no longer happening.
BLIND_TICKS=0
# The template the MIG currently builds from. EMPTY until collect_mig() has
# succeeded, and empty is what template_state() reads as `unknown` — so under
# `set -u` a controller that has not yet described its MIG, or whose describe
# failed, recycles nothing rather than dying or, far worse, reading every host
# as stale against an empty string.
MIG_TEMPLATE=""

gh_token() {
  local now
  now=$(date +%s)
  # Installation tokens live an hour; refresh with margin rather than on 401,
  # so a token expiring mid-tick cannot be mistaken for an API outage (which
  # would make every host reg=unknown and freeze all draining).
  if [ -n "$GH_TOKEN" ] && [ "$now" -lt "$((GH_TOKEN_EXPIRY - 300))" ]; then
    printf '%s' "$GH_TOKEN"
    return 0
  fi

  local key header payload sig jwt
  # `timeout` for the same reason the curls are bounded: gcloud carries its own
  # retry loop and can sit on a stalled TLS handshake far past a tick.
  key=$(timeout 60 gcloud secrets versions access latest --secret="$KEY_SECRET" 2>/dev/null)
  [ -n "$key" ] || { log "cannot read App key secret $KEY_SECRET"; return 1; }

  _b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | _b64)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign <(printf '%s' "$key") | _b64)
  jwt="$header.$payload.$sig"

  local resp
  resp=$(curl "${CURL_TIMEOUTS[@]}" -fsS -X POST -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$INSTALL_ID/access_tokens") || return 1

  GH_TOKEN=$(printf '%s' "$resp" | jq -r '.token // empty')
  [ -n "$GH_TOKEN" ] || return 1
  GH_TOKEN_EXPIRY=$((now + 3600))
  printf '%s' "$GH_TOKEN"
}

# Body on stdout, and the reason in $STATE_DIR/api.status when there is no body.
# A FILE, not a variable: callers assign the body with `X=$(gh_api …)`, so every
# variable this function sets lives and dies in that subshell. With
# `-f` the only thing a caller could learn from a failure was that it happened:
# a rate limit, a revoked installation, and a firewall dropping egress all
# produced the same empty string, and the drain path treats all three the same
# way (do nothing) — so a pool frozen for an hour looked exactly like a pool
# frozen for one tick. `000` is curl's own "never got a response".
#
# The status is ALSO written to $STATE_DIR/api.status, because callers assign
# the body with `X=$(gh_api …)` and a variable set inside that subshell never
# reaches them.
gh_api() {
  local tok status
  tok=$(gh_token) || { printf 'no-token' >"$STATE_DIR/api.status"; return 1; }
  status=$(curl "${CURL_TIMEOUTS[@]}" -sS -o "$STATE_DIR/api.body" -w '%{http_code}' \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$1" 2>>"$LOG") || status="000"
  printf '%s' "$status" >"$STATE_DIR/api.status"
  case "$status" in
    2*) cat "$STATE_DIR/api.body"; return 0 ;;
  esac
  return 1
}

# --- demand ------------------------------------------------------------------
#
# Demand counts queued AND in-progress jobs, not queued alone. Counting only
# queued makes the metric collapse to 0 the moment work starts, which tells the
# autoscaler the pool is idle while every slot is busy.
#
# Only jobs THIS pool could actually serve are counted, using GitHub's own
# rule: a job runs on an agent whose label set is a SUPERSET of the job's
# `runs-on`. Matching on the pool name instead would count nothing at all —
# workflows across this fleet ask for label sets like
# [self-hosted, linux, gcp, <Repo>], which contain no pool name — and a pool
# that reports zero demand never scales out, while looking healthy.
#
# A job asking for a label this pool does not carry belongs to another pool (or
# to GitHub-hosted runners) and is correctly ignored.
# budget_allows_call <now> <deadline> <call_max_time> -> 0 = start the call
#
# A call must FIT inside the budget, not merely start inside it: curl will spend
# its full timeout regardless of how little budget is left, so "start if now <
# deadline" overruns by almost one timeout on the last call of every exhausted
# sweep. Pure, and exercised by scripts/ci/demand-budget.selftest.sh.
budget_allows_call() {
  [ $(( $1 + $3 )) -le "$2" ]
}

collect_demand() {
  local runs jobs
  DEMAND_TOTAL=0
  DEMAND_QUEUED=0
  QUEUE_WAIT_MAX=0
  RUNNING_MAX=0
  # Reset HERE, with the other counters, not after the loop: every early return
  # below would otherwise leave the previous tick's value in place and the
  # controller would keep republishing "demand is truncated" forever.
  DEMAND_RUNS_SKIPPED=0

  # The deadline starts BEFORE the two run-list calls, because they are part of
  # the sweep and each can cost a full curl timeout. Starting it after them let
  # a 90s budget authorise 90s + two 30s list calls + one 30s job call = 180s of
  # demand work, which eats the watchdog reserve the budget exists to protect.
  local sweep_start deadline
  sweep_start=$(date +%s)
  deadline=$((sweep_start + DEMAND_BUDGET))

  runs=$(gh_api "repos/$REPO_FULL/actions/runs?status=queued&per_page=50" 2>/dev/null)
  local runs_ip
  runs_ip=$(gh_api "repos/$REPO_FULL/actions/runs?status=in_progress&per_page=50" 2>/dev/null)

  # QUEUED RUNS FIRST, and no `sort -u` across the two lists: the order decides
  # what survives the budget below, and queued jobs are the ones the pool has to
  # scale out FOR. `awk '!seen[$0]++'` keeps that order while still visiting a
  # run that appears in both lists only once.
  #
  # This is a PRIORITY, not a guarantee. A run flips to in_progress as soon as
  # ONE of its jobs starts, so a matrix or a needs: chain can hold queued jobs
  # inside an in_progress run — which sorts last and is dropped first. So an
  # exhausted budget can under-report QUEUED demand too, not only in-progress
  # work. That is why the truncation is published (ci_demand_runs_skipped) and
  # logged rather than treated as harmless: the honest statement is that demand
  # is a lower bound, full stop.
  local ids
  ids=$(printf '%s\n%s' "$runs" "$runs_ip" \
    | jq -r '.workflow_runs[]?.id' 2>/dev/null | awk 'NF && !seen[$0]++')
  [ -n "$ids" ] || return 0

  local now

  # One API call per run, and the run count is whatever the repo happens to be
  # doing — so this loop, alone, sets the tick duration. One pool in this fleet
  # measured a 212s tick against a 300s watchdog threshold on 2026-08-14: not
  # yet fatal, and only a busier hour away from being restarted mid-tick forever.
  # The budget bounds the tick instead of hoping the repo stays quiet.
  local examined=0 skipped=0

  local id
  for id in $ids; do
    # The call must FIT, not merely start: one begun a second before the
    # deadline still costs its full curl timeout, so the budget is overrun by
    # almost a whole timeout every time. CURL_MAX_TIME is that timeout.
    if ! budget_allows_call "$(date +%s)" "$deadline" "$CURL_MAX_TIME"; then
      skipped=$((skipped + 1))
      continue
    fi
    examined=$((examined + 1))
    jobs=$(gh_api "repos/$REPO_FULL/actions/runs/$id/jobs?per_page=100" 2>/dev/null) || continue

    local counted
    counted=$(printf '%s' "$jobs" | jq -r --argjson mine_labels "$POOL_LABELS_JSON" '
      [ .jobs[]?
        | select(.status == "queued" or .status == "in_progress")
        | select( ((.labels // []) | length) > 0 )
        | select( ((.labels // []) - $mine_labels) | length == 0 )
      ] as $mine
      | [ ($mine | length),
          ([ $mine[] | select(.status == "queued") ] | length),
          ([ $mine[] | select(.status == "queued") | .started_at // .created_at ] | join(" ")),
          ([ $mine[] | select(.status == "in_progress") | .started_at // empty ] | join(" "))
        ] | @tsv' 2>/dev/null)

    [ -n "$counted" ] || continue
    local n q stamps running
    n=$(printf '%s' "$counted" | cut -f1)
    q=$(printf '%s' "$counted" | cut -f2)
    stamps=$(printf '%s' "$counted" | cut -f3)
    running=$(printf '%s' "$counted" | cut -f4)

    DEMAND_TOTAL=$((DEMAND_TOTAL + n))
    DEMAND_QUEUED=$((DEMAND_QUEUED + q))

    # Read the clock HERE, per run, and not once before the sweep. Both ages
    # below are measured against it, and `sweep_start` is captured before the
    # two run-list calls — each of which can spend a full CURL_MAX_TIME — and
    # before this run's own job fetch. Against that stale reading every age is
    # short by however long the sweep has been running, which on a busy pool is
    # most of DEMAND_BUDGET: the two series would understate the wait and the
    # run time by up to a minute and a half, and understate them MOST on the
    # pool under the most load, which is the pool being looked at.
    now=$(date +%s)

    local s wait epoch
    for s in $stamps; do
      epoch=$(date -d "$s" +%s 2>/dev/null) || continue
      wait=$((now - epoch))
      [ "$wait" -gt "$QUEUE_WAIT_MAX" ] && QUEUE_WAIT_MAX=$wait
    done

    # Same arithmetic, different question: how long has the OLDEST job that is
    # already executing been executing for. Free — these jobs are in the payload
    # the demand sweep just paid for, and their start times were discarded.
    #
    # A job that started after this run's clock reading yields a negative age
    # and loses the comparison. That is the right answer, not a swallowed one:
    # the question is which job is OLDEST, and the job that just started is
    # never it. The only value this can distort is a pool whose sole in-flight
    # job began within the same second, reported as 0 rather than as 1 — on a
    # gauge whose threshold is measured in minutes, and which is about to be
    # correct on the next tick anyway.
    for s in $running; do
      epoch=$(date -d "$s" +%s 2>/dev/null) || continue
      wait=$((now - epoch))
      [ "$wait" -gt "$RUNNING_MAX" ] && RUNNING_MAX=$wait
    done
  done

  # NEVER silently. A truncated sweep under-reports demand, and under-reported
  # demand is a pool that does not scale out — the exact symptom this fleet keeps
  # misreading as "the autoscaler is broken". Published as a series too, so the
  # budget being too small for a repo is visible without reading a controller log.
  DEMAND_RUNS_SKIPPED=$skipped
  [ "$skipped" -gt 0 ] && log "demand budget ${DEMAND_BUDGET}s exhausted after $examined run(s): $skipped run(s) not examined this tick — demand is a LOWER BOUND, and a skipped in_progress run may still hold queued jobs"
  return 0
}

# --- outcomes ----------------------------------------------------------------
#
# WHAT THIS ANSWERS, AND WHY NOTHING ELSE DOES
#
# Every series above this line describes the POOL: how many hosts, how many
# slots, how long the queue. None of them describes the WORK. So a fleet-wide
# question the whole optimisation effort turns on — which workflow spends the
# pool's seconds, and which one spends them failing — has no answer anywhere in
# the metrics, and gets answered instead by reading run logs by hand, per repo,
# which is why it is only ever answered for the loudest repo.
#
# WHY A SECOND SWEEP AND NOT A FREE RIDE ON THE DEMAND ONE
#
# collect_demand already holds a complete job payload for every run it examines,
# so counting outcomes there looks free. It is not. That sweep only ever fetches
# runs that are QUEUED or IN_PROGRESS, and a run leaves both lists the instant
# its last job finishes — so the jobs it can count are every job EXCEPT the ones
# that finished last, and the job that finishes last is very often the one that
# failed. A red rate built from it would be biased in precisely the place it is
# read.
#
# Completed runs are enumerated instead. A completed run is immutable and the
# API lists it whether or not this controller ever saw it live, so the dedup key
# is a run id, a tick this controller spent restarting is recoverable on the
# next one, and the count does not depend on the poll interval.
#
# Seconds are the pool's, not GitHub's: jobs are filtered by the same
# superset rule collect_demand uses, so a repository's GitHub-hosted jobs never
# appear in a self-hosted pool's cost attribution.
OUTCOME_STATE="$STATE_DIR/runs-counted"
# Its own budget, on top of DEMAND_BUDGET. 90 + 30 stays well inside the
# watchdog's 300s floor with the host walk and the drains still to pay for.
OUTCOME_BUDGET=30
# How many run ids to remember, NOT how long to remember them for. An age-based
# cutoff looks equivalent and is not: a quiet repository's fifty most recent
# completed runs can all be older than any sane retention, so every id would age
# out while still being listed by the API, and the pool would republish
# days-old outcomes as if they had just happened — a phantom burst, on a repo
# with no activity to explain it. A count strictly greater than the page size
# cannot do that: an id can only be forgotten after OUTCOME_KEEP later runs have
# completed, by which point the API stopped listing it long ago.
OUTCOME_KEEP=500
# Seconds between sweeps. This is the one thing in the tick that is not a control
# signal — nothing drains or scales on it — so it does not need the poll
# interval. At the default 20s poll a per-tick sweep would spend 180 list calls
# an hour of a 5000/hour installation budget to learn something that changes on
# the timescale of a CI run; once every 300s costs 12 and loses nothing, because
# a completed run stays in the 50-deep list far longer than that.
OUTCOME_INTERVAL=300
OUTCOME_LAST_SWEEP=0
# Distinct workflow names to label. A workflow name is repository-authored text
# and every distinct value is a billed time series, so the set is bounded here
# rather than trusted; the overflow is not dropped, it is attributed to `other`.
OUTCOME_MAX_WORKFLOWS=20
OUTCOME_RUNS_SKIPPED=0
declare -A OUTCOME_JOBS=()
declare -A OUTCOME_SECONDS=()

collect_outcomes() {
  OUTCOME_JOBS=()
  OUTCOME_SECONDS=()

  local sweep_start deadline
  sweep_start=$(date +%s)

  # Not this tick's turn. The counters are deliberately NOT reset here:
  # ci_outcome_runs_skipped keeps reporting what the last real sweep found,
  # which is the true state of the attribution, rather than flickering to 0 on
  # every tick in between and hiding a sustained shortfall.
  [ $((sweep_start - OUTCOME_LAST_SWEEP)) -ge "$OUTCOME_INTERVAL" ] || return 0
  OUTCOME_LAST_SWEEP=$sweep_start
  OUTCOME_RUNS_SKIPPED=0

  deadline=$((sweep_start + OUTCOME_BUDGET))

  local runs ids
  runs=$(gh_api "repos/$REPO_FULL/actions/runs?status=completed&per_page=50" 2>/dev/null) || return 0
  ids=$(printf '%s' "$runs" | jq -r '.workflow_runs[]?.id' 2>/dev/null | awk 'NF && !seen[$0]++')
  [ -n "$ids" ] || return 0

  # FIRST BOOT SEEDS, IT DOES NOT BACKFILL. Without this the first tick finds
  # fifty unseen runs, spends its whole budget fetching job lists for work that
  # finished before this controller existed, and takes several more ticks to
  # crawl out — publishing a burst of history as if it had just happened. The
  # honest contract is that a pool reports the outcomes of runs that completed
  # while it was watching.
  if [ ! -f "$OUTCOME_STATE" ]; then
    { local id; for id in $ids; do printf '%s %s\n' "$sweep_start" "$id"; done; } >"$OUTCOME_STATE"
    log "outcome sweep seeded with $(printf '%s\n' "$ids" | grep -c .) already-completed run(s); outcomes are reported from now on"
    return 0
  fi

  # Trim to the newest OUTCOME_KEEP ids before the membership test. Appended in
  # completion order, so `tail` is newest-last and the ids dropped are the ones
  # the API stopped listing long ago. Read fully before the file is rewritten:
  # redirecting into a file that is also the input truncates it first.
  local kept
  kept=$(tail -n "$OUTCOME_KEEP" "$OUTCOME_STATE" 2>/dev/null)
  printf '%s\n' "$kept" | awk 'NF' >"$OUTCOME_STATE"

  local workflows=0
  declare -A seen_workflow=()

  local id
  for id in $ids; do
    grep -q " $id\$" "$OUTCOME_STATE" && continue

    if ! budget_allows_call "$(date +%s)" "$deadline" "$CURL_MAX_TIME"; then
      OUTCOME_RUNS_SKIPPED=$((OUTCOME_RUNS_SKIPPED + 1))
      continue
    fi

    local jobs rows
    jobs=$(gh_api "repos/$REPO_FULL/actions/runs/$id/jobs?per_page=100" 2>/dev/null) || continue

    # One line per job: workflow, conclusion, seconds. `completed_at` and
    # `started_at` are both present on a completed job; a job that reports
    # neither contributes 0 seconds rather than a negative number.
    rows=$(printf '%s' "$jobs" | jq -r --argjson mine_labels "$POOL_LABELS_JSON" '
      .jobs[]?
      | select(.status == "completed")
      | select( ((.labels // []) | length) > 0 )
      | select( ((.labels // []) - $mine_labels) | length == 0 )
      | [ (.workflow_name // "unknown"),
          (.conclusion // "unknown"),
          ( ( ((.completed_at // "") | if . == "" then 0 else fromdateiso8601 end)
            - ((.started_at   // "") | if . == "" then 0 else fromdateiso8601 end) ) as $d
            | if $d > 0 then $d else 0 end )
        ] | @tsv' 2>/dev/null)

    # Recorded whether or not it had any job of ours: the run was examined, and
    # re-examining it every tick for the rest of the day would spend the budget
    # that the runs we do care about need.
    printf '%s %s\n' "$sweep_start" "$id" >>"$OUTCOME_STATE"
    [ -n "$rows" ] || continue

    local wf outcome secs
    while IFS=$'\t' read -r wf outcome secs; do
      [ -n "$outcome" ] || continue
      wf=$(ts_label_value "$wf")
      outcome=$(ts_label_value "$outcome")

      if [ -z "${seen_workflow[$wf]:-}" ]; then
        if [ "$workflows" -ge "$OUTCOME_MAX_WORKFLOWS" ]; then
          wf="other"
        else
          workflows=$((workflows + 1))
          seen_workflow[$wf]=1
        fi
      fi

      # `${secs:-0}` and not `$secs`: an arithmetic expansion with an empty
      # operand is a syntax error, and under `set -u`-adjacent shells a short
      # row would abort the tick — the outcome sweep must never be able to take
      # the scaling loop down with it.
      secs="${secs:-0}"
      OUTCOME_JOBS["$wf|$outcome"]=$(( ${OUTCOME_JOBS["$wf|$outcome"]:-0} + 1 ))
      OUTCOME_SECONDS["$wf"]=$(( ${OUTCOME_SECONDS["$wf"]:-0} + ${secs%%.*} ))
    done <<<"$rows"
  done

  [ "$OUTCOME_RUNS_SKIPPED" -gt 0 ] && log "outcome budget ${OUTCOME_BUDGET}s exhausted: $OUTCOME_RUNS_SKIPPED completed run(s) not read this tick — they are retried next tick, not lost"
  return 0
}

# queue_outcome_series — the dimensioned points, if there are any.
#
# Unlike every other series here these are NOT published as a zero when nothing
# happened, because "nothing happened" has no workflow name to label. That makes
# absence ambiguous on its own, which is why ci_outcome_runs_skipped is
# published unconditionally alongside ci_poller_heartbeat: heartbeat present and
# no ci_jobs_completed means the pool ran no jobs, not that the controller died.
#
# Each point is the DELTA for this tick, on a GAUGE, exactly as
# ci_drain_verdicts already is — sum it over a window to read a rate.
queue_outcome_series() {
  local key wf outcome
  for key in "${!OUTCOME_JOBS[@]}"; do
    wf="${key%%|*}"
    outcome="${key##*|}"
    queue_series "ci_jobs_completed" "${OUTCOME_JOBS[$key]}" \
      "\"workflow\":\"$wf\",\"outcome\":\"$outcome\""
  done
  for wf in "${!OUTCOME_SECONDS[@]}"; do
    queue_series "ci_job_seconds" "${OUTCOME_SECONDS[$wf]}" "\"workflow\":\"$wf\""
  done
}

# --- hosts -------------------------------------------------------------------

collect_runners() {
  # One page of 100 covers max_hosts * slots for every pool in this fleet;
  # paginate rather than silently truncate if that stops being true.
  # The status is read back from disk because this call runs in a command
  # substitution: an assignment gh_api made would happen in a subshell and be
  # gone by the time this line runs. That is why 36 consecutive
  # blind ticks were logged as `status=` — the one field that says WHY the pool
  # stopped draining was the one field the subshell ate.
  RUNNERS_JSON=$(gh_api "repos/$REPO_FULL/actions/runners?per_page=100") || {
    RUNNERS_JSON=""
    RUNNER_LIST_STATUS="$(cat "$STATE_DIR/api.status" 2>/dev/null)"
    RUNNER_LIST_STATUS="${RUNNER_LIST_STATUS:-unknown}"
    return 1
  }
  if [ -z "$RUNNERS_JSON" ]; then
    RUNNER_LIST_STATUS="empty-body"
    return 1
  fi
  RUNNER_LIST_STATUS="ok"
  return 0
}

collect_hosts() {
  # The third column is what makes a stale host visible at all. It costs
  # nothing: the same call already returns it, and without it the controller
  # cannot tell a host built from the current template from one built five
  # releases ago — which is why a pool that never goes idle never upgrades.
  #
  # Basenames on both sides. The MIG reports a template as a full self-link and
  # a managed instance reports it as a partial URL, so comparing the raw strings
  # would read every host as stale — the single read that, applied uniformly,
  # cordons the whole pool at once.
  # The fourth column is the instance's own self-link, and it is here rather
  # than fetched per host because it is the only place the controller learns a
  # host's ZONE. A regional MIG spreads hosts across zones and every per-instance
  # compute call needs one; the alternative is a describe per host per tick.
  # Consumers read it with `${uri##*/zones/}` style expansion, never by guessing
  # `<region>-a`.
  # CSV, not `value()`, and the readers below split on `IFS=,`. `value()` is TAB
  # separated, tab is IFS whitespace, and a run of IFS whitespace COLLAPSES — so
  # one empty field shifts every later field left by one. `instanceStatus` is
  # empty for an instance the MIG is still CREATING, i.e. on every scale-out,
  # and with four columns that shift put the self-link into `host_tpl`:
  # template_state would then read a booting host as `stale` instead of the
  # `unknown` the recycle rule's fail-safe is built on, and the self-link would
  # arrive empty. A comma is not IFS whitespace, so an empty field stays empty.
  HOSTS=$(gcloud compute instance-groups managed list-instances "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --format="csv[no-heading](instance.basename(),instanceStatus,version.instanceTemplate.basename(),instance)" 2>/dev/null)
}

# One describe per tick for both facts we need from the MIG: the target size we
# publish, and the baseInstanceName that bounds the orphan reaper to instances
# THIS pool can create. Kept together so the reaper never costs an extra call.
collect_mig() {
  local line
  line=$(gcloud compute instance-groups managed describe "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --format="value(baseInstanceName,targetSize,versions[0].instanceTemplate.basename())" 2>/dev/null)
  MIG_BASE=$(printf '%s' "$line" | cut -f1)
  MIG_TARGET=$(printf '%s' "$line" | cut -f2)
  MIG_TEMPLATE=$(printf '%s' "$line" | cut -f3)
  MIG_BASE=${MIG_BASE:-}
  MIG_TARGET=${MIG_TARGET:-0}
  # Empty means the describe failed or the field moved. Left empty on purpose so
  # template_state() below reads `unknown` and NOTHING is recycled: the
  # alternative — defaulting to some template name — would make every host stale
  # against it and cordon the entire pool on a transient API failure.
  MIG_TEMPLATE=${MIG_TEMPLATE:-}
}

# template_state <host_template> -> current | stale | unknown
# Either side missing is `unknown`, never `stale`. See collect_mig().
template_state() {
  local host_tpl="${1:-}"
  if [ -z "$host_tpl" ] || [ -z "$MIG_TEMPLATE" ]; then
    echo "unknown"
  elif [ "$host_tpl" = "$MIG_TEMPLATE" ]; then
    echo "current"
  else
    echo "stale"
  fi
}

# --- orphan registrations ----------------------------------------------------
#
# drain_host() deregisters before deleting, so the controller's own scale-in is
# self-cleaning. Nothing else is: an operator `delete-instances`, a MIG
# recreate, host maintenance, or a controller restart mid-drain all leave the
# agents registered forever. The verdict rule lives in orphan-decision.sh; this
# is only its I/O.
reap_orphan_registrations() {
  # No runner list means we cannot prove anything about any agent. Same
  # fail-safe as the drain path: do nothing this tick.
  [ -n "$RUNNERS_JSON" ] || return 0

  local ORPHAN_TOKEN
  ORPHAN_TOKEN=$(gh_token) || return 0

  local live
  live=$(printf '%s' "$HOSTS" | awk -F, '{print $1}' | paste -sd, -)

  local name status busy id verdict f misses
  while IFS=$'\t' read -r id name status busy; do
    [ -n "$name" ] || continue

    f="$STATE_DIR/orphan-$name"
    misses=$(cat "$f" 2>/dev/null)
    misses=${misses:-0}

    verdict=$(orphan_decision "$name" "$status" "$busy" "$MIG_BASE" "$live" \
      "$misses" "$ORPHAN_CONFIRM_TICKS")

    case "$verdict" in
      reap:*)
        local code
        code=$(curl "${CURL_TIMEOUTS[@]}" -s -o /dev/null -w '%{http_code}' -X DELETE \
          -H "Authorization: Bearer $ORPHAN_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/$REPO_FULL/actions/runners/$id")
        case "$code" in
          204 | 404)
            rm -f "$f"
            REAPED=$((REAPED + 1))
            log "reap $name: $verdict (HTTP $code)"
            ;;
          *)
            # 422 = GitHub says it is running a job. Our view was stale; forget
            # the strikes so it has to re-qualify from scratch.
            rm -f "$f"
            log "reap $name: refused (HTTP $code) — registration kept"
            ;;
        esac
        ;;
      keep:unconfirmed*)
        echo $((misses + 1)) >"$f"
        ;;
      *)
        # Any other keep means the agent is demonstrably fine — clear its
        # strikes so a host that flaps never accumulates its way to a reap.
        rm -f "$f"
        ;;
    esac
  done <<<"$(printf '%s' "$RUNNERS_JSON" | jq -r '
    .runners[]? | [ (.id|tostring), .name, .status,
                    (if .busy then "1" else "0" end) ] | @tsv' 2>/dev/null)"

  # State files for names GitHub no longer lists at all (we deleted them, or
  # someone else did) would otherwise accumulate on a controller that runs for
  # months.
  for f in "$STATE_DIR"/orphan-*; do
    [ -e "$f" ] || continue
    name=$(basename "$f"); name=${name#orphan-}
    printf '%s' "$RUNNERS_JSON" | jq -e --arg n "$name" \
      '[.runners[]? | select(.name == $n)] | length > 0' >/dev/null 2>&1 || rm -f "$f"
  done
}

# host_facts <host> -> sets HOST_BUSY, HOST_REG
# Slot agents are named "<host>-s<N>" by host-startup.sh; that naming IS the
# join key between GCE instances and GitHub registrations.
host_facts() {
  local host="$1"
  if [ -z "$RUNNERS_JSON" ]; then
    HOST_BUSY=0
    HOST_REG="unknown"
    return 0
  fi

  local line present busy
  line=$(printf '%s' "$RUNNERS_JSON" | jq -r --arg h "$host" '
    [ .runners[]? | select(.name | startswith($h + "-s")) ] as $mine
    | [ ($mine | length),
        ([ $mine[] | select(.busy == true) ] | length)
      ] | @tsv' 2>/dev/null)

  present=$(printf '%s' "$line" | cut -f1)
  busy=$(printf '%s' "$line" | cut -f2)
  present=${present:-0}
  busy=${busy:-0}

  HOST_BUSY=$busy
  if [ "$present" -eq 0 ]; then
    HOST_REG="absent"
  elif [ "$present" -lt "$SLOTS" ]; then
    HOST_REG="partial"
  else
    HOST_REG="present"
  fi
}

# host_age_seconds <host>
# How long THIS CONTROLLER has known the host, from a file stamped the first
# tick it appears. Deliberately not the instance's creationTimestamp: that would
# cost an API call per host per tick, and the direction this errs in is the safe
# one — after a controller restart every host reads young, so the worst case is
# that a genuinely dead host survives one register-grace window instead of a
# live one being shot.
host_age_seconds() {
  local host="$1"
  local f="$STATE_DIR/seen-$host"
  local now first
  now=$(date +%s)
  if [ ! -f "$f" ]; then
    echo "$now" >"$f"
    echo 0
    return 0
  fi
  first=$(cat "$f" 2>/dev/null)
  [ -n "$first" ] || { echo "$now" >"$f"; echo 0; return 0; }
  echo $((now - first))
}

# idle_seconds <host> <busy>
# Idle age is kept on disk, not in memory, so a controller restart does not
# reset every host's clock and hand the whole pool a fresh grace window.
idle_seconds() {
  local host="$1" busy="$2"
  local f="$STATE_DIR/idle-$host"
  local now
  now=$(date +%s)

  if [ "$busy" -gt 0 ]; then
    rm -f "$f"
    echo 0
    return 0
  fi

  if [ ! -f "$f" ]; then
    echo "$now" >"$f"
    echo 0
    return 0
  fi

  local since
  since=$(cat "$f" 2>/dev/null)
  [ -n "$since" ] || { echo "$now" >"$f"; echo 0; return 0; }
  echo $((now - since))
}

# --- registration tokens -------------------------------------------------------
#
# Inert unless the pool set `controller_mints_registration_token`, which today
# means: unless the pool's hosts are Windows.
#
# A Windows host cannot mint its own registration token — its service account
# deliberately holds no Secret Manager grant, because a Windows host cannot
# fence job code off the metadata server and anything that account can read, a
# pull request running on that host can read. The controller reads the App key
# already for the queue poll, so minting here MOVES a call rather than granting
# a new capability.
#
# THE DELETE IS THE CONTROL, NOT THE CLEANUP. The token lands in instance
# metadata, which on a Windows host the job can read. GitHub expires a
# registration token in an hour; deleting the key the moment the host's agents
# appear is what turns that hour into seconds. An edit that drops the delete
# leaves every Windows host advertising a live registration token to the pull
# request it is running — job interception against that repository.
#
# TWO markers, not one, and they are not the same fact:
#
#   regtoken-<host>  MINTED. Written once the host has been given a token, and
#                    removed only by the sweep, when the host leaves the MIG.
#                    It is what makes minting once-per-instance. Overloading it
#                    with the delete's bookkeeping made "the key is gone" also
#                    mean "mint another one", which on a cordoned host — still
#                    executing a pull request, agents already deregistered, so
#                    permanently `absent` — is a fresh hour-long credential
#                    written into that job's own metadata every other tick.
#   regkey-<host>    THE KEY MAY BE LIVE. Written before the metadata call and
#                    removed only after a confirmed delete.
#   regfail-<host>   Failed write attempts. Three, then stop asking GitHub.
#
# So every path below fails in the direction that keeps the key small: a write
# that reports failure is followed by a delete in case it landed anyway, a
# failed delete keeps regkey so the delete retries, and a `present` host whose
# regkey state was lost is deleted from anyway rather than assumed clean.

# write_registration_token <instance-self-link> <regkey-marker>
write_registration_token() {
  local uri="$1" keylive="$2"
  local tok resp reg f zone host rc
  tok=$(gh_token) || { log "regtoken: no installation token"; return 1; }

  resp=$(curl "${CURL_TIMEOUTS[@]}" -fsS -X POST \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO_FULL/actions/runners/registration-token") || return 1
  reg=$(printf '%s' "$resp" | jq -r '.token // empty')
  [ -n "$reg" ] || return 1

  zone=${uri%/instances/*}; zone=${zone##*/}
  host=${uri##*/}
  [ -n "$zone" ] && [ -n "$host" ] || { log "regtoken: cannot read a zone from $uri"; return 1; }

  # --metadata-from-file, never --metadata: a token passed as an argument sits
  # in the process table, and on the pool this exists for one of the local
  # accounts reading that table is running the pull request. `600` on the temp
  # file for the same reason, and it is removed on every path.
  # Every early return is ABOVE this line, so the token file has exactly one
  # creation point and one removal point and needs no trap to pair them. (A
  # `trap … RETURN` would not survive the nested delete call below, and would
  # not help against a kill anyway — 0600 on a controller that runs no build
  # input is the bound there, and that is the honest limit.)
  f=$(mktemp) || return 1
  chmod 600 "$f" 2>/dev/null || true
  rc=1
  # An unchecked write is an EMPTY key on a full disk: the host reads a
  # zero-length token, never registers, and the marker says it was served.
  if printf '%s' "$reg" >"$f"; then
    # The marker goes in BEFORE the call. `timeout 60` fires on a setMetadata
    # that may already have committed server-side, and a key believed unwritten
    # is a key nobody ever comes back to delete.
    : >"$keylive"
    # `timeout` for the reason every curl here is bounded: gcloud has its own
    # retry loop and can outlive a tick on a stalled handshake.
    timeout 60 gcloud compute instances add-metadata "$host" \
      --project="$PROJECT" --zone="$zone" \
      --metadata-from-file="$REG_TOKEN_KEY=$f" >/dev/null 2>&1
    rc=$?
  fi
  rm -f "$f"
  if [ "$rc" -ne 0 ]; then
    # It may have landed regardless. Take it back, and only then forget it.
    delete_registration_token "$uri" && rm -f "$keylive"
  fi
  return "$rc"
}

# delete_registration_token <instance-self-link>
# Idempotent: removing a key that is not there succeeds, so this is safe to call
# again on any tick whose previous delete failed.
delete_registration_token() {
  local uri="$1" zone host
  zone=${uri%/instances/*}; zone=${zone##*/}
  host=${uri##*/}
  [ -n "$zone" ] && [ -n "$host" ] || return 1
  timeout 60 gcloud compute instances remove-metadata "$host" \
    --project="$PROJECT" --zone="$zone" \
    --keys="$REG_TOKEN_KEY" >/dev/null 2>&1
}

# registration_token_step <host> <self-link> <reg-state> <age-seconds> <status>
# The whole lifecycle in one function so it can be RUN by a self-test rather
# than read: the delete is a security property, and a property nothing executes
# is a comment.
registration_token_step() {
  local host="$1" uri="$2" reg="$3" age="$4" status="${5:-}"
  local minted="$STATE_DIR/regtoken-$host"
  local keylive="$STATE_DIR/regkey-$host"
  local cordon="$STATE_DIR/cordon-$host"
  local fails="$STATE_DIR/regfail-$host"
  local n

  case "$reg" in
    present)
      # Agents are in GitHub's runner list; the token has done its job. The
      # delete is NOT conditional on this controller remembering it wrote the
      # key: the sweep clears markers on an empty host list, a boot disk does
      # not survive a controller replacement, and either would otherwise leave
      # a live credential in metadata for GitHub's full hour. Deleting is
      # idempotent, so the recovery path costs one call and then stops.
      if [ ! -f "$minted" ] || [ -f "$keylive" ]; then
        if delete_registration_token "$uri"; then
          rm -f "$keylive"
          : >"$minted"
          log "regtoken $host: agents registered — $REG_TOKEN_KEY deleted"
        else
          log "regtoken $host: registered but $REG_TOKEN_KEY could not be deleted — retrying next tick"
        fi
      fi
      ;;
    absent | partial)
      # `partial` means at least one slot IS registered and can already pick up
      # a job, so it is grouped with `absent` only for the mint; the delete
      # below does not wait on the remaining slots any differently.
      if [ -f "$keylive" ]; then
        # A cordoned host will never register again — its agents were removed
        # on purpose and the job it is still running is the one the key would
        # be stolen by. Past the grace the host is not coming up either. Either
        # way the credential has no future use, so take it back now.
        if [ -f "$cordon" ] || [ "$age" -ge "$REGISTER_GRACE" ]; then
          if delete_registration_token "$uri"; then
            rm -f "$keylive"
            log "regtoken $host: no agents after ${age}s (cordoned=$([ -f "$cordon" ] && echo yes || echo no)) — $REG_TOKEN_KEY deleted"
          fi
        fi
        return 0
      fi
      # ONE token per instance. Every guard below is a state in which this host
      # was reachable by the branch above and must not be handed a second one:
      # already minted for, cordoned (job code running, deregistered on
      # purpose), not actually booting, or past the grace at which the recycle
      # rule deletes it anyway.
      [ -f "$minted" ] && return 0
      [ -f "$cordon" ] && return 0
      [ "$age" -ge "$REGISTER_GRACE" ] && return 0
      case "$status" in
        PROVISIONING | STAGING | RUNNING) ;;
        *) return 0 ;;
      esac
      # THREE attempts, then stop. A write that keeps failing re-mints once a
      # tick, and each attempt is a registration-token POST against the same App
      # installation the queue poll depends on — the secondary-rate-limit path
      # this file's header calls the blind-tick outage. Worse, the failure this
      # retries hardest is `timeout 60` on a setMetadata that COMMITTED, so each
      # cycle parks another live credential in job-readable metadata. The host
      # is deleted at REGISTER_GRACE regardless, so the retries buy nothing.
      n=$(cat "$fails" 2>/dev/null)
      case "${n:-0}" in *[!0-9]*) n=0 ;; *) n=${n:-0} ;; esac
      [ "$n" -ge 3 ] && return 0
      if write_registration_token "$uri" "$keylive"; then
        : >"$minted"
        rm -f "$fails"
        log "regtoken $host: minted and written to $REG_TOKEN_KEY"
      else
        printf '%s' "$((n + 1))" >"$fails"
        log "regtoken $host: $REG_TOKEN_KEY could not be written (attempt $((n + 1)) of 3)"
      fi
      ;;
    *)
      # `unknown` — the runner list read failed this tick, so nothing is known
      # about this host's agents. Do not hand out a credential on a guess, and
      # do not pull one out from under a host that may be mid-registration.
      :
      ;;
  esac
  return 0
}

# --- drain -------------------------------------------------------------------
#
# The verdict from drain_decision() authorises this sequence and nothing less.
# A bare instance delete would race a job that started between the poll and the
# delete; deregistering first closes that race because GitHub REFUSES to remove
# an agent that is executing a job, and that refusal is the mid-job guard.
drain_host() {
  local host="$1"
  local ids id refused=0

  ids=$(printf '%s' "$RUNNERS_JSON" | jq -r --arg h "$host" \
    '.runners[]? | select(.name | startswith($h + "-s")) | .id' 2>/dev/null)

  local tok
  tok=$(gh_token) || { log "drain $host: no token, aborting drain"; return 1; }

  # An "absent" host has no ids to deregister, so the 422 mid-job guard below
  # has nothing to refuse and cannot protect it. Re-ask GitHub with a FRESH
  # list first: if the agents came up between the verdict and now, the host is
  # alive and may already be holding work.
  if [ -z "$ids" ]; then
    local fresh
    fresh=$(gh_api "repos/$REPO_FULL/actions/runners?per_page=100" 2>/dev/null)
    ids=$(printf '%s' "$fresh" | jq -r --arg h "$host" \
      '.runners[]? | select(.name | startswith($h + "-s")) | .id' 2>/dev/null)
    if [ -n "$ids" ]; then
      log "drain $host: agents registered between the poll and the drain — aborting"
      rm -f "$STATE_DIR/idle-$host"
      DRAIN_ABORTED=$((DRAIN_ABORTED + 1))
      return 1
    fi
  fi

  for id in $ids; do
    local code
    code=$(curl "${CURL_TIMEOUTS[@]}" -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer $tok" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO_FULL/actions/runners/$id")
    case "$code" in
      204 | 404) ;; # gone, or already gone
      *)
        # 422 here means "that runner is running a job" — a job started between
        # the poll and now. Abort the whole drain: a host with one live job is
        # a host that keeps all its slots.
        log "drain $host: runner $id refused deregistration (HTTP $code) — host is working, aborting"
        refused=1
        break
        ;;
    esac
  done

  if [ "$refused" -eq 1 ]; then
    rm -f "$STATE_DIR/idle-$host"
    DRAIN_ABORTED=$((DRAIN_ABORTED + 1))
    return 1
  fi

  # Second gate: even with every registration gone, do not delete while a job
  # process is alive on the box. Checked from here rather than on the host
  # because the host has no permission to remove itself from the MIG.
  local zone
  zone=$(gcloud compute instances list --project="$PROJECT" \
    --filter="name=$host" --format="value(zone)" 2>/dev/null | head -1)

  if [ -n "$zone" ]; then
    local workers
    workers=$(gcloud compute ssh "$host" --zone="$zone" --project="$PROJECT" \
      --tunnel-through-iap --command 'pgrep -fc "Runner.Worker" || true' \
      2>/dev/null | tr -d '[:space:]')
    if [ -n "$workers" ] && [ "$workers" != "0" ]; then
      log "drain $host: $workers job worker(s) still alive after deregistration — leaving host up"
      DRAIN_ABORTED=$((DRAIN_ABORTED + 1))
      return 1
    fi
  fi

  gcloud compute instance-groups managed delete-instances "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --instances="$host" >>"$LOG" 2>&1 || {
      log "drain $host: delete-instances failed"
      return 1
    }

  rm -f "$STATE_DIR/idle-$host" "$STATE_DIR/seen-$host"
  log "drain $host: deregistered and deleted"
  DRAINED=$((DRAINED + 1))
  return 0
}

# --- cordon ------------------------------------------------------------------
#
# Half a drain, and the half that makes "recreate the host without killing its
# job" possible at all.
#
# drain_host() ABORTS on the first agent GitHub refuses to deregister, because
# for an idle-based drain a refusal means our idle read was stale and the host
# is working — the right answer there is to leave the whole host alone. For a
# stale-template host the refusal means something else entirely: that agent is
# finishing a job, and every OTHER agent should still go. So this walks the
# whole list and treats 422 as the expected outcome rather than an abort.
#
# The effect is a host that cannot receive another job — its idle slots are gone
# from the pool and agents here are not --ephemeral, with Restart=no units, so a
# deregistered slot stays deregistered — while the job it is running finishes
# untouched. It retires on a later tick, from recycle_decision's retire branch.
#
# The held slot is still registered, so for up to one poll interval after its
# job lands it can be handed another one. That is why the cordon is re-issued
# every tick instead of once: the next tick either finds it idle and removes it,
# or finds it working again and refuses again. The host leaves a poll later than
# the ideal — it never leaves with a job on it, which is the property that
# matters.
cordon_host() {
  local host="$1"
  local ids id gone=0 held=0

  ids=$(printf '%s' "$RUNNERS_JSON" | jq -r --arg h "$host" \
    '.runners[]? | select(.name | startswith($h + "-s")) | .id' 2>/dev/null)

  local tok
  tok=$(gh_token) || { log "cordon $host: no token, aborting cordon"; return 1; }

  # Marked BEFORE the first deregistration, not after. A cordon that dies
  # halfway has already removed slots from the pool; without the marker the next
  # tick would not count this host against the budget and would cordon a second
  # one beside it.
  : >"$STATE_DIR/cordon-$host"

  for id in $ids; do
    local code
    code=$(curl "${CURL_TIMEOUTS[@]}" -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer $tok" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO_FULL/actions/runners/$id")
    case "$code" in
      204 | 404) gone=$((gone + 1)) ;;
      *)
        # 422: executing a job. Expected, and the entire mid-job guarantee.
        held=$((held + 1))
        ;;
    esac
  done

  log "cordon $host: $gone slot(s) removed from the pool, $held still finishing work"
  CORDONED=$((CORDONED + 1))
  return 0
}

# --- tick --------------------------------------------------------------------

tick() {
  DRAINED=0
  DRAIN_ABORTED=0
  REAPED=0
  CORDONED=0
  RETIRED=0

  local tick_start
  tick_start=$(date +%s)

  collect_demand
  # A blind tick is not an error, it is a SUSPENSION: every host reads
  # reg=unknown, so nothing drains. One is unremarkable; a run of them is a pool
  # pinned at its current size, billing for hosts nobody is using, while the
  # heartbeat keeps publishing 1 and every dashboard stays green. The counter is
  # what makes the difference visible — it is published on every tick, and an
  # alert on it fires on the run, not on the single blip.
  if collect_runners; then
    BLIND_TICKS=0
  else
    BLIND_TICKS=$((BLIND_TICKS + 1))
    log "GitHub runner list unavailable this tick (status=$RUNNER_LIST_STATUS, consecutive=$BLIND_TICKS) — every host reads reg=unknown and nothing will be drained (fail-safe)"
  fi
  collect_hosts
  collect_mig

  local pool_size=0 slots_busy=0 idle_max=0 draining=0 stale_hosts=0
  local host status host_tpl host_uri busy idle age verdict tpl cordoned recycling

  # Hosts already mid-recycle, counted BEFORE any decision this tick, so every
  # host is judged against the same budget rather than against however many
  # happened to be cordoned earlier in the loop.
  #
  # Markers for hosts the MIG no longer lists are cleared first: a retired host
  # that left a marker behind would consume a slot of the budget forever, and
  # the pool would silently stop upgrading after `max_unavailable` releases.
  #
  # Deliberately NOT `… | grep -qx`: under `pipefail` grep -q closes the pipe on
  # the first match and the upstream awk dies of SIGPIPE, so the pipeline's
  # status depends on WHERE in the list the host happened to sit. A live host
  # matching on the last line would read as absent and lose its marker — and a
  # lost marker is a budget slot handed back, which is how more hosts go
  # unavailable at once than max_unavailable permits.
  #
  # `regtoken-*` is swept by the same loop and for a stronger reason than
  # tidiness: a marker left behind by a deleted host is this controller
  # believing it already wrote that host's token, so a host whose name is ever
  # reused would boot with no token and never register.
  #
  # And the sweep does not run on an EMPTY host list. collect_mig swallows its
  # errors, so one API blip reads as "the pool has no hosts" — which would clear
  # every marker in the fleet at once, including the regkey- ones that are the
  # only record that a live registration token is sitting in an instance's
  # metadata. A stale marker costs one host a recycle; a cleared one costs a
  # credential. An actually-empty pool is swept on the next tick that reads one.
  local f mname live_hosts
  live_hosts=$(printf '%s\n' "$HOSTS" | awk -F, '{ if ($1 != "") print $1 }')
  for f in "$STATE_DIR"/cordon-* "$STATE_DIR"/regtoken-* "$STATE_DIR"/regkey-* \
    "$STATE_DIR"/regfail-*; do
    [ -n "$live_hosts" ] || break
    [ -e "$f" ] || continue
    mname=$(basename "$f")
    mname=${mname#cordon-}
    mname=${mname#regtoken-}
    mname=${mname#regkey-}
    mname=${mname#regfail-}
    case $'\n'"$live_hosts"$'\n' in
      *$'\n'"$mname"$'\n'*) ;;
      *) rm -f "$f" ;;
    esac
  done
  recycling=$(find "$STATE_DIR" -maxdepth 1 -name 'cordon-*' 2>/dev/null | wc -l)

  # `IFS=,` on both walks, and it is not cosmetic — see collect_hosts.
  while IFS=, read -r host status host_tpl host_uri; do
    [ -n "$host" ] || continue
    [ "$status" = "RUNNING" ] && pool_size=$((pool_size + 1))
    [ "$(template_state "$host_tpl")" = "stale" ] && stale_hosts=$((stale_hosts + 1))
  done <<<"$HOSTS"

  while IFS=, read -r host status host_tpl host_uri; do
    [ -n "$host" ] || continue

    host_facts "$host"
    busy=$HOST_BUSY
    slots_busy=$((slots_busy + busy))

    idle=$(idle_seconds "$host" "$busy")
    [ "$idle" -gt "$idle_max" ] && idle_max=$idle
    age=$(host_age_seconds "$host")

    # Before any deletion verdict: a host that is still booting needs its
    # registration token now, and a host that has registered needs the key gone
    # now. Both are no-ops on a pool that mints on the host, and both are
    # skipped when the MIG did not report a self-link, because without a zone
    # there is no instance to address and a guessed one is a call against some
    # other machine.
    if [ "$MINT_REG" = "true" ] && [ -n "$host_uri" ]; then
      registration_token_step "$host" "$host_uri" "$HOST_REG" "$age" "$status"
    fi

    # The recycle rule is asked FIRST, and a cordon/retire verdict ends this
    # host's tick. Both rules delete, and only this one knows the host is
    # obsolete: letting drain_decision also speak would mean a host being
    # deliberately retired could instead be kept as "warm" — warm being the
    # exact property that keeps the wrong startup script alive.
    tpl=$(template_state "$host_tpl")
    cordoned=0
    [ -f "$STATE_DIR/cordon-$host" ] && cordoned=1

    verdict=$(recycle_decision "$status" "$tpl" "$busy" "$HOST_REG" \
      "$age" "$REGISTER_GRACE" "$recycling" "$RECYCLE_MAX_UNAVAILABLE" "$cordoned")

    case "$verdict" in
      cordon:*)
        log "$host: $verdict"
        if [ "$cordoned" -eq 0 ]; then
          recycling=$((recycling + 1))
        fi
        # `|| log` is load-bearing, not defensive noise: the controller runs
        # under `set -e`, and cordon_host returns 1 when no token could be
        # minted. Bare, that failure would kill the tick — and a controller that
        # dies mid-tick publishes none of the series it queued, so the pool goes
        # dark rather than merely un-recycled. The marker is already written, so
        # the next tick resumes this host's cordon where this one stopped.
        cordon_host "$host" || log "$host: cordon incomplete — retrying next tick"
        continue
        ;;
      retire:*)
        log "$host: $verdict"
        draining=$((draining + 1))
        if [ "$cordoned" -eq 0 ]; then
          recycling=$((recycling + 1))
        fi
        if drain_host "$host"; then
          pool_size=$((pool_size - 1))
          RETIRED=$((RETIRED + 1))
          rm -f "$STATE_DIR/cordon-$host"
        fi
        continue
        ;;
      *) : ;;
    esac

    verdict=$(drain_decision "$status" "$busy" "$idle" "$GRACE" "$pool_size" "$MIN_HOSTS" "$HOST_REG" \
      "$age" "$REGISTER_GRACE")

    case "$verdict" in
      drain:*)
        log "$host: $verdict"
        draining=$((draining + 1))
        if drain_host "$host"; then
          pool_size=$((pool_size - 1))
        fi
        ;;
      *) : ;;
    esac
  done <<<"$HOSTS"

  # Runs AFTER the drain loop: drain_host() deregisters the agents of the hosts
  # it deletes, so reaping first would race its own bookkeeping.
  reap_orphan_registrations

  local target="$MIG_TARGET"

  # Deliberately LAST, after every scaling decision this tick makes. It is the
  # only work in the tick that nothing waits on — no host is drained and no MIG
  # is resized on what it finds — so running it earlier would spend up to
  # OUTCOME_BUDGET seconds delaying the flush that the autoscaler reads
  # ci_demand from, in order to publish a number nobody is paged on.
  collect_outcomes

  # One request per tick, all series together.
  queue_series "ci_demand" "$DEMAND_TOTAL"
  queue_series "ci_demand_queued" "$DEMAND_QUEUED"
  queue_series "ci_hosts_running" "$pool_size"
  # Published so saturation is expressible as a ratio in one alert policy that
  # works for every pool, rather than a per-pool threshold copied by hand.
  queue_series "ci_hosts_max" "$MAX_HOSTS"
  queue_series "ci_hosts_draining" "$draining"
  queue_series "ci_slots_total" "$((pool_size * SLOTS))"
  queue_series "ci_slots_busy" "$slots_busy"
  queue_series "ci_host_idle_seconds_max" "$idle_max"
  queue_series "ci_queue_wait_seconds_max" "$QUEUE_WAIT_MAX"
  # The other half of the wait. ci_queue_wait_seconds_max says how long a job
  # waited to START; this says how long the oldest one that DID start has been
  # running. A slot whose runner agent stops taking steps mid-job leaves GitHub
  # believing the job is in flight, and nothing in this controller can see it:
  # the orphan reaper deliberately backs off when GitHub reports a runner busy,
  # which is exactly the state a wedged slot is in. So the job runs out its
  # `timeout-minutes`, is reported as `cancelled`, and takes a required check —
  # and the PR — with it. Observed 2026-08-15 on DataRetrival #2404: eighteen
  # steps done in 35s, step nineteen never dispatched, fifteen minutes of
  # nothing, every sibling job green.
  #
  # A max, not a count over a threshold: "too long" is per repository — an
  # integration suite legitimately runs for half an hour where a lint job never
  # exceeds two minutes — and a fleet-wide constant would either miss the wedge
  # or cry wolf. A gauge of the oldest in-flight job lets each repo's alert
  # policy pick its own number, and it degrades to the truth (the longest job
  # this pool is running) rather than to a lie when nothing is wrong.
  queue_series "ci_job_running_seconds_max" "$RUNNING_MAX"
  queue_series "ci_mig_target_size" "$target"
  queue_series "ci_drain_verdicts" "$DRAINED" '"outcome":"drained"'
  queue_series "ci_drain_verdicts" "$DRAIN_ABORTED" '"outcome":"aborted"'
  # The one series that says whether an APPLY reached machines. A pin lands, a
  # template changes, and this climbs to the pool size and then falls back to
  # zero as the hosts are replaced. Stuck above zero means a pool that keeps
  # being told to upgrade and never does — which is precisely the state that was
  # invisible on 2026-08-15, when v5.7.0 was applied and five hosts kept serving
  # jobs from the previous template with nothing anywhere reporting it.
  queue_series "ci_hosts_stale_template" "$stale_hosts"
  # Per-tick deltas, like ci_drain_verdicts. `cordoned` climbing while `retired`
  # stays flat is a pool whose jobs never end — the recycle is working and the
  # hosts are not leaving.
  queue_series "ci_recycle_verdicts" "$CORDONED" '"outcome":"cordoned"'
  queue_series "ci_recycle_verdicts" "$RETIRED" '"outcome":"retired"'
  # A pool at steady state reaps ~0. A series that keeps climbing means hosts
  # are disappearing without going through drain_host() — worth an alert, not
  # just a log line.
  queue_series "ci_orphan_registrations_reaped" "$REAPED"
  # Heartbeat is published on EVERY tick including a bad one, so "no data" on
  # this series means the controller is down — a distinct alert from "the pool
  # is idle", which the other series cannot distinguish on their own.
  queue_series "ci_poller_heartbeat" "1"
  # Published on EVERY tick, 0 included — a series that only appears when broken
  # is indistinguishable from a controller that stopped publishing, which is the
  # confusion this whole fleet keeps paying for. 0 means "the last tick could see
  # GitHub"; N means scale-in has been suspended for N consecutive ticks.
  queue_series "ci_runner_list_blind_ticks" "$BLIND_TICKS"
  # How long this tick took, end to end. The fleet had no series for it and paid
  # for that: a tick growing past the watchdog threshold is a controller about to
  # be restarted mid-tick forever, and the only visible symptom was every OTHER
  # series going absent at once. Published last so it also covers the work done
  # after the drain loop.
  queue_series "ci_tick_seconds" "$(( $(date +%s) - tick_start ))"
  # >0 means ci_demand is a lower bound this tick, so a pool that looks
  # under-scaled may simply not have been counted.
  queue_series "ci_demand_runs_skipped" "$DEMAND_RUNS_SKIPPED"
  # Published on every tick, 0 included — it is what makes an ABSENT
  # ci_jobs_completed readable as "no jobs finished" rather than "the outcome
  # sweep never got to them".
  queue_series "ci_outcome_runs_skipped" "$OUTCOME_RUNS_SKIPPED"
  queue_outcome_series
  flush_series
}

# --- install / run -----------------------------------------------------------

install_self() {
  mkdir -p "$STATE_DIR" /opt/ci-controller
  install -m 0755 "$0" "$SELF_INSTALL"

  # jq is the only runtime dependency not in the base image. Installed here,
  # once, on a 2-vCPU always-on VM — not in any build path.
  command -v jq >/dev/null 2>&1 || {
    apt-get update -qq >>"$LOG" 2>&1
    apt-get install -y -qq jq >>"$LOG" 2>&1
  }

  cat >/etc/systemd/system/ci-controller.service <<EOF
[Unit]
Description=CI runner pool controller ($POOL)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SELF_INSTALL --loop
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

  # --- watchdog --------------------------------------------------------------
  #
  # `Restart=always` only fires when the process EXITS. The failure this fleet
  # actually suffers is the opposite: the loop blocks on a call and the process
  # stays perfectly alive, so systemd sees a healthy unit while the pool stops
  # scaling out and stops draining. Bounded curls make that unlikely; this makes
  # it self-correcting, because "unlikely" ran for 2h55m on 2026-08-14 and
  # needed a human with SSH to end it.
  #
  # A separate unit on purpose — a watchdog inside the loop it watches shares
  # its fate. Deliberately dumb: compare the heartbeat file's age against a
  # threshold and restart, nothing else. Threshold is 10 polls (min 300s), far
  # above any legitimate tick — a full tick is bounded by the curl timeouts
  # times the hosts it walks — so a restart means genuinely stuck, not merely
  # slow. Restarting is safe at any point: every tick recomputes from live
  # GitHub and MIG state, and the drain/orphan state files are idempotent
  # counters, so nothing is lost by starting the tick over.
  local wd_threshold=$((POLL * 10))
  [ "$wd_threshold" -lt 300 ] && wd_threshold=300

  # The decision rule is EMITTED FROM THE FUNCTION THIS PROCESS CARRIES, via
  # `declare -f`, not re-typed into the heredoc. watchdog-decision.sh is
  # concatenated into this script at apply time and unit-tested in CI, so the
  # text on the box is the text the tests exercised. A second hand-written copy
  # here would be the one that drifts — and its drift would be invisible, since
  # the watchdog only speaks by restarting something.
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
    declare -f watchdog_verdict
    cat <<WDEOF
HB="$STATE_DIR/heartbeat"
THRESHOLD=$wd_threshold
UNIT=ci-controller.service

now=\$(date +%s)
present=0; age=0
if [ -f "\$HB" ]; then
  present=1
  last=\$(stat -c %Y "\$HB" 2>/dev/null || echo "\$now")
  age=\$((now - last))
fi

# How long the unit has been up. An inactive unit reports the zero timestamp and
# systemd prints an empty value when it cannot answer at all; both become -1,
# which watchdog_verdict treats as "old enough to judge" — an unreadable uptime
# must not switch the watchdog off.
uptime=-1
started=\$(systemctl show "\$UNIT" -p ActiveEnterTimestamp --value 2>/dev/null)
if [ -n "\$started" ] && [ "\$started" != "n/a" ]; then
  epoch=\$(date -d "\$started" +%s 2>/dev/null || echo "")
  [ -n "\$epoch" ] && [ "\$epoch" -gt 0 ] && uptime=\$((now - epoch))
fi

verdict=\$(watchdog_verdict "\$present" "\$age" "\$uptime" "\$THRESHOLD")
case "\$verdict" in
  restart)
    logger -t ci-controller-watchdog -- "heartbeat \${age}s old (>= \${THRESHOLD}s) and unit up \${uptime}s — restarting \$UNIT"
    systemctl restart "\$UNIT"
    ;;
  hold:restarted-*)
    # Logged, unlike the other holds: this is the branch that was missing, and
    # if a controller is being held every minute the operator should be able to
    # see that the watchdog is deliberately not acting.
    logger -t ci-controller-watchdog -- "heartbeat \${age}s old but \$verdict — holding"
    ;;
esac
WDEOF
  } >/opt/ci-controller/watchdog.sh
  chmod 0755 /opt/ci-controller/watchdog.sh

  cat >/etc/systemd/system/ci-controller-watchdog.service <<'WDSVCEOF'
[Unit]
Description=CI controller watchdog — restarts the controller if its tick loop stalls

[Service]
Type=oneshot
ExecStart=/opt/ci-controller/watchdog.sh
# This unit is itself a `Type=oneshot`, which has no start timeout by default and
# whose timer will not re-fire while an activation is still starting — the very
# trap it exists to catch. It only stats a file and calls systemctl, so anything
# past a minute is stuck, not slow.
TimeoutStartSec=60
WDSVCEOF

  cat >/etc/systemd/system/ci-controller-watchdog.timer <<'WDTIMEOF'
[Unit]
Description=Check the CI controller heartbeat every minute

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10s

[Install]
WantedBy=timers.target
WDTIMEOF

  systemctl daemon-reload
  systemctl enable ci-controller.service
  systemctl enable ci-controller-watchdog.timer

  # RESTART, not `enable --now`. The controller VM keeps its boot disk across a
  # reset, so /opt/ci-controller/controller.sh from the PREVIOUS version is
  # already on disk and its unit is already enabled: systemd starts the OLD code
  # at boot, this script then overwrites the file, and `enable --now` sees a
  # running unit and does nothing. The result is the worst possible shape of a
  # rollout — the file on disk is the new version, `terraform apply` reports
  # success, and the process serving the pool is still the old one. That is
  # exactly how v5.1.0 reached the IntegrateIT controller on 2026-08-14 with the
  # bounded curls and the watchdog present in the file and absent from the
  # running loop (no heartbeat file, so the watchdog also stayed inert).
  #
  # Restarting unconditionally is safe: every tick recomputes from live GitHub
  # and MIG state, and the drain/orphan state files are idempotent counters, so
  # a tick started over loses nothing.
  systemctl restart ci-controller.service
  systemctl restart ci-controller-watchdog.timer
  log "controller installed for $REPO_FULL pool=$POOL mig=$MIG poll=${POLL}s grace=${GRACE}s slots=$SLOTS watchdog=${wd_threshold}s"
}

run_loop() {
  log "controller loop starting"
  while true; do
    # Written BEFORE the tick as well as after it. The heartbeat is LOCAL
    # liveness — "this loop is turning" — and a tick can legitimately run for
    # minutes on a repo with many active runs. Writing it only afterwards made
    # a slow tick indistinguishable from a wedged one, and the watchdog's
    # restart then killed the tick before it could write the file that would
    # have stopped the restarting (see watchdog-decision.sh). A tick genuinely
    # stuck on a call still ages this file out, because the write happens once
    # per iteration, not once per second.
    date +%s >"$STATE_DIR/heartbeat" 2>/dev/null || true
    tick || log "tick failed"
    # After it too, so an ordinary tick keeps the file at most one tick old
    # rather than one tick plus its own duration.
    date +%s >"$STATE_DIR/heartbeat" 2>/dev/null || true
    sleep "$POLL"
  done
}

case "${1:-}" in
  --loop) run_loop ;;
  *) install_self ;;
esac
