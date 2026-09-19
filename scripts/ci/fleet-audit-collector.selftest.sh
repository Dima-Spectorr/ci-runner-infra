#!/usr/bin/env bash
# Self-test for the fleet audit's ONE impure function that holds a judgement of
# its own: backlog_facts().
#
# Everything else in fleet-audit.sh copies a value out of a response. This one
# decides, from several responses, whether there is an unreleased backlog and
# how old it is — and it can answer "nothing is waiting" for four different
# reasons, three of which mean "I could not tell". Those three shipped as
# silent passes in review and were only found by stubbing `api` by hand; that
# is what this file automates.
#
# THE FAILURE THIS FILE EXISTS TO PREVENT IS A QUIET ONE, so almost every case
# below asserts the EXACT fact string, not merely that the call succeeded. An
# assertion on exit status would have passed against every one of those bugs.
# `backlog=0;backlog_hours=0` is the one output that ends the audit's inquiry —
# the rule takes it as a clean bill of health — so each case says in full which
# of the two shapes it expects: a number the collector established, or a count
# with NO age, which the rule turns into a warning.
#
# No network and no `gh`: the file is sourced with FLEET_AUDIT_LIB=1, which
# stops it before its run section, and `api` is replaced below.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FLEET_AUDIT_LIB=1
export FLEET_OWNER=acct
# Pinned so the fixture paths are stable and VERSION is never read. A tag name
# that no repository has is deliberate: every response below is a fixture.
export FLOATING_TAG=v9
# shellcheck source=/dev/null
source "$HERE/fleet-audit.sh"

REPO=ci-runner-infra
PASS=0
FAIL=0

SHA_TAG=1111111111111111111111111111111111111111
SHA_OBJ=2222222222222222222222222222222222222222
C1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
C2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C3=cccccccccccccccccccccccccccccccccccccccc

NOW=$(date -u +%s)
# iso <seconds-ago> — a timestamp relative to this run, so an age assertion is
# a constant rather than a number that rots the day after it is written.
iso() { date -u -d "@$(( NOW - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# --- the fixture ---------------------------------------------------------------
#
# One global per endpoint, plus one array for the per-commit reads. Every case
# sets the ones it cares about after reset_fixture, so the diff between a case
# and the healthy baseline is exactly the input under test.
declare -A COMMIT_BODY=()
F_REF=""      # git/ref/tags/<tag>
F_TAGOBJ=""   # git/tags/<sha>
F_REPO=""     # repos/<owner>/<repo>
F_CMP=""      # compare/<base>...<head>

# The call counter lives in a FILE, not a variable. `backlog_facts` is called
# inside a command substitution, so every increment the stub makes happens in a
# subshell and is discarded on return — the first draft of this file asserted
# one commit read, saw zero, and the zero meant nothing at all.
READS_FILE="${TMPDIR:-/tmp}/fleet-audit-collector-reads.$$"
reads() { wc -l < "$READS_FILE" 2>/dev/null | tr -d ' \r'; }
trap 'rm -f "$READS_FILE"' EXIT

reset_fixture() {
  COMMIT_BODY=()
  : > "$READS_FILE"
  # Both are read by the sourced collector, never by this file — which is what
  # the disable below says, and why it is not a sign they can be removed.
  # shellcheck disable=SC2034
  BACKLOG_SCAN_MAX=40
  # shellcheck disable=SC2034
  RELEASED_SURFACE='^(modules|scripts)/'
  F_REF="{\"object\":{\"type\":\"tag\",\"sha\":\"$SHA_TAG\"}}"
  F_TAGOBJ="{\"object\":{\"sha\":\"$SHA_OBJ\"}}"
  F_REPO='{"default_branch":"main"}'
  F_CMP=""
}

# The stub. Dispatch order matters: `/git/tags/` and `/commits/` both end in a
# sha, and the bare repository path is a prefix of every other one, so it is
# last.
api() {
  case "$1" in
    */git/ref/tags/*) printf '%s' "$F_REF" ;;
    */git/tags/*)     printf '%s' "$F_TAGOBJ" ;;
    */compare/*)      printf '%s' "$F_CMP" ;;
    */commits/*)
      echo "$1" >> "$READS_FILE"
      printf '%s' "${COMMIT_BODY[${1##*/}]:-}"
      ;;
    *)                printf '%s' "$F_REPO" ;;
  esac
}

