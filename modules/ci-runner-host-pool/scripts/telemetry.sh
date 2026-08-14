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
# Sourced by controller-startup.sh. Expects: PROJECT, REGION, REPO_FULL, POOL,
# METRIC_PREFIX.

TELEMETRY_BUFFER=""

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
