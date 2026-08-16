#!/usr/bin/env bash
# Self-test for the Windows host-boot invariants whose breakage is SILENT.
#
# This is the bash, mutation-based gate that docs/adr-windows-pool.md §5 calls
# gate 3, and it is modelled directly on host-startup.selftest.sh — same helpers,
# same discipline, same reason. Its companions are the parse and analyzer gates
# (powershell-gate.sh) and the Pester suite over the script's pure functions
# (windows-startup.Tests.ps1). Parsing and linting are still READING: v5.1.4
# passed every gate in ci.yml while every controller in the fleet died on its
# first tick, because all of them read the controller's text and none ran it.
#
# WHAT THIS FILE GUARDS THAT NOTHING ELSE CAN
#
# §3A deleted the metadata fence rather than deferring it. Windows Firewall gives
# an explicit block rule precedence over every conflicting allow rule, supports
# no administrator-assigned ordering, and has no per-principal outbound filter
# that works without IPsec the metadata server does not speak — so a host-wide
# block installs cleanly and takes the guest agent, the beacon and the broker
# down along with the slot accounts. The safety property moved into IAM.
#
# That leaves two things a later edit could silently undo, and neither raises an
# error at boot:
#
#   the fence comes back    A `New-NetFirewallRule` added by somebody who read
#                           §3 without reading §3A REVIEWS as a security
#                           improvement and strands the entire pool. Phase 2 of
#                           §3 is still in the document, marked superseded, and
#                           a superseded design is the easiest thing in the world
#                           to implement by accident.
#
#   a credential in metadata §3A accepts that job code on a Windows host can read
#                           instance metadata and forge guest attributes. The
#                           rule that makes that acceptable is that NO credential
#                           of any kind is put there by this host. The
#                           registration token is the controller's to write and
#                           the controller's to delete (controller-startup.sh);
#                           this script writes neither it nor anything else.
#
# …plus phase 3's own invariants, whose breakage is loud at JOB time and silent
# at boot: a broker bound off loopback, one proven only to answer rather than to
# vend, or a pool whose empty job service account quietly downgrades to the host
# identity instead of handing jobs no Google credentials at all.
#
# The per-job reset hooks add their own invariants to this file when phase 4
# lands; they are not here yet because the hooks are not.
#
# Every mutation below breaks the script the way a later edit plausibly would and
# asserts this test notices. A gate that only passes on correct input is not
# evidence.

# Every predicate and mutation below matches the TEXT of windows-host-startup.ps1,
# in which the identifiers quoted are the literal characters that must be there.
# Expanding them here would compare against this test's own environment and pass
# on any script at all — so the single quotes are the point.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/windows-host-startup.ps1"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# Code only: full-line comments stripped, so prose about an invariant can never
# satisfy the check for the invariant. PowerShell line comments are `#`, the same
# character bash uses, so the Linux helper transfers unchanged.
#
# NOTE: this does NOT strip `<# … #>` doc-comment bodies. That is deliberate and
# it cuts the safe way for the NEGATIVE assertions below: a docstring that spells
# out `New-NetFirewallRule` in prose FAILS this gate. Over-strict on "this must
# not appear" costs a reword; under-strict costs the pool.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `... | grep -q` under `set -o pipefail`. `grep -q` exits the moment it
# matches, the writer upstream takes SIGPIPE and exits 141, and pipefail then
# makes the PIPELINE fail — so a successful match is reported as a failure. It is
# a race with how much the writer had already buffered, which is why this passed
# on a laptop and failed on a runner against a byte-identical script. Every
# predicate below therefore matches against a string, not through a pipe.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# --- invariant 1: there is no fence, and there must never be one -------------

has_no_firewall_fence() { # <file>
  local code
  code=$(code_of "$1")
  # The mechanism §3A refuted. An allow rule cannot survive a host-wide block on
  # this platform, so any rule at all here is either a no-op or a strand.
  ! matches "$code" 'New-NetFirewallRule' || return 1
  # The profile-wide form, rejected on feasibility: a CI host's job code is an
  # un-enumerable set of programs reaching an un-enumerable set of registries, so
  # the allow-list that makes CI work is `*`.
  ! matches "$code" 'Set-NetFirewallProfile' || return 1
  # And the same thing spelled through the legacy tool, which no reader of the
  # PowerShell-only rule would think was covered.
  ! matches "$code" 'netsh[[:space:]]+(-[a-z]+[[:space:]]+)*advfirewall' || return 1
  # The block rule's own address+port, in any spelling that would fence the
  # metadata server off this host.
  ! matches "$code" '(Block|Deny)[^\n]*169\.254\.169\.254|169\.254\.169\.254[^\n]*(Block|Deny)' || return 1
}

