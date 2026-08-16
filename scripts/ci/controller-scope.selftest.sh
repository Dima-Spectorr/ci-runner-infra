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
reg_seq() { # <reg> <age> <pre> <status> [busy] [add-rc] [del-rc] [mutation-sed]
  #          [created-ago] [instance-key] [describe-rc] [facts-mutation-sed]
  # <pre> is a comma list of pre-existing markers, from:
  #   minted  keylive  cordon  fails=<n>
  # <created-ago>, <instance-key> and <describe-rc> are the DURABLE facts — what
  # the GCE API says, as opposed to what the controller's disk says. They default
  # to the ordinary case: an instance created just now, carrying no registration
  # token, readable. <instance-key> is `present`, `absent`, `issued` (the token
  # was handed out once and has since been deleted — only the durable marker
  # remains) or `none` (an instance with no metadata at all, which flattens to no
  # output at exit 0).
  # The last argument mutates `instance_durable_facts` rather than the step, so
  # the gcloud invocation itself can be reverted and seen to fail.
  # -> adds|removes|minted?|keylive?|fails=<n>
  local reg="$1" age="$2" pre="${3:-}" status="${4:-RUNNING}" busy="${5:-0}"
  local arc="${6:-0}" drc="${7:-0}" mut="${8:-}"
  local cago="${9:-0}" ikey="${10:-absent}" derc="${11:-0}" dmut="${12:-}"
  local dir out step facts m
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
  facts=$(fn instance_durable_facts)
  [ -n "$dmut" ] && facts=$(printf '%s\n' "$facts" | sed "$dmut")

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
        # A stub that accepts every flag is not a test double, it is a blindfold.
        # This one shipped a \`describe --filter\` — a list-family flag \`describe\`
        # rejects with exit 2 — past 51 green checks, and the result would have
        # been a pool where nothing ever minted and no host ever registered. So
        # \`describe\` now takes an ALLOW-LIST, and anything else fails the way
        # real gcloud fails.
        case \"\$*\" in
          *'instances describe'*)
            local a
            for a in \"\$@\"; do
              case \"\$a\" in
                compute | instances | describe | h1) ;;
                --project=* | --zone=* | --format=* | --flatten=*) ;;
                *)
                  echo \"ERROR: (gcloud.compute.instances.describe) unrecognized arguments: \$a\" >&2
                  return 2 ;;
              esac
            done ;;
        esac
        case \"\$*\" in
          *add-metadata*) return $arc ;;
          *remove-metadata*) return $drc ;;
          # The GCE API's own answers. An RFC3339 stamp with fractional seconds
          # and an offset, because that is the shape GCE returns and the parse
          # has to survive it.
          *creationTimestamp*)
            [ $derc -eq 0 ] || return $derc
            date -u -d \"@\$((\$(date -u +%s) - $cago))\" +%Y-%m-%dT%H:%M:%S.000-00:00
            return 0 ;;
          *metadata.items.key*)
            [ $derc -eq 0 ] || return $derc
            # The WHOLE key set, one per line — which is what the real
            # projection returns, there being no --filter to narrow it. The
            # absent case still prints a key, and one whose name CONTAINS the
            # real one, so a substring match would read it as present.
            #
            # \`issued\` is the state that outlives everything else: the token was
            # handed out once and correctly deleted, and the marker the write put
            # there in the same call is all that remains. It is deliberately
            # listed BEFORE the token key in the \`present\` case, because the loop
            # must see every line rather than stop at the first match.
            case '$ikey' in
              present) printf '%s\n' instance-template ci-registration-token-issued ci-registration-token created-by ;;
              absent) printf '%s\n' instance-template ci-registration-token-old created-by ;;
              issued) printf '%s\n' instance-template ci-registration-token-issued created-by ;;
              none) : ;;
            esac
            return 0 ;;
          *) return $drc ;;
        esac
      }
      $(fn write_registration_token)
      $(fn delete_registration_token)
      $facts
      $step
      registration_token_step h1 https://c/zones/test-zone-a/instances/h1 '$reg' '$age' '$status' '$busy'
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
check "regtoken: a cordoned host's live key is taken back at once" "0|1|minted|no-keylive|fails=0" \
  "$(reg_seq absent 30 cordon,keylive)"

# Only a host that is actually coming up. A TERMINATED instance the MIG still
# lists has nothing to register with.
check "regtoken: a terminated host is not minted a token" "0|0|no-minted|no-keylive|fails=0" \
  "$(reg_seq absent 30 '' TERMINATED)"

# PARTIAL — one slot registered, the rest not. This shipped in the same mint arm
# as `absent`, and it is the more dangerous of the two: a registered slot can
# ALREADY be executing a pull request, and that job reads the metadata key. And
# it does not self-correct, because host_age_seconds is controller-local — a
# replaced controller reads every host as age 0, so a SLOTS=2 host with slot 1
# running a job and slot 2 dead reads `partial` indefinitely and never reaches
# the `present` delete. Mint on `absent` only; on `partial`, take it back.
check "regtoken: a partly registered host is NOT minted a token" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq partial 0 '')"
check "regtoken: a partly registered host's key is taken back" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq partial 0 minted,keylive)"

