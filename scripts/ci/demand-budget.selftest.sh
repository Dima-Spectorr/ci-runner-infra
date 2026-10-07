#!/usr/bin/env bash
# The two rules that decide whether a bounded demand sweep can still overrun the
# watchdog window — asserted against the DEPLOYED text, extracted from the files
# that ship it, never a copy pasted in here.
#
# Both were review findings on the fix for the restart loop, and both are the
# same class of mistake: a bound that looks like a bound but is not one.
#
#   * a call was allowed to START inside the budget, so the last call of an
#     exhausted sweep could spend a whole curl timeout beyond it — a 90s budget
#     authorised ~180s of demand work and ate the watchdog reserve;
#   * the slow-tick alert threshold was the constant 150, while the watchdog
#     window is max(300, poll_interval_seconds * 10) — so a pool polling every
#     60s (600s window) would page for healthy 200s ticks, and the documented
#     remedy of raising the poll interval would not clear it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTRL="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"
ALERTS="$ROOT/scripts/ci/ensure-alert-policies.sh"

# shellcheck disable=SC1090
source <(sed -n '/^budget_allows_call()/,/^}/p' "$CTRL")
# shellcheck disable=SC1090
source <(sed -n '/^is_iso8601()/,/^}/p' "$CTRL")
# shellcheck disable=SC1090
source <(sed -n '/^watchdog_threshold()/,/^}/p' "$ALERTS")

pass=0; fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
  else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1)); fi
}
verdict() { budget_allows_call "$1" "$2" "$3" && echo start || echo skip; }

# ── the call must fit, not merely start ──────────────────────────────────────
# now=100, deadline=200, timeout=30: 70s of room, the call fits.
check "a call that fits is started" start "$(verdict 100 200 30)"

# The finding itself: 29s of budget left, a 30s timeout. The old rule started
# this call because now < deadline, and it ran 1s past the deadline plus 29.
check "a call that would overrun the deadline is skipped" skip "$(verdict 171 200 30)"

# Exactly fits — allowed, or a budget that is a whole multiple of the timeout
# would waste its last slot.
check "a call that exactly fits is started" start "$(verdict 170 200 30)"

check "past the deadline, nothing starts" skip "$(verdict 201 200 30)"
check "at the deadline, nothing starts" skip "$(verdict 200 200 30)"

# ── a job-age gauge must not measure the age of midnight ─────────────────────
#
# jq writes `-` into a stamp column when a run has no job in that state, because
# a tab-separated field cannot be empty. The stamp loops used to hand every word
# straight to `date -d` and trust its exit status to reject the rest.
#
# It does not reject it. This is the whole finding, asserted against the real
# binary rather than described: if a later reader ever wonders why the shape
# test is there, this line answers it.
midnight=$(date -u -d "$(date -u +%Y-%m-%d)" +%s)
for junk in - 0 Z; do
  check "date accepts '$junk' and calls it midnight — hence the shape test" \
    "$midnight" "$(date -u -d "$junk" +%s 2>/dev/null || echo rejected)"
  check "the shape test rejects '$junk'" reject \
    "$(if is_iso8601 "$junk"; then echo accept; else echo reject; fi)"
done
check "a real GitHub instant is accepted" accept \
  "$(if is_iso8601 2026-08-29T00:00:06Z; then echo accept; else echo reject; fi)"
# A fractional-second or offset form is still an instant, and both must pass or
# a valid stamp is silently dropped and the pool reads as having no demand.
# GitHub emits neither today, which is exactly why they are asserted: a later
# tightening of the guard would otherwise break them the day a producer starts.
for good in 2026-08-29T00:00:06+03:00 2026-08-29T00:00:06-05:30 \
            2026-08-29T00:00:06.123Z  2026-08-29T00:00:06.123456789+03:00; do
  check "accepted: $good" accept \
    "$(if is_iso8601 "$good"; then echo accept; else echo reject; fi)"
done

