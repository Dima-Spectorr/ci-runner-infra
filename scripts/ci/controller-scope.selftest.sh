#!/usr/bin/env bash
# The controller runs under `set -euo pipefail`, so a variable that is in scope
# in one function and not in another is not a style question — it is a crash.
#
# WHY THIS EXISTS (2026-08-14, v5.1.5)
#
# v5.1.4 introduced `sweep_start` as a local of collect_demand and, in the same
# edit, a global replace rewrote `now=$(date +%s)` to `now=$sweep_start`
# EVERYWHERE — including gh_token() and idle_seconds(), which have no such local.
# Under `set -u` gh_token then died on every call, so the controller could not
# mint an installation token, could not list runners, and every tick was blind:
# 36 consecutive blind ticks across all seven pools, scale-in suspended fleet
# wide, while the heartbeat published 1 and `systemctl` said active. Terraform
# applied it, the module validated, shellcheck passed, and every existing
# self-test passed, because all of them read the text and none of them RAN it.
#
# So this one runs it. Each function below is extracted from the shipping file
# and executed under the controller's own flags with only the globals the
# controller has actually set at that point. A function that reads a variable
# belonging to some other function's scope fails here instead of in the fleet.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTRL="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"

pass=0; fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
  else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

fn() { sed -n "/^$1() {/,/^}/p" "$CTRL"; }

# run_fn <function> <call> [pre-set globals...]
# Runs the extracted function under set -u with stubbed side effects, and
# reports ok / the shell's own error. An unbound variable surfaces verbatim.
run_fn() {
  local name="$1" call="$2"; shift 2
  local out
  out=$(
    bash -c "
      set -uo pipefail
      $(printf '%s\n' "$@")
      $(fn "$name")
      $call >/dev/null 2>&1 || true
    " 2>&1
  )
  if [ -z "$out" ]; then echo ok; else echo "$out" | head -1; fi
}

# ── the crash itself ─────────────────────────────────────────────────────────
# gh_token with a live cached token takes the early-return path and must not
# reach for any clock it does not own.
check "gh_token computes its own clock" ok \
  "$(run_fn gh_token 'gh_token' \
      'GH_TOKEN=tok' 'GH_TOKEN_EXPIRY=99999999999' 'LOG=/dev/null' \
      'log() { :; }' 'md() { echo x; }')"

# idle_seconds on the busy path returns before touching the disk, so nothing
# but its own clock is in play.
check "idle_seconds computes its own clock" ok \
  "$(run_fn idle_seconds 'idle_seconds host 1' 'STATE_DIR=/tmp')"

# ── the scope rule, stated once ──────────────────────────────────────────────
# The static half, and the general form of the bug: a function that READS a name
# which is someone else's local, declares no local of its own for it, and is
# never assigned at file scope. Catches the next global replace even in a
# function this self-test does not execute. Same-named locals in two functions
# are fine — that is not sharing, it is two independent variables.
check "no function reads another function's local" "" "$(python3 - "$CTRL" <<'PY'
import re, sys

src = open(sys.argv[1], encoding='utf-8').read().split('\n')

funcs, cur, body = {}, None, []
globals_assigned = set()
for line in src:
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{', line)
    if m:
        cur, body = m.group(1), []
        continue
    if cur is not None:
        if line == '}':
            funcs[cur] = body
            cur = None
        else:
            body.append(line)
    else:
        g = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=', line)
        if g:
            globals_assigned.add(g.group(1))

def locals_of(body):
    names = set()
    for line in body:
        m = re.match(r'\s*local\s+(.*)', line)
        if m:
            for tok in m.group(1).split():
                names.add(tok.split('=')[0].strip('";'))
    return names

owned = {f: locals_of(b) for f, b in funcs.items()}
all_locals = set().union(*owned.values()) if owned else set()

leaks = []
for f, body in funcs.items():
    mine = owned[f]
    for i, line in enumerate(body):
        if line.lstrip().startswith('#'):
            continue
        # `\$x` is text this function WRITES (the watchdog heredoc), and a
        # single-quoted span is not shell expansion at all (jq's own `$n`).
        # Neither is a read of anyone's variable.
        scan = re.sub(r"'[^']*'", "''", line.replace('\\$', ''))
        for ref in re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', scan):
            if ref in all_locals and ref not in mine and ref not in globals_assigned:
                leaks.append(f'{f}: ${ref} ({line.strip()})')
print('\n'.join(sorted(set(leaks))))
PY
)"

# ── the field that made the outage unreadable ────────────────────────────────
# `X=$(gh_api …)` runs gh_api in a subshell, so GH_HTTP_STATUS never reaches the
# caller: the blind-tick log line printed `status=` for 36 ticks straight.
grep -q 'printf .%s. "$status" >"$STATE_DIR/api.status"' "$CTRL" \
  && r=yes || r=no
check "gh_api persists its status past the subshell" yes "$r"

grep -q 'RUNNER_LIST_STATUS="$(cat "$STATE_DIR/api.status"' "$CTRL" \
  && r=yes || r=no
check "collect_runners reads the persisted status" yes "$r"

echo "controller-scope selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
