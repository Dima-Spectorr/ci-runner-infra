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
# THE LANE'S ONLY TOOL HAS TO BE THERE BEFORE THE LANE RUNS.
#
# `merge-lane.sh` is `gh api` from top to bottom, and it reads every fact with
# `|| true` because a failed read must never be mistaken for a passing check.
# That is right for a rate limit and catastrophic for a missing binary: on the
# fleet's self-hosted images, which do not ship the CLI, every read returned
# nothing, the lane concluded there was nothing to merge, and the job went
# green. Ordering matters as much as presence — installing the CLI after the
# driver has already run is not a fix.
guarantees_the_cli_it_runs_on() {
  local code install driver
  code=$(code_of "$1")
  matches "$code" 'run: bash scripts/ci/ensure-gh\.sh' || return 1
  install=$(printf '%s\n' "$code" | grep -n 'ensure-gh\.sh' | head -1 | cut -d: -f1)
  driver=$(printf '%s\n' "$code" | grep -n 'run: bash scripts/ci/merge-lane\.sh' | head -1 | cut -d: -f1)
  [ -n "$install" ] && [ -n "$driver" ] && [ "$install" -lt "$driver" ]
}

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
#
# Collects every `run:` body rather than everything from the first one to the
# end of the file. The cheaper version held only while the driver step was last
# in the job: the moment a step was added above it the range swallowed the
# following steps' `env:` blocks, where an expression is exactly how a value is
# supposed to arrive, and the assertion fired on correct code.
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
  matches "$code" 'ref: \$\{\{ inputs.implementation-ref \|\| github.job_workflow_sha \}\}'
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

# `gh api` PRINTS THE ERROR BODY TO STDOUT, so `|| true` on a check read does
# not yield "no checks" — it yields one nameless JSON object mixed into the
# stream. `map({(.name): .state})` then dies on a null key, the aggregation
# comes back EMPTY, and every required check resolves to the empty string,
# which the classifier's `*)` arm counts as FAILED. Measured live 2026-08-25:
# two `success` check-runs reported as `skip:red failed=2` across six
# repositories, because the App lacked `Commit statuses: read`.
#
# Three properties, and the check needs all of them: the check-run read keeps
# its exit status, the aggregation drops anything without a string name, and an
# empty aggregation is fatal rather than fed to the classifier.
fails_closed_on_an_unreadable_check_surface() {
  local code
  code=$(code_of "$1")
  matches "$code" 'if ! runs="\$\(gh api --paginate "repos/\$R/commits/\$sha/check-runs' || return 1
  matches "$code" 'select\(type == "object" and \(\.name \| type\) == "string"\)' || return 1
  matches "$code" 'did not aggregate — the lane is blind, not idle" >&2' || return 1
  # And the diagnostics stay off stdout: this function's stdout is its return
  # value, so a log line written there is read as the counts.
  matches "$code" 'cannot read the check-runs of \$sha — the lane is blind, not idle" >&2'
}

# The other half of the same 403: the status surface being unreadable is NOT a
# reason to stop merging on the check-runs that are readable, but it is a reason
# to say so. Without the warning, a required context that is a legacy commit
# status reads as ABSENT and is indistinguishable from a renamed job.
says_so_when_the_status_surface_is_unreadable() {
  local code
  code=$(code_of "$1")
  matches "$code" 'if ! statuses="\$\(gh api --paginate' || return 1
  matches "$code" "Commit statuses: read" || return 1
  matches "$code" 'hold the lane\." >&2'
}

# "Once" has to survive a subshell. `check_counts` is called as
# `counts="$(check_counts …)"`, so a shell variable set inside it is gone by the
# next call and the warning is re-armed per pull request — measured at one copy
# per open pull request on two repositories. The marker is therefore a file, in
# a per-run directory that is removed on exit so it cannot silence the next run.
says_it_once_across_subshells() {
  local code
  code=$(code_of "$1")
  matches "$code" 'LANE_TMP="\$\(mktemp -d\)"' || return 1
  matches "$code" "trap 'rm -rf \"\\\$LANE_TMP\"' EXIT" || return 1
  matches "$code" 'STATUS_WARN_ONCE="\$LANE_TMP/' || return 1
  matches "$code" 'if \[ ! -e "\$STATUS_WARN_ONCE" \]' || return 1
  # And nothing may go back to a variable that a subshell throws away.
  ! matches "$code" 'STATUS_SURFACE_WARNED'
}

# Reading `/pulls/<n>` on a pull request nobody has asked about recently
# ENQUEUES the mergeability computation and returns null in the same breath. One
# read therefore learns nothing about a stale pull request, which is the normal
# state of one sitting in a queue — measured as `wait:mergeability-unknown` for
# every open pull request on two repositories at once, a pass that did nothing.
asks_again_when_mergeability_is_not_computed_yet() {
  local code
  code=$(code_of "$1")
  matches "$code" 'while \[ "\$mergeable" = "null" \] && \[ "\$mergeable_try" -lt 2 \]' || return 1
  matches "$code" 'sleep 2' || return 1
  # Bounded, or a lane pass hangs on a pull request GitHub will never answer.
  matches "$code" 'mergeable_try=\$\(\(mergeable_try \+ 1\)\)' || return 1
  # And the re-read is normalised: `gh api` puts the error body on stdout, so
  # anything that is not literally true/false has to collapse back to unknown.
  matches "$code" 'true \| false\) mergeable="\$reread" ;;'
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
  matches "$code" '\$\{#detail_lines\[@\]\}" -ne 4' || return 1
  ! matches "$code" 'read -r mergeable labels sha'
}

# ...and it must say WHY. A permanent cause — a missing App permission, or the
# field-collapse defect above building a URL with no sha in it — emits exactly
# the same line as a transient 5xx, every fifteen minutes, forever. A
# fail-closed verdict with no diagnostic is a lane that is stuck and cannot tell
# anyone; that is how the field-collapse defect stayed hidden.
# A LANE THAT CANNOT SEE MUST NOT REPORT A QUIET DAY.
#
# Every other early return in the driver means "looked, found nothing to do",
# and green is the honest answer. Failing to read the base tip is the one that
# is not: it means no pull request was judged at all. This was found in
# production — `gh` was absent from the fleet's pool images, every `gh api ...
# || true` returned nothing, and seven repositories reported a healthy lane
# with `0 action(s)` for a morning while merging nothing. The missing binary is
# fixed in the workflow; the indistinguishable green is fixed here, because the
# next cause of a blind lane will not be that one.
fails_when_it_cannot_read_the_base() {
  local code
  code=$(code_of "$1")
  matches "$code" 'LANE_FATAL=1' || return 1
  matches "$code" 'LANE_FATAL.*-ne 0' || return 1
  matches "$code" 'exit 1'
}

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
# The queue view: what replaces Mergify's dashboard
# ---------------------------------------------------------------------------
#
# Mergify had a page you could open to see what was queued and why. This lane
# keeps no queue at all — that is the design, and it is what makes a cancelled
# pending run cost nothing — so the view has to be rebuilt from the verdicts of
# the pass that just ran. The properties below are the ones that decide whether
# that view can be TRUSTED, which is a stronger requirement than whether it
# renders.

# Free, native, and unconditional. The job summary needs no permission and no
# API call, so it is the surface that must never be optional: the pinned issue
# can 404 on a missing grant, and if that were the only view a repository would
# be flying blind with nothing red to say so.
publishes_the_queue_where_it_costs_nothing() {
  local code
  code=$(code_of "$1")
  matches "$code" 'render_queue >>"\$GITHUB_STEP_SUMMARY"' || return 1
  matches "$code" '^publish_step_summary$'
}

# The pinned issue is best-effort BY DESIGN. `Issues: write` is a separate grant
# from `Pull requests: write`, and a permission added to an installed App stays
# pending until the installation owner accepts it — so the window where this
# call 404s is the ordinary state of a repository mid-rollout. A lane that
# stopped merging because it could not draw a table would be a queue view that
# broke the queue.
survives_an_unpublishable_status_issue() {
  local code
  code=$(code_of "$1")
  matches "$code" '^publish_status_issue$' || return 1
  matches "$code" 'gh api -X PATCH "repos/\$R/issues/\$STATUS_ISSUE"' || return 1
  matches "$code" '::warning::could not update the queue issue'
}

# Issues and pull requests share one number space and one endpoint, so a
# mistyped variable does not 404 — it overwrites a pull request's description
# with a table, on every run. The lane must confirm it is writing to a plain
# issue before it writes anything.
refuses_to_overwrite_a_pull_request_body() {
  local code
  code=$(code_of "$1")
  matches "$code" 'if .pull_request then "pull-request" else "issue" end' || return 1
  matches "$code" '\[ "\$kind" != "issue" \]'
}

# THE ROWS THE PASS GAVE UP ON ARE THE ONES WORTH SEEING.
#
# Every early `continue` in the candidate loop is a pull request the lane could
# not judge. Omitting those from the table renders "the queue is empty" over
# "the lane is broken" — and that is not hypothetical: the field-collapse defect
# this file already gates against presented for an hour as a lane that simply
# had nothing to do.
shows_the_candidates_it_could_not_judge() {
  local code
  code=$(code_of "$1")
  matches "$code" 'queue_row 8 "\$num" "\$list_title" wait:detail-unreadable' || return 1
  matches "$code" 'queue_row 8 "\$num" "\$title" wait:base-comparison-unreadable' || return 1
  matches "$code" 'queue_row 9 "\$num" "\$list_title" "skip:no-label' || return 1
  # A candidate the pass ran out of time to reach is the newest way to be
  # invisible, and the one an operator is least likely to suspect: the lane is
  # green, it merged something, and the snapshot is simply short.
  matches "$code" 'queue_row 8 ".*" ".*" wait:not-read-this-pass'
}

# A snapshot of the wrong pass is worse than no snapshot: it shows a pull
# request the lane merged four seconds ago as still waiting. The reset belongs
# inside `one_pass`, above the early return as well as above the loop.
snapshots_the_pass_that_just_ran() {
  local code n
  code=$(code_of "$1")
  # Once at the top level to declare it, once inside the pass to clear it.
  n=$(printf '%s\n' "$code" | grep -cE '^ *QUEUE_ROWS=\(\)$')
  [ "${n:-0}" -ge 2 ] || return 1
  matches "$code" '^  QUEUE_ROWS=\(\)$'
}

