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
POLL=$(md "instance/attributes/ci-poll-seconds")
METRIC_PREFIX=$(md "instance/attributes/ci-metric-prefix")

# --- the pool table ----------------------------------------------------------
#
# ONE controller, N pools. Everything that describes A pool — its MIG, its
# labels, its graces, whether it mints registration tokens — is per-pool state
# from here on, and pool_select() writes it into the globals the rest of this
# file already reads. That is deliberate and it is the whole design: every
# function that acts on a pool is UNCHANGED, and the tick loop selects a pool
# before calling them.
#
# THE LEGACY SHAPE IS SYNTHESISED, NOT SERVED BY A SECOND PATH. A controller
# rendered before `ci-pools` existed carries the old one-key-per-field metadata
# and no table; it becomes a one-row table here and takes the same code path.
# So there is no second implementation to keep in step, and no consumer has to
# move Terraform state to keep the controller it already has running.
POOLS_JSON=$(md "instance/attributes/ci-pools")
if [ -z "${POOLS_JSON:-}" ]; then
  # `nz` and not jq's `//`: an ABSENT metadata attribute reads as the empty
  # string, and in jq an empty string is truthy — `"" // 900` is `""`, not 900.
  # Every default in pool_table_parse() would be bypassed by the very thing it
  # exists to default, and the row would then be rejected as non-numeric.
  #
  # One behaviour change is deliberate and bounded: a controller so old that it
  # has no `ci-host-os` at all used to resolve to `unknown`, which shut the
  # drain gate's OS-inference fallback. It now defaults to `linux`. Every such
  # controller IS Linux — the key landed in the same change as Windows support —
  # so the inference it re-enables can only reach the answer it would have been
  # given explicitly.
  POOLS_JSON=$(jq -n \
    --arg name "$(md "instance/attributes/ci-pool")" \
    --arg mig "$(md "instance/attributes/ci-mig-name")" \
    --arg region "$(md "instance/attributes/ci-region")" \
    --arg slots "$(md "instance/attributes/ci-slots")" \
    --arg minh "$(md "instance/attributes/ci-min-hosts")" \
    --arg maxh "$(md "instance/attributes/ci-max-hosts")" \
    --arg grace "$(md "instance/attributes/ci-drain-grace-seconds")" \
    --arg reggrace "$(md "instance/attributes/ci-register-grace-seconds")" \
    --arg ticks "$(md "instance/attributes/ci-orphan-confirm-ticks")" \
    --arg recycle "$(md "instance/attributes/ci-recycle-max-unavailable")" \
    --arg hostos "$(md "instance/attributes/ci-host-os")" \
    --arg mint "$(md "instance/attributes/ci-mint-registration-token")" \
    --arg beacon "$(md "instance/attributes/ci-beacon-interval")" \
    --arg pin "$(md "instance/attributes/ci-pin-orphan-grace-seconds")" \
    --arg labels "$(md "instance/attributes/ci-runner-labels")" \
    'def nz: if . == "" then null else . end;
     [ { name: $name, mig: $mig, region: $region,
         slots: ($slots | nz), min_hosts: ($minh | nz), max_hosts: ($maxh | nz),
         drain_grace_seconds: ($grace | nz),
         register_grace_seconds: ($reggrace | nz),
         orphan_confirm_ticks: ($ticks | nz),
         recycle_max_unavailable: ($recycle | nz),
         host_os: ($hostos | nz),
         mints_registration_token: ($mint | nz),
         beacon_interval: ($beacon | nz),
         pin_orphan_grace_seconds: ($pin | nz),
         runner_labels: $labels } ]')
fi

POOLS=()
declare -A P_MIG=() P_REGION=() P_SLOTS=() P_MIN=() P_MAX=() P_GRACE=()
declare -A P_REGGRACE=() P_TICKS=() P_RECYCLE=() P_HOST_OS=() P_MINT=()
declare -A P_ROLE=() P_BEACON=() P_PIN=() P_LABELS=() P_LABELS_JSON=()

# Rejected rows are counted and published (ci_pool_table_rejected), not merely
# logged: a pool that silently stopped being served looks exactly like a pool
# with nothing to do, and its autoscaler is ONLY_UP, so it holds its last size
# indefinitely with every other series reading healthy.
POOL_TABLE_REJECTED=0
{
  pool_rejects=$(mktemp)
  pool_rows=$(printf '%s' "$POOLS_JSON" | pool_table_parse 2>"$pool_rejects") || {
    echo "no usable pool in ci-pools metadata — this controller has nothing to manage" >&2
    cat "$pool_rejects" >&2
    rm -f "$pool_rejects"
    exit 1
  }
  # `grep -c` exits 1 on zero matches, so `|| echo 0` would append a SECOND
  # line to a count that is already "0" and every later `-eq` on it would be an
  # `integer expression expected`. wc counts without an opinion.
  POOL_TABLE_REJECTED=$(grep -c . "$pool_rejects" 2>/dev/null | head -1)
  case "${POOL_TABLE_REJECTED:-}" in '' | *[!0-9]*) POOL_TABLE_REJECTED=0 ;; esac
  [ "$POOL_TABLE_REJECTED" -eq 0 ] || cat "$pool_rejects" >&2
  rm -f "$pool_rejects"
}

# Tab-separated on the way back in, and safely so: pool_table_parse rejects any
# row with an empty column, so there is no run of empty fields for `read` to
# collapse. See the note in pool-table.sh.
while IFS=$'\t' read -r p_name p_mig p_region p_slots p_min p_max p_grace \
  p_reggrace p_ticks p_recycle p_hostos p_mint p_role p_beacon p_pin p_labels; do
  [ -n "$p_name" ] || continue
  POOLS+=("$p_name")
  P_MIG["$p_name"]="$p_mig"
  P_REGION["$p_name"]="$p_region"
  P_SLOTS["$p_name"]="$p_slots"
  P_MIN["$p_name"]="$p_min"
  P_MAX["$p_name"]="$p_max"
  P_GRACE["$p_name"]="$p_grace"
  P_REGGRACE["$p_name"]="$p_reggrace"
  P_TICKS["$p_name"]="$p_ticks"
  P_RECYCLE["$p_name"]="$p_recycle"
  P_HOST_OS["$p_name"]="$p_hostos"
  P_MINT["$p_name"]="$p_mint"
  P_ROLE["$p_name"]="$p_role"
  P_BEACON["$p_name"]="$p_beacon"
  P_PIN["$p_name"]="$p_pin"
  P_LABELS["$p_name"]="$p_labels"
  # The left-hand side of GitHub's superset rule, precomputed once per pool
  # rather than per run per tick. Must stay identical to what host-startup.sh
  # passes to config.sh, which is why both sides come from one metadata value.
  P_LABELS_JSON["$p_name"]=$(printf '%s' "$p_labels" \
    | jq -R -c 'split(",") | map(select(length > 0))')
done <<<"$pool_rows"

# The label sets of every pool at once, as {pool: [labels]}. The demand sweep
# fetches a run's job list ONCE and asks jq which pools each job belongs to —
# the entire reason a repository can have four pools without paying for four
# controllers' worth of API calls.
POOLS_LABELS_MAP=$(
  {
    for p in "${POOLS[@]}"; do
      jq -n -c --arg p "$p" --argjson l "${P_LABELS_JSON[$p]}" '{($p): $l}'
    done
  } | jq -s -c 'add // {}'
)

# pool_select <name> — make <name> THE pool for every function below.
#
# It writes the same global names the single-pool controller always used, which
# is why drain_host(), registration_token_step(), beacon_gate() and the rest are
# byte-identical to what they were. The reset half matters as much as the write
# half: MIG_TEMPLATE and the MIG facts are cleared, so a describe that fails for
# the second pool cannot leave the first pool's template in place and read every
# one of the second pool's hosts as stale — which is a whole-pool cordon.
pool_select() {
  POOL="$1"
  MIG="${P_MIG[$POOL]}"
  REGION="${P_REGION[$POOL]}"
  SLOTS="${P_SLOTS[$POOL]}"
  MIN_HOSTS="${P_MIN[$POOL]}"
  MAX_HOSTS="${P_MAX[$POOL]}"
  GRACE="${P_GRACE[$POOL]}"
  REGISTER_GRACE="${P_REGGRACE[$POOL]}"
  ORPHAN_CONFIRM_TICKS="${P_TICKS[$POOL]}"
  RECYCLE_MAX_UNAVAILABLE="${P_RECYCLE[$POOL]}"
  CONTROLLER_HOST_OS="${P_HOST_OS[$POOL]}"
  MINT_REG="${P_MINT[$POOL]}"
  POOL_ROLE="${P_ROLE[$POOL]}"
  BEACON_INTERVAL="${P_BEACON[$POOL]}"
  PIN_ORPHAN_GRACE="${P_PIN[$POOL]}"
  RUNNER_LABELS="${P_LABELS[$POOL]}"
  POOL_LABELS_JSON="${P_LABELS_JSON[$POOL]}"

  MIG_BASE=""
  MIG_TARGET=0
  MIG_TEMPLATE=""

  DEMAND_TOTAL="${D_TOTAL[$POOL]:-0}"
  DEMAND_QUEUED="${D_QUEUED[$POOL]:-0}"
  QUEUE_WAIT_MAX="${D_WAIT[$POOL]:-0}"
  RUNNING_MAX="${D_RUNNING[$POOL]:-0}"
}

