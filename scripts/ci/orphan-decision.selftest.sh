#!/usr/bin/env bash
# Self-test for the controller's orphan-registration rule.
#
# This rule deletes GitHub runner registrations. Getting it wrong in the
# permissive direction removes a LIVE slot from the pool (or kills a running
# job) and is only visible hours later as "the pool lost capacity", so every
# guard below is asserted here rather than on the fleet.
#
# Every case is a real situation this fleet has produced, not a synthetic input.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/host-ownership.sh"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/orphan-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(orphan_decision "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

BASE=ci-runner-host-dataretrival

# args: name status busy base live_hosts_csv misses required_misses

# --- what the reaper exists to clean up ---------------------------------------
# 2026-08-13: the fleet was recycled onto a new golden image with
# `delete-instances`, which bypasses drain_host() and its deregister loop. 24
# registrations for six long-gone hosts were left behind in this repo alone.
expect reap "offline slot whose instance is gone is reaped once confirmed" \
  "$BASE-0ff6-s1" offline 0 "$BASE" "$BASE-pnph" 2 2
expect reap "reaped even when the pool is now genuinely empty" \
  "$BASE-52wl-s3" offline 0 "$BASE" "" 3 2

# --- the guards that make it safe ---------------------------------------------
# A failed `gcloud list-instances` returns an EMPTY host list, which reads
# exactly like a pool at zero. One bad tick must not deregister a live fleet.
expect keep "a single hostless tick is not enough" \
  "$BASE-0ff6-s1" offline 0 "$BASE" "" 0 2
expect keep "still not enough one tick later" \
  "$BASE-0ff6-s1" offline 0 "$BASE" "" 1 2

expect keep "an agent whose instance is alive is never touched" \
  "$BASE-pnph-s2" offline 0 "$BASE" "$BASE-pnph,$BASE-abcd" 9 2
expect keep "online agents are left alone" \
  "$BASE-0ff6-s1" online 0 "$BASE" "" 9 2
expect keep "a busy agent is never deregistered, whatever the MIG says" \
  "$BASE-0ff6-s1" offline 1 "$BASE" "" 9 2

# --- bounding the reaper to THIS pool -----------------------------------------
# A repo's runner list also carries the windows pool and whatever a retired
# one-VM-per-job pool left behind (SOAP-To-REST still had ci-runner-soap-to-rest-*
# entries). Those are someone else's to reclaim.
expect keep "another pool's agent in the same repo is not ours" \
  ci-runner-integrateit-windows-4bc1 offline 0 "$BASE" "" 9 2
expect keep "the retired pool's naming does not match the MIG base" \
  ci-runner-soap-to-rest-890v offline 0 ci-runner-host-soap "" 9 2
expect keep "an empty baseInstanceName reaps NOTHING rather than everything" \
  "$BASE-0ff6-s1" offline 0 "" "" 9 2

# The controller itself registers no agent, but a name without the "-s<N>" slot
# suffix has no host to join back to and must not be guessed at.
expect keep "a non-slot name is not resolvable to an instance" \
  "$BASE-controller" offline 0 "$BASE" "" 9 2

# A host name that merely PREFIXES a live one must not read as alive.
expect reap "prefix collision does not count as a live host" \
  "$BASE-abcd-s1" offline 0 "$BASE" "$BASE-abcde,$BASE-abc" 2 2
# A host suffix that is not the MIG's four characters is not an instance this
# pool could have created, so its agent is left alone rather than guessed at.
expect keep "a two-character host suffix is not this pool's instance" \
  "$BASE-ab-s1" offline 0 "$BASE" "$BASE-abcd" 2 2

# --- the name grammar the bound now reads (#1487) -----------------------------
# Linux JIT slots carry a per-mint hex nonce after the slot number.
expect reap "a Linux run-once slot with its nonce is resolved to its instance" \
  "$BASE-0ff6-s1-deadbeef" offline 0 "$BASE" "$BASE-pnph" 2 2
expect keep "and that slot is alive while its instance is" \
  "$BASE-0ff6-s1-deadbeef" offline 0 "$BASE" "$BASE-0ff6" 9 2
expect keep "a nonce that is not hex is not a slot name" \
  "$BASE-0ff6-s1-zz" offline 0 "$BASE" "" 9 2
expect keep "a slot number that is not digits is not a slot name" \
  "$BASE-0ff6-sx" offline 0 "$BASE" "" 9 2
expect keep "an owned instance name with no slot is not a slot name" \
  "$BASE-0ff6" offline 0 "$BASE" "" 9 2
expect keep "the pool's own controller instance is never this pool's agent" \
  "$BASE-controller-ab12" offline 0 "$BASE" "" 9 2
expect keep "an upper-case suffix is not a name GCE gives an instance" \
  "$BASE-0FF6-s1" offline 0 "$BASE" "" 9 2

# --- two pools, one label set, two controllers (#1486) ------------------------
# A pool being moved to another project exists twice for a while: the same
# runner labels, the same pool name, a controller each. GitHub's runner list is
# per repository, so each controller sees BOTH pools' agents, and each one's
# live-host list holds only its own. With one base name between them every
# agent of the other pool is "offline with no instance behind it" the moment it
# blinks, and is deregistered. `instance_base_name` gives one side a different
# base; the base is then the only thing telling the two apart, and these are
# the two controllers' views of the same four agents.
OTHER=ci-relocated-pool

expect keep "a foreign base with the same labels is the other controller's to reap" \
  "$OTHER-0ff6-s1" offline 0 "$BASE" "" 9 2