# M-4. The marker-less recovery delete used to read `present` only, and the
# expiry chain above it is gated on `[ -f "$keylive" ]`. So a `partial` host that
# lost its markers — the sweep, a replaced controller — had NO path to a delete
# at all, and held a live key until GitHub expired it an hour later, on a host
# where the registered slot may already be running the pull request that reads
# it. The case above is that host: `partial`, no markers, and the second field
# must be a 1.
#
# `unknown` stays excluded and this is the case that says so. Deleting on a
# blind tick would strand a genuinely booting host with no way to register, and
# that exposure is bounded by GitHub's own hour, which is the trade the ADR
# already states.
check "regtoken: M-4 — a marker-less blind tick is still NOT deleted from" \
  "0|0|no-minted|no-keylive|fails=0" "$(reg_seq unknown 0 '')"

# BUSY is the strongest statement that job code is executing right now, and it
# is passed in rather than re-derived so the guard cannot be skipped by a caller.
check "regtoken: a busy host is never minted a token" \
  "0|0|no-minted|no-keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 1)"
check "regtoken: a busy host's live key is taken back" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq absent 0 minted,keylive RUNNING 1)"

# A blind tick knows nothing about this host's AGENTS. It must not hand out a
# credential on a guess, nor pull one away from a host that may be mid-register.
check "regtoken: an unreadable runner list mints nothing" "0|0|no-minted|no-keylive|fails=0" \
  "$(reg_seq unknown 30 '')"
check "regtoken: an unreadable runner list leaves a booting host alone" "0|0|minted|keylive|fails=0" \
  "$(reg_seq unknown 120 minted,keylive)"

# …but `unknown` is not an exemption from the EXPIRY. It is set for every host
# at once whenever the runner list read fails, and this repo has seen 36
# consecutive blind ticks; a rule that only expires on a known reg state leaves
# a live token in job-readable metadata on every Windows host for the whole
# outage, cordoned ones included. `cordon`, `busy` and `age` are all still known
# locally during a blind tick, and the delete is idempotent.
check "regtoken: a blind tick still takes back a cordoned host's key" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq unknown 99999 minted,keylive,cordon)"
check "regtoken: a blind tick still expires a key past the grace" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq unknown 99999 minted,keylive)"
check "regtoken: a blind tick still takes back a busy host's key" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq unknown 30 minted,keylive RUNNING 1)"

# THE ERROR PATHS, which is where both of the review's blocking findings lived.
# A write that reports failure may still have committed server-side, so it is
# followed by a delete and the key is NOT recorded as written; a delete that
# fails keeps `keylive` so the next tick tries again.
check "regtoken: a failed write takes the key back and does not claim it" \
  "1|1|no-minted|no-keylive|fails=1" "$(reg_seq absent 30 '' RUNNING 0 1 0)"

# …and it gives up after three. Retrying a failed write once a tick is a
# registration-token POST per tick against the App installation the queue poll
# shares, and the failure it retries hardest — a `timeout` on a setMetadata that
# committed anyway — parks another live credential each time round.
check "regtoken: minting gives up after three failed writes" \
  "0|0|no-minted|no-keylive|fails=3" "$(reg_seq absent 30 fails=3 RUNNING 0 1 0)"
check "regtoken: a success clears the failure count" \
  "1|0|minted|keylive|fails=0" "$(reg_seq absent 30 fails=2)"
check "regtoken: a failed delete keeps the key on the books for a retry" \
  "0|1|minted|keylive|fails=0" "$(reg_seq present 120 minted,keylive RUNNING 0 0 1)"

# ── H-3: the controller replacement that defeats every local guard at once ────
#
# Each of the five guards on the mint path is either a marker file on the
# controller's boot disk or an age measured from the controller's own boot, and
# ONE event — replacing the controller — voids all five together. A host that is
# cordoned and still executing a pull request then presents exactly this row:
# `absent` and `busy=0` because cordoning deregistered its agents, `age` 0
# because host_age_seconds starts at this controller's first sight of it,
# `RUNNING`, and no markers because they went with the disk. Before the durable
# gate that read `1|0|minted|keylive` — a fresh hour-long credential written
# into the metadata of the job that host is running, and left there for a whole
# REGISTER_GRACE, because the next tick sees `keylive` with no expiry reason.
#
# The durable facts are the GCE API's, so the replacement cannot touch them. The
# instance was really created 4000s ago, which is past the 600s grace, so the
# host is not booting whatever the controller's clock says.
check "regtoken: H-3 — a controller replacement does not re-mint an old host" \
  "0|0|minted|no-keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 4000)"

