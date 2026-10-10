#!/usr/bin/env bash
# Behavioural self-test for the merge lane's fetch phase.
#
# `merge-lane.selftest.sh` pins the WIRING of the fetch phase on the text of the
# driver. This file runs the thing: the record/replay pair, the claim, the jobs
# and the tally out of `merge-lane-fetch.sh`, and then the whole driver against
# a stand-in for the API: once reading serially and once reading concurrently,
# to show the two print the same lines in the same order; a concurrent pass
# whose clock passes the pass budget part-way, against a serial pass on the
# later clock; and three passes over an empty queue for the line that says how
# long the run waited — outside a workflow run, inside one whose times can be
# read, and inside one whose times cannot.
#
# No network, no token, and nothing is written outside one temporary directory.
# The stand-in is a `gh` placed first on PATH, because the code under test calls
# `command gh` and a shell function would never be reached.
#
# EVERY ASSERTION HAS AN ID AND A MUTATION. The cases print `ok <id>` or
# `FAIL <id>`; each mutation below breaks one property in a copy of the file
# under test and must turn exactly the id it names to `FAIL`. An assertion that
# stays `ok` under its own mutation was asserting nothing, and is reported.
#
# Single quotes around `$`-text are patterns and sed programs, on purpose.
# And `say <id> $?` straight after a bare test reports THAT TEST's status, which
# is the whole of what a case is: the condition is the assertion.
# shellcheck disable=SC2016,SC2319

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH="$HERE/merge-lane-fetch.sh"
DRIVER="$HERE/merge-lane.sh"
DECISION="$HERE/merge-lane-decision.sh"

PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

for f in "$FETCH" "$DRIVER" "$DECISION"; do
  [ -f "$f" ] || {
    printf 'FAIL: missing %s — every check below would be vacuous\n' "$f"
    exit 1
  }
done
if ! command -v jq >/dev/null 2>&1; then
  # NOT A SKIP: without jq the stand-in answers nothing and every case would
  # "pass" on two equally empty runs.
  echo 'FAIL: jq is not on PATH, so nothing here can run'
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/fix"

# ---------------------------------------------------------------------------
# The stand-in for `gh`.
#
# `gh api [--paginate] <url> [--jq <program>]` is every read the lane makes. A
# url under `repos/` is answered from a fixture file named after it, through
# the caller's own `--jq` program, so the driver's projections are exercised
# too. A url with no fixture is a 404 the way `gh` reports one: the error BODY
# on stdout, a diagnostic on stderr, a non-zero exit. `<fixture>.<n>` answers
# the n-th read of a url, which is how a pull request whose mergeability is
# `null` on the first read and computed on the second is expressed.
#
# Anything that is not a plain read — a method, a field, a body — is refused
# with a status of its own and written to the log as a WRITE, so a write that
# reached the network from a fetch job cannot hide among the reads.
# ---------------------------------------------------------------------------
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
[ "${1:-}" = api ] || exit 2
shift
url='' prog=''
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) prog="$2"; shift 2 ;;
    --paginate) shift ;;
    # A write is logged and refused. With GH_STUB_RATE_LIMIT_WRITES it is
    # refused the way a drained installation quota refuses it, to show the
    # retry does not repeat it.
    -*)
      printf 'WRITE %s\n' "$*" >>"$GH_STUB_LOG"
      if [ -n "${GH_STUB_RATE_LIMIT_WRITES:-}" ]; then
        printf 'gh: You have exceeded a secondary rate limit. (HTTP 403)\n' >&2
        exit 1
      fi
      exit 97
      ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  rate_limit)
    # The retry asks for the core window's reset alone; everything else asks
    # for the whole line.
    if [ "$prog" = .resources.core.reset ]; then echo "${GH_STUB_RESET:-1}"; else echo '5000 4990 10 1900000000'; fi
    exit 0
    ;;
