#!/usr/bin/env bash
# merge-lane-fetch — reading every open pull request at once, deciding in order.
#
# The lane's walk reads several facts per open pull request, and it used to read
# them one pull request after another. The ranking cannot be cut short — the
# oldest head wins at equal priority, and a stuck head can become a `drop` that
# outranks every merge — so a green pull request waited for every other head's
# reads before the lane knew it had won.
#
# What this file adds is the smallest thing that removes the wait without
# touching a decision: the walk runs TWICE over the same list.
#
#   1. FETCH. A bounded number of background jobs run the walk's own code, each
#      taking the heads it manages to claim. Their output is discarded and they
#      act on nothing; every `gh api` read they make is RECORDED — its
#      arguments, output, error text and exit status — under one directory per
#      pull request.
#   2. DECIDE. The walk runs again in the foreground, in list order, exactly as
#      it always did, and each read is ANSWERED FROM THE RECORDING instead of
#      the network. Every verdict line, queue row and candidate comes from this
#      second walk, so they come out in list order and cannot interleave.
#
# The reads are the same reads because they are the same lines of code. A
# recording that is missing, empty, cut short, or that stops matching what the
# deciding walk asks for is never taken as an answer: that head is read live, in
# its turn, which is the serial walk this replaced. A failed read is recorded as
# a failed read — exit status, body and all — and replays as one.
#
# Nothing here knows what a verdict is. It is sourced by `merge-lane.sh` and
# exercised, without a network, by `merge-lane-fetch.selftest.sh`.
#
# NOT `wait -n`, AND NOT GNU parallel. The lane runs on hosted and on
# self-hosted Linux runners and nothing guarantees either tool there. Jobs claim
# heads with `mkdir`, which is atomic everywhere, so a slow head never holds up
# the others, the cap is simply the number of jobs, and one plain `wait` ends
# the phase.

# How many bytes a counter file holds. The counters are files of dots for the
# reason the lane's own call counter is one: nearly every read happens inside a
# `$(...)` subshell, where a shell variable increment dies.
lane_fetch_count() {
  local s=''
  if [ -e "$1" ]; then s="$(<"$1")"; fi
  printf '%s' "${#s}"
}

# True when a `gh api` call would WRITE. A fetch job never makes one, whatever
# the walk asks for: every mutation belongs to the deciding walk, serially.
#
# `api graphql` is a READ here: its query travels in `-f`/`-F` fields, and the
# lane sends no GraphQL mutation. Any `-X` / `--method` / `--input` still writes.
lane_gh_mutates() {
  local arg graphql=''
  [ "${1:-}" = api ] && [ "${2:-}" = graphql ] && graphql=1
  for arg in "$@"; do
    case "$arg" in
      -X | --method | -X?* | --method=* | --input | --input=*) return 0 ;;
      -f | -F | --field | --raw-field | --field=* | --raw-field=*) [ -n "$graphql" ] || return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# A RATE-LIMITED CALL IS MADE ONCE MORE, WHEN THE WAIT IS SHORT.
#
# The merge App's installation budget is shared by every lane in the fleet, so
# a pass can be refused part-way: `API rate limit exceeded for installation ID
# ...` (HTTP 403), or a secondary limit (403 or 429). Before this, the first
# such refusal ended the read with an error, and a pass that needed it failed;
# every pull request that went green meanwhile then waited for the next
# trigger. Measured on IntegrateIT 2026-10-10: two passes failed on it within a
# minute and a green pull request sat for 824s.
#
# ONE retry, and only when the window reopens soon. A secondary limit asks for
# a minute; a primary one reopens at the `x-ratelimit-reset` the REFUSAL
# ITSELF carried, which can be most of an hour away. Waiting longer than
# LANE_RETRY_MAX_WAIT, or past the pass budget, holds the lock for nothing:
# the call fails as before, and the workflow's `recover` job dispatches one
# more pass after the window. A refused call was not carried out, so making a
# write again is not making it twice.
#
# Every call — read or write, recorded or live — goes through here: `gh()` in
# merge-lane.sh and `lane_gh_record` below. None of them reads stdin.
LANE_RETRY_MAX_WAIT=90

