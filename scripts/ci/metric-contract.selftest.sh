#!/usr/bin/env bash
# Every metric the controller publishes must appear in the module's
# `metric_names` output, and vice versa.
#
# WHY: `ci_orphan_registrations_reaped` was published from the day the reaper
# landed and was never added to the output. Dashboards and alert policies are
# built from that output, so the series existed in Cloud Monitoring and nothing
# looked at it — a metric nobody can find is a metric nobody has. The drift is
# silent in both directions: an output naming a series the controller stopped
# publishing produces an alert that can never fire, which reads as "healthy".
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller="$here/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"
outputs="$here/../../modules/ci-runner-host-pool/outputs.tf"

# What the controller actually sends: every `queue_series "<name>"` call.
published="$(grep -oE 'queue_series[[:space:]]+"[a-z0-9_]+"' "$controller" \
  | sed 's/.*"\(.*\)"/\1/' | sort -u)"

# What the module promises: the string list inside the metric_names output.
declared="$(sed -n '/output "metric_names"/,/^}/p' "$outputs" \
  | grep -oE '"ci_[a-z0-9_]+"' | tr -d '"' | sort -u)"

fails=0

# Prove the extractors see something before trusting either side of the diff:
# two empty lists compare equal, and a broken grep would pass this gate
# silently — the exact failure mode it exists to catch.
[ "$(printf '%s\n' "$published" | grep -c .)" -ge 5 ] || {
  printf 'FAIL extracted %s published metric(s) from the controller — the matcher is broken\n' \
    "$(printf '%s\n' "$published" | grep -c .)"; fails=$((fails + 1)); }
[ "$(printf '%s\n' "$declared" | grep -c .)" -ge 5 ] || {
  printf 'FAIL extracted %s declared metric(s) from outputs.tf — the matcher is broken\n' \
    "$(printf '%s\n' "$declared" | grep -c .)"; fails=$((fails + 1)); }

while read -r m; do
  [ -n "$m" ] || continue
  if printf '%s\n' "$declared" | grep -qx "$m"; then
    printf 'ok   %s is published and declared\n' "$m"
  else
    printf 'FAIL %s is published by the controller but missing from metric_names — no dashboard can find it\n' "$m"
    fails=$((fails + 1))
  fi
done <<<"$published"

while read -r m; do
  [ -n "$m" ] || continue
  if ! printf '%s\n' "$published" | grep -qx "$m"; then
    printf 'FAIL %s is declared in metric_names but nothing publishes it — an alert on it can never fire\n' "$m"
    fails=$((fails + 1))
  fi
done <<<"$declared"

if [ "$fails" -eq 0 ]; then
  printf '\nPASS — the published metrics and the module contract agree.\n'
else
  printf '\n%d mismatch(es).\n' "$fails"; exit 1
fi
