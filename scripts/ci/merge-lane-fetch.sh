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
lane_gh_mutates() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -X | --method | -X?* | --method=* | -f | -F | --field | --raw-field | --field=* | --raw-field=* | --input | --input=*) return 0 ;;
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
# a minute; a primary one reopens at the `reset` the free `rate_limit` read
# reports, which can be most of an hour away. Waiting longer than
# LANE_RETRY_MAX_WAIT, or past the pass budget, holds the lock for nothing:
# the call fails as before, and the workflow's `recover` job dispatches one
# more pass after the window. A refused call was not carried out, so making a
# write again is not making it twice.
#
# Every call — read or write, recorded or live — goes through here: `gh()` in
# merge-lane.sh and `lane_gh_record` below. None of them reads stdin.
LANE_RETRY_MAX_WAIT=90

# <stderr-file> — the seconds to wait before the call is worth making again,
# or a failure when the error is not a rate limit at all.
lane_rate_limit_wait() {
  local err="$1" now reset
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
  now="$(date -u +%s)"
  reset="$(command gh api rate_limit --jq '.resources.core.reset' 2>/dev/null)" || reset=''
  if [[ "$reset" =~ ^[0-9]+$ ]] && [ "$reset" -gt "$now" ]; then
    printf '%s' "$((reset - now + 1))"
  else
    # The core bucket is not what refused it — a limit `rate_limit` does not
    # report. A minute is what GitHub asks for.
    printf 60
  fi
}

# The one sleep the retry makes. A function so the self-test can see it.
lane_retry_sleep() { command sleep "$1"; }

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
  command gh "$@" >"$d/out" 2>"$d/err" || rc=$?
  if [ "$rc" -ne 0 ] && wait="$(lane_rate_limit_wait "$d/err")"; then
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
      command gh "$@" >"$d/out" 2>"$d/err" || rc=$?
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