# Same defect as the detail read, one layer up: the rows are tab-joined and then
# tab-split to render, tab is IFS whitespace, and one empty field would shift
# every column after it left — quietly, into a table that still looks like a
# table.
never_writes_an_empty_queue_field() {
  local code n
  code=$(code_of "$1")
  matches "$code" '^qf\(\) ' || return 1
  n=$(printf '%s\n' "$code" | grep -oE 'qf "\$[1-7]"' | wc -l)
  [ "${n:-0}" -eq 7 ]
}

# The input exists on the callee and reaches the driver. Declaring it and not
# wiring the environment variable is a silent no-op: the consumer sets a number,
# the lane accepts it, and nothing is ever published.
# The line number of the first match, in the comment-stripped text. `grep -v`
# renumbers, but it preserves ORDER, and order is the whole of what these
# assertions are about: which of two things the lane does first.
line_of() { # <text> <ere>
  printf '%s\n' "$1" | grep -nE -- "$2" | head -1 | cut -d: -f1
}

before() { # <text> <ere-first> <ere-second>
  local a b
  a=$(line_of "$1" "$2")
  b=$(line_of "$1" "$3")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# ---------------------------------------------------------------------------
# The cost of a pass. #444.
#
# A lane pass reads the whole open list and then spends five or six API calls
# and up to four seconds of sleeps on each candidate. When those were spent on
# every open pull request — including the ones about to be skipped for want of
# the label — the cost tracked the SIZE OF THE REPOSITORY rather than the depth
# of the queue, and on IntegrateIT (~35 open) every pass ran past the job's
# fifteen-minute ceiling and was killed. Thirty consecutive runs merged nothing.
#
# The reason that went unnoticed for a day is the fact worth remembering: a
# `timeout-minutes` kill is reported as `cancelled`, which is also what an
# operator cancelling produces and what `concurrency` eviction produces. There
# is no annotation and no summary. So both halves are asserted here — the label
# must be judged before anything is spent, and the lane must run out of time
# before the job does, so that it ends by SAYING it ran out of time.
# ---------------------------------------------------------------------------
gates_on_the_label_before_it_spends_anything() {
  local code
  code=$(code_of "$1")
  # The list read has to carry the label, or the gate below has nothing cheap
  # to read and the per-pull-request call comes back.
  matches "$code" '\.labels // \[\]\) \| map\(\.name\)' || return 1
  matches "$code" 'list_labels="\$\{pr_fields' || return 1
  before "$code" '",\$list_labels," != ' 'gh api "repos/\$R/pulls/\$num"'
}

# ---------------------------------------------------------------------------
# The pin waiver: the one pull request nobody is going to label
#
# A label gate and "track the shared workflows automatically" are in direct
# conflict, because the bump arrives from a bot that does not label. The waiver
# resolves it, and every assertion here is about keeping it NARROW — the failure
# it must never have is a bot pull request that edits a job merging unlabelled.
# ---------------------------------------------------------------------------
waives_the_label_only_for_a_pin_only_diff() {
  local code
  code=$(code_of "$1")
  # Off unless configured, and only ever for the configured author.
  matches "$code" '^  \[ -n "\$PIN_BUMP_ACTOR" \] \|\| return 1' || return 1
  matches "$code" '^  \[ "\$author" = "\$PIN_BUMP_ACTOR" \] \|\| return 1' || return 1
  # A file outside the workflow directory refuses the waiver …
  matches "$code" '^        \.github/workflows/\*\) continue ;;' || return 1
  # … and so does a changed line that does not name the pinned repository.
  matches "$code" '\*uses:\*"\$PIN_BUMP_REPO/\.github/workflows/"\*\) saw_pin=1 ;;' || return 1
  # An empty diff is not a pin bump: `saw_pin` has to have been set.
  matches "$code" '^  \[ "\$saw_pin" -eq 1 \]'
}

the_pin_waiver_is_asked_only_when_the_label_is_missing() {
  local code
  code=$(code_of "$1")
  # It costs an API call, so it sits INSIDE the label-missing branch, never
  # above it — the ordinary labelled pull request must not pay for it.
  before "$code" '",\$list_labels," != ' 'if lane_is_pin_bump "\$num" "\$list_author"' || return 1
  # And the authoritative gate honours a waiver already granted, or the second
  # gate would skip everything the first one waved through.
  matches "$code" '^    if \[ "\$pin_waiver" -eq 0 \] && \[ -n "\$REQUIRE_LABEL" \]'
}

the_pin_waiver_is_off_by_default() {
  local code
  code=$(code_of "$1")
  matches "$code" '^PIN_BUMP_ACTOR="\$\{PIN_BUMP_ACTOR:-\}"'
}

passes_the_pin_waiver_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      pin-bump-actor:' || return 1
  matches "$code" 'PIN_BUMP_ACTOR: \$\{\{ inputs.pin-bump-actor \}\}' || return 1
  matches "$code" 'PIN_BUMP_REPO: \$\{\{ inputs.pin-bump-repo \}\}'
}

skips_before_it_sleeps() {
  local code
  code=$(code_of "$1")
  # The authoritative gate, on the detail read's copy, still sits above the
  # mergeability retry loop — the only place in the pass that sleeps.
  before "$code" '",\$labels," != ' '^      sleep '
}

stops_walking_when_the_pass_runs_out_of_time() {
  local code
  code=$(code_of "$1")
  # Anchored to the WALK's own call site. Matching the bare name would let this
  # be satisfied by one of the other two deadline checks — the action loop's and
  # the batch's — and a walk that lost its deadline would still pass.
  matches "$code" '^    if lane_pass_expired "\$LANE_STARTED" "\$PASS_BUDGET" ' || return 1
  # Asked at the top of the candidate loop AND around the action loop: four
  # actions are four full walks, and a run killed after its last merge but
  # before the summary reports nothing about what it merged.
  [ "$(printf '%s\n' "$code" | grep -cE 'lane_pass_expired')" -ge 2 ] || return 1
  matches "$code" 'truncated_at=-1' || return 1
  matches "$code" '"\$truncated_at" -ge 0' || return 1
  matches "$code" '::warning::lane: pass truncated' || return 1
  # The counts, not just the fact. "Read 4 of 35" is what tells an operator
  # whether to raise the budget or close some pull requests.
  matches "$code" 'read \$read_count of \$total'
}

the_lane_runs_out_of_time_before_the_job_does() {
  local budget timeout
  budget=$(awk '/^      pass-budget-seconds:/{f=1} f&&/^ *default:/{print;exit}' "$1" | grep -oE '[0-9]+')
  timeout=$(grep -oE '^    timeout-minutes: [0-9]+' "$1" | grep -oE '[0-9]+' | head -1)
  [ -n "$budget" ] && [ -n "$timeout" ] || return 1
  # A margin, not merely "less than". The budget is checked BETWEEN candidates,
  # so the lane can overshoot it by however long one candidate takes, and it
  # still has to publish the summary and the queue issue afterwards. A budget
  # that only just fits inside the ceiling would be killed doing exactly that,
  # and a run that merges and then reports nothing is worse than one that
  # merges nothing.
  [ "$((budget + 120))" -le "$((timeout * 60))" ] || return 1
  local driver_default
  driver_default=$(grep -oE '^PASS_BUDGET="\$\{PASS_BUDGET:-[0-9]+\}"' "$DRIVER" | grep -oE '[0-9]+')
  [ -n "$driver_default" ] || return 1
  # The driver's own fallback is what applies when someone runs it by hand or
  # from a caller that predates the input, so it is held to the same ceiling.
  [ "$((driver_default + 120))" -le "$((timeout * 60))" ]
}

passes_the_pass_budget_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      pass-budget-seconds:' || return 1
  matches "$code" 'PASS_BUDGET: \$\{\{ inputs.pass-budget-seconds \}\}'
}

fails_closed_on_an_unreadable_pull_request_list() {
  local code
  code=$(code_of "$1")
  # `gh api` writes the error body to stdout, so a list read that dropped its
  # exit status would hand back a JSON document and then — because that is not
  # five fields per record — either report a healthy quiet day or read garbage.
  matches "$code" 'if ! prs_raw="\$\(gh api --paginate "repos/\$R/pulls\?state=open' || return 1
  matches "$code" '\$\{#pr_fields\[@\]\} % 6\)\) -ne 0' || return 1
  [ "$(printf '%s\n' "$code" | grep -cE 'LANE_FATAL=1')" -ge 4 ]
}

passes_the_status_issue_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      status-issue:' || return 1
  matches "$code" 'STATUS_ISSUE: \$\{\{ inputs.status-issue \}\}'
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

# THE DOCUMENTED EXAMPLE MUST CARRY EXACTLY ONE PIN.
#
# This used to assert that two shas AGREED: a `uses:` pin, and an
# `implementation-ref` input repeating it eight lines below, because a reusable
# workflow's `actions/checkout` clones the CALLER and the lane had to be told
# where its own driver lived. Two shas that must agree is a rule someone has to
# keep, and Dependabot cannot keep it — it rewrites a `uses:` line and cannot
# see an input value, so an automatic update moved the workflow and left the
# driver on the previous release.
#
# The workflow now defaults the ref to `github.job_workflow_sha`, the commit it
# was itself called at, so the second sha is not merely unnecessary — a
# consumer who copies one out of an old example reintroduces the skew by hand.
# The gate is therefore the opposite of the old one: the example pins the
# `uses:` line and says nothing else.
documented_example_carries_one_pin() {
  local doc="$1"
  grep -qE 'merge-lane\.yml@[0-9a-f]{40}' "$doc" || return 1
  ! grep -qE '^ *implementation-ref: [0-9a-f]{40}' "$doc"
}

# THE EXAMPLE MUST PASS THE GATES THE FLEET ALREADY RUNS.
#
# The cutover shipped a caller that three of this fleet's own vendored gates
# reject, and nobody found out until the first ordinary pull request in a
# consumer — because the cutover itself landed by admin merge, which is exactly
# the path that skips them. Thirteen repositories then needed the same two
# additions by hand.
#
# `check-workflow-concurrency.sh` requires a top-level `concurrency:`, and a
# constant group key on a scheduled workflow requires the serialization marker.
# `check-runner-policy.sh` RUNNER7 requires a `remote-reusable-allowed` marker
# naming this callee, because it cannot read across the repository boundary.
# Neither is optional and neither is discoverable from the callee, so the
# example is where a consumer learns them — and this is the check that keeps
# them there. It runs on a pull request, which the gates it stands in for
# cannot do from this repository.
documented_example_survives_the_consumer_gates() {
  local doc="$1"
  grep -qE '^concurrency:' "$doc" || return 1
  grep -qE '^# concurrency-serialization: intentional[[:space:]]*[—-]' "$doc" || return 1
  grep -qE '^ *# remote-reusable-allowed\(Dima-Spectorr/ci-runner-infra/\.github/workflows/merge-lane\.yml, #' "$doc"
}

