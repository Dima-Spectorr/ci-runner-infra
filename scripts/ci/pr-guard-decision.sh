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
