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
#
# zone_of_uri comes along unconditionally. It is a leaf — no globals, no I/O —
# and four of the functions extracted here call it, so leaving it out turns a
# behavioural assertion into `command not found` and the harness reports the
# helper's absence as the tested function's failure.
run_fn() {
  local name="$1" call="$2"; shift 2
  local out
  out=$(
    bash -c "
      set -uo pipefail
      $(printf '%s\n' "$@")
      $(fn zone_of_uri)
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
grep -q 'format="csv\[no-heading\](name,instanceStatus,version.instanceTemplate.basename(),instance.uri(),currentAction)"' "$CTRL" \
  && r=yes || r=no
check "host row: collect_hosts asks gcloud for CSV, and for the URI as a URI" yes "$r"

# ── the transform that is attached to the key, not to the column ─────────────
#
# This projection used to read `(instance.basename(),instanceStatus,...,instance)`.
# gcloud attaches a transform to the KEY, so naming `instance` twice applied the
# basename to BOTH columns and the self-link arrived as the host's short name.
# Nothing downstream noticed: `${uri%/instances/*}` had nothing to strip, so the
# derived "zone" was the host name, every per-instance call failed on it, and the
# pin-hold gate reported `read-failed` — which vetoes. Both IntegrateIT pools sat
# undeletable on a stale template for two days behind that one word.
#
# Asserted as an ABSENCE because that is the shape of the mistake: the projection
# is wrong only in combination, and a reader checking the fourth column alone
# would call the old string correct. Scoped to `--format=` lines, because the
# comment above collect_hosts quotes the broken projection on purpose and a bare
# grep for the token would fail on the explanation of the bug.
r=$(grep -E '^[^#]*--format=' "$CTRL" | grep -c 'instance\.basename()')
check "host row: no basename transform shares the key with the self-link" 0 "$r"

# Every zone derivation goes through zone_of_uri, which returns EMPTY for a
# string that is not a self-link. The inline `${uri%/instances/*}` it replaced
# returned the input unchanged instead — non-empty, so it passed the `[ -z ]`
# guard each call site already had, and the wrong answer looked like a right one.
# shellcheck disable=SC2016
r=$(grep -c 'zone=$(zone_of_uri "$uri")' "$CTRL")
check "host row: all four zone derivations go through zone_of_uri" 4 "$r"
# ONE, and it is zone_of_uri's own body. A second is a call site that went back
# to doing it by hand, which is the regression this whole section is about.
# shellcheck disable=SC2016
r=$(grep -c 'zone=${uri%/instances/\*}' "$CTRL")
check "host row: the inline derivation survives in exactly one place" 1 "$r"

# And the rule itself, run rather than grepped: a bare host name must not be
# able to present itself as a zone.
eval "$(fn zone_of_uri)"
check "zone_of_uri: a real self-link yields the zone" "test-zone-a" \
  "$(zone_of_uri 'https://www.googleapis.com/compute/v1/projects/p/zones/test-zone-a/instances/h1')"
check "zone_of_uri: a bare host name yields nothing" "" "$(zone_of_uri 'ci-runner-host-abcd')"
check "zone_of_uri: an empty string yields nothing" "" "$(zone_of_uri '')"
check "zone_of_uri: a zone URI with no instance yields nothing" "" \
  "$(zone_of_uri 'https://www.googleapis.com/compute/v1/projects/p/zones/test-zone-a')"
r=$(grep -c 'while IFS=, read -r host status host_tpl host_uri host_action; do' "$CTRL")
check "host row: both host walks split on the comma" 2 "$r"
# Five names, not four: with four, `read` glues the fifth column onto the
# self-link ("https://.../instances/h,DELETING") and every zone derived from it
# is wrong, while currentAction silently reads empty.
# Three since classify_pinned() landed: the drain walk, the orphan reaper, and
# the pinned-job classifier all derive the live-host list from $HOSTS the same
# way. This number is the count of readers, so a new one added with the wrong
# separator lands as a FALLING count, not a passing test — which is the reason
# it is asserted as an exact figure rather than a floor.
r=$(grep -c "awk -F, '{ *\(if (\$1 != \"\") \)\?print \$1" "$CTRL")
check "host row: every awk reader splits on the comma" 3 "$r"

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
      # A leaf helper with no globals and no I/O, called by all three of the
      # functions below. Left out, every assertion in this section reports the
      # helper's absence as the tested function's failure.
      $(fn zone_of_uri)
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
# It used to default here, from one metadata key. It now arrives per POOL, off
# a table row, so the default has TWO halves and both are asserted: the file
# scope the controller starts from, and the parser that fills the row. Either
# one alone can be true while a pool still mints — a row is only as safe as the
# column it did not set.
grep -q '^MINT_REG=false$' "$CTRL" && r=yes || r=no
check "regtoken: minting is OFF at file scope, before any pool is selected" yes "$r"

# And the column itself: the parser emits the literal string `false` for
# anything that is not boolean true or the string "true". This is where a
# hand-written table's `mints_registration_token: "no"` — truthy to jq, and to
# nothing else — is turned into a refusal rather than a licence to write
# credentials into instance metadata for a pool that has no host to read them.
r=$(printf '%s' '[{"name":"p","mig":"m","region":"r","runner_labels":"l",
                   "mints_registration_token":"no"}]' |
  { . "$ROOT/modules/ci-runner-host-pool/scripts/pool-table.sh"
    pool_table_parse 2>/dev/null | cut -f12; })
check "regtoken: the pool table refuses a non-true mint column" false "$r"
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