# The per-pool globals pool_select writes, declared at file scope so that a read
# before the first select cannot kill the tick under `set -u`.
POOL=""
MIG=""
REGION=""
SLOTS=1
MIN_HOSTS=0
MAX_HOSTS=0
GRACE=900
REGISTER_GRACE=600
ORPHAN_CONFIRM_TICKS=3
RECYCLE_MAX_UNAVAILABLE=0
CONTROLLER_HOST_OS="unknown"
MINT_REG=false
# POOL_ROLE and POOL_LABELS_JSON are written by pool_select and read by
# nothing in THIS file — the routing rule that consumes the role, and the
# label set the demand sweep hands to jq, both live in the pool table and
# arrive at their readers by other routes. Dropping them here would mean
# re-deriving them per tick from the table instead.
# shellcheck disable=SC2034
POOL_ROLE="ci"
BEACON_INTERVAL=30
PIN_ORPHAN_GRACE=900
RUNNER_LABELS=""
# shellcheck disable=SC2034
POOL_LABELS_JSON="[]"

# The per-instance metadata key a minted token is written to, and DELETED from.
# Hard-coded rather than an input: it is a contract between this file and the
# host boot script in the same module, and a configurable name is one more way
# for the delete to miss the key the write created.
REG_TOKEN_KEY="ci-registration-token"
# The guest-attribute namespace a Windows host publishes its liveness beacon
# into, and the keys inside it. Hard-coded for the same reason REG_TOKEN_KEY is:
# it is a contract between this file and the beacon publisher in this module.
BEACON_NS="ci"
# The key inside that namespace the pin hold is published to, and the ceiling
# the controller will honour on any single hold. Both are contracts with the
# host helper rather than inputs: PIN_HOLD_KEY is the name `ci-pin-hold` writes,
# and PIN_HOLD_MAX is the same 7200 that helper's own PIN_MAX_TTL clamps --ttl
# to. A controller ceiling BELOW the host's clamp would silently cut holds
# short; a configurable one would be one more way for the two to drift apart.
PIN_HOLD_KEY="pin-hold"
PIN_HOLD_MAX=7200
POLL=${POLL:-20}
# Seconds the demand sweep may spend walking per-run job lists. It must stay far
# below the watchdog threshold (10 polls, min 300s): a tick that outruns the
# watchdog is restarted before it can write the heartbeat, and then restarted
# again forever. 90s leaves room for the rest of the tick — the host walk, the
# drains, the orphan reap and the flush — inside any legitimate threshold.
DEMAND_BUDGET=$(md "instance/attributes/ci-demand-budget-seconds")
DEMAND_BUDGET=${DEMAND_BUDGET:-90}
DEMAND_RUNS_SKIPPED=0
# The demand sweep's per-pool results. One sweep fills all four; pool_select()
# hands the selected pool's values to the tick as the globals it always used.
declare -A D_TOTAL=() D_QUEUED=() D_WAIT=() D_RUNNING=()
METRIC_PREFIX=${METRIC_PREFIX:-custom.googleapis.com/github}
REPO_FULL="$OWNER/$REPO"

# An empty label set silently matches NOTHING: every queued job is discarded as
# "not mine", demand reads 0 on every tick, and the pool sits at zero hosts
# while jobs queue. That check now lives in pool_table_parse(), one row at a
# time — a controller serving four pools must not be taken down by the one that
# is misconfigured — and a table in which EVERY row fails it still exits above.

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

