#!/usr/bin/env bash
# Mutation self-test for RUNNER8 in `check-runner-policy.sh`.
#
# WHY THIS FILE EXISTS SEPARATELY FROM THE GATE'S OWN `--selftest`
#
# The gate already carries fixtures, and CI already runs them. What fixtures
# cannot tell you is whether they would NOTICE. A fixture asserting "this
# workflow produces RUNNER8" passes on a gate that produces RUNNER8 for the
# right reason and on a gate that produces it for the wrong one, and it keeps
# passing while the detector behind it is quietly weakened — which is the exact
# shape of failure this repository has already shipped once: a `describe
# --filter` went past fifty-one green checks because the stub under them
# accepted a flag the real tool rejects.
#
# So each mutation below reverts one element of the RUNNER8 rule in a COPY of
# the gate and asserts that the gate's own fixture suite then FAILS. A detector
# that has not been seen to fire is not a detector.
#
# WHY THE CONTROL RUN IS THE FIRST THING HERE
#
# Every assertion below is "the mutated gate fails". That sentence is also true
# of a gate that cannot run at all — a copy in a temporary directory whose
# `REPO_ROOT` resolves somewhere useless, a missing interpreter, a `mktemp` that
# is not writable. Then every mutation reads as detected and this file is a row
# of green ticks over nothing. The control proves the opposite direction first:
# an UNMUTATED copy, in the same temporary directory, run the same way, PASSES.
#
# WHY THE CASES ARE A LIST AND NOT A SEQUENCE OF CALLS
#
# Each case is one full run of the gate's seventy-fixture suite — about fifteen
# seconds — over a file nothing else touches. Run one after another that is six
# and a quarter minutes, and it was 53% of this repository's entire CI critical
# path: longer than every other gate in `ci.yml` added together. Nothing about
# the cases makes them ordered; they were sequential only because a shell
# function called once per case, in a row, is the obvious way to write them.
#
# So the cases are DATA now — `mutate` prints one tab-separated row instead of
# running one — and the parent dispatches them across the runner's cores by
# re-entering this same file with `--case N`. The case list stays the single
# source of truth for both halves, so a case cannot be added to the listing and
# missed by the runner.
#
# The count is asserted at the end for the reason every other floor in this
# repository is asserted: a dispatch loop that silently ran nothing reports the
# same zero failures as one that ran everything. And because a worker can also
# die without a word — OOM, a `bash` that will not start, a full disk — every
# case prints a verdict even when it passes, and the parent reconciles the
# verdicts it received against the cases it started. Counting only failures
# would score a batch of dead workers as a clean suite.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-runner-policy.sh"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# A mutation of a MISSING file is an empty file, whose `--selftest` fails for
# reasons that have nothing to do with the rule — and every case below would
# score green. Assert the input exists before asserting anything about it.
if [ ! -r "$GATE" ]; then
  echo "FAIL: missing $GATE — every check below would be vacuous"
  exit 1
fi

# The gate's whole fixture suite, over the copy it is handed. Output is
# discarded: this file asserts the VERDICT, and printing fifty ok-lines per
# mutation would bury the one line that matters.
gate_suite_passes() { # <path-to-a-copy-of-the-gate>
  bash "$1" --selftest >/dev/null 2>&1
}

# --- one case, as run by a worker ---------------------------------------------
#
# EVERY CASE PRINTS EXACTLY ONE VERDICT LINE — `ok   [n]` or `FAIL: [n]` — and
# that is the contract the parent audits, not merely the one it counts.
#
# Success used to print nothing, which made two states identical: a case that
# ran and passed, and a case whose worker never ran at all. `xargs` reports a
# child killed by the OOM killer, a `bash` that could not start, or a `mktemp`
# on a full disk the same way it reports a detected mutation — one exit status
# for the whole batch — so a batch in which half the workers died silently
# scored as a clean suite. One line per case makes the parent able to say "I
# started twenty-five and twenty-five answered", which is the only form of that
# assertion that survives workers dying.
run_case() { # <index> <description> <sed-program>
  local idx="$1" desc="$2" prog="$3" work tmp
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $work now: the trap outlives the local
  trap "rm -rf '$work'" EXIT
  tmp="$work/mutant.sh"
  sed "$prog" "$GATE" >"$tmp"
  # A sed program that matches nothing leaves the gate intact, the suite passes,
  # and the case would read as "mutation not detected" — or, worse, a program
  # whose replacement still contains the original text would read as detected
  # while nothing changed. Either way the assertion was never made, so refuse to
  # score a case whose file is byte-identical to the gate.
  if cmp -s "$tmp" "$GATE"; then
    printf 'FAIL: [%s] mutation changed nothing, so it asserts nothing: %s\n' "$idx" "$desc"
    return 1
  fi
  if gate_suite_passes "$tmp"; then
    printf 'FAIL: [%s] mutation not detected: %s\n' "$idx" "$desc"
    return 1
  fi
  printf 'ok   [%s] %s\n' "$idx" "$desc"
  return 0
}

