# shellcheck shell=bash
# merge-lane-retry — whether ONE repository's merge lane should be dispatched
# again, as a PURE function over facts somebody else collected (#1463).
#
# WHY THIS EXISTS
#
# A lane pass that is skipped under the App quota floor, or fails part-way on
# the quota, was never retried. `merge-lane.sh` says the lane "resumes on the
# next trigger or the cron backstop" — but the next trigger is a CI completion,
# and none comes when every pull request is already green; and the backstop in
# a consumer's `merge-lane-events.yml` is DAILY (#1380). So one lost pass
# stalled a repository for up to a day: DataRetrival, 2026-09-30 to 10-01,
# twelve green pull requests, drained at once by a manual dispatch.
#
# WHAT IT DECIDES FROM
#
# Not from "the last pass was lost". A quota-skipped pass ends SUCCESS, so the
# run list cannot tell a lost pass from a real one. The symptom is readable
# instead: the repository has a pull request GitHub itself calls ready to
# merge, and no lane pass has succeeded for `retry_after` seconds. A real pass
# would have merged it; a pass that deliberately holds it is retried a bounded
# number of times and then reported, never retried forever.
#
# WHY EVERY UNKNOWN HOLDS
#
# The inverse of the fleet audit, for the reason the reaper gives: this file
# ACTS. A dispatch on a fact that could not be read spends a hosted minute and
# App quota on a guess, on a timer, in every repository. So an unknown never
# dispatches — and it is printed as `hold:unreadable`, never as
# `skip:nothing-ready`, so "did not check" and "nothing to do" stay apart.
#
# Tenancy-agnostic: no customer literals, no repository names. Every threshold
# is an input.

# How long after the last SUCCESSFUL pass a ready pull request is left alone.
# With the watchdog on a 15-minute timer this bounds a lost pass at 30 minutes:
# at most one tick that still sees the pass as recent, and the one after it.
LANE_RETRY_AFTER_DEFAULT=900
# How many of the watchdog's own dispatches one repository may receive inside
# the window the collector reads (six hours by default). A pull request the
# lane holds on purpose — a base it will not vouch for, a required check no
# workflow emits — is ready by GitHub's reading forever, and without a cap it
# would buy a hosted pass every tick: the cost #1380 removed, moved to another
# runner. `0` turns the cap off, the spelling every numeric knob here uses.
LANE_RETRY_MAX_DEFAULT=4

# A fact that may be compared with `-lt`. `[ "$x" -lt "$y" ]` on a non-numeric
# operand exits 2, and 2 is falsey, so an unparseable fact would silently take
# the "not under the threshold" branch.
_retry_is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# _retry_fact <facts> <key> — the FIRST value of <key> in a `k=v;k=v` string.
# First wins, so a collector that prepends `readable=0` overrides whatever a
# later fragment claimed.
_retry_fact() {
  local hay=";$1;" key="$2" rest
  case "$hay" in
    *";$key="*)
      rest="${hay#*";$key="}"
      printf '%s' "${rest%%;*}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# lane_retry_quota_holds <remaining> <floor> — true when nothing should be
# dispatched because the merge App's shared quota is under the lane's floor.
#
# The lane refuses to start a pass below the same floor, so a dispatch now buys
# a hosted run that reads nothing. An UNREADABLE quota does not hold, which is
# the lane's own rule: the reads that follow fail loudly if it really is gone.
# ---------------------------------------------------------------------------
lane_retry_quota_holds() {
  local remaining="${1:-}" floor="${2:-}"
  _retry_is_number "$remaining" || return 1
  _retry_is_number "$floor" || return 1
  # A floor of 0 turns the hold off with no arm of its own: nothing is under 0.
  [ "$remaining" -lt "$floor" ]
}

