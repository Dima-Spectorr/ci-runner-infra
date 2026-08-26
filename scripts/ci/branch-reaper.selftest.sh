#!/usr/bin/env bash
# Structural self-test for the branch reaper's workflows and API driver.
#
# `branch-reaper-decision.selftest.sh` next door holds every DECISION the reaper
# makes, on pure functions, with 26 cases. This file covers what that one cannot:
# the wiring. A `schedule` workflow is dispatched only from the default branch,
# and the driver only ever talks to GitHub — so neither can be executed by the
# pull request that changes them, and the first live run of a change here is the
# next scheduled run after it merges.
#
# That is a property of the trigger, not a gap in the testing, and it is why
# these assertions are made on the TEXT, with mutations. A property silently
# removed has to fail a check that can actually run on a pull request, because
# the alternative is finding out when the reaper deletes a branch it should not
# have — and unlike a bad merge, that is not something you revert.
#
# THE WEIGHTING IS INVERTED RELATIVE TO THE MERGE LANE'S SELF-TEST. There the
# properties defended hardest are the ones whose loss lets something merge. Here
# they are the ones whose loss lets something be DESTROYED: the dry-run default,
# the deletion cap, the fail-closed index read, and the fact that every verdict
# comes from the tested decision function rather than from this half.
#
# Every pattern below matches the TEXT of a workflow or a script, in which
# `${{ ... }}` and `$branch` are the literal characters that have to be there.
# Single quotes are the point, not an oversight.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

CALLEE="$ROOT/.github/workflows/branch-reaper.yml"
CALLER="$ROOT/.github/workflows/branch-reaper-self.yml"
DRIVER="$ROOT/scripts/ci/branch-reaper.sh"
DECISION="$ROOT/scripts/ci/branch-reaper-decision.sh"
CI="$ROOT/.github/workflows/ci.yml"
DOC="$ROOT/docs/branch-reaper.md"

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
# property can never be what satisfies the check for that property. Both files
# argue for these properties at length in prose, which is exactly the material
# that would make a naive grep pass over a file that lost them.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `… | grep -q` under `set -o pipefail`: grep exits on the first match,
# the writer takes SIGPIPE, and a successful match is reported as a failure.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# OCCURRENCES, not matching lines. `grep -c` counts lines, and the six report
# fields are guarded on one line — a line count would report 1 and the check
# would then pass over a row that had lost five of its guards.
count_of() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -oE -- "$2" | grep -c '')
  printf '%s' "${n:-0}"
}

# ---------------------------------------------------------------------------
# The callee: how the reaper is wired
# ---------------------------------------------------------------------------

# A callee with a second trigger would run on its own account, holding delete
# authority, with none of the caller's inputs set — including `dry-run`, whose
# schema default is the only thing then standing between it and the repository.
is_reusable_only() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  workflow_call:' || return 1
  ! matches "$code" '^  (pull_request|push|schedule|workflow_run|workflow_dispatch):'
}

# THE SAFETY DEFAULT, AND THE ONE PROPERTY THIS FILE EXISTS FOR.
#
# The merge lane's `dry-run` defaults to FALSE, because a lane that has to be
# switched on merges nothing and that is a visible, harmless failure. This one
# defaults to TRUE, because the equivalent slip here is not harmless. A copied
# input block that brought the lane's default along would produce a workflow
# that reads exactly like this one and deletes branches on its first run.
defaults_to_a_dry_run() {
  local block
  block=$(sed -n '/^      dry-run:/,/^      [a-z-]*:$/p' "$1" | grep -vE '^[[:space:]]*#')
  matches "$block" '^        default: true$' || return 1
  ! matches "$block" '^        default: false$'
}

# A cap exists at the schema level and reaches the driver. Without it, the first
# armed run against a repository nobody has ever pruned — the run most likely to
# be acting on a keep-list somebody got wrong — is also the run that deletes the
# most.
caps_the_deletions() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      max-deletions:' || return 1
  matches "$code" '^          MAX_DELETIONS: \$\{\{ inputs\.max-deletions \}\}$'
}