# ── the drain's idle proof, and the order it runs in (#930) ─────────────────
#
# drain_host() proves a host idle and only THEN deregisters its agents. The
# proof is GitHub's own `busy` flag read from a fresh, complete roster, plus the
# host's beacon on Windows; GitHub's 422 on a DELETE is the guard for a job
# assigned after the read. Nothing logs in to the host.
#
# The property #930 is about is `dereg=0` on every keep: a drain that stops for
# ANY reason -- a busy agent, a roster it cannot read, a beacon that says keep,
# an OS it cannot establish -- must stop with every agent still registered.
# The order used to be the reverse, the proof was an IAP-SSH probe the
# controller could not log in to make, and every idle host in a pool was
# stripped of its agents and then kept: GitHub `total_count: 0`, MIG healthy,
# twice in six hours on 2026-09-17.
#
# So the function is RUN, against a fake GitHub and a fake compute API, and
# judged on the calls it made -- `dereg` is the number of DELETEs sent to
# GitHub, `del` the number of instance deletes -- never on the text of a branch.
BEACON="$ROOT/modules/ci-runner-host-pool/scripts/beacon-decision.sh"
[ -r "$BEACON" ] || { echo "FAIL: missing $BEACON — every gate check below is vacuous"; exit 1; }
# Read once, into a variable, rather than `cat`-ed inside the runner: the runner
# body is a double-quoted string, so a path with a space in it has nowhere to be
# quoted. The rule ships as its own file and is concatenated onto the controller
# by main.tf, so the gate must be tested against that file and not a copy.
BEACON_SRC=$(cat "$BEACON")
grep -q '^beacon_decision() {' "$BEACON" || {
  echo "FAIL: beacon_decision() not found in $BEACON — the windows cases would all read keep"; exit 1; }

roster_json() { # <agents> <busy|NULL> -> a GitHub runner listing for host h1
  local n="$1" b="$2" i out="" sep="" flag
  for ((i = 1; i <= n; i++)); do
    if [ "$b" = NULL ]; then flag=''
    elif [ "$i" -le "$b" ]; then flag=',"busy":true'
    else flag=',"busy":false'; fi
    out="$out$sep{\"id\":$((10 + i)),\"name\":\"h1-s$i\"$flag}"
    sep=,
  done
  printf '{"runners":[%s]}' "$out"
}

# shellcheck disable=SC2016
gate_seq() { # <os> <ga-csv> <ga-rc> <describe-rc> <runners> <misses> <busy>
  #            <age> [mutation-sed] [emit]
  # <os> is what the INSTANCE's own metadata says: linux | windows | none (a
  # host from a template predating `ci-host-os`) | anything else (a value this
  # controller does not know) | nozone (the MIG reported no self-link, so there
  # is no instance to address at all).
  # <ga-csv> is what `get-guest-attributes --format=csv(key,value)` returns.
  # <runners> is how many agents GitHub lists for the host.
  # <busy> is how many of them the FRESH roster reports busy; NULL is a roster
  # with no busy field at all, and ROSTERFAIL is a roster that cannot be read.
  # <age> is how long this controller has known the host, in seconds.
  # [emit]=events prints the structured events instead of the summary.
  # Env: GATE_CTRL_OS (the controller's own ci-host-os, default linux);
  # GATE_GA_ERR (stderr of a failing guest-attribute read); GATE_FRESH_RUNNERS
  # (agents in the fresh roster, default <runners>); GATE_DEL_CODE (GitHub's
  # answer to a DELETE, default 204); GATE_MIG_RC (delete-instances status).
  # -> ssh=<n> ga=<n> dereg=<n> del=<n> rc=<n> clear=<n> held=<n> und=<n> fb=<n> err=<n>
  local os="${1:-linux}" ga="${2:-}" garc="${3:-0}" derc="${4:-0}"
  local runners="${5:-1}" misses="${6:-0}" busy="${7:-0}" age="${8:-0}"
  local mut="${9:-}" emit="${10:-}"
  local dir out code zone summary rfail=0
  dir=$(mktemp -d)
  : >"$dir/calls"
  : >"$dir/curls"
  : >"$dir/events"
  : >"$dir/log"
  printf '%s' "$ga" >"$dir/ga.csv"

  roster_json "$runners" 0 >"$dir/runners.json"
  if [ "$busy" = ROSTERFAIL ]; then
    rfail=1
    busy=0
  fi
  roster_json "${GATE_FRESH_RUNNERS:-$runners}" "$busy" >"$dir/fresh.json"

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

  # Every function the gate is made of, mutated as ONE body. fetch_runner_roster
  # is the real one: the proof is only as good as its insistence on reading the
  # roster to its END, and a stub that always says "complete" removes exactly
  # that. guest_attributes_denied is real for the same reason on the beacon side.
  code=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$(fn host_age_seconds)" "$(fn instance_host_os)" \
    "$(fn guest_attributes_denied)" "$(fn note_guest_attributes_denied)" \
    "$(fn beacon_gate)" "$(fn fetch_runner_roster)" "$(fn drain_fail)" "$(fn drain_host)")
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
      # note_guest_attributes_denied reads this, and under \`set -u\` an unbound
      # name would abort the whole subshell rather than fail one check.
      GA_DENIED_FILE=''
      BEACON_INTERVAL=30
      REGISTER_GRACE=600
      ORPHAN_CONFIRM_TICKS=3
      DRAINED=0
      DRAIN_ABORTED=0
      DRAIN_ERRORS=0
      WORKER_GATE_CLEAR=0
      WORKER_GATE_HELD=0
      WORKER_GATE_UNDETERMINED=0
      WORKER_GATE_OS_FALLBACK=0
      CONTROLLER_HOST_OS=${GATE_CTRL_OS:-linux}
      CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)
      RUNNER_PAGE_MAX=20
      RUNNER_LIST_STATUS=ok
      RUNNERS_JSON=\$(cat '$dir/runners.json')
      log() { :; }
      event() { echo \"\$1 \$2\" >>'$dir/events'; }
      gh_token() { echo installation-token; }
      # The FRESH roster drain_host reads for itself. A failure is a non-zero
      # status with the reason on disk, which is how the real gh_api reports it.
      gh_api() {
        [ $rfail -eq 0 ] || { echo 503 >'$dir/api.status'; return 1; }
        cat '$dir/fresh.json'
      }
      curl() { echo \"\$*\" >>'$dir/curls'; echo '${GATE_DEL_CODE:-204}'; }
      timeout() { shift; \"\$@\"; }
      gcloud() {
        echo \"\$*\" >>'$dir/calls'
        case \"\$*\" in
          *'compute ssh'*) return 255 ;;
          *get-guest-attributes*)
            # The stderr matters as much as the status. beacon_gate classifies
            # the refusal by grepping gcloud's own message for the constraint
            # id, so a stub that fails silently exercises only half the branch.
            [ $garc -eq 0 ] || { printf '%s\n' '${GATE_GA_ERR:-}' >&2; return $garc; }
            cat '$dir/ga.csv'; return 0 ;;
          *'instances describe'*)
            [ $derc -eq 0 ] || return $derc
            cat '$dir/meta.json'; return 0 ;;
          *'instances list'*) printf '%s\n' '$zone'; return 0 ;;
          *delete-instances*) return ${GATE_MIG_RC:-0} ;;
        esac
        return 0
      }
      $BEACON_SRC
      $code
      drain_host h1
      echo \"rc=\$? clear=\$WORKER_GATE_CLEAR held=\$WORKER_GATE_HELD und=\$WORKER_GATE_UNDETERMINED fb=\$WORKER_GATE_OS_FALLBACK err=\$DRAIN_ERRORS\"
    " 2>&1
  )

  if [ "$emit" = "events" ]; then
    tr '\n' ';' <"$dir/events"
    rm -rf "$dir"
    return
  fi

  summary=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  printf 'ssh=%s ga=%s dereg=%s del=%s %s' \
    "$(grep -c 'compute ssh' "$dir/calls")" \
    "$(grep -c 'get-guest-attributes' "$dir/calls")" \
    "$(grep -c -- '-X DELETE' "$dir/curls")" \
    "$(grep -c 'delete-instances' "$dir/calls")" \
    "$summary"
  rm -rf "$dir"
}

