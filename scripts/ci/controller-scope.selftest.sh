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

# template_state() decides whether a host is deleted for being obsolete, and it
# reads a GLOBAL the tick may not have filled yet — collect_mig() runs before the
# host walk, but a failed describe leaves MIG_TEMPLATE empty and a controller
# restarted mid-tick has never assigned it at all. Under `set -u` an unassigned
# global is a crash; worse than the crash would be it evaluating to "" and
# matching nothing, which reads every host in the pool as stale at once.
check "template_state survives an empty MIG template" unknown \
  "$(bash -c "set -uo pipefail; MIG_TEMPLATE=''; $(fn template_state); template_state tpl-a" 2>&1)"
check "template_state survives an empty host template" unknown \
  "$(bash -c "set -uo pipefail; MIG_TEMPLATE=tpl-a; $(fn template_state); template_state ''" 2>&1)"
check "template_state survives no argument at all" unknown \
  "$(bash -c "set -uo pipefail; MIG_TEMPLATE=tpl-a; $(fn template_state); template_state" 2>&1)"
check "template_state names a match current" current \
  "$(bash -c "set -uo pipefail; MIG_TEMPLATE=tpl-a; $(fn template_state); template_state tpl-a" 2>&1)"
check "template_state names a mismatch stale" stale \
  "$(bash -c "set -uo pipefail; MIG_TEMPLATE=tpl-b; $(fn template_state); template_state tpl-a" 2>&1)"

# The global must exist at FILE scope, not only inside collect_mig(). This is
# the static half of the four checks above: they prove the function is safe when
# the variable is empty, this proves it is never merely unbound.
# shellcheck disable=SC2016
grep -q '^MIG_TEMPLATE=""' "$CTRL" && r=yes || r=no
check "MIG_TEMPLATE is initialised at file scope" yes "$r"

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
# `X=$(gh_api …)` runs gh_api in a subshell, so a status kept in a variable never
# reaches the caller: the blind-tick log line printed `status=` for 36 ticks
# straight. It goes through a file for exactly that reason.
# shellcheck disable=SC2016
grep -q 'printf .%s. "$status" >"$STATE_DIR/api.status"' "$CTRL" \
  && r=yes || r=no
check "gh_api persists its status past the subshell" yes "$r"

# shellcheck disable=SC2016
grep -q 'RUNNER_LIST_STATUS="$(cat "$STATE_DIR/api.status"' "$CTRL" \
  && r=yes || r=no
check "collect_runners reads the persisted status" yes "$r"

# ── the host row, and the empty field that silently shifts it ────────────────
#
# collect_hosts gained a fourth column (the instance self-link, the only place
# the controller learns a host's zone). With gcloud's `value()` the columns are
# TAB separated, tab is IFS whitespace, and a run of IFS whitespace COLLAPSES:
# one empty field shifts every later field left by one. `instanceStatus` is
# empty for an instance the MIG is still CREATING — every scale-out — so the
# self-link would land in `host_tpl` and template_state would call a booting
# host `stale` instead of the `unknown` the recycle fail-safe is built on.
# CSV fixes it because a comma is not IFS whitespace. Both halves are asserted:
# the format gcloud is asked for, and the IFS the readers actually use.
row() { # <line> <ifs> -> a|b|c|d
  printf '%s\n' "$1" | {
    IFS="$2" read -r a b c d
    printf '%s|%s|%s|%s' "$a" "$b" "$c" "$d"
  }
}
check "host row: an empty status does not shift the later fields" \
  "h1||tpl-a|https://x/zones/z/instances/h1" \
  "$(row 'h1,,tpl-a,https://x/zones/z/instances/h1' ,)"
# The negative control: the same row under the OLD separator, so the failure
# this guards against is demonstrated rather than asserted.
check "host row: the tab-separated shape really did shift" \
  "h1|tpl-a|https://x/zones/z/instances/h1|" \
  "$(row "$(printf 'h1\t\ttpl-a\thttps://x/zones/z/instances/h1')" "$(printf '\t')")"

# shellcheck disable=SC2016
grep -q 'format="csv\[no-heading\](instance.basename(),instanceStatus,' "$CTRL" && r=yes || r=no
check "host row: collect_hosts asks gcloud for CSV" yes "$r"
r=$(grep -c 'while IFS=, read -r host status host_tpl host_uri' "$CTRL")
check "host row: both host walks split on the comma" 2 "$r"
r=$(grep -c "awk -F, '{ *\(if (\$1 != \"\") \)\?print \$1" "$CTRL")
check "host row: both awk readers split on the comma" 2 "$r"