# cmp_body <ahead> <base-date-json> <files-json-or-empty> <commit-entries…>
# Builds a compare response. `<base-date-json>` is spliced raw so a case can
# pass `null` or omit the key entirely, and `<files-json-or-empty>` empty means
# NO `files` key at all — which is the whole point of the first case.
cmp_body() {
  local ahead="$1" basedate="$2" files="$3"; shift 3
  local commits="" entry
  for entry in "$@"; do
    [ -n "$commits" ] && commits="$commits,"
    commits="$commits{\"sha\":\"${entry%% *}\",\"commit\":{\"committer\":{\"date\":\"${entry#* }\"}}}"
  done
  printf '{"ahead_by":%s,"base_commit":{"commit":{"committer":%s}},"commits":[%s]%s}' \
    "$ahead" "$basedate" "$commits" \
    "${files:+,\"files\":$files}"
}

# commit_body <file…> — a commit read whose file list is exactly these paths.
commit_body() {
  local out="" f
  for f in "$@"; do
    [ -n "$out" ] && out="$out,"
    out="$out{\"filename\":\"$f\"}"
  done
  printf '{"sha":"x","files":[%s]}' "$out"
}

# is <expected> <description> — backlog_facts must print exactly this.
is() {
  local want="$1" desc="$2" got
  got=$(backlog_facts "$REPO")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "$want" "$got"
  fi
}

# eq <actual> <expected> <description> — for the facts about the call itself.
eq() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$3" "$2" "$1"
  fi
}

# --- resolving the tag ---------------------------------------------------------

# The tag does not resolve at all. THE ONE THING THIS MUST NOT DO IS REPORT AN
# EMPTY BACKLOG: "I could not find the ref every consumer pins" and "nothing is
# waiting to be published" are opposite facts, and the rule only fails loudly on
# the first if the collector says so.
reset_fixture
F_REF=""
is "tag_readable=0" "a 404 on the tag ref is unreadable, not an empty backlog"

# Resolves to something that is neither a tag nor a commit.
reset_fixture
F_REF='{"object":{"type":"blob","sha":"'"$SHA_TAG"'"}}'
is "tag_readable=0" "a tag ref pointing at an unexpected object type is unreadable"

# The annotated tag dereferences, but the tag OBJECT read fails. Without the
# dereference the collector would compare a tag object against a branch, which
# the compare endpoint answers with a 404 every single day.
reset_fixture
F_TAGOBJ=""
is "tag_readable=0" "an annotated tag whose object read failed is unreadable"

# A lightweight tag needs no dereference — and must not be given one.
reset_fixture
F_REF='{"object":{"type":"commit","sha":"'"$SHA_OBJ"'"}}'
F_TAGOBJ='{"object":{"sha":"not-a-sha"}}'
F_CMP=$(cmp_body 0 "{\"date\":\"$(iso 7200)\"}" "")
is "tag_readable=1;backlog=0;backlog_hours=0" "a lightweight tag resolves without a dereference"

# The annotated tag dereferences to something that is not an object name at
# all. `[ -n "$sha" ]` would accept it and hand it to the compare endpoint,
# which answers 404 — an unreadable tag reported as an uncomparable branch, one
# rung quieter than it should be.
reset_fixture
F_TAGOBJ='{"object":{"sha":"not-a-sha"}}'
is "tag_readable=0" "a tag dereferencing to something that is not a sha is unreadable"

# The repository read failed, so there is no default branch to compare against.
# Reported as readable-tag-but-nothing-else, which the rule warns on.
#
# THE COMPARE FIXTURE HERE IS A HEALTHY ONE, deliberately. Leaving it empty
# would make this case pass for the wrong reason: a `main` guessed in place of
# the branch that could not be read would hit an empty compare body and report
# the same unknown by accident. With a clean compare waiting, a guess renders as
# `backlog=0` — a clean bill of health for a repository whose name for its own
# default branch was never established.
reset_fixture
F_REPO=""
F_CMP=$(cmp_body 0 "{\"date\":\"$(iso 7200)\"}" "")
is "tag_readable=1" "an unreadable default branch is not an empty backlog"

# --- the comparison ------------------------------------------------------------

# `.ahead_by` absent. A refusal body and a tag sitting at the tip produce the
# same `// empty` here, and only one of them means the backlog is empty.
reset_fixture
F_CMP='{"status":"error"}'
is "tag_readable=1" "a compare response with no ahead_by is unknown, not zero"