# The other durable fact, and the one the `keylive` marker used to carry alone:
# an instance that already holds the key is ADOPTED, never handed a second one.
# `keylive` comes back so the expiry rule above owns it from the next tick — it
# is the only code that ever deletes the key.
check "regtoken: H-3 — a key already on the instance is adopted, not re-minted" \
  "0|0|no-minted|keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 0 present)"

# And an unreadable API mints nothing. A durable fact that could not be read is
# not a licence to fall back on the disk the fix exists to distrust.
#
# The failure is CHARGED to the same three-attempt cap as a failed write — the
# fifth field. It is the only refusal on this path that would otherwise leave no
# trace, and it costs two instances.describe per host per tick for as long as it
# lasts, which for a project-wide API outage means every host at once.
check "regtoken: H-3 — unreadable instance facts mint nothing" \
  "0|0|no-minted|no-keylive|fails=1" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 0 absent 1)"
check "regtoken: an unreadable read counts towards the same cap as a failed write" \
  "0|0|no-minted|no-keylive|fails=3" "$(reg_seq absent 0 fails=2 RUNNING 0 0 0 '' 0 absent 1)"

# …and once the cap is reached the describe is not even attempted. The cap sits
# ABOVE the durable gate for that reason: a capped host must cost no API calls
# at all, or an outage that trips the cap on every host keeps paying for it. The
# read is unreadable here too, so had the order been the other way round this
# would read `fails=4`.
check "regtoken: a capped host makes no further instance reads" \
  "0|0|no-minted|no-keylive|fails=3" "$(reg_seq absent 0 fails=3 RUNNING 0 0 0 '' 0 absent 1)"

# A genuinely new host is still served. The gate must not be a blanket refusal:
# that would be a pool that never registers, which is the failure mode a
# security fix is most likely to ship by accident.
check "regtoken: a durably new host is still minted a token" \
  "1|0|minted|keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 30)"

# ── H-4: the YOUNG host the durable age gate does not reach ──────────────────
#
# The age gate only protects an instance that is OLD. This is the other half,
# and the durable facts as first written could not see it: an instance created
# 30s ago that registered, was cordoned mid-job, and had its token correctly
# deleted by the previous controller. To a REPLACEMENT controller it reads
# `absent` (cordoning deregistered the agents), `busy=0` (same reason), `age=0`
# (host_age_seconds starts at this controller's first sight of it), no markers
# (they went with the boot disk), DUR_AGE 30 — under the grace — and DUR_KEY
# genuinely absent. Every guard satisfied, and identical to a host that has
# simply never registered. The old code minted, which writes a fresh hour-long
# credential into the metadata of the pull request that host is running.
#
# What tells them apart is on the instance: the write puts an ISSUED marker
# there in the same setMetadata as the token, and nothing ever removes it.
check "regtoken: H-4 — a young host that was already issued one is not minted again" \
  "0|0|minted|no-keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 30 issued)"

# The marker refuses a MINT and nothing else. The `present` fixture carries it
# alongside a live key — which is the real pairing, since the write puts both
# there in one call — so the adoption case above and the durably-old delete
# below both run against a host that was issued one, and both must still act.
# An instance with NO metadata at all. The projection flattens to no output and
# exits 0, and that is an ABSENT key, not an unreadable one — reading it as a
# failure would permanently refuse to mint for a genuinely key-less host, which
# is the never-registers outage in a smaller box.
check "regtoken: an instance with no metadata at all is minted a token" \
  "1|0|minted|keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 30 none)"

# The durable age gate is asked BEFORE adoption, and it owns the key. An
# instance that is really past the grace AND still carrying the key is deleted
# from here, where the evidence is. Adopting first and leaving it to the expiry
# rule was the earlier shape, and it held a live credential for a further whole
# REGISTER_GRACE — the expiry chain only ever sees the controller-local age,
# which a replacement reset to 0.
check "regtoken: a durably old host still carrying the key is deleted from" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 4000 present)"

# …and when that delete FAILS the key is still out there, so `keylive` goes on
# the books for the expiry rule to retry — and `minted` deliberately does not.
# Claiming the work is done is the one outcome a failed delete must never
# produce, because `minted` is what stops the marker-less recovery arm looking
# again.
check "regtoken: a failed durable-age delete is retried, never marked done" \
  "0|1|no-minted|keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 1 '' 4000 present)"

# The detector has to be SEEN firing, or it is not a detector. The delete call
# is replaced by a no-op that still succeeds — the shape of the plausible bad
# edit, where the bookkeeping around the delete survives and only the compute
# call is gone — and the SECOND field must drop from 1 to 0. If it does not, the
# check above is reading something other than the shipping code, and a Windows
# pool could ship with a live registration token in every host's metadata while
# this file says ok.
check "regtoken: the delete check FAILS when the delete is removed" "0|0|minted|no-keylive|fails=0" \
  "$(reg_seq present 120 minted,keylive RUNNING 0 0 0 's/delete_registration_token/true/g')"