# Deleting a ref triggers no downstream workflow when done with the built-in
# token, but more to the point the built-in token cannot delete a protected ref
# and cannot be audited as a named actor. The App is the one write path.
# THE DRIVER'S ONLY TOOL HAS TO BE THERE BEFORE THE DRIVER RUNS.
#
# The fleet's self-hosted images do not ship `gh`, and the reaper is `gh api`
# throughout. A failed read is a keep, so the reaper does not delete anything
# wrong when the CLI is missing — it simply stops sweeping, reports success,
# and the backlog it exists to prevent grows behind a green daily run. Order is
# part of the assertion: installing the CLI after the driver is not a fix.
guarantees_the_cli_it_runs_on() {
  local code install driver
  code=$(code_of "$1")
  matches "$code" 'run: bash scripts/ci/ensure-gh\.sh' || return 1
  install=$(printf '%s\n' "$code" | grep -n 'ensure-gh\.sh' | head -1 | cut -d: -f1)
  driver=$(printf '%s\n' "$code" | grep -n 'run: bash scripts/ci/branch-reaper\.sh' | head -1 | cut -d: -f1)
  [ -n "$install" ] && [ -n "$driver" ] && [ "$install" -lt "$driver" ]
}

acts_as_the_app() {
  local code
  code=$(code_of "$1")
  matches "$code" 'uses: actions/create-github-app-token@[0-9a-f]{40}' || return 1
  matches "$code" 'GH_TOKEN: \$\{\{ steps\.token\.outputs\.token \}\}' || return 1
  ! matches "$code" 'GH_TOKEN: \$\{\{ (secrets\.GITHUB_TOKEN|github\.token) \}\}'
}

# The checkout must not leave a credential on disk, and the built-in token must
# never hold write to contents here: two write paths into a job that deletes
# refs is one too many.
never_writes_as_itself() {
  local code
  code=$(code_of "$1")
  matches "$code" '^          persist-credentials: false$' || return 1
  ! matches "$code" '^      contents: write$'
}

# Two reapers at once is two sweeps each reading a branch list the other is
# changing. `cancel-in-progress: false` is the other half: a cancelled reaper is
# one that deleted some branches and wrote no report.
serialises() {
  local code
  code=$(code_of "$1")
  matches "$code" '^    concurrency:' || return 1
  matches "$code" '^      group: branch-reaper' || return 1
  matches "$code" '^      cancel-in-progress: false$'
}

# THE TWO GROUPS MUST NOT BE THE SAME NAME.
#
# Serialising is necessary and is asserted above; serialising against YOURSELF
# is the failure this pair exists to prevent. A job cannot acquire a
# concurrency group that its own run already holds at workflow level — GitHub
# does not queue it and does not cancel the holder, it fails the job in about a
# second with no runner assigned, no steps and no log. Nothing in the run, the
# annotations or the API says "concurrency".
#
# Both halves were spelled `branch-reaper` from the cutover to 2026-08-26: the
# callee's job here, and the caller template in `docs/branch-reaper.md` that
# every consumer copied. Nine of nine consumer repositories therefore failed
# every 04:17 sweep since rollout and deleted nothing, while this repository
# passed — its own caller happens to declare no workflow-level group, which is
# also why no assertion over the files in this repository alone could have
# caught it. That is what makes this a CROSS-FILE predicate: the bug does not
# exist in either file, only between them.
#
# Checked from both sides so that either file drifting back onto the other's
# name fails, whichever one is edited.
group_of() { # <file> <indent>
  code_of "$1" | sed -n "s/^$2group: \(.*\)\$/\1/p" | head -1
}

callee_group_cannot_collide_with_a_caller() {
  local callee doc
  callee=$(group_of "$1" '      ')
  doc=$(group_of "$DOC" '  ')
  [ -n "$callee" ] && [ -n "$doc" ] && [ "$callee" != "$doc" ]
}

documented_caller_cannot_collide_with_the_callee() {
  local callee doc
  doc=$(group_of "$1" '  ')
  callee=$(group_of "$CALLEE" '      ')
  [ -n "$callee" ] && [ -n "$doc" ] && [ "$callee" != "$doc" ]
}

