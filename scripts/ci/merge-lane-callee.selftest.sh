#!/usr/bin/env bash
# =============================================================================
# merge-lane-callee.selftest.sh — the lane runs the release its caller pinned
#
# WHY (#1555)
#   A consumer pins `merge-lane.yml@<sha>`, and that pinned only the workflow
#   FILE. The scripts it runs were checked out at
#   `inputs.implementation-ref || github.job_workflow_sha`, the second was empty
#   in every run measured, and `actions/checkout` handed an empty ref clones the
#   DEFAULT BRANCH. So every merge to this repository's main ran in every
#   consumer's lane at once: #1552 took IntegrateIT and entity-platform down for
#   two hours through pins at v5.124.0 and v5.111.2.
#
#   The workflow now resolves the commit from the caller's own `uses:` line in
#   an inline step (it runs before any checkout, so it cannot be a script).
#   This test extracts that exact block from the workflow and runs it against a
#   stub `curl`, so what is tested is what ships.
#
#   The property that matters most is the negative one: every way of NOT
#   knowing the commit exits non-zero and writes no `sha=` output — because an
#   empty output is precisely the empty ref that clones main.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CALLEE="$ROOT/.github/workflows/merge-lane.yml"
STEP="Resolve the lane's own commit"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

# The `run: |` block of the named step, de-indented — the shell the runner gets.
extract_block() { # <workflow> <step name>
  awk -v name="$2" '
    !found && index($0, "- name: " name) { found = 1; next }
    found && !inrun && /^[ \t]+- name:/ { exit }
    found && !inrun && /^[ \t]+run: \|[ \t]*$/ { inrun = 1; next }
    inrun {
      if ($0 ~ /^[ \t]*$/) { print ""; next }
      match($0, /^[ \t]*/)
      if (!indent) indent = RLENGTH
      if (RLENGTH < indent) exit
      print substr($0, indent + 1)
    }' "$1"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BLOCK="$WORK/resolve.sh"
extract_block "$CALLEE" "$STEP" >"$BLOCK"
if ! grep -q 'GITHUB_OUTPUT' "$BLOCK"; then
  echo "FAIL: could not extract the '$STEP' run block from $CALLEE — every case below would be vacuous"
  exit 1
fi

# A stub curl: serves a caller workflow file and a tag table from the case dir,
# and records every URL it was asked for.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
printf '%s\n' "$url" >>"$CASE/urls"
case "$url" in
  */contents/*)
    [ -f "$CASE/caller.yml" ] || exit 22
    cat "$CASE/caller.yml"
    ;;
  */commits/*)
    ref="${url##*/commits/}"
    line=$(grep -E "^$ref " "$CASE/tags" 2>/dev/null) || exit 22
    printf '%s' "${line#* }"
    ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$WORK/bin/curl"

PIN_A=2c2e32da5dae9d4efd5a07f1b17d45ae836953fc
PIN_B=760c59e02d4384fe4ef50d1b1ca7c1fd8a98c163
HERE=1111111111111111111111111111111111111111

# run_case <name> <repo> <impl-ref> <workflow-ref>  (caller.yml/tags prepared in $CASE)
run_case() {
  local repo="$2" impl_ref="$3" wf_ref="$4"
  : >"$CASE/out"
  (
    export PATH="$WORK/bin:$PATH" CASE READ_TOKEN=t GITHUB_API_URL=https://api.example
    export GITHUB_REPOSITORY="$repo" GITHUB_WORKFLOW_REF="$wf_ref" GITHUB_WORKFLOW_SHA="$HERE"
    export GITHUB_OUTPUT="$CASE/out" IMPLEMENTATION_REPOSITORY=Dima-Spectorr/ci-runner-infra
    export IMPLEMENTATION_REF="$impl_ref" CALLEE_PATH=.github/workflows/merge-lane.yml
    bash "$BLOCK"
  ) >"$CASE/log" 2>&1
  echo $? >"$CASE/rc"
}

new_case() {
  CASE="$WORK/$1"
  mkdir -p "$CASE"
  : >"$CASE/urls"
}

expect_sha() { # <case name> <sha>
  local got
  got=$(cat "$CASE/out")
  if [ "$(cat "$CASE/rc")" = 0 ] && [ "$got" = "sha=$2" ]; then ok; else
    bad "$1: wanted rc=0 and sha=$2, got rc=$(cat "$CASE/rc") output '$got' log: $(tr '\n' ' ' <"$CASE/log")"
  fi
}

