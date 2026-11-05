#!/usr/bin/env bash
# Self-test for the `runnerfastexit` alert (#1676): fast_exit() in the slot loop
# (host-startup.sh), the log metric ci_runner_fast_exits, and the policy that
# pages on it.
#
# WHY THIS TEST EXISTS.
#
# On 2026-11-05 every runner in the fleet registered and stopped about 3 s
# later, because GitHub had deprecated the baked version. The loop re-minted at
# once, spent the App's API budget, and the only record of why sat in each
# slot's _diag/Runner_*.log. The fix is three files agreeing on two sentences:
# the slot loop says them, the shipper sends the tag, the metric matches them.
# Every disagreement is silent -- a reworded sentence leaves a metric that exists
# and a policy that syncs green and never fires -- so each sentence is pinned
# against its WRITER, and the backoff that protects the API budget is run.
# Then each check is broken on purpose, and the suite must notice.

# Patterns match the TEXT of the scripts, where `$idx` is literal characters.
# shellcheck disable=SC2016
# The stubs in run_fe are called from the eval'd fast_exit.
# shellcheck disable=SC2317

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
SRC="$HERE/ensure-alert-policies.sh"
HS="$ROOT/modules/ci-runner-host-pool/scripts/host-startup.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

TOP="$(mktemp -d)"
trap 'rm -rf "$TOP"' EXIT

