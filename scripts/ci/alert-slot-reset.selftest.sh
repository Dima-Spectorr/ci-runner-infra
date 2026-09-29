#!/usr/bin/env bash
# Self-test for the `slotreset` alert in ensure-alert-policies.sh (#1403): the
# log-based metric ci_slot_reset_failures, and the policy that pages on it.
#
# WHY THIS TEST EXISTS.
#
# The metric counts lines a HOST writes, in a log the host's shipper names, by
# phrases the reset prints. That is three files agreeing on four strings, and
# every disagreement is silent: a phrase reworded in the reset, a log renamed in
# the shipper, a tag the shipper stops sending -- each leaves a metric that
# exists, a policy that syncs green, and an alert that never fires. So every
# string is pinned against its WRITER (host-startup.sh), never against a copy:
#
#   each phrase the filter matches is still printed by a `say` in the reset or
#   the sweep, and that tool's tag is one the shipper sends;
#   the log the filter selects is the log the shipper writes;
#   no phrase also matches the RECOVERY line, which must not page;
#   the rendered body survives policy_unchanged() -- or it PATCHes hourly and
#   re-notifies (alert-policy-idempotence.selftest.sh says why that matters).
#
# Then each check is broken on purpose, and the suite must notice.

# Patterns and mutations match the TEXT of the two scripts, in which `$dsock`
# and `${MUTE_FILTER}` are literal characters -- so the single quotes are the point.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
SRC="$HERE/ensure-alert-policies.sh"
HS="$ROOT/modules/ci-runner-host-pool/scripts/host-startup.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

TOP="$(mktemp -d)"; trap 'rm -rf "$TOP"' EXIT

