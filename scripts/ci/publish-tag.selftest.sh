#!/usr/bin/env bash
# Self-test for the workflow that turns `VERSION` into a tag a consumer can pin.
#
# WHY: tags stopped at v5.3.2 while `VERSION` said v5.7.0. v5.4.0, v5.5.0 and
# v5.6.0 merged, passed every gate, updated every documented pin — and were
# unreachable, because tagging was a human step and the human stopped. Every
# `?ref=` in the README named a tag that did not exist, so the one
# copy-pasteable line in the repository pointed at nothing for four releases.
#
# The failure is SILENT in the way that matters: nothing goes red. Main is
# healthy, docs-pins is green (it asserts the docs against `VERSION`, and is
# deliberately not asserted against `git tag`), and `release-tag.yml` validates
# tags that were pushed — the whole failure is that none was. It surfaces only
# when a consumer tries to adopt.
#
# So the checks below are STRUCTURAL, on the workflow text: they assert the
# properties that make the automation trustworthy — that it runs unfiltered on
# main, that it is idempotent, that it refuses an unshaped VERSION, that the
# exact tag is immutable once published, and that only the floating major tag
# moves. Each mutation breaks one the way a later edit plausibly would and
# asserts this test notices; a gate that only passes on correct input is not
# evidence.

# Every predicate matches the TEXT of the workflow, in which `$want`, `$major`
# and `${{ github.token }}` are the literal characters that must be there.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$HERE/../../.github/workflows/publish-tag.yml"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$WORKFLOW" ] || { echo "FAIL: missing $WORKFLOW"; exit 1; }

# Code only: full-line comments stripped, so the long rationale above each
# property in the workflow can never satisfy the check for the property.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `... | grep -q` under `set -o pipefail`: grep exits on first match, the
# writer takes SIGPIPE, and a successful match is reported as a failure. Match
# against a string instead.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# A release that is not published is the whole failure, so the trigger must be
# every push to main. A `paths:` filter would express "tag when a release
# lands" — which is exactly the promise the human made and broke.
runs_on_every_main_push() {
  local code; code=$(code_of "$1")
  matches "$code" '^on:' || return 1
  matches "$code" 'branches: \[main\]' || return 1
  ! matches "$code" '^[[:space:]]+paths(-ignore)?:' || return 1
}

# Without write access the job cannot create a ref at all, and the run that
# does nothing looks the same as the run with nothing to do.
can_write_tags() {
  local code; code=$(code_of "$1")
  matches "$code" '^permissions:' || return 1
  matches "$code" 'contents: write' || return 1
}

# Running on every push is only safe if a push with nothing to publish is a
# no-op. Without the existence check the job fails on every push after a
# release, and a workflow that is red by design stops being read.
is_idempotent() {
  local code; code=$(code_of "$1")
  matches "$code" 'git/ref/tags/\$want' || return 1
  matches "$code" 'already exists' || return 1
  matches "$code" 'exit 0' || return 1
}

# A tag cannot be moved once a consumer has pinned it, so an unshaped VERSION
# must never reach `git/refs` — the mistake is permanent.
refuses_an_unshaped_version() {
  local code; code=$(code_of "$1")
  matches "$code" 'grep -qE .\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$' || return 1
  matches "$code" 'refusing to create a tag' || return 1
  matches "$code" 'exit 1' || return 1
}

# Annotated, not lightweight: the tagger date is when the version was published,
# which is the first thing anyone asks when auditing what the fleet was running,
# and the one fact a lightweight tag cannot carry.
creates_an_annotated_tag() {
  local code; code=$(code_of "$1")
  matches "$code" 'git/tags' || return 1
  matches "$code" '-f type=commit' || return 1
  matches "$code" '-f object="\$GITHUB_SHA"' || return 1
}

# The exact tag IS the release. Moving it would change what a consumer already
# pinned, which is the one thing a pin is for — so nothing may force it.
never_moves_an_exact_tag() {
  local code; code=$(code_of "$1")
  ! matches "$code" 'refs/tags/\$want.*force' || return 1
  ! matches "$code" '-X PATCH .*tags/\$want' || return 1
}

# The floating major tag is the half that must move, and only forward, and only
# within its major — "the newest v5", never "the newest anything".
advances_the_major_tag() {
  local code; code=$(code_of "$1")
  matches "$code" 'major="\$\{want%%\..*\}"' || return 1
  matches "$code" 'tags/\$major' || return 1
  matches "$code" '-F force=true' || return 1
}

check() { # <predicate> <description>
  if "$1" "$WORKFLOW"; then ok; else bad "$2"; fi
}

echo "publish-tag self-test:"
check runs_on_every_main_push       "the workflow does not run on every push to main"
check can_write_tags                "the workflow cannot write tags"
check is_idempotent                 "a push with nothing to publish is not a no-op"
check refuses_an_unshaped_version   "an unshaped VERSION is not refused"
check creates_an_annotated_tag      "the tag is not annotated"
check never_moves_an_exact_tag      "a published exact tag can be moved"
check advances_the_major_tag        "the floating major tag is not advanced"

mutate() { # <description> <sed-program> <predicate> — predicate must go false
  local desc="$1" prog="$2" pred="$3" tmp
  tmp=$(mktemp)
  sed "$prog" "$WORKFLOW" >"$tmp"
  if "$pred" "$tmp"; then bad "mutation not detected: $desc"; else ok; fi
  rm -f "$tmp"
}

mutate "trigger narrowed to VERSION changes" \
  's|^    branches: \[main\]$|    branches: [main]\n    paths: [VERSION]|' runs_on_every_main_push
mutate "trigger left the default branch" \
  's|branches: \[main\]|branches: [release]|'                            runs_on_every_main_push
mutate "token downgraded to read" \
  's|contents: write|contents: read|'                                    can_write_tags
mutate "existence check dropped" \
  's|git/ref/tags/\$want|git/ref/tags/nothing|'                          is_idempotent
mutate "shape guard dropped" \
  's|grep -qE|grep -cE|'                                                 refuses_an_unshaped_version
mutate "refusal downgraded to a warning" \
  's|refusing to create a tag|creating a tag|'                           refuses_an_unshaped_version
mutate "lightweight tag instead of annotated" \
  's|-f type=commit||'                                                   creates_an_annotated_tag
mutate "tag object points at the wrong commit" \
  's|-f object="\$GITHUB_SHA"|-f object="$SOME_OTHER_SHA"|'              creates_an_annotated_tag
mutate "the exact tag is force-moved" \
  's|^          sha=.*|          gh api -X PATCH "repos/$GITHUB_REPOSITORY/git/refs/tags/$want" -F force=true|' never_moves_an_exact_tag
mutate "major tag no longer derived from VERSION" \
  's|want%%|hardcoded_major_ignoring_|'                                  advances_the_major_tag
mutate "major tag can no longer move forward" \
  's|-F force=true|-F force=false|'                                      advances_the_major_tag

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