expect_refusal() { # <case name>
  if [ "$(cat "$CASE/rc")" != 0 ] && [ ! -s "$CASE/out" ] && grep -q '::error' "$CASE/log"; then ok; else
    bad "$1: wanted a non-zero exit, an ::error and NO sha output (an empty ref clones main); got rc=$(cat "$CASE/rc") output '$(cat "$CASE/out")'"
  fi
}

CONSUMER=Dima-Spectorr/Consumer
WF="$CONSUMER/.github/workflows/merge-lane.yml@refs/heads/main"

# 1. The common case: a sha pin, exactly as consumers write it.
new_case sha-pin
cat >"$CASE/caller.yml" <<EOF
jobs:
  lane:
    # uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@$PIN_B  (an old note)
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@$PIN_A # v5.124.0
EOF
run_case "" "$CONSUMER" "" "$WF"
expect_sha "a sha pin runs that sha (a commented-out uses: line is not a pin)" "$PIN_A"
if grep -q "/repos/$CONSUMER/contents/.github/workflows/merge-lane.yml?ref=$HERE" "$CASE/urls"; then ok; else
  bad "the caller's workflow must be read at GITHUB_WORKFLOW_SHA, the commit that ran — asked for: $(tr '\n' ' ' <"$CASE/urls")"
fi

# 2. A tag pin resolves through the API to its commit.
new_case tag-pin
printf '%s\n' "  - uses: 'dima-spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@v5.124.0'" >"$CASE/caller.yml"
printf 'v5.124.0 %s\n' "$PIN_A" >"$CASE/tags"
run_case "" "$CONSUMER" "" "$WF"
expect_sha "a quoted tag pin, owner in another case, resolves to its commit" "$PIN_A"

# 3. This repository calls itself with a local path: the commit that ran.
new_case local-path
printf '%s\n' "    uses: ./.github/workflows/merge-lane.yml" >"$CASE/caller.yml"
run_case "" Dima-Spectorr/ci-runner-infra "" "Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane-self.yml@refs/heads/main"
expect_sha "a local uses: in this repository runs GITHUB_WORKFLOW_SHA" "$HERE"

# 4. A local path in ANOTHER repository is that repository's file, not ours.
new_case local-elsewhere
printf '%s\n' "    uses: ./.github/workflows/merge-lane.yml" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "a consumer's local merge-lane.yml is not this callee"

# 5. The explicit input wins and the caller is not read.
new_case input-ref
run_case "" "$CONSUMER" "$PIN_B" "$WF"
expect_sha "implementation-ref, when set, is the commit" "$PIN_B"
if [ ! -s "$CASE/urls" ]; then ok; else bad "a sha implementation-ref needs no API read; made: $(tr '\n' ' ' <"$CASE/urls")"; fi

# --- every way of not knowing the commit refuses ---------------------------

new_case no-uses
printf '%s\n' "jobs:" "  lane:" "    runs-on: ubuntu-latest" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "a caller file with no uses: line for this workflow (an intermediate reusable workflow)"

new_case two-pins
printf '%s\n' "    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@$PIN_A" \
  "    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@$PIN_B" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "two disagreeing pins in the caller"

new_case unreadable
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "the caller's workflow file cannot be read"

new_case no-workflow-ref
printf '%s\n' "    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@$PIN_A" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" ""
expect_refusal "GITHUB_WORKFLOW_REF unset"

new_case foreign-workflow-ref
printf '%s\n' "    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@$PIN_A" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" "Someone/Else/.github/workflows/x.yml@refs/heads/main"
expect_refusal "GITHUB_WORKFLOW_REF naming another repository"

new_case unknown-tag
printf '%s\n' "    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@v0.0.0" >"$CASE/caller.yml"
: >"$CASE/tags"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "a tag that does not resolve"

new_case not-a-sha
printf '%s\n' "    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/merge-lane.yml@v9" >"$CASE/caller.yml"
printf 'v9 %s\n' "<html>not a sha</html>" >"$CASE/tags"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "a ref whose resolution is not a 40-hex sha"

if [ "$FAIL" -gt 0 ]; then
  echo "merge-lane-callee: $FAIL failed, $PASS passed"
  exit 1
fi
echo "merge-lane-callee: $PASS checks pass"