# ── the registration token, and the delete that is the whole point ───────────
#
# On a Windows pool the controller mints each host's runner registration token
# and writes it to that instance's metadata, because the host account no longer
# holds the Secret Manager grant it would need to mint its own (ADR §3A). Job
# code on that host can READ instance metadata — there is no Windows mechanism
# that stops it — so DELETING the key once the agents register is the security
# property, not housekeeping. GitHub's own bound is a whole hour.
#
# Grepping for a `remove-metadata` would not prove it: the delete has to happen
# on the right branch, only once the agents are really in GitHub's runner list,
# and it has to survive the marker bookkeeping. So the sequence is RUN against a
# fake compute API and judged on the calls it made. `gcloud`, `curl` and `jq`
# are shell functions, so this needs no fixture directory and no network.
# shellcheck disable=SC2016
reg_seq() { # <reg> <age> <pre> <status> [add-rc] [del-rc] [mutation-sed]
  # <pre> is a comma list of pre-existing markers, from:
  #   minted  keylive  cordon  fails=<n>
  # -> adds|removes|minted?|keylive?|fails=<n>
  local reg="$1" age="$2" pre="${3:-}" status="${4:-RUNNING}"
  local arc="${5:-0}" drc="${6:-0}" mut="${7:-}"
  local dir out step m
  dir=$(mktemp -d)
  : >"$dir/calls"
  for m in ${pre//,/ }; do
    case "$m" in
      minted) : >"$dir/regtoken-h1" ;;
      keylive) : >"$dir/regkey-h1" ;;
      cordon) : >"$dir/cordon-h1" ;;
      fails=*) printf '%s' "${m#fails=}" >"$dir/regfail-h1" ;;
    esac
  done

  step=$(fn registration_token_step)
  [ -n "$mut" ] && step=$(printf '%s\n' "$step" | sed "$mut")

  out=$(
    bash -c "
      set -uo pipefail
      STATE_DIR='$dir'
      REG_TOKEN_KEY=ci-registration-token
      REGISTER_GRACE=600
      PROJECT=test-project
      REPO_FULL=test-owner/test-repo
      CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)
      log() { :; }
      gh_token() { echo installation-token; }
      curl() { echo '{\"token\":\"REGTOKEN\"}'; }
      jq() { echo REGTOKEN; }
      mktemp() { echo '$dir/tokfile'; }
      chmod() { :; }
      timeout() { shift; \"\$@\"; }
      gcloud() {
        echo \"\$*\" >>'$dir/calls'
        case \"\$*\" in *add-metadata*) return $arc ;; *) return $drc ;; esac
      }
      $(fn write_registration_token)
      $(fn delete_registration_token)
      $step
      registration_token_step h1 https://c/zones/test-zone-a/instances/h1 '$reg' '$age' '$status'
    " 2>&1
  )
  [ -z "$out" ] || { printf 'shell-error: %s' "$(printf '%s' "$out" | head -1)"; rm -rf "$dir"; return; }

  printf '%s|%s|%s|%s|%s' \
    "$(grep -c 'add-metadata' "$dir/calls")" \
    "$(grep -c 'remove-metadata' "$dir/calls")" \
    "$([ -f "$dir/regtoken-h1" ] && echo minted || echo no-minted)" \
    "$([ -f "$dir/regkey-h1" ] && echo keylive || echo no-keylive)" \
    "fails=$(cat "$dir/regfail-h1" 2>/dev/null || echo 0)"
  rm -rf "$dir"
}

# A host that has not registered yet gets exactly one token, and `minted` is
# what stops the next tick minting a second.
check "regtoken: absent host is minted a token" "1|0|minted|keylive|fails=0" "$(reg_seq absent 30)"
check "regtoken: a token already written is not re-minted" "0|0|minted|keylive|fails=0" \
  "$(reg_seq absent 30 minted,keylive)"

# THE CHECK THIS FILE EXISTS FOR.
check "regtoken: the key is DELETED once the agents register" "0|1|minted|no-keylive|fails=0" \
  "$(reg_seq present 120 minted,keylive)"

# …and it is deleted even when this controller has no record of writing it. The
# markers live on a boot disk the controller can lose and a sweep can clear; if
# the delete needed one, losing it would strand a live credential in metadata
# for GitHub's whole hour with nothing left to come back for it.
check "regtoken: a registered host with no marker is still cleaned" "0|1|minted|no-keylive|fails=0" \
  "$(reg_seq present 120 '')"
check "regtoken: a host already cleaned is not called about again" "0|0|minted|no-keylive|fails=0" \
  "$(reg_seq present 120 minted)"

