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
source <(sed -n '/^is_iso8601()/,/^}/p' "$CTRL")
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

# ── a job-age gauge must not measure the age of midnight ─────────────────────
#
# jq writes `-` into a stamp column when a run has no job in that state, because
# a tab-separated field cannot be empty. The stamp loops used to hand every word
# straight to `date -d` and trust its exit status to reject the rest.
#
# It does not reject it. This is the whole finding, asserted against the real
# binary rather than described: if a later reader ever wonders why the shape
# test is there, this line answers it.
midnight=$(date -u -d "$(date -u +%Y-%m-%d)" +%s)
for junk in - 0 Z; do
  check "date accepts '$junk' and calls it midnight — hence the shape test" \
    "$midnight" "$(date -u -d "$junk" +%s 2>/dev/null || echo rejected)"
  check "the shape test rejects '$junk'" reject \
    "$(if is_iso8601 "$junk"; then echo accept; else echo reject; fi)"
done
check "a real GitHub instant is accepted" accept \
  "$(if is_iso8601 2026-08-29T00:00:06Z; then echo accept; else echo reject; fi)"
# A fractional-second or offset form is still an instant; the trailing glob has
# to allow it or a valid stamp would be silently dropped and read as no demand.
check "an offset instant is accepted" accept \
  "$(if is_iso8601 2026-08-29T00:00:06+03:00; then echo accept; else echo reject; fi)"
check "a date with no time is rejected" reject \
  "$(if is_iso8601 2026-08-29; then echo accept; else echo reject; fi)"

# Both loops, because both were wrong in the same way: the queued-stamp loop
# pegged ci_queue_wait_seconds_max and the in-progress one pegged
# ci_job_running_seconds_max, each to seconds-since-UTC-midnight, on every pool,
# every day (#518). D_WAIT is a high-water mark, so the sentinel does not join
# the real samples — it buries them.
guarded=$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -c 'is_iso8601 "\$s" || continue')
check "both stamp loops guard the token before parsing it" 2 "$guarded"

# ── the alert threshold follows the watchdog window ──────────────────────────
check "default poll: floor applies" 300 "$(watchdog_threshold 20)"
check "a fast poll cannot lower the window below the floor" 300 "$(watchdog_threshold 5)"
check "a 60s poll widens the window to 600s" 600 "$(watchdog_threshold 60)"
# The false page from the review: 200s ticks on a 60s poll are healthy, and a
# fixed 150s threshold pages for them.
check "a 600s window derives 480s, not a fixed 150s" 480 "$(( $(watchdog_threshold 60) * 4 / 5 ))"
# Four fifths and not half, which is what shipped first. Half a 300s window is
# 150s, and a tick of 150s on a 20s poll is the middle of the healthy range —
# measured over a week, every incident this raised peaked at 179s against a
# window nothing came near exhausting. The alert is meant to be the precursor to
# the watchdog restarting the controller, so it has to sit close enough to the
# window to mean that, and still leave a full tick of warning.
check "the default window warns at 240s, not at 150s" 240 "$(( $(watchdog_threshold 20) * 4 / 5 ))"

# ── structural: the tested text is the shipped text ──────────────────────────
# A grep for a literal line of shell: the $(…) and "$VAR" inside these patterns
# are the text being searched for, not expansions — hence single quotes.
found() { if grep -qF "$2" "$1"; then echo yes; else echo no; fi; }

# shellcheck disable=SC2016
check "the controller uses the tested budget rule" yes \
  "$(found "$CTRL" 'budget_allows_call "$(date +%s)" "$deadline" "$CURL_MAX_TIME"')"

# shellcheck disable=SC2016
check "the alert script uses the tested threshold rule" yes \
  "$(found "$ALERTS" 'WATCHDOG_THRESHOLD="$(watchdog_threshold "$POLL")"')"

# shellcheck disable=SC2016
check "the slow-tick threshold is four fifths of the window" yes \
  "$(found "$ALERTS" 'SLOW_TICK=$(( WATCHDOG_THRESHOLD * 4 / 5 ))')"

# The two thresholds that must follow the POOL's own configuration rather than a
# literal. A pool may widen either grace — Windows is FORCED to, the module
# floors register_grace_seconds at 1200 there — and a fixed threshold then fires
# at half the boot time the pool is configured to permit, on every cold start,
# forever. Both derive from the value passed in, plus one alignment window.
# shellcheck disable=SC2016
check "the queue threshold follows register_grace_seconds" yes \
  "$(found "$ALERTS" 'QUEUE_WAIT=$(( REGISTER_GRACE + 300 ))')"