# Same discipline for the two findings above: each fix is REVERTED in place and
# the case that covers it must change its answer. A case that reads the same
# with the fix gone is not covering the fix.
#
# H-3: the durable age gate is short-circuited — the shape of the plausible bad
# edit, where the describe still happens and only the decision it feeds is gone
# — and the old defect comes straight back: an add-metadata on a host that has
# been alive for over an hour.
# shellcheck disable=SC2016
check "regtoken: the H-3 case FAILS when the durable age gate is reverted" \
  "1|0|minted|keylive|fails=0" \
  "$(reg_seq absent 0 '' RUNNING 0 0 0 's/if \[ "\$DUR_AGE" -ge "\$REGISTER_GRACE" \]; then/if false; then/' 4000)"

# M-4: the recovery arm goes back to `present` only, and the `partial` host with
# no markers stops being deleted from — the second field drops from 1 to 0,
# which is the live key left in job-readable metadata for GitHub's whole hour.
# shellcheck disable=SC2016
check "regtoken: the M-4 case FAILS when the partial arm is reverted" \
  "0|0|no-minted|no-keylive|fails=0" \
  "$(reg_seq partial 0 '' RUNNING 0 0 0 's/|| \[ "\$reg" = "partial" \]; }/|| false; }/')"

# F2: the durable age arm stops owning the key — the shape of the earlier code,
# where an instance found to be an hour old was ADOPTED and left to the expiry
# rule. The delete disappears and `minted` is written over a live credential,
# which is the worst of the three outcomes: the marker-less recovery arm will
# not look again either.
# shellcheck disable=SC2016
check "regtoken: the durable-age delete FAILS when that arm stops owning the key" \
  "0|0|minted|no-keylive|fails=0" \
  "$(reg_seq absent 0 '' RUNNING 0 0 0 's/^    if \[ "\$DUR_KEY" = "present" \]; then/    if false; then/' 4000 present)"

# F3: the unreadable read stops being charged to the cap, and an outage that
# affects every host at once buys two instances.describe per host per tick, for
# as long as it lasts, with nothing on disk to show for it.
# shellcheck disable=SC2016
check "regtoken: the unreadable-read cap FAILS when the charge is removed" \
  "0|0|no-minted|no-keylive|fails=0" \
  "$(reg_seq absent 0 '' RUNNING 0 0 0 's/echo $((n + 1)) >"$fails"/:/' 0 absent 1)"

# H-4: the issued gate is short-circuited, and the young cordoned host is minted
# a second live credential — the defect the durable age gate alone left open.
# shellcheck disable=SC2016
check "regtoken: the H-4 case FAILS when the issued gate is reverted" \
  "1|0|minted|keylive|fails=0" \
  "$(reg_seq absent 0 '' RUNNING 0 0 0 's/if \[ "\$DUR_ISSUED" != "absent" \]; then/if false; then/' 30 issued)"

# The `!= absent` spelling is not covered by a case, and deliberately: `unknown`
# is only reachable when the facts read FAILED, and the caller returns before
# this line in that event. It is defence in depth against a future caller, not a
# behaviour this harness can reach — a check for it would assert nothing.

# A creationTimestamp in the FUTURE — a controller whose clock is behind the
# API's. The instance's real age is unknowable from here, so the durable age
# reads as the refusing sentinel and nothing is minted; a key already on the
# instance is taken back rather than left.
check "regtoken: an instance created in the future is not treated as new" \
  "0|0|minted|no-keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' -120 absent)"

check "regtoken: and a key already on such an instance is deleted" \
  "0|1|minted|no-keylive|fails=0" "$(reg_seq absent 0 '' RUNNING 0 0 0 '' -120 present)"

# The clamp goes back to 0 — the shape that shipped — and the negative age reads
# as brand new, which is the single most mint-permissive answer the function can
# give, handed to the host whose age it just failed to establish.
# shellcheck disable=SC2016
check "regtoken: the skew clamp FAILS when a negative age clamps to 0" \
  "1|0|minted|keylive|fails=0" \
  "$(reg_seq absent 0 '' RUNNING 0 0 0 '' -120 absent 0 's/|| DUR_AGE=999999999/|| DUR_AGE=0/')"

# All THREE durable facts are reset before any early return. DUR_ISSUED is the
# one that matters most and was the one missing: `absent` left over from another
# host's successful read is a licence to mint.
r=$(sed -n '/^instance_durable_facts()/,/^  zone=/p' "$CTRL" |
  grep -c -E '^  DUR_(AGE|KEY|ISSUED)=')
check "regtoken: every durable fact is reset before the first early return" 3 "$r"

