#!/usr/bin/env bash
# merge-lane-recover — one more lane pass after a FAILED one, as soon as the
# merge App's quota answers again. Run by `merge-lane.yml`'s `recover` job.
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
# WAIT FOR THE QUOTA TO ANSWER, NOT FOR A CLOCK. The job used to sleep until
# the `core.reset` that `GET /rate_limit` reported, clamped to 900s. That number
# is not the throttle's. Measured on IntegrateIT 2026-10-11: pass 38115253421
# was refused `API rate limit exceeded for installation ID 156351615` at
# 05:35:37 while `/rate_limit` on the same token had said `remaining=3390`
# seconds earlier, and one second later said `remaining=5450 used=0`, resetting
# at 06:35 — a fresh window that was not the one refusing. The recover job
# slept the 900s cap holding the caller's `merge-lane` group, every pass in
# between was evicted, the next pass was refused again at 05:52 and slept
# another 900s, and merges resumed at 06:16: 26-47 minutes added to five green
# pull requests.
#
# So the job PROBES. It mints its own App token, waits RECOVER_MIN_WAIT, then
# makes one real read with it (`GET repos/<repo>`, one call, which also names
# the default branch). An answer means the quota is back: dispatch at once. A
# rate-limit refusal is waited out until the `x-ratelimit-reset` header OF THAT
# REFUSAL, but never more than RECOVER_PROBE_EVERY before asking again, because
# the header can describe a window as wrongly as `/rate_limit` did. The total
# is capped at RECOVER_MAX_WAIT and the dispatch is made then anyway: the
# dispatched pass reports for itself. The caller's group is held for as long as
# the quota is really gone, plus at most one probe interval — and a pass
# started inside that time would only be refused the same way.
#
# Any answer that is not a rate limit — a 401 from a revoked key, a 404 — ends
# the wait too. Waiting would not change it, and the dispatched pass is where
# it is reported.
#
#   dispatch     In the `recover` job. APP_TOKEN is a freshly minted merge-App
#                token, used ONLY to probe. DISPATCH_TOKEN is the run's own
#                GITHUB_TOKEN, whose budget is the REPOSITORY's, not the App's
#                that just ran out; it makes the one write. A dispatch made with
#                GITHUB_TOKEN does start a run (`workflow_dispatch` and
#                `repository_dispatch` are the documented exceptions to "a
#                GITHUB_TOKEN event triggers no workflow").
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
# curl, not `gh`: the pool images do not ship `gh` and this job does not
# install it.
set -uo pipefail

RECOVER_MIN_WAIT=30
RECOVER_PROBE_EVERY=60
RECOVER_MAX_WAIT=900

die() { echo "merge-lane-recover: $*" >&2; exit 1; }

# The one sleep. A function so the self-test can see it.
recover_sleep() { command sleep "$1"; }

# <reset-epoch-or-empty> <now> — seconds until the next probe: until the
# refusal's own reset when that is sooner, else RECOVER_PROBE_EVERY. Never 0.
recover_probe_wait() {
  local reset="$1" now="$2" w="$RECOVER_PROBE_EVERY"
  if [[ "$reset" =~ ^[0-9]+$ ]] && [ "$((reset - now + 1))" -lt "$w" ]; then
    w=$((reset - now + 1))
  fi
  [ "$w" -ge 1 ] || w=1
  printf '%s' "$w"
}

api() { # <token> <method> <path> [body] — prints the HTTP status; body to $RECOVER_BODY, headers to $RECOVER_HEADERS
  local token="$1" method="$2" path="$3" body="${4:-}"
  local -a args=(-sS -o "$RECOVER_BODY" -D "$RECOVER_HEADERS" -w '%{http_code}' -X "$method" --config -
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28')
  [ -z "$body" ] || args+=(-d "$body")
  # The token travels on stdin (`--config -`), never in argv, where `ps` and /proc
  # would show it to every process on the host.
  curl "${args[@]}" "${GITHUB_API_URL:-https://api.github.com}/$path" <<<"header = \"Authorization: Bearer $token\""
}

# <status> — true when the last answer was a rate-limit refusal.
rate_limited() {
  case "$1" in
    429) return 0 ;;
    403) grep -qi 'rate limit' "$RECOVER_BODY" ;;
    *) return 1 ;;
  esac
}