# The zone is required, not optional. `date -d` reads a zoneless timestamp in
# the controller's local time and a trailing-junk one by ignoring the junk —
# both are a silently wrong age rather than a rejected token, which is the same
# failure the sentinel caused and the reason the shape test exists at all.
for bad in 2026-08-29 2026-08-29T00:00:06 2026-08-29T00:00:06Zjunk \
           2026-08-29T00:00:06.Z 2026-08-29T00:00:06+3:00 26-08-29T00:00:06Z; do
  check "rejected: $bad" reject \
    "$(if is_iso8601 "$bad"; then echo accept; else echo reject; fi)"
done

# Both loops, because both were wrong in the same way: the queued-stamp loop
# pegged ci_queue_wait_seconds_max and the in-progress one pegged
# ci_job_running_seconds_max, each to seconds-since-UTC-midnight, on every pool,
# every day (#518). D_WAIT is a high-water mark, so the sentinel does not join
# the real samples — it buries them.
# shellcheck disable=SC2016  # the $s is the text being matched, not an expansion
guarded=$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -c 'is_iso8601 "\$s" || continue')
check "both stamp loops guard the token before parsing it" 2 "$guarded"

# ── the alert threshold follows the watchdog window ──────────────────────────
check "default poll: floor applies" 300 "$(watchdog_threshold 20)"
check "a fast poll cannot lower the window below the floor" 300 "$(watchdog_threshold 5)"
check "a 60s poll widens the window to 600s" 600 "$(watchdog_threshold 60)"
# The false page from the review: 200s ticks on a 60s poll are healthy, and a
# fixed 150s threshold pages for them.
check "a 600s window derives 480s, not a fixed 150s" 480 "$(( $(watchdog_threshold 60) * 4 / 5 ))"
# Four fifths and not half, which is what shipped first. Half a 300s window is
# 150s, and a tick of 150s on a 20s poll is the middle of the healthy range —
# measured over a week, every incident this raised peaked at 179s against a
# window nothing came near exhausting. The alert is meant to be the precursor to
# the watchdog restarting the controller, so it has to sit close enough to the
# window to mean that, and still leave a full tick of warning.
check "the default window warns at 240s, not at 150s" 240 "$(( $(watchdog_threshold 20) * 4 / 5 ))"

# ── structural: the tested text is the shipped text ──────────────────────────
# A grep for a literal line of shell: the $(…) and "$VAR" inside these patterns
# are the text being searched for, not expansions — hence single quotes.
found() { if grep -qF "$2" "$1"; then echo yes; else echo no; fi; }

# shellcheck disable=SC2016
check "the controller uses the tested budget rule" yes \
  "$(found "$CTRL" 'budget_allows_call "$(date +%s)" "$deadline" "$CURL_MAX_TIME"')"

# shellcheck disable=SC2016
check "the alert script uses the tested threshold rule" yes \
  "$(found "$ALERTS" 'WATCHDOG_THRESHOLD="$(watchdog_threshold "$POLL")"')"

# shellcheck disable=SC2016
check "the slow-tick threshold is four fifths of the window" yes \
  "$(found "$ALERTS" 'SLOW_TICK=$(( WATCHDOG_THRESHOLD * 4 / 5 ))')"

# The two thresholds that must follow the POOL's own configuration rather than a
# literal. A pool may widen either grace — Windows is FORCED to, the module
# floors register_grace_seconds at 1200 there — and a fixed threshold then fires
# at half the boot time the pool is configured to permit, on every cold start,
# forever. Both derive from the value passed in, plus one alignment window.
# shellcheck disable=SC2016
check "the queue threshold follows register_grace_seconds" yes \
  "$(found "$ALERTS" 'QUEUE_WAIT=$(( REGISTER_GRACE + 300 ))')"
# shellcheck disable=SC2016
check "the idle threshold follows drain_grace_seconds" yes \
  "$(found "$ALERTS" 'IDLE_THRESHOLD=$(( DRAIN_GRACE + 300 ))')"

# Neither may be spent as a literal in the policy body: an interpolated
# threshold that some later edit pins back to a number is the same bug with the
# derivation still sitting above it, looking correct.
check "no policy hard-codes the old 600s queue threshold" yes \
  "$(if grep -q '"thresholdValue": 600\.0' "$ALERTS"; then echo no; else echo yes; fi)"
check "no policy hard-codes the old 1200s idle threshold" yes \
  "$(if grep -q '"thresholdValue": 1200\.0' "$ALERTS"; then echo no; else echo yes; fi)"

