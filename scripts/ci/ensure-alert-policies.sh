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
#   ensure-alert-policies.sh --project <id> --email <addr> [--account <sa-email>] [--dry-run]
#
#   --account selects a per-command identity for a project in another
#   organisation. It is never exported: GOOGLE_APPLICATION_CREDENTIALS is shared
#   with every other session on this host and must not be mutated.
set -euo pipefail

PROJECT=""; EMAIL=""; ACCOUNT=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --email)   EMAIL="$2";   shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }
[ -n "$EMAIL" ]   || { echo "--email is required (the channel every policy notifies)" >&2; exit 2; }

# The corporate proxy blackholes the token endpoint; without this every call
# below fails as an auth error rather than a network one, which sends the reader
# looking at IAM.
export no_proxy="googleapis.com,*.googleapis.com,localhost,127.0.0.1,::1,.local"
export NO_PROXY="$no_proxy"

g() {
  if [ -n "$ACCOUNT" ]; then gcloud "$@" --project="$PROJECT" --account="$ACCOUNT"
  else gcloud "$@" --project="$PROJECT"; fi
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
# `labels.email_address=a@b` reads `email` as a field reference -- and gcloud
# reports that as INVALID_ARGUMENT, which under `2>/dev/null` is indistinguishable
# from "no such channel". The script would then create a duplicate channel on
# every run and every alert would page twice.
channel="$(g alpha monitoring channels list --format='value(name,type,labels.email_address)' 2>/dev/null \
  | awk -F'\t' -v e="$EMAIL" '$2=="email" && $3==e {print $1; exit}' || true)"

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
    channel="$(g alpha monitoring channels create --channel-content-from-file="$tmp/channel.json" \
      --format='value(name)')"
    echo "created channel $channel"
  fi
else
  echo "channel exists: $channel"
fi

# ── the six policies ─────────────────────────────────────────────────────────
# `duration` is what stops each of these paging on a blip. Every threshold below
# is deliberately longer than one controller tick.
policy_json() {  # <key> -> a full alertPolicy body on stdout
  case "$1" in
    heartbeat) cat <<EOF
{ "displayName": "CI runners / controller dead (no heartbeat 10m)",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "The CI warm-host controller stopped reporting. Jobs will queue and the pool will not scale. Check the controller VM (ci-runner-*-controller) and its ci-controller.service." },
  "conditions": [ { "displayName": "ci_poller_heartbeat absent for 10m",
    "conditionAbsent": { "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/github/ci_poller_heartbeat\" AND resource.type=\"generic_node\"",
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
      "filter": "metric.type=\"custom.googleapis.com/github/ci_runner_list_blind_ticks\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    idle) cat <<EOF
{ "displayName": "CI runners / pool not scaling to zero (idle host 20m)",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "A warm host has been idle past the drain threshold and was not removed — scale-to-zero is broken and the pool is burning money. Check controller drain logs and the MIG autoscaler. If ci_runner_list_blind_ticks is also non-zero, THAT is the cause and this alert is a symptom." },
  "conditions": [ { "displayName": "ci_host_idle_seconds_max > 1200 for 10m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 1200.0, "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/github/ci_host_idle_seconds_max\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    queue) cat <<EOF
{ "displayName": "CI runners / queue starved (job waiting 10m)",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "A queued job has waited past the SLO without a slot. Either the pool hit max_hosts, hosts failed to boot, or the runner agent is offline. Compare ci_hosts_running with ci_mig_target_size, then read the host serial logs." },
  "conditions": [ { "displayName": "ci_queue_wait_seconds_max > 600 for 10m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 600.0, "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/github/ci_queue_wait_seconds_max\" AND resource.type=\"generic_node\"",
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
      "filter": "metric.type=\"custom.googleapis.com/github/ci_drain_verdicts\" AND resource.type=\"generic_node\" AND metric.labels.outcome=\"error\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
    slowtick) cat <<EOF
{ "displayName": "CI runners / tick approaching the watchdog threshold",
  "combiner": "OR",
  "documentation": { "mimeType": "text/markdown", "content":
    "A controller tick is taking longer than half the watchdog threshold (300s at the default poll). This is the precursor to a total blackout, not a slowdown: once a tick outlasts the threshold the watchdog restarts the controller mid-tick, the restart prevents the heartbeat that would have stopped it, and every series — heartbeat included — goes absent while systemd still reports active (running). Two pools in this fleet ran that way for hours on 2026-08-14. Demand costs one API call per active workflow run, so the usual cause is a busier repository; lower demand_budget_seconds or raise poll_interval_seconds. Check ci_demand_runs_skipped." },
  "conditions": [ { "displayName": "ci_tick_seconds > 150 for 10m",
    "conditionThreshold": { "comparison": "COMPARISON_GT", "thresholdValue": 150.0, "duration": "600s",
      "filter": "metric.type=\"custom.googleapis.com/github/ci_tick_seconds\" AND resource.type=\"generic_node\"",
      "aggregations": [ { "alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_MAX" } ] } } ],
  "notificationChannels": [ "$channel" ] }
EOF
    ;;
  esac
}

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
# Done over REST, not gcloud: there is no `gcloud monitoring metrics-descriptors`
# group at all. An existence check written as `gcloud ... describe >/dev/null
# 2>&1` therefore fails for EVERY metric, including the ones already there, and
# the script silently re-POSTs on every run — the check reports "absent" whether
# the descriptor is absent or the command does not exist.
api_token() {
  if [ -n "$ACCOUNT" ]; then gcloud auth print-access-token --account="$ACCOUNT"
  else gcloud auth print-access-token; fi
}

ensure_descriptor() {  # <short name> <description>
  local short="$1" desc="$2" type="custom.googleapis.com/github/$1" token status
  token="$(api_token)"
  [ -n "$token" ] || { echo "no access token — is the proxy bypass set?" >&2; return 1; }
  local base="https://monitoring.googleapis.com/v3/projects/$PROJECT/metricDescriptors"

  status="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" "$base/$type")"
  case "$status" in
    200) return 0 ;;
    404) ;;
    *) echo "$PROJECT: cannot read descriptor $type (HTTP $status)" >&2; return 1 ;;
  esac

  if [ "$DRY" = "1" ]; then echo "$PROJECT: would declare metric descriptor $type"; return 0; fi
  status="$(curl -sS --max-time 30 -o "$tmp/desc.out" -w '%{http_code}' \
    -X POST "$base" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "{\"type\":\"$type\",\"metricKind\":\"GAUGE\",\"valueType\":\"DOUBLE\",
         \"description\":\"$desc\",\"displayName\":\"$short\"}")"
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
ensure_descriptor ci_queue_wait_seconds_max  "Longest time a queued job has waited for a slot."
ensure_descriptor ci_drain_verdicts          "Drain-loop outcomes, labelled by outcome."
ensure_descriptor ci_tick_seconds            "Controller tick duration. Approaching the watchdog threshold means an imminent restart loop in which nothing is published at all."

existing="$(g alpha monitoring policies list --format='value(displayName,name)' 2>/dev/null || true)"

for key in heartbeat blind idle queue drain slowtick; do
  policy_json "$key" >"$tmp/p.json"
  name="$(sed -n 's/.*"displayName": "\(CI runners \/ [^"]*\)".*/\1/p' "$tmp/p.json" | head -1)"
  id="$(printf '%s\n' "$existing" | awk -F'\t' -v n="$name" '$1==n {print $2}' | head -1)"

  if [ "$DRY" = "1" ]; then
    printf '%s: would %s — %s\n' "$PROJECT" "$([ -n "$id" ] && echo update || echo create)" "$name"
    continue
  fi

  if [ -n "$id" ]; then
    # A full body with no `--fields` is a whole-policy replace, which is what is
    # wanted: the file above is the intended state, so a threshold this script
    # stopped setting must disappear rather than linger. (`--fields` here accepts
    # only `disabled` and `notificationChannels`; it is not a field mask.)
    g alpha monitoring policies update "$id" --policy-from-file="$tmp/p.json" \
      --format='value(name)' >/dev/null
    printf '%s: updated  %s\n' "$PROJECT" "$name"
  else
    g alpha monitoring policies create --policy-from-file="$tmp/p.json" --format='value(name)' >/dev/null
    printf '%s: created  %s\n' "$PROJECT" "$name"
  fi
done
