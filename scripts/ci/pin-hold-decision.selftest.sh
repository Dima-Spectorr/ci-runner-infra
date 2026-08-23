#!/usr/bin/env bash

# shellcheck disable=SC2016
#   The single quotes in the wiring half are load-bearing. Every pattern there
#   is an extended regular expression matched against the controller's TEXT, so
#   `$host`, `$rc` and `$BEACON_NS` are literal dollar signs the file has to
#   contain -- not variables this suite holds. Expanded, each pattern would
#   collapse toward the empty string and match anything, which is precisely the
#   failure the wiring assertions exist to catch: they would all pass against a
#   controller with the veto ripped out.
#   File scope rather than per call site because a directive on a comment binds
#   to the next command only, and there are ten of them.
# Self-test for the controller's PIN HOLD rule, and for the wiring that applies
# it.
#
# The rule decides whether a host the controller has already resolved to remove
# is removed. Every case below is a way that decision can be wrong, and the two
# directions are not symmetric:
#
#   * a wrong `free:` deletes a host a pull request has named by label, taking
#     its shared database with it and wedging every remaining job of that run;
#   * a wrong `hold:` keeps one machine warm until the hold lapses.
#
# So the degraded states — a failed read, a malformed value, a corrupt cache —
# all belong on the `hold:` side, and each has a case here. The MONOTONIC cases
# are the security ones: a guest attribute is writable by any process on the VM,
# so a co-tenant job on another slot can publish a valid-but-expired hold over a
# live one, and the rule must refuse to move a deadline backwards.
#
# The second half asserts the wiring, because a proven rule nothing calls is
# worth nothing, and the specific failure this guards is subtle: the tick
# `continue`s on a recycle verdict, so a veto wired only into the drain path is
# bypassed entirely by a stale-template cordon.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../modules/ci-runner-host-pool/scripts"
# shellcheck source=/dev/null
source "$MOD/pin-hold-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(pin_hold_decision "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: read_status present raw cached_run cached_expiry now max_hold
#
# A fixed clock, so every expiry below reads as an offset rather than as
# whatever the suite happened to run at.
NOW=1000000
MAX=7200
LIVE=$((NOW + 600))
GONE=$((NOW - 600))

# --- the two affirmative cases ------------------------------------------------
# These are the only shapes that let a removal proceed. Everything else keeps.
expect free "no hold published and none remembered is the free case" \
  0 0 "" "" 0 "$NOW" "$MAX"
expect free "a hold that has lapsed frees the host" \
  0 1 "77 $GONE" 77 "$GONE" "$NOW" "$MAX"

# --- a live hold vetoes -------------------------------------------------------
expect hold "a live published hold vetoes the removal" \
  0 1 "77 $LIVE" "" 0 "$NOW" "$MAX"
expect "hold:run=77 expiry=$LIVE" "the verdict carries the pair the caller must remember" \
  0 1 "77 $LIVE" "" 0 "$NOW" "$MAX"
# The boundary. One second past the deadline is not a hold; the deadline itself
# is still in the future by the only clock the controller has.
expect hold "the last second before the expiry still holds" \
  0 1 "77 $((NOW + 1))" "" 0 "$NOW" "$MAX"
expect free "the expiry second itself is free" \
  0 1 "77 $NOW" "" 0 "$NOW" "$MAX"

# --- MONOTONIC: a co-tenant can extend, never shorten -------------------------
# The attack this rule exists to refuse. Another pull request's job, on another
# slot of the same host, publishes a syntactically perfect hold that has already
# expired — over the top of a live one. Answered from the cache, the host stays.
expect "hold:run=88 expiry=$LIVE" "an expired publish cannot shorten a remembered live hold" \
  0 1 "77 $GONE" 88 "$LIVE" "$NOW" "$MAX"
expect "hold:run=88 expiry=$LIVE" "a shorter live publish cannot shorten a remembered hold" \
  0 1 "77 $((NOW + 60))" 88 "$LIVE" "$NOW" "$MAX"
# Erasing the attribute outright is the same attack by another route, and the
# helper's own release writes exactly this. The remembered hold still governs;
# it simply stops being renewed, and lapses on its own.
expect "hold:run=88 expiry=$LIVE" "an empty publish cannot shorten a remembered hold" \
  0 1 "" 88 "$LIVE" "$NOW" "$MAX"