# The genuinely healthy case: the tag is at the tip.
reset_fixture
F_CMP=$(cmp_body 0 "{\"date\":\"$(iso 7200)\"}" "")
is "tag_readable=1;backlog=0;backlog_hours=0" "a tag at the tip of the default branch is an empty backlog"

# --- the union-of-files shortcut -----------------------------------------------

# R1. `files` ABSENT WITH `ahead_by` > 0. This is what a truncated, refused or
# otherwise unexpected compare body looks like, and it produces exactly the same
# zero match count as a documentation-only range. Taking the shortcut on it
# printed `backlog=0` for a range that was five commits ahead — #960's own
# defect, rebuilt one layer down. The walk must run instead.
reset_fixture
F_CMP=$(cmp_body 5 "{\"date\":\"$(iso 720000)\"}" "" "$C1 $(iso 360000)")
COMMIT_BODY[$C1]=$(commit_body modules/ci-host/main.tf)
is "tag_readable=1;backlog=1;backlog_hours=100" "a compare body with no files array is walked, never shortcut"
eq "$(reads)" 1 "the missing-files case actually read the commit"

# A COMPLETE `files` array in which nothing matches. Same zero, opposite
# meaning, and here the shortcut is correct: the compare response already
# carries the union of the range, so a documentation-only day is settled
# without a single further call.
reset_fixture
F_CMP=$(cmp_body 3 "{\"date\":\"$(iso 7200)\"}" \
  '[{"filename":"docs/fleet-audit.md"},{"filename":"README.md"},{"filename":"packer/ci-host-image.pkr.hcl"}]' \
  "$C1 $(iso 360000)")
COMMIT_BODY[$C1]=$(commit_body modules/ci-host/main.tf)
is "tag_readable=1;backlog=0;backlog_hours=0" "a complete files array with no released surface is an empty backlog"
eq "$(reads)" 0 "the no-match shortcut spends no further API calls"

# A complete array WITH a match falls through to the walk, because the union
# says only that something matched somewhere in the range — not which commit,
# and the finding is about the oldest one waiting.
reset_fixture
F_CMP=$(cmp_body 2 "{\"date\":\"$(iso 720000)\"}" \
  '[{"filename":"docs/x.md"},{"filename":"scripts/ci/merge-lane.sh"}]' \
  "$C1 $(iso 180000)" "$C2 $(iso 3600)")
COMMIT_BODY[$C1]=$(commit_body docs/x.md)
COMMIT_BODY[$C2]=$(commit_body scripts/ci/merge-lane.sh)
is "tag_readable=1;backlog=1;backlog_hours=1" "a matching union is walked, and the age comes from the matching commit"

# --- dating the backlog --------------------------------------------------------

# R2. THE BASE COMMIT'S DATE IS ABSENT. `date -u -d "" +%s` does not fail: GNU
# date reads an empty argument as today at midnight UTC and exits 0, so the
# floor that exists to stop the age being OVERSTATED became a ceiling that
# understated it — a two-hundred-hour-old commit rendered as a few hours old,
# under the threshold, compliant. With no readable base date the clamp must not
# be applied at all.
reset_fixture
F_CMP=$(cmp_body 1 'null' "" "$C1 $(iso 720000)")
COMMIT_BODY[$C1]=$(commit_body modules/ci-host/main.tf)
is "tag_readable=1;backlog=1;backlog_hours=200" "an absent base-commit date leaves the age unclamped"

# The clamp itself, when the base date IS readable: nothing can have been
# waiting for publication longer than the tag has been the current tag, so a
# commit written on a long-lived branch is dated from when the tag moved.
reset_fixture
F_CMP=$(cmp_body 1 "{\"date\":\"$(iso 36000)\"}" "" "$C1 $(iso 720000)")
COMMIT_BODY[$C1]=$(commit_body modules/ci-host/main.tf)
is "tag_readable=1;backlog=1;backlog_hours=10" "the backlog clock cannot start before the tag moved"

# R3. A COMMIT DATED IN THE FUTURE. Clock skew is unknown, not healthy:
# clamping a negative age to zero read as "published moments ago", and since the
# age is taken from the first match it also hid every genuinely old commit
# behind it. It counts, it dates nothing, and the result carries NO age.
reset_fixture
F_CMP=$(cmp_body 2 "{\"date\":\"$(iso 720000)\"}" "" "$C1 $(iso -86400)" "$C2 $(iso 360000)")
COMMIT_BODY[$C1]=$(commit_body modules/a.tf)
COMMIT_BODY[$C2]=$(commit_body modules/b.tf)
is "tag_readable=1;backlog=2" "a future-dated commit yields a count with no age, never zero hours"