# The `x-ratelimit-reset` of the last answer, or nothing.
header_reset() {
  tr -d '\r' <"$RECOVER_HEADERS" | sed -n 's/^[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Ss][Ee][Tt]:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n 1
}

default_branch_of_body() {
  tr -d '\n' <"$RECOVER_BODY" | sed -n 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

dispatch() {
  local wf="${RECOVER_WORKFLOW:-}" repo="${GITHUB_REPOSITORY:-}" ref="${DEFAULT_BRANCH:-}" w code waited probes=0
  [ -n "${DISPATCH_TOKEN:-}" ] || die "DISPATCH_TOKEN is empty — the job needs 'permissions: actions: write' and github.token"
  [ -n "${APP_TOKEN:-}" ] || die "APP_TOKEN is empty — the recover job mints the merge App token to probe its quota"
  [ -n "$repo" ] || die "GITHUB_REPOSITORY is empty"
  [[ "$wf" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || die "recover-workflow '$wf' is not a workflow file name in .github/workflows"
  RECOVER_BODY="$(mktemp)"
  RECOVER_HEADERS="$(mktemp)"
  trap 'rm -f "$RECOVER_BODY" "$RECOVER_HEADERS"' EXIT

  echo "merge-lane-recover: lane pass ${GITHUB_RUN_ID:-?} failed; probing the merge App's quota in ${RECOVER_MIN_WAIT}s, then every ${RECOVER_PROBE_EVERY}s at most, for up to ${RECOVER_MAX_WAIT}s"
  recover_sleep "$RECOVER_MIN_WAIT"
  waited="$RECOVER_MIN_WAIT"
  while :; do
    probes=$((probes + 1))
    code="$(api "$APP_TOKEN" GET "repos/$repo")"
    if ! rate_limited "$code"; then
      echo "merge-lane-recover: probe $probes answered HTTP $code after ${waited}s — the quota is not what stops a pass now"
      break
    fi
    if [ "$waited" -ge "$RECOVER_MAX_WAIT" ]; then
      echo "merge-lane-recover: still rate limited after ${waited}s and $probes probe(s) — dispatching anyway; the dispatched pass reports for itself"
      break
    fi
    w="$(recover_probe_wait "$(header_reset)" "$(date -u +%s)")"
    [ "$((waited + w))" -le "$RECOVER_MAX_WAIT" ] || w=$((RECOVER_MAX_WAIT - waited))
    echo "merge-lane-recover: probe $probes rate limited (HTTP $code); asking again in ${w}s"
    recover_sleep "$w"
    waited=$((waited + w))
  done

  if [ -z "$ref" ] && [ "$code" = 200 ]; then ref="$(default_branch_of_body)"; fi
  if [ -z "$ref" ]; then
    code="$(api "$DISPATCH_TOKEN" GET "repos/$repo")"
    [ "$code" = 200 ] || die "could not read the default branch of $repo (HTTP $code)"
    ref="$(default_branch_of_body)"
    [ -n "$ref" ] || die "the repository answer named no default branch"
  fi
  # The ref is spliced into a JSON body, so it is held to a branch name's shape.
  [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "default branch '$ref' is not a plain branch name"
  code="$(api "$DISPATCH_TOKEN" POST "repos/$repo/actions/workflows/$wf/dispatches" "{\"ref\":\"$ref\",\"inputs\":{\"recovered\":\"true\"}}")"
  if [ "$code" != 204 ]; then
    die "dispatching $wf on $ref was refused (HTTP $code): $(head -c 300 "$RECOVER_BODY"). A 403 is a caller that did not grant 'actions: write' to the reusable workflow's job; a 404 is a repository with no $wf; a 422 is a $wf that does not declare the 'recovered' workflow_dispatch input (type: string) the recovery marks its pass with."
  fi
  echo "merge-lane-recover: dispatched $wf on $ref"
}

case "${1:-}" in
  dispatch) dispatch ;;
  *) die "usage: merge-lane-recover.sh dispatch" ;;
esac