# Idle time alone does not mean a host should have gone: a pull request pinned
# to a host holds it warm on purpose and reports exactly the idle seconds of one
# the drain loop forgot. The pairing is the whole alert, and it has to be
# AND_WITH_MATCHING_RESOURCE — plain AND would let a pin on one pool silence a
# genuinely stuck host on another.
check "the idle policy pairs idle time with the pin holds" yes \
  "$(if sed -n '/pool not scaling to zero/,/^EOF/p' "$ALERTS" \
      | grep 'ci_pin_holds_honoured' >/dev/null; then echo yes; else echo no; fi)"
check "the idle policy matches the two conditions per resource" yes \
  "$(if sed -n '/pool not scaling to zero/,/^EOF/p' "$ALERTS" \
      | grep '"combiner": "AND_WITH_MATCHING_RESOURCE"' >/dev/null; then echo yes; else echo no; fi)"
# A policy naming a descriptor this script never declares is rejected 404 on a
# project where no host has published that series yet, and the run defers it.
check "the paired metric is declared as a descriptor" yes \
  "$(found "$ALERTS" 'ensure_descriptor ci_pin_holds_honoured')"

# Renaming a policy without this lookup does not rename anything: the inventory
# is keyed on displayName, the old policy stops matching, and the run creates a
# second one beside it — old thresholds still live, still notifying, no longer
# reachable from the file. Both policies renamed in this change need a row.
check "the sync loop can find a policy under its former name" yes \
  "$(if sed -n '/^for key in heartbeat/,/^done/p' "$ALERTS" \
      | grep 'former=' >/dev/null; then echo yes; else echo no; fi)"
for old in "CI runners / queue starved (job waiting 10m)" \
           "CI runners / pool not scaling to zero (idle host 20m)"; do
  check "the former name is still looked up: ${old##*/ }" yes \
    "$(if grep -qF "$old" "$ALERTS"; then echo yes; else echo no; fi)"
done

# The deadline must cover the run-list calls too — starting it after them was
# how the budget came to authorise twice its own value.
if sed -n '/^collect_demand()/,/^}/p' "$CTRL" \
   | awk '/deadline=\$\(\(sweep_start \+ DEMAND_BUDGET\)\)/{d=NR} /actions\/runs\?status=queued/{r=NR} END{exit !(d && r && d < r)}'; then
  check "the budget starts before the run-list calls" yes yes
else
  check "the budget starts before the run-list calls" yes no
fi

# A skipped count left over from a previous tick reads as "demand is still
# truncated" forever, so it resets with the other counters, not after the loop.
if sed -n '/^collect_demand()/,/^}/p' "$CTRL" \
   | awk '/DEMAND_RUNS_SKIPPED=0/{z=NR} /\[ -n "\$ids" \] \|\| return 0/{e=NR} END{exit !(z && e && z < e)}'; then
  check "the skipped counter resets before every early return" yes yes
else
  check "the skipped counter resets before every early return" yes no
fi

# ── corpses are aged out server-side, not just uncounted ─────────────────────
#
# A wedged run stays `queued` forever and no API call clears it. The jq filter
# stops them being counted; it cannot stop them filling the 50-run page and
# pushing real queued work off it, which reads as demand 0 rather than as
# truncation. Measured 2026-08-27: IntegrateIT 31 queued, 26 of them corpses.

qline=$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -F 'actions/runs?status=queued')
# shellcheck disable=SC2016  # the $ is the text being matched, not an expansion
check "the queued run list is filtered by creation date" yes \
  "$(case "$qline" in *'$demand_since_q'*) echo yes ;; *) echo no ;; esac)"

# An in-progress run is legitimately older than the window — a long build can
# still have a job that started a minute ago — so this list must NOT be filtered.
ipline=$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -F 'actions/runs?status=in_progress')
check "the in-progress run list is NOT filtered by creation date" yes \
  "$(case "$ipline" in *created=*) echo no ;; *) echo yes ;; esac)"

# The cutoff is the same constant the jq filter uses, or the two disagree about
# which runs are corpses and the fetch drops one the counter still expects.
# shellcheck disable=SC2016
check "the cutoff is derived from DEMAND_MAX_AGE" yes \
  "$(found "$CTRL" 'date -u -d "@$((sweep_start - DEMAND_MAX_AGE))"')"