# An unparseable date is the same class: it cannot date the backlog, and the
# collector must not substitute a number for it.
reset_fixture
F_CMP=$(cmp_body 1 "{\"date\":\"$(iso 7200)\"}" "" "$C1 not-a-date")
COMMIT_BODY[$C1]=$(commit_body modules/a.tf)
is "tag_readable=1;backlog=1" "an unparseable commit date yields a count with no age"

# --- reads that did not arrive -------------------------------------------------

# A COMMIT WHOSE OWN READ CAME BACK EMPTY. `api` answers a failure with an empty
# body, `jq` then yields no filenames, and the match count is zero — the same
# zero a documentation commit produces. Read as "touched nothing", a refused API
# call quietly shrinks the backlog toward the clean answer.
reset_fixture
F_CMP=$(cmp_body 1 "{\"date\":\"$(iso 7200)\"}" "" "$C1 $(iso 360000)")
COMMIT_BODY[$C1]=""
is "tag_readable=1;backlog=1" "a commit whose read came back empty is unknown, not unreleased-nothing"

# A body that is valid JSON but not the commit asked for — a rate-limit or error
# document — is the same finding, and is why the check is for `.sha` rather than
# for non-empty bytes.
reset_fixture
F_CMP=$(cmp_body 1 "{\"date\":\"$(iso 7200)\"}" "" "$C1 $(iso 360000)")
COMMIT_BODY[$C1]='{"message":"API rate limit exceeded"}'
is "tag_readable=1;backlog=1" "an error document in place of a commit is unknown, not empty"

# A genuine documentation commit, which is the case the two above must not be
# confused with: read successfully, matched nothing, backlog is empty.
reset_fixture
F_CMP=$(cmp_body 1 "{\"date\":\"$(iso 7200)\"}" "" "$C1 $(iso 360000)")
COMMIT_BODY[$C1]=$(commit_body docs/fleet-audit.md)
is "tag_readable=1;backlog=0;backlog_hours=0" "a commit read successfully that touched no released surface is empty"

# --- the bounded walk ----------------------------------------------------------

# THE CAP. One API call per commit against a tag that has not moved in months
# would be hundreds, so the walk stops — and past the stop the age is REPORTED
# AS UNKNOWN rather than taken from however far it got. The count falls back to
# the compare's own `ahead_by`, which is the only number still known to be
# complete.
reset_fixture
# shellcheck disable=SC2034  # read by the sourced collector
BACKLOG_SCAN_MAX=1
F_CMP=$(cmp_body 3 "{\"date\":\"$(iso 7200)\"}" "" \
  "$C1 $(iso 360000)" "$C2 $(iso 180000)" "$C3 $(iso 3600)")
COMMIT_BODY[$C1]=$(commit_body docs/x.md)
COMMIT_BODY[$C2]=$(commit_body modules/a.tf)
COMMIT_BODY[$C3]=$(commit_body modules/b.tf)
is "tag_readable=1;backlog=3" "a walk stopped by the cap reports ahead_by and no age"
eq "$(reads)" 1 "the cap actually bounds the number of API calls"

# The same three commits WITHOUT the cap: the walk completes, and the age comes
# from the oldest MATCHING commit rather than the oldest commit.
reset_fixture
F_CMP=$(cmp_body 3 "{\"date\":\"$(iso 720000)\"}" "" \
  "$C1 $(iso 360000)" "$C2 $(iso 180000)" "$C3 $(iso 3600)")
COMMIT_BODY[$C1]=$(commit_body docs/x.md)
COMMIT_BODY[$C2]=$(commit_body modules/a.tf)
COMMIT_BODY[$C3]=$(commit_body modules/b.tf)
is "tag_readable=1;backlog=2;backlog_hours=50" "a completed walk dates the backlog from the oldest matching commit"

# A compare that claims commits but carries none. `ahead_by` said there is work
# and the list said otherwise; the two disagree, so neither is reported as a
# clean answer.
reset_fixture
F_CMP='{"ahead_by":4,"base_commit":{"commit":{"committer":{"date":"'"$(iso 7200)"'"}}},"commits":[]}'
is "tag_readable=1" "ahead_by with an empty commit list is unknown"

printf '\nfleet-audit collector self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