# --- linux: the proof is GitHub's, and it comes first ------------------------
check "gate/linux: an idle host is deregistered and deleted" \
  "ssh=0 ga=0 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" "$(gate_seq linux)"
check "gate/linux: both agents of an idle two-slot host are deregistered" \
  "ssh=0 ga=0 dereg=2 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" "$(gate_seq linux '' 0 0 2)"

# THE REGRESSION (#930). Each of these used to deregister first and ask second.
check "gate/linux: a busy agent keeps the host AND every registration" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" "$(gate_seq linux '' 0 0 1 0 1)"
check "gate/linux: one busy agent of two keeps both registered" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" "$(gate_seq linux '' 0 0 2 0 1)"
check "gate/linux: the idle proof cannot complete -- runners stay registered, drain errors" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" "$(gate_seq linux '' 0 0 1 0 ROSTERFAIL)"
check "gate/linux: an unprovable drain emits an ERROR event, not only a log line" \
  "ERROR drain-error;" "$(gate_seq linux '' 0 0 1 0 ROSTERFAIL 0 '' events)"
# Only an explicit `busy: false` proves idle. A roster that omits the flag is a
# roster that did not say.
check "gate/linux: a missing busy flag is not idle" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" "$(gate_seq linux '' 0 0 1 0 NULL)"
# A host the tick saw with no agents, that has some now, came alive in between.
check "gate/linux: agents that registered since the poll abort the drain" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=0 fb=0 err=0" \
  "$(GATE_FRESH_RUNNERS=1 gate_seq linux '' 0 0 0)"
# The zombie #930 left behind: a RUNNING host with no agents at all. It must be
# reclaimable, or the pool sits at max_hosts with nothing registered.
check "gate/linux: a host with no agents left is deleted, not kept forever" \
  "ssh=0 ga=0 dereg=0 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" "$(gate_seq linux '' 0 0 0)"
check "gate/linux: a 422 mid-deregistration aborts (a job just started)" \
  "ssh=0 ga=0 dereg=1 del=0 rc=1 clear=1 held=0 und=0 fb=0 err=0" \
  "$(GATE_DEL_CODE=422 gate_seq linux)"
check "gate/linux: any other DELETE answer is a drain error" \
  "ssh=0 ga=0 dereg=1 del=0 rc=1 clear=1 held=0 und=0 fb=0 err=1" \
  "$(GATE_DEL_CODE=502 gate_seq linux)"
check "gate/linux: a failed instance delete is a drain error" \
  "ssh=0 ga=0 dereg=1 del=1 rc=1 clear=1 held=0 und=0 fb=0 err=1" \
  "$(GATE_MIG_RC=1 gate_seq linux)"
check "gate/linux: every step of a drain is a structured event" \
  "INFO drain-probe;INFO drain-deregister;INFO drain-delete;" \
  "$(gate_seq linux '' 0 0 1 0 0 0 '' events)"
# The Linux path never touches the guest-attribute API and never logs in.
check "gate/linux: guest attributes are never read" \
  "ssh=0 ga=0 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" \
  "$(gate_seq linux $'workers,0\nts,2030-01-01T00:00:00Z' 0 0 1 0 0)"

# --- windows: the beacon, also BEFORE deregistration --------------------------
NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

check "gate/windows: a fresh beacon reporting zero workers deletes" \
  "ssh=0 ga=1 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")")"
check "gate/windows: a fresh beacon reporting a live worker keeps, registered" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,2\nts,%s' "$NOW_TS")")"
check "gate/windows: a busy agent keeps before the beacon is even read" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 0 0 1 0 1)"
check "gate/windows: unreadable guest attributes keep the host" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 1)"
check "gate/windows: a stale beacon keeps the host" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' \
    "$(date -u -d '600 seconds ago' +%Y-%m-%dT%H:%M:%SZ)")")"
