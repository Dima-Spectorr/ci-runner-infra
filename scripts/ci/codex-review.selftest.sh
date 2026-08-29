#!/usr/bin/env bash
# Self-test for the automated-review trigger: the rule, and the wiring around it.
#
# This workflow SPENDS MONEY, and it is dispatched by `workflow_run`, so — like
# the merge lane — the pull request that changes it cannot exercise it even
# once. The first live run is the first CI completion after the merge. These
# cases are the entire test.
#
# The weighting follows the cost of being wrong, and it is asymmetric in the
# opposite direction from the merge lane's. There, a wrong `merge` lands
# unchecked code and a wrong `skip` costs a wait. Here, a wrong `skip` costs a
# review somebody asks for by hand — visible, one comment to fix — and a wrong
# `request` costs credits, repeatedly, silently, on every CI completion for as
# long as the pull request is open. So every unreadable input is asserted to
# decline to spend.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/codex-review-decision.sh"

CALLEE="$ROOT/.github/workflows/codex-review.yml"
CALLER="$ROOT/.github/workflows/codex-review-self.yml"
DRIVER="$ROOT/scripts/ci/codex-review.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

for f in "$CALLEE" "$CALLER" "$DRIVER"; do
  [ -f "$f" ] || {
    printf 'FAIL: missing %s — every check below would be vacuous\n' "$f"
    exit 1
  }
done

# Code only: full-line comments stripped, so the rationale above each property
# can never be what satisfies the check for that property.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# --- the rule -----------------------------------------------------------------

expect() { # <expected-prefix> <desc> <args...>
  local want="$1" desc="$2" got
  shift 2
  got=$(review_request_verdict "$@")
  if [[ "$got" == "$want"* ]]; then
    ok
  else
    bad "$(printf '%s\n  args: %s\n  want: %s*\n  got:  %s' "$desc" "$*" "$want" "$got")"
  fi
}

# args: conclusion draft state requested [author] [skip_authors]

# The one verdict that spends.
expect "request:green" "green, open, not a draft, not asked before" success 0 open 0
expect "request:green" "an author with no skip list configured" success 0 open 0 someone ''
expect "request:green" "an author who is not on the skip list" success 0 open 0 someone 'dependabot[bot]'

# Invariant A. Every conclusion that is not `success` — and there are more of
# them than people remember, which is why this is a whitelist rather than a
# test for `failure`.
expect "skip:not-green" "a failed run is the whole reason this workflow exists" failure 0 open 0
expect "skip:not-green" "a cancelled run reached no verdict" cancelled 0 open 0
expect "skip:not-green" "a timed-out run reached no verdict" timed_out 0 open 0
expect "skip:not-green" "an action-required run is not a pass" action_required 0 open 0
expect "skip:not-green" "a skipped run proved nothing about this diff" skipped 0 open 0
expect "skip:not-green" "a neutral run declined to judge" neutral 0 open 0
expect "skip:not-green" "an empty conclusion is a run still going, not a green one" "" 0 open 0
expect "skip:not-green" "a conclusion nobody has heard of does not spend" banana 0 open 0
# The one that would be easy to get wrong with a case-insensitive comparison.
expect "skip:not-green" "SUCCESS is not the string GitHub sends" SUCCESS 0 open 0

# Invariant B. The trigger fires on every CI completion and a re-run IS a
# completion, so this is not an edge case — it is the second-most-common path.
expect "skip:already-requested" "asked once for this sha already" success 0 open 1
expect "skip:already-requested" "an unreadable comment surface must not authorise a second purchase" success 0 open ""
expect "skip:already-requested" "a garbled marker count does not spend" success 0 open maybe

# Invariant D, and the closed pull request.
expect "skip:draft" "a draft is the author saying not yet" success 1 open 0
expect "skip:not-open" "merged while its CI was finishing" success 0 closed 0
expect "skip:not-open" "closed while its CI was finishing" success 0 CLOSED 0

expect "skip:author" "a bot whose pull requests are not what the credits are for" \
  success 0 open 0 'dependabot[bot]' 'dependabot[bot]'
expect "skip:author" "one of several skipped authors" \
  success 0 open 0 'renovate[bot]' 'dependabot[bot] renovate[bot]'
# The ordering that matters: a skip list must not turn a red run green, and a
# draft must not become reviewable by having an ordinary author.
expect "skip:not-green" "the skip list is not consulted before the conclusion" \
  failure 0 open 0 someone 'dependabot[bot]'
expect "skip:draft" "an ordinary author does not make a draft reviewable" \
  success 1 open 0 someone 'dependabot[bot]'

# The marker names the sha and only the sha. Invariant C — a new green version
# is a new review — is exactly this, and a marker that named the pull request
# instead would review the first green version of a branch and nothing after it.
if [ "$(review_marker abc123)" = "$(review_marker abc124)" ]; then
  bad "the request marker does not distinguish two commits, so a pull request is reviewed once and never again"
else
  ok
fi
if printf '%s' "$(review_marker abc123)" | grep -cE '^<!--.*-->$' >/dev/null; then ok; else
  bad "the request marker is not an HTML comment, so it renders as noise on every pull request it is written to"