esac
printf '%s\n' "$url" >>"$GH_STUB_LOG"
# The one read that moves the clock, for the pass that runs out of time: see
# the clock below.
if [ -n "${GH_STUB_TRIP_ON:-}" ] && [ "${url%%\?*}" = "$GH_STUB_TRIP_ON" ]; then : >"$CLOCK_TRIPPED"; fi
case "$url" in
  # Rate-limited on the first call, answered on the second: the three shapes
  # GitHub refuses with.
  limit/* | secondary/* | toomany/*)
    k="retry_$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')"
    printf . >>"$GH_STUB_STATE/$k"
    seen="$(cat "$GH_STUB_STATE/$k")"
    if [ "${#seen}" -ge 2 ]; then printf 'out:%s\n' "$url"; exit 0; fi
    case "$url" in
      limit/*) printf 'gh: API rate limit exceeded for installation ID 1. (HTTP 403)\n' >&2 ;;
      secondary/*) printf 'gh: You have exceeded a secondary rate limit. (HTTP 403)\n' >&2 ;;
      *) printf 'gh: Too Many Requests (HTTP 429)\n' >&2 ;;
    esac
    exit 1
    ;;
  forbidden/*) printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; exit 1 ;;
  stuck/*) printf 'gh: You have exceeded a secondary rate limit. (HTTP 403)\n' >&2; exit 1 ;;
  ok/*) printf 'out:%s\n' "$url"; exit 0 ;;
  fail/*)
    printf '{"message":"boom %s"}\n' "$url"
    printf 'gh: boom (HTTP 500)\n' >&2
    exit 22
    ;;
esac
key="$(printf '%s' "${url%%\?*}" | tr -c 'A-Za-z0-9' '_')"
printf . >>"$GH_STUB_STATE/$key"
seen="$(cat "$GH_STUB_STATE/$key")"
file="$GH_STUB_FIXTURES/$key.${#seen}"
[ -e "$file" ] || file="$GH_STUB_FIXTURES/$key"
if [ ! -e "$file" ]; then
  printf '{"message":"Not Found","status":"404"}\n'
  printf 'gh: Not Found (HTTP 404)\n' >&2
  exit 1
fi
# `tr`: a jq built for Windows ends its lines with a carriage return, and this
# file is run on a developer's machine as well as on a runner.
if [ -n "$prog" ]; then jq -rc "$prog" "$file" | tr -d '\r'; else cat "$file"; fi
STUB
chmod +x "$WORK/bin/gh"

# A clock that does not move, for the end-to-end runs only. The lane prints
# ages and durations, and two runs a minute apart would differ in those and in
# nothing else. A call that names its own instant (`-d`) is the real `date`.
#
# It moves ONCE, and only when a case asks: from the moment the file named by
# `CLOCK_TRIPPED` exists, every reading is a thousand seconds later — past the
# default pass budget in one step. The stand-in for `gh` creates that file on
# the read a case names, so a pass runs out of time at a known read rather than
# after a sleep somebody tuned to one machine.
mkdir "$WORK/clock"
REAL_DATE="$(command -v date)"
export REAL_DATE
cat >"$WORK/clock/date" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in -d | -d?* | --date | --date=*) exec "$REAL_DATE" "$@" ;; esac
done
at=1767400000
if [ -n "${CLOCK_TRIPPED:-}" ] && [ -e "$CLOCK_TRIPPED" ]; then at=$((at + 1000)); fi
exec "$REAL_DATE" -d "@$at" "$@"
STUB
chmod +x "$WORK/clock/date"
export GH_STUB_LOG="$WORK/gh.log" GH_STUB_STATE="$WORK/state" GH_STUB_FIXTURES="$WORK/fix"
mkdir "$GH_STUB_STATE"
: >"$GH_STUB_LOG"
PATH="$WORK/bin:$PATH"

# How many lines the stand-in's log holds: one per call that reached it.
stub_calls() { wc -l <"$GH_STUB_LOG" | tr -d '[:space:]'; }

# Waits, bounded, for a path to exist. A case that needs two things to be in
# flight together says so with a file, never with a guess at how long a fork
# takes on this machine.
await() { # <path> [tenths-of-a-second]
  local n=0 max="${2:-100}"
  until [ -e "$1" ]; do
    n=$((n + 1))
    [ "$n" -le "$max" ] || return 1
    command sleep 0.1
  done
}

say() { # <id> <status>
  if [ "$2" -eq 0 ]; then echo "ok $1"; else echo "FAIL $1"; fi
}

# ---------------------------------------------------------------------------
# The cases. Each group runs in a subshell that sources the file under test, so
# a mutated copy can be put through exactly the same cases.
# ---------------------------------------------------------------------------

# Record, seal, replay — and every way a recording can be unusable.
cases_core() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/core.XXXXXX")"
    LANE_RECORD='' LANE_REPLAY=''
    : >"$GH_STUB_LOG"

    # A successful read and a FAILED one, recorded.
    lane_fetch_claim "$d/0"
    rec_out_a="$(lane_gh_record api ok/a --jq .x 2>"$d/a.err")"
    rec_rc_a=$?
    rec_out_b="$(lane_gh_record api fail/b 2>"$d/b.err")"
    rec_rc_b=$?
    lane_fetch_seal
    made="$(stub_calls)"

    LANE_REPLAY="$d/0"
    rep_rc_a=99 rep_rc_b=99 rep_out_a='' rep_out_b=''
    if lane_gh_can_replay api ok/a --jq .x; then
      rep_out_a="$(lane_gh_serve 2>"$d/a.rerr")"
      rep_rc_a=$?
      # The serve above ran in a subshell; the counter is a file for that reason.
    fi
    if lane_gh_can_replay api fail/b; then
      rep_out_b="$(lane_gh_serve 2>"$d/b.rerr")"
      rep_rc_b=$?
    fi
    [ "$rec_out_a" = 'out:ok/a' ] && [ "$rep_out_a" = "$rec_out_a" ] \
      && [ "$rec_out_b" = '{"message":"boom fail/b"}' ] && [ "$rep_out_b" = "$rec_out_b" ]
    say replay-stdout $?
    [ -s "$d/b.err" ] && cmp -s "$d/b.err" "$d/b.rerr" && cmp -s "$d/a.err" "$d/a.rerr"
    say replay-stderr $?
    [ "$rec_rc_a" -eq 0 ] && [ "$rep_rc_a" -eq 0 ] && [ "$rec_rc_b" -eq 22 ] && [ "$rep_rc_b" -eq 22 ]
    say replay-status $?
    [ "$made" -eq 2 ] && [ "$(stub_calls)" -eq 2 ]
    say replay-makes-no-call $?
    # One more question than was recorded is never answered from the recording.
    ! lane_gh_can_replay api ok/a --jq .x && [ -e "$d/0/diverged" ]
    say one-more-question-is-live $?

    # A DIFFERENT question, then the right one: live from the mismatch on.
    lane_fetch_claim "$d/1"
    lane_gh_record api ok/a >/dev/null 2>&1
    lane_gh_record api ok/b >/dev/null 2>&1
    lane_fetch_seal
    LANE_REPLAY="$d/1"
    ! lane_gh_can_replay api ok/z && [ -e "$d/1/diverged" ]
    say mismatch-diverges $?
    ! lane_gh_can_replay api ok/a && ! lane_gh_has_next
    say diverged-stays-live $?

    # A read whose arguments differ only in how they are split is a different
    # read: the comparison is on the whole argument list.
    lane_fetch_claim "$d/2"
    lane_gh_record api ok/a --jq '.x, .y' >/dev/null 2>&1
    lane_fetch_seal
    LANE_REPLAY="$d/2"
    # shellcheck disable=SC2251 # the status IS read, by `say` on the next line
    ! lane_gh_can_replay api ok/a --jq '.x,' '.y'
    say arguments-compared-whole $?

    # The four states.
    [ "$(lane_fetch_state "$d/none")" = missing ]
    say state-missing $?
    lane_fetch_claim "$d/3"
    lane_gh_record api ok/a >/dev/null 2>&1
    held="$LANE_RECORD"
    LANE_RECORD=''
    [ "$(lane_fetch_state "$held")" = missing ]
    say state-unsealed-is-missing $?
    : >"$held/result"
    [ "$(lane_fetch_state "$held")" = empty ]
    say state-empty $?
    printf 'calls=1\n' >"$held/result"
    [ "$(lane_fetch_state "$held")" = incomplete ]
    say state-no-closing-line $?
    # Every file of a second read is there, and the count of reads actually
    # finished still says one: the count is what is believed.
    printf 'calls=2\nstatus=complete\n' >"$held/result"
    : >"$held/1.rc"
    : >"$held/1.out"
    : >"$held/1.args"
    [ "$(lane_fetch_state "$held")" = incomplete ]
    say state-count-disagrees $?
    rm -f "$held/1.rc" "$held/1.out" "$held/1.args"
    printf 'calls=1\nstatus=complete\n' >"$held/result"
    [ "$(lane_fetch_state "$held")" = ready ]
    say state-ready $?
    rm -f "$held/0.rc"
    [ "$(lane_fetch_state "$held")" = incomplete ]
    say state-read-missing $?

    # A WRITE is never made by a fetch job, never recorded, never replayed.
    : >"$GH_STUB_LOG"
    # A head whose walk asked for one is marked, so the deciding walk reads the
    # whole head live rather than replaying up to a write it must make itself.
    lane_fetch_claim "$d/4"
    lane_gh_record api ok/a >/dev/null 2>&1
    w1=0 w2=0 w3=0
    lane_gh_record api -X PUT repos/o/r/pulls/1/merge >/dev/null 2>&1 || w1=$?
    lane_gh_record api repos/o/r/issues/1/comments -f body=x >/dev/null 2>&1 || w2=$?
    lane_gh_record api --method=PATCH repos/o/r/issues/1 >/dev/null 2>&1 || w3=$?
    [ "$w1" -ne 0 ] && [ "$w2" -ne 0 ] && [ "$w3" -ne 0 ] && [ "$(stub_calls)" -eq 1 ]
    say write-never-reaches-the-network $?
    [ ! -e "$d/4/1.args" ] && [ "$(lane_fetch_count "$d/4/seq")" -eq 1 ]
    say write-never-recorded $?
    lane_fetch_seal
    LANE_REPLAY="$d/4"
    [ "$(lane_fetch_state "$d/4")" = ready ] && ! lane_gh_has_next && ! lane_gh_can_replay api ok/a
    say write-never-replayed $?
    LANE_REPLAY=''

    # One head, one job; and claiming the next head closes the previous one.
    lane_fetch_claim "$d/5"
    first=$?
    lane_gh_record api ok/a >/dev/null 2>&1
    again=0
    # As another job would: with no recording of its own open.
    (
      LANE_RECORD=''
      lane_fetch_claim "$d/5"
    ) || again=$?
    [ "$first" -eq 0 ] && [ "$again" -ne 0 ]
    say claim-is-exclusive $?
    lane_fetch_claim "$d/6"
    [ "$(lane_fetch_state "$d/5")" = ready ]
    say claim-seals-the-previous $?
    lane_fetch_seal

    # The tally sums what each result carries, and only usable ones.
    t="$d/tally"
    mkdir "$t"
    lane_fetch_claim "$t/0"
    lane_gh_record api ok/a >/dev/null 2>&1
    lane_gh_record api ok/b >/dev/null 2>&1
    lane_fetch_claim "$t/1"
    lane_fetch_claim "$t/2"
    lane_gh_record api ok/c >/dev/null 2>&1
    lane_gh_record api ok/d >/dev/null 2>&1
    lane_gh_record api ok/e >/dev/null 2>&1
    lane_fetch_claim "$t/3"
    lane_gh_record api ok/f >/dev/null 2>&1
    LANE_RECORD=''
    # The fourth has a result, and it claims reads the disk does not hold.
    printf 'calls=9\nstatus=complete\n' >"$t/3/result"
    [ "$(lane_fetch_tally "$t" 4)" = '3 5' ]
    say tally-sums-usable-results $?
    LANE_REPLAY="$t/0"
    lane_gh_can_replay api ok/a && lane_gh_serve >/dev/null 2>&1
    LANE_REPLAY="$t/2"
    lane_gh_can_replay api ok/zzz
    LANE_REPLAY=''
    [ "$(lane_fetch_unused "$t" 4)" = '5 1' ]
    say unused-reads-and-divergence-counted $?
  )
}

# Jobs: the cap, the order, a death.
cases_spawn() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/spawn.XXXXXX")"
    # Read by the sourced file's functions, which shellcheck does not follow.
    # shellcheck disable=SC2034
    LANE_RECORD='' LANE_REPLAY=''
    mkdir "$d/rec" "$d/flight" "$d/peak"
    total=7 jobs=3

    # Each job walks every head and reads the ones it claims. A read marks
    # itself in flight, notes how many are, and — for the first head only —
    # stays in flight until a LATER head has finished, so the first head is
    # never the first to complete, however the scheduler behaves.
    #
    # Called by name, from `lane_fetch_spawn`, so it is not unreachable.
    # shellcheck disable=SC2317
    job() {
      local i n
      : >"$d/started.$1"
      for ((i = 0; i < total; i++)); do
        lane_fetch_claim "$d/rec/$i" || continue
        echo "$i" >>"$d/claims.$1"
        : >"$d/flight/$i"
        n="$(find "$d/flight" -type f | wc -l | tr -d '[:space:]')"
        : >"$d/peak/$n.$i"
        if [ "$i" -eq 0 ]; then await "$d/done.later" 50; fi
        if [ "$i" -eq 5 ]; then
          # A job that dies holding a head: its read is made, never sealed.
          lane_gh_record api ok/dead >/dev/null 2>&1
          rm -f "$d/flight/$i"
          kill -9 "$BASHPID"
        fi
        lane_gh_record api "ok/$i" >/dev/null 2>&1
        lane_gh_record api "ok/$i/again" >/dev/null 2>&1
        echo "$i" >>"$d/order"
        rm -f "$d/flight/$i"
        if [ "$i" -gt 0 ]; then : >"$d/done.later"; fi
      done
      lane_fetch_seal
    }
    lane_fetch_spawn "$jobs" job
    spawn_rc=$?
    left="${#LANE_FETCH_PIDS[@]}"
    # Only a broken copy leaves anything running here; it is not left behind.
    wait 2>/dev/null

    peak="$(find "$d/peak" -type f | sed 's|.*/||; s|\..*||' | sort -n | tail -1)"
    [ "${peak:-0}" -le "$jobs" ] && [ "$(find "$d" -maxdepth 1 -name 'started.*' | wc -l | tr -d '[:space:]')" -eq "$jobs" ]
    say cap-is-respected $?
    [ "${peak:-0}" -gt 1 ]
    say more-than-one-in-flight $?
    [ "$(cat "$d"/claims.* | sort -n | tr '\n' ' ')" = '0 1 2 3 4 5 6 ' ]
    say every-head-claimed-once $?
    [ "$(head -1 "$d/order")" != 0 ] && [ "$(grep -cx 0 "$d/order")" -eq 1 ] \
      && [ "$(lane_fetch_state "$d/rec/0")" = ready ]
    say out-of-order-completion $?
    [ "$spawn_rc" -eq 0 ] && [ "$(lane_fetch_state "$d/rec/5")" = missing ] \
      && [ "$(lane_fetch_count "$d/rec/5/seq")" -eq 1 ]
    say dead-job-leaves-no-usable-recording $?
    # Six usable heads of seven, two reads each — the dead job's read is not in
    # the sum, because its recording was never closed.
    [ "$(lane_fetch_tally "$d/rec" "$total")" = '6 12' ]
    say calls-summed-across-jobs $?
    [ "$left" -eq 0 ]
    say nothing-left-to-kill-after-the-wait $?
  )
}

