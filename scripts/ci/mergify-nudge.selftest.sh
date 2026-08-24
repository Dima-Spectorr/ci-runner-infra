#!/usr/bin/env bash
# Self-test for the workflow that tells Mergify its webhook did not arrive.
#
# WHY THIS FILE HAS TO EXIST, RATHER THAN A TEST RUN
#
# `mergify-nudge-self.yml` is triggered by `workflow_run`, and GitHub dispatches
# `workflow_run` from the DEFAULT BRANCH only. The pull request that changes the
# nudge cannot run the nudge. There is no arrangement of jobs that fixes this —
# it is a property of the trigger — so the only evidence available at
# pull-request time is evidence about the TEXT.
#
# That makes this file the whole safety net, and makes the mutations the
# important half of it. A predicate that only passes on correct input is not
# evidence; each mutation below breaks one property the way a later edit
# plausibly would, and asserts that this test goes red for it. Anything that is
# asserted here and not mutated here is asserted by hope.
#
# WHAT IS DELIBERATELY NOT ASSERTED
#
# That the mechanism WORKS — that Mergify reads the comment, honours the
# `commands_restrictions` entry that admits `github-actions[bot]`, and advances
# the pull request. That is a fact about Mergify's servers, it is not decidable
# from this repository, and the first observation of it is the first CI
# completion on main after the merge. `docs/ci-merge-queue-baseline.md` says
# what to look at and what a silent failure looks like.

# The predicates match the TEXT of the workflows, in which `$GRACE`, `$prs` and
# `${{ … }}` are the literal characters that must be there. Expanding them in
# this shell would make every match fail against a file that is perfectly
# correct.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CALLEE="$ROOT/.github/workflows/mergify-nudge.yml"
CALLER="$ROOT/.github/workflows/mergify-nudge-self.yml"
CI="$ROOT/.github/workflows/ci.yml"
MERGIFY="$ROOT/.mergify.yml"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

for f in "$CALLEE" "$CALLER" "$CI" "$MERGIFY"; do
  [ -f "$f" ] || { printf 'FAIL: missing %s — every check below would be vacuous\n' "$f"; exit 1; }
done

# Code only: full-line comments stripped, so the long rationale above each
# property can never be what satisfies the check for that property. Both files
# argue for the properties at length in prose, which is exactly the material
# that would make a naive grep pass over a workflow that lost them.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `… | grep -q` under `set -o pipefail`: grep exits on the first match,
# the writer takes SIGPIPE, and a successful match is then reported as a
# failure. Count instead, and compare.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# The callee: what the nudge does
# ---------------------------------------------------------------------------

# A callee with a second trigger would run on its own account, from a context
# where `github.event.workflow_run` is empty — so every field it reads would be
# blank and the guards would be answering questions about nothing.
is_reusable_only() {
  local code; code=$(code_of "$1")
  matches "$code" '^  workflow_call:' || return 1
  ! matches "$code" '^  (push|pull_request|pull_request_target|schedule|workflow_run|workflow_dispatch|issue_comment):' || return 1
}

# Without this the job cannot post, and a nudge that cannot be posted fails
# exactly like a nudge that was not needed: quietly, with the pull request
# waiting.
can_comment() {
  local code; code=$(code_of "$1")
  matches "$code" '^      pull-requests: write$' || return 1
}

# The scope that governs `/commits/{sha}/check-runs`. Declaring a `permissions:`
# block sets everything unlisted to `none`, so omitting this does not fall back
# to a default read — the probe 403s, `mergify_seen_it` fails closed, and every
# run nudges. Asserted on BOTH files because a callee cannot exceed its caller:
# either half missing produces the same 403.
can_read_check_runs() {
  local code; code=$(code_of "$1")
  matches "$code" '^      checks: read$' || return 1
}

# A red CI run is a queue event too. Dropping `failure` leaves a dead entry
# holding the front of a serial queue until `checks_timeout`.
acts_on_failure_too() {
  local code; code=$(code_of "$1")
  matches "$code" 'success\|failure\|timed_out\)' || return 1
}

