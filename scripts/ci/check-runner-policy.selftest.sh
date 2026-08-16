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

# --- the mutations -----------------------------------------------------------

mutate() { # <description> <sed-program> — the gate's fixture suite must FAIL
  local desc="$1" prog="$2" tmp
  tmp="$WORK/mutant.sh"
  sed "$prog" "$GATE" >"$tmp"
  # A sed program that matches nothing leaves the gate intact, the suite passes,
  # and the case would read as "mutation not detected" — or, worse, a program
  # whose replacement still contains the original text would read as detected
  # while nothing changed. Either way the assertion was never made, so refuse to
  # score a case whose file is byte-identical to the gate.
  if cmp -s "$tmp" "$GATE"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    rm -f "$tmp"
    return
  fi
  if gate_suite_passes "$tmp"; then
    bad "mutation not detected: $desc"
  else
    ok
  fi
  rm -f "$tmp"
}

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
  's@grep -qiE "^(${WINDOWS_LABEL})$"@grep -qE "^(${WINDOWS_LABEL})$"@'

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

printf 'check-runner-policy self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