# ── F4: the bug the stub above could not see ─────────────────────────────────
#
# `--filter` is a `list`-family flag; `describe` rejects it with `unrecognized
# arguments` and exit 2. This shipped, and it meant `instance_durable_facts`
# returned failure for every host on every tick — so nothing was ever minted and
# no host ever registered. 51 checks passed over it, because the stub accepted
# any flag. Reverting the flag must now break the mint, and the only reason it
# does is the allow-list.
# shellcheck disable=SC2016
check "regtoken: F4 — the mint FAILS when the describe goes back to --filter" \
  "0|0|no-minted|no-keylive|fails=1" \
  "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 30 absent 0 's/--flatten="metadata.items\[\]"/--filter="metadata.items.key=$REG_TOKEN_KEY"/')"

# …and the key match is a WHOLE LINE. With no `--filter` the projection returns
# the instance's entire key set, so a substring test would read the neighbouring
# `ci-registration-token-old` as the token itself — and the host would be
# "adopted" against a key that does not exist and never register. The issued
# marker makes this sharper still: `ci-registration-token-issued` is a key the
# controller itself writes next to the token, so a substring match now has a
# guaranteed decoy on every host that ever registered.
# shellcheck disable=SC2016
check "regtoken: F4 — a substring key match adopts the wrong key" \
  "0|0|no-minted|keylive|fails=0" \
  "$(reg_seq absent 0 '' RUNNING 0 0 0 '' 30 absent 0 's/      "$REG_TOKEN_KEY") DUR_KEY="present" ;;/      *"$REG_TOKEN_KEY"*) DUR_KEY="present" ;;/')"

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

# The issued marker rides on the same call and IS on the command line, which is
# fine only because its value is the literal `1`. This asserts that stays true:
# the day someone puts anything else behind `--metadata=` on this call, it is on
# the process table of a host running a pull request.
# shellcheck disable=SC2016
grep -c -- '--metadata=' "$CTRL" | grep -qx 1 && r=yes || r=no
check "regtoken: exactly one --metadata on the mint call" yes "$r"
# shellcheck disable=SC2016
grep -q -- '--metadata="${REG_TOKEN_KEY}-issued=1"' "$CTRL" && r=yes || r=no
check "regtoken: and it carries only the issued marker, never the token" yes "$r"

# The delete names the token key and only the token key. Removing the issued
# marker with it would put the durable fact back on the controller's disk, which
# is the root cause every finding on this path has traced to.
# shellcheck disable=SC2016
grep -q -- '--keys="$REG_TOKEN_KEY"' "$CTRL" && r=yes || r=no
check "regtoken: the delete never takes the issued marker with it" yes "$r"

# ── the SECOND delete gate, under both values of ci-host-os ──────────────────
#
# drain_host()'s first gate is GitHub's refusal to deregister a runner that is
# executing a job, and it is OS-independent. The second gate asks the host
# whether a `Runner.Worker` process is still alive, and THAT question has two
# implementations: `gcloud compute ssh … pgrep` on Linux, and the host-published
# beacon read back through the compute API on Windows.
#
# This is the one change in the Windows sequence that can break a Linux pool,
# and the ADR names the precedent by version: v5.1.4 shipped because the diff
# was read instead of the function being run. So the function is RUN, under both
# values, against a fake compute API, and judged on the calls it made and the
# verdict it reached — never on the text of the branch.
#
# The Linux assertion is deliberately the strongest one available: the recorded
# argv of the ssh invocation, byte for byte, plus the verdict for each of the
# three answers pgrep can give (a count, zero, and nothing at all).
BEACON="$ROOT/modules/ci-runner-host-pool/scripts/beacon-decision.sh"
[ -r "$BEACON" ] || { echo "FAIL: missing $BEACON — every gate check below is vacuous"; exit 1; }
# Read once, into a variable, rather than `cat`-ed inside the runner: the runner
# body is a double-quoted string, so a path with a space in it has nowhere to be
# quoted. The rule ships as its own file and is concatenated onto the controller
# by main.tf, so the gate must be tested against that file and not a copy.
BEACON_SRC=$(cat "$BEACON")
grep -q '^beacon_decision() {' "$BEACON" || {
  echo "FAIL: beacon_decision() not found in $BEACON — the windows cases would all read keep"; exit 1; }

