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
STATUS_ISSUE="${STATUS_ISSUE:-}"
# auto | true | false. `auto` asks the base branch, which is the only answer
# that cannot drift: a per-repository input is a second copy of a fact GitHub
# already publishes, and the lane has been bitten once already by two lists that
# had to be kept equal by hand.
REQUIRE_UP_TO_DATE="${REQUIRE_UP_TO_DATE:-auto}"

R="$GITHUB_REPOSITORY"

# Somewhere to keep once-per-run markers that survive a SUBSHELL, because the
# things that want to say something once are all called from inside one. A
# directory rather than `mktemp` per marker: the marker's meaning is its
# ABSENCE, and a file that has to be created and then deleted to mean "not yet"
# is a name another process can win in between.
LANE_TMP="$(mktemp -d)"
trap 'rm -rf "$LANE_TMP"' EXIT
STATUS_WARN_ONCE="$LANE_TMP/status-surface-warned"

# ---------------------------------------------------------------------------
# THE QUEUE, AS SOMETHING YOU CAN LOOK AT.
#
# Mergify had a dashboard. This lane keeps no queue — it recomputes the
# candidate set from the API on every pass, which is what makes a cancelled
# pending run lose nothing — so there is no stored list to render. What there
# is, is the verdict the lane reached for every open pull request on this pass,
# and that is strictly more informative than a position in a list: it says what
# each one is waiting for.
#
# Every candidate gets a row, INCLUDING the ones the pass gives up on early.
# A view that silently omits the pull requests the lane could not read is a view
# that says "the queue is empty" when the truth is "the lane is broken", which
# is the same class of defect as a gate that reads a file it never matches.
#
# The first field is a sort key and is never rendered. Actionable rows carry the
# lane's own rank key, so the top row is the pull request the next action would
# touch. Everything else is parked behind them under a leading `8` or `9`, and
# the ordering inside that tail is deliberate: `8` for the ones the lane could
# not READ, `9` for the ones it deliberately skipped. A candidate it failed to
# read is the row someone needs to see first, above every ordinary wait.
# ---------------------------------------------------------------------------
QUEUE_ROWS=()

# `-` for an unknown field, never the empty string: every row is split on tabs
# further down, tab is IFS whitespace, and an empty field would collapse and
# shift every column after it left. Same defect as the detail read below.
qf() { [ -n "${1:-}" ] && printf '%s' "$1" || printf -- '-'; }