# The EXIT path: a run that ends mid-fetch takes its jobs with it.
cases_kill() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/kill.XXXXXX")"

    command sleep 60 &
    LANE_FETCH_PIDS=("$!")
    one="$!"
    lane_fetch_kill
    n=0
    while kill -0 "$one" 2>/dev/null && [ "$n" -lt 30 ]; do
      n=$((n + 1))
      command sleep 0.1
    done
    ! kill -0 "$one" 2>/dev/null && [ "${#LANE_FETCH_PIDS[@]}" -eq 0 ]
    rc=$?
    kill -9 "$one" 2>/dev/null
    wait "$one" 2>/dev/null
    say exit-kills-the-jobs "$rc"

    if ! command -v pgrep >/dev/null 2>&1; then
      # Said, not passed: without `pgrep` a job's children cannot be listed,
      # and this machine cannot show that they are.
      echo 'skip kill-reaches-the-children'
      exit 0
    fi
    (
      command sleep 60 &
      echo "$!" >"$d/child"
      wait
    ) &
    parent="$!"
    await "$d/child" 50
    child="$(cat "$d/child")"
    lane_kill_tree "$parent"
    wait "$parent" 2>/dev/null
    n=0
    while kill -0 "$child" 2>/dev/null && [ "$n" -lt 30 ]; do
      n=$((n + 1))
      command sleep 0.1
    done
    ! kill -0 "$parent" 2>/dev/null && ! kill -0 "$child" 2>/dev/null
    rc=$?
    kill -9 "$child" 2>/dev/null
    say kill-reaches-the-children "$rc"
  )
}

# What a job takes from the shell that started it (#1510). The lane runs under
# `errexit` and holds an EXIT trap that deletes its temporary directory; a job
# must have neither.
cases_shell() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/shell.XXXXXX")"
    # Read by the sourced file's functions, which shellcheck does not follow.
    # shellcheck disable=SC2034
    LANE_RECORD='' LANE_REPLAY=''
    # THIS FILE'S OWN EXIT TRAP DELETES ITS WORKING DIRECTORY, and `trap -p` in
    # a subshell still prints it. Under the second mutation below a job re-arms
    # whatever `trap -p` prints, so without a trap of this group's own every
    # job of the first case would delete the directory every later group runs
    # in — which is the damage the line under test exists to prevent, and it
    # was observed here before this line was written.
    trap : EXIT

    # A command that fails in the middle of a job, in a shell where `errexit`
    # is ON and is not being ignored: the subshell below is a plain command,
    # not the condition of anything. The job must reach the line after it.
    #
    # Called by name, from `lane_fetch_spawn`, so it is not unreachable.
    # shellcheck disable=SC2317
    failing_job() {
      false
      : >"$d/after-failure.$1"
    }
    (
      set -e
      lane_fetch_spawn 2 failing_job
    )
    [ -e "$d/after-failure.0" ] && [ -e "$d/after-failure.1" ]
    say a-failed-command-does-not-end-a-job $?

    # The parent's EXIT trap runs once, when the PARENT exits — not once per
    # job as each one ends. Counted after the jobs have finished and again
    # after the parent has.
    #
    # WHAT THE MUTATION IS. bash already resets traps in a subshell, so deleting
    # the job's `trap - EXIT` changes nothing and would prove nothing. The
    # mutation re-arms the parent's trap inside the job instead, which is what
    # that line is there to make impossible.
    # shellcheck disable=SC2317
    quiet_job() { : >"$d/quiet.$1"; }
    (
      trap 'printf . >>"$d/trap-ran"' EXIT
      lane_fetch_spawn 2 quiet_job
      lane_fetch_count "$d/trap-ran" >"$d/trap-ran-while-running"
    )
    [ -e "$d/quiet.0" ] && [ -e "$d/quiet.1" ] && [ "$(<"$d/trap-ran-while-running")" = 0 ] \
      && [ "$(lane_fetch_count "$d/trap-ran")" -eq 1 ]
    say a-job-does-not-run-the-exit-trap $?
  )
}