# A required check that SKIPPED is satisfied, and never silently. GitHub's own
# branch protection counts it that way and so did Mergify, so a lane that reads
# it as red is stricter than every gate around it — and holds a one-file docs
# change nothing could have broken, with GitHub itself reporting mergeable. The
# names are logged, because a job that skipped on a broken `if:` must stay
# visible; absorbing it is the risk this arm carries.
counts_a_skipped_requirement_as_passing() {
  local code
  code=$(code_of "$1")
  matches "$code" 'were_skipped\+=\("\$name"\)' || return 1
  matches "$code" 'required and SKIPPED, counted as passing' || return 1
  # `neutral` still is not a pass: a check that ran and declined to judge said
  # something different from one that never had to run.
  ! matches "$code" 'neutral \| skipped\)'
}

# The label gate is the only line in the example whose FAILURE MODE IS SILENCE.
# `${{ vars.X }}` renders as an empty string when the variable is unset,
# mistyped, or cleared later by someone tidying settings — and empty means "no
# label required", so the bare form arms the lane against the whole backlog it
# was added to hold back, with nothing red anywhere. A consumer copies this
# example; the example must carry the fallback.
documented_label_gate_fails_closed() {
  local doc="$1"
  grep -qE "require-label: \\\$\{\{ vars\.MERGE_LANE_REQUIRE_LABEL \|\| '[^']+' \}\}" "$doc" || return 1
  ! grep -qE "require-label: \\\$\{\{ vars\.MERGE_LANE_REQUIRE_LABEL \}\}" "$doc"
}

# An Actions expression is parsed wherever it appears in the workflow file —
# INCLUDING inside an input's `description:`, where `vars` is not in scope. The
# result is "Unrecognized named-value", a startup failure: no jobs, no log, and
# nothing on the run to read. Measured 2026-08-25: documenting the label gate's
# fallback inline took every lane run in this repository down for an hour, and
# it looked like an outage rather than a syntax error. The header carries prose;
# the copyable line lives in `docs/merge-lane.md`, which is inert.
declares_its_inputs_without_a_live_expression() {
  local header
  header=$(awk '/^jobs:/ { exit } { print }' "$1")
  ! matches "$header" '\$\{\{'
}

# THE BATCH IS A CONSEQUENCE OF THE BASE, NOT A SPEED SETTING.
#
# Acting on several candidates from one reading of the world is only sound
# where a merge cannot invalidate the other verdicts — a base that does not
# require a branch to be up to date. On a strict base every `behind_by` in the
# pass is stale the moment something merges, and a batch there would merge
# against facts that no longer hold. So the widened budget has to stay welded
# to `LANE_STRICT`; an unguarded `batch=` is the whole defect.
batches_only_when_the_base_allows_it() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  local batch=1$' || return 1
  matches "$code" '^  if \[ "\$LANE_STRICT" = "0" \] \&\& \[ "\$MAX_ACTIONS" -gt "\$acted" \]; then$' || return 1
  matches "$code" '^    batch=\$\(\(MAX_ACTIONS - acted\)\)$'
}

# The batch is optional work; the pass deadline is not. A pass that ran out of
# time still takes its FIRST action -- that is the deadline's own design, the
# best candidate it managed to read -- but spending the job's remaining
# publishing headroom on a fifth merge costs the queue snapshot and the
# annotation that explain why the pass was short.
stops_batching_at_the_pass_deadline() {
  matches "$(code_of "$1")" '^      if lane_pass_expired "\$LANE_STARTED" "\$PASS_BUDGET" '
}

# A refused merge means the world moved — most often that this pass's own
# earlier merge left the next candidate conflicting. Carrying on down the
# ranking after a refusal is how a batch turns into a sequence of guesses.
#
# Exit 2 is the one refusal that does NOT mean the world moved: the App lacks a
# permission on the files this pull request touches, which says nothing about
# any other candidate. That one is skipped so it cannot starve the backlog —
# but it must still be an EXCEPTION, spelled out, or the general case silently
# becomes "carry on".
ends_the_batch_on_a_refusal() {
  local code
  code=$(code_of "$1")
  matches "$code" '^    lane_take_action .* \|\| take_rc=\$\?$' || return 1
  matches "$code" '^      \[ "\$take_rc" -eq 2 \] \|\| break$'
}

# A REFUSAL THE LANE CANNOT EXPLAIN COSTS HOURS. The old annotation guessed —
# "head moved, or the branch became unmergeable" — while gh's stderr, carrying
# the actual HTTP 403, went to the log unread. An operator who then checks the
# pull request finds it mergeable and clean and has nowhere left to look.
quotes_what_github_actually_said() {
  local code
  code=$(code_of "$1")
  # The error is captured off the call, not discarded. Asserted in two pieces
  # because the call is line-continued and `matches` reads a line at a time.
  matches "$code" '^      if merge_err="\$\(gh api -X PUT ' || return 1
  matches "$code" '^      if update_err="\$\(gh api -X PUT ' || return 1
  [ "$(printf '%s\n' "$code" | grep -c -- '--silent 2>&1)"')" = 2 ] || return 1
  # …and reaches the annotation.
  matches "$code" 'GitHub said: \$err'
}

# The fleet's pull requests are overwhelmingly workflow pull requests, and a
# GitHub App may not touch `.github/workflows/**` without the `workflows`
# permission. Reported as the generic "head moved" this is undiagnosable; and
# because such a pull request is refused identically on every pass, one of them
# at the head of the ranking holds the entire repository. It is named, and it
# does not end the batch.
names_the_workflows_permission_refusal() {
  local code
  code=$(code_of "$1")
  matches "$code" "^    \*'workflows'\*permission\*)\$" || return 1
  matches "$code" '^      return 2$'
}

# "Not asked" and "up to date" are different facts. The verdict does not care —
# it never reads `behind` on a non-strict base — but the queue table is what an
# operator reads to decide whether the lane is working, and a column of zeroes
# it never measured is a table that lies.
says_when_it_did_not_ask_how_far_behind() {
  local code
  code=$(code_of "$1")
  matches "$code" "^      behind_cell='n/a'$" || return 1
  matches "$code" '^    if \[ "\$LANE_STRICT" = "0" \]; then$'
}

# The one risk a non-strict base carries that the merge API will not refuse on
# the lane's behalf: two pull requests, each green alone, broken together. The
# lane cannot prevent it without rebuilding every branch on every merge -- which
# is what a strict base is, and what the repository declined -- so instead it
# refuses to keep merging onto a base whose own required checks are failing.
halts_when_the_base_itself_is_red() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  if lane_base_is_broken "\$base_sha"; then$' || return 1
  matches "$code" '^    LANE_HALT_REASON=' || return 1
  # Above the walk. Below it the gate still works, but a halted pass would first
  # spend a call per open pull request reaching a verdict it will not act on.
  local halt_line walk_line
  halt_line=$(grep -n '^  if lane_base_is_broken ' "$1" | head -n1 | cut -d: -f1)
  # The OPEN-LIST read specifically. `repos/$R/pulls` alone also matches the
  # per-pull-request reads — `/pulls/<n>/reviews`, `/pulls/<n>/files` — and the
  # first of those to appear in the file would be compared instead, which
  # answers a different question and can only answer it by accident.
  walk_line=$(grep -n 'gh api --paginate "repos/\$R/pulls?state=open' "$1" | head -n1 | cut -d: -f1)
  [ -n "$halt_line" ] && [ -n "$walk_line" ] && [ "$halt_line" -lt "$walk_line" ]
}

# FAILS OPEN, and that direction is the load-bearing part. Most repositories run
# their required checks on `pull_request` only, so every one of them is ABSENT on
# the base tip forever; a gate that halted on a missing or pending check would
# stop the lane in every repository in the fleet the day it shipped. Only a
# definite failure counts.
only_a_definite_failure_halts_the_lane() {
  matches "$(code_of "$1")" '^  \[ "\$\{failed:-0\}" -gt 0 \]$'
}

# A halted pass returns before it reads a single pull request, so it renders no
# rows -- which is byte-for-byte what a base with nothing open renders. Without
# the reason on the snapshot, the lane stopping and the lane having nothing to do
# are the same picture.
says_on_the_snapshot_that_it_halted() {
  local code
  code=$(code_of "$1")
  matches "$code" '^    printf .> \*\*Halted\.\*\* ' || return 1
  matches "$code" '^      printf ._The open list was not read on this pass\._'
}

# THE BASE-HEALTH GATE READS ITS OWN LIST, AND FALLS BACK TO THE STRICT ONE.
# `BASE_HEALTH_CHECKS` exists so a repository whose required suite takes half an
# hour can arm the gate against a cheap post-merge job instead. Two things have
# to hold for that not to be a quiet ungating: an unset value must fall back to
# `REQUIRED` rather than to nothing -- an empty list would make `check_counts`
# count zero failures and the gate would pass on a base that is on fire -- and
# the shadowing must be LOCAL to `lane_base_is_broken`, or every merge after the
# first pass would be gated on the cheap list too.
reads_its_own_list_on_the_base_tip() {
  local code
  code=$(code_of "$1")
  matches "$code" '^mapfile -t BASE_HEALTH < ' || return 1
  matches "$code" '^  local -a REQUIRED=\("\$\{BASE_HEALTH\[@\]\}"\)$'
}

falls_back_to_the_required_list() {
  local code
  code=$(code_of "$1")
  matches "$code" '^if \[ "\$\{#BASE_HEALTH\[@\]\}" -eq 0 \]; then$' || return 1
  matches "$code" '^  BASE_HEALTH=\("\$\{REQUIRED\[@\]\}"\)$'
}

# The shadow has to sit inside the function. At file scope it would replace the
# merge path's own list, and the lane would merge on whatever cheap subset the
# base-health gate was pointed at -- the exact ungating invariant B exists to
# prevent, arriving through the input added to make the gate affordable.
scopes_the_shadow_to_the_gate() {
  local shadow_line fn_start fn_end
  shadow_line=$(grep -n '^  local -a REQUIRED=("${BASE_HEALTH\[@\]}")' "$1" | head -n1 | cut -d: -f1)
  fn_start=$(grep -n '^lane_base_is_broken() {' "$1" | head -n1 | cut -d: -f1)
  fn_end=$(grep -n '^one_pass() {' "$1" | head -n1 | cut -d: -f1)
  [ -n "$shadow_line" ] && [ -n "$fn_start" ] && [ -n "$fn_end" ] \
    && [ "$shadow_line" -gt "$fn_start" ] && [ "$shadow_line" -lt "$fn_end" ]
}