# <stderr-file> <headers-file> [now] — the seconds to wait before the call is
# worth making again, or a failure when the error is not a rate limit at all.
#
# DECIDED FROM THE REFUSAL'S OWN HEADERS, NEVER FROM `GET /rate_limit` (#1548).
# That endpoint was the number that was wrong: on IntegrateIT 2026-10-11 pass
# 38115253421 was refused at 05:35:37 and one second later `rate_limit` said
# `remaining=5450 used=0`, reset 06:35. The refusal's header block names the
# window that refused it. `remaining=0` with a reset ahead is that window, and
# its reset is when the call can succeed. Anything else — some quota left, a
# reset already past, no headers at all — is a limit the window does not
# describe, and a minute is what GitHub asks for.
lane_rate_limit_wait() {
  local err="$1" hdr="${2:-}" now="${3:-}" w remaining reset
  if grep -q 'HTTP 429' "$err"; then
    :
  elif grep -q 'HTTP 403' "$err" && grep -qi 'rate limit' "$err"; then
    :
  else
    return 1
  fi
  if grep -qi 'secondary rate limit' "$err"; then
    printf 60
    return 0
  fi
  [ -n "$now" ] || now="$(date -u +%s)"
  w="$(lane_hdr_window "$hdr")"
  read -r _ remaining _ reset _ <<<"$w"
  if [ "${remaining:-}" = 0 ] && [[ "${reset:-}" =~ ^[0-9]+$ ]] && [ "$reset" -gt "$now" ]; then
    printf '%s' "$((reset - now + 1))"
  else
    printf 60
  fi
}

# The one sleep the retry makes. A function so the self-test can see it.
lane_retry_sleep() { command sleep "$1"; }

# ---------------------------------------------------------------------------
# A FAILED READ SAYS WHY BEFORE IT SAYS "BLIND" (#1425).
#
# "The lane is blind, not idle" is the line for a lane that cannot look: a
# token without access, a base that does not exist. A quota refusal part-way
# through a pass printed the same first line, and an operator reading it went
# looking for a missing permission (entity-platform run 36594989687, a 403
# rate limit). A refusal is transient and has a time it ends; a server error is
# GitHub's, not the lane's. Each is named as itself.
#
# <stderr-file> [quota-file] [now] — prints the cause of a failed read when it
# is a rate limit or a server error, and fails for anything else (the caller
# then says "blind"). The retry time comes from the window the refusal itself
# carried, as `lane_quota_note` wrote it — never from `GET /rate_limit` (#1548).
lane_read_cause() {
  local err="$1" q="${2:-}" now="${3:-}" limit remaining used reset at
  [ -s "$err" ] || return 1
  if grep -q 'HTTP 429' "$err" || grep -q 'RATE_LIMITED' "$err" \
    || { grep -q 'HTTP 403' "$err" && grep -qi 'rate limit' "$err"; }; then
    [ -n "$now" ] || now="$(date -u +%s)"
    if [ -n "$q" ] && [ -s "$q" ] && read -r limit remaining used reset <"$q" \
      && [ "${remaining:-}" = 0 ] && [[ "${reset:-}" =~ ^[0-9]+$ ]] && [ "$reset" -gt "$now" ] \
      && at="$(date -u -d "@$reset" +%H:%M:%SZ 2>/dev/null)"; then
      printf 'rate limited by GitHub (the merge App quota is shared by every lane), retry at %s — not blind; the recover job dispatches a pass after it' "$at"
    else
      printf 'rate limited by GitHub (the merge App quota is shared by every lane), retry in about a minute — not blind; the recover job dispatches a pass after it'
    fi
    return 0
  fi
  if grep -qE 'HTTP 5[0-9][0-9]|server error' "$err"; then
    at="$(grep -oE 'HTTP 5[0-9][0-9]' "$err" | head -1 || true)"
    printf 'GitHub answered with a server error (%s) — the lane is blind for this pass, not idle; the recover job dispatches another' \
      "${at:-an error page, not JSON}"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# THE QUOTA IS READ FROM THE LANE'S OWN ANSWERS, NOT FROM `rate_limit` (#1543).
#
# `GET /rate_limit` was seen reporting `used=0` for the merge App's token while
# real calls on the same token were refused for rate limit (IntegrateIT,
# 2026-10-11, pass 38115253421 — see merge-lane-recover.sh). A guard that asks
# that endpoint whether to keep spending is asking the one number that was
# wrong. Every real answer GitHub gives carries the window that answered it in
# `x-ratelimit-remaining` / `x-ratelimit-reset`, refusals included, and the lane
# already makes those calls: so every `gh api` here runs with `-i`, the header
# block is cut off the output before any caller sees it, and the newest core
# window is written to LANE_QUOTA as `limit remaining used reset`. The guard in
# merge-lane.sh reads that file and nothing else.
#
# A FILE, replaced whole with `mv`, for the reason the call counter is one: the
# calls happen in `$(...)` subshells and in concurrent fetch jobs, and a reader
# must never see half a line. Last answer wins, which is what "most recent"
# means when several are in flight. Empty LANE_QUOTA records nothing.

# <raw> <out> <headers> — splits `gh api -i` output. `gh` prints each page's
# header block as an `HTTP/x.y nnn` line, then `Name: value` lines ending in
# CR LF, then a lone CR LF; the body follows. Every block goes to <headers>
# (so its last block is the newest answer), everything else to <out>. The lone
# line is matched as "\r" OR "": some awk builds (Git Bash's) strip the CR on
# read, and a split that waited for "\r" there swallowed the body as headers.
lane_gh_split() {
  awk -v hdr="$3" '
    inh { if ($0 == "\r" || $0 == "") { inh = 0 } else { print > hdr }; next }
    /^HTTP\/[0-9.]+ [0-9][0-9][0-9]/ { inh = 1; print > hdr; next }
    { print }
  ' "$1" >"$2"
}

# <headers-file> — `limit remaining used reset resource` of the LAST header
# block (the newest answer), any bucket; `?` for a field it did not carry.
# Nothing when that block carries no numeric remaining + reset. A missing or
# empty file is nothing too.
lane_hdr_window() {
  [ -n "${1:-}" ] && [ -s "$1" ] || return 0
  tr -d '\r' <"$1" | awk -F': *' '
    /^HTTP\// { l = ""; r = ""; u = ""; s = ""; res = ""; next }
    { k = tolower($1) }
    k == "x-ratelimit-limit" { l = $2 }
    k == "x-ratelimit-remaining" { r = $2 }
    k == "x-ratelimit-used" { u = $2 }
    k == "x-ratelimit-reset" { s = $2 }
    k == "x-ratelimit-resource" { res = $2 }
    END {
      if (r ~ /^[0-9]+$/ && s ~ /^[0-9]+$/)
        print (l ~ /^[0-9]+$/ ? l : "?") " " r " " (u ~ /^[0-9]+$/ ? u : "?") " " s " " (res == "" ? "?" : res)
    }'
}

# <headers> — writes the LAST block's window to LANE_QUOTA when it is the core
# bucket, and to LANE_QUOTA.graphql when it is the graphql bucket: the lane
# spends both, the open list from graphql (#1541) and everything else from
# core. A block for any other bucket (`search`) is ignored.
lane_quota_note() {
  local w limit remaining used reset res file
  [ -n "${LANE_QUOTA:-}" ] || return 0
  w="$(lane_hdr_window "$1")"
  [ -n "$w" ] || return 0
  read -r limit remaining used reset res <<<"$w"
  case "$res" in
    core | '?') file="$LANE_QUOTA" ;;
    graphql) file="$LANE_QUOTA.graphql" ;;
    *) return 0 ;;
  esac
  printf '%s %s %s %s\n' "$limit" "$remaining" "$used" "$reset" >"$file.$$.$BASHPID" && mv -f "$file.$$.$BASHPID" "$file"
}

