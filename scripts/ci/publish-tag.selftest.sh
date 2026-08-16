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
RELEASE="$HERE/../../.github/workflows/release-tag.yml"

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

# "Force" and "forward" are not the same thing, and only the second is safe.
# A force-patch to whatever VERSION says follows VERSION BACKWARDS on a revert or
# a bad cherry-pick, and for the floating tag that is a silent fleet-wide
# downgrade: it arrives at every consumer on its next apply, with no pull request
# anywhere and nothing red. Now that every repository pins `?ref=v5`, this is the
# single highest-blast-radius line in the repository.
never_moves_the_major_backwards() {
  local code; code=$(code_of "$1")
  matches "$code" 'contents/VERSION\?ref=\$major' || return 1
  matches "$code" 'sort -V' || return 1
  matches "$code" 'BACKWARDS' || return 1
  # And an unreadable current version must not be the one path that permits it.
  matches "$code" 'refusing to move it blind' || return 1
}

# Running on every push means most runs have nothing to do, and the PATCH that
# moves the floating tag is the ONLY call in the workflow needing write access to
# a tag ref. On 2026-08-15 six consecutive runs went red on a 403 from it — five
# of them writing the object the ref already held, over releases that had already
# been published correctly. A write that cannot change anything must not be
# attempted: a release workflow red for a write nobody needed is red in the way
# that stops anyone reading it, and the sixth failure looked exactly like the
# five.
skips_a_pointless_move() {
  local code; code=$(code_of "$1")
  matches "$code" '\[ "\$at" = "\$sha" \]' || return 1
  matches "$code" 'nothing to move' || return 1
}

# That 403 was transient: the same call, with the same token, against the same
# ref, at the same target, succeeded twelve seconds before the window opened and
# again seventy minutes after it closed, with no repository setting that any API
# shows changing in between. One attempt is not evidence that a release is
# broken — and a failure message without the API's own words is not evidence of
# anything at all, which is why the diagnosis cost a day.
retries_a_failed_write() {
  local code; code=$(code_of "$1")
  matches "$code" 'retry_api\(\) \{' || return 1
  matches "$code" 'sleep \$\(\(attempt' || return 1
  matches "$code" 'of 3 failed: \$\(tr' || return 1
  matches "$code" 'retry_api -X PATCH' || return 1
}

# The exact tag was created SECONDS ago, by the previous step, and reading it
# back is what tells this step where to point the floating major. On 2026-08-16
# that read returned `Not Found` for a tag `git ls-remote` showed present the
# whole time: read-after-write on the refs API is not immediate.
#
# Unretried, that 404 fails the release AFTER the exact tag is published, which
# is the single worst state this workflow can leave behind — v5.16.0 out, `v5`
# still on v5.15.0, every consumer pinning the floating major silently resolving
# yesterday's source, and the only thing saying so a red run on a workflow
# nobody watches when the tag they wanted exists.
#
# The ordering half is not pedantry: `retry_api` is defined inside this step's
# script, and a read placed above the definition is `command not found` — which
# in a `set -uo pipefail` script without `-e` is a non-zero return that lands in
# the `|| { exit 1 }` branch and reports the tag as missing. Same red run, and a
# completely misleading message.
reads_the_new_tag_with_a_retry() {
  local code def use
  code=$(code_of "$1")
  matches "$code" 'sha=\$\(retry_api "repos/\$GITHUB_REPOSITORY/git/ref/tags/\$want"' || return 1
  ! matches "$code" 'sha=\$\(gh api' || return 1

  def=$(printf '%s\n' "$code" | grep -n '^ *retry_api() {' | head -1 | cut -d: -f1)
  use=$(printf '%s\n' "$code" | grep -n 'sha=\$(retry_api' | head -1 | cut -d: -f1)
  [ -n "$def" ] && [ -n "$use" ] && [ "$def" -lt "$use" ]
}

# The write reporting success and the tag actually pointing somewhere are two
# facts, and only the second one reaches consumers. Nobody looks at the floating
# tag again until a `terraform apply` resolves it, so a 200 that did not land —
# or a concurrent run that repointed it in between — is indistinguishable from a
# published release right up to the moment it is in the fleet.
reads_the_tag_back() {
  local code; code=$(code_of "$1")
  matches "$code" 'now=\$\(retry_api "repos/\$GITHUB_REPOSITORY/git/ref/tags/\$major"' || return 1
  matches "$code" '\[ "\$now" != "\$sha" \]' || return 1
  matches "$code" 'did not land' || return 1
}

# Everything here is idempotent, so the answer to a failed release is to run it
# again. Without a manual trigger the only way to run it again is to push a
# commit to main — a release-shaped act performed for a non-release reason — and
# re-running the failed run works only while the run is still retained.
can_be_re_run_by_hand() {
  local code; code=$(code_of "$1")
  matches "$code" '^  workflow_dispatch:' || return 1
}