# --- the mutations -----------------------------------------------------------
#
# One row per case: a description and the sed program that reverts one element
# of the rule, tab-separated.
#
# NEITHER FIELD MAY CONTAIN A TAB OR A NEWLINE, and both are refused rather than
# merely documented. A tab makes the row split into the wrong two halves, so the
# case runs with a truncated description and a sed program nobody wrote. A
# newline is worse and quieter: the row becomes TWO rows, every index after it
# shifts by one, and the count the floor and the reported-verdict audit both
# rest on stops meaning "cases". Neither is hypothetical enough to leave to a
# comment — these sed programs are edited by hand and several already span two
# source lines.
TAB=$'\t'
NL=$'\n'

mutate() { # <description> <sed-program>
  case "$1$2" in
    *"$TAB"*)
      printf 'FAIL: case field contains a tab, which would split the row wrongly: %s\n' "$1" >&2
      exit 1
      ;;
    *"$NL"*)
      printf 'FAIL: case field contains a newline, which would split it into two rows: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  printf '%s%s%s\n' "$1" "$TAB" "$2"
}

case_list() {

# 1-2. The reader stops reporting the key. This is the failure that reads
#      cleanest of all: the bash rule below is untouched and reviews as correct,
#      and it is simply never handed the fact it branches on.
mutate "the reader no longer reports container:" \
  's@            out("#CONTAINER", vid)@            pass@'
mutate "the reader no longer reports services:" \
  's@            out("#SERVICES", vid)@            pass@'

# 3. The Windows label set widens to cover the Linux pool. The gate still fires
#    on every fixture that expects RUNNER8, so only the Linux-pool-with-a-
#    container fixture can catch it — which is what that fixture is for. A rule
#    that refuses `container:` on the Linux pool is a rule consumers turn off.
mutate "the Windows label set widened to a second OS" \
  "s@^WINDOWS_LABEL='windows'\$@WINDOWS_LABEL='windows|linux'@"

# 4. The label match becomes case-sensitive. GitHub does not distinguish the
#    spellings, so `Windows` — which is how consumers actually write it — would
#    stop being a Windows pool while `windows` kept working: the rule would hold
#    for exactly half the fleet and nothing would say which half.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "the Windows label matched case-sensitively" \
  's@grep -ciE "^(${WINDOWS_LABEL})$"@grep -cE "^(${WINDOWS_LABEL})$"@'

# 5-6. One half of the disjunction dropped. Distinct from cases 1-2: there the
#      fact never arrives, here it arrives and is not read. Both halves matter
#      independently — `services:` is the one that fails at "Initialize
#      containers" before a step runs, `container:` the one a job author is most
#      likely to copy across from a Linux workflow.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "the services: half of the condition dropped" \
  's@\[ "$has_container" -eq 1 \] || \[ "$has_services" -eq 1 \]@[ "$has_container" -eq 1 ]@'
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "the container: half of the condition dropped" \
  's@\[ "$has_container" -eq 1 \] || \[ "$has_services" -eq 1 \]@[ "$has_services" -eq 1 ]@'

# 7. The finding is computed and never reported. A gate that decides correctly
#    and says nothing is indistinguishable from a clean repository, and it is
#    the state a refactor reaches by deleting one line.
mutate "the diagnostic never emitted" \
  's@        err RUNNER8 @        : RUNNER8 @'

# --- RUNNER9/10/11 -------------------------------------------------------------
# Same argument as the eight above, applied to the three rules that decide how
# many hosts and how many databases a pull request gets. Each of these is a
# plausible edit — a refactor, a "tightening" of a regex, a threshold nudged
# while debugging — and none of them changes how the gate reads.
# shellcheck disable=SC2016  # the gate's own source text, matched literally

# 8. The reader stops reporting the resolution. The bash rule is untouched and
#    reviews as correct; it is simply never handed the fact it branches on, so
#    every correctly pinned consumer in the fleet is reported as unpinned — and
#    RUNNER9 firing everywhere is how RUNNER9 gets turned off everywhere.
mutate "the reader no longer reports the anchor resolution" \
  's@out("#RUNSONNEEDS", vid, anchor)@pass@'

# 9. The resolution is read only up to the first `||`. A plain consumer still
#    passes, so most fixtures stay green — but the fleet's fork-routing idiom
#    puts the resolution in the SECOND branch, and that is the spelling every
#    consumer in a public repository writes.
mutate "the anchor resolution read only before the fork branch" \
  's@NEEDS_OUTPUT.finditer(text)@NEEDS_OUTPUT.finditer(text.split("||")[0])@'

# 10. The band regex stops covering the band. `localhost:35100` becomes a port
#     like any other, and the Windows job that cannot possibly work is reported
#     clean — RUNNER11's whole subject restored by one character class.
mutate "the loopback band regex no longer covers the band" \
  's@(35\[1-9\]\[0-9\]{2}@(95[1-9][0-9]{2}@'

# 10b. The band regex stops being case-insensitive. `LOCALHOST:35100` is the
#      same mistake in the same job, and a gate that reads one spelling and not
#      the other reports the file clean.
mutate "the loopback band match is case-sensitive again"   's@^    re.IGNORECASE,$@@'

# Indentation is deliberately not part of the two `err` patterns below, and the
# exemption pattern is not anchored to its leading spaces either. All three
# broke at once when the rules moved a nesting level, and a mutation that no
# longer applies asserts nothing while still reporting green -- the exact
# failure `mutate` exists to make loud.

# 11-12. Each finding computed and never reported. A gate that decides
#        correctly and says nothing is indistinguishable from a clean
#        repository, and it is the state a refactor reaches by deleting a line.
mutate "the RUNNER9 diagnostic never emitted" \
  's@ err RUNNER9 @ : RUNNER9 @'
mutate "the RUNNER11 diagnostic never emitted" \
  's@ err RUNNER11 @ : RUNNER11 @'

# 13. The owner threshold nudged by one. Two stacks in one run — the precise
#     thing rule 2 forbids — becomes the passing case, and nothing else changes.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "the owner count tolerates a second stack" \
  's@\[ "$owners" -gt 1 \]@[ "$owners" -gt 2 ]@'

# 14. Windows loses its exemption from RUNNER9. Rule 1's whole exception is that
#     a Windows job IS a second host, on purpose; a gate that demands it pin to
#     the Linux anchor is asking for a job that cannot run.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "Windows no longer exempt from the pinning rule" \
  's@if \[ "$windows_pool" -eq 0 \] && \[ "$pins_to_anchor" -eq 0 \]@if [ "$pins_to_anchor" -eq 0 ]@'

# 15. The exemption stops being read. Every declared exception goes red at once,
#     which is the other way a gate gets disabled: not by missing a finding, but
#     by refusing an answer the repository already argued for in writing.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "a declared exemption is no longer honoured" \
  's@if ! shared_infra_marker "$file" exempt "$job_base"; then@if true; then@'

# 16. The marker stops being bound to its job, so a marker naming ANY job in the
#     file excuses every job in it — including one added later that nobody
#     weighed against the exemption's reasoning, which is the whole reason the
#     job id is in the marker.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "the marker no longer has to name the job it excuses" \
  's@${esc}${tail}@[^)]*@'

# 17. The literal rule widened back to every quoted string. This is the
#     over-correction, and it fails a CORRECT workflow rather than passing a
#     wrong one — which is the more expensive direction: a gate that reports
#     the `'main'` in a `contains()` guard teaches the repository to pass
#     `--allow-dynamic-runner`, and the rule is gone for everything.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "every quoted string counts as a runner fallback" \
  's@(?:&&|\\|\\|)\\s\*@@'

# 18. A block-scalar indicator is only recognised at end of line, so `run: |`
#     opens a block and `run: | # note` does not. The body goes back into the
#     comment view and a marker echoed there declares an exemption again —
#     the same bypass, reachable by adding a comment to the line above it.
mutate "a commented block-scalar header no longer opens a block" \
  's@(#\.\*)?@@g'

# --- RUNNER12/13 ---------------------------------------------------------------
# The merge-queue route. RUNNER12 is a security rule whose failure is silent in
# both directions -- the workflow is green either way -- so "the detector has
# been seen to fire" is worth more here than anywhere else in this file.
#
# The SC2016 waivers below sit on each `mutate` that needs one rather than here:
# a directive applies to the next command, not to a block, and one written at the
# top of a section reads as covering the section while covering one call.

# 19. The reader stops reporting the route at all. Every rule below is untouched
#     and reviews as correct; none of them is ever handed the fact it branches
#     on, and a repository routing on the branch name alone reads as clean.
mutate "the reader no longer reports the queue route" \
  's@    out("#QUEUEREF", vid, origin)@    return@'

# 20-21. One required conjunct stops being required. Each half has its own
#        fixture because each half is a different vulnerability: without the
#        same-repo test a FORK takes the reserved pool, without the author test
#        any member of the repository does.
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "the same-repo conjunct no longer required" \
  's@  \[ "$same_repo" -eq 0 \] && missing=@  [ 1 -eq 0 ] \&\& missing=@'
# shellcheck disable=SC2016  # the gate's own source text, matched literally
mutate "the Mergify-author conjunct no longer required" \
  's@  \[ "$author" -eq 0 \] && missing=@  [ 1 -eq 0 ] \&\& missing=@'

# 22. The RUNNER12 finding is computed and never reported -- the state a
#     refactor reaches by deleting one line.
mutate "the RUNNER12 diagnostic never emitted" \
  's@        err RUNNER12 @        : RUNNER12 @'

# 23. The disjointness test always answers yes. Both pools keep their names,
#     the route keeps working, and the queue pool quietly serves ordinary pull
#     requests again -- which is the rationing the split exists to remove,
#     restored without a single label changing.
mutate "the disjointness test always answers yes" \
  's@^disjoint_scopes() {$@disjoint_scopes() { return 0;@'

# 24. Scope labels compared case-sensitively. GitHub does not distinguish
#     `Linux` from `linux`, so two spellings of ONE pool would read as two
#     pools and the superset that merges them would go unreported.
mutate "scope labels compared case-sensitively" \
  "s@    tr '\\[:upper:\\]' '\\[:lower:\\]' | grep -vxE@    cat | grep -vxE@"

}