# `cancelled` means `cancel-in-progress` superseded the run and a newer one is
# already in flight. Nudging for it posts a comment about a commit nobody is
# waiting on, on every force-push.
ignores_a_non_verdict() {
  local code; code=$(code_of "$1")
  matches "$code" 'is not a verdict Mergify can act on' || return 1
  matches "$code" '^            \*\)$' || return 1
}

# The grace period is what keeps this silent on the healthy majority of runs.
# Removing it turns the nudge into a comment on every CI completion, which is
# how the automation gets muted.
waits_out_the_healthy_case() {
  local code; code=$(code_of "$1")
  matches "$code" 'bounded_sleep "\$GRACE"' || return 1
  matches "$code" 'bounded_sleep "\$INTERVAL"' || return 1
}

# Posting the command ONCE is not a nudge, it is a coin flip. The comment
# reaches Mergify over the same webhook channel that dropped the `check_run`
# event this workflow exists to compensate for; when that delivery is the one
# lost, the pull request waits for Mergify's periodic reconciliation and the
# measured cost is a flat ~10 minutes — three of the first ten nudges in this
# repository did exactly that, which is the original stall reappearing one
# layer up. Re-sending is the entire fix, and it is the kind of loop a later
# reader deletes as redundant because the happy path never enters it.
retries_an_unanswered_nudge() {
  local code; code=$(code_of "$1")
  matches "$code" 'post_nudge "\$nudge"' || return 1
  matches "$code" '\[ "\$nudge" -lt "\$NUDGE_ATTEMPTS" \]' || return 1
  matches "$code" 'bounded_sleep "\$CONFIRM"' || return 1
  # And the retry must be driven by a real re-read of Mergify's check-runs, not
  # by the timer alone: a ladder that posts N comments regardless answers a
  # Mergify that already replied with two more comments.
  matches "$code" 'if mergify_seen_it; then' || return 1
}

# The loop breaks immediately after the last post, so without a trailing wait
# the final comment is the only one never given a chance to be answered — and
# the job does not merely miss a clean exit, it warns that Mergify ignored
# everything. That happened on #372 with Mergify's reply in the same second.
# An alarm that fires on the success path is worse than no alarm.
confirms_the_last_nudge_before_warning() {
  local code; code=$(code_of "$1")
  # The tail after the loop: a wait, a re-read, and a clean exit — all three, or
  # the warning below them is not evidence of anything.
  # Reset on EVERY `done`, so only the run of lines after the LAST one counts.
  # Anchoring on the first `done` instead lets the ladder's own in-loop wait and
  # probe satisfy this, and the assertion passes with the tail deleted. The
  # trailing `[[:space:]]*$` matters: `done <<EOF` closes the loop inside
  # `post_nudge` and a bare `done$` walks straight past it.
  printf '%s\n' "$code" | awk '
    /^[[:space:]]*done([[:space:]].*)?$/    { waited = probed = hit = 0; next }
    /bounded_sleep "\$CONFIRM"/             { waited = 1 }
    waited && /if mergify_seen_it; then/    { probed = 1 }
    probed && /^[[:space:]]*exit 0$/        { hit = 1 }
    END { exit !hit }
  '
}

# `/check-runs` truncates silently. Read one page and a commit busy enough to
# push Mergify's own check past the boundary looks permanently behind — which
# used to cost one redundant comment and now costs the whole ladder.
reads_every_check_run_page() {
  local code; code=$(code_of "$1")
  matches "$code" 'gh api --paginate "repos/\$GITHUB_REPOSITORY/commits/\$HEAD_SHA/check-runs' || return 1
  # Pages arrive as separate JSON documents; without `-s` the query runs once
  # per page and the shell gets several answers where it expects one.
  matches "$code" 'jq -rs' || return 1
}

