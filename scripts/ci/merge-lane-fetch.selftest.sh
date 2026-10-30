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
# reached the network from a fetch job cannot hide among the reads. The one
# exception is `api graphql`, whose query and variables travel as `-f`/`-F`
# fields: it is answered from the fixture `graphql`, one JSON document a page,
# and its header block names the graphql bucket.
# ---------------------------------------------------------------------------
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
[ "${1:-}" = api ] || exit 2
shift
url='' prog='' include='' paginate='' cursor=''
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) prog="$2"; shift 2 ;;
    --paginate) paginate=1; shift ;;
    -f) if [ "$url" = graphql ] && [ $# -ge 2 ] && [ "${2%%=*}" = endCursor ]; then cursor="${2#endCursor=}"; shift 2; continue; fi ;;&
    # `-i`: the answer's header block first, in `gh`'s own shape — a status line,
    # CR LF header lines, a lone CR LF. The window it reports is set by the case
    # (GH_STUB_REMAINING / _RESET / _RESOURCE); GH_STUB_NO_HEADERS answers with
    # none, the way an API that is not answering at all would.
    -i) include=1; shift ;;
    -f | -F) if [ "$url" = graphql ] && [ $# -ge 2 ]; then shift 2; continue; fi ;;&
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
    # Nothing in the lane asks `rate_limit` any more (#1543, #1548): the guard
    # and the retry's wait both read the answers' own headers. A read here is
    # logged and refused, so code that went back to it would read nothing and
    # the cases below would say so.
    printf 'RATE_LIMIT %s\n' "$prog" >>"$GH_STUB_LOG"
    exit 3
    ;;
esac
if [ -n "$include" ] && [ -z "${GH_STUB_NO_HEADERS:-}" ]; then
  printf 'HTTP/2.0 200 OK\n'
  printf 'X-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: %s\r\nX-Ratelimit-Resource: %s\r\nX-Ratelimit-Used: 10\r\n\r\n' \
    "${GH_STUB_REMAINING:-4990}" "${GH_STUB_QUOTA_RESET:-1900000000}" "${GH_STUB_RESOURCE:-$([ "$url" = graphql ] && echo graphql || echo core)}"
fi
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
# A GraphQL fixture holds one page a line, and the page is picked by the
# `endCursor` variable the way GitHub picks it: none is the first page, `pN` is
# line N. `--paginate` is refused, because it stops at the first page carrying
# `errors` and so cannot be how the lane reads (#1541). An answer that carries
# `errors` is what gh makes of one: the body raw on stdout (gh skips `--jq`
# then), its first message on stderr, exit 1. A page that reads `HTTP <code>`
# is a refusal with no GraphQL body at all.
if [ "$url" = graphql ] && [ -e "$file" ]; then
  [ -z "$paginate" ] || { printf 'gh api graphql --paginate is not how the lane reads\n' >&2; exit 98; }
  printf '%s\n' "${cursor:--}" >>"$GH_STUB_STATE/graphql.cursors"
  line=1
  case "$cursor" in p[0-9]*) line="${cursor#p}" ;; esac
  sed -n "${line}p" "$file" >"$GH_STUB_STATE/graphql.page"
  # `<fault> then <page>`: the fault on the first ask of this page, the page on
  # every ask after it — a server that failed once (#1581).
  page="$(cat "$GH_STUB_STATE/graphql.page")"
  case "$page" in
    *' then '*)
      printf . >>"$GH_STUB_STATE/graphql.flaky.$line"
      if [ "$(wc -c <"$GH_STUB_STATE/graphql.flaky.$line" | tr -d ' ')" -ge 2 ]; then
        printf '%s\n' "${page#* then }" >"$GH_STUB_STATE/graphql.page"
      else
        printf '%s\n' "${page%% then *}" >"$GH_STUB_STATE/graphql.page"
      fi
      ;;
  esac
  case "$(cat "$GH_STUB_STATE/graphql.page")" in
    # `HTTP <code> [text]`: a refusal with no GraphQL body, gh's stderr naming it.
    'HTTP '*)
      printf '{"message":"Bad Gateway"}\n'
      printf 'gh: %s\n' "$(cat "$GH_STUB_STATE/graphql.page")" >&2
      exit 1
      ;;
    # GitHub's HTML error page where JSON was due.
    HTML)
      printf '<!DOCTYPE html>\n<html><head><title>Unicorn! - GitHub</title></head><body>Something went wrong</body></html>\n'
      printf "gh: invalid character '<' looking for beginning of value\n" >&2
      exit 1
      ;;
  esac
  if jq -e '(.errors // []) | length > 0' "$GH_STUB_STATE/graphql.page" >/dev/null 2>&1; then
    cat "$GH_STUB_STATE/graphql.page"
    printf 'gh: %s\n' "$(jq -r '.errors[0].message' "$GH_STUB_STATE/graphql.page" | tr -d '\r')" >&2
    exit 1
  fi
  file="$GH_STUB_STATE/graphql.page"