queue_row() { # <sortkey> <num> <title> <verdict> <priority> <behind> <checks>
  QUEUE_ROWS+=("$(qf "$1")"$'\t'"$(qf "$2")"$'\t'"$(qf "$3")"$'\t'"$(qf "$4")"$'\t'"$(qf "$5")"$'\t'"$(qf "$6")"$'\t'"$(qf "$7")")
}

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
# `--paginate` on both, and it is not defensive padding. A commit in this
# repository already carries more than twenty check-runs and the shard count
# only grows; past a hundred, an unpaginated read silently returns the first
# page, a required check that fell off the end is counted ABSENT, and the lane
# stops merging a pull request that is in fact green. The retiring
# `mergify-nudge` documents the same truncation for the same endpoint.
check_counts() {
  local sha="$1"
  local runs statuses all

  # `|| true` DOES NOT MEAN "NO DATA". `gh api` writes the error BODY to
  # STDOUT on a non-2xx, so a swallowed failure does not leave the stream
  # empty — it leaves one more JSON object in it, with no `.name`. `group_by`
  # then produces a null key, `map({(.name): .state})` dies on "Object keys
  # must be strings", `all` comes back EMPTY, and every required check
  # resolves to the empty string: not `success`, not `pending`, not `absent`,
  # so the `*)` arm below counts all of them FAILED.
  #
  # Measured live on 2026-08-25 against an App token that did not hold
  # `Commit statuses: read`: two check-runs, both `success`, reported as
  # `skip:red failed=2` with `0/2` green, in six repositories at once. The
  # lane was not merging anything and every surface said the pull request was
  # red. So the exit status is kept, and a failed read never joins the stream.
  #
  # EVERY DIAGNOSTIC BELOW GOES TO STDERR. This function's stdout IS its return
  # value — `counts="$(check_counts "$sha")"` — so a log line written to stdout
  # would be read as the counts, which is the same class of mistake the rest of
  # this comment is about.
  if ! runs="$(gh api --paginate "repos/$R/commits/$sha/check-runs?per_page=100" \
    --jq '.check_runs[] | {name: .name, state: (if .status != "completed" then "pending" else (.conclusion // "pending") end), at: (.completed_at // .started_at // "")}' 2>/dev/null)"; then
    echo "lane: cannot read the check-runs of $sha — the lane is blind, not idle" >&2
    LANE_FATAL=1
    echo "0 ${#REQUIRED[@]} 0 0"
    return
  fi

  # The status surface is treated differently on purpose. A repository may
  # legitimately publish no commit statuses at all, and the merge App may not
  # hold `Commit statuses: read` — neither is a reason to stop merging on the
  # check-runs that ARE readable. What it is a reason for is saying so once: a
  # required context that happens to be a legacy status then reads as ABSENT,
  # the lane skips on `missing-required`, and an operator who was not told
  # about the 403 has no way to tell that apart from a renamed job.
  #
  # ONCE means a FILE, not a variable. This function is called as
  # `counts="$(check_counts "$sha")"`, which is a SUBSHELL — an assignment made
  # here dies with it, so a variable guard is re-armed on every pull request and
  # says "once" thirty times. Measured on 2026-08-25: the warning printed once
  # per open pull request on IntegrateIT and on Apigee-Portal, which is the
  # volume at which an operator learns to scroll past the one line that names
  # the permission they are missing.
  if ! statuses="$(gh api --paginate "repos/$R/commits/$sha/status?per_page=100" \
    --jq '.statuses[] | {name: .context, state: (if .state == "pending" then "pending" else .state end), at: (.updated_at // "")}' 2>/dev/null)"; then
    statuses=""
    if [ ! -e "$STATUS_WARN_ONCE" ]; then
      : >"$STATUS_WARN_ONCE"
      echo "lane: WARNING the commit-status surface is unreadable — grant the merge App 'Commit statuses: read'. Check-runs are still read; a required check that is a legacy commit status will count as MISSING and hold the lane." >&2
    fi
  fi

  # Newest wins per name. `--paginate` emits one document per page, so these are
  # streams of objects rather than one array; `-s` collects the stream. The
  # `select` is the second belt on the failure above: anything without a string
  # name is not a check, and one of them must never be able to void the whole
  # aggregation.
  all="$(printf '%s\n%s\n' "$runs" "$statuses" \
    | jq -s '[.[] | select(type == "object" and (.name | type) == "string")]
             | sort_by(.at) | group_by(.name) | map(.[-1]) | map({(.name): .state}) | add // {}')"

  # An empty `all` is what the poisoned stream produced, and it is not the same
  # thing as a commit with no checks — that is `{}`. Never let it fall through
  # to the classifier, which would read it as every check failing.
  if [ -z "$all" ]; then
    echo "lane: the check surfaces of $sha did not aggregate — the lane is blind, not idle" >&2
    LANE_FATAL=1
    echo "0 ${#REQUIRED[@]} 0 0"
    return
  fi

  local green=0 missing=0 failed=0 pending=0 name state
  local -a were_skipped=()
  for name in "${REQUIRED[@]}"; do
    state="$(printf '%s' "$all" | jq -r --arg n "$name" '.[$n] // "absent"')"
    case "$state" in
      success) green=$((green + 1)) ;;
      pending | queued | in_progress) pending=$((pending + 1)) ;;
      absent) missing=$((missing + 1)) ;;
      # `skipped` PASSES, because that is what the platform means by it and what
      # every gate around this one already does. GitHub's own branch protection
      # counts a skipped required check as satisfied, and so did Mergify — a job
      # behind a path filter did not run because the diff did not reach it.
      #
      # Treating it as a failure was this lane's first position, and it was
      # wrong in a way only the fleet could show: measured 2026-08-25, a pull
      # request touching one Markdown file skipped `Web production build` on
      # Apigee-Portal and BOTH required jobs on CarListPrice, so the lane held
      # two repositories on a change nothing could have broken while GitHub
      # itself said mergeable. Nothing red, nothing merging — the Mergify
      # failure this lane exists to end, rebuilt from the other side.
      #
      # It is never silent. The names are printed with the verdict, so a job
      # that skipped because someone broke its `if:` is visible rather than
      # absorbed — that is the risk this arm carries, and the log is its price.
      skipped)
        green=$((green + 1))
        were_skipped+=("$name")
        ;;
      # `neutral` is NOT a pass. A check that ran and declined to judge has said
      # something different from one that never needed to run.
      *) failed=$((failed + 1)) ;;
    esac
  done
  if [ "${#were_skipped[@]}" -gt 0 ]; then
    echo "lane: $sha — required and SKIPPED, counted as passing: $(
      IFS=', '; echo "${were_skipped[*]}")" >&2
  fi
  echo "$green $missing $failed $pending"
}

