#!/usr/bin/env bash
# Self-test for the "is this alert policy already what we intend?" comparison in
# ensure-alert-policies.sh.
#
# WHY THIS TEST EXISTS.
#
# Updating a Cloud Monitoring alert policy CLOSES its open incidents; the next
# evaluation opens new ones and notifies again. ensure-alert-policies.sh used to
# PATCH all fourteen policies unconditionally, and it runs from the apply
# trigger, which is scheduled HOURLY. So every condition that was currently true
# re-sent a mail every hour, around the clock, describing nothing that had
# changed. That was the whole of the "huge amount of alerts and no CI problem"
# this fleet reported on 2026-09-02: three true conditions fleet-wide, and all
# fourteen policies carrying a mutationRecord from the apply that had just run.
#
# The fix skips the PATCH when the live policy already says what we intend, so
# THIS comparison is now the only thing standing between an operator's threshold
# edit and a change that silently never lands. It is tested from both sides:
#
#   every mutation below MUST be seen (rc=1)   -- or a real edit never deploys;
#   every untouched policy MUST be skipped     -- or the mail flood comes back.
#
# The second half is not decoration. The server omits thresholdValue when it is
# zero, and ten of the fourteen policies are `> 0` conditions; a comparison that
# failed to fold absent into 0.0 would call MOST of them permanently changed,
# pass every mutation case here, and fix nothing at all.

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SRC="$HERE/ensure-alert-policies.sh"

PASS=0
FAIL=0

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }

# The function under test, lifted from the shipping script rather than copied
# into this file: a copy would let the two drift, and the drift would be silent
# in exactly the direction that costs mail.
FN="$(sed -n '/^policy_unchanged() {$/,/^}$/p' "$SRC")"
if [ -z "$FN" ]; then
  echo "FAIL: policy_unchanged() not found in ensure-alert-policies.sh"
  exit 1
fi
eval "$FN"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# A fixture shaped like what the API actually returns, including the two things
# the server does that a hand-written fixture would miss: it names each
# condition, and it OMITS thresholdValue on a `> 0` condition.
cat > "$tmp/listing.json" <<'JSON'
{"alertPolicies":[
 {"name":"projects/p/alertPolicies/1",
  "displayName":"CI runners / capacity on paper",
  "combiner":"OR",
  "enabled":true,
  "creationRecord":{"mutateTime":"2026-08-01T00:00:00Z"},
  "mutationRecord":{"mutateTime":"2026-09-02T15:39:33Z"},
  "notificationChannels":["projects/p/notificationChannels/2","projects/p/notificationChannels/1"],
  "documentation":{"content":"slots are missing","mimeType":"text/markdown"},
  "conditions":[
   {"name":"projects/p/alertPolicies/1/conditions/a",
    "displayName":"slots missing",
    "conditionThreshold":{
      "filter":"metric.type=\"custom.googleapis.com/ci_slots_missing\"",
      "comparison":"COMPARISON_GT",
      "duration":"600s",
      "aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_MAX"}]}},
   {"name":"projects/p/alertPolicies/1/conditions/b",
    "displayName":"host idle",
    "conditionThreshold":{
      "filter":"metric.type=\"custom.googleapis.com/ci_host_idle_seconds_max\"",
      "comparison":"COMPARISON_GT",
      "thresholdValue":3600,
      "duration":"600s",
      "aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_MAX"}]}}]}
]}
JSON

# The intended body, derived from the listing so the two agree by construction:
# no name, no records, no `enabled`, no condition names. Note what it does NOT
# strip -- the `> 0` condition has no thresholdValue here because the LISTING
# omits it. The script itself emits `"thresholdValue": 0.0` for that condition;
# reconciling absent against 0.0 is exactly what policy_unchanged() is for, and
# the "absent threshold equals 0" case below is the assertion that proves it.
python3 - "$tmp/listing.json" "$tmp/base.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))["alertPolicies"][0]
q = {k: v for k, v in p.items()
     if k not in ("name", "creationRecord", "mutationRecord", "enabled")}
q["conditions"] = [{k: v for k, v in c.items() if k != "name"} for c in q["conditions"]]
json.dump(q, open(sys.argv[2], "w", encoding="utf-8"))
PY

# check <expected rc> <description> [python mutation applied to `q`]
check() {
  local want="$1" desc="$2" mut="${3:-}"
  # Build the fixture, and treat a failure to build it as a failed case. A
  # mutation that raises leaves json.dump unreached, so without this the file
  # from the PREVIOUS case is what gets compared -- and since that file is
  # usually base-identical, a broken `check 0` would pass for the one reason the
  # test exists to rule out. Deleting it first turns a silent skip into a loud
  # one either way.
  rm -f "$tmp/p.json"
  if ! python3 - "$tmp/base.json" "$tmp/p.json" "$mut" <<'PY'
import json, sys
q = json.load(open(sys.argv[1], encoding="utf-8"))
if sys.argv[3]:
    exec(sys.argv[3])
json.dump(q, open(sys.argv[2], "w", encoding="utf-8"))
PY
  then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (fixture generation failed — the mutation did not apply)\n' "$desc"
    return
  fi
  policy_unchanged "projects/p/alertPolicies/1" "$tmp/p.json" "$tmp/listing.json"
  local got=$?
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (rc=%s, want %s)\n' "$desc" "$got" "$want"
  fi
}

