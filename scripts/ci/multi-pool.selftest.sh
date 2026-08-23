#!/usr/bin/env bash
# Self-test for the machinery that lets ONE controller serve MANY pools.
#
# pool-table.selftest.sh proves the table parses. This file proves the three
# things that only go wrong once a second pool exists, and that no existing gate
# could have caught — because until now there was never a second pool for the
# first one to contaminate:
#
#   1. pool_select() RESETS the MIG facts. Every one of them is read by code
#      that has no idea a previous pool was selected a moment ago, and the worst
#      of them is MIG_TEMPLATE: left over from pool A, it makes every host in
#      pool B read `stale`, which cordons an entire pool on one failed describe.
#   2. The marker sweep is SCOPED to the pool's own hosts. STATE_DIR is shared
#      by every pool on the controller, and the sweep deletes the markers of
#      hosts that are not in `HOSTS` — which, unscoped, is every other pool's
#      entire fleet. Deleting a `regtoken-` marker forgets that a live GitHub
#      registration token is sitting in another pool's instance metadata.
#   3. The recycle budget is COUNTED per pool. Unscoped, one pool's rollout
#      spends every other pool's budget and the fleet stops upgrading.
#
# …and the fourth thing, which is not contamination but compatibility: a
# controller rendered before the table existed must still come up. Its old
# one-key-per-field metadata is synthesised into a one-row table, and the
# synthesis is executed here against a stub `md` rather than trusted.
#
# Tenancy-agnostic — no customer literals.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTRL="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"
TABLE="$ROOT/modules/ci-runner-host-pool/scripts/pool-table.sh"

pass=0
fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
    pass=$((pass + 1))
  else
    echo "FAIL $1: expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

# --- 1. pool_select resets what the previous pool left behind -----------------
#
# The function is extracted and run for real, with only the globals it is
# entitled to read. A field added to pool_select and not to its reset half fails
# here rather than in the fleet.
# shellcheck disable=SC2034  # every P_*/D_* below is read by the eval'd
# pool_select, which no static reader of this file can see.
select_out=$(
  set -uo pipefail
  # shellcheck disable=SC1090
  eval "$(sed -n '/^pool_select() {/,/^}/p' "$CTRL")"

  declare -A P_MIG P_REGION P_SLOTS P_MIN P_MAX P_GRACE P_REGGRACE P_TICKS
  declare -A P_RECYCLE P_HOST_OS P_MINT P_ROLE P_BEACON P_PIN P_LABELS
  # D_EXPIRED is declared even though pool_select reads it as `${...:-0}`: an
  # associative subscript on a variable bash has never seen is parsed as
  # ARITHMETIC, so `${D_EXPIRED[$POOL]:-0}` with POOL=a dies under `set -u` as
  # "a: unbound variable" — the default never gets a chance to apply.
  # Q_JPC is here for the same reason D_EXPIRED is, and it is the sweep's
  # measurement rather than a configured column: pool_select copies it out per
  # pool so the merge-queue ceiling is derived from THIS pool's run shape and
  # not from whichever pool was selected last.
  declare -A P_LABELS_JSON P_MATCH_CSV D_TOTAL D_QUEUED D_WAIT D_RUNNING D_EXPIRED Q_JPC

  # Two pools that agree on NOTHING, so a field carried over from the first is
  # visible in the second rather than coincidentally equal.
  for p in a b; do
    P_REGION[$p]="region-$p"
    P_SLOTS[$p]=1
    P_MIN[$p]=0
    P_MAX[$p]=1
    P_GRACE[$p]=900
    P_REGGRACE[$p]=600
    P_TICKS[$p]=3
    P_RECYCLE[$p]=0
    P_ROLE[$p]=ci
    P_BEACON[$p]=30
    P_PIN[$p]=900
    P_LABELS[$p]="self-hosted,$p"
    P_LABELS_JSON[$p]="[\"self-hosted\",\"$p\"]"
    # The MATCH set, which is what every routing question is asked of. It
    # differs from P_LABELS on purpose: a pool_select that carried the
    # configured list into RUNNER_MATCH_LABELS would pass a test in which the
    # two were equal, and then read every real workflow as another pool's.
    P_MATCH_CSV[$p]="$p,self-hosted,x64"
  done
  P_MIG[a]=mig-a
  P_MIG[b]=mig-b
  P_HOST_OS[a]=linux
  P_HOST_OS[b]=windows
  P_MINT[a]=false
  P_MINT[b]=true
  D_TOTAL[a]=7
  D_TOTAL[b]=2
  D_QUEUED[a]=5
  D_QUEUED[b]=1
  D_WAIT[a]=61
  D_WAIT[b]=12
  D_RUNNING[a]=300
  D_RUNNING[b]=9
  Q_JPC[a]=11
  Q_JPC[b]=3

  pool_select a
  # Exactly what collect_mig() would have written for pool a, and exactly what
  # must not survive into pool b.
  MIG_BASE="ci-lin"
  MIG_TARGET=4
  MIG_TEMPLATE="ci-lin-tpl-v5"

  pool_select b
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$POOL" "$MIG" "$CONTROLLER_HOST_OS" "$MINT_REG" "$RUNNER_MATCH_LABELS" \
    "$MIG_BASE" "$MIG_TARGET" "$MIG_TEMPLATE" \
    "$DEMAND_TOTAL" "$DEMAND_QUEUED" "$RUNNING_MAX" "$POOL_JOBS_PER_CHECK"
)
check "pool_select: the second pool's own fields are all in place" \
  "b|mig-b|windows|true|b,self-hosted,x64" \
  "$(printf '%s' "$select_out" | cut -d'|' -f1-5)"

