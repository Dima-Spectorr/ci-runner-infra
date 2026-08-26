#!/usr/bin/env bash
# pr-guard — the API half. The rules live next door in `pr-guard-decision.sh`;
# this file only gathers facts, says what it found, and exits on the verdict.
#
# Same split, and same reason, as the merge lane: the workflow that calls this
# runs from the default branch, so the pull request that changes it exercises
# nothing. Everything that decides is a pure function with 31 cases against it.
#
# Read `docs/merge-lane.md` — "What a non-strict base costs" — for why this
# exists at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/pr-guard-decision.sh"

: "${GH_TOKEN:?a token with pull-requests access is required}"
: "${GITHUB_REPOSITORY:?}"
: "${PR_NUMBER:?}"
MAX_BEHIND="${MAX_BEHIND:-0}"
ENFORCE_FRESHNESS="${ENFORCE_FRESHNESS:-false}"
ENFORCE_OVERLAP="${ENFORCE_OVERLAP:-false}"
# How many other open pull requests to compare against. Every one of them costs
# a `files` call, so on a repository with ninety open this is the difference
# between one API call and ninety-one. The cap is applied to the list ordered by
# MOST RECENTLY UPDATED, because the pull request somebody is actively pushing
# to is the one worth colliding with; a branch untouched for a month is going to
# need a rebase regardless of what this says.
MAX_COMPARE="${MAX_COMPARE:-30}"

R="$GITHUB_REPOSITORY"
MARKER='<!-- pr-guard -->'

pr="$(gh api "repos/$R/pulls/$PR_NUMBER")"
BASE="$(jq -r '.base.ref' <<<"$pr")"
HEAD_SHA="$(jq -r '.head.sha' <<<"$pr")"
DRAFT="$(jq -r '.draft' <<<"$pr")"

# A draft is work in progress by definition. Telling its author their branch is
# stale is noise, and it is noise on the pull requests that are open longest.
if [ "$DRAFT" = "true" ]; then
  echo "pr-guard: #$PR_NUMBER is a draft — nothing to say yet"
  exit 0
fi

echo "pr-guard: #$PR_NUMBER base=$BASE head=$HEAD_SHA max-behind=$MAX_BEHIND compare-cap=$MAX_COMPARE"

# --- how stale is it? --------------------------------------------------------
# `|| true` is safe here ONLY because `guard_freshness` re-validates: anything
# that is not a plain number becomes `unknown`, which never fails the run. That
# is the whole reason the numeric test lives in the pure function rather than
# being assumed here.
behind="$(gh api "repos/$R/compare/$BASE...$HEAD_SHA" --jq '.behind_by' 2>/dev/null || true)"
freshness="$(guard_freshness "$behind" "$MAX_BEHIND" "$ENFORCE_FRESHNESS")"
echo "pr-guard: freshness $freshness"

# --- who else is in these files? ---------------------------------------------
# Paginated. Past a hundred changed files an unpaginated read returns the first
# page, the rest of the diff is invisible to the intersection, and the guard
# reports `ok:distinct` for two pull requests rewriting the same file — a green
# answer to a question it did not finish asking.
mine="$(gh api --paginate "repos/$R/pulls/$PR_NUMBER/files?per_page=100" --jq '.[].filename' 2>/dev/null || true)"
mine_n="$(printf '%s\n' "$mine" | grep -cv '^[[:space:]]*$' || true)"
echo "pr-guard: $mine_n changed file(s)"

# PIPED TO `jq`, NOT `gh api --jq`. That flag takes the program and nothing
# else — there is no way to pass `--argjson` through it — so the pull request's
# own number would have had to be interpolated into the program text, where a
# non-numeric value is code. `-s` collects `--paginate`'s one-array-per-page
# into a single stream.
others="$(gh api --paginate "repos/$R/pulls?state=open&base=$BASE&sort=updated&direction=desc&per_page=100" 2>/dev/null \
  | jq -r -s --argjson me "$PR_NUMBER" \
      'add // [] | .[] | select(.number != $me and .draft == false) | "\(.number)\t\(.title)"' 2>/dev/null || true)"

declare -a COLLISIONS=()
shared_total=0
compared=0
while IFS=$'\t' read -r onum otitle; do
  [ -n "$onum" ] || continue
  [ "$compared" -lt "$MAX_COMPARE" ] || break
  compared=$((compared + 1))
  theirs="$(gh api --paginate "repos/$R/pulls/$onum/files?per_page=100" --jq '.[].filename' 2>/dev/null || true)"
  both="$(guard_shared "$mine" "$theirs")"
  [ -n "$both" ] || continue
  n="$(printf '%s\n' "$both" | grep -c . || true)"
  shared_total=$((shared_total + n))
  COLLISIONS+=("$onum"$'\t'"$otitle"$'\t'"$n"$'\t'"$(printf '%s' "$both" | tr '\n' ' ')")