# <dir> <gh-args...> — one real call: output to <dir>/out, error text to
# <dir>/err, the status returned. A `gh api` call is made with `-i` and its
# answer's window noted; its output reaches <dir>/out without the headers.
lane_gh_call() {
  local d="$1" rc=0
  shift
  if [ "${1:-}" != api ]; then
    command gh "$@" >"$d/out" 2>"$d/err" || rc=$?
    return "$rc"
  fi
  command gh api -i "${@:2}" >"$d/raw" 2>"$d/err" || rc=$?
  : >"$d/hdr"
  lane_gh_split "$d/raw" "$d/out" "$d/hdr"
  lane_quota_note "$d/hdr"
  return "$rc"
}

# `command gh "$@"`, made once more after a short rate-limit wait. The caller
# receives the output, the error text and the status of the LAST attempt.
#
# READS ONLY. A write is made once: the wait can be up to LANE_RETRY_MAX_WAIT,
# and what the lane decided on (reviews, labels, the base) can change in that
# time, so repeating `PUT pulls/N/merge` after it would merge on a verdict never
# re-checked. A refused write ends the pass; `recover` dispatches another that
# decides again from live state.
lane_gh_retry() {
  local d rc=0 wait
  if ! d="$(mktemp -d "${LANE_TMP:-${TMPDIR:-/tmp}}/retry.XXXXXX" 2>/dev/null)"; then
    command gh "$@"
    return
  fi
  lane_gh_call "$d" "$@" || rc=$?
  if [ "$rc" -ne 0 ] && wait="$(lane_rate_limit_wait "$d/err" "$d/hdr")"; then
    if lane_gh_mutates "$@"; then
      echo "lane: rate limited on a write; a write is never repeated on the old verdict — the pass ends and the recover job decides again from live state" >&2
    elif [ "$wait" -gt "$LANE_RETRY_MAX_WAIT" ]; then
      echo "lane: rate limited; the window reopens in ${wait}s, past the ${LANE_RETRY_MAX_WAIT}s a call may wait — not retried, the recover job dispatches a pass after it" >&2
    elif [ -n "${LANE_STARTED:-}" ] && [ -n "${PASS_BUDGET:-}" ] \
      && [ "$(($(date -u +%s) + wait))" -ge "$((LANE_STARTED + PASS_BUDGET))" ]; then
      echo "lane: rate limited; a ${wait}s wait would outlast the ${PASS_BUDGET}s pass budget — not retried" >&2
    else
      echo "lane: rate limited; making this call once more in ${wait}s" >&2
      lane_retry_sleep "$wait"
      rc=0
      lane_gh_call "$d" "$@" || rc=$?
    fi
  fi
  cat "$d/out"
  cat "$d/err" >&2
  rm -rf "$d"
  return "$rc"
}

