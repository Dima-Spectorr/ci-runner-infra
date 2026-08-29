#!/usr/bin/env bash
# codex-review — ask for an automated review of the pull requests a CI run just
# turned green, and of nothing else.
#
# See `codex-review-decision.sh` for the argument. The short form: the vendor's
# own "review every new pull request" switch pays for a review of every version
# of every branch, and on a branch that goes red twice before it goes green that
# is three reviews of which two were of code nobody kept. This asks once, for
# the version that is a candidate to merge.
#
# WHAT THIS DOES NOT DO
#
# It does not decide whether the review was any good, it does not wait for it,
# and it does not gate anything. Holding the merge until the reviewer has
# answered is the merge lane's job — `review-bots` there — and the two halves
# are deliberately separate: this one spends credits, that one spends time.
#
# THE TOKEN QUESTION, WHICH YOU MUST VERIFY ONCE.
#
# The review is requested by COMMENTING, so whatever identity posts the comment
# has to be one the reviewer's App reacts to. The built-in `GITHUB_TOKEN` posts
# as `github-actions[bot]`; an App token posts as that App. GitHub delivers the
# `issue_comment` webhook to installed Apps either way — the suppression rule
# people remember applies to triggering further *workflows*, not to Apps — but
# a reviewer is free to ignore bot comments as a loop guard, and no
# documentation promises it will not.
#
# So: after arming this for the first time, read the pull request. If the
# reviewer answered, the built-in token is enough for the whole fleet. If it did
# not, pass `review-token` — the merge App's token, or a PAT — and it will.
# Nothing here can tell the two apart on its own, which is why it is written
# down rather than detected.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/codex-review-decision.sh"

R="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
HEAD_SHA="${HEAD_SHA:?the head sha of the completed run is required}"
CONCLUSION="${CONCLUSION:-}"
COMMAND="${REVIEW_COMMAND:-@codex review}"
SKIP_AUTHORS="${SKIP_AUTHORS:-}"
# DRY RUN UNLESS SOMEBODY SAID `false`, WHICH IS THE OPPOSITE OF THE OBVIOUS
# READING AND IS THE POINT.
#
# The same convention `merge-lane.sh` uses, for a sharper version of the same
# reason: an unset variable, a typo, a caller that forgot the input, or a
# `vars.*` that does not exist all produce something that is not the string
# `false` — and every one of them must land on "decide and log", not on "spend".
# A default that spends is a default that empties an account the first time a
# consumer copies the caller without reading it.
ARMED=false
if [ "${DRY_RUN:-true}" = "false" ]; then
  ARMED=true
fi

echo "codex-review: repo=$R sha=${HEAD_SHA:0:8} conclusion=${CONCLUSION:-unknown} armed=$ARMED"

# THE PULL REQUESTS THIS COMMIT IS THE HEAD OF.
#
# `workflow_run` hands over a sha, not a pull request — a CI run on a branch
# knows nothing about what is open against it. This endpoint answers the
# question directly, and the `select` narrows it from "pull requests containing
# this commit" to "pull requests whose HEAD is this commit": a merged commit is
# contained by every branch downstream of it, and reviewing those would be the
# same waste in a new shape.
#
# FAILS CLOSED, LOUDLY. An unreadable list is not an empty one. Exiting green on
# a read failure is how this becomes a workflow that has silently asked for
# nothing for a month while every pull request waits out the merge lane's review
# grace.
#
# THE ONE EXCEPTION IS A COMMIT THIS REPOSITORY HAS NEVER HEARD OF, WHICH IS A
# 404 AND IS NOT A FAILURE. On a public repository a CI run can complete for a
# commit that lives in a fork; there is nothing here to review and nothing has
# gone wrong. Treating it as a read failure would paint this workflow red on
# every fork contribution, and a workflow that is always red is a workflow
# nobody reads — including on the day the read failure is real.
if ! prs="$(gh api --paginate "repos/$R/commits/$HEAD_SHA/pulls?per_page=100" \
  --jq ".[] | select(.head.sha == \"$HEAD_SHA\") | [.number, .draft, .state, .user.login] | @tsv" 2>&1)"; then
  if printf '%s' "$prs" | grep -cF -- 'HTTP 404' >/dev/null; then
    echo "codex-review: ${HEAD_SHA:0:8} is not a commit in $R — a fork's run, most likely. Nothing to review."
    exit 0
  fi
  echo "::error::codex-review: could not read the pull requests for ${HEAD_SHA:0:8} — $(printf '%s' "$prs" | tr '\n' ' ' | cut -c1-400)"
  exit 1
fi