# gh_api hands the path to curl verbatim, so `>=` and the timestamp's colons
# have to be encoded here or the query is silently malformed.
ds=$(date -u -d "@0" +%Y-%m-%dT%H:%M:%SZ)
check "the cutoff is URL-encoded" "&created=%3E%3D1970-01-01T00%3A00%3A00Z" \
  "&created=%3E%3D${ds//:/%3A}"

# ── the sweep fetches in parallel, and does it safely ────────────────────────
#
# WHY THIS BLOCK EXISTS. The sweep spent its budget one round trip at a time, so
# the runs a tick could examine was DEMAND_BUDGET / round-trip rather than the
# runs the repository had. Measured on ci-runner-host-iit, 2026-08-30, at 21 of
# 21 runners busy: ci_demand_runs_skipped between 6 and 24 on every tick of a
# two-hour window while ci_demand reported 5-13, so the autoscaler sized the
# pool against roughly half its demand and PR jobs queued 3-12 minutes. Nothing
# was red: demand was a number, it was non-zero, and the pool was the size that
# number implied.
#
# Parallel fetching is easy to get subtly wrong in ways that are also not red,
# which is what each check below is for.

# The clamp is a pure function precisely so it can be exercised here rather than
# against a metadata server.
source <(sed -n '/^clamp_fetch_concurrency()/,/^}/p' "$CTRL")
check "an unset fetch concurrency falls back to 8"  8  "$(clamp_fetch_concurrency "")"
check "a non-numeric fetch concurrency falls back"  8  "$(clamp_fetch_concurrency "eight")"
# 0 is the value that would make the sweep fetch nothing and report demand 0
# for ever — the failure the fan-out exists to end, reintroduced through its
# own knob.
check "zero is clamped up, never honoured"          1  "$(clamp_fetch_concurrency 0)"
check "a sane value is passed through"              12 "$(clamp_fetch_concurrency 12)"
check "the rate-limit ceiling is enforced"          32 "$(clamp_fetch_concurrency 500)"

# gh_api writes every response to ONE fixed pair of paths. Two of those running
# at once do not fail — they hand each other's body back, which is a wrong
# demand count with nothing red anywhere. The concurrent path must therefore use
# the caller-named variant.
# Every needle below is a literal excerpt of controller-startup.sh, so a `$` is
# the character being searched for and a trailing `\` is the line continuation
# that excerpt ends on — both are quoted exactly on purpose.
# shellcheck disable=SC2016,SC1003
check "the fan-out uses the fork-safe fetch, not gh_api" yes \
  "$(found "$CTRL" 'gh_api_fetch "$tok" "repos/$REPO_FULL/actions/runs/$id/jobs?per_page=100" \')"
check "the fork-safe fetch never writes the shared body path" yes \
  "$(if sed -n '/^gh_api_fetch()/,/^}/p' "$CTRL" | grep 'STATE_DIR/api\.' >/dev/null; then echo no; else echo yes; fi)"
# A partially written body from a killed curl read as a job list is a silently
# short demand count, so the payload is renamed into place only on success.
# shellcheck disable=SC2016
check "the fetch renames into place rather than writing in place" yes \
  "$(if sed -n '/^gh_api_fetch()/,/^}/p' "$CTRL" | grep 'mv -f "\$dest.part" "\$dest"' >/dev/null; then echo yes; else echo no; fi)"

# gh_token caches the installation token in globals, and a global set inside a
# background subshell dies with it. A fan-out that called it would read the App
# private key out of Secret Manager and mint a token once per branch, per tick,
# for ever.
check "the fork-safe fetch takes the token as an argument" yes \
  "$(if sed -n '/^gh_api_fetch()/,/^}/p' "$CTRL" | grep 'gh_token' >/dev/null; then echo no; else echo yes; fi)"
# shellcheck disable=SC2016
check "the token is resolved once, in the parent" yes \
  "$(found "$CTRL" 'tok=$(gh_token) || { rm -rf "$jobs_dir"; return 0; }')"