# One read, made for real and written down. The caller still receives the
# output, the error text and the exit status, because the walk needs them to
# know which read comes next.
#
# Nothing the lane authenticates with is in any of these files: the token
# reaches `gh` through the environment, never through an argument, and what
# comes back is the API's answer.
lane_gh_record() {
  local n rc=0
  if lane_gh_mutates "$@"; then
    : >"$LANE_RECORD/diverged"
    return 1
  fi
  n="$(lane_fetch_count "$LANE_RECORD/seq")"
  printf '%s\n' "$@" >"$LANE_RECORD/$n.args"
  lane_gh_retry "$@" >"$LANE_RECORD/$n.out" 2>"$LANE_RECORD/$n.err" || rc=$?
  printf '%s' "$rc" >"$LANE_RECORD/$n.rc"
  # Counted last: a job killed part-way through a read leaves a call that was
  # never counted, so the recording reads as cut short rather than as complete.
  printf . >>"$LANE_RECORD/seq"
  cat "$LANE_RECORD/$n.out"
  cat "$LANE_RECORD/$n.err" >&2
  return "$rc"
}

# Whether the NEXT recorded read is there to be served, without consuming it.
lane_gh_has_next() {
  [ ! -e "$LANE_REPLAY/diverged" ] || return 1
  [ -e "$LANE_REPLAY/$(lane_fetch_count "$LANE_REPLAY/replayed").rc" ]
}

# Whether the next recorded read is THIS read. The arguments are compared
# whole: a deciding walk that asks a different question than the fetch did —
# or one more question — gets a live answer from there on, never the recorded
# answer to something else.
lane_gh_can_replay() {
  local m
  [ ! -e "$LANE_REPLAY/diverged" ] || return 1
  m="$(lane_fetch_count "$LANE_REPLAY/replayed")"
  if [ -e "$LANE_REPLAY/$m.rc" ] && [ "$(printf '%s\n' "$@")" = "$(<"$LANE_REPLAY/$m.args")" ]; then
    return 0
  fi
  : >"$LANE_REPLAY/diverged"
  return 1
}

# Serves the read `lane_gh_can_replay` just accepted: same output, same error
# text on the same stream, same exit status.
lane_gh_serve() {
  local m
  m="$(lane_fetch_count "$LANE_REPLAY/replayed")"
  printf . >>"$LANE_REPLAY/replayed"
  cat "$LANE_REPLAY/$m.out"
  cat "$LANE_REPLAY/$m.err" >&2
  return "$(<"$LANE_REPLAY/$m.rc")"
}

# `ready`, or why not: `missing`, `empty`, `incomplete`.
#
# AN UNUSABLE RECORDING IS NOT "NO CHECKS". A zero-byte result, a result with
# no closing line, or one whose call count disagrees with what is on disk means
# a job died or was killed. Each of those is told apart here so the caller can
# say which, and none of them is ever replayed.
lane_fetch_state() {
  local rec="$1" key value calls='' status='' n
  if [ ! -e "$rec/result" ]; then
    echo missing
    return 0
  fi
  if [ ! -s "$rec/result" ]; then
    echo empty
    return 0
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      calls) calls="$value" ;;
      status) status="$value" ;;
    esac
  done <"$rec/result"
  if ! [[ "$calls" =~ ^[0-9]+$ ]] || [ "$status" != complete ] \
    || [ "$calls" != "$(lane_fetch_count "$rec/seq")" ]; then
    echo incomplete
    return 0
  fi
  for ((n = 0; n < calls; n++)); do
    if [ ! -e "$rec/$n.rc" ] || [ ! -e "$rec/$n.out" ] || [ ! -e "$rec/$n.args" ]; then
      echo incomplete
      return 0
    fi
  done
  echo ready
}

# Closes the recording this job is writing, if any. The call count travels IN
# the result, and the result is renamed into place, so a reader sees either a
# whole one or none.
lane_fetch_seal() {
  if [ -n "${LANE_RECORD:-}" ]; then
    printf 'calls=%s\nstatus=complete\n' "$(lane_fetch_count "$LANE_RECORD/seq")" >"$LANE_RECORD/result.tmp" \
      && mv "$LANE_RECORD/result.tmp" "$LANE_RECORD/result"
  fi
  LANE_RECORD=''
}