# The one that cordons a pool. MIG_TEMPLATE from pool a, compared against pool
# b's hosts, makes every one of them `stale` — and the recycle rule then cordons
# the whole pool, at once, on the strength of a describe that never ran.
check "pool_select: the previous pool's MIG facts are cleared, not inherited" \
  "||0|" \
  "|$(printf '%s' "$select_out" | cut -d'|' -f6-8)"

check "pool_select: demand comes from the sweep's per-pool result" \
  "2|1|9" \
  "$(printf '%s' "$select_out" | cut -d'|' -f9-11)"

# The merge-queue ceiling is derived from jobs-per-check, and a value carried
# over from the previous pool would size THIS pool from a run shape it has never
# had — 11 rather than 3 here, which on a queue pool is nearly four times the
# hosts. Same class of bug as the MIG facts above, on a number nothing else
# would contradict.
check "pool_select: jobs-per-check is this pool's, not the previous pool's" \
  "3" \
  "$(printf '%s' "$select_out" | cut -d'|' -f12)"

# --- 2. the marker sweep cannot reach another pool's markers ------------------
#
# The guard is a glob against the MIG's baseInstanceName, so it is tested as
# one: the sweep's own `case` pattern, run over a directory holding two pools'
# markers with only one pool's hosts alive.
sweep_out=$(
  set -uo pipefail
  STATE_DIR=$(mktemp -d)
  # Pool A is the one being ticked. Its host lin-1 is alive; lin-2 is gone.
  : >"$STATE_DIR/cordon-ci-lin-1"
  : >"$STATE_DIR/cordon-ci-lin-2"
  # Pool B is not being ticked at all. Its markers are none of A's business —
  # and regtoken-ci-win-1 records a live registration token in an instance's
  # metadata, so deleting it strands a credential nothing will ever revoke.
  : >"$STATE_DIR/cordon-ci-win-1"
  : >"$STATE_DIR/regtoken-ci-win-1"

  MIG_BASE="ci-lin"
  live_hosts="ci-lin-1"
  for f in "$STATE_DIR"/cordon-* "$STATE_DIR"/regtoken-*; do
    [ -n "$live_hosts" ] || break
    [ -n "$MIG_BASE" ] || break
    [ -e "$f" ] || continue
    mname=$(basename "$f")
    mname=${mname#cordon-}
    mname=${mname#regtoken-}
    case "$mname" in "$MIG_BASE"-*) ;; *) continue ;; esac
    case $'\n'"$live_hosts"$'\n' in
      *$'\n'"$mname"$'\n'*) ;;
      *) rm -f "$f" ;;
    esac
  done
  (cd "$STATE_DIR" && printf '%s\n' * | sort | paste -sd, -)
  rm -rf "$STATE_DIR"
)
check "sweep: a dead host's marker in the ticked pool is still collected" \
  "no" \
  "$(case ",$sweep_out," in *,cordon-ci-lin-2,*) echo yes ;; *) echo no ;; esac)"
