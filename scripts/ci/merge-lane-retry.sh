#!/usr/bin/env bash
# merge-lane-retry — collect the facts for every lane repository in the fleet
# manifest and act on the rule in `merge-lane-retry-decision.sh` (#1463).
#
# This file is the COLLECTOR and the one POST. It holds no rule: which
# repository is dispatched, through which file, and when not, is decided in the
# decision file, which the self-test holds. What is here is which API answers
# which fact, and what each read costs.
#
# WHAT A TICK COSTS THE MERGE APP
#
# The lane's quota is the installation's REST `core` bucket, shared by every
# repository (docs/merge-lane.md, "The App quota is shared"). This run draws on
# it as little as it can:
#
#   * `rate_limit` is free, and is read first. Under the lane's own floor the
#     run stops there: a pass dispatched now would skip, and nothing else is
#     worth reading.
#   * the pull-request read is ONE GraphQL query per repository, which is
#     charged to the `graphql` bucket — not the one the lanes are short of.
#   * the REST reads (which lane files exist, their recent runs) are made only
#     for a repository that has a ready pull request: three calls, plus one for
#     the dispatch. A fleet with nothing waiting costs zero `core` calls.
#
# Usage: FLEET_OWNER=<account> GH_TOKEN=<app token> merge-lane-retry.sh
#   RETRY_ARMED=true   send the dispatch. Anything else is a DRY RUN, which
#                      prints the same verdicts and posts nothing.
#   RETRY_ACTOR        the login the dispatch is made as (`<app-slug>[bot]`),
#                      so the cap counts this watchdog's dispatches and not a
#                      person's.
#   RETRY_ONLY         one repository name, for reading a single verdict.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/merge-lane-retry-decision.sh"

OWNER="${FLEET_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
MANIFEST="${FLEET_MANIFEST:-$ROOT/fleet/repos.tsv}"
ARMED="${RETRY_ARMED:-false}"
ACTOR="${RETRY_ACTOR:-}"
ONLY="${RETRY_ONLY:-}"

# knob <name> <value> <default> — a numeric setting, or its default with a
# line on stderr. A non-numeric override must not silently remove a bound.
knob() {
  if _retry_is_number "$2"; then printf '%s' "$2"; return 0; fi
  [ -z "$2" ] || echo "merge-lane-retry: $1=\"$2\" is not a whole number; using $3" >&2
  printf '%s' "$3"
}
# The lane's own default floor (merge-lane.sh, QUOTA_FLOOR).
QUOTA_FLOOR=$(knob QUOTA_FLOOR "${QUOTA_FLOOR:-}" 500)
RETRY_AFTER=$(knob RETRY_AFTER "${RETRY_AFTER:-}" "$LANE_RETRY_AFTER_DEFAULT")
MAX_RETRIES=$(knob MAX_RETRIES "${MAX_RETRIES:-}" "$LANE_RETRY_MAX_DEFAULT")
# How far back a dispatch counts against the cap, and how far back runs are read.
RETRY_WINDOW=$(knob RETRY_WINDOW "${RETRY_WINDOW:-}" 21600)
# Past this age a queued lane run is a corpse rather than a pass on its way.
INFLIGHT_MAX=$(knob INFLIGHT_MAX "${INFLIGHT_MAX:-}" 1800)

if [ -z "$OWNER" ]; then
  echo "merge-lane-retry: no account — set FLEET_OWNER" >&2
  exit 2
fi
if [ ! -r "$MANIFEST" ]; then
  echo "merge-lane-retry: cannot read the fleet manifest at $MANIFEST" >&2
  exit 2
fi
for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "merge-lane-retry: $tool is not on PATH" >&2; exit 2; }
done

CORE_CALLS=0
# api <path> — a GET that returns empty rather than dying; every parser reads
# empty as unreadable, and the rule holds on unreadable. `</dev/null` is
# load-bearing: `gh` reads standard input, and inside the manifest loop it
# would eat the rest of the manifest.
#
# The call is counted at each call site, not in here: every caller runs this in
# a command substitution, and a counter bumped in a subshell stays 0.
api() { gh api "$1" </dev/null 2>/dev/null; }

# One query, one repository: the default branch (read, never assumed — three
# repositories in this fleet are not on `main`) and every open pull request's
# draft flag, base and merge state. The first hundred, most recently updated
# first; a repository with more open than that is judged on those.
# shellcheck disable=SC2016  # GraphQL variables, not shell ones
PR_QUERY='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){defaultBranchRef{name} pullRequests(states:OPEN,first:100,orderBy:{field:UPDATED_AT,direction:DESC}){totalCount nodes{number isDraft baseRefName mergeStateStatus}}}}'

mode="DRY RUN"
[ "$ARMED" = true ] && mode="ARMED"
echo "merge-lane-retry: $mode — retry-after=${RETRY_AFTER}s max-retries=$MAX_RETRIES window=${RETRY_WINDOW}s quota-floor=$QUOTA_FLOOR actor=${ACTOR:-<any>}"