# The three DURABLE facts about an instance — its real age, whether it already
# carries a registration token, and whether it was EVER issued one — filled by
# instance_durable_facts() and read only by the mint path. At file scope for the
# same reason as MIG_TEMPLATE: under `set -u` a read before the first successful
# fill would kill the tick.
#
# The age default is deliberately ENORMOUS, not 0. Today the only reader is
# guarded by this function's return code, so the defaults are never consulted —
# but a durable fact that fails OPEN is worse than the marker it replaced,
# because the code now trusts it. `DUR_AGE=0` reads as "born this instant",
# which is below every grace and therefore the most mint-permissive value
# available; a huge age refuses instead. `unknown` is likewise not "absent": the
# adoption arm tests for `present` and the mint arm for `absent`, so an
# unfillable key fact matches neither and nothing happens. DUR_ISSUED is read
# the other way round — the mint is refused unless it is provably `absent` — so
# that the same `unknown` refuses there too.
DUR_AGE=999999999
DUR_KEY="unknown"
DUR_ISSUED="unknown"

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
  # Per pool now, not per controller. The sweep itself is still ONE pass over
  # the repository's runs: a job list is fetched once and scored against every
  # pool's label set inside the same jq invocation, which is what lets four
  # pools cost what one used to.
  local p
  for p in "${POOLS[@]}"; do
    D_TOTAL["$p"]=0
    D_QUEUED["$p"]=0
    D_WAIT["$p"]=0
    D_RUNNING["$p"]=0
  done
  # Reset HERE, with the other counters, not after the loop: every early return
  # below would otherwise leave the previous tick's value in place and the
  # controller would keep republishing "demand is truncated" forever.
  DEMAND_RUNS_SKIPPED=0
  # Same reason, and it matters more for this one: a stale pinned-job list is
  # not a stale number, it is a set of run ids that classify_pinned would judge
  # against a host list from a later tick — and cancel.
  PINNED_JOBS=""

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

    # One line per POOL, from one pass over one job list. The candidate set —
    # unfinished, labelled, not pinned — is computed once and then intersected
    # with each pool's labels, so adding a pool costs jq an intersection rather
    # than the controller an API call.
    #
    # A job counts for every pool whose label set is a superset of its own, and
    # that is GitHub's own rule, not a simplification: any such runner really
    # can pick the job up. It also means two pools with overlapping label sets
    # both scale out for the same job. That is why the merge-queue pools are
    # given a label the CI pools do not carry AND deliberately omit the generic
    # labels the CI pools do — the sets are disjoint by construction, and this
    # is the code that would double-scale if they ever stopped being.
    local counted
    counted=$(printf '%s' "$jobs" | jq -r --argjson pools "$POOLS_LABELS_MAP" '
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
          # `-` and not "" when a pool matched nothing in this run. An empty
          # field between tabs is a field `read` COLLAPSES — tab is IFS
          # whitespace — so a run with in-flight jobs and no queued ones would
          # hand the in-flight stamps to the queued column and report a job
          # that started ten minutes ago as having waited ten minutes.
          # `date -d -` fails and the stamp is skipped, which is the intent.
          ([ $mine[] | select(.status == "queued") | .started_at // .created_at ]
             | join(" ") | if . == "" then "-" else . end),
          ([ $mine[] | select(.status == "in_progress") | .started_at // empty ]
             | join(" ") | if . == "" then "-" else . end)
        ] | @tsv' 2>/dev/null)

    [ -n "$counted" ] || continue

    # The pinned half of the same payload, kept rather than counted.
    #
    # It is NOT filtered against this pool's labels here. Stripping the affinity
    # label before the subset test, deciding whether the named host is even ours
    # to reason about, and deciding whether a run is unservable are one rule, and
    # that rule lives in pinned_job_decision() where it is unit-tested. A second,
    # partial copy of it in jq is how the two drift.
    #
    # It is also not classified here, because it cannot be: the host list this
    # tick is collected AFTER the demand sweep, so at this point the controller
    # does not yet know which hosts are alive. Judging a pin against last tick's
    # list would make the first tick after a restart — when the list is empty —
    # the one that cancels every pinned run in the repo.
    local pinned_recs
    # The jq variable is $rid and not $run: the controller-scope gate reads
    # every $name in a function against every other function's locals, and
    # classify_pinned owns a local called `run`. A jq variable is invisible to
    # that check as anything other than a collision.
    pinned_recs=$(printf '%s' "$jobs" | jq -r --arg rid "$id" '
      .jobs[]?
      | select(.status == "queued" or .status == "in_progress")
      | select( ((.labels // []) | map(select(startswith("host-"))) | length) > 0 )
      | [ $rid, .status, ((.labels // []) | join(",")), (.created_at // "") ]
      | @tsv' 2>/dev/null)
    if [ -n "$pinned_recs" ]; then
      PINNED_JOBS="${PINNED_JOBS}${pinned_recs}
"
    fi

    # Read the clock HERE, per run, and not once before the sweep. Both ages
    # below are measured against it, and `sweep_start` is captured before the
    # two run-list calls — each of which can spend a full CURL_MAX_TIME — and
    # before this run's own job fetch. Against that stale reading every age is
    # short by however long the sweep has been running, which on a busy pool is
    # most of DEMAND_BUDGET: the two series would understate the wait and the
    # run time by up to a minute and a half, and understate them MOST on the
    # pool under the most load, which is the pool being looked at.
    now=$(date +%s)

    # One line per pool, in the order jq emitted them. A pool with no matching
    # job in this run still emits a line of zeros and an empty stamp list, which
    # is what keeps the accumulators honest without a second membership test.
    local c_pool n q stamps running s wait epoch
    while IFS=$'\t' read -r c_pool n q stamps running; do
      [ -n "${c_pool:-}" ] || continue
      # A pool jq knows about but this shell does not cannot happen — the map
      # was built from POOLS — but the guard costs nothing and an unguarded
      # write would create a phantom entry that every later loop iterates.
      [ -n "${D_TOTAL[$c_pool]+set}" ] || continue

      D_TOTAL["$c_pool"]=$(( D_TOTAL["$c_pool"] + ${n:-0} ))
      D_QUEUED["$c_pool"]=$(( D_QUEUED["$c_pool"] + ${q:-0} ))

      for s in $stamps; do
        epoch=$(date -d "$s" +%s 2>/dev/null) || continue
        wait=$((now - epoch))
        [ "$wait" -gt "${D_WAIT[$c_pool]}" ] && D_WAIT["$c_pool"]=$wait
      done

      # Same arithmetic, different question: how long has the OLDEST job that is
      # already executing been executing for. Free — these jobs are in the
      # payload the demand sweep just paid for, and their start times were
      # discarded.
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
        [ "$wait" -gt "${D_RUNNING[$c_pool]}" ] && D_RUNNING["$c_pool"]=$wait
      done
    done <<<"$counted"
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
    rows=$(printf '%s' "$jobs" | jq -r --argjson pools "$POOLS_LABELS_MAP" '
      [ .jobs[]?
        | select(.status == "completed")
        | select( ((.labels // []) | length) > 0 )
      ] as $candidates
      | $pools | to_entries[]
      | .key as $pool
      | .value as $mine_labels
      | $candidates[]
      | select( ((.labels // []) - $mine_labels) | length == 0 )
      | [ $pool,
          (.workflow_name // "unknown"),
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

    local o_pool wf outcome secs
    while IFS=$'\t' read -r o_pool wf outcome secs; do
      [ -n "$o_pool" ] || continue
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
      # Keyed by POOL first. Cost attribution is per pool or it is not
      # attribution: the whole point of a merge-queue pool is to be able to say
      # what the queue's second CI pass costs, separately from the first.
      OUTCOME_JOBS["$o_pool|$wf|$outcome"]=$(( ${OUTCOME_JOBS["$o_pool|$wf|$outcome"]:-0} + 1 ))
      OUTCOME_SECONDS["$o_pool|$wf"]=$(( ${OUTCOME_SECONDS["$o_pool|$wf"]:-0} + ${secs%%.*} ))
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
# Emits the points belonging to the CURRENTLY SELECTED pool, and is therefore
# called once per pool from inside the per-pool tick — queue_series labels every
# point with $POOL, so a key from another pool published here would be filed
# under this one.
queue_outcome_series() {
  local key rest wf outcome
  for key in "${!OUTCOME_JOBS[@]}"; do
    case "$key" in "$POOL|"*) ;; *) continue ;; esac
    rest="${key#"$POOL|"}"
    wf="${rest%|*}"
    outcome="${rest##*|}"
    queue_series "ci_jobs_completed" "${OUTCOME_JOBS[$key]}" \
      "\"workflow\":\"$wf\",\"outcome\":\"$outcome\""
  done
  for key in "${!OUTCOME_SECONDS[@]}"; do
    case "$key" in "$POOL|"*) ;; *) continue ;; esac
    wf="${key#"$POOL|"}"
    queue_series "ci_job_seconds" "${OUTCOME_SECONDS[$key]}" "\"workflow\":\"$wf\""
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
# --- pinned jobs -------------------------------------------------------------
#
# The demand sweep set PINNED_JOBS aside because it ran before the host list.
# This is the other half: with the list in hand, every pinned job gets one
# verdict from pinned_job_decision(), and the two that matter are the ones that
# do NOT count as scale-out demand and the one that cannot run at all.
#
# WHY A RUN IS CANCELLED RATHER THAN LEFT ALONE
#
# A job pinned to a host that no longer exists is not slow, it is unservable:
# no runner will ever carry that label again — a MIG replacement comes back
# under a new name — so nothing retries it, nothing scales for it, and it holds
# its concurrency group until GitHub times it out 24 hours later. Failing it in
# minutes turns a silent day-long wedge into a re-run.
#
# Which makes a false positive expensive, so three separate things have to be
# true before anything is cancelled: the host must be one THIS pool could have
# created, the job must have been queued longer than the grace window, and the
# host list must be non-empty. The last is the fail-safe that matters most —
# see below.
classify_pinned() {
  DEMAND_PINNED=0
  PIN_ORPHANED=0

  [ -n "${PINNED_JOBS:-}" ] || return 0

  local live
  live=$(printf '%s' "$HOSTS" | awk -F, '{print $1}' | paste -sd, -)

  # AN EMPTY HOST LIST IS NOT AN EMPTY POOL. collect_hosts can come back with
  # nothing because the pool genuinely scaled to zero, or because the list call
  # failed — and those are indistinguishable here. Under the first reading every
  # pinned job in the repo is orphaned; under the second, every one of those
  # cancellations is wrong. Same fail-safe the drain path and the reaper take:
  # a tick that cannot see is a tick that does not act. Pinned work is still
  # counted, so the metric does not collapse to zero at the same moment.
  local blind=0
  [ -n "$live" ] || blind=1

  local now run status labels created age epoch verdict token code
  now=$(date +%s)

  while IFS=$(printf '\t') read -r run status labels created; do
    [ -n "$run" ] || continue

    # An unparseable timestamp yields age 0, which reads as "just queued" and
    # therefore as "wait". Erring toward the grace window is the whole posture.
    age=0
    if epoch=$(date -d "$created" +%s 2>/dev/null); then
      age=$((now - epoch))
      [ "$age" -lt 0 ] && age=0
    fi

    verdict=$(pinned_job_decision "$status" "$labels" "$RUNNER_LABELS" "$MIG_BASE" \
      "$live" "$age" "$PIN_ORPHAN_GRACE")

    case "$verdict" in
      pinned:* | wait:*)
        # Counted as work in flight and NOT added to ci_demand: only the host
        # named in the label can serve it, so an autoscaler whose one move is
        # "add a host" would buy a machine per tick that the job cannot use.
        DEMAND_PINNED=$((DEMAND_PINNED + 1))
        ;;
      orphan:*)
        # The run id is interpolated into an API path, and everything else on
        # this line is derived from a payload a pull request can influence. It
        # is an integer from GitHub or it is not used — a value carrying a slash
        # would address a different endpoint entirely.
        case "$run" in
          "" | *[!0-9]*) log "pinned run '$run': $verdict — id is not numeric, not cancelled"; continue ;;
        esac
        if [ "$blind" = 1 ]; then
          DEMAND_PINNED=$((DEMAND_PINNED + 1))
          log "pinned run $run: $verdict — NOT cancelled, this tick has no host list (fail-safe)"
          continue
        fi
        token=$(gh_token) || { log "pinned run $run: $verdict — no token, not cancelled"; continue; }
        code=$(curl "${CURL_TIMEOUTS[@]}" -s -o /dev/null -w '%{http_code}' -X POST \
          -H "Authorization: Bearer $token" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/$REPO_FULL/actions/runs/$run/cancel")
        case "$code" in
          202 | 409)
            # 409 = already finishing. The run is leaving either way, and
            # counting it as handled is what stops the log repeating per tick.
            PIN_ORPHANED=$((PIN_ORPHANED + 1))
            log "pinned run $run: $verdict — cancelled (HTTP $code)"
            ;;
          *)
            # Most likely the app lacks Actions: write. Say so once per tick
            # rather than retrying: the job still cannot run, and a wedge nobody
            # can see is exactly what this function exists to prevent.
            log "pinned run $run: $verdict — cancel REFUSED (HTTP $code); the run will wait for GitHub's own timeout"
            ;;
        esac
        ;;
    esac
  done <<PINNED_EOF
$PINNED_JOBS
PINNED_EOF

  return 0
}

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
#                    removed only after a confirmed delete. Also written when the
#                    durable gate finds a key already on the instance, which is
#                    how a lost regkey is picked back up.
#   regfail-<host>   Failed write attempts. Three, then stop asking GitHub.
#
# So every path below fails in the direction that keeps the key small: a write
# that reports failure is followed by a delete in case it landed anyway, a failed
# delete keeps regkey so the delete retries, and a `present` OR `partial` host
# whose regkey state was lost is deleted from anyway rather than assumed clean.
#
# AND NONE OF THE THREE IS ALLOWED TO BE THE LAST WORD ON THE MINT PATH. All of
# them live on the controller's boot disk, so replacing the controller erases
# every one at the same instant — together with host_age_seconds, which restarts
# from this controller's first sight of a host. That single event is what made a
# cordoned host mid-job read as brand new and get handed a fresh credential into
# its own job's metadata. The mint path therefore ends at instance_durable_facts,
# which asks the GCE API instead. A fourth marker file cannot express either of
# the two facts it needs, because the problem is not which fact is recorded — it
# is where.

# write_registration_token <instance-self-link> <regkey-marker>
write_registration_token() {
  local uri="$1" keylive="$2"
  local tok resp reg f zone host rc

  # The parse comes FIRST, before anything is minted. A registration token is
  # live from the moment GitHub issues it, so a self-link this cannot address —
  # a MIG row with no instance URI, a format change — would otherwise burn an
  # hour-long credential that no delete path can ever reach, because the delete
  # needs the same zone this failed to read.
  zone=${uri%/instances/*}; zone=${zone##*/}
  host=${uri##*/}
  if [ -z "$zone" ] || [ -z "$host" ]; then
    log "regtoken: cannot read a zone from $uri"
    return 1
  fi

  tok=$(gh_token) || { log "regtoken: no installation token"; return 1; }

  resp=$(curl "${CURL_TIMEOUTS[@]}" -fsS -X POST \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO_FULL/actions/runners/registration-token") || return 1
  reg=$(printf '%s' "$resp" | jq -r '.token // empty')
  [ -n "$reg" ] || return 1

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
    #
    # The ISSUED marker goes in the SAME call, and that is the whole point of it.
    # It is the durable form of the `minted` marker: one setMetadata, so if the
    # token committed then so did the record that it was ever handed out, and no
    # later controller can conclude otherwise. It is never deleted — the delete
    # below names only $REG_TOKEN_KEY — so it outlives both the token and the
    # controller that wrote it. `--metadata`, not `--metadata-from-file`, because
    # the value is the literal `1` and carries no secret; the token beside it is
    # still passed by file.
    timeout 60 gcloud compute instances add-metadata "$host" \
      --project="$PROJECT" --zone="$zone" \
      --metadata="${REG_TOKEN_KEY}-issued=1" \
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

# instance_durable_facts <instance-self-link>
# Fills DUR_AGE (seconds since GCE CREATED this instance), DUR_KEY
# (present|absent — whether $REG_TOKEN_KEY is on the instance right now) and
# DUR_ISSUED (present|absent — whether this instance was EVER handed a token).
# Returns non-zero if any could not be read, and the caller must then mint
# nothing: an unreadable fact is not a licence to guess.
#
# Both facts come from the GCE API on purpose. Everything else the mint path
# consults is a marker file under STATE_DIR or an age measured from THIS
# controller's own boot, and all of it lives on the controller's boot disk. A
# controller REPLACEMENT is therefore a single event that erases every guard at
# once, which is why a fourth marker file cannot be the answer here: it would be
# the same fact in the same place. These two survive the disk because they are
# not on it.
#
# host_age_seconds explains why the tick does not read creationTimestamp: that
# would be one describe per host per tick. This is not per tick — see the call
# site, which sits below both the `minted` marker and the failure cap.
instance_durable_facts() {
  local uri="$1" zone host created now keyrow k
  # Reset to the REFUSING pair, not to zero: every `return 1` below leaves these
  # behind, and a caller that ignored the return code would otherwise read the
  # most permissive answer this function can give. Same reasoning as the
  # file-scope defaults.
  DUR_AGE=999999999
  DUR_KEY="unknown"
  # DUR_ISSUED belongs in the reset for the same reason, and leaving it out was
  # worse than the other two: it is the only one of the three whose stale value
  # can be the PERMISSIVE one. A previous host's successful call leaves it
  # `absent`, and a `return 1` here would hand that answer to the next host —
  # "this instance was never issued a token" — about an instance nothing was
  # read from. The current caller checks the return code, so this is not a live
  # bug; it is the shape that makes the next caller's mistake unrecoverable.
  DUR_ISSUED="unknown"

  zone=${uri%/instances/*}
  zone=${zone##*/}
  host=${uri##*/}
  [ -n "$zone" ] && [ -n "$host" ] || return 1

  # A plain scalar projection, and `timeout` for the reason every gcloud call in
  # this file is bounded: gcloud has its own retry loop and can outlive a tick.
  created=$(timeout 60 gcloud compute instances describe "$host" \
    --project="$PROJECT" --zone="$zone" \
    --format="value(creationTimestamp)" 2>/dev/null) || return 1
  [ -n "$created" ] || return 1
  created=$(date -u -d "$created" +%s 2>/dev/null) || return 1
  case "${created:-}" in '' | *[!0-9]*) return 1 ;; esac

  now=$(date -u +%s)
  DUR_AGE=$((now - created))
  # Clock skew between this controller and the API must not read as "brand new
  # in the future"; the safe direction is old — and `0` is the opposite of old.
  # A negative age means this controller's clock is BEHIND the API's, so every
  # instance it sees is younger than it really is, and clamping the overflow to
  # 0 handed the most mint-permissive answer to exactly the hosts whose real age
  # is least knowable. Clamped to the same sentinel an unreadable fact gets:
  # `>= REGISTER_GRACE`, so the arm below refuses, and — if the key is somehow
  # still there — takes it back. The cost is that a badly-skewed controller
  # mints for nobody, which is an outage the recycle rule already bounds.
  [ "$DUR_AGE" -ge 0 ] || DUR_AGE=999999999

  # `--flatten` and NO `--filter`. `--filter` is a list-family flag; `describe`
  # rejects it with `unrecognized arguments` and exit 2, which this function
  # would report as "facts unreadable" for every host on every tick — so nothing
  # would ever be minted and no host would ever register. It shipped that way
  # and 51 passing checks did not see it, because the harness stubs `gcloud` as a
  # shell function that accepts any flag. Verified against a live instance
  # 2026-08-16: the projection below exits 0 and prints one metadata key per line.
  #
  # So the match happens here, as a whole line. A substring test would call
  # `<key>-old` a present key.
  if ! keyrow=$(timeout 60 gcloud compute instances describe "$host" \
    --project="$PROJECT" --zone="$zone" \
    --flatten="metadata.items[]" \
    --format="value(metadata.items.key)" 2>/dev/null); then
    return 1
  fi
  # Empty output at exit 0 is an ABSENT key, not an unreadable one: an instance
  # with no metadata at all flattens to nothing, and reporting that as a failure
  # would permanently refuse to mint for a genuinely key-less host — the same
  # never-registers outage in a smaller box. Only a non-zero exit returns 1.
  #
  # Both keys come out of the SAME list, so the third fact costs no extra call.
  # No `break`: the loop has to see every line now, and the two keys can arrive
  # in either order.
  DUR_KEY="absent"
  DUR_ISSUED="absent"
  while IFS= read -r k; do
    case "$k" in
      "$REG_TOKEN_KEY") DUR_KEY="present" ;;
      "${REG_TOKEN_KEY}-issued") DUR_ISSUED="present" ;;
    esac
  done <<EOF
$keyrow
EOF
  return 0
}

# registration_token_step <host> <self-link> <reg> <age-seconds> <status> <busy>
# The whole lifecycle in one function so it can be RUN by a self-test rather
# than read: the delete is a security property, and a property nothing executes
# is a comment.
#
# EXPIRY FIRST, THEN MINT, and the expiry rule does not consult `reg` at all.
# Deciding on `reg` alone is what shipped two High findings: `partial` shares a
# mint arm with `absent` while meaning a slot is already registered and may be
# running a job, and `unknown` — set for EVERY host at once whenever the runner
# list read fails, for as long as the outage lasts — refused to take anything
# back. `reg` describes GitHub's opinion of the agents; whether a live credential
# should still be sitting in a job-readable metadata key is a different question,
# and the answer is no as soon as the host is cordoned, busy, registered or out
# of time, whatever GitHub happens to be saying this tick.
registration_token_step() {
  local host="$1" uri="$2" reg="$3" age="$4" status="${5:-}" busy="${6:-0}"
  local minted="$STATE_DIR/regtoken-$host"
  local keylive="$STATE_DIR/regkey-$host"
  local cordon="$STATE_DIR/cordon-$host"
  local fails="$STATE_DIR/regfail-$host"
  local n why=""
  case "$busy" in *[!0-9]*) busy=0 ;; esac

  # --- expiry: one rule, and it runs on every reg state including `unknown` ---
  #
  #   registered   the token did its job.
  #   partial      a registered slot can already be executing a pull request,
  #                and that job reads this key. The host contract is that the
  #                startup script reads the key ONCE and configures every slot
  #                from that read, so a delete here cannot strand slot 2.
  #   busy         a job is running on this host right now. Strictly stronger
  #                than `partial`, and it is passed in rather than re-derived
  #                so the guard is structural.
  #   cordoned     agents deregistered on purpose; the host reads `absent`
  #                forever while the job it was running keeps going.
  #   past grace   not coming up. GitHub's own bound is an hour; ours is this.
  #
  # `unknown` is NOT an exemption. It means the runner list read failed, which
  # is a controller-side outage — this repo has seen 36 consecutive blind ticks
  # — and during it `cordon`, `busy` and `age` are all still known locally. Not
  # minting on a guess is right; refusing to take a credential back is not, and
  # the delete is idempotent so a needless one costs a call.
  if [ -f "$keylive" ]; then
    # Spelled as an if-chain, not `test && assign`, for the reason 151cfda gave:
    # a bare `a && b` whose `b` is a failing test leaves the whole LIST non-zero,
    # so the last such line becomes this function's exit status. The step is
    # called bare from the tick, and `registration_token_step … || …` is the
    # obvious next edit, at which point a host that simply matched no expiry
    # reason reads as a failure. (This file sets `set -uo pipefail`, line 26 —
    # NOT `-e` — so the risk is a wrong status, not an immediate exit.)
    if [ "$reg" = "present" ]; then
      why="agents registered"
    elif [ "$reg" = "partial" ]; then
      why="a slot registered"
    elif [ "$busy" -gt 0 ]; then
      why="a job is running"
    elif [ -f "$cordon" ]; then
      why="host cordoned"
    elif [ "$age" -ge "$REGISTER_GRACE" ]; then
      why="no agents after ${age}s"
    fi
    if [ -n "$why" ]; then
      if delete_registration_token "$uri"; then
        rm -f "$keylive"
        : >"$minted"
        log "regtoken $host: $why — $REG_TOKEN_KEY deleted"
      else
        log "regtoken $host: $why but $REG_TOKEN_KEY could not be deleted — retrying next tick"
      fi
    fi
    return 0
  fi

  # No local record that a key is live — but local records are lost (the sweep,
  # a replaced controller, a `timeout` on a write that committed).
  #
  # `present` AND `partial`. Restricting this to `present` was the gap: the
  # expiry chain above is gated on `[ -f "$keylive" ]`, so a host whose markers
  # went with a replaced controller has no expiry path at all, and `partial`
  # excluded here left it holding a LIVE key until GitHub expired it an hour
  # later — on a host where a registered slot may already be executing a pull
  # request that can read the key. A registered slot is the same proof `present`
  # gives that the token has done its job; the host contract is that the boot
  # script reads the key ONCE and configures every slot from that read, so
  # deleting cannot strand slot 2.
  #
  # `unknown` stays OUT, and deliberately. It is set for every host at once
  # whenever the runner list read fails, and deleting on it would strand a
  # genuinely booting host with no way to register. That case stays bounded by
  # GitHub's own hour, which is what the ADR already says.
  if { [ "$reg" = "present" ] || [ "$reg" = "partial" ]; } && [ ! -f "$minted" ]; then
    if delete_registration_token "$uri"; then
      : >"$minted"
      log "regtoken $host: $reg with no local record — $REG_TOKEN_KEY deleted"
    fi
    return 0
  fi

  # --- mint: `absent` ONLY ---
  #
  # Not `partial`. host_age_seconds is controller-local, so a replaced
  # controller reads every host as age 0; a SLOTS=2 host with slot 1 running a
  # pull request and slot 2 dead then reads `partial` indefinitely, and minting
  # for it writes a fresh hour-long credential into the metadata of the job on
  # slot 1. A host that is genuinely half-registered does not need a second
  # token — it already had one.
  [ "$reg" = "absent" ] || return 0

  # ONE token per instance. Each guard is a state this host could reach and must
  # not be handed a token in: already minted for, running a job, cordoned, not
  # actually booting, or past the grace at which the recycle rule deletes it.
  [ -f "$minted" ] && return 0
  [ "$busy" -gt 0 ] && return 0
  [ -f "$cordon" ] && return 0
  [ "$age" -ge "$REGISTER_GRACE" ] && return 0
  case "$status" in
    PROVISIONING | STAGING | RUNNING) ;;
    *) return 0 ;;
  esac

  # THREE attempts, then stop. A write that keeps failing re-mints once a tick,
  # and each attempt is a registration-token POST against the same App
  # installation the queue poll depends on — the secondary-rate-limit path this
  # file's header calls the blind-tick outage. Worse, the failure this retries
  # hardest is `timeout 60` on a setMetadata that COMMITTED, so each cycle parks
  # another live credential in job-readable metadata. The host is deleted at
  # REGISTER_GRACE regardless, so the retries buy nothing.
  n=$(cat "$fails" 2>/dev/null)
  case "${n:-0}" in *[!0-9]*) n=0 ;; *) n=${n:-0} ;; esac
  [ "$n" -ge 3 ] && return 0

  # --- the durable gate: the last question, and the only one not asked of disk --
  #
  # Every guard above is a marker file under STATE_DIR or an age measured from
  # this controller's own boot, and a controller REPLACEMENT defeats all five at
  # once. A host mid-job that was cordoned then reads: `minted` gone with the
  # disk, `cordon` gone with the disk, `age` 0 because host_age_seconds starts
  # at this controller's first sight of it, `busy` 0 because cordoning
  # deregistered its agents so GitHub reports no runners, and `absent` for the
  # same reason. Brand new, by every local measure, while it executes a pull
  # request — and the token would land in the metadata that job reads and sit
  # there for a whole REGISTER_GRACE, because the next tick sees `keylive` with
  # no expiry reason.
  #
  # So the last two questions are asked of the GCE API, which the controller
  # cannot lose with its disk. Not of a fourth marker file: that is the same
  # fact in the same place, and it is this same root cause that produced the
  # finding three times.
  # A failed read is CHARGED to the same three-attempt cap as a failed write.
  # It is the only refusal on this path that leaves no trace otherwise, and it
  # costs two instances.describe per host per tick — 6 a minute per host at
  # POLL=20 — for as long as the failure lasts, which for a project-wide API
  # outage means every host at once. The cap exists for exactly that.
  if ! instance_durable_facts "$uri"; then
    echo $((n + 1)) >"$fails"
    log "regtoken $host: instance facts unreadable (attempt $((n + 1)) of 3) — minting nothing this tick"
    return 0
  fi

  # THIS HOST IS NOT NEW — and this is asked BEFORE adoption, on purpose.
  #
  # Past the grace by its real creation time, it is not a host that is still
  # booting, whatever this controller's own clock says. Adopting first and
  # letting the expiry rule catch it next tick was the earlier shape, and it
  # meant the controller could learn from the API that an instance is an hour
  # old, write `keylive`, and then hold that live credential for a further whole
  # REGISTER_GRACE — because the expiry chain runs above any durable read and
  # only ever sees the controller-local `age`, which a replacement reset to 0.
  #
  # One rule, not two: the delete happens here, where the evidence is. Teaching
  # the expiry arm to read DUR_AGE instead would mean a describe per host per
  # tick for as long as any key is live, which is exactly the cost
  # host_age_seconds documents refusing.
  if [ "$DUR_AGE" -ge "$REGISTER_GRACE" ]; then
    if [ "$DUR_KEY" = "present" ]; then
      if delete_registration_token "$uri"; then
        rm -f "$keylive"
        : >"$minted"
        log "regtoken $host: created ${DUR_AGE}s ago and still carrying $REG_TOKEN_KEY — deleted"
      else
        # The key is still out there. `keylive` so the expiry rule keeps trying,
        # and NO `minted`: claiming the work is done is the one outcome a failed
        # delete must never produce.
        : >"$keylive"
        log "regtoken $host: created ${DUR_AGE}s ago, delete of $REG_TOKEN_KEY FAILED — will retry"
      fi
    else
      : >"$minted"
      log "regtoken $host: created ${DUR_AGE}s ago, not booting — no token minted"
    fi
    return 0
  fi

  # THIS HOST ALREADY HAS A KEY, and is still within grace. Adopt it rather than
  # mint a second: writing `keylive` hands it to the expiry rule above, which is
  # the only code that ever deletes it, and which will run on the next tick with
  # the reasons this controller does still know.
  if [ "$DUR_KEY" = "present" ]; then
    : >"$keylive"
    log "regtoken $host: $REG_TOKEN_KEY already on the instance — adopted, not re-minted"
    return 0
  fi

  # ONE TOKEN PER INSTANCE, EVER — and this is the durable form of the `minted`
  # marker, which is why it is asked last, right before the write it guards.
  #
  # The age gate above only protects a host that is OLD. It leaves the young one:
  # an instance created 30s ago that registered, was cordoned or lost its agents
  # mid-job, and had its token correctly deleted by the previous controller. To a
  # replacement controller that host reads `absent` (cordoning deregistered the
  # agents), `busy=0` (same reason), `age=0` (host_age_seconds starts at this
  # controller's first sight of it), no markers (they went with the boot disk),
  # DUR_AGE under the grace and DUR_KEY genuinely absent — every guard satisfied,
  # and indistinguishable from a host that has simply never registered. Minting
  # writes a fresh hour-long credential into the metadata of the job it is
  # running, which is the exact interception this whole path exists to prevent.
  #
  # The instance's own metadata is what tells the two apart, because the write
  # put the marker there in the same setMetadata as the token and nothing ever
  # removes it. `!= absent`, not `= present`: an unfillable fact is `unknown`,
  # and the safe reading of "I could not tell whether this host already had one"
  # is that it did.
  if [ "$DUR_ISSUED" != "absent" ]; then
    : >"$minted"
    log "regtoken $host: already issued a token once (${REG_TOKEN_KEY}-issued) — not minting a second"
    return 0
  fi

  if write_registration_token "$uri" "$keylive"; then
    : >"$minted"
    rm -f "$fails"
    log "regtoken $host: minted and written to $REG_TOKEN_KEY"
  else
    printf '%s' "$((n + 1))" >"$fails"
    log "regtoken $host: $REG_TOKEN_KEY could not be written (attempt $((n + 1)) of 3)"
  fi
  return 0
}

# --- the second delete gate, per OS ------------------------------------------
#
# instance_host_os <host> <zone> -> linux | windows | absent | unknown
#
# READ FROM THE HOST, NOT FROM THIS CONTROLLER'S OWN METADATA.
#
# The controller carries `ci-host-os` too, and using it would cost nothing. It
# would also be wrong for the one window in which this matters. `ci-host-os`
# lives on the INSTANCE TEMPLATE, and a template change is applied to a running
# MIG host by host: during any rollout — including the one that introduces the
# key — the pool holds hosts from two templates at once, and the controller's
# own metadata describes neither of them reliably (it is updated by the same
# apply, and a controller is not restarted in step with its hosts). Asking each
# host what it is turns a confident wrong answer into a per-host fact. The cost
# is one describe per drain, on a path that already spends a list and an ssh.
#
# `absent` and `unknown` are SEPARATE answers and conflating them deadlocks the
# fleet. `unknown` is "we did not get an answer" — no zone, or the describe
# failed — and it is transient. `absent` is a definite answer: the describe
# SUCCEEDED and this instance carries no `ci-host-os` at all, i.e. it predates
# the template that publishes the key. Every host running today is `absent`, and
# because the autoscaler is ONLY_UP, `update_policy` is OPPORTUNISTIC and
# drain_host() is the only code path that deletes a host, an `absent` host that
# is never drained is never replaced and so is never given the key. Treating
# `absent` as undeterminable closes that loop and pins the pool at max hosts
# forever. The caller resolves it; see the fallback arm in drain_host().
#
# `--format=json(metadata)` plus jq rather than a flattened key/value
# projection: metadata VALUES are arbitrary text and the boot script is tens of
# kilobytes of it, containing both commas and newlines, so any line-oriented
# CSV/TSV parse of key+value is decided by the contents of somebody's shell
# script. JSON escapes them and jq is already a hard dependency here.
instance_host_os() {
  local host="$1" zone="$2" json os
  if [ -z "$host" ] || [ -z "$zone" ]; then echo "unknown"; return 0; fi

  json=$(timeout 60 gcloud compute instances describe "$host" \
    --project="$PROJECT" --zone="$zone" \
    --format="json(metadata)" 2>/dev/null) || { echo "unknown"; return 0; }

  # `[...][0]` rather than a `| head -1`: under `pipefail` head closes the pipe
  # on the first line and jq dies of SIGPIPE, which would turn a perfectly good
  # read into a failure some of the time, depending on buffering.
  os=$(printf '%s' "$json" \
    | jq -r '[.metadata.items[]? | select(.key == "ci-host-os") | .value][0] // ""' 2>/dev/null)

  case "$os" in
    linux | windows) echo "$os" ;;
    # Empty means the key is not there — a definite fact from a successful read.
    # Any OTHER value is a key this controller does not understand, which is not
    # a pre-key host and gets no fallback: `unknown`, and the host is kept.
    '') echo "absent" ;;
    *) echo "unknown" ;;
  esac
  return 0
}

# beacon_gate <host> <zone> <registrations> -> the beacon_decision() verdict
#
# The Windows half of the second gate: all of the I/O, none of the rule. The
# rule is beacon_decision(), which ships unit-tested one release ahead of this
# call site precisely so the code that deletes a machine is the code that was
# proven.
#
# NO INBOUND PATH. The host publishes outbound into its own guest attributes and
# this reads them through the same compute API the controller already calls —
# no sshd, no IAP firewall rule, no admin session onto a box running
# pull-request code.
#
# ONE call for the whole namespace, not one per key: guest attributes are rate
# limited to 10 queries per minute per instance, and manufacturing that limit on
# the busy pool would present as read-failed, which is a keep — a drain that
# stops working when the fleet gets busy.
beacon_gate() {
  local host="$1" zone="$2" regs="$3"
  local raw rc line key val present=0 workers="" ts_raw="" ts=0 now age misses
  local mf="$STATE_DIR/beaconmiss-$host"

  raw=$(timeout 60 gcloud compute instances get-guest-attributes "$host" \
    --project="$PROJECT" --zone="$zone" --query-path="$BEACON_NS/" \
    --format="csv[no-heading](key,value)" 2>/dev/null)
  rc=$?

  # FIRST occurrence of each key wins. Guest attributes are writable by any
  # process on the VM, job code included — Google documents this plainly — so
  # the reader must not let a later line overwrite an earlier one.
  #
  # `present` is set by SEEING the key, not by liking its value: an empty or
  # malformed count is a broken publisher, and beacon_decision() answers `keep`
  # for it. Treating it as absent would hand it to the never-booted arm instead.
  while IFS= read -r line; do
    key=${line%%,*}
    val=${line#*,}
    case "$key" in
      workers) [ "$present" = "1" ] || { present=1; workers="$val"; } ;;
      ts) [ -n "$ts_raw" ] || ts_raw="$val" ;;
    esac
  done <<EOF
$raw
EOF

  now=$(date -u +%s)
  if [ -n "$ts_raw" ]; then
    ts=$(date -u -d "$ts_raw" +%s 2>/dev/null) || ts=0
    # A negative epoch carries a `-` and is caught here, which is what the rule
    # wants: 0 means "the caller could not parse it", and keeps.
    case "${ts:-}" in '' | *[!0-9]*) ts=0 ;; esac
  fi

  age=$(host_age_seconds "$host")

  misses=$(cat "$mf" 2>/dev/null)
  case "${misses:-}" in '' | *[!0-9]*) misses=0 ;; esac

  # The counter advances on the ONE branch it belongs to — a read that SUCCEEDED
  # and found no beacon — and is cleared by anything else, so a failed read can
  # never accumulate towards a deletion. Written after the verdict so this tick
  # is judged on the count it entered with.
  local verdict
  verdict=$(beacon_decision "$rc" "$present" "$workers" "$ts" "$now" \
    "$BEACON_INTERVAL" "$age" "$REGISTER_GRACE" "$regs" "$misses" \
    "$ORPHAN_CONFIRM_TICKS")

  if [ "$rc" = "0" ] && [ "$present" != "1" ]; then
    printf '%s' "$((misses + 1))" >"$mf"
  else
    rm -f "$mf"
  fi

  printf '%s' "$verdict"
  return 0
}

# pin_hold_gate <host> <host_uri> -> the pin_hold_decision() verdict
#
# The veto's I/O, and the monotonic cache it is taken against. The rule is
# pin_hold_decision(); everything here is the round trip and the file.
#
# Called ONLY for a host the controller has already decided to remove. That is
# the whole reason the hold is a veto on the verdict rather than an argument to
# it: recycle_decision() is consulted for every host on every tick, and a hold
# passed as an argument would cost a guest-attribute read per host per tick --
# straight into the 10-queries-per-minute-per-instance limit, on the busy pool,
# where manufacturing that limit presents as read-failed and read-failed keeps.
#
# THE CACHE IS THE SECURITY PROPERTY. `$STATE_DIR/pinhold-<host>` holds the
# greatest expiry this controller has ever seen for the host, and the verdict is
# taken against that -- so a co-tenant job on another slot can only ever extend
# a hold, never shorten one. See pin-hold-decision.sh for what shortening one
# would otherwise buy an attacker.
pin_hold_gate() {
  local host="$1" uri="$2"
  local zone raw rc line key val present=0 hold_raw=""
  local cf="$STATE_DIR/pinhold-$host"
  local cached c_run="" c_exp=0 now verdict m_run m_exp

  # No self-link, no zone, and a guessed zone addresses some other machine. The
  # read cannot happen, so this reads exactly as the read failing: keep.
  zone=${uri%/instances/*}
  zone=${zone##*/}
  if [ -z "$uri" ] || [ -z "$zone" ]; then
    printf '%s' "hold:run= expiry=0 no-zone"
    return 0
  fi

  # The WHOLE namespace in one call, like beacon_gate, and not
  # `--query-path=ci/pin-hold`: a query path naming a key that is not there
  # exits NON-ZERO, which this rule reads as "we did not get an answer" and
  # answers by keeping the host. Every unheld host in the fleet would then be
  # undeletable. Asked for the namespace, an absent key is a successful read
  # that returns no row -- a fact, and the fact the free path needs.
  raw=$(timeout 60 gcloud compute instances get-guest-attributes "$host" \
    --project="$PROJECT" --zone="$zone" --query-path="$BEACON_NS/" \
    --format="csv[no-heading](key,value)" 2>/dev/null)
  rc=$?

  # FIRST occurrence wins, for the same reason beacon_gate does it: guest
  # attributes are writable by any process on the VM, job code included, and a
  # later row must not overwrite an earlier one within a single read.
  while IFS= read -r line; do
    key=${line%%,*}
    val=${line#*,}
    case "$key" in
      "$PIN_HOLD_KEY") [ "$present" = "1" ] || { present=1; hold_raw="$val"; } ;;
    esac
  done <<PIN_ATTR_EOF
$raw
PIN_ATTR_EOF

  cached=$(cat "$cf" 2>/dev/null)
  c_run=${cached%% *}
  c_exp=${cached##* }

  now=$(date -u +%s)
  verdict=$(pin_hold_decision "$rc" "$present" "$hold_raw" "$c_run" "$c_exp" \
    "$now" "$PIN_HOLD_MAX")

  # The cache is written only from a read that SUCCEEDED. A failed read is not
  # evidence about a hold in either direction, and letting it rewrite the file
  # would let one API blip either forget a live hold or freeze a dead one.
  if [ "$rc" = "0" ]; then
    case "$verdict" in
      hold:*)
        m_run=${verdict#*run=}
        m_run=${m_run%% *}
        m_exp=${verdict#*expiry=}
        m_exp=${m_exp%% *}
        # A malformed publish with nothing cached yields expiry=0: it holds this
        # host for this tick, and it deliberately leaves no record behind.
        case "$m_exp" in
          '' | 0 | *[!0-9]*) ;;
          *) printf '%s %s' "$m_run" "$m_exp" >"$cf" ;;
        esac
        ;;
      *) rm -f "$cf" ;;
    esac
  fi

  printf '%s' "$verdict"
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

  # Counted BEFORE the deregistrations below, because after them GitHub's list
  # is empty by construction. beacon_decision() reads this to tell "the boot
  # script never ran" apart from "the publisher is broken on a host that DID
  # register" — and asking GitHub after the drain answers 0 for both.
  local regs
  regs=$(printf '%s\n' "$ids" | grep -c '[0-9]')

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

  # WHICH question to ask is a property of the HOST. See instance_host_os().
  local host_os="unknown"
  if [ -n "$zone" ]; then
    host_os=$(instance_host_os "$host" "$zone")
  fi

  # TRANSITIONAL, AND REMOVABLE. Delete this arm — and `absent` with it — once no
  # host can predate `ci-host-os`; ci_worker_gate_os_fallback reading zero across
  # every pool for a full recycle window is the evidence that day has come.
  #
  # A host that carries no `ci-host-os` was built from the template that existed
  # before the key, and on this pool that template is the controller's own OS:
  # one MIG, one instance template, one `var.host_os`, published to the hosts and
  # to the controller from the same variable. Without this arm the pool cannot
  # scale in at all — see instance_host_os() for why that state is permanent
  # rather than transient — and for a Linux pool the fallback is the gate that
  # `main` runs today, so it is not a new risk, it is the absence of a new one.
  #
  # It is NOT the inference PR 7 refuses. That one was "a missing key means
  # linux" with nothing else to go on. This is scoped to a template generation
  # that is provably Linux-only: Windows pools did not exist before the key, so
  # an absent key on a Windows controller is anomalous and keeps.
  if [ "$host_os" = "absent" ]; then
    if [ "$CONTROLLER_HOST_OS" = "linux" ]; then
      log "drain $host: LEGACY HOST — no ci-host-os on the instance, resolving to linux from this controller's own ci-host-os; it will carry the key once this delete replaces it"
      WORKER_GATE_OS_FALLBACK=$((WORKER_GATE_OS_FALLBACK + 1))
      host_os="linux"
    else
      log "drain $host: no ci-host-os on the instance and this controller is ci-host-os=$CONTROLLER_HOST_OS, which cannot predate the key — leaving host up"
      host_os="unknown"
    fi
  fi

  if [ "$host_os" = "windows" ]; then
    local verdict
    verdict=$(beacon_gate "$host" "$zone" "$regs")
    case "$verdict" in
      delete:*)
        log "drain $host: beacon gate clear ($verdict)"
        WORKER_GATE_CLEAR=$((WORKER_GATE_CLEAR + 1))
        ;;
      *)
        log "drain $host: $verdict — leaving host up"
        WORKER_GATE_HELD=$((WORKER_GATE_HELD + 1))
        DRAIN_ABORTED=$((DRAIN_ABORTED + 1))
        return 1
        ;;
    esac
  elif [ "$host_os" != "linux" ]; then
    # FAIL CLOSED, and this is a deliberate change to the Linux path's DEGRADED
    # case. Until now an unreadable zone skipped the second gate entirely and
    # the host was deleted anyway — a delete on a host nothing had been able to
    # ask about. There is now a second way to arrive here (the OS itself is
    # unreadable), and both answers are the same one: an unknown host is kept.
    # A wrong keep bills for one host until the next tick; a wrong delete costs
    # up to slots_per_host merge-blocking jobs, and nobody finds out from here.
    log "drain $host: cannot establish how to ask this host for live workers (ci-host-os=$host_os, zone=${zone:-unknown}) — leaving host up"
    WORKER_GATE_UNDETERMINED=$((WORKER_GATE_UNDETERMINED + 1))
    DRAIN_ABORTED=$((DRAIN_ABORTED + 1))
    return 1
  fi

  if [ "$host_os" = "linux" ]; then
    local workers
    workers=$(gcloud compute ssh "$host" --zone="$zone" --project="$PROJECT" \
      --tunnel-through-iap --command 'pgrep -fc "Runner.Worker" || true' \
      2>/dev/null | tr -d '[:space:]')
    if [ -n "$workers" ] && [ "$workers" != "0" ]; then
      log "drain $host: $workers job worker(s) still alive after deregistration — leaving host up"
      WORKER_GATE_HELD=$((WORKER_GATE_HELD + 1))
      DRAIN_ABORTED=$((DRAIN_ABORTED + 1))
      return 1
    fi
    WORKER_GATE_CLEAR=$((WORKER_GATE_CLEAR + 1))
  fi

  gcloud compute instance-groups managed delete-instances "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --instances="$host" >>"$LOG" 2>&1 || {
      log "drain $host: delete-instances failed"
      return 1
    }

  # pinhold- goes with them. The host reached this line only because its hold
  # was absent or lapsed -- a live one vetoes the verdict that calls drain_host
  # -- so nothing is being forgotten, and a leftover file would be a veto with
  # no host to apply to.
  rm -f "$STATE_DIR/idle-$host" "$STATE_DIR/seen-$host" "$STATE_DIR/beaconmiss-$host" \
    "$STATE_DIR/pinhold-$host"
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

