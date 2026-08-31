#!/usr/bin/env bash
# ensure-alert-policies.sh — make one project's CI-runner alerting match the fleet.
#
# WHY THIS EXISTS (2026-08-14):
#   The four runner alert policies were created by hand in ONE project and never
#   replicated. Six of the seven pools — every pool in the other organisation
#   plus the three product projects — published the metrics to Cloud Monitoring
#   with nothing watching them. The pools were instrumented; only one of them was
#   MONITORED, and the difference is invisible from inside the pool: the series
#   exist either way. Hand-created observability does not roll out, so this is a
#   script that any project can be brought up to date with, run repeatedly.
#
#   It is also how `ci_runner_list_blind_ticks` reaches the fleet. That metric is
#   the reason for the exercise: a controller that cannot read the GitHub runner
#   list suspends scale-in while the heartbeat keeps saying 1.
#
# Idempotent: policies are matched by displayName and UPDATED in place, so a
# threshold change is a re-run, not a delete-and-recreate that drops the incident
# history and leaves a window with no policy at all.
#
# Usage:
#   ensure-alert-policies.sh --project <id> [--email <addr>] [--account <sa-email>]
#                            [--poll-interval-seconds <n>] [--cache-stale-hours <n>]
#                            [--register-grace-seconds <n>] [--drain-grace-seconds <n>]
#                            [--dry-run]
#
#   --email is OPTIONAL, and omitting it is what lets an unattended build run
#   this. With no address the script ADOPTS the project's existing email
#   notification channel — the one every policy in that project already pages —
#   and refuses to guess when there is none or more than one. An address is
#   still required to BOOTSTRAP a project that has never had a channel, because
#   inventing one would silently point thirteen policies at nobody.
#
#   --poll-interval-seconds must match the pool's `poll_interval_seconds`: the
#   slow-tick threshold is derived from it, because the watchdog window is.
#
#   --register-grace-seconds and --drain-grace-seconds must match the pool's
#   variables of the same name. THIS IS NOT DECORATION, and getting it wrong is
#   what made this script's own alerting unreadable for a fortnight: both of the
#   thresholds below are statements about how long the pool is ALLOWED to take,
#   so a literal that disagrees with the pool pages on supported behaviour. See
#   the queue and idle policies for the derivation in each case.
#
#   --cache-stale-hours must be BELOW the pool's `cache_snapshot_max_age_hours`.
#   Set at or above it, the alert fires only once hosts have already started
#   refusing the snapshot — which is the outage, not the warning.
#
#   --account selects a per-command identity for a project in another
#   organisation. It is never exported: GOOGLE_APPLICATION_CREDENTIALS is shared
#   with every other session on this host and must not be mutated.
set -euo pipefail

PROJECT=""; EMAIL=""; ACCOUNT=""; DRY=0
# The slow-tick threshold is NOT a constant of the fleet. The watchdog fires at
# max(300, poll_interval_seconds * 10), so a pool polling every 60s has a 600s
# window and healthy 200s ticks there are fine — a fixed 150s would page for a
# supported configuration, and the documented remedy (raise poll_interval_seconds)
# would not clear it. Pass half the pool's watchdog threshold; the default is
# half of the default window.
POLL=20
# Well under the module's default cache_snapshot_max_age_hours of 168: a daily
# publish that has missed two days is a broken publish, and the two days of
# warning are the whole point — at 168 the first notification a human gets is
# every host in the pool starting cold.
CACHE_STALE_HOURS=48
# Both mirror the ci-runner-host-pool defaults. A pool that sets its own must
# pass it here too; the two policies that read them say what goes wrong if it
# does not.
REGISTER_GRACE=600
DRAIN_GRACE=900
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --email)   EMAIL="$2";   shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --poll-interval-seconds) POLL="$2"; shift 2 ;;
    --cache-stale-hours) CACHE_STALE_HOURS="$2"; shift 2 ;;
    --register-grace-seconds) REGISTER_GRACE="$2"; shift 2 ;;
    --drain-grace-seconds) DRAIN_GRACE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }
# --email is NOT validated here. An empty address means "adopt whatever channel
# this project already pages", which cannot be decided until the channels have
# been listed — see the notification-channel section below.
case "$POLL" in ''|*[!0-9]*) echo "--poll-interval-seconds must be a whole number of seconds" >&2; exit 2 ;; esac
[ "$POLL" -ge 1 ] || { echo "--poll-interval-seconds must be >= 1" >&2; exit 2; }
case "$CACHE_STALE_HOURS" in ''|*[!0-9]*) echo "--cache-stale-hours must be a whole number of hours" >&2; exit 2 ;; esac
[ "$CACHE_STALE_HOURS" -ge 1 ] || { echo "--cache-stale-hours must be >= 1" >&2; exit 2; }
case "$REGISTER_GRACE" in ''|*[!0-9]*) echo "--register-grace-seconds must be a whole number of seconds" >&2; exit 2 ;; esac
[ "$REGISTER_GRACE" -ge 1 ] || { echo "--register-grace-seconds must be >= 1" >&2; exit 2; }
case "$DRAIN_GRACE" in ''|*[!0-9]*) echo "--drain-grace-seconds must be a whole number of seconds" >&2; exit 2 ;; esac
[ "$DRAIN_GRACE" -ge 1 ] || { echo "--drain-grace-seconds must be >= 1" >&2; exit 2; }

# Same expression the module and the watchdog use, as a pure function so the
# self-test can exercise the deployed text rather than a copy of it.
# watchdog_threshold <poll_interval_seconds> -> seconds
watchdog_threshold() {
  local t=$(( $1 * 10 ))
  [ "$t" -lt 300 ] && t=300
  echo "$t"
}
WATCHDOG_THRESHOLD="$(watchdog_threshold "$POLL")"
# Four fifths of the watchdog window, not half of it. Half is not a precursor,
# it is the middle of the healthy range: a pool polling every 20s has a 300s
# window, and 150s ticks are ordinary on a busy repository — measured over one
# week on this fleet, the slow-tick policy opened ten incidents and every one of
# them peaked at 179s, comfortably inside a window nothing was close to
# exhausting. At four fifths the alert keeps a full tick of warning before the
# watchdog restarts anything and stops claiming a healthy tick is an emergency.
SLOW_TICK=$(( WATCHDOG_THRESHOLD * 4 / 5 ))
# ONE ALIGNMENT WINDOW BEYOND THE POOL'S OWN BOOT BUDGET, and nothing shorter is
# defensible. register_grace_seconds is the pool's statement of how long a host
# may take from creation to its last agent registering; a job that arrives at a
# pool scaled to zero cannot be served before that time has passed, by
# definition. The old literal of 600 equalled the Linux boot budget exactly, so
# every cold start raced its own alert — and on Windows, where the module floors
# the grace at 1200, it fired at half the permitted boot time. Two pools in this
# fleet sit at zero almost always, so almost every job there was a cold start:
# they produced 72 of the 184 incidents measured in the week before this change
# while serving barely a host of real work.
QUEUE_WAIT=$(( REGISTER_GRACE + 300 ))
# Same shape against the drain side: drain_grace_seconds is how long a host may
# sit idle before the controller is expected to drain it, so the alert has to
# start one window after that and not at a literal that a pool with a wider warm
# window would breach continuously.
IDLE_THRESHOLD=$(( DRAIN_GRACE + 300 ))

