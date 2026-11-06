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
# It also holds the pure text readers for the two-file lane (#1382): the events
# file's pin, the relay's name against what the events file hears, and the two
# `with:` blocks — fed the documented template itself, near the end.
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
# last. Replaced by a second stub for the fork-posture cases near the end, which
# is why shellcheck reads this one's body as unreachable (SC2317) and, from
# v0.11, the function as never invoked (SC2329).
# shellcheck disable=SC2317,SC2329
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

# --- the two-file lane: events pin, relay name, with: blocks (#1382) ----------
#
# The fixtures ARE the documented template, read out of docs/merge-lane.md: the
# files a consumer copies are the files the audit has to parse, so a template
# edit the parser cannot read fails here rather than in the first audit after
# a consumer copies it.
DOC="$HERE/../../docs/merge-lane.md"
doc_block() { # <workflow name>
  awk -v want="name: $1" '
    /^```yaml$/            { inblk = 1; first = 1; keep = 0; buf = ""; next }
    inblk && /^```$/       { if (keep) printf "%s", buf; inblk = 0; next }
    inblk                  { if (first) { keep = ($0 == want); first = 0 }
                             buf = buf $0 "\n" }
  ' "$DOC"
}
T_POOL=$(doc_block 'Merge lane')
T_EVENTS=$(doc_block 'Merge lane (events)')
T_RELAY=$(doc_block 'Merge lane review relay')
eq "$([ -n "$T_POOL" ] && [ -n "$T_EVENTS" ] && [ -n "$T_RELAY" ] && echo 1)" 1 \
   "all three template blocks are found in the doc, so no case below is vacuous"

# The events file carries the same pin the pool file does, and pin_in reads it.
eq "$(pin_in "$T_EVENTS" 'merge-lane\.yml' | grep -cE '^[0-9a-f]{40}$')" 1 \
   "the events template's pin is readable by pin_in"
eq "$(pin_in "$T_EVENTS" 'merge-lane\.yml')" "$(pin_in "$T_POOL" 'merge-lane\.yml')" \
   "the two lane templates pin the same commit"

eq "$(workflow_name_of "$T_RELAY")" "Merge lane review relay" "the relay's name is read from its name: line"
eq "$(workflow_name_of "name: 'Quoted relay'  # x")" "Quoted relay" "a quoted, commented name: is unquoted"
eq "$(relay_agrees "$T_EVENTS" "$T_RELAY")" 1 "the documented relay matches what the events template hears"
# edited <before> <after> <description> — every fixture below is the template
# with one substitution, and a `${var/pattern/…}` whose pattern misses returns
# the text UNCHANGED. The case after it would then assert on the healthy
# template and could pass for that reason alone, so each edit is asserted to
# have landed before it is used.
edited() {
  if [ "$1" != "$2" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); printf 'FAIL: the fixture edit changed nothing: %s\n' "$3"; fi
}

X="${T_RELAY/name: Merge lane review relay/name: Review relay}"
edited "$T_RELAY" "$X" "relay renamed"
eq "$(relay_agrees "$T_EVENTS" "$X")" 0 "a relay renamed away from the events file's workflows: entry is a mismatch"

X="${T_EVENTS/workflows: \[Merge lane review relay\]/workflows: [Other relay]}"
edited "$T_EVENTS" "$X" "events hears another name"
eq "$(relay_agrees "$X" "$T_RELAY")" 0 "an events file listening for a different name is a mismatch"

# The YAML-sequence spelling of the list is heard the same as the inline one.
X="${T_EVENTS/    workflows: \[Merge lane review relay\]/    workflows:
      - \"Merge lane review relay\"}"
edited "$T_EVENTS" "$X" "sequence form"
eq "$(relay_agrees "$X" "$T_RELAY")" 1 "a sequence-form workflows: list is read"

# A comment line inside the sequence does not end the list early...
X="${T_EVENTS/    workflows: \[Merge lane review relay\]/    workflows:
      # the relay, by its name: line
      - Merge lane review relay}"
edited "$T_EVENTS" "$X" "comment inside a sequence"
eq "$(relay_agrees "$X" "$T_RELAY")" 1 "a comment inside a sequence-form list does not end it"

