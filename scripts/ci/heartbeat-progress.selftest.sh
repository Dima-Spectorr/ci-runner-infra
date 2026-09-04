#!/usr/bin/env bash
# The heartbeat means "the loop MOVED", and this file is what says so.
#
# THE INCIDENT (2026-09-03, IntegrateIT)
#
# The heartbeat was written only around the tick — once before, once after — so
# its age was the elapsed time of the tick in progress. A tick that outran the
# 300s watchdog threshold was therefore read as a wedge, and the restart the
# watchdog issued killed the tick before it could finish. watchdog-decision.sh's
# uptime grace did not break that loop; it PACED it, one restart every 350s:
#
#   restart -> hold:restarted-70s -> 140s -> 210s -> 280s -> restart -> ...
#
# for 54 minutes, four windows in three days, `NRestarts=0` throughout (the
# watchdog calls `systemctl restart`, so systemd's counter never moves) and the
# unit `active (running)` the whole time. Every series is queued during the tick
# and flushed at its end, so a tick that is always killed publishes NOTHING —
# and what reached a human was `ci_poller_heartbeat absent for 10m`, an alert
# whose text says the controller is dead about a controller that was merely
# never allowed to finish.
#
# watchdog-decision.selftest.sh tests the RULE and passes either way: the rule
# was never the half that was wrong. This file tests the INPUT the rule is fed —
# that a slow-but-moving tick keeps refreshing it, and that a tick stuck between
# two phases does not.
#
# Tenancy-agnostic — no customer literals.
#
# The stubs below (date, log, logger, the collect_* phases, tick_pool) are
# called only from the tick() this file `eval`s out of the controller, so
# shellcheck's reachability pass sees no caller and reports every one of them as
# dead code. Same reason as multi-pool.selftest.sh and metric-contract.
# shellcheck disable=SC2317

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTRL="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"
# shellcheck source=../../modules/ci-runner-host-pool/scripts/watchdog-decision.sh
source "$ROOT/modules/ci-runner-host-pool/scripts/watchdog-decision.sh"

pass=0
fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
    pass=$((pass + 1))
  else
    echo "FAIL $1: expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

# --- 1. beat writes the file the watchdog reads -------------------------------
beat_out=$(
  set -uo pipefail
  # shellcheck disable=SC1090
  eval "$(sed -n '/^beat() {/,/^}/p' "$CTRL")"
  STATE_DIR=$(mktemp -d)
  beat
  cat "$STATE_DIR/heartbeat"
  rm -rf "$STATE_DIR"
)
check "beat writes an epoch second to STATE_DIR/heartbeat" \
  ok "$(case "$beat_out" in '' | *[!0-9]*) echo "not-an-epoch:$beat_out" ;; *) echo ok ;; esac)"

# --- 2. a slow tick refreshes it AS IT GOES -----------------------------------
#
# tick() is extracted and run for real against stubbed phases and a fake clock
# that advances 100 seconds per phase — a 700s tick, more than twice the
# watchdog's threshold. What is asserted is not that tick() finished (it always
# did; it was killed for taking too long) but that the file was refreshed
# BETWEEN phases, which is the only thing that can distinguish the two.
slow_out=$(
  set -uo pipefail
  STATE_DIR=$(mktemp -d)
  CLOCK=1000
  OBSERVED=""

  # `date +%s` for beat and for tick's own timing; `date -u +%FT%TZ` for log.
  # It READS the fake clock and never advances it: the phases are what take
  # time. A clock advanced by `date` would be advanced by `beat` itself, and the
  # test would then measure its own instrumentation.
  date() {
    case "${1:-}" in
      +%s) printf '%s\n' "$CLOCK" ;;
      *) printf 'stub\n' ;;
    esac
  }
  log() { :; }
  logger() { :; }

  # Each stubbed phase records what the watchdog WOULD have read at the moment
  # the phase began: the age of the heartbeat against the fake clock.
  # A MISSING file counts as infinitely old, never as fresh: a tick that stopped
  # writing one at all is the exact regression this test exists to catch, and a
  # default of "now" would make that case pass.
  observe() {
    local hb
    hb=$(cat "$STATE_DIR/heartbeat" 2>/dev/null || echo 0)
    OBSERVED="$OBSERVED $(( CLOCK - hb ))"
    # …and then the phase does its 100 seconds of work.
    CLOCK=$((CLOCK + 100))
  }
  collect_runners() { observe; return 0; }
  collect_demand() { observe; }
  collect_outcomes() { observe; }
  collect_parked() { observe; }
  collect_apply_build() { observe; }
  pool_select() { :; }
  tick_pool() { observe; }
  queue_controller_series() { :; }
  queue_outcome_series() { :; }
  flush_series() { :; }

  # The state tick() reads, set here because the phases that would normally set
  # it are stubbed. Read only inside the eval'd tick(), so SC2034 for the same
  # reason the stubs above are SC2317.
  # shellcheck disable=SC2034
  BLIND_TICKS=0
  # shellcheck disable=SC2034
  RUNNER_LIST_STATUS=200
  # shellcheck disable=SC2034
  POOLS=(a b)

  # shellcheck disable=SC1090
  eval "$(sed -n '/^beat() {/,/^}/p' "$CTRL")"
  # shellcheck disable=SC1090
  eval "$(sed -n '/^tick() {/,/^}/p' "$CTRL")"

  # run_loop() writes one before entering the tick; the harness stands in for it
  # so that the first phase is judged against a real heartbeat rather than
  # against a missing file.
  beat
  tick

  # The largest age any phase saw. Under the old code this was the whole tick;
  # under the new one it can never exceed one phase.
  worst=0
  for a in $OBSERVED; do [ "$a" -gt "$worst" ] && worst=$a; done
  printf '%s\n' "$worst"
  rm -rf "$STATE_DIR"
)
worst_age=$slow_out

