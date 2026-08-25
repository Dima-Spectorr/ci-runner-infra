#!/usr/bin/env bash
# Structural self-test for the merge lane's workflows and API driver.
#
# `merge-lane-decision.selftest.sh` next door holds every DECISION the lane
# makes, on pure functions, with 55 cases. This file covers what that one
# cannot: the wiring. A `workflow_run` workflow is dispatched only from the
# default branch, and the API driver only ever talks to GitHub — so neither can
# be executed by the pull request that changes them, and the first live run of a
# change here is the first CI completion after it merges.
#
# That is a property of the trigger, not a gap in the testing, and it is why
# these assertions are made on the TEXT, with mutations. A property that is
# silently removed has to fail a check that can actually run on a pull request,
# because the alternative is finding out when the lane merges something it
# should not have.
#
# The weighting is by blast radius. This is the only machinery in the repository
# that lands code on the default branch, so the properties asserted hardest are
# the ones whose loss would let it merge something unverified, merge as the
# wrong identity, or merge two things at once.
#
# Every pattern below matches the TEXT of a workflow or a script, in which
# `${{ ... }}` and `$sha` are the literal characters that have to be there.
# Single quotes are the point, not an oversight.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

CALLEE="$ROOT/.github/workflows/merge-lane.yml"
CALLER="$ROOT/.github/workflows/merge-lane-self.yml"
DRIVER="$ROOT/scripts/ci/merge-lane.sh"
DECISION="$ROOT/scripts/ci/merge-lane-decision.sh"
CI="$ROOT/.github/workflows/ci.yml"
DOC="$ROOT/docs/merge-lane.md"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

for f in "$CALLEE" "$CALLER" "$DRIVER" "$DECISION" "$CI" "$DOC"; do
  [ -f "$f" ] || {
    printf 'FAIL: missing %s — every check below would be vacuous\n' "$f"
    exit 1
  }
done

# Code only: full-line comments stripped, so the long rationale above each
# property can never be what satisfies the check for that property. Both
# workflows argue for these properties at length in prose, which is exactly the
# material that would make a naive grep pass over a file that lost them.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `… | grep -q` under `set -o pipefail`: grep exits on the first match,
# the writer takes SIGPIPE, and a successful match is reported as a failure.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# The callee: how the lane is wired
# ---------------------------------------------------------------------------

# A callee with a second trigger would run on its own account, holding merge
# authority, with none of the caller's inputs set.
is_reusable_only() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  workflow_call:' || return 1
  ! matches "$code" '^  (pull_request|push|schedule|workflow_run|workflow_dispatch):'
}

# THE IDENTITY PROPERTY. A merge or a branch update performed with the built-in
# `GITHUB_TOKEN` triggers no further workflow — the re-run the lane depends on
# would never start, and every release and deploy workflow that fires on a push
# to the default branch would silently stop firing. It does not fail; it quietly
# does half the job, which is why it needs a test rather than a comment.
acts_as_the_app() {
  local code
  code=$(code_of "$1")
  matches "$code" 'uses: actions/create-github-app-token@[0-9a-f]{40}' || return 1
  matches "$code" 'GH_TOKEN: \$\{\{ steps\.token\.outputs\.token \}\}' || return 1
  ! matches "$code" 'GH_TOKEN: \$\{\{ (secrets\.GITHUB_TOKEN|github\.token) \}\}'
}

# The checkout must not leave a credential on disk that later steps could push
# with, and the built-in token must never hold write to contents here: the App
# token is the only write path, and having two is how the wrong one gets used.
never_writes_as_itself() {
  local code
  code=$(code_of "$1")
  matches "$code" '^          persist-credentials: false$' || return 1
  ! matches "$code" '^      contents: write$'
}

