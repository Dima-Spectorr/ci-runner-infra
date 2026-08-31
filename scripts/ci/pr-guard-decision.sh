#!/usr/bin/env bash
# pr-guard — the rules half. Pure functions, no network, no state.
#
# The merge lane answers "may this merge NOW". These answer the two questions
# that come earlier and that the lane deliberately cannot: is this pull request
# even looking at the current base, and is somebody else already changing the
# same files?
#
# Both exist because the fleet's bases are NON-STRICT. That is a considered
# choice — a strict base costs a full CI run per open pull request per merge,
# which on a repository with ninety of them is thousands of Actions minutes to
# drain a backlog once — but it means GitHub itself will not tell an author that
# their branch is stale or that it collides with someone else's. See
# `docs/merge-lane.md`.
#
# ADVISORY BY DEFAULT, AND THAT IS NOT TIMIDITY. A repository turning these on
# for the first time typically has a backlog of open pull requests, every one of
# which was opened before the rule existed. A gate that starts by failing all of
# them teaches everyone to ignore it. `enforce` is per-question and per-caller,
# so a repository can advise while it drains and enforce once it is current.
#
# The API half is `pr-guard.sh`. The split is the same one the lane uses: the
# workflow that calls this runs only from the default branch, so the pull
# request that CHANGES it exercises nothing — everything that decides has to be
# a pure function with cases against it.
set -uo pipefail

# ---------------------------------------------------------------------------
# guard_freshness <behind> <max-behind> <enforce>
#
# `behind` is `compare/<base>...<head>.behind_by`: how many commits the base has
# that this head does not.
#
# Prints one of:
#   ok:current            — within tolerance
#   warn:behind-<n>       — stale, advisory
#   fail:behind-<n>       — stale, and this caller enforces
#   unknown:unreadable    — the comparison did not produce a number
#
# `unknown` NEVER FAILS, even under enforce. A branch that has been deleted, a
# fork whose head is gone, a rate-limited read: none of those are the author
# doing something wrong, and a check that goes red because GitHub was slow is a
# check people learn to re-run without reading.
#
# `max-behind` is a tolerance, not a switch. `0` is the strict reading — any
# commit on the base makes the branch stale — and on a repository that merges
# every few minutes that marks nearly every open pull request. A small non-zero
# value says "you are looking at roughly the current base", which is the actual
# question.
# ---------------------------------------------------------------------------
guard_freshness() {
  local behind="${1:-}" max="${2:-0}" enforce="${3:-false}"

  [[ "$behind" =~ ^[0-9]+$ ]] || { printf 'unknown:unreadable'; return; }
  [[ "$max" =~ ^[0-9]+$ ]] || max=0

  if [ "$behind" -le "$max" ]; then
    printf 'ok:current'
  elif [ "$enforce" = "true" ]; then
    printf 'fail:behind-%s' "$behind"
  else
    printf 'warn:behind-%s' "$behind"
  fi
}

# ---------------------------------------------------------------------------
# guard_shared <files-a> <files-b>
#
# Two newline-separated path lists in, the paths in both out, one per line,
# sorted and deduplicated. Empty output means the two pull requests cannot
# textually conflict.
#
# EXACT PATHS, NOT DIRECTORIES. Two pull requests both touching `src/` are not
# in conflict and saying they are would make this noise within a day. Two
# touching `src/auth.ts` might be, and that is worth one comment.
#
# It is also, deliberately, only a TEXTUAL overlap. Two pull requests that break
# each other through entirely separate files are exactly the case this cannot
# see; that one is bounded by the lane's base-health gate instead, after the
# fact rather than before it. Claiming otherwise here would be the more
# dangerous error, because a green "no overlap" would be read as "safe".
# ---------------------------------------------------------------------------
guard_shared() {
  local a="${1:-}" b="${2:-}"
  # `comm` needs both sides sorted and needs real files; process substitution
  # keeps it to one pass without a temporary anyone has to clean up. Blank lines
  # are dropped first — an empty path is in every list and would report every
  # pair as overlapping.
  comm -12 \
    <(printf '%s\n' "$a" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u) \
    <(printf '%s\n' "$b" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u)
}