# A bare `wait` blocks on every background job this process owns, including the
# liveness responder, so each pid is waited on by name.
check "the sweep waits on named pids, never bare" yes \
  "$(if sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -E '^\s*wait\s*$' >/dev/null; then echo no; else echo yes; fi)"
# shellcheck disable=SC2016
check "every batch is drained before the next starts" yes \
  "$(found "$CTRL" 'for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done')"

# Fetching in parallel moves the tick's cost from the network to jq. A repo busy
# enough to fill the fetch phase can hand the counting loop more payloads than
# the budget covers, and a payload fetched but never counted is under-reported
# demand exactly like one never fetched.
if sed -n '/phase 2: COUNT/,/^}/p' "$CTRL" \
   | awk '/budget_allows_call/{b=NR} /skipped=\$\(\(skipped \+ 1\)\)/{s=NR} END{exit !(b && s && b < s)}'; then
  check "the counting phase is bounded by the same deadline" yes yes
else
  check "the counting phase is bounded by the same deadline" yes no
fi

# A leftover payload from a previous tick is the next tick's answer for a run it
# skipped: stale demand presented as fresh, which is worse than the truncation
# it hides. Cleared on the way in AND on the way out — the way out alone leaves
# a controller killed mid-sweep seeding the next one.
if sed -n '/^collect_demand()/,/^}/p' "$CTRL" \
   | awk '/jobs_dir="\$STATE_DIR\/demand-jobs"/{d=NR} /rm -rf "\$jobs_dir"/{if(!f)f=NR} END{exit !(d && f && d < f)}'; then
  check "the payload directory is cleared before the sweep" yes yes
else
  check "the payload directory is cleared before the sweep" yes no
fi
# shellcheck disable=SC2016
check "the payload directory is cleared after the sweep" yes \
  "$(if [ "$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -c 'rm -rf "\$jobs_dir"')" -ge 2 ]; then echo yes; else echo no; fi)"

# ── the GitHub budget is measured, and measuring it changes nothing (#1486) ──
#
# Every repository of one App installation shares one hourly budget, and
# neither the real limit nor the real cost of a tick had been read off a
# response. The functions below are the SHIPPED text, extracted and run against
# a stubbed transport. Three properties matter and each has failed silently
# somewhere in this repository before:
#
#   * a missing header must publish NOTHING — a gauge reading 0 remaining is the
#     alarm, and a response without the header is not one;
#   * a 304 must hand back exactly the body the 200 returned, or the demand
#     sweep quietly reads a different run list than GitHub holds;
#   * none of it may fail the call it rides on.
yn() { if "$@"; then echo yes; else echo no; fi; }

# A subject that extracts to nothing defines nothing, and every assertion after
# it would then run against a function that does not exist — or, worse, against
# a stub. Each one is checked for a body before it is trusted.
for fn in gh_rate_fields gh_rate_note gh_rate_summarise gh_rate_tick_summary \
          queue_github_rate_series gh_etag_read gh_etag_store gh_api gh_api_fetch; do
  src=$(sed -n "/^${fn}() {/,/^}/p" "$CTRL")
  check "extracted a real body for $fn" yes \
    "$(if [ "$(printf '%s\n' "$src" | grep -c .)" -ge 3 ]; then echo yes; else echo no; fi)"
  eval "$src"
done

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
STATE_DIR="$W/state"
# Read only inside the eval'd functions, which no static reader can see.
# shellcheck disable=SC2034
LOG=/dev/null
# shellcheck disable=SC2034
CURL_TIMEOUTS=()
# shellcheck disable=SC2034
CYCLE_SECONDS=""
gh_token() { printf 'stub-token'; }
event() { printf '%s\n' "$4" >>"$W/events"; }
queue_series() { printf '%s=%s\n' "$1" "$2" >>"$W/series"; }
fresh() { rm -rf "$W/state" "$W/calls" "$W/events" "$W/series"; mkdir -p "$W/state"; : >"$W/calls"; : >"$W/events"; : >"$W/series"; }