# And the wait is only worth anything if the answer can stop it. A run that
# waits and then posts regardless is the unconditional version with extra
# latency.
posts_only_when_mergify_is_behind() {
  local code; code=$(code_of "$1")
  matches "$code" 'if mergify_seen_it; then' || return 1
  matches "$code" 'no nudge needed' || return 1
  matches "$code" '^              exit 0$' || return 1
}

# By app, not by check name. `Mergify Merge Protections` is Mergify's name to
# change, and a name that stops matching makes this report "behind" forever —
# a comment on every run, for a reason nobody would look for in a grep pattern.
identifies_mergify_by_app() {
  local code; code=$(code_of "$1")
  matches "$code" 'select\(\.app\.slug == "mergify"\)' || return 1
}

# "Behind" is a comparison, not a state. Without the CI end time this asks
# "has Mergify ever run", which is true on every pull request that has ever
# been evaluated, so it would never nudge at all.
compares_against_the_ci_end_time() {
  local code; code=$(code_of "$1")
  matches "$code" 'ci_ended="\$\(date -u -d "\$RUN_ENDED_AT" \+%s\)"' || return 1
  matches "$code" '\-ge "\$ci_ended"' || return 1
}

# Mergify reads a command only when it STARTS the comment. Any prefix — a
# heading, a quote, an HTML marker — and the comment is prose that nothing acts
# on, while the workflow log still says it nudged.
the_command_starts_the_comment() {
  local code; code=$(code_of "$1")
  matches "$code" "^              '@mergifyio refresh' \\\\$" || return 1
}

# `workflow_run.pull_requests` is EMPTY for a fork pull request. Reading it
# instead would make forks the one case that silently never gets nudged.
resolves_pull_requests_from_the_api() {
  local code; code=$(code_of "$1")
  matches "$code" 'commits/\$HEAD_SHA/pulls' || return 1
  ! matches "$code" 'workflow_run\.pull_requests' || return 1
}

# A draft or closed pull request is not waiting on Mergify, and commenting on
# one is pure noise on somebody's unfinished work.
skips_what_is_not_waiting() {
  local code; code=$(code_of "$1")
  matches "$code" 'select\(\.state == "open"\)' || return 1
  matches "$code" 'select\(\.draft == false\)' || return 1
}

# One commit can head more than one open pull request. Refreshing the first and
# stopping leaves the others in the exact state this exists to clear.
nudges_every_matching_pull_request() {
  local code; code=$(code_of "$1")
  matches "$code" '^            while read -r pr; do$' || return 1
  # `$prs` and its `EOF` stay at ten spaces however deeply the loop is nested:
  # YAML strips exactly that much from the block scalar, which puts the heredoc
  # delimiter at column zero where the shell requires it.
  matches "$code" '^          \$prs$' || return 1
}

# `${{ }}` is substituted before the shell parses the line, so a value carrying
# a quote or a newline becomes shell SYNTAX. `head_branch` and `display_title`
# are attacker-chosen on a fork pull request, and this job holds a write token.
# The whole run body must therefore read from the environment and nothing else.
keeps_expressions_out_of_the_shell() {
  local body
  body=$(sed -n '/run: |/,$p' "$1")
  [ -n "$body" ] || return 1
  ! matches "$body" '\$\{\{' || return 1
}

# The job sleeps by design, so an unbounded one is a job that can sleep for six
# hours against the account's concurrency. But the bound has to be big enough
# to cover the waits it sits over: every one of them is an input, and at
# `confirm-seconds: 240` the ladder needs ~12 minutes, so a hard 10 had GitHub
# cancel the job mid-wait — no final probe, no warning, a red run on a
# configuration this workflow documents as supported.
#
# Deriving it from the inputs is not available: RUNNER6 refuses a
# `timeout-minutes` it cannot resolve to a number, on the grounds that a bound
# nobody can evaluate is not a bound. So it is a literal, and the safety comes
# from the shell clamping its own sleeps to the SAME number — which is only
# true while the two stay equal, and they are in different halves of the file.
is_bounded() {
  local code; code=$(code_of "$1")
  local job env
  job=$(printf '%s\n' "$code" | sed -n 's|^    timeout-minutes: \([0-9]\+\)$|\1|p')
  env=$(printf '%s\n' "$code" | sed -n 's|^          JOB_TIMEOUT_MINUTES: \([0-9]\+\)$|\1|p')
  [ -n "$job" ] && [ "$job" = "$env" ] || return 1
  matches "$code" 'deadline=\$\(\( \$\(date -u \+%s\) \+ JOB_TIMEOUT_MINUTES \* 60' || return 1
  matches "$code" '^          bounded_sleep\(\) \{' || return 1
  # Every wait goes through the clamp, or the one that does not is the one that
  # runs past the timeout.
  ! matches "$code" '^ +sleep "\$(GRACE|INTERVAL|CONFIRM)"$' || return 1
}