# ---------------------------------------------------------------------------
# End to end: the driver itself, serial and concurrent, over one mixed queue.
# ---------------------------------------------------------------------------
REPO='example/repo'
sha_of() { printf '%08d%032d' "$1" 0; }
fx() { # <url-without-query> <json> [n-th-read]
  local key
  key="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
  printf '%s\n' "$2" >"${FX_DIR:-$WORK/fix}/$key${3:+.$3}"
}
fx_checks() { # <sha> <status> <conclusion-json>
  fx "repos/$REPO/commits/$1/check-runs" \
    "{\"check_runs\":[{\"name\":\"build\",\"status\":\"$2\",\"conclusion\":$3,\"completed_at\":\"2026-01-02T00:00:00Z\",\"started_at\":\"2026-01-02T00:00:00Z\",\"app\":{\"slug\":\"ci\"},\"check_suite\":{\"id\":7}}]}"
  fx "repos/$REPO/commits/$1/check-suites" \
    "{\"check_suites\":[{\"id\":7,\"app\":{\"slug\":\"ci\"},\"status\":\"$2\",\"created_at\":\"2026-01-02T00:00:00Z\"}]}"
  fx "repos/$REPO/commits/$1/status" '{"statuses":[]}'
  fx "repos/$REPO/commits/$1" '{"commit":{"committer":{"date":"2026-01-02T00:00:00Z"}}}'
}
fx_detail() { # <num> <mergeable-json> <labels-json> [n-th-read]
  fx "repos/$REPO/pulls/$1" \
    "{\"mergeable\":$2,\"labels\":$3,\"head\":{\"sha\":\"$(sha_of "${5:-$1}")\"},\"title\":\"change $1\"}" "${4:-}"
}
build_fixtures() {
  local q='[{"name":"queue"}]' list='' n draft labels
  fx "repos/$REPO/commits/main" '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}'
  fx "repos/$REPO/rules/branches/main" '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]'
  fx_checks bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb completed '"success"'
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    draft=false labels="$q"
    case "$n" in
      1 | 12) draft=true ;;
      2) labels='[]' ;;
      10) labels='[{"name":"queue"},{"name":"merge-lane/priority-5"}]' ;;
    esac
    list="$list${list:+,}{\"number\":$n,\"head\":{\"sha\":\"$(sha_of "$n")\"},\"draft\":$draft,\"labels\":$labels,\"title\":\"change $n\",\"user\":{\"login\":\"someone\"}}"
    fx_checks "$(sha_of "$n")" completed '"success"'
    fx_detail "$n" true "$labels"
    fx "repos/$REPO/compare/main...$(sha_of "$n")" '{"behind_by":0}'
  done
  fx "repos/$REPO/pulls" "[$list]"
  # 3, 11: settled red. 7: still running. 14: reports nothing at all.
  fx_checks "$(sha_of 3)" completed '"failure"'
  fx_checks "$(sha_of 11)" completed '"failure"'
  fx_checks "$(sha_of 7)" in_progress null
  fx "repos/$REPO/commits/$(sha_of 14)/check-runs" '{"check_runs":[]}'
  fx "repos/$REPO/commits/$(sha_of 14)/check-suites" '{"check_suites":[]}'
  # 5: mergeability not computed on the first read, behind the base.
  fx_detail 5 null "$q" 1
  fx "repos/$REPO/compare/main...$(sha_of 5)" '{"behind_by":3}'
  # 6: conflicting. 8: the detail read FAILS. 9: the base comparison FAILS.
  fx_detail 6 false "$q"
  rm -f "$WORK/fix/$(printf '%s' "repos/$REPO/pulls/8" | tr -c 'A-Za-z0-9' '_')"
  rm -f "$WORK/fix/$(printf '%s' "repos/$REPO/compare/main...$(sha_of 9)" | tr -c 'A-Za-z0-9' '_')"
  # 13: a commit was pushed between the list read and the detail read.
  fx_detail 13 true "$q" '' 130
  fx_checks "$(sha_of 130)" completed '"success"'
  fx "repos/$REPO/compare/main...$(sha_of 130)" '{"behind_by":0}'
}

# One run of the driver in <scripts-dir>. Its output, the reads that reached
# the stand-in (sorted: order across jobs is not a property), the queue table,
# and whatever it left behind in its temporary directory.
lane_run() { # <scripts-dir> <fetch-concurrency> <tag>
  local out="$WORK/run.$3"
  rm -rf "$out"
  mkdir "$out" "$out/tmp" "$out/state"
  : >"$out/calls"
  : >"$out/summary"
  # The four names Actions sets are pinned, to nothing unless a case sets them:
  # this file runs inside a workflow run too, and the lane would otherwise ask
  # the stand-in about the run that is running the test.
  PATH="$WORK/clock:$PATH" GH_STUB_LOG="$out/calls" GH_STUB_STATE="$out/state" TMPDIR="$out/tmp" \
    GITHUB_RUN_ID="${LANE_TEST_RUN_ID:-}" GITHUB_RUN_ATTEMPT=1 RUNNER_NAME=runner-b GITHUB_EVENT_NAME=workflow_run \
    GH_TOKEN=stand-in GITHUB_REPOSITORY="$REPO" LANE_BASE=main REQUIRED_CHECKS=build \
    REQUIRE_LABEL=queue DRY_RUN=true STATUS_ISSUE='' GITHUB_STEP_SUMMARY="$out/summary" \
    FETCH_CONCURRENCY="$2" bash "$1/merge-lane.sh" >"$out/log" 2>&1
  echo "$?" >"$out/rc"
  sort "$out/calls" >"$out/calls.sorted"
  grep -v '^lane: fetch phase read ' "$out/log" >"$out/log.decided"
}

scripts_copy() { # <tag> -> a directory holding the three scripts the driver needs
  local dir="$WORK/scripts.$1"
  rm -rf "$dir"
  mkdir "$dir"
  cp "$DRIVER" "$DECISION" "$FETCH" "$dir/"
  printf '%s' "$dir"
}

# <serial-run-tag> <concurrent-run-tag>
cases_e2e() {
  local s="$WORK/run.$1" c="$WORK/run.$2" kinds
  [ -s "$s/log.decided" ] && cmp -s "$s/log.decided" "$c/log.decided"
  say e2e-lines-identical-in-order $?
  [ -s "$s/summary" ] && cmp -s "$s/summary" "$c/summary" && [ "$(cat "$s/rc")" = "$(cat "$c/rc")" ]
  say e2e-queue-table-identical $?
  [ "$(grep -c 'the fetch phase and the walk disagreed' "$c/log")" -eq 0 ]
  say e2e-no-disagreement $?
  [ "$(grep -c '^lane: fetch phase read 14 of 14 open pull request(s) in [0-9]*s at concurrency 8, ' "$c/log")" -eq 1 ] \
    && [ "$(grep -c '^lane: fetch phase read ' "$s/log")" -eq 0 ]
  say e2e-every-head-fetched $?
  # The same reads, the same number of times: nothing was read twice, so the
  # speed-up is real and the quota a pass spends did not move.
  [ -s "$s/calls.sorted" ] && cmp -s "$s/calls.sorted" "$c/calls.sorted"
  say e2e-same-reads $?
  [ "$(grep -c '^WRITE ' "$s/calls")" -eq 0 ] && [ "$(grep -c '^WRITE ' "$c/calls")" -eq 0 ]
  say e2e-no-write-in-a-dry-run $?
  [ -z "$(ls -A "$s/tmp")" ] && [ -z "$(ls -A "$c/tmp")" ]
  say e2e-nothing-left-behind $?
  # The queue really is mixed: two equally blind runs would also be identical.
  kinds=0
  for want in '#1 skip:draft' '#2 skip:no-label' '#3 skip:red' '#4 merge:' '#5 update:' '#6 skip:conflict' \
    '#8 wait:detail-unreadable' '#9 wait:base-comparison-unreadable' '#10 merge:' '#13 head moved' '#13 merge:' \
    '#7 drop:' 'dry-run — would take'; do
    if [ "$(grep -cF -- "$want" "$s/log")" -gt 0 ]; then kinds=$((kinds + 1)); else echo "  (serial run has no line with '$want')" >&2; fi
  done
  [ "$kinds" -eq 13 ]
  say e2e-queue-is-mixed $?
}

# ---------------------------------------------------------------------------
# A CONCURRENT PASS THAT RUNS OUT OF TIME (#1510).
#
# Two jobs, and the clock passes the budget on the FIRST read of the sixth
# head. What that leaves is the case the guide describes and nothing ran: heads
# in hand when the budget went, a head each job claimed afterwards and never
# read, and the rest untouched.
#
# HOW MANY HEADS WERE READ IS TAKEN FROM THE RUN, NOT WRITTEN HERE. It is six
# when the other job is still inside an earlier head as the clock moves, and
# seven if it claimed the next one a moment before. Either is the lane behaving
# correctly, so every assertion below is stated for "the N the fetch phase
# says it read" — and the first one bounds N, so none of them can pass on a
# pass that was not cut, or on one that read nothing.
# ---------------------------------------------------------------------------
cut_run() { # <scripts-dir> <tag>
  rm -f "$WORK/clock-cut"
  GH_STUB_TRIP_ON="repos/$REPO/commits/$(sha_of 6)/check-runs" CLOCK_TRIPPED="$WORK/clock-cut" lane_run "$1" 2 "$2"
}