is_bounded() {
  local code
  code=$(code_of "$1")
  matches "$code" '^    timeout-minutes: [0-9]+$'
}

# `${{ }}` is spliced in before the shell parses the line, and `keep-patterns`
# is operator-supplied text arriving in a job that can delete refs. Everything
# reaches the shell as an environment variable.
#
# Collects every `run:` body rather than everything from the first one to the
# end of the file. The cheaper version held only while the driver step was last
# in the job: add a step above it and the range swallows the following steps'
# `env:` blocks, where an expression is exactly how a value is meant to arrive.
keeps_expressions_out_of_the_shell() {
  local body
  body=$(awk '
    /^        run:/       { inrun = 1; print; next }
    inrun && /^ {10,}/    { print; next }
    inrun && /^[[:space:]]*$/ { print; next }
                          { inrun = 0 }
  ' "$1")
  ! matches "$body" '\$\{\{'
}

# Logic in YAML is logic that ships untested, for the reason at the top of this
# file. The callee must delegate rather than grow a decision of its own.
delegates_the_decision() {
  local code
  code=$(code_of "$1")
  matches "$code" '^        run: bash scripts/ci/branch-reaper\.sh$'
}

# A reusable workflow's `actions/checkout` clones the CALLER, so a reaper that
# does not name its own repository dies in every consumer looking for a driver
# that is not in their tree.
checks_out_its_own_implementation() {
  local code
  code=$(code_of "$1")
  matches "$code" '^          repository: \$\{\{ inputs\.implementation-repository \}\}$' || return 1
  matches "$code" '^          ref: \$\{\{ inputs\.implementation-ref \|\| github\.job_workflow_sha \}\}$'
}

# Every declared knob has to actually reach the script. An input that is
# documented, accepted, and then dropped is worse than one that does not exist:
# the operator sets `min-age-days: 90` and gets 14.
passes_every_input_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" '^          MIN_AGE_DAYS: \$\{\{ inputs\.min-age-days \}\}$' || return 1
  matches "$code" '^          KEEP_PATTERNS: \$\{\{ inputs\.keep-patterns \}\}$' || return 1
  matches "$code" '^          DRY_RUN: \$\{\{ inputs\.dry-run \}\}$'
}

# ---------------------------------------------------------------------------
# The caller: what fires the reaper
# ---------------------------------------------------------------------------

runs_on_a_schedule() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  schedule:' || return 1
  matches "$code" "^    - cron: '"
}

# The only way an operator reads a verdict before the next daily run, and how
# the dry-run report is read during cutover.
can_be_run_on_demand() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  workflow_dispatch:'
}

# Fail-safe in the direction that deletes nothing: anything other than the exact
# arming value leaves it in dry run. `!= 'true'` and never `== 'false'`, which
# would read an unset variable as armed.
arms_deliberately() {
  local code
  code=$(code_of "$1")
  matches "$code" "dry-run: \\\$\{\{ vars\.BRANCH_REAPER_ARMED != 'true' \}\}" || return 1
  ! matches "$code" "dry-run: \\\$\{\{ vars\.[A-Z_]+ == 'false' \}\}"
}

# Even a dry run mints the App token, so a reaper wired before the secrets exist
# goes red every day on the default branch — and a red that means "setup is
# unfinished" is indistinguishable from one that means "the reaper is broken".
waits_for_the_app_to_exist() {
  local code
  code=$(code_of "$1")
  matches "$code" "^    if: vars\.MERGE_LANE_ENABLED == 'true'$"
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

# The workflow's schema default is not the only place the safety default has to
# live. The driver is also run by hand during cutover, with no workflow in
# sight, and by anyone debugging it — so an unset `DRY_RUN` must not delete.
defaults_to_a_dry_run_without_a_workflow() {
  local code
  code=$(code_of "$1")
  matches "$code" '^DRY_RUN="\$\{DRY_RUN:-true\}"$'
}

# The one test that gates every deletion, and it is written as "not false"
# rather than "is true" on purpose: a `DRY_RUN` of `TRUE`, `1`, `yes` or a
# trailing space must all leave the repository alone.
deletes_only_on_an_explicit_false() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  if \[ "\$DRY_RUN" != "false" \]; then$' || return 1
  ! matches "$code" '\[ "\$DRY_RUN" = "true" \]'
}