if [ -z "$prs" ]; then
  echo "codex-review: ${HEAD_SHA:0:8} is not the head of any open pull request — nothing to review"
  exit 0
fi

requested=0
# A POST THAT FAILED IS A REVIEW THAT WAS NEVER ASKED FOR, AND THE RUN SAYS SO.
#
# The loop below does not stop on one failure — one 403 on one pull request
# should not cost the others their review — but the run must not conclude
# `success` either. The merge lane is on the other end of this: it holds a green
# pull request waiting for an answer, waits out `review-grace-seconds`, and
# merges unreviewed. A green run here would make that look like a slow reviewer
# rather than a request that was never put, and the two need different fixes.
#
# An UNREADABLE COMMENT SURFACE lands in the same place, by the same argument.
# It suppresses the request — that direction cannot spend twice — and a
# suppressed request is a request that was never put, so it is counted and the
# run is red. It gets its own counter because the two need different fixes: a
# refused POST is a permission, an unreadable list is usually the API.
failed=0
unread=0
while IFS=$'\t' read -r num draft state author; do
  [ -n "$num" ] || continue

  # An `if`, not `[ ... ] && isdraft=1`. The list form leaves a non-zero status
  # behind on the common path (a pull request that is not a draft), which is
  # safe here and stops being safe the moment the construct is moved to the end
  # of a function or of the script — where `set -e` reads that status as a
  # failure. Not worth carrying a shape whose safety depends on what follows it.
  isdraft=0
  if [ "$draft" = "true" ]; then
    isdraft=1
  fi

  # Invariant B, and the only read this script makes per pull request. The
  # marker lives in the comment it wrote last time, because this fleet keeps no
  # state of its own — see `review_marker`.
  #
  # An unreadable comment surface counts as ALREADY REQUESTED, which is the
  # direction that cannot spend money twice. The failure it produces instead is
  # a review somebody has to ask for by hand, and that is visible.
  already=0
  if bodies="$(gh api --paginate "repos/$R/issues/$num/comments?per_page=100" --jq '.[].body' 2>/dev/null)"; then
    # `grep -c ... >/dev/null`, never `-q`: under `pipefail` a `-q` that exits on
    # its first match closes the pipe and the writer dies on SIGPIPE.
    if printf '%s\n' "$bodies" | grep -cF -- "$(review_marker "$HEAD_SHA")" >/dev/null; then
      already=1
    fi
  else
    echo "::error::codex-review: #$num — the comment surface is unreadable, so this counts as already asked rather than risking a second paid review. Nothing was asked for ${HEAD_SHA:0:8} and nothing will ask again unless CI completes again."
    already=1
    unread=$((unread + 1))
  fi

  verdict="$(review_request_verdict "$CONCLUSION" "$isdraft" "$state" "$already" "$author" "$SKIP_AUTHORS")"
  echo "codex-review: #$num $verdict (sha=${HEAD_SHA:0:8} author=$author)"

  [ "${verdict%%:*}" = "request" ] || continue

  if [ "$ARMED" != "true" ]; then
    echo "::notice::dry-run — would ask for a review of #$num at ${HEAD_SHA:0:8}"
    continue
  fi

  # The command and the marker in ONE comment. Two comments would be two things
  # that can half-happen: a marker written without a request means a review that
  # is never asked for and never asked for again, and a request written without
  # a marker means one paid review per CI completion for as long as the pull
  # request stays open.
  body="$COMMAND

$(review_marker "$HEAD_SHA")"

  if gh api "repos/$R/issues/$num/comments" -f body="$body" --silent; then
    requested=$((requested + 1))
    echo "codex-review: #$num asked at ${HEAD_SHA:0:8}"
  else
    # Not fatal for the other pull requests in the list — one 403 on one pull
    # request should not stop the rest being asked — but it must not pass
    # silently either, because the merge lane is now waiting for an answer to a
    # question that was never put.
    echo "::error::codex-review: could not comment on #$num. Without the comment nothing was asked, and the merge lane will wait out its review grace and merge unreviewed."
    failed=$((failed + 1))
  fi
done <<<"$prs"

echo "codex-review: asked for $requested review(s)"

if [ "$unread" -gt 0 ]; then
  echo "::error::codex-review: $unread pull request(s) were suppressed by an unreadable comment surface, not by a decision."
fi

if [ $((failed + unread)) -gt 0 ]; then
  echo "::error::codex-review: $((failed + unread)) pull request(s) were not asked. The run is red on purpose — see the annotations above for which, and note that a green run here is what tells an operator the reviewer is slow rather than unasked."
  exit 1
fi