check "gate/windows: an unparseable beacon timestamp keeps the host" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,not-a-time')")"
check "gate/windows: no beacon on a young host keeps it" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" "$(gate_seq windows '' 0 0 0 0 0 60)"
check "gate/windows: no beacon on a host that HAS agents keeps it" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" "$(gate_seq windows '' 0 0 2 9 0 4000)"
check "gate/windows: an unconfirmed beacon-less host keeps" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" "$(gate_seq windows '' 0 0 0 1 0 4000)"
check "gate/windows: a confirmed never-booted host is deleted" \
  "ssh=0 ga=1 dereg=0 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" "$(gate_seq windows '' 0 0 0 3 0 4000)"

# --- the read the ORG refuses, end to end ------------------------------------
GA_POLICY_ERR='ERROR: (gcloud.compute.instances.get-guest-attributes) HTTPError 412: Constraint constraints/compute.disableGuestAttributesAccess violated for project 000000000000.'

check "gate/windows: a refused read still keeps a young host" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(GATE_GA_ERR="$GA_POLICY_ERR" gate_seq windows '' 1 0 0 0 0 60)"
check "gate/windows: a refused read still keeps a host that HAS agents" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(GATE_GA_ERR="$GA_POLICY_ERR" gate_seq windows '' 1 0 2 9 0 4000)"
check "gate/windows: a refused read still needs its confirmations" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(GATE_GA_ERR="$GA_POLICY_ERR" gate_seq windows '' 1 0 0 1 0 4000)"
check "gate/windows: a host that can never publish a beacon is finally reclaimable" \
  "ssh=0 ga=1 dereg=0 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" \
  "$(GATE_GA_ERR="$GA_POLICY_ERR" gate_seq windows '' 1 0 0 3 0 4000)"
check "gate/windows: an unexplained read failure with the same shape still keeps" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows '' 1 0 0 3 0 4000)"
check "gate/windows: another org constraint is not this one" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(GATE_GA_ERR='ERROR: HTTPError 412: Constraint constraints/compute.disableSerialPortAccess violated for project 1.' \
    gate_seq windows '' 1 0 0 3 0 4000)"
# shellcheck disable=SC2016  # the sed script must carry the literal $ names.
check "gate/windows: dropping the flag restores the host nobody could delete" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(GATE_GA_ERR="$GA_POLICY_ERR" gate_seq windows '' 1 0 0 3 0 4000 \
    's/"\$ORPHAN_CONFIRM_TICKS" "\$denied"/"$ORPHAN_CONFIRM_TICKS"/')"

# --- the OS itself cannot be established: fail CLOSED, agents kept ------------
check "gate/unknown: a ci-host-os this controller does not know keeps the host" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" "$(gate_seq freebsd)"
check "gate/unknown: an unreadable instance describe keeps the host" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" "$(gate_seq linux '' 0 1)"
check "gate/unknown: no zone keeps the host" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" "$(gate_seq nozone)"

# --- the host predates `ci-host-os` entirely: fall back, do NOT deadlock ------
check "gate/legacy: an absent ci-host-os on a linux controller drains as linux" \
  "ssh=0 ga=0 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=1 err=0" "$(gate_seq none)"
check "gate/legacy: the fallback still holds a host with a busy agent" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" "$(gate_seq none '' 0 0 1 0 1)"
check "gate/legacy: an absent ci-host-os on a windows controller keeps the host" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" \
  "$(GATE_CTRL_OS=windows gate_seq none)"
check "gate/legacy: a controller with no ci-host-os of its own keeps the host" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" \
  "$(GATE_CTRL_OS=unknown gate_seq none)"

# --- the mutations: every check above must be seen to FAIL ------------------
#
# M0 is #930 itself: the busy proof is skipped, and a host with a job on it has
# its agent deregistered (the stub's DELETE answers 204, as GitHub would for an
# agent whose job was assigned after the read).
# shellcheck disable=SC2016
check "gate/mutation: skipping the busy proof deregisters a working host" \
  "ssh=0 ga=0 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" \
  "$(gate_seq linux '' 0 0 1 0 1 0 's/if \[ "\$busy" -gt 0 \]; then/if false; then/')"
# M1: the Windows arm is short-circuited; an idle Windows host is never deletable.
# shellcheck disable=SC2016
check "gate/mutation: removing the windows arm stops the beacon read" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 0 0 1 0 0 0 \
    's/if \[ "\$host_os" = "windows" \]; then/if false; then/')"
# M2: the OS is taken from the controller instead of the host. The beacon read
# disappears (ga=0) and a Windows host with two live workers is deleted.
# shellcheck disable=SC2016
check "gate/mutation: trusting the controller's own OS skips a Windows beacon" \
  "ssh=0 ga=0 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,2\nts,%s' "$NOW_TS")" 0 0 1 0 0 0 \
    's/host_os=\$(instance_host_os "\$host" "\$zone")/host_os=linux/')"
# M3: the fail-closed arm is removed, and a host of unknown OS is deleted.
# shellcheck disable=SC2016
check "gate/mutation: without the fail-closed arm an unknown host is deleted" \
  "ssh=0 ga=0 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" \
  "$(gate_seq freebsd '' 0 0 1 0 0 0 's/elif \[ "\$host_os" != "linux" \]; then/elif false; then/')"
# M7: the legacy fallback is removed -- the fleet-wide scale-in deadlock.
# shellcheck disable=SC2016
check "gate/mutation: removing the legacy fallback deadlocks a pre-key host" \
  "ssh=0 ga=0 dereg=0 del=0 rc=1 clear=0 held=0 und=1 fb=0 err=1" \
  "$(gate_seq none '' 0 0 1 0 0 0 's/if \[ "\$host_os" = "absent" \]; then/if false; then/')"
# M8: the fallback ignores the controller's own OS on a Windows pool.
# shellcheck disable=SC2016
check "gate/mutation: an unconditional fallback drains a windows pool's host as linux" \
  "ssh=0 ga=0 dereg=1 del=1 rc=0 clear=1 held=0 und=0 fb=1 err=0" \
  "$(GATE_CTRL_OS=windows gate_seq none '' 0 0 1 0 0 0 \
    's/if \[ "\$CONTROLLER_HOST_OS" = "linux" \]; then/if true; then/')"