# tick — one pass over the whole REPOSITORY, then one pass per pool.
#
# The split is the point of this file. Everything GitHub can answer once for the
# repository — the runner list, the demand sweep, the outcome sweep — is done
# once here, and each pool's own work runs against the results. Four pools cost
# one repository's worth of API calls, which is what makes four pools possible
# at all: the alternative, four controllers, is four times the polling against
# an installation rate limit that all of them share.
tick() {
  local tick_start
  tick_start=$(date +%s)

  # A blind tick is not an error, it is a SUSPENSION: every host reads
  # reg=unknown, so nothing drains, in EVERY pool. One is unremarkable; a run of
  # them is a fleet pinned at its current size, billing for hosts nobody is
  # using, while the heartbeat keeps publishing 1 and every dashboard stays
  # green. The counter is what makes the difference visible — it is published on
  # every tick, and an alert on it fires on the run, not on the single blip.
  if collect_runners; then
    BLIND_TICKS=0
  else
    BLIND_TICKS=$((BLIND_TICKS + 1))
    log "GitHub runner list unavailable this tick (status=$RUNNER_LIST_STATUS, consecutive=$BLIND_TICKS) — every host reads reg=unknown and nothing will be drained (fail-safe)"
  fi

  collect_demand

  # Deliberately BEFORE the pool loop, unlike the single-pool controller that
  # ran it last. It is still the work nothing waits on — no host is drained and
  # no MIG resized on what it finds — but with N pools the flush is now shared,
  # so running it last would delay the flush for every pool rather than for the
  # one it belongs to. It carries its own budget and its own interval; on most
  # ticks it returns immediately.
  collect_outcomes

  local p
  for p in "${POOLS[@]}"; do
    pool_select "$p"
    tick_pool
  done

  # The controller-wide facts, published under EVERY pool's label. A pool whose
  # series simply stop is indistinguishable from a pool that went idle, so each
  # one carries its own copy of the heartbeat and of the two counters that say
  # whether this tick could see GitHub at all.
  local tick_seconds
  tick_seconds=$(( $(date +%s) - tick_start ))
  for p in "${POOLS[@]}"; do
    pool_select "$p"
    queue_controller_series "$tick_seconds"
    queue_outcome_series
  done

  # One request per tick, every pool's series together.
  flush_series
}