# The workflow has to hand the driver the value, or the input is decoration and
# every repository that sets it silently keeps the strict list.
passes_the_base_health_list_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      base-health-checks:$' || return 1
  matches "$code" '^          BASE_HEALTH_CHECKS: \$\{\{ inputs\.base-health-checks \}\}$'
}

# A cancelled required check has to mean two different things in the two places
# it is read, and getting that wrong wedges the lane on a healthy base. The job
# that answers the base-health question is keyed on a constant concurrency group
# with cancel-in-progress -- the only shape that answers for the CURRENT tip --
# so the next merge cancels it, and a cancelled run counted as red would halt
# every pass on a repository with nothing wrong with it.
reads_a_cancelled_base_check_as_unanswered() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      cancelled | stale)$' || return 1
  matches "$code" '^        if \[ "\$\{BASE_TIP_READ:-0\}" = "1" \]; then$' || return 1
  matches "$code" '^          pending=\$\(\(pending \+ 1\)\)$' || return 1
  # And the OTHER arm, which is the half that must not be lost: on the merge
  # path a cancelled required check is still a check that did not pass.
  matches "$code" '^          failed=\$\(\(failed \+ 1\)\)$'
}

# `BASE_TIP_READ` is set in exactly one place. Set anywhere else -- at file
# scope, or on the merge path -- and a cancelled required check stops blocking
# the merge it should block.
sets_the_base_tip_handle_only_in_the_gate() {
  local set_line fn_start fn_end n
  n=$(grep -c '^  local BASE_TIP_READ=1$' "$1")
  [ "$n" = "1" ] || return 1
  grep -q '^BASE_TIP_READ=' "$1" && return 1
  set_line=$(grep -n '^  local BASE_TIP_READ=1$' "$1" | head -n1 | cut -d: -f1)
  fn_start=$(grep -n '^lane_base_is_broken() {' "$1" | head -n1 | cut -d: -f1)
  fn_end=$(grep -n '^one_pass() {' "$1" | head -n1 | cut -d: -f1)
  [ -n "$set_line" ] && [ -n "$fn_start" ] && [ -n "$fn_end" ] \
    && [ "$set_line" -gt "$fn_start" ] && [ "$set_line" -lt "$fn_end" ]
}

# NOT RED IS NOT VOUCHED FOR, AND THE BATCH IS WHERE THAT BITES.
# The halt asks its question once, at the top of a pass, and a pass may then
# merge several pull requests. The first of them can turn the base red -- two
# branches green alone and broken together is precisely the case this gate
# exists for -- and the rest of the batch lands on it before any post-merge job
# has reported. So the tip is re-read between merges, and the batch stops unless
# it has answered green.
waits_for_the_tip_between_merges() {
  matches "$(code_of "$1")" '^        if ! lane_base_is_vouched "\$tip_now" "\$tip_at"; then$'
}

# And at the top of every pass as well, or the rule is undone by the loop around
# it: the run loop calls `one_pass` again immediately, and a lane run triggered
# seconds after another one's merge would walk straight past an unanswered tip.
waits_for_the_tip_at_the_top_of_a_pass() {
  matches "$(code_of "$1")" '^  if ! lane_base_is_vouched "\$base_sha" "\$base_at"; then$'
}

# THE WAIT IS BOUNDED, AND THAT IS NOT A CONVENIENCE. The job answering for the
# tip is keyed to supersede its own runs, so on a busy base it is routinely
# cancelled before it reports -- `cancelled` is read as unanswered by design.
# A wait with no ceiling would stall the lane hardest exactly where it merges
# most, which is the failure mode the whole lane was built to end.
the_wait_for_an_answer_is_bounded() {
  local code
  code=$(code_of "$1")
  matches "$code" '^BASE_HEALTH_GRACE="\$\{BASE_HEALTH_GRACE:-900\}"$' || return 1
  matches "$code" '^  if \[ "\$age" -ge "\$BASE_HEALTH_GRACE" \]; then$' || return 1
  # And says so out loud when it gives up, because a lane that proceeds
  # unvouched every pass has a broken health job, not a small grace window.
  matches "$code" 'proceeding unvouched'
}

# AND THE CEILING ABOVE IS NOT ITSELF A BOUND ON THE WAIT, WHICH IS WHY THE
# WINDOW EXISTS. `age` is the TIP's age, so every merge that lands restarts the
# clock from zero: each wait expires correctly and the sequence never does.
# Measured on IntegrateIT, where a 6-14 minute health job answers for a `main`
# that advances every 2-16 and the lane merged nothing for a working day.
#
# OFF UNLESS ASKED FOR. Thirteen armed repositories do not get a relaxed gate
# because one of them outran its health job; the default is the rule the gate
# shipped with, and the value is set by the repository that needs it.
the_staleness_window_is_off_by_default() {
  local code
  code=$(code_of "$1")
  matches "$code" '^BASE_HEALTH_MAX_STALENESS="\$\{BASE_HEALTH_MAX_STALENESS:-0\}"$' || return 1
  matches "$code" '\[ "\$BASE_HEALTH_MAX_STALENESS" -gt 0 \]'
}

# AND IT IS CLOSED FOR THE REST OF A RUN THAT HAS MERGED. The other half of this
# gate's job is stopping a batch piling onto a tip THE LANE ITSELF just made and
# nothing has vouched for -- the Apigee-Portal case, #3568 and #3556, green
# alone and broken together. An ancestor's answer predates that merge by
# definition, so letting it speak for the new tip would undo the batch gate
# through the window. Held on a RUN variable, not a pass one: the run loop
# starts the next pass immediately and a pass-scoped guard would be cleared by
# the iteration around it.
the_staleness_window_closes_after_the_lane_merges() {
  local code
  code=$(code_of "$1")
  matches "$code" '\[ -z "\$LANE_MERGED_THIS_RUN" \]' || return 1
  matches "$code" '^        LANE_MERGED_THIS_RUN=1$'
}

# A RED ANCESTOR IS AN ANSWER, NOT NOISE TO BE SEARCHED PAST. The walk stops at
# the first ancestor that answered either way. Continuing past a red one to find
# an older green one would turn the window into a licence to merge onto a base
# that is broken and has said so -- the single thing the whole gate exists to
# prevent, reached through the relaxation added to keep it usable.
a_red_ancestor_inside_the_window_halts_the_lane() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      broken\)$' || return 1
  # rc 1 out of the walk, and the caller must refuse on it rather than fall
  # through to the grace clock that would merge unvouched anyway.
  matches "$code" '^      1\) return 1 ;;$'
}

# BOUNDED BY AGE AND BY HOPS, and both are load-bearing. Without the age test
# the "window" is the whole history and any green commit ever vouches for the
# tip. Without the hop cap a base nothing has answered for spends a pass at two
# paginated check reads per commit proving what the age test proves for free.
the_window_walk_is_bounded() {
  local code
  code=$(code_of "$1")
  matches "$code" '^    \[ "\$age" -lt "\$BASE_HEALTH_MAX_STALENESS" \] \|\| break$' || return 1
  matches "$code" '^    \[ "\$hops" -lt "\$BASE_HEALTH_MAX_HOPS" \] \|\| break$'
}

# The knob has to reach the driver, the same way the list and the grace do. A
# workflow input nothing reads is a repository that set the value, watched the
# lane go on halting, and has no way to tell which end is wrong.
passes_the_staleness_window_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      base-health-max-staleness-seconds:$' || return 1
  matches "$code" '^          BASE_HEALTH_MAX_STALENESS: \$\{\{ inputs\.base-health-max-staleness-seconds \}\}$'
}

# ARMED-NESS IS READ FROM THE PASS TIP, NEVER FROM THE ONE A MERGE JUST MADE.
# Seconds after a merge the post-merge run does not exist yet, so its checks
# read as MISSING on the new tip -- identical to an unarmed repository, forever.
# Deciding it there would answer "nothing is watching" every single time, which
# turns the whole gate off precisely when it is needed.
decides_armed_ness_before_the_batch_moves_the_tip() {
  local set_line fn_start fn_end
  [ "$(grep -c '^  if \[ "\$LANE_BASE_VERDICT" = .inert. \]; then LANE_BASE_ARMED=..; else LANE_BASE_ARMED=1; fi$' "$1")" = "1" ] || return 1
  set_line=$(grep -n '^  if \[ "\$LANE_BASE_VERDICT" = .inert. \]; then LANE_BASE_ARMED=' "$1" | head -n1 | cut -d: -f1)
  fn_start=$(grep -n '^one_pass() {' "$1" | head -n1 | cut -d: -f1)
  fn_end=$(grep -n '^lane_take_action() {' "$1" | head -n1 | cut -d: -f1)
  [ -n "$set_line" ] && [ "$set_line" -gt "$fn_start" ] && [ "$set_line" -lt "$fn_end" ]
}

# An INERT base -- the fleet's ordinary state, and every repository nobody has
# armed -- must keep draining a batch without paying two API calls per merge to
# be told what the top of the pass already established.
costs_an_unarmed_base_nothing() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      if \[ -n "\$LANE_BASE_ARMED" \]; then$' || return 1
  matches "$code" '^  \[ -n "\$LANE_BASE_ARMED" \] \|\| return 0$'
}

# The four verdicts have to stay four. Collapsing `inert` and `unanswered` --
# they look identical to the halt, which is why the halt could afford one
# boolean -- is what makes an armed base look unarmed and reopens the whole gap.
tells_an_unanswered_tip_from_an_unwatched_one() {
  local code
  code=$(code_of "$1")
  matches "$code" "^    LANE_BASE_VERDICT='unanswered'\$" || return 1
  matches "$code" "^    LANE_BASE_VERDICT='inert'\$"
}

