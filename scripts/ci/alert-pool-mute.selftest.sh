#!/usr/bin/env bash
# Self-test for --muted-pool in ensure-alert-policies.sh.
#
# WHY THIS TEST EXISTS.
#
# A mute is the one change to this script that fails SILENTLY in the expensive
# direction. Every other defect here shows up as mail: a bad threshold pages, a
# bad filter pages, an unconditional PATCH pages hourly. A mute that is too wide
# produces no mail at all, and a project with no mail looks exactly like a
# project with nothing wrong -- which is the failure this whole script was
# written to prevent. So the assertions run in both directions:
#
#   the named pool MUST be excluded from every pool-scoped condition
#     -- or the mute does not work and the operator turns the policy off by hand;
#   every OTHER pool MUST still be matched, and an unmuted run MUST be
#   byte-identical to the pre-mute behaviour
#     -- or muting one broken pool quietly blinds the healthy ones beside it.
#
# The last one is the reason the flag exists instead of a Cloud Monitoring
# snooze: a snooze is scoped to the POLICY, so on this fleet -- where several
# pools share a project -- it silences the pools that are fine along with the
# one that is not.
#
# The functions and the mute block are LIFTED from the shipping script rather
# than copied into this file, for the same reason as the idempotence test: a
# copy drifts, and the drift is invisible in the direction that costs coverage.

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SRC="$HERE/ensure-alert-policies.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
want() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1 (want '$2', got '$3')"; fi
}

# ---------------------------------------------------------------------------
# Lift the mute block. It is top-level code, not a function, so it is bounded by
# its own first line and the `fi` that closes it.
# ---------------------------------------------------------------------------
MUTE_BLOCK="$(sed -n '/^MUTE_FILTER=""$/,/^fi$/p' "$SRC")"
[ -n "$MUTE_BLOCK" ] || { echo "FAIL: the MUTE_FILTER block was not found in ensure-alert-policies.sh"; exit 1; }

PJ="$(sed -n '/^policy_json() {/,/^}$/p' "$SRC")"
[ -n "$PJ" ] || { echo "FAIL: policy_json() was not found in ensure-alert-policies.sh"; exit 1; }

# Every key the generation loop iterates, read from the loop itself so a new
# policy added to the script is covered here without anyone remembering to.
KEYS="$(sed -n 's/^for key in \(.*\); do$/\1/p' "$SRC")"
[ -n "$KEYS" ] || { echo "FAIL: the policy key list was not found in ensure-alert-policies.sh"; exit 1; }

# render [<muted-pool>...] -> every policy body, concatenated, on stdout
# Runs in a subshell so one render's variables cannot leak into the next. Pools
# arrive as separate arguments, matching the shipping script's array, so a name
# containing a space stays ONE name here too -- a test that pre-splits its own
# fixtures cannot see the splitting bug.
# Everything assigned below is read inside the eval'd blocks, which the linter
# sees only as an opaque string -- hence the whole-function SC2034. The values
# are irrelevant to this test; only their presence is, because `set -u` in the
# shipping script means an undefined one aborts the render rather than emitting
# a wrong policy.
# shellcheck disable=SC2034
render() (
  set -uo pipefail
  MUTED_POOLS=("$@")
  channel="projects/p/notificationChannels/1"
  POLL=20; WATCHDOG_THRESHOLD=300; SLOW_TICK=240; QUEUE_WAIT=900
  IDLE_THRESHOLD=1200; DRAIN_GRACE=900; REGISTER_GRACE=600; CACHE_STALE_HOURS=48
  eval "$MUTE_BLOCK" || exit 1
  eval "$PJ"
  for key in $KEYS; do policy_json "$key"; done
)

plain="$(render)"
[ -n "$plain" ] || { echo "FAIL: rendering with no mute produced nothing"; exit 1; }
muted="$(render pool-broken)"
[ -n "$muted" ] || { echo "FAIL: rendering with a mute produced nothing"; exit 1; }

# ---------------------------------------------------------------------------
# 1. No mute must change nothing at all.
#
# This is the assertion that lets the flag be added to a fleet of seven projects
# where six of them pass it nothing. If an unmuted render differs by so much as
# a space, every one of those projects gets a PATCH on the next hourly apply --
# and a PATCH closes open incidents, which re-notifies. That is the exact mail
# flood the idempotence test was written for, re-introduced from a new angle.
# ---------------------------------------------------------------------------
if [ "$plain" = "$(render)" ]; then ok; else bad "two unmuted renders disagree"; fi
case "$plain" in
  *'MUTED POOLS'*) bad "an unmuted policy carries the mute note" ;;
  *'metric.labels.pool!='*) bad "an unmuted policy carries a pool exclusion" ;;
  *) ok ;;
esac

# ---------------------------------------------------------------------------
# 2. The exclusion reaches EVERY pool-scoped condition, not just the two that
#    happened to be paging when the flag was written.
#
# Counted, not merely present: the whole point is that the operator does not
# have to audit fourteen policies by hand to find the one that still mails.
# ---------------------------------------------------------------------------
scoped_plain=$(printf '%s\n' "$plain" | grep -c 'resource\.type=\\"generic_node\\"')
excluded=$(printf '%s\n' "$muted" | grep -c 'resource\.type=\\"generic_node\\" AND metric\.labels\.pool!=\\"pool-broken\\"')
want "every generic_node condition carries the exclusion" "$scoped_plain" "$excluded"

