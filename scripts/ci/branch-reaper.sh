#!/usr/bin/env bash
# branch-reaper — the API half. The decision lives next door in
# `branch-reaper-decision.sh`; this file gathers facts and acts on a verdict.
#
# The split is the same one the merge lane makes, for the same reason: every
# line here talks to GitHub, so none of it can be unit-tested, and the workflow
# that runs it is dispatched on a schedule from the default branch, so the pull
# request that changes it exercises nothing. Everything that DECIDES lives in
# pure functions with cases against them, and what is left here is deliberately
# dull.
#
# Read `docs/branch-reaper.md` for the rule and the operator switches.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/branch-reaper-decision.sh"

: "${GH_TOKEN:?the merge App token is required}"
: "${GITHUB_REPOSITORY:?}"
MIN_AGE_DAYS="${MIN_AGE_DAYS:-14}"
MAX_DELETIONS="${MAX_DELETIONS:-20}"
KEEP_PATTERNS="${KEEP_PATTERNS:-}"
# DEFAULTS TO A DRY RUN, AND THE MERGE LANE DOES NOT.
#
# The lane's wrong answer writes something you can revert. This one's destroys
# commits that may exist nowhere else, so the direction the switch fails in is
# the opposite: unset, mistyped, or set to anything but the exact string
# `false`, nothing is deleted.
DRY_RUN="${DRY_RUN:-true}"

R="$GITHUB_REPOSITORY"

# The operator's keep-list, one glob per line, blanks dropped. Matched with
# bash's `==` pattern operator, so `release/*` and `wip-*` both work and nothing
# is a regular expression.
mapfile -t KEEP < <(printf '%s\n' "$KEEP_PATTERNS" | sed 's/[[:space:]]*$//' | grep -v '^$' || true)

now="$(date -u +%s)"

echo "reaper: repo=$R min-age-days=$MIN_AGE_DAYS max-deletions=$MAX_DELETIONS dry-run=$DRY_RUN"
for k in ${KEEP[@]+"${KEEP[@]}"}; do echo "reaper: keeps '$k'"; done

DEFAULT_BRANCH="$(gh api "repos/$R" --jq '.default_branch')"
[ -n "$DEFAULT_BRANCH" ] || {
  echo "::error::could not read the default branch — refusing to evaluate anything"
  exit 1
}
echo "reaper: default branch is '$DEFAULT_BRANCH'"

