#!/usr/bin/env bash
# Self-test for the two pin-hold alerts in ensure-alert-policies.sh (#1388):
# `heldpool` (every running host held, no demand, 2h) and `unverifiedkeep`
# (hosts kept on a guest-attribute read that keeps failing).
#
# WHY THIS TEST EXISTS.
#
# On 2026-09-29 three pools sat full and idle for weeks -- 3/3, 3/3 and 4/4 hosts
# held by the pin-hold veto with ci_demand = 0 (#1384). Nothing paged, and not by
# accident: the only policy about an idle pool stands down while
# ci_pin_holds_honoured is non-zero, so the stuck veto silenced the alert that
# should have caught it. These two policies are the answer, and every way they
# can be wrong is silent -- a metric name the controller never writes, a
# denominator that pairs with nothing, a log filter that matches no event all
# produce a policy that exists, syncs green, and never fires. So each property
# is pinned here against the WRITER, not against a copy of the policy:
#
#   the metric names are the ones controller-startup.sh actually queues;
#   the 2h duration is not below the controller's own PIN_HOLD_MAX;
#   the log filter names events the controller actually sends, at WARNING;
#   the rendered body survives policy_unchanged() -- or it PATCHes hourly and
#   re-notifies (see alert-policy-idempotence.selftest.sh for why that matters).
#
# Everything is LIFTED from the shipping scripts, never copied.

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
SRC="$HERE/ensure-alert-policies.sh"
CTL="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"
PHD="$ROOT/modules/ci-runner-host-pool/scripts/beacon-decision.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }

MUTE_BLOCK="$(sed -n '/^MUTE_FILTER=""$/,/^fi$/p' "$SRC")"
PJ="$(sed -n '/^policy_json() {/,/^}$/p' "$SRC")"
PU="$(sed -n '/^policy_unchanged() {$/,/^}$/p' "$SRC")"
KEYS="$(sed -n 's/^for key in \(.*\); do$/\1/p' "$SRC")"
for part in MUTE_BLOCK PJ PU KEYS; do
  [ -n "${!part}" ] || { echo "FAIL: $part not found in ensure-alert-policies.sh"; exit 1; }
done
eval "$PU"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# render <key> [<muted-pool>...] -> that one policy body on stdout
# shellcheck disable=SC2034  # every assignment is read inside the eval'd blocks.
render() (
  set -uo pipefail
  key="$1"; shift
  MUTED_POOLS=("$@")
  channel="projects/p/notificationChannels/1"
  POLL=20; WATCHDOG_THRESHOLD=300; SLOW_TICK=240; QUEUE_WAIT=900
  IDLE_THRESHOLD=1200; DRAIN_GRACE=900; REGISTER_GRACE=600; CACHE_STALE_HOURS=48
  eval "$MUTE_BLOCK" || exit 1
  eval "$PJ"
  policy_json "$key"
)

# --- 1. both policies are actually synced -----------------------------------
for k in heldpool unverifiedkeep; do
  case " $KEYS " in
    *" $k "*) ok ;;
    *) bad "'$k' is not in the sync loop's key list -- the policy would never be written" ;;
  esac
done

render heldpool >"$tmp/held.json"
render heldpool pool-broken >"$tmp/held-muted.json"
render unverifiedkeep >"$tmp/keep.json"
render unverifiedkeep pool-broken >"$tmp/keep-muted.json"

# The facts the policies must agree with, read from the writer.
pin_hold_max="$(sed -n 's/^PIN_HOLD_MAX=\([0-9][0-9]*\)$/\1/p' "$CTL")"
[ -n "$pin_hold_max" ] || bad "PIN_HOLD_MAX not found in controller-startup.sh"

for m in ci_pin_holds_honoured ci_hosts_running ci_demand; do
  if grep -q "queue_series \"$m\" " "$CTL"; then ok; else
    bad "controller-startup.sh no longer queues $m -- heldpool would watch a series nobody writes"; fi
done
# The classes pin_hold_class() sends at WARNING -- the ones the log metric counts.
warn_classes="$(sed -n 's/.*echo "\([a-z-]*\) WARNING".*/\1/p' "$PHD" | tr '\n' ' ')"
[ -n "$warn_classes" ] || bad "pin_hold_class() sends nothing at WARNING any more"

