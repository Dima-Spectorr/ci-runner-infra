#!/usr/bin/env bash
# merge-lane — the API half of the lane. The decisions live next door in
# `merge-lane-decision.sh`; this file only gathers facts and acts on a verdict.
#
# The split is not tidiness. This script cannot be unit-tested — every line of
# it talks to GitHub — and the workflow that invokes it runs only from the
# default branch, so the pull request that changes it exercises nothing. So
# everything that DECIDES lives in pure functions with 55 cases against them,
# and what is left here is deliberately dull: read a field, pass it in, do what
# it says.
#
# Read `docs/merge-lane.md` for the design and the migration off Mergify.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/merge-lane-decision.sh"

: "${GH_TOKEN:?the merge App token is required}"
: "${GITHUB_REPOSITORY:?}"
LANE_BASE="${LANE_BASE:-main}"
REQUIRED_CHECKS="${REQUIRED_CHECKS:-}"
BUDGET="${BUDGET:-1800}"
MAX_ACTIONS="${MAX_ACTIONS:-4}"
REQUIRE_LABEL="${REQUIRE_LABEL:-}"
PRIORITY_PREFIX="${PRIORITY_PREFIX:-merge-lane/priority-}"
DRY_RUN="${DRY_RUN:-false}"

R="$GITHUB_REPOSITORY"

# The required-check names, one per line, blanks dropped. An empty list is not a
# permissive lane — `lane_verdict` refuses to merge anything when it is empty,
# and this is the message that explains why.
mapfile -t REQUIRED < <(printf '%s\n' "$REQUIRED_CHECKS" | sed 's/[[:space:]]*$//' | grep -v '^$' || true)
if [ "${#REQUIRED[@]}" -eq 0 ]; then
  echo "::error::no required checks were configured — the lane will not merge anything until 'required-checks' names at least one check"
  exit 1
fi

echo "lane: base=$LANE_BASE required=${#REQUIRED[@]} budget=${BUDGET}s max-actions=$MAX_ACTIONS dry-run=$DRY_RUN"
for c in "${REQUIRED[@]}"; do echo "lane: requires '$c'"; done

now="$(date -u +%s)"

# ---------------------------------------------------------------------------
# check_counts <sha> — how the required checks stand on exactly this commit.
#
# Prints "green missing failed pending".
#
# Both surfaces are read. GitHub Actions reports check-runs, but a required
# context can equally be a legacy commit STATUS, and a lane that only knew about
# check-runs would count a green status as missing and never merge. Mergify's
# `check-success` matched either, so matching either is what keeps the migrated
# conditions meaning the same thing.
#
# A name that appears more than once — a re-run, or a matrix leg sharing a name
# — is resolved to its NEWEST occurrence, because that is the one the pull
# request displays and the one a human means by "it is green now".
# ---------------------------------------------------------------------------
check_counts() {
  local sha="$1"
  local runs statuses all
  runs="$(gh api "repos/$R/commits/$sha/check-runs?per_page=100" \
    --jq '[.check_runs[] | {name: .name, state: (if .status != "completed" then "pending" else (.conclusion // "pending") end), at: (.completed_at // .started_at // "")}]' 2>/dev/null || echo '[]')"
  statuses="$(gh api "repos/$R/commits/$sha/status?per_page=100" \
    --jq '[.statuses[] | {name: .context, state: (if .state == "pending" then "pending" else .state end), at: (.updated_at // "")}]' 2>/dev/null || echo '[]')"

  # Newest wins per name.
  all="$(printf '%s\n%s\n' "$runs" "$statuses" \
    | jq -s 'add | sort_by(.at) | group_by(.name) | map(.[-1]) | map({(.name): .state}) | add // {}')"

  local green=0 missing=0 failed=0 pending=0 name state
  for name in "${REQUIRED[@]}"; do
    state="$(printf '%s' "$all" | jq -r --arg n "$name" '.[$n] // "absent"')"
    case "$state" in
      success) green=$((green + 1)) ;;
      pending | queued | in_progress) pending=$((pending + 1)) ;;
      absent) missing=$((missing + 1)) ;;
      # `neutral` and `skipped` are NOT successes. A required check that skipped
      # itself — a path filter, a draft gate — produced no verdict on this diff,
      # and counting it green is how a lane merges something nothing checked.
      *) failed=$((failed + 1)) ;;
    esac
  done
  echo "$green $missing $failed $pending"
}