echo "merge-lane self-test:"
check waits_for_the_tip_between_merges "$DRIVER" "a batch keeps merging after the first merge without re-reading the base, so two pull requests that are green alone and broken together bury the rest of the backlog on top of the break"
check waits_for_the_tip_at_the_top_of_a_pass "$DRIVER" "only the batch waits for the tip to answer, so the run loop's next pass merges onto it anyway and the rule is undone by the loop around it"
check the_wait_for_an_answer_is_bounded "$DRIVER" "the lane waits for a base-health answer with no ceiling, so a health job cancelled by its own successor stalls the lane hardest on the busiest base"
check the_staleness_window_is_off_by_default "$DRIVER" "the staleness window is on for every repository by default, so thirteen armed bases get a relaxed base-health gate none of them asked for"
check the_staleness_window_closes_after_the_lane_merges "$DRIVER" "an ancestor's answer vouches for a tip the lane itself just created, which undoes the between-merges gate through the window and lets a batch pile onto a semantic conflict"
check a_red_ancestor_inside_the_window_halts_the_lane "$DRIVER" "the walk searches past a red ancestor for an older green one, so a base that is broken and has said so reads as vouched"
check the_window_walk_is_bounded "$DRIVER" "the ancestor walk is unbounded in age or in hops, so any green commit in history vouches for the tip, or a pass is spent at two check reads per commit proving nothing answered"
check passes_the_staleness_window_to_the_driver "$CALLEE" "the workflow declares the staleness window but never hands it to the driver, so a repository that sets it watches the lane go on halting with no way to tell which end is wrong"
check decides_armed_ness_before_the_batch_moves_the_tip "$DRIVER" "armed-ness is decided against a tip a merge just created, where the post-merge run does not exist yet, so every armed base reads as unarmed and the gate is off when it matters"
check costs_an_unarmed_base_nothing "$DRIVER" "an inert base pays two API calls per merge to re-learn that nothing answers for it"
check tells_an_unanswered_tip_from_an_unwatched_one "$DRIVER" "'nobody is watching' and 'nobody has answered yet' collapse into one verdict, so an armed base reads as unarmed and the batch stacks onto an unvouched tip"
check reads_a_cancelled_base_check_as_unanswered "$DRIVER" "a cancelled check on the base tip counts as a failure, so the base-health gate halts every pass on a repository whose base is healthy and whose answering run was merely superseded"
check sets_the_base_tip_handle_only_in_the_gate "$DRIVER" "the base-tip reading mode is set outside the gate, so a cancelled required check stops blocking the merge it exists to block"
check declares_its_inputs_without_a_live_expression "$CALLEE" "an input description carries an Actions expression, and one naming vars fails the whole workflow at startup with no jobs and no log to read"
check documented_label_gate_fails_closed "$DOC" "the documented label gate is wired bare to a variable, so a consumer copying it gets a lane that merges its entire backlog the moment the variable is unset, mistyped or cleared"
check documented_example_carries_one_pin "$DOC" "the documented example still sets implementation-ref to a sha, so a consumer copying it reintroduces a second pin Dependabot cannot keep in step with the first"
check documented_example_survives_the_consumer_gates "$DOC" "the documented example is missing the concurrency block or the RUNNER7 declaration, so a consumer who copies it verbatim gets a caller their own vendored gates reject"
check is_reusable_only "$CALLEE" "the callee has a trigger other than workflow_call, so it can run holding merge authority with no inputs set"
check acts_as_the_app "$CALLEE" "the lane does not act as the merge App, so its merges and updates trigger no downstream workflow"
check never_writes_as_itself "$CALLEE" "the built-in token can write, so there are two write paths and the wrong one can be used"
check serialises "$CALLEE" "the lane does not serialise, so two runs can merge against a world the other is changing"
check is_bounded "$CALLEE" "the lane is unbounded, so one run can hold the lock indefinitely"
check keeps_expressions_out_of_the_shell "$CALLEE" "an expression is interpolated into the shell of a job that can merge"
check demands_its_gate "$CALLEE" "required-checks is optional, so a consumer can wire a lane that merges on no evidence"
check delegates_the_decision "$CALLEE" "the callee decides something itself, in YAML, where no pull request can test it"
check checks_out_its_own_implementation "$CALLEE" "the checkout takes the caller's tree, so every consumer's lane dies looking for a driver that is not there"
check guarantees_the_cli_it_runs_on "$CALLEE" "the lane assumes gh is installed, which is true of GitHub-hosted images and false of the fleet's pool, where every API read then returns nothing and the run goes green"

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
check fails_closed_on_an_unreadable_check_surface "$DRIVER" "a failed check read is swallowed into the stream as a nameless object, and every required check on a green pull request then counts as FAILED"
check says_so_when_the_status_surface_is_unreadable "$DRIVER" "a 403 on the commit-status surface is silent, so a required legacy status reads as missing with nothing naming the cause"
check asks_again_when_mergeability_is_not_computed_yet "$DRIVER" "the lane reads mergeability once, and the first read is the request rather than the answer, so a stale pull request waits forever"
check says_it_once_across_subshells "$DRIVER" "the once-guard is a shell variable set inside a subshell, so the warning prints once per pull request instead of once per run"
check counts_a_skipped_requirement_as_passing "$DRIVER" "a required check that skipped is read as a failure, so any pull request a path filter steers around its jobs is held for ever while GitHub reports it mergeable"
check fails_when_it_cannot_read_the_base "$DRIVER" "a lane that cannot read the base exits green with '0 actions', which is exactly what a healthy quiet day looks like"
check reads_the_detail_without_collapsing_an_empty_field "$DRIVER" "an unlabelled pull request loses its head sha to field collapsing, so the lane can never act on one"
check reports_why_the_comparison_failed "$DRIVER" "a base comparison fails closed without logging the cause, so a permanent block looks like a transient one forever"
check refuses_a_base_that_moved "$DRIVER" "the base tip is not re-checked before acting, so a push to the base merges a head verified against a base that is gone"
check announces_a_release_once "$DRIVER" "a release is not recorded per sha, so the lane re-comments on every pass and every sweep"
check batches_only_when_the_base_allows_it "$DRIVER" "the pass acts on more than one candidate without checking that the base is non-strict, so on a strict base it merges against behind_by values its own earlier merge invalidated"
check stops_batching_at_the_pass_deadline "$DRIVER" "the batch keeps merging past the pass deadline, so a truncated pass spends the headroom it needs to publish the queue and the annotation explaining the truncation"
check ends_the_batch_on_a_refusal "$DRIVER" "a refused action does not stop the batch, so the lane keeps working down a ranking the refusal just proved stale"
check quotes_what_github_actually_said "$DRIVER" "a refusal is reported as a guess while GitHub's own reason is thrown away, so a lane that logs merge:ready and then acts on nothing cannot be diagnosed at all"
check names_the_workflows_permission_refusal "$DRIVER" "a pull request the App may never merge — it touches a workflow file — reads as a transient refusal and ends the batch on every pass, so one of them starves the whole repository"
check halts_when_the_base_itself_is_red "$DRIVER" "the lane keeps merging onto a base whose own required checks are failing, burying the commit that broke it under everything that follows"
check only_a_definite_failure_halts_the_lane "$DRIVER" "the base-health gate halts on something other than a definite failure, which deadlocks every repository whose required checks run on pull_request only"
check says_on_the_snapshot_that_it_halted "$DRIVER" "a halted lane renders exactly like a base with nothing open, so the queue view reports a quiet day while nothing can merge"
check reads_its_own_list_on_the_base_tip "$DRIVER" "the base-health gate reads the merge list instead of its own, so arming it costs a full required suite on every push to the base"
check falls_back_to_the_required_list "$DRIVER" "an unset base-health list resolves to nothing rather than to the required checks, and a gate reading an empty list passes on a base that is on fire"
check scopes_the_shadow_to_the_gate "$DRIVER" "the base-health list leaks out of the gate and becomes what the MERGE is gated on, which is invariant B ungated by the input meant to make the gate affordable"
check passes_the_base_health_list_to_the_driver "$CALLEE" "the input exists but never reaches the driver, so every repository that sets it silently keeps the expensive list"
check says_when_it_did_not_ask_how_far_behind "$DRIVER" "the queue reports 0 commits behind for a pull request it never compared, so the table an operator trusts is showing a number nothing measured"

check publishes_the_queue_where_it_costs_nothing "$DRIVER" "the queue is not written to the job summary, so the only view of it depends on a permission that may not have been granted"
check survives_an_unpublishable_status_issue "$DRIVER" "a status issue that cannot be written is not handled, so a missing Issues grant stops the lane merging"
check refuses_to_overwrite_a_pull_request_body "$DRIVER" "the status-issue number is not confirmed to be an issue, so a typo overwrites a pull request description on every run"
check shows_the_candidates_it_could_not_judge "$DRIVER" "a pull request the pass gave up on is left out of the queue view, so a broken lane renders as an empty queue"
check snapshots_the_pass_that_just_ran "$DRIVER" "the queue is not reset per pass, so the published view mixes passes and can show a merged pull request as waiting"
check never_writes_an_empty_queue_field "$DRIVER" "a queue field can be empty, and tab collapsing then shifts every column after it left"
check passes_the_status_issue_to_the_driver "$CALLEE" "status-issue is declared but never reaches the driver, so setting it does nothing"

check gates_on_the_label_before_it_spends_anything "$DRIVER" "the label is read per pull request, so the lane pays a detail read, two sleeps, a comparison and two check reads for every candidate it is about to skip — and the pass then costs the size of the repository rather than the depth of the queue (#444)"
check skips_before_it_sleeps "$DRIVER" "the mergeability retry loop sleeps above the label gate, so the lane waits four seconds per pull request it has already decided to skip"
check waives_the_label_only_for_a_pin_only_diff "$DRIVER" "the pin waiver is wider than a pin bump, so a bot pull request that edits a job merges without the label"
check the_pin_waiver_is_asked_only_when_the_label_is_missing "$DRIVER" "the waiver's API call is paid for every candidate, or a waiver granted by the cheap gate is thrown away by the authoritative one"
check the_pin_waiver_is_off_by_default "$DRIVER" "a repository that never asked for the waiver gets it anyway, and its label gate is no longer a gate"
check passes_the_pin_waiver_to_the_driver "$CALLEE" "the waiver is configured on the caller and never reaches the driver, so Dependabot's bump still waits for a label nobody applies"
check stops_walking_when_the_pass_runs_out_of_time "$DRIVER" "a pass has no deadline of its own, so it is killed by the job's timeout-minutes instead — and that kill reports as 'cancelled', which is indistinguishable from an operator cancelling it and leaves no annotation, no summary and no queue update (#444)"
check fails_closed_on_an_unreadable_pull_request_list "$DRIVER" "a failed list read falls through as 'no open pull requests', so a lane that cannot see the queue reports a quiet day"
check passes_the_pass_budget_to_the_driver "$CALLEE" "pass-budget-seconds is declared but never reaches the driver, so setting it does nothing"
check the_lane_runs_out_of_time_before_the_job_does "$CALLEE" "the pass budget does not leave the lane two minutes to finish inside the job's timeout-minutes — raise the timeout or lower the budget, but never let the job's ceiling arrive first: that kill reports as 'cancelled' and publishes nothing"

