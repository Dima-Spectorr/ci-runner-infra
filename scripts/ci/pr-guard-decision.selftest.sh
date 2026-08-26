#!/usr/bin/env bash
# Self-test for the pull-request guard's rules.
#
# These do not merge anything, so the blast radius is smaller than the lane's —
# but the failure mode is worse than it looks. A guard that goes red for advice
# gets ignored, and then it is not a guard; a guard that goes red because a read
# failed gets re-run without being read, which is the same thing with extra
# steps. So the weighting here is on the arms that FAIL: every one of them is
# tested against the case one step away that must stay green.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/pr-guard-decision.sh"

PASS=0
FAIL=0

expect() { # <want> <desc> <fn> <args...>
  local want="$1" desc="$2" fn="$3"
  shift 3
  local got
  got=$("$fn" "$@")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# --- freshness ---------------------------------------------------------------
expect 'ok:current' "level with the base" guard_freshness 0 0 false
expect 'ok:current' "level with the base, enforcing" guard_freshness 0 0 true
expect 'warn:behind-1' "one commit behind a zero tolerance is behind — >, not >=" \
  guard_freshness 1 0 false
expect 'fail:behind-1' "the same, where the caller enforces" guard_freshness 1 0 true

# The tolerance boundary, from both sides. A `<` here instead of `<=` would make
# `max-behind: 5` mean four, which nobody would notice until they were counting.
expect 'ok:current' "exactly at the tolerance is within it" guard_freshness 5 5 false
expect 'fail:behind-6' "one past the tolerance is past it" guard_freshness 6 5 true

# UNKNOWN NEVER FAILS. This is the arm that keeps the check credible: a deleted
# branch, a gone fork head, a rate-limited read. None is the author's doing.
expect 'unknown:unreadable' "an empty comparison, enforcing" guard_freshness '' 0 true
expect 'unknown:unreadable' "an error body where a number was expected, enforcing" \
  guard_freshness 'Not Found' 0 true
expect 'unknown:unreadable' "a negative number is not a distance behind" \
  guard_freshness -1 0 true

# A nonsense tolerance falls back to strict rather than to permissive. An
# operator typo must not silently switch the gate off.
expect 'warn:behind-2' "an unreadable tolerance reads as zero, not as infinite" \
  guard_freshness 2 'lots' false

# `enforce` is matched exactly, because every other spelling arriving from a
# workflow input — `True`, `1`, `yes` — is an operator who THINKS they enforced.
# Failing open there is the safe direction; the comment still says it.
expect 'warn:behind-1' "only the exact string true enforces" guard_freshness 1 0 True
expect 'warn:behind-1' "1 is not true" guard_freshness 1 0 1

# --- overlap -----------------------------------------------------------------
expect 'ok:distinct' "no shared paths" guard_overlap 0 true
expect 'warn:overlap-1' "one shared path, advisory" guard_overlap 1 false
expect 'fail:overlap-1' "one shared path, enforcing" guard_overlap 1 true
expect 'unknown:unreadable' "an unreadable count never fails" guard_overlap '' true

# --- the intersection itself -------------------------------------------------
shared() { guard_shared "$1" "$2" | tr '\n' ' ' | sed 's/ *$//'; }

expect 'src/auth.ts' "the one path in both" shared \
  "$(printf 'src/auth.ts\nREADME.md')" "$(printf 'src/auth.ts\npackage.json')"
expect '' "same directory, different files, is not an overlap" shared \
  'src/auth.ts' 'src/session.ts'
expect '' "a prefix is not a path — src/auth.ts must not match src/auth.test.ts" shared \
  'src/auth.ts' 'src/auth.test.ts'
expect '' "nothing on one side" shared 'src/auth.ts' ''
expect '' "nothing on either side" shared '' ''
# The empty path is a member of every list. Without the blank filter this pair
# reports as overlapping and so does every other pair in the repository.
expect '' "blank lines do not make two disjoint pull requests overlap" shared \
  "$(printf 'a.ts\n\n')" "$(printf 'b.ts\n\n')"
expect 'a.ts b.ts' "two shared paths come back sorted" shared \
  "$(printf 'b.ts\nz.ts\na.ts')" "$(printf 'a.ts\nb.ts\nq.ts')"
expect 'a.ts' "a path repeated on one side is reported once" shared \
  "$(printf 'a.ts\na.ts')" 'a.ts'
# `comm` compares bytewise and a locale that collates differently would silently
# drop matches. `LC_ALL=C` in the function is what this asserts.
expect 'A.ts' "case is significant, and the sort agrees with the comparison" shared \
  "$(printf 'A.ts\nb.ts')" "$(printf 'A.ts\nB.ts')"

# --- the run's exit status ---------------------------------------------------
status() { guard_exit "$@" && printf 'green' || printf 'red'; }
expect 'green' "nothing to say" status ok:current ok:distinct
expect 'green' "advice alone is not a failure" status warn:behind-3 warn:overlap-2
expect 'green' "an unreadable answer is not a failure" status unknown:unreadable
expect 'red' "one enforced failure fails the run" status ok:current fail:overlap-1
expect 'red' "the failure is found wherever it sits" status fail:behind-9 ok:distinct
# `ok:` must not be matched by a prefix rule that also matches nothing else --
# a verdict this does not recognise is green, deliberately, because an
# unrecognised verdict is a bug in the caller and not a reason to block a merge.
expect 'green' "an unrecognised verdict does not fail the run" status weird:thing

printf 'pr-guard decision: %d checks pass' "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf ', %d FAILED\n' "$FAIL"
  exit 1
fi
printf '\n'
