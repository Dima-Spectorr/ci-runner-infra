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

# beat — "the loop moved". The watchdog's only input, written at every point in
# a tick where progress can be proven.
#
# WHY THE TICK WRITES IT AND NOT ONLY THE LOOP AROUND IT (2026-09-03)
#
# The heartbeat used to be written twice, both times in run_loop(): once before
# the tick and once after. That makes its age equal to the ELAPSED TIME OF THE
# CURRENT TICK, so a tick that legitimately outruns the watchdog threshold is
# indistinguishable from a wedge — and the restart the watchdog then issues
# kills the tick before it can finish, which is the loop watchdog-decision.sh
# was written to break. The uptime grace added there did not break that loop, it
# PACED it:
#
#   restart -> hold:restarted-70s -> 140s -> 210s -> 280s -> restart -> ...
#
# The IntegrateIT controller ran exactly that on 2026-09-03: one restart every
# 350s for 54 minutes, and four such windows in three days. `NRestarts=0`
# throughout (the watchdog calls `systemctl restart`, so systemd's own counter
# never moves), the unit `active (running)`, and NOT ONE metric published —
# every series is queued during the tick and flushed at its end, so a tick that
# is always killed flushes nothing. What reached the humans was
# `ci_poller_heartbeat` absent for 10m: an alert that says "the controller is
# dead" about a controller whose only problem was that its own watchdog would
# not let it finish a tick.
#
# So the heartbeat now means "a phase of the tick completed", not "a tick
# completed". A slow tick keeps it fresh, because a slow tick is still moving; a
# tick blocked on one call still ages it out, because nothing between two phases
# writes it and every call in this file is bounded. The watchdog rule itself is
# unchanged — it was never the half that was wrong.
beat() {
  date +%s >"$STATE_DIR/heartbeat" 2>/dev/null || true
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
# The branch the merge queue admits. Read here rather than assumed, because the
# parking sweep compares every open pull request's base against it and a wrong
# value would report the whole repository as parked. Defaulted in the shell and
# not only in Terraform: a controller rendered before this key existed has no
# such attribute, and `md` returns the empty string for one that is absent —
# which would make every base comparison unequal.
QUEUE_BASE=$(md "instance/attributes/ci-queue-base")
: "${QUEUE_BASE:=main}"

# Empty unless the root turned autohealing on. NO DEFAULT, deliberately — the
# other way round from QUEUE_BASE above. An absent attribute must mean "do not
# listen": this is the machine holding the App installation token, and a
# defaulted port would open a socket on every controller in the fleet to answer
# a probe nobody configured.
HEALTH_PORT=$(md "instance/attributes/ci-health-port")
case "$HEALTH_PORT" in
  '' | *[!0-9]*) HEALTH_PORT="" ;;