# --- the worker entry point ---------------------------------------------------
#
# Reached only by the dispatcher below, re-entering this file. It reads its case
# out of the same list the parent counted, so the two cannot disagree about what
# case N is.
if [ "${1:-}" = "--case" ]; then
  row="$(case_list | sed -n "${2}p")"
  # An out-of-range index yields an empty row, whose two empty fields make a
  # `sed` program that changes nothing — which `run_case` reports, correctly, as
  # a case that asserts nothing. Named here anyway, because "case 26 changed
  # nothing" is a much worse clue than "there is no case 26".
  if [ -z "$row" ]; then
    printf 'FAIL: no case at index %s — the dispatcher and the list disagree\n' "$2"
    exit 1
  fi
  # `$TAB` rather than a literal tab in the source: an editor or a formatter
  # that expands one turns both expansions into no-ops, and the case then runs
  # with the whole row as its description and an empty sed program — which
  # `run_case` would report as "changed nothing", for a reason nowhere near it.
  run_case "$2" "${row%%"$TAB"*}" "${row#*"$TAB"}"
  exit
fi

# --- the shard ----------------------------------------------------------------
#
# Every case re-runs the gate's WHOLE fixture suite, and that suite spawns one
# `python3` per fixture — seventy-six interpreter startups, each importing
# PyYAML, about seventeen seconds. Twenty-five mutations plus the control paid
# that price at four-way parallelism and the step took three minutes ten, which
# was 37% of the entire CI run for this repository.
#
# So the cases are ALSO splittable across machines. `--shard I/N` runs the
# strided subset `I, I+N, I+2N, …`; the caller runs N of them at once and the
# suite finishes in the time one shard takes.
#
# `N` IS NOT WRITTEN DOWN TWICE. The caller in `ci.yml` passes GitHub's
# `strategy.job-total`, which IS the length of the matrix list, so adding or
# removing a shard cannot leave a stale total behind — the failure mode that
# would otherwise silently stop running the last shard's mutations while every
# job still reported green.
# `parse_shard <spec>` prints `I N` and returns 0, or explains itself and returns
# 1. It is a FUNCTION rather than the inline code it replaced so that the guards
# can be asserted below: testing them by re-invoking this script would, on any
# spec the guard wrongly ACCEPTS, run the whole mutation suite — and a wrongly
# accepted spec is the only case worth testing for.
parse_shard() { # <spec>
  local spec="$1" i n
  i="${spec%%/*}"
  n="${spec##*/}"
  # A malformed spec must not fall back to "run everything" — that reads as a
  # pass while N-1 shards duplicate each other and nothing says so.
  # Both numbers are required, spelled out. `--shard 4` without a slash would
  # otherwise parse as BOTH halves — shard 4 of 4 — and quietly run a quarter of
  # the mutations for a caller who believes they asked for all of them.
  case "$spec" in
    "" | *[!0-9/]* | */*/* | /* | */)
      printf 'FAIL: --shard wants I/N with both whole numbers, got: %s\n' "$spec" >&2
      return 1
      ;;
    */*) ;; # one slash, digits either side
    *)
      printf 'FAIL: --shard wants I/N, got a lone number: %s\n' "$spec" >&2
      return 1
      ;;
  esac
  # DEMAND A POSITIVE ANSWER AND READ AN ERROR AS "NO".
  #
  # `[` compares in base ten, so digit-only halves need no normalising: `08` is
  # eight here, where `$(( 08 ))` is a bad-octal error. What `[` does NOT survive
  # is a number too large for a C long — `[ 99999999999999999999 -lt 1 ]` exits 2
  # with "integer expected" rather than answering.
  #
  # This file is `set -u` without `-e`, and the previous spelling was three
  # rejections OR-ed together (`-lt 1 || -lt 1 || -gt`). All three arms erroring
  # therefore read as "no rejection matched", and the spec was ACCEPTED:
  # `--shard 1/99999999999999999999` reached awk, whose `NR % n` selected case 1
  # alone, skipped the other twenty-four, and exited green. Asking instead for
  # proof that the spec IS in range puts the error on the refusing side.
  if ! { [ "$n" -ge 1 ] && [ "$i" -ge 1 ] && [ "$i" -le "$n" ]; } 2>/dev/null; then
    printf 'FAIL: --shard %s is not a shard of a set of %s\n' "$i" "$n" >&2
    return 1
  fi
  # NORMALISE, now that both halves are known to be real integers in range.
  # `[` was the forgiving one: everything downstream reads a leading zero as
  # octal. `printf '%d' 08` is "invalid octal number" and prints 0, so an
  # accepted `08/24` would otherwise announce itself as "shard 0 of 24" in the
  # summary line — a report that contradicts the run it describes. `10#` forces
  # base ten, and cannot overflow here because the check above has already
  # refused anything `[` was unable to compare.
  printf '%s %s\n' "$((10#$i))" "$((10#$n))"
}

SHARD_I=1
SHARD_N=1
if [ "${1:-}" = "--shard" ]; then
  if ! shard_parsed="$(parse_shard "${2:-}")"; then
    exit 1
  fi
  SHARD_I="${shard_parsed%% *}"
  SHARD_N="${shard_parsed##* }"
fi

# The guard is the only thing between a typo in `ci.yml` and a run that asserts a
# fraction of the suite and reports green, so it is exercised rather than
# trusted. These cost nothing: every one of them is decided before the first
# mutation is written.
for spec in "" "4" "/4" "4/" "1/0" "0/4" "5/4" "1//4" "4/x" "1/99999999999999999999"; do
  if parse_shard "$spec" >/dev/null 2>&1; then
    bad "--shard '$spec' was accepted — a spec that does not name one shard of a real set has to be refused, or the run skips mutations and says nothing"
  else
    ok
  fi
done
for spec in "1/1" "1/6" "6/6" "08/24"; do
  if parse_shard "$spec" >/dev/null 2>&1; then
    ok
  else
    bad "--shard '$spec' was refused, and it names a real shard"
  fi
done
# The pair it returns is what every later line believes, so read it rather than
# only checking that it said yes.
for probe in "1/6=1 6" "08/24=8 24" "6/6=6 6"; do
  got="$(parse_shard "${probe%%=*}" 2>/dev/null)"
  if [ "$got" = "${probe#*=}" ]; then
    ok
  else
    bad "--shard '${probe%%=*}' parsed as '$got', not '${probe#*=}' — the run would be reported as a shard it is not"
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the control -------------------------------------------------------------

cp "$GATE" "$WORK/control.sh"
if gate_suite_passes "$WORK/control.sh"; then
  ok
else
  bad "an UNMUTATED copy of the gate fails its own fixture suite — either the gate is broken, or it cannot run from a temporary directory, and in the second case every mutation below would score as detected without asserting anything"
  # Continuing would print green ticks over a harness that cannot tell the two
  # answers apart, which is worse than reporting nothing.
  printf 'check-runner-policy self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# --- the dispatcher -----------------------------------------------------------
#
# The control has just proved the harness works, so from here the cases are
# independent runs over files nothing shares. `nproc` rather than a literal: a
# hosted runner has four cores and a fleet host has more, and hard-coding either
# number makes the file wrong on the other.
#
# A FLOOR ON THE CASE COUNT, for the same reason Pester has one in `ci.yml`. A
# refactor that leaves `case_list` emitting nothing — a stray `return`, a
# renamed helper — makes `xargs` run zero workers and this file print "N passed,
# 0 failed" over a mutation suite that asserted nothing at all.
CASES="$(case_list | wc -l)"
FLOOR=24
if [ "$CASES" -lt "$FLOOR" ]; then
  bad "the case list yielded only $CASES case(s), fewer than the $FLOOR this file is known to contain — it did not run, whatever the exit code says"
  printf 'check-runner-policy self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# The floor above is asserted on the FULL list, not on this shard's slice: the
# regression it exists to catch — `case_list` collapsing to nothing — has to be
# visible from whichever shard happens to run.
#
# A shard with no cases at all means N was raised past the number of mutations,
# and that shard would otherwise print a clean "0 of 0 answered". It is a
# misconfiguration, so it is a failure.
MINE="$(seq 1 "$CASES" | awk -v i="$SHARD_I" -v n="$SHARD_N" 'NR % n == i % n')"
SHARD_CASES="$(printf '%s' "$MINE" | grep -c . || true)"
if [ "$SHARD_CASES" -eq 0 ]; then
  bad "shard $SHARD_I of $SHARD_N drew none of the $CASES case(s) — there are more shards than mutations, so this job asserts nothing"
  printf 'check-runner-policy self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

JOBS="$(nproc 2>/dev/null || echo 4)"
# `-I{}` already implies one argument per command; passing `-n1` beside it makes
# xargs warn that the two are mutually exclusive, on every run, forever.
OUT="$(printf '%s\n' "$MINE" | xargs -P "$JOBS" -I{} bash "${BASH_SOURCE[0]}" --case {} 2>&1)"
DISPATCH_RC=$?

# The workers' interleaved verdicts, printed in full. Unlike the sequential
# version this is the ONLY record of what ran: an `ok` line names a case that
# answered, and its absence is the finding audited below.
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
fi

# Counted out of the verdict lines rather than out of an exit status, because
# `xargs` collapses any number of failed children into one 123 and the summary
# has to say how many.
CASE_OK="$(printf '%s\n' "$OUT" | grep -c '^ok   \[')"
CASE_FAIL="$(printf '%s\n' "$OUT" | grep -c '^FAIL: ')"
FAIL=$((FAIL + CASE_FAIL))
PASS=$((PASS + CASE_OK))

# THE AUDIT, and the reason every case prints even when it passes.
#
# A worker can end without a verdict: the OOM killer takes it, `bash` cannot
# start, `mktemp` finds a full disk, the runner reclaims the job's cgroup. Every
# one of those leaves `$CASE_FAIL` at zero, and counting only failures would
# then report a clean mutation suite over cases that never ran — the exact
# vacuous pass this whole file exists to make impossible one level down.
#
# So the dispatch is reconciled twice, on two independent facts. The count of
# verdicts must equal the count of cases started, and a non-zero `xargs` status
# with no failing case named is itself a finding rather than a curiosity.
#
# Reconciled against THIS SHARD'S slice rather than the full list — a shard that
# drew seven cases and heard seven verdicts is complete, and comparing it to the
# full list would redden every sharded run.
REPORTED=$((CASE_OK + CASE_FAIL))
if [ "$REPORTED" -ne "$SHARD_CASES" ]; then
  bad "the dispatcher started $SHARD_CASES case(s) and $REPORTED returned a verdict — the rest ended without one, so their mutations were never asserted, whatever the exit codes say"
fi
if [ "$DISPATCH_RC" -ne 0 ] && [ "$CASE_FAIL" -eq 0 ]; then
  bad "xargs exited $DISPATCH_RC while every case that answered was green — a worker failed for a reason it never got to print, and this run proves nothing"
fi

printf 'check-runner-policy self-test: %d passed, %d failed (shard %d of %d: %d of %d case(s) answered, %d at a time; %d case(s) in the full list)\n' \
  "$PASS" "$FAIL" "$SHARD_I" "$SHARD_N" "$REPORTED" "$SHARD_CASES" "$JOBS" "$CASES"
[ "$FAIL" -eq 0 ]