# M4: the registration count is zeroed, so a host whose publisher died but
# whose agents are registered reads as never-booted and is deleted.
check "gate/mutation: losing the registration count deletes a live host" \
  "ssh=0 ga=1 dereg=2 del=1 rc=0 clear=1 held=0 und=0 fb=0 err=0" \
  "$(gate_seq windows '' 0 0 2 9 0 4000 '/^  regs=/a regs=0')"
# M5: the beacon's timestamp is dropped; the affirmative case becomes unreachable.
# shellcheck disable=SC2016
check "gate/mutation: dropping the parsed timestamp makes the delete unreachable" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 0 0 1 0 0 0 \
    's/"\$ts" "\$now"/0 "\$now"/')"
# M6: the published count is never captured; the gate becomes inert.
# shellcheck disable=SC2016
check "gate/mutation: not capturing the worker count makes the gate inert" \
  "ssh=0 ga=1 dereg=0 del=0 rc=1 clear=0 held=1 und=0 fb=0 err=0" \
  "$(gate_seq windows "$(printf 'workers,0\nts,%s' "$NOW_TS")" 0 0 1 0 0 0 \
    's/{ present=1; workers="\$val"; }/present=1/')"


# The summary and the verdict used to sit HERE, with eighty more checks below
# them. `[ "$fail" -eq 0 ]` in the middle of a script is not a gate: its status
# is discarded, the script runs on, and the exit status is whatever the LAST
# command happened to return -- a `check`, which returns 0 whether it passed or
# failed. So this file reported "N passed, 1 failed" and exited 0, and CI has
# been treating an inert gate as a green one. Both moved to the end of the file.

# --- #278: capacity that ANSWERS, and the gap ---------------------------------
#
# ci_slots_total is arithmetic — hosts × slots — so it reads exactly the same
# whether every agent registered or none did. Three separate outages hid in that
# gap: a host that registered nothing (#130), a host whose slot units died at
# ExecStartPre (#268), and a slot the host's own sweep condemned and stopped
# after it failed to reach a clean state CONDEMN_MAX times (#278). All three
# subtract from the count of slots that answer, and none of them was published.
#
# host_facts() has always computed that count and thrown it away. It is run for
# real here, because the one thing that must not happen is a BLIND tick reading
# as an outage: an unreadable runner list knows nothing about any host, and a
# host summed as having zero slots is indistinguishable from a host that lost
# them — which would page on exactly the ticks where nothing is known.
hf() { # <runners-json> <slots> <host>
  (
    set -uo pipefail
    eval "$(fn host_facts)"
    # Read by host_facts, which arrived through the eval above — no static
    # reader can see that, so both names look dead here and neither is.
    # shellcheck disable=SC2034
    RUNNERS_JSON="$1"
    # shellcheck disable=SC2034
    SLOTS="$2"
    HOST_BUSY=0
    HOST_PRESENT=0
    HOST_REG=""
    host_facts "$3"
    printf '%s|%s|%s' "$HOST_PRESENT" "$HOST_BUSY" "$HOST_REG"
  ) 2>&1
}

FULL='{"runners":[
  {"name":"ci-lin-a1b2-s1","busy":true},
  {"name":"ci-lin-a1b2-s2","busy":false},
  {"name":"ci-lin-a1b2-s3","busy":false},
  {"name":"ci-lin-a1b2-s4","busy":false},
  {"name":"ci-lin-zzzz-s1","busy":true}
]}'

check "slots: a fully registered host reports every slot, and only its own" \
  "4|1|present" "$(hf "$FULL" 4 ci-lin-a1b2)"

# The #278 shape: one slot condemned and its agent stopped, so it is simply not
# in the list any more. The host is still RUNNING, still serving on the other
# three, and every existing series reads healthy.
CONDEMNED='{"runners":[
  {"name":"ci-lin-a1b2-s1","busy":true},
  {"name":"ci-lin-a1b2-s2","busy":false},
  {"name":"ci-lin-a1b2-s3","busy":false}
]}'
check "slots: a condemned slot is missing from the count, not from the pool" \
  "3|1|partial" "$(hf "$CONDEMNED" 4 ci-lin-a1b2)"

# The #268 shape: the host booted, announced itself, and registered nothing.
check "slots: a host that registered nothing reads as zero, not as unknown" \
  "0|0|absent" "$(hf '{"runners":[]}' 4 ci-lin-a1b2)"

# THE ONE THAT MUST NOT BE ZERO. A tick that could not read the list is not
# evidence about any host in either direction.
check "slots: a blind tick reports -1, which the sum skips entirely" \
  "-1|0|unknown" "$(hf '' 4 ci-lin-a1b2)"

# And the sum itself: the three guards that keep ordinary scale-out from moving
# the series. A host still inside its registration grace has not registered YET,
# a host that is not RUNNING is arriving or leaving, and a blind tick knows
# nothing — each has to be excluded, or the gap is non-zero on every scale event
# and the alert built on it is turned off within a week.
_guards=$(sed -n '/SLOTS THAT ANSWER/,/^    fi$/p' "$CTRL")
# The needles are the controller's text, so they must NOT expand here.
# shellcheck disable=SC2016
for needle in '"$HOST_PRESENT" -ge 0' '"$status" = "RUNNING"' '"$age" -ge "$REGISTER_GRACE"'; do
  case "$_guards" in
    *"$needle"*) r=yes ;;
    *) r=no ;;
  esac
  check "slots: the sum excludes on [$needle]" yes "$r"
done

check "slots: both series are published" "2" \
  "$(grep -cE 'queue_series "ci_slots_(registered|missing)"' "$CTRL")"