fi

# --- the wiring ---------------------------------------------------------------

# A callee with a second trigger would run on its own account, with no inputs
# set — the same property the merge lane's callee has, for the same reason.
#
# Counted inside the `on:` block only. A job name is also a two-space key, so
# counting them across the whole file would make this fail on a correct workflow
# — and a check that fails on the correct shape gets edited until it passes,
# which is how a property stops being one.
is_reusable_only() {
  local triggers
  triggers=$(code_of "$1" | sed -n '/^on:/,/^[a-z]/p' | grep -E '^  [a-z_]+:' || true)
  matches "$triggers" '^  workflow_call:' || return 1
  local n
  n=$(printf '%s\n' "$triggers" | grep -cE '^  [a-z_]+:' || true)
  [ "${n:-0}" -eq 1 ]
}

# THE TRIGGER IS THE WHOLE POINT. A caller that fires on `pull_request` is the
# vendor's automatic review rebuilt in YAML: it would ask before CI has said
# anything, which is what this exists to stop.
fires_only_on_a_completed_run() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  workflow_run:' || return 1
  matches "$code" '^    types: \[completed\]' || return 1
  ! matches "$code" '^  pull_request(_target)?:'
}

# The conclusion has to REACH the rule. A caller that hands over the sha and not
# the conclusion asks for a review of every completion, red ones included, and
# nothing in the logs would look wrong.
passes_the_conclusion_to_the_driver() {
  local code
  code=$(code_of "$1")
  matches "$code" 'CONCLUSION: \$\{\{ inputs.conclusion \}\}' || return 1
  matches "$code" 'HEAD_SHA: \$\{\{ inputs.head-sha \}\}'
}

# Two writes where one would do is two things that can half-happen: a marker
# without a request is a review never asked for, a request without a marker is
# one paid review per CI completion forever.
asks_and_records_in_one_comment() {
  local code
  code=$(code_of "$1")
  local n
  n=$(printf '%s\n' "$code" | grep -cE 'issues/\$num/comments" -f body=' || true)
  [ "${n:-0}" -eq 1 ] || return 1
  matches "$code" 'body="\$COMMAND'
}

# An unreadable list of pull requests is not an empty one. This is the failure
# that would otherwise be invisible: the workflow goes green having asked for
# nothing, every pull request waits out the merge lane's grace, and the warning
# blames the reviewer.
fails_closed_on_an_unreadable_pull_request_list() {
  local code
  code=$(code_of "$1")
  matches "$code" 'if ! prs="\$\(gh api --paginate' || return 1
  matches "$code" '::error::codex-review: could not read the pull requests' || return 1
  matches "$code" '^  exit 1$'
}

# Only the pull requests this commit is the HEAD of. Without the filter, a merge
# to the base would ask for a review of every open pull request that contains
# the commit.
reviews_only_the_head_of_a_pull_request() {
  local code
  code=$(code_of "$1")
  matches "$code" 'select\(\.head\.sha == '
}

# Every list endpoint is paginated. A pull request with more than a hundred
# comments would otherwise lose the marker off the end of the first page and be
# reviewed again, at cost, on every CI completion.
reads_every_page() {
  local code n
  code=$(code_of "$1")
  n=$(printf '%s\n' "$code" | grep -cE 'gh api --paginate' || true)
  [ "${n:-0}" -eq 2 ]
}

check() { # <predicate> <file> <description>
  if "$1" "$2"; then ok; else bad "$3"; fi
}

check is_reusable_only "$CALLEE" "the callee has a trigger other than workflow_call, so it runs on its own account with no inputs set and asks for reviews nobody configured"
check fires_only_on_a_completed_run "$CALLER" "the caller fires on something other than a completed run — a pull_request trigger here is the vendor's automatic review rebuilt in YAML, which is what this replaces"
check passes_the_conclusion_to_the_driver "$CALLEE" "the CI conclusion never reaches the rule, so every completion asks for a review and the red ones cost exactly what they cost before"
check asks_and_records_in_one_comment "$DRIVER" "the request and the record are two separate writes, so one can happen without the other: a review never asked for, or one paid review per CI completion for as long as the pull request is open"
check fails_closed_on_an_unreadable_pull_request_list "$DRIVER" "an unreadable pull request list is treated as an empty one, so the workflow goes green having asked for nothing and the merge lane blames the reviewer"
check reviews_only_the_head_of_a_pull_request "$DRIVER" "any pull request containing the commit is reviewed, so a merge to the base asks for a review of the whole backlog"
check reads_every_page "$DRIVER" "a list read is unpaginated, so on a busy pull request the marker falls off the end of the first page and the same commit is reviewed again on every CI completion"

# --- the driver, actually run ------------------------------------------------
#
# Everything above READS the driver. This RUNS it, against a stub `gh`.
#
# The distinction is the point. Every check above is a grep, and a grep cannot
# see the failure mode this script is most exposed to: it runs under `set -e`,
# it is a loop over API output, and a single command leaving a non-zero status
# in the wrong position ends the whole run — exit 0, no error, nothing reviewed,
# on every repository, until somebody notices reviews stopped. That reads
# correctly. It greps correctly. It only fails when it runs.
#
# So the bar here is low and non-negotiable: for each shape, the driver reaches
# its last line, and the verdict it reaches is the one the rule says.