# The corporate proxy blackholes the token endpoint; without this every call
# below fails as an auth error rather than a network one, which sends the reader
# looking at IAM.
export no_proxy="googleapis.com,*.googleapis.com,localhost,127.0.0.1,::1,.local"
export NO_PROXY="$no_proxy"

g() {
  if [ -n "$ACCOUNT" ]; then gcloud "$@" --project="$PROJECT" --account="$ACCOUNT"
  else gcloud "$@" --project="$PROJECT"; fi
}

# ── the Monitoring API, over REST rather than `gcloud alpha` ─────────────────
# Channels and policies used to go through `gcloud alpha monitoring`. That group
# is not part of a default Cloud SDK install, and on a machine where the SDK
# lives somewhere the operator cannot write — Program Files on Windows, a
# root-owned /usr/lib on a locked-down host — `gcloud components install alpha`
# fails outright. There is no fallback in that state: the script cannot run at
# all, which is how this project ended up with six of its nine policies
# provisioned and the three cache alerts missing for a week without anyone
# noticing the script had stopped being runnable.
#
# The descriptor code below already spoke REST for its own reason (there is no
# `gcloud monitoring metrics-descriptors` group in ANY track). Using the same
# transport for channels and policies removes the surprise install dependency
# and makes every call in this script fail the same way when auth is wrong.
# Minted once, not per call. There are now upwards of twenty API calls in a full
# run (fifteen policies, twenty-two descriptors, two listings), and `gcloud auth
# print-access-token` is a Python process launch each time — on a machine behind
# the corporate proxy that was the dominant cost of the run and, worse, twenty
# more chances to fail on a network blip in the middle of provisioning. An
# access token is good for an hour; a run that takes an hour has a bigger
# problem than a stale token.
_TOKEN=""
api_token() {
  if [ -z "$_TOKEN" ]; then
    if [ -n "$ACCOUNT" ]; then _TOKEN="$(gcloud auth print-access-token --account="$ACCOUNT")"
    else _TOKEN="$(gcloud auth print-access-token)"; fi
  fi
  printf '%s' "$_TOKEN"
}

MON_API="https://monitoring.googleapis.com/v3/projects"

# mon <METHOD> <path-under-project> [body-file] — body to $tmp/api.out, prints
# the HTTP status. The caller decides what a status means; nothing here treats a
# non-2xx as success, because a policy that silently failed to create is exactly
# the failure this whole script exists to prevent.
mon() {
  local method="$1" path="$2" body="${3:-}" token retry=()
  token="$(api_token)"
  [ -n "$token" ] || { echo "no access token — is the proxy bypass set?" >&2; return 1; }
  # Retries on GET and PATCH only. Both are idempotent, and the observed failure
  # here is a CONNECT timeout through the corporate proxy — a request that never
  # reached the server, which is precisely what is safe to repeat. POST gets
  # none: `curl --retry` also retries a 5xx, and a 5xx on `alertPolicies.create`
  # may well have created the policy, so retrying it would leave two copies and
  # page twice. A POST that fails is instead recovered by re-running the script,
  # which lists first and finds whatever did get created.
  case "$method" in
    GET|PATCH) retry=(--retry 3 --retry-delay 3 --retry-connrefused) ;;
  esac
  if [ -n "$body" ]; then
    curl -sS --connect-timeout 20 --max-time 60 "${retry[@]}" \
      -o "$tmp/api.out" -w '%{http_code}' \
      -X "$method" "$MON_API/$PROJECT/$path" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      --data-binary "@$body"
  else
    curl -sS --connect-timeout 20 --max-time 60 "${retry[@]}" \
      -o "$tmp/api.out" -w '%{http_code}' \
      -X "$method" "$MON_API/$PROJECT/$path" \
      -H "Authorization: Bearer $token"
  fi
}

# The two listings below need `displayName<TAB>name` pairs out of a JSON page.
# Named rather than inlined twice, and fail-closed: a missing python3 must stop
# the script, not read as "no channels and no policies exist" — which would
# create a duplicate channel and a second copy of all thirteen policies.
json_pairs() {  # <collection key> <name field> — reads $tmp/api.out
  command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required to read the Monitoring API response" >&2; return 1; }
  python3 - "$1" "$2" "$tmp/api.out" <<'PY'
import json, sys
key, field, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
for item in doc.get(key) or []:
    print("%s\t%s\t%s" % (item.get(field, ""), item.get("name", ""),
                          (item.get("labels") or {}).get("email_address", "")))
PY
}

tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

# ── notification channel ──────────────────────────────────────────────────────
# Matched on the address, not the display name: a second channel to the same
# inbox produces duplicate pages, and a policy pointing at a channel that was
# renamed still works.
#
# `|| true` on the lookup, not on the create: a project with no channels yet is
# the normal first run, and gcloud exits non-zero on some empty filters. A failed
# CREATE must still stop the script — a policy pointing at nothing is a policy
# that cannot page.
#
# Matched client-side. The server-side filter rejects an unquoted address --
# `labels.email_address=a@b` reads `email` as a field reference -- and the API
# reports that as INVALID_ARGUMENT, which when swallowed is indistinguishable
# from "no such channel". The script would then create a duplicate channel on
# every run and every alert would page twice.
#
# A LIST that fails must stop the script for the same reason: "the call errored"
# and "there are no channels" are the same empty string, and guessing the second
# is what produces the duplicate.
ch_status="$(mon GET 'notificationChannels?pageSize=1000')"
[ "$ch_status" = "200" ] || {
  echo "$PROJECT: cannot list notification channels (HTTP $ch_status)" >&2
  sed -n '1,20p' "$tmp/api.out" >&2; exit 1; }