if required_checks_all_exist_in_ci; then ok; else
  bad "a check named in the caller's required-checks does not match any job name in ci.yml — the lane would count it missing and decline every pull request"
fi

# ---------------------------------------------------------------------------
# Mutations — each predicate must be load-bearing, not merely satisfied
# ---------------------------------------------------------------------------
mutate() { # <description> <file> <sed-program> <predicate> — predicate must go false
  local desc="$1" f="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
  # A sed that ERRORS writes nothing, and an empty file fails every predicate —
  # so a broken mutation program reported as a passing assertion. Caught twice
  # while writing the #444 cases; the delimiter and the escaping are easy to get
  # wrong and nothing said so.
  if ! sed "$prog" "$f" >"$tmp" 2>/dev/null; then
    bad "the mutation program is not valid sed, so it asserts nothing: $desc"
    rm -f "$tmp"
    return
  fi
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
mutate "the CLI install step is dropped" "$CALLEE" \
  's@^        run: bash scripts/ci/ensure-gh\.sh$@        run: true@' guarantees_the_cli_it_runs_on

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
mutate "a blind lane goes back to reporting a quiet day" "$DRIVER" \
  's|^    LANE_FATAL=1$|    :|' fails_when_it_cannot_read_the_base
mutate "the commit-status surface is dropped" "$DRIVER" \
  's|commits/\$sha/status|commits/$sha/nothing|' reads_both_check_surfaces
mutate "the empty-configuration guard is removed" "$DRIVER" \
  's%^if \[ "..#REQUIRED\[@\]." -eq 0 \]; then%if false; then%' fails_closed_on_empty_configuration
mutate "the check-run read stops paginating" "$DRIVER" \
  's@gh api --paginate "repos/\$R/commits/\$sha/check-runs@gh api "repos/$R/commits/$sha/check-runs@' reads_every_page
mutate "the pull request list stops paginating" "$DRIVER" \
  's@gh api --paginate "repos/\$R/pulls?state=open@gh api "repos/$R/pulls?state=open@' reads_every_page
mutate "an unreadable comparison falls back to up-to-date" "$DRIVER" \
  's@^      if ! behind=@      behind=0; if false; behind=@' fails_closed_on_an_unreadable_comparison

mutate "the check-run read swallows its exit status again" "$DRIVER" \
  's@if ! runs="\$(gh api --paginate "repos/\$R/commits/\$sha/check-runs@if false; runs="$(gh api --paginate "repos/$R/commits/$sha/check-runs@' \
  fails_closed_on_an_unreadable_check_surface
mutate "the aggregation stops filtering nameless objects" "$DRIVER" \
  's@select(type == "object" and (.name | type) == "string")@select(true)@' \
  fails_closed_on_an_unreadable_check_surface
mutate "the status 403 goes quiet again" "$DRIVER" \
  's@if ! statuses="\$(gh api --paginate@if false; statuses="$(gh api --paginate@' \
  says_so_when_the_status_surface_is_unreadable
mutate "a check-surface diagnostic goes to stdout, where it is read as the counts" "$DRIVER" \
  's@the lane is blind, not idle" >&2@the lane is blind, not idle"@' \
  fails_closed_on_an_unreadable_check_surface
mutate "a skipped requirement goes back to counting as red" "$DRIVER" \
  's@        were_skipped+=("\$name")@        failed=$((failed + 1))@' \
  counts_a_skipped_requirement_as_passing
mutate "the once-guard goes back to a variable a subshell throws away" "$DRIVER" \
  's@if \[ ! -e "\$STATUS_WARN_ONCE" \]; then@if [ -z "${STATUS_SURFACE_WARNED:-}" ]; then@' \
  says_it_once_across_subshells
mutate "the mergeability re-read is dropped, so one null answer is the final one" "$DRIVER" \
  's@while \[ "\$mergeable" = "null" \] \&\& @while false \&\& @' \
  asks_again_when_mergeability_is_not_computed_yet

mutate "the detail read goes back to a tab split" "$DRIVER" \
  's@^    mapfile -t detail_lines@    IFS=$'"'"'\\t'"'"' read -r mergeable labels sha; mapfile -t detail_lines@' \
  reads_the_detail_without_collapsing_an_empty_field

mutate "the batch stops asking whether the base allows it" "$DRIVER" \
  's@^  if \[ "\$LANE_STRICT" = "0" \] && @  if @' batches_only_when_the_base_allows_it
mutate "the batch stops honouring the pass deadline" "$DRIVER"   's@^      if lane_pass_expired @      if false \&\& lane_pass_expired @' stops_batching_at_the_pass_deadline
mutate "the base-health gate is removed, so the lane merges onto a red base" "$DRIVER" \
  's@^  if lane_base_is_broken "\$base_sha"; then$@  if false; then@' halts_when_the_base_itself_is_red
mutate "the base-health gate sinks below the walk it exists to skip" "$DRIVER" \
  's@^  if lane_base_is_broken "\$base_sha"; then$@  :  # moved\n@' halts_when_the_base_itself_is_red
mutate "the base-health gate starts halting on a check that merely has not reported" "$DRIVER" \
  's@^  \[ "\${failed:-0}" -gt 0 \]$@  [ $(( ${failed:-0} + ${missing:-0} )) -gt 0 ]@' only_a_definite_failure_halts_the_lane
mutate "the halt stops being explained on the snapshot" "$DRIVER" \
  's@^    printf .> \*\*Halted\.\*\* @    printf '"'"'> \\n@' says_on_the_snapshot_that_it_halted
mutate "the base-health gate reads the merge list rather than its own" "$DRIVER" \
  's%^  local -a REQUIRED=("\${BASE_HEALTH\[@\]}")$%  :%' reads_its_own_list_on_the_base_tip
mutate "an unset base-health list resolves to nothing instead of to the required checks" "$DRIVER" \
  's%^  BASE_HEALTH=("\${REQUIRED\[@\]}")$%  BASE_HEALTH=()%' falls_back_to_the_required_list
mutate "the workflow stops handing the base-health list to the driver" "$CALLEE" \
  's@^          BASE_HEALTH_CHECKS: .*$@          BASE_HEALTH_CHECKS: x@' passes_the_base_health_list_to_the_driver
mutate "a cancelled check on the base tip goes back to counting as red" "$DRIVER" \
  's%^      cancelled | stale)$%      cancelled-never)%' reads_a_cancelled_base_check_as_unanswered
mutate "the base-tip reading mode is set for the merge path too" "$DRIVER" \
  's%^  local BASE_TIP_READ=1$%BASE_TIP_READ=1%' sets_the_base_tip_handle_only_in_the_gate
mutate "the batch stops re-reading the base between merges" "$DRIVER" \
  's@^        if ! lane_base_is_vouched "\$tip_now" "\$tip_at"; then$@        if false; then@' waits_for_the_tip_between_merges
mutate "only the batch waits, and the next pass merges anyway" "$DRIVER" \
  's@^  if ! lane_base_is_vouched "\$base_sha" "\$base_at"; then$@  if false; then@' waits_for_the_tip_at_the_top_of_a_pass
mutate "the wait for a base-health answer loses its ceiling" "$DRIVER" \
  's@^  if \[ "\$age" -ge "\$BASE_HEALTH_GRACE" \]; then$@  if false; then@' the_wait_for_an_answer_is_bounded
mutate "the staleness window becomes on-by-default for the whole fleet" "$DRIVER" \
  's@^BASE_HEALTH_MAX_STALENESS=.*$@BASE_HEALTH_MAX_STALENESS="600"@' the_staleness_window_is_off_by_default
mutate "the window stays open after the lane has merged" "$DRIVER" \
  's@^        LANE_MERGED_THIS_RUN=1$@        :@' the_staleness_window_closes_after_the_lane_merges
mutate "a red ancestor stops halting the walk" "$DRIVER" \
  's@^      1) return 1 ;;$@      1) : ;;@' a_red_ancestor_inside_the_window_halts_the_lane
mutate "the ancestor walk loses its age bound" "$DRIVER" \
  's@^    \[ "\$age" -lt "\$BASE_HEALTH_MAX_STALENESS" \] || break$@    :@' the_window_walk_is_bounded
mutate "the workflow stops handing the staleness window to the driver" "$CALLEE" \
  's@^          BASE_HEALTH_MAX_STALENESS: .*$@          BASE_HEALTH_MAX_STALENESS: 0@' passes_the_staleness_window_to_the_driver
mutate "armed-ness starts being decided against the tip the merge just made" "$DRIVER" \
  's@^  if \[ "\$LANE_BASE_VERDICT" = .inert. \]; then LANE_BASE_ARMED=..; else LANE_BASE_ARMED=1; fi$@  :@' decides_armed_ness_before_the_batch_moves_the_tip
mutate "an unwatched base becomes indistinguishable from an unanswered one" "$DRIVER" \
  "s@^    LANE_BASE_VERDICT='inert'\$@    LANE_BASE_VERDICT='unanswered'@" tells_an_unanswered_tip_from_an_unwatched_one
mutate "a refused action no longer ends the batch" "$DRIVER" \
  's@^      \[ "\$take_rc" -eq 2 \] || break$@      :@' ends_the_batch_on_a_refusal
mutate "gh's stderr goes back to the log instead of the annotation" "$DRIVER" \
  's@ --silent 2>&1)"@ --silent)"@' quotes_what_github_actually_said
mutate "the workflows-permission refusal stops being named" "$DRIVER" \
  "s@^    \*'workflows'\*permission\*)\$@    *'workflows-never'*permission*)@" names_the_workflows_permission_refusal
mutate "the unasked comparison starts reporting itself as up to date" "$DRIVER" \
  "s@^      behind_cell='n/a'\$@      behind_cell=\"\$behind\"@" says_when_it_did_not_ask_how_far_behind

mutate "the comparison error is swallowed again" "$DRIVER" \
  's@2>"\$cmp_err"@2>/dev/null@' reports_why_the_comparison_failed
mutate "the moved-base guard is removed" "$DRIVER" \
  's@\[ "\$base_now" != "\$base_sha" \]@false@' refuses_a_base_that_moved
mutate "the release stops being recorded per sha" "$DRIVER" \
  's@merge-lane:released:@merge-lane-released@' announces_a_release_once

mutate "the job summary stops being written" "$DRIVER" \
  's@^publish_step_summary$@# publish_step_summary@' publishes_the_queue_where_it_costs_nothing
mutate "an unwritable status issue starts failing the run" "$DRIVER" \
  's@::warning::could not update the queue issue@::error::could not update issue@' survives_an_unpublishable_status_issue
mutate "the status issue is written without checking what it is" "$DRIVER" \
  's@if \[ "\$kind" != "issue" \]; then@if false; then@' refuses_to_overwrite_a_pull_request_body
mutate "the unreadable candidates drop out of the view" "$DRIVER" \
  's@^        queue_row 8 "\$num" "\$title" wait:base-comparison-unreadable.*@        :@' shows_the_candidates_it_could_not_judge
mutate "the queue is accumulated across passes instead of reset" "$DRIVER" \
  's@^  QUEUE_ROWS=()$@  :@' snapshots_the_pass_that_just_ran
mutate "a queue field goes in raw" "$DRIVER" \
  's@"\$(qf "\$3")"@"\$3"@' never_writes_an_empty_queue_field

mutate "an input description gets an expression written into it again" "$CALLEE" \
  's@`vars.MERGE_LANE_REQUIRE_LABEL || .ready-to-merge.`, in an expression.@`${{ vars.MERGE_LANE_REQUIRE_LABEL }}`.@' \
  declares_its_inputs_without_a_live_expression

mutate "status-issue stops reaching the driver" "$CALLEE" \
  's@^          STATUS_ISSUE: .*@          X_UNUSED: 0@' passes_the_status_issue_to_the_driver

mutate "the list read stops carrying the label, so the gate needs a per-pull-request call again" "$DRIVER" \
  's@((\.labels // \[\]) | map(\.name) | join(","))@""@' \
  gates_on_the_label_before_it_spends_anything
mutate "the cheap gate goes back to reading the detail copy, below the calls it exists to avoid" "$DRIVER" \
  's@",\$list_labels," != @",$labels," != @' \
  gates_on_the_label_before_it_spends_anything
mutate "the pin waiver stops asking who wrote the pull request, so any unlabelled one is waived" "$DRIVER" \
  's@^  \[ "\$author" = "\$PIN_BUMP_ACTOR" \] || return 1@  :@' \
  waives_the_label_only_for_a_pin_only_diff
mutate "the pin waiver stops refusing a changed line that is not a pin" "$DRIVER" \
  's@\*uses:\*"\$PIN_BUMP_REPO/\.github/workflows/"\*) saw_pin=1 ;;@*) saw_pin=1 ;;@' \
  waives_the_label_only_for_a_pin_only_diff
mutate "the pin waiver arms itself by default" "$DRIVER" \
  's@^PIN_BUMP_ACTOR="\${PIN_BUMP_ACTOR:-}"@PIN_BUMP_ACTOR="${PIN_BUMP_ACTOR:-dependabot[bot]}"@' \
  the_pin_waiver_is_off_by_default
mutate "the authoritative gate forgets the waiver the cheap one granted" "$DRIVER" \
  's@if \[ "\$pin_waiver" -eq 0 \] && \[ -n "\$REQUIRE_LABEL" \]@if [ -n "$REQUIRE_LABEL" ]@' \
  the_pin_waiver_is_asked_only_when_the_label_is_missing
mutate "the pin waiver stops reaching the driver" "$CALLEE" \
  's@^          PIN_BUMP_ACTOR: .*@          X_UNUSED_PIN: 0@' \
  passes_the_pin_waiver_to_the_driver

mutate "the authoritative gate sinks back below the loop that sleeps" "$DRIVER" \
  's@",\$labels," != @",$detail_labels," != @' \
  skips_before_it_sleeps

mutate "the pass loses its deadline and waits for the job's ceiling instead" "$DRIVER" \
  's@^    if lane_pass_expired @    if false \&\& lane_deadline_gone @' \
  stops_walking_when_the_pass_runs_out_of_time
mutate "the truncation flag goes back to 0, so a pass that read NOTHING reports as complete" "$DRIVER" \
  's@truncated_at=-1@truncated_at=0@' \
  stops_walking_when_the_pass_runs_out_of_time
mutate "a truncated pass downgrades to a notice, which writes no annotation" "$DRIVER" \
  's@::warning::lane: pass truncated@::notice::lane: pass truncated@' \
  stops_walking_when_the_pass_runs_out_of_time
mutate "the truncation stops saying how much of the list it read" "$DRIVER" \
  's@read \$read_count of \$total@stopped early@' \
  stops_walking_when_the_pass_runs_out_of_time

mutate "the pull request list swallows its exit status, so a blind lane reports a quiet day" "$DRIVER" \
  's@if ! prs_raw="\$(gh api --paginate@if false; prs_raw="$(gh api --paginate@' \
  fails_closed_on_an_unreadable_pull_request_list
mutate "the record-shape assertion is dropped, so a short read slides every field" "$DRIVER" \
  's|pr_fields\[@\]} % 6)) -ne 0|pr_fields[@]} % 6)) -ne 999|' \
  fails_closed_on_an_unreadable_pull_request_list

mutate "the pass budget stops reaching the driver" "$CALLEE" \
  's@PASS_BUDGET: [$][{][{] inputs.pass-budget-seconds [}][}]@PASS_BUDGET_UNUSED: ${{ inputs.pass-budget-seconds }}@' \
  passes_the_pass_budget_to_the_driver
mutate "the pass budget is raised past the job's own ceiling" "$CALLEE" \
  's@^        default: 600$@        default: 1800@' \
  the_lane_runs_out_of_time_before_the_job_does
mutate "the job timeout is cut below the pass budget" "$CALLEE" \
  's@^    timeout-minutes: 15$@    timeout-minutes: 5@' \
  the_lane_runs_out_of_time_before_the_job_does

mutate "the documented example loses its concurrency block" "$DOC" \
  's@^concurrency:@# concurrency:@' documented_example_survives_the_consumer_gates
mutate "the documented example loses its RUNNER7 declaration" "$DOC" \
  's@# remote-reusable-allowed@# remote-reusable-was-allowed@' documented_example_survives_the_consumer_gates
mutate "the documented label gate goes back to the bare variable, which is empty when unset" "$DOC" \
  "s@require-label: \\\${{ vars.MERGE_LANE_REQUIRE_LABEL || 'ready-to-merge' }}@require-label: \\\${{ vars.MERGE_LANE_REQUIRE_LABEL }}@" \
  documented_label_gate_fails_closed

# ---------------------------------------------------------------------------
# The automated-review gate.
#
# This is the one gate in the lane that FAILS OPEN, and the properties worth
# asserting are all about keeping that honest. Two ways to get it wrong:
#
#   1. It stops being bounded — a reviewer that never answers then holds every
#      green pull request in the fleet forever, which is a vendor's billing
#      page acquiring merge authority. Nothing about a hold announces itself,
#      so this failure is silent by construction.
#   2. It stops being paid for — the reads move out of the `merge:ready` arm
#      and become two API calls on every open pull request on every pass, which
#      is exactly the cost that had the lane killed by its own job timeout on
#      IntegrateIT (#444).
#
# And one that is not a failure mode at all: the gate cannot approve anything.
# It only ever converts a `merge` into a `wait`.
# ---------------------------------------------------------------------------

# The wait is bounded, and the expiry says so out loud. A hold with no grace and
# no annotation is the deadlock above.
the_review_wait_is_bounded() {
  local code
  code=$(code_of "$1")
  matches "$code" 'lane_review_gate .*REVIEW_GRACE' || return 1
  matches "$code" 'REVIEW_GRACE="\$\{REVIEW_GRACE:-[0-9]+\}"' || return 1
  # `#$action_num`, not `#$num`: the annotation is written where the merge is
  # taken, not where the candidate is classified. The walk sees every expired
  # candidate and merges at most one of them, so an annotation written in the
  # walk claims merges that never happen — and this is the surface an operator
  # reads to decide the reviewer is down.
  matches "$code" '::warning::lane: #\$action_num merging UNREVIEWED'
}

# The verdict has to SURVIVE the walk to be sayable at the merge. It rides the
# candidate tuple; a tuple that drops the field turns the annotation into a
# permanently empty string and the detection surface goes quiet rather than
# noisy — the failure direction that is never noticed.
the_unreviewed_verdict_reaches_the_merge() {
  local code
  code=$(code_of "$1")
  matches "$code" 'candidates\+=\("\$key.*\$unreviewed"\)' || return 1
  matches "$code" 'read -r _ action_num action_sha action_verdict action_unreviewed' || return 1
  matches "$code" 'if \[ -n "\$action_unreviewed" \]; then'
}

# Only a pull request the lane has already decided to merge pays for the two
# reads. `#444` is what this costs when it is wrong.
the_review_gate_is_asked_only_of_a_ready_merge() {
  local code
  code=$(code_of "$1")
  matches "$code" '\[ "\$\{verdict%%:\*\}" = "merge" \]' || return 1
  before "$code" 'verdict="\$\(lane_verdict' 'read -r answered unavailable'
}

# An unreadable surface is not an unanswered one. `review_answered` returning 0
# on a rate limit would hold a green pull request for the whole grace on every
# pass and then merge it with a warning that names the wrong cause.
an_unreadable_review_surface_is_not_an_unanswered_one() {
  local code n
  code=$(code_of "$1")
  n=$(printf '%s\n' "$code" | grep -cE '^    echo "-1 0 0"$')
  [ "${n:-0}" -eq 2 ]
}

# A REVIEWER THAT CANNOT REVIEW HAS ANSWERED, and the lane must stop waiting for
# it. Copilot reports a rate limit by CONCLUDING ITS OWN CHECK RUN red against
# the head sha and publishing neither a review nor a comment — measured
# 2026-08-30, on every pull request in the fleet at once, for seven hours.
# Without this surface each of those pull requests burns the full grace and then
# merges with a warning naming a cause that is not the cause.
#
# Three things have to hold together, and the last is the one that matters:
# only a NON-GREEN conclusion counts. A reviewer that ran and had something to
# say also concludes its check run — green — and its findings arrive on the two
# surfaces above a moment later. Counting that would discharge the gate ahead of
# the review it exists to wait for, which is worse than the delay it fixes.
a_reviewer_that_declined_counts_as_answered() {
  local code
  code=$(code_of "$1")
  matches "$code" 'commits/\$sha/check-runs\?per_page=100' || return 1
  matches "$code" 'conclusion != "success"' || return 1
  # The login is `x[bot]`; the check run is named `x`.
  matches "$code" 'grep -cxF -- "\$\{bot%\\\[bot\\\]\}"' || return 1
  # Counted separately as well as into `answered`, or the log cannot tell a
  # reviewed pull request from one nobody could review.
  matches "$code" 'u=\$\(\(u \+ 1\)\)' || return 1
  matches "$code" 'echo "\$n \$u \$s"'
}

# A REVIEWER THAT READ AN EARLIER COMMIT IS NOT A REVIEWER THAT IS DOWN, and
# until this counter existed both printed `answered=0`. Copilot reviews the
# first push and stops — fourteen of fifteen merged multi-commit pull requests
# in the fleet had no Copilot review on the head that landed — so the annotation
# documented as "a reviewer is down, go look" was firing on a healthy reviewer
# that was simply never asked again. `pr-guard` asks; this is what says so when
# that did not work.
#
# `stale` must stay DISJOINT from `answered`: a review of an older tree says
# nothing about the new one, and counting it would merge ahead of the review the
# gate exists to wait for. The `continue` above it is what keeps that true.
a_review_of_an_earlier_commit_is_counted_but_not_answered() {
  local code
  code=$(code_of "$1")
  matches "$code" 's=\$\(\(s \+ 1\)\)' || return 1
  # Reached only after every answer arm has declined it.
  before "$code" 'u=\$\(\(u \+ 1\)\)' 's=\$\(\(s \+ 1\)\)' || return 1
  # Rides to the gate, and the gate is what puts it in the verdict line.
  matches "$code" 'lane_review_gate .*"\$unavailable" "\$stale"' || return 1
  # And the annotation reads it, or the operator is sent to the wrong place.
  matches "$code" "\\*' stale='\\*)" || return 1
  # BOTH surfaces, exactly as the answer arms above read both. A reviewer whose
  # only surface is a summary comment would otherwise never be stale, however
  # many earlier commits it had spoken about, and the annotation would go back
  # to naming an outage that is not happening — for precisely the reviewer this
  # function grew its second surface to accommodate.
  #
  # ANCHORED ON THE `||`, and that is the whole assertion. Written without it,
  # this matched the `answered` arm forty lines up — which reads `$comments`
  # too — so it passed with the stale arm reading one surface, which is the
  # exact defect it claims to exclude. Mutation-checked: swapping `$comments`
  # for `$reviews` on this line must turn it red.
  matches "$code" '\|\| printf .%s.n. "[$]comments"'
}

# A clean Codex review publishes no review object at all — only a summary
# comment naming the commit. Reading one surface holds every clean pull request
# for the full grace and then warns that nobody reviewed it.
both_review_surfaces_are_read() {
  local code
  code=$(code_of "$1")
  matches "$code" 'pulls/\$num/reviews' || return 1
  matches "$code" 'issues/\$num/comments\?per_page=100' || return 1
  matches "$code" 'grep -cF -- "\$short"'
}

# The clock starts when CI went green, not when the branch was pushed. The
# commit date would charge a pull request for its own CI run and expire the
# grace before the first pass on anything opened yesterday.
the_review_clock_starts_at_green() {
  local code
  code=$(code_of "$1")
  matches "$code" 'check-runs\?per_page=100' || return 1
  matches "$code" 'select\(\.completed_at\)'
}

# A REQUIRED CONTEXT MAY BE A LEGACY COMMIT STATUS, and `check_counts` already
# accepts one — so a repository whose required contexts are all statuses is a
# supported configuration with no check-runs at all. Read only the check-run
# surface and that repository has no clock: empty reads as expired, and the hold
# ends the moment it begins. The failure is silent on both sides, which is why it
# is asserted here rather than left to a repository to discover.
the_review_clock_reads_the_commit_status_surface() {
  local code
  code=$(code_of "$1")
  matches "$code" 'commits/\$sha/status\?per_page=100' || return 1
  matches "$code" '\.statuses\[\]' || return 1
  matches "$code" 'select\(\.updated_at\)'
}

# And it counts only the checks the operator called required. Unfiltered, a slow
# optional job or a coverage bot moves the clock forward and holds a green pull
# request past the configured grace — the same list `check_counts` judges, or
# the two disagree about when the pull request went green.
the_review_clock_is_confined_to_the_required_contexts() {
  local code
  code=$(code_of "$1")
  matches "$code" '--argjson req' || return 1
  matches "$code" 'inside\(\$req\)'
}

passes_the_review_gate_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" '^      review-bots:' || return 1
  matches "$code" '^      review-grace-seconds:' || return 1
  matches "$code" 'REVIEW_BOTS_INPUT: \$\{\{ inputs.review-bots \}\}' || return 1
  matches "$code" 'REVIEW_GRACE: \$\{\{ inputs.review-grace-seconds \}\}'
}