remaining=$(gh api rate_limit --jq '.resources.core.remaining' </dev/null 2>/dev/null | tr -d '\r')
echo "merge-lane-retry: merge App quota remaining=${remaining:-unreadable}"
if lane_retry_quota_holds "$remaining" "$QUOTA_FLOOR"; then
  echo "::warning::merge-lane-retry: HELD, not idle — the merge App's shared quota is at $remaining, under the lane's floor of $QUOTA_FLOOR. A pass dispatched now would skip, so nothing was read and nothing was sent; the next tick asks again."
  exit 0
fi

DISPATCHED=0
HELD=0
FAILS=0
NOW=$(date -u +%s)
SINCE=$(date -u -d "@$((NOW - RETRY_WINDOW))" +%Y-%m-%dT%H:%M:%SZ)
SINCE_Q="%3E%3D${SINCE//:/%3A}"

while IFS=$'\t' read -r repo tier _; do
  repo="${repo%$'\r'}"; tier="${tier%$'\r'}"
  case "$repo" in ''|'#'*) continue ;; esac
  [ -n "$ONLY" ] && [ "$repo" != "$ONLY" ] && continue
  # Decided by the rule, on the tier alone, before anything is read: a
  # repository with no lane to retry costs nothing and prints nothing.
  case "$(lane_retry_verdict "tier=$tier")" in skip:tier-*) continue ;; esac

  facts="tier=$tier;retry_after=$RETRY_AFTER;max_retries=$MAX_RETRIES"
  prf=$(gh api graphql -f query="$PR_QUERY" -f owner="$OWNER" -f name="$repo" </dev/null 2>/dev/null | lane_retry_pr_facts)
  facts="$facts;$prf"
  ready=$(_retry_fact "$prf" ready)
  default=$(_retry_fact "$prf" default)

  if _retry_is_number "$ready" && [ "$ready" -gt 0 ]; then
    CORE_CALLS=$((CORE_CALLS + 1))
    wff=$(api "repos/$OWNER/$repo/actions/workflows?per_page=100" | lane_retry_workflow_facts)
    runs=""
    for wf in merge-lane-events.yml merge-lane.yml; do
      key=has_events; [ "$wf" = merge-lane.yml ] && key=has_lane
      [ "$(_retry_fact "$wff" "$key")" = 1 ] || continue
      CORE_CALLS=$((CORE_CALLS + 1))
      page=$(api "repos/$OWNER/$repo/actions/workflows/$wf/runs?per_page=50&created=$SINCE_Q")
      # A failed read must not look like "no runs": that reads as "no recent
      # pass" and dispatches. Mark it, and let the rule hold.
      [ -n "$page" ] || facts="readable=0;$facts"
      runs="$runs$page"$'\n'
    done
    runf=$(printf '%s' "$runs" | jq -s '[.[] | .workflow_runs[]]' 2>/dev/null \
      | lane_retry_run_facts "$NOW" "$ACTOR" "$RETRY_WINDOW" "$INFLIGHT_MAX")
    facts="$facts;$wff;$runf"
    # Either parser's own `readable=0` has to win over the pull-request
    # fragment's `readable=1`, which comes first.
    case ";$wff;$runf;" in *";readable=0;"*) facts="readable=0;$facts" ;; esac
  fi

  verdict=$(lane_retry_verdict "$facts")
  case "$verdict" in
    dispatch:*)
      wf="${verdict#dispatch:}"; wf="${wf%% *}"
      if [ "$ARMED" != true ]; then
        printf '%-22s %s\n' "$repo" "would-$verdict ref=$default (dry run)"
        continue
      fi
      CORE_CALLS=$((CORE_CALLS + 1))
      if err=$(gh api -X POST "repos/$OWNER/$repo/actions/workflows/$wf/dispatches" -f ref="$default" </dev/null 2>&1 >/dev/null); then
        printf '%-22s %s\n' "$repo" "$verdict ref=$default"
        DISPATCHED=$((DISPATCHED + 1))
      else
        printf '%-22s %s\n' "$repo" "fail:dispatch-refused $wf ref=$default"
        FAILS=$((FAILS + 1))
        case "$err" in
          *"Resource not accessible by integration"*)
            # The same answer waits in every other repository. Stop here
            # rather than spend a call per repository to hear it again.
            echo "::error::merge-lane-retry: the merge App may not dispatch a workflow in $repo — its installation does not hold 'Actions: write'. Nothing can be retried until the owner grants it and the installation accepts it (docs/merge-lane.md, \"A lost pass is retried\")."
            break
            ;;
          *) echo "::error::merge-lane-retry: $repo: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300)" ;;
        esac
      fi
      ;;
    skip:*)
      printf '%-22s %s\n' "$repo" "$verdict"
      ;;
    hold:recent-pass*|hold:pass-in-flight*)
      printf '%-22s %s\n' "$repo" "$verdict"
      ;;
    *)
      # Every other hold is a ready pull request nothing will merge until
      # somebody looks: said as a warning, because the run stays green.
      printf '%-22s %s\n' "$repo" "$verdict"
      echo "::warning::merge-lane-retry: $repo — $verdict (docs/merge-lane.md, \"A lost pass is retried\")"
      HELD=$((HELD + 1))
      ;;
  esac
done < "$MANIFEST"

printf '\nmerge-lane-retry: %d dispatched, %d held for a person, %d failed; %d REST call(s) on the merge App quota\n' \
  "$DISPATCHED" "$HELD" "$FAILS" "$CORE_CALLS"
[ "$FAILS" -eq 0 ]