# ...and a name that appears only in a trailing comment is not heard.
X="${T_EVENTS/workflows: \[Merge lane review relay\]/workflows: [CI] # not yet, Merge lane review relay}"
edited "$T_EVENTS" "$X" "name in a trailing comment"
eq "$(relay_agrees "$X" "$T_RELAY")" 0 "the relay's name in a trailing comment is not what the events file hears"

# A list the parser cannot read — here indented deeper than it expects — yields
# NOTHING heard. That is the parser's silence, not the file's: unknown, never a
# mismatch, so the rule warns rather than fails.
X="${T_EVENTS/    workflows: \[Merge lane review relay\]/      workflows: [Merge lane review relay]}"
edited "$T_EVENTS" "$X" "unreadable indentation"
eq "$(relay_agrees "$X" "$T_RELAY")" "" "an events file whose workflows: list cannot be parsed is unknown, not a mismatch"
eq "$(relay_agrees "name: x" "$T_RELAY")" "" "an events file with no workflow_run at all is unknown, not a mismatch"

eq "$(relay_agrees "" "$T_RELAY")" "" "an unread events file is unknown, not a mismatch"
eq "$(relay_agrees "$T_EVENTS" "")" "" "an unread relay is unknown, not a mismatch"

# The two with: blocks. The documented pair differs only in runs-on and in
# comments, and both of those are ignored — anything else is drift.
eq "$(with_agrees "$T_POOL" "$T_EVENTS")" 1 "the documented lane templates agree apart from runs-on"

X="${T_EVENTS/review-grace-seconds: 60/review-grace-seconds: 600}"
edited "$T_EVENTS" "$X" "different input value"
eq "$(with_agrees "$T_POOL" "$X")" 0 "a different input value in the events file is drift"

X="${T_EVENTS/        Your other required check
/}"
edited "$T_EVENTS" "$X" "required check removed"
eq "$(with_agrees "$T_POOL" "$X")" 0 "a required check missing from the events file is drift"

X="${T_EVENTS/      pass-budget-seconds: 600
/}"
edited "$T_EVENTS" "$X" "input removed"
eq "$(with_agrees "$T_POOL" "$X")" 0 "an input only one file sets is drift"

X="${T_EVENTS/runs-on: ubuntu-latest/runs-on: some-other-label}"
edited "$T_EVENTS" "$X" "runs-on changed"
eq "$(with_agrees "$T_POOL" "$X")" 1 "runs-on alone is not drift"

# The block ends at the next job-level key: secrets: must not be read as input.
X="${T_EVENTS/app-id: \$\{\{ secrets.MERGE_APP_ID \}\}/app-id: x}"
edited "$T_EVENTS" "$X" "secrets changed"
eq "$(with_agrees "$T_POOL" "$X")" 1 "the secrets: block after with: is not part of it"

# A comment indented LESS than the inputs, inside the block, neither ends it
# nor counts: the input after it is still read, and still compared.
X="${T_EVENTS/      review-grace-seconds: 60/  # a shallow note inside with:
      review-grace-seconds: 60}"
edited "$T_EVENTS" "$X" "shallow comment inside with"
eq "$(with_agrees "$T_POOL" "$X")" 1 "a shallow comment inside with: does not end the block"
Y="${X/review-grace-seconds: 60/review-grace-seconds: 61}"
edited "$X" "$Y" "shallow comment then drift"
eq "$(with_agrees "$T_POOL" "$Y")" 0 "an input after a shallow comment is still compared"

# A trailing comment on an input is not part of its value.
X="${T_EVENTS/review-grace-seconds: 60/review-grace-seconds: 60  # the fleet default}"
edited "$T_EVENTS" "$X" "trailing comment"
eq "$(with_agrees "$T_POOL" "$X")" 1 "a trailing comment on an input is not drift"

eq "$(with_agrees "" "$T_EVENTS")" "" "an unread lane file is unknown, not drift"
eq "$(with_agrees "$T_POOL" "name: x")" "" "a file with no with: block is unknown, not drift"