# ---------------------------------------------------------------------------
# ONE READ OF THE PULL REQUEST HISTORY, NOT ONE READ PER BRANCH.
#
# The obvious shape — ask `pulls?head=owner:<branch>` once per branch — costs a
# call per branch, and this repository already has 256 of them. Measured: it did
# not finish in five minutes. Worse than slow, it scales the wrong way, because
# the repositories with the most branches to prune are exactly the ones where it
# would exhaust the hourly rate limit; and under the fail-closed rule a failed
# read is a keep, so the job would quietly stop pruning precisely where it is
# needed most.
#
# Cost here is bounded by the number of pull requests ever opened rather than by
# the number of branches, it is paginated once, and everything after it is local
# lookups. On this repository that is ~5 calls instead of ~256.
#
# FAIL CLOSED, AND FAIL GLOBALLY. An index that did not load is not a repository
# with no pull requests — and that distinction is the entire safety of this job,
# because "this branch has no merged pull request" is read from the same absence
# as "this branch is missing from a half-loaded index". So an empty index aborts
# the run rather than producing a sweep in which every branch looks unmerged.
# ---------------------------------------------------------------------------
pr_index_tsv() {
  # `--paginate` with `--jq` emits one array per page, hence `jq -s add` to
  # concatenate them before grouping.
  gh api --paginate "repos/$R/pulls?state=all&per_page=100" \
    --jq '[.[] | {ref: .head.ref, state: .state, merged_at: .merged_at, head: .head.sha, number: .number}]' |
    jq -rs 'add // []
      | group_by(.ref)
      | map({ ref: .[0].ref,
              open: (map(select(.state == "open")) | length),
              merged: (map(select(.merged_at != null)) | sort_by(.merged_at) | last) })
      | .[]
      | [ .ref,
          (.open | tostring),
          (if .merged then "1" else "0" end),
          (.merged.merged_at // "-"),
          (.merged.head // "-"),
          (if .merged then (.merged.number | tostring) else "-" end) ]
      | @tsv'
}

# An associative array and not a `grep` over the text: a branch named `feat/a`
# must not match the row belonging to `feat/ab`, and an exact-key lookup is
# incapable of getting that wrong.
declare -A PR_OPEN PR_MERGED PR_AT PR_HEAD PR_NUM
index_rows=0
while IFS=$'\t' read -r ref popen pmerged pat phead pnum; do
  [ -n "$ref" ] || continue
  PR_OPEN["$ref"]="$popen"
  PR_MERGED["$ref"]="$pmerged"
  PR_AT["$ref"]="$pat"
  PR_HEAD["$ref"]="$phead"
  PR_NUM["$ref"]="$pnum"
  index_rows=$((index_rows + 1))
done < <(pr_index_tsv || true)

if [ "$index_rows" -eq 0 ]; then
  echo "::error::read no pull requests at all — that is either an unreadable API or a repository with no history, and in neither case is deleting branches safe"
  exit 1
fi
echo "reaper: indexed $index_rows branch name(s) from the pull request history"

# Every branch an OPEN pull request targets. Read once, as a set, rather than
# per branch: a repository with two hundred branches and four open pull requests
# should make one call for this, not two hundred.
#
# `--paginate`, and it is load-bearing rather than defensive. An unpaginated
# read past a hundred open pull requests would silently omit bases from this
# set, and a base missing from it is a branch the reaper is willing to delete
# out from under an open pull request.
OPEN_BASES="$(gh api --paginate "repos/$R/pulls?state=open&per_page=100" --jq '.[].base.ref' 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# The report. Same shape and the same reasoning as the merge lane's: one row per
# branch INCLUDING the ones nothing happened to, because the interesting
# question an operator has is never "what did you delete" — the log says that —
# it is "why is this branch still here".
# ---------------------------------------------------------------------------
REPORT_ROWS=()
# `-` for an unknown field, never the empty string: the rows are tab-joined and
# tab-split to render, and tab is IFS whitespace, so one empty field would
# collapse and shift every column after it left.
rf() { [ -n "${1:-}" ] && printf '%s' "$1" || printf -- '-'; }
report_row() { # <sortkey> <branch> <verdict> <age> <pull request> <outcome>
  REPORT_ROWS+=("$(rf "$1")"$'\t'"$(rf "$2")"$'\t'"$(rf "$3")"$'\t'"$(rf "$4")"$'\t'"$(rf "$5")"$'\t'"$(rf "$6")")
}

deleted=0
examined=0

# `--paginate`: the whole point of this job is a repository with more branches
# than anyone wants to look at, so reading only the first page would leave
# exactly the branches it exists to find.
while IFS=$'\t' read -r branch tip protected; do
  [ -n "$branch" ] || continue
  examined=$((examined + 1))

  is_default=0
  if [ "$branch" = "$DEFAULT_BRANCH" ]; then is_default=1; fi

  is_protected=0
  if [ "$protected" = "true" ]; then is_protected=1; fi

  excluded=0
  for k in ${KEEP[@]+"${KEEP[@]}"}; do
    # shellcheck disable=SC2053  # the right-hand side is a glob on purpose
    if [[ "$branch" == $k ]]; then
      excluded=1
      break
    fi
  done

  base_of_open=0
  if [ -n "$OPEN_BASES" ] && printf '%s\n' "$OPEN_BASES" | grep -cFx -- "$branch" >/dev/null; then
    base_of_open=1
  fi

  # A branch absent from the index has never been the head of a pull request.
  # That reads as unmerged, which is a keep — and it is the right answer rather
  # than a convenient one, because a branch nobody ever opened a pull request
  # for is unreviewed work and the single most likely thing in the list to be
  # somebody's session in progress.
  has_open=0
  if [ "${PR_OPEN[$branch]:-0}" != "0" ]; then has_open=1; fi

  has_merged="${PR_MERGED[$branch]:-0}"
  merged_at="${PR_AT[$branch]:--}"
  merged_head="${PR_HEAD[$branch]:--}"
  pr_number="${PR_NUM[$branch]:--}"
  if [ "$merged_at" = "-" ]; then merged_at=''; fi
  if [ "$merged_head" = "-" ]; then merged_head=''; fi

  # THE SQUASH-SAFE REACHABILITY TEST.
  #
  # A squash merge writes a new commit on the default branch, so the branch tip
  # is not an ancestor of it and "is it merged into main" cannot be asked with
  # `git merge-base`. What can be asked is whether the tip is still the exact
  # sha that was merged. If it is not, someone pushed afterwards and those
  # commits were never merged and never reviewed.
  tip_matches=''
  if [ -n "$merged_head" ] && [ -n "$tip" ]; then
    if [ "$merged_head" = "$tip" ]; then tip_matches=1; else tip_matches=0; fi
  fi

  age_days=''
  if [ -n "$merged_at" ]; then
    merged_epoch="$(date -u -d "$merged_at" +%s 2>/dev/null || echo '')"
    if [ -n "$merged_epoch" ] && [ "$merged_epoch" -le "$now" ]; then
      age_days=$(((now - merged_epoch) / 86400))
    fi
  fi

  verdict="$(reaper_verdict "$is_default" "$is_protected" "$excluded" "$base_of_open" \
    "$has_open" "$has_merged" "$tip_matches" "$age_days" "$MIN_AGE_DAYS")"

  echo "reaper: $branch $verdict (tip=${tip:0:8} pr=${pr_number:--} age=${age_days:--}d)"

  if [ "${verdict%%:*}" != "delete" ]; then
    # Sorted so the near misses read first: what this job would delete next is
    # the only kept row anyone reviews, and the structural keeps — the default
    # branch, the keep-list — are noise that sinks to the bottom.
    case "$verdict" in
      keep:too-recent*) report_row 5 "$branch" "$verdict" "$age_days" "$pr_number" 'kept' ;;
      keep:moved-since-merge* | keep:tip-unknown* | keep:age-unknown*) report_row 6 "$branch" "$verdict" "$age_days" "$pr_number" 'kept' ;;
      keep:not-merged* | keep:pull-request-open*) report_row 7 "$branch" "$verdict" "$age_days" "$pr_number" 'kept' ;;
      *) report_row 9 "$branch" "$verdict" "$age_days" "$pr_number" 'kept' ;;
    esac
    continue
  fi

  if [ "$DRY_RUN" != "false" ]; then
    echo "reaper: dry run — would delete $branch"
    report_row 1 "$branch" "$verdict" "$age_days" "$pr_number" 'would delete'
    continue
  fi

  # BOUNDED, AND THE BOUND IS NOT A PERFORMANCE KNOB.
  #
  # The first armed run against a repository nobody has ever pruned is the run
  # most likely to be acting on a misconfiguration, and it is also the run that
  # would delete the most. A cap turns "the keep-list was wrong" from a
  # repository-wide event into twenty branches and a report, with the rest still
  # there on the next run.
  if [ "$deleted" -ge "$MAX_DELETIONS" ]; then
    echo "reaper: $branch delete deferred — this run's cap of $MAX_DELETIONS is reached"
    report_row 2 "$branch" "$verdict" "$age_days" "$pr_number" 'deferred (cap)'
    continue
  fi

  # `git/refs/heads/<branch>` and not a shell-built path: the branch name goes
  # straight into a URL and branch names contain slashes. gh does not encode a
  # path, so this relies on the slash being meaningful here — it is, `refs/heads`
  # is hierarchical — and on the name having come from the API rather than from
  # an input.
  if gh api -X DELETE "repos/$R/git/refs/heads/$branch" --silent 2>/dev/null; then
    deleted=$((deleted + 1))
    echo "::notice::deleted branch $branch (merged in #${pr_number:-?}, ${age_days}d ago)"
    report_row 1 "$branch" "$verdict" "$age_days" "$pr_number" 'deleted'
  else
    echo "::warning::could not delete $branch — the merge App needs 'Contents: write', or the branch is protected by a ruleset this read did not see"
    report_row 2 "$branch" "$verdict" "$age_days" "$pr_number" 'delete failed'
  fi
