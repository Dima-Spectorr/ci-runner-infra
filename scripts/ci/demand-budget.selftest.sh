#!/usr/bin/env bash
# The two rules that decide whether a bounded demand sweep can still overrun the
# watchdog window — asserted against the DEPLOYED text, extracted from the files
# that ship it, never a copy pasted in here.
#
# Both were review findings on the fix for the restart loop, and both are the
# same class of mistake: a bound that looks like a bound but is not one.
#
#   * a call was allowed to START inside the budget, so the last call of an
#     exhausted sweep could spend a whole curl timeout beyond it — a 90s budget
#     authorised ~180s of demand work and ate the watchdog reserve;
#   * the slow-tick alert threshold was the constant 150, while the watchdog
#     window is max(300, poll_interval_seconds * 10) — so a pool polling every
#     60s (600s window) would page for healthy 200s ticks, and the documented
#     remedy of raising the poll interval would not clear it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTRL="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"
ALERTS="$ROOT/scripts/ci/ensure-alert-policies.sh"

# shellcheck disable=SC1090
source <(sed -n '/^budget_allows_call()/,/^}/p' "$CTRL")
# shellcheck disable=SC1090
source <(sed -n '/^watchdog_threshold()/,/^}/p' "$ALERTS")

pass=0; fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
  else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1)); fi
}
verdict() { budget_allows_call "$1" "$2" "$3" && echo start || echo skip; }

# ── the call must fit, not merely start ──────────────────────────────────────
# now=100, deadline=200, timeout=30: 70s of room, the call fits.
check "a call that fits is started" start "$(verdict 100 200 30)"

# The finding itself: 29s of budget left, a 30s timeout. The old rule started
# this call because now < deadline, and it ran 1s past the deadline plus 29.
check "a call that would overrun the deadline is skipped" skip "$(verdict 171 200 30)"

# Exactly fits — allowed, or a budget that is a whole multiple of the timeout
# would waste its last slot.
check "a call that exactly fits is started" start "$(verdict 170 200 30)"

check "past the deadline, nothing starts" skip "$(verdict 201 200 30)"
check "at the deadline, nothing starts" skip "$(verdict 200 200 30)"

# ── the alert threshold follows the watchdog window ──────────────────────────
check "default poll: floor applies" 300 "$(watchdog_threshold 20)"
check "a fast poll cannot lower the window below the floor" 300 "$(watchdog_threshold 5)"
check "a 60s poll widens the window to 600s" 600 "$(watchdog_threshold 60)"
# The false page from the review: 200s ticks on a 60s poll are healthy, and a
# fixed 150s threshold pages for them.
check "half a 600s window is 300s, not 150s" 300 "$(( $(watchdog_threshold 60) / 2 ))"

# ── structural: the tested text is the shipped text ──────────────────────────
grep -q 'budget_allows_call "$(date +%s)" "$deadline" "$CURL_MAX_TIME"' "$CTRL" \
  && check "the controller uses the tested budget rule" yes yes \
  || check "the controller uses the tested budget rule" yes no

grep -q 'WATCHDOG_THRESHOLD="$(watchdog_threshold "$POLL")"' "$ALERTS" \
  && check "the alert script uses the tested threshold rule" yes yes \
  || check "the alert script uses the tested threshold rule" yes no

# The deadline must cover the run-list calls too — starting it after them was
# how the budget came to authorise twice its own value.
if sed -n '/^collect_demand()/,/^}/p' "$CTRL" \
   | awk '/deadline=\$\(\(sweep_start \+ DEMAND_BUDGET\)\)/{d=NR} /actions\/runs\?status=queued/{r=NR} END{exit !(d && r && d < r)}'; then
  check "the budget starts before the run-list calls" yes yes
else
  check "the budget starts before the run-list calls" yes no
fi

# A skipped count left over from a previous tick reads as "demand is still
# truncated" forever, so it resets with the other counters, not after the loop.
if sed -n '/^collect_demand()/,/^}/p' "$CTRL" \
   | awk '/DEMAND_RUNS_SKIPPED=0/{z=NR} /\[ -n "\$ids" \] \|\| return 0/{e=NR} END{exit !(z && e && z < e)}'; then
  check "the skipped counter resets before every early return" yes yes
else
  check "the skipped counter resets before every early return" yes no
fi

echo "demand-budget selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