# ── the hysteresis clock behind the capacity-lost recycle ────────────────────
#
# recycle_decision() is a pure function, so the clock that decides whether
# `partial` has held long enough lives out here, in partial_seconds(). Two
# properties matter, and neither is visible by reading the decision rule:
#
#  1. it must compute its own clock (the v5.1.5 crash above, in a new function);
#  2. ANY reading other than `partial` must CLEAR the timer -- including
#     `unknown`. A tick that could not ask GitHub is not evidence the host is
#     still degraded, and a run of blind ticks accumulating into a delete is the
#     failure mode this whole family of rules is built to refuse. Clearing costs
#     one more grace window; not clearing costs a host nobody can justify.
#
# Run for real against a scratch STATE_DIR, because the file is the state.
check "partial_seconds computes its own clock" ok \
  "$(run_fn partial_seconds 'partial_seconds host present' 'STATE_DIR=/tmp')"

_psd=$(mktemp -d)
_ps() { # <reg> -> the function's output, against a persistent STATE_DIR
  bash -c "
    set -uo pipefail
    STATE_DIR=$_psd
    $(fn partial_seconds)
    partial_seconds h1 '$1'
  " 2>&1
}
# A first partial tick starts the clock at zero rather than reporting the whole
# uptime -- a host that has been up for hours must not be recycled on the first
# tick its registration slips.
check "partial_seconds: the first partial tick starts the clock" "0" "$(_ps partial)"
check "partial_seconds: the marker survives a second partial tick" "yes" \
  "$(_before=$(cat "$_psd/partial-h1"); _ps partial >/dev/null
     [ "$(cat "$_psd/partial-h1")" = "$_before" ] && echo yes || echo no)"
# Backdate the marker: this is the only way to observe accumulation without
# making the test sleep. Reading the elapsed value straight after writing it
# would be a race against the second boundary, which is why the tick above is
# asserted on the marker rather than on the number it returns.
echo $(($(date +%s) - 900)) >"$_psd/partial-h1"
check "partial_seconds: an old marker accumulates" "yes" \
  "$(_v=$(_ps partial); [ "$_v" -ge 900 ] && [ "$_v" -lt 910 ] && echo yes || echo "$_v")"
# ...and the reset. `present` clears it, and `unknown` must too.
check "partial_seconds: present clears the clock" "0" "$(_ps present)"
check "partial_seconds: the marker file is gone after a reset" "no" \
  "$([ -f "$_psd/partial-h1" ] && echo yes || echo no)"
echo $(($(date +%s) - 900)) >"$_psd/partial-h1"
check "partial_seconds: an unreadable registration clears it too" "0" "$(_ps unknown)"
check "partial_seconds: unknown left no marker behind" "no" \
  "$([ -f "$_psd/partial-h1" ] && echo yes || echo no)"
# A marker that is not a number is the dangerous input: bash arithmetic reads it
# as 0, which would put this host's partial age at seconds-since-the-epoch and
# clear every hysteresis window in one tick. It must restamp, not accumulate.
printf 'not-a-clock' >"$_psd/partial-h1"
check "partial_seconds: a corrupt marker restamps instead of reading as epoch" "0" \
  "$(_ps partial)"
check "partial_seconds: the restamped marker is a plain number" "yes" \
  "$(case "$(cat "$_psd/partial-h1")" in "" | *[!0-9]*) echo no ;; *) echo yes ;; esac)"
# A marker dated in the future -- a clock step back, or a restored disk image --
# clamps to zero rather than going negative into the comparison.
echo $(($(date +%s) + 600)) >"$_psd/partial-h1"
check "partial_seconds: a future marker clamps to zero" "0" "$(_ps partial)"
rm -rf "$_psd"

# The clock is only useful if it reaches the rule. Both halves asserted: the
# call site passes it, and the host's marker is removed with the host -- a
# leftover would hand a later host of the same name a clock it never started.
# shellcheck disable=SC2016
grep -q 'partial_for=$(partial_seconds "$host" "$HOST_REG")' "$CTRL" && r=yes || r=no
check "partial_seconds: the tick computes it" yes "$r"
# shellcheck disable=SC2016
grep -A2 'recycle_decision "\$status"' "$CTRL" | grep -q '"\$partial_for")' && r=yes || r=no
check "partial_seconds: recycle_decision receives it as its tenth argument" yes "$r"
# shellcheck disable=SC2016
sed -n '/^  rm -f "\$STATE_DIR\/idle-\$host"/,/pinhold/p' "$CTRL" \
  | grep -q '"\$STATE_DIR/partial-\$host"' && r=yes || r=no
check "partial_seconds: the marker is cleaned up with the host" yes "$r"
# ...and it is scoped. tick_pool() declares its per-host variables in one local
# list; a name left off it becomes a global that survives into the next pool's
# tick, so a host that was never partial could be recycled on the previous
# pool's clock.
grep -q '^  local host status .* partial_for$' "$CTRL" && r=yes || r=no
check "partial_seconds: partial_for is local to tick_pool" yes "$r"

# --- pool_size accounting -----------------------------------------------------
#
# ci_hosts_running and ci_slots_total are derived from pool_size, which counts
# RUNNING hosts only. drain_decision deletes a TERMINATED or SUSPENDED host
# unconditionally, so a decrement that does not ask the status subtracts a host
# that was never added -- measured as ci_hosts_running = -1 and
# ci_slots_total = -4 on ci-runner-host-telnet, 2026-09-04.
#
# Asserted as a property of EVERY decrement rather than of the two that exist
# today: a third one added later is caught by the same check.
# shellcheck disable=SC2016  # the $((pool_size - 1)) is the shipping source text being matched, not an expression to evaluate.
_dec=$(grep -c 'pool_size=$((pool_size - 1))' "$CTRL")
check "pool_size: every decrement is accounted for" "yes" \
  "$([ "$_dec" -ge 1 ] && echo yes || echo no)"