# Every verdict comes from the tested function, and the delete arm is guarded by
# that verdict rather than by a condition rebuilt here. A second copy of the
# rule in this file is a copy with no cases against it.
delegates_every_verdict() {
  local code
  code=$(code_of "$1")
  matches "$code" 'source "\$HERE/branch-reaper-decision\.sh"' || return 1
  matches "$code" 'verdict="\$\(reaper_verdict ' || return 1
  matches "$code" '\[ "\$\{verdict%%:\*\}" != "delete" \]' || return 1
  # Exactly one call to the delete endpoint, so there is one guarded path and
  # not a second one somebody added for a special case.
  [ "$(count_of "$code" 'gh api -X DELETE')" -eq 1 ]
}

# A list endpoint read unpaginated is the failure that matters most here: the
# branches past page one are precisely the old ones this job exists to find, and
# the pull requests past page one are precisely the merges that would make an
# old branch look unmerged.
reads_every_page() {
  local code
  code=$(code_of "$1")
  matches "$code" 'gh api --paginate "repos/\$R/branches\?per_page=100"' || return 1
  matches "$code" 'gh api --paginate "repos/\$R/pulls\?state=all&per_page=100"' || return 1
  matches "$code" 'gh api --paginate "repos/\$R/pulls\?state=open&per_page=100"'
}

# THE INDEX IS READ ONCE, NOT ONCE PER BRANCH.
#
# Not a performance note. The per-branch shape costs one call per branch —
# measured, it did not finish in five minutes against 256 branches — and it
# scales the wrong way: the repositories with the most to prune are the ones
# where it exhausts the rate limit, and a failed read is a keep, so the job
# silently stops pruning exactly where it is needed.
indexes_the_pull_requests_once() {
  local code
  code=$(code_of "$1")
  matches "$code" '^declare -A PR_OPEN PR_MERGED PR_AT PR_HEAD PR_NUM$' || return 1
  ! matches "$code" 'gh api .*-f "head='
}

# FAIL CLOSED, GLOBALLY. An index that did not load is not a repository with no
# pull requests — and that distinction is the whole safety of this job, because
# "no merged pull request" is read from the same absence as "missing from a
# half-loaded index". An empty index has to abort the run, not produce a sweep
# in which every branch reads as unmerged.
fails_closed_on_an_unreadable_index() {
  local code
  code=$(code_of "$1")
  matches "$code" '^if \[ "\$index_rows" -eq 0 \]; then$' || return 1
  matches "$code" '^  exit 1$'
}

# The default branch is read from the API rather than assumed to be `main`. Four
# repositories in this fleet default to `master`, and a reaper that assumes the
# wrong name deletes the one branch it must never touch.
reads_the_default_branch_from_the_api() {
  local code
  code=$(code_of "$1")
  matches "$code" 'DEFAULT_BRANCH="\$\(gh api "repos/\$R" --jq .\.default_branch' || return 1
  ! matches "$code" 'DEFAULT_BRANCH="\$\{DEFAULT_BRANCH:-main\}"'
}

honours_the_cap() {
  local code
  code=$(code_of "$1")
  matches "$code" '\[ "\$deleted" -ge "\$MAX_DELETIONS" \]'
}

# THE SQUASH-SAFE REACHABILITY TEST. A squash merge leaves the branch tip
# unreachable from the default branch, so the only sound question is whether the
# tip is still the sha that was merged. An unknown tip must stay empty — the
# decision function reads that as `keep:tip-unknown` — rather than defaulting to
# either answer.
compares_the_tip_to_the_merged_head() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  tip_matches=.{2}$' || return 1
  matches "$code" 'if \[ "\$merged_head" = "\$tip" \]; then tip_matches=1; else tip_matches=0; fi'
}

