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

# The anchor is now a call to this repository's own published workflow rather
# than seventy-five lines the adopter copies, and RUNNER7 is what makes that
# call reviewable: the gate cannot read a remote callee, so the acceptance is
# declared beside the call, against an issue. Drop the declaration and the check
# has to re-arm — otherwise the example teaches an unreviewed remote call.
mutate RUNNER7 "the remote-reusable declaration beside the anchor call is dropped" \
  '/^# remote-reusable-allowed(/d'

# --- 3. and the ref it teaches can be pasted into a repository that runs our
#        own pin gate --------------------------------------------------------
#
# This check used to demand `@v5`, and it was wrong (#351). `PIN1` in
# `check-action-pins.sh` — published here, copied into every consumer — rejects
# a tag outright, so the example was teaching a line that could not be green
# anywhere it was meant to be pasted. Three adoptions hit it before the
# contradiction was noticed, and it was ours, not theirs.
#
# `docs-pins.selftest.sh` now holds the same shape across every tracked `*.md`.
# It cannot see this file — its scope is `git ls-files -- '*.md'` — so the
# convention holds here only because this check holds it.
#
# The ageing objection the old text raised is answered by the comment rather
# than by the ref. PIN1 requires a version comment precisely so Dependabot can
# rewrite the pin: seven repositories copy this file, and in each of them a
# superseded SHA arrives as a reviewable pull request instead of sitting
# silently — which is more than a floating tag ever reported.
# EVERY reference to this repository, not just the anchor's. The example also
# teaches the `shared-infra-db` action, and a tag there fails PIN1 in exactly
# the same way — one checked line beside one unchecked line is the shape that
# lets the unchecked one rot.
example_refs=0
example_bad=0
while IFS= read -r line; do
  example_refs=$((example_refs + 1))
  # `grep -c … >/dev/null` rather than `grep -q`, per PFR3: the reader ends the
  # pipeline and its status is the answer, and `-q` exits on the first match,
  # killing the in-process writer with EPIPE under pipefail.
  printf '%s\n' "$line" \
    | grep -cE 'ci-runner-infra/\.github/(actions|workflows)/[A-Za-z0-9._/-]+@[0-9a-f]{40}([[:space:]]|$)' >/dev/null \
    || { example_bad=$((example_bad + 1)); continue; }
  printf '%s\n' "$line" \
    | grep -cE '@[0-9a-f]{40}.*#[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+' >/dev/null \
    || example_bad=$((example_bad + 1))
done < <(grep -E 'ci-runner-infra/\.github/(actions|workflows)/[A-Za-z0-9._/-]+@' "$EXAMPLE" | grep -v '^[[:space:]]*#')

if [ "$example_refs" -eq 0 ]; then
  bad "the example references this repository nowhere — the anchor call is the point of the file, so this check just stopped asserting anything"
elif [ "$example_bad" -ne 0 ]; then
  bad "$example_bad of $example_refs reference(s) to this repository in the example are not a 40-character SHA with a version comment (PIN1 in check-action-pins.sh rejects a tag, and every consumer runs that gate, so the line as written cannot be pasted anywhere it is meant to go)"
else
  ok
fi

# And the workflow it names has to exist here, under that exact path, or the
# example teaches a call to nothing. The gate cannot check a remote callee by
# design — but this callee is not remote from here.
if [ -r "$REPO_ROOT/.github/workflows/shared-infra-anchor.yml" ]; then
  ok
else
  bad "the example calls .github/workflows/shared-infra-anchor.yml and this repository does not have it — every adopter's anchor job would fail to resolve"
fi

# EVERY DEGRADE BRANCH PUBLISHES EVERY OUTPUT.
#
# The anchor exits from six places, and a caller reads the outputs from a job
# that has already gone green — so an output a branch forgot is not a failure
# there, it is the literal string `null` arriving in whatever job consumed it,
# minutes later, in a matrix expression that cannot be read from the anchor's
# log. That is why `addr` and `pg` have always been published empty rather than
# omitted, and it is why `pinned` and `slots` are positional arguments to
# `publish` rather than optional ones.
#
# Positional is not enforcement on its own — bash does not check arity — so this
# gate counts the arguments statically and moves the discovery to review time.
ANCHOR="$REPO_ROOT/.github/workflows/shared-infra-anchor.yml"
calls=0
short=0
while IFS= read -r line; do
  calls=$((calls + 1))
  # Argument count with every $(…) and "…" collapsed to a single token first,
  # so a jq program full of spaces counts as the one argument it is.
  # shellcheck disable=SC2016  # sed programs, matched literally against the anchor's text
  n=$(printf '%s\n' "$line" \
    | sed -e 's/\$([^)]*)/A/g' -e 's/"[^"]*"/A/g' -e 's/^[[:space:]]*publish[[:space:]]*//' \
    | tr -s ' ' '\n' | grep -c '.')
  [ "$n" -ge 5 ] || short=$((short + 1))
done < <(grep -E '^[[:space:]]*publish[[:space:]]+' "$ANCHOR")

if [ "$calls" -eq 0 ]; then
  bad "the anchor publishes its outputs nowhere — either the helper was renamed or this check stopped asserting anything"
elif [ "$short" -ne 0 ]; then
  bad "$short of $calls publish() call(s) in the anchor pass fewer than 5 arguments: a degrade branch that omits one hands the caller the literal string 'null' for that output, which fails in the consuming job long after the anchor went green"
else
  ok
fi

printf 'shared-infra example: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