# The transport. `rate` answers with all four headers, `bare` with none, `dead`
# with no response at all (curl's own exit, no header file written). A request
# whose If-None-Match equals the current validator is answered 304 with NO body.
STUB_MODE=rate STUB_BODY='' STUB_ETAG='' STUB_LIMIT=5000 STUB_REM=4990 STUB_USED=10 STUB_RESET=1700000000
curl() {
  local a prev="" out="" dump="" inm="" url="" status=200
  for a in "$@"; do
    case "$prev" in
      -o) out="$a" ;;
      -D) dump="$a" ;;
      -H) case "$a" in "If-None-Match: "*) inm="${a#If-None-Match: }" ;; esac ;;
    esac
    prev="$a"
    url="$a"
  done
  printf '%s\t%s\n' "$url" "$inm" >>"$W/calls"
  [ "$STUB_MODE" = dead ] && return 7
  if [ -n "$inm" ] && [ "$inm" = "$STUB_ETAG" ]; then status=304; fi
  if [ -n "$dump" ]; then
    {
      printf 'HTTP/2 %s\r\n' "$status"
      if [ -n "$STUB_ETAG" ]; then printf 'ETag: %s\r\n' "$STUB_ETAG"; fi
      if [ "$STUB_MODE" = rate ]; then
        printf 'X-RateLimit-Limit: %s\r\nX-RateLimit-Remaining: %s\r\n' "$STUB_LIMIT" "$STUB_REM"
        printf 'X-RateLimit-Used: %s\r\nX-RateLimit-Reset: %s\r\n' "$STUB_USED" "$STUB_RESET"
      fi
      printf '\r\n'
    } >"$dump"
  fi
  if [ "$status" != 304 ] && [ -n "$out" ]; then printf '%s' "$STUB_BODY" >"$out"; fi
  printf '%s' "$status"
}
ledger() { cat "$STATE_DIR/gh-rate.ledger" 2>/dev/null | tr '\n' '|'; }

# --- the headers are captured on the GET paths, not only on the two writes ----
fresh
STUB_BODY='{"runs":1}'
check "gh_api still returns the body" '{"runs":1}' "$(gh_api "repos/o/r/actions/runners")"
check "gh_api notes the four rate headers of its response" \
  "200 5000 4990 10 1700000000|" "$(ledger)"

fresh
STUB_REM=4321 STUB_USED=679
gh_api_fetch stub-token "repos/o/r/actions/runs/1/jobs" "$W/state/job-1"
check "the fork-safe fetch notes them too" "200 5000 4321 679 1700000000|" "$(ledger)"
check "the fork-safe fetch still delivers its payload" '{"runs":1}' "$(cat "$W/state/job-1" 2>/dev/null)"
check "the fork-safe fetch leaves no header file beside the payload" no \
  "$(yn test -e "$W/state/job-1.hdr")"

# A call that never got a response writes no header file. The previous call's
# file must not be read as its answer: that would republish a `remaining` from
# a request that succeeded as the state of one that could not connect.
fresh
STUB_REM=4990 STUB_USED=10
gh_api "repos/o/r/a" >/dev/null
STUB_MODE=dead
gh_api "repos/o/r/b" >/dev/null
STUB_MODE=rate
check "a call with no response notes no headers, not the previous call's" \
  "200 5000 4990 10 1700000000|000 - - - -|" "$(ledger)"

# --- a missing header publishes nothing; a present one publishes ------------
fresh
STUB_MODE=bare
gh_api "repos/o/r/a" >/dev/null
STUB_MODE=rate
check "a response without rate headers is noted as absent, never as 0" "200 - - - -|" "$(ledger)"
gh_rate_tick_summary
queue_github_rate_series
check "missing headers publish the counts and NO rate gauge" \
  "ci_github_requests=1 ci_github_not_modified=0" "$(tr '\n' ' ' <"$W/series" | sed 's/ $//')"

# The positive control: without it the check above passes for a publisher that
# publishes nothing at all.
fresh
gh_api "repos/o/r/a" >/dev/null
gh_api "repos/o/r/b" >/dev/null
gh_rate_tick_summary
# shellcheck disable=SC2034
CYCLE_SECONDS=23
queue_github_rate_series
CYCLE_SECONDS=""
check "present headers publish limit, remaining, both counts and the cycle" \
  "ci_github_requests=2 ci_github_not_modified=0 ci_github_rate_limit=5000 ci_github_rate_remaining=4990 ci_cycle_seconds=23" \
  "$(tr '\n' ' ' <"$W/series" | sed 's/ $//')"