esac

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
declare -A P_MATCH_JSON=() P_MATCH_CSV=()

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
  # THE SET WE CONFIGURE IS NOT THE SET THE AGENT ANSWERS TO, and the difference
  # is why this fleet's `ci_demand` was structurally 0 on every pool. The runner
  # registers three labels of its own that no `--labels` argument produces and
  # none of ours can remove -- GitHub calls them `read-only`: `self-hosted`, the
  # OS (`Linux`/`Windows`), and the architecture (`X64`). Every workflow in the
  # fleet asks for `[self-hosted, linux, gcp, <Repo>]`; the configured list has
  # no `linux` in it at all, so the subset test left `["linux"]` over, counted
  # nothing, and the autoscaler was handed a flat zero while jobs queued for
  # hours in front of idle slots. Only `min_hosts` and the warm schedules ever
  # moved a pool.
  #
  # Case is the second half of the same bug: GitHub dispatches
  # case-insensitively, so `linux` and `Linux` are one label to it and two to a
  # jq `-`. Adding the read-only labels WITHOUT folding fixes nothing. Both
  # sides are folded here and at every comparison downstream.
  #
  # `X64` is derived and not read back off a registered runner on purpose: a
  # pool with no live runner would report an empty match set, count no demand,
  # and never buy the host that would have registered one -- a deadlock that
  # only an operator could break. It is correct for every machine type this
  # module can create; an arm64 pool would need this to follow the machine type.
  P_MATCH_JSON["$p_name"]=$(printf '%s' "$p_labels" | jq -R -c --arg os "$p_hostos" '
    (if ($os | ascii_downcase) == "windows" then "Windows" else "Linux" end) as $osl
    | split(",") + ["self-hosted", $osl, "X64"]
    | map(select(length > 0) | ascii_downcase) | unique')
  P_MATCH_CSV["$p_name"]=$(printf '%s' "${P_MATCH_JSON[$p_name]}" | jq -r 'join(",")')
done <<<"$pool_rows"

# The MATCH sets of every pool at once, as {pool: [folded labels]}. The demand
# sweep fetches a run's job list ONCE and asks jq which pools each job belongs
# to — the entire reason a repository can have four pools without paying for
# four controllers' worth of API calls.
#
# P_MATCH_JSON and not P_LABELS_JSON: what a job can be routed to is decided by
# what the AGENT registers, which is the configured list plus the runner's own
# read-only labels, compared case-insensitively. P_LABELS_JSON stays exactly
# what `config.sh --labels` was given, because that parity is what keeps the
# host and the controller talking about the same pool.
POOLS_MATCH_MAP=$(
  {
    for p in "${POOLS[@]}"; do
      jq -n -c --arg p "$p" --argjson l "${P_MATCH_JSON[$p]}" '{($p): $l}'
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
  RUNNER_MATCH_LABELS="${P_MATCH_CSV[$POOL]}"
  POOL_LABELS_JSON="${P_LABELS_JSON[$POOL]}"

  MIG_BASE=""
  MIG_TARGET=0
  MIG_TEMPLATE=""

  DEMAND_TOTAL="${D_TOTAL[$POOL]:-0}"
  DEMAND_QUEUED="${D_QUEUED[$POOL]:-0}"
  QUEUE_WAIT_MAX="${D_WAIT[$POOL]:-0}"
  RUNNING_MAX="${D_RUNNING[$POOL]:-0}"
  DEMAND_EXPIRED="${D_EXPIRED[$POOL]:-0}"
  POOL_JOBS_PER_CHECK="${Q_JPC[$POOL]:-1}"
}

# The per-pool globals pool_select writes, declared at file scope so that a read
# before the first select cannot kill the tick under `set -u`.
POOL=""
DEMAND_EXPIRED=0
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
# Read in tick_pool: the role is what decides whether a pool publishes the
# merge-queue series at all. It arrived with PR3 unread by this file; it is
# read now.
POOL_ROLE="ci"
# The high-water jobs-per-check for the selected pool. 1 until the demand sweep
# has seen a run — nothing acts on it any more, it is published for a human
# sizing `max_hosts`, and 1 is the honest answer for "no run observed yet".
POOL_JOBS_PER_CHECK=1
BEACON_INTERVAL=30
PIN_ORPHAN_GRACE=900
# The configured list, verbatim — kept for parity with `config.sh --labels` and
# read by the multi-pool test, not by any routing decision in this file.
# shellcheck disable=SC2034
RUNNER_LABELS=""
# What the pool's agents actually ANSWER to: that list plus the runner's own
# read-only labels, folded. Every routing question — is this job ours, is this
# pin one of our labels, is this host- label known to the fleet — is asked of
# this one and never of RUNNER_LABELS. See P_MATCH_JSON for why.
RUNNER_MATCH_LABELS=""
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

# HOW MANY OF THE PER-RUN JOB LISTS ARE IN FLIGHT AT ONCE.
#
# The sweep costs one API call per unfinished run, and it spent them ONE AT A
# TIME. That is a latency problem, not a throughput one: each call is a round
# trip to api.github.com from the pool's region, and the controller does nothing
# but wait for it. So the number of runs a tick can examine was
# DEMAND_BUDGET / round-trip, and on a busy repository that is far fewer runs
# than the repository has.
#
# Measured on ci-runner-host-iit, 2026-08-30, at 21 of 21 runners busy:
# `ci_demand_runs_skipped` sat between 6 and 24 on EVERY tick of a two-hour
# window while `ci_demand` reported 5-13. The autoscaler was therefore sizing
# the pool against roughly half its real demand, recommending 4 hosts for a pool
# whose every slot was occupied, and PR jobs queued 3-12 minutes waiting for a
# host the metric never asked for. Every part of that reads as healthy: demand
# is a number, it is non-zero, and the pool is at the size that number implies.
#
# Fetching in parallel removes the serialisation without touching a single
# accounting rule — the same job lists, the same jq, the same budget, in the
# same order. What it changes is how many of them fit in the budget.
#
# EIGHT, and the ceiling is GitHub's secondary rate limit rather than the
# machine: the documented guidance is no more than 100 concurrent requests
# against the REST API, and this fleet runs one controller per pool project
# against one installation. Eight is an order of magnitude inside that and still
# turns a 27-run sweep from 27 round trips into 4.
#
# A pool that sets this to 0, to empty, or to something that is not a number
# would fan out zero calls and report demand 0 for ever — which is the exact
# failure this whole block exists to end, reintroduced through the knob that
# fixes it. So the value is CLAMPED rather than rejected: a controller that
# refuses to boot over a tuning knob is worse than one that ignores it, and a
# pure function is a thing the selftest can exercise without a metadata server.
clamp_fetch_concurrency() { # <raw> -> a usable count on stdout
  local v="$1"
  case "$v" in
    ''|*[!0-9]*) printf '8'; return 0 ;;
  esac
  [ "$v" -ge 1 ] || { printf '1'; return 0; }
  # Upper bound is GitHub's secondary rate limit, not the machine: the
  # documented guidance is no more than 100 concurrent REST requests per
  # installation, and one controller per pool project shares that budget with
  # its siblings. 32 leaves room for every pool in a fleet at once.
  [ "$v" -le 32 ] || { printf '32'; return 0; }
  printf '%s' "$v"
}
DEMAND_FETCH_CONCURRENCY=$(clamp_fetch_concurrency "$(md "instance/attributes/ci-demand-fetch-concurrency")")
# The demand sweep's per-pool results. One sweep fills all four; pool_select()
# hands the selected pool's values to the tick as the globals it always used.
declare -A D_TOTAL=() D_QUEUED=() D_WAIT=() D_RUNNING=() D_EXPIRED=()

# HOW LONG A QUEUED JOB IS ALLOWED TO BE DEMAND.
#
# GitHub keeps a run `queued` for as long as its jobs are undispatched, and
# nothing ever takes it out of that list on its own: a run held by an
# unapproved deployment environment, blocked behind a `concurrency` group, or
# simply abandoned on a dead branch stays queued and keeps asking this pool for
# a host. Apigee-Portal had three of them from 2026-08-19 still queued on
# 2026-08-23, one holding a job this pool's labels matched — twelve slots idle,
# every one of them online, and a demand floor of 1 that could not fall.
#
# The application repository does not have to do anything wrong to cause it,
# which is exactly why the controller has to bound it rather than trust it.
#
# Two harms, and the second is the one that hides the first: a pool that can
# never return to zero holds a host warm for work that will never arrive, and
# ci_demand_wait_seconds pegs at the corpse's age — so the gauge that says "this
# pool is behind" is saturated and a real queue underneath it is invisible.
#
# Six hours is far past any legitimate wait: the longest genuine one measured on
# this fleet is 72 minutes, behind a full merge queue. And where a legitimate
# job COULD exceed it, the pool is by definition already at max_hosts, so
# dropping it changes no decision — under-reporting is only possible in the one
# state where the number is not being acted on.
DEMAND_MAX_AGE=21600
METRIC_PREFIX=${METRIC_PREFIX:-custom.googleapis.com/ci}
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

# The same GET, to a CALLER-NAMED file, safe to run in a background subshell.
#
# gh_api cannot be: it writes every response to the one fixed pair of paths
# $STATE_DIR/api.body and $STATE_DIR/api.status, which is exactly right for a
# sequential caller that reads the status afterwards, and a data race the moment
# two of them run at once. Two concurrent gh_api calls do not fail — they hand
# each other's body back, which is a wrong demand count with nothing red
# anywhere. So the concurrent path gets its own function rather than a flag on
# that one, and the two cannot be confused at a call site.
#
# THE TOKEN IS AN ARGUMENT, not a call to gh_token. gh_token caches the
# installation token in the globals GH_TOKEN/GH_TOKEN_EXPIRY, and a global set
# inside a background subshell dies with it — so a fan-out that called it would
# read the App private key out of Secret Manager and mint a fresh installation
# token once per branch, every tick, for ever. The caller resolves it once, in
# the parent, where the cache is real.
#
# Written to a temporary path and renamed on success, so a partially-written
# body from a killed curl can never be read as a job list: the reader tests for
# the final name, and a failed call simply leaves it absent.
gh_api_fetch() { # <token> <api-path> <destination-file>
  local tok="$1" path="$2" dest="$3" status
  status=$(curl "${CURL_TIMEOUTS[@]}" -sS -o "$dest.part" -w '%{http_code}' \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$path" 2>>"$LOG") || status="000"
  case "$status" in
    2*) mv -f "$dest.part" "$dest" && return 0 ;;
  esac
  rm -f "$dest.part"
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

# Does this token LOOK like the ISO-8601 instant GitHub returns? Only the shape
# is tested; `date` still does the parsing. The two jobs are separate on purpose
# — `date -d` is a natural-language parser, not a validator, and it maps `-`,
# `0`, `Z` and the empty string onto today at 00:00:00 with exit status 0. Every
# one of those reaches the stamp loops (jq writes `-` for a run with no job in a
# given state), and each one turns a job-age gauge into seconds-since-midnight.
#
# An INSTANT, so the zone is required rather than optional: `date -d` reads a
# zoneless timestamp in the controller's local time, which is a silently wrong
# age rather than a rejected token, and a trailing-junk token would sail past a
# looser test for the same reason the sentinel did. Fractional seconds are
# accepted because they are still an instant — GitHub does not emit them today,
# and a guard that rejected them would drop real stamps the day it started to.
is_iso8601() {
  local rest
  rest="${1#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]}"
  [ "$rest" != "$1" ] || return 1          # no date-time head, nothing was cut
  case "$rest" in
    .[0-9]*)                               # optional fraction, any precision
      rest="${rest#.}"
      while :; do
        case "$rest" in [0-9]*) rest="${rest#?}" ;; *) break ;; esac
      done
      ;;
  esac
  case "$rest" in
    Z|+[0-9][0-9]:[0-9][0-9]|-[0-9][0-9]:[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
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
    D_EXPIRED["$p"]=0
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

  # AGE OUT THE CORPSES SERVER-SIDE, not just in the jq below.
  #
  # A wedged run stays `queued` forever and no API call will clear it: cancel
  # and force-cancel both 409 "Cannot cancel a workflow run that has not been
  # queued yet", DELETE 403s, rerun 403s. Apigee-Portal accumulated 24 of them
  # from a single 2026-08-26 incident window and they are still there.
  #
  # The DEMAND_MAX_AGE filter in the jq below already stops them being COUNTED,
  # so the metric is honest. It does not stop them being FETCHED, and that is
  # the part that bites, in two escalating ways:
  #
  #   1. Each corpse costs a full job-list call before it can be discarded, out
  #      of a budget sized for real work. 24 of them is 24 calls a tick spent
  #      to learn nothing, and every one of them raises the chance a live run
  #      sorts past the deadline and lands in ci_demand_runs_skipped.
  #   2. Worse, and unbounded: this page holds 50. Corpses are permanent and
  #      accumulate, so a repo that collects 50 of them pushes every REAL
  #      queued run off the page entirely. That truncation happens at the API,
  #      before the budget, so it does not even register as skipped — demand
  #      reads a clean 0, the pool sits at zero, and every signal is green.
  #
  # `created` is GitHub's own filter and costs nothing. Encoded by hand: gh_api
  # passes the path through to curl verbatim.
  #
  # QUEUED ONLY. An in-progress run is legitimately older than the window — a
  # long build created eight hours ago can still have a job that started a
  # minute ago — so filtering that list on run creation would drop live work.
  # A queued run has no such gap: its jobs were created with it and none has
  # started, so the run's own age bounds theirs.
  local demand_since demand_since_q=""
  demand_since=$(date -u -d "@$((sweep_start - DEMAND_MAX_AGE))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  # Appended rather than folded into a variable holding the whole query: the
  # budget selftest asserts the deadline is set before the queued-run call by
  # matching the literal `actions/runs?status=queued`, and a URL assembled out
  # of sight of that line silently stops being checked.
  [ -n "$demand_since" ] && demand_since_q="&created=%3E%3D${demand_since//:/%3A}"

  runs=$(gh_api "repos/$REPO_FULL/actions/runs?status=queued&per_page=50$demand_since_q" 2>/dev/null)
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

  # ── phase 1: FETCH, in parallel ──────────────────────────────────────────
  #
  # See DEMAND_FETCH_CONCURRENCY. The order is still queued-runs-first, and the
  # budget still authorises each call individually — what changed is that the
  # controller no longer sits idle through one round trip before starting the
  # next, which is what made a busy repository unmeasurable.
  #
  # A DIRECTORY PER TICK, removed at the end of the sweep and again before the
  # next one starts. A leftover file from a previous tick would be read as this
  # tick's answer for a run the budget skipped — stale demand presented as
  # fresh, which is worse than the truncation it would be hiding.
  local jobs_dir tok
  jobs_dir="$STATE_DIR/demand-jobs"
  rm -rf "$jobs_dir"
  mkdir -p "$jobs_dir" || return 0

  # ONCE, in the parent, so the cache in gh_token is the one that answers and
  # the children are handed a string. See gh_api_fetch.
  tok=$(gh_token) || { rm -rf "$jobs_dir"; return 0; }

  # Every pid is waited on EXPLICITLY rather than with a bare `wait`: this
  # process also runs the liveness responder and other long-lived background
  # work, and a bare `wait` would block the sweep on whichever of those happens
  # to be alive.
  local pids=() p
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
    gh_api_fetch "$tok" "repos/$REPO_FULL/actions/runs/$id/jobs?per_page=100" \
      "$jobs_dir/$id" 2>/dev/null &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$DEMAND_FETCH_CONCURRENCY" ]; then
      for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
      pids=()
    fi
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

  # ── phase 2: COUNT ───────────────────────────────────────────────────────
  #
  # Unchanged, and deliberately still sequential: it is jq and shell arithmetic
  # over payloads already on disk, and the accumulators below are shared state
  # that a subshell could not write back to.
  #
  # Bounded by the SAME deadline. Fetching in parallel moved the tick's cost
  # from the network to jq, and a repository busy enough to fill the fetch phase
  # can now hand this loop more payloads than the budget covers. A run whose
  # payload arrived but was never counted is under-reported demand exactly like
  # one never fetched, so it lands on the same counter and the same log line
  # rather than vanishing into a number that looks complete.
  for id in $ids; do
    [ -s "$jobs_dir/$id" ] || continue
    if ! budget_allows_call "$(date +%s)" "$deadline" 0; then
      skipped=$((skipped + 1))
      continue
    fi
    jobs=$(cat "$jobs_dir/$id" 2>/dev/null) || continue
    [ -n "$jobs" ] || continue

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
    counted=$(printf '%s' "$jobs" | jq -r --argjson pools "$POOLS_MATCH_MAP" \
      --argjson now "$sweep_start" --argjson maxage "$DEMAND_MAX_AGE" '
      # A QUEUED JOB HAS A SHELF LIFE, and past it this pool stops answering for
      # it. See DEMAND_MAX_AGE. An unparseable timestamp reads as "just now" and
      # is therefore never aged out -- the fail-safe direction, since the cost of
      # keeping a corpse is a warm host and the cost of dropping a live job is a
      # pool that will not scale out for real work.
      # GITHUB ROUTES CASE-INSENSITIVELY and jq subtracts case-sensitively, so
      # every comparison below is between folded sets. $pools arrives folded.
      def jlabels: ((.labels // []) | map(ascii_downcase));
      def expired:
        .status == "queued"
        and (((((.started_at // .created_at) // "") | fromdateiso8601?) // $now)
              < ($now - $maxage));
      [ .jobs[]?
        | select(.status == "queued" or .status == "in_progress")
        | select( ((.labels // []) | length) > 0 )
      ] as $candidates
      | $pools | to_entries[]
      | .key as $pool
      | .value as $mine_labels
      # THE `host-` PREFIX IS RESERVED, NOT OWNED, so the pin test is per POOL and
      # cannot live in the pool-independent candidate set above: a pool that
      # legitimately carries `host-large` serves a job asking for it, and dropping
      # that job as "pinned" here while the pinned classifier -- which subtracts
      # the same labels -- reads it as unpinned leaves it counted on neither
      # series, scaling nothing and invisible on both charts.
      | [ $candidates[]
          | select( ((jlabels | map(select(startswith("host-")))) - $mine_labels | length) == 0 )
          | select( (jlabels - $mine_labels) | length == 0 ) ] as $matched
      # Dropped from the COUNT and from the STAMPS both. Leaving an expired job
      # in the stamps would peg ci_demand_wait_seconds at its age forever, which
      # is worse than the phantom host: a saturated gauge cannot report the real
      # queue underneath it, and that gauge is how a starved pool is noticed.
      | [ $matched[] | select(expired | not) ] as $mine
      | ([ $matched[] | select(expired) ] | length) as $expired_n
      | [ $pool,
          ($mine | length),
          ([ $mine[] | select(.status == "queued") ] | length),
          # `-` and not "" when a pool matched nothing in this run. An empty
          # field between tabs is a field `read` COLLAPSES — tab is IFS
          # whitespace — so a run with in-flight jobs and no queued ones would
          # hand the in-flight stamps to the queued column and report a job
          # that started ten minutes ago as having waited ten minutes.
          # What skips this sentinel is is_iso8601 in the reader, and nothing
          # else. This comment used to claim `date -d -` fails; it does not —
          # it exits 0 and returns today at 00:00:00, which is how both job-age
          # gauges came to report seconds since midnight (#518). Any reader of
          # this column must test the shape of a token before parsing it.
          # (No apostrophes in here: the jq program is a single-quoted string.)
          ([ $mine[] | select(.status == "queued") | .started_at // .created_at ]
             | join(" ") | if . == "" then "-" else . end),
          ([ $mine[] | select(.status == "in_progress") | .started_at // empty ]
             | join(" ") | if . == "" then "-" else . end),
          # Appended, never inserted: the two fields above are space-joined
          # lists, and a reader that shifted its columns would hand a stamp list
          # to a counter. Always a number, so it cannot collapse under IFS.
          $expired_n
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
    # THE `host-` PREFIX IS RESERVED, NOT OWNED. A pool configured long before
    # this ADR may legitimately carry a label like `host-large`, and a job naming
    # it is an ordinary job for that pool -- not a pin at a named machine. So the
    # test is "a host- label no configured pool carries", and it has to agree
    # with the demand filter above: a job excluded from ci_demand as pinned and
    # then read as unpinned here would vanish from both series and scale nothing.
    #
    # The UNION over the pool table, and not this pool's labels: one controller
    # now serves every pool in one sweep, so there is no "this pool" here to ask
    # -- POOL_LABELS_JSON is whichever pool was selected last, which before the
    # first select is the empty list and would read every host- label as a pin.
    pinned_recs=$(printf '%s' "$jobs" | jq -r --arg rid "$id" --argjson pools "$POOLS_MATCH_MAP" '
      def jlabels: ((.labels // []) | map(ascii_downcase));
      ([ $pools | to_entries[] | .value[] ] | unique) as $known_labels
      | .jobs[]?
      | select(.status == "queued" or .status == "in_progress")
      | select( ((jlabels | map(select(startswith("host-")))) - $known_labels | length) > 0 )
      | [ $rid, .status, ((.labels // []) | join(",")), (.created_at // .started_at // "") ]
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
    local c_pool n q stamps running expired_n s wait epoch
    while IFS=$'\t' read -r c_pool n q stamps running expired_n; do
      [ -n "${c_pool:-}" ] || continue
      # A pool jq knows about but this shell does not cannot happen — the map
      # was built from POOLS — but the guard costs nothing and an unguarded
      # write would create a phantom entry that every later loop iterates.
      [ -n "${D_TOTAL[$c_pool]+set}" ] || continue

      # HOW BIG ONE RUN IS, for this pool, kept as a high-water mark across
      # ticks. `n` is already exactly that: the jobs of ONE workflow run that
      # this pool can serve. For a merge-queue pool a workflow run IS a
      # speculative check, so this is the "jobs per check" the capacity rule
      # needs, measured instead of guessed — see Q_JPC. Tracked for every pool
      # because the accumulator is shared and one comparison is cheaper than a
      # role test; only a merge-queue pool ever reads it.
      if [ "${n:-0}" -gt "${Q_JPC[$c_pool]:-1}" ]; then
        Q_JPC["$c_pool"]="$n"
      fi

      D_TOTAL["$c_pool"]=$(( D_TOTAL["$c_pool"] + ${n:-0} ))
      D_QUEUED["$c_pool"]=$(( D_QUEUED["$c_pool"] + ${q:-0} ))
      D_EXPIRED["$c_pool"]=$(( D_EXPIRED["$c_pool"] + ${expired_n:-0} ))

      # The shape test is the guard; `date` is not. GNU date accepts `-`, `0`,
      # `Z` and the empty string, exits 0 for each, and resolves every one of
      # them to TODAY AT 00:00:00 — so `|| continue` never fires and the sweep
      # measures the age of midnight. jq writes `-` into this column whenever a
      # run has no job in this state (a tab field cannot be empty or `read`
      # collapses the columns), which is most runs, most ticks. Because D_WAIT
      # is a high-water mark the bad value does not merely join the real ones,
      # it buries them: after roughly 00:10 UTC nothing true can be reported
      # again until midnight. Measured on ci-runner-host-iit, both gauges
      # tracked the clock 1:1 all day, peaking at 86398 (#518).
      for s in $stamps; do
        is_iso8601 "$s" || continue
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
        is_iso8601 "$s" || continue   # same sentinel, same midnight — see above
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
  # The payloads are this tick's answer and nothing reads them after it. Left
  # behind they would be the next tick's stale answer for a run it skipped.
  rm -rf "$jobs_dir"

  DEMAND_RUNS_SKIPPED=$skipped
  [ "$skipped" -gt 0 ] && log "demand budget ${DEMAND_BUDGET}s exhausted after $examined run(s) at fetch concurrency ${DEMAND_FETCH_CONCURRENCY}: $skipped run(s) not examined this tick — demand is a LOWER BOUND, and a skipped in_progress run may still hold queued jobs"
  return 0
}

# Jobs one check run produces, per pool, OBSERVED rather than configured — a
# high-water mark that only ever rises while this process lives.
#
# Configuring it would mean asking an operator for a number they cannot know:
# it is however many jobs the repository's pull-request workflows happen to
# contain today, and it changes with every workflow edit. Observing it costs
# nothing — collect_demand already counts, per run and per pool, exactly this.
#
# Nothing in this file acts on it. It is published as
# `ci_queue_jobs_per_check` and it is the input a human multiplies to size a
# merge-queue pool's `max_hosts`, now that the derivation that used to consume
# it retired with Mergify. A high-water mark is never too low for a run shape
# that has already been seen, which is the property that makes it safe to size
# by.
declare -A Q_JPC=()

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
    rows=$(printf '%s' "$jobs" | jq -r --argjson pools "$POOLS_MATCH_MAP" '
      def jlabels: ((.labels // []) | map(ascii_downcase));
      [ .jobs[]?
        | select(.status == "completed")
        | select( ((.labels // []) | length) > 0 )
      ] as $candidates
      | $pools | to_entries[]
      | .key as $pool
      | .value as $mine_labels
      | $candidates[]
      | select( (jlabels - $mine_labels) | length == 0 )
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

# --- parked pull requests ------------------------------------------------------
#
# The one sweep in this file that is not about capacity. parked-decision.sh
# carries the rule and the reasoning; this is the I/O around it.
#
# COST. The list call is unconditional and costs one request per interval. The
# per-pull-request check counts are paid ONLY for pull requests that already
# fail an entry condition, because parked_verdict's first branch is decidable
# from the list payload alone — so a repository whose pull requests all target
# the queue's branch and none of which are drafts pays exactly one call, and a
# repository with a wall of stale drafts pays a bounded number.
#
# PERMISSION. `commits/<sha>/check-runs` needs the installation to hold
# `checks: read`. It is the only endpoint in this file that does, so an
# installation granted the older permission set will fail every one of these
# calls and nothing else. That is logged by name rather than counted silently:
# the failure mode of this whole feature is being quietly inert, which is what
# it was built to fix.
PARKED_BUDGET=20
# Seconds between sweeps. Nothing scales or drains on this, and an entry
# condition changes on the timescale of a human editing a pull request, so it
# rides the same 300s the outcome sweep uses rather than the poll interval.
PARKED_INTERVAL=300
PARKED_LAST_SWEEP=0
# A ceiling on top of the budget. The budget bounds the TIME; this bounds the
# calls, so a repository with sixty open drafts cannot spend a whole tick's
# worth of installation rate limit on a question nothing waits on.
PARKED_MAX_CANDIDATES=20
PARKED_SKIPPED=0
# DENIED IS NOT SKIPPED, and conflating them is what made the permission note
# above a comment rather than a signal. A skipped pull request is retried on the
# next sweep and the count is merely a lower bound; a denied one is retried
# forever and the count is a lie. Both would have moved the same counter, so an
# installation without `checks: read` published "the sweep is slightly behind"
# every five minutes, indefinitely, while reporting zero parked pull requests —
# a feature built to end a silent zero, failing by producing one.
PARKED_DENIED=0
# Every reason parked_verdict can return, keyed here so the series can be
# published as a zero. A metric that only appears when something is wrong is
# indistinguishable from a controller that stopped publishing — the same
# argument as ci_runner_list_blind_ticks, and the reason the list is closed.
PARKED_REASONS=(draft base draft-and-base)
declare -A PARKED_COUNT=()

collect_parked() {
  local sweep_start
  sweep_start=$(date +%s)

  # Not this tick's turn. Counters are deliberately NOT reset here: they keep
  # reporting what the last real sweep found, rather than flickering to 0 on
  # every tick in between and hiding a pull request that has been parked for a
  # week.
  [ $((sweep_start - PARKED_LAST_SWEEP)) -ge "$PARKED_INTERVAL" ] || return 0
  PARKED_LAST_SWEEP=$sweep_start

  local r
  for r in "${PARKED_REASONS[@]}"; do PARKED_COUNT["$r"]=0; done
  PARKED_SKIPPED=0
  PARKED_DENIED=0

  local deadline=$((sweep_start + PARKED_BUDGET))

  local pulls rows status
  pulls=$(gh_api "repos/$REPO_FULL/pulls?state=open&per_page=50") || {
    status=$(cat "$STATE_DIR/api.status" 2>/dev/null)
    # The word DENIED is load-bearing: the alert's runbook tells the operator to
    # grep for it, so a path that raises ci_parked_sweep_denied without printing
    # it sends somebody to a log that has nothing to say. This path is refused
    # for a DIFFERENT permission than the check-runs one — listing pull requests
    # needs `pull_requests: read` — and the message says so, because the fix
    # differs and the counter cannot carry that distinction on its own.
    if parked_denial "$status"; then
      PARKED_DENIED=$((PARKED_DENIED + 1))
      log "parked sweep: DENIED listing open pull requests (status=$status) — this call needs 'pull_requests: read', not the 'checks: read' the per-pull-request call needs"
    else
      log "parked sweep: cannot list open pull requests (status=$status)"
    fi
    return 0
  }

  # The free half of the rule, applied before anything is fetched. `.draft` is
  # present on every entry of the list payload and `.base.ref` likewise, so a
  # pull request that satisfies both entry conditions is dropped for nothing.
  rows=$(printf '%s' "$pulls" | jq -r --arg qb "$QUEUE_BASE" '
    .[]?
    | select((.draft == true) or ((.base.ref // "") != $qb))
    | [ (.number | tostring),
        (if .draft then "1" else "0" end),
        (.base.ref // ""),
        (.head.sha // "") ] | @tsv' 2>/dev/null)
  [ -n "$rows" ] || return 0

  local num draft base sha checks counts total failed pending verdict reason
  local examined=0
  while IFS=$'\t' read -r num draft base sha; do
    [ -n "$num" ] || continue
    [ -n "$sha" ] || continue

    if [ "$examined" -ge "$PARKED_MAX_CANDIDATES" ] \
      || ! budget_allows_call "$(date +%s)" "$deadline" "$CURL_MAX_TIME"; then
      PARKED_SKIPPED=$((PARKED_SKIPPED + 1))
      continue
    fi
    examined=$((examined + 1))

    checks=$(gh_api "repos/$REPO_FULL/commits/$sha/check-runs?per_page=100") || {
      status=$(cat "$STATE_DIR/api.status" 2>/dev/null)
      # A denial is counted as a denial and NOT also as a skip: the two carry
      # opposite advice — wait, versus grant a permission — and a counter that
      # moves for both tells the reader neither.
      if parked_denial "$status"; then
        PARKED_DENIED=$((PARKED_DENIED + 1))
        log "parked sweep: DENIED reading check runs for #$num (status=$status) — the App installation lacks 'checks: read', so this sweep can never report anything until that is granted"
      else
        PARKED_SKIPPED=$((PARKED_SKIPPED + 1))
        log "parked sweep: cannot read check runs for #$num (status=$status)"
      fi
      continue
    }

    # `neutral` and `skipped` are deliberately absent from the failure list.
    # GitHub does not treat either as blocking and neither does the queue, so
    # counting them would read a path-filtered monorepo as permanently red and
    # this rule would never fire on the repositories that need it most.
    counts=$(printf '%s' "$checks" | jq -r '
      [ .check_runs[]? ] as $c
      | [ ($c | length),
          ($c | map(select(.status == "completed")
                    | (.conclusion // ""))
              | map(select(. == "failure" or . == "cancelled"
                        or . == "timed_out" or . == "action_required"))
              | length),
          ($c | map(select(.status != "completed")) | length)
        ] | @tsv' 2>/dev/null)
    IFS=$'\t' read -r total failed pending <<<"$counts"

    # The empty string is passed through rather than defaulted to a number: an
    # unparseable count must reach parked_verdict as unparseable, which it
    # answers with silence. Defaulting to 0 here would turn a jq failure into
    # "green, no checks failed" and manufacture the alert.
    verdict=$(parked_verdict "$draft" "$base" "$QUEUE_BASE" \
      "${total:-}" "${failed:-}" "${pending:-}")

    case "$verdict" in
      parked:*)
        reason="${verdict#parked:}"
        reason="${reason%% *}"
        PARKED_COUNT["$reason"]=$((${PARKED_COUNT["$reason"]:-0} + 1))
        # Logged with the number, because the metric can only say how many. The
        # operator reading an alert needs to know WHICH pull request, and this
        # is the only place that says so.
        log "pull request #$num is green and cannot enter the merge queue ($verdict) — no check reports this as a failure"
        ;;
    esac
  done <<<"$rows"

  [ "$PARKED_SKIPPED" -gt 0 ] && log "parked sweep: $PARKED_SKIPPED pull request(s) not examined this sweep (budget ${PARKED_BUDGET}s, ceiling $PARKED_MAX_CANDIDATES) — retried next sweep, not lost"
  return 0
}

# --- the apply trigger -------------------------------------------------------
#
# The one thing in this project that nothing else watches: the Cloud Build
# trigger that applies the runner infrastructure. It is the build that maintains
# every alert policy in this project, so it is also the build whose failure no
# policy in this project can report — and it fails in a shape that is invisible
# by construction.
#
# A trigger's build config is validated when a build FIRES, not when Terraform
# creates it. A config that has grown past one of Cloud Build's size cliffs is
# refused at submit: sub-second FAILURE, no log, no build steps, the whole
# explanation in the build's own `statusDetail`. `ci-runner-apply-entity-platform`
# sat in that state from 2026-08-30 and was found by hand on 2026-08-31 while
# somebody was doing something else. The pool kept serving jobs the whole time,
# on whatever configuration it had when the refusal started, and every dashboard
# in the project stayed green — because a pool that stops receiving infrastructure
# and a pool with nothing to receive look exactly alike.
#
# Cloud Logging cannot see it. Measured on the real refusal: there is no build
# log at all, and the `CreateBuild` audit entry is severity NOTICE with
# `granted: true` and an empty `status` — indistinguishable from a healthy build
# being created. So a log-based metric would report green on precisely the
# projects that are broken, and the refusal exists in exactly one place: the
# build resource, readable only through the Cloud Build API.
#
# Hence here. The controller already runs continuously in every pool project and
# already publishes to the alert policies this would need, so the check costs one
# `gcloud builds list` and no new credential beyond `cloudbuild.builds.list` —
# which, unlike `cloudbuild.triggers.*`, IS available to a custom role.
#
# It reads BUILDS, never triggers, and that is not an accident: listing triggers
# needs `cloudbuild.triggers.list`, which no custom role can hold. A build
# carries its trigger's name in `substitutions.TRIGGER_NAME`, so the newest apply
# build is reachable with the one permission that can be granted narrowly.
APPLY_TRIGGER_PREFIX=${APPLY_TRIGGER_PREFIX:-ci-runner-apply-}
# Fifteen minutes. The trigger it watches fires daily, so polling it on the tick
# interval would spend the demand budget — the standing lesson of
# ci_demand_runs_skipped — to re-learn a fact that changes once a day.
APPLY_CHECK_INTERVAL=900
APPLY_CHECK_LAST=0
# Deliberately NOT reset between sweeps, for the same reason the parked counters
# are not: on the ticks in between, these keep reporting what the last real sweep
# found rather than flickering to a zero that reads as healthy.
APPLY_BUILD_AGE=0
APPLY_BUILD_FAILED=0
# The two ways the numbers above are not answers. `missing` is a successful list
# that found no apply build at all — the trigger that never fires, which produces
# no failure to find and is the half of this that a status check alone would
# miss. `denied` is the list itself being refused, which makes both of the
# numbers above stale rather than merely zero. They are separate because the
# operator's next move differs: one is a trigger to go look at, the other is a
# grant to go make.
APPLY_BUILD_MISSING=0
APPLY_CHECK_DENIED=0

collect_apply_build() {
  local now
  now=$(date +%s)
  [ $((now - APPLY_CHECK_LAST)) -ge "$APPLY_CHECK_INTERVAL" ] || return 0
  APPLY_CHECK_LAST=$now

  # The controller's own region. The apply trigger is a project fact rather than
  # a pool fact, and REGION is per-pool and only set inside pool_select().
  local zone region
  zone=$(md "instance/zone")
  region="${zone##*/}"
  region="${region%-*}"
  if [ -z "$region" ]; then
    log "apply check: cannot read this instance's zone — skipping (counters keep their previous values)"
    return 0
  fi

  # `timeout` for the reason every gcloud call in this file is bounded: gcloud
  # carries its own retry loop and can outlive a tick. Newest first, and one
  # page rather than one row, because the newest build of the apply trigger may
  # sit behind other builds in this project.
  local rows
  if ! rows=$(timeout 60 gcloud builds list \
    --project="$PROJECT" --region="$region" --limit=50 \
    --format='value(substitutions.TRIGGER_NAME,status,createTime)' 2>&1); then
    APPLY_CHECK_DENIED=1
    # DENIED is the word the runbook tells the operator to grep for, so the path
    # that raises the counter has to print it.
    log "apply check: DENIED listing builds in $PROJECT/$region — this call needs cloudbuild.builds.list; ci_apply_build_age_seconds and ci_apply_build_failed are now STALE, not zero: ${rows%%$'\n'*}"
    return 0
  fi
  APPLY_CHECK_DENIED=0

  local name status created found=0 newest_status="" newest_created=""
  while IFS=$'\t' read -r name status created; do
    case "$name" in "$APPLY_TRIGGER_PREFIX"*) ;; *) continue ;; esac
    # The ROW is what found means, not the status on it. A build whose status
    # column came back empty is a build that exists and did not succeed, which
    # is `failed:unknown` — deriving found from the status instead would file it
    # as `missing` and describe a trigger that is firing as one that stopped.
    found=1
    newest_status="$status"
    newest_created="$created"
    break
  done <<<"$rows"

  local age=-1 created_epoch
  if [ "$found" = "1" ]; then
    created_epoch=$(date -d "$newest_created" +%s 2>/dev/null) || created_epoch=0
    [ "$created_epoch" -gt 0 ] && age=$((now - created_epoch))
  fi

  local verdict
  verdict=$(apply_verdict "$found" "$newest_status" "$age")

  case "$verdict" in
    missing)
      # A successful list with no apply build in it. Not a failure — worse: this
      # is the trigger that has stopped firing, which by definition leaves no
      # FAILURE behind to be found. Age keeps its previous value rather than
      # resetting, because a 0 here would read as "applied a moment ago".
      #
      # ci_apply_build_failed is CLEARED here rather than left standing. Its
      # descriptor says "the newest apply build did not succeed", and on this
      # arm there is no newest apply build for it to be describing — a series
      # that keeps asserting a build nobody can go and read is a triage dead
      # end. Nothing is silenced by it: this arm raises ci_apply_build_missing,
      # the same policy alerts on both, and the age keeps its previous value.
      APPLY_BUILD_MISSING=1
      APPLY_BUILD_FAILED=0
      log "apply check: no ${APPLY_TRIGGER_PREFIX}* build in the last 50 builds of $PROJECT/$region — the trigger is not firing, and a trigger that never fires produces no failure to alert on"
      return 0
      ;;
    failed:*)
      APPLY_BUILD_MISSING=0
      APPLY_BUILD_FAILED=1
      [ "$age" -ge 0 ] && APPLY_BUILD_AGE=$age
      # The refusal's whole explanation is in statusDetail and nowhere else, so
      # the log line carries the query: an operator who reaches this alert and
      # finds only "FAILURE" has to go and run it by hand anyway.
      log "apply check: the newest apply build in $PROJECT/$region is ${verdict#failed:} (created $newest_created) — this project is no longer receiving runner infrastructure; read its statusDetail with 'gcloud builds list --project=$PROJECT --region=$region --limit=50 --format=\"value(substitutions.TRIGGER_NAME,status,statusDetail)\" | grep \"^$APPLY_TRIGGER_PREFIX\" | head -1'"
      ;;
    inflight:*)
      # Still running. The previous verdict stands rather than being reported as
      # a green that has not happened yet — but the age does advance, because
      # the build exists and its create time is a fact.
      APPLY_BUILD_MISSING=0
      [ "$age" -ge 0 ] && APPLY_BUILD_AGE=$age
      ;;
    ok)
      APPLY_BUILD_MISSING=0
      APPLY_BUILD_FAILED=0
      [ "$age" -ge 0 ] && APPLY_BUILD_AGE=$age
      ;;
  esac
  return 0
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
  #
  # `name` for the first column and `.uri()` on the fourth, and BOTH spellings
  # are load-bearing. A gcloud projection attaches a transform to the KEY, not
  # to the column, so naming `instance` twice — once as `instance.basename()`
  # and once bare — applies the basename to both, and the fourth column comes
  # back as the host's short name. Measured on a live pool:
  #
  #   (instance.basename(),instance) -> ci-runner-host-abcd,ci-runner-host-abcd
  #   (name,instance.uri())          -> ci-runner-host-abcd,https://.../zones/<zone>/instances/ci-runner-host-abcd
  #
  # A basename in the self-link column is not a visible failure. `${uri%/instances/*}`
  # has nothing to strip, `${zone##*/}` has no slash to cut, and the "zone" the
  # readers derive is the HOST NAME. Every per-instance compute call then fails
  # with an invalid zone, which the pin-hold gate reads as `read-failed` — and
  # `read-failed` vetoes. The whole pool becomes undeletable and never rolls
  # onto a new template, while the log says nothing worse than "read-failed".
  # Nor does the org-policy classifier get a chance: the request never reaches
  # the policy, so a fleet with guest attributes switched off looks identical.
  #
  # Bare `instance` is not the answer either — in list-instances it renders as
  # the SCOPE, the bare zone name, rather than as the link. `.uri()` is the spelling that asks for the URI
  # and says so.
  HOSTS=$(gcloud compute instance-groups managed list-instances "$MIG" \
    --region="$REGION" --project="$PROJECT" \
    --format="csv[no-heading](name,instanceStatus,version.instanceTemplate.basename(),instance.uri())" 2>/dev/null)
}

# One describe per tick for both facts we need from the MIG: the target size we
# publish, and the baseInstanceName that bounds the orphan reaper to instances
# THIS pool can create. Kept together so the reaper never costs an extra call.
MIG_BASE=""
MIG_TARGET=0
MIG_TEMPLATE=""

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
  PIN_VANISHED=0

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

  # PINNED_JOBS holds one record per JOB; cancellation is per RUN. A matrix of
  # eight pinned jobs is one wedged run, and posting eight cancels to it would
  # publish eight units of ci_pinned_runs_cancelled for the one run that left.
  # Two lists rather than one: `tried` stops the second POST, `gone` stops the
  # second COUNT, and the gap between them is a run whose cancel was refused --
  # which is still pinned demand, because the job is still sitting there.
  local tried=" " gone=" "
  local now run status labels created age epoch verdict token code
  local pin_host missing
  now=$(date +%s)

  # The absence clock is refreshed BEFORE any verdict is asked for, so every job
  # in this loop is judged against the same reading of the same tick.
  refresh_host_liveness "$live" "$now" "$blind"

  while IFS=$(printf '\t') read -r run status labels created; do
    [ -n "$run" ] || continue

    # An unparseable timestamp yields age 0, which reads as "just queued" and
    # therefore as "wait". Erring toward the grace window is the whole posture.
    age=0
    if epoch=$(date -d "$created" +%s 2>/dev/null); then
      age=$((now - epoch))
      [ "$age" -lt 0 ] && age=0
    fi

    # How long the pinned host has been missing, asked of the SAME rule that
    # decides what a pin is — pin_host_of is rule 2, not a second reading of it.
    # Empty for an unpinned job, for a job carrying two pins, and for a host
    # this controller has never listed; all three mean "no absence clock", and
    # the decision function is explicit about treating that as unknown rather
    # than as zero.
    pin_host=$(pin_host_of "$labels" "$RUNNER_MATCH_LABELS")
    missing=""
    [ -n "$pin_host" ] && missing=$(host_missing_seconds "$pin_host" "$now")

    verdict=$(pinned_job_decision "$status" "$labels" "$RUNNER_MATCH_LABELS" "$MIG_BASE" \
      "$live" "$age" "$PIN_ORPHAN_GRACE" "$missing")

    case "$verdict" in
      pinned:* | wait:*)
        # Counted as work in flight and NOT added to ci_demand: only the host
        # named in the label can serve it, so an autoscaler whose one move is
        # "add a host" would buy a machine per tick that the job cannot use.
        DEMAND_PINNED=$((DEMAND_PINNED + 1))
        ;;
      orphan:* | vanished:*)
        # `vanished` is `orphan` for a job that was RUNNING when its host went
        # away, and the handling below is deliberately identical: the same
        # cancel, the same per-run de-duplication, the same fail-safes. It is a
        # separate verdict because it is a separate FAULT — a queued job
        # outliving a scale-in can be nobody's mistake, while live work losing
        # its host is the fleet's every time — and because it is the one that
        # unblocks everything downstream. A cancelled run has a conclusion; a
        # run whose host evaporated has none and never will, so whatever is
        # waiting on that status waits out its own timeout instead. That is the
        # 150 minutes a merge queue spends before dequeuing a green pull request
        # for a reason that names nothing.
        #
        # Counted here, per JOB, and before every guard below — including the
        # de-duplication that makes ci_pinned_runs_cancelled per-RUN. The two
        # series answer different questions on purpose: that one counts the
        # action taken, this one counts the fault observed, and a matrix of
        # eight jobs on one dead host really is eight jobs that lost their host.
        # It is also the only one of the two that survives a refused cancel,
        # which is exactly the case where an operator needs to see the number.
        case "$verdict" in
          vanished:*) PIN_VANISHED=$((PIN_VANISHED + 1)) ;;
        esac
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
        case "$gone" in *" $run "*) continue ;; esac
        case "$tried" in
          *" $run "*)
            # Already posted for this run this tick and it did not take. The job
            # is still queued, so it is still demand nothing can serve.
            DEMAND_PINNED=$((DEMAND_PINNED + 1))
            continue
            ;;
        esac
        # A run nothing can cancel is a run still sitting in the queue: counted,
        # so ci_demand_pinned shows the wedge instead of reporting zero of it.
        token=$(gh_token) || {
          DEMAND_PINNED=$((DEMAND_PINNED + 1))
          tried="$tried$run "
          log "pinned run $run: $verdict — no token, not cancelled"
          continue
        }
        tried="$tried$run "
        code=$(curl "${CURL_TIMEOUTS[@]}" -s -o /dev/null -w '%{http_code}' -X POST \
          -H "Authorization: Bearer $token" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/$REPO_FULL/actions/runs/$run/cancel")
        case "$code" in
          202 | 409)
            # 409 = already finishing. The run is leaving either way, and
            # counting it as handled is what stops the log repeating per tick.
            gone="$gone$run "
            PIN_ORPHANED=$((PIN_ORPHANED + 1))
            log "pinned run $run: $verdict — cancelled (HTTP $code)"
            ;;
          *)
            # Most likely the app lacks Actions: write. Say so once per tick
            # rather than retrying: the job still cannot run, and a wedge nobody
            # can see is exactly what this function exists to prevent.
            DEMAND_PINNED=$((DEMAND_PINNED + 1))
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

# host_facts <host> -> sets HOST_BUSY, HOST_PRESENT, HOST_REG
# Slot agents are named "<host>-s<N>" by host-startup.sh; that naming IS the
# join key between GCE instances and GitHub registrations.
host_facts() {
  local host="$1"
  if [ -z "$RUNNERS_JSON" ]; then
    HOST_BUSY=0
    HOST_PRESENT=-1
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
  # How many of this host's slots ANSWER, as opposed to how many it was built
  # with. The two have never been compared: a slot is counted as capacity on the
  # strength of its agent being up, and the fleet had no series that said
  # otherwise. -1 above, never 0, because a tick that could not read the runner
  # list knows nothing about this host and must not be summed as a host with no
  # slots — that reads identically to the outage it is supposed to detect.
  HOST_PRESENT=$present
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

# --- the absence ledger -------------------------------------------------------
#
# host_age_seconds above answers "how long have we known this host". This
# answers the opposite and, for a pinned job, the only question that matters:
# how long has the host been CONTINUOUSLY MISSING from the MIG's list.
#
# It exists because `age` — seconds since the job was created — is not evidence
# about a host. A job that queued for twenty minutes and then lost its host has
# already spent its whole grace allowance before the host went anywhere, so one
# blipped listing was enough to cancel it. That was tolerable while only queued
# jobs could be cancelled; it is not tolerable now that a RUNNING one can be,
# which is why pinned_job_decision refuses the `vanished` verdict outright
# unless this ledger can answer.
#
# Keyed by HOST and not by job, so it is independent of which pins exist this
# tick and survives a job being recreated. One file per host, the same shape as
# seen-/idle-/orphan-, and it is refreshed for every live host every tick — so
# "the file is old" and "the host is missing" are the same statement.
refresh_host_liveness() {
  local live="$1" now="$2" blind="$3"
  local f host

  # A BLIND TICK RESETS EVERY CLOCK RATHER THAN ADVANCING THEM. An empty host
  # list means the list call failed or the pool is genuinely at zero, and those
  # are indistinguishable here — the same ambiguity classify_pinned refuses to
  # act on. Letting the absence clocks run through it would mean a listing
  # outage of one grace window handed every pinned host a cancellation the
  # moment sight returned, which is the outage causing the damage rather than
  # merely hiding it.
  if [ "$blind" = 1 ]; then
    for f in "$STATE_DIR"/absent-*; do
      [ -e "$f" ] || continue
      printf '%s' "$now" >"$f"
    done
    return 0
  fi

  for host in ${live//,/ }; do
    # Same charset check as the reader, and here it guards a WRITE. This list
    # comes from the instance-group listing rather than from a pull request, so
    # nothing malformed is expected — which is the reason to check rather than
    # not: an unexpected value in a trusted list is precisely the one that goes
    # unnoticed, and the failure it would cause is a file written outside the
    # state directory by the one process on the fleet holding the App token.
    case "$host" in
      "" | *[!a-z0-9-]*)
        log "host liveness: refusing to stamp a clock for an implausible instance name [$host] — the pool listing returned something that is not a GCE instance name"
        continue
        ;;
    esac
    printf '%s' "$now" >"$STATE_DIR/absent-$host"
  done

  # A host absent for a full day is not coming back and no job pinned to it has
  # survived either — GitHub's own timeout is 24 hours. Pruning here rather than
  # on a timer keeps a controller that runs for months from accumulating a file
  # per host it has ever seen.
  local stamp
  for f in "$STATE_DIR"/absent-*; do
    [ -e "$f" ] || continue
    stamp=$(cat "$f" 2>/dev/null)
    case "$stamp" in
      "" | *[!0-9]*) rm -f "$f"; continue ;;
    esac
    [ $((now - stamp)) -gt 86400 ] && rm -f "$f"
  done
  return 0
}

# host_missing_seconds <host> <now>
# Echoes the seconds since the host was last listed, or NOTHING when this
# controller has never listed it. Empty is not zero and must not be read as
# one: a host we have never seen is a host we can say nothing about, and
# pinned_job_decision treats the two completely differently.
host_missing_seconds() {
  local host="$1" now="$2"

  # The name becomes a path, so it is checked here as well as at pin_host_of,
  # which is where it was cleaned. Not redundancy for its own sake: the name
  # originates in `runs-on`, the two functions live in different files joined
  # only at Terraform apply time, and a future caller reaching this one with a
  # name from somewhere else is exactly the change that would not look wrong.
  # A path is never built from a string this function has not itself vetted.
  case "$host" in
    "" | *[!a-z0-9-]*) return 0 ;;
  esac

  local f="$STATE_DIR/absent-$host"
  local stamp
  [ -f "$f" ] || return 0
  stamp=$(cat "$f" 2>/dev/null)
  case "$stamp" in
    "" | *[!0-9]*) return 0 ;;
  esac
  local gap=$((now - stamp))
  [ "$gap" -lt 0 ] && gap=0
  printf '%s' "$gap"
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
  # A marker that is not a plain number is not a clock. Bash arithmetic would
  # read it as 0 and hand back an age of "seconds since the epoch", which is
  # past every window this controller has. Restamp instead — the same thing an
  # absent file means — and lose one grace window rather than the host.
  case "$since" in
    "" | *[!0-9]*) echo "$now" >"$f"; echo 0; return 0 ;;
  esac
  local gap=$((now - since))
  [ "$gap" -lt 0 ] && gap=0
  echo "$gap"
}

# How long this host has read `partial` WITHOUT INTERRUPTION, for the
# capacity-lost arm of recycle_decision().
#
# Same shape as idle_seconds() and for the same reason: the decision is a pure
# function, so the clock has to live out here. Any reading OTHER than `partial`
# clears the file — including `unknown`. A tick that could not ask GitHub is not
# evidence the host is still degraded, and letting it hold the timer would let a
# run of blind ticks accumulate into a delete nobody could justify afterwards.
# The cost of clearing is one more grace window before the host is recycled,
# which is the direction this rule should be wrong in.
partial_seconds() {
  local host="$1" reg="$2"
  local f="$STATE_DIR/partial-$host"
  local now
  now=$(date +%s)

  if [ "$reg" != "partial" ]; then
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
  # Same validation as idle_seconds(), and it matters more here: a marker read
  # as 0 would put this host's partial age at decades, clearing the hysteresis
  # window in one tick and retiring a host whose slot sweep was still running.
  case "$since" in
    "" | *[!0-9]*) echo "$now" >"$f"; echo 0; return 0 ;;
  esac
  local gap=$((now - since))
  [ "$gap" -lt 0 ] && gap=0
  echo "$gap"
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

# zone_of_uri <instance-self-link> -> the zone, or EMPTY
#
# Four call sites derive a zone from a MIG row's self-link, and all four used to
# do it inline with `${uri%/instances/*}` followed by `${zone##*/}`. On a real
# self-link that is correct. On anything that is NOT a self-link it is silently
# wrong in the worst available way: neither expansion has anything to match, so
# a bare host name comes back out as the "zone", non-empty, and sails through
# the `[ -z "$zone" ]` guard each site already has.
#
# That is not hypothetical. collect_hosts asked gcloud for `instance` alongside
# `instance.basename()`, gcloud attaches a transform to the key rather than to
# the column, and the self-link column arrived as the host's short name for
# every host in the fleet. Each per-instance call then addressed zone
# `ci-runner-host-abcd`, failed, and the pin-hold gate read the failure as
# `read-failed` — which vetoes. Every host on both IntegrateIT pools sat
# undeletable on a stale template for two days, and the only trace was the word
# `read-failed` in a log line that also appears for an ordinary API blip.
#
# The projection is fixed at the source. This exists so that the NEXT thing that
# hands these functions something that is not a self-link fails as "no zone",
# which every caller already handles, instead of as a plausible wrong answer.
zone_of_uri() {
  local uri="${1:-}" zone
  # Both halves must be present. `*/zones/*/instances/*` is the shape of the
  # only string this is allowed to succeed on.
  case "$uri" in
    */zones/*/instances/*) ;;
    *) return 0 ;;
  esac
  zone=${uri%/instances/*}
  zone=${zone##*/}
  printf '%s' "$zone"
}

# write_registration_token <instance-self-link> <regkey-marker>
write_registration_token() {
  local uri="$1" keylive="$2"
  local tok resp reg f zone host rc

  # The parse comes FIRST, before anything is minted. A registration token is
  # live from the moment GitHub issues it, so a self-link this cannot address —
  # a MIG row with no instance URI, a format change — would otherwise burn an
  # hour-long credential that no delete path can ever reach, because the delete
  # needs the same zone this failed to read.
  zone=$(zone_of_uri "$uri")
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
  zone=$(zone_of_uri "$uri")
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

  zone=$(zone_of_uri "$uri")
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

# guest_attributes_denied <stderr-text> -> 0 if the read was refused by the org
# policy that turns guest attributes off, 1 otherwise.
#
# Both gates below read a host's guest attributes, and until now both threw the
# error away (`2>/dev/null`) and judged on the exit status alone. One status
# covers a timeout, a quota, a missing IAM grant and this:
#
#   HTTPError 412: Constraint constraints/compute.disableGuestAttributesAccess
#   violated for project <n>.
#
# which is not a failure at all but a standing fact about the project: guest
# attributes are off, in BOTH directions, so no host can publish a beacon and no
# job can publish a pin hold. Read as an ordinary failure it made every pin hold
# read as live and vetoed every drain and every recycle in the fleet, silently
# and permanently (2026-08-24 — see pin-hold-decision.sh).
#
# GREPPED FROM THE ERROR, AND NARROWLY. The constraint NAME is the fact; 412 on
# its own is not, and a bare 403 is the controller's own IAM, where a hold can
# still exist and keeping the host is right. `LC_ALL=C` because gcloud localises
# its message envelope but not the constraint id, and a locale-sensitive match
# is one that stops matching on somebody else's machine.
#
# The text can only ever come from gcloud on the controller. Nothing a job can
# write reaches it, which is what keeps this from being a way to talk the
# controller out of a veto.
guest_attributes_denied() {
  case "$(printf '%s' "${1:-}" | LC_ALL=C tr -d '\r')" in
    *constraints/compute.disableGuestAttributesAccess*) return 0 ;;
    *) return 1 ;;
  esac
}

# note_guest_attributes_denied — record one refusal for this tick.
#
# A FILE, AND NOT A VARIABLE, AND THAT IS THE WHOLE POINT. Both gates are called
# as `x=$(beacon_gate ...)` / `x=$(pin_hold_gate ...)`, which is a SUBSHELL:
# an ordinary shell increment inside either of them touches a copy that is
# discarded the moment the substitution closes, and the series would publish a
# confident zero on exactly the fleet it exists to report. The counter has to
# outlive the subshell, so it is a file the parent counts.
#
# Appended to rather than incremented, so two gates racing cannot lose a count
# to a read-modify-write, and truncated by tick_pool at the start of every tick.
GA_DENIED_FILE=""
note_guest_attributes_denied() {
  [ -n "$GA_DENIED_FILE" ] || return 0
  printf 'x\n' >>"$GA_DENIED_FILE" 2>/dev/null || true
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
  local errf

  # The error text is kept now, not discarded. The BEHAVIOUR here is unchanged
  # on purpose — unlike a pin hold, a beacon that cannot be read is the loss of
  # the only evidence this host is idle, so `keep` is still the right answer
  # whatever the reason. What was missing was any way to tell a fleet that will
  # never delete another Windows host from one that simply has nothing to
  # delete, and that is what the counter below buys.
  errf=$(mktemp 2>/dev/null) || errf=""
  raw=$(timeout 60 gcloud compute instances get-guest-attributes "$host" \
    --project="$PROJECT" --zone="$zone" --query-path="$BEACON_NS/" \
    --format="csv[no-heading](key,value)" 2>"${errf:-/dev/null}")
  rc=$?
  if [ "$rc" != "0" ] && [ -n "$errf" ] && guest_attributes_denied "$(cat "$errf")"; then
    note_guest_attributes_denied
    log "beacon: guest attributes are disabled by org policy -- $host cannot publish one, so it can never be drained on idleness"
  fi
  [ -z "$errf" ] || rm -f "$errf"

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
  local cached c_run="" c_exp=0 now verdict m_run m_exp errf disabled=0

  # No self-link, no zone, and a guessed zone addresses some other machine. The
  # read cannot happen, so this reads exactly as the read failing: keep.
  zone=$(zone_of_uri "$uri")
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
  errf=$(mktemp 2>/dev/null) || errf=""
  raw=$(timeout 60 gcloud compute instances get-guest-attributes "$host" \
    --project="$PROJECT" --zone="$zone" --query-path="$BEACON_NS/" \
    --format="csv[no-heading](key,value)" 2>"${errf:-/dev/null}")
  rc=$?
  # The one failure that is not a failure. Classified here, in the I/O half,
  # because the rule stays pure and because the CALLER is the only thing that
  # ever sees gcloud's error text.
  if [ "$rc" != "0" ] && [ -n "$errf" ] && guest_attributes_denied "$(cat "$errf")"; then
    disabled=1
    note_guest_attributes_denied
    log "pin-hold: guest attributes are disabled by org policy -- no hold can be published, so the veto on $host is not honoured"
  fi
  [ -z "$errf" ] || rm -f "$errf"

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
    "$now" "$PIN_HOLD_MAX" "$disabled")

  # The cache is written only from a read that SUCCEEDED. A failed read is not
  # evidence about a hold in either direction, and letting it rewrite the file
  # would let one API blip either forget a live hold or freeze a dead one.
  # `disabled` joins rc=0 as a state we are willing to write from, and it only
  # ever takes the drop arm: the policy is off, no hold can exist, and an entry
  # cached from before it landed would otherwise sit there vetoing this host
  # until it lapsed on its own.
  if [ "$rc" = "0" ] || [ "$disabled" = "1" ]; then
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
    "$STATE_DIR/pinhold-$host" "$STATE_DIR/partial-$host"
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

  beat

  collect_demand
  beat

  # Deliberately BEFORE the pool loop, unlike the single-pool controller that
  # ran it last. It is still the work nothing waits on — no host is drained and
  # no MIG resized on what it finds — but with N pools the flush is now shared,
  # so running it last would delay the flush for every pool rather than for the
  # one it belongs to. It carries its own budget and its own interval; on most
  # ticks it returns immediately.
  collect_outcomes
  beat

  # Same placement, same reasoning, as the outcome sweep: repository-wide, on
  # its own interval, and nothing in the pool loop waits on what it finds. It is
  # the only thing this controller does that is not about capacity at all — see
  # parked-decision.sh for why a fleet control plane is nonetheless the right
  # place for it.
  collect_parked
  beat

  # Same placement and the same contract again: project-wide, on its own
  # interval, and nothing in the pool loop waits on it. It is the only sweep here
  # that looks at the control plane rather than at the work — see
  # collect_apply_build() for why a pool controller is nonetheless the only thing
  # in the project that can see this.
  collect_apply_build
  beat
  local p
  for p in "${POOLS[@]}"; do
    pool_select "$p"
    tick_pool
    # One pool's walk is minutes of work on its own, so the next pool's turn is
    # a progress point in its own right.
    beat
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
  # Reads refused by constraints/compute.disableGuestAttributesAccess this tick,
  # across BOTH gates. Zero on a healthy pool and equal to the number of hosts
  # the controller tried to remove on a pool where the mechanism is off, so the
  # series answers "is my scale-in wired to a switch somebody threw at the org?"
  # — the question nobody could ask for the day this went unnoticed.
  #
  # The path is per POOL, not per controller: one controller serves up to four,
  # and a shared file would report the Linux pool's refusals under the Windows
  # pool's label as well. Truncated here, counted at publish.
  GA_DENIED_FILE="$STATE_DIR/ga-denied-$POOL"
  : >"$GA_DENIED_FILE" 2>/dev/null || GA_DENIED_FILE=""
  # Re-declared, not merely cleared: `declare -A` on an existing name keeps its
  # entries, so a plain assignment here would carry one pool's skips into the
  # next pool's tick on a controller that serves four of them.
  unset RECYCLE_SKIPS
  declare -gA RECYCLE_SKIPS=()

  collect_hosts
  # AFTER collect_hosts, and that ordering is the whole reason this is not part
  # of collect_demand: classify_pinned decides whether a pinned run is servable,
  # which is a question about which hosts are alive.
  # BEFORE classify_pinned, which reads MIG_BASE to tell a host this pool owns
  # from a host it never had. Under `set -u` reading it first does not misjudge
  # anything -- it kills the controller, and systemd restarts it into the same
  # tick for as long as the pinned job stays queued.
  collect_mig
  classify_pinned

  local pool_size=0 slots_busy=0 idle_max=0 draining=0 stale_hosts=0
  # Slots that answered, summed only over hosts the runner list could speak
  # about. slots_known is the denominator that goes with it: without it a blind
  # tick and a fleet-wide outage produce the same pair of numbers.
  local slots_registered=0 slots_known=0
  local host status host_tpl host_uri busy idle age verdict hold tpl cordoned recycling partial_for
  local skip_reason

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

    # Per HOST, not per pool. The walk is where a tick's minutes are actually
    # spent — a drain deregisters an agent, deletes an instance and waits on
    # both — and a sixteen-host pool walked at ten seconds a host is a tick the
    # watchdog would otherwise judge wedged halfway through.
    beat

    host_facts "$host"
    busy=$HOST_BUSY
    slots_busy=$((slots_busy + busy))

    idle=$(idle_seconds "$host" "$busy")
    [ "$idle" -gt "$idle_max" ] && idle_max=$idle
    age=$(host_age_seconds "$host")

    # SLOTS THAT ANSWER, over hosts old enough to have answered. A host still
    # inside its registration grace has not registered YET, and a host that is
    # not RUNNING is booting or on its way out; counting either as short of
    # slots would make ci_slots_missing non-zero through every ordinary scale
    # event, which is how a series stops being alerted on. A tick that could not
    # read the runner list contributes nothing to either side — HOST_PRESENT is
    # -1 there, and a blind tick must not read as an outage.
    if [ "$HOST_PRESENT" -ge 0 ] && [ "$status" = "RUNNING" ] &&
      [ "$age" -ge "$REGISTER_GRACE" ]; then
      slots_known=$((slots_known + SLOTS))
      slots_registered=$((slots_registered + HOST_PRESENT))
    fi

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

    partial_for=$(partial_seconds "$host" "$HOST_REG")

    verdict=$(recycle_decision "$status" "$tpl" "$busy" "$HOST_REG" \
      "$age" "$REGISTER_GRACE" "$recycling" "$RECYCLE_MAX_UNAVAILABLE" "$cordoned" \
      "$partial_for")

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
          # ONLY a host this tick actually COUNTED may be discounted. pool_size
          # was built from the RUNNING hosts alone in the walk above, so
          # subtracting for a host in any other state removes a host that was
          # never added -- see the note at the drain arm below, where the same
          # correction is made for the same reason.
          if [ "$status" = "RUNNING" ]; then
            pool_size=$((pool_size - 1))
          fi
          RETIRED=$((RETIRED + 1))
          rm -f "$STATE_DIR/cordon-$host"
        fi
        continue
        ;;
      skip:*)
        # WHY A SKIP IS COUNTED AT ALL. Until now only `cordoned` and `retired`
        # were published, so a recycle mechanism that skipped every host on
        # every tick produced exactly the same telemetry as one with nothing to
        # do — which is how a pool sat on a stale template for a day underneath
        # a `ci_hosts_stale_template` of 9 that was already screaming.
        #
        # ONLY WHILE THE TEMPLATE IS NOT CURRENT. `skip:template=current` is the
        # answer for every healthy host on every tick; counting it would publish
        # the pool size under a label that means nothing and bury the six that
        # do. A skip is interesting exactly when the mechanism HAD something to
        # do and did not do it.
        #
        # `partial` widens that, because the second recycle reason does not go
        # through the template at all: a host on a CURRENT template that has
        # lost registered capacity is precisely the case this mechanism was
        # extended to catch, and the ticks it spends inside the hysteresis
        # window are the only warning that it is about to act. Gated on the
        # template alone, those ticks would publish nothing and the eventual
        # delete would arrive with no run-up behind it.
        if [ "$tpl" != "current" ] || [ "$HOST_REG" = "partial" ]; then
          skip_reason=${verdict#skip:}
          skip_reason=${skip_reason%% *}
          skip_reason=${skip_reason%%=*}
          case "$skip_reason" in
            # Closed set, so the label can never be widened by a verdict string
            # somebody edits later without also editing the publisher.
            disabled | not-running | template | registration-unknown | booting | at-capacity | partial-grace) ;;
            *) skip_reason=other ;;
          esac
          RECYCLE_SKIPS["$skip_reason"]=$((${RECYCLE_SKIPS["$skip_reason"]:-0} + 1))
        fi
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
          # THE COUNT AND THE DISCOUNT MUST AGREE ON WHAT A HOST IS.
          #
          # pool_size counts RUNNING hosts and nothing else. drain_decision, by
          # contrast, deletes a TERMINATED or SUSPENDED host UNCONDITIONALLY --
          # that is rule 1, and it is correct: a host in that state is gone, and
          # waiting for it to go idle would wait forever. So the two disagree
          # about which hosts exist, and an unguarded decrement here subtracts a
          # host that was never added.
          #
          # Measured on ci-runner-host-telnet 2026-09-04: a pool of one whose
          # only host was already TERMINATED published ci_hosts_running = -1 and
          # ci_slots_total = -4 for the tick that reaped it. The slotsmissing policy
          # sends the on-call to read ci_slots_total next to ci_slots_registered to
          # size the gap, so a negative total is not cosmetic -- it inverts the
          # arithmetic they were sent to read.
          if [ "$status" = "RUNNING" ]; then
            pool_size=$((pool_size - 1))
          fi
        fi
        ;;
      *) : ;;
    esac
  done <<<"$HOSTS"

  # Runs AFTER the drain loop: drain_host() deregisters the agents of the hosts
  # it deletes, so reaping first would race its own bookkeeping.
  reap_orphan_registrations

  local target="$MIG_TARGET"

  # A merge-queue pool used to have a ceiling DERIVED from the repository's
  # `.mergify.yml` — `max_parallel_checks` x observed jobs-per-check — because
  # Mergify was a producer that published how much it would ask for. The merge
  # lane is not: it merges what is ready, one candidate at a time, and there is
  # no file anywhere that states a concurrency to read. So the ceiling is
  # Terraform's `max_hosts` and nothing else, which is what every pool in the
  # fleet has actually been running on since `.mergify.yml` was deleted — the
  # derivation failed open to exactly that and had been dead ever since.
  local demand_published="$DEMAND_TOTAL"

  # Still published, and still only for a merge-queue pool: this one is
  # OBSERVED from real runs rather than read from any configuration, so it
  # outlives the thing that used to consume it. It is what a human needs to
  # size `max_hosts` by hand now that nothing sizes it automatically.
  if [ "$POOL_ROLE" = "merge-queue" ]; then
    queue_series "ci_queue_jobs_per_check" "$POOL_JOBS_PER_CHECK"
  fi

  queue_series "ci_demand" "$demand_published"
  # Deliberately a SEPARATE series and not part of ci_demand: the autoscaler
  # consumes ci_demand, and a pinned job cannot be served by the host it would
  # buy. Published so that "the pool looks idle" and "the pool is full of work
  # nothing can scale for" stop reading identically on a dashboard.
  queue_series "ci_demand_pinned" "${DEMAND_PINNED:-0}"
  queue_series "ci_pinned_runs_cancelled" "${PIN_ORPHANED:-0}"
  queue_series "ci_pinned_jobs_host_vanished" "${PIN_VANISHED:-0}"
  queue_series "ci_demand_queued" "$DEMAND_QUEUED"
  # Queued jobs this pool has STOPPED answering for: older than DEMAND_MAX_AGE,
  # so they are not in ci_demand and not in ci_demand_wait_seconds either. This
  # is the series that keeps that subtraction honest -- without it a pool whose
  # repository is holding a run at an unapproved environment simply reports less
  # demand than the repository can see queued, and the two numbers disagreeing
  # with no third one to explain them is how a correct autoscaler gets blamed.
  # Sustained >0 is a repository problem to go and close, not a fleet problem.
  queue_series "ci_demand_expired" "$DEMAND_EXPIRED"
  # A FLOOR, kept even though the arithmetic above is now correct. These two
  # series are counts of things that exist, so a negative one is never a reading
  # -- it is a bug that has already happened, and it reaches an alert policy
  # before it reaches anybody who could fix it. The guard costs one comparison
  # and bounds the blast radius of the NEXT accounting mistake to a wrong number
  # rather than an inverted one. The log line is what stops it being silent.
  if [ "$pool_size" -lt 0 ]; then
    log "BUG: pool_size=$pool_size — clamped to 0 (a host was discounted that was never counted)"
    pool_size=0
  fi
  queue_series "ci_hosts_running" "$pool_size"
  # Published so saturation is expressible as a ratio in one alert policy that
  # works for every pool, rather than a per-pool threshold copied by hand.
  queue_series "ci_hosts_max" "$MAX_HOSTS"
  queue_series "ci_hosts_draining" "$draining"
  queue_series "ci_slots_total" "$((pool_size * SLOTS))"
  queue_series "ci_slots_busy" "$slots_busy"
  # CAPACITY THAT ANSWERS, and the gap. ci_slots_total is arithmetic —
  # hosts × slots — so it says what the pool was BUILT with and cannot say
  # whether any of it is reachable. Every failure in the #130 / #268 / #278
  # family is invisible in it: a host that registered nothing, a host whose slot
  # units died at ExecStartPre, a slot the sweep condemned and stopped. All
  # three subtract from ci_slots_registered, and the difference is the series to
  # alert on.
  queue_series "ci_slots_registered" "$slots_registered"
  queue_series "ci_slots_missing" "$((slots_known - slots_registered))"
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
  # The series that would have named the cause in one glance. Non-zero means
  # guest attributes are administratively off for this project: pin holds cannot
  # be published at all, and a Windows pool cannot report idleness, so it cannot
  # drain. Alert on ANY non-zero -- unlike a hold, this never resolves on its own
  # and no amount of waiting makes it lapse.
  # `wc -l`, not `grep -c .`: grep exits 1 on an empty file and would need an
  # `|| echo 0` that appends a SECOND line to a count that is already 0. wc
  # counts without an opinion — the same reasoning as POOL_TABLE_REJECTED.
  local ga_denied=0
  if [ -n "$GA_DENIED_FILE" ] && [ -f "$GA_DENIED_FILE" ]; then
    ga_denied=$(wc -l <"$GA_DENIED_FILE" 2>/dev/null | tr -d ' ')
    case "${ga_denied:-}" in '' | *[!0-9]*) ga_denied=0 ;; esac
  fi
  queue_series "ci_guest_attributes_denied" "$ga_denied"
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
  # And the refusals, on the SAME series, so one chart reads as an accounting:
  # every stale host this tick either moved or is named here with the reason it
  # did not. Published as a fixed set including the zeroes -- a reason that
  # appears only when it fires is a reason nobody can build an alert on, because
  # the absence of the series and the absence of the problem look identical.
  local reason
  for reason in disabled not-running template registration-unknown booting at-capacity partial-grace other; do
    queue_series "ci_recycle_verdicts" "${RECYCLE_SKIPS["$reason"]:-0}" \
      "\"outcome\":\"skip-$reason\""
  done
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

  # Pull requests that are green and can never enter the merge queue. A
  # REPOSITORY fact published under every pool's label, exactly like the
  # heartbeat above and for the same reason — a pool whose series merely stop
  # reads as an idle pool. Read it with max() across pools, never sum(): four
  # pools publishing the same repository's count would otherwise report four
  # times the parked pull requests.
  #
  # Every reason is published every tick, 0 included. A series that appears only
  # when something is parked cannot be told apart from a sweep that never ran,
  # and "the sweep never ran" is precisely the state this whole feature exists
  # to stop being invisible.
  local r
  for r in "${PARKED_REASONS[@]}"; do
    queue_series "ci_prs_green_and_unqueued" "${PARKED_COUNT[$r]:-0}" "\"reason\":\"$r\""
  done
  # What makes the zero above readable. Non-zero means the sweep ran out of
  # budget or hit its ceiling, so the count is a lower bound rather than an
  # answer — the same contract as ci_demand_runs_skipped.
  queue_series "ci_parked_prs_skipped" "$PARKED_SKIPPED"
  # And what makes the zero UNREADABLE if it is missing. Non-zero here means the
  # sweep was refused rather than delayed: the count above is not a lower bound,
  # it is nothing at all, and no number of further sweeps will improve it. This
  # is the series to alert on, because a repository whose installation lacks
  # `checks: read` publishes an unbroken zero from every other series in this
  # block — which is exactly what a repository with nothing parked publishes.
  queue_series "ci_parked_sweep_denied" "$PARKED_DENIED"

  # Whether this project is still receiving runner infrastructure. A PROJECT
  # fact published under every pool's label, for the same reason the heartbeat
  # is — read it with max() across pools, never sum().
  #
  # Age rather than a timestamp, so one threshold works in every project: alert
  # above two of whatever `apply_schedule` that project uses. It is the half that
  # catches a trigger which stopped firing, and there is no failure to find in
  # that case, which is why it is not enough to publish the status alone.
  queue_series "ci_apply_build_age_seconds" "$APPLY_BUILD_AGE"
  # 1 means the newest apply build did not succeed. Includes the refusal this
  # was built for, whose FAILURE lasts a fraction of a second and writes no log.
  queue_series "ci_apply_build_failed" "$APPLY_BUILD_FAILED"
  # And the two series that decide whether the zeros above can be believed.
  # `missing` is the trigger not firing at all; `denied` is the check itself
  # being refused, which leaves the two numbers above frozen at whatever the last
  # sweep that worked found. Both published every tick, 0 included — a series
  # that appears only when it fires cannot be told apart from a controller that
  # stopped publishing, which is the failure this whole collector exists to end.
  queue_series "ci_apply_build_missing" "$APPLY_BUILD_MISSING"
  queue_series "ci_apply_check_denied" "$APPLY_CHECK_DENIED"
}

# --- install / run -----------------------------------------------------------

install_self() {
  mkdir -p "$STATE_DIR" /opt/ci-controller
  install -m 0755 "$0" "$SELF_INSTALL"

  # jq is the one runtime dependency not in the base image. Installed here,
  # once, on a 2-vCPU always-on VM — not in any build path. python3-yaml used
  # to be installed beside it for the Mergify configuration reader; that reader
  # is gone and it was the only user, so the controller no longer needs a YAML
  # parser at all.
  if ! command -v jq >/dev/null 2>&1; then
    apt-get update -qq >>"$LOG" 2>&1
    apt-get install -y -qq jq >>"$LOG" 2>&1 || true
    command -v jq >/dev/null 2>&1 \
      || log "jq is still missing after install — the controller cannot parse any GitHub response and every tick will be blind"
  fi

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

  # --- liveness responder (#308) ---------------------------------------------
  #
  # Installed ONLY when the root asked for autohealing. Without it no port is
  # opened, which is the default and the state every controller in the fleet is
  # in until an operator changes it.
  #
  # What it answers matters more than that it answers. The managed group's
  # health check is the one thing in this design authorised to DELETE the
  # control plane, so a responder that returns 200 merely because a process is
  # listening would license a rebuild loop against a controller that is fine,
  # and license nothing against one that is wedged — the wedge keeps the socket
  # open. So the verdict is the heartbeat's age, the same file the watchdog
  # reads, against a threshold deliberately WIDER than the watchdog's: the
  # watchdog restarts a unit, this deletes a machine, and the cheaper remedy
  # must get first refusal.
  if [ -n "$HEALTH_PORT" ]; then
    # The heartbeat file must EXIST before the responder starts, because the
    # unit below bind-mounts that one path into an otherwise empty view of
    # /var/lib. A bind source that is absent at unit start is absent for the
    # life of the process — `Restart=always` never fires, since a responder
    # answering 503 has not exited — so a controller installed a moment before
    # its first tick would answer 503 forever and the group would delete it on a
    # loop. Touching it here is not a lie about liveness: the controller service
    # is restarted a few lines below and overwrites it within one tick, and if
    # that never happens the file ages out and the verdict flips to 503 exactly
    # as it should.
    touch "$STATE_DIR/heartbeat" 2>/dev/null || true

    cat >/opt/ci-controller/livez.py <<LIVEZEOF
import http.server, os, time

HB = "$STATE_DIR/heartbeat"
THRESHOLD = $((wd_threshold * 3))

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/livez":
            self.send_response(404); self.end_headers(); return
        try:
            age = int(time.time() - os.stat(HB).st_mtime)
        except OSError:
            # No heartbeat file yet. The group's initial_delay_sec covers a
            # controller that has not reached its first tick; past that, an
            # absent heartbeat is the same as an ancient one.
            age = THRESHOLD + 1
        ok = age < THRESHOLD
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(("age=%d threshold=%d\n" % (age, THRESHOLD)).encode())

    def log_message(self, *a):
        # A probe every 30s, forever. Logging it buries the controller's own log.
        pass

http.server.HTTPServer(("0.0.0.0", $HEALTH_PORT), H).serve_forever()
LIVEZEOF
    chmod 0644 /opt/ci-controller/livez.py

    cat >/etc/systemd/system/ci-controller-livez.service <<'LIVEZSVCEOF'
[Unit]
Description=CI controller liveness responder — 200 while the tick heartbeat is fresh

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/ci-controller/livez.py
Restart=always
RestartSec=10
# It reads one file's mtime and writes a fixed string. Nothing it does needs
# the controller's identity, and it is the only thing on this VM listening on a
# port, so it runs as nobody.
#
# AND IT IS THE ONLY UNPRIVILEGED PROCESS ON THIS MACHINE. Before #308 the
# controller ran nothing but root's own loop; adding a socket listener changed
# what a bug in that listener would be worth. `$STATE_DIR` is created 0755 by
# root and holds `api.body` — the last GitHub response, which on a private
# repository is repository data — so "runs as nobody" alone would leave a
# network-facing process able to read it.
#
# TemporaryFileSystem + BindReadOnlyPaths is the narrow answer: an empty tmpfs
# is mounted over /var/lib inside this unit's namespace and exactly one path is
# bound back in, read-only. The responder therefore sees the heartbeat and
# NOTHING else under /var/lib — not api.body, not the drain counters. Everything
# below it removes a capability the responder demonstrably does not use.
User=nobody
Group=nogroup
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
TemporaryFileSystem=/var/lib:ro
BindReadOnlyPaths=/var/lib/ci-controller/heartbeat
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
# MemoryDenyWriteExecute is deliberately NOT set. It is the one hardening on
# this list that breaks interpreters rather than merely constraining them, and
# a responder that fails to start is a probe that never answers, which is a
# group deleting a healthy controller every few minutes. The blast radius of
# each setting here is judged against that, not against a static checklist.
CapabilityBoundingSet=
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
LIVEZSVCEOF
  else
    # Autohealing was turned OFF on a controller that previously had it on. The
    # unit file survives the reboot on the boot disk, so leaving it alone would
    # keep the port open after the operator asked for it to close.
    if [ -f /etc/systemd/system/ci-controller-livez.service ]; then
      systemctl disable --now ci-controller-livez.service >>"$LOG" 2>&1 || true
      rm -f /etc/systemd/system/ci-controller-livez.service /opt/ci-controller/livez.py
      log "liveness responder removed — autohealing is off"
    fi
  fi

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
  if [ -n "$HEALTH_PORT" ]; then
    systemctl enable ci-controller-livez.service >>"$LOG" 2>&1 || true
    # RESTART for the same reason as the controller above: the previous
    # version's livez.py is already on disk and its unit already running, so
    # `enable --now` would leave the old responder serving the new threshold.
    systemctl restart ci-controller-livez.service >>"$LOG" 2>&1 || true
  fi
  log "controller installed for $REPO_FULL pool=$POOL mig=$MIG poll=${POLL}s grace=${GRACE}s slots=$SLOTS watchdog=${wd_threshold}s livez=${HEALTH_PORT:-off}"
}

run_loop() {
  log "controller loop starting"
  while true; do
    # The loop's own two beats, around a tick that now also beats at every
    # phase boundary of its own (see beat()). Writing it ONLY here — before and
    # after — was the 2026-09-03 bug: the age was then the elapsed time of the
    # tick in progress, a slow tick was indistinguishable from a wedged one,
    # and the watchdog's restart killed the tick before it could write the file
    # that would have stopped the restarting (see watchdog-decision.sh). These
    # two stay because they cover what the tick itself cannot: the sleep
    # between ticks, and a tick that fails before its first phase.
    beat
    tick || log "tick failed"
    # After it too, so an ordinary tick keeps the file at most one tick old
    # rather than one tick plus its own duration.
    beat
    sleep "$POLL"
  done
}

case "${1:-}" in
  --loop) run_loop ;;
  *) install_self ;;
esac