# --- invariant 2: no credential reaches metadata or guest attributes ---------

has_no_credential_channel() { # <file>
  local code key
  code=$(code_of "$1")

  # 1. Instance metadata is written by the CONTROLLER and never by the host. The
  #    registration token key is minted, written and DELETED by
  #    controller-startup.sh; a host that could write instance metadata could
  #    also re-create the key the controller just deleted.
  ! matches "$code" 'add-metadata|setMetadata' || return 1
  ! matches "$code" 'instance/attributes[^\n]*-Method[[:space:]]+(Put|Post)' || return 1

  # 2. Every guest-attribute write names a key from the allow-list. `boot` is the
  #    only one this script writes; `workers` and `ts` belong to the beacon and
  #    are asserted in windows-beacon.Tests.ps1. A new key is a new channel off
  #    this host and must be reviewed as one, which is what failing here forces.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
      boot|workers|ts) ;;
      *) return 1 ;;
    esac
  done < <(printf '%s\n' "$code" \
    | grep -oE "Write-GuestAttribute -Key '[A-Za-z0-9_-]+'" \
    | sed -E "s/.*'(.*)'/\\1/")

  # 3. And nothing credential-shaped reaches either channel, whatever the key is
  #    called. This is the check that survives somebody adding an allow-listed
  #    key and putting the wrong thing in it.
  ! matches "$code" '(Write-GuestAttribute|add-metadata|guest-attributes)[^\n]*([Pp]assword|[Ss]ecret|[Tt]oken|[Cc]redential)' || return 1

  # 4. The slot password never leaves the SecureString it is born in. Phase 1
  #    builds a PSCredential and hands it to phase 5; a plaintext conversion is
  #    the step that would make items 2 and 3 reachable in the first place.
  ! matches "$code" 'ConvertFrom-SecureString|NetworkCredential\(' || return 1
}

# --- phase 3's own invariants ------------------------------------------------

has_job_broker() { # <file>
  local code
  code=$(code_of "$1")
  # Loopback, not the VM's address. Windows has no per-slot network namespace
  # (§4), so every slot shares one loopback and the Linux 0.0.0.0 bind — which
  # exists only because each Linux slot has its OWN loopback — would add an
  # exposure on the VM's NIC in exchange for nothing.
  matches "$code" 'CI_BROKER_HOST" value="127\.0\.0\.1"' || return 1
  ! matches "$code" 'CI_BROKER_HOST" value="0\.0\.0\.0"' || return 1
  # The identity is validated before it reaches an XML document and a service
  # environment block, both of which run as LocalSystem.
  matches "$code" 'Test-JobServiceAccountName -Name \$account' || return 1
  # Readiness asserts the CAPABILITY, not the daemon: a broker that answers 200
  # and vends nothing is the failure `Get-Service … Running` cannot see.
  matches "$code" '\$token\.access_token' || return 1
  # Bounded. A broker that ACCEPTS and never answers would otherwise turn a
  # 30x2s readiness probe into an unbounded wait.
  matches "$code" '\-TimeoutSec \$script:HttpTimeoutSeconds' || return 1
  # Fatal. A host that registers agents without a working broker turns every
  # deploy step into a confusing auth failure at job time.
  matches "$code" 'if \(-not \(Test-JobBrokerReady -Port \$port\)\) \{' || return 1
  # An empty job service account is a valid pool with NO broker, and must never
  # be a silent downgrade to the host identity.
  matches "$code" 'IsNullOrWhiteSpace\(\$JobServiceAccount\)' || return 1
}

# --- the helper carries the trap it was written to avoid ---------------------
# A match on the FIRST line of a large input is the worst case: with `grep -q`
# the writer is still pushing bytes when grep exits on the match, takes SIGPIPE,
# and pipefail reports the successful match as a failure.
if matches "$(seq 1 20000)" '^1$' && ! matches "$(seq 1 20000)" '^abc$'; then
  ok
