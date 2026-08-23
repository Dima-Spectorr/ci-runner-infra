#!/usr/bin/env bash
# =============================================================================
# check-shared-infra-example.sh — keep the worked example worth copying
#
# `docs/examples/pr-shared-infra.yml` is the file seven repositories are going
# to copy when they adopt the three-rule contract (phase 7 of
# docs/adr-pr-host-affinity.md). A reference workflow nobody checks is a
# reference workflow that rots, and it rots SILENTLY: the defect ships to every
# adopter and surfaces one repository at a time, as a job failing on their pool
# for a reason that reads like their mistake.
#
# WHY "THE GATE REPORTS IT CLEAN" IS NOT ENOUGH ON ITS OWN
#
# Almost anything is clean under `--shared-infra`. A file with one hosted job is
# clean. So is an empty one, near enough. "Clean" tells you the example did not
# TRIP the rules; it does not tell you the example EXERCISES them, and an
# example that exercises nothing can drift arbitrarily far from the contract
# while this check stays green — the same failure the repository already
# answered once, for the gate's own fixtures, in
# `check-runner-policy.selftest.sh`.
#
# So the argument is made in both directions, exactly as it is there:
#
#   1. the example, unmodified, is CLEAN; and
#   2. three mutations of it are each REPORTED, with the specific rule id.
#
# Together those say the example sits ON the edge of each rule rather than
# somewhere comfortably inside it. Remove the anchor reference, add a second
# owner, or dial `localhost` on a band port, and this goes red here — before it
# can go red in a consumer that copied it.
#
# WHY THE JOBS ARE NOT RUN
#
# They cannot be, from here. This repository defines the self-hosted fleet and
# must not need the fleet to be healthy in order to fix the fleet, which is why
# every job in `.github/workflows/` is on a GitHub-hosted runner. What executes
# on every pull request to this repository is this check. The jobs execute in
# the repositories that adopt the file.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/check-runner-policy.sh"
EXAMPLE="$REPO_ROOT/docs/examples/pr-shared-infra.yml"

# The posture the example is written for, and the one phase 7 turns on in each
# consumer. `--allow-dynamic-runner` because the anchor idiom IS an expression;
# RUNNER9 is what supplies the specificity that flag gives up.
FLAGS=(--shared-infra --allow-dynamic-runner --forks=allowed)

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# Every assertion below reads the gate's output. A missing input, or a gate that
# cannot run at all, produces no output — and "no RUNNER9 in the output" would
# then score as clean. Assert the inputs exist before asserting anything of
# them.
for f in "$GATE" "$EXAMPLE"; do
  if [ ! -r "$f" ]; then
    echo "FAIL: missing $f — every check below would be vacuous"
    exit 1
  fi
done

# Hard-fail rather than degrade. An empty `WORK` writes every mutant to
# `./mutant.yml` in whatever directory this was invoked from — a file left in
# the working tree, and, worse, a `rm -rf ""` in the trap that silently removes
# nothing while the caller believes it cleaned up.
if ! WORK="$(mktemp -d)" || [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "FAIL: could not create a temporary directory — every mutation below would write into the working tree"
  exit 1
fi
trap 'rm -rf "$WORK"' EXIT

# --- 1. the example is clean --------------------------------------------------

if out="$(bash "$GATE" "${FLAGS[@]}" "$EXAMPLE" 2>&1)"; then
  ok
else
  bad "the worked example does not pass the rules it demonstrates:
$out"
  # Continuing would report mutations as "detected" by a gate that was already
  # red on the unmutated file, which asserts nothing.
  printf 'shared-infra example: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# --- 2. and it is clean at the edge -------------------------------------------

mutate() { # <rule-id> <description> <sed-program>
  local id="$1" desc="$2" prog="$3" tmp got
  tmp="$WORK/mutant.yml"
  # A `sed` that refuses its program writes an empty file, which the gate then
  # reports as a workflow with no jobs — clean, and scored as "the rule did not
  # fire" when in truth nothing was ever checked.
  if ! sed "$prog" "$EXAMPLE" >"$tmp"; then
    bad "the mutation program was refused by sed, so it asserts nothing: $desc"
    return
  fi
  # A sed program that matches nothing leaves the example intact, the gate
  # reports it clean, and the case reads as "the rule did not fire" — when in
  # truth the assertion was never made. This is how the gate's own mutation
  # suite has already broken twice, both times by pinning a pattern to
  # indentation that later moved. Refuse to score a byte-identical file.
  if cmp -s "$tmp" "$EXAMPLE"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    return
  fi
  got="$(bash "$GATE" "${FLAGS[@]}" "$tmp" 2>&1)"
  if printf '%s' "$got" | grep -c "\[$id\]" >/dev/null; then
    ok
  else
    bad "the example no longer exercises $id — $desc, and the gate still reports it clean:
$got"
  fi
}

# Rule 1, one host per pull request. The consumer stops resolving its pool from
# the anchor and names it directly, which is what every one of these workflows
# looked like before the contract: GitHub is then free to place it on a
# different host, where this run's stack does not exist.
# shellcheck disable=SC2016  # a sed program over the example's own text
mutate RUNNER9 "the test job names its pool directly instead of the anchor's output" \
  's@^    runs-on: .*fromJSON(needs\.anchor\.outputs\.runs-on).*$@    runs-on: [self-hosted, linux, gcp, ExampleRepo]@'

# Rule 2, one stack per run. A second job declares itself an owner — the shape
# this takes in real life is a second workflow, or a job that "just needs its
# own database for one test".
mutate RUNNER10 "a second job declares itself an infrastructure owner" \
  's@^# shared-infra-owner(anchor): .*$@&\n# shared-infra-owner(test): brings up a second stack@'

# Rule 3, Windows reaches the stack across the band. `localhost` on a band port
# is the Windows machine, where nothing is listening.
# shellcheck disable=SC2016  # a sed program over the example's own text
mutate RUNNER11 "the Windows job dials localhost on the band port" \
  's|postgres://ci@${{ needs.anchor.outputs.addr }}:${{ needs.anchor.outputs.pg }}|postgres://ci@localhost:35100|'

printf 'shared-infra example: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
