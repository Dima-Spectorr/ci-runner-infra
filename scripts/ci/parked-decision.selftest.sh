#!/usr/bin/env bash
# Self-test for the controller's merge-queue parking rule.
#
# This rule does not delete anything, so the cost of getting it wrong is not a
# lost job — it is a muted alert. It fires on a state that every other surface
# reports as healthy, which means the only thing standing between it and being
# ignored is that it stays quiet on work in progress. A rule that reports a
# green draft opened four minutes ago is a rule somebody filters out of their
# inbox, and then the parked pull request it was built for goes unseen again.
#
# So the cases below are weighted towards the SILENT arms: every reason the rule
# has to say nothing, plus the boundary of each count it compares, plus the
# malformed inputs a sweep can hand it when GitHub answers oddly.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/parked-decision.sh"

PASS=0
FAIL=0

# expect <expected-prefix> <description> <args...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(parked_verdict "$@")
  if [[ "$got" == "$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  args: %s\n  want: %s*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# args: draft base queue_base checks_total checks_failed checks_pending
QB=main

# --- the reportable states ----------------------------------------------------
# All three are the same shape: finished, nothing failed, and the queue will
# never take it. These are the shapes that produced two "CI is stuck" reports in
# one week with no failing job anywhere.
expect "parked:draft" "a green draft is the shape that parked for three days" \
  1 "$QB" "$QB" 40 0 0
expect "parked:base" "a green pull request based on a sibling branch is #299" \
  0 feature/x "$QB" 12 0 0
expect "parked:draft-and-base" "both conditions failing is reported as both" \
  1 feature/x "$QB" 12 0 0
expect "parked:draft" "one green check is enough to be finished" \
  1 "$QB" "$QB" 1 0 0
# Neutral and skipped runs are not failures anywhere in GitHub's own model, and
# the caller is specified to exclude them from `failed`. A repository with a
# large skipped matrix is therefore still reportable, which matters: that is the
# normal shape of a monorepo's path-filtered workflows.
expect "parked:draft" "skipped checks do not count as failures at this boundary" \
  1 "$QB" "$QB" 40 0 0

# --- admissible: not this rule's business -------------------------------------
# The free half of the rule. A pull request that fails no entry condition is
# dropped here, BEFORE the caller pays for its check counts — which is what
# keeps the sweep at one list call on a healthy repository.
expect "quiet:admissible" "the ordinary case costs nothing and says nothing" \
  0 "$QB" "$QB" 40 0 0
expect "quiet:admissible" "and says nothing even when it is red" \
  0 "$QB" "$QB" 40 7 0
expect "quiet:admissible" "a queue base other than main is honoured" \
  0 develop develop 40 0 0
expect "parked:base" "…and the same branch is parked when the queue wants another" \
  0 develop "$QB" 40 0 0

# --- silent arm 1: nothing ran ------------------------------------------------
# Also the conflict case, deliberately. A conflicted branch runs no CI, so it
# arrives here with zero checks and leaves quietly — which is how this rule
# stays out of the one entry condition GitHub already reports in red.
expect "quiet:no-checks" "a draft with no checks at all is work in progress" \
  1 "$QB" "$QB" 0 0 0
expect "quiet:no-checks" "a conflicted branch runs nothing and is not reported here" \
  0 feature/x "$QB" 0 0 0

# --- silent arm 2: still running ----------------------------------------------
expect "quiet:in-flight" "one pending check is enough to stay quiet" \
  1 "$QB" "$QB" 40 0 1
expect "quiet:in-flight" "pending outranks failed — the run is not over" \
  1 "$QB" "$QB" 40 3 1

# --- silent arm 3: already red ------------------------------------------------
# The author has a failure on the page. A second signal saying the queue will
# not take it adds nothing, and every added signal on an already-failing pull
# request is a reason to stop reading this one.
expect "quiet:red" "a red draft is not a parked pull request" \
  1 "$QB" "$QB" 40 1 0
expect "quiet:red" "…at any number of failures" \
  0 feature/x "$QB" 40 40 0

# --- malformed input ----------------------------------------------------------
# A sweep hands this rule whatever jq made of GitHub's answer. Every one of
# these must be silence: the whole value of the rule is that it fires on a state
# nothing else reports, so a false positive out of its own parsing spends the
# only credibility it has.
expect "quiet:unparseable" "a non-numeric total is not a green pull request" \
  1 "$QB" "$QB" null 0 0
expect "quiet:unparseable" "nor a non-numeric failed count" \
  1 "$QB" "$QB" 40 "" 0
expect "quiet:unparseable" "nor a non-numeric pending count" \
  1 "$QB" "$QB" 40 0 abc
expect "quiet:unparseable" "a negative count is not numeric here either" \
  1 "$QB" "$QB" -1 0 0
expect "quiet:no-queue-base" "an unconfigured queue base parks nothing" \
  1 "$QB" "" 40 0 0
expect "quiet:no-base" "a pull request with no base branch is unjudgeable" \
  1 "" "$QB" 40 0 0

# `draft` is the one argument that is not validated, because it does not need
# to be: anything that is not the string "1" is read as "not a draft", and the
# base comparison then decides on its own. An unknown draft flag can therefore
# lose a report, never invent one.
expect "quiet:admissible" "an unrecognised draft flag never manufactures a report" \
  yes "$QB" "$QB" 40 0 0
expect "parked:base" "…and does not suppress one the base condition earned" \
  yes feature/x "$QB" 40 0 0

# --- defaults -----------------------------------------------------------------
# Called with nothing, the rule must be silent. A future caller that forgets an
# argument gets no alert, not a spurious one.
expect "quiet:" "no arguments at all is silence" # (no args)

# --- parked_denial: is a failed sweep refused, or merely late? -----------------
#
# The counter this feeds is the one an operator is paged on, and it separates
# two states that used to share a number: "retry in five minutes" and "no
# retry will ever work". A rule that says DENIED too eagerly pages somebody
# during a GitHub incident; one that says it too rarely restores the silent
# zero this whole file exists to end.
deny() { # <expected: yes|no> <name> <status>
  local want="$1" name="$2" status="${3-}"
  local got=no
  parked_denial "$status" && got=yes
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name: parked_denial '$status' -> $got, expected $want"
  fi
}

deny yes "403 is the missing checks:read permission, the whole reason for this" 403
deny yes "401 is a rejected installation token, equally permanent" 401
deny yes "404 on a sha the same token just listed is a permission answer" 404

# Everything below is LATE, and counting it as denied would page a human for
# something that fixes itself.
deny no  "500 is GitHub having a bad day" 500
deny no  "502 likewise" 502
deny no  "503 likewise" 503
deny no  "000 is curl never getting a response — a network fact, not a grant" 000
deny no  "no-token is the secret read failing, reported by its own path" no-token
deny no  "200 never reaches here, and must not be read as a denial anyway" 200
deny no  "an empty status is unknown, and unknown is not a page" ""
deny no  "no argument at all is silence, like every other rule in this file"
deny no  "a status that merely CONTAINS 403 is not a 403" "x403"
deny no  "nor one that is prefixed by it" "4030"

if [ "$FAIL" -gt 0 ]; then
  echo "parked-decision: $FAIL failed, $PASS passed"
  exit 1
fi
echo "parked-decision: $PASS cases pass"
