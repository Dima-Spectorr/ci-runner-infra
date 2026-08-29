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
#
# Every pattern below matches the TEXT of a workflow or a script, in which
# `${{ ... }}` and `$num` are the literal characters that have to be there.
# Single quotes are the point, not an oversight.
# shellcheck disable=SC2016
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
  # Scoped to the lines that follow THAT annotation, not to the file. There is a
  # second `exit 1` at the end of the driver now — the one that reddens a run
  # whose comment POST failed — and a bare file-wide search for it would let
  # this one be deleted while the check went on passing.
  local window
  window=$(printf '%s\n' "$code" | grep -A3 -F '::error::codex-review: could not read the pull requests' || true)
  matches "$window" '^  exit 1$'
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

# A REQUEST THAT WAS NEVER POSTED MUST REDDEN THE RUN.
#
# The annotation alone is not enough. A green run here is what tells an operator
# that the reviewer is slow; if a 403 on the comment POST leaves the run green,
# the only visible consequence is the merge lane waiting out its grace and
# merging unreviewed — and that symptom points at the reviewer rather than at
# the permission. The loop still finishes: one refused pull request must not
# cost the others their review.
reddens_the_run_when_a_request_could_not_be_posted() {
  local code
  code=$(code_of "$1")
  matches "$code" 'failed=\$\(\(failed \+ 1\)\)' || return 1
  matches "$code" 'if \[ \$\(\(failed \+ unread\)\) -gt 0 \]; then'
}

# THE OTHER WAY A REQUEST GOES MISSING WITHOUT ANYONE DECIDING IT SHOULD.
#
# An unreadable comment surface suppresses the request, and that is correct —
# it is the direction that cannot spend twice. What is not correct is doing it
# quietly: nothing was asked for this sha, and nothing will ask again unless CI
# completes again, so the run must end red for the same reason a refused POST
# does. Separate counter, because a refused POST is a permission and an
# unreadable list is usually the API, and the two need different fixes.
reddens_the_run_when_the_comment_surface_was_unreadable() {
  local code
  code=$(code_of "$1")
  matches "$code" 'unread=\$\(\(unread \+ 1\)\)' || return 1
  matches "$code" 'if \[ \$\(\(failed \+ unread\)\) -gt 0 \]; then'
}

# A DRAFT THAT BECOMES READY MUST PRODUCE A CI COMPLETION.
#
# This is the one property that lives in a file neither the caller nor the
# callee owns, and it is asserted here because nothing else would notice it
# going. The rule declines to spend on a draft; the caller is dispatched by CI
# completions only. `opened, synchronize, reopened` — the default set — contains
# no event for "marked ready", so a draft whose last push went green sits at
# that same green sha when it becomes ready, produces no completion, and is
# never reviewed. The merge lane then holds it for its grace and merges it
# unreviewed, which reads as a slow reviewer.
#
# Consumers own their own CI workflow, so for them this is documentation
# (`docs/ai-code-review.md`) rather than a gate. Here it is a gate.
reruns_ci_when_a_draft_becomes_ready() {
  local code
  code=$(code_of "$1")
  matches "$code" '^  pull_request:' || return 1
  matches "$code" '^    types: \[.*ready_for_review.*\]'
}