# check_all <ensure-alert-policies.sh> <host-startup.sh> -> one line per failure
# Runs in a subshell: it evals the shipping script's functions, and a mutant's
# must not leak into the next call.
# shellcheck disable=SC2034  # the assignments are read inside the eval'd blocks.
check_all() (
  src="$1"
  hs="$2"
  d="$(mktemp -d "$TOP/c.XXXXXX")"
  fail() { printf '%s\n' "$1"; }

  MUTE_BLOCK="$(sed -n '/^MUTE_FILTER=""$/,/^fi$/p' "$src")"
  PJ="$(sed -n '/^policy_json() {/,/^}$/p' "$src")"
  PU="$(sed -n '/^policy_unchanged() {$/,/^}$/p' "$src")"
  KEYS="$(sed -n 's/^for key in \(.*\); do$/\1/p' "$src")"
  for part in MUTE_BLOCK PJ PU KEYS; do
    [ -n "${!part}" ] || { fail "$part not found in ensure-alert-policies.sh"; exit 0; }
  done

  # --- 1. the policy is synced, and has the shape it claims ---------------------
  case " $KEYS " in *" slotreset "*) ;; *) fail "'slotreset' is not in the sync loop -- the policy is never written" ;; esac

  render() (
    MUTED_POOLS=("$@")
    channel="projects/p/notificationChannels/1"
    POLL=20; WATCHDOG_THRESHOLD=300; SLOW_TICK=240; QUEUE_WAIT=900
    IDLE_THRESHOLD=1200; DRAIN_GRACE=900; REGISTER_GRACE=600; CACHE_STALE_HOURS=48
    eval "$MUTE_BLOCK" || exit 1
    eval "$PJ"
    policy_json slotreset
  )
  render >"$d/p.json"
  render pool-broken >"$d/pm.json"
  if ! jq -e . "$d/p.json" >/dev/null 2>&1; then
    fail "the slotreset policy does not render to valid JSON"; exit 0
  fi
  c='.conditions[0].conditionThreshold'
  [ "$(jq '.conditions | length' "$d/p.json")" = 1 ] || fail "slotreset has $(jq '.conditions | length' "$d/p.json") conditions, want 1"
  metric=$(jq -r "$c.filter" "$d/p.json" | sed -n 's/.*metric\.type="\([^"]*\)".*/\1/p')
  [ "$metric" = logging.googleapis.com/user/ci_slot_reset_failures ] || fail "slotreset watches '$metric'"
  case "$(jq -r "$c.filter" "$d/p.json")" in *'resource.type="gce_instance"'*) ;; *) fail "a log metric on host lines lives on gce_instance" ;; esac
  jq -e "$c.comparison == \"COMPARISON_GT\" and $c.thresholdValue == 0" "$d/p.json" >/dev/null ||
    fail "slotreset must fire on any occurrence (> 0)"
  [ "$(jq -r "$c.aggregations[0].perSeriesAligner" "$d/p.json")" = ALIGN_SUM ] || fail "a log counter is summed, not averaged"
  [ "$(jq -r "$c.aggregations[0].alignmentPeriod" "$d/p.json")" = 600s ] || fail "the window is not ten minutes"
  cmp -s "$d/p.json" "$d/pm.json" || fail "--muted-pool changed a policy keyed on gce_instance, which it cannot mute"

  # --- 2. the metric exists, and reads the log the shipper writes ---------------
  grep -q '^ensure_log_metric ci_slot_reset_failures ' "$src" || fail "no ensure_log_metric creates ci_slot_reset_failures"
  lf="$(sed -n '/^ensure_log_metric ci_slot_reset_failures/,/^$/p' "$src" | sed -n "3s/^ *'\(.*\)'$/\1/p")"
  [ -n "$lf" ] || { fail "the ci_slot_reset_failures filter could not be read"; exit 0; }
  logid="$(sed -n 's/^LOG_ID=\([a-z-]*\)$/\1/p' "$hs")"
  [ -n "$logid" ] || fail "the shipper's LOG_ID was not found in host-startup.sh"
  case "$lf" in *"logName:\"logs/$logid\""*) ;; *) fail "the filter does not select the shipper's log ($logid): $lf" ;; esac
  case "$lf" in *projects/*) fail "the filter names a project" ;; esac

  # --- 3. every phrase is still written, by a tool the shipper sends ------------
  ids="$(sed -n 's/^IDENTIFIERS=(\(.*\))$/\1/p' "$hs")"
  [ -n "$ids" ] || fail "the shipper's IDENTIFIERS were not found"
  # One row per `say` line: <the tag of the say() in scope> TAB <the line>.
  awk '
    /^say\(\) \{ logger -t / { tag = $0; sub(/.*logger -t /, "", tag); sub(/ .*/, "", tag) }
    /say "/ { print tag "\t" $0 }
  ' "$hs" >"$d/says"
  phrases="$(printf '%s' "$lf" | grep -oE 'jsonPayload\.message:"[^"]+"' | sed 's/^jsonPayload\.message:"//; s/"$//')"
  [ -n "$phrases" ] || fail "the filter matches no jsonPayload.message phrase"
  while IFS= read -r ph; do
    [ -n "$ph" ] || continue
    if [ "$ph" = "reads as foreign" ]; then
      # Rendered from a variable: the reset prints "reads as \$dsock", and
      # daemon_sock() answers `foreign` for a name that is not its daemon's.
      rows="$(grep -F 'reads as \$dsock' "$d/says")"
      grep -q 'echo foreign' "$hs" || fail "daemon_sock no longer answers 'foreign'"
    else
      rows="$(grep -F -- "$ph" "$d/says")"
    fi
    [ -n "$rows" ] || { fail "no say line in host-startup.sh prints '$ph' any more"; continue; }
    while IFS=$'\t' read -r tag _; do
      case " $ids " in *" $tag "*) ;; *) fail "'$ph' is written under tag '$tag', which the shipper does not send" ;; esac
    done <<<"$rows"
    # The recovery line must not page.
    grep -F 'clean again after being condemned' "$d/says" | grep -qF -- "$ph" &&
      fail "'$ph' also matches the recovery line -- a slot coming BACK would page"
  done <<<"$phrases"

  # --- 4. idempotence against the REAL body -------------------------------------
  eval "$PU"
  jq '{alertPolicies: [. + {name: "projects/p/alertPolicies/9", enabled: true,
        creationRecord: {mutateTime: "2026-09-29T00:00:00Z"},
        mutationRecord: {mutateTime: "2026-09-29T01:00:00Z"},
        conditions: [.conditions | to_entries[] | .value + {name: ("projects/p/alertPolicies/9/conditions/" + (.key|tostring))}]}]}' \
    "$d/p.json" >"$d/listing.json"
  policy_unchanged projects/p/alertPolicies/9 "$d/p.json" "$d/listing.json" ||
    fail "slotreset reads as changed against its own echo -- it would PATCH and re-notify every apply"
)

