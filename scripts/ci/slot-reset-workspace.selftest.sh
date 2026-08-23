#!/usr/bin/env bash
# Self-test for the one slot-reset invariant that, when it broke, took the whole
# fleet down while every symptom pointed somewhere else.
#
# THE BUG (2026-08-23). `slot-reset.sh started` wipes `_work` and recreates each
# entry it removed as an EMPTY directory, so a step that chdirs into one does not
# land on a path that stopped existing. It recreated ONE level. The directory the
# runner actually hands a step is `$RUNNER_WORKSPACE/<repo>` — `_work/<repo>/<repo>`
# — which is two.
#
# Nothing noticed, because on an ordinary job `actions/checkout` recreates the
# workspace in the first step. The job that pays is the one this hook DELIBERATELY
# fails — a slot whose previous job never reached its completed hook:
#
#   fail_after ends the job before any step runs   nothing recreates the workspace
#   job-completed is launched IN that directory    it cannot start at all
#   only job-completed writes the clean marker     the marker is never written
#   the next job finds no marker                   and fails itself, identically
#
# A hook written to cost one job cost the slot forever. Nine slots across three
# hosts were dead, every open pull request was red, and each rerun landed on a
# different poisoned slot — which reads exactly like flake and is its opposite.
#
# WHY THIS TEST IS BEHAVIOURAL. The repo's other host-startup checks are
# structural, and a structural check is what this bug walked past: the code said
# "recreate the directory", a reviewer read that as "recreate the chdir target",
# and both sentences are true of a script that recreates the wrong depth. So this
# one EXTRACTS the generated hook and RUNS it, then asks the filesystem.
#
# Case 2 re-breaks the hook the way it was broken before and asserts this test
# goes red. A test that only passes on correct input is not evidence.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/host-startup.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