# --- the half that protects the operator: a real edit must still be written ---
check 1 "threshold raised"       "q['conditions'][1]['conditionThreshold']['thresholdValue'] = 7200"
check 1 "threshold 0 -> 1"       "q['conditions'][0]['conditionThreshold']['thresholdValue'] = 1"
check 1 "duration changed"       "q['conditions'][0]['conditionThreshold']['duration'] = '900s'"
check 1 "filter changed"         "q['conditions'][0]['conditionThreshold']['filter'] = 'metric.type=\"other\"'"
check 1 "comparison changed"     "q['conditions'][0]['conditionThreshold']['comparison'] = 'COMPARISON_LT'"
check 1 "aligner changed"        "q['conditions'][0]['conditionThreshold']['aggregations'][0]['perSeriesAligner'] = 'ALIGN_MIN'"
check 1 "documentation edited"   "q['documentation']['content'] = 'rewritten'"
check 1 "displayName changed"    "q['displayName'] = 'CI runners / renamed'"
check 1 "combiner changed"       "q['combiner'] = 'AND'"
check 1 "condition removed"      "q['conditions'].pop()"
check 1 "condition added"        "q['conditions'].append(json.loads(json.dumps(q['conditions'][0])))"
# Order is compared as written: an operator who reorders conditions means it.
check 1 "conditions reordered"   "q['conditions'].reverse()"
check 1 "channel added"          "q['notificationChannels'].append('projects/p/notificationChannels/9')"
check 1 "channel removed"        "q['notificationChannels'].pop()"

# --- the half that stops the mail: nothing to say means nothing is written ---
check 0 "untouched policy is unchanged"
# Channel ORDER is not meaningful to the API and the listing returns it in its
# own order; treating a reordering as a change would re-notify hourly forever,
# which is the bug this whole file exists for.
check 0 "channel order is not a change"  "q['notificationChannels'].reverse()"
# The server writes thresholdValue 0.0 as absent. If this reads as a change, ten
# of the fourteen live policies re-notify on every apply and nothing is fixed.
check 0 "absent thresholdValue equals 0" "q['conditions'][0]['conditionThreshold']['thresholdValue'] = 0"

# --- and it FAILS OPEN: when it cannot tell, the PATCH goes ahead -------------
# A wrong "changed" costs one redundant notification -- the behaviour being
# replaced. A wrong "unchanged" is a threshold edit that silently never lands.
# Those are not symmetric, so every unknown must err toward writing.
cp "$tmp/base.json" "$tmp/p.json"
if policy_unchanged "projects/p/alertPolicies/404" "$tmp/p.json" "$tmp/listing.json"; then
  FAIL=$((FAIL + 1)); echo "FAIL: a policy id the listing does not carry must read as changed"
else
  PASS=$((PASS + 1))
fi
# A listing that carries the id twice is the duplicate-policy case the upsert
# loop already warns about. Which of the two the API evaluates is not ours to
# decide, so "they look the same" is not an answer -- it must write.
python3 - "$tmp/listing.json" "$tmp/dupes.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["alertPolicies"].append(json.loads(json.dumps(d["alertPolicies"][0])))
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PY
cp "$tmp/base.json" "$tmp/p.json"
if policy_unchanged "projects/p/alertPolicies/1" "$tmp/p.json" "$tmp/dupes.json"; then
  FAIL=$((FAIL + 1)); echo "FAIL: an id the listing carries twice must read as changed"
else
  PASS=$((PASS + 1))
fi
printf '%s' '{not json' > "$tmp/bad.json"
if policy_unchanged "projects/p/alertPolicies/1" "$tmp/bad.json" "$tmp/listing.json"; then
  FAIL=$((FAIL + 1)); echo "FAIL: an unparseable intended body must read as changed"
else
  PASS=$((PASS + 1))
fi

# --- and the caller must actually use it -------------------------------------
# The comparison is worthless if the loop never consults it, or consults it
# after the dry-run branch -- a dry run that promises an update the real run
# would skip is a report of work that does not happen.
# shellcheck disable=SC2016  # matching shell source text literally, on purpose.
for needle in \
  'cp "$tmp/api.out" "$tmp/existing.json"' \
  'if [ -n "$id" ] && policy_unchanged "$id" "$tmp/p.json" "$tmp/existing.json"; then'
do
  if grep -qF "$needle" "$SRC"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: `%s` no longer appears in ensure-alert-policies.sh\n' "$needle"
  fi
done

# The check must precede THIS loop's dry-run branch, so the branch is anchored
# on the text only this one contains. An earlier version of this assertion
# looked for the first `if [ "$DRY" = "1" ]` after the check and was satisfied
# by one of the four SIBLING dry-run branches further down the file -- it stayed
# green with the check moved to the wrong side of the branch, which is the whole
# thing it exists to catch.
# shellcheck disable=SC2016  # ditto: these are source-text needles.
CHECK_LINE="$(grep -n 'policy_unchanged "$id"' "$SRC" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016
DRY_LINE="$(grep -nF 'echo update || echo create' "$SRC" | head -1 | cut -d: -f1)"
if [ -n "$CHECK_LINE" ] && [ -n "$DRY_LINE" ] && [ "$CHECK_LINE" -lt "$DRY_LINE" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: the unchanged check must sit before the dry-run branch of the upsert loop"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