# ...and a manual trigger lets the caller pick the ref, while every step here
# publishes a tag AT THE COMMIT IT RUNS ON. Dispatched from a feature branch it
# would create the tag that branch's VERSION names at an unmerged commit —
# permanently, since a published exact tag is never moved — and every consumer
# pinning it would get code that never passed the queue. The lever that recovers
# a release must not also be the lever that publishes one from anywhere.
refuses_a_release_off_the_default_branch() {
  local code; code=$(code_of "$1")
  matches "$code" "if: github\.ref != 'refs/heads/main'" || return 1
  matches "$code" 'runs on the default branch only' || return 1
}

# release-tag.yml asserts a pushed tag equals VERSION. The floating major tag is
# by construction never equal to VERSION, so a `v*` trigger makes every
# successful release produce a failing run — and a check that is red on every
# release is worse than no check, because it trains everyone to ignore the one
# signal that says a tag sits at the wrong commit.
release_check_ignores_the_floating_tag() {
  local code; code=$(code_of "$1")
  matches "$code" "tags: \['v\*\.\*\.\*'\]" || return 1
  ! matches "$code" "tags: \['v\*'\]" || return 1
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
check never_moves_the_major_backwards "the floating major tag can be moved backwards"
check skips_a_pointless_move        "a move that cannot change anything is attempted anyway"
check retries_a_failed_write        "a single transient API failure fails the release, silently"
check reads_the_new_tag_with_a_retry "the just-published tag is read once, or read before retry_api exists — a slow refs API turns a good release into a stranded floating tag"
check reads_the_tag_back            "the tag is not read back, so a write that did not land passes"
check can_be_re_run_by_hand         "a failed release cannot be re-driven without pushing to main"
check refuses_a_release_off_the_default_branch \
                                    "a manual run from a feature branch would publish a tag at an unmerged commit"

[ -f "$RELEASE" ] || { echo "FAIL: missing $RELEASE"; exit 1; }
if release_check_ignores_the_floating_tag "$RELEASE"; then ok
else bad "release-tag.yml fires on the floating major tag and will fail on every release"; fi

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
mutate "direction guard dropped, force-patch left in place" \
  's|sort -V|cat|'                                                       never_moves_the_major_backwards
mutate "the current version is no longer read from the tag" \
  's|contents/VERSION?ref=\$major|contents/VERSION|'                     never_moves_the_major_backwards
mutate "an unreadable current version fails open" \
  's|refusing to move it blind|continuing anyway|'                       never_moves_the_major_backwards
mutate "the already-there check no longer compares against the tag being published" \
  's|\[ "\$at" = "\$sha" \]|[ "$at" = "something-else" ]|'               skips_a_pointless_move
mutate "the no-op falls through to the write anyway" \
  's|nothing to move|moving it regardless|'                              skips_a_pointless_move
mutate "the retry wrapper is bypassed" \
  's|retry_api|gh_api_once|'                                             retries_a_failed_write
mutate "the backoff between attempts is dropped" \
  's|^ *sleep .*|              :|'                                       retries_a_failed_write
mutate "the API answer no longer reaches the log" \
  's|of 3 failed: \$(tr|of 3 failed. #|'                                 retries_a_failed_write
# SC2016 off: `$(` and `$GITHUB_REPOSITORY` are matched LITERALLY in the
# workflow source. Expanding them in the shell would make the sed match nothing,
# and a mutation that changes nothing always goes false — reporting a pass.
# shellcheck disable=SC2016
mutate "the just-created tag is read once, without the retry" \
  's|sha=$(retry_api "repos/$GITHUB_REPOSITORY/git/ref/tags/$want"|sha=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$want"|' reads_the_new_tag_with_a_retry
# shellcheck disable=SC2016
mutate "retry_api is no longer defined above the read that calls it" \
  's|^          retry_api() {|          moved_later_retry_api() {|'      reads_the_new_tag_with_a_retry
mutate "the tag is no longer read back after the write" \
  's|^          now=\$(retry_api|          unused=$(retry_api|'          reads_the_tag_back
mutate "a write that did not land is accepted" \
  's|did not land|landed|'                                               reads_the_tag_back
mutate "the manual re-run lever is removed" \
  's|^  workflow_dispatch:||'                                            can_be_re_run_by_hand
mutate "the branch guard is widened past the default branch" \
  's|refs/heads/main|refs/heads/anything|'                               refuses_a_release_off_the_default_branch
mutate "the branch guard can never fire" \
  's|^        if: github.ref != .*|        if: false|'                   refuses_a_release_off_the_default_branch

mutate_file() { # <description> <file> <sed-program> <predicate> — predicate must go false
  local desc="$1" f="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
  sed "$prog" "$f" >"$tmp"
  if "$pred" "$tmp"; then bad "mutation not detected: $desc"; else ok; fi
  rm -f "$tmp"
}

mutate_file "release check widened back to every v* tag" "$RELEASE" \
  "s|tags: \['v\*\.\*\.\*'\]|tags: ['v*']|" release_check_ignores_the_floating_tag

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