# shellcheck disable=SC2016
gate_seq() { # <os> <ga-csv> <ga-rc> <describe-rc> <runners> <misses> <ssh-out>
  #            <age> [mutation-sed] [emit]
  # <os> is what the INSTANCE's own metadata says: linux | windows | none (a
  # host from a template predating `ci-host-os`) | anything else (a value this
  # controller does not know) | nozone (the MIG reported no self-link, so there
  # is no instance to address at all).
  # <ga-csv> is what `get-guest-attributes --format=csv(key,value)` returns.
  # <runners> is how many agents GitHub lists for the host BEFORE the drain.
  # <age> is how long this controller has known the host, in seconds.
  # [emit]=argv prints the recorded ssh command line instead of the summary.
  # -> ssh=<n> ga=<n> del=<n> rc=<n> clear=<n> held=<n> und=<n>
  local os="${1:-linux}" ga="${2:-}" garc="${3:-0}" derc="${4:-0}"
  local runners="${5:-1}" misses="${6:-0}" sshout="${7:-0}" age="${8:-0}"
  local mut="${9:-}" emit="${10:-}"
  local dir out code zone summary
  dir=$(mktemp -d)
  : >"$dir/calls"
  : >"$dir/log"
  printf '%s' "$ga" >"$dir/ga.csv"

  case "$runners" in
    0) printf '{"runners":[]}' >"$dir/runners.json" ;;
    1) printf '{"runners":[{"id":11,"name":"h1-s1","busy":false}]}' >"$dir/runners.json" ;;
    *) printf '%s' '{"runners":[{"id":11,"name":"h1-s1","busy":false},{"id":12,"name":"h1-s2","busy":false}]}' \
      >"$dir/runners.json" ;;
  esac

  # A REAL instance's metadata: the boot script is in there too, it is tens of
  # kilobytes, and it contains both commas and newlines. That is not decoration
  # — it is the reason the OS is read out of JSON rather than out of a flattened
  # key/value projection, and a fixture without it would pass either way.
  case "$os" in
    none | nozone)
      printf '%s' '{"metadata":{"items":[{"key":"startup-script","value":"#!/bin/sh\nfoo,bar\nci-host-os,windows\n"}]}}' \
        >"$dir/meta.json" ;;
    *)
      printf '{"metadata":{"items":[{"key":"startup-script","value":"#!/bin/sh\\nfoo,bar\\n"},{"key":"ci-host-os","value":"%s"}]}}' \
        "$os" >"$dir/meta.json" ;;
  esac

  # host_age_seconds() reads a file this controller stamped, so the age is set
  # by writing the stamp rather than by waiting.
  printf '%s' "$(($(date +%s) - age))" >"$dir/seen-h1"
  [ "$misses" = "0" ] || printf '%s' "$misses" >"$dir/beaconmiss-h1"

  # All four functions the gate is made of, mutated as ONE body: the branch
  # lives in drain_host, the I/O in beacon_gate, and a mutation that could only
  # reach one of them would leave half the gate unfalsifiable.
  code=$(printf '%s\n%s\n%s\n%s\n' \
    "$(fn host_age_seconds)" "$(fn instance_host_os)" \
    "$(fn beacon_gate)" "$(fn drain_host)")
  [ -n "$mut" ] && code=$(printf '%s\n' "$code" | sed "$mut")

  zone=test-zone-a
  [ "$os" = "nozone" ] && zone=""

  out=$(
    bash -c "
      set -uo pipefail
      STATE_DIR='$dir'
      LOG='$dir/log'
      PROJECT=test-project
      REPO_FULL=test-owner/test-repo
      MIG=test-mig
      REGION=test-region
      BEACON_NS=ci
      BEACON_INTERVAL=30
      REGISTER_GRACE=600
      ORPHAN_CONFIRM_TICKS=3
      DRAINED=0
      DRAIN_ABORTED=0
      WORKER_GATE_CLEAR=0
      WORKER_GATE_HELD=0
      WORKER_GATE_UNDETERMINED=0
      CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)
      RUNNERS_JSON=\$(cat '$dir/runners.json')
      log() { :; }
      gh_token() { echo installation-token; }
      gh_api() { echo '{\"runners\":[]}'; }
      curl() { echo 204; }
      timeout() { shift; \"\$@\"; }
      gcloud() {
        echo \"\$*\" >>'$dir/calls'
        case \"\$*\" in
          *'compute ssh'*) printf '%s\n' '$sshout'; return 0 ;;
          *get-guest-attributes*)
            [ $garc -eq 0 ] || return $garc
            cat '$dir/ga.csv'; return 0 ;;
          *'instances describe'*)
            [ $derc -eq 0 ] || return $derc
            cat '$dir/meta.json'; return 0 ;;
          *'instances list'*) printf '%s\n' '$zone'; return 0 ;;
        esac
        return 0
      }
      $BEACON_SRC
      $code
      drain_host h1
      echo \"rc=\$? clear=\$WORKER_GATE_CLEAR held=\$WORKER_GATE_HELD und=\$WORKER_GATE_UNDETERMINED\"
    " 2>&1
  )

  if [ "$emit" = "argv" ]; then
    # No `| head`: under pipefail a reader that closes early takes the writer
    # down with SIGPIPE, and the harness has already paid for that once. There
    # is at most one ssh line, and none is an empty answer the check reports.
    grep 'compute ssh' "$dir/calls"
    rm -rf "$dir"
    return
  fi

  summary=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  printf 'ssh=%s ga=%s del=%s %s' \
    "$(grep -c 'compute ssh' "$dir/calls")" \
    "$(grep -c 'get-guest-attributes' "$dir/calls")" \
    "$(grep -c 'delete-instances' "$dir/calls")" \
    "$summary"
  rm -rf "$dir"
}