# Takes the head whose recording directory is <dir>, or returns 1 when another
# job already has it. Called once per head, in list order, by every job: the
# previous head's recording is closed first, whoever wins this one.
lane_fetch_claim() {
  lane_fetch_seal
  [ ! -d "$1" ] || return 1
  mkdir "$1" 2>/dev/null || return 1
  LANE_RECORD="$1"
  : >"$LANE_RECORD/seq"
  return 0
}

# Starts <jobs> background jobs, each running `<fn> <job-number>`, and waits for
# all of them.
#
# `set +e` IS SAID OUT LOUD. The walk has always run with `errexit` ignored —
# it is called from the condition of an `if` — and a read that fails there is
# handled by the line that made it. A job must not be the one place where a
# failed read ends the process instead. `pipefail` and `nounset` are inherited
# unchanged. The parent's EXIT trap is dropped for the same reason it is not
# inherited: a job that ran it would delete the directory its siblings write to.
LANE_FETCH_PIDS=()
lane_fetch_spawn() {
  local jobs="$1" fn="$2" w
  LANE_FETCH_PIDS=()
  [ "$jobs" -gt 0 ] || return 0
  for ((w = 0; w < jobs; w++)); do
    (
      set +e
      trap - EXIT
      "$fn" "$w"
    ) &
    LANE_FETCH_PIDS+=("$!")
  done
  wait "${LANE_FETCH_PIDS[@]}" 2>/dev/null || true
  LANE_FETCH_PIDS=()
}

# Ends a process and everything under it. A job's reads run in children of
# their own, so signalling the job alone would leave a `gh` or a `sleep` behind
# it; the children are listed before the parent is signalled, because a dead
# parent's children are no longer findable through it.
lane_kill_tree() {
  local pid="$1" kid kids=''
  if command -v pgrep >/dev/null 2>&1; then kids="$(pgrep -P "$pid" 2>/dev/null || true)"; fi
  kill "$pid" 2>/dev/null || true
  for kid in $kids; do lane_kill_tree "$kid"; done
}

# For the lane's EXIT trap: a run that ends while a fetch is in flight takes
# its jobs with it.
lane_fetch_kill() {
  local pid
  for pid in "${LANE_FETCH_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then lane_kill_tree "$pid"; fi
  done
  LANE_FETCH_PIDS=()
}

# `<heads> <calls>`: how many of the first <total> heads have a usable
# recording, and how many reads those recordings hold — summed from the count
# each result carries, because a count kept in a job's own variables died with
# the job.
lane_fetch_tally() {
  local dir="$1" total="$2" i heads=0 calls=0 key value
  for ((i = 0; i < total; i++)); do
    [ "$(lane_fetch_state "$dir/$i")" = ready ] || continue
    heads=$((heads + 1))
    while IFS='=' read -r key value; do
      if [ "$key" = calls ]; then calls=$((calls + value)); fi
    done <"$dir/$i/result"
  done
  printf '%s %s' "$heads" "$calls"
}

# `<unused> <diverged>`: reads that were made but that no verdict consumed —
# a head past the pass deadline, a recording that was cut short, a replay that
# stopped matching — and how many heads stopped matching. The reads were spent
# against the quota whether or not they were used, so the caller counts them.
lane_fetch_unused() {
  local dir="$1" total="$2" i made used unused=0 diverged=0
  for ((i = 0; i < total; i++)); do
    [ -d "$dir/$i" ] || continue
    made="$(lane_fetch_count "$dir/$i/seq")"
    used="$(lane_fetch_count "$dir/$i/replayed")"
    if [ "$made" -gt "$used" ]; then unused=$((unused + made - used)); fi
    if [ -e "$dir/$i/diverged" ]; then diverged=$((diverged + 1)); fi
  done
  printf '%s %s' "$unused" "$diverged"
}