expect "hold:run=88 expiry=$LIVE" "a key that vanished cannot shorten a remembered hold" \
  0 0 "" 88 "$LIVE" "$NOW" "$MAX"
# Extending is allowed, and is the bounded cost the design accepts.
expect "hold:run=77 expiry=$((NOW + 900))" "a longer publish does move the deadline forward" \
  0 1 "77 $((NOW + 900))" 88 "$LIVE" "$NOW" "$MAX"

# --- the clamp ----------------------------------------------------------------
# Job code can write an expiry ten years out as easily as a correct one. Without
# the clamp that host is undeletable forever — a billing, invisible resident of
# a pool that reports the right number of hosts.
expect "hold:run=77 expiry=$((NOW + MAX))" "an absurd expiry is clamped to the ceiling" \
  0 1 "77 99999999999" "" 0 "$NOW" "$MAX"
expect "hold:run=77 expiry=$((NOW + MAX))" "the clamp binds the cache too, by binding what reaches it" \
  0 1 "77 $((NOW + MAX + 1))" "" 0 "$NOW" "$MAX"
expect "hold:run=77 expiry=$((NOW + MAX))" "a hold exactly at the ceiling is not clamped away" \
  0 1 "77 $((NOW + MAX))" "" 0 "$NOW" "$MAX"

# --- degraded: every one of these keeps ---------------------------------------
# 1. The mechanism failed. Guest attributes are rate limited per instance, so
#    this is what a BUSY fleet produces — reading it as "no hold" would delete
#    pinned hosts precisely when the most runs are in flight.
expect hold "a failed read is not evidence that there is no hold" \
  1 0 "" "" 0 "$NOW" "$MAX"
expect "hold:run=88 expiry=$LIVE" "a failed read reports the remembered pair" \
  1 0 "" 88 "$LIVE" "$NOW" "$MAX"
expect hold "a failed read keeps even when the cache says the hold has lapsed" \
  1 1 "77 $LIVE" 88 "$GONE" "$NOW" "$MAX"

# 2. A broken publisher. Each of these is a value that parses as something, and
#    none of them is a hold — but a publisher that writes garbage tells us
#    nothing about the host, and nothing never authorises a deletion.
for bad in "77" "77 abc" "abc 123" "77 $LIVE extra" "  " "-1 $LIVE" "77 -$LIVE" "77 1e9"; do
  expect hold "a malformed hold keeps the host: '$bad'" \
    0 1 "$bad" "" 0 "$NOW" "$MAX"
done
# A herestring reads ONE line, so a value whose tail is hidden behind a newline
# must not be able to present its head as a well-formed hold.
expect hold "a hold carrying a newline is malformed, not its first line" \
  0 1 "$(printf '77 %s\nanything' "$LIVE")" "" 0 "$NOW" "$MAX"
# And a broken publish must not become the remembered answer.
expect "hold:run= expiry=0" "a malformed hold with nothing cached leaves no pair to remember" \
  0 1 "77 abc" "" 0 "$NOW" "$MAX"
expect "hold:run=88 expiry=$LIVE" "a malformed hold does not disturb what is remembered" \
  0 1 "77 abc" 88 "$LIVE" "$NOW" "$MAX"

# 3. A corrupt cache. The file can be truncated by a reboot mid-write. It must
#    neither veto forever nor abort the tick on a numeric comparison — under
#    `set -e`, a controller that dies mid-tick publishes none of its series and
#    the pool goes dark.
expect free "a corrupt cached expiry is no cache at all" \
  0 0 "" 88 "not-a-number" "$NOW" "$MAX"
expect free "a corrupt cached run is no cache at all" \
  0 0 "" "../etc" "$LIVE" "$NOW" "$MAX"
expect free "a half-written cache line is no cache at all" \
  0 0 "" "" "" "$NOW" "$MAX"
expect "hold:run=77 expiry=$LIVE" "a corrupt cache still yields to a good publish" \
  0 1 "77 $LIVE" 88 "junk" "$NOW" "$MAX"

# 4. Defaults. A future caller that forgets an argument gets the safe verdict.
expect hold "no arguments at all is a hold" # (no args)