# ---------------------------------------------------------------------------
# One pass: read every candidate, rank them, act on the best one.
# Returns 0 if it acted, 1 if there was nothing to do.
# ---------------------------------------------------------------------------
one_pass() {
  local prs
  prs="$(gh api "repos/$R/pulls?state=open&base=$LANE_BASE&per_page=100" \
    --jq '.[] | [.number, .head.sha, (.draft|tostring), (.mergeable_state // "")] | @tsv')"
  if [ -z "$prs" ]; then
    echo "lane: no open pull requests on $LANE_BASE"
    return 1
  fi

  local best_key='' best_line=''
  local num sha draft _state

  while IFS=$'\t' read -r num sha draft _state; do
    [ -n "$num" ] || continue

    # `mergeable` is computed asynchronously and is null until GitHub has done
    # it, which is why the list call above is not enough — the list does not
    # carry it at all. Read per pull request, and let null stay null: the
    # decision treats it as a wait, not as a guess in either direction.
    local detail mergeable labels behind age headdate
    detail="$(gh api "repos/$R/pulls/$num" --jq '[(.mergeable|tostring), (.labels|map(.name)|join(",")), .head.sha] | @tsv')"
    IFS=$'\t' read -r mergeable labels sha <<<"$detail"

    local conflict=''
    case "$mergeable" in
      true) conflict=0 ;;
      false) conflict=1 ;;
      *) conflict='' ;;
    esac

    if [ -n "$REQUIRE_LABEL" ] && [[ ",$labels," != *",$REQUIRE_LABEL,"* ]]; then
      echo "lane: #$num skip:no-label ($REQUIRE_LABEL)"
      continue
    fi

    local priority=50 l _labels
    IFS=',' read -ra _labels <<<"$labels"
    for l in "${_labels[@]}"; do
      if [[ "$l" == "$PRIORITY_PREFIX"* ]]; then
        local p="${l#"$PRIORITY_PREFIX"}"
        [[ "$p" =~ ^[0-9]+$ ]] && priority="$p"
      fi
    done

    # How far the base has moved since this branch last saw it. `behind_by` is
    # the whole of invariant C: it is what makes this a queue rather than plain
    # auto-merge, and what catches two sessions that pass alone and break
    # together.
    behind="$(gh api "repos/$R/compare/$LANE_BASE...$sha" --jq '.behind_by' 2>/dev/null || echo '')"
    [[ "$behind" =~ ^[0-9]+$ ]] || behind=0

    # The in-flight clock, and the only one available without storing state:
    # when this head commit was written. `lane_verdict` only allows it to expire
    # an entry that still has something outstanding, precisely because by this
    # clock a patient pull request looks ancient.
    headdate="$(gh api "repos/$R/commits/$sha" --jq '.commit.committer.date' 2>/dev/null || echo '')"
    if [ -n "$headdate" ]; then
      age=$((now - $(date -u -d "$headdate" +%s)))
      [ "$age" -ge 0 ] || age=0
    else
      age=''
    fi

    local counts green missing failed pending
    counts="$(check_counts "$sha")"
    read -r green missing failed pending <<<"$counts"

    local isdraft=0
    [ "$draft" = "true" ] && isdraft=1

    local verdict
    verdict="$(lane_verdict "$isdraft" "$LANE_BASE" "$LANE_BASE" "$conflict" \
      "${#REQUIRED[@]}" "$green" "$missing" "$failed" "$pending" "$behind" "$age" "$BUDGET")"

    echo "lane: #$num $verdict (sha=${sha:0:8} priority=$priority behind=$behind)"

    if lane_admits "$verdict"; then
      local key
      key="$(lane_rank "$verdict" "$priority" "${age:-0}")"
      if [ -z "$best_key" ] || [[ "$key" < "$best_key" ]]; then
        best_key="$key"
        best_line="$num	$sha	$verdict"
      fi
    fi
  done <<<"$prs"

  if [ -z "$best_line" ]; then
    echo "lane: nothing actionable this pass"
    return 1
  fi

  local action_num action_sha action_verdict
  IFS=$'\t' read -r action_num action_sha action_verdict <<<"$best_line"

  if [ "$DRY_RUN" = "true" ]; then
    echo "::notice::dry-run — would take '$action_verdict' on #$action_num"
    return 1
  fi

  case "${action_verdict%%:*}" in
    merge)
      # `sha=` is not decoration. It makes the merge conditional on the head
      # still being the commit every check above was read against; a push that
      # landed while this pass was running fails the call instead of merging
      # code nothing verified. This is the race Mergify closed by owning the
      # queue, and it has to be closed explicitly now that we do.
      if gh api -X PUT "repos/$R/pulls/$action_num/merge" \
        -f merge_method=squash -f sha="$action_sha" --silent; then
        echo "::notice::merged #$action_num ($action_verdict)"
      else
        echo "::warning::merge of #$action_num was refused — head moved, or the branch became unmergeable. Re-reading next pass."
        return 1
      fi
      ;;
    update)
      # Same guard, same reason. This push is what starts the re-run whose
      # completion brings the lane back — and it starts one only because the
      # token is the App's.
      if gh api -X PUT "repos/$R/pulls/$action_num/update-branch" \
        -f expected_head_sha="$action_sha" --silent; then
        echo "::notice::updated #$action_num onto $LANE_BASE ($action_verdict) — its own CI now re-runs in place"
      else
        echo "::warning::update of #$action_num was refused — head moved. Re-reading next pass."
        return 1
      fi
      ;;
    drop)
      gh api "repos/$R/issues/$action_num/comments" -f body="$(printf '%s\n\n%s\n' \
        "The merge lane released this pull request: \`$action_verdict\`." \
        "Its required checks did not all reach a conclusion within the lane's budget, so it was let go rather than left holding the lane. Nothing is wrong with the diff as far as the lane knows — push, or re-run the checks, and it will be picked up again automatically.")" --silent
      echo "::notice::released #$action_num ($action_verdict)"
      ;;
  esac
  return 0
}

acted=0
while [ "$acted" -lt "$MAX_ACTIONS" ]; do
  if one_pass; then
    acted=$((acted + 1))
    # The world changed: a merge just moved the base, so everything else is now
    # one commit behind and has to be re-read rather than judged on the facts
    # gathered before it.
    now="$(date -u +%s)"
  else
    break
  fi
done

echo "lane: done, $acted action(s)"