# A branch named `feat/a` must not be mistaken for the row belonging to
# `feat/ab`. The index is an exact-key lookup, and the open-base set is matched
# with `-F -x` — fixed string, whole line — because branch names contain `.`,
# `+` and `*`, all of which are regular-expression metacharacters.
matches_a_branch_name_exactly() {
  local code
  code=$(code_of "$1")
  matches "$code" 'grep -cFx -- "\$branch"' || return 1
  matches "$code" 'PR_OPEN\[\$branch\]'
}

# The report is written to the job summary, which costs nothing and needs no
# permission — the same choice the merge lane's queue view makes. The question
# an operator has is never "what did you delete", the log says that; it is "why
# is this branch still here".
writes_the_report_where_it_costs_nothing() {
  local code
  code=$(code_of "$1")
  matches "$code" 'GITHUB_STEP_SUMMARY' || return 1
  matches "$code" '^  render_report >>"\$GITHUB_STEP_SUMMARY"$'
}

# Report rows are tab-joined and tab-split to render, and tab is IFS whitespace:
# one empty field collapses and shifts every column after it left, so a kept
# branch would render under another branch's verdict. Six fields, six guards.
never_writes_an_empty_report_field() {
  local code
  code=$(code_of "$1")
  [ "$(count_of "$code" 'rf "\$[1-6]"')" -eq 6 ]
}

# ---------------------------------------------------------------------------
# CI, and the documentation
# ---------------------------------------------------------------------------

# Both self-tests have to run. This one asserting its own presence is not
# circular — it is what catches a `ci.yml` edit that drops the step while the
# file still sits in the tree looking like coverage.
ci_runs_both_self_tests() {
  local code
  code=$(code_of "$1")
  matches "$code" 'branch-reaper-decision\.selftest\.sh' || return 1
  matches "$code" 'scripts/ci/branch-reaper\.selftest\.sh'
}

# THE DOCUMENTED EXAMPLE MUST CARRY EXACTLY ONE PIN.
#
# This used to assert that two shas AGREED: a `uses:` pin and an
# `implementation-ref` repeating it. Two shas that must agree is a rule someone
# has to keep, and Dependabot cannot keep it — it rewrites a `uses:` line and
# cannot see an input value, so an automatic update moves the workflow and
# leaves the driver on the previous release.
#
# The workflow now defaults the ref to `github.job_workflow_sha`, the commit it
# was itself called at, so a second sha in the example is not merely redundant:
# a consumer who copies it reintroduces the skew by hand.
documented_example_carries_one_pin() {
  grep -qE 'uses: Dima-Spectorr/ci-runner-infra/\.github/workflows/branch-reaper\.yml@[0-9a-f]{40}' "$1" || return 1
  ! grep -qE '^ *implementation-ref: [0-9a-f]{40}' "$1"
}

# THE EXAMPLE MUST PASS THE GATES THE FLEET ALREADY RUNS.
#
# The cutover shipped a caller that this fleet's own vendored gates reject, and
# nobody found out until the first ordinary pull request in a consumer — the
# cutover itself landed by admin merge, which is the path that skips them.
# `check-workflow-concurrency.sh` requires a top-level `concurrency:`, and a
# constant group key on a scheduled workflow requires the serialization marker;
# `check-runner-policy.sh` RUNNER7 requires a `remote-reusable-allowed` marker
# naming this callee. Neither is discoverable from the callee, so the example is
# where a consumer learns them, and this is what keeps them there.
documented_example_survives_the_consumer_gates() {
  grep -qE '^concurrency:' "$1" || return 1
  grep -qE '^# concurrency-serialization: intentional[[:space:]]*[—-]' "$1" || return 1
  grep -qE '^ *# remote-reusable-allowed\(Dima-Spectorr/ci-runner-infra/\.github/workflows/branch-reaper\.yml, #' "$1"
}

# ---------------------------------------------------------------------------
echo "branch-reaper self-test:"

check() { # <predicate> <file> <description>
  if "$1" "$2"; then ok; else bad "$3"; fi
}