# ---------------------------------------------------------------------------
# guard_overlap <shared-count> <enforce>
#
# Prints:
#   ok:distinct           — nothing shared with any other open pull request
#   warn:overlap-<n>      — shared paths, advisory
#   fail:overlap-<n>      — shared paths, and this caller enforces
#
# A non-numeric count is `unknown`, on the same reasoning as `guard_freshness`:
# the read failed, and the author is not the reason.
#
# ENFORCE HERE IS THE HARSHER OF THE TWO and should stay off in most
# repositories. Overlapping with an open pull request is legitimately common —
# a shared lockfile, a changelog, a barrel file — and the useful output is
# usually the comment naming who else is in there, not a red check. Turn it on
# for a repository where two people silently rewriting the same file has
# actually cost something.
# ---------------------------------------------------------------------------
guard_overlap() {
  local n="${1:-}" enforce="${2:-false}"

  [[ "$n" =~ ^[0-9]+$ ]] || { printf 'unknown:unreadable'; return; }

  if [ "$n" -eq 0 ]; then
    printf 'ok:distinct'
  elif [ "$enforce" = "true" ]; then
    printf 'fail:overlap-%s' "$n"
  else
    printf 'warn:overlap-%s' "$n"
  fi
}

# ---------------------------------------------------------------------------
# guard_rereview <head-sha> <bots> <reviews> <pending>
#
# Which of this repository's automated reviewers have said something about the
# CURRENT head, and which reviewed an earlier one and were never asked again.
#
#   bots     newline-separated logins, with or without a `[bot]` suffix — the
#            same value `review-bots` carries into the merge lane.
#   reviews  `login<TAB>commit-oid`, one per published review on this pull
#            request, in any order.
#   pending  newline-separated logins with an OUTSTANDING review request.
#
# Prints `login<TAB>state` per configured reviewer, `[bot]` stripped:
#   answered — it reviewed this exact head; nothing to do
#   pending  — it has been asked about something and has not answered yet
#   stale    — it reviewed an EARLIER commit on this pull request and has not
#              been asked about this one
#   absent   — it has never reviewed this pull request at all
#
# ONLY `stale` IS ACTIONABLE, and the other three are the reason this is a
# function rather than a one-line grep.
#
# `absent` is deliberately left alone. A reviewer that has never spoken here is
# either still on its first pass — it is fast, but it is not instant — or is not
# configured on this repository at all, and asking it again on every push would
# be a poke in the dark that produces nothing and looks, in the log, exactly
# like the thing that does work.
#
# `pending` is left alone for a sharper reason: a re-request replaces the
# outstanding one. Asking again for a review already in flight restarts it, so a
# pull request pushed twice in quick succession would keep cancelling its own
# review and never get one.
#
# `answered` is matched on the FULL oid and nothing shorter. An abbreviated
# match is a prefix match, and a prefix match against the wrong commit is the
# one error this must not make: it would report a head as reviewed that nobody
# has looked at.
# ---------------------------------------------------------------------------
guard_rereview() {
  local head="${1:-}" bots="${2:-}" reviews="${3:-}" pending="${4:-}"
  local bot login mine

  # No head, nothing to compare against. Silence rather than four `absent`
  # lines: a caller that could not read the sha has not learned that nobody
  # reviewed it.
  [ -n "$head" ] || return 0

  while IFS= read -r bot; do
    login="$(printf '%s' "$bot" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\[bot\]$//')"
    [ -n "$login" ] || continue
    # The reviewer's login is normalised on BOTH sides, not just on the
    # configured one. GitHub returns a bot as `name` in some responses and
    # `name[bot]` in others, and a comparison that strips the suffix from the
    # configured list only would read a review it does have as no review at
    # all — reporting `stale` for an answered head, or `absent` for a stale
    # one. Same reason the pending list is stripped below.
    mine="$(printf '%s\n' "$reviews" \
      | awk -F'\t' -v b="$login" '{ a = $1; sub(/\[bot\]$/, "", a) } a == b { print $2 }')"

    if printf '%s\n' "$mine" | grep -cxF -- "$head" >/dev/null; then
      printf '%s\tanswered\n' "$login"
    elif printf '%s\n' "$pending" | sed 's/\[bot\]$//' | grep -cxF -- "$login" >/dev/null; then
      printf '%s\tpending\n' "$login"
    elif printf '%s\n' "$mine" | grep -c '[^[:space:]]' >/dev/null; then
      printf '%s\tstale\n' "$login"
    else
      printf '%s\tabsent\n' "$login"
    fi
  done <<<"$bots"
}

# ---------------------------------------------------------------------------
# guard_exit <verdict>...
#
# The whole run's exit status from the verdicts it reached. Non-zero only when
# something says `fail`; `warn` and `unknown` are green on purpose, because the
# comment carries them and a check that is red for advice is a check that is
# always red.
# ---------------------------------------------------------------------------
guard_exit() {
  local v
  for v in "$@"; do
    case "$v" in
      fail:*) return 1 ;;
    esac
  done
  return 0
}