# A marker is a comment, and on a public repository a comment is something a
# stranger can write. Matched by text alone it is a suppression anyone can post:
# the run concludes `skip:already-requested`, nothing is asked, nothing is red,
# and the merge lane waits out its grace and merges unreviewed.
#
# Asserted structurally as well as behaviourally because the behavioural cases
# need `jq` and skip without it — and the machine this is edited on is exactly
# the kind that skips.
authenticates_the_dedupe_marker() {
  local code
  code=$(code_of "$1")
  matches "$code" 'gh api user --jq' || return 1
  matches "$code" 'marker_author_filter="select\(.user.login == ' || return 1
  matches "$code" "marker_author_filter='select\\(.user.type == " || return 1
  matches "$code" '\$marker_author_filter'
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
check reddens_the_run_when_a_request_could_not_be_posted "$DRIVER" "a comment POST that fails leaves the run green, so the only visible symptom is the merge lane merging unreviewed and the blame lands on the reviewer rather than on the permission"
check reddens_the_run_when_the_comment_surface_was_unreadable "$DRIVER" "an unreadable comment surface suppresses the request and leaves the run green, so nothing was asked for this sha, nothing will ask again, and the only symptom is the merge lane merging unreviewed"
check authenticates_the_dedupe_marker "$DRIVER" "the dedupe marker is matched by text alone, so anyone who can comment on a pull request can suppress its review by posting the marker before CI finishes — and the run says skip:already-requested for a review nobody asked for"
check reruns_ci_when_a_draft_becomes_ready "$ROOT/.github/workflows/ci.yml" "CI does not run when a draft is marked ready, so a draft that went green while it was a draft produces no further completion, is never asked for a review, and the merge lane merges it unreviewed"

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
# Stub. Answers the four reads/writes the driver makes and nothing else, so an
# unanticipated call shows up as an empty answer rather than a plausible one.
#
# The comment read is the one case that does REAL work: it runs the driver's own
# \`--jq\` program over \$STUB_COMMENTS. A stub that ignored the filter and
# returned bodies would pass whatever the driver asked for, which is exactly the
# property under test here — who wrote the marker.
case "\$*" in
  user*|*" user"*)
    # \`/user\` answers a personal access token and refuses the built-in
    # \`GITHUB_TOKEN\` and an App installation token. Unset login stands for
    # the refusal.
    [ -n "\${STUB_LOGIN:-}" ] || exit 1
    printf '%s\n' "\$STUB_LOGIN"
    ;;
  *"/pulls?per_page=100"*) cat "$fixture" ;;
  *"/comments?per_page=100"*)
    expr='' prev=''
    for a in "\$@"; do
      [ "\$prev" = "--jq" ] && expr="\$a"
      prev="\$a"
    done
    printf '%s' "\${STUB_COMMENTS:-[]}" | jq -r "\$expr"
    ;;
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

  # WHOSE MARKER COUNTS. These need a real `jq`, because the property is the
  # driver's own filter program and a stub that ignored it would assert nothing.
  if command -v jq >/dev/null 2>&1; then
    MARKER='<!-- codex-review:requested:abc1234def -->'
    BY_STRANGER="[{\"user\":{\"login\":\"drive-by\",\"type\":\"User\"},\"body\":\"$MARKER\"}]"
    BY_REQUESTER="[{\"user\":{\"login\":\"asker\",\"type\":\"User\"},\"body\":\"$MARKER\"}]"
    BY_BOT="[{\"user\":{\"login\":\"github-actions[bot]\",\"type\":\"Bot\"},\"body\":\"$MARKER\"}]"

    # The reported hole: anyone who can comment posts the marker before CI
    # finishes and the review is silently never asked for.
    driver_case "a stranger's marker does not suppress the request" \
      "$ONE_PR" 'request:green' \
      GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=true \
      STUB_LOGIN=asker STUB_COMMENTS="$BY_STRANGER"

    # And the half that must not break while fixing it: a filter that stops
    # matching the workflow's own marker buys a review per CI completion.
    driver_case "the requester's own marker still suppresses the request" \
      "$ONE_PR" 'skip:already-requested' \
      GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=true \
      STUB_LOGIN=asker STUB_COMMENTS="$BY_REQUESTER"

    # Built-in token: `/user` refuses, so the login cannot be resolved and the
    # filter falls back to "written by a Bot" — still no human, still its own
    # marker.
    driver_case "with no resolvable login a bot's own marker still suppresses" \
      "$ONE_PR" 'skip:already-requested' \
      GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=true \
      STUB_COMMENTS="$BY_BOT"

    driver_case "with no resolvable login a stranger's marker is still refused" \
      "$ONE_PR" 'request:green' \
      GITHUB_REPOSITORY=o/r HEAD_SHA=abc1234def CONCLUSION=success DRY_RUN=true \
      STUB_COMMENTS="$BY_STRANGER"
  else
    echo "note: no jq on this machine, so the marker-authorship cases are skipped"
  fi
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
mutate "a failed request stops reddening the run" "$DRIVER" \
  's|^    failed=$((failed + 1))$|    :|' reddens_the_run_when_a_request_could_not_be_posted
mutate "an unreadable comment surface stops reddening the run" "$DRIVER" \
  's|^    unread=$((unread + 1))$|    :|' reddens_the_run_when_the_comment_surface_was_unreadable
mutate "the marker is read back from any author again" "$DRIVER" \
  's@\$marker_author_filter | @@' authenticates_the_dedupe_marker
mutate "CI stops running when a draft is marked ready" "$ROOT/.github/workflows/ci.yml" \
  's|^    types: \[opened, synchronize, reopened, ready_for_review\]$|    types: [opened, synchronize, reopened]|' \
  reruns_ci_when_a_draft_becomes_ready

if [ "$FAIL" -gt 0 ]; then
  echo "codex-review: $FAIL failed, $PASS passed"
  exit 1
fi
echo "codex-review: $PASS checks pass"