# shellcheck disable=SC2034  # read inside the eval'd blocks.
check_all() (
  src="$1"
  hs="$2"
  d="$(mktemp -d "$TOP/c.XXXXXX")"
  fail() { printf '%s\n' "$1"; }

  MUTE_BLOCK="$(sed -n '/^MUTE_FILTER=""$/,/^fi$/p' "$src")"
  PJ="$(sed -n '/^policy_json() {/,/^}$/p' "$src")"
  KEYS="$(sed -n 's/^for key in \(.*\); do$/\1/p' "$src")"
  FE="$(sed -n '/^fast_exit() {/,/^}$/p' "$hs")"
  for part in MUTE_BLOCK PJ KEYS FE; do
    [ -n "${!part}" ] || { fail "$part not found"; exit 0; }
  done

  # --- 1. the policy is synced and has the shape it claims ----------------------
  case " $KEYS " in *" runnerfastexit "*) ;; *) fail "'runnerfastexit' is not in the sync loop -- the policy is never written" ;; esac
  (
    MUTED_POOLS=()
    channel="projects/p/notificationChannels/1"
    POLL=20; WATCHDOG_THRESHOLD=300; SLOW_TICK=240; QUEUE_WAIT=900
    IDLE_THRESHOLD=1200; DRAIN_GRACE=900; REGISTER_GRACE=600; CACHE_STALE_HOURS=48
    eval "$MUTE_BLOCK" || exit 1
    eval "$PJ"
    policy_json runnerfastexit
  ) >"$d/p.json"
  jq -e . "$d/p.json" >/dev/null 2>&1 || { fail "the runnerfastexit policy does not render to valid JSON"; exit 0; }
  c='.conditions[0].conditionThreshold'
  metric=$(jq -r "$c.filter" "$d/p.json" | sed -n 's/.*metric\.type="\([^"]*\)".*/\1/p')
  [ "$metric" = logging.googleapis.com/user/ci_runner_fast_exits ] || fail "the policy watches '$metric'"
  [ "$(jq -r "$c.comparison" "$d/p.json")" = COMPARISON_GT ] || fail "the comparison is not GT"
  thr=$(jq -r "$c.thresholdValue" "$d/p.json")
  # One early stop is a deregistration race; a refused host makes dozens.
  awk -v t="$thr" 'BEGIN { exit !(t >= 1 && t <= 10) }' || fail "threshold $thr is outside 1..10"
  jq -r '.documentation.content' "$d/p.json" | grep -q 'Rolling a new runner version out' ||
    fail "the policy's documentation does not point at the rollout section"

  # --- 2. the metric reads the shipper's log, under a tag the shipper sends ------
  lf="$(sed -n '/^ensure_log_metric ci_runner_fast_exits/,/^$/p' "$src" | sed -n "3s/^ *'\(.*\)'$/\1/p")"
  [ -n "$lf" ] || { fail "the ci_runner_fast_exits filter could not be read"; exit 0; }
  logid="$(sed -n 's/^LOG_ID=\([a-z-]*\)$/\1/p' "$hs")"
  case "$lf" in *"logName:\"logs/$logid\""*) ;; *) fail "the filter does not select the shipper's log ($logid)" ;; esac
  ids="$(sed -n 's/^IDENTIFIERS=(\(.*\))$/\1/p' "$hs")"
  pairs="$(printf '%s' "$lf" | grep -oE 'jsonPayload\.identifier="[^"]+" AND jsonPayload\.message=~"[^"]+"' |
    sed -E 's/^jsonPayload\.identifier="([^"]+)" AND jsonPayload\.message=~"([^"]+)"$/\1\t\2/')"
  nmsg="$(printf '%s' "$lf" | grep -oE 'jsonPayload\.message' | grep -c .)"
  [ "$nmsg" = "$(printf '%s\n' "$pairs" | grep -c .)" ] || fail "a message condition is not paired with an identifier"
  [ "$nmsg" = 2 ] || fail "the filter has $nmsg message conditions, want 2"
  while IFS=$'\t' read -r id re; do
    [ -n "$id" ] || continue
    case "$re" in ^slot\ *\$) ;; *) fail "not anchored at both ends: $re" ;; esac
    case "$re" in *'.*'* | *'.+'* | *"\\"*) fail "a wildcard or backslash in: $re" ;; esac
    case " $ids " in *" $id "*) ;; *) fail "'$id' is not a tag the shipper sends" ;; esac
    [ "$id" = ci-slot-loop ] || fail "condition under '$id', not the slot loop's tag"
  done <<<"$pairs"

  # --- 3. each condition matches a sentence fast_exit really says ----------------
  grep -q '^say() { logger -t ci-slot-loop ' "$hs" || fail "the slot loop's say() no longer logs under ci-slot-loop"
  printf '%s\n' "$FE" | grep 'say "' | sed 's/^[^"]*say "//; s/"[^"]*$//' |
    sed 's/\$idx/3/g; s/\$id/123456/g; s/\${lived}/3/g; s/\${wait}/47/g' >"$d/said"
  [ "$(grep -c . "$d/said")" = 2 ] || fail "fast_exit has $(grep -c . "$d/said") say lines, want 2"
  while IFS=$'\t' read -r _ re; do
    [ -n "$re" ] || continue
    grep -Eq -- "$re" "$d/said" || fail "no fast_exit sentence matches: $re"
  done <<<"$pairs"
  # Forgeries: the sentence with text a job chose in an open field.
  for pl in "slot 3: runner 1 stopped 3s after it started without taking a job -- registering again in 30s; x" \
    "x slot 3: runner 1 stopped 3s after it started without taking a job -- registering again in 30s" \
    "slot 3: runner \$(id) stopped 3s after it started without taking a job -- registering again in 30s"; do
    while IFS=$'\t' read -r _ re; do
      [ -n "$re" ] || continue
      grep -Eq -- "$re" <<<"$pl" && fail "a forged line matches: $pl"
    done <<<"$pairs"
  done

  # --- 4. the backoff, run ---------------------------------------------------------
  # Stubs: a clock, a gate, a log and a sleep that records instead of sleeping.
  run_fe() ( # <lived seconds...> -> the waits, one per line ("-" when none)
    T=1000000
    date() { echo "$T"; }
    gate() { [ -n "${GATED:-}" ]; }
    say() { printf '%s\n' "$*" >>"$d/say.log"; }
    sleep() { slept="$1"; }
    find() { [ -n "${DIAG:-}" ] && echo "$d/Runner_1.log"; }
    idx=3 id=99 SLOT_ROOT="$d" FAST_EXIT_SECS=60 fast_exits=0
    eval "$FE"
    for lived in "$@"; do
      slept=-
      fast_exit $((T - lived))
      echo "$slept"
    done
  )
  : >"$d/say.log"
  waits=$(run_fe 3 3 3 3 3 3 3 3 | tr '\n' ' ')
  # 30 doubling, capped at 900, with up to 29s of jitter on top.
  i=0
  for w in $waits; do
    i=$((i + 1))
    case "$i" in 1) lo=30 ;; 2) lo=60 ;; 3) lo=120 ;; 4) lo=240 ;; 5) lo=480 ;; *) lo=900 ;; esac
    { [ "$w" != - ] && [ "$w" -ge "$lo" ] && [ "$w" -lt $((lo + 30)) ]; } ||
      fail "fast exit #$i waited '$w', want $lo..$((lo + 29)) (all: $waits)"
  done
  [ "$i" = 8 ] || fail "the backoff ran $i times, want 8"
  w=$(run_fe 3 3 120 3 | tail -n 1)
  { [ "$w" -ge 30 ] && [ "$w" -lt 60 ]; } || fail "a normal lifetime does not reset the backoff (waited $w after it)"
  [ "$(run_fe 120 | tr -d '\n')" = - ] || fail "a runner that lived 120s was treated as a fast exit"
  [ "$(GATED=1 run_fe 3 | tr -d '\n')" = - ] || fail "a runner deregistered by a drain or cordon was treated as a fast exit"
  : >"$d/say.log"
  printf 'Runner version v2.336.0 is deprecated and cannot receive messages.\n' >"$d/Runner_1.log"
  DIAG=1 run_fe 3 >/dev/null
  grep -q 'as a deprecated version' "$d/say.log" || fail "GitHub's deprecation message in _diag did not produce the deprecated-version line"
  : >"$d/say.log"
  printf 'nothing to see\n' >"$d/Runner_1.log"
  DIAG=1 run_fe 3 >/dev/null
  grep -q 'as a deprecated version' "$d/say.log" && fail "the deprecated-version line fired without GitHub's message"
  grep -q 'nothing to see' "$d/say.log" && fail "fast_exit logged text from _diag, which a job can write"

  # --- 5. the loop calls it, and the loop's template can expand SLOT_ROOT --------
  grep -q '^    fast_exit "\$started"$' "$hs" || fail "the slot loop never calls fast_exit"
  grep -q 'UTILITY SLOT_BINDING_DIR SLOT_ROOT$' "$hs" || fail "SLOT_ROOT is not exported into slot-loop.sh -- fast_exit cannot find _diag"
  grep -q '^  started=\$(date +%s)$' "$hs" || fail "the slot loop no longer records when the agent started"
  exit 0
)