fi
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
    # shellcheck disable=SC2317,SC2329  # called indirectly, by lane_snap_page via the sourced fetch file
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

    # Racing claims of one head have exactly one winner: four jobs at once, 40
    # times. A claim that is not exclusive on this image fails here outright,
    # not only through the timing of the cases above (#1644).
    p="$d/race"
    mkdir "$p"
    multi=0
    for ((r = 0; r < 40; r++)); do
      for ((w = 0; w < 4; w++)); do
        (LANE_RECORD='' && lane_fetch_claim "$p/$r" && : >"$p/won.$r.$w") &
      done
      wait
      won=0
      for f in "$p"/won."$r".*; do
        if [ -e "$f" ]; then won=$((won + 1)); fi
      done
      if [ "$won" -ne 1 ]; then multi=$((multi + 1)); fi
    done
    [ "$multi" -eq 0 ]
    say racing-claims-have-one-winner $?
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
    # shellcheck disable=SC2317,SC2329  # called indirectly, by lane_snap_page via the sourced fetch file
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
    # shellcheck disable=SC2317,SC2329  # called indirectly, by lane_snap_page via the sourced fetch file
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
    # A GraphQL page holds ten; mergeability is UNKNOWN and no commit node is
    # given, so the snapshot answers for nothing but the list and every head is
    # read from the REST fixtures below, as the cases here were written.
    [ "$n" -ne 11 ] || list="$list]}}}}"$'\n''{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":['
    [ "$n" -eq 1 ] || [ "$n" -eq 11 ] || list="$list,"
    list="$list{\"number\":$n,\"headRefOid\":\"$(sha_of "$n")\",\"isDraft\":$draft,\"labels\":{\"nodes\":$labels},\"title\":\"change $n\",\"mergeable\":\"UNKNOWN\",\"author\":{\"__typename\":\"User\",\"login\":\"someone\"},\"commits\":{\"nodes\":[]}}"
    fx_checks "$(sha_of "$n")" completed '"success"'
    fx_detail "$n" true "$labels"
    fx "repos/$REPO/compare/main...$(sha_of "$n")" '{"behind_by":0}'
  done
  fx graphql '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":true,"endCursor":"p2"},"nodes":['"$list"']}}}}'
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
# shellcheck disable=SC2034,SC2317,SC2329,SC2181
cases_retry() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/retry.XXXXXX")"
    LANE_TMP="$d" LANE_RECORD='' LANE_REPLAY=''
    unset LANE_STARTED PASS_BUDGET GH_STUB_REMAINING GH_STUB_QUOTA_RESET GH_STUB_RESOURCE GH_STUB_NO_HEADERS
    # Git for Windows' gawk drops a trailing CR that Linux gawk keeps, so the
    # CRLF case would pass here even with the CR left in. BINMODE=3 makes a
    # local run read the bytes CI reads; on Linux gawk ignores it.
    awk() { command awk -v BINMODE=3 "$@"; }
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
    # The wait is the reset the REFUSAL carried (#1548) — and `rate_limit` is
    # never asked: the stub refuses it, and logs the attempt.
    out="$(GH_STUB_REMAINING=0 GH_STUB_QUOTA_RESET=$((now + 30)) lane_gh_retry api limit/a 2>"$d/err")"
    rc=$?
    w="$(slept)"
    [ "$rc" -eq 0 ] && [ "$out" = 'out:limit/a' ] && [ "${w:-0}" -ge 25 ] && [ "${w:-0}" -le 31 ] \
      && [ "$(grep -c '^RATE_LIMIT' "$GH_STUB_LOG")" -eq 0 ]
    say retry-primary-waits-for-the-reset $?

    fresh
    GH_STUB_REMAINING=0 GH_STUB_QUOTA_RESET=$((now + 600)) lane_gh_retry api limit/b >/dev/null 2>"$d/err"
    [ $? -ne 0 ] && [ -z "$(slept)" ] && [ "$(calls limit/b)" -eq 1 ] && grep -q 'not retried' "$d/err"
    say retry-not-past-the-cap $?

    # A refusal whose own window still has quota left (remaining=4990, reset an
    # hour out) was not refused by that window: waiting for its reset would hold
    # the pass an hour for a window already open. One more call after a minute.
    fresh
    out="$(GH_STUB_QUOTA_RESET=$((now + 3600)) lane_gh_retry api limit/c 2>"$d/err")"
    [ $? -eq 0 ] && [ "$out" = 'out:limit/c' ] && [ "$(slept)" = 60 ] && [ "$(calls limit/c)" -eq 2 ]
    say retry-quota-left-after-a-minute $?

    # A refusal with no header block says nothing about any window: a minute.
    fresh
    out="$(GH_STUB_NO_HEADERS=1 lane_gh_retry api limit/d 2>"$d/err")"
    [ $? -eq 0 ] && [ "$out" = 'out:limit/d' ] && [ "$(slept)" = 60 ] && [ "$(calls limit/d)" -eq 2 ]
    say retry-no-headers-after-a-minute $?

    # The shape GitHub answers a drained installation with: `gh api -i` prints
    # the status line, CR LF header lines, then the body. Exact to the second.
    fresh
    printf 'gh: API rate limit exceeded for installation ID 1. (HTTP 403)\n' >"$d/e403"
    printf 'HTTP/2.0 403 Forbidden\r\nX-Github-Request-Id: AB12:3:4\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: 1900000045\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Used: 5000\r\n' >"$d/h403"
    [ "$(lane_rate_limit_wait "$d/e403" "$d/h403" 1900000000)" = 46 ]
    say retry-wait-from-a-crlf-refusal $?

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
# THE QUOTA IS NOTED FROM THE LANE'S OWN ANSWERS (#1543). Every real `gh api`
# goes out with `-i`; the caller gets the body alone, and LANE_QUOTA holds the
# newest core window an answer carried — a refusal's included.
# shellcheck disable=SC2034
cases_quota() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/quota.XXXXXX")"
    LANE_TMP="$d" LANE_RECORD='' LANE_REPLAY='' LANE_QUOTA="$d/quota"
    unset LANE_STARTED PASS_BUDGET GH_STUB_REMAINING GH_STUB_QUOTA_RESET GH_STUB_RESOURCE GH_STUB_NO_HEADERS
    : >"$GH_STUB_LOG"

    out="$(lane_gh_retry api ok/q1)"; rc=$?
    [ "$rc" -eq 0 ] && [ "$out" = 'out:ok/q1' ]
    say quota-headers-never-reach-the-caller $?
    [ "$(cat "$d/quota" 2>/dev/null)" = '5000 4990 10 1900000000' ]
    say quota-noted-from-the-answer $?

    GH_STUB_REMAINING=0 GH_STUB_QUOTA_RESET=1900000123 lane_gh_retry api forbidden/q >/dev/null 2>&1
    [ "$(cat "$d/quota" 2>/dev/null)" = '5000 0 10 1900000123' ]
    say quota-noted-from-a-refusal $?

    GH_STUB_RESOURCE=graphql lane_gh_retry api ok/q2 >/dev/null
    GH_STUB_RESOURCE=search lane_gh_retry api ok/q4 >/dev/null
    GH_STUB_NO_HEADERS=1 lane_gh_retry api ok/q3 >/dev/null
    [ "$(cat "$d/quota" 2>/dev/null)" = '5000 0 10 1900000123' ]
    say quota-kept-over-another-bucket-and-a-bare-answer $?
    # The open list is read from the graphql bucket (#1541): its window is kept
    # apart, for the guard to hold on.
    [ "$(cat "$d/quota.graphql" 2>/dev/null)" = '5000 4990 10 1900000000' ]
    say quota-graphql-noted-apart $?

    [ "$(grep -c '^RATE_LIMIT' "$GH_STUB_LOG")" -eq 0 ]
    say quota-never-asks-rate-limit $?
  )
}