# ---------------------------------------------------------------------------
# ONE GRAPHQL READ A PAGE ANSWERS THE WHOLE OPEN LIST, CHECKS AND ALL (#1541).
#
# The walk used to pay per open pull request: its check-runs, its check-suites,
# its workflow runs, its commit statuses and its detail, every pass. On a
# repository with ~60 open pull requests that was hundreds of calls a pass from
# the merge App's shared installation quota, and draining it stalled every lane
# in the fleet (#1540). `lane_snapshot` asks GraphQL, once per page of 25, for
# every open pull request on the base with its head, its mergeability and every
# check suite on that head with its check runs, its workflow and its event, and
# writes what it learned as the REST bodies the walk already reads. The walk is
# unchanged: `lane_snap_serve`, in the `gh` wrapper, answers a read from those
# bodies through the read's own `--jq` program, so the projections, the
# authority rules and every verdict are the same lines of code.
#
# Measured on a consumer repository, 2026-10-12, 61 open pull requests: 3
# pages, 13 points of the `graphql` bucket each, and for one head each of the
# four bodies matched the REST read of the same instant (runs by suite and
# name, suites by id and status, runs by workflow and event).
#
# WHAT IS NOT SERVED IS READ LIVE, AS BEFORE.
#   * A head with more than 50 suites, or a suite with more than 100 check
#     runs, is not written: a body cut at a page edge would count a required
#     check that fell off the end ABSENT. That head's reads go to REST, paged.
#   * A head whose newest commit is not the listed head is not written either.
#   * Mergeability is written only when GraphQL has computed it. `UNKNOWN` is
#     what the detail read's wait-and-re-read exists for, and that read asks
#     REST, which is also what starts GitHub computing it.
#   * A read that exists to be FRESH — the mergeability re-read, the pre-merge
#     read — is made with `LANE_SNAP` emptied, so it never meets an answer from
#     the start of the pass.
#
# AN APP GRAPHQL WILL NOT NAME IS READ FROM REST. Under the merge App's
# installation token GraphQL cannot resolve `CheckSuite.app` for a suite owned
# by ANOTHER installation's private App: the page answers HTTP 200 with every
# node, that one field `null`, and an `errors` entry `type: INTERNAL` whose path
# ends in `.app` (measured, diag run 38227488117; REST names the same suite's
# app). The walk keys every check by its app, so a head with any suite whose
# app is `null` gets no `check-runs` and no `check-suites` body: those two reads
# go to REST, which names every app. Its statuses, workflow runs and detail do
# not involve an app and are still served.
#
# THE ERRORS ARRAY IS READ, NEVER GH'S EXIT STATUS. `gh api graphql` exits
# non-zero whenever the answer carries `errors`, and with `--paginate` it stops
# at that page, so the read pages itself and judges each body: a page is taken
# when it holds the whole connection (`pageInfo` and `nodes`) and EVERY error
# names a path ending in a check suite's `app` — the one field whose `null` the
# writer above refuses to use. Any other error, a page with no data, or an
# error with no path is the lane blind, and the pass fails closed. #1552 trusted
# the exit status and blinded every consumer lane on the first private App.
#
# A Bot author's login is `name` in GraphQL and `name[bot]` in REST; the REST
# form is written, because `pin-bump-actor` is configured in it.
# ---------------------------------------------------------------------------
LANE_SNAP=''
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
LANE_SNAP_QUERY='query($owner: String!, $name: String!, $base: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $base, first: 25, after: $endCursor, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number isDraft title headRefOid mergeable
        author { __typename login }
        labels(first: 100) { nodes { name } }
        commits(last: 1) { nodes { commit {
          oid
          status { contexts { context state createdAt } }
          checkSuites(first: 50) {
            pageInfo { hasNextPage }
            nodes {
              databaseId status conclusion createdAt
              app { slug databaseId }
              workflowRun { event workflow { databaseId } }
              checkRuns(first: 100, filterBy: {checkType: LATEST}) {
                pageInfo { hasNextPage }
                nodes { name status conclusion startedAt completedAt }
              }
            }
          }
        } } }
      }
    }
  }
}'