# --- the utility host's fork posture (#1704) -----------------------------------
#
# The bodies are the ones GitHub actually returns: the success shape and the
# public-repository 422 were read live on 2026-11-05; the 403/404 shapes are
# gh's error-document form, which `api` passes through on stdout.
F_FORK=""
F_COMPARE=""
# Per-SHA compare answers and per-path file bodies for the every-pin cases
# (#1716); a SHA with no entry gets F_COMPARE, a path with no entry nothing.
declare -A COMPARE_BY_SHA=()
declare -A FILE_BY_PATH=()
FORK_PATH_FILE="${TMPDIR:-/tmp}/fleet-audit-collector-forkpath.$$"
trap 'rm -f "$READS_FILE" "$FORK_PATH_FILE"' EXIT
api() {
  case "$1" in
    */actions/permissions/fork-pr-workflows-private-repos)
      echo "$1" > "$FORK_PATH_FILE"
      printf '%s' "$F_FORK" ;;
    # The provenance cases (#1715) below share this stub rather than redefine it.
    */compare/*)
      echo "$1" >> "$PROV_CALLS"
      printf '%s' "${COMPARE_BY_SHA[${1##*...}]:-$F_COMPARE}" ;;
    */contents/*)
      echo "$1" >> "$PROV_CALLS"
      printf '%s' "${FILE_BY_PATH[${1#*/contents/}]:-}" ;;
    *) printf '' ;;
  esac
}
fork_body() { # <run-workflows-value-json>
  printf '{"run_workflows_from_fork_pull_requests":%s,"send_write_tokens_to_workflows":false,"send_secrets_and_variables":false,"require_approval_for_fork_pr_workflows":false}' "$1"
}

F_FORK=$(fork_body false)
eq "$(fork_pr_facts svc-a)" "false" "a private repository with fork workflows off reads false"
eq "$(cat "$FORK_PATH_FILE")" "repos/acct/svc-a/actions/permissions/fork-pr-workflows-private-repos" \
   "a bare name is read under the audited owner"
F_FORK=$(fork_body true)
eq "$(fork_pr_facts svc-a)" "true" "fork workflows re-enabled reads true"
: > "$FORK_PATH_FILE"
eq "$(fork_pr_facts other/svc-b)" "true" "an owner/name entry is read as given"
eq "$(cat "$FORK_PATH_FILE")" "repos/other/svc-b/actions/permissions/fork-pr-workflows-private-repos" \
   "an owner/name entry is not prefixed with the audited owner"

F_FORK='{"message":"Fork PR workflow settings is not allowed for public repositories.","documentation_url":"https://docs.github.com/rest/actions/permissions#get-private-repo-fork-pr-workflow-settings-for-a-repository","status":"422"}'
eq "$(fork_pr_facts svc-a)" "public" "the public-repository 422 is its own value"

# THE TRAPS. A refusal body has no boolean, and each of these must come back
# `unreadable` — never `false`, which the rule reports as compliant.
F_FORK='{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest","status":"403"}'
eq "$(fork_pr_facts svc-a)" "unreadable" "a 403 (no Administration: read) is unreadable, not false"
F_FORK='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
eq "$(fork_pr_facts svc-a)" "unreadable" "a 404 (App not installed) is unreadable, not false"
F_FORK='{"message":"Resource not accessible to public integrations","status":"403"}'
eq "$(fork_pr_facts svc-a)" "unreadable" "a refusal that merely mentions public is not the 422 answer"
F_FORK='{"message":"Validation Failed","status":"422"}'
eq "$(fork_pr_facts svc-a)" "unreadable" "a 422 that is not the public-repository answer is unreadable"
F_FORK=""
eq "$(fork_pr_facts svc-a)" "unreadable" "an empty body is unreadable, not false"
F_FORK=$(fork_body '"false"')
eq "$(fork_pr_facts svc-a)" "unreadable" "a string where the boolean belongs is unreadable"
F_FORK=$(fork_body null)
eq "$(fork_pr_facts svc-a)" "unreadable" "a null setting is unreadable, not false"

# Operator input never reaches a URL unless it is a plain repository name.
F_FORK=$(fork_body false)
: > "$FORK_PATH_FILE"
eq "$(fork_pr_facts '../../user')" "unreadable" "a path-traversal entry is refused"
eq "$(fork_pr_facts 'a/b/c')" "unreadable" "an entry with two slashes is refused"
eq "$(fork_pr_facts 'acct/..')" "unreadable" "a dot-dot repository component is refused"
eq "$(wc -c < "$FORK_PATH_FILE" | tr -d ' ')" "0" "a refused entry makes no API call"

# The list parser: every separator an operator might type into a variable.
eq "$(utility_repos_of "svc-a, svc-b
svc-c	svc-a  other/svc-d" | tr '\n' ' ')" "svc-a svc-b svc-c other/svc-d " \
   "commas, spaces, tabs and newlines all separate; duplicates and blanks drop"