check is_reusable_only "$CALLEE" "the callee has a trigger other than workflow_call, so it can run holding delete authority with no inputs set"
check defaults_to_a_dry_run "$CALLEE" "dry-run no longer defaults to true, so a consumer who omits it deletes branches on the first run"
check caps_the_deletions "$CALLEE" "the per-run deletion cap is missing or never reaches the driver"
check acts_as_the_app "$CALLEE" "the reaper does not act as the merge App, so deletions are unattributed and protected refs fail"
check never_writes_as_itself "$CALLEE" "the built-in token can write, so there are two write paths into a job that deletes refs"
check serialises "$CALLEE" "the reaper does not serialise, so two sweeps can act on a branch list the other is changing"
check callee_group_cannot_collide_with_a_caller "$CALLEE" "the callee's concurrency group is the one the documented caller holds, so the job can never acquire it and every consumer's sweep dies in a second with no log"
check is_bounded "$CALLEE" "the reaper is unbounded, so one run can hold the lock indefinitely"
check keeps_expressions_out_of_the_shell "$CALLEE" "an expression is interpolated into the shell of a job that can delete refs"
check delegates_the_decision "$CALLEE" "the callee decides something itself, in YAML, where no pull request can test it"
check checks_out_its_own_implementation "$CALLEE" "the checkout takes the caller's tree, so every consumer's reaper dies looking for a driver that is not there"
check guarantees_the_cli_it_runs_on "$CALLEE" "the reaper assumes gh is installed, which is false on the fleet's pool, where it then keeps every branch and reports a successful sweep"
check passes_every_input_to_the_driver "$CALLEE" "an input is declared and then dropped, so setting it silently does nothing"

check runs_on_a_schedule "$CALLER" "there is no schedule, so the reaper never runs"
check can_be_run_on_demand "$CALLER" "there is no manual trigger, so a dry-run report cannot be read before the next scheduled run"
check arms_deliberately "$CALLER" "the reaper is not armed by an explicit variable, so it cannot be landed in dry run"
check waits_for_the_app_to_exist "$CALLER" "the reaper runs before an operator confirms the App exists, so it goes red daily and that red stops meaning anything"
check passes_the_app_credentials "$CALLER" "the caller does not pass App credentials, so the reaper cannot authenticate"

check defaults_to_a_dry_run_without_a_workflow "$DRIVER" "an unset DRY_RUN deletes, so running the driver by hand destroys branches"
check deletes_only_on_an_explicit_false "$DRIVER" "the dry-run gate is not written as not-false, so a DRY_RUN of TRUE or 1 deletes"
check delegates_every_verdict "$DRIVER" "the driver decides something itself, or has a second unguarded delete path"
check reads_every_page "$DRIVER" "a list endpoint is read unpaginated, so old branches are invisible or their merges are"
check indexes_the_pull_requests_once "$DRIVER" "the pull request read is back to one call per branch, which exhausts the rate limit on exactly the repositories that need pruning"
check fails_closed_on_an_unreadable_index "$DRIVER" "an unloadable index is not distinguished from a repository with no pull requests, so every branch reads as unmerged"
check reads_the_default_branch_from_the_api "$DRIVER" "the default branch is assumed rather than read, and four repositories in this fleet use master"
check honours_the_cap "$DRIVER" "the per-run deletion cap is not enforced"
check compares_the_tip_to_the_merged_head "$DRIVER" "the squash-safe tip comparison is gone, so commits pushed after a merge are deleted with the branch"
check matches_a_branch_name_exactly "$DRIVER" "a branch name is matched loosely, so one branch inherits another's pull request facts"
check writes_the_report_where_it_costs_nothing "$DRIVER" "the report is not written to the job summary, so there is no record of why a branch was kept"
check never_writes_an_empty_report_field "$DRIVER" "a report field can be empty, and tab collapsing then shifts every column after it left"

check ci_runs_both_self_tests "$CI" "a branch-reaper self-test is not run by CI, so it is a file rather than a gate"
check documented_example_carries_one_pin "$DOC" "the documented example still sets implementation-ref to a sha, so a consumer copying it reintroduces a second pin Dependabot cannot keep in step with the first"
check documented_example_survives_the_consumer_gates "$DOC" "the documented example is missing the concurrency block or the RUNNER7 declaration, so a consumer who copies it verbatim gets a caller their own vendored gates reject"
check documented_caller_cannot_collide_with_the_callee "$DOC" "the documented caller holds the callee job's own concurrency group, so every consumer who copies it reaps nothing and is told nothing"

