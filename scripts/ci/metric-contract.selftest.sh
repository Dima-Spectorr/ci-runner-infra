#!/usr/bin/env bash
# Every metric the pool publishes must appear in the module's `metric_names`
# output, and vice versa.
#
# "The pool" is THREE scripts, not one. The controller publishes every tick; the
# Linux host publishes once, for the cache hydrate, because that finishes before
# the runner agent registers and the controller never observes it; and the
# Windows host publishes the same five hydrate series for the same reason. The
# first two share telemetry.sh and go through `queue_series`; the Windows script
# cannot dot-source a bash file and has its own publisher, so it goes through
# `Add-MetricSeries -Name`. All three belong to this diff — a check that read
# only the controller would have called the hosts' series "declared and nothing
# publishes it".
#
# TWO MATCHERS, ONE CONTRACT. The Windows publisher was added (#252) precisely so
# a Windows pool stops being invisible; if this file had kept reading two scripts,
# the new series would have been the ones it could not see, and the check written
# to catch silent drift would have been silent about the drift it was extended for.
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
winhost="$scripts/windows-host-startup.ps1"
outputs="$here/../../modules/ci-runner-host-pool/outputs.tf"

# What a bash script actually sends: every `queue_series "<name>"` call.
names_in() {
  grep -oE 'queue_series[[:space:]]+"[a-z0-9_]+"' "$1" \
    | sed 's/.*"\(.*\)"/\1/' | sort -u
}
# And the PowerShell equivalent. Single-quoted on that side, which is not a
# style difference: PowerShell interpolates inside double quotes, so a metric
# name written "…" there would be a name this matcher reads correctly and the
# host might not send.
ps_names_in() {
  grep -oE "Add-MetricSeries[[:space:]]+-Name[[:space:]]+'[a-z0-9_]+'" "$1" \
    | sed "s/.*'\(.*\)'/\1/" | sort -u
}
controller_published="$(names_in "$controller")"
host_published="$(names_in "$host")"
winhost_published="$(ps_names_in "$winhost")"
published="$(printf '%s\n%s\n%s\n' "$controller_published" "$host_published" \
  "$winhost_published" | grep . | sort -u)"

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
floor "windows-host-startup.ps1" "$winhost_published" 3
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

# THE TWO HOSTS MUST AGREE, and the generic diff below cannot see it: the union
# still contains a series one host dropped, so it stays "published and declared"
# while half the fleet stopped sending it. That is the exact shape of the gap
# #252 closed — a Windows pool answering `ci_cache_hydrate_verdict` with an empty
# chart, which reads as "no data yet" rather than "this pool never reports".
while read -r m; do
  [ -n "$m" ] || continue
  printf '%s\n' "$winhost_published" | grep -cx "$m" >/dev/null || {
    printf 'FAIL %s is published by host-startup.sh but not by windows-host-startup.ps1 — a Windows pool answers that series with an empty chart, which reads as "no data yet"\n' "$m"
    fails=$((fails + 1)); }
done <<<"$host_published"
while read -r m; do
  [ -n "$m" ] || continue
  printf '%s\n' "$host_published" | grep -cx "$m" >/dev/null || {
    printf 'FAIL %s is published by windows-host-startup.ps1 but not by host-startup.sh — the two host kinds no longer describe the same boot\n' "$m"
    fails=$((fails + 1)); }
done <<<"$winhost_published"

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

# --- and the contract that a declared metric actually ARRIVES ----------------
#
# Agreeing on names is worth nothing if the request carrying them is rejected.
# Cloud Monitoring caps projects.timeSeries.create at 200 TimeSeries objects and
# rejects the WHOLE request past it, so on a four-pool controller — ~55 series
# per pool — one flush would drop every series in the tick, `ci_demand` included,
# and the pool would stop scaling while every dashboard held its last value.
#
# Run for real, against a stubbed transport, because the arithmetic is the thing
# under test: the buffer is a comma-joined string of JSON objects and the cap is
# enforced by COUNTING on the way in, which is exactly the kind of off-by-one a
# static read of the diff cannot settle.
batching_holds() {
  local dir reqs
  dir=$(mktemp -d) || return 1
  reqs="$dir/requests"
  : >"$reqs"

  (
    set -uo pipefail
    # Read by telemetry.sh, which arrives through the `.` below — no static
    # reader can see that, so all five look dead here and none of them is.
    # shellcheck disable=SC2034
    PROJECT=test-project REGION=test-region
    # shellcheck disable=SC2034
    REPO_FULL=test-owner/test-repo POOL=test-pool
    # shellcheck disable=SC2034
    METRIC_PREFIX=custom.googleapis.com/ci
    # Called only from the sourced file, so SC2317 again.
    # shellcheck disable=SC2317
    log() { :; }

    # Shadows the binary for the whole subshell. The token call and the POST are
    # told apart by their URL, and the POST records how many series it was handed
    # rather than sending them anywhere.
    #
    # SC2317 for the same reason as the SC2034s above: the only caller is inside
    # the sourced file, so every line of this body reads as unreachable.
    # shellcheck disable=SC2317
    curl() {
      local a prev="" body=""
      case "$*" in
        *service-accounts/default/token*)
          printf '{"access_token":"stub"}'
          return 0
          ;;
      esac
      for a in "$@"; do
        [ "$prev" = "-d" ] && body="$a"
        prev="$a"
      done
      printf '%s' "$body" | grep -o '"metric"' | wc -l | tr -d ' ' >>"$reqs"
      printf '200'
    }

    # shellcheck source=/dev/null
    . "$scripts/telemetry.sh"

    # No `local` here: this is a subshell, not a function (shellcheck SC2168).
    for i in $(seq 1 450); do
      queue_series "ci_probe_$i" 1
    done
    flush_series
  ) >/dev/null 2>&1

  local got
  got=$(tr '\n' ' ' <"$reqs" | sed 's/ *$//')
  rm -rf "$dir"
  [ "$got" = "200 200 50" ] || {
    printf 'FAIL telemetry batching: 450 queued series produced requests of [%s], expected [200 200 50] — a request over 200 is rejected whole, so this drops every series in the tick including ci_demand\n' "$got"
    return 1
  }
  printf 'ok   telemetry: 450 series are split into requests of 200, 200, 50\n'
}

batching_holds || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  printf '\nPASS — the published metrics and the module contract agree.\n'
else
  printf '\n%d mismatch(es).\n' "$fails"; exit 1
fi