# --- linux: the path that already exists, and must not have moved ------------
#
# The command, byte for byte. `$*` joins the argv with a single space, so the
# `--command` string is visible whole — this fails on a changed flag, a dropped
# `--tunnel-through-iap`, or a rewritten pgrep expression.
check "gate/linux: the ssh command is unchanged, byte for byte" \
  'compute ssh h1 --zone=test-zone-a --project=test-project --tunnel-through-iap --command pgrep -fc "Runner.Worker" || true' \
  "$(gate_seq linux '' 0 0 1 0 0 0 '' argv)"

check "gate/linux: pgrep says zero, the host is deleted" \
  "ssh=1 ga=0 del=1 rc=0 clear=1 held=0 und=0" "$(gate_seq linux)"
check "gate/linux: pgrep says two, the host is kept" \
  "ssh=1 ga=0 del=0 rc=1 clear=0 held=1 und=0" "$(gate_seq linux '' 0 0 1 0 2)"
# An unreachable host produces no output at all, and today that DELETES: the
# `-n "$workers"` test is false, so the gate abstains. Asserted rather than
# fixed — changing it is a separate decision about Linux behaviour, and this PR
# is the one that must not make it by accident.
check "gate/linux: an empty pgrep answer still deletes, as it does today" \
  "ssh=1 ga=0 del=1 rc=0 clear=1 held=0 und=0" "$(gate_seq linux '' 0 0 1 0 '')"
# The Linux path must never touch the guest-attribute API, and never pays for a
# beacon read it would not understand.
check "gate/linux: guest attributes are never read" \
  "ssh=1 ga=0 del=1 rc=0 clear=1 held=0 und=0" \
  "$(gate_seq linux $'workers,0\nts,2030-01-01T00:00:00Z' 0 0 1 0 0)"

# --- windows: no inbound path, ever ------------------------------------------
#
# `ssh=0` in every case below is the property the whole option-(ii) decision in
# the ADR rests on: a Windows host needs no sshd, no IAP firewall rule and no
# administrator session from the controller onto a machine running pull-request
# code. One `gcloud compute ssh` against a Windows host would re-import all
# three, and it would hang rather than fail.
NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

check "gate/windows: a fresh beacon reporting zero workers deletes" \
  "ssh=0 ga=1 del=1 rc=0 clear=1 held=0 und=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")")"
check "gate/windows: a fresh beacon reporting a live worker keeps" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" \
  "$(gate_seq windows "$(printf 'workers,2\nts,%s' "$NOW_TS")")"

# Guest attributes that cannot be READ. Non-zero is not "no workers", it is "we
# did not get an answer" — and the API rate-limits this call per instance, so a
# busy fleet manufactures exactly this. Reading it as idle would delete hosts
# because the pool got busy.
check "gate/windows: unreadable guest attributes keep the host" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 1)"

# A stale beacon is a DEAD PUBLISHER, not an idle host: the host may be
# perfectly busy and we no longer know. 3x the 30s interval is the ceiling, so
# 600s is far past it.
check "gate/windows: a stale beacon keeps the host" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' \
    "$(date -u -d '600 seconds ago' +%Y-%m-%dT%H:%M:%SZ)")")"

# A beacon whose timestamp cannot be parsed at all — a publisher writing
# something else into a namespace job code can also write to.
check "gate/windows: an unparseable beacon timestamp keeps the host" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,not-a-time')")"

# No beacon at all. The three ways that ends, in order of how much is known:
#  * young  — still booting, and a Windows boot is minutes;
#  * had agents — the boot script DID reach registration, so the publisher is
#    what is broken and a worker can exist where we cannot see it. This is the
#    case that proves the registration count is taken BEFORE drain_host
#    deregisters everything, because afterwards GitHub answers 0 for every host;
#  * old, never registered, confirmed across ticks — the only delete in the
#    whole rule without positive evidence, and it is confined to a host that
#    never became a runner.
check "gate/windows: no beacon on a young host keeps it" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" "$(gate_seq windows '' 0 0 0 0 0 60)"
check "gate/windows: no beacon on a host that HAD agents keeps it" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" "$(gate_seq windows '' 0 0 2 9 0 4000)"
check "gate/windows: an unconfirmed beacon-less host keeps" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" "$(gate_seq windows '' 0 0 0 1 0 4000)"
check "gate/windows: a confirmed never-booted host is deleted" \
  "ssh=0 ga=1 del=1 rc=0 clear=1 held=0 und=0" "$(gate_seq windows '' 0 0 0 3 0 4000)"