check the_review_wait_is_bounded "$DRIVER" "the wait for an automated review has no ceiling or expires silently, so a reviewer that stops answering — a Codex account out of credits is the ordinary way — holds every green pull request in the fleet with nothing in any log saying why"
check the_review_gate_is_asked_only_of_a_ready_merge "$DRIVER" "the review reads happen before the merge verdict, so every open pull request pays two API calls per pass and the cost tracks the size of the repository — the #444 defect, rebuilt"
check an_unreadable_review_surface_is_not_an_unanswered_one "$DRIVER" "an unreadable review surface counts as nobody having answered, so a rate limit holds a green pull request for the whole grace and then blames the reviewer"
check both_review_surfaces_are_read "$DRIVER" "only the review surface is read, so a Codex review that found nothing — which publishes a summary comment and no review — reads as no review at all"
check a_reviewer_that_declined_counts_as_answered "$DRIVER" "a reviewer that reported it CANNOT review — a rate-limited Copilot, which fails its own check run and publishes nothing else — is still waited for, so every green pull request in the fleet burns the full grace and then merges with a warning blaming the wrong thing"
check a_review_of_an_earlier_commit_is_counted_but_not_answered "$DRIVER" "a reviewer that read an EARLIER commit here reads identically to a reviewer that is down, so every moved head merges with an annotation sending an operator to check a vendor outage that is not happening"
check the_review_clock_starts_at_green "$DRIVER" "the review grace is measured from something other than the last check finishing, so a pull request opened yesterday exhausts it before the reviewer is even asked"
check the_review_clock_reads_the_commit_status_surface "$DRIVER" "the review clock reads only the check-run surface, so a repository whose required contexts are legacy commit statuses has no clock at all — the grace expires the instant it is armed and the gate waits for nobody, with nothing in any log saying so"
check the_review_clock_is_confined_to_the_required_contexts "$DRIVER" "the review clock counts any check at all, so a slow optional job or a coverage bot moves it forward and holds a green pull request well past the grace the operator configured"
check the_unreviewed_verdict_reaches_the_merge "$DRIVER" "the unreviewed verdict does not survive the walk, so the annotation an operator reads to spot a reviewer that has stopped answering is written empty or not at all"
check passes_the_review_gate_to_the_driver "$CALLEE" "the workflow declares the review gate but never hands it to the driver, so a repository that arms it merges unreviewed and nothing says so"

