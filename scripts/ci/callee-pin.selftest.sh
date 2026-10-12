#!/usr/bin/env bash
# =============================================================================
# callee-pin.selftest.sh — a reusable workflow runs the release its caller pinned
#
# WHY (#1555, #1556)
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
#   #1556 found the same hole in pr-guard, branch-reaper, codex-review and
#   support-windows. This test therefore covers EVERY reusable workflow in
#   .github/workflows/ that checks out a repository other than the caller's:
#   it is discovered, not listed, so a new one cannot reintroduce a default-branch
#   checkout of itself without failing here (see `discover` at the bottom).
#
#   The property that matters most is the negative one: every way of NOT
#   knowing the commit exits non-zero and writes no `sha=` output — because an
#   empty output is precisely the empty ref that clones main.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STEP="Resolve the callee's own commit"

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

# Discovery mode (no argument): find every reusable workflow, hold each to the
# structural rules, and run this script once per workflow that checks out
# another repository.
if [ $# -eq 0 ]; then
  self="${BASH_SOURCE[0]}"
  failed=0
  checked=0
  ref_sum=""
  for f in "$ROOT"/.github/workflows/*.yml; do
    grep -qE '^[[:space:]]*workflow_call:' "$f" || continue
    name=$(basename "$f")
    # A step is whatever starts at `      - ` up to the next; comments dropped.
    verdict=$(awk '
      function flush() {
        if (step ~ /uses: actions\/checkout/ && step ~ /repository:/) {
          checkouts++
          if (step !~ /(steps\.callee\.outputs\.sha|needs\.[a-z-]+\.outputs\.callee-sha) \}\}/) bad = bad " checkout-of-another-repo-without-resolved-ref"
        }
        if (step ~ /- name: Resolve the callee.s own commit/) resolver = 1
        step = ""
      }
      /^[ \t]*#/ { next }
      /job_workflow_sha/ { bad = bad " job_workflow_sha" }
      /^      - / { if (step != "") flush(); step = $0 "\n"; next }
      step != "" { step = step $0 "\n" }
      END { if (step != "") flush(); printf "%d %d%s\n", checkouts + 0, resolver + 0, bad }' "$f")
    # shellcheck disable=SC2086
    set -- $verdict
    n=$1
    has=$2
    shift 2
    if [ -n "$*" ]; then
      printf 'FAIL: %s:%s — a reusable workflow that checks out a repository must pin it to the commit its caller named, never the default branch (#1556)\n' "$name" " $*"
      failed=1
    elif [ "$n" -gt 0 ] && [ "$has" -ne 1 ]; then
      printf 'FAIL: %s checks out another repository but has no "%s" step (#1556)\n' "$name" "$STEP"
      failed=1
    elif [ "$n" -gt 0 ]; then
      checked=$((checked + 1))
      bash "$self" "$name" || failed=1
    fi
    if grep -q -- "- name: $STEP" "$f"; then
      # The resolver is inlined (it runs before any checkout, so it cannot be a
      # script): one rule, copied. The copies must be the SAME text.
      sum=$(extract_block "$f" "$STEP" | cksum)
      [ -n "$ref_sum" ] || ref_sum=$sum
      [ "$sum" = "$ref_sum" ] || {
        echo "FAIL: $name: its resolver block differs from the others (#1556)"
        failed=1
      }
    fi
  done
  if [ "$checked" -lt 5 ]; then
    echo "FAIL: discovered only $checked pinned reusable workflows, expected at least 5 — discovery is broken, so every check above is vacuous"
    failed=1
  fi
  [ "$failed" -eq 0 ] && echo "callee-pin: $checked reusable workflows pinned"
  exit "$failed"
fi

WFNAME="$1"
CALLEE="$ROOT/.github/workflows/$WFNAME"
CALLEE_PATH=".github/workflows/$WFNAME"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
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
    export GITHUB_OUTPUT="$CASE/out" IMPLEMENTATION_REPOSITORY=Example-Org/ci-runner-infra
    export IMPLEMENTATION_REF="$impl_ref" CALLEE_PATH="$CALLEE_PATH"
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

CONSUMER=Example-Org/Consumer
WF="$CONSUMER/.github/workflows/$WFNAME@refs/heads/main"

# 1. The common case: a sha pin, exactly as consumers write it.
new_case sha-pin
cat >"$CASE/caller.yml" <<EOF
jobs:
  lane:
    # uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@$PIN_B  (an old note)
    uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@$PIN_A # v5.124.0
EOF
run_case "" "$CONSUMER" "" "$WF"
expect_sha "a sha pin runs that sha (a commented-out uses: line is not a pin)" "$PIN_A"
if grep -q "/repos/$CONSUMER/contents/.github/workflows/$WFNAME?ref=$HERE" "$CASE/urls"; then ok; else
  bad "the caller's workflow must be read at GITHUB_WORKFLOW_SHA, the commit that ran — asked for: $(tr '\n' ' ' <"$CASE/urls")"
fi

# 2. A tag pin resolves through the API to its commit.
new_case tag-pin
printf '%s\n' "  - uses: 'example-org/ci-runner-infra/.github/workflows/$WFNAME@v5.124.0'" >"$CASE/caller.yml"
printf 'v5.124.0 %s\n' "$PIN_A" >"$CASE/tags"
run_case "" "$CONSUMER" "" "$WF"
expect_sha "a quoted tag pin, owner in another case, resolves to its commit" "$PIN_A"

# 3. This repository calls itself with a local path: the commit that ran.
new_case local-path
printf '%s\n' "    uses: ./.github/workflows/$WFNAME" >"$CASE/caller.yml"
run_case "" Example-Org/ci-runner-infra "" "Example-Org/ci-runner-infra/.github/workflows/merge-lane-self.yml@refs/heads/main"
expect_sha "a local uses: in this repository runs GITHUB_WORKFLOW_SHA" "$HERE"

# 4. A local path in ANOTHER repository is that repository's file, not ours.
new_case local-elsewhere
printf '%s\n' "    uses: ./.github/workflows/$WFNAME" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "a consumer's local $WFNAME is not this callee"

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
printf '%s\n' "    uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@$PIN_A" \
  "    uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@$PIN_B" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "two disagreeing pins in the caller"

new_case unreadable
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "the caller's workflow file cannot be read"

new_case no-workflow-ref
printf '%s\n' "    uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@$PIN_A" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" ""
expect_refusal "GITHUB_WORKFLOW_REF unset"

new_case foreign-workflow-ref
printf '%s\n' "    uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@$PIN_A" >"$CASE/caller.yml"
run_case "" "$CONSUMER" "" "Someone/Else/.github/workflows/x.yml@refs/heads/main"
expect_refusal "GITHUB_WORKFLOW_REF naming another repository"

new_case unknown-tag
printf '%s\n' "    uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@v0.0.0" >"$CASE/caller.yml"
: >"$CASE/tags"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "a tag that does not resolve"

new_case not-a-sha
printf '%s\n' "    uses: Example-Org/ci-runner-infra/.github/workflows/$WFNAME@v9" >"$CASE/caller.yml"
printf 'v9 %s\n' "<html>not a sha</html>" >"$CASE/tags"
run_case "" "$CONSUMER" "" "$WF"
expect_refusal "a ref whose resolution is not a 40-hex sha"

if [ "$FAIL" -gt 0 ]; then
  echo "callee-pin ($WFNAME): $FAIL failed, $PASS passed"
  exit 1
fi
echo "callee-pin ($WFNAME): $PASS checks pass"