# ---------------------------------------------------------------------------
# lane_retry_verdict "key=value;key=value;..." — one line, always.
#
#   dispatch:<workflow file> ...   start a lane pass through that file
#   hold:<why> ...                 a pull request is ready and nothing is sent
#   skip:<why>                     nothing here for the watchdog to do
#
# Facts:
#   tier          the manifest tier. Only `pool` and `lane` carry a lane a
#                 consumer does not already time itself; the `source`
#                 repository runs its own fifteen-minute sweep.
#   readable      0 when any read failed
#   ready         open, non-draft pull requests on the default branch that
#                 GitHub reports as clean, unstable or has-hooks
#   has_events    1 | 0 | disabled — `merge-lane-events.yml`, the hosted file
#   has_lane      1 | 0 | disabled — `merge-lane.yml`
#   inflight      lane runs queued or running, young enough to be real
#   last_success_age  seconds since the newest successful lane run ended, ""
#                 when there is none inside the window
#   retries       the watchdog's own dispatches inside the window
#   retry_after   see LANE_RETRY_AFTER_DEFAULT
#   max_retries   see LANE_RETRY_MAX_DEFAULT
# ---------------------------------------------------------------------------
lane_retry_verdict() {
  local f="${1:-}" tier readable ready has_events has_lane inflight age retries
  local retry_after max_retries target
  tier=$(_retry_fact "$f" tier)
  readable=$(_retry_fact "$f" readable)
  ready=$(_retry_fact "$f" ready)
  has_events=$(_retry_fact "$f" has_events)
  has_lane=$(_retry_fact "$f" has_lane)
  inflight=$(_retry_fact "$f" inflight)
  age=$(_retry_fact "$f" last_success_age)
  retries=$(_retry_fact "$f" retries)
  retry_after=$(_retry_fact "$f" retry_after)
  max_retries=$(_retry_fact "$f" max_retries)
  _retry_is_number "$retry_after" || retry_after=$LANE_RETRY_AFTER_DEFAULT
  _retry_is_number "$max_retries" || max_retries=$LANE_RETRY_MAX_DEFAULT

  case "$tier" in
    pool|lane) ;;
    *) echo "skip:tier-${tier:-unknown}"; return 0 ;;
  esac

  if [ "$readable" = 0 ] || ! _retry_is_number "$ready"; then
    echo "hold:unreadable"; return 0
  fi
  if [ "$ready" -eq 0 ]; then
    echo "skip:nothing-ready"; return 0
  fi

  # WHICH FILE, AND THE ONE THIS MUST NEVER START.
  #
  # The events file is hosted by construction. A repository that still has only
  # `merge-lane.yml` runs it on whatever `runs-on` that file names: hosted for
  # the `lane` tier, a POOL LABEL for the `pool` tier — and a dispatch there
  # starts a self-hosted host to answer "nothing to merge", on a timer, which
  # is exactly what #1380 removed. So an unmigrated pool repository is held and
  # reported, never dispatched.
  case "$has_events" in
    1) target=merge-lane-events.yml ;;
    disabled) echo "hold:events-workflow-disabled ready=$ready"; return 0 ;;
    0)
      if [ "$has_lane" != 1 ]; then
        echo "hold:no-lane-workflow ready=$ready"; return 0
      fi
      if [ "$tier" != lane ]; then
        echo "hold:pool-single-file ready=$ready"; return 0
      fi
      target=merge-lane.yml
      ;;
    *) echo "hold:unreadable"; return 0 ;;
  esac

  if ! _retry_is_number "$inflight" || ! _retry_is_number "$retries"; then
    echo "hold:unreadable"; return 0
  fi
  # A pass is already on its way. Dispatching a second would only evict the
  # pending member of the lane's concurrency group.
  if [ "$inflight" -gt 0 ]; then
    echo "hold:pass-in-flight ready=$ready inflight=$inflight"; return 0
  fi
  if [ "$max_retries" -gt 0 ] && [ "$retries" -ge "$max_retries" ]; then
    echo "hold:retries-exhausted ready=$ready retries=$retries max=$max_retries"; return 0
  fi
  if [ -n "$age" ]; then
    if ! _retry_is_number "$age"; then
      echo "hold:unreadable"; return 0
    fi
    if [ "$age" -lt "$retry_after" ]; then
      echo "hold:recent-pass ready=$ready last-success=${age}s retry-after=${retry_after}s"; return 0
    fi
  fi
  echo "dispatch:$target ready=$ready last-success=${age:-none}${age:+s} retries=$retries"
}

# ---------------------------------------------------------------------------
# The three collectors' parsers. Each reads one API answer on standard input
# and prints a facts fragment; anything it cannot parse is `readable=0`. They
# live here, not in the driver, so the self-test holds them too — a parser that
# quietly counts a draft is a dispatch rule nobody reviewed.
# ---------------------------------------------------------------------------

