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
  # Every message condition is paired with the tag that writes it, and anchored
  # at both ends. A bare `jsonPayload.message:"..."` is a substring search, and
  # root lines under these tags quote text a job chose (#1410 review F1).
  pairs="$(printf '%s' "$lf" | grep -oE 'jsonPayload\.identifier="[^"]+" AND jsonPayload\.message=~"[^"]+"' |
    sed -E 's/^jsonPayload\.identifier="([^"]+)" AND jsonPayload\.message=~"([^"]+)"$/\1\t\2/')"
  [ -n "$pairs" ] || fail "the filter pairs no identifier with a message regex"
  nmsg="$(printf '%s' "$lf" | grep -oE 'jsonPayload\.message' | grep -c .)"
  npair="$(printf '%s\n' "$pairs" | grep -c .)"
  [ "$nmsg" = "$npair" ] || fail "$((nmsg - npair)) message condition(s) are not paired with an identifier and a =~ regex"
  while IFS=$'\t' read -r id re; do
    [ -n "$id" ] || continue
    case "$re" in ^slot\ *\$) ;; *) fail "not anchored at both ends from 'slot <n>: ': $re" ;; esac
    case "$re" in *'.*'* | *'.+'*) fail "a wildcard where only a computed field belongs: $re" ;; esac
    case " $ids " in *" $id "*) ;; *) fail "'$id' is not a tag the shipper sends" ;; esac
  done <<<"$pairs"

  # filter_hit <identifier> <message> -- the filter's conditions, evaluated.
  # Here-strings, never `printf | grep -q`: under pipefail that is the #1409
  # race, where a match is reported as a failure.
  filter_hit() {
    local id re
    while IFS=$'\t' read -r id re; do
      [ "$id" = "$1" ] && grep -Eq -- "$re" <<<"$2" && return 0
    done <<<"$pairs"
    return 1
  }

  # The writer: every say line, rendered with the values the reset computes.
  render_say() { # <raw line> -> the message it logs
    local m="$1"
    m="${m#*say \"}"; m="${m%\"*}"
    m="${m//'\$idx'/3}"; m="${m//'\$sock'//run/user/1003/docker.sock}"; m="${m//'\$dsock'/foreign}"
    m="${m//'\$burns'/4}"; m="${m//'\$left'/2}"; m="${m//'\$u'/ci-s3}"
    printf '%s' "$m"
  }
  : >"$d/alerting"
  while IFS=$'\t' read -r tag raw; do
    msg="$(render_say "$raw")"
    if filter_hit "$tag" "$msg"; then
      printf '%s\t%s\n' "$tag" "$msg" >>"$d/alerting"
    fi
  done <"$d/says"
  # Each condition must be satisfied by a line the writer really prints.
  while IFS=$'\t' read -r id re; do
    [ -n "$id" ] || continue
    ok_=""
    while IFS=$'\t' read -r tag msg; do
      [ "$tag" = "$id" ] && grep -Eq -- "$re" <<<"$msg" && { ok_=1; break; }
    done <"$d/alerting"
    [ -n "$ok_" ] || fail "no say line in host-startup.sh, under $id, matches: $re"
  done <<<"$pairs"
  # ...and the four failures the policy documents are all among them.
  for ph in "is not the socket it listens on" "reads as foreign" "refusing to call this slot clean" "taking it out of service"; do
    grep -F -- "$ph" "$d/alerting" >/dev/null 2>&1 || fail "no alerting line says '$ph' any more"
  done
  grep -q 'echo foreign' "$hs" || fail "daemon_sock no longer answers 'foreign'"

  # The recovery line must not page.
  while IFS=$'\t' read -r tag raw; do
    filter_hit "$tag" "$(render_say "$raw")" && fail "the recovery line pages: a slot coming BACK would alert"
  done < <(grep -F 'clean again after being condemned' "$d/says")

  # --- 3b. forgeries: text a job chooses, in root lines under shipped tags -------
  # Each payload is an alerting sentence, or its bare phrase, planted where a
  # job can plant it. None may match.
  payloads=()
  while IFS=$'\t' read -r _ msg; do payloads+=("$msg"); done <"$d/alerting"
  payloads+=("is not the socket it listens on" "x reads as foreign" "refusing to call this slot clean" "taking it out of service")
  tcm="$(grep -F 'TOOL CACHE MISS — a job put' "$d/says")"
  [ -n "$tcm" ] || fail "the TOOL CACHE MISS line moved -- the forgery below would test nothing"
  dsaid="$(grep -F 'could not list the containers the last job left' "$d/says")"
  [ -n "$dsaid" ] || fail "the docker_said line moved -- the forgery below would test nothing"
  for pl in "${payloads[@]}"; do
    # (a) a directory name in the slot's tool cache.
    raw="${tcm#*$'\t'}"
    raw="${raw//'\$(safe "\$t_tool")'/"$pl"}";raw="${raw//'\$(safe "\$t_ver")'/1.0}"; raw="${raw//'\$(safe "\$t_arch")'/x64}"
    filter_hit "${tcm%%$'\t'*}" "$(render_say "$raw")" && fail "a tool-cache directory named '$pl' forges a page"
    # (b) an argument a job appends to pin-hold through sudo.
    filter_hit ci-pin-hold "refusing: unknown argument '$pl'" && fail "a pin-hold argument '$pl' forges a page"
    filter_hit ci-slot-reset "refusing: unknown argument '$pl'" && fail "a pin-hold-shaped line under the reset's tag, carrying '$pl', forges a page"
    # (c) the slot daemon's own error text.
    raw="${dsaid#*$'\t'}"
    raw="${raw//'\$(docker_said)'/" (docker: $pl)"}"
    filter_hit "${dsaid%%$'\t'*}" "$(render_say "$raw")" && fail "a docker error reading '$pl' forges a page"
  done
  # And the argument is sanitised before it is logged at all.
  grep -qF "unknown argument '\\\$(safe \"\\\$1\")'" "$hs" || fail "pin-hold logs its unknown argument without safe()"
  grep -qF "unknown argument '\\\$1'" "$hs" && fail "pin-hold still logs an unknown argument raw"

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
mutate "the filter pages on recovery"      src 's@\[0-9\]+ consecutive failures to reach a clean state — taking it out of service rather than letting it keep winning jobs it will burn\$@[^ ]+ again after being condemned — putting it back into service$@'
mutate "a phrase nobody prints"            src 's@refusing to call this slot clean\$"@refusing to call the slot clean$"@'
mutate "a bare phrase beside the pairs"    src 's@ OR (jsonPayload.identifier="ci-slot-sweep"@ OR jsonPayload.message:"taking it out of service" OR (jsonPayload.identifier="ci-slot-sweep"@'
mutate "a condition unanchored at the end" src 's@\[^ \]+ reads as foreign\$"@[^ ]+ reads as foreign"@'
mutate "a wildcard where a field belongs"  src 's@\[^ \]+ reads as foreign\$"@.+ reads as foreign$"@'
mutate "a condition under the wrong tag"   src 's@(jsonPayload.identifier="ci-slot-sweep" AND@(jsonPayload.identifier="ci-slot-reset" AND@'
# The forgeries alone: anchored at both ends, no .* or .+, the writer's own
# line still matches -- only a planted phrase shows the field is too wide.
mutate "a field wide enough to plant into" src 's@\[^ \]+ reads as foreign\$"@[^!]+ reads as foreign[^!]*$"@'
mutate "pin-hold logs its argument raw"    hs  "s@unknown argument '\\\\\$(safe \"\\\\\$1\")'@unknown argument '\\\\\$1'@"
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
