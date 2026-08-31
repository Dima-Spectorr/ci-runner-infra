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

# --- which reviewers have seen this head -------------------------------------
# The bug these exist for: Copilot reviews the first push and then stops, so the
# lane asks about a head nobody was asked about, finds nothing, and stamps
# `UNREVIEWED` — the annotation that is supposed to mean a reviewer is DOWN.
HEAD='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
OLD='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
COP='copilot-pull-request-reviewer'

expect "$COP	answered" "a review of this exact head is an answer" \
  guard_rereview "$HEAD" "$COP" "$COP	$HEAD" ''
expect "$COP	stale" "a review of an earlier commit and no request for this one" \
  guard_rereview "$HEAD" "$COP" "$COP	$OLD" ''
expect "$COP	absent" "never reviewed here — not asked, on purpose" \
  guard_rereview "$HEAD" "$COP" '' ''
# A REQUEST IN FLIGHT IS NOT A STALE ONE. `requestReviews` REPLACES the
# outstanding request, so re-asking here restarts the review; a pull request
# pushed twice in a minute would cancel its own review forever.
expect "$COP	pending" "an outstanding request outranks the earlier review" \
  guard_rereview "$HEAD" "$COP" "$COP	$OLD" "$COP"
# An answer for the head still wins over a pending request for something else:
# the question is whether THIS head was reviewed, not whether anything is open.
expect "$COP	answered" "an answer for this head outranks an outstanding request" \
  guard_rereview "$HEAD" "$COP" "$COP	$HEAD" "$COP"

# The `[bot]` suffix. `review-bots` is written with it, GraphQL reports the
# login without it, and a mismatch here reports every reviewer `absent` — which
# re-requests nothing and looks, in the log, exactly like working correctly.
expect "$COP	answered" "the configured login may carry a [bot] suffix" \
  guard_rereview "$HEAD" "${COP}[bot]" "$COP	$HEAD" ''
expect "$COP	pending" "so may the pending one" \
  guard_rereview "$HEAD" "$COP" "$COP	$OLD" "${COP}[bot]"
# And so may the REVIEW's own author. GitHub returns a bot login suffixed in
# some responses and bare in others; stripping only the configured side would
# read a review that exists as no review at all, which is the same wrong answer
# in the opposite direction — `stale` for a head already reviewed.
expect "$COP	answered" "and so may the login on the review itself" \
  guard_rereview "$HEAD" "$COP" "${COP}[bot]	$HEAD" ''
expect "$COP	stale" "which must not hide an earlier review either" \
  guard_rereview "$HEAD" "${COP}[bot]" "${COP}[bot]	$OLD" ''

# ANOTHER REVIEWER'S REVIEW IS NOT THIS ONE'S. Matching the sha without the
# login would mark every configured reviewer answered the moment any one of
# them spoke, which is the whole gate silently disarmed.
expect "$COP	stale" "a different login's review of this head is not an answer" \
  guard_rereview "$HEAD" "$COP" "$(printf 'someone-else\t%s\n%s\t%s' "$HEAD" "$COP" "$OLD")" ''
expect "$COP	absent" "nor does it make an unseen reviewer stale" \
  guard_rereview "$HEAD" "$COP" "someone-else	$HEAD" ''

# FULL OIDS ONLY. An abbreviated match is a prefix match, and a prefix match
# against the wrong commit reports a head as reviewed that nobody has read.
expect "$COP	stale" "an abbreviation of the head does not count as the head" \
  guard_rereview "$HEAD" "$COP" "$COP	${HEAD:0:7}" ''

expect "$(printf '%s\tanswered\nsecond-reviewer\tstale' "$COP")" \
  "each configured reviewer is judged on its own" \
  guard_rereview "$HEAD" "$(printf '%s\nsecond-reviewer' "$COP")" \
  "$(printf '%s\t%s\nsecond-reviewer\t%s' "$COP" "$HEAD" "$OLD")" ''

# Nothing configured, nothing said. Both are silence, and silence is correct:
# a repository that does not arm the gate must not have pushes poked at it.
expect '' "no reviewers configured" guard_rereview "$HEAD" '' "$COP	$HEAD" ''
expect '' "blank lines in the configured list are not reviewers" \
  guard_rereview "$HEAD" "$(printf '\n   \n')" '' ''
# A HEAD THE CALLER COULD NOT READ IS NOT AN UNREVIEWED ONE. Printing `absent`
# here would re-request a review against nothing on every push.
expect '' "an unreadable head says nothing rather than 'nobody reviewed it'" \
  guard_rereview '' "$COP" "$COP	$HEAD" ''

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

# --- the workflow actually hands the rule to the driver -----------------------
# The rules above are pure and provable; none of that matters if the workflow
# does not pass the input through. This is the failure mode the merge lane has
# a case for by name: a gate declared in YAML, never reaching the script, and
# silent about it — every pull request looks handled and nothing is.
#
# The DEFAULT is asserted too, and it is the load-bearing half. A
# `workflow_call` default reaches only a caller that OMITS the input, and today
# every caller omits this one; an empty default would ship this change to
# nobody while every log said it had landed. That is #578, verbatim.
WF="$HERE/../../.github/workflows/pr-guard.yml"
wired() { # <regex>
  if [ -f "$WF" ] && grep -qE "$1" "$WF"; then printf 'yes'; else printf 'no'; fi
}
expect 'yes' "the workflow hands review-bots to the driver" \
  wired '^ +REVIEW_BOTS_INPUT: \$\{\{ inputs\.review-bots \}\}$'
expect 'yes' "and the input has a non-empty default, or it reaches no caller" \
  wired '^ +default: copilot-pull-request-reviewer\[bot\]$'

# --- the two API calls must be able to say WHY they failed --------------------
# Both fail soft by design, so their only report is what `gh` wrote to stderr:
# a caller missing `pull-requests: write`, a fork's read-only token and a
# GraphQL outage are three different operator actions and one identical
# "could not". A `2>/dev/null` here reads like ordinary tidying and silently
# converts every one of them into the same unactionable line.
DRV="$HERE/pr-guard.sh"
quiet_gh() { # <regex matching the gh invocation>
  if [ -f "$DRV" ] && grep -E "$1" "$DRV" | grep -c '2>/dev/null' >/dev/null; then
    printf 'silenced'
  else
    printf 'audible'
  fi
}
expect 'audible' "the reviews read reports its own failure" \
  quiet_gh '^ +-f query="[$]guard_gql"'
expect 'audible' "and so does the re-request mutation" \
  quiet_gh 'pullRequest \{ number \} \} \}. --silent'

# A reviewer missing from the `reviewRequests` page reads as `stale`, not
# `pending`, and the stale arm re-asks — which REPLACES the request in flight.
# So a page size below the maximum is not a tidier query, it is this guard
# cancelling the review it exists to leave alone. Asserted as a number rather
# than as the literal text, so raising it stays legal and lowering it does not.
guard_page() { # <connection name>
  local n
  n="$(sed -n "s/.*$1(first:\([0-9]\+\)).*/\1/p" "$DRV" 2>/dev/null | head -1)"
  if [ "${n:-0}" -ge 100 ]; then printf 'max'; else printf 'truncating(%s)' "${n:-unset}"; fi
}
expect 'max' "the pending-reviewer page is not truncated" \
  guard_page 'reviewRequests'

printf 'pr-guard decision: %d checks pass' "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf ', %d FAILED\n' "$FAIL"
  exit 1
fi
printf '\n'