# --- 2. the shape, parsed rather than grepped --------------------------------
python3 - "$tmp/held.json" "$tmp/held-muted.json" "$tmp/keep.json" "$tmp/keep-muted.json" \
  "${pin_hold_max:-0}" "$SRC" "$CTL" >"$tmp/shape.out" 2>&1 <<'PY'
import json, re, sys
held, held_m, keep, keep_m = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:5])
phm = int(sys.argv[5]); src = open(sys.argv[6], encoding="utf-8").read()
ctl = open(sys.argv[7], encoding="utf-8").read()
fails = []
def need(cond, msg):
    if not cond: fails.append(msg)
def secs(d): return int(d.rstrip("s"))
def metric(f):
    m = re.search(r'metric\.type="([^"]+)"', f or ""); return m.group(1) if m else None
PFX = "custom.googleapis.com/ci/"

# heldpool
need(held["combiner"] == "AND_WITH_MATCHING_RESOURCE",
     "heldpool must match conditions on the resource -- plain AND lets one pool's holds pair with another's demand")
c = held["conditions"]
need(len(c) == 2, "heldpool has %d conditions, want 2" % len(c))
r = c[0]["conditionThreshold"]; d = c[1]["conditionThreshold"]
need(metric(r.get("filter")) == PFX + "ci_pin_holds_honoured", "ratio numerator is not ci_pin_holds_honoured")
need(metric(r.get("denominatorFilter")) == PFX + "ci_hosts_running", "ratio denominator is not ci_hosts_running")
need(r.get("comparison") == "COMPARISON_GE" and float(r.get("thresholdValue", 0)) == 1.0,
     "ratio must be >= 1.0: a TERMINATED host is held but not running, so a stuck pool can read above 1")
need(r.get("aggregations") == r.get("denominatorAggregations"),
     "numerator and denominator must be aligned identically or the ratio compares different windows")
for a in (r.get("aggregations") or []) + (r.get("denominatorAggregations") or []):
    need("crossSeriesReducer" not in a and "groupByFields" not in a,
         "a cross-series reduce merges pools, and 'every host held' is a per-pool fact")
need(metric(d.get("filter")) == PFX + "ci_demand", "second condition is not ci_demand")
need(d.get("comparison") == "COMPARISON_LT" and float(d.get("thresholdValue", 0)) == 1.0,
     "demand condition must be ci_demand < 1")
for x in (r, d):
    need(secs(x["duration"]) >= phm > 0,
         "duration %s is below PIN_HOLD_MAX=%ss -- a legitimate hold would page" % (x["duration"], phm))
# muted: all three filters, denominator included
rm_ = held_m["conditions"][0]["conditionThreshold"]; dm = held_m["conditions"][1]["conditionThreshold"]
for name, f in (("numerator", rm_["filter"]), ("denominator", rm_["denominatorFilter"]), ("demand", dm["filter"])):
    need('metric.labels.pool!="pool-broken"' in f, "--muted-pool does not reach the heldpool %s" % name)
need(held_m["documentation"]["content"].startswith("MUTED POOLS: pool-broken."), "a muted heldpool does not say so")

# unverifiedkeep
k = keep["conditions"]; need(len(k) == 1, "unverifiedkeep has %d conditions, want 1" % len(k))
t = k[0]["conditionThreshold"]
m = metric(t["filter"])
need(m == "logging.googleapis.com/user/ci_unverified_host_keeps", "unverifiedkeep watches %s" % m)
need('resource.type="gce_instance"' in t["filter"], "a log metric on controller events lives on gce_instance")
need(secs(t["duration"]) >= phm > 0, "unverifiedkeep duration is below PIN_HOLD_MAX")
# The events are throttled to one per host per EVENT_HEARTBEAT; a sum window
# narrower than two of them has gaps inside a failure that never stopped.
hb = re.search(r"^EVENT_HEARTBEAT=(\d+)$", ctl, re.M)
need(hb is not None, "EVENT_HEARTBEAT not found in controller-startup.sh")
if hb:
    need(secs(t["aggregations"][0]["alignmentPeriod"]) >= 2 * int(hb.group(1)),
         "the sum window is narrower than two event heartbeats -- a steady failure would flap")
need(t["aggregations"][0]["perSeriesAligner"] == "ALIGN_SUM", "a log counter is summed, not averaged")
need(keep_m == keep, "--muted-pool changed a policy it cannot mute")
need("MUTED POOLS" not in keep_m["documentation"]["content"], "unverifiedkeep claims a mute it cannot apply")
need(m.rsplit("/", 1)[1] in re.findall(r"^ensure_log_metric (\S+)", src, re.M),
     "no ensure_log_metric call creates the metric unverifiedkeep watches")

