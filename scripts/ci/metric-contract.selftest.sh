#!/usr/bin/env bash
# Every metric the pool publishes must appear in the module's `metric_names`
# output, and vice versa.
#
# "The pool" is two scripts, not one. The controller publishes every tick; the
# host publishes once, for the cache hydrate, because that finishes before the
# runner agent registers and the controller never observes it. Both share
# telemetry.sh, so both go through `queue_series` and both belong to this diff —
# a check that read only the controller would have called the host's series
# "declared and nothing publishes it".
#
# WHY: `ci_orphan_registrations_reaped` was published from the day the reaper
# landed and was never added to the output. Dashboards and alert policies are
# built from that output, so the series existed in Cloud Monitoring and nothing
# looked at it — a metric nobody can find is a metric nobody has. The drift is
# silent in both directions: an output naming a series the controller stopped
# publishing produces an alert that can never fire, which reads as "healthy".
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/../../modules/ci-runner-host-pool/scripts"
controller="$scripts/controller-startup.sh"
host="$scripts/host-startup.sh"
outputs="$here/../../modules/ci-runner-host-pool/outputs.tf"

# What each script actually sends: every `queue_series "<name>"` call.
names_in() {
  grep -oE 'queue_series[[:space:]]+"[a-z0-9_]+"' "$1" \
    | sed 's/.*"\(.*\)"/\1/' | sort -u
}
controller_published="$(names_in "$controller")"
host_published="$(names_in "$host")"
published="$(printf '%s\n%s\n' "$controller_published" "$host_published" | grep . | sort -u)"

# What the module promises: the string list inside the metric_names output.
declared="$(sed -n '/output "metric_names"/,/^}/p' "$outputs" \
  | grep -oE '"ci_[a-z0-9_]+"' | tr -d '"' | sort -u)"

fails=0

# Prove the extractors see something before trusting either side of the diff:
# two empty lists compare equal, and a broken grep would pass this gate
# silently — the exact failure mode it exists to catch.
#
# Floored PER SCRIPT, not on the union. The controller publishes twenty-odd
# series and the host five, so a host matcher that silently stopped matching
# would leave the union far above any single threshold — and the host's series
# would then read as "declared and nothing publishes it", which is the same
# message as the real drift this check is for.
floor() { # <label> <list> <minimum>
  local n; n="$(printf '%s\n' "$2" | grep -c . || true)"
  [ "$n" -ge "$3" ] || {
    printf 'FAIL extracted %s published metric(s) from %s — the matcher is broken\n' "$n" "$1"
    fails=$((fails + 1)); }
}
floor "controller-startup.sh" "$controller_published" 5
floor "host-startup.sh" "$host_published" 3
[ "$(printf '%s\n' "$declared" | grep -c .)" -ge 5 ] || {
  printf 'FAIL extracted %s declared metric(s) from outputs.tf — the matcher is broken\n' \
    "$(printf '%s\n' "$declared" | grep -c .)"; fails=$((fails + 1)); }

# Named, rather than left to the generic diff below, because this one series is
# the only evidence a dashboard has that the SECOND delete gate still runs. Its
# `undetermined` outcome is a controller that cannot establish a host's OS and
# therefore keeps it: scale-in silently suspended while every other series reads
# healthy. Deleted from either side, the diff below reports it as ordinary
# drift; here it reports it by name.
# ci_worker_gate_os_fallback is named for the opposite reason: it is the only
# countdown on a transitional arm that resolves a pre-`ci-host-os` host by
# inference. Lose the series and the arm has no removal criterion and becomes
# permanent.
# ci_pin_holds_honoured is named for a third reason: it is the ONLY evidence
# that the pin-hold veto ran at all. Every other symptom of losing it is a
# success -- hosts drain, the pool shrinks, the graphs look healthy -- right up
# until a pull request's second job finds the host it named is gone.
for m in ci_worker_gate_verdicts ci_worker_gate_os_fallback ci_pin_holds_honoured; do
  printf '%s\n' "$published" | grep -cx "$m" >/dev/null || {
    printf 'FAIL %s is not published by either script — the second delete gate has no telemetry\n' "$m"
    fails=$((fails + 1)); }
  printf '%s\n' "$declared" | grep -cx "$m" >/dev/null || {
    printf 'FAIL %s is not declared in metric_names — no dashboard or alert can find the delete gate\n' "$m"
    fails=$((fails + 1)); }
done

while read -r m; do
  [ -n "$m" ] || continue
  if printf '%s\n' "$declared" | grep -cx "$m" >/dev/null; then
    printf 'ok   %s is published and declared\n' "$m"
  else
    printf 'FAIL %s is published by the controller but missing from metric_names — no dashboard can find it\n' "$m"
    fails=$((fails + 1))
  fi
done <<<"$published"

while read -r m; do
  [ -n "$m" ] || continue
  if ! printf '%s\n' "$published" | grep -cx "$m" >/dev/null; then
    printf 'FAIL %s is declared in metric_names but nothing publishes it — an alert on it can never fire\n' "$m"
    fails=$((fails + 1))
  fi
done <<<"$declared"

if [ "$fails" -eq 0 ]; then
  printf '\nPASS — the published metrics and the module contract agree.\n'
else
  printf '\n%d mismatch(es).\n' "$fails"; exit 1
fi
