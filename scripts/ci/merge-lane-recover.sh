#!/usr/bin/env bash
# merge-lane-recover — one more lane pass after a FAILED one, once the merge
# App's quota window has reopened. Run by `merge-lane.yml`'s `recover` job.
#
# WHY. A lane pass that fails strands every pull request that went green during
# it: the next pass starts only on the next CI completion somewhere in the
# repository, or on the consumer's daily backstop. The usual failure is the
# merge App's installation quota, which every lane in the fleet shares.
# Measured on IntegrateIT 2026-10-10: passes 38034257788 and 38034329587 failed
# `API rate limit exceeded for installation ID ...`, and a green pull request
# sat for 824s until an unrelated completion started another pass. The fleet
# watchdog (`merge-lane-retry.yml`) catches the same stall, but on a 15-minute
# timer and only after `retry_after`; this is the same repository, at once.
#
# Two modes:
#
#   read-reset   In the FAILED lane job, with the App token in GH_TOKEN: write
#                `reset=<epoch>` — when the App's core window reopens — to
#                GITHUB_OUTPUT. `rate_limit` is free. Nothing is written when
#                it cannot be read; the dispatch then waits the minimum.
#
#   dispatch     In the `recover` job: wait until APP_RESET (at least
#                RECOVER_MIN_WAIT, at most RECOVER_MAX_WAIT), then dispatch
#                RECOVER_WORKFLOW on the repository's default branch with
#                DISPATCH_TOKEN — the run's own GITHUB_TOKEN, whose budget is
#                the REPOSITORY's, not the App's that just ran out. A dispatch
#                made with GITHUB_TOKEN does start a run (`workflow_dispatch`
#                and `repository_dispatch` are the documented exceptions to
#                "a GITHUB_TOKEN event triggers no workflow").
#
# ONE dispatch, never a loop. The dispatch carries `inputs.recovered=true`, and the
# job does not run when the failed pass was itself dispatched
# (`github.event_name == 'workflow_dispatch'`, or `github.event.inputs.recovered`
# is set) or was started by the completion of a dispatched run
# (`github.event.workflow_run.event == 'workflow_dispatch'`, the shape a
# recover-workflow that is a CI workflow takes). A pass that keeps failing — a
# revoked key — is red on the dispatched run and goes no further. The target
# must therefore declare a `recovered` string input under `workflow_dispatch`;
# GitHub refuses (422) a dispatch with an input the workflow does not declare.
#
# curl, not `gh`, in `dispatch`: the pool images do not ship `gh` and this job
# does not install it.
set -uo pipefail

RECOVER_MIN_WAIT=60
RECOVER_MAX_WAIT=900

die() { echo "merge-lane-recover: $*" >&2; exit 1; }

# The one sleep. A function so the self-test can see it.
recover_sleep() { command sleep "$1"; }

# <reset-epoch-or-empty> <now> — seconds to wait: until the reset, clamped.
recover_wait() {
  local reset="$1" now="$2" w="$RECOVER_MIN_WAIT"
  if [[ "$reset" =~ ^[0-9]+$ ]] && [ "$((reset - now + 5))" -gt "$w" ]; then
    w=$((reset - now + 5))
  fi
  [ "$w" -le "$RECOVER_MAX_WAIT" ] || w="$RECOVER_MAX_WAIT"
  printf '%s' "$w"
}

api() { # <method> <path> [body] — prints the HTTP status; the body goes to $RECOVER_BODY
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -o "$RECOVER_BODY" -w '%{http_code}' -X "$method" --config -
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28')
  [ -z "$body" ] || args+=(-d "$body")
  # The token travels on stdin (`--config -`), never in argv, where `ps` and /proc
  # would show it to every process on the host.
  curl "${args[@]}" "${GITHUB_API_URL:-https://api.github.com}/$path" <<<"header = \"Authorization: Bearer $DISPATCH_TOKEN\""
}

read_reset() {
  local reset
  reset="$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null)" || reset=''
  if [[ "$reset" =~ ^[0-9]+$ ]]; then
    echo "merge-lane-recover: the merge App's quota window reopens at $(date -u -d "@$reset" +%H:%M:%SZ 2>/dev/null || echo "$reset")"
    printf 'reset=%s\n' "$reset" >>"${GITHUB_OUTPUT:-/dev/null}"
  else
    echo "merge-lane-recover: could not read the merge App's quota window; the retry waits ${RECOVER_MIN_WAIT}s"
  fi
}

dispatch() {
  local wf="${RECOVER_WORKFLOW:-}" repo="${GITHUB_REPOSITORY:-}" ref="${DEFAULT_BRANCH:-}" w code
  [ -n "${DISPATCH_TOKEN:-}" ] || die "DISPATCH_TOKEN is empty — the job needs 'permissions: actions: write' and github.token"
  [ -n "$repo" ] || die "GITHUB_REPOSITORY is empty"
  [[ "$wf" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || die "recover-workflow '$wf' is not a workflow file name in .github/workflows"
  RECOVER_BODY="$(mktemp)"
  trap 'rm -f "$RECOVER_BODY"' EXIT

  w="$(recover_wait "${APP_RESET:-}" "$(date -u +%s)")"
  echo "merge-lane-recover: lane pass ${GITHUB_RUN_ID:-?} failed; dispatching $wf once, in ${w}s"
  recover_sleep "$w"

  if [ -z "$ref" ]; then
    code="$(api GET "repos/$repo")"
    [ "$code" = 200 ] || die "could not read the default branch of $repo (HTTP $code)"
    ref="$(tr -d '\n' <"$RECOVER_BODY" | sed -n 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$ref" ] || die "the repository answer named no default branch"
  fi
  # The ref is spliced into a JSON body, so it is held to a branch name's shape.
  [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "default branch '$ref' is not a plain branch name"
  code="$(api POST "repos/$repo/actions/workflows/$wf/dispatches" "{\"ref\":\"$ref\",\"inputs\":{\"recovered\":\"true\"}}")"
  if [ "$code" != 204 ]; then
    die "dispatching $wf on $ref was refused (HTTP $code): $(head -c 300 "$RECOVER_BODY"). A 403 is a caller that did not grant 'actions: write' to the reusable workflow's job; a 404 is a repository with no $wf; a 422 is a $wf that does not declare the 'recovered' workflow_dispatch input (type: string) the recovery marks its pass with."
  fi
  echo "merge-lane-recover: dispatched $wf on $ref"
}

case "${1:-}" in
  read-reset) read_reset ;;
  dispatch) dispatch ;;
  *) die "usage: merge-lane-recover.sh read-reset|dispatch" ;;
esac