# ---------------------------------------------------------------------------
# Mutations. Every property above must be DETECTABLE, not merely present: a
# predicate that would pass over a file with the property removed asserts
# nothing, and is worse than no predicate because it reads as coverage.
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

mutate "the callee grows a schedule of its own" "$CALLEE" \
  's|^  workflow_call:|  schedule:\n  workflow_call:|' is_reusable_only
mutate "dry-run picks up the merge lane's default" "$CALLEE" \
  's|^        default: true$|        default: false|' defaults_to_a_dry_run
mutate "the deletion cap stops reaching the driver" "$CALLEE" \
  's|^          MAX_DELETIONS: .*|          X_UNUSED: 0|' caps_the_deletions
mutate "the reaper falls back to the built-in token" "$CALLEE" \
  's@GH_TOKEN: .*steps\.token\.outputs\.token.*@GH_TOKEN: ${{ github.token }}@' acts_as_the_app
mutate "the CLI install step is dropped" "$CALLEE" \
  's@^        run: bash scripts/ci/ensure-gh\.sh$@        run: true@' guarantees_the_cli_it_runs_on
mutate "the checkout starts persisting credentials" "$CALLEE" \
  's|^          persist-credentials: false$|          persist-credentials: true|' never_writes_as_itself
mutate "the job grants itself contents: write" "$CALLEE" \
  's|^      contents: read$|      contents: write|' never_writes_as_itself
mutate "the reaper stops serialising" "$CALLEE" \
  's|^    concurrency:|    x-concurrency:|' serialises
mutate "in-flight reapers become cancellable" "$CALLEE" \
  's|^      cancel-in-progress: false$|      cancel-in-progress: true|' serialises
mutate "the callee takes back the group name the documented caller holds" "$CALLEE" \
  's|^      group: branch-reaper-callee-.*|      group: branch-reaper-caller|' \
  callee_group_cannot_collide_with_a_caller
mutate "the documented caller takes the callee job's group name" "$DOC" \
  's|^  group: branch-reaper-caller$|  group: branch-reaper-callee-${{ github.repository }}|' \
  documented_caller_cannot_collide_with_the_callee
mutate "the job timeout is removed" "$CALLEE" \
  's|^    timeout-minutes: 15$|    x: 15|' is_bounded
mutate "an input is spliced into the shell" "$CALLEE" \
  's|^        run: bash scripts/ci/branch-reaper\.sh$|        run: bash scripts/ci/branch-reaper.sh ${{ inputs.keep-patterns }}|' \
  keeps_expressions_out_of_the_shell
mutate "the checkout takes the caller's tree" "$CALLEE" \
  's|^          repository: .*|          x-repository: caller|' checks_out_its_own_implementation
mutate "min-age-days is accepted and dropped" "$CALLEE" \
  's|^          MIN_AGE_DAYS: .*|          X_UNUSED: 0|' passes_every_input_to_the_driver
mutate "keep-patterns is accepted and dropped" "$CALLEE" \
  's|^          KEEP_PATTERNS: .*|          X_UNUSED: 0|' passes_every_input_to_the_driver

mutate "the schedule is removed" "$CALLER" \
  's|^  schedule:|  x-schedule:|' runs_on_a_schedule
mutate "the manual trigger is removed" "$CALLER" \
  's|^  workflow_dispatch:|  x-workflow_dispatch:|' can_be_run_on_demand
mutate "arming inverts so an unset variable means armed" "$CALLER" \
  "s|vars\\.BRANCH_REAPER_ARMED != 'true'|vars.BRANCH_REAPER_DISARMED == 'false'|" arms_deliberately
mutate "the App-exists gate is dropped" "$CALLER" \
  "s|^    if: vars\\.MERGE_LANE_ENABLED == 'true'\$|    if: always()|" waits_for_the_app_to_exist
mutate "the private key stops being passed" "$CALLER" \
  's|^      app-private-key: .*|      x-app-private-key: none|' passes_the_app_credentials