# No address given: adopt the one this project already pages. This is the mode
# an unattended apply runs in, and the reason the whole script can now be a
# build step rather than something an operator has to remember — a project is
# brought up to date without anyone naming an inbox in ten terraform roots.
#
# It refuses to guess in both directions, and neither refusal is pedantry.
# ZERO channels is a project that has never been bootstrapped: creating one
# would need an address, and the only address available to a build is one it
# invented. MORE THAN ONE is worse than ambiguous — picking either silently
# gives thirteen policies a destination that half the people who set this
# project up do not read, and the incident that proves it is the one nobody
# was paged for.
if [ -z "$EMAIL" ]; then
  adopted="$(json_pairs notificationChannels type \
    | awk -F'\t' '$1=="email" && $3!="" {print $3}' | sort -u)"
  n="$(printf '%s\n' "$adopted" | grep -c . || true)"
  case "$n" in
    1) EMAIL="$adopted"; echo "adopting this project's existing email channel: $EMAIL" ;;
    0) echo "$PROJECT: no email notification channel exists, so there is nothing to adopt — re-run with --email <addr> once to bootstrap it" >&2; exit 2 ;;
    *) echo "$PROJECT: $n email notification channels exist and this script will not choose between them — re-run with --email <addr>:" >&2
       printf '%s\n' "$adopted" | sed 's/^/  /' >&2; exit 2 ;;
  esac
fi

channel="$(json_pairs notificationChannels type \
  | awk -F'\t' -v e="$EMAIL" '$1=="email" && $3==e {print $2; exit}')"

if [ -z "$channel" ]; then
  if [ "$DRY" = "1" ]; then
    echo "would create email channel for $EMAIL in $PROJECT"; channel="DRY-RUN-CHANNEL"
  else
    cat >"$tmp/channel.json" <<EOF
{ "type": "email",
  "displayName": "CI runners oncall",
  "description": "Destination for every CI warm-host runner alert in this project.",
  "labels": { "email_address": "$EMAIL" } }
EOF
    cr_status="$(mon POST notificationChannels "$tmp/channel.json")"
    [ "$cr_status" = "200" ] || {
      echo "$PROJECT: cannot create the notification channel (HTTP $cr_status)" >&2
      sed -n '1,20p' "$tmp/api.out" >&2; exit 1; }
    channel="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["name"])' "$tmp/api.out")"
    echo "created channel $channel"
  fi
else
  echo "channel exists: $channel"
fi