# <url> — the file name a url's body is written under.
lane_snap_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# <nodes-file> <repo> <dir> — the pull request nodes, one JSON object a line,
# turned into the walk's six list fields a pull request (on stdout, in the order
# the REST list read printed them) and the REST bodies (under <dir>, one file a
# url, named as `lane_snap_key` names it).
lane_snap_write() {
  local nodes="$1" repo="$2" dir="$3" key body fields
  fields="$(jq -r '
    (.number | tostring), .headRefOid, (.isDraft | tostring),
    ((.labels.nodes // []) | map(.name) | join(",")),
    ((.title // "") | gsub("[\r\n]"; " ")),
    (if .author == null then "" elif .author.__typename == "Bot" then .author.login + "[bot]" else .author.login end)
  ' "$nodes")" || return 1
  # A jq built for Windows ends its lines CRLF; no body or name may keep the CR.
  [ -z "$fields" ] || printf '%s\n' "${fields//$'\r'/}"
  while IFS= read -r key && IFS= read -r body; do
    key="${key%$'\r'}"
    printf '%s\n' "${body%$'\r'}" >"$dir/$key"
  done < <(jq -r --arg r "$repo" '
    def key: gsub("[^A-Za-z0-9]"; "_");
    def low: if . == null then null else ascii_downcase end;
    . as $pr
    | (if .mergeable == "MERGEABLE" then true elif .mergeable == "CONFLICTING" then false else null end) as $m
    | ((.commits.nodes // [])[0].commit // null) as $c
    | (if $m != null then
        [("repos/\($r)/pulls/\(.number)" | key),
         ({mergeable: $m, state: "open", draft: .isDraft, head: {sha: .headRefOid}, title: .title,
           labels: ((.labels.nodes // []) | map({name}))} | tojson)]
      else empty end),
      ( select($c != null and $c.oid == $pr.headRefOid)
      | select(($c.checkSuites.pageInfo.hasNextPage | not)
               and ([($c.checkSuites.nodes // [])[] | .checkRuns.pageInfo.hasNextPage] | any | not))
      | ($c.checkSuites.nodes // []) as $s
      | $pr.headRefOid as $sha
      | ( ( select([$s[] | .app.slug | type == "string"] | all)
          | [("repos/\($r)/commits/\($sha)/check-runs?per_page=100" | key),
             ({check_runs: [$s[] as $x | ($x.checkRuns.nodes // [])[]
                | {name, status: (.status | low), conclusion: (.conclusion | low),
                   started_at: .startedAt, completed_at: .completedAt,
                   app: {slug: $x.app.slug, id: $x.app.databaseId},
                   check_suite: {id: $x.databaseId}}]} | tojson)],
            [("repos/\($r)/commits/\($sha)/check-suites?per_page=100" | key),
             ({check_suites: [$s[] | {id: .databaseId, status: (.status | low), conclusion: (.conclusion | low),
                created_at: .createdAt, app: {slug: .app.slug, id: .app.databaseId}}]} | tojson)] ),
        [("repos/\($r)/actions/runs?head_sha=\($sha)&per_page=100" | key),
         ({workflow_runs: [$s[] | select(.workflowRun != null)
            | {check_suite_id: .databaseId, workflow_id: .workflowRun.workflow.databaseId, event: .workflowRun.event}]} | tojson)],
        [("repos/\($r)/commits/\($sha)/status?per_page=100" | key),
         ({statuses: [($c.status.contexts // [])[]
            | {context, state: (if .state == "EXPECTED" then "pending" else (.state | low) end),
               created_at: .createdAt, updated_at: .createdAt}]} | tojson)] ) )
    | .[0], .[1]
  ' "$nodes")
}

# <page-file> — succeeds when a GraphQL answer is one the snapshot may use: the
# whole connection is there, and every error (if any) names a path that ends in
# a check suite's `app`. See "AN APP GRAPHQL WILL NOT NAME" above.
lane_snap_page_ok() {
  jq -e '
    (.data.repository.pullRequests.pageInfo | type) == "object"
    and (.data.repository.pullRequests.nodes | type) == "array"
    and ([.data.repository.pullRequests.nodes[] | type == "object"] | all)
    and ((.errors // []) | type) == "array"
    and ([(.errors // [])[]
          | (.path | type) == "array" and (.path | length) > 1
            and .path[-1] == "app" and any(.path[]; . == "checkSuites")]
         | all)
  ' "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# A PAGE GITHUB FAILED TO SERVE IS ASKED AGAIN, IN THE PASS (#1581).
#
# A 502, or GitHub's "Something went wrong" page, on one page of the open list
# ended the pass blind, and `recover` dispatched another a minute later: on
# IntegrateIT 2026-10-12 passes 38308770674 and 38315550015 failed on `HTTP 502
# Bad Gateway` with the quota healthy, and a green pull request waited for the
# next pass. The same page, by the same cursor, is asked again after a short
# wait — it is a read, so asking twice changes nothing.
#
# ONLY A SERVER'S FAILURE. A 4xx is an answer — a refusal, a missing
# permission, a quota — and asking again at once changes none of them: a rate
# limit is already waited out (or not) by `lane_gh_retry`, and the rest end the
# pass as before. A page that IS a usable answer is never re-asked, so the
# tolerated `.app` error, whose message is also "Something went wrong", is not
# retried: only a page `lane_snap_page_ok` refused can reach here.
LANE_SNAP_RETRIES=2
lane_snap_retry_sleep() { sleep "$1"; }

# <page-file> <stderr-file> — succeeds when a refused page is a server's
# failure worth asking again: an HTTP 5xx, an HTML error page where JSON was
# due, or a GraphQL answer with no data whose every error has no path and says
# "Something went wrong" (GitHub's own timeout). Never on a 4xx.
lane_snap_page_transient() {
  local page="$1" err="$2"
  ! grep -qE 'HTTP 4[0-9][0-9]' "$err" || return 1
  grep -qE 'HTTP 5[0-9][0-9]' "$err" && return 0
  head -c 512 "$page" | grep -qiE '<!doctype html|<html' && return 0
  jq -e '
    (.data.repository.pullRequests | type) != "object"
    and ((.errors // []) | length) > 0
    and ([.errors[] | (.path == null) and ((.message // "") | test("Something went wrong"))] | all)
  ' "$page" >/dev/null 2>&1
}

# <dir> — reads the open list into <dir> and prints the six list fields a pull
# request; writes one line to <dir>/summary saying what the read was. One
# `gh api graphql` call a page, counted and header-noted by the `gh` wrapper
# like any other read, paged here by `endCursor` (never `--paginate`, which
# stops at the first page carrying `errors`). Fails, with what the API said on
# stderr, on any page `lane_snap_page_ok` refuses; the caller treats that as a
# blind lane, as it did the REST list.
lane_snapshot() {
  local dir="$1" cursor='' prev='' pages=0 tolerated=0 n more rc tries=0 reasked=0 wait
  local page="$dir/page" err="$dir/page.err"
  : >"$dir/nodes"
  while :; do
    rc=0
    if [ -n "$cursor" ]; then
      gh api graphql -F owner="${R%%/*}" -F name="${R#*/}" -F base="$LANE_BASE" -f endCursor="$cursor" \
        -f query="$LANE_SNAP_QUERY" >"$page" 2>"$err" || rc=$?
    else
      gh api graphql -F owner="${R%%/*}" -F name="${R#*/}" -F base="$LANE_BASE" \
        -f query="$LANE_SNAP_QUERY" >"$page" 2>"$err" || rc=$?
    fi
    pages=$((pages + 1))
    if ! lane_snap_page_ok "$page"; then
      # The same page, by the same cursor, once more after a short wait (#1581).
      if [ "$tries" -lt "$LANE_SNAP_RETRIES" ] && lane_snap_page_transient "$page" "$err"; then
        tries=$((tries + 1)) reasked=$((reasked + 1)) pages=$((pages - 1))
        wait=$((2 + (tries - 1) * 3))
        echo "page $((pages + 1)): $(tr '\n' ' ' <"$err" | cut -c1-120) — a server error; asking again in ${wait}s (retry $tries of $LANE_SNAP_RETRIES)" >&2
        lane_snap_retry_sleep "$wait"
        continue
      fi
      local said
      said="$(jq -rc '[(.errors // [])[] | {type, path, message}] | .[:3]' "$page" 2>/dev/null)" \
        || said="$(head -c 300 "$page")"
      echo "page $pages (gh exit $rc): $(tr '\n' ' ' <"$err" | cut -c1-200) errors: ${said:0:300}" >&2
      [ "$tries" -eq 0 ] || echo "page $pages: a server error on each of $((tries + 1)) attempts — not asked again this pass" >&2
      return 1
    fi
    tries=0
    n="$(jq '(.errors // []) | length' "$page" | tr -d '\r')"
    tolerated=$((tolerated + n))
    jq -c '.data.repository.pullRequests.nodes[]' "$page" | tr -d '\r' >>"$dir/nodes"
    more="$(jq -r '.data.repository.pullRequests.pageInfo | if .hasNextPage == true then (.endCursor // "") else "-" end' "$page" | tr -d '\r')"
    [ "$more" != - ] || break
    if [ -z "$more" ] || [ "$more" = "$prev" ]; then
      echo "page $pages says there is a next page but gives no new cursor ('$more')" >&2
      return 1
    fi
    prev="$more" cursor="$more"
  done
  rm -f "$page" "$err"
  printf 'open list read in %s GraphQL page(s), %s pull request(s); %s check-suite app field(s) GraphQL could not resolve, their heads'"'"' checks read from REST; %s page read(s) asked again after a server error\n' \
    "$pages" "$(wc -l <"$dir/nodes" | tr -d ' ')" "$tolerated" "$reasked" >"$dir/summary"
  lane_snap_write "$dir/nodes" "$R" "$dir"
}

# `gh api [--paginate] <url> [--jq <program>]` answered from the snapshot, or
# return 1 for anything else — another shape, a write, a url not in it. Not
# counted: no call was made. `--jq` is applied the way gh applies it: a string
# raw, anything else as compact JSON.
lane_snap_serve() {
  [ -n "$LANE_SNAP" ] && [ "${1:-}" = api ] || return 1
  shift
  local url='' prog='' file
  while [ $# -gt 0 ]; do
    case "$1" in
      --paginate) shift ;;
      --jq)
        [ $# -ge 2 ] || return 1
        prog="$2"
        shift 2
        ;;
      -*) return 1 ;;
      *)
        [ -z "$url" ] || return 1
        url="$1"
        shift
        ;;
    esac
  done
  [ -n "$url" ] || return 1
  file="$LANE_SNAP/$(lane_snap_key "$url")"
  [ -f "$file" ] || return 1
  [ -n "$prog" ] || {
    cat "$file"
    return 0
  }
  # Whole or not at all: a program that fails on the body falls through to the
  # live read rather than leaving half an answer in the caller's stream. A jq
  # built for Windows ends its lines CRLF; gh does not.
  local out
  out="$(jq -rc "$prog" "$file" 2>/dev/null)" || return 1
  [ -z "$out" ] || printf '%s\n' "${out//$'\r'/}"
}