# ---------------------------------------------------------------------------
# already_released <pr> <sha> — has the lane already said this out loud?
#
# The lane keeps no state of its own, deliberately, so the record of a release
# is the release notice: a hidden marker naming the exact head sha. Only read
# when a verdict is `drop`, which is rare.
# ---------------------------------------------------------------------------
released_marker() { printf '<!-- merge-lane:released:%s -->' "$1"; }

already_released() {
  local num="$1" sha="$2" bodies
  bodies="$(gh api --paginate "repos/$R/issues/$num/comments?per_page=100" --jq '.[].body' 2>/dev/null || true)"
  # `grep -c ... >/dev/null` rather than `-q`: under `pipefail` a `-q` that
  # exits on its first match closes the pipe and the writer dies on SIGPIPE,
  # which this repository has been bitten by often enough to have a gate for.
  printf '%s\n' "$bodies" | grep -cF -- "$(released_marker "$sha")" >/dev/null
}

# ---------------------------------------------------------------------------
# Does this base require a branch to be UP TO DATE before it may merge?
#
# Answered once per run from the base's own effective rules, because the lane
# must not be stricter than the branch it merges into. `update:behind` on a
# non-strict base discards a green suite and spends a full CI run to rebuild
# the same answer, and on a busy repository the base moves again before that
# run lands — so the pull request never converges and the lane burns its whole
# action budget re-updating branches it was always allowed to merge.
#
# FAILS CLOSED. An unreadable answer means strict, which costs a CI run; the
# other way round asks GitHub for a merge it will refuse.
# ---------------------------------------------------------------------------
LANE_STRICT=''
lane_resolve_strict() {
  [ -z "$LANE_STRICT" ] || return 0

  case "$REQUIRE_UP_TO_DATE" in
    true)
      LANE_STRICT=1
      echo "lane: up-to-date required (pinned by configuration)"
      return 0
      ;;
    false)
      LANE_STRICT=0
      echo "lane: up-to-date NOT required (pinned by configuration)"
      return 0
      ;;
  esac

  # `rules/branches/<branch>` is the EFFECTIVE rule set for the branch — every
  # ruleset that matches it, already merged — so one call answers the question
  # no matter how many rulesets the repository has. Classic branch protection
  # surfaces here too.
  local strict
  if ! strict="$(gh api "repos/$R/rules/branches/$LANE_BASE" \
    --jq '[.[] | select(.type=="required_status_checks")
             | .parameters.strict_required_status_checks_policy] | any' 2>/dev/null)" \
    || [ -z "$strict" ]; then
    LANE_STRICT=1
    echo "lane: cannot read the rules on $LANE_BASE — assuming up-to-date IS required"
    return 0
  fi

  if [ "$strict" = "true" ]; then
    LANE_STRICT=1
    echo "lane: $LANE_BASE requires a branch to be up to date — behind means update"
  else
    LANE_STRICT=0
    echo "lane: $LANE_BASE does not require a branch to be up to date — behind still merges"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# One pass: read every candidate, rank them, act on the best one.