# A host that never comes up must not sit on a live credential until GitHub
# expires it an hour later — and must not be minted a fresh one either.
check "regtoken: the key is deleted when the register grace expires" "0|1|minted|no-keylive|fails=0" \
  "$(reg_seq absent 900 minted,keylive)"
check "regtoken: inside the grace the key is left for the booting host" "0|0|minted|keylive|fails=0" \
  "$(reg_seq absent 300 minted,keylive)"
check "regtoken: past the grace no first token is minted either" "0|0|no-minted|no-keylive|fails=0" \
  "$(reg_seq absent 900 '')"

# A CORDONED host is the dangerous one: its agents were deregistered on purpose
# so it reads `absent` forever, while the job it was running keeps executing.
# Minting for it would write a fresh hour-long credential into the metadata of
# the very pull request it is meant to be protected from — every other tick,
# indefinitely.
check "regtoken: a cordoned host is never minted a token" "0|0|no-minted|no-keylive|fails=0" \
  "$(reg_seq absent 30 cordon)"
check "regtoken: a cordoned host's live key is taken back at once" "0|1|no-minted|no-keylive|fails=0" \
  "$(reg_seq absent 30 cordon,keylive)"

# Only a host that is actually coming up. A TERMINATED instance the MIG still
# lists has nothing to register with.
check "regtoken: a terminated host is not minted a token" "0|0|no-minted|no-keylive|fails=0" \
  "$(reg_seq absent 30 '' TERMINATED)"

# A blind tick knows nothing about this host's agents. It must neither hand out
# a credential on a guess nor pull one away from a host mid-registration.
check "regtoken: an unreadable runner list does nothing" "0|0|minted|keylive|fails=0" \
  "$(reg_seq unknown 120 minted,keylive)"

# THE ERROR PATHS, which is where both of the review's blocking findings lived.
# A write that reports failure may still have committed server-side, so it is
# followed by a delete and the key is NOT recorded as written; a delete that
# fails keeps `keylive` so the next tick tries again.
check "regtoken: a failed write takes the key back and does not claim it" \
  "1|1|no-minted|no-keylive|fails=1" "$(reg_seq absent 30 '' RUNNING 1 0)"

# …and it gives up after three. Retrying a failed write once a tick is a
# registration-token POST per tick against the App installation the queue poll
# shares, and the failure it retries hardest — a `timeout` on a setMetadata that
# committed anyway — parks another live credential each time round.
check "regtoken: minting gives up after three failed writes" \
  "0|0|no-minted|no-keylive|fails=3" "$(reg_seq absent 30 fails=3 RUNNING 1 0)"
check "regtoken: a success clears the failure count" \
  "1|0|minted|keylive|fails=0" "$(reg_seq absent 30 fails=2)"
check "regtoken: a failed delete keeps the key on the books for a retry" \
  "0|1|minted|keylive|fails=0" "$(reg_seq present 120 minted,keylive RUNNING 0 1)"

# The detector has to be SEEN firing, or it is not a detector. The delete call
# is replaced by a no-op that still succeeds — the shape of the plausible bad
# edit, where the bookkeeping around the delete survives and only the compute
# call is gone — and the SECOND field must drop from 1 to 0. If it does not, the
# check above is reading something other than the shipping code, and a Windows
# pool could ship with a live registration token in every host's metadata while
# this file says ok.
check "regtoken: the delete check FAILS when the delete is removed" "0|0|minted|no-keylive|fails=0" \
  "$(reg_seq present 120 minted,keylive RUNNING 0 0 's/delete_registration_token/true/g')"

# The whole path is opt-in, and the default is what every existing Linux
# controller runs. Flipping either of these turns on credential-writing into
# instance metadata for pools that have no reason for it and no Windows host to
# consume it.
# shellcheck disable=SC2016
grep -q 'MINT_REG=${MINT_REG:-false}' "$CTRL" && r=yes || r=no
check "regtoken: minting defaults OFF when the metadata key is absent" yes "$r"
# shellcheck disable=SC2016
grep -q 'if \[ "$MINT_REG" = "true" \] && \[ -n "$host_uri" \]' "$CTRL" && r=yes || r=no
check "regtoken: the tick calls the step only on an opted-in pool" yes "$r"

# Static, because the mint path above is stubbed and a stub cannot show where a
# real token would go. `--metadata` puts the token on gcloud's argv, and on the
# pool this exists for one of the local accounts reading the process table is
# running the pull request.
# shellcheck disable=SC2016
grep -q -- '--metadata-from-file="$REG_TOKEN_KEY=$f"' "$CTRL" && r=yes || r=no
check "regtoken: the token is passed by file, never on the command line" yes "$r"

echo "controller-scope selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