# ---------------------------------------------------------------------------
# THE OPEN LIST IS ONE GRAPHQL READ A PAGE (#1541), AND IT ANSWERS THE WALK.
#
# Three pages of the shape GitHub answers the query with, each reached by the
# `endCursor` the page before it gave: one pull request whose head is fully
# known, and around it every shape the snapshot must NOT answer for — a null
# rollup, a suite list cut at a page edge, a head that moved, mergeability not
# computed yet, and the one GraphQL measurably refuses under the merge App's
# token: a suite whose `app` it cannot resolve, answered as `null` beside an
# `errors` entry `type: INTERNAL` at that `.app` (diag run 38227488117). The
# stand-in answers that page the way gh does: body on stdout, exit 1.
# ---------------------------------------------------------------------------
snap_node() { # <number> <sha> <mergeable> <author-json> <commits-json>
  printf '{"number":%s,"isDraft":false,"title":"change %s\\r\\nmore","headRefOid":"%s","mergeable":"%s","author":%s,"labels":{"nodes":[{"name":"queue"}]},"commits":{"nodes":%s}}' \
    "$1" "$1" "$2" "$3" "$4" "$5"
}
snap_suite() { # <id> <app-json> <workflow-run-json> <more-runs> <runs-json>
  printf '{"databaseId":%s,"status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2026-01-02T00:00:00Z","app":%s,"workflowRun":%s,"checkRuns":{"pageInfo":{"hasNextPage":%s},"nodes":%s}}' \
    "$1" "$2" "$3" "$4" "$5"
}
snap_page() { # <has-next> <end-cursor-json> <nodes> [errors-json]
  printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":[%s]}}}%s}\n' \
    "$1" "$2" "$3" "${4:+,\"errors\":$4}"
}
# The error GitHub answers for the suite it cannot name the app of.
SNAP_APP_ERROR='[{"type":"INTERNAL","path":["repository","pullRequests","nodes",1,"commits","nodes",0,"commit","checkSuites","nodes",1,"app"],"locations":[{"line":15,"column":15}],"message":"Something went wrong while executing your query."}]'
build_snap_fixture() { # <dir>
  local a b c d e f g run other private s1 s2 s3
  a="$(sha_of 21)" b="$(sha_of 22)" c="$(sha_of 23)" d="$(sha_of 24)" e="$(sha_of 25)" f="$(sha_of 26)" g="$(sha_of 27)"
  run='[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-02T00:00:00Z","completedAt":"2026-01-02T00:01:00Z"}]'
  s1="$(snap_suite 101 '{"slug":"github-actions","databaseId":15368}' '{"event":"pull_request","workflow":{"databaseId":9}}' false "$run")"
  other="$(snap_suite 102 '{"slug":"other-app","databaseId":77}' null false '[]')"
  s2="$(snap_suite 103 '{"slug":"github-actions","databaseId":15368}' null true "$run")"
  s3="$(snap_suite 104 '{"slug":"github-actions","databaseId":15368}' null false "$run")"
  private="$(snap_suite 105 null null false "$run")"
  {
    # 21: fully known, two apps; an EXPECTED status. 22: a null rollup — no
    # status, no suite — written as the empty answer it is.
    snap_page true '"p2"' "$(snap_node 21 "$a" MERGEABLE '{"__typename":"User","login":"someone"}' \
      "[{\"commit\":{\"oid\":\"$a\",\"status\":{\"contexts\":[{\"context\":\"legacy\",\"state\":\"EXPECTED\",\"createdAt\":\"2026-01-02T00:00:00Z\"}]},\"checkSuites\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[$s1,$other]}}}]"),$(
      snap_node 22 "$b" CONFLICTING '{"__typename":"Bot","login":"pin-bot"}' \
      "[{\"commit\":{\"oid\":\"$b\",\"status\":null,\"checkSuites\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[]}}}]")"
    # 23: a suite cut at a page edge of its runs. 24: the head moved. 25: no
    # commit node at all.
    snap_page true '"p3"' "$(snap_node 23 "$c" UNKNOWN null \
      "[{\"commit\":{\"oid\":\"$c\",\"status\":null,\"checkSuites\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[$s2]}}}]"),$(
      snap_node 24 "$d" UNKNOWN '{"__typename":"User","login":"x"}' \
      "[{\"commit\":{\"oid\":\"$(sha_of 240)\",\"status\":null,\"checkSuites\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[$s3]}}}]"),$(
      snap_node 25 "$e" UNKNOWN '{"__typename":"User","login":"x"}' '[]')"
    # 26: more suites than one page holds. 27: a suite whose app GraphQL could
    # not resolve, with the INTERNAL error at its `.app` — every other field whole.
    snap_page false null "$(snap_node 26 "$f" UNKNOWN '{"__typename":"User","login":"x"}' \
      "[{\"commit\":{\"oid\":\"$f\",\"status\":null,\"checkSuites\":{\"pageInfo\":{\"hasNextPage\":true},\"nodes\":[$s3]}}}]"),$(
      snap_node 27 "$g" MERGEABLE '{"__typename":"User","login":"x"}' \
      "[{\"commit\":{\"oid\":\"$g\",\"status\":{\"contexts\":[{\"context\":\"legacy\",\"state\":\"SUCCESS\",\"createdAt\":\"2026-01-02T00:00:00Z\"}]},\"checkSuites\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[$s1,$private]}}}]")" \
      "$SNAP_APP_ERROR"
  } >"$1/graphql"
}

# <dir> <kind> — an open list GraphQL answers with something the lane must not
# read through. The first page is always whole; the second carries the fault.
build_snap_fault() {
  local ok node last
  node="$(snap_node 31 "$(sha_of 31)" MERGEABLE '{"__typename":"User","login":"x"}' '[]')"
  ok="$(snap_page true '"p2"' "$node")"
  last="$(snap_page false null "$(snap_node 32 "$(sha_of 32)" MERGEABLE '{"__typename":"User","login":"y"}' '[]')")"
  case "$2" in
    # An error anywhere but a check suite's app: here, at a check run.
    other-path) printf '%s\n' "$ok" "$(snap_page false null "$node" '[{"type":"INTERNAL","path":["repository","pullRequests","nodes",0,"commits","nodes",0,"commit","checkSuites","nodes",0,"checkRuns"],"message":"x"}]')" ;;
    # An `.app` that is not a check suite's.
    app-elsewhere) printf '%s\n' "$ok" "$(snap_page false null "$node" '[{"type":"INTERNAL","path":["repository","pullRequests","nodes",0,"app"],"message":"x"}]')" ;;
    # An error with no path: the shape of a rate limit, with no data.
    no-path) printf '%s\n' "$ok" '{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}' ;;
    # The tolerated error, on a page whose connection is missing.
    no-data) printf '%s\n' "$ok" "{\"data\":{\"repository\":null},\"errors\":$SNAP_APP_ERROR}" ;;
    # The tolerated error, on a page that has its nodes but no `pageInfo`: it
    # cannot say whether a next page exists, so it must not read as the last.
    no-pageinfo) printf '%s\n' "$ok" "{\"data\":{\"repository\":{\"pullRequests\":{\"nodes\":[$node]}}},\"errors\":$SNAP_APP_ERROR}" ;;
    # A null pull request node beside the tolerated error.
    null-node) printf '%s\n' "$ok" "$(snap_page false null "$node,null" "$SNAP_APP_ERROR")" ;;
    # No GraphQL body at all.
    http) printf '%s\n' "$ok" 'HTTP 502' ;;
    # A next page with no cursor to reach it.
    no-cursor) printf '%s\n' "$(snap_page true null "$node")" ;;
    # A server that failed the second page once, then served it (#1581).
    502-then-ok) printf '%s\n' "$ok" "HTTP 502 Bad Gateway then $last" ;;
    html-then-ok) printf '%s\n' "$ok" "HTML then $last" ;;
    timeout-then-ok) printf '%s\n' "$ok" '{"data":null,"errors":[{"message":"Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug."}]} then '"$last" ;;
    # A primary rate limit, refused as a 403: an answer, never asked again here.
    limited) printf '%s\n' "$ok" 'HTTP 403 API rate limit exceeded for installation ID 1.' ;;
  esac >"$1/graphql"
}