eq "$(utility_repos_of "")" "" "an empty list yields nothing"
eq "$(utility_repos_of "$(printf 'svc-a\r\nsvc-b\r\n')" | tr '\n' ' ')" "svc-a svc-b " \
   "a CRLF-terminated variable leaves no carriage return in a name"

# The run section, end to end, against a fake `gh` and an empty manifest: the
# one place the list, the collector, the rule and the tally meet. One
# repository is named so the account-listing half stays out of it.
FAKE="${TMPDIR:-/tmp}/fleet-audit-fakegh.$$"
EMPTY_MANIFEST="$FAKE/repos.tsv"
mkdir -p "$FAKE"
trap 'rm -f "$READS_FILE" "$FORK_PATH_FILE"; rm -rf "$FAKE"' EXIT
: > "$EMPTY_MANIFEST"
# shellcheck disable=SC2016  # the fake's text is expanded by the fake, not here
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in *fork-pr-workflows-private-repos*) printf "%s" "$FAKE_FORK_BODY" ;; *) exit 1 ;; esac' > "$FAKE/gh"
chmod +x "$FAKE/gh"
run_audit() { # <utility-list> <fork-body> <only>
  env -u FLEET_AUDIT_LIB PATH="$FAKE:$PATH" FLEET_OWNER=acct FLEET_MANIFEST="$EMPTY_MANIFEST" \
    UTILITY_HOST_REPOS="$1" FAKE_FORK_BODY="$2" bash "$HERE/fleet-audit.sh" "$3" 2>/dev/null
  echo "exit=$?"
}
OUT=$(run_audit "" "$(fork_body true)" svc-a)
eq "$(printf '%s\n' "$OUT" | grep -c 'note:fork-pr-audit-skipped UTILITY_HOST_REPOS-is-unset')" 1 \
   "an unset list is reported as a skipped check, not silence"
eq "$(printf '%s\n' "$OUT" | grep -c 'fork-pr-workflows')" 0 "an unset list reads no repository"
eq "$(printf '%s\n' "$OUT" | tail -1)" "exit=0" "a skipped check does not fail the audit"
OUT=$(run_audit "svc-a,svc-b" "$(fork_body true)" svc-a)
eq "$(printf '%s\n' "$OUT" | grep -cE '^svc-a +fail:fork-pr-workflows-enabled ')" 1 \
   "a utility-host repository with fork workflows on is reported as a failure"
eq "$(printf '%s\n' "$OUT" | grep -c '^svc-b ')" 0 "the one-repository argument narrows the fork check too"
eq "$(printf '%s\n' "$OUT" | grep -c 'note:fork-pr-audit-skipped')" 0 "a set list is not reported as skipped"
eq "$(printf '%s\n' "$OUT" | tail -1)" "exit=1" "a fork-PR failure fails the audit"
OUT=$(run_audit "svc-a" '{"message":"Not Found","status":"404"}' svc-a)
eq "$(printf '%s\n' "$OUT" | grep -cE '^svc-a +warn:fork-pr-setting-unreadable ')" 1 \
   "an unreadable setting reaches the report as a warning"
eq "$(printf '%s\n' "$OUT" | tail -1)" "exit=0" "an unreadable setting warns without failing the audit"
OUT=$(run_audit "svc-a" "$(fork_body false)" svc-a)
eq "$(printf '%s\n' "$OUT" | grep -cE '^svc-a +ok:fork-pr-workflows-disabled$')" 1 \
   "a compliant utility-host repository is reported, not silent"

# --- pin provenance (#1715) -----------------------------------------------------
#
# The compare bodies' `status` words were read live on 2026-11-06: an older
# default-branch commit compared as `<branch>...<sha>` reads `behind`; a SHA
# the repository does not hold is gh's error document with "status":"404".
eq "$(history_of_compare '{"status":"behind","ahead_by":0,"behind_by":4}')" "1" "an ancestor of the branch is in the history"
eq "$(history_of_compare '{"status":"identical"}')" "1" "the branch tip is in the history"
eq "$(history_of_compare '{"status":"diverged"}')" "0" "a diverged commit is not in the history"
eq "$(history_of_compare '{"status":"ahead"}')" "0" "a commit carrying work the branch lacks is not in the history"
eq "$(history_of_compare '{"message":"Not Found","status":"404"}')" "0" "a SHA the repository does not hold is not in the history"
eq "$(history_of_compare '{"message":"Resource not accessible by integration","status":"403"}')" "" "a 403 is unknown, never a verdict"
eq "$(history_of_compare '')" "" "an empty body is unknown"
eq "$(history_of_compare 'not json')" "" "a non-JSON body is unknown"

