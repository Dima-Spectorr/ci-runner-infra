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
GH_HTTP_STATUS=""
RUNNER_LIST_STATUS="ok"
# Consecutive ticks that could not read the runner list. Reset on the first
# successful read, published every tick. In-memory on purpose: a controller
# restart genuinely starts a new run of ticks, and a counter surviving on disk
# would report a suspension that is no longer happening.
BLIND_TICKS=0

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

# Body on stdout, and the reason on GH_HTTP_STATUS when there is no body. With
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
  tok=$(gh_token) || { GH_HTTP_STATUS="no-token"; printf 'no-token' >"$STATE_DIR/api.status"; return 1; }
  status=$(curl "${CURL_TIMEOUTS[@]}" -sS -o "$STATE_DIR/api.body" -w '%{http_code}' \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$1" 2>>"$LOG") || status="000"
  GH_HTTP_STATUS="$status"
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
  now=$sweep_start

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
          ([ $mine[] | select(.status == "queued") | .started_at // .created_at ] | join(" "))
        ] | @tsv' 2>/dev/null)

    [ -n "$counted" ] || continue
    local n q stamps
    n=$(printf '%s' "$counted" | cut -f1)
    q=$(printf '%s' "$counted" | cut -f2)
    stamps=$(printf '%s' "$counted" | cut -f3)

    DEMAND_TOTAL=$((DEMAND_TOTAL + n))
    DEMAND_QUEUED=$((DEMAND_QUEUED + q))

    local s wait epoch
    for s in $stamps; do
      epoch=$(date -d "$s" +%s 2>/dev/null) || continue
      wait=$((now - epoch))
      [ "$wait" -gt "$QUEUE_WAIT_MAX" ] && QUEUE_WAIT_MAX=$wait
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

# --- hosts -------------------------------------------------------------------

collect_runners() {
  # One page of 100 covers max_hosts * slots for every pool in this fleet;
  # paginate rather than silently truncate if that stops being true.
  # The status is read back from disk, not from GH_HTTP_STATUS: this call runs
  # in a command substitution, so every assignment gh_api makes happens in a
  # subshell and is gone by the time this line runs. That is why 36 consecutive
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
  HOSTS=$(gcloud compute instance-groups managed list-instances "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --format="value(instance.basename(),instanceStatus)" 2>/dev/null)
}

# One describe per tick for both facts we need from the MIG: the target size we
# publish, and the baseInstanceName that bounds the orphan reaper to instances
# THIS pool can create. Kept together so the reaper never costs an extra call.
collect_mig() {
  local line
  line=$(gcloud compute instance-groups managed describe "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --format="value(baseInstanceName,targetSize)" 2>/dev/null)
  MIG_BASE=$(printf '%s' "$line" | cut -f1)
  MIG_TARGET=$(printf '%s' "$line" | cut -f2)
  MIG_BASE=${MIG_BASE:-}
  MIG_TARGET=${MIG_TARGET:-0}
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
  live=$(printf '%s' "$HOSTS" | awk '{print $1}' | paste -sd, -)

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

# --- tick --------------------------------------------------------------------

tick() {
  DRAINED=0
  DRAIN_ABORTED=0
  REAPED=0

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

  local pool_size=0 slots_busy=0 idle_max=0 draining=0
  local host status busy idle age verdict

  while read -r host status; do
    [ -n "$host" ] || continue
    [ "$status" = "RUNNING" ] && pool_size=$((pool_size + 1))
  done <<<"$HOSTS"

  while read -r host status; do
    [ -n "$host" ] || continue

    host_facts "$host"
    busy=$HOST_BUSY
    slots_busy=$((slots_busy + busy))

    idle=$(idle_seconds "$host" "$busy")
    [ "$idle" -gt "$idle_max" ] && idle_max=$idle
    age=$(host_age_seconds "$host")

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
  queue_series "ci_mig_target_size" "$target"
  queue_series "ci_drain_verdicts" "$DRAINED" '"outcome":"drained"'
  queue_series "ci_drain_verdicts" "$DRAIN_ABORTED" '"outcome":"aborted"'
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