# Two lanes running at once against one base is two merges racing, each computed
# against a world the other is changing. `cancel-in-progress: false` is the
# other half: cancelling a lane mid-merge is how a branch gets updated and then
# abandoned.
serialises() {
  local code
  code=$(code_of "$1")
  matches "$code" '^    concurrency:' || return 1
  matches "$code" '^      group: merge-lane-' || return 1
  matches "$code" '^      cancel-in-progress: false$'
}

# An unbounded loop against a repository that keeps producing candidates is a
# job that never ends while holding the lane's lock.
is_bounded() {
  local code
  code=$(code_of "$1")
  matches "$code" '^    timeout-minutes: [0-9]+$' || return 1
  matches "$code" '^        default: [0-9]+$'
}

# `${{ }}` is spliced in before the shell parses the line, and this job holds a
# token that can merge. Everything reaches the shell as an environment variable.
keeps_expressions_out_of_the_shell() {
  local body
  body=$(sed -n '/^        run: /,$p' "$1")
  ! matches "$body" '\$\{\{'
}

# A lane told to require nothing would merge on no evidence. The input is
# mandatory at the schema level so a consumer cannot omit it by accident.
demands_its_gate() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      required-checks:' || return 1
  matches "$code" '^        required: true$'
}

# Logic in YAML is logic that ships untested, for the reason at the top of this
# file. The callee must delegate rather than grow a decision of its own.
delegates_the_decision() {
  local code
  code=$(code_of "$1")
  matches "$code" '^        run: bash scripts/ci/merge-lane\.sh$'
}

# ---------------------------------------------------------------------------
# The caller: what fires the lane
# ---------------------------------------------------------------------------

triggers_on_ci_completion() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  workflow_run:' || return 1
  matches "$code" '^    workflows: \[CI\]' || return 1
  matches "$code" '^    types: \[completed\]'
}

# A merge moves the base, which makes every other open pull request one commit
# behind — and that is not a CI completion, so nothing would dispatch the lane
# to notice. The sweep is the only thing that recovers a missed dispatch.
has_a_backstop_sweep() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  schedule:' || return 1
  matches "$code" '^    - cron:'
}

# Fail-safe in the direction that does not merge: anything other than the exact
# arming value leaves the lane in dry run.
arms_deliberately() {
  local code
  code=$(code_of "$1")
  matches "$code" "dry-run: \\\$\{\{ vars\.MERGE_LANE_ARMED != 'true' \}\}"
}

