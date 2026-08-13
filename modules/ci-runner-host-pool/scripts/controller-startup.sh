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

md() {
  curl -fsS -H "Metadata-Flavor: Google" \
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

SLOTS=${SLOTS:-1}
MIN_HOSTS=${MIN_HOSTS:-0}
MAX_HOSTS=${MAX_HOSTS:-0}
GRACE=${GRACE:-900}
POLL=${POLL:-20}
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
  key=$(gcloud secrets versions access latest --secret="$KEY_SECRET" 2>/dev/null)
  [ -n "$key" ] || { log "cannot read App key secret $KEY_SECRET"; return 1; }

  _b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | _b64)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign <(printf '%s' "$key") | _b64)
  jwt="$header.$payload.$sig"

  local resp
  resp=$(curl -fsS -X POST -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$INSTALL_ID/access_tokens") || return 1

  GH_TOKEN=$(printf '%s' "$resp" | jq -r '.token // empty')
  [ -n "$GH_TOKEN" ] || return 1
  GH_TOKEN_EXPIRY=$((now + 3600))
  printf '%s' "$GH_TOKEN"
}

gh_api() {
  local tok
  tok=$(gh_token) || return 1
  curl -fsS -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$1"
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
collect_demand() {
  local runs jobs
  DEMAND_TOTAL=0
  DEMAND_QUEUED=0
  QUEUE_WAIT_MAX=0

  runs=$(gh_api "repos/$REPO_FULL/actions/runs?status=queued&per_page=50" 2>/dev/null)
  local runs_ip
  runs_ip=$(gh_api "repos/$REPO_FULL/actions/runs?status=in_progress&per_page=50" 2>/dev/null)

  local ids
  ids=$(printf '%s\n%s' "$runs" "$runs_ip" \
    | jq -r '.workflow_runs[]?.id' 2>/dev/null | sort -u)
  [ -n "$ids" ] || return 0

  local now
  now=$(date +%s)

  local id
  for id in $ids; do
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
}

# --- hosts -------------------------------------------------------------------

collect_runners() {
  # One page of 100 covers max_hosts * slots for every pool in this fleet;
  # paginate rather than silently truncate if that stops being true.
  RUNNERS_JSON=$(gh_api "repos/$REPO_FULL/actions/runners?per_page=100" 2>/dev/null)
  if [ -z "$RUNNERS_JSON" ]; then
    RUNNERS_JSON=""
    return 1
  fi
  return 0
}

collect_hosts() {
  HOSTS=$(gcloud compute instance-groups managed list-instances "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --format="value(instance.basename(),instanceStatus)" 2>/dev/null)
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

  for id in $ids; do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
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

  rm -f "$STATE_DIR/idle-$host"
  log "drain $host: deregistered and deleted"
  DRAINED=$((DRAINED + 1))
  return 0
}

# --- tick --------------------------------------------------------------------

tick() {
  DRAINED=0
  DRAIN_ABORTED=0

  collect_demand
  collect_runners || log "GitHub runner list unavailable this tick — every host reads reg=unknown and nothing will be drained (fail-safe)"
  collect_hosts

  local pool_size=0 slots_busy=0 idle_max=0 draining=0
  local host status busy idle verdict

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

    verdict=$(drain_decision "$status" "$busy" "$idle" "$GRACE" "$pool_size" "$MIN_HOSTS" "$HOST_REG")

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

  local target
  target=$(gcloud compute instance-groups managed describe "$MIG" \
    --region="$REGION" --project="$PROJECT" --format="value(targetSize)" 2>/dev/null)
  target=${target:-0}

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
  # Heartbeat is published on EVERY tick including a bad one, so "no data" on
  # this series means the controller is down — a distinct alert from "the pool
  # is idle", which the other series cannot distinguish on their own.
  queue_series "ci_poller_heartbeat" "1"
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

  systemctl daemon-reload
  systemctl enable --now ci-controller.service
  log "controller installed for $REPO_FULL pool=$POOL mig=$MIG poll=${POLL}s grace=${GRACE}s slots=$SLOTS"
}

run_loop() {
  log "controller loop starting"
  while true; do
    tick || log "tick failed"
    sleep "$POLL"
  done
}

case "${1:-}" in
  --loop) run_loop ;;
  *) install_self ;;
esac