# tick_pool — everything that is true of ONE pool. Unchanged from the
# single-pool controller except that it no longer sweeps GitHub or flushes:
# pool_select() has already written the globals it reads.
tick_pool() {
  DRAINED=0
  DRAIN_ABORTED=0
  REAPED=0
  CORDONED=0
  RETIRED=0
  WORKER_GATE_CLEAR=0
  WORKER_GATE_HELD=0
  WORKER_GATE_UNDETERMINED=0
  WORKER_GATE_OS_FALLBACK=0
  PIN_HELD=0

  collect_hosts
  # AFTER collect_hosts, and that ordering is the whole reason this is not part
  # of collect_demand: classify_pinned decides whether a pinned run is servable,
  # which is a question about which hosts are alive.
  classify_pinned
  collect_mig

  local pool_size=0 slots_busy=0 idle_max=0 draining=0 stale_hosts=0
  local host status host_tpl host_uri busy idle age verdict hold tpl cordoned recycling

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
  #
  # AND THE STATE DIRECTORY IS NOW SHARED BY EVERY POOL. `live_hosts` is this
  # pool's host list, so an unscoped sweep would read every OTHER pool's markers
  # as belonging to hosts that no longer exist and delete them — handing back
  # recycle budget across the whole controller and, worse, forgetting that a
  # live registration token is sitting in another pool's instance metadata. Only
  # markers whose host name this pool's MIG could have created are considered,
  # and if the MIG's base name could not be read, nothing is swept at all.
  for f in "$STATE_DIR"/cordon-* "$STATE_DIR"/regtoken-* "$STATE_DIR"/regkey-* \
    "$STATE_DIR"/regfail-* "$STATE_DIR"/beaconmiss-* "$STATE_DIR"/pinhold-*; do
    [ -n "$live_hosts" ] || break
    [ -n "$MIG_BASE" ] || break
    [ -e "$f" ] || continue
    mname=$(basename "$f")
    mname=${mname#cordon-}
    mname=${mname#regtoken-}
    mname=${mname#regkey-}
    mname=${mname#regfail-}
    mname=${mname#beaconmiss-}
    mname=${mname#pinhold-}
    case "$mname" in "$MIG_BASE"-*) ;; *) continue ;; esac
    case $'\n'"$live_hosts"$'\n' in
      *$'\n'"$mname"$'\n'*) ;;
      *) rm -f "$f" ;;
    esac
  done
  # Scoped to this pool's own hosts, for the same reason the sweep above is: the
  # recycle budget is per pool, and counting the whole controller's cordons
  # would let one pool's rollout stop every other pool from rolling out at all.
  # With no base name to scope by, the budget reads as fully spent — a pool that
  # cannot count its own cordons must not start new ones.
  if [ -n "$MIG_BASE" ]; then
    recycling=$(find "$STATE_DIR" -maxdepth 1 -name "cordon-$MIG_BASE-*" 2>/dev/null | wc -l)
  else
    recycling="$RECYCLE_MAX_UNAVAILABLE"
  fi

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
    # registration token now, and a host that has registered — or is running a
    # job, or was cordoned, or ran out of time — needs the key gone now. Both
    # are no-ops on a pool that mints on the host, and both are skipped when the
    # MIG did not report a self-link, because without a zone there is no
    # instance to address and a guessed one is a call against some other
    # machine.
    #
    # `busy` is passed rather than re-derived inside the step: it is the
    # strongest single statement that job code is executing on this host right
    # now, and the step's expiry rule is the one place that has to be certain of
    # it. It is read from HOST_BUSY above, after host_facts.
    if [ "$MINT_REG" = "true" ] && [ -n "$host_uri" ]; then
      registration_token_step "$host" "$host_uri" "$HOST_REG" "$age" "$status" "$busy"
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

    # THE PIN HOLD VETO, first half. A cordon is not "less than" a delete here:
    # it deregisters the host's idle agents, and a cordoned host stops answering
    # its own affinity label while the run pinned to it still has jobs to place.
    # A hold wired only into the drain path would be bypassed entirely by a
    # stale-template recycle.
    case "$verdict" in
      cordon:* | retire:*)
        hold=$(pin_hold_gate "$host" "$host_uri")
        case "$hold" in
          hold:*)
            log "$host: $verdict -- VETOED by pin hold ($hold)"
            PIN_HELD=$((PIN_HELD + 1))
            continue
            ;;
        esac
        ;;
    esac

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

    # THE PIN HOLD VETO, second half. Same gate, same cache, the other path.
    case "$verdict" in
      drain:*)
        hold=$(pin_hold_gate "$host" "$host_uri")
        case "$hold" in
          hold:*)
            log "$host: $verdict -- VETOED by pin hold ($hold)"
            PIN_HELD=$((PIN_HELD + 1))
            continue
            ;;
        esac
        ;;
    esac

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

  queue_series "ci_demand" "$DEMAND_TOTAL"
  # Deliberately a SEPARATE series and not part of ci_demand: the autoscaler
  # consumes ci_demand, and a pinned job cannot be served by the host it would
  # buy. Published so that "the pool looks idle" and "the pool is full of work
  # nothing can scale for" stop reading identically on a dashboard.
  queue_series "ci_demand_pinned" "${DEMAND_PINNED:-0}"
  queue_series "ci_pinned_runs_cancelled" "${PIN_ORPHANED:-0}"
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
  # The SECOND delete gate, split out of ci_drain_verdicts because "aborted"
  # cannot distinguish the three things that stop a delete here, and only one of
  # them is the system working. `held` is the gate doing its job — a worker is
  # alive. `undetermined` is the gate UNABLE to do its job: the host's OS or its
  # facts could not be read, so the controller fails closed and keeps a host it
  # cannot ask about. Sustained non-zero `undetermined` is scale-in quietly
  # suspended on hosts that all look healthy, which is the shape of every outage
  # this controller has had; it is the value to alert on. Per-tick deltas, like
  # ci_drain_verdicts — align with a sum over the window, never a mean.
  queue_series "ci_worker_gate_verdicts" "$WORKER_GATE_CLEAR" '"outcome":"clear"'
  queue_series "ci_worker_gate_verdicts" "$WORKER_GATE_HELD" '"outcome":"held"'
  queue_series "ci_worker_gate_verdicts" "$WORKER_GATE_UNDETERMINED" '"outcome":"undetermined"'
  # Removals this pool decided on and then did not carry out because the host
  # was pinned. Not an error and not a drain: it is scale-in deliberately
  # deferred, and the series exists so "the pool will not shrink" and "the pool
  # is holding hosts for runs in flight" stop reading identically. Sustained
  # non-zero with no pinned demand is a hold that is not lapsing -- the shape a
  # forged or abandoned hold would have, bounded by PIN_HOLD_MAX either way.
  queue_series "ci_pin_holds_honoured" "${PIN_HELD:-0}"
  # Not a fourth `outcome`: a fallback host goes on to reach `clear` or `held`
  # like any other, so folding it into that label set would double-count. It is
  # the countdown on a transitional arm — see drain_host(). Zero across every
  # pool for a full recycle window means no host predates `ci-host-os` any more
  # and the arm can be deleted; non-zero long after a rollout means a pool is not
  # recycling and its hosts are still being resolved by inference.
  queue_series "ci_worker_gate_os_fallback" "$WORKER_GATE_OS_FALLBACK"
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
}

