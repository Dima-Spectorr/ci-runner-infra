#!/usr/bin/env bash
# ci-runner-host-pool — the telemetry publisher.
#
# ONE publisher, used for every series. The fleet's previous pools each grew
# their own ad-hoc metric write next to the one metric the autoscaler needed,
# so every pool published a different subset under a different name and no
# fleet-wide view was possible. Here every series goes through publish_series()
# and therefore shares a resource type, a label set, and a failure mode.
#
# Resource is `generic_node` labelled with repo + pool, so one dashboard can
# group by repo, by pool, or by neither, without per-repo dashboard code.
#
# Concatenated ahead of BOTH startup scripts — the controller's, which publishes
# every tick, and the host's, which publishes once for the cache hydrate. The
# host cannot delegate that one: the hydrate runs before the agent registers, so
# the controller never observes it, and a controller reporting on it would be
# reporting on something it did not watch. Both accounts already hold
# roles/monitoring.metricWriter, so this costs no new grant on a machine that
# runs pull-request code.
#
# Expects: PROJECT, REGION, REPO_FULL, POOL, METRIC_PREFIX, and a `log`.

TELEMETRY_BUFFER=""

# ts_label_value <string> — echoes a string that is safe to paste into the JSON
# label fragment below.
#
# Every label this file carried until now was a constant written by hand
# ("drained", "aborted"). The outcome series carries workflow names, which come
# from a repository's own YAML: arbitrary user text, reaching a JSON document
# built by string concatenation. One `"` in a workflow name would not corrupt
# one label — it would make the whole request unparseable and drop EVERY series
# in that tick, including the one the autoscaler reads.
#
# Allowlist rather than escape. Escaping has to be right about every case
# (quotes, backslashes, newlines, invalid UTF-8 from a truncated multi-byte
# character); an allowlist has to be right about one. Anything outside it
# becomes `_`, which is lossy in the harmless direction — a label that reads
# slightly wrong beats a tick that publishes nothing.
#
# Capped at 64 characters because a label value is also a cardinality decision:
# the tail of a long name is where the per-run junk lives.
ts_label_value() {
  local v="${1//[^A-Za-z0-9._\/ -]/_}"
  v="${v:0:64}"
  printf '%s' "${v:-unknown}"
}

# _ts_point <metric> <value> [<label-json-fragment>]
_ts_point() {
  local metric="$1" value="$2" extra="${3:-}"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local labels="\"repo\":\"$REPO_FULL\",\"pool\":\"$POOL\""
  [ -n "$extra" ] && labels="$labels,$extra"

  # Every series is a GAUGE double. Uniform on purpose: a mixed metric kind
  # across a fleet makes a single alert policy impossible to express.
  cat <<EOF
{
  "metric": { "type": "$METRIC_PREFIX/$metric", "labels": { $labels } },
  "resource": {
    "type": "generic_node",
    "labels": {
      "project_id": "$PROJECT",
      "location": "$REGION",
      "namespace": "$POOL",
      "node_id": "$REPO_FULL"
    }
  },
  "metricKind": "GAUGE",
  "valueType": "DOUBLE",
  "points": [ { "interval": { "endTime": "$now" }, "value": { "doubleValue": $value } } ]
}
EOF
}

# queue_series <metric> <value> [<label-json-fragment>]
# Buffers a point. Cloud Monitoring rejects two points for the SAME series in
# one request, so callers must not queue a metric twice per tick.
queue_series() {
  local point
  point=$(_ts_point "$@")
  if [ -n "$TELEMETRY_BUFFER" ]; then
    TELEMETRY_BUFFER="$TELEMETRY_BUFFER,$point"
  else
    TELEMETRY_BUFFER="$point"
  fi
}

# flush_series — one API call per tick, whatever the number of metrics.
flush_series() {
  [ -n "$TELEMETRY_BUFFER" ] || return 0

  local body token http
  body="{\"timeSeries\":[$TELEMETRY_BUFFER]}"
  TELEMETRY_BUFFER=""

  # Bounded, and spelled out rather than reusing the controller's CURL_TIMEOUTS:
  # this file is concatenated BEFORE controller-startup.sh, so depending on a
  # variable defined there would make the flush's safety a property of link
  # order. The controller's tick loop is a plain `while true`, so a hang here
  # does not fail — it stops every later tick, and with it demand publication
  # and all scale-in, while the process still looks alive to systemd.
  token=$(curl --connect-timeout 10 --max-time 30 -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || { log "telemetry: no access token"; return 1; }

  http=$(curl --connect-timeout 10 --max-time 30 \
    -s -o /tmp/ts-response.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "https://monitoring.googleapis.com/v3/projects/$PROJECT/timeSeries" \
    -d "$body")

  if [ "$http" != "200" ]; then
    # Loud, because a silent telemetry failure is worse than no telemetry: the
    # autoscaler reads ci_demand from here, so a pool that cannot publish is a
    # pool that stops scaling out while looking healthy.
    log "telemetry: POST timeSeries -> HTTP $http: $(head -c 400 /tmp/ts-response.json)"
    return 1
  fi
  return 0
}

# publish_series <metric> <value> [<label-json-fragment>]
# Queue + flush, for a single out-of-band point (e.g. the failure heartbeat).
publish_series() {
  queue_series "$@"
  flush_series
}