# SC2034: the LANE_* globals and R are read by the sourced fetch file.
# shellcheck disable=SC2034
cases_snap() { # <fetch-file>
  (
    # shellcheck source=/dev/null
    source "$1"
    d="$(mktemp -d "$WORK/snap.XXXXXX")"
    mkdir "$d/fix" "$d/snap"
    build_snap_fixture "$d/fix"
    # The page retry's wait is written down, never slept (#1581).
    # shellcheck disable=SC2317,SC2329  # called indirectly, by lane_snap_page via the sourced fetch file
    lane_snap_retry_sleep() { echo "$1" >>"$d/slept"; }
    LANE_TMP="$d" LANE_RECORD='' LANE_REPLAY='' LANE_QUOTA="$d/quota" R="$REPO" LANE_BASE=main
    unset GH_STUB_REMAINING GH_STUB_QUOTA_RESET GH_STUB_RESOURCE GH_STUB_NO_HEADERS
    : >"$GH_STUB_LOG"
    : >"$GH_STUB_STATE/graphql.cursors"
    a="$(sha_of 21)" b="$(sha_of 22)" g="$(sha_of 27)"
    has() { [ -e "$d/snap/$(lane_snap_key "repos/$REPO/$1")" ]; }

    fields="$(GH_STUB_FIXTURES="$d/fix" lane_snapshot "$d/snap")"
    rc=$?
    [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$fields" | wc -l | tr -d ' ')" -eq 42 ] \
      && [ "$(printf '%s\n' "$fields" | sed -n '1p;7p;13p;19p;25p;31p;37p' | tr '\n' ' ')" = '21 22 23 24 25 26 27 ' ] \
      && [ "$(grep -cx graphql "$GH_STUB_LOG")" -eq 3 ] && [ "$(wc -l <"$GH_STUB_LOG" | tr -d ' ')" -eq 3 ] \
      && [ "$(tr '\n' ' ' <"$GH_STUB_STATE/graphql.cursors")" = '- p2 p3 ' ]
    say snap-reads-every-page-by-cursor $?

    [ "$(printf '%s\n' "$fields" | sed -n '2,6p' | tr '\n' '|')" = "$a|false|queue|change 21  more|someone|" ]
    say snap-list-fields-in-rest-order $?

    [ "$(printf '%s\n' "$fields" | sed -n '12p')" = 'pin-bot[bot]' ] && [ -z "$(printf '%s\n' "$fields" | sed -n '18p')" ]
    say snap-bot-login-in-rest-form $?

    LANE_SNAP="$d/snap"
    [ "$(lane_snap_serve api --paginate "repos/$REPO/commits/$a/check-runs?per_page=100" --jq '.check_runs[] | .name + " " + .status + " " + .conclusion + " " + .app.slug')" = 'ci completed success github-actions' ] \
      && [ "$(lane_snap_serve api --paginate "repos/$REPO/commits/$a/check-suites?per_page=100" --jq '[.check_suites[].app.slug] | join(",")')" = 'github-actions,other-app' ] \
      && [ "$(lane_snap_serve api --paginate "repos/$REPO/actions/runs?head_sha=$a&per_page=100" --jq '.workflow_runs[] | "\(.check_suite_id) \(.workflow_id) \(.event)"')" = '101 9 pull_request' ] \
      && [ "$(lane_snap_serve api --paginate "repos/$REPO/commits/$a/status?per_page=100" --jq '.statuses[] | .context + " " + .state')" = 'legacy pending' ] \
      && [ "$(lane_snap_serve api "repos/$REPO/pulls/21" --jq '(.mergeable|tostring), (.labels|map(.name)|join(",")), .head.sha')" = "$(printf 'true\nqueue\n%s' "$a")" ] \
      && [ "$(wc -l <"$GH_STUB_LOG" | tr -d ' ')" -eq 3 ]
    say snap-serves-the-rest-bodies-without-a-call $?

    [ "$(lane_snap_serve api "repos/$REPO/pulls/22" --jq '.mergeable|tostring')" = false ] \
      && [ "$(lane_snap_serve api --paginate "repos/$REPO/commits/$b/check-runs?per_page=100" --jq '.check_runs | length')" = 0 ] \
      && [ "$(lane_snap_serve api --paginate "repos/$REPO/commits/$b/status?per_page=100" --jq '.statuses | length')" = 0 ]
    say snap-null-rollup-is-the-empty-answer $?

    ! has "commits/$(sha_of 23)/check-runs?per_page=100" && ! has "commits/$(sha_of 26)/check-suites?per_page=100" \
      && ! has "commits/$(sha_of 24)/check-runs?per_page=100" && ! has "commits/$(sha_of 25)/check-runs?per_page=100"
    say snap-cut-moved-or-missing-head-is-read-live $?

    ! has pulls/23 && ! has pulls/24 && has pulls/21 && has pulls/22
    say snap-unknown-mergeability-is-read-live $?

    # THE INTERNAL ERROR AT `.app`, WITH THE DATA WHOLE, PROCEEDS — and the head
    # it touched has its app-keyed reads go to REST, which names every app;
    # what does not involve an app is still served.
    ! has "commits/$g/check-runs?per_page=100" && ! has "commits/$g/check-suites?per_page=100" \
      && [ "$(lane_snap_serve api --paginate "repos/$REPO/commits/$g/status?per_page=100" --jq '.statuses[] | .context + " " + .state')" = 'legacy success' ] \
      && [ "$(lane_snap_serve api --paginate "repos/$REPO/actions/runs?head_sha=$g&per_page=100" --jq '[.workflow_runs[].check_suite_id] | join(",")')" = '101' ] \
      && has pulls/27 \
      && grep -q '^open list read in 3 GraphQL page(s), 7 pull request(s); 1 check-suite app field' "$d/snap/summary"
    say snap-app-error-with-full-data-proceeds $?

    # ANY OTHER ERROR IS THE LANE BLIND: no list, a reason on stderr, every time.
    local kind all=0
    for kind in other-path app-elsewhere no-path no-data no-pageinfo null-node http no-cursor limited; do
      mkdir "$d/fault-$kind" "$d/fault-$kind/snap"
      build_snap_fault "$d/fault-$kind" "$kind"
      : >"$GH_STUB_STATE/graphql.cursors"
      if GH_STUB_FIXTURES="$d/fault-$kind" lane_snapshot "$d/fault-$kind/snap" >"$d/fault-$kind/out" 2>"$d/fault-$kind/err"; then
        all=1
      elif [ ! -s "$d/fault-$kind/err" ]; then
        all=1
      fi
    done
    [ "$all" -eq 0 ]
    say snap-any-other-error-fails-closed $?

    # A PAGE GITHUB FAILED TO SERVE IS ASKED AGAIN (#1581). <kind> — runs the
    # read on that fault fixture; leaves out/err/rc, the graphql calls and the
    # cursors asked in $d/r-<kind>.
    snap_run() {
      local r="$d/r-$1"
      mkdir -p "$r/snap"
      build_snap_fault "$r" "$1"
      : >"$GH_STUB_STATE/graphql.cursors"
      : >"$GH_STUB_LOG"
      : >"$d/slept"
      rm -f "$GH_STUB_STATE"/graphql.flaky.*
      local rc=0
      GH_STUB_FIXTURES="$r" lane_snapshot "$r/snap" >"$r/out" 2>"$r/err" || rc=$?
      printf '%s' "$rc" >"$r/rc"
      grep -cx graphql "$GH_STUB_LOG" >"$r/calls" || true
      tr '\n' ' ' <"$GH_STUB_STATE/graphql.cursors" >"$r/cursors"
    }
    local k ok_all=0
    for k in 502-then-ok html-then-ok timeout-then-ok; do
      snap_run "$k"
      [ "$(<"$d/r-$k/rc")" = 0 ] && [ "$(<"$d/r-$k/calls")" = 3 ] && [ "$(<"$d/r-$k/cursors")" = '- p2 p2 ' ] \
        && [ "$(sed -n '1p;7p' "$d/r-$k/out" | tr '\n' ' ')" = '31 32 ' ] \
        && [ "$(tr '\n' ' ' <"$d/slept")" = '2 ' ] \
        && grep -q '^open list read in 2 GraphQL page(s), 2 pull request(s);.* 1 page read(s) asked again after a server error$' "$d/r-$k/snap/summary" \
        || ok_all=1
    done
    [ "$ok_all" -eq 0 ]
    say snap-a-server-error-on-a-page-is-asked-again $?

    # Every ask fails: bounded at LANE_SNAP_RETRIES, then blind — and says it
    # was a server error on every attempt, which the first log line then names.
    snap_run http
    [ "$(<"$d/r-http/rc")" != 0 ] && [ "$(<"$d/r-http/calls")" = $((2 + LANE_SNAP_RETRIES)) ] \
      && [ "$(tr '\n' ' ' <"$d/slept")" = '2 5 ' ] \
      && grep -q "a server error on each of $((1 + LANE_SNAP_RETRIES)) attempts" "$d/r-http/err" \
      && [ "$(lane_read_cause "$d/r-http/err")" = 'GitHub answered with a server error (HTTP 502) — the lane is blind for this pass, not idle; the recover job dispatches another' ]
    say snap-a-server-error-every-time-is-bounded-and-named $?

    # A quota refusal is an answer: never asked again by the page retry.
    local quota_ok=0
    for k in limited no-path; do
      snap_run "$k"
      [ "$(<"$d/r-$k/rc")" != 0 ] && [ "$(<"$d/r-$k/calls")" = 2 ] && [ ! -s "$d/slept" ] \
        && ! grep -q 'asking again' "$d/r-$k/err" || quota_ok=1
    done
    [ "$quota_ok" -eq 0 ]
    say snap-a-quota-refusal-is-not-asked-again $?

    # (#1425) The first line of a failed read names a quota refusal as one, with
    # the time the refusing window reopens, and says "blind" only for the rest.
    printf 'gh: API rate limit exceeded for installation ID 1. (HTTP 403)\n' >"$d/e403"
    printf 'gh: Too Many Requests (HTTP 429)\n' >"$d/e429"
    printf 'gh: Resource not accessible by integration (HTTP 403)\n' >"$d/eperm"
    printf 'gh: Not Found (HTTP 404)\n' >"$d/e404"
    printf '5000 0 5000 1900000600\n' >"$d/qzero"
    printf '5000 12 4988 1900000600\n' >"$d/qleft"
    [ "$(lane_read_cause "$d/e403" "$d/qzero" 1900000000)" = 'rate limited by GitHub (the merge App quota is shared by every lane), retry at '"$(date -u -d @1900000600 +%H:%M:%SZ)"' — not blind; the recover job dispatches a pass after it' ] \
      && [[ "$(lane_read_cause "$d/e429" "$d/qleft" 1900000000)" == 'rate limited by GitHub '*'retry in about a minute — not blind'* ]] \
      && [[ "$(lane_read_cause "$d/r-no-path/err" '' 1900000000)" == 'rate limited by GitHub'* ]] \
      && [[ "$(lane_read_cause "$d/r-limited/err" "$d/missing" 1900000000)" == 'rate limited by GitHub'* ]] \
      && ! lane_read_cause "$d/eperm" "$d/qzero" 1900000000 >/dev/null \
      && ! lane_read_cause "$d/e404" '' 1900000000 >/dev/null \
      && ! lane_read_cause "$d/missing" '' 1900000000 >/dev/null
    say read-cause-names-a-quota-refusal-not-blind $?

    ! lane_snap_serve api --method=PUT "repos/$REPO/pulls/21" && ! lane_snap_serve api "repos/$REPO/pulls/99" \
      && ! LANE_SNAP='' lane_snap_serve api "repos/$REPO/pulls/21" && ! lane_snap_serve api "repos/$REPO/pulls/21" --jq '.nope | error'
    say snap-serves-nothing-else $?

    ! lane_gh_mutates api graphql -F owner=o -f endCursor=c -f query=q \
      && lane_gh_mutates api "repos/$REPO/issues/1/comments" -f body=x && lane_gh_mutates api graphql -X POST -f query=q
    say snap-graphql-read-is-not-a-write $?
  )
}

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
tally_lines "$(cases_spawn "$FETCH" 2>&1)" 8 spawn
tally_lines "$(cases_kill "$FETCH" 2>&1)" 2 kill
tally_lines "$(cases_shell "$FETCH" 2>&1)" 2 shell
tally_lines "$(cases_retry "$FETCH" 2>&1)" 12 retry
tally_lines "$(cases_quota "$FETCH" 2>&1)" 6 quota
tally_lines "$(cases_snap "$FETCH" 2>&1)" 15 snap