# ── the thirteen policies ────────────────────────────────────────────────────────
# `duration` is what stops each of these paging on a blip, and every controller
# threshold below is deliberately longer than one controller tick.
#
# The two CACHE policies are the exception, and deliberately: their series are
# published once per host BOOT, not once per tick. A `duration` of 600s asks a
# sporadic series to hold a condition across windows it publishes nothing in, so
# it would silence exactly the pool that is failing quietly — few boots, every
# one of them broken. They use duration 0s over a wide alignment window instead,
# which is the same anti-blip guarantee expressed in the units the series has:
# one bad boot in the window is enough, because one bad boot is already the
# whole population.
policy_json() {  # <key> -> a full alertPolicy body on stdout
  case "$1" in
    heartbeat) cat <<EOF
{ "displayName": "CI runners / controller dead (no heartbeat 10m)",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "The CI warm-host controller stopped reporting. Jobs will queue and the pool will not scale. Since #308 the controller is a managed group of size 1, so a DELETED one is rebuilt on its own and this alert should clear within a few minutes -- one that does not clear is a controller that boots and cannot tick, not a missing machine. Find the VM with 'gcloud compute instance-groups managed list-instances <name>-controller' (the instance name carries a suffix and changes on every rebuild) and read its ci-controller.service." },
  "conditions": [ { "displayName": "ci_poller_heartbeat absent for 10m",
    "conditionAbsent": { "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_poller_heartbeat\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MEAN" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    blind) cat <<EOF
{ "displayName": "CI runners / scale-in suspended (controller blind to the runner list)",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "The controller cannot read the GitHub runner list, so every host reads reg=unknown and NOTHING is drained. That is the correct fail-safe — a host that cannot be proven idle must not be deleted mid-job — but the pool now holds its hosts indefinitely and the heartbeat still reports 1, so nothing else will tell you. Check the GitHub App installation, the token, and egress from the controller. Fires only on a sustained run: a single blind tick is ordinary API noise." },
  "conditions": [ { "displayName": "ci_runner_list_blind_ticks > 3 for 10m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 3.0, "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_runner_list_blind_ticks\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    idle) cat <<EOF
{ "displayName": "CI runners / pool not scaling to zero (unpinned idle host)",
  "combiner": "AND_WITH_MATCHING_RESOURCE",
  "documentation": { "mimeType": "text/markdown", "content":
    "A warm host with no pin on it has been idle past this pool's drain threshold of ${DRAIN_GRACE}s and was not removed — scale-to-zero is broken and the pool is burning money. Check controller drain logs and the MIG autoscaler. If ci_runner_list_blind_ticks is also non-zero, THAT is the cause and this alert is a symptom.\n\nTHE SECOND CONDITION IS WHAT MAKES THIS READABLE. Idle time alone does not mean a host should have gone: pull-request host affinity holds a host for its pull request deliberately, and such a host reports exactly the idle seconds of one the drain loop forgot. Measured over a week on the busiest repository in this fleet, ci_pin_holds_honoured was non-zero for 565 of 1609 samples on one pool and 508 of 800 on the other — which accounted for very nearly every sample where idle time passed the threshold. On idle time alone this policy opened twenty incidents in that week and every one of them was affinity working as designed, so requiring BOTH conditions on the same resource is the difference between an alert about scale-to-zero and an alert about the pool being used.\n\nAND_WITH_MATCHING_RESOURCE, not AND: the controller publishes both series per pool under a generic_node whose namespace IS the pool name, so matching on the resource is what keeps a pin on one pool from silencing an idle host on another." },
  "conditions": [ { "displayName": "ci_host_idle_seconds_max > ${IDLE_THRESHOLD} for 10m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": ${IDLE_THRESHOLD}.0, "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_host_idle_seconds_max\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } },
    { "displayName": "ci_pin_holds_honoured < 1 for 10m",
    "conditionThreshold": { "comparison": "COMPARISON_LT", "thresholdValue": 1.0, "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_pin_holds_honoured\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    queue) cat <<EOF
{ "displayName": "CI runners / queue starved (job waiting past the boot budget)",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "A queued job has waited ${QUEUE_WAIT}s without a slot — this pool's register_grace_seconds of ${REGISTER_GRACE}s plus one alignment window, which is the longest a COLD start is allowed to take. Either the pool hit max_hosts, hosts failed to boot, or the runner agent is offline. Compare ci_hosts_running with ci_mig_target_size, then read the host serial logs.\n\nThe threshold is derived rather than fixed because the fixed one was wrong in the only way that matters: at 600s it equalled the Linux boot budget exactly, so a single job arriving at a pool scaled to zero raced its own alert, and on a Windows pool — where the module floors register_grace_seconds at 1200 — it fired at half the boot time the pool was configured to permit. Pass --register-grace-seconds whenever the pool overrides it.\n\nBEFORE BELIEVING THIS ONE, LOOK AT HOW LONG THE WAIT IS, AND AT THE CLOCK. A wait that equals the time since UTC midnight is the controller reporting the age of midnight, not the age of a job: the demand sweep writes a sentinel into the stamp column for a run with no queued job, and GNU date resolves that sentinel — and 0, and Z, and the empty string — to today at 00:00:00 with exit status 0. Fixed in #518 by testing the token's shape before parsing it; a pool still reporting the sawtooth is running a controller from an instance template cut before that, so check the template's date before investigating the pool. Otherwise a wait of hours on a pool with spare max_hosts is genuine: list the repository's queued runs by age and find what no host will take." },
  "conditions": [ { "displayName": "ci_queue_wait_seconds_max > ${QUEUE_WAIT} for 15m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": ${QUEUE_WAIT}.0, "duration": "900s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_queue_wait_seconds_max\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    drain) cat <<EOF
{ "displayName": "CI runners / drain failing",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "The controller's drain loop is erroring. Hosts either leak (cost) or are deleted mid-job (flaky CI). Read the drain verdicts in the controller log." },
  "conditions": [ { "displayName": "ci_drain_verdicts{outcome=error} > 0 for 15m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "900s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_drain_verdicts\" AND resource.type=\"generic_node\" AND metric.labels.outcome=\"error\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    slowtick) cat <<EOF
{ "displayName": "CI runners / tick approaching the watchdog threshold",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "A controller tick is taking longer than ${SLOW_TICK}s — four fifths of this pool's watchdog threshold of ${WATCHDOG_THRESHOLD}s (max(300, poll_interval_seconds * 10), with poll_interval_seconds=${POLL}). This is the precursor to a total blackout, not a slowdown: once a tick outlasts the threshold the watchdog restarts the controller mid-tick, the restart prevents the heartbeat that would have stopped it, and every series — heartbeat included — goes absent while systemd still reports active (running). Two pools in this fleet ran that way for hours on 2026-08-14. Demand costs one API call per active workflow run, so the usual cause is a busier repository; lower demand_budget_seconds, or raise poll_interval_seconds AND re-run this script so the threshold follows the wider watchdog window. Check ci_demand_runs_skipped.\n\nFour fifths and not half, which is what this was until it was measured: half the window is the middle of the healthy range, not a precursor to anything. A pool polling every 20s has a 300s window, and a 150s tick is ordinary on a busy repository — over one week this policy opened ten incidents at half and every one of them peaked at 179s, nowhere near exhausting a window nothing was close to exhausting. At four fifths there is still a full tick of warning before the watchdog restarts anything." },
  "conditions": [ { "displayName": "ci_tick_seconds > ${SLOW_TICK} for 10m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": ${SLOW_TICK}.0, "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_tick_seconds\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    cachestale) cat <<EOF
{ "displayName": "CI runners / cache snapshot going stale",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "Hosts are booting on a shared-cache snapshot older than ${CACHE_STALE_HOURS}h, so the publishing run has stopped producing one. Nothing is broken yet — a stale snapshot is still hydrated, and hosts keep serving jobs — which is why this needs an alert: the failure is a scheduled workflow that quietly stopped, and it stays invisible until the age passes the pool's cache_snapshot_max_age_hours and every host starts cold. Check the publish-cache-snapshot workflow's last run and the pointer object (gcloud storage cat gs://<bucket>/cache/<pool>/current). Read next to ci_cache_snapshot_bytes: a snapshot that stopped growing is a publish that started failing before this did." },
  "conditions": [ { "displayName": "ci_cache_snapshot_age_hours > ${CACHE_STALE_HOURS}",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": ${CACHE_STALE_HOURS}.0, "duration": "0s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_cache_snapshot_age_hours\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "3600s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    cachefail) cat <<EOF
{ "displayName": "CI runners / cache hydrate failing on a configured pool",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "Hosts in a pool that HAS a snapshot bucket are registering without the shared cache. The layer fails open by design, so nothing is red: jobs run, they just run cold, and the only other symptom is CI getting slower over weeks. The verdict label says which of the dozen exits was taken — no-snapshot and bad-pointer mean the publish side, too-old, too-big and too-big-expanded mean a bound (the last one means the archive decompressed to more than eight times its own size, so the host refused it rather than unpack part of it), download-timeout and unpack-timeout mean cache_hydrate_budget_seconds is too small for the snapshot's size, scan-refused means the archive failed the host's own safety scan and SHOULD be investigated as a publish that produced something a host would not unpack. not-configured is excluded here: it is the correct steady state for a pool with no bucket, and paging on it would page every pool that never wanted this feature — a host that could not READ its configuration reports no-metadata-server instead, which is included. Read /var/log/ci-runner-startup.log on a recent host." },
  "conditions": [ { "displayName": "ci_cache_hydrate_verdict{verdict!=hydrated,not-configured} > 0",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "0s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_cache_hydrate_verdict\" AND resource.type=\"generic_node\" AND metric.labels.verdict!=\"hydrated\" AND metric.labels.verdict!=\"not-configured\"",
      "aggregations": [ { "alignmentPeriod": "3600s", "perSeriesAligner": "ALIGN_SUM" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    slotsmissing) cat <<EOF
{ "displayName": "CI runners / capacity on paper only (slots registered short of slots built)",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "Hosts are RUNNING and past their registration grace, and fewer runner agents answer than the pool was built with. This is the one alert that separates 'the pool is fine and jobs are queuing' from 'the pool is not there': ci_slots_total is arithmetic — hosts x slots — so it reads identically whether every agent registered or none did, and every other series stays green through all three of the failures below.\n\nRead ci_slots_registered next to ci_slots_total to size the gap, then the host serial log. Three causes, in rough order of likelihood: a host that registered NOTHING (its config.sh never completed — check the registration token and egress to github.com); a host whose slot units died before the agent started (a truncated generated hook is 203/EXEC, and the host still reports healthy); or a slot the host's own sweep CONDEMNED after CONDEMN_MAX consecutive failures to reach a clean state, which is the sweep working — the slot was failing every job it claimed — and grep 'taking it out of service' in the host's syslog will say so.\n\nA controller that cannot read the runner list contributes to neither side of this, by construction, so an unreadable API cannot raise it. Sustained non-zero only, for thirty minutes: a host replaced mid-window is excluded by the grace, but a rolling recycle still ticks it, and at fifteen minutes a recycle that paused between hosts — which is what a cordon does, one host at a time — outlasted the window and paged for a pool being upgraded exactly as intended." },
  "conditions": [ { "displayName": "ci_slots_missing > 0 for 30m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "1800s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_slots_missing\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MIN" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    parked) cat <<EOF
{ "displayName": "CI runners / a green pull request cannot enter the merge queue",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "An open pull request has every check green and can NEVER be merged, because it fails one of the queue's entry conditions. Read the metric's \`reason\` label for which one: \`draft\` (nobody promoted it out of draft), \`base\` (it targets a branch the queue does not admit — usually a sibling feature branch an agent session stacked it on), or both.\n\nThis is the only alert here that fires on a state every other surface reports as healthy. Mergify does not fail an unmet entry condition, it reports NEUTRAL, which renders as a grey dot beside forty green ticks: no red check, no comment, no timer. Two repositories in this fleet reported 'CI is making no progress' in one week and neither had a failing job: two green DRAFTS nobody promoted in one, and a pull request BASED on a sibling feature branch in the other. Both were found days later by a human wondering why something had not landed.\n\nThe controller's log names the pull request number: grep 'cannot enter the merge queue' in the controller's syslog. Fix it in the repository — promote the draft, or retarget the base — not here. Read with max() across pools: the count is a REPOSITORY fact and every pool on the controller publishes the same one.\n\nA long window on purpose. A draft opened and promoted within the hour is somebody working, not an incident; only a pull request that stays finished-and-parked is worth a page. If ci_parked_prs_skipped is non-zero the count is a lower bound — the sweep hit its budget or its candidate ceiling." },
  "conditions": [ { "displayName": "ci_prs_green_and_unqueued > 0 for 60m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "3600s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_prs_green_and_unqueued\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    parkeddenied) cat <<EOF
{ "displayName": "CI runners / the parking sweep is being refused",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "GitHub is refusing the parking sweep, so the alert above it can never fire. This is the watcher's watcher, and it exists because the feature it guards fails by looking healthy: a sweep that is refused publishes an unbroken ci_prs_green_and_unqueued of ZERO, which is precisely what a repository with nothing parked publishes.\n\nThe sweep makes two calls and either can be the refused one, so read the log line before granting anything: listing open pull requests needs \`pull_requests: read\`, and \`commits/<sha>/check-runs\` needs \`checks: read\`. Almost always the GitHub App installation for this repository holds the older permission set. Nothing else about the controller degrades - demand, draining and recycling all keep working, which is why nobody notices. Grant the permission on the App, then ACCEPT it on the installation: a permission added to an App stays pending until the installation approves it, and a pending permission behaves exactly like one that was never granted.\n\nDistinct from ci_parked_prs_skipped on purpose. Skipped means the sweep ran out of budget and will retry; this means it was refused and will be refused again in five minutes, forever. Grep 'parked sweep: DENIED' in the controller's syslog for the status GitHub actually returned - 401 is a bad App key or installation id rather than a missing permission, and 404 on a sha the same token just listed is a permission answer wearing another number.\n\nRead with max() across pools, like everything else the controller publishes per repository. Fires after 30m: a single refused sweep during a GitHub incident is not worth a page, five in a row is." },
  "conditions": [ { "displayName": "ci_parked_sweep_denied > 0 for 30m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "1800s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_parked_sweep_denied\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    applystale) cat <<EOF
{ "displayName": "CI runners / this project has stopped receiving runner infrastructure",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "The Cloud Build trigger that applies this project's runner infrastructure is not landing changes any more. Nothing else in this project can report that, and this alert is the only reason it is not invisible.\n\nWhy it hides. A trigger's build config is validated when a build FIRES, not when Terraform creates it. A config that outgrows one of Cloud Build's two size cliffs — 10,000 characters per build-step argument, and roughly 128 KiB for the whole config — is REFUSED at submit: a FAILURE lasting a fraction of a second, with no build log, no steps, and the entire explanation in the build's own \`statusDetail\`. The audit entry Cloud Logging does keep is severity NOTICE with \`granted: true\` and an empty status, indistinguishable from a healthy build being created, so no log-based metric can tell them apart. Meanwhile the pool keeps serving jobs on whatever configuration it had when the refusal started, every other policy here stays green, and the trigger looks correct in the console. \`ci-runner-apply-entity-platform\` sat like that from 2026-08-30 and was found by hand the next day, by somebody doing something else.\n\nThree conditions, and WHICH one fired decides what you do:\n\n- **ci_apply_build_failed** — the newest apply build did not succeed. Read its explanation first, because a refusal says nothing in the log: \`gcloud builds list --project <id> --region <region> --limit 1 --format='value(status,statusDetail,createTime)'\`. If statusDetail names a size limit, the trigger CANNOT REPAIR ITSELF — the build that would apply the fix is the build being refused — and recovery is one out-of-band \`gcloud builds submit\` per project, described in docs/applying-runner-infra.md.\n- **ci_apply_build_missing** — no apply build at all in this project's recent history. The trigger is not firing, which produces no failure to find; check that the scheduler job and the trigger still exist and that \`apply_schedule\` is set.\n- **ci_apply_check_denied** — the CHECK is refused, so the two conditions above are stale rather than green. The controller needs \`roles/cloudbuild.builds.viewer\`; grep 'apply check: DENIED' in the controller's syslog.\n\nThe age condition is the half that catches a trigger which quietly stopped firing, and it is set at two days because the apply runs daily. Read every series with max() across pools: they are PROJECT facts published under each pool's label, exactly like the heartbeat." },
  "conditions": [
    { "displayName": "ci_apply_build_failed > 0 for 30m",
      "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "1800s",
        "filter": "metric.type=\"custom.googleapis.com/ci/ci_apply_build_failed\" AND resource.type=\"generic_node\"",
        "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } },
    { "displayName": "ci_apply_build_missing > 0 for 30m",
      "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "1800s",
        "filter": "metric.type=\"custom.googleapis.com/ci/ci_apply_build_missing\" AND resource.type=\"generic_node\"",
        "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } },
    { "displayName": "ci_apply_check_denied > 0 for 30m",
      "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "1800s",
        "filter": "metric.type=\"custom.googleapis.com/ci/ci_apply_check_denied\" AND resource.type=\"generic_node\"",
        "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } },
    { "displayName": "ci_apply_build_age_seconds > 2 days for 1h",
      "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 172800.0, "duration": "3600s",
        "filter": "metric.type=\"custom.googleapis.com/ci/ci_apply_build_age_seconds\" AND resource.type=\"generic_node\"",
        "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    hostvanished) cat <<EOF
{ "displayName": "CI runners / a host went away under a running job",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "A job was found RUNNING on a host that no longer exists. The controller cancels the run so it reports something, and this counts the jobs it found.\n\nWhy it is worth a page rather than a line in a log: a slot that dies holding a job produces NO SIGNAL. GitHub leaves the check run \`in_progress\` with nothing behind it — not success, not failure, not cancelled — until its own 24-hour timeout. Nothing is red, nothing is queued, the pool reports healthy, and the job simply never finishes. Everything waiting on that status then waits out ITS timeout instead: a merge queue does not read a missing status as a failure, it reads it as 'still checking' and holds the entry for its full window before dequeuing on a timeout that names no cause. Measured on one repository, that is 150 minutes spent on a pull request whose own CI had been green for hours.\n\nSo the cancellation is the REMEDY, not the incident. The incident is upstream, and it is one of: a slot poisoned mid-run, an agent that stopped answering, host maintenance or an operator delete-instances against a busy host, or a MIG recreate. Grep 'went away under a running job' in the controller's syslog for the instance name, then look at that slot's history — a host that appears here repeatedly is a host to recycle, not a job to re-run.\n\nTwo clocks have to run out before anything is cancelled, and the absence clock is required: the controller refuses this verdict entirely unless it can say how long the host has been continuously missing from the MIG list, and a tick with no host list at all resets every clock rather than advancing it. A false positive here is live work thrown away, so the rule is deliberately slower than the queued-job equivalent.\n\nRead with max() across pools. Fires on any occurrence within the window — this is not a rate to tolerate." },
  "conditions": [ { "displayName": "ci_pinned_jobs_host_vanished > 0 for 15m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "900s",
      "filter": "metric.type=\"custom.googleapis.com/ci/ci_pinned_jobs_host_vanished\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    egressdenied) cat <<EOF
{ "displayName": "CI runners / egress refused",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "A warm host tried to open an outbound connection the runner firewall refused. Read the entries — logName compute.googleapis.com/firewall, jsonPayload.disposition=DENIED — for the destination address and port. Two very different causes, and the log tells them apart: an ordinary port the pool legitimately needs and nobody added (add it to egress_tcp_ports, or to database_egress_ports if it is a database on a private address), or a job reaching somewhere it has no business reaching, which is a warm host running third-party code from a lockfile. Before this metric existed the first case looked like a test client hanging until the job timed out, and the second looked like nothing at all. Fires on a sustained run, not a single refusal: one blocked probe is ordinary." },
  "conditions": [ { "displayName": "ci_egress_denied > 0 for 15m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 0.0, "duration": "900s",
      "filter": "metric.type=\"logging.googleapis.com/user/ci_egress_denied\" AND resource.type=\"gce_instance\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_SUM" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
  esac
}

# ── log-based metrics ─────────────────────────────────────────────────────────
# The egress record is a LOG, not a series, so the one alertable fact in it has
# to be counted into a metric first. Only the refusals: counting the allows
# would be a metric that rises with build volume and says nothing, and the
# allowed destinations are answered by egress-destinations.sh against a reviewed
# baseline — a question about novelty, which no threshold can express.
#
# Created before the policy, because a policy naming a metric type Cloud
# Monitoring has never seen is rejected outright.
ensure_log_metric() {  # <name> <description> <filter>
  local name="$1" desc="$2" filter="$3"
  if g logging metrics describe "$name" >/dev/null 2>&1; then
    if [ "$DRY" = "1" ]; then echo "$PROJECT: would update log metric $name"; return 0; fi
    g logging metrics update "$name" --description="$desc" --log-filter="$filter" >/dev/null
    echo "$PROJECT: updated  log metric $name"
  else
    if [ "$DRY" = "1" ]; then echo "$PROJECT: would create log metric $name"; return 0; fi
    g logging metrics create "$name" --description="$desc" --log-filter="$filter" >/dev/null
    echo "$PROJECT: created  log metric $name"
  fi
}

ensure_log_metric ci_egress_denied \
  "Outbound connections the CI runner firewall refused. Non-zero is either a port the pool needs and nobody added, or a job reaching somewhere it should not." \
  'logName:"compute.googleapis.com%2Ffirewall" AND jsonPayload.rule_details.direction="EGRESS" AND jsonPayload.disposition="DENIED"'

# ── metric descriptors ────────────────────────────────────────────────────────
# An alert policy cannot be created against a metric type Cloud Monitoring has
# never seen: the API answers "Cannot find metric(s) that match type = ...".
# Left implicit, that makes the alert depend on the pool having already run,
# which is backwards — the window a new pool most needs watching is its first
# hour. Declaring the descriptor here lets alerting be provisioned BEFORE the
# controller ever publishes.
#
# GAUGE/DOUBLE matches what telemetry.sh writes. A descriptor that disagrees is
# not a cosmetic difference: the write is rejected and the series stays empty
# while every dashboard shows a metric that simply has no data.
#
# THE LABELS MATTER TOO, and only for some filters, which is why this took a
# while to see. A policy that selects a label by EQUALITY is accepted against a
# descriptor that declares no labels at all — `ci_drain_verdicts` with
# `metric.labels.outcome="error"` syncs happily. A policy that NEGATES one is
# not: `metric.labels.verdict!="hydrated"` is answered
# `Cannot find metric(s) that match type = ... label = "verdict"`, a 404 naming
# the label. So a descriptor declared here without its labels blocks its own
# alert permanently, and does it wearing the costume of the deferred-404 case
# below — "come back once a host has published" — which will never come true,
# because the descriptor already exists and it is the label that is missing.
# Declare the labels for every metric that carries one.
#
# POSTing a type that already exists UPDATES it rather than conflicting (200,
# not 409), so adding a label to this list is enough: there is no delete step and
# the existing points survive.
#
# Observed and deliberately relied on: a label declared with no data behind it
# does NOT come back on a later GET — the descriptor reads as label-less again.
# The declaration still counts where it matters, because policy validation
# happens at write time and the policy, once created, persists. The consequence
# for the code below is that the "already complete" check never matches for a
# label with no points yet, so a labelled descriptor is simply re-POSTed on every
# run. That is the safe direction to fail in, and it is why the check is written
# as "skip only if every label is already visible" rather than "skip if present".
#
# Done over REST, not gcloud: there is no `gcloud monitoring metrics-descriptors`
# group at all. An existence check written as `gcloud ... describe >/dev/null
# 2>&1` therefore fails for EVERY metric, including the ones already there, and
# the script silently re-POSTs on every run — the check reports "absent" whether
# the descriptor is absent or the command does not exist.
ensure_descriptor() {  # <short name> <description> [label ...]
  local short="$1" desc="$2" type="custom.googleapis.com/ci/$1" token status
  shift 2
  local labels=("$@")
  token="$(api_token)"
  [ -n "$token" ] || { echo "no access token — is the proxy bypass set?" >&2; return 1; }
  local base="https://monitoring.googleapis.com/v3/projects/$PROJECT/metricDescriptors"

  status="$(curl -sS --max-time 30 -o "$tmp/desc.get" -w '%{http_code}' \
    -H "Authorization: Bearer $token" "$base/$type")"
  case "$status" in
    200) # Present is not necessarily complete: a descriptor declared before this
         # function knew about labels has none, and re-POSTing is what adds them.
         local missing=0 l
         for l in ${labels[@]+"${labels[@]}"}; do
           grep -q "\"key\": \"$l\"" "$tmp/desc.get" || missing=1
         done
         [ "$missing" = "0" ] && return 0 ;;
    404) ;;
    *) echo "$PROJECT: cannot read descriptor $type (HTTP $status)" >&2; return 1 ;;
  esac

  if [ "$DRY" = "1" ]; then echo "$PROJECT: would declare metric descriptor $type"; return 0; fi
  local labels_json="" l
  for l in ${labels[@]+"${labels[@]}"}; do
    labels_json="$labels_json,{\"key\":\"$l\",\"valueType\":\"STRING\"}"
  done
  [ -n "$labels_json" ] && labels_json=",\"labels\":[${labels_json#,}]"
  status="$(curl -sS --max-time 30 -o "$tmp/desc.out" -w '%{http_code}' \
    -X POST "$base" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "{\"type\":\"$type\",\"metricKind\":\"GAUGE\",\"valueType\":\"DOUBLE\",
         \"description\":\"$desc\",\"displayName\":\"$short\"$labels_json}")"
  case "$status" in
    2*) echo "$PROJECT: declared metric descriptor $type" ;;
    409) echo "$PROJECT: descriptor $type already present" ;;
    *) sed -n '1,10p' "$tmp/desc.out" >&2
       echo "$PROJECT: failed to declare $type (HTTP $status)" >&2; return 1 ;;
  esac
}

ensure_descriptor ci_poller_heartbeat        "1 on every controller tick. Absence means the controller is dead."
ensure_descriptor ci_runner_list_blind_ticks "Consecutive ticks the controller could not read the GitHub runner list. Non-zero means scale-in is suspended."
ensure_descriptor ci_host_idle_seconds_max   "Longest idle time across warm hosts."
ensure_descriptor ci_pin_holds_honoured      "Warm hosts kept alive this tick because a pull request is pinned to them. Read WITH ci_host_idle_seconds_max and never alone: idle time on a pinned host is affinity working, not a drain that failed, and the two together are what distinguish the pool being used from scale-to-zero being broken."
ensure_descriptor ci_queue_wait_seconds_max  "Longest time a queued job has waited for a slot."
ensure_descriptor ci_drain_verdicts          "Drain-loop outcomes, labelled by outcome." outcome
ensure_descriptor ci_tick_seconds            "Controller tick duration. Approaching the watchdog threshold means an imminent restart loop in which nothing is published at all."
# Declared even though the policy reads only ci_slots_missing: the gap is not
# actionable without the numerator, and a descriptor a dashboard cannot find
# is how "how many slots ARE answering" becomes a question nobody can ask
# during the incident.
ensure_descriptor ci_slots_registered        "Slots whose runner agent answers, over RUNNING hosts past their registration grace. Compare with ci_slots_total, which is arithmetic and cannot fall."
ensure_descriptor ci_slots_missing           "Slots the pool was built with that no agent answers for. Non-zero is capacity that exists on paper only: a host that registered nothing, a host whose slot units died before the agent started, or a slot the host condemned for failing every job it claimed."
ensure_descriptor ci_prs_green_and_unqueued "Open pull requests that are green and can never enter the merge queue, labelled by the entry condition they fail. A repository fact published under every pool label -- read with max(), never sum()." reason
ensure_descriptor ci_parked_prs_skipped     "Pull requests the parking sweep did not examine. Non-zero makes ci_prs_green_and_unqueued a lower bound."
ensure_descriptor ci_pinned_jobs_host_vanished "Jobs found RUNNING on a host that no longer exists, counted per job and before any per-run de-duplication. Such a job reports no conclusion at all until GitHub's 24-hour timeout, so everything waiting on its status - a merge queue above all - waits out its own timeout instead. Non-zero is live work that lost its machine; grep 'went away under a running job' for the instance."
ensure_descriptor ci_apply_build_age_seconds "Age of the newest ci-runner-apply-* Cloud Build in this project. The half of the apply check that catches a trigger which stopped FIRING - that state produces no failed build to find. A project fact published under every pool label; read with max(), never sum()."
ensure_descriptor ci_apply_build_failed     "1 when the newest apply build did not succeed. Includes the refusal this was built for: a build config that outgrows a Cloud Build size cliff fails in under a second with no log and no steps, and its only explanation is the build's own statusDetail."
ensure_descriptor ci_apply_build_missing    "1 when a successful listing found no apply build at all. Distinct from failed on purpose - a trigger that never fires leaves nothing behind to be red - and distinct from denied, because this one is a trigger to go and look at rather than a grant to go and make."
ensure_descriptor ci_apply_check_denied     "1 when the apply check itself was refused, which makes ci_apply_build_age_seconds and ci_apply_build_failed STALE rather than zero. The controller needs roles/cloudbuild.builds.viewer; grep 'apply check: DENIED' for the error."
ensure_descriptor ci_parked_sweep_denied    "Parking sweeps GitHub refused (401/403/404). Non-zero means ci_prs_green_and_unqueued is inert rather than zero. Either call can be the refused one and they need different permissions - listing pull requests needs 'pull_requests: read', reading check runs needs 'checks: read' - and a bad App key or installation id reads the same, so grep 'parked sweep: DENIED' for which."
# Published by the HOST once per boot, not by the controller per tick. Declared
# here for the same reason as the rest — a pool that has never booted a host
# still needs its alerting provisioned — and it matters more here: these series
# are absent for long stretches by nature, so waiting for one to appear before
# the policy can be created means the policy is created after the incident.
ensure_descriptor ci_cache_hydrate_verdict   "1 per host boot, labelled by verdict. Every value but hydrated means the host registered without the shared cache." verdict
ensure_descriptor ci_cache_hydrate_seconds   "Seconds the shared-cache hydrate spent, whatever it decided. Approaching cache_hydrate_budget_seconds means hosts pay the full budget and start cold anyway."
ensure_descriptor ci_cache_snapshot_age_hours "Age of the snapshot the host read about, recorded before the bounds that may reject it."
ensure_descriptor ci_cache_snapshot_bytes    "Compressed size of that snapshot. A size that stops changing is a publish that stopped."
ensure_descriptor ci_cache_dirs_hydrated     "Tool caches moved in. Zero alongside a hydrated verdict is a snapshot packed from an empty tree."

# Same fail-closed rule as the channel listing: a LIST that errored reads as an
# empty inventory, and an empty inventory makes every policy below look absent —
# so the script would create a SECOND copy of every policy and double every page.
pl_status="$(mon GET 'alertPolicies?pageSize=1000')"
[ "$pl_status" = "200" ] || {
  echo "$PROJECT: cannot list alert policies (HTTP $pl_status)" >&2
  sed -n '1,20p' "$tmp/api.out" >&2; exit 1; }
existing="$(json_pairs alertPolicies displayName)"

# A policy that names a metric descriptor which does not exist YET is rejected
# 404. That is not a broken policy — Monitoring creates a custom descriptor on
# the first point written, so any series no host has published in this project
# is legitimately absent: a fresh pool, a pool that has not hydrated a cache, a
# prefix that just moved. Aborting the loop there leaves every policy AFTER it
# unsynced, which is how a run that ends in one loud 404 quietly skips seven
# alerts. Collect them, keep going, and fail at the end naming all of them.
# A 404 alone is not enough: the API returns it for a bad policy id too, and
# treating that as "come back later" would turn a real mistake into a warning.
# Match the body as well.
no_such_metric() {
  [ "$1" = "404" ] || return 1
  grep -q 'Cannot find metric' "$tmp/api.out"
}

deferred=""
for key in heartbeat blind idle queue drain slowtick cachestale cachefail slotsmissing parked parkeddenied applystale hostvanished egressdenied; do
  policy_json "$key" >"$tmp/p.json"
  # Neither of these ends in `| head -1`, and that is deliberate. This script
  # runs `set -euo pipefail`; under both options a reader that stops early sends
  # SIGPIPE to its writer, the writer exits 141, `pipefail` promotes 141 to the
  # pipeline's status, and a BARE assignment's status is its substitution's — so
  # `set -e` kills the script on a line that got the right answer. Whether it
  # fires is a race with how much the writer had already buffered, which is what
  # makes it a rare, unreproducible failure rather than a broken script. The
  # writers here are `sed` and `awk`, so take the first line in the shell.
  # Enforced by scripts/ci/check-pipefail-readers.sh (PFR1).
  name_all="$(sed -n 's/.*"displayName": "\(CI runners \/ [^"]*\)".*/\1/p' "$tmp/p.json")"
  name="${name_all%%$'\n'*}"
  id_all="$(printf '%s\n' "$existing" | awk -F'\t' -v n="$name" '$1==n {print $2}')"
  id="${id_all%%$'\n'*}"

  # A policy this script has RENAMED is not a policy this script has never seen.
  # The inventory above is keyed on displayName and nothing else, so the moment a
  # name in policy_json() changes, the old policy stops matching, looks absent,
  # and the run creates a second one beside it — leaving the old thresholds live,
  # still notifying, and no longer reachable from this file. That is the same
  # double-page the duplicate check below reports, except this script would have
  # caused it. Fall back to the name the policy used to carry: PATCH sends the
  # whole policy, displayName included, so updating the old id renames it in
  # place. Add a row here whenever a displayName changes, and only ever remove
  # one once every project has been synced past it.
  if [ -z "$id" ]; then
    former=""
    case "$key" in
      idle)  former="CI runners / pool not scaling to zero (idle host 20m)" ;;
      queue) former="CI runners / queue starved (job waiting 10m)" ;;
    esac
    if [ -n "$former" ]; then
      id_all="$(printf '%s\n' "$existing" | awk -F'\t' -v n="$former" '$1==n {print $2}')"
      id="${id_all%%$'\n'*}"
      [ -z "$id" ] || echo "$PROJECT: renaming ${id##*/} — '$former' becomes '$name'" >&2
    fi
  fi

  # Taking the first match keeps the script running, but two policies with one
  # displayName is a state it must not pass over in silence: this run updates one
  # of them and the other keeps whatever thresholds it was created with, so the
  # project pages twice and only one of the pages reflects the file. Found live
  # as a byte-identical pair — the shape the POST-is-never-retried rule in mon()
  # predicts, a create that timed out after the server had already accepted it.
  # Report it and name the survivor; deleting the extra is an
  # operator decision, not something a sync script should do unprompted.
  dupes="$(printf '%s\n' "$id_all" | grep -c . || true)"
  [ "${dupes:-0}" -le 1 ] || {
    echo "$PROJECT: $dupes policies share the name '$name' — updating ${id##*/} and leaving the rest stale. Delete the extras." >&2; }

  if [ "$DRY" = "1" ]; then
    printf '%s: would %s — %s\n' "$PROJECT" "$([ -n "$id" ] && echo update || echo create)" "$name"
    continue
  fi

  if [ -n "$id" ]; then
    # PATCH with NO updateMask is a whole-policy replace, which is what is
    # wanted: the file above is the intended state, so a threshold this script
    # stopped setting must disappear rather than linger. Supplying a mask here
    # would silently preserve exactly the stale conditions this run is meant to
    # remove. The policy name comes from the URL, so the body needs none.
    up_status="$(mon PATCH "${id#projects/"$PROJECT"/}" "$tmp/p.json")"
    [ "$up_status" = "200" ] || {
      echo "$PROJECT: cannot update $name (HTTP $up_status)" >&2
      sed -n '1,20p' "$tmp/api.out" >&2
      no_such_metric "$up_status" || exit 1
      deferred="$deferred$name"$'\n'; continue; }
    printf '%s: updated  %s\n' "$PROJECT" "$name"
  else
    cp_status="$(mon POST alertPolicies "$tmp/p.json")"
    [ "$cp_status" = "200" ] || {
      echo "$PROJECT: cannot create $name (HTTP $cp_status)" >&2
      sed -n '1,20p' "$tmp/api.out" >&2
      no_such_metric "$cp_status" || exit 1
      deferred="$deferred$name"$'\n'; continue; }
    printf '%s: created  %s\n' "$PROJECT" "$name"
  fi
done

if [ -n "$deferred" ]; then
  echo >&2
  echo "$PROJECT: these policies name a metric this project has never received:" >&2
  printf '%s' "$deferred" | sed 's/^/  /' >&2
  echo "Every other policy WAS synced. Re-run once a host has published the" >&2
  echo "series — a descriptor appears on its first point, then within 10 minutes." >&2
  exit 1
fi
