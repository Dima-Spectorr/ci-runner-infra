#!/usr/bin/env bash
# The watchdog rule, tested against the loop it was written for.
#
# On 2026-08-14 two of seven controllers in this fleet were restarted every 60s
# for hours. Both were `active (running)`, both
# consumed a full CPU-minute per minute, and both published no metric at all —
# including ci_poller_heartbeat, the series whose absence is supposed to mean
# "the controller is dead". The rule had one input, the heartbeat's age, and the
# restart it issued was what prevented the heartbeat from being written.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../modules/ci-runner-host-pool/scripts/watchdog-decision.sh
source "$HERE/../../modules/ci-runner-host-pool/scripts/watchdog-decision.sh"

PASS=0
FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; PASS=$((PASS + 1))
  else printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

T=300

# --- the incident ------------------------------------------------------------
# A controller restarted 12s ago, with a heartbeat file 900s stale because the
# previous restarts kept killing the tick that would have refreshed it. The old
# rule restarted it here, and would go on doing so every 60s forever.
check "a just-restarted controller is held, however stale its heartbeat" \
  "hold:restarted-12s-ago" "$(watchdog_verdict 1 900 12 "$T")"

# The same controller one threshold later. If it STILL has not written a
# heartbeat it is genuinely wedged, and the watchdog must act — the grace is a
# delay, not an exemption.
check "past the grace, a stale heartbeat still restarts" \
  restart "$(watchdog_verdict 1 900 301 "$T")"

# --- ordinary operation ------------------------------------------------------
check "fresh heartbeat, long-running unit: no action" \
  "hold:fresh-20s" "$(watchdog_verdict 1 20 86400 "$T")"

# A 212s tick on a 300s threshold — measured on a busy pool. Slow is not stuck.
check "a slow tick under the threshold is not restarted" \
  "hold:fresh-212s" "$(watchdog_verdict 1 212 86400 "$T")"

check "heartbeat exactly at the threshold restarts" \
  restart "$(watchdog_verdict 1 300 86400 "$T")"

# --- first boot --------------------------------------------------------------
check "no heartbeat file yet: hold (normal boot, not a wedge)" \
  "hold:no-heartbeat-yet" "$(watchdog_verdict 0 0 5 "$T")"

# Absence must keep holding rather than becoming a restart loop of its own: with
# no file there is nothing a restart could fix.
check "no heartbeat file after a long uptime: still hold, never restart" \
  "hold:no-heartbeat-yet" "$(watchdog_verdict 0 0 86400 "$T")"

# --- unknown uptime ----------------------------------------------------------
# systemd not answering must not switch the watchdog off — an unreadable uptime
# falls back to judging on the heartbeat alone, which is the old behaviour and
# is correct as long as it is not the DEFAULT.
check "unknown uptime with a stale heartbeat restarts" \
  restart "$(watchdog_verdict 1 900 -1 "$T")"

check "unknown uptime with a fresh heartbeat holds" \
  "hold:fresh-10s" "$(watchdog_verdict 1 10 -1 "$T")"

# --- the generated watchdog carries THIS function ----------------------------
# The installer emits the watchdog with `declare -f watchdog_verdict`, so the
# text on the box is the text tested above. A hand-copied second implementation
# in the heredoc would drift silently — the watchdog's only output is a restart.
INSTALLER="$HERE/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"
if grep -q 'declare -f watchdog_verdict' "$INSTALLER"; then
  printf 'ok   the installer emits the tested function into watchdog.sh\n'; PASS=$((PASS + 1))
else
  printf 'FAIL the installer no longer emits watchdog_verdict — the deployed rule is untested\n'; FAIL=$((FAIL + 1))
fi

# ...and the module concatenates the file that defines it, or the emitted
# watchdog would be an empty script that never restarts anything.
if grep -q 'scripts/watchdog-decision.sh' "$HERE/../../modules/ci-runner-host-pool/main.tf"; then
  printf 'ok   watchdog-decision.sh is concatenated into the controller startup script\n'; PASS=$((PASS + 1))
else
  printf 'FAIL watchdog-decision.sh is not in the controller startup concatenation — watchdog_verdict would be undefined on the box\n'; FAIL=$((FAIL + 1))
fi

printf 'watchdog-decision selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