check "the summary consumes the ledger, so a tick is not counted twice" no \
  "$(yn test -e "$STATE_DIR/gh-rate.ledger")"

# No ledger at all is "not measured", which is not the same as zero requests.
fresh
gh_rate_tick_summary
queue_github_rate_series
check "a tick with no ledger publishes nothing rather than zeros" "" "$(cat "$W/series")"

# --- a 304 returns the stored body, and only a named call is conditional -----
fresh
STUB_ETAG='W/"abc123"' STUB_BODY='{"workflow_runs":[{"id":7}]}'
first=$(gh_api "repos/o/r/actions/runs?status=queued&created=1" runs-queued)
# The server would send something else if it were asked unconditionally; a 304
# carries no body, so anything but the stored one here is a wrong run list.
STUB_BODY='{"workflow_runs":[]}'
second=$(gh_api "repos/o/r/actions/runs?status=queued&created=2" runs-queued)
second_rc=$?
check "the first named call sends no validator" "" "$(sed -n 1p "$W/calls" | cut -f2)"
check "the second sends the stored validator as If-None-Match" 'W/"abc123"' "$(sed -n 2p "$W/calls" | cut -f2)"
check "a 304 is noted as a 304" 304 "$(sed -n 2p "$STATE_DIR/gh-rate.ledger" | cut -d' ' -f1)"
check "a 304 succeeds" 0 "$second_rc"
check "a 304 returns exactly the body the 200 returned" "$first" "$second"
check "…and that body is the real one" '{"workflow_runs":[{"id":7}]}' "$second"

gh_api "repos/o/r/actions/runs?per_page=100&status=queued" >/dev/null
check "an unnamed call is never conditional, whatever is stored" "" "$(sed -n 3p "$W/calls" | cut -f2)"
gh_api "repos/o/r/actions/runs?status=in_progress" runs-in-progress >/dev/null
check "one call's validator is not sent on another's" "" "$(sed -n 4p "$W/calls" | cut -f2)"

# The list changed: a new validator, a new body, and the store follows.
STUB_ETAG='W/"def456"' STUB_BODY='{"workflow_runs":[{"id":8}]}'
third=$(gh_api "repos/o/r/actions/runs?status=queued&created=3" runs-queued)
STUB_BODY='{"workflow_runs":[]}'
fourth=$(gh_api "repos/o/r/actions/runs?status=queued&created=4" runs-queued)
check "a changed list is returned fresh" '{"workflow_runs":[{"id":8}]}' "$third"
check "…and the next 304 returns the NEW stored body" "$third" "$fourth"

# A validator read back from disk becomes a request header. One that is not
# shaped like a validator is dropped, and the call goes out unconditional.
printf 'x\r\nX-Injected: 1' >"$STATE_DIR/etag-runs-queued.etag"
check "a malformed stored validator is not sent" "" "$(gh_etag_read runs-queued)"
STUB_ETAG='' STUB_BODY='{"runs":1}'

# --- are 304s billed? the arithmetic the tick's one event reports ------------
cat >"$W/ledger" <<'LEDGER'
200 5000 4990 10 1700
304 5000 4990 10 1700
304 5000 4989 11 1700
304 - - - -
200 5000 4980 20 1700
LEDGER
check "304s are split into used-advanced, used-flat and not-comparable" \
  "5 3 1 1 1 5000 4980" "$(gh_rate_summarise "$W/ledger")"

# The window rolled over mid-tick: the new window's numbers are the budget now,
# and the old one's low-water mark would read as an exhausted installation.
printf '200 5000 12 4988 1700\n200 5000 4999 1 5300\n200 5000 12 4988 1700\n' >"$W/ledger"
check "limit and remaining come from the latest window" "3 0 0 0 0 5000 4999" "$(gh_rate_summarise "$W/ledger")"

fresh
printf '200 5000 4990 10 1700\n304 5000 4990 10 1700\n304 5000 4989 11 1700\n' >"$STATE_DIR/gh-rate.ledger"
gh_rate_tick_summary
check "a tick that saw 304s writes exactly one event" 1 "$(grep -c . "$W/events")"
check "…and it says how many advanced the used counter" yes \
  "$(yn grep -q 'advanced across 1, did not advance across 1, not comparable 0' "$W/events")"