done <<<"$others"

echo "pr-guard: compared against $compared other open pull request(s)"
overlap="$(guard_overlap "$shared_total" "$ENFORCE_OVERLAP")"
echo "pr-guard: overlap $overlap"

# --- say it ------------------------------------------------------------------
render() {
  printf '%s\n## Pull-request guard\n\n' "$MARKER"

  case "$freshness" in
    ok:*)      printf -- '- **Base** — up to date with `%s`.\n' "$BASE" ;;
    unknown:*) printf -- '- **Base** — could not be compared with `%s`. Not treated as a problem.\n' "$BASE" ;;
    *)         printf -- '- **Base** — this branch is **%s commit(s) behind `%s`**. Its checks were reported against a base that has moved; merge or rebase `%s` into it to have them mean something.\n' \
                 "${freshness#*-}" "$BASE" "$BASE" ;;
  esac

  if [ "${#COLLISIONS[@]}" -eq 0 ]; then
    printf -- '- **Overlap** — no other open pull request touches these files.\n\n'
  else
    printf -- '- **Overlap** — %s open pull request(s) touch files this one also changes:\n\n' "${#COLLISIONS[@]}"
    printf '| pull request | shared files |\n|---|---|\n'
    local n t c f
    while IFS=$'\t' read -r n t c f; do
      # A title is free text and a `|` in it would end the cell early.
      t="${t//|/\\|}"
      printf '| [#%s](https://github.com/%s/pull/%s) %s | `%s` (%s) |\n' "$n" "$R" "$n" "$t" "${f% }" "$c"
    done < <(printf '%s\n' "${COLLISIONS[@]}")
    printf '\n'
  fi

  if [ "$compared" -ge "$MAX_COMPARE" ]; then
    printf '> Compared against the %s most recently updated open pull requests, not all of them.\n\n' "$MAX_COMPARE"
  fi

  # NAME THE MODE. A warning nobody has to act on and a failure that blocks look
  # identical in a comment, and an author who cannot tell them apart treats both
  # the same way — which is to say, treats the blocking one as advice.
  case "$freshness$overlap" in
    *fail:*) printf '_This check is **enforced** here: the findings above are blocking._\n' ;;
    *)       printf '_Advisory. This check does not block a merge._\n' ;;
  esac
}

body="$(render)"
# An `if`, not `[ ... ] && ...`. Under `set -e` a bare test that fails at
# statement level ENDS THE SCRIPT, so running outside Actions — where
# `GITHUB_STEP_SUMMARY` is unset — would exit here, before the comment and
# before the verdict, and report success while having checked nothing.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "$body" >>"$GITHUB_STEP_SUMMARY"
fi

# --- one comment, edited, never a second one ---------------------------------
# Every push re-runs this. Posting rather than editing would leave a pull
# request with twenty near-identical comments, which is how a useful signal
# becomes something everyone collapses.
#
# `|| true` around both calls on purpose: a fork's `GITHUB_TOKEN` is read-only,
# so a pull request from a fork cannot be commented on, and refusing to run the
# CHECK because we could not publish the ADVICE would be the wrong way round.
# The job summary above already carries it.
existing="$(gh api --paginate "repos/$R/issues/$PR_NUMBER/comments?per_page=100" 2>/dev/null \
  | jq -r -s --arg m "$MARKER" \
      '(add // []) | map(select(.body | startswith($m))) | .[0].id // empty' 2>/dev/null || true)"

if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$R/issues/comments/$existing" -f body="$body" --silent 2>/dev/null \
    || echo "pr-guard: could not update the comment — the findings are in the job summary"
elif [ "$freshness" != "ok:current" ] || [ "${#COLLISIONS[@]}" -gt 0 ]; then
  # Only OPEN a comment when there is something to say. A clean pull request
  # gets the job summary and nothing else; a comment saying "all fine" on every
  # pull request in the repository is a notification everyone mutes, taking the
  # ones that matter with it.
  gh api -X POST "repos/$R/issues/$PR_NUMBER/comments" -f body="$body" --silent 2>/dev/null \
    || echo "pr-guard: could not post the comment — the findings are in the job summary"
fi

guard_exit "$freshness" "$overlap"