leftover=$(printf '%s\n' "$muted" | grep -c 'resource\.type=\\"generic_node\\"[^ ]' || true)
want "no generic_node condition was left unmuted" "0" "$leftover"

# The log-based egress policy keys on gce_instance and carries no pool label, so
# there is nothing to exclude on. Asserted rather than assumed: a future edit
# that gives it a pool label should make this line fail and be reconsidered,
# not quietly ship a policy that pages for a pool the operator muted.
gce_muted=$(printf '%s\n' "$muted" | grep -c 'gce_instance\\" AND metric\.labels\.pool!=' || true)
want "the log-based egress policy is not muted" "0" "$gce_muted"

# ---------------------------------------------------------------------------
# 3. A mute is never silent.
#
# One note per policy, carrying the pool name. An exclusion the console shows
# only inside a filter expression is one an operator reads past; the note is
# what makes "this is quiet because we made it quiet" legible at a glance.
# ---------------------------------------------------------------------------
docs=$(printf '%s\n' "$plain" | grep -c '"documentation": { "mimeType": "text/markdown", "content":')
notes=$(printf '%s\n' "$muted" | grep -c 'MUTED POOLS: pool-broken\.')
want "every policy that was muted says so" "$((docs - 1))" "$notes"

# The one policy that must NOT carry the note is the one that could not be
# muted. Caught in production on the first apply: the note went onto all
# fourteen, so the egress policy read "this policy no longer pages for them"
# while it went on paging for exactly those pools. A mute that lies about its
# own scope is worse than no mute, because that sentence is what an operator
# would rely on to decide the silence was deliberate.
egress_note=$(printf '%s\n' "$muted" | grep -c 'MUTED POOLS.*runner firewall refused' || true)
want "the policy that could not be muted does not claim to be" "0" "$egress_note"

# ---------------------------------------------------------------------------
# 4. Muting one pool must not mute another.
#
# The reason this flag exists at all. A muted pool almost always shares its
# project with pools that are fine and busy; if this assertion fails, the flag
# has become the policy-scoped snooze it was written to avoid.
# ---------------------------------------------------------------------------
case "$muted" in
  *'metric.labels.pool!=\"pool-healthy\"'*) bad "muting the Windows pool also excluded the Linux pool" ;;
  *) ok ;;
esac

two="$(render pool-broken pool-other)"
a=$(printf '%s\n' "$two" | grep -c 'pool!=\\"pool-broken\\" AND metric\.labels\.pool!=\\"pool-other\\"')
want "two mutes chain onto the same filter" "$scoped_plain" "$a"
case "$two" in
  *'MUTED POOLS: pool-broken, pool-other.'*) ok ;;
  *) bad "the note does not list both muted pools" ;;
esac

# ---------------------------------------------------------------------------
# 5. The rendered bodies must still be JSON.
#
# A pool name is pasted into a JSON string that is pasted into a Monitoring
# filter expression -- two levels of quoting, which is exactly the shape that
# looks right and parses wrong. Parsing every body is cheaper than reading them.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  for pools in '' 'pool-broken' 'pool-broken pool-other'; do
    # Unquoted on purpose: these fixtures ARE space-separated lists, and render
    # now takes one pool per argument.
    # shellcheck disable=SC2086
    if render $pools | python3 -c '
import json, sys
raw = sys.stdin.read()
dec, i, n = json.JSONDecoder(), 0, 0
while i < len(raw):
    while i < len(raw) and raw[i].isspace(): i += 1
    if i >= len(raw): break
    obj, i = dec.raw_decode(raw, i)
    n += 1
    for c in obj.get("conditions", []):
        t = c.get("conditionThreshold") or c.get("conditionAbsent") or {}
        if "filter" not in t: raise SystemExit("condition without a filter")
sys.exit(0 if n else "no policies parsed")
'; then ok; else bad "the rendered policies are not valid JSON (muted: '${pools:-none}')"; fi
  done
else
  echo "SKIP: python3 not available, JSON validity not checked"
fi

# ---------------------------------------------------------------------------
# 6. A pool name that could break out of the filter must be REFUSED, not pasted.
#
# The values arrive from Terraform, which is not a trust boundary in the usual
# sense -- but this string ends up inside a shell command inside a Cloud Build
# step, and "it comes from our own config" is how every one of those gets its
# first injection. Refusing is also the honest failure: a name that needs a
# quote is not a pool name.
# ---------------------------------------------------------------------------
# MUTED_POOLS is read inside the eval'd block, same blind spot as render().
# shellcheck disable=SC2034
refuses() { # <pool value>
  ( set -uo pipefail
    MUTED_POOLS=("$1")
    eval "$MUTE_BLOCK" ) >/dev/null 2>&1
  [ "$?" = "2" ]
}
# 'a b' and '' are the two that a space-joined accumulator lets through, and both
# fail OPEN: one silently mutes a pool nobody named, the other writes a note
# claiming a mute that did not happen. They are listed first because they are the
# cases the character class alone does not catch.
# The single quotes below are the fixture: `$(id)` must reach the script as
# eight literal characters. Expanding it here would test a name nobody types.
# shellcheck disable=SC2016
for evil in 'a b' '' ' ' 'a"' 'a\b' 'a"OR"1' 'a b/c' 'pool;rm -rf /' '$(id)'; do
  if refuses "$evil"; then ok; else bad "a pool name that cannot be safely quoted was accepted: $evil"; fi
done
for good in pool-broken pool-b.q pool_1 pool.a; do
  if refuses "$good"; then bad "a legitimate pool name was refused: $good"; else ok; fi
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