# shellcheck disable=SC2016
check "the idle threshold follows drain_grace_seconds" yes \
  "$(found "$ALERTS" 'IDLE_THRESHOLD=$(( DRAIN_GRACE + 300 ))')"

# Neither may be spent as a literal in the policy body: an interpolated
# threshold that some later edit pins back to a number is the same bug with the
# derivation still sitting above it, looking correct.
check "no policy hard-codes the old 600s queue threshold" yes \
  "$(if grep -q '"thresholdValue": 600\.0' "$ALERTS"; then echo no; else echo yes; fi)"
check "no policy hard-codes the old 1200s idle threshold" yes \
  "$(if grep -q '"thresholdValue": 1200\.0' "$ALERTS"; then echo no; else echo yes; fi)"

# Idle time alone does not mean a host should have gone: a pull request pinned
# to a host holds it warm on purpose and reports exactly the idle seconds of one
# the drain loop forgot. The pairing is the whole alert, and it has to be
# AND_WITH_MATCHING_RESOURCE — plain AND would let a pin on one pool silence a
# genuinely stuck host on another.
check "the idle policy pairs idle time with the pin holds" yes \
  "$(if sed -n '/pool not scaling to zero/,/^EOF/p' "$ALERTS" \
      | grep -q 'ci_pin_holds_honoured'; then echo yes; else echo no; fi)"
check "the idle policy matches the two conditions per resource" yes \
  "$(if sed -n '/pool not scaling to zero/,/^EOF/p' "$ALERTS" \
      | grep -q '"combiner": "AND_WITH_MATCHING_RESOURCE"'; then echo yes; else echo no; fi)"
# A policy naming a descriptor this script never declares is rejected 404 on a
# project where no host has published that series yet, and the run defers it.
check "the paired metric is declared as a descriptor" yes \
  "$(found "$ALERTS" 'ensure_descriptor ci_pin_holds_honoured')"

# Renaming a policy without this lookup does not rename anything: the inventory
# is keyed on displayName, the old policy stops matching, and the run creates a
# second one beside it — old thresholds still live, still notifying, no longer
# reachable from the file. Both policies renamed in this change need a row.
check "the sync loop can find a policy under its former name" yes \
  "$(if sed -n '/^for key in heartbeat/,/^done/p' "$ALERTS" \
      | grep -q 'former='; then echo yes; else echo no; fi)"
for old in "CI runners / queue starved (job waiting 10m)" \
           "CI runners / pool not scaling to zero (idle host 20m)"; do
  check "the former name is still looked up: ${old##*/ }" yes \
    "$(if grep -qF "$old" "$ALERTS"; then echo yes; else echo no; fi)"
done

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

# ── corpses are aged out server-side, not just uncounted ─────────────────────
#
# A wedged run stays `queued` forever and no API call clears it. The jq filter
# stops them being counted; it cannot stop them filling the 50-run page and
# pushing real queued work off it, which reads as demand 0 rather than as
# truncation. Measured 2026-08-27: IntegrateIT 31 queued, 26 of them corpses.

qline=$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -F 'actions/runs?status=queued')
# shellcheck disable=SC2016  # the $ is the text being matched, not an expansion
check "the queued run list is filtered by creation date" yes \
  "$(case "$qline" in *'$demand_since_q'*) echo yes ;; *) echo no ;; esac)"

# An in-progress run is legitimately older than the window — a long build can
# still have a job that started a minute ago — so this list must NOT be filtered.
ipline=$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -F 'actions/runs?status=in_progress')
check "the in-progress run list is NOT filtered by creation date" yes \
  "$(case "$ipline" in *created=*) echo no ;; *) echo yes ;; esac)"

# The cutoff is the same constant the jq filter uses, or the two disagree about
# which runs are corpses and the fetch drops one the counter still expects.
# shellcheck disable=SC2016
check "the cutoff is derived from DEMAND_MAX_AGE" yes \
  "$(found "$CTRL" 'date -u -d "@$((sweep_start - DEMAND_MAX_AGE))"')"

# gh_api hands the path to curl verbatim, so `>=` and the timestamp's colons
# have to be encoded here or the query is silently malformed.
ds=$(date -u -d "@0" +%Y-%m-%dT%H:%M:%SZ)
check "the cutoff is URL-encoded" "&created=%3E%3D1970-01-01T00%3A00%3A00Z" \
  "&created=%3E%3D${ds//:/%3A}"

echo "demand-budget selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