check "the 304 count is what gets published" 2 "$GH_RATE_NOT_MODIFIED"
fresh
printf '200 5000 4990 10 1700\n' >"$STATE_DIR/gh-rate.ledger"
gh_rate_tick_summary
check "a tick with no 304 writes no event" 0 "$(grep -c . "$W/events")"

# --- none of it may fail the call ------------------------------------------
# The ledger path is a DIRECTORY, so every append is refused.
fresh
mkdir "$STATE_DIR/gh-rate.ledger"
out=$(gh_api "repos/o/r/a")
check "an unwritable ledger does not fail gh_api" "0 {\"runs\":1}" "$? $out"
check "an unwritable ledger does not fail the note" 0 "$(gh_rate_note 200 /nonexistent; echo $?)"
gh_rate_tick_summary
check "an unreadable ledger does not fail the summary, and publishes nothing" "0 []" "$? [$GH_RATE_REQUESTS]"

# --- the full cycle is measured start to start -------------------------------
cycle_out=$(
  CLOCK=1000
  date() { printf '%s\n' "$CLOCK"; }
  beat() { :; }
  collect_runners() { return 0; }
  collect_demand() { :; }
  collect_outcomes() { :; }
  collect_parked() { :; }
  collect_apply_build() { :; }
  pool_select() { :; }
  tick_pool() { :; }
  queue_controller_series() { :; }
  queue_outcome_series() { :; }
  flush_series() { :; }
  flush_events() { :; }
  gh_rate_tick_summary() { :; }
  # shellcheck disable=SC2034
  BLIND_TICKS=0 POOLS=(a) LAST_TICK_START=0
  eval "$(sed -n '/^tick() {/,/^}/p' "$CTRL")"
  tick
  printf '[%s]' "$CYCLE_SECONDS"
  CLOCK=$((CLOCK + 137))
  tick
  printf '[%s]' "$CYCLE_SECONDS"
)
check "the first tick has no cycle; the second measures start to start" "[][137]" "$cycle_out"

# --- structural: the tested text is wired where it is tested -----------------
check "the queued run list is conditional" yes \
  "$(case "$qline" in *'$demand_since_q" runs-queued '*) echo yes ;; *) echo no ;; esac)"
check "the in-progress run list is conditional" yes \
  "$(case "$ipline" in *'per_page=50" runs-in-progress '*) echo yes ;; *) echo no ;; esac)"
# The re-run page is deliberately NOT conditional in this change: the task is
# the two status lists, and the third call has its own spelling for that reason.
rrline=$(sed -n '/^collect_demand()/,/^}/p' "$CTRL" | grep -F 'actions/runs?per_page=100&status=queued')
check "the re-run page is found, and left unconditional" yes \
  "$(case "$rrline" in *'status=queued" 2>/dev/null)'*) echo yes ;; *) echo no ;; esac)"

# EVERY call path: a function that talks to api.github.com and notes nothing is
# a path whose requests are spent and never counted.
unnoted=$(awk '
  /^[a-z_]+\(\) \{/ { fn = $1; url = 0; note = 0; next }
  /^[[:space:]]*#/ { next }
  fn != "" && /"https:\/\/api\.github\.com\// { url++ }
  fn != "" && /gh_rate_note / { note++ }
  /^\}/ { if (fn != "" && url > 0) { seen++; if (note < url) printf "%s ", fn }; fn = "" }
  END { printf "seen=%d", seen }' "$CTRL")
check "every function that calls GitHub notes its requests (nine of them)" "seen=9" "$unnoted"

if sed -n '/^tick() {/,/^}/p' "$CTRL" \
   | awk '/gh_rate_tick_summary/{s=NR} /queue_controller_series/{q=NR} END{exit !(s && q && s < q)}'; then
  check "the ledger is summarised before the tick's series are queued" yes yes
else
  check "the ledger is summarised before the tick's series are queued" yes no
fi
check "the controller series include the GitHub spend" yes \
  "$(if sed -n '/^queue_controller_series() {/,/^}/p' "$CTRL" | grep -qx '  queue_github_rate_series'; then echo yes; else echo no; fi)"

echo "demand-budget selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
