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
# same zero failures as one that ran everything.

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
# Prints nothing and exits 0 when the mutation was detected; prints one `FAIL: `
# line and exits 1 otherwise. That contract is what lets the parent count
# failures out of interleaved output from several workers at once.
run_case() { # <description> <sed-program>
  local desc="$1" prog="$2" work tmp
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
    printf 'FAIL: mutation changed nothing, so it asserts nothing: %s\n' "$desc"
    return 1
  fi
  if gate_suite_passes "$tmp"; then
    printf 'FAIL: mutation not detected: %s\n' "$desc"
    return 1
  fi
  return 0
}

# --- the mutations -----------------------------------------------------------
#
# One row per case: a description and the sed program that reverts one element
# of the rule. Tab-separated, and neither field may contain a tab or a newline —
# `mutate` refuses one that does rather than handing the dispatcher a row it
# would split into the wrong two halves and run as a case nobody wrote.
TAB="$(printf '\t')"

mutate() { # <description> <sed-program>
  case "$1$2" in
    *"$TAB"*)
      printf 'FAIL: case field contains a tab, which would split it wrongly: %s\n' "$1" >&2
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
  run_case "${row%%"$TAB"*}" "${row#*"$TAB"}"
  exit
fi

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

JOBS="$(nproc 2>/dev/null || echo 4)"
# `-I{}` already implies one argument per command; passing `-n1` beside it makes
# xargs warn that the two are mutually exclusive, on every run, forever.
OUT="$(seq 1 "$CASES" | xargs -P "$JOBS" -I{} bash "${BASH_SOURCE[0]}" --case {} 2>&1)"

# Counted out of the workers' interleaved output rather than out of an exit
# status: `xargs` collapses any number of failed children into one 123, and the
# summary has to say how many.
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
fi
CASE_FAIL="$(printf '%s\n' "$OUT" | grep -c '^FAIL: ')"
FAIL=$((FAIL + CASE_FAIL))
PASS=$((PASS + CASES - CASE_FAIL))

printf 'check-runner-policy self-test: %d passed, %d failed (%d case(s), %d at a time)\n' \
  "$PASS" "$FAIL" "$CASES" "$JOBS"
[ "$FAIL" -eq 0 ]
