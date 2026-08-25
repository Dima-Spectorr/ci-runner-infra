#!/usr/bin/env bash
# Self-test for the branch reaper's per-branch rule.
#
# This rule DELETES. Unlike the merge lane, whose wrong answer writes something
# you can revert, a wrong answer here destroys commits that may exist nowhere
# else — so the weighting is inverted: nearly every case below is a case that
# must NOT delete, and each one differs from the single deleting case by exactly
# one input.
#
# The workflow that calls it runs on a schedule from the default branch, so the
# pull request that changes it cannot exercise it. These cases are the test.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/branch-reaper-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(reaper_verdict "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: is_default protected excluded base_of_open_pr has_open_pr has_merged_pr
#       tip_matches age_days min_age_days

# --- the one verdict that destroys anything -----------------------------------
expect "delete:merged-and-aged" "merged, untouched since, and past the grace period" \
  0 0 0 0 0 1 1 20 14
expect "delete:merged-and-aged" "exactly at the threshold deletes — the rule is strictly less than" \
  0 0 0 0 0 1 1 14 14
expect "delete:merged-and-aged" "a zero threshold means as soon as it is merged" \
  0 0 0 0 0 1 1 0 0

# --- one off each input, where a wrong comparison would delete ----------------
# Every case here is the deleting case above with exactly ONE input changed.
expect "keep:too-recent" "one day short of the threshold, and >= would delete it" \
  0 0 0 0 0 1 1 13 14
expect "keep:default-branch" "the default branch is never a candidate" \
  1 0 0 0 0 1 1 20 14
expect "keep:protected" "a protected branch is never a candidate" \
  0 1 0 0 0 1 1 20 14
expect "keep:excluded" "the operator's keep-list wins over every other fact" \
  0 0 1 0 0 1 1 20 14
expect "keep:base-of-open-pull-request" "deleting a base closes the pull request targeting it" \
  0 0 0 1 0 1 1 20 14
expect "keep:pull-request-open" "a branch may carry a merged pull request AND a newer open one" \
  0 0 0 0 1 1 1 20 14
expect "keep:not-merged" "no merged pull request means the work exists nowhere else" \
  0 0 0 0 0 0 1 20 14
expect "keep:moved-since-merge" "commits pushed after the merge were never merged" \
  0 0 0 0 0 1 0 20 14

# --- unknowns are keeps, never guesses ----------------------------------------
# The whole file is written so that no arm deletes on a fact the caller failed
# to establish. An empty string is what a failed API read looks like here.
expect "keep:tip-unknown" "an unreadable tip is not an unchanged tip" \
  0 0 0 0 0 1 "" 20 14
expect "keep:age-unknown" "an unreadable merge date is not an old one" \
  0 0 0 0 0 1 1 "" 14
expect "keep:age-unknown" "a non-numeric age is not an old one" \
  0 0 0 0 0 1 1 "twenty" 14
expect "keep:unparseable-threshold" "a mistyped threshold must not read as zero days" \
  0 0 0 0 0 1 1 20 "fourteen"
expect "keep:unparseable-threshold" "an empty threshold must not read as zero days" \
  0 0 0 0 0 1 1 20 ""
expect "keep:unparseable-threshold" "a negative threshold is not a threshold" \
  0 0 0 0 0 1 1 20 "-1"

# --- inputs the caller may leave off entirely ---------------------------------
# A caller that passes nothing must get a keep, not a crash and not a delete.
expect "keep:unparseable-threshold" "no arguments at all" ""

# --- the safety ordering ------------------------------------------------------
# These assert WHICH reason is reported when several apply, because the reason
# is what an operator reads when they ask why a branch is still there. A
# protected branch that also happens to be unreadable must say "protected".
expect "keep:default-branch" "default wins over protected" \
  1 1 1 1 1 0 "" "" 14
expect "keep:protected" "protected wins over the keep-list" \
  0 1 1 1 1 0 "" "" 14
expect "keep:base-of-open-pull-request" "being a base is reported before being a head" \
  0 0 0 1 1 1 1 20 14
expect "keep:pull-request-open" "an open pull request is reported before the merged one" \
  0 0 0 0 1 1 1 20 14
expect "keep:not-merged" "unmerged is reported before anything about the tip" \
  0 0 0 0 0 0 "" "" 14

# --- non-1 truthiness ---------------------------------------------------------
# Only the exact string `1` is true. Anything else — "true", "yes", empty — must
# not be read as a flag being set, in either direction.
expect "delete:merged-and-aged" "a flag set to 'true' rather than 1 is not set" \
  "true" "true" "true" "true" "true" 1 1 20 14
expect "keep:not-merged" "has_merged_pr must be exactly 1 to count as merged" \
  0 0 0 0 0 "true" 1 20 14
expect "keep:moved-since-merge" "tip_matches must be exactly 1 to count as unchanged" \
  0 0 0 0 0 1 "true" 20 14

if [ "$FAIL" -gt 0 ]; then
  echo "branch-reaper-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "branch-reaper-decision: $PASS cases pass"