# 300s is the watchdog threshold the fleet runs (10 polls, floor 300).
check "no phase of a 700s tick ever sees a heartbeat past the threshold" \
  hold "$(case "$(watchdog_verdict 1 "$worst_age" 86400 300)" in hold:*) echo hold ;; *) echo restart ;; esac)"

# And the same fact stated as the loop the fix exists to break: the watchdog
# looking at this controller mid-tick holds instead of restarting it.
check "a slow-but-moving tick is not restarted" \
  "hold:fresh-${worst_age}s" "$(watchdog_verdict 1 "$worst_age" 86400 300)"

# --- 3. a tick STUCK between two phases still ages out ------------------------
#
# The counterpart, and the reason beat() is called at phase boundaries rather
# than from a background refresher: a refresher would keep the file fresh while
# the loop was blocked on a socket, disabling the watchdog altogether. Here one
# phase never returns, so nothing writes the file and the age grows without
# bound — which must still be a restart.
stuck_age=$(
  set -uo pipefail
  STATE_DIR=$(mktemp -d)
  CLOCK=1000
  date() { case "${1:-}" in +%s) printf '%s\n' "$CLOCK" ;; *) printf 'stub\n' ;; esac; }
  # shellcheck disable=SC1090
  eval "$(sed -n '/^beat() {/,/^}/p' "$CTRL")"
  beat
  # The phase blocks for an hour: no beat, because a blocked phase reaches no
  # boundary.
  CLOCK=$((CLOCK + 3600))
  printf '%s\n' "$(( CLOCK - $(cat "$STATE_DIR/heartbeat") ))"
  rm -rf "$STATE_DIR"
)
check "a tick blocked inside one phase is still judged wedged" \
  restart "$(watchdog_verdict 1 "$stuck_age" 86400 300)"

# --- 4. the boundaries are still there ----------------------------------------
#
# A structural check, because deleting a `beat` reintroduces the incident
# silently: the tick would still pass every test above that does not walk the
# phase it guards. Every phase call in tick() must be followed by one.
missing=$(
  awk '/^tick\(\) \{/,/^\}/' "$CTRL" |
    grep -A2 -E '^  (collect_runners|collect_demand|collect_outcomes|collect_parked|collect_apply_build|    tick_pool)' |
    awk '/^  (collect_|    tick_pool)/ { phase=$1; found=0; next }
         /beat/ { found=1 }
         /^--$/ { if (phase != "" && found == 0) print phase; phase="" }
         END { if (phase != "" && found == 0) print phase }'
)
check "every phase of tick() is followed by a beat" "" "$missing"

# The per-host walk, which is where a tick's minutes actually go.
check "the host walk beats once per host" \
  yes "$(awk '/^tick_pool\(\) \{/,/^\}/' "$CTRL" |
    grep -A12 'read -r host status host_tpl host_uri' | grep -c '^  *beat$' |
    awk '{ print ($1 >= 1 ? "yes" : "no") }')"

echo
echo "heartbeat-progress: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
