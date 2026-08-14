#!/usr/bin/env bash
# Self-test for the two host-boot invariants whose breakage is SILENT.
#
# Both were paid for once already on the pool this module replaces:
#
#   --disableupdate  GitHub forced an actions/runner self-update, leaving run.sh
#                    alive while the agent was OFFLINE and undispatchable. CI
#                    stalled 90 minutes with VMs RUNNING and zero usable runners
#                    (DataRetrival #2281). A warm host makes it worse: the
#                    self-update takes K slots down at once.
#
#   metadata fence   Job code could reach 169.254.169.254 and mint a token for
#                    the host service account — which reads the GitHub App
#                    private key from Secret Manager and can delete instances
#                    (#1958). Any workflow would own the fleet.
#
# Neither failure raises an error at boot: the host registers, serves jobs, and
# looks healthy. So they are pinned here instead.
#
# The checks are STRUCTURAL — the flag must be an argument to config.sh, not a
# word in a comment or a log line. Each mutation below breaks the script the way
# a later edit plausibly would and asserts this test notices; a gate that only
# passes on correct input is not evidence.

# Every predicate and mutation below matches the TEXT of host-startup.sh, in
# which `$u`, `$idx` and `$(slot_user …)` are the literal characters that must be
# there. Expanding them here would compare against this test's own environment
# and pass on any script at all — so the single quotes are the point.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/host-startup.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# Code only: full-line comments stripped, so prose about an invariant can never
# satisfy the check for the invariant.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# --- the invariants, as pure predicates over a script's text -----------------

# --disableupdate must sit in config.sh's own argument list. The list is
# continued across lines with backslashes, so the run is joined first.
has_disableupdate() { # <file>
  code_of "$1" \
    | sed ':a;/\\$/{N;s/\\\n//;ba}' \
    | grep -qE 'config\.sh([^|;&]|\\)*--disableupdate'
}

has_metadata_fence() { # <file>
  local code
  code=$(code_of "$1")
  printf '%s' "$code" | grep -q '169\.254\.169\.254' || return 1
  printf '%s' "$code" | grep -q -- '--uid-owner "$u"' || return 1     # fenced per uid
  printf '%s' "$code" | grep -qE '^[[:space:]]*fence_uid runner' || return 1  # the legacy job user
  printf '%s' "$code" | grep -q 'DOCKER-USER' || return 1             # and its containers
  # Every SLOT user too — a job now runs as ci-s<idx>, not as `runner`, so a
  # fence that only names `runner` fences nobody who executes build code.
  printf '%s' "$code" | grep -qE 'fence_uid "\$\(slot_user' || return 1
  # Fails closed: a host that cannot install the fence must not register agents.
  printf '%s' "$code" | grep -qE 'fence_metadata[[:space:]]*\|\|[[:space:]]*die'
}

# Per-slot container isolation (#10). Before this, every slot talked to the one
# rootful daemon, so a job could enumerate the sibling slots' containers, exec
# into them and read their GITHUB_TOKEN and workspace — and, the host being
# warm, later jobs' too. Three parts, all silent when broken: the agent must be
# pointed at ITS OWN socket, the shared daemon must be gone, and the slot must
# not run as an account another slot also runs as.
has_slot_isolation() { # <file>
  local code
  code=$(code_of "$1")
  # the agent's DOCKER_HOST is the slot's own socket, not the system one
  printf '%s' "$code" | grep -qE 'Environment=DOCKER_HOST=unix:///run/\$u/docker\.sock' || return 1
  # a daemon per slot, started before the agent that will use it
  printf '%s' "$code" | grep -q 'ci-dockerd@' || return 1
  printf '%s' "$code" | grep -qE 'start_slot_dockerd "\$idx"[[:space:]]*\|\|[[:space:]]*return 1' || return 1
  # the shared rootful daemon is masked, not merely stopped
  printf '%s' "$code" | grep -qE 'systemctl mask .*docker\.socket' || return 1
  # and the agent runs as the slot's own user
  printf '%s' "$code" | grep -qE '^User=\$u$' || return 1
  printf '%s' "$code" | grep -qE 'sudo -u "\$u" "\$dir/config\.sh"'
}

# --- the real script must satisfy both ---------------------------------------
if has_disableupdate "$SCRIPT"; then
  ok
else
  bad "config.sh is not passed --disableupdate — a forced self-update will take every slot on the host OFFLINE (#2281)"
fi

if has_metadata_fence "$SCRIPT"; then
  ok
else
  bad "job code is not fenced off 169.254.169.254 for every job uid (runner + each slot) and DOCKER-USER, or the fence does not fail closed (#1958)"
fi

if has_slot_isolation "$SCRIPT"; then
  ok
else
  bad "slots do not get their own user and their own container daemon — a job can reach the sibling slots' containers, tokens and workspaces (#10)"
fi

# --- mutation cases: prove the checks above can actually fail -----------------
mutate() { # <description> <sed-program> <predicate> — predicate must go false
  local desc="$1" prog="$2" pred="$3" tmp
  tmp=$(mktemp)
  sed "$prog" "$SCRIPT" >"$tmp"
  if "$pred" "$tmp"; then
    bad "mutation not detected: $desc"
  else
    ok
  fi
  rm -f "$tmp"
}

mutate "flag removed"              's/ --disableupdate//'                         has_disableupdate
mutate "flag only in a comment"    's/ --disableupdate/ \\\n  # --disableupdate/' has_disableupdate
mutate "flag only in a log line"   's/--unattended --replace --disableupdate/--unattended --replace/; s/^log()/log "--disableupdate"\nlog()/' has_disableupdate
mutate "fence address dropped"     's/169\.254\.169\.254/127.0.0.1/g'             has_metadata_fence
mutate "containers unfenced"       's/DOCKER-USER/OUTPUT/g'                       has_metadata_fence
mutate "fence no longer fatal"     's/fence_metadata || die/fence_metadata || log/' has_metadata_fence
mutate "slot users unfenced"       's/fence_uid "\$(slot_user/fence_uid "runner" #(slot_user/'  has_metadata_fence
mutate "agent back on the shared daemon" 's|^Environment=DOCKER_HOST=unix:///run/\$u/docker.sock$|Environment=DOCKER_HOST=unix:///var/run/docker.sock|' has_slot_isolation
mutate "shared daemon left running" 's/systemctl mask --now docker.service docker.socket/systemctl stop docker.service/' has_slot_isolation
mutate "slots share one account"   's/^User=\$u$/User=runner/'                     has_slot_isolation
mutate "agent starts without its daemon" 's/start_slot_dockerd "\$idx" || return 1/start_slot_dockerd "$idx" || true/' has_slot_isolation

printf 'host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