mutant "the header block reaches the caller" cases_quota "$FETCH"   's|^    inh { if ([$]0 == "[\]r" [|][|] [$]0 == "") { inh = 0 } else { print > hdr }; next }$|    inh { print; if (length($0) < 2) inh = 0; next }|' quota-headers-never-reach-the-caller
mutant "a call goes out without its headers" cases_quota "$FETCH"   's|command gh api -i "\${@:2}"|command gh api "${@:2}"|' quota-noted-from-the-answer
mutant "a refusal's headers are dropped" cases_quota "$FETCH"   's|^  lane_quota_note "\$d/hdr"$|  [ "$rc" -ne 0 ] \|\| lane_quota_note "$d/hdr"|' quota-noted-from-a-refusal
mutant "another bucket's window is taken for the REST quota" cases_quota "$FETCH"   's|^    graphql) file="\$LANE_QUOTA.graphql" ;;$|    graphql) file="$LANE_QUOTA" ;;|' quota-kept-over-another-bucket-and-a-bare-answer
mutant "the graphql window is dropped" cases_quota "$FETCH"   's|^    graphql) file="\$LANE_QUOTA.graphql" ;;$|    graphql) return 0 ;;|' quota-graphql-noted-apart

mutant "the list reads one page" cases_snap "$FETCH" \
  's|^    \[ "\$more" != - \] \|\| break$|    break|' snap-reads-every-page-by-cursor