_unguarded=$(awk '
  /pool_size=\$\(\(pool_size - 1\)\)/ { if (prev !~ /\$status" = "RUNNING"/) bad++ }
  # Comment-only lines are skipped, so `prev` is the previous line of CODE. A
  # comment between the guard and the decrement is a documented decrement, not
  # an unguarded one, and must not read as a failure.
  /[^[:space:]]/ && $0 !~ /^[[:space:]]*#/ { prev = $0 }
  END { print bad + 0 }
' "$CTRL")
check "pool_size: no decrement runs without a RUNNING guard above it" "0" "$_unguarded"
# The floor is the second line of defence and it must sit BEFORE the publish,
# not after -- a clamp downstream of queue_series would publish the bad values
# and then correct a variable nobody reads again.
_clamp=$(awk '
  /if \[ "\$pool_size" -lt 0 \]/ { seen = NR }
  # BOTH publishes that consume pool_size, not just the obvious one:
  # ci_slots_total is pool_size x SLOTS, so a reorder that left it in front of
  # the clamp would publish a negative total while this check stayed green.
  /queue_series "ci_hosts_running"/ { if (seen && seen < NR) running = 1 }
  /queue_series "ci_slots_total"/ { if (seen && seen < NR) total = 1 }
  END { print (running && total) ? 1 : 0 }
' "$CTRL")
check "pool_size: the negative clamp precedes both publishes that consume it" "1" "$_clamp"
# And it is not silent. A clamp that fixes the number without saying so turns
# the next accounting bug into a series that merely looks plausible.
# shellcheck disable=SC2016  # the $pool_size is the shipping source text being matched, not a variable to expand.
grep -A2 'if \[ "\$pool_size" -lt 0 \]' "$CTRL" | grep -q '^ *log "BUG' && r=yes || r=no
check "pool_size: the clamp logs that it fired" yes "$r"

# ── the cordon: what a refusal MEANS, and how old the cordon is ──────────────
#
# Two defects, both of which made a cordon unreadable from the outside.
#
# D1. Every HTTP code that was not 204/404 landed in one arm labelled "still
#     finishing work", with no log line. So a 401 (token), a 403 (secondary rate
#     limit), a 5xx and a curl that never completed (000) all produced the same
#     message as a healthy busy pool -- and specifically the same message as the
#     livelock in #948, which is what they would have been diagnosed as.
#     drain_host()'s deregister loop has always split these; the cordon now does
#     too, counted rather than aborting, because a cordon walks the whole list.
#
# D2. `: >"$STATE_DIR/cordon-$host"` ran on EVERY cordon pass, and the cordon is
#     re-issued every tick. So the marker's timestamp was always "last tick",
#     never "cordon start", and a cordon's age was underivable anywhere -- on
#     exactly the hosts where the age is the only evidence of #948.
#
# RUN, not grepped, for the reason at the top of this file: the counting is
# arithmetic across three variables and a grep cannot tell 422 from 403.
#
# cordon_seq <codes> [marker-age|none] -> gone|held|failed|noprog|warns|marker
#   <codes>       comma list of HTTP codes the DELETE returns, one runner each.
#                 An empty element is curl returning nothing at all.
#   <marker-age>  seconds ago the cordon marker was stamped, or `none` for a
#                 host being cordoned for the first time. `empty` writes the
#                 marker the OLD code wrote -- zero bytes -- which is what every
#                 marker on disk looks like at the moment this ships.
#   marker        the marker's content as a verdict: `kept=<age>` when the
#                 pre-existing stamp survived the pass, `restamped`/`stamped`
#                 when it was written this pass, `absent` when there is none.
cordon_seq() {
  local codes="$1" mage="${2:-none}"
  local dir out now
  dir=$(mktemp -d)
  now=$(date +%s)
  case "$mage" in
    none) ;;
    empty) : >"$dir/cordon-h1" ;;
    *) echo $((now - mage)) >"$dir/cordon-h1" ;;
  esac
  printf '%s\n' "$codes" | tr ',' '\n' >"$dir/codes"

  out=$(
    bash -c "
      set -uo pipefail
      STATE_DIR='$dir'
      REPO_FULL=test-owner/test-repo
      CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)
      CORDON_NO_PROGRESS_SECONDS=3600
      CORDONED=0; CORDON_HELD=0; CORDON_ERRORS=0; CORDON_NO_PROGRESS=0
      RUNNERS_JSON='{}'
      log() { :; }
      # The severity and the event name are what an operator greps for, so they
      # are what is recorded -- not the message text.
      event() { printf '%s %s\n' \"\$1\" \"\$2\" >>'$dir/events'; }
      gh_token() { echo installation-token; }
      # One id per code. Stubbed because this harness must not need jq on PATH;
      # the real filter selects '<host>-s*' names, which is a separate concern
      # and is covered where the roster is parsed.
      jq() { local i=1 n; n=\$(wc -l <'$dir/codes'); while [ \"\$i\" -le \"\$n\" ]; do echo \"\$i\"; i=\$((i + 1)); done; }
      # A code of 'none' is curl printing NOTHING -- a connection that died
      # before -w could write a status at all. 000 is curl's own value for the
      # same class of failure when it DOES get to write one. Both are tested:
      # an empty \$code and a literal 000 are different strings, and the arm
      # has to catch both. No backticks anywhere in this string: shellcheck
      # reads the outer file, where a backtick inside these double quotes is a
      # command substitution and not the prose it looks like (SC2006).
      curl() { local n c; n=\$(( \$(cat '$dir/ncalls' 2>/dev/null || echo 0) + 1 )); echo \"\$n\" >'$dir/ncalls'; c=\$(sed -n \"\${n}p\" '$dir/codes'); [ \"\$c\" = none ] || printf '%s' \"\$c\"; }
      $(fn cordon_seconds)
      $(fn cordon_host)
      cordon_host h1 >/dev/null 2>&1
      printf '%s|%s|%s|%s' \"\$CORDON_HELD\" \"\$CORDON_ERRORS\" \"\$CORDON_NO_PROGRESS\" \"\$CORDONED\"
    " 2>&1
  )
  case "$out" in
    [0-9]*'|'[0-9]*'|'[0-9]*'|'[0-9]*) ;;
    *) printf 'shell-error: %s' "$(printf '%s' "$out" | head -1)"; rm -rf "$dir"; return ;;
  esac

  local held errs noprog gone marker body
  held=${out%%|*}; out=${out#*|}
  errs=${out%%|*}; out=${out#*|}
  noprog=${out%%|*}
  gone=$(grep -c '^INFO cordon-deregister$' "$dir/events" 2>/dev/null)
  body=$(cat "$dir/cordon-h1" 2>/dev/null)
  if [ ! -f "$dir/cordon-h1" ]; then
    marker=absent
  elif [ "$mage" = none ] || [ "$mage" = empty ]; then
    # Written this pass. Only that it is a usable stamp matters.
    case "$body" in "" | *[!0-9]*) marker=unstamped ;; *) marker=stamped ;; esac
  elif [ "$body" = "$((now - mage))" ]; then
    marker="kept=$mage"
  else
    marker=restamped
  fi
  printf '%s|%s|%s|%s|%s|%s' "${gone:-0}" "$held" "$errs" "$noprog" \
    "$(grep -c '^WARNING ' "$dir/events" 2>/dev/null)" "$marker"
  rm -rf "$dir"
}

# The ordinary cordon: both slots idle, both gone, nothing held, nothing warned.
check "cordon: two idle slots are removed and nothing is held" "2|0|0|0|0|stamped" \
  "$(cordon_seq 204,204)"

# THE CHECKS D1 EXISTS FOR. A 422 is a job finishing and is NOT a warning; a 401,
# a 403, a 500 and a curl that returned nothing are, and none of them may be
# counted as held. Each is asserted on its own, because one arm that swallowed
# all four would pass a test that only tried one of them.
check "cordon: a 422 is held, silently, and is not an error" "1|1|0|0|0|stamped" \
  "$(cordon_seq 204,422)"
check "cordon: a 401 is an error, not work in progress" "1|0|1|0|1|stamped" \
  "$(cordon_seq 204,401)"
check "cordon: a 403 rate limit is an error, not work in progress" "1|0|1|0|1|stamped" \
  "$(cordon_seq 204,403)"
check "cordon: a 500 is an error, not work in progress" "1|0|1|0|1|stamped" \
  "$(cordon_seq 204,500)"
check "cordon: curl's own 000 is an error, not work in progress" \
  "1|0|1|0|1|stamped" "$(cordon_seq 204,000)"
check "cordon: a curl that answered nothing at all is an error too" \
  "1|0|1|0|1|stamped" "$(cordon_seq 204,none)"
# And the mixture, which is the row an operator actually reads: one slot gone,
# one finishing a job, one unanswered. Three distinct numbers -- and before this
# change the last two were the same number.
check "cordon: held and unanswered are separate columns" "1|1|1|0|1|stamped" \
  "$(cordon_seq 204,422,401)"

# THE CHECKS D2 EXISTS FOR. The marker carries the cordon's START, so a pass that
# re-issues the cordon must not touch it.
check "cordon: an existing marker is not re-truncated or restamped" \
  "0|1|0|0|0|kept=600" "$(cordon_seq 422 600)"
check "cordon: a first cordon stamps the marker with a readable time" \
  "0|1|0|0|0|stamped" "$(cordon_seq 422 none)"
# Every marker on disk at the moment this ships is zero bytes, written by `: >`.
# Read as 0 it would put the cordon's age at decades and fire no-progress on the
# first tick after the upgrade, so it is restamped to now and reported as young.
check "cordon: a legacy zero-byte marker is restamped, not read as the epoch" \
  "0|1|0|0|0|stamped" "$(cordon_seq 422 empty)"

# THE OBSERVABILITY HALF OF #948. A cordon past the window that removed NOTHING
# and still holds a slot is not converging: the held slot keeps being handed
# work. Signalled here; NOT fixed here.
check "cordon: a held slot past the window is reported as no progress" \
  "0|1|0|1|1|kept=7200" "$(cordon_seq 422 7200)"
check "cordon: inside the window a held slot is just a long job" \
  "0|1|0|0|0|kept=1800" "$(cordon_seq 422 1800)"
# Progress this tick is progress, however old the cordon: a slot came out of the
# pool, so the next tick is strictly closer to a retire.
check "cordon: an old cordon that removed a slot is not no-progress" \
  "1|1|0|0|0|kept=7200" "$(cordon_seq 204,422 7200)"
# An unanswered DELETE is not no-progress either. It is already warned about as
# an error, and reporting it on BOTH would send a token fault to the livelock
# alert -- the exact confusion D1 removes.
check "cordon: an unanswered DELETE on an old cordon is not no-progress" \
  "0|0|1|0|1|kept=7200" "$(cordon_seq 401 7200)"

# And the publish. A counter nothing sends is a counter nobody sees, and the
# three labels go out as a fixed set including the zeroes for the reason the skip
# reasons do: a series that appears only when it fires cannot be alerted on.
for _o in cordon-held cordon-error cordon-no-progress; do
  grep -qF "\"outcome\":\"$_o\"" "$CTRL" && r=yes || r=no
  check "cordon: $_o is published on ci_recycle_verdicts" yes "$r"
done
# Reset per tick, like every other per-tick delta. Left unreset they would
# accumulate across pools on a controller that serves four.
for _v in CORDON_HELD CORDON_ERRORS CORDON_NO_PROGRESS; do
  grep -qE "^  $_v=0\$" "$CTRL" && r=yes || r=no
  check "cordon: $_v is reset at the top of tick_pool" yes "$r"
done

# THE LAST LINES IN THE FILE, and `exit` rather than a bare test, so that a check
# appended below them cannot silently become the script's exit status again.
echo "controller-scope selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