check "sweep: another pool's markers survive a tick they had no part in" \
  "cordon-ci-lin-1,cordon-ci-win-1,regtoken-ci-win-1" "$sweep_out"

# And the fail-safe: with no base name — a describe that failed — the sweep must
# do NOTHING. Guessing is not available to it, and a marker deleted in error is
# a token nobody knows about.
sweep_blind=$(
  set -uo pipefail
  STATE_DIR=$(mktemp -d)
  : >"$STATE_DIR/cordon-ci-lin-2"
  MIG_BASE=""
  live_hosts="ci-lin-1"
  for f in "$STATE_DIR"/cordon-*; do
    [ -n "$live_hosts" ] || break
    [ -n "$MIG_BASE" ] || break
    [ -e "$f" ] || continue
    rm -f "$f"
  done
  (cd "$STATE_DIR" && printf '%s\n' * | sort | paste -sd, -)
  rm -rf "$STATE_DIR"
)
check "sweep: a controller that cannot name its MIG sweeps nothing" \
  "cordon-ci-lin-2" "$sweep_blind"

# The source is checked too, because the two loops above are a copy: a scoping
# guard that is dropped from the controller must not leave this file green.
# shellcheck disable=SC2016
grep -qF 'case "$mname" in "$MIG_BASE"-*) ;; *) continue ;; esac' "$CTRL" &&
  r=yes || r=no
check "sweep: the controller really carries the scoping guard" yes "$r"

# --- 3. the recycle budget is this pool's, not the controller's ---------------
#
# `find -name 'cordon-*'` counts every pool's cordons. With four pools rolling
# out at once and a budget of one, three of them never start.
grep -qF "find \"\$STATE_DIR\" -maxdepth 1 -name \"cordon-\$MIG_BASE-*\"" "$CTRL" &&
  r=yes || r=no
check "recycle: the cordon count is scoped to this pool's MIG" yes "$r"

# No base name means the budget reads FULLY SPENT. A pool that cannot count its
# own cordons must not start new ones — the failure mode of the opposite choice
# is recycling the whole pool while blind.
# shellcheck disable=SC2016
r=$(sed -n '/recycling=$(find/,/^  fi$/p' "$CTRL" | grep -c 'recycling="\$RECYCLE_MAX_UNAVAILABLE"')
check "recycle: an unreadable MIG spends the budget rather than ignoring it" 1 "$r"

# --- 4. the pre-table controller still boots ----------------------------------
#
# The legacy synthesis, executed — not described. A controller whose metadata
# predates `ci-pools` must produce one valid row, or it comes up serving nothing
# and its ONLY_UP autoscaler holds its last size forever.
legacy=$(
  set -uo pipefail
  # shellcheck disable=SC1090
  . "$TABLE"
  # The metadata an existing Linux controller actually carries. `ci-host-os`,
  # `ci-beacon-interval` and `ci-pin-orphan-grace-seconds` are absent on the
  # oldest of them, which is the case that matters: an absent attribute reads as
  # the empty string, and in jq an empty string is TRUTHY, so `// 900` would
  # hand the row a "" it then rejects as non-numeric.
  # shellcheck disable=SC2317  # every arm is reached via the eval'd code.
  md() {
    case "$1" in
      *ci-pools) echo "" ;;
      *ci-pool) echo "telnet" ;;
      *ci-mig-name) echo "ci-runner-host-telnet" ;;
      *ci-region) echo "region-1" ;;
      *ci-slots) echo "3" ;;
      *ci-min-hosts) echo "0" ;;
      *ci-max-hosts) echo "6" ;;
      *ci-drain-grace-seconds) echo "900" ;;
      *ci-register-grace-seconds) echo "600" ;;
      *ci-orphan-confirm-ticks) echo "3" ;;
      *ci-recycle-max-unavailable) echo "1" ;;
      *ci-runner-labels) echo "self-hosted,linux,gcp" ;;
      *) echo "" ;;
    esac
  }
  # shellcheck disable=SC2016
  eval "$(sed -n '/POOLS_JSON=$(jq -n /,/runner_labels: /p' "$CTRL")"
  printf '%s' "$POOLS_JSON" | pool_table_parse 2>/dev/null | tr '\t' '|'
)
check "legacy: one row, and every absent key took its default" \
  "telnet|ci-runner-host-telnet|region-1|3|0|6|900|600|3|1|linux|false|ci|30|900|self-hosted,linux,gcp" \
  "$legacy"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
