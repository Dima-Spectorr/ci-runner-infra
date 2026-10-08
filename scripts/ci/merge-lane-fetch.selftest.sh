#!/usr/bin/env bash
# Behavioural self-test for the merge lane's fetch phase.
#
# `merge-lane.selftest.sh` pins the WIRING of the fetch phase on the text of the
# driver. This file runs the thing: the record/replay pair, the claim, the jobs
# and the tally out of `merge-lane-fetch.sh`, and then the whole driver, twice,
# against a stand-in for the API — once reading serially and once reading
# concurrently — to show the two print the same lines in the same order.
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
    -*) printf 'WRITE %s\n' "$*" >>"$GH_STUB_LOG"; exit 97 ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  rate_limit) echo '5000 4990 10 1900000000'; exit 0 ;;
esac
printf '%s\n' "$url" >>"$GH_STUB_LOG"
case "$url" in
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
mkdir "$WORK/clock"
REAL_DATE="$(command -v date)"
export REAL_DATE
cat >"$WORK/clock/date" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in -d | -d?* | --date | --date=*) exec "$REAL_DATE" "$@" ;; esac
done
exec "$REAL_DATE" -d '@1767400000' "$@"
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

# ---------------------------------------------------------------------------
# End to end: the driver itself, serial and concurrent, over one mixed queue.
# ---------------------------------------------------------------------------
REPO='example/repo'
sha_of() { printf '%08d%032d' "$1" 0; }
fx() { # <url-without-query> <json> [n-th-read]
  local key
  key="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
  printf '%s\n' "$2" >"$WORK/fix/$key${3:+.$3}"
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
  PATH="$WORK/clock:$PATH" GH_STUB_LOG="$out/calls" GH_STUB_STATE="$out/state" TMPDIR="$out/tmp" \
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
  diff "$WORK/run.serial/log.decided" "$WORK/run.concurrent/log.decided" | head -40
  diff "$WORK/run.serial/calls.sorted" "$WORK/run.concurrent/calls.sorted" | head -20
  diff "$WORK/run.serial/summary" "$WORK/run.concurrent/summary" | head -20
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

echo
if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane-fetch: $FAIL failed, $PASS passed, $SKIP skipped"
  exit 1
fi
echo "merge-lane-fetch: $PASS checks pass, $SKIP skipped"