PROV_SHA=cccccccccccccccccccccccccccccccccccccccc
PROV_CALLS="${TMPDIR:-/tmp}/fleet-audit-collector-provcalls.$$"
PIN_HISTORY_CACHE="${TMPDIR:-/tmp}/fleet-audit-collector-provcache.$$"
mkdir -p "$PIN_HISTORY_CACHE"
trap 'rm -f "$READS_FILE" "$FORK_PATH_FILE" "$PROV_CALLS"; rm -rf "$FAKE" "$PIN_HISTORY_CACHE"' EXIT
: > "$PROV_CALLS"
F_COMPARE='{"status":"behind"}'
# shellcheck disable=SC2034  # read by pin_in_history, sourced from fleet-audit.sh
FLEET_HISTORY_BRANCH=main
eq "$(pin_in_history "$PROV_SHA")" "1" "an in-history pin reads 1"
eq "$(cat "$PROV_CALLS")" "repos/acct/ci-runner-infra/compare/main...$PROV_SHA" "the compare is branch...sha against the fleet repository"
eq "$(pin_in_history "$PROV_SHA")" "1" "a second read of the same pin answers the same"
eq "$(wc -l < "$PROV_CALLS" | tr -d ' ')" "1" "and comes from the cache, not a second compare"
eq "$(pin_in_history "not-a-sha")" "" "a malformed pin is unknown and makes no call"
# shellcheck disable=SC2034  # read by pin_in_history
FLEET_HISTORY_BRANCH=""
rm -f "$PIN_HISTORY_CACHE"/*
eq "$(pin_in_history "$PROV_SHA")" "" "an unreadable fleet repository makes every provenance unknown"
eq "$(wc -l < "$PROV_CALLS" | tr -d ' ')" "1" "and makes no compare whose 404 would read as an imposter"
PIN_HISTORY_CACHE=""

# A compare body holding SEVERAL JSON objects (#1716 item 3) is no single
# answer: jq prints one status per object, and two words are not a verdict.
eq "$(history_of_compare '{"status":"behind"}{"status":"behind"}')" "" "concatenated compare objects are unknown, even when they agree"
eq "$(history_of_compare '{"status":"404"} {"status":"behind"}')" "" "concatenated compare objects that disagree are unknown"

# --- every pin, every workflow (#1716) --------------------------------------------
#
# GOOD is in the fleet's history, BAD is an imposter (a fork-only commit: 404).
GOOD=dddddddddddddddddddddddddddddddddddddddd
BAD=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
UNK=ffffffffffffffffffffffffffffffffffffffff
COMPARE_BY_SHA=([$GOOD]='{"status":"behind"}' [$BAD]='{"message":"Not Found","status":"404"}' [$UNK]='{"message":"Resource not accessible by integration","status":"403"}')
# shellcheck disable=SC2034  # read by pin_in_history
FLEET_HISTORY_BRANCH=main
CALLEE="acct/ci-runner-infra/.github/workflows/merge-lane.yml"
job() { printf '  %s:\n    uses: %s@%s\n' "$1" "$CALLEE" "$2"; }

# The reviewer's reproduction: a commented decoy, in history, above the real pin.
# Comments are NOT stripped (a line-based strip cannot see quoting, below), so
# the decoy is judged as a pin too — it can only add a pin, never hide one, and
# the worst verdict, the imposter, wins.
DECOY="jobs:
  # uses: $CALLEE@$GOOD
$(job lane "$BAD")"
eq "$(pins_in "$DECOY" 'merge-lane\.yml' | tr '\n' ' ')" "$GOOD $BAD " "a commented decoy is read as well as the real pin"
eq "$(pin_in "$DECOY" 'merge-lane\.yml')" "$GOOD" "pin_in is the first pin, decoy or not"
eq "$(caller_pin_facts lane "$DECOY" 'merge-lane\.yml')" "lane_pin=$GOOD;lane_pins=$GOOD,$BAD;lane_pin_in_history=0;lane_history_pin=$BAD" \
   "a decoy comment above an imposter pin still fails provenance, naming the imposter"

# A pin in a trailing comment is judged too: noise, never a silent pass.
TRAIL="    uses: $CALLEE@$GOOD # was $CALLEE@$BAD"
eq "$(pins_in "$TRAIL" 'merge-lane\.yml' | tr '\n' ' ')" "$GOOD $BAD " "a pin in a trailing comment is judged too"

# The security review's two probes (round 2): a ` #` inside a quoted string, and
# a `#`-led line inside a multi-line double-quoted flow scalar. Comment
# stripping hid the imposter in both.
PROBE1="jobs: {x: {name: \"a #\", uses: $CALLEE@$BAD}}"
eq "$(pins_in "$PROBE1" 'merge-lane\.yml')" "$BAD" "a ' #' inside a quoted flow-mapping value does not hide the pin"
PROBE2="jobs: {x: {name: \"a
  # b\", uses: $CALLEE@$BAD}}"
eq "$(pins_in "$PROBE2" 'merge-lane\.yml')" "$BAD" "a '#'-led line inside a quoted multi-line scalar does not hide the pin"

# A ref that only STARTS like a SHA is a branch or tag: not a pin, but a not-a-sha.
eq "$(pins_in "    uses: $CALLEE@${GOOD}x" 'merge-lane\.yml')" "" "<40 hex>x is not a SHA pin"
eq "$(pins_in "    uses: \"$CALLEE@$BAD\"" 'merge-lane\.yml')" "$BAD" "a quoted SHA pin is still a pin"
for REF in v5 main 1234567 "${GOOD}x" refs/pull/1/head "refs/pull/1/${GOOD}x" ""; do
  eq "$(refs_not_sha_in "    uses: $CALLEE@$REF")" "${REF:-<empty>}" "a fleet ref '@${REF:-<empty>}' is reported as not a SHA"
done
eq "$(refs_not_sha_in "    uses: '$CALLEE@v5' # tag")" "v5" "a quoted tag ref stops at the quote"
eq "$(refs_not_sha_in "    uses: $CALLEE@$GOOD")" "" "a 40-hex SHA ref is not reported"
eq "$(refs_not_sha_in "    uses: actions/checkout@v4")" "" "a non-fleet ref by tag is not this rule's business"

# An escape in a double-quoted scalar can spell a fleet reference neither
# extractor sees: `\x69` for `i`, and a backslash-newline joining two halves.
eq "$(obfuscated_in "    uses: \"o/c\\x69-runner-infra/.github/workflows/merge-lane.yml@$BAD\"")" "1" "a \\x69 escape on a uses line is obfuscated"
CONT="    uses: \"$CALLEE@bbbbbbbbbbbbbbbbbbbb\\
      bbbbbbbbbbbbbbbbbbbb\""
eq "$(obfuscated_in "$CONT")" "1" "a backslash continuation on a uses line is obfuscated"
eq "$(pins_in "$CONT" 'merge-lane\.yml')" "" "and the split pin is invisible to the extractor, which is why it warns"
NEXT="    uses: >-
      \"o/c\\x69-runner-infra/.github/workflows/merge-lane.yml@$BAD\""
eq "$(obfuscated_in "$NEXT")" "1" "an escape on the value line after a bare uses: is obfuscated"
ORDINARY="name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: printf 'a\\tb\\n' | grep -E '\\s'
      - run: |
          echo \"done\" \\
            && true
  lane:
    uses: $CALLEE@$GOOD"
eq "$(obfuscated_in "$ORDINARY")" "" "an ordinary workflow with backslashes in run: text does not warn"

# Two jobs call the same callee; the second is the imposter. Worst wins, the
# stale rule still reads the first, and the finding names the imposter.
TWO_JOBS="jobs:
$(job a "$GOOD")
$(job b "$BAD")"
eq "$(pins_in "$TWO_JOBS" 'merge-lane\.yml' | tr '\n' ' ')" "$GOOD $BAD " "both jobs' pins are read, in order"
eq "$(caller_pin_facts lane "$TWO_JOBS" 'merge-lane\.yml')" "lane_pin=$GOOD;lane_pins=$GOOD,$BAD;lane_pin_in_history=0;lane_history_pin=$BAD" \
   "one imposter among two jobs fails, naming the imposter"
UNK_JOBS="jobs:
$(job a "$GOOD")
$(job b "$UNK")"
eq "$(caller_pin_facts lane "$UNK_JOBS" 'merge-lane\.yml')" "lane_pin=$GOOD;lane_pins=$GOOD,$UNK;lane_pin_in_history=;lane_history_pin=$UNK" \
   "an unknown among good pins is unknown, never a pass"
ALL_GOOD="jobs:
$(job a "$GOOD")
$(job b "$GOOD")
$(job c "$(printf '%s' "$GOOD" | tr 'a-f' 'A-F')")"
eq "$(pins_in "$ALL_GOOD" 'merge-lane\.yml')" "$GOOD" "repeated pins, any case, de-duplicate to one"
eq "$(caller_pin_facts lane "$ALL_GOOD" 'merge-lane\.yml')" "lane_pin=$GOOD;lane_pins=$GOOD;lane_pin_in_history=1;lane_history_pin=$GOOD" \
   "every pin in history is quiet"
eq "$(caller_pin_facts lane "name: x" 'merge-lane\.yml')" "lane_pin=;lane_pins=;lane_pin_in_history=;lane_history_pin=" \
   "a caller with no pin has no provenance"

# GitHub resolves the owner/repository in any case, so a mixed-case path is the
# same fleet call: an imposter behind it must fail, not slip past the match.
MIXED="jobs:
$(job a "$GOOD")
  b:
    uses: Acct/CI-Runner-Infra/.GitHub/Workflows/merge-lane.yml@$(printf '%s' "$BAD" | tr 'a-f' 'A-F')"
eq "$(pins_in "$MIXED" 'merge-lane\.yml' | tr '\n' ' ')" "$GOOD $BAD " "a mixed-case path is matched, and its SHA lowercased"
eq "$(caller_pin_facts lane "$MIXED" 'merge-lane\.yml')" "lane_pin=$GOOD;lane_pins=$GOOD,$BAD;lane_pin_in_history=0;lane_history_pin=$BAD" \
   "a mixed-case path with an imposter SHA fails"
eq "$(pins_in "$MIXED" 'merge-lane\.yml' | grep -cvE '^[0-9a-f]{40}$')" "0" "every extracted pin passes the is_sha shape"

# The scan over every workflow file. merge-lane.yml was already read for the
# named caller, so it must come from WORKFLOW_TEXT, not a second read.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
OTHER="jobs:
  deploy:
    uses: ACCT/Ci-Runner-Infra/.github/workflows/pr-guard.yml@$BAD"
WORKFLOW_TEXT=([merge-lane.yml]="$(job lane "$GOOD")")
FILE_BY_PATH=([.github/workflows/deploy.yaml]="{\"content\":\"$(b64 "$OTHER")\"}"
              [.github/workflows/ci.yml]="{\"content\":\"$(b64 "name: CI")\"}")
: > "$PROV_CALLS"
LIST="merge-lane.yml
ci.yml
deploy.yaml
README.md"
eq "$(workflow_pin_facts svc-a "$LIST")" \
   "wf_scanned=1;wf_pins=2;wf_pin_in_history=0;wf_history_pin=$BAD;wf_history_files=deploy.yaml;wf_unread=;wf_refused=0;wf_not_sha=;wf_obfuscated=" \
   "an imposter pin in an extra workflow file fails, naming the file"
eq "$(grep -c '/contents/' "$PROV_CALLS")" "2" "only the files not already read are fetched, and non-YAML is skipped"
eq "$(grep -c 'contents/.github/workflows/merge-lane.yml' "$PROV_CALLS")" "0" "the named caller's text is reused"

FILE_BY_PATH[.github/workflows/deploy.yaml]="{\"content\":\"$(b64 "${OTHER/$BAD/$GOOD}")\"}"
eq "$(workflow_pin_facts svc-a "$LIST")" \
   "wf_scanned=1;wf_pins=2;wf_pin_in_history=1;wf_history_pin=;wf_history_files=;wf_unread=;wf_refused=0;wf_not_sha=;wf_obfuscated=" \
   "every pin in every workflow in history is quiet"

FILE_BY_PATH[.github/workflows/deploy.yaml]="{\"content\":\"$(b64 "${OTHER/$BAD/$UNK}")\"}"
eq "$(workflow_pin_facts svc-a "$LIST")" \
   "wf_scanned=1;wf_pins=2;wf_pin_in_history=;wf_history_pin=$UNK;wf_history_files=deploy.yaml;wf_unread=;wf_refused=0;wf_not_sha=;wf_obfuscated=" \
   "an unknown provenance in an extra file is unknown, naming the file"

# shellcheck disable=SC2034  # read by workflow_pin_facts
WORKFLOW_TEXT=()
eq "$(workflow_pin_facts svc-a "$(printf 'gone.yml\r\na;b.yml\r\n')")" \
   "wf_scanned=1;wf_pins=0;wf_pin_in_history=1;wf_history_pin=;wf_history_files=;wf_unread=gone.yml;wf_refused=1;wf_not_sha=;wf_obfuscated=" \
   "an unreadable file and an unsafe name are reported as unscanned, never clean"

# Upper-case extensions run exactly like lower-case ones, so they are scanned;
# a tag-pinned and an escaped fleet call are named in their own facts.
FILE_BY_PATH=([.github/workflows/CI.YML]="{\"content\":\"$(b64 "$OTHER")\"}"
              [.github/workflows/tag.Yaml]="{\"content\":\"$(b64 "    uses: $CALLEE@v5")\"}"
              [.github/workflows/esc.yml]="{\"content\":\"$(b64 "    uses: \"o/c\\x69-runner-infra/.github/workflows/merge-lane.yml@$BAD\"")\"}")
eq "$(workflow_pin_facts svc-a "$(printf 'CI.YML\ntag.Yaml\nesc.yml\nnotes.TXT')")" \
   "wf_scanned=1;wf_pins=1;wf_pin_in_history=0;wf_history_pin=$BAD;wf_history_files=CI.YML;wf_unread=;wf_refused=0;wf_not_sha=tag.Yaml;wf_obfuscated=esc.yml" \
   "an upper-case .YML is scanned, a tag ref is not-a-sha, an escape is obfuscated"

# A workflows listing that could not be read is unscanned in every tier that
# scans, never a clean scan with nothing in it.
FILE_BY_PATH=()
for TIER in checks pool lane; do
  eq "$(facts_for svc-a "$TIER" "$GOOD" | grep -o 'wf_scanned=1;wf_listing_unreadable=1')" "wf_scanned=1;wf_listing_unreadable=1" \
     "an unreadable workflows listing is reported in the $TIER tier"
done
eq "$(facts_for svc-a dormant "$GOOD" | grep -c 'wf_')" "0" "a dormant repository is not scanned"
FILE_BY_PATH=()
COMPARE_BY_SHA=()
# shellcheck disable=SC2034  # read by pin_in_history
FLEET_HISTORY_BRANCH=""

# --- the two guards around the collector ---------------------------------------
#
# Neither is a judgement inside backlog_facts(), and both fail the way this
# whole file exists to catch: quietly, leaving an audit that still reports
# facts. Each is decided once at load, so each is asserted by re-entering the
# script in a subshell rather than by calling a function.

# A cap that `test` cannot compare is not a cap. `[ "$n" -gt abc ]` EXITS 2
# rather than returning false, the walk then reads that as "not past the cap",
# and one operator typo turns a 40-call audit into one call per commit.
load() { FLEET_AUDIT_LIB=1 FLEET_OWNER=acct FLOATING_TAG=v9 BACKLOG_SCAN_MAX="$1" \
  bash -c 'source "$0" && printf "%s" "$BACKLOG_SCAN_MAX"' "$HERE/fleet-audit.sh" 2>/dev/null; }
eq "$(load abc)" "40" "a scan cap that is not a number falls back to the default"
eq "$(load '')"  "40" "an empty scan cap falls back to the default"
eq "$(load 7)"   "7"  "a numeric scan cap is honoured"
eq "$(load 0)"   "0"  "zero is a whole number, and still caps the walk at zero"

# The library guard has to mean the same thing however the file was entered.
# EXECUTED with the variable set, a bare top-level `return` is an error that
# stops nothing under `set -uo pipefail`, so the audit it was told not to run
# runs anyway — against the real account, from a test.
eq "$(FLEET_AUDIT_LIB=1 bash "$HERE/fleet-audit.sh" >/dev/null 2>&1; echo "$?")" "0" \
   "the library guard stops an EXECUTED run instead of falling through it"
eq "$(FLEET_AUDIT_LIB=1 bash "$HERE/fleet-audit.sh" 2>&1 >/dev/null | wc -l | tr -d ' ')" "0" \
   "and it stops quietly, with nothing on stderr"

printf '\nfleet-audit collector self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