# The inputs are `type: number`, not `integer`, so `0.5` is a value a caller can
# legally pass. `[ 0.5 -le 1155 ]` is an arithmetic test: it prints "integer
# expression expected" and returns FALSE, which the clamp reads as "too long"
# and answers by sleeping the whole remaining budget. Every wait must therefore
# be normalised before any comparison sees it, and a value that is not a number
# at all must be named rather than silently treated as zero.
normalises_the_waits() {
  local code; code=$(code_of "$1")
  matches "$code" '^          to_seconds\(\) \{' || return 1
  matches "$code" '::error::\$name must be a non-negative number' || return 1
  local v
  for v in GRACE ATTEMPTS INTERVAL NUDGE_ATTEMPTS CONFIRM; do
    matches "$code" "^          $v=\"\\\$\(to_seconds " || return 1
  done
}

# Running out of budget is a verdict, not a no-op. If `bounded_sleep` reports
# success on a wait it could not take, every later wait returns instantly and
# the ladder posts its remaining nudges back-to-back — the confirmation window
# skipped, and the run signing off by blaming a webhook subsystem that is fine.
stops_when_the_budget_is_spent() {
  local code; code=$(code_of "$1")
  matches "$code" '^          out_of_time=0$' || return 1
  # `bounded_sleep` itself must report the exhaustion, not just the callers:
  # a `return 0` on the path it could not sleep through makes every check below
  # true and still leaves the ladder collapsing into a burst.
  local body
  body=$(printf '%s\n' "$code" | awk '/^          bounded_sleep\(\) \{/,/^          \}$/')
  [ -n "$body" ] || return 1
  # `grep -c … >/dev/null`, not `grep -q`: under `pipefail` a `-q` reader exits
  # on its first match, the in-process writer dies of EPIPE, and the pipeline
  # that FOUND the text reports failure. PFR3 rejects it. `-c` reads to the end
  # and still exits 1 on no match, which is the answer this line wants.
  [ "$(printf '%s\n' "$body" | grep -cE '^ +return 0$')" -eq 0 ] || return 1
  [ "$(printf '%s\n' "$body" | grep -cE '^ +return 1$')" -eq 2 ] || return 1
  # No wait may discard the verdict.
  matches "$code" '^ +bounded_sleep "\$GRACE" \|\| out_of_time=1$'    || return 1
  matches "$code" '^ +bounded_sleep "\$INTERVAL" \|\| out_of_time=1$' || return 1
  matches "$code" '^ +bounded_sleep "\$CONFIRM" \|\| out_of_time=1$'  || return 1
  # The retry loop leaves rather than posting into a window that does not exist.
  matches "$code" '^ +\[ "\$out_of_time" -eq 0 \] \|\| break$'        || return 1
  # And the closing warning names the real fault.
  matches "$code" '^          if \[ "\$out_of_time" -ne 0 \]; then$'  || return 1
  matches "$code" 'stopped after \$nudge of \$NUDGE_ATTEMPTS'         || return 1
}

# ---------------------------------------------------------------------------
# The caller: whether the nudge is ever reached
# ---------------------------------------------------------------------------

triggers_on_ci_completion() {
  local code; code=$(code_of "$1")
  matches "$code" '^  workflow_run:' || return 1
  matches "$code" '^    types: \[completed\]$' || return 1
}