done < <(gh api --paginate "repos/$R/branches?per_page=100" \
  --jq '.[] | [.name, .commit.sha, (.protected|tostring)] | @tsv')

# ---------------------------------------------------------------------------
# render_report — the run's decisions, as markdown, on stdout.
# ---------------------------------------------------------------------------
# SC2016: the single-quoted strings below are printf FORMATS and the backticks
# in them are markdown code spans, not command substitution. Double-quoting them
# to satisfy the linter is the change that would break this — the shell would
# then try to run `%s` as a command.
# shellcheck disable=SC2016
render_report() {
  printf '## Branch reaper — `%s`\n\n' "$R"
  if [ "$DRY_RUN" != "false" ]; then
    printf '> **Dry run.** Every verdict below was computed for real; nothing was deleted.\n\n'
  fi
  printf 'Deletes a branch only when a pull request with that head was **merged**, the branch tip is **still the sha that was merged**, and the merge was at least **%s day(s)** ago.\n\n' "$MIN_AGE_DAYS"

  if [ "${#REPORT_ROWS[@]}" -eq 0 ]; then
    printf '_No branches._\n\n'
  else
    printf '| branch | verdict | reason | merged | age | outcome |\n'
    printf '|---|---|---|---|---|---|\n'
    local k b v a p o reason
    while IFS=$'\t' read -r k b v a p o; do
      : "$k"
      reason="${v#*:}"
      if [ "$reason" = "$v" ]; then reason='—'; fi
      local pr='—'
      if [ "$p" != "-" ]; then pr="#$p"; fi
      local age='—'
      if [ "$a" != "-" ]; then age="${a}d"; fi
      printf '| `%s` | `%s` | %s | %s | %s | %s |\n' "$b" "${v%%:*}" "$reason" "$pr" "$age" "$o"
    done < <(printf '%s\n' "${REPORT_ROWS[@]}" | sort)
    printf '\n'
  fi

  printf '%s branch(es) examined, %s deleted. Read %s' "$examined" "$deleted" "$(date -u +'%Y-%m-%d %H:%M:%SZ')"
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf ' by [this run](https://github.com/%s/actions/runs/%s)' "$R" "$GITHUB_RUN_ID"
  fi
  printf '.\n'
}

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  render_report >>"$GITHUB_STEP_SUMMARY"
fi

echo "reaper: done, $examined examined, $deleted deleted"
