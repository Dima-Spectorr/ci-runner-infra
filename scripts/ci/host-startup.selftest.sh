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
  printf '%s' "$code" | grep -q -- '--uid-owner runner' || return 1   # the job user
  printf '%s' "$code" | grep -q 'DOCKER-USER' || return 1             # and its containers
  # Fails closed: a host that cannot install the fence must not register agents.
  printf '%s' "$code" | grep -qE 'fence_metadata[[:space:]]*\|\|[[:space:]]*die'
}

# --- the real script must satisfy both ---------------------------------------
has_disableupdate "$SCRIPT" \
  && ok || bad "config.sh is not passed --disableupdate — a forced self-update will take every slot on the host OFFLINE (#2281)"

has_metadata_fence "$SCRIPT" \
  && ok || bad "job code is not fenced off 169.254.169.254 for both the runner uid and DOCKER-USER, or the fence does not fail closed (#1958)"

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

printf 'host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