print("\n".join(fails))
sys.exit(1 if fails else 0)
PY
shape_rc=$?
if [ "$shape_rc" = 0 ]; then ok; else
  while IFS= read -r line; do [ -n "$line" ] && bad "$line"; done <"$tmp/shape.out"; fi

# --- 3. the log filter matches what the controller sends ---------------------
# Lifted from the ensure_log_metric call itself: the filter is its third line.
lf="$(sed -n '/^ensure_log_metric ci_unverified_host_keeps/,/^$/p' "$SRC" | sed -n "3s/^ *'\(.*\)'$/\1/p")"
[ -n "$lf" ] || bad "the ci_unverified_host_keeps log filter could not be read"
case "$lf" in *'logName:"logs/ci-controller"'*) ok ;; *) bad "the log filter does not select the ci-controller log: $lf" ;; esac
case "$lf" in *'severity=WARNING'*) ok ;; *) bad "the log filter would count INFO pin-hold vetoes, which are affinity working: $lf" ;; esac
for ev in beacon-read-failed pin-hold-veto; do
  case "$lf" in *"jsonPayload.event=\"$ev\""*) ok ;; *) bad "the log filter does not count $ev" ;; esac
  # ...and the controller still sends it, through throttled_event, at WARNING or
  # via pin_hold_class (whose WARNING classes were read above).
  if grep -qE "throttled_event .*(WARNING|\"\\\$sev\") $ev " "$CTL"; then ok; else
    bad "controller-startup.sh no longer sends $ev through throttled_event"; fi
done
case " $warn_classes " in *" read-failed "*) ok ;; *) bad "a failed pin-hold read is no longer WARNING: $warn_classes" ;; esac
# The filter names no project: it runs in every pool project.
case "$lf" in *projects/*) bad "the log filter names a project" ;; *) ok ;; esac

# --- 4. idempotence against the REAL body ------------------------------------
# A body with a denominator is new to policy_unchanged(). Echo it the way the
# server does -- add name, records, enabled and a name per condition -- and it
# must read unchanged, or every hourly apply PATCHes it and re-notifies.
for body in held keep; do
  python3 - "$tmp/$body.json" "$tmp/$body.listing.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
live = dict(p, name="projects/p/alertPolicies/7", enabled=True,
            creationRecord={"mutateTime": "2026-09-29T00:00:00Z"},
            mutationRecord={"mutateTime": "2026-09-29T01:00:00Z"})
live["conditions"] = [dict(c, name="projects/p/alertPolicies/7/conditions/%d" % i)
                      for i, c in enumerate(p["conditions"])]
json.dump({"alertPolicies": [live]}, open(sys.argv[2], "w", encoding="utf-8"))
PY
  if policy_unchanged projects/p/alertPolicies/7 "$tmp/$body.json" "$tmp/$body.listing.json"; then ok; else
    bad "the $body policy reads as changed against its own echo -- it would PATCH and re-notify every apply"; fi
done
# ...and an edit to the half that is new must still land.
mutate() { # <python expression on q> <description>
  python3 - "$tmp/held.json" "$tmp/held.mut.json" "$1" <<'PY'
import json, sys
q = json.load(open(sys.argv[1], encoding="utf-8")); exec(sys.argv[3])
json.dump(q, open(sys.argv[2], "w", encoding="utf-8"))
PY
  if policy_unchanged projects/p/alertPolicies/7 "$tmp/held.mut.json" "$tmp/held.listing.json"; then
    bad "$2 reads as unchanged -- the edit would never deploy"; else ok; fi
}
mutate "q['conditions'][0]['conditionThreshold']['denominatorFilter'] = 'metric.type=\"x\"'" "a denominator filter edit"
mutate "q['conditions'][0]['conditionThreshold']['denominatorAggregations'][0]['perSeriesAligner'] = 'ALIGN_MAX'" "a denominator aligner edit"
mutate "q['conditions'][0]['conditionThreshold'].pop('denominatorFilter')" "dropping the denominator"

# --- 5. both descriptors the ratio needs are declared ------------------------
for m in ci_hosts_running ci_demand ci_pin_holds_honoured; do
  if grep -q "^ensure_descriptor $m " "$SRC"; then ok; else
    bad "no ensure_descriptor for $m -- a project whose controller has not ticked defers heldpool"; fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
