#!/usr/bin/env bash

# Self-test for the `run:` block of `.github/workflows/shared-infra-anchor.yml`.
#
# The anchor never runs in this repository (its only trigger is
# `workflow_call`), so until now its branches were checked only as TEXT:
# `check-shared-infra-example.sh` counts `publish` arguments. PR priority
# (#1533) adds behaviour a text check cannot see — which events add
# `background`, how wide a background run may fan out, and the unpinned
# fallback when a host has no background slot to spare — and every one of those
# breaks SILENTLY in a consumer:
#
#   * `background` on a pull_request run pins PR jobs to the lower slots and
#     undoes the priority it exists for;
#   * `background` missing on a push run lets push fan-out fill the top slots
#     again (measured 2026-10-10: PR shards waited up to 192s);
#   * a background run that pins a host with no usable background slot pins
#     every consumer to a host nothing can schedule them on.
#
# So the block is extracted exactly as GitHub would run it and executed against
# stubs: `ci-pin-hold` (answers from STUB_PIN and records that it was called)
# and `docker` (no-op). `jq` is real, because the arrays are built with it.
# Every case reads $GITHUB_OUTPUT, which is what a consumer reads.
#
# Then the argument is made the other way: each mutation of the workflow must
# turn at least one case red, or the case that should catch it asserts nothing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANCHOR="$HERE/../../.github/workflows/shared-infra-anchor.yml"
[ -r "$ANCHOR" ] || { echo "FAIL: cannot find the anchor at $ANCHOR"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

if ! WORK="$(mktemp -d)" || [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "FAIL: could not create a temporary directory"
  exit 1
fi
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat >"$WORK/bin/ci-pin-hold" <<'EOF'
#!/usr/bin/env bash
: >"$STUB_PIN_CALLED"
printf 'pinned=%s\n' "${STUB_PIN:-1}"
EOF
cat >"$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/ci-pin-hold" "$WORK/bin/docker"

# The `run: |` block of the `up` step, de-indented. The block is the last thing
# in the file; stop at the first non-blank line indented less than the block
# body in case a step is ever added after it.
extract() { # <workflow> <out>
  awk '
    /^        run: \|[[:space:]]*$/ { inrun = 1; next }
    inrun && /^[[:space:]]*$/ { print ""; next }
    inrun && !/^          / { exit }
    inrun { print substr($0, 11) }
  ' "$1" >"$2"
}

# Runs the extracted block with a clean environment plus the given KEY=VALUE
# pairs; leaves the outputs in $WORK/out and whether a pin was taken in
# $WORK/pin-called.
run_anchor() { # <script> KEY=VALUE...
  local script="$1"; shift
  : >"$WORK/out"
  rm -f "$WORK/pin-called"
  env -i PATH="$WORK/bin:$PATH" HOME="${HOME:-/tmp}" \
    GITHUB_OUTPUT="$WORK/out" GITHUB_RUN_ID=4242 STUB_PIN_CALLED="$WORK/pin-called" \
    REPO_LABEL=ExampleRepo CI_PIN_TTL=90m COMPOSE_FILE_IN=ci/compose.yaml \
    COMPOSE_PROJECT_IN='' MIGRATE='' HOSTED_RUNNER=ubuntu-latest PR_NUMBER=7 \
    CI_HOST_LABEL=host-h1 CI_SHARED_INFRA_ADDR=10.0.0.2 \
    CI_SHARED_INFRA_PORT_MIN=35100 CI_SHARED_INFRA_PORT_MAX=35199 \
    CI_HOST_SLOTS=4 CI_HOST_BACKGROUND_SLOTS=3 \
    "$@" bash "$script" >"$WORK/log" 2>&1
}

out() { sed -n "s/^$1=//p" "$WORK/out"; }

# One expectation per output; prints the first mismatch and returns 1.
expect() { # <case> key=value...
  local name="$1" kv k v got; shift
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    got="$(out "$k")"
    if [ "$got" != "$v" ]; then
      printf '  %s: %s is %s, want %s\n' "$name" "$k" "${got:-<empty>}" "$v"
      return 1
    fi
  done
}

POOL='["self-hosted","linux","gcp","ExampleRepo"]'
POOL_BG='["self-hosted","linux","gcp","ExampleRepo","background"]'
PIN='["self-hosted","linux","gcp","ExampleRepo","host-h1"]'
PIN_BG='["self-hosted","linux","gcp","ExampleRepo","host-h1","background"]'

# Every case, against one workflow file. Returns non-zero on the first that
# fails; `want_fail` mode is how the mutations below reuse it.
CASES=0
suite() { # <workflow>
  local s="$WORK/anchor.sh"
  extract "$1" "$s"
  grep -c 'publish' "$s" >/dev/null || { echo "  extraction found no run block"; return 1; }
  CASES=0

  # 1. push: background everywhere, width = background slots - reserved one.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=push || { echo "  push: anchor exited non-zero: $(cat "$WORK/log")"; return 1; }
  expect push runs-on="$PIN_BG" pool="$POOL_BG" pinned=1 slots=2 pg=35100 addr=10.0.0.2 || return 1

  # 2. schedule is background too.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=schedule || { echo "  schedule: anchor exited non-zero"; return 1; }
  expect schedule runs-on="$PIN_BG" pool="$POOL_BG" pinned=1 slots=2 || return 1

  # 3. pull_request: no background anywhere; width = every slot but the reserved one.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=pull_request || { echo "  pull_request: anchor exited non-zero"; return 1; }
  expect pull_request runs-on="$PIN" pool="$POOL" pinned=1 slots=3 || return 1

  # 4. a PR run ignores the background count, even when it is too small to pin a push run.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=pull_request CI_HOST_BACKGROUND_SLOTS=1 || { echo "  pr-bg1: exited non-zero"; return 1; }
  expect pr-bg1 runs-on="$PIN" pinned=1 slots=3 || return 1

  # 5-7. a push run with no usable background slot publishes unpinned, and takes no pin.
  local bgval
  for bgval in 1 '' abc; do
    CASES=$((CASES + 1))
    run_anchor "$s" EVENT_NAME=push CI_HOST_BACKGROUND_SLOTS="$bgval" \
      || { echo "  push-bg'$bgval': exited non-zero: $(cat "$WORK/log")"; return 1; }
    expect "push-bg'$bgval'" runs-on="$POOL_BG" pool="$POOL_BG" pinned=0 slots=0 pg='' addr='' || return 1
    if [ -e "$WORK/pin-called" ]; then
      echo "  push-bg'$bgval': ci-pin-hold was called — a pin was taken that no consumer could use"
      return 1
    fi
  done

  # 8. pin-only (no compose file) on push keeps the background width.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=push COMPOSE_FILE_IN='' || { echo "  pin-only: exited non-zero"; return 1; }
  expect pin-only runs-on="$PIN_BG" pool="$POOL_BG" pinned=1 slots=2 pg='' || return 1

  # 9. another run holds the host: unpinned, still background.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=push STUB_PIN=0 || { echo "  held: exited non-zero"; return 1; }
  expect held runs-on="$POOL_BG" pool="$POOL_BG" pinned=0 slots=0 || return 1

  # 10. a host predating the contract: unpinned pool, background on push.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=push CI_HOST_LABEL='' || { echo "  old-host: exited non-zero"; return 1; }
  expect old-host runs-on="$POOL_BG" pool="$POOL_BG" pinned=0 slots=0 || return 1

  # 11. a fork gets the hosted array in BOTH runs-on and pool.
  CASES=$((CASES + 1))
  run_anchor "$s" EVENT_NAME=pull_request IS_FORK=true || { echo "  fork: exited non-zero"; return 1; }
  expect fork runs-on='["ubuntu-latest"]' pool='["ubuntu-latest"]' pinned=0 slots=0 || return 1

  # 12. the anchor job itself asks for `background` on push/schedule (static:
  #     the expression is evaluated by GitHub, not by this shell).
  CASES=$((CASES + 1))
  grep -cF "(github.event_name == 'push' || github.event_name == 'schedule') && ',\"background\"' || ''" "$1" >/dev/null \
    || { echo "  anchor runs-on: no longer adds background on push/schedule"; return 1; }
  # 13. a reservation-aware caller (#1600) lands its anchor only on a host no
  #     other run holds: `ci-unheld` joins the anchor's OWN runs-on, opt-in, and
  #     never the published pool/pinned arrays (the job's work runs on the host
  #     the anchor pinned, whatever label it carries by then).
  CASES=$((CASES + 1))
  grep -cF "inputs.require-unheld-host && ',\"ci-unheld\"' || ''" "$1" >/dev/null \
    || { echo "  anchor runs-on: require-unheld-host no longer adds ci-unheld"; return 1; }
  grep -cE '^      require-unheld-host:$' "$1" >/dev/null \
    || { echo "  the require-unheld-host input is gone"; return 1; }
  awk '/^      require-unheld-host:$/{f=1;next} f&&/^      [a-z#]/{exit} f' "$1" | grep -qE '^        default: false$' \
    || { echo "  require-unheld-host is no longer opt-in (default false)"; return 1; }
  if grep -F '"ci-unheld"' "$1" | grep -vF 'inputs.require-unheld-host' | grep -q .; then
    echo "  ci-unheld appears outside the anchor's own runs-on"; return 1
  fi
  # …and wires the new output through the job and the workflow.
  grep -cE '^      pool: \$\{\{ steps\.up\.outputs\.pool \}\}$' "$1" >/dev/null \
    || { echo "  job output 'pool' is not wired from the step"; return 1; }
  grep -cE '^        value: \$\{\{ jobs\.anchor\.outputs\.pool \}\}$' "$1" >/dev/null \
    || { echo "  workflow output 'pool' is not wired from the job"; return 1; }
  # …and hands the event to the shell (this harness sets EVENT_NAME itself, so
  # only the env line in the workflow proves the real step sees it).
  grep -cE '^          EVENT_NAME: \$\{\{ github\.event_name \}\}$' "$1" >/dev/null \
    || { echo "  the step no longer passes github.event_name as EVENT_NAME"; return 1; }
  return 0
}

# --- 1. the anchor as written passes every case --------------------------------
if msg="$(suite "$ANCHOR")"; then
  ok
else
  bad "the anchor does not behave as #1533 requires:
$msg"
  printf 'shared-infra anchor: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# --- 2. and each mutation turns a case red -------------------------------------
mutate() { # <description> <sed-program>
  local desc="$1" prog="$2" tmp="$WORK/mutant.yml"
  if ! sed "$prog" "$ANCHOR" >"$tmp"; then
    bad "sed refused the mutation, so it asserts nothing: $desc"; return
  fi
  if cmp -s "$tmp" "$ANCHOR"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"; return
  fi
  if suite "$tmp" >/dev/null; then
    bad "mutation survived — no case catches: $desc"
  else
    ok
  fi
}

# shellcheck disable=SC2016  # sed programs over the workflow's own text
{
mutate "schedule runs are not background"          's/push | schedule) background=1 ;;/push) background=1 ;;/'
mutate "no event is background"                    's/push | schedule) background=1 ;;/push | schedule) background=0 ;;/'
mutate "every event is background"                 's/ \*) background=0 ;;/ *) background=1 ;;/'
mutate "the pinned array drops background"         's/'"'"'\["self-hosted","linux","gcp",\$l,\$h\] + (if \$bg == "1" then \["background"\] else \[\] end)'"'"'/'"'"'["self-hosted","linux","gcp",$l,$h]'"'"'/'
mutate "the pool drops background"                 's/'"'"'\["self-hosted","linux","gcp",\$l\] + (if \$bg == "1" then \["background"\] else \[\] end)'"'"'/'"'"'["self-hosted","linux","gcp",$l]'"'"'/'
mutate "the pool output is never written"          "/printf 'pool=%s/d"
mutate "the unpinned fallback is removed"          's/if \[ "\$slots" -lt 1 \]; then/if false; then/'
mutate "background width ignores the reserved slot" 's/slots=\$(( 10#\$b - 1 ))/slots=$(( 10#$b ))/'
mutate "background width is the PR width"          's/slots=\$(( 10#\$b - 1 ))/slots="$(free_slots)"/'
mutate "the anchor job never asks for background"  "s/(github.event_name == 'push' || github.event_name == 'schedule') \&\& ',\"background\"' || ''/''/"
mutate "the anchor never asks for ci-unheld"        "s/inputs.require-unheld-host \&\& ',\"ci-unheld\"' || ''/''/"
mutate "the reservation-aware input is removed"     '/^      require-unheld-host:$/d'
mutate "reservation-aware routing is on by default" '/^      require-unheld-host:$/,/^        type: boolean$/s/^        default: false$/        default: true/'
mutate "the pinned array asks for ci-unheld"        's/\["self-hosted","linux","gcp",\$l,\$h\]/["self-hosted","linux","gcp",$l,$h,"ci-unheld"]/'
mutate "the job output pool is unwired"            '/^      pool: \${{ steps\.up\.outputs\.pool }}$/d'
mutate "the event never reaches the shell"         '/^          EVENT_NAME: \${{ github\.event_name }}$/d'
}

printf 'shared-infra anchor: %d passed, %d failed (%d cases per suite)\n' "$PASS" "$FAIL" "$CASES"
[ "$FAIL" -eq 0 ]