mutant "the next page is asked without its cursor" cases_snap "$FETCH" \
  's| -f endCursor="\$cursor" | |' snap-reads-every-page-by-cursor
mutant "a Bot author keeps the GraphQL form" cases_snap "$FETCH" \
  's|then .author.login + "\[bot\]" else|then .author.login else|' snap-bot-login-in-rest-form
mutant "gh's exit status decides the read again" cases_snap "$FETCH" \
  's|^    pages=\$((pages + 1))$|    pages=$((pages + 1)); [ "$rc" -eq 0 ] \|\| return 1|' snap-app-error-with-full-data-proceeds
mutant "a head whose app GraphQL could not name is served" cases_snap "$FETCH" \
  's/select(\[\$s\[\] | .app.slug | type == "string"\] | all)/select(true)/' snap-app-error-with-full-data-proceeds
mutant "any error is accepted" cases_snap "$FETCH" \
  's|^  jq -e '"'"'$|  true \|\| jq -e '"'"'|' snap-any-other-error-fails-closed
mutant "an error anywhere ending in app is accepted" cases_snap "$FETCH" \
  's| and any(.path\[\]; . == "checkSuites")\]$|]|' snap-any-other-error-fails-closed
mutant "an error at any path is accepted" cases_snap "$FETCH" \
  's|            and .path\[-1\] == "app" and any(.path\[\]; . == "checkSuites")\]$|            ]|' snap-any-other-error-fails-closed