# <reference-run-tag> <cut-run-tag>
cases_cut() {
  local r="$WORK/run.$1" c="$WORK/run.$2" n i late=0 same=1 rows=0 strays=0 took
  n="$(sed -n 's/^lane: fetch phase read \([0-9]*\) of 14 open pull request(s) in .*/\1/p' "$c/log")"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0

  # A job asks the deadline question before each head, so the phase ends with
  # the heads that were in flight and reads nothing after them.
  for ((i = n + 1; i <= 14; i++)); do
    late=$((late + $(grep -cF -- "$(sha_of "$i")" "$c/calls") + $(grep -c -e "/pulls/$i\$" -e "/pulls/$i?" "$c/calls")))
  done
  [ "$n" -ge 6 ] && [ "$n" -lt 14 ] && [ "$late" -eq 0 ]
  say cut-fetch-stops-at-the-deadline $?

  # Every head already read is judged, whatever the clock says, and judged as
  # the serial walk judges it; the warning counts exactly those.
  for ((i = 1; i <= n; i++)); do
    grep "^lane: #$i " "$r/log" >"$WORK/cut.want"
    grep "^lane: #$i " "$c/log" >"$WORK/cut.got"
    if [ ! -s "$WORK/cut.want" ] || ! cmp -s "$WORK/cut.want" "$WORK/cut.got"; then same=0; fi
  done
  [ "$n" -gt 0 ] && [ "$same" -eq 1 ] \
    && [ "$(grep -c "^::warning::lane: pass truncated after 600s — read $n of 14 open pull request(s) on main\. " "$c/log")" -eq 1 ]
  say cut-read-heads-keep-their-verdicts $?

  # Every head nobody read is a row saying so — the ones a job claimed and
  # stopped on included — and none of them is given a verdict line.
  for ((i = n + 1; i <= 14; i++)); do
    rows=$((rows + $(grep -cF -- "| [#$i](https://github.com/$REPO/pull/$i) change $i | \`wait\` | not-read-this-pass |" "$c/summary")))
    strays=$((strays + $(grep -c "^lane: #$i " "$c/log")))
  done
  [ "$n" -lt 14 ] && [ "$rows" -eq $((14 - n)) ] && [ "$(grep -c 'not-read-this-pass' "$c/summary")" -eq "$rows" ] && [ "$strays" -eq 0 ]
  say cut-unread-heads-are-rows $?

  # A deadline alone is NOT a disagreement between the two walks: every
  # recording that was closed is used whole, and the head a job stopped on has
  # no recording to disagree with. The warning is for a killed job or a replay
  # that stopped matching, and a cut pass that printed it would train an
  # operator to ignore it.
  [ "$(grep -c '^::warning::lane: pass truncated ' "$c/log")" -eq 1 ] \
    && [ "$(grep -c 'the fetch phase and the walk disagreed' "$c/log")" -eq 0 ] \
    && [ "$(grep -c ' was not read by the fetch phase ' "$c/log")" -eq 0 ]
  say cut-is-not-a-disagreement $?

  # And the pass still acts on the best head it did read.
  took="$(sed -n 's/^::notice::dry-run — would take .* on #\([0-9]*\)$/\1/p' "$c/log")"
  [[ "$took" =~ ^[0-9]+$ ]] && [ "$took" -ge 1 ] && [ "$took" -le "$n" ]
  say cut-still-acts-on-what-it-read $?
}

# ---------------------------------------------------------------------------
# HOW LONG THE RUN WAITED FOR ITS RUNNER AND THE LOCK (#1510).
#
# Three runs over an empty queue: outside a workflow run, inside one whose
# times can be read, and inside one whose times cannot.
# ---------------------------------------------------------------------------
wait_runs() { # <scripts-dir> <tag-suffix>
  GH_STUB_FIXTURES="$WORK/fix-quiet" lane_run "$1" 8 "quiet$2"
  GH_STUB_FIXTURES="$WORK/fix-quiet" LANE_TEST_RUN_ID=77 lane_run "$1" 8 "waited$2"
  GH_STUB_FIXTURES="$WORK/fix-quiet" LANE_TEST_RUN_ID=78 lane_run "$1" 8 "unreadable$2"
}

# <outside-a-run-tag> <readable-tag> <unreadable-tag>
cases_wait() {
  local q="$WORK/run.$1" w="$WORK/run.$2" u="$WORK/run.$3"
  local counts='s/[0-9]* API call(s) spent/N API call(s) spent/; s/so far: [0-9]*)/so far: N)/'
  # One line, both figures, and the job is the one on THIS runner.
  [ "$(grep -c '^lane: this run waited ' "$w/log")" -eq 1 ] \
    && [ "$(grep -cF -- "lane: this run waited 30s for the 'merge-lane-main' lock and a runner — triggered 2026-01-03T00:26:00Z (workflow_run), on a runner 2026-01-03T00:26:30Z — and then spent 10s on job setup before this line." "$w/log")" -eq 1 ]
  say wait-is-one-line-with-both-figures $?
  [ -s "$q/log" ] && [ "$(grep -c -e '^lane: this run waited ' -e '^lane: could not read how long ' "$q/log")" -eq 0 ] \
    && [ "$(grep -c 'actions/runs' "$q/calls")" -eq 0 ]
  say wait-is-not-asked-outside-a-run $?
  # A wait that cannot be read is one line. The run ends as it would have, and
  # every other line is the same but for the two reads it counted.
  grep -v '^lane: could not read how long ' "$u/log" | sed "$counts" >"$WORK/wait.got"
  sed "$counts" "$q/log" >"$WORK/wait.want"
  [ "$(grep -c "^lane: could not read how long this run waited for its runner and the 'merge-lane-main' lock " "$u/log")" -eq 1 ] \
    && [ "$(cat "$u/rc")" = 0 ] && [ "$(cat "$q/rc")" = 0 ] && [ -s "$WORK/wait.want" ] && cmp -s "$WORK/wait.want" "$WORK/wait.got"
  say wait-unreadable-changes-nothing $?
}