mutate "an unset DRY_RUN starts meaning armed" "$DRIVER" \
  's|^DRY_RUN="\${DRY_RUN:-true}"$|DRY_RUN="${DRY_RUN:-false}"|' defaults_to_a_dry_run_without_a_workflow
mutate "the dry-run gate becomes is-true instead of not-false" "$DRIVER" \
  's|^  if \[ "\$DRY_RUN" != "false" \]; then$|  if [ "$DRY_RUN" = "true" ]; then|' deletes_only_on_an_explicit_false
mutate "the delete arm stops checking the verdict" "$DRIVER" \
  's|\[ "\${verdict%%:\*}" != "delete" \]|false|' delegates_every_verdict
mutate "a second delete path is added" "$DRIVER" \
  's@^echo "reaper: done@gh api -X DELETE "repos/$R/git/refs/heads/x"\necho "reaper: done@' delegates_every_verdict
mutate "the decision function stops being sourced" "$DRIVER" \
  's|source "\$HERE/branch-reaper-decision\.sh"|true|' delegates_every_verdict
mutate "the branch list stops paginating" "$DRIVER" \
  's@gh api --paginate "repos/\$R/branches@gh api "repos/$R/branches@' reads_every_page
mutate "the pull request index stops paginating" "$DRIVER" \
  's@gh api --paginate "repos/\$R/pulls?state=all@gh api "repos/$R/pulls?state=all@' reads_every_page
mutate "the open-base read stops paginating" "$DRIVER" \
  's@gh api --paginate "repos/\$R/pulls?state=open@gh api "repos/$R/pulls?state=open@' reads_every_page
mutate "the index goes back to one read per branch" "$DRIVER" \
  's@^declare -A PR_OPEN.*@gh api -X GET "repos/$R/pulls" -f "head=$OWNER:$branch"@' indexes_the_pull_requests_once
mutate "an empty index stops aborting the run" "$DRIVER" \
  's|^if \[ "\$index_rows" -eq 0 \]; then$|if false; then|' fails_closed_on_an_unreadable_index
mutate "the default branch is assumed to be main" "$DRIVER" \
  's@^DEFAULT_BRANCH="\$(gh api.*@DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"@' reads_the_default_branch_from_the_api
mutate "the deletion cap stops being enforced" "$DRIVER" \
  's|\[ "\$deleted" -ge "\$MAX_DELETIONS" \]|false|' honours_the_cap
mutate "an unknown tip starts counting as unchanged" "$DRIVER" \
  's|^  tip_matches=..$|  tip_matches=1|' compares_the_tip_to_the_merged_head
mutate "the open-base match becomes a regular expression" "$DRIVER" \
  's|grep -cFx -- "\$branch"|grep -c -- "$branch"|' matches_a_branch_name_exactly
mutate "the job summary stops being written" "$DRIVER" \
  's|^  render_report >>"\$GITHUB_STEP_SUMMARY"$|  render_report >/dev/null|' writes_the_report_where_it_costs_nothing
mutate "a report field goes in raw" "$DRIVER" \
  's|"\$(rf "\$3")"|"$3"|' never_writes_an_empty_report_field

mutate "the structural self-test drops out of CI" "$CI" \
  's@scripts/ci/branch-reaper\.selftest\.sh@scripts/ci/nope.sh@' ci_runs_both_self_tests
mutate "the decision self-test drops out of CI" "$CI" \
  's@branch-reaper-decision\.selftest\.sh@nope.sh@' ci_runs_both_self_tests

mutate "the documented example loses its concurrency block" "$DOC" \
  's@^concurrency:@# concurrency:@' documented_example_survives_the_consumer_gates
mutate "the documented example loses its RUNNER7 declaration" "$DOC" \
  's@# remote-reusable-allowed@# remote-reusable-was-allowed@' documented_example_survives_the_consumer_gates

if [ "$FAIL" -gt 0 ]; then
  echo "branch-reaper: $FAIL failed, $PASS passed"
  exit 1
fi
echo "branch-reaper: $PASS checks pass"