mutant "a page whose connection is missing is accepted" cases_snap "$FETCH" \
  's|^    (.data.repository.pullRequests.pageInfo \| type) == "object"$|    true|' snap-any-other-error-fails-closed
mutant "a next page with no cursor ends the read as if it were the last" cases_snap "$FETCH" \
  's|^    if \[ -z "\$more" \] \|\| \[ "\$more" = "\$prev" \]; then$|    if [ -z "$more" ]; then break; fi; if [ "$more" = "$prev" ]; then|' snap-any-other-error-fails-closed
mutant "an EXPECTED status is passed through" cases_snap "$FETCH" \
  's|if .state == "EXPECTED" then "pending" else (.state \| low) end|.state \| low|' snap-serves-the-rest-bodies-without-a-call
mutant "a null rollup is not written" cases_snap "$FETCH" \
  's|(\$c.checkSuites.nodes // \[\]) as \$s$|($c.checkSuites.nodes // empty) as $s \| select($s \| length > 0)|' snap-null-rollup-is-the-empty-answer
mutant "a suite cut at a page edge is served" cases_snap "$FETCH" \
  's|and (\[(\$c.checkSuites.nodes // \[\])\[\] \| .checkRuns.pageInfo.hasNextPage\] \| any \| not))|)|' snap-cut-moved-or-missing-head-is-read-live
mutant "a moved head is served" cases_snap "$FETCH" \
  's|select(\$c != null and \$c.oid == \$pr.headRefOid)|select($c != null)|' snap-cut-moved-or-missing-head-is-read-live
mutant "an uncomputed mergeability is written" cases_snap "$FETCH" \
  's#^    | (if \$m != null then$#    | (if true then#' snap-unknown-mergeability-is-read-live
mutant "a write is answered from the snapshot" cases_snap "$FETCH" \
  '/^lane_snap_serve() {$/,/^}$/s|^      -\*) return 1 ;;$|      -*) shift ;;|' snap-serves-nothing-else
mutant "a failed program serves half an answer" cases_snap "$FETCH" \
  's|^  out="\$(jq -rc "\$prog" "\$file" 2>/dev/null)" \|\| return 1$|  out="$(jq -rc "$prog" "$file" 2>/dev/null)"|' snap-serves-nothing-else
mutant "a graphql read counts as a write" cases_snap "$FETCH" \
  's|^  \[ "\${1:-}" = api \] \&\& \[ "\${2:-}" = graphql \] \&\& graphql=1$|  :|' snap-graphql-read-is-not-a-write
mutant "a page that failed on a server error is not asked again" cases_snap "$FETCH" \
  's|^LANE_SNAP_RETRIES=2$|LANE_SNAP_RETRIES=0|' snap-a-server-error-on-a-page-is-asked-again
mutant "an HTML error page is not a server error" cases_snap "$FETCH" \
  "s/grep -qiE '<!doctype html|<html' && return 0/false/" snap-a-server-error-on-a-page-is-asked-again
mutant "a GraphQL timeout is not a server error" cases_snap "$FETCH" \
  's|test("Something went wrong")|test("nothing matches this")|' snap-a-server-error-on-a-page-is-asked-again
mutant "the page retry is unbounded" cases_snap "$FETCH" \
  's|^      if \[ "\$tries" -lt "\$LANE_SNAP_RETRIES" \] \&\& lane_snap_page_transient|      if [ "$tries" -lt 9 ] \&\& lane_snap_page_transient|' snap-a-server-error-every-time-is-bounded-and-named
mutant "an exhausted retry stops saying it was a server error" cases_snap "$FETCH" \
  's|a server error on each of|it failed on each of|' snap-a-server-error-every-time-is-bounded-and-named
mutant "a rate limit reads as blind again" cases_snap "$FETCH" \
  "s/grep -q 'HTTP 429' \"\$err\" || grep -q 'RATE_LIMITED'/false \&\& grep -q x/" read-cause-names-a-quota-refusal-not-blind
mutant "the retry time stops coming from the refusing window" cases_snap "$FETCH" \
  's|\[ "\${remaining:-}" = 0 \] \&\& \[\[ "\${reset:-}" =~|false \&\& [[ "${reset:-}" =~|' read-cause-names-a-quota-refusal-not-blind
mutant "a missing permission reads as a rate limit" cases_snap "$FETCH" \
  "s/grep -q 'HTTP 403' \"\$err\" \&\& grep -qi 'rate limit' \"\$err\"/grep -q 'HTTP 403' \"\$err\"/" read-cause-names-a-quota-refusal-not-blind

mutant "a call waits however long the window is" cases_retry "$FETCH" \
  's|^LANE_RETRY_MAX_WAIT=90$|LANE_RETRY_MAX_WAIT=99999|' retry-not-past-the-cap
mutant "a secondary limit is retried at once" cases_retry "$FETCH" \
  '/secondary rate limit/,/return 0/s|printf 60|printf 0|' retry-secondary-once-after-a-minute
mutant "a primary limit ignores the reset" cases_retry "$FETCH" \
  's|^    printf .%s. "\$((reset - now + 1))"$|    printf 60|' retry-primary-waits-for-the-reset
mutant "a window with quota left is waited out to its reset" cases_retry "$FETCH" \
  's|^  if \[ "\${remaining:-}" = 0 \] && |  if |' retry-quota-left-after-a-minute
mutant "the retry's wait asks rate_limit again" cases_retry "$FETCH" \
  's|^  w="\$(lane_hdr_window "\$hdr")"$|  w="$(command gh api rate_limit --jq .x 2>/dev/null)"|' retry-primary-waits-for-the-reset