mutate "the review gate loses its grace and becomes an unbounded hold" "$DRIVER" \
  's|"\$review_age" "\$REVIEW_GRACE"|"$review_age" ""|' \
  the_review_wait_is_bounded
mutate "merging unreviewed downgrades to a notice, which writes no annotation" "$DRIVER" \
  's@::warning::lane: #\$action_num merging UNREVIEWED@::notice::lane: #$action_num merging UNREVIEWED@' \
  the_review_wait_is_bounded
mutate "the unreviewed verdict stops riding the candidate tuple" "$DRIVER" \
  's@	\$unreviewed")@")@' \
  the_unreviewed_verdict_reaches_the_merge
mutate "the review reads stop being confined to a ready merge" "$DRIVER" \
  's|= "merge" \]; then|= "" ]; then|' \
  the_review_gate_is_asked_only_of_a_ready_merge
mutate "a review of an earlier commit stops being counted, so it reads as an outage" "$DRIVER" \
  's@s=$((s + 1))@:@' \
  a_review_of_an_earlier_commit_is_counted_but_not_answered
mutate "the stale count stops riding to the gate, so no verdict line carries it" "$DRIVER" \
  's@"$unavailable" "$stale"@"$unavailable"@' \
  a_review_of_an_earlier_commit_is_counted_but_not_answered
mutate "an unreadable review surface starts counting as zero answers" "$DRIVER" \
  's@^    echo "-1 0 0"$@    echo "0 0 0"@' \
  an_unreadable_review_surface_is_not_an_unanswered_one
mutate "the declined-reviewer surface is dropped, so a rate limit reads as silence" "$DRIVER" \
  's@commits/\$sha/check-runs?per_page=100@commits/$sha/check-runs-unused?per_page=100@' \
  a_reviewer_that_declined_counts_as_answered
mutate "a GREEN reviewer check run starts discharging the gate ahead of its own review" "$DRIVER" \
  's@select(.conclusion != "success" and@select(.conclusion != "no-such-conclusion" and@' \
  a_reviewer_that_declined_counts_as_answered
mutate "the comment surface is dropped, so a clean review reads as no review" "$DRIVER" \
  's@issues/\$num/comments?per_page=100@issues/$num/comments-unused?per_page=100@' \
  both_review_surfaces_are_read
mutate "the review clock goes back to when the checks started" "$DRIVER" \
  's@select(.completed_at) | {name: .name, at: .completed_at}@select(.started_at) | {name: .name, at: .started_at}@' \
  the_review_clock_starts_at_green
mutate "the review clock drops the commit-status surface" "$DRIVER" \
  's@commits/\$sha/status?per_page=100@commits/$sha/status-unused?per_page=100@' \
  the_review_clock_reads_the_commit_status_surface
mutate "the review clock stops confining itself to the required contexts" "$DRIVER" \
  's@select(\[.name\] | inside(\$req))@select(true)@' \
  the_review_clock_is_confined_to_the_required_contexts
mutate "the review bots stop reaching the driver" "$CALLEE" \
  's@REVIEW_BOTS_INPUT: [$][{][{] inputs.review-bots [}][}]@REVIEW_BOTS_UNUSED: ${{ inputs.review-bots }}@' \
  passes_the_review_gate_to_the_driver

if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane: $FAIL failed, $PASS passed"
  exit 1
fi
echo "merge-lane: $PASS checks pass"