# A rate-limited call is made ONCE more, after the wait GitHub asks for, and
# only when that wait fits under the cap and inside the pass budget. Anything
# else — a refusal that is not a rate limit, a window far off — is the caller's
# answer at once; the `recover` job dispatches a pass after a long window.
# SC2034: the LANE_* globals are read by the sourced fetch file. SC2317: the
# sleep stub is called by lane_gh_retry. SC2181: each case asserts on the exit
# code of a call whose output and stderr it also inspects.
# shellcheck disable=SC2034,SC2317,SC2181
cases_retry() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/retry.XXXXXX")"
    LANE_TMP="$d" LANE_RECORD='' LANE_REPLAY=''
    unset LANE_STARTED PASS_BUDGET GH_STUB_RESET
    # Every mutant runs this group again: each URL must be refused afresh.
    rm -f "$GH_STUB_STATE"/retry_*
    # Not `$d`: the retry has a local `d` of its own, and bash scoping is dynamic.
    slept_file="$d/slept"
    lane_retry_sleep() { echo "$1" >>"$slept_file"; }
    fresh() { rm -f "$d/slept" "$d/err"; : >"$GH_STUB_LOG"; }
    slept() { cat "$d/slept" 2>/dev/null; }
    calls() { grep -cx "$1" "$GH_STUB_LOG"; }
    now="$(date -u +%s)"

    fresh
    out="$(lane_gh_retry api secondary/a 2>"$d/err")"
    [ $? -eq 0 ] && [ "$out" = 'out:secondary/a' ] && [ "$(slept)" = 60 ] && [ "$(calls secondary/a)" -eq 2 ]
    say retry-secondary-once-after-a-minute $?

    fresh
    out="$(lane_gh_retry api toomany/a 2>"$d/err")"
    [ $? -eq 0 ] && [ "$out" = 'out:toomany/a' ] && [ "$(slept)" = 60 ]
    say retry-429 $?

    # The clock is read again here: earlier cases take seconds on a slow shell.
    fresh
    now="$(date -u +%s)"
    out="$(GH_STUB_RESET=$((now + 30)) lane_gh_retry api limit/a 2>"$d/err")"
    rc=$?
    w="$(slept)"
    [ "$rc" -eq 0 ] && [ "$out" = 'out:limit/a' ] && [ "${w:-0}" -ge 25 ] && [ "${w:-0}" -le 31 ]
    say retry-primary-waits-for-the-reset $?

    fresh
    GH_STUB_RESET=$((now + 600)) lane_gh_retry api limit/b >/dev/null 2>"$d/err"
    [ $? -ne 0 ] && [ -z "$(slept)" ] && [ "$(calls limit/b)" -eq 1 ] && grep -q 'not retried' "$d/err"
    say retry-not-past-the-cap $?

    fresh
    lane_gh_retry api forbidden/a >/dev/null 2>"$d/err"
    [ $? -ne 0 ] && [ -z "$(slept)" ] && [ "$(calls forbidden/a)" -eq 1 ] && grep -q 'HTTP 403' "$d/err"
    say retry-only-a-rate-limit $?

    fresh
    (LANE_STARTED="$now" PASS_BUDGET=30 lane_gh_retry api secondary/b >/dev/null 2>"$d/err")
    [ $? -ne 0 ] && [ -z "$(slept)" ] && [ "$(calls secondary/b)" -eq 1 ] && grep -q 'pass budget' "$d/err"
    say retry-within-the-pass-budget $?

    fresh
    lane_gh_retry api stuck/a >/dev/null 2>"$d/err"
    [ $? -ne 0 ] && [ "$(slept)" = 60 ] && [ "$(calls stuck/a)" -eq 2 ]
    say retry-only-once $?

    # A WRITE is never made twice: after the wait the lane's verdict (reviews,
    # labels, the base) may be stale, and a second `PUT pulls/N/merge` would act
    # on it. One attempt, no sleep, the refusal handed back.
    fresh
    GH_STUB_RATE_LIMIT_WRITES=1 lane_gh_retry api -X PUT repos/o/r/pulls/1/merge >/dev/null 2>"$d/err"
    [ $? -ne 0 ] && [ -z "$(slept)" ] && [ "$(grep -c '^WRITE ' "$GH_STUB_LOG")" -eq 1 ] \
      && [ "$(grep -c 'a write is never repeated' "$d/err")" -eq 1 ]
    say retry-never-repeats-a-write $?

    # The recording holds the answer the retry got, so a replaying job sees the
    # read succeed exactly as the recording job did.
    fresh
    lane_fetch_claim "$d/r"
    out="$(lane_gh_record api secondary/c 2>/dev/null)"
    rc=$?
    lane_fetch_seal
    [ "$rc" -eq 0 ] && [ "$out" = 'out:secondary/c' ] && [ "$(cat "$d/r/0.rc")" = 0 ] \
      && [ "$(cat "$d/r/0.out")" = 'out:secondary/c' ]
    say retry-recorded-as-answered $?
  )
}

# ---------------------------------------------------------------------------
# Running them.
# ---------------------------------------------------------------------------
tally_lines() { # <output> <how-many-expected> <group>
  local line n=0
  while IFS= read -r line; do
    case "$line" in
      'ok '*) ok; n=$((n + 1)) ;;
      'skip '*) SKIP=$((SKIP + 1)); n=$((n + 1)); printf 'SKIPPED: %s — it cannot be shown on this machine\n' "${line#skip }" ;;
      'FAIL '*) bad "$3: ${line#FAIL }"; n=$((n + 1)) ;;
    esac
  done <<<"$1"
  # A group that printed fewer lines than it has assertions died part-way, and
  # the assertions it never reached must not be counted as passing.
  [ "$n" -eq "$2" ] || bad "$3: $n result(s), expected $2 — the group did not run to its end"
}

# <description> <group-function> <file> <sed-program> <id>
mutant() {
  local desc="$1" group="$2" file="$3" prog="$4" id="$5" tmp out
  tmp="$(mktemp "$WORK/mutant.XXXXXX")"
  if ! sed "$prog" "$file" >"$tmp" 2>/dev/null; then
    bad "the mutation program is not valid sed, so it asserts nothing: $desc"
    return
  fi
  if cmp -s "$tmp" "$file"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    return
  fi
  out="$("$group" "$tmp" 2>/dev/null)"
  if [ "$(printf '%s\n' "$out" | grep -cxF -- "FAIL $id")" -eq 1 ]; then
    ok
  elif [ "$(printf '%s\n' "$out" | grep -cxF -- "skip $id")" -eq 1 ]; then
    SKIP=$((SKIP + 1))
  else
    bad "mutation not detected by '$id': $desc"
  fi
}

# `e2e` as the only argument runs the end-to-end half alone, for iterating on
# the driver; CI runs the file with no argument, which is everything.
if [ "${1:-}" != e2e ]; then
tally_lines "$(cases_core "$FETCH" 2>&1)" 22 core
tally_lines "$(cases_spawn "$FETCH" 2>&1)" 7 spawn
tally_lines "$(cases_kill "$FETCH" 2>&1)" 2 kill
tally_lines "$(cases_shell "$FETCH" 2>&1)" 2 shell
tally_lines "$(cases_retry "$FETCH" 2>&1)" 9 retry

mutant "a call waits however long the window is" cases_retry "$FETCH" \
  's|^LANE_RETRY_MAX_WAIT=90$|LANE_RETRY_MAX_WAIT=99999|' retry-not-past-the-cap
mutant "a secondary limit is retried at once" cases_retry "$FETCH" \
  '/secondary rate limit/,/return 0/s|printf 60|printf 0|' retry-secondary-once-after-a-minute
mutant "a primary limit ignores the reset" cases_retry "$FETCH" \
  's|^    printf .%s. "\$((reset - now + 1))"$|    printf 60|' retry-primary-waits-for-the-reset
mutant "every 403 is retried" cases_retry "$FETCH" \
  "s|grep -q 'HTTP 403' \"\\\$err\" && grep -qi 'rate limit' \"\\\$err\"|grep -q 'HTTP 403' \"\$err\"|" retry-only-a-rate-limit
mutant "a 429 is not retried" cases_retry "$FETCH" \
  "s|if grep -q 'HTTP 429' \"\\\$err\"; then|if false; then|" retry-429
mutant "a retry may outlast the pass budget" cases_retry "$FETCH" \
  's|^    elif \[ -n "\${LANE_STARTED:-}" \] && \[ -n "\${PASS_BUDGET:-}" \] \\$|    elif false \\|' retry-within-the-pass-budget
mutant "a retried call is made twice more" cases_retry "$FETCH" \
  's|^      rc=0$|      rc=0; command gh "$@" >/dev/null 2>\&1|' retry-only-once
mutant "a refused write is made once more after the wait" cases_retry "$FETCH" \
  's|^    if lane_gh_mutates "\$@"; then$|    if false; then|' retry-never-repeats-a-write
mutant "the recording bypasses the retry" cases_retry "$FETCH" \
  's|^  lane_gh_retry "\$@" >"\$LANE_RECORD/\$n\.out"|  command gh "$@" >"$LANE_RECORD/$n.out"|' retry-recorded-as-answered

mutant "a replayed read loses its output" cases_core "$FETCH" \
  's|^  cat "\$LANE_REPLAY/\$m\.out"$|  :|' replay-stdout
mutant "a replayed read loses its error text" cases_core "$FETCH" \
  's|^  cat "\$LANE_REPLAY/\$m\.err" >&2$|  :|' replay-stderr
mutant "a failed read replays as a successful one" cases_core "$FETCH" \
  's|^  return "\$(<"\$LANE_REPLAY/\$m\.rc")"$|  return 0|' replay-status
mutant "a replay goes to the network as well" cases_core "$FETCH" \
  's|^  cat "\$LANE_REPLAY/\$m\.out"$|  command gh api ok/extra >/dev/null; cat "$LANE_REPLAY/$m.out"|' replay-makes-no-call
mutant "a question past the end of a recording does not mark it" cases_core "$FETCH" \
  '/^lane_gh_can_replay() {$/,/^}$/s|^  : >"\$LANE_REPLAY/diverged"$|  :|' one-more-question-is-live
mutant "the next recorded read answers whatever is asked" cases_core "$FETCH" \
  's|^  if \[ -e "\$LANE_REPLAY/\$m\.rc" \] && \[ .*$|  if [ -e "$LANE_REPLAY/$m.rc" ]; then|' mismatch-diverges