# queue_controller_series <tick_seconds> — the facts that belong to the
# CONTROLLER rather than to a pool, published once per pool so that every pool
# carries its own heartbeat and its own "could this tick see GitHub" counters.
# Duplicated on purpose: a pool whose series merely stop reads as an idle pool.
queue_controller_series() {
  local tick_seconds="${1:-0}"
  # Heartbeat is published on EVERY tick including a bad one, so "no data" on
  # this series means the controller is down — a distinct alert from "the pool
  # is idle", which the other series cannot distinguish on their own.
  queue_series "ci_poller_heartbeat" "1"
  # Pools the table refused. Non-zero means this controller is serving fewer
  # pools than it was configured with, and the pool that is missing has no
  # series of its own to go absent — this is the only place it is visible.
  queue_series "ci_pool_table_rejected" "$POOL_TABLE_REJECTED"
  # Published on EVERY tick, 0 included — a series that only appears when broken
  # is indistinguishable from a controller that stopped publishing, which is the
  # confusion this whole fleet keeps paying for. 0 means "the last tick could see
  # GitHub"; N means scale-in has been suspended for N consecutive ticks.
  queue_series "ci_runner_list_blind_ticks" "$BLIND_TICKS"
  # How long this tick took, end to end. The fleet had no series for it and paid
  # for that: a tick growing past the watchdog threshold is a controller about to
  # be restarted mid-tick forever, and the only visible symptom was every OTHER
  # series going absent at once.
  #
  # It is the WHOLE controller's tick, not this pool's share of it, and every
  # pool reports the same number — because the number the watchdog threshold is
  # compared against is the whole loop. A per-pool split would be four values
  # none of which can be alerted on.
  queue_series "ci_tick_seconds" "$tick_seconds"
  # >0 means ci_demand is a lower bound this tick, so a pool that looks
  # under-scaled may simply not have been counted. Controller-wide: the sweep is
  # shared, so a run skipped for budget is skipped for every pool.
  queue_series "ci_demand_runs_skipped" "$DEMAND_RUNS_SKIPPED"
  # Published on every tick, 0 included — it is what makes an ABSENT
  # ci_jobs_completed readable as "no jobs finished" rather than "the outcome
  # sweep never got to them".
  queue_series "ci_outcome_runs_skipped" "$OUTCOME_RUNS_SKIPPED"
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
