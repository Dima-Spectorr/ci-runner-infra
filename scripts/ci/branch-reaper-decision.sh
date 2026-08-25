# shellcheck shell=bash
# branch-reaper — whether one branch may be deleted, as a PURE function.
#
# WHY THIS EXISTS
#
# The merge lane squash-merges and leaves the head branch behind. Every session
# in this fleet also works in its own worktree on its own branch, so branches
# accumulate faster here than in a repository with one contributor, and a branch
# list nobody prunes stops being a list you can read — which matters, because
# `git branch -r` is how you find out whether another session already has your
# task in flight.
#
# WHY IT IS A SEPARATE DECISION FROM THE LANE
#
# Blast radius, in the opposite direction. The lane's wrong answer merges
# something; this one's wrong answer DESTROYS something, and the two failures
# want different defaults. A merge can be reverted from the history it just
# wrote. A deleted branch whose commits are not reachable from anywhere is gone:
# GitHub keeps unreachable objects for a while and will restore a ref from the
# UI for a while, but neither is a guarantee and neither is something you want
# to be relying on.
#
# So this file is written the way a delete should be — every unknown is a KEEP,
# and there is no arm that deletes on a fact the caller could not establish.
#
# WHY "MERGED" IS NOT ENOUGH ON ITS OWN
#
# Under a squash merge the branch tip is NOT an ancestor of the default branch,
# so the usual "is it reachable from main" test cannot be used: it would answer
# "no" for every branch this repository has ever merged. The analogue that does
# hold — and it is the one GitHub's own "Delete branch" button uses — is that
# the branch tip is still EXACTLY the head sha that was merged. If someone
# pushed after the merge, those commits were never merged and never reviewed,
# and the branch is live work that happens to have a merged pull request behind
# it.
#
# Tenancy-agnostic: no customer literals, no repository knowledge, no branch
# naming convention. Every threshold is an argument.

# ---------------------------------------------------------------------------
# reaper_verdict — the whole rule, as one function over one branch.
#
#   reaper_verdict <is_default> <protected> <excluded> <base_of_open_pr> \
#                  <has_open_pr> <has_merged_pr> <tip_matches_merged_head> \
#                  <age_days> <min_age_days>
#
# is_default        1 if this is the repository's default branch
# protected         1 if GitHub reports the branch protected
# excluded          1 if the operator's keep-list matches this branch
# base_of_open_pr   1 if any open pull request TARGETS this branch
# has_open_pr       1 if any open pull request has this branch as its head
# has_merged_pr     1 if any pull request with this head was merged
# tip_matches       1 if the branch tip is still the sha that was merged,
#                   0 if it is not, "" if the caller could not establish it
# age_days          whole days since the merge, or "" if unknown
# min_age_days      how old a merged branch must be before it may be deleted
#
# Prints exactly one `verdict:reason key=value...` line and returns 0. An
# unparseable input is a verdict rather than a crash: a reaper that dies on one
# odd branch stops pruning the repository, which is annoying, whereas a reaper
# that guesses deletes work.
#
# Verdicts:
#   keep:*    leave the branch alone, and the reason says why
#   delete:*  the branch is merged, unchanged since the merge, and old enough
# ---------------------------------------------------------------------------
reaper_verdict() {
  local is_default="${1:-}"
  local protected="${2:-}"
  local excluded="${3:-}"
  local base_of_open_pr="${4:-}"
  local has_open_pr="${5:-}"
  local has_merged_pr="${6:-}"
  local tip_matches="${7:-}"
  local age_days="${8:-}"
  local min_age_days="${9:-}"

  # Configuration first. A threshold that did not parse is not "zero days" — it
  # is an operator who typed something wrong, and reading it as zero would
  # delete every merged branch in the repository on the first run.
  if ! [[ "$min_age_days" =~ ^[0-9]+$ ]]; then
    echo "keep:unparseable-threshold min_age_days=$min_age_days"
    return 0
  fi

  # The four "never, regardless of anything else" arms, cheapest first. They are
  # ordered ahead of every fact about pull requests so that a branch protected
  # by policy is reported as protected even when the API read behind it failed.
  if [ "$is_default" = "1" ]; then
    echo "keep:default-branch"
    return 0
  fi

  if [ "$protected" = "1" ]; then
    echo "keep:protected"
    return 0
  fi

  if [ "$excluded" = "1" ]; then
    echo "keep:excluded"
    return 0
  fi

  # A branch that an open pull request TARGETS is a base, not a head. Deleting
  # it closes that pull request and throws away its review thread. Long-lived
  # integration branches are exactly this shape and are exactly what somebody
  # would forget to add to the keep-list.
  if [ "$base_of_open_pr" = "1" ]; then
    echo "keep:base-of-open-pull-request"
    return 0
  fi

  # A branch can carry BOTH a merged pull request and a newer open one — reopen
  # a line of work, push again, open a second pull request. Checked before the
  # merged test, because the merged test would otherwise say yes.
  if [ "$has_open_pr" = "1" ]; then
    echo "keep:pull-request-open"
    return 0
  fi

  # Never inferred from age or from the absence of a pull request. A branch with
  # no pull request at all is unreviewed, unmerged work, and it is the single
  # most likely thing in the list to be somebody's session in progress. It also
  # covers a pull request that was CLOSED without merging: closed is not merged,
  # and the code in it exists nowhere else.
  if [ "$has_merged_pr" != "1" ]; then
    echo "keep:not-merged"
    return 0
  fi

  # The squash-safe reachability test, and the one arm where "" must not be read
  # as either answer. An unknown tip means the caller could not compare, so the
  # honest verdict is a keep with a reason that says the comparison failed
  # rather than that the branch moved.
  if [ -z "$tip_matches" ]; then
    echo "keep:tip-unknown"
    return 0
  fi

  if [ "$tip_matches" != "1" ]; then
    echo "keep:moved-since-merge"
    return 0
  fi

  if ! [[ "$age_days" =~ ^[0-9]+$ ]]; then
    echo "keep:age-unknown age_days=$age_days"
    return 0
  fi

  # Strictly less than, so `min_age_days=0` means "as soon as it is merged" and
  # `14` means a branch merged thirteen days ago survives. The grace period is
  # the whole point of the feature: a branch you merged this morning is a branch
  # you may still be reading, cherry-picking from, or about to reopen.
  if [ "$age_days" -lt "$min_age_days" ]; then
    echo "keep:too-recent age_days=$age_days min=$min_age_days"
    return 0
  fi

  echo "delete:merged-and-aged age_days=$age_days min=$min_age_days"
  return 0
}