else
  bad "matches() is unreliable on a large input — the pipefail/SIGPIPE trap is back, and every predicate below is now untrustworthy"
fi

# --- the real script must satisfy every one ----------------------------------

if has_no_firewall_fence "$SCRIPT"; then
  ok
else
  bad "the Windows boot script installs a firewall rule — §3A refuted every form of it: an explicit block beats any allow, there is no administrator-assigned ordering, and a host-wide block takes the guest agent, the beacon and the broker down with the slot accounts, stranding the whole pool"
fi

if has_no_credential_channel "$SCRIPT"; then
  ok
else
  bad "the Windows boot script puts a credential where job code can read it — §3A accepts that a Windows job can read instance metadata and forge guest attributes, and the rule that makes that acceptable is that this host writes no credential to either"
fi

if has_job_broker "$SCRIPT"; then
  ok
else
  bad "the job credential broker is missing, bound off loopback, unvalidated, unbounded, or not proven to VEND a token before agents register — a broker that answers and vends nothing turns every deploy step into a confusing auth failure at job time"
fi

# --- mutation cases: prove the checks above can actually fail -----------------
#
# Every one of these reverts the fix in place and asserts the covered case
# changes its answer. A detector that has not been SEEN to fire is not a
# detector: this repository shipped a `describe --filter` past 51 green checks
# because a stub accepted a flag real gcloud rejects.
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

# 1. The fence comes back, in each shape somebody might reintroduce it.
mutate "the phase-2 block rule reintroduced" \
  's|^\$script:BrokerServiceName.*|New-NetFirewallRule -DisplayName ci-md -Direction Outbound -RemoteAddress 169.254.169.254 -Action Block|' \
  has_no_firewall_fence
mutate "a -Service allow exemption reintroduced" \
  's|^\$script:BrokerServiceName.*|New-NetFirewallRule -DisplayName ci-md-allow -Service GCEAgent -Action Allow|' \
  has_no_firewall_fence
mutate "the profile-wide default-block form" \
  's|^\$script:BrokerServiceName.*|Set-NetFirewallProfile -All -DefaultOutboundAction Block|' \
  has_no_firewall_fence
mutate "the same fence spelled through netsh" \
  's|^\$script:BrokerServiceName.*|\& netsh advfirewall firewall add rule name=ci dir=out action=block remoteip=169.254.169.254|' \
  has_no_firewall_fence

# 2. A credential reaches a channel job code can read.
mutate "a credential written to guest attributes" \
  "s|^\\\$script:BrokerServiceName.*|Write-GuestAttribute -Key 'token' -Value \\\$regToken|" \
  has_no_credential_channel
mutate "a credential written to instance metadata" \
  's|^\$script:BrokerServiceName.*|\& gcloud compute instances add-metadata $name --metadata=ci-slot-password=$pw|' \
  has_no_credential_channel
mutate "an allow-listed key carrying the wrong thing" \
  "s|Write-GuestAttribute -Key 'boot' -Value (Get-BeaconTimestamp)|Write-GuestAttribute -Key 'boot' -Value \\\$slotPassword|" \
  has_no_credential_channel
mutate "the slot password converted out of its SecureString" \
  's|^\$script:BrokerServiceName.*|$plain = ConvertFrom-SecureString $secure -AsPlainText|' \
  has_no_credential_channel

# 3. The broker regresses to the Linux shape, or to checking the daemon.
mutate "broker bound on the VM's address" \
  's|CI_BROKER_HOST" value="127.0.0.1"|CI_BROKER_HOST" value="0.0.0.0"|' \
  has_job_broker
mutate "job service account no longer validated" \
  's|Test-JobServiceAccountName -Name \$account|$true #|' \
  has_job_broker
mutate "readiness back to 'it responded'" \
  's|\$token\.access_token|$token|' \
  has_job_broker
mutate "readiness probe unbounded" \
  's|-TimeoutSec \$script:HttpTimeoutSeconds|-TimeoutSec 0|g' \
  has_job_broker
mutate "a broker that never vended is no longer fatal" \
  's|if (-not (Test-JobBrokerReady -Port \$port)) {|if ($false) {|' \
  has_job_broker
mutate "no-broker pool silently downgraded to the host identity" \
  's|IsNullOrWhiteSpace(\$JobServiceAccount)|$false|' \
  has_job_broker


printf 'windows-host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