# Returns 0 if it acted, 1 if there was nothing to do.
# ---------------------------------------------------------------------------
one_pass() {
  local prs base_sha

  # THE BASE AS IT STOOD WHEN THIS PASS READ THE WORLD.
  #
  # Everything below — `behind_by` above all — is a statement about this
  # commit. The `concurrency` group serialises merge-lane runs against each
  # other, but it says nothing about a human pushing to the base, or an admin
  # merge, or a release workflow committing. Any of those between the
  # comparison and the merge call would land a head that was verified against
  # a base that no longer exists, and `sha=` would not notice: it pins the
  # head. So the tip is captured here and re-read immediately before acting.
  # FATAL, NOT "NOTHING TO DO". Every other `return 1` here means the lane
  # looked and found nothing actionable, and the run is rightly green. This one
  # means the lane could not look at all — a token without access, a base that
  # does not exist, a missing `gh` — and a green run saying "0 actions" is
  # indistinguishable from a healthy quiet day. That is exactly how seven
  # repositories reported a working lane for a morning while merging nothing.
  if ! base_sha="$(gh api "repos/$R/commits/$LANE_BASE" --jq '.sha' 2>/dev/null)" || [ -z "$base_sha" ]; then
    echo "lane: cannot read the tip of $LANE_BASE — the lane is blind, not idle"
    LANE_FATAL=1
    return 1
  fi

  lane_resolve_strict

  # Reset here, at the top of the pass, and never once per run. Every pass
  # re-reads the world, so the LAST pass is the only one describing the world as
  # it is now; the earlier ones describe a world that a merge has already
  # changed. Above the early return as well as above the loop, or a pass that
  # finds nothing open would publish the previous pass's rows as if they were
  # still there.
  QUEUE_ROWS=()

  # Paginated: past a hundred open pull requests on one base, an unpaginated
  # read would make every candidate after the first page permanently invisible
  # — and drafts and red ones, which the lane can never clear, are exactly what
  # would sit on that page holding a green one out of sight forever.
  #
  # THREE FIELDS, NONE OF WHICH CAN BE EMPTY, AND THAT IS THE POINT.
  #
  # Tab is IFS whitespace, so `read` collapses a run of them and an empty field
  # silently shifts every field after it left. `.number` and `.head.sha` are
  # always present and `.draft|tostring` is always `true` or `false`, so this
  # split cannot slide. `mergeable_state` used to be read here as a fourth
  # field and is not — it is unused, it CAN be empty, and carrying an
  # empty-able field through a tab split is the defect this comment exists to
  # stop coming back.
  prs="$(gh api --paginate "repos/$R/pulls?state=open&base=$LANE_BASE&per_page=100" \
    --jq '.[] | [.number, .head.sha, (.draft|tostring)] | @tsv')"
  if [ -z "$prs" ]; then
    echo "lane: no open pull requests on $LANE_BASE"
    return 1
  fi

  local candidates=()
  local num sha draft

  while IFS=$'\t' read -r num sha draft; do
    [ -n "$num" ] || continue

    # `mergeable` is computed asynchronously and is null until GitHub has done
    # it, which is why the list call above is not enough — the list does not
    # carry it at all. Read per pull request, and let null stay null: the
    # decision treats it as a wait, not as a guess in either direction.
    #
    # ONE FIELD PER LINE, NOT `@tsv` INTO `read`.
    #
    # `labels` is empty for an unlabelled pull request, which is the ORDINARY
    # case, and tab is IFS *whitespace* — so `IFS=$'\t' read -r a b c` collapses
    # the run of two tabs into one delimiter, slides the head sha into `labels`
    # and leaves `sha` EMPTY. Every call below then addresses
    # `repos/<repo>/compare/main...` and `.../commits/`, and the lane can never
    # act on any pull request that has no label.
    #
    # This is exactly what the first live dry run did, and it presented as
    # `wait:base-comparison-unreadable` — a verdict that reads as a transient
    # API problem. `mapfile` splits on newlines only and keeps empty lines, so
    # the field count is checked rather than inferred.
    #
    # The title is read here rather than in the list call above for the same
    # reason: it is free text, it is the one field that could itself contain a
    # tab, and it exists only to be shown in the queue snapshot.
    local detail_lines=() mergeable labels title behind age headdate
    mapfile -t detail_lines < <(gh api "repos/$R/pulls/$num" \
      --jq '(.mergeable|tostring), (.labels|map(.name)|join(",")), .head.sha, .title')
    if [ "${#detail_lines[@]}" -ne 4 ]; then
      echo "lane: #$num wait:detail-unreadable — the pull request read returned ${#detail_lines[@]} field(s), not 4"
      queue_row 8 "$num" '' wait:detail-unreadable '' '' ''
      continue
    fi
    mergeable="${detail_lines[0]}"
    labels="${detail_lines[1]}"
    sha="${detail_lines[2]}"
    title="${detail_lines[3]}"

    # THE FIRST READ IS THE REQUEST, NOT THE ANSWER. GitHub computes
    # mergeability lazily: reading `/pulls/<n>` on a pull request nobody has
    # asked about recently ENQUEUES the computation and returns `null` in the
    # same breath. A lane that reads once therefore learns nothing about a stale
    # pull request — and stale is the normal state of one waiting in a queue.
    #
    # Measured on 2026-08-25: a dispatched pass on IntegrateIT and on
    # Apigee-Portal returned `null` for EVERY open pull request, so the pass did
    # nothing at all. Left alone that is not merely slow, it is the Mergify
    # failure this lane exists to end: nothing red, nothing merging, and the
    # next answer arriving whenever the next trigger happens to fire.
    #
    # So ask again, briefly. Bounded on purpose — three reads, two seconds
    # apart, is the difference between "not computed yet" and "GitHub is having
    # a bad day", and the second one is still a wait rather than a guess.
    local mergeable_try=0
    while [ "$mergeable" = "null" ] && [ "$mergeable_try" -lt 2 ]; do
      mergeable_try=$((mergeable_try + 1))
      sleep 2
      # The re-read is normalised rather than trusted. `gh api` writes the error
      # BODY to stdout on a non-2xx, so a failed read hands back a JSON document
      # here, not an empty string — and `true`/`false` are the only two values
      # downstream is allowed to see as an answer.
      local reread=''
      reread="$(gh api "repos/$R/pulls/$num" --jq '.mergeable|tostring' 2>/dev/null)" || reread=''
      case "$reread" in
        true | false) mergeable="$reread" ;;
        *) mergeable=null ;;
      esac
    done

    local conflict=''
    case "$mergeable" in
      true) conflict=0 ;;
      false) conflict=1 ;;
      *) conflict='' ;;
    esac

    if [ -n "$REQUIRE_LABEL" ] && [[ ",$labels," != *",$REQUIRE_LABEL,"* ]]; then
      echo "lane: #$num skip:no-label ($REQUIRE_LABEL)"
      queue_row 9 "$num" "$title" "skip:no-label($REQUIRE_LABEL)" '' '' ''
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
    #
    # And it FAILS CLOSED. A transient 5xx, a rate limit or an expired token
    # all make this call fail, and a fallback of 0 would read as "current with
    # the base" — the one answer that lets a merge through. `sha=` on the merge
    # call does not save us here: it pins the head, and being behind is a fact
    # about the BASE. An unreadable comparison means the lane does not know, so
    # it does nothing this pass and looks again on the next one.
    # FAILING CLOSED SILENTLY IS ITS OWN BUG.
    #
    # `wait:base-comparison-unreadable` is the right verdict for a transient
    # 5xx, for a missing App permission, and for a bug in this script that
    # builds a nonsense URL. On a schedule those are indistinguishable: the lane
    # prints the same line every fifteen minutes forever and nothing ever says
    # which one it is. That is not hypothetical — the field-collapse defect
    # described above hid behind this exact line on the first live dry run, and
    # an hour went into suspecting App permissions that were correct all along.
    # So the error goes to the log. It is a `gh` diagnostic (status, URL,
    # message), never a body the lane authenticates with.
    #
    # AND IT IS ONLY ASKED WHEN THE BASE MAKES IT MATTER. This is one API call
    # per pull request per pass, and on a base that does not require a branch to
    # be up to date the answer changes no verdict — it would survive only as a
    # column in the queue table. On the repository this lane was built for that
    # is ~86 calls a pass and five passes a run, which is most of the difference
    # between a pass that finishes inside `timeout-minutes` and one that is
    # killed at 15 minutes having merged nothing. The column says `n/a` rather
    # than `0`, because "not asked" and "up to date" are different facts and the
    # table is what an operator reads to decide the lane is working.
    local behind_cell
    if [ "$LANE_STRICT" = "0" ]; then
      behind=0
      behind_cell='n/a'
    else
      local cmp_err
      cmp_err="$(mktemp)"
      if ! behind="$(gh api "repos/$R/compare/$LANE_BASE...$sha" --jq '.behind_by' 2>"$cmp_err")" \
        || [[ ! "$behind" =~ ^[0-9]+$ ]]; then
        echo "lane: #$num wait:base-comparison-unreadable — not assuming it is current"
        echo "lane: #$num compare said: $(tr '\n' ' ' <"$cmp_err" | cut -c1-400)"
        rm -f "$cmp_err"
        queue_row 8 "$num" "$title" wait:base-comparison-unreadable "$priority" '' ''
        continue
      fi
      rm -f "$cmp_err"
      behind_cell="$behind"
    fi

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
      "${#REQUIRED[@]}" "$green" "$missing" "$failed" "$pending" "$behind" "$age" "$BUDGET" \
      "$LANE_STRICT")"

    echo "lane: #$num $verdict (sha=${sha:0:8} priority=$priority behind=$behind_cell)"

    # Ranked exactly as the lane ranks it when it is actionable, and parked
    # behind everything actionable when it is not — so the top row is always the
    # pull request the next action would touch, and the rows under it are an
    # order rather than a list.
    if lane_admits "$verdict"; then
      queue_row "$(lane_rank "$verdict" "$priority" "${age:-0}")" \
        "$num" "$title" "$verdict" "$priority" "$behind_cell" "$green/${#REQUIRED[@]}"
    else
      queue_row "8:$(printf '%03d' "$priority"):$(printf '%08d' "$num")" \
        "$num" "$title" "$verdict" "$priority" "$behind_cell" "$green/${#REQUIRED[@]}"
    fi

    # A release is a one-shot, not a state the lane keeps re-announcing. The
    # dropped pull request stays open, stays a candidate, and its verdict stays
    # `drop` until something changes — so without this it would be ranked first
    # again on the very next iteration, comment again, and go on doing that
    # every fifteen minutes for as long as the check never reports. Once per
    # head sha is once: the marker lives in the comment itself, which survives
    # a run, a restart and a re-installation, and a push produces a new sha and
    # therefore a new, warranted release notice.
    if [ "${verdict%%:*}" = "drop" ] && already_released "$num" "$sha"; then
      echo "lane: #$num drop already announced for ${sha:0:8} — leaving it alone"
      continue
    fi

    if lane_admits "$verdict"; then
      local key
      key="$(lane_rank "$verdict" "$priority" "${age:-0}")"
      candidates+=("$key	$num	$sha	$verdict")
    fi
  done <<<"$prs"

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "lane: nothing actionable this pass"
    return 1
  fi

  # Ranked once, and the whole ranking is kept rather than only its head — see
  # the batch below for why the lane sometimes wants more than the first row.
  local ranked
  ranked="$(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort)"

  local action_num action_sha action_verdict
  IFS=$'\t' read -r _ action_num action_sha action_verdict <<<"$(head -n1 <<<"$ranked")"

  if [ "$DRY_RUN" = "true" ]; then
    echo "::notice::dry-run — would take '$action_verdict' on #$action_num"
    return 1
  fi

  # THE OTHER HALF OF THE RACE. `sha=` below rejects a moved HEAD; nothing in
  # the merge API rejects a moved BASE, so it is checked here. If the tip is no
  # longer what `behind_by` was computed against, every verdict in this pass
  # describes a world that has gone — so none of them is acted on, and the next
  # pass reads the new one.
  local base_now
  if ! base_now="$(gh api "repos/$R/commits/$LANE_BASE" --jq '.sha' 2>/dev/null)" || [ "$base_now" != "$base_sha" ]; then
    echo "::warning::$LANE_BASE moved while this pass was reading (${base_sha:0:8} → ${base_now:0:8}) — nothing acted on, re-reading."
    return 1
  fi

  # HOW MANY OF THE RANKING THIS PASS MAY ACT ON.
  #
  # One, normally, and then the whole world is read again — because a merge
  # moves the base, and on a base that requires a branch to be up to date that
  # invalidates every `behind_by` this pass computed. Re-reading is the only
  # honest thing to do there.
  #
  # On a base that does NOT require it, that reasoning does not apply and the
  # cost is severe. A merge cannot make another pull request's required checks
  # any less green — they were reported against ITS head, which nothing here
  # touched — and being behind is not a condition GitHub imposes. The only thing
  # a merge can change is whether a branch still applies cleanly, and the merge
  # API refuses that itself with a 405, which lands in the refusal path below
  # and stops the batch. So the re-walk buys nothing and costs a full walk of
  # the open list: on IntegrateIT that is ~5 walks of ~86 pull requests per run,
  # 14m34s against `timeout-minutes: 15`, which is why passes were being killed
  # mid-drain and the queue never emptied.
  #
  # Only merges batch. A `drop` is a comment the lane owes anyway, but an
  # `update` starts a CI run whose result the next candidate might depend on,
  # and a strict base is the only place updates occur — so anything that is not
  # a merge ends the batch and the world is re-read.
  #
  # Spelled as an `if` rather than the terser `[ … ] && batch=…` used elsewhere
  # in this file. Under `set -e` that form is only survivable because `one_pass`
  # is always called as the condition of an `if`, which suppresses errexit for
  # the whole call; a future caller that runs it as a plain statement would turn
  # every strict-base pass into a silent exit.
  local batch=1
  if [ "$LANE_STRICT" = "0" ] && [ "$MAX_ACTIONS" -gt "$acted" ]; then
    batch=$((MAX_ACTIONS - acted))
  fi

  PASS_ACTED=0
  while IFS=$'\t' read -r _ action_num action_sha action_verdict; do
    [ -n "$action_num" ] || continue
    [ "$PASS_ACTED" -lt "$batch" ] || break
    if [ "$PASS_ACTED" -gt 0 ] && [ "${action_verdict%%:*}" != "merge" ]; then
      break
    fi
    lane_take_action "$action_num" "$action_sha" "$action_verdict" || break
    PASS_ACTED=$((PASS_ACTED + 1))
  done <<<"$ranked"

  [ "$PASS_ACTED" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Take one action. 0 if it landed, 1 if GitHub refused it — a refusal is never
# retried in place, because the reason for it is always that the world moved,
# and the next pass is where the lane looks at the world it moved to.
# ---------------------------------------------------------------------------
lane_take_action() {
  local action_num="$1" action_sha="$2" action_verdict="$3"

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
      gh api "repos/$R/issues/$action_num/comments" -f body="$(printf '%s\n\n%s\n\n%s\n' \
        "The merge lane released this pull request: \`$action_verdict\`." \
        "Its required checks did not all reach a conclusion within the lane's budget, so it was let go rather than left holding the lane. Nothing is wrong with the diff as far as the lane knows — push, or re-run the checks, and it will be picked up again automatically." \
        "$(released_marker "$action_sha")")" --silent
      echo "::notice::released #$action_num ($action_verdict)"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# render_queue — the snapshot, as markdown, on stdout.
#
# Rows are ranked exactly as the lane ranks them, so the pull request at the top
# is the one the next action would touch. Everything below it is ordered by the
# same key, which means the table reads as an ORDER rather than as a list of
# facts in whatever order the API returned them.
# ---------------------------------------------------------------------------
# SC2016: the single-quoted strings below are printf FORMATS and the backticks
# in them are markdown code spans, not command substitution. Double-quoting them
# to satisfy the linter is the change that would actually break this — the shell
# would then try to run `%s` as a command.
# shellcheck disable=SC2016
render_queue() {
  printf '## Merge lane — `%s`\n\n' "$LANE_BASE"
  if [ "$DRY_RUN" = "true" ]; then
    printf '> **Dry run.** Every verdict below was computed for real; none was acted on.\n\n'
  fi

  if [ "${#QUEUE_ROWS[@]}" -eq 0 ]; then
    printf '_No open pull requests on `%s`._\n\n' "$LANE_BASE"
  else
    printf '| pull request | verdict | waiting on | priority | behind | required |\n'
    printf '|---|---|---|---|---|---|\n'
    local k n t v p b c reason
    # Sorted on the hidden first column, which is the lane's own rank key.
    while IFS=$'\t' read -r k n t v p b c; do
      : "$k"
      # A title is free text and a `|` in it would end the cell early, taking
      # every column after it with it.
      t="${t//|/\\|}"
      reason="${v#*:}"
      [ "$reason" = "$v" ] && reason='—'
      printf '| [#%s](https://github.com/%s/pull/%s) %s | `%s` | %s | %s | %s | %s |\n' \
        "$n" "$R" "$n" "$t" "${v%%:*}" "$reason" "$p" "$b" "$c"
    done < <(printf '%s\n' "${QUEUE_ROWS[@]}" | sort)
    printf '\n'
  fi

  printf 'Requires all of:'
  local c2
  for c2 in "${REQUIRED[@]}"; do printf ' `%s`' "$c2"; done
  printf '\n\n'

  printf 'Read %s' "$(date -u +'%Y-%m-%d %H:%M:%SZ')"
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf ' by [this run](https://github.com/%s/actions/runs/%s)' "$R" "$GITHUB_RUN_ID"
  fi
  printf '. The lane re-reads everything on every pass; nothing here is stored.\n'
}

# The Actions run page. Free, native, no API call, and it is where someone
# already is when they go looking at why the lane did what it did.
publish_step_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  render_queue >>"$GITHUB_STEP_SUMMARY"
}

# ...and one bookmarkable place that is always current, for someone who is not
# in the Actions tab. The body is REWRITTEN rather than commented on: an edit
# notifies nobody, where a comment every fifteen minutes would make the issue
# unusable within a day.
#
# NEEDS `Issues: write` ON THE MERGE APP, WHICH IS NOT `Pull requests: write`.
# GitHub treats them as separate permissions even though a pull request is an
# issue, and the lane's existing release comment goes through the pull-request
# permission. Without the grant this call 404s, which is why it warns and
# returns rather than failing the run: a queue view that cannot be published is
# not a reason to stop merging.
publish_status_issue() {
  # Unset is the ordinary case and means "summary only". Anything that is not a
  # positive number is an operator typo, and it gets said out loud rather than
  # turning into a PATCH against a nonsense path.
  [ -n "$STATUS_ISSUE" ] || return 0
  if [[ ! "$STATUS_ISSUE" =~ ^[1-9][0-9]*$ ]]; then
    echo "::warning::status-issue is '$STATUS_ISSUE', which is not an issue number — the queue was written to the job summary only"
    return 0
  fi
  # ISSUES AND PULL REQUESTS SHARE THE NUMBER SPACE, AND THIS ENDPOINT.
  #
  # `repos/<r>/issues/<n>` happily addresses a pull request, so a mistyped
  # variable does not 404 — it OVERWRITES SOMEONE'S PULL REQUEST DESCRIPTION,
  # every fifteen minutes, with a table. The lane holds `Contents: write` and
  # merges code; the one thing it must not do is destroy the text explaining
  # what is being merged. One GET, once per run, to make that impossible.
  local kind
  kind="$(gh api "repos/$R/issues/$STATUS_ISSUE" --jq 'if .pull_request then "pull-request" else "issue" end' 2>/dev/null || echo 'unreadable')"
  if [ "$kind" != "issue" ]; then
    echo "::warning::not publishing the queue to #$STATUS_ISSUE — it reads as '$kind', and this lane only ever rewrites the body of a plain issue. The queue is in the job summary."
    return 0
  fi

  local body
  body="$(render_queue)"
  if gh api -X PATCH "repos/$R/issues/$STATUS_ISSUE" -f body="$body" --silent 2>/dev/null; then
    echo "lane: queue published to issue #$STATUS_ISSUE"
  else
    echo "::warning::could not update the queue issue #$STATUS_ISSUE — the merge App needs 'Issues: write', and a permission added to an installed App stays pending until the installation owner accepts it. Merging is unaffected."
  fi
}

acted=0
# How many actions the pass that just ran took. Normally one; more when the base
# lets a pass drain several without having to re-read the world between them.
PASS_ACTED=0
# Set by `one_pass` when the lane could not read the world it is meant to judge.
LANE_FATAL=0
while [ "$acted" -lt "$MAX_ACTIONS" ]; do
  if one_pass; then
    acted=$((acted + PASS_ACTED))
    # The world changed: a merge just moved the base, so everything else is now
    # one commit behind and has to be re-read rather than judged on the facts
    # gathered before it.
    now="$(date -u +%s)"
  else
    break
  fi
done

# After the loop, so the snapshot describes the world the lane is LEAVING
# rather than the one it found — a pull request it just merged is gone from it,
# and the one that was behind that merge no longer is.
publish_step_summary
publish_status_issue

echo "lane: done, $acted action(s)"

# After the summary and the queue issue, so an operator looking at a red lane
# still gets whatever the run managed to see.
if [ "$LANE_FATAL" -ne 0 ]; then
  echo "lane: failing the run — it could not read $LANE_BASE, so '0 actions' means nothing" >&2
  exit 1
fi