expect keep "and it stays untouched however long it has been hostless here" \
  "$OTHER-0ff6-s4" offline 0 "$BASE" "$BASE-pnph" 99 2
expect reap "while this pool's own orphan is still reaped exactly as before" \
  "$BASE-0ff6-s1" offline 0 "$BASE" "$BASE-pnph" 9 2
expect keep "seen from the other controller, this pool's agents are the foreign ones" \
  "$BASE-0ff6-s1" offline 0 "$OTHER" "" 9 2
expect reap "and that controller reaps its own" \
  "$OTHER-0ff6-s1" offline 0 "$OTHER" "$OTHER-pnph" 9 2

# A BASE THAT EXTENDS OURS WITH A HYPHEN (#1487). The bound used to be the prefix
# `<base>-`, so `<base>-b-0ff6-s1` was inside it: this controller claimed the
# other pool's agent, found no instance of its own behind it, and reaped a slot
# that was serving jobs somewhere else. The bound is now the exact grammar
# `<base>-<4>-s<N>[-<hex>]`, so the other pool's agent is not ours — whichever
# of the two controllers is asking — and the plan-time precondition that kept
# such a pair apart is gone.
expect keep "a base that extends ours with a hyphen is the other pool's, not ours" \
  "$BASE-b-0ff6-s1" offline 0 "$BASE" "$BASE-pnph" 9 2
expect keep "nor its Linux run-once slot, nonce and all" \
  "$BASE-b-0ff6-s1-deadbeef" offline 0 "$BASE" "$BASE-pnph" 9 2
expect keep "a four-character extension is not ours either" \
  "$BASE-b123-0ff6-s1" offline 0 "$BASE" "" 9 2
expect reap "while the longer base still reaps its own orphans" \
  "$BASE-b-0ff6-s1" offline 0 "$BASE-b" "$BASE-b-pnph" 9 2
expect keep "and does not claim the shorter base's agents" \
  "$BASE-b0ff-s1" offline 0 "$BASE-b" "" 9 2

# --- the helper itself ----------------------------------------------------------
# pool_owns_host / pool_slot_host / pool_marker_count are what every other
# ownership site in the controller calls (the pinned-run rule, the marker sweep,
# the recycle count, the boot list), so their contract is asserted directly.
ok() {
  local desc="$1"
  shift
  if "$@"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  cmd: %s\n' "$desc" "$*"
  fi
}
no() {
  local desc="$1"
  shift
  if "$@"; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  cmd: %s (unexpectedly true)\n' "$desc" "$*"
  else PASS=$((PASS + 1)); fi
}
eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

ok "an instance the MIG could have named is owned" pool_owns_host ci-a ci-a-0ff6
no "a longer base's instance is not" pool_owns_host ci-a ci-a-b-0ff6
no "a five-character suffix is not" pool_owns_host ci-a ci-a-0ff6x
no "a three-character suffix is not" pool_owns_host ci-a ci-a-0ff
no "an upper-case suffix is not" pool_owns_host ci-a ci-a-0FF6
no "a suffix holding a hyphen is not" pool_owns_host ci-a ci-a-0f-6
no "the controller is not" pool_owns_host ci-a ci-a-controller-ab12
no "the base itself is not" pool_owns_host ci-a ci-a
no "an empty base owns nothing" pool_owns_host "" -0ff6
no "a glob character in the base is literal" pool_owns_host 'ci-*' ci-a-0ff6
no "a different base is not" pool_owns_host ci-b ci-a-0ff6

eq "a Windows slot resolves to its instance" ci-a-0ff6 "$(pool_slot_host ci-a ci-a-0ff6-s2)"
eq "a Linux JIT slot resolves to its instance" ci-a-0ff6 "$(pool_slot_host ci-a ci-a-0ff6-s12-0a1b2c3d)"
no "a longer base's slot does not resolve" pool_slot_host ci-a ci-a-b-0ff6-s1
no "a slot with nothing after -s does not" pool_slot_host ci-a ci-a-0ff6-s
no "a slot with an empty nonce does not" pool_slot_host ci-a ci-a-0ff6-s1-
no "a slot with two nonces does not" pool_slot_host ci-a ci-a-0ff6-s1-ab-cd
no "an instance name alone is not a slot" pool_slot_host ci-a ci-a-0ff6
eq "a refused slot prints nothing" "" "$(pool_slot_host ci-a ci-a-b-0ff6-s1)"

MDIR=$(mktemp -d)
trap 'rm -rf "$MDIR"' EXIT
: >"$MDIR/cordon-ci-a-0ff6"
: >"$MDIR/reserve-ci-a-pnph"
: >"$MDIR/cordon-ci-a-b-0ff6"   # the longer base's host: not ours
: >"$MDIR/reserve-ci-a-b-pnph"  # ditto
: >"$MDIR/cordon-ci-b-0ff6"     # an unrelated pool
: >"$MDIR/drain-ci-a-abcd"      # a kind that was not asked for
mkdir "$MDIR/cordon-ci-a-zzzz"  # not a file
eq "the recycle count is this pool's own cordons and reserves" 2 \
  "$(pool_marker_count "$MDIR" ci-a cordon reserve)"
eq "seen from the longer base, only its own two" 2 \
  "$(pool_marker_count "$MDIR" ci-a-b cordon reserve)"
eq "one kind counts only that kind" 1 "$(pool_marker_count "$MDIR" ci-a cordon)"
eq "an empty base counts nothing" 0 "$(pool_marker_count "$MDIR" "" cordon reserve)"
eq "a missing directory counts nothing" 0 "$(pool_marker_count "$MDIR/nope" ci-a cordon reserve)"

printf 'orphan-decision selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