failures=$(check_all "$SRC" "$HS")
if [ -n "$failures" ]; then
  printf 'FAIL: %s\n' "$failures"
  exit 1
fi
echo "ok: runnerfastexit alert, metric and slot-loop backoff agree"

mrc=0
mutate() { # <name> <which: src|hs> <sed expression>
  local name="$1" which="$2" expr="$3" s="$SRC" h="$HS" m
  m="$TOP/m.${name// /-}"
  if [ "$which" = src ]; then sed "$expr" "$SRC" >"$m" && s="$m"; else sed "$expr" "$HS" >"$m" && h="$m"; fi
  if cmp -s "$m" "$([ "$which" = src ] && echo "$SRC" || echo "$HS")"; then
    echo "FAIL: mutation '$name' changed nothing -- its pattern is stale"; mrc=1; return
  fi
  [ -n "$(check_all "$s" "$h")" ] || { echo "FAIL: mutation '$name' survived"; mrc=1; }
}
mutate "policy not synced" src 's/ slotreset runnerfastexit; do/ slotreset; do/'
mutate "sentence reworded" hs 's/without taking a job -- registering again/without a job -- registering again/'
mutate "filter unanchored" src 's/registering again in \[0-9\]+s\$"/registering again in [0-9]+s"/'
mutate "no backoff cap" hs 's/\[ "\$wait" -le 900 \] || wait=900/:/'
mutate "no reset on a normal life" hs '/^  if \[ "\$lived" -ge "\$FAST_EXIT_SECS" \]; then$/,/^  fi$/s/fast_exits=0/:/'
mutate "drains count as refusals" hs 's/^  gate >\/dev\/null \&\& return 0$/  :/'
mutate "SLOT_ROOT not exported" hs 's/UTILITY SLOT_BINDING_DIR SLOT_ROOT$/UTILITY SLOT_BINDING_DIR/'
mutate "deprecation phrase lost" hs "s/'is deprecated|cannot receive messages'/'is unsupported'/"
[ "$mrc" = 0 ] && echo "ok: every mutation was caught"
exit "$mrc"