# A newer CI completion must cancel a nudge still sitting in its grace period
# for the previous commit on the same pull request: that older nudge would be
# asking a question about a superseded sha.
supersedes_an_older_nudge() {
  local code; code=$(code_of "$1")
  matches "$code" '^  cancel-in-progress: true$' || return 1
  matches "$code" '^  group: mergify-nudge-' || return 1
}

# …and it must cancel ONLY that pull request's nudge. `head_branch` is the
# SOURCE branch's name, which two pull requests from two forks may share; keyed
# on it they cancel each other, and a nudge cancelled right after the OTHER
# pull request's last required check leaves exactly the stall this workflow
# exists to clear. A separate predicate from the one above because the failure
# is the opposite one: that check asks whether superseding happens at all, this
# asks whether it is confined to one pull request.
cancels_only_its_own_pull_request() {
  local code; code=$(code_of "$1")
  # The group must be derived from the pull request…
  matches "$code" '^  group: mergify-nudge-\$\{\{ github\.event\.workflow_run\.pull_requests\[0\]\.number ' || return 1
  # …and must not be derived from the branch name at all. Asserting the good
  # spelling is not enough on its own: a group naming BOTH would pass that and
  # still collide, because two same-named branches differ only in the half a
  # `||` never reaches.
  ! matches "$code" '^  group: .*head_branch' || return 1
}

# The callee declares the write, but a reusable workflow cannot grant itself
# more than the caller gave it. Omit it here and the callee's declaration is a
# statement about a permission it does not have.
grants_the_write_at_the_call() {
  local code; code=$(code_of "$1")
  matches "$code" '^      pull-requests: write$' || return 1
  matches "$code" 'uses: \./\.github/workflows/mergify-nudge\.yml' || return 1
}

check() { # <predicate> <file> <description>
  if "$1" "$2"; then ok; else bad "$3"; fi
}

echo "mergify-nudge self-test:"
check is_reusable_only                  "$CALLEE" "the callee has a trigger other than workflow_call, so it can run with no workflow_run context"
check can_comment                       "$CALLEE" "the job cannot post a comment, so every nudge is a silent no-op"
check can_read_check_runs               "$CALLEE" "the job cannot read check-runs, so the probe 403s and every run nudges"
check acts_on_failure_too               "$CALLEE" "a failed CI run is not nudged, so a dead queue entry waits out checks_timeout"
check ignores_a_non_verdict             "$CALLEE" "a cancelled or skipped run is nudged, so every force-push posts a comment"
check waits_out_the_healthy_case        "$CALLEE" "the grace period is gone, so the healthy majority of runs post a comment"
check retries_an_unanswered_nudge       "$CALLEE" "an unanswered refresh command is never re-sent, so a lost comment webhook still costs the ~10 minutes this workflow exists to remove"
check confirms_the_last_nudge_before_warning "$CALLEE" "the final nudge is never given the confirmation window the others got, so a Mergify that answered it is still reported as having ignored everything"
check reads_every_check_run_page        "$CALLEE" "the check-run probe reads one page, so a busy commit can hide Mergify's own check and draw the entire ladder"
check posts_only_when_mergify_is_behind "$CALLEE" "the wait cannot end early, so the check on Mergify's state buys nothing"
check identifies_mergify_by_app         "$CALLEE" "Mergify's checks are matched by name rather than by app, which goes stale silently"
check compares_against_the_ci_end_time  "$CALLEE" "'behind' is not compared against anything, so it can never be true"
check the_command_starts_the_comment    "$CALLEE" "the command does not start the comment, so Mergify does not read it"
check resolves_pull_requests_from_the_api "$CALLEE" "the pull request is read from the event payload, which is empty for a fork"
check skips_what_is_not_waiting         "$CALLEE" "draft and closed pull requests are commented on"
check nudges_every_matching_pull_request "$CALLEE" "only the first pull request at this head is nudged"
check keeps_expressions_out_of_the_shell "$CALLEE" "an expression is interpolated into the shell of a job holding a write token"
check is_bounded                        "$CALLEE" "the job that sleeps by design has no timeout"
check normalises_the_waits              "$CALLEE" "a fractional wait reaches an integer comparison, which fails false and makes the clamp sleep the entire remaining budget"
check stops_when_the_budget_is_spent    "$CALLEE" "an exhausted budget is swallowed, so the remaining nudges post back-to-back with no window to answer and the run blames the webhook deliveries"
check triggers_on_ci_completion         "$CALLER" "the caller does not fire on a completed CI run"
check supersedes_an_older_nudge         "$CALLER" "a superseded nudge is not cancelled and will ask about an old sha"
check cancels_only_its_own_pull_request "$CALLER" "the concurrency group is keyed on the branch name, so two forks sharing one cancel each other's nudge"
check grants_the_write_at_the_call      "$CALLER" "the caller does not pass the write the callee needs"
check can_read_check_runs               "$CALLER" "the caller does not pass checks: read, so the callee's own declaration buys nothing"

