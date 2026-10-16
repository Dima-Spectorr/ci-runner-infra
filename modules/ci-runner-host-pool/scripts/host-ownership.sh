#!/usr/bin/env bash
# ci-runner-host-pool — which host, and which runner agent, belongs to THIS
# pool. One rule, as PURE functions, shared by every place the controller asks.
#
# WHY THIS FILE EXISTS
#
# The controller used to answer "is this mine?" with a PREFIX glob on the host
# MIG's base instance name, `"$base"-*`, in four places: the orphan reaper,
# pinned-job rule 5, the state-marker sweep and recycle count, and the boot
# list. A base that is another base extended by a hyphen is inside that glob,
# so a controller whose base is `ci` also claimed `ci-win-ab12` and its agent
# `ci-win-ab12-s1`: it found no instance of its own behind them and, once the
# confirm ticks passed, deregistered a live slot of the other pool and
# cancelled the runs pinned to it (#1487). The module refused one such pairing
# at plan time; nothing refused two differently named pools in one repository.
#
# THE NAME GRAMMAR, read from the code that writes each name:
#
#   instance  `<base>-<4>`   a managed instance group names every instance it
#                            creates `<baseInstanceName>-<four random [a-z0-9]>`
#                            (main.tf, the host MIG). A recreate keeps the name.
#   agent     `<instance>-s<N>`              windows-host-startup.ps1
#             `<instance>-s<N>-<hex nonce>`  host-startup.sh mint_jit (run-once
#                                            JIT slots, a fresh nonce per mint)
#   pin       `host-<instance>`              the affinity label, stripped by
#                                            the caller before it gets here
#
# Nothing else is ours. In particular the pool's own controller,
# `<pool>-controller-<4>`, is not: it registers no agent, and its suffix is not
# four characters. An instance given a hand-chosen name outside the group is not
# recognised either — nothing in this repository creates one, and an
# unrecognised name is only ever LEFT ALONE (kept, ignored, not swept), never
# acted on.
#
# The suffix is matched against an explicit character list rather than a range
# such as `[a-z0-9]`: a bracket range is collation-dependent in some locales,
# and this test decides which machines' agents a controller may deregister.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# pool_owns_host <base_instance_name> <instance_name>
#
# Exit 0 exactly when <instance_name> is `<base>-<4 lowercase letters/digits>`,
# i.e. a name this pool's MIG could have created. An empty base owns nothing.
pool_owns_host() {
  local base="${1:-}" host="${2:-}" suffix
  [ -n "$base" ] || return 1
  case "$host" in
    "$base"-*) ;;
    *) return 1 ;;
  esac
  suffix=${host#"$base"-}
  [ "${#suffix}" -eq 4 ] || return 1
  case "$suffix" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
  esac
  return 0
}

# pool_slot_host <base_instance_name> <agent_name>
#
# Prints the instance an agent belongs to and exits 0 when <agent_name> is
# `<instance>-s<N>` or `<instance>-s<N>-<hex>` with pool_owns_host true of the
# instance. Exits 1, printing nothing, for anything else.
pool_slot_host() {
  local base="${1:-}" name="${2:-}" host rest slot nonce
  [ -n "$base" ] || return 1
  case "$name" in
    "$base"-*) ;;
    *) return 1 ;;
  esac
  # `<base>-` plus the four-character suffix: the instance is a fixed length
  # once the base is known, so it is cut, not searched for.
  host=${name:0:$((${#base} + 5))}
  pool_owns_host "$base" "$host" || return 1
  rest=${name:${#host}}
  case "$rest" in
    -s*) rest=${rest#-s} ;;
    *) return 1 ;;
  esac
  slot=${rest%%-*}
  case "$slot" in
    "" | *[!0123456789]*) return 1 ;;
  esac
  if [ "$slot" != "$rest" ]; then
    nonce=${rest#*-}
    case "$nonce" in
      "" | *[!0123456789abcdef]*) return 1 ;;
    esac
  fi
  printf '%s\n' "$host"
  return 0
}

# pool_marker_count <state_dir> <base_instance_name> <kind>...
#
# How many `<kind>-<instance>` files directly in <state_dir> name an instance
# this pool owns, summed over every <kind> given (e.g. `cordon reserve`). The
# state directory is shared by every pool on a controller, so a count that is
# not bounded by ownership spends one pool's recycle budget on another's hosts.
# Prints the number; an empty base prints 0 — the CALLER decides what an
# unreadable base means for its budget.
pool_marker_count() {
  local dir="${1:-}" base="${2:-}" kind f m n=0
  if [ "$#" -lt 2 ] || [ -z "$dir" ] || [ -z "$base" ]; then
    echo 0
    return 0
  fi
  shift 2
  for kind in "$@"; do
    for f in "$dir/$kind-"*; do
      [ -f "$f" ] || continue
      m=${f##*/}
      pool_owns_host "$base" "${m#"$kind"-}" && n=$((n + 1))
    done
  done
  echo "$n"
}