PASS=0
FAIL=0
out="$(check_all "$SRC" "$HS")"
if [ -z "$out" ]; then PASS=$((PASS + 1)); else
  while IFS= read -r l; do [ -n "$l" ] && { FAIL=$((FAIL + 1)); echo "FAIL: $l"; }; done <<<"$out"
fi

# --- mutations: each must make check_all report something ---------------------
mutate() { # <description> <src|hs> <sed program>
  local m="$TOP/mutant" orig s="$SRC" h="$HS"
  if [ "$2" = src ]; then orig="$SRC"; s="$m"; else orig="$HS"; h="$m"; fi
  sed "$3" "$orig" >"$m"
  if cmp -s "$m" "$orig"; then FAIL=$((FAIL + 1)); echo "FAIL: mutation '$1' did not apply (stale anchor)"; return; fi
  if [ -n "$(check_all "$s" "$h")" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo "FAIL: mutation not detected: $1"; fi
}

mutate "the policy is not synced"          src 's/ unverifiedkeep slotreset; do$/ unverifiedkeep; do/'
mutate "the metric is never created"       src 's/^ensure_log_metric ci_slot_reset_failures /ensure_log_metric ci_slot_reset_failurez /'
mutate "the policy watches another metric" src 's@logging.googleapis.com/user/ci_slot_reset_failures@logging.googleapis.com/user/ci_slot_resets@'
mutate "the filter reads another log"      src "s@'logName:\"logs/ci-slot-lifecycle\" AND@'logName:\"logs/ci-slot-reset\" AND@"
mutate "the filter pages on recovery"      src 's@jsonPayload.message:"taking it out of service"@jsonPayload.message:"condemned"@'
mutate "a phrase nobody prints"            src 's@jsonPayload.message:"refusing to call this slot clean"@jsonPayload.message:"refusing to call the slot clean"@'
mutate "the counter is averaged"           src '/ci_slot_reset_failures\\" AND/{n;s/ALIGN_SUM/ALIGN_MEAN/}'
mutate "the window is not ten minutes"     src '/ci_slot_reset_failures\\" AND/{n;s/"600s"/"3600s"/}'
mutate "the pool mute reaches it"          src 's@ci_slot_reset_failures\\" AND resource.type=\\"gce_instance\\""@ci_slot_reset_failures\\" AND resource.type=\\"gce_instance\\"${MUTE_FILTER}"@'
mutate "it waits for five"                 src '/ci_slot_reset_failures > 0 in 10m/{n;s/"thresholdValue": 0.0/"thresholdValue": 5.0/}'
mutate "the body is not JSON"              src '/"CI runners \/ a slot failed its reset/{n;s/"OR",$/"OR"/}'
mutate "the reset rewords its refusal"    hs  's/-- refusing to call this slot clean/-- the slot is not clean/'
mutate "the sweep rewords its condemn"     hs  's/— taking it out of service rather/— removing it from service rather/'
mutate "the reset stops saying reads as"   hs  's/reads as \\\$dsock"/is \\$dsock"/'
mutate "the shipper renames its log"       hs  's/^LOG_ID=ci-slot-lifecycle$/LOG_ID=ci-host-journal/'
mutate "the shipper drops the sweep's tag" hs  's/^IDENTIFIERS=(ci-slot-reset ci-slot-sweep /IDENTIFIERS=(ci-slot-reset /'

printf '\nalert-slot-reset self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