# lane_retry_pr_facts — from the GraphQL answer for one repository.
#
# READY IS GITHUB'S OWN WORD, NOT A ROLLUP. `mergeStateStatus` is judged
# against the ruleset's required checks, so a pull request whose only red check
# is one nobody requires reads UNSTABLE and counts — which the status rollup
# would call FAILURE (DataRetrival merges with a non-required suite red). An
# UNKNOWN state is not ready this tick; asking is what makes GitHub compute it,
# so the next tick has the answer.
lane_retry_pr_facts() {
  local out
  out=$(jq -r '
    .data.repository as $r
    | if ($r | type) != "object" then "readable=0"
      elif (($r.pullRequests.nodes | type) != "array") then "readable=0"
      else
        ($r.defaultBranchRef.name // "") as $d
        | if $d == "" or ($d | test("[;= ]")) then "readable=0"
          else
            ([ $r.pullRequests.nodes[]
               | select(.isDraft == false)
               | select(.baseRefName == $d)
               | select(.mergeStateStatus | IN("CLEAN", "UNSTABLE", "HAS_HOOKS"))
             ] | length) as $ready
            | "readable=1;default=\($d);open=\($r.pullRequests.totalCount // 0);ready=\($ready)"
          end
      end' 2>/dev/null) || out=""
  printf '%s\n' "${out:-readable=0}"
}

# lane_retry_workflow_facts — from `actions/workflows`.
#
# A workflow GitHub disabled (sixty days without activity, or by hand) cannot
# be dispatched, and it is a different sentence from a file that is not there.
lane_retry_workflow_facts() {
  local out
  out=$(jq -r '
    def st($p):
      ([.workflows[] | select(.path == $p) | .state] | first // "") as $s
      | if $s == "" then "0" elif $s == "active" then "1" else "disabled" end;
    if (.workflows | type) != "array" then "readable=0"
    else "has_events=\(st(".github/workflows/merge-lane-events.yml"));has_lane=\(st(".github/workflows/merge-lane.yml"))"
    end' 2>/dev/null) || out=""
  printf '%s\n' "${out:-readable=0}"
}

# lane_retry_run_facts <now> <actor> <window> <inflight-max> — from an ARRAY of
# workflow runs, both lane files' together.
#
#   <actor>         the login the watchdog dispatches as. Empty counts every
#                   manual dispatch, the reading that retries LESS.
#   <window>        how far back a dispatch still counts against the cap
#   <inflight-max>  past this age a queued run is a corpse, not a pass on its
#                   way: a lane run wedged behind a dark pool would otherwise
#                   hold the retry forever, looking exactly like a busy queue.
lane_retry_run_facts() {
  local now="${1:-}" actor="${2:-}" window="${3:-}" inflight_max="${4:-}" out
  if ! _retry_is_number "$now" || ! _retry_is_number "$window" || ! _retry_is_number "$inflight_max"; then
    echo "readable=0"; return 0
  fi
  out=$(jq -r --argjson now "$now" --arg actor "$actor" \
    --argjson window "$window" --argjson inflight_max "$inflight_max" '
    def ep: (. // "") | (try fromdateiso8601 catch 0);
    def nonneg: if . < 0 then 0 else . end;
    if type != "array" then "readable=0"
    else
      [ .[] | { status, conclusion, event,
                actor: (.actor.login // ""),
                created: (.created_at | ep),
                updated: (.updated_at | ep) } ] as $r
      | ([ $r[] | select(.status != "completed")
                | select(($now - .created) < $inflight_max) ] | length) as $inflight
      | ([ $r[] | select(.status == "completed" and .conclusion == "success") | .updated ] | max) as $last
      | ([ $r[] | select(.event == "workflow_dispatch")
                | select($actor == "" or .actor == $actor)
                | select(($now - .created) < $window) ] | length) as $retries
      | "inflight=\($inflight);last_success_age=\(if $last == null then "" else (($now - $last) | nonneg) end);retries=\($retries)"
    end' 2>/dev/null) || out=""
  printf '%s\n' "${out:-readable=0}"
}
