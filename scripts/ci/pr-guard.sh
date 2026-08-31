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

# --- the reviewer that read the last push and not this one -------------------
# Copilot reviews the FIRST push to a pull request and then stops. Measured
# across the fleet on 2026-08-30: fourteen of fifteen merged multi-commit pull
# requests had no Copilot review on the head that actually landed. The merge
# lane asks about the head it is about to merge, finds nothing, waits out its
# grace and annotates the merge `UNREVIEWED` — a warning documented to mean "a
# reviewer is down, go look". It had been firing on a reviewer in perfect
# health that simply was not asked again, which is how such a warning stops
# being read. See `docs/ai-code-review.md`.
#
# ASKED HERE, ON THE PUSH, AND THAT IS THE WHOLE DESIGN. CI on this fleet takes
# tens of minutes and a review takes a few, so a review requested now runs
# beside the checks and has landed long before the lane asks. Asking at merge
# time would work too and would add the review's latency to every merge, which
# is precisely what the last three releases went to removing.
#
# DRAFTS ARE EXCLUDED BY THE EXIT ABOVE, deliberately. A reviewer does not read
# a draft, the lane does not merge one, and `ready_for_review` brings the pull
# request back through here.
#
# EVERY CALL FAILS SOFT. A fork's token is read-only and a caller may not hold
# `pull-requests: write`; a guard that went red because it could not ASK for a
# review would be a worse version of the problem it fixes. The lane's grace is
# the fallback and it still works — it is just louder than it needs to be.
mapfile -t GUARD_REVIEW_BOTS < <(printf '%s\n' "${REVIEW_BOTS_INPUT:-}" \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
FORK="$(jq -r '.head.repo.fork // false' <<<"$pr")"

if [ "${#GUARD_REVIEW_BOTS[@]}" -eq 0 ]; then
  echo "pr-guard: no review-bots configured — not asking anyone for a review"
elif [ "$FORK" = "true" ]; then
  echo "pr-guard: #$PR_NUMBER is from a fork — the token is read-only, so no review is requested"
else
  # ONE READ FOR ALL THREE FACTS, AND IT HAS TO BE GRAPHQL. REST answers none of
  # them together: `/pulls/<n>/requested_reviewers` omits bots entirely, and
  # POSTing to it refuses a bot login outright — `422 Reviews may only be
  # requested from collaborators`, measured 2026-08-30. The reviewer's node id
  # is only reachable as the AUTHOR of a review it has already published;
  # `suggestedActors` returns `copilot-swe-agent`, which is the coding agent and
  # a different bot.
  #
  # The pull request number rides in as a VARIABLE, never interpolated into the
  # program text — the same argument the `--argjson` comment below makes.
  # SC2016: `$o`, `$r` and `$n` are GRAPHQL variables and must reach the server
  # unexpanded — that is the entire point of passing them with `-F`. Double
  # quoting here is the change that would break it, and it would break it by
  # substituting shell values into a query the server then rejects.
  # shellcheck disable=SC2016
  guard_gql='query($o:String!,$r:String!,$n:Int!) {
    repository(owner:$o, name:$r) { pullRequest(number:$n) {
      id
      reviews(last:100) { nodes { commit { oid } author { login ... on Bot { id } } } }
      reviewRequests(first:20) { nodes { requestedReviewer {
        ... on Bot { login } ... on User { login } } } }
    } }
  }'
  # `-f` for the strings and `-F` only for the number: `-F` COERCES, so an
  # owner or repository name that happens to be all digits would arrive as an
  # Int and the server would reject the query against `String!`.
  #
  # `gh`'s stderr is deliberately NOT redirected, here or on the mutation below.
  # This section is written to fail soft and say why, and a swallowed error
  # leaves only "it did not work": the difference between a caller missing
  # `pull-requests: write`, a fork's read-only token and a GraphQL outage is the
  # whole of the diagnosis, and it exists nowhere but in that message.
  guard_pr="$(gh api graphql -f o="${R%%/*}" -f r="${R#*/}" -F n="$PR_NUMBER" \
    -f query="$guard_gql" || true)"

  guard_pr_id="$(jq -r '.data.repository.pullRequest.id // empty' <<<"$guard_pr" 2>/dev/null || true)"

  # A read that failed and a pull request nobody has reviewed produce the same
  # empty lists, and would print the same four `absent` lines — "did not check"
  # rendering as "found nothing", which is the failure this guard exists to stop
  # doing elsewhere. The pull request's node id is present in every successful
  # response and in none of the failures, so its absence names the read.
  if [ -z "$guard_pr_id" ]; then
    echo "pr-guard: could not read #$PR_NUMBER's reviews — no review is re-requested, and the reviewer states below are unknown rather than absent"
  fi

  guard_reviews="$(jq -r '.data.repository.pullRequest.reviews.nodes[]?
      | select(.author != null and .commit != null)
      | [.author.login, .commit.oid] | @tsv' <<<"$guard_pr" 2>/dev/null || true)"
  guard_pending="$(jq -r '.data.repository.pullRequest.reviewRequests.nodes[]?
      | .requestedReviewer.login // empty' <<<"$guard_pr" 2>/dev/null || true)"
  guard_ids="$(jq -r '.data.repository.pullRequest.reviews.nodes[]?
      | select(.author.id != null) | [.author.login, .author.id] | @tsv' <<<"$guard_pr" 2>/dev/null || true)"

  while IFS=$'\t' read -r guard_bot guard_state; do
    [ -n "$guard_bot" ] || continue
    echo "pr-guard: review $guard_bot=$guard_state"
    # Only `stale` is actionable, and `guard_rereview` documents why each of the
    # other three is not — `pending` in particular, where re-asking REPLACES the
    # request in flight and a pull request pushed twice would cancel its own
    # review.
    if [ "$guard_state" != "stale" ]; then continue; fi

    # Suffix-stripped on both sides, as in `guard_rereview`: `guard_bot` is the
    # normalised login and `guard_ids` carries whatever the API returned, so a
    # bare `==` would lose the node id for the one reviewer we mean to re-ask.
    guard_bid="$(printf '%s\n' "$guard_ids" \
      | awk -F'\t' -v b="$guard_bot" '{ a = $1; sub(/\[bot\]$/, "", a) } a == b { print $2; exit }')"
    if [ -z "$guard_pr_id" ] || [ -z "$guard_bid" ]; then
      echo "pr-guard: $guard_bot reviewed an earlier commit, but its node id is unreadable — not re-requested"
      continue
    fi
    # shellcheck disable=SC2016  # `$p` and `$b` are GraphQL variables, as above.
    if gh api graphql -f p="$guard_pr_id" -f b="$guard_bid" \
      -f query='mutation($p:ID!,$b:ID!) {
        requestReviews(input:{pullRequestId:$p, botIds:[$b], union:true}) {
          pullRequest { number } } }' --silent; then
      echo "pr-guard: asked $guard_bot to review ${HEAD_SHA:0:8} — it had reviewed an earlier commit here"
    else
      # `union:true` above so this never drops a reviewer somebody else added.
      # `gh`'s own error is on the line above this one, unredirected: the reason
      # is what an operator needs, and this line cannot carry it.
      echo "pr-guard: could not ask $guard_bot to review ${HEAD_SHA:0:8} — the merge lane falls back to its grace (reason above)"
    fi
  done < <(guard_rereview "$HEAD_SHA" "$(printf '%s\n' "${GUARD_REVIEW_BOTS[@]}")" \
    "$guard_reviews" "$guard_pending")
fi

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
# SC2016: the single-quoted strings below are printf FORMATS and the backticks
# in them are markdown code spans, not command substitution. Double-quoting them
# is the change that would actually break this — the shell would then try to run
# `%s` as a command. Same disable, same reason, as `render_queue` in
# `merge-lane.sh`.
# shellcheck disable=SC2016
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