# --- the wiring ---------------------------------------------------------------
#
# A proven rule nothing calls is worth nothing. These are predicates over the
# controller's source, in the same spirit as host-startup.selftest.sh: they do
# not run the controller, they assert that the text which will run on the box
# still says what the rule assumes.
CTL="$MOD/controller-startup.sh"
ctl=$(cat "$CTL")

# Counting rather than `grep -q`: under `set -o pipefail` a quiet grep exits on
# its first match, the writer upstream takes EPIPE, and the pipeline reports 141
# -- so every assertion that MATCHED would read as a failure. The bug is silent
# in the other direction too, which is what makes it worth spelling out here.
wired() { # <description> <ere>
  local n
  n=$(printf '%s' "$ctl" | grep -cE -- "$2")
  if [ "${n:-0}" -ge 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  no line in controller-startup.sh matches: %s\n' "$1" "$2"
  fi
}

counted() { # <description> <ere> <n>
  local n
  n=$(printf '%s' "$ctl" | grep -cE -- "$2")
  if [ "${n:-0}" -eq "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected %s line(s) matching %s, found %s\n' "$1" "$3" "$2" "${n:-0}"
  fi
}

# BOTH removal paths. The tick asks recycle_decision() first and `continue`s on
# its verdict, so drain_decision() is never consulted for a host being recycled:
# a veto on the drain path alone is bypassed entirely by a stale-template
# cordon, and a cordoned host stops answering its own affinity label while the
# run pinned to it still has jobs to place. Two call sites, no fewer.
counted "the veto is applied on both removal paths" 'pin_hold_gate "\$host" "\$host_uri"' 2
wired "the recycle path is vetoed before it acts" '^ +cordon:\* \| retire:\*\)$'
wired "the drain path is vetoed before it acts" 'VETOED by pin hold'

# The veto is a veto: the rules stay pure functions of their arguments, and
# neither gains a hold argument. If a hold were passed IN, it would have to be
# read for every host on every tick — straight into the per-instance rate limit,
# on the busy pool, where hitting it presents as read-failed and read-failed
# keeps every host.
wired "recycle_decision keeps its signature" 'recycle_decision "\$status" "\$tpl" "\$busy" "\$HOST_REG"'
wired "drain_decision keeps its signature" 'drain_decision "\$status" "\$busy" "\$idle" "\$GRACE"'

# The namespace read, not the single key: `--query-path` naming a key that is
# not there exits NON-ZERO, which this rule reads as a failed read and answers
# by keeping. Every unheld host in the fleet would be undeletable.
wired "the gate reads the whole namespace" '\-\-query-path="\$BEACON_NS/"'
counted "nothing reads the hold key by path" '\-\-query-path="\$BEACON_NS/\$PIN_HOLD_KEY"' 0

# The cache is the monotonic store, and only a read that SUCCEEDED may write it.
wired "the cache lives beside the beacon's own markers" 'pinhold-\$host'
wired "only a successful read updates the cache" 'if \[ "\$rc" = "0" \]; then'
wired "the cache goes when the host does" 'STATE_DIR/pinhold-\$host"$'

# The ceiling is a contract with the host helper's own clamp, not an input. A
# controller ceiling BELOW the host's PIN_MAX_TTL would silently cut every hold
# short; above it, a value the helper refuses to write would still be honoured.
wired "the controller clamps holds" 'PIN_HOLD_MAX=7200'
host_max=$(grep -E '^PIN_MAX_TTL=[0-9]+$' "$MOD/host-startup.sh" | head -1 | cut -d= -f2)
if [ "${host_max:-}" = "7200" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL: the host helper clamps --ttl at %s and the controller honours 7200 — one of them is cutting holds short\n' \
    "${host_max:-unset}"
fi

# The veto has to be visible. Every other symptom of losing it is a success:
# hosts drain, the pool shrinks, the graphs look healthy, right up until a
# pull request's second job finds the host it named is gone.
wired "held removals are counted" 'PIN_HELD=\$\(\(PIN_HELD \+ 1\)\)'
wired "the counter resets per pool" '^ +PIN_HELD=0$'
wired "the count is published" 'queue_series "ci_pin_holds_honoured"'

if [ "$FAIL" -gt 0 ]; then
  echo "pin-hold-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "pin-hold-decision: $PASS cases pass"