# The trigger names the CI workflow by its `name:` key, which is the only handle
# `workflow_run` offers. Renaming `ci.yml`'s name detaches the nudge with
# nothing going red anywhere — the workflow simply stops being dispatched. This
# is the one check that reads a file the nudge does not own.
ci_name=$(grep -m1 -E '^name: ' "$CI" | sed 's/^name: //')
if [ -n "$ci_name" ] && matches "$(code_of "$CALLER")" "^    workflows: \[$ci_name\]$"; then ok
else bad "the caller's workflow_run trigger does not name ci.yml's '$ci_name' — the nudge is detached and nothing reports it"; fi

# The other half. Without this entry Mergify discards the comment for want of
# sender permission, in silence, and the only symptom is that nothing improves.
admits_the_bot_sender() {
  local code; code=$(code_of "$1")
  matches "$code" '^commands_restrictions:$' || return 1
  matches "$code" '^  refresh:$' || return 1
  matches "$code" 'sender = github-actions\[bot\]' || return 1
  # Declaring the key replaces the default, so dropping the write clause would
  # lock every human out of a command they can run today.
  matches "$code" 'sender-permission >= write' || return 1
  # The default's OTHER arm, and the one this block shipped without: a fork
  # pull request's author may refresh their own. Not the only route out of a
  # stall — `resolves_pull_requests_from_the_api` above is what makes the nudge
  # reach forks at all — but the one the author still has when the nudge itself
  # is what is broken, and an upstream default is not ours to drop in silence.
  #
  # Asserted as a GROUP, not as two independent line matches: split into two
  # separate arms that each also demand write permission, both lines are still
  # present, the external author is still refused, and a pair of `matches` calls
  # would report green. Raised by Codex against the commit that added them.
  local grouped
  grouped=$(printf '%s\n' "$code" | awk '
    /^[[:space:]]*- and:$/                          { open = 1; n = 0; next }
    open && /^[[:space:]]*- sender = \{\{author\}\}$/ { n++; next }
    open && /^[[:space:]]*- from-fork$/               { n++; next }
                                                    { if (n == 2) hit = 1; open = 0; n = 0 }
    END { if (n == 2) hit = 1; print hit + 0 }
  ')
  [ "$grouped" = "1" ] || return 1
}
check admits_the_bot_sender "$MERGIFY" ".mergify.yml does not admit github-actions[bot] as a refresh sender, so every nudge is discarded in silence"

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
  's|^  workflow_call:|  pull_request:\n  workflow_call:|'            is_reusable_only
mutate "the comment permission is downgraded to read" "$CALLEE" \
  's|^      pull-requests: write$|      pull-requests: read|'         can_comment
mutate "the callee stops granting itself checks: read" "$CALLEE" \
  's|^      checks: read$|      contents: read|'                      can_read_check_runs
mutate "failure is dropped from the verdicts" "$CALLEE" \
  's|success\|failure\|timed_out)|success)|'                          acts_on_failure_too
mutate "the catch-all arm is removed, so every conclusion nudges" "$CALLEE" \
  's|^            \*)$|            never_matches)|'                   ignores_a_non_verdict
mutate "the grace period is removed" "$CALLEE" \
  's|^          bounded_sleep "\$GRACE" .*$|          :|'             waits_out_the_healthy_case
mutate "the retry interval is removed" "$CALLEE" \
  's|^            bounded_sleep "\$INTERVAL" .*$|            :|'       waits_out_the_healthy_case
mutate "the check-run probe stops paginating" "$CALLEE" \
  's|gh api --paginate "repos/\$GITHUB_REPOSITORY/commits|gh api "repos/$GITHUB_REPOSITORY/commits|' reads_every_check_run_page
mutate "the pages are queried one at a time instead of slurped" "$CALLEE" \
  's|jq -rs|jq -r|'                                                   reads_every_check_run_page
mutate "the nudge is posted once and never re-sent" "$CALLEE" \
  's|\[ "\$nudge" -lt "\$NUDGE_ATTEMPTS" \]|false|'                    retries_an_unanswered_nudge
mutate "the retry stops waiting for an answer before re-posting" "$CALLEE" \
  's|bounded_sleep "\$CONFIRM"|:|'                                    retries_an_unanswered_nudge
mutate "the ladder posts on a timer instead of checking Mergify" "$CALLEE" \
  's|if mergify_seen_it; then|if false; then|g'                       retries_an_unanswered_nudge
# Indentation no longer separates the two `bounded_sleep "$CONFIRM"` calls — the
# trailing one is inside the `out_of_time` guard, so both sit twelve spaces deep.
# Delete the guarded block as a range instead; the `-eq 0` opener is unique (the
# final warning tests `-ne 0`, and the attempts loop breaks on one line).
mutate "the last nudge loses the confirmation window and warns over a success" "$CALLEE" \
  '/^          if \[ "\$out_of_time" -eq 0 \]; then$/,/^          fi$/d'  confirms_the_last_nudge_before_warning
mutate "the early exit is removed, so it always posts" "$CALLEE" \
  's|^              exit 0$|              true|'                      posts_only_when_mergify_is_behind
mutate "Mergify is matched by check name instead of by app" "$CALLEE" \
  's|select(\.app\.slug == "mergify")|select(.name == "Mergify Merge Protections")|' identifies_mergify_by_app
mutate "the comparison against the CI end time is dropped" "$CALLEE" \
  's|-ge "\$ci_ended"|-ge 0|'                                         compares_against_the_ci_end_time
mutate "the CI end time is no longer read from the event" "$CALLEE" \
  's|ci_ended="\$(date -u -d "\$RUN_ENDED_AT" +%s)"|ci_ended=0|'      compares_against_the_ci_end_time
mutate "the command is no longer the first line of the comment" "$CALLEE" \
  "s|^              '@mergifyio refresh' \\\\\$|              '#### CI finished' \\\\|" the_command_starts_the_comment
mutate "the pull request is read from the event payload" "$CALLEE" \
  's|commits/\$HEAD_SHA/pulls|../workflow_run.pull_requests|'         resolves_pull_requests_from_the_api
mutate "closed pull requests are no longer filtered out" "$CALLEE" \
  's|select(\.state == "open")|.|'                                    skips_what_is_not_waiting
mutate "drafts are no longer filtered out" "$CALLEE" \
  's|select(\.draft == false)|.|'                                     skips_what_is_not_waiting
mutate "the loop is replaced by a single-shot read of the first pull request" "$CALLEE" \
  's|^            while read -r pr; do$|            pr=${prs%%\\n*}; {|' nudges_every_matching_pull_request
mutate "the loop is fed nothing, so it nudges no pull request at all" "$CALLEE" \
  's|^          \$prs$|          |'                                   nudges_every_matching_pull_request
mutate "an expression is spliced into the shell" "$CALLEE" \
  's|\$RUN_URL|${{ github.event.workflow_run.html_url }}|'            keeps_expressions_out_of_the_shell
mutate "the timeout is removed" "$CALLEE" \
  's|^    timeout-minutes: .*$|    # unbounded|'                      is_bounded
mutate "the job timeout and the clamp drift apart" "$CALLEE" \
  's|^    timeout-minutes: .*$|    timeout-minutes: 10|'              is_bounded
mutate "a wait escapes the clamp and can outlast the timeout" "$CALLEE" \
  's|^          bounded_sleep "\$GRACE" .*$|          sleep "\$GRACE"|' is_bounded
mutate "a fractional input reaches the integer comparison unnormalised" "$CALLEE" \
  's|^          GRACE="\$(to_seconds .*$|          :|'                 normalises_the_waits
mutate "a non-numeric input is accepted instead of named" "$CALLEE" \
  's|^                echo "::error::\$name must be.*$|                :|' normalises_the_waits
mutate "a spent budget is swallowed instead of reported" "$CALLEE" \
  's|^              return 1$|              return 0|'                 stops_when_the_budget_is_spent
mutate "the ladder keeps posting after the budget is spent" "$CALLEE" \
  's@^            \[ "\$out_of_time" -eq 0 \] || break$@            true@' stops_when_the_budget_is_spent
mutate "an overrun is blamed on the webhook deliveries" "$CALLEE" \
  's|^          if \[ "\$out_of_time" -ne 0 \]; then$|          if false; then|' stops_when_the_budget_is_spent

mutate "the caller no longer fires on completion" "$CALLER" \
  's|^    types: \[completed\]$|    types: [requested]|'              triggers_on_ci_completion
mutate "the workflow_run trigger is replaced by a push trigger" "$CALLER" \
  's|^  workflow_run:|  push:|'                                       triggers_on_ci_completion
mutate "a superseded nudge is left running" "$CALLER" \
  's|^  cancel-in-progress: true$|  cancel-in-progress: false|'       supersedes_an_older_nudge
mutate "the group goes back to the branch name" "$CALLER" \
  's|workflow_run\.pull_requests\[0\]\.number|workflow_run.head_branch|' cancels_only_its_own_pull_request
mutate "the group names the branch as well as the pull request" "$CALLER" \
  's|^  group: mergify-nudge-|  group: mergify-nudge-${{ github.event.workflow_run.head_branch }}-|' cancels_only_its_own_pull_request
mutate "the caller stops passing the write" "$CALLER" \
  's|^      pull-requests: write$|      pull-requests: read|'         grants_the_write_at_the_call
mutate "the caller stops passing checks: read" "$CALLER" \
  's|^      checks: read$|      contents: read|'                      can_read_check_runs
mutate "the caller points at a different callee" "$CALLER" \
  's|uses: \./\.github/workflows/mergify-nudge\.yml|uses: ./.github/workflows/ci.yml|' grants_the_write_at_the_call

mutate "the bot sender is dropped from the refresh restriction" "$MERGIFY" \
  's|          - sender = github-actions\[bot\]||'                    admits_the_bot_sender
mutate "the write clause is dropped, locking humans out" "$MERGIFY" \
  's|          - sender-permission >= write||'                        admits_the_bot_sender
mutate "the restriction is renamed to a command that is not the one posted" "$MERGIFY" \
  's|^  refresh:$|  rebase:|'                                         admits_the_bot_sender
mutate "the fork author loses the backstop the nudge cannot give them" "$MERGIFY" \
  's|^              - sender = {{author}}$||'                         admits_the_bot_sender
mutate "the author clause stops being scoped to forks" "$MERGIFY" \
  's|^              - from-fork$||'                                   admits_the_bot_sender
# The mutation the two above cannot catch on their own: both lines survive, so
# a presence check stays green, but they no longer share an `and` — the author
# is admitted only when some OTHER arm already admits them, which is never.
mutate "the two fork clauses stop sharing one and-arm" "$MERGIFY" \
  's|^          - and:$|          - or:|'                             admits_the_bot_sender

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