run_driver() { # <fixture> <env...> — prints the driver's output, exit code last
  local fixture="$1"
  shift
  local bin
  bin="$(mktemp -d)"
  cat >"$bin/gh" <<STUB
#!/usr/bin/env bash
# Stub. Answers the three reads/writes the driver makes and nothing else, so an
# unanticipated call shows up as an empty answer rather than a plausible one.
case "\$*" in
  *"/pulls?per_page=100"*) cat "$fixture" ;;
  *"/comments?per_page=100"*) printf '' ;;
  *"/comments"*) echo "STUB-COMMENT-POSTED" >&2 ;;
  *) printf '' ;;
esac
STUB
  chmod +x "$bin/gh" 2>/dev/null || true
  (
    export PATH="$bin:$PATH"
    env "$@" bash "$DRIVER" 2>&1
    echo "exit=$?"
  )
  rm -rf "$bin"
}

driver_case() { # <desc> <fixture-content> <expect-ere> <env...>
  local desc="$1" content="$2" want="$3"
  shift 3
  local fixture out
  fixture="$(mktemp)"
  printf '%s' "$content" >"$fixture"
  out="$(run_driver "$fixture" "$@")"
  if printf '%s\n' "$out" | grep -cE -- "$want" >/dev/null; then
    ok
  else
    bad "$(printf '%s\n  want: %s\n  got:\n%s' "$desc" "$want" "$out")"
  fi
  rm -f "$fixture"
}

# `chmod +x` is a no-op on some filesystems this repository is edited from, and
# a stub that cannot execute would fail every case below for a reason that has
# nothing to do with the driver. Probe once and say so rather than indict the
# code.
_probe="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$_probe/x"
chmod +x "$_probe/x" 2>/dev/null || true
if "$_probe/x" 2>/dev/null; then
  ONE_PR=$'12\tfalse\topen\tsomeone\n'
  TWO_PRS=$'12\tfalse\topen\tsomeone\n13\tfalse\topen\tanother\n'

  driver_case "an ordinary, non-draft pull request does not end the run" \
    "$ONE_PR" 'asked for [0-9]+ review' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=true

  driver_case "a second pull request is still processed after the first" \
    "$TWO_PRS" 'codex-review: #13' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=true

  # Unset DRY_RUN must not spend. This is the shape a consumer produces by
  # copying the caller and forgetting the input.
  driver_case "an unset DRY_RUN is a dry run, not a purchase" \
    "$ONE_PR" 'dry-run — would ask' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success

  driver_case "DRY_RUN=false is the only value that spends" \
    "$ONE_PR" 'asked at abc1234d' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=false

  driver_case "a red conclusion reaches the rule and spends nothing" \
    "$ONE_PR" 'skip:not-green' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=failure DRY_RUN=false

  driver_case "a draft is skipped without ending the run" \
    $'12\ttrue\topen\tsomeone\n' 'skip:draft' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=false

  driver_case "a commit that heads no pull request exits clean" \
    '' 'not the head of any open pull request' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=false

  # Every shape above must END, and `exit=0` is how that is visible. A driver
  # killed by errexit mid-loop also prints `exit=0`, which is why the cases
  # above assert on the LAST line the driver writes rather than on its status.
  driver_case "the run finishes rather than being killed mid-loop" \
    "$TWO_PRS" 'exit=0' \
    GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=true
else
  echo "note: this filesystem grants no execute bit, so the stub-driven driver cases are skipped"
fi
rm -rf "$_probe"

mutate() { # <description> <file> <sed-program> <predicate> — predicate must go false
  local desc="$1" f="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
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

mutate "the callee grows a trigger of its own, so it runs with no inputs set" "$CALLEE" \
  's|^  workflow_call:|  schedule:\n  workflow_call:|' is_reusable_only
mutate "the caller grows a pull_request trigger" "$CALLER" \
  's|^  workflow_run:|  pull_request:\n  workflow_run:|' fires_only_on_a_completed_run
mutate "the conclusion stops reaching the driver" "$CALLEE" \
  's|CONCLUSION: [$][{][{] inputs.conclusion [}][}]|CONCLUSION_UNUSED: ${{ inputs.conclusion }}|' \
  passes_the_conclusion_to_the_driver
mutate "the head filter is dropped, so every pull request containing the commit is reviewed" "$DRIVER" \
  's|select(.head.sha == |select(.number != null and .head.sha != |' \
  reviews_only_the_head_of_a_pull_request
mutate "the comment read loses its pagination" "$DRIVER" \
  's|gh api --paginate "repos/\$R/issues|gh api "repos/$R/issues|' reads_every_page
mutate "the unreadable pull request list stops being fatal" "$DRIVER" \
  's|^  exit 1$|  exit 0|' fails_closed_on_an_unreadable_pull_request_list

if [ "$FAIL" -gt 0 ]; then
  echo "codex-review: $FAIL failed, $PASS passed"
  exit 1
fi
echo "codex-review: $PASS checks pass"