mutant "a diverged recording is replayed again" cases_core "$FETCH" \
  's|^  \[ ! -e "\$LANE_REPLAY/diverged" \] \|\| return 1$|  :|' diverged-stays-live
mutant "arguments are compared joined, not whole" cases_core "$FETCH" \
  's|^  if \[ -e "\$LANE_REPLAY/\$m\.rc" \] && \[ .*$|  if [ -e "$LANE_REPLAY/$m.rc" ] \&\& [ "$*" = "$(tr "\\n" " " <"$LANE_REPLAY/$m.args" \| sed "s/ $//")" ]; then|' arguments-compared-whole
mutant "a recording with no result reads as ready" cases_core "$FETCH" \
  '/^lane_fetch_state() {$/,/^}$/s|^    echo missing$|    echo ready|' state-missing
mutant "an unsealed recording reads as ready" cases_core "$FETCH" \
  '/^lane_fetch_state() {$/,/^}$/s|^    echo missing$|    echo ready|' state-unsealed-is-missing
mutant "a zero-byte result reads as ready" cases_core "$FETCH" \
  '/^lane_fetch_state() {$/,/^}$/s|^    echo empty$|    echo ready|' state-empty
mutant "a result with no closing line is accepted" cases_core "$FETCH" \
  's/ || \[ "\$status" != complete \] \\$/ \\/' state-no-closing-line
mutant "a result whose count disagrees with the disk is accepted" cases_core "$FETCH" \
  's/^    || \[ "\$calls" != "\$(lane_fetch_count "\$rec\/seq")" \]; then$/    ; then/' state-count-disagrees
mutant "a whole recording reads as incomplete" cases_core "$FETCH" \
  '/^lane_fetch_state() {$/,/^}$/s|^  echo ready$|  echo incomplete|' state-ready
mutant "a recording with a read missing is accepted" cases_core "$FETCH" \
  's|^    if \[ ! -e "\$rec/\$n\.rc" \] .*$|    if false; then|' state-read-missing
mutant "a fetch job makes the write it is asked for" cases_core "$FETCH" \
  's|^  if lane_gh_mutates "\$@"; then$|  if false; then|' write-never-reaches-the-network
mutant "a body field is not recognised as a write" cases_core "$FETCH" \
  's/ | -f | -F | / | /' write-never-reaches-the-network
mutant "a refused write is written down as a read" cases_core "$FETCH" \
  '/^  if lane_gh_mutates "\$@"; then$/a\    printf . >>"$LANE_RECORD/seq"; : >"$LANE_RECORD/1.args"' write-never-recorded
mutant "a head whose walk asked for a write is replayed all the same" cases_core "$FETCH" \
  '/^lane_gh_record() {$/,/^}$/s|^    : >"\$LANE_RECORD/diverged"$|    :|' write-never-replayed
mutant "two jobs can take one head" cases_core "$FETCH" \
  '/^lane_fetch_claim() {$/,/^}$/{s|^  \[ ! -d "\$1" \] \|\| return 1$|  :|;s|^  mkdir "\$1" 2>/dev/null \|\| return 1$|  mkdir -p "$1"|}' claim-is-exclusive
mutant "claiming the next head leaves the previous one open" cases_core "$FETCH" \
  '/^lane_fetch_claim() {$/,/^}$/s|^  lane_fetch_seal$|  :|' claim-seals-the-previous
mutant "the tally counts heads whose recording is unusable" cases_core "$FETCH" \
  '/^lane_fetch_tally() {$/,/^}$/s|^    \[ "\$(lane_fetch_state "\$dir/\$i")" = ready \] \|\| continue$|    [ -e "$dir/$i/result" ] \|\| continue|' tally-sums-usable-results
mutant "reads no verdict used are not counted" cases_core "$FETCH" \
  '/^lane_fetch_unused() {$/,/^}$/s|unused=\$((unused + made - used))|:|' unused-reads-and-divergence-counted

mutant "every job is started with nothing to stop it at the cap" cases_spawn "$FETCH" \
  's|^  for ((w = 0; w < jobs; w++)); do$|  for ((w = 0; w < jobs + 2; w++)); do|' cap-is-respected
mutant "the jobs run one after another" cases_spawn "$FETCH" \
  '/^lane_fetch_spawn() {$/,/^}$/s|^    ) &$|    ) \& wait "$!"|' more-than-one-in-flight
mutant "every job reads every head" cases_spawn "$FETCH" \
  '/^lane_fetch_claim() {$/,/^}$/{s|^  \[ ! -d "\$1" \] \|\| return 1$|  :|;s|^  mkdir "\$1" 2>/dev/null \|\| return 1$|  mkdir -p "$1"|}' every-head-claimed-once
mutant "the jobs run one after another, so the first head cannot finish last" cases_spawn "$FETCH" \
  '/^lane_fetch_spawn() {$/,/^}$/s|^    ) &$|    ) \& wait "$!"|' out-of-order-completion
mutant "a recording nobody closed is taken as whole" cases_spawn "$FETCH" \
  '/^lane_fetch_state() {$/,/^}$/s|^    echo missing$|    echo ready|' dead-job-leaves-no-usable-recording
mutant "the call count is kept in the job's own memory" cases_spawn "$FETCH" \
  '/^lane_fetch_tally() {$/,/^}$/s|calls=\$((calls + value))|calls=$((calls + 1))|' calls-summed-across-jobs
mutant "the phase returns before its jobs have finished" cases_spawn "$FETCH" \
  '/^lane_fetch_spawn() {$/,/^}$/{s|^  wait "\${LANE_FETCH_PIDS\[@\]}" 2>/dev/null \|\| true$|  :|;s|^  LANE_FETCH_PIDS=()$|  :|}' nothing-left-to-kill-after-the-wait

mutant "the EXIT path signals nothing" cases_kill "$FETCH" \
  's|^    if \[ -n "\$pid" \]; then lane_kill_tree "\$pid"; fi$|    :|' exit-kills-the-jobs
mutant "only the job is signalled, and its children are left running" cases_kill "$FETCH" \
  's|^  for kid in \$kids; do lane_kill_tree "\$kid"; done$|  :|' kill-reaches-the-children

mutant "a job inherits errexit, so its first failed command ends it" cases_shell "$FETCH" \
  '/^lane_fetch_spawn() {$/,/^}$/s|^      set +e$|      :|' a-failed-command-does-not-end-a-job
mutant "a job arms the parent's EXIT trap for itself" cases_shell "$FETCH" \
  '/^lane_fetch_spawn() {$/,/^}$/s|^      trap - EXIT$|      eval "$(trap -p EXIT)"|' a-job-does-not-run-the-exit-trap
fi

# --- end to end -------------------------------------------------------------
build_fixtures
real="$(scripts_copy real)"
lane_run "$real" 1 serial
lane_run "$real" 8 concurrent
tally_lines "$(cases_e2e serial concurrent 2>&1)" 8 "end to end"
if [ "$FAIL" -gt 0 ]; then
  echo '--- serial run ---'
  cat "$WORK/run.serial/log"
  echo '--- concurrent run, differing lines ---'
  # `sed -n`, not `head`: it reads its input to the end, so `diff` is never
  # cut off by a closed pipe (the pipefail reader gate, PFR2).
  diff "$WORK/run.serial/log.decided" "$WORK/run.concurrent/log.decided" | sed -n '1,40p'
  diff "$WORK/run.serial/calls.sorted" "$WORK/run.concurrent/calls.sorted" | sed -n '1,20p'
  diff "$WORK/run.serial/summary" "$WORK/run.concurrent/summary" | sed -n '1,20p'
  echo "--- left behind: $(find "$WORK/run.serial/tmp" "$WORK/run.concurrent/tmp" -mindepth 1 | tr '\n' ' ')"
fi

# <description> <script> <sed-program> <id>: the concurrent run of a broken copy
# is compared with the serial run of the real one.
e2e_mutant() {
  local desc="$1" name="$2" prog="$3" id="$4" dir out
  dir="$(scripts_copy mutant)"
  if ! sed "$prog" "$HERE/$name" >"$dir/$name" 2>/dev/null; then
    bad "the mutation program is not valid sed, so it asserts nothing: $desc"
    return
  fi
  if cmp -s "$dir/$name" "$HERE/$name"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    return
  fi
  lane_run "$dir" 8 mutant
  out="$(cases_e2e serial mutant 2>/dev/null)"
  if [ "$(printf '%s\n' "$out" | grep -cxF -- "FAIL $id")" -eq 1 ]; then ok; else bad "mutation not detected by '$id': $desc"; fi
}
e2e_mutant "a replayed read is answered with the previous read's output" merge-lane-fetch.sh \
  's|^  cat "\$LANE_REPLAY/\$m\.out"$|  cat "$LANE_REPLAY/$((m > 0 ? m - 1 : m)).out"|' e2e-lines-identical-in-order