[ -f "$SCRIPT" ] || {
  echo "FAIL: missing $SCRIPT"
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Extract the hook the host actually installs.
#
# By its heredoc marker, never by line number: this file sits beside a 4000-line
# script under active edit, and a line range would drift into testing whatever
# moved into it. The body is an UNQUOTED heredoc, so `eval`-ing it back through
# `cat <<EOF` reproduces the host's own expansion exactly — the `\$` escapes stay
# runtime variables, the four path settings below get baked in, and what comes out
# is byte-for-byte what root runs, with different paths.
# ---------------------------------------------------------------------------
extract_body() { # <script> -> heredoc template on stdout
  awk '
    /cat >\/opt\/ci\/job-hooks\/slot-reset\.sh <<EOF/ { grab = 1; next }
    grab && /^EOF$/                                   { exit }
    grab                                              { print }
  ' "$1"
}

BODY="$TMP/body.tmpl"
extract_body "$SCRIPT" >"$BODY"
[ -s "$BODY" ] || {
  echo "FAIL: could not find the slot-reset.sh heredoc in $SCRIPT"
  exit 1
}

# The slot index is deliberately absurd. The hook hard-codes a `/home/ci-s<digits>`
# shape check on the home it is about to empty, and this test runs ON a slot host,
# where `/home/ci-s0` … `/home/ci-s7` are real slots with real jobs in them. An
# index no host will ever have means the home step operates on a path that does
# not exist: it fails, harmlessly, and the reset carries on to `_work`, which is
# the part under test. Nothing here can reach a live slot.
IDX=987654

render_hook() { # <template> <slot-root> -> path to a runnable hook
  local tmpl="$1" out="$2/hook.sh"
  # A subshell, so the four names below are scoped to this expansion and cannot
  # leak into the next case's. They are plain assignments rather than a prefix on
  # `eval`, because a prefix on a BUILTIN is exactly the shape whose scope differs
  # between shells and modes — and the whole point here is to reproduce the host's
  # expansion faithfully, not to be terse about it.
  (
    SLOT_ROOT="$2/slots"
    SLOT_STATE="$2/state"
    SLOT_TEMPLATE="$2/template"
    SLOT_USER_PREFIX="ci-s"
    PIN_DIR="$2/pin"
    export SLOT_ROOT SLOT_STATE SLOT_TEMPLATE SLOT_USER_PREFIX PIN_DIR
    eval "cat <<EOF
$(cat "$tmpl")
EOF"
  ) >"$out" 2>/dev/null
  chmod 0755 "$out"
  printf '%s\n' "$out"
}

# Shims. The hook runs as root on a host; here it runs as whoever invoked the
# test, so the three things only root can do are answered rather than performed.
# `install` keeps doing its real job — creating the directories this test is
# entirely about — with just the ownership flags dropped.
make_shims() { # <dir>
  local d="$1/shims"
  mkdir -p "$d"
  cat >"$d/getent" <<SHIM
#!/usr/bin/env bash
# Only ever asked for the slot user's passwd entry.
[ "\${1:-}" = passwd ] || exit 2
printf 'ci-s%s:x:12345:12345::/home/ci-s%s:/bin/bash\n' "$IDX" "$IDX"
SHIM
  cat >"$d/chown" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
  cat >"$d/install" <<'SHIM'
#!/usr/bin/env bash
# Drop -o/-g and their values; pass everything else to the real install.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -g) shift 2 ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
exec /usr/bin/install "${args[@]}"
SHIM
  chmod 0755 "$d"/*
  printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
# A slot in the state that poisons it: a previous job died mid-run, so `_work`
# holds a real two-level workspace, and no clean marker was ever written.
# ---------------------------------------------------------------------------
setup_slot() { # <root>
  local r="$1"
  # `.reset/<idx>` is the root-owned holding directory the reset renames `_work`
  # into for the duration. provision_slot_user creates it at boot; without it the
  # `mv -T` fails, the reset does nothing at all, and every assertion below would
  # be reading the fixture back to itself.
  mkdir -p "$r/template" "$r/state/$IDX" "$r/pin" "$r/slots/.reset/$IDX"
  mkdir -p "$r/slots/$IDX/_work/IntegrateIT/IntegrateIT/src"
  mkdir -p "$r/slots/$IDX/_work/_temp" "$r/slots/$IDX/_work/_actions" "$r/slots/$IDX/_work/_tool"
  echo 'a previous job left this' >"$r/slots/$IDX/_work/IntegrateIT/IntegrateIT/src/leftover.txt"
  # No $r/state/$IDX/clean — that absence IS the poisoned state.
}

run_started() { # <root> -> exit code of the hook, output on stdout
  local r="$1" hook shims
  hook="$(render_hook "$BODY" "$r")"
  shims="$(make_shims "$r")"
  SUDO_UID=12345 PATH="$shims:$PATH" bash "$hook" started 2>&1
}

# ---------------------------------------------------------------------------
# Case 1 — the regression itself.
# ---------------------------------------------------------------------------
R1="$TMP/case1"
mkdir -p "$R1"
setup_slot "$R1"
OUT1="$(run_started "$R1")"
RC1=$?

WS="$R1/slots/$IDX/_work/IntegrateIT/IntegrateIT"

# The hook is expected to FAIL this job — that is its whole purpose on a slot with
# no marker — so a non-zero exit is the correct outcome, not a problem.
if [ "$RC1" -ne 0 ]; then ok; else bad "a slot with no clean marker must still fail the job that starts on it"; fi

case "$OUT1" in
*"was not left clean"*) ok ;;
*) bad "the reset did not take the poisoned path; it said: $OUT1" ;;
esac

# THE ASSERTION. job-completed is launched with this as its working directory. If
# it is absent the hook cannot start, the marker is never written, and the slot is
# dead for every job after this one.
if [ -d "$WS" ]; then ok; else bad "the job-completed hook's working directory $WS was not recreated"; fi

# Recreated EMPTY. The directory belongs to the next job; its contents belonged to
# the last one, and one of the things this reset exists to stop is the next job
# reading them.
if [ -e "$WS/src" ] || [ -e "$WS/src/leftover.txt" ]; then
  bad "the previous job's workspace content survived the reset"
else ok; fi

# Depth 1 is recreated too, and `_temp` is deliberately spared at 'started' — the
# runner writes this hook's own invocation into it.
if [ -d "$R1/slots/$IDX/_work/_tool" ]; then ok; else bad "_tool was not recreated"; fi
if [ -d "$R1/slots/$IDX/_work/_temp" ]; then ok; else bad "_temp must survive a 'started' reset"; fi

# ---------------------------------------------------------------------------
# Case 2 — break it back, and prove this test notices.
#
# The mutation is the bug as it shipped: recreate the entry, and nothing beneath
# it. If case 1 can pass against this, case 1 is asserting nothing.
# ---------------------------------------------------------------------------
MUT="$TMP/body.mutant.tmpl"
sed '/install -d -o "\\\$u" -g "\\\$u" -m 0755 "\\\$e\/\\\$sub"/,+1d' "$BODY" >"$MUT"

# -F, and worth a line: the template holds `"\$e/\$sub"` with the dollars escaped
# for the heredoc, so a pattern written as `\$e/\$sub` looks right and matches
# nothing — it reads the backslash as the escape it is not. Both counts then come
# back 0 and the guard passes while asserting the mutation never applied.
if [ "$(grep -cF 'e/\$sub' "$MUT")" -eq 0 ] && [ "$(grep -cF 'e/\$sub' "$BODY")" -gt 0 ]; then
  ok
else
  bad "the mutation did not apply — case 2 would pass without testing anything"
fi

R2="$TMP/case2"
mkdir -p "$R2"
setup_slot "$R2"
hook2="$(render_hook "$MUT" "$R2")"
shims2="$(make_shims "$R2")"
SUDO_UID=12345 PATH="$shims2:$PATH" bash "$hook2" started >/dev/null 2>&1

if [ -d "$R2/slots/$IDX/_work/IntegrateIT/IntegrateIT" ]; then
  bad "the depth-1-only hook recreated a depth-2 workspace — this test cannot detect the regression"
else
  ok
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '✓ slot-reset self-test: a failed job costs one job, not the slot (%d check(s)).\n' "$PASS"
  exit 0
fi
printf '✗ slot-reset self-test: %d of %d check(s) failed.\n' "$FAIL" "$((PASS + FAIL))"
exit 1