mutant "a CR is kept on a header value" cases_retry "$FETCH" \
  "s|^  tr -d '\\\\r' <\"\\\$1\" [|] awk|  awk|; s|^    }'\$|    }' \"\$1\"|" retry-wait-from-a-crlf-refusal
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
  's/) \[ -n "\$graphql" \] || return 0 ;;$/) ;;/' write-never-reaches-the-network
mutant "a refused write is written down as a read" cases_core "$FETCH" \
  '/^  if lane_gh_mutates "\$@"; then$/a\    printf . >>"$LANE_RECORD/seq"; : >"$LANE_RECORD/1.args"' write-never-recorded
mutant "a head whose walk asked for a write is replayed all the same" cases_core "$FETCH" \
  '/^lane_gh_record() {$/,/^}$/s|^    : >"\$LANE_RECORD/diverged"$|    :|' write-never-replayed
mutant "two jobs can take one head" cases_core "$FETCH" \
  '/^lane_fetch_claim() {$/,/^}$/{s|^  \[ ! -e "\$1.claim" \] \|\| return 1$|  :|;s|^  (set -C && : >"\$1.claim") 2>/dev/null \|\| return 1$|  : >"$1.claim"|}' claim-is-exclusive
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
  '/^lane_fetch_claim() {$/,/^}$/{s|^  \[ ! -e "\$1.claim" \] \|\| return 1$|  :|;s|^  (set -C && : >"\$1.claim") 2>/dev/null \|\| return 1$|  : >"$1.claim"|}' every-head-claimed-once
mutant "a claim that is not exclusive lets every racing job win it" cases_spawn "$FETCH" \
  '/^lane_fetch_claim() {$/,/^}$/{s|^  \[ ! -e "\$1.claim" \] \|\| return 1$|  :|;s|^  (set -C && : >"\$1.claim") 2>/dev/null \|\| return 1$|  : >"$1.claim"|}' racing-claims-have-one-winner
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
fx graphql '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}'
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

# --- the quota guard, end to end (#1543) -------------------------------------
#
# The guard decides from the headers of the lane's own newest answer. The first
# pass has none, so it makes ONE real read and decides from that. Three runs of
# the whole driver: the serial run above, where the answers report plenty; one
# whose answers report 10 left; and one whose answers carry no headers at all.
guard_runs() { # <scripts-dir> <tag-suffix>
  GH_STUB_REMAINING=10 lane_run "$1" 1 "exhausted$2"
  GH_STUB_NO_HEADERS=1 lane_run "$1" 1 "noheaders$2"
}

# <plenty-run-tag> <exhausted-run-tag> <no-headers-run-tag>
cases_guard() {
  local rc p="$WORK/run.$1" x="$WORK/run.$2" n="$WORK/run.$3"
  grep -q '^lane: quota at pass start: remaining=4990 of limit=5000 used=10 resets=.*, from the lane.s newest API answer (allow:above-floor' "$p/log" \
    && ! grep -q 'SKIPPED, not idle' "$p/log" && [ "$(grep -cx "repos/$REPO" "$p/calls")" -eq 1 ]
  say guard-plenty-continues $?
  grep -q "SKIPPED, not idle — the merge App's shared API quota is at 10 of 5000, under the floor of 500" "$x/log" \
    && [ "$(grep -vc '^$' "$x/calls")" -eq 1 ] && [ "$(grep -cx "repos/$REPO" "$x/calls")" -eq 1 ]
  say guard-exhausted-stops $?
  grep -q "SKIPPED, not idle — no answer from the GitHub API carried the merge App's quota headers" "$n/log" \
    && grep -q '^lane: quota at pass start: unknown' "$n/log" && [ "$(grep -vc '^$' "$n/calls")" -eq 1 ]
  say guard-no-header-holds $?
  if grep -q '^RATE_LIMIT' "$p/calls" "$x/calls" "$n/calls"; then rc=1; else rc=0; fi
  say guard-never-asks-rate-limit "$rc"
}

guard_runs "$real" ''
tally_lines "$(cases_guard serial exhausted noheaders 2>&1)" 4 "quota guard"
if [ "$FAIL" -gt 0 ]; then
  echo '--- run on an exhausted quota ---'
  cat "$WORK/run.exhausted/log"
  echo '--- run with no quota headers ---'
  cat "$WORK/run.noheaders/log"
fi

# <description> <file-name> <sed-program> <id>
guard_mutant() {
  local desc="$1" name="$2" prog="$3" id="$4" dir out
  dir="$(scripts_copy guard)"
  if ! sed "$prog" "$dir/$name" >"$dir/$name.m" 2>/dev/null; then
    bad "the mutation program is not valid sed, so it asserts nothing: $desc"
    return
  fi
  if cmp -s "$dir/$name.m" "$dir/$name"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    return
  fi
  mv "$dir/$name.m" "$dir/$name"
  lane_run "$dir" 1 plenty.m
  guard_runs "$dir" .m
  out="$(cases_guard plenty.m exhausted.m noheaders.m 2>/dev/null)"
  if [ "$(printf '%s\n' "$out" | grep -cxF -- "FAIL $id")" -eq 1 ]; then ok; else bad "mutation not detected by '$id': $desc"; fi
}
guard_mutant "the first pass starts without a real answer to decide from" merge-lane.sh \
  's|^    gh api "repos/\$R" --jq .\.id. >/dev/null 2>\&1 [|][|] true$|    :|' guard-plenty-continues
guard_mutant "an exhausted window does not stop the pass" merge-lane-decision.sh \
  's|^  elif \[ "\$remaining" -lt "\$floor" \]; then$|  elif false; then|' guard-exhausted-stops
guard_mutant "no headers is read as plenty" merge-lane.sh \
  's|^    hold:\*)$|    hold:never)|' guard-no-header-holds

echo
if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane-fetch: $FAIL failed, $PASS passed, $SKIP skipped"
  exit 1
fi
echo "merge-lane-fetch: $PASS checks pass, $SKIP skipped"
