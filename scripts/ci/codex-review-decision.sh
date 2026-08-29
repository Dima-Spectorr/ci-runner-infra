# shellcheck shell=bash
# codex-review — whether to spend a review on this pull request, as PURE
# functions.
#
# WHY THIS EXISTS
#
# A Codex review costs credits. Configured the obvious way — the vendor's own
# "review every new pull request" switch — the fleet pays for a review of every
# version of every branch, including the ones that never had a chance:
#
#   push, CI red, review paid for
#   fix,  CI red, review paid for
#   fix,  CI green, review paid for
#
# Two of those three reviewed code that was already known to be wrong, and none
# of the three was read by anybody until the last one. The review that matters
# is the one of the version that is about to MERGE, and the cheapest signal that
# a version might be that one is its own CI going green.
#
# So the automatic switch is turned off in the Codex account and the request
# moves here: one comment, on a successful CI completion, once per head sha.
#
# WHY THE LOGIC IS HERE AND NOT IN THE WORKFLOW
#
# The same argument every other `*-decision.sh` in this fleet makes, and it is
# the `merge-lane` argument exactly: the caller is a `workflow_run` workflow, so
# it runs only from the DEFAULT BRANCH and the pull request that changes it
# cannot exercise it even once. Logic in YAML is logic that ships untested.
#
# THE INVARIANTS
#
#  A. NEVER ask for a review of code that is not green. That is the whole point
#     of the change; a `conclusion` that is anything but `success` spends
#     nothing.
#
#  B. NEVER ask twice for the same head sha. The trigger fires on every CI
#     completion, a re-run is a completion, and the fifteen-minute sweep that
#     wakes the merge lane could wake this too — each of which would be another
#     paid review of code already reviewed. The record is a marker in the
#     comment itself, because this fleet stores no state of its own.
#
#  C. A new green version IS a new review. The operator's decision, recorded:
#     each push that reaches green gets one review, so a fix made in response to
#     a review is itself reviewed. Deduplication is per SHA, never per pull
#     request.
#
#  D. A draft is the author saying "not yet", and paying to review it is exactly
#     the waste this file exists to remove.
#
# Tenancy-agnostic — no customer literals, no repository knowledge, no reviewer
# name. Every threshold is an argument.

# ---------------------------------------------------------------------------
# review_request_verdict — the whole rule, over one pull request.
#
#   review_request_verdict <conclusion> <draft> <state> <requested> [author] [skip_authors]
#
# conclusion    the CI run's conclusion: success, failure, cancelled, ...
# draft         1 if the pull request is a draft, else 0
# state         the pull request's state: open, closed
# requested     1 if a request has already been recorded for this head sha
# author        the pull request's author login, optional
# skip_authors  space-separated logins whose pull requests are never reviewed,
#               optional. In practice `dependabot[bot]`: a lockfile bump is not
#               what the credits are for.
#
# Prints exactly one `verdict:reason` line and returns 0. An unreadable input is
# a verdict rather than a crash, and every unreadable input declines to spend —
# the opposite direction from the merge lane, and for the obvious reason: the
# cost of a wrong `skip` is a review somebody asks for by hand, and the cost of
# a wrong `request` is money.
#
# Verdicts:
#   skip:*     spend nothing
#   request:*  ask for a review now
# ---------------------------------------------------------------------------
review_request_verdict() {
  local conclusion="${1:-}"
  local draft="${2:-}"
  local state="${3:-}"
  local requested="${4:-}"
  local author="${5:-}"
  local skip_authors="${6:-}"

  # Invariant A, and it is first because it is the reason for all of this.
  if [ "$conclusion" != "success" ]; then
    echo "skip:not-green conclusion=${conclusion:-unknown}"
    return 0
  fi

  # A pull request that merged or closed while its CI was finishing. The run is
  # green and the code is gone.
  if [ -n "$state" ] && [ "$state" != "open" ]; then
    echo "skip:not-open state=$state"
    return 0
  fi

  # Invariant D.
  if [ "$draft" = "1" ]; then
    echo "skip:draft"
    return 0
  fi

  # Invariant B. Anything that is not an explicit 0 counts as already
  # requested: an unreadable comment surface must not authorise a second
  # purchase, and the failure it produces instead — a review that has to be
  # asked for by hand — is one somebody can see and fix.
  if [ "$requested" != "0" ]; then
    echo "skip:already-requested"
    return 0
  fi

  if [ -n "$author" ] && [ -n "$skip_authors" ]; then
    local a
    for a in $skip_authors; do
      if [ "$a" = "$author" ]; then
        echo "skip:author author=$author"
        return 0
      fi
    done
  fi

  echo "request:green"
  return 0
}

# ---------------------------------------------------------------------------
# review_marker <sha> — the record that a review was bought for this commit.
#
# A hidden HTML comment, in the request comment itself. The same mechanism the
# merge lane's release notice uses, for the same reason: this fleet keeps no
# state of its own, and a marker in a comment survives a run, a restart, a
# re-installation and a change of runner.
#
# It names the SHA and nothing else, which is invariant C — a push produces a
# new sha and therefore a new, warranted request.
# ---------------------------------------------------------------------------
review_marker() { printf '<!-- codex-review:requested:%s -->' "$1"; }