e2e_mutant "a fetch job's lines reach the log" merge-lane.sh \
  's|^  lane_walk >/dev/null 2>&1$|  lane_walk|' e2e-lines-identical-in-order
e2e_mutant "no recording is ever taken, so every head is read twice" merge-lane-fetch.sh \
  '/^lane_gh_can_replay() {$/,/^}$/s|^  local m$|  return 1|' e2e-same-reads
e2e_mutant "every recording stops matching part-way" merge-lane-fetch.sh \
  's|^  if \[ -e "\$LANE_REPLAY/\$m\.rc" \] && \[ |  if [ "$m" -lt 2 ] \&\& [ -e "$LANE_REPLAY/$m.rc" ] \&\& [ |' e2e-no-disagreement
e2e_mutant "the fetch phase never starts" merge-lane.sh \
  's|^  \[ "\$jobs" -gt 1 \] \|\| return 0$|  return 0|' e2e-every-head-fetched
e2e_mutant "the run leaves its temporary directory behind" merge-lane.sh \
  "s|^trap 'lane_fetch_kill; rm -rf \"\\\$LANE_TMP\"' EXIT\$|trap 'lane_fetch_kill' EXIT|" e2e-nothing-left-behind
e2e_mutant "a dry run acts" merge-lane.sh \
  's|^  if \[ "\$DRY_RUN" = "true" \]; then$|  if false; then|' e2e-no-write-in-a-dry-run

# --- a concurrent pass that runs out of time ---------------------------------
# The reference is a serial pass whose clock ALREADY reads the later time, with
# the whole budget ahead of it: the deciding walk of the cut pass runs entirely
# after the clock moved, so that is the serial walk its lines must equal.
: >"$WORK/clock-late"
CLOCK_TRIPPED="$WORK/clock-late" lane_run "$real" 1 late
cut_run "$real" cut
tally_lines "$(cases_cut late cut 2>&1)" 5 "cut pass"
if [ "$FAIL" -gt 0 ]; then
  echo '--- cut run ---'
  cat "$WORK/run.cut/log" "$WORK/run.cut/summary"
  echo '--- reads that reached the stand-in ---'
  cat "$WORK/run.cut/calls.sorted"
fi

# <description> <script> <sed-program> <id>: the cut run of a broken copy.
cut_mutant() {
  local desc="$1" name="$2" prog="$3" id="$4" dir out
  dir="$(scripts_copy mutant)"
  if ! sed "$prog" "$HERE/$name" >"$dir/$name" 2>/dev/null; then
    bad "the mutation program is not valid sed, so it asserts nothing: $desc"
    return
  fi
  if cmp -s "$dir/$name" "$HERE/$name"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    return
  fi
  cut_run "$dir" mutant
  out="$(cases_cut late mutant 2>/dev/null)"
  if [ "$(printf '%s\n' "$out" | grep -cxF -- "FAIL $id")" -eq 1 ]; then ok; else bad "mutation not detected by '$id': $desc"; fi
}
cut_mutant "a fetch job goes on reading past the deadline" merge-lane.sh \
  's|^    if \[ -z "\$LANE_REPLAY" \] && lane_pass_expired |    if [ "$LANE_WALK_ROLE" != fetch ] \&\& [ -z "$LANE_REPLAY" ] \&\& lane_pass_expired |' cut-fetch-stops-at-the-deadline
cut_mutant "a head already read is thrown away once the budget is spent" merge-lane.sh \
  's|^    if \[ -z "\$LANE_REPLAY" \] && lane_pass_expired |    if lane_pass_expired |' cut-read-heads-keep-their-verdicts
cut_mutant "the first unread head gets no row" merge-lane.sh \
  's|^    for ((j = truncated_at; j < total; j++)); do$|    for ((j = truncated_at + 1; j < total; j++)); do|' cut-unread-heads-are-rows
cut_mutant "the head a job stopped on is closed as if it had been read" merge-lane.sh \
  's|^  if \[ "\$truncated_at" -lt 0 \]; then lane_fetch_seal; fi$|  lane_fetch_seal|' cut-is-not-a-disagreement
cut_mutant "a pass that ran out of time acts on nothing" merge-lane.sh \
  '/^  if \[ "\$truncated_at" -ge 0 \]; then$/a\    candidates=()' cut-still-acts-on-what-it-read

# --- how long the run waited --------------------------------------------------
# An empty queue: the line is printed before the list is read, so these runs
# need no pull request and cost four reads each.
mkdir "$WORK/fix-quiet"
FX_DIR="$WORK/fix-quiet"
fx "repos/$REPO/commits/main" '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}'
fx "repos/$REPO/rules/branches/main" '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]'
fx_checks bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb completed '"success"'
fx "repos/$REPO/pulls" '[]'
# Run 77: triggered at 00:26:00, taken by `runner-b` at 00:26:30, and the clock
# reads 00:26:40. Two decoys: a job in progress on ANOTHER runner, and a job
# this runner has already finished.
fx "repos/$REPO/actions/runs/77/attempts/1" '{"run_started_at":"2026-01-03T00:26:00Z","created_at":"2026-01-03T00:20:00Z"}'
fx "repos/$REPO/actions/runs/77/attempts/1/jobs" '{"jobs":[{"status":"in_progress","runner_name":"runner-a","started_at":"2026-01-03T00:26:05Z"},{"status":"completed","runner_name":"runner-b","started_at":"2026-01-03T00:26:01Z"},{"status":"in_progress","runner_name":"runner-b","started_at":"2026-01-03T00:26:30Z"},{"status":"queued","runner_name":null,"started_at":null}]}'
unset FX_DIR
wait_runs "$real" ''
tally_lines "$(cases_wait quiet waited unreadable 2>&1)" 3 "wait line"
if [ "$FAIL" -gt 0 ]; then
  echo '--- run with a readable wait ---'
  cat "$WORK/run.waited/log"
  echo '--- run with an unreadable one ---'
  cat "$WORK/run.unreadable/log"
fi

# <description> <sed-program> <id>
wait_mutant() {
  local desc="$1" prog="$2" id="$3" dir out
  dir="$(scripts_copy mutant)"
  if ! sed "$prog" "$DRIVER" >"$dir/merge-lane.sh" 2>/dev/null; then
    bad "the mutation program is not valid sed, so it asserts nothing: $desc"
    return
  fi
  if cmp -s "$dir/merge-lane.sh" "$DRIVER"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    return
  fi
  wait_runs "$dir" .m
  out="$(cases_wait quiet.m waited.m unreadable.m 2>/dev/null)"
  if [ "$(printf '%s\n' "$out" | grep -cxF -- "FAIL $id")" -eq 1 ]; then ok; else bad "mutation not detected by '$id': $desc"; fi
}
wait_mutant "the first job in progress is taken, whichever runner has it" \
  's|^    if \[ -n "\$at" \] && \[ "\$name" = "\${RUNNER_NAME:-}" \]; then$|    if [ -n "$at" ]; then|' wait-is-one-line-with-both-figures
wait_mutant "the wait is measured from the run's first attempt, not this one" \
  "s|--jq '\.run_started_at // empty'|--jq '.created_at // empty'|" wait-is-one-line-with-both-figures
wait_mutant "the run is asked about where there is no run" \
  's|^  \[ -n "\${GITHUB_RUN_ID:-}" \] \|\| return 0$|  :|' wait-is-not-asked-outside-a-run
wait_mutant "a wait that cannot be read ends the run" \
  's|^    echo "lane: could not read how long |    exit 1; echo "lane: could not read how long |' wait-unreadable-changes-nothing

echo
if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane-fetch: $FAIL failed, $PASS passed, $SKIP skipped"
  exit 1
fi
echo "merge-lane-fetch: $PASS checks pass, $SKIP skipped"