# --- the OS itself cannot be established: fail CLOSED ------------------------
#
# `und=1` and `del=0` in all three. A host whose OS is unknown is a host nobody
# can ask the worker question about, and "nothing" has never authorised a
# deletion. The cost of being wrong the other way is not symmetric: a spurious
# keep bills for one host until the next tick, a spurious delete costs up to
# `slots_per_host` merge-blocking jobs and reports nothing.
#
# The absent-key case is the one that matters on the day this ships: every host
# in the fleet predates `ci-host-os` until its pool rolls a new template. It
# must NOT be read as "linux" — inferring an OS from a missing key is the
# confident wrong answer, and on a Windows host it would ssh into a machine with
# no sshd, get nothing back, and read that as "no workers" and delete it.
check "gate/unknown: an absent ci-host-os is not assumed to be linux" \
  "ssh=0 ga=0 del=0 rc=1 clear=0 held=0 und=1" "$(gate_seq none)"
check "gate/unknown: a ci-host-os this controller does not know keeps the host" \
  "ssh=0 ga=0 del=0 rc=1 clear=0 held=0 und=1" "$(gate_seq freebsd)"
check "gate/unknown: an unreadable instance describe keeps the host" \
  "ssh=0 ga=0 del=0 rc=1 clear=0 held=0 und=1" "$(gate_seq linux '' 0 1)"
# No self-link from the MIG means no zone, and until now that SKIPPED the second
# gate and deleted the host anyway — a delete on a host nothing had been able to
# ask about. Now it is the same `unknown` as the rest.
check "gate/unknown: no zone no longer skips the gate and deletes" \
  "ssh=0 ga=0 del=0 rc=1 clear=0 held=0 und=1" "$(gate_seq nozone)"

# --- the mutations: every check above must be seen to FAIL ------------------
#
# A predicate that cannot be made to go false is asserting nothing. Each edit
# below is the plausible bad one — the shape a careless change actually takes,
# where the surrounding bookkeeping survives — and each anchor was confirmed to
# exist in the shipping file before the expectation was written.
#
# M1: the Windows arm is short-circuited. The beacon read disappears and the
# host falls through to the fail-closed arm, so a perfectly idle Windows host
# is never deletable and the pool stops scaling in.
# shellcheck disable=SC2016
check "gate/mutation: removing the windows arm stops the beacon read" \
  "ssh=0 ga=0 del=0 rc=1 clear=0 held=0 und=1" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 0 0 1 0 0 0 \
    's/if \[ "\$host_os" = "windows" \]; then/if false; then/')"

# M2: the OS is taken from this controller's own configuration instead of from
# the host — the mixed-rollout mistake, in one line. A Windows host is then
# ssh'd into. It has no sshd, the call returns nothing, and `-n "$workers"` is
# false, so the gate abstains and the host is DELETED mid-job. `ssh=1` is the
# whole finding.
# shellcheck disable=SC2016
check "gate/mutation: trusting the controller's own OS ssh's into a Windows host" \
  "ssh=1 ga=0 del=1 rc=0 clear=1 held=0 und=0" \
  "$(gate_seq windows "$(printf 'workers,2\nts,%s' "$NOW_TS")" 0 0 1 0 '' 0 \
    's/host_os=\$(instance_host_os "\$host" "\$zone")/host_os=linux/')"

# M3: the fail-closed arm is removed. A host of unknown OS then walks straight
# past both implementations of the gate to the delete — which is precisely what
# happens today when the zone is empty, and is the behaviour this PR changes.
# shellcheck disable=SC2016
check "gate/mutation: without the fail-closed arm an unknown host is deleted" \
  "ssh=0 ga=0 del=1 rc=0 clear=0 held=0 und=0" \
  "$(gate_seq none '' 0 0 1 0 0 0 's/elif \[ "\$host_os" != "linux" \]; then/elif false; then/')"

# M4: the registration count is taken AFTER the deregistrations rather than
# before. GitHub then reports zero agents for every host, the
# "registered-without-beacon" row can never fire, and a host whose publisher
# died — but whose boot script plainly reached registration — is deleted on the
# never-booted arm with a job possibly still running on it.
check "gate/mutation: counting registrations after the drain deletes a live host" \
  "ssh=0 ga=1 del=1 rc=0 clear=1 held=0 und=0" \
  "$(gate_seq windows '' 0 0 2 9 0 4000 '/^  regs=/a regs=0')"

# M5: the beacon's timestamp is dropped on the floor and the rule is handed a 0,
# which it reads as "the caller could not parse it". The affirmative case stops
# being reachable at all — the pool never scales in, and it looks like a beacon
# problem rather than a plumbing one.
# shellcheck disable=SC2016
check "gate/mutation: dropping the parsed timestamp makes the delete unreachable" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 0 0 1 0 0 0 \
    's/"\$ts" "\$now"/0 "\$now"/')"

# M6: the published count is never captured, only the key's presence. Every
# beacon then reads as unparseable, which keeps — safe, and completely inert.
# The gate would be a no-op that nothing distinguishes from a working one.
# shellcheck disable=SC2016
check "gate/mutation: not capturing the worker count makes the gate inert" \
  "ssh=0 ga=1 del=0 rc=1 clear=0 held=1 und=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 0 0 1 0 0 0 \
    's/{ present=1; workers="\$val"; }/present=1/')"

echo "controller-scope selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