passes_the_app_credentials() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      app-id: \$\{\{ secrets\.' || return 1
  matches "$code" '^      app-private-key: \$\{\{ secrets\.'
}

# ---------------------------------------------------------------------------
# The driver: what it does with a verdict
# ---------------------------------------------------------------------------

# THE RACE. Every check was read against one head sha; a push that lands while
# the pass is running must make the call FAIL rather than merge code that
# nothing verified. Mergify closed this by owning the queue. We own it now, so
# we close it explicitly.
merges_only_the_sha_it_verified() {
  local code
  code=$(code_of "$1")
  matches "$code" 'pulls/\$action_num/merge' || return 1
  matches "$code" '\-f sha="\$action_sha"' || return 1
  matches "$code" '\-f expected_head_sha="\$action_sha"'
}

# A required check that skipped itself produced no verdict on this diff.
# Counting `neutral` or `skipped` as success is how a lane merges something
# nothing actually checked — and it is the single easiest mistake to make here,
# because GitHub's own UI renders both as not-a-failure.
treats_a_non_verdict_as_a_failure() {
  local code
  code=$(code_of "$1")
  ! matches "$code" '^ *success \| (neutral|skipped)\)'
}

# Both surfaces, because a required context may be a legacy commit status rather
# than a check-run, and a lane that only read check-runs would count a green
# status as missing and never merge anything.
reads_both_check_surfaces() {
  local code
  code=$(code_of "$1")
  matches "$code" 'commits/\$sha/check-runs' || return 1
  matches "$code" 'commits/\$sha/status'
}

# A dry run still mints the App token, so a caller wired before the App exists
# fails on every CI completion on the default branch. That red is
# indistinguishable from a broken lane, which is the one signal that has to stay
# meaningful — so the caller stays switched off until an operator says the App
# is there.
waits_for_the_app_to_exist() {
  local code
  code=$(code_of "$1")
  matches "$code" "^ *if: vars.MERGE_LANE_ENABLED == 'true'$"
}

# A reusable workflow's `actions/checkout` clones the CALLER. Without an
# explicit repository the lane would look for its own driver in the consumer's
# tree, where it does not exist — a failure every consumer hits and this
# repository never does, because here caller and callee are the same repo.
checks_out_its_own_implementation() {
  local code
  code=$(code_of "$1")
  matches "$code" 'repository: \$\{\{ inputs.implementation-repository \}\}' || return 1
  matches "$code" 'ref: \$\{\{ inputs.implementation-ref \}\}'
}

# Every list endpoint the lane reads is paginated. Unpaginated, a required check
# past the first page reads as ABSENT and the lane declines a green pull
# request; an open pull request past the first page is invisible forever.
reads_every_page() {
  local code
  code=$(code_of "$1")
  matches "$code" 'gh api --paginate "repos/\$R/commits/\$sha/check-runs' || return 1
  matches "$code" 'gh api --paginate "repos/\$R/commits/\$sha/status' || return 1
  matches "$code" 'gh api --paginate "repos/\$R/pulls\?state=open'
}

# `behind_by` is the only fact that makes this a queue. A failed comparison must
# not read as zero: zero means "current with the base", which is precisely the
# answer that lets a merge through on evidence the lane never gathered.
fails_closed_on_an_unreadable_comparison() {
  local code
  code=$(code_of "$1")
  matches "$code" 'if ! behind=' || return 1
  matches "$code" 'wait:base-comparison-unreadable' || return 1
  # And the old shape must be gone: a fallback assignment of 0 anywhere near
  # `behind` re-opens it silently.
  ! matches "$code" '\|\| behind=0'
}

# AN UNLABELLED PULL REQUEST IS THE ORDINARY CASE.
#
# `@tsv` piped into `IFS=$'\t' read -r a b c` looks exact and is not: tab is IFS
# *whitespace*, so bash collapses the two adjacent tabs an empty `labels` field
# produces, the head sha lands in `labels`, and `sha` comes out EMPTY. Every
# later call then addresses `.../compare/main...` and the lane can act on no
# unlabelled pull request, ever. Seen live on the first dry run, where it
# presented as `wait:base-comparison-unreadable` and read as a transient.
reads_the_detail_without_collapsing_an_empty_field() {
  local code
  code=$(code_of "$1")
  matches "$code" 'mapfile -t detail_lines' || return 1
  matches "$code" '\$\{#detail_lines\[@\]\}" -ne 3' || return 1
  ! matches "$code" 'read -r mergeable labels sha'
}

# ...and it must say WHY. A permanent cause — a missing App permission, or the
# field-collapse defect above building a URL with no sha in it — emits exactly
# the same line as a transient 5xx, every fifteen minutes, forever. A
# fail-closed verdict with no diagnostic is a lane that is stuck and cannot tell
# anyone; that is how the field-collapse defect stayed hidden.
reports_why_the_comparison_failed() {
  local code
  code=$(code_of "$1")
  matches "$code" '2>"\$cmp_err"' || return 1
  matches "$code" 'compare said:'
}

# `sha=` pins the head; nothing in the merge API pins the base. A push to the
# base between the comparison and the merge lands a head verified against a
# base that no longer exists, and the concurrency group does not help — it
# serialises merge-lane runs, not humans.
refuses_a_base_that_moved() {
  local code
  code=$(code_of "$1")
  matches "$code" 'base_sha=' || return 1
  matches "$code" 'base_now=' || return 1
  matches "$code" '\[ "\$base_now" != "\$base_sha" \]'
}

# A dropped pull request stays open and keeps its verdict, so without a
# per-sha record the lane re-announces the same release on every pass and every
# scheduled sweep, forever.
announces_a_release_once() {
  local code
  code=$(code_of "$1")
  matches "$code" 'merge-lane:released:' || return 1
  matches "$code" 'already_released "\$num" "\$sha"'
}

# Empty configuration must stop the lane, not open it.
fails_closed_on_empty_configuration() {
  local code
  code=$(code_of "$1")
  matches "$code" 'if \[ "\$\{#REQUIRED\[@\]\}" -eq 0 \]' || return 1
  matches "$code" '^  exit 1$'
}

# ---------------------------------------------------------------------------
# The join: the checks the caller names must be checks that exist
# ---------------------------------------------------------------------------
#
# A renamed CI job makes the lane count that check as MISSING, and the lane then
# declines every pull request in the repository — the safe direction, but a
# total stop discovered only after the rename merges. This is the check that
# turns it into a red job on the pull request that does the renaming.
required_checks_all_exist_in_ci() {
  local ci_names name
  ci_names="$(grep -E "^    name: " "$CI" | sed 's/^    name: //')"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # `grep -c … >/dev/null`, never `grep -Fxq`: the quiet form exits on its
    # first match, the writer takes EPIPE, and pipefail then reports a pipeline
    # that FOUND its text as a failure.
    printf '%s\n' "$ci_names" | grep -cFx -- "$name" >/dev/null || return 1
  done < <(sed -n '/^      required-checks: |/,/^      [a-z-]*:/p' "$CALLER" |
    sed -e '1d' -e '$d' -e 's/^        //' | grep -v '^ *#' | grep -v '^$')
}

check() { # <predicate> <file> <description>
  if "$1" "$2"; then ok; else bad "$3"; fi
}

# THE DOCUMENTED PIN AND THE DOCUMENTED REF MUST BE THE SAME COMMIT.
#
# `docs-pins.selftest.sh` checks the `uses:` line against VERSION and stops
# there, because for every other workflow in this repository the pin is the
# whole story. The lane is the exception: a reusable workflow's
# `actions/checkout` clones the CALLER, so the lane is additionally told where
# its own driver lives, and `implementation-ref` is a second, unchecked sha
# sitting eight lines below the first.
#
# Bump one and not the other and a consumer runs one release's decision logic
# under another release's wiring. Nothing fails; the lane just behaves like a
# version nobody is looking at. The doc says the two must agree — that sentence
# is a comment, and this is the gate.
pins_agree_in_the_documented_example() {
  local doc="$1" pin ref
  pin=$(grep -oE 'merge-lane\.yml@[0-9a-f]{40}' "$doc" | head -1 | cut -d@ -f2)
  ref=$(grep -oE 'implementation-ref: [0-9a-f]{40}' "$doc" | head -1 | awk '{print $2}')
  [ -n "$pin" ] && [ -n "$ref" ] && [ "$pin" = "$ref" ]
}

echo "merge-lane self-test:"
check pins_agree_in_the_documented_example "$DOC" "the documented uses: pin and implementation-ref are different commits, so a consumer copying them runs one release's driver under another release's workflow"
check is_reusable_only "$CALLEE" "the callee has a trigger other than workflow_call, so it can run holding merge authority with no inputs set"
check acts_as_the_app "$CALLEE" "the lane does not act as the merge App, so its merges and updates trigger no downstream workflow"
check never_writes_as_itself "$CALLEE" "the built-in token can write, so there are two write paths and the wrong one can be used"
check serialises "$CALLEE" "the lane does not serialise, so two runs can merge against a world the other is changing"
check is_bounded "$CALLEE" "the lane is unbounded, so one run can hold the lock indefinitely"
check keeps_expressions_out_of_the_shell "$CALLEE" "an expression is interpolated into the shell of a job that can merge"
check demands_its_gate "$CALLEE" "required-checks is optional, so a consumer can wire a lane that merges on no evidence"
check delegates_the_decision "$CALLEE" "the callee decides something itself, in YAML, where no pull request can test it"
check checks_out_its_own_implementation "$CALLEE" "the checkout takes the caller's tree, so every consumer's lane dies looking for a driver that is not there"

check triggers_on_ci_completion "$CALLER" "the caller does not fire on a completed CI run, which is the entire fast path"
check has_a_backstop_sweep "$CALLER" "there is no sweep, so a pull request needing only an update waits for an event that never comes"
check arms_deliberately "$CALLER" "the lane is not armed by an explicit variable, so it cannot be landed in dry run"
check passes_the_app_credentials "$CALLER" "the caller does not pass App credentials, so the lane cannot authenticate"
check waits_for_the_app_to_exist "$CALLER" "the caller runs before an operator confirms the App exists, so it goes red on every CI completion and that red stops meaning anything"

check merges_only_the_sha_it_verified "$DRIVER" "the merge is not conditional on the verified sha, so a push mid-pass merges unverified code"
check treats_a_non_verdict_as_a_failure "$DRIVER" "a skipped or neutral required check counts as success, so the lane merges what nothing checked"
check reads_both_check_surfaces "$DRIVER" "only one check surface is read, so a required commit status can never be satisfied"
check fails_closed_on_empty_configuration "$DRIVER" "empty configuration does not stop the lane"
check reads_every_page "$DRIVER" "a list endpoint is read unpaginated, so a required check or a whole pull request can be invisible"
check fails_closed_on_an_unreadable_comparison "$DRIVER" "a failed base comparison reads as up-to-date, which is the one answer that lets a merge through"
check reads_the_detail_without_collapsing_an_empty_field "$DRIVER" "an unlabelled pull request loses its head sha to field collapsing, so the lane can never act on one"
check reports_why_the_comparison_failed "$DRIVER" "a base comparison fails closed without logging the cause, so a permanent block looks like a transient one forever"
check refuses_a_base_that_moved "$DRIVER" "the base tip is not re-checked before acting, so a push to the base merges a head verified against a base that is gone"
check announces_a_release_once "$DRIVER" "a release is not recorded per sha, so the lane re-comments on every pass and every sweep"

if required_checks_all_exist_in_ci; then ok; else
  bad "a check named in the caller's required-checks does not match any job name in ci.yml — the lane would count it missing and decline every pull request"
fi

# ---------------------------------------------------------------------------
# Mutations — each predicate must be load-bearing, not merely satisfied
# ---------------------------------------------------------------------------
mutate() { # <description> <file> <sed-program> <predicate> — predicate must go false
  local desc="$1" f="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
  sed "$prog" "$f" >"$tmp"
  if cmp -s "$tmp" "$f"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
  elif "$pred" "$tmp"; then
    bad "mutation not detected: $desc"
  else
    ok
  fi
  rm -f "$tmp"
}

mutate "the callee grows a pull_request trigger" "$CALLEE" \
  's|^  workflow_call:|  pull_request:\n  workflow_call:|' is_reusable_only
mutate "the lane falls back to the built-in token" "$CALLEE" \
  's@GH_TOKEN: .*steps\.token\.outputs\.token.*@GH_TOKEN: ${{ github.token }}@' acts_as_the_app
mutate "the App token step is dropped" "$CALLEE" \
  's|uses: actions/create-github-app-token@|uses: actions/nope@|' acts_as_the_app
mutate "the checkout starts persisting credentials" "$CALLEE" \
  's|^          persist-credentials: false$|          persist-credentials: true|' never_writes_as_itself
mutate "the job grants itself contents: write" "$CALLEE" \
  's|^      contents: read$|      contents: write|' never_writes_as_itself
mutate "the lane stops serialising" "$CALLEE" \
  's|^    concurrency:|    x-concurrency:|' serialises
mutate "in-flight lanes become cancellable" "$CALLEE" \
  's|^      cancel-in-progress: false$|      cancel-in-progress: true|' serialises
mutate "the job timeout is removed" "$CALLEE" \
  's|^    timeout-minutes: 15$|    x: 15|' is_bounded
mutate "required-checks becomes optional" "$CALLEE" \
  's|^        required: true$|        required: false|' demands_its_gate
mutate "the callee inlines a decision instead of delegating" "$CALLEE" \
  's|^        run: bash scripts/ci/merge-lane\.sh$|        run: gh pr merge --squash|' delegates_the_decision
mutate "the checkout reverts to the caller's tree" "$CALLEE" \
  's@^          repository: .*@          fetch-depth: 0@' checks_out_its_own_implementation
mutate "the implementation ref stops being pinnable" "$CALLEE" \
  's@^          ref: .*inputs.implementation-ref.*@          ref: main@' checks_out_its_own_implementation

mutate "the caller stops listening to CI" "$CALLER" \
  's|^    workflows: \[CI\]|    workflows: [Something Else]|' triggers_on_ci_completion
mutate "the backstop sweep is removed" "$CALLER" \
  's|^  schedule:|  x-schedule:|' has_a_backstop_sweep
mutate "the lane is armed unconditionally" "$CALLER" \
  's@dry-run: .*MERGE_LANE_ARMED.*@dry-run: false@' arms_deliberately
mutate "the caller runs before the App is provisioned" "$CALLER" \
  "s@^    if: vars.MERGE_LANE_ENABLED == 'true'\$@    name: lane@" waits_for_the_app_to_exist
mutate "the private key stops being passed" "$CALLER" \
  's@^      app-private-key: .*@      app-private-key: literal-key@' passes_the_app_credentials

mutate "the merge stops pinning the verified sha" "$DRIVER" \
  's|-f sha="\$action_sha"|-f merge_method=squash|' merges_only_the_sha_it_verified
mutate "the branch update stops pinning the expected head" "$DRIVER" \
  's|-f expected_head_sha="\$action_sha"|--silent|' merges_only_the_sha_it_verified
mutate "skipped is folded into success" "$DRIVER" \
  's@^      success) green=@      success | skipped) green=@' treats_a_non_verdict_as_a_failure
mutate "the commit-status surface is dropped" "$DRIVER" \
  's|commits/\$sha/status|commits/$sha/nothing|' reads_both_check_surfaces
mutate "the empty-configuration guard is removed" "$DRIVER" \
  's%^if \[ "..#REQUIRED\[@\]." -eq 0 \]; then%if false; then%' fails_closed_on_empty_configuration
mutate "the check-run read stops paginating" "$DRIVER" \
  's@gh api --paginate "repos/\$R/commits/\$sha/check-runs@gh api "repos/$R/commits/$sha/check-runs@' reads_every_page
mutate "the pull request list stops paginating" "$DRIVER" \
  's@gh api --paginate "repos/\$R/pulls?state=open@gh api "repos/$R/pulls?state=open@' reads_every_page
mutate "an unreadable comparison falls back to up-to-date" "$DRIVER" \
  's@^    if ! behind=@    behind=0; if false; behind=@' fails_closed_on_an_unreadable_comparison

mutate "the detail read goes back to a tab split" "$DRIVER" \
  's@^    mapfile -t detail_lines@    IFS=$'"'"'\\t'"'"' read -r mergeable labels sha; mapfile -t detail_lines@' \
  reads_the_detail_without_collapsing_an_empty_field

mutate "the comparison error is swallowed again" "$DRIVER" \
  's@2>"\$cmp_err"@2>/dev/null@' reports_why_the_comparison_failed
mutate "the moved-base guard is removed" "$DRIVER" \
  's@\[ "\$base_now" != "\$base_sha" \]@false@' refuses_a_base_that_moved
mutate "the release stops being recorded per sha" "$DRIVER" \
  's@merge-lane:released:@merge-lane-released@' announces_a_release_once

if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane: $FAIL failed, $PASS passed"
  exit 1
fi
echo "merge-lane: $PASS checks pass"
