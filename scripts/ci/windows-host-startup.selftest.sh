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
# …and one that DOES fail at boot, but only on the pools nobody tests:
#
#   hooks made conditional  The tempting edit folds ACTIONS_RUNNER_HOOK_JOB_* in
#                           beside the GCE_METADATA_* values, since all five are
#                           "credential plumbing". A pool with no job service
#                           account then gets no reset hook — and that is the
#                           pool where an inherited credential is WORST, because
#                           nothing on the host competes with what a workflow
#                           left behind, so the leftover is simply what the next
#                           pull request authenticates as.
#
# Every mutation below breaks the script the way a later edit plausibly would and
# asserts this test notices. A gate that only passes on correct input is not
# evidence.

# Every predicate and mutation below matches the TEXT of windows-host-startup.ps1,
# in which `$block`, `$HookPath` and `$script:JobHookPath` are the literal
# characters that must be there. Expanding them here would compare against this
# test's own environment and pass on any script at all — so the single quotes are
# the point.
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

# --- invariant 3: the reset hooks are set unconditionally --------------------

has_unconditional_job_hooks() { # <file>
  local code
  code=$(code_of "$1")

  # Both ends of the job. COMPLETED alone leaves a live credential on disk for
  # the whole idle window and does not run at all if the agent is killed mid-job,
  # which is the case that leaves the most behind; STARTED alone leaves the idle
  # window open.
  matches "$code" "ACTIONS_RUNNER_HOOK_JOB_STARTED'\] = \\\$HookPath" || return 1
  matches "$code" "ACTIONS_RUNNER_HOOK_JOB_COMPLETED'\] = \\\$HookPath" || return 1

  # …at the FUNCTION's indentation, not the broker branch's. This is the whole
  # invariant, and indentation is what makes it decidable from the text: the
  # `if (-not …BrokerEndpoint)` body is indented one level deeper, so a hook
  # assignment that moved inside it lands at 8 spaces instead of 4.
  matches "$code" "^    \\\$block\['ACTIONS_RUNNER_HOOK_JOB_STARTED'\]" || return 1
  matches "$code" "^    \\\$block\['ACTIONS_RUNNER_HOOK_JOB_COMPLETED'\]" || return 1
  ! matches "$code" "^        \\\$block\['ACTIONS_RUNNER_HOOK_JOB_" || return 1

  # …and the install itself is unconditional too. A hook path in the environment
  # of an agent whose hook file was never written takes work and fails all of it.
  matches "$code" '^    \$hookPath = Invoke-Phase4JobHook -SlotUsers \$slotUsers$' || return 1
  ! matches "$code" '^        \$hookPath = Invoke-Phase4JobHook' || return 1
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

# --- invariant 4: every ambiguous outcome resolves AWAY from a credential ----
#
# The Linux script gets this property structurally: fence_metadata blocks
# 169.254.169.254 for every job whether or not a job SA exists, so a read that
# fails, a pool with no broker and a squatted port all end in "no credentials".
# §3A deleted the fence here, so on Windows each of those three has to be
# decided in code — and each one was originally decided the wrong way.

has_fail_closed_metadata() { # <file>
  local code
  code=$(code_of "$1")
  # A read that FAILED is not an attribute that is UNSET. The old catch-all
  # returned '' for both, and '' is a decision on two attributes: it turns a
  # broker pool into a no-broker pool, and it drops the image floor to 1.
  matches "$code" 'Test-MetadataAbsence -StatusCode \$status' || return 1
  matches "$code" 'refusing to' || return 1
  # …and the predicate itself must not read a missing status as a 404. $null is
  # what a refused connection, a DNS failure and a read timeout all produce.
  matches "$code" 'if \(\$null -eq \$StatusCode\) \{ return \$false \}' || return 1
  return 0
}

has_closed_metadata_endpoint() { # <file>
  local code
  code=$(code_of "$1")
  # The endpoint a no-broker pool points its slots at. Leaving GCE_METADATA_*
  # unset does not withhold credentials on Windows: gcloud, google-auth and the
  # Go and Java clients fall through to the real 169.254.169.254 and come back
  # as the HOST service account. That is the silent downgrade the no-broker path
  # claims never to make, and this constant is what makes the claim true.
  matches "$code" '^\$script:ClosedMetadataEndpoint' || return 1
  matches "$code" "^\\\$script:ClosedMetadataPort" || return 1
  # Reserved, therefore unbindable. An OPEN closed-endpoint is worse than none:
  # a job could bind it and hand the next pull request a token of its choosing.
  matches "$code" 'Lock-LoopbackPort -Port \$script:ClosedMetadataPort' || return 1
  matches "$code" 'excludedportrange' || return 1
  return 0
}

has_owned_broker_socket() { # <file>
  local code
  code=$(code_of "$1")
  # A vended token proves a broker is THERE, not that it is OURS. Between a
  # broker crash and the shim's 10-second restart the port is free, and every
  # slot shares one loopback (§4).
  matches "$code" 'Test-BrokerListenerSid -Sid \(Get-PortListenerSid -Port \$Port\)' || return 1
  # The SID, not the account name — `NT AUTHORITY\SYSTEM` is localised.
  matches "$code" "S-1-5-18" || return 1
  # Outside the retry loop. Deny-Boot raised inside the `try` would be caught by
  # the handler that exists to tolerate a broker still starting, and the boot
  # would go on to register agents pointed at the squatter.
  matches "$code" '^    if \(-not \(Test-BrokerListenerSid' || return 1
  return 0
}

has_job_hook_acl() { # <file>
  local code
  code=$(code_of "$1")
  # One file executed by every slot on the host: read-and-execute for the slots,
  # writable by none of them. A slot that could rewrite it would be running code
  # in every OTHER slot's identity, and on a warm host in every later job's too.
  matches "$code" 'Protect-CiDirectory -Path \$script:JobHookPath -ReadOnlyUser \$SlotUsers' || return 1
  matches "$code" "Rights = 'ReadAndExecute'" || return 1
  ! matches "$code" 'Protect-CiDirectory -Path \$script:JobHookPath -SlotUser' || return 1
  # The profile is resolved from the ACCOUNT DATABASE, never from a variable the
  # job could have rewritten — the hook runs inside the agent's environment.
  matches "$code" 'ProfileImagePath' || return 1
  ! matches "$code" '\$env:USERPROFILE|\$env:APPDATA' || return 1
  # …and it refuses anything that is not a slot profile rather than recursing.
  matches "$code" "notmatch '\^ci-s\[0-9\]\+\\\$'" || return 1
  matches "$code" 'refusing to clean' || return 1
  # The credential stores it removes, on Windows paths.
  matches "$code" 'AppData.Roaming.gcloud' || return 1
}

# --- phase 5: the two obligations the controller cannot check ----------------
#
# The controller mints the registration token, writes it to this instance's
# `ci-registration-token` key, and DELETES that key as soon as GitHub reports any
# of the host's agents registered — `partial`, not only `present`. Both
# consequences below are host-side, both are silent when broken, and neither is
# visible from the controller.

has_single_registration_token_read() { # <file>
  local code n
  code=$(code_of "$1")

  # OBLIGATION (a). The read is a statement of Invoke-Phase5Registration's own
  # body — four spaces — and its value is passed down. Moved inside the foreach
  # it lands at eight, which is the whole invariant and is decidable from the
  # text exactly as the job-hook indentation check is.
  matches "$code" '^    \$regToken = Wait-RegistrationToken$' || return 1
  ! matches "$code" '^        \$regToken = Wait-RegistrationToken' || return 1

  # …and the loop consumes the VARIABLE. `-RegistrationToken (Wait-Registration…)`
  # is the same bug spelled without moving a line: slot 1 registers, the
  # controller's delete fires, and slot 2's call returns nothing.
  matches "$code" '\-RegistrationToken \$regToken' || return 1
  ! matches "$code" '\-RegistrationToken \(Wait-RegistrationToken' || return 1

  # Exactly one assignment in the whole file. A second one anywhere is a second
  # read, wherever it happens to be indented.
  n=$(printf '%s\n' "$code" | grep -cE '\$regToken = Wait-RegistrationToken')
  [ "${n:-0}" -eq 1 ] || return 1
}

has_blocking_registration_expiry() { # <file>
  local code
  code=$(code_of "$1")

  # OBLIGATION (b). The wait's timeout arm DENIES THE BOOT. Returning '' instead
  # is the tempting edit — it reads as graceful — and it is how a rebooted host
  # past the token's deletion registers with an empty token instead of being
  # reclaimed by the register-grace drain, which is the designed outcome.
  matches "$code" 'Deny-Boot \("no \$script:RegistrationTokenKey on this instance' || return 1
  # The wait is bounded, or the "block" is an unbounded hang: a host that never
  # registers, never powers off, and counts against the pool's size the whole
  # time. That is the 2h55m outage restated.
  matches "$code" '\$deadline = \(Get-Date\)\.AddSeconds\(\$TimeoutSeconds\)' || return 1
  matches "$code" 'if \(\(Get-Date\) -ge \$deadline\) \{ break \}' || return 1

  # And the second half of the same obligation: config.cmd is never reached with
  # an empty token even if something upstream stops denying the boot.
  matches "$code" 'IsNullOrWhiteSpace\(\$RegistrationToken\)' || return 1
  matches "$code" 'refusing to run config.cmd with an empty registration' || return 1
}

# --- phase 5: registration, and the recycle contract it must not break -------

has_agent_registration() { # <file>
  local code
  code=$(code_of "$1")

  # --disableupdate is an ARGUMENT, not a word in a comment. GitHub otherwise
  # forces a runner self-update that leaves the process alive while the agent is
  # offline and undispatchable — 90 minutes of stalled CI on the pool this
  # replaces, and on a warm host it takes K slots down at once.
  matches "$code" "'--unattended', '--replace', '--disableupdate', '--runasservice'" || return 1
  # A rebooted host has an agent of this name already in GitHub's list, and a
  # refused registration is a slot that never comes back.
  matches "$code" "'--replace'" || return 1
  # Copied per slot, never shared: config.cmd writes .runner and .credentials
  # into the directory it runs in, so K agents in one directory share one
  # identity.
  matches "$code" 'Copy-Item -Path \(Join-Path \$script:RunnerTemplate' || return 1
  # The ACL is re-applied AFTER config.cmd, which wrote those two files as the
  # elevated identity. Without it the agent cannot read its own credentials —
  # or, worse, a sibling can.
  matches "$code" 'Protect-CiDirectory -Path \$agent -SlotUser \$Slot\.User' || return 1
  # The environment is written on the SERVICE, before it is ever started. A
  # service started once under the SCM default has already written its state as
  # the wrong identity.
  matches "$code" 'Write-ServiceEnvironment -ServiceName \$serviceName -Environment \$Environment' || return 1
  # …and the account it ends up running as is the slot's, from the PSCredential
  # phase 1 built.
  matches "$code" 'Grant-ServiceLogonAccount -ServiceName \$serviceName -Credential \$Slot\.Credential' || return 1
  # The service name comes from the agent's own marker and is validated before it
  # reaches sc.exe — the file lives in a directory the slot account can write.
  matches "$code" 'Get-RunnerServiceName -Marker \$marker -AgentName \$name' || return 1
  # …and validated against THIS slot's agent name, not just against the shape of
  # a runner service name. A stale or restored marker naming a sibling's service
  # otherwise gets this slot's logon account and environment applied to it.
  matches "$code" 'EndsWith\("\.\$AgentName"' || return 1
  # STOPPED between config.cmd and the identity change. config.cmd --runasservice
  # starts what it installs, under the SCM default account, and neither the logon
  # account nor the environment block reaches a process already running — while
  # Start-Service on an already-running service reports success.
  matches "$code" 'Stop-Service -Name \$serviceName -Force' || return 1
  matches "$code" "WaitForStatus\\('Stopped'" || return 1
  # …and the expiry caught, because WaitForStatus throws rather than returning a
  # stale status: uncaught, the one failure this block reports is reported as a
  # bare .NET exception instead of the sentence naming the consequence.
  matches "$code" 'did not stop within' || return 1
  # Running is not the assertion; who it runs as is. This is the one check that
  # can tell a correctly identity-switched agent from one that quietly kept the
  # shared machine account.
  matches "$code" 'Test-ServiceLogonAccount -StartName \$configured -SlotUser \$Slot\.User' || return 1
  # The token never reaches the log verbatim, whatever config.cmd decides to
  # print in a future version.
  matches "$code" 'Get-RedactedLine -Line \(\[string\] \$line\) -Secret \$RegistrationToken' || return 1
  # The plaintext-password spellings this design exists to avoid. Every one of
  # them puts the slot credential in the process table of a host whose local
  # accounts run pull-request code.
  ! matches "$code" 'windowslogonpassword|password=[^\n]*\$|StartPassword' || return 1
}

has_cleared_recovery_actions() { # <file>
  local code
  code=$(code_of "$1")

  # The Windows spelling of the Linux unit's `Restart=no`, and the README's
  # recycle contract depends on it. Agents are not --ephemeral, so the controller
  # drains a host by deregistering its agents; an agent the SCM restarts after a
  # job-time failure re-registers, takes more work, and keeps a host the
  # controller believes is draining alive forever.
  matches "$code" 'sc\.exe failure[^\n]*reset= 0 actions=' || return 1
  matches "$code" 'Clear-ServiceRecoveryAction -ServiceName \$serviceName' || return 1
  # A failure to clear them is FATAL. "Best effort" here is a host that cannot be
  # retired, discovered weeks later as a machine nobody can delete.
  matches "$code" 'could not clear the recovery actions on \$ServiceName' || return 1
  # The actions list is EMPTY. The beacon and the broker carry a restart action
  # deliberately — those must come back — but writing one here is the exact
  # regression, and `actions= restart/60000` is what a reader who thinks
  # "services should be resilient" types.
  ! matches "$code" 'actions=[^\n]*restart' || return 1
}

has_worthless_host_identity_probe() { # <file>
  local code
  code=$(code_of "$1")

  # §3A replaced "the slot cannot reach the endpoint" -- a property this design
  # does not have -- with "the token the endpoint yields is worthless". Both
  # halves of the #1958 reduction are asserted, and the assertion is a 403 from
  # the real API rather than anything about a socket.
  matches "$code" 'secretmanager\.googleapis\.com' || return 1
  matches "$code" 'monitoring\.googleapis\.com' || return 1
  matches "$code" 'Test-NegativeCapability' || return 1

  # 403 and ONLY 403. The three near-misses are each a different kind of wrong:
  # 200 is the finding, $null is unproved, and 401 is a probe whose own token
  # acquisition failed and which therefore answers 401 to everything -- a
  # predicate that accepted "not 200" would score that boot perfect.
  matches "$code" 'int\] \$StatusCode -eq 403' || return 1

  # The token under test comes from the REAL metadata server. Minting it through
  # the broker would measure the runner service's environment block instead of
  # the host identity, which is the one thing this check is about.
  matches "$code" "'\\\$MetadataRoot/instance/service-accounts/default/token'" || return 1

  # The payload RECORDS; the boot script DECIDES. A verdict reached inside a
  # service running as the account under test is not evidence about that
  # account, and a verdict that failed to be written must not read as a clean
  # one -- which is what the missing-file case below is.
  matches "$code" 'the probe produced no verdict at all' || return 1

  # Both halves of the broker identity. A broker that silently fell back to the
  # host account looks like a working broker from every angle except this one.
  matches "$code" 'the broker vends' || return 1
}

has_probe_literal_guard() { # <file>
  local code
  code=$(code_of "$1")

  # Get-ProbeScript builds PowerShell SOURCE, so every value it interpolates is
  # code -- and the secret name and broker endpoint both arrive from instance
  # metadata, which §3A says outright is writable by anything holding the
  # machine's identity. One apostrophe closes the literal and appends statements
  # to a payload running with a live, unreduced host token: a larger capability
  # than the one the probe exists to disprove.
  matches "$code" 'Test-ProbeLiteral' || return 1
  matches "$code" "n = 'MetadataRoot'" || return 1
  matches "$code" 'interpolated as code' || return 1

  # An allow-list per kind, and a THROW rather than a strip. A sanitized value
  # still builds a payload, and a payload that quietly measured the wrong secret
  # is worse than a boot that stops with the reason on the console.
  matches "$code" "\\^\\[A-Za-z0-9_-\\]\\+\\\$" || return 1
  matches "$code" 'throw \("probe ' || return 1

  # Three sibling outcomes, not two. Get-ChildItem throws identically on a path
  # this account may not read and a path that is not there, so folding them
  # together lets a workspace that had not been created yet report as a proved
  # ACL boundary -- the same absence-read-as-a-pass the missing-verdict case
  # above refuses.
  matches "$code" 'UnauthorizedAccessException' || return 1
  matches "$code" 'ItemNotFoundException' || return 1
  matches "$code" 'never tested' || return 1
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

if has_unconditional_job_hooks "$SCRIPT"; then
  ok
else
  bad "the per-job credential reset hooks are conditional — a pool with no job service account gets no hook, and that is the pool where an inherited credential is worst: nothing competes with what the last workflow left behind, so it is simply what the next pull request authenticates as"
fi

if has_job_broker "$SCRIPT"; then
  ok
else
  bad "the job credential broker is missing, bound off loopback, unvalidated, unbounded, or not proven to VEND a token before agents register — a broker that answers and vends nothing turns every deploy step into a confusing auth failure at job time"
fi

if has_fail_closed_metadata "$SCRIPT"; then
  ok
else
  bad "a failed metadata read is treated as an unset attribute — one flaky read then silently turns a broker pool into a no-broker pool, or drops the image floor to 1, and the boot log says nothing a healthy boot does not also say"
fi

if has_closed_metadata_endpoint "$SCRIPT"; then
  ok
else
  bad "a pool with no job service account leaves its slots' ADC unpointed — that is not 'no credentials', it is the HOST service account, because §3A deleted the fence that gives Linux this property for free"
fi

if has_owned_broker_socket "$SCRIPT"; then
  ok
else
  bad "readiness trusts whoever answers on the broker's port — the port is free for ten seconds after any broker crash and every slot shares one loopback, so a process a previous job left behind can vend an attacker-chosen token, project and zone to every later job on this host"
fi

if has_worthless_host_identity_probe "$SCRIPT"; then
  ok
else
  bad "the boot probe no longer proves the host identity is worthless — §3A traded the metadata fence for an IAM reduction that Terraform cannot verify at plan time, so a Windows pool pointed at an unreduced host account applies clean and is only wrong once a pull request is running on it"
fi

if has_probe_literal_guard "$SCRIPT"; then
  ok
else
  bad "the probe payload interpolates metadata-derived values without an allow-list, or folds a missing sibling workspace into a denied one — the first turns a defence probe into arbitrary code holding a live host token, the second reports an ACL boundary that was never tested as proved"
fi

if has_job_hook_acl "$SCRIPT"; then
  ok
else
  bad "the reset hook is slot-writable, or resolves the profile from the job's own environment — one file is executed by every slot on the host, so a slot that can rewrite it runs code in every other slot's identity"
fi

if has_single_registration_token_read "$SCRIPT"; then
  ok
else
  bad "the registration token is read per slot rather than once above the loop — the controller deletes the key the moment GitHub reports the host partial, so slot 1 registers, the key vanishes, and every later slot silently gets nothing on a host that looks healthy"
fi

if has_blocking_registration_expiry "$SCRIPT"; then
  ok
else
  bad "a host that cannot get a registration token proceeds anyway — after the key is deleted a REBOOT must log and block so the register-grace drain reclaims the instance, not run config.cmd with an empty token"
fi

if has_agent_registration "$SCRIPT"; then
  ok
else
  bad "agent registration is missing an argument the recycle contract depends on, shares one runner directory across slots, or hands the slot password to something that takes it as plaintext"
fi

if has_cleared_recovery_actions "$SCRIPT"; then
  ok
else
  bad "the runner service keeps its SCM recovery actions — an agent the SCM restarts after a job-time failure re-registers and takes more work on a host the controller believes is draining, which is the Windows spelling of the Linux unit's Restart=no"
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
  # A sed program that matches NOTHING leaves the predicate true and reads as a
  # detected mutation only because the file was never mutated. That is the same
  # class of hole as the `describe --filter` stub: a green check over an
  # assertion that was never made. Refuse to score a case that changed nothing.
  if cmp -s "$tmp" "$SCRIPT"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    rm -f "$tmp"
    return
  fi
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

# 3. The hooks become conditional — the exact edit the invariant exists for.
mutate "hooks folded into the broker branch" \
  "s|^    \\\$block\\['ACTIONS_RUNNER_HOOK_JOB_STARTED'\\]|        \\\$block['ACTIONS_RUNNER_HOOK_JOB_STARTED']|" \
  has_unconditional_job_hooks
mutate "JOB_STARTED dropped, leaving only the completion hook" \
  "s|^    \\\$block\\['ACTIONS_RUNNER_HOOK_JOB_STARTED'\\].*||" \
  has_unconditional_job_hooks
mutate "JOB_COMPLETED dropped, leaving only the start hook" \
  "s|^    \\\$block\\['ACTIONS_RUNNER_HOOK_JOB_COMPLETED'\\].*||" \
  has_unconditional_job_hooks
mutate "hook install made conditional in Invoke-Main" \
  's|^    \$hookPath = Invoke-Phase4JobHook -SlotUsers \$slotUsers$|        $hookPath = Invoke-Phase4JobHook -SlotUsers $slotUsers|' \
  has_unconditional_job_hooks

# 4. The broker regresses to the Linux shape, or to checking the daemon.
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

# 4. An ambiguous outcome resolves TOWARD a credential again.
mutate "the metadata read back to swallowing every failure" \
  's|Test-MetadataAbsence -StatusCode \$status|$true|' \
  has_fail_closed_metadata
mutate "a transport failure read as an unset attribute" \
  's|if ($null -eq \$StatusCode) { return \$false }|if ($null -eq $StatusCode) { return $true }|' \
  has_fail_closed_metadata
mutate "the closed endpoint deleted, leaving ADC pointed at nothing" \
  's|^\$script:ClosedMetadataEndpoint.*||' \
  has_closed_metadata_endpoint
mutate "the closed endpoint left bindable by any job" \
  's|Lock-LoopbackPort -Port \$script:ClosedMetadataPort||' \
  has_closed_metadata_endpoint
mutate "the reservation weakened to a no-op" \
  's|excludedportrange|show|' \
  has_closed_metadata_endpoint
mutate "readiness back to trusting whoever answers" \
  's|Test-BrokerListenerSid -Sid (Get-PortListenerSid -Port \$Port)|$true|' \
  has_owned_broker_socket
mutate "the owner check moved back inside the retry's try block" \
  's|^    if (-not (Test-BrokerListenerSid|            if (-not (Test-BrokerListenerSid|' \
  has_owned_broker_socket
mutate "the owner matched by localisable name instead of SID" \
  's|S-1-5-18|NT AUTHORITY\\SYSTEM|g' \
  has_owned_broker_socket

# 5. The hook loses its ACL or its account-database resolution.
mutate "hook made slot-writable" \
  's|Protect-CiDirectory -Path \$script:JobHookPath -ReadOnlyUser \$SlotUsers|Protect-CiDirectory -Path $script:JobHookPath -SlotUser $SlotUsers[0]|' \
  has_job_hook_acl
mutate "read-and-execute widened to modify" \
  "s|Rights = 'ReadAndExecute'|Rights = 'Modify'|" \
  has_job_hook_acl
mutate "profile taken from the job's environment" \
  's|(Get-ItemProperty -LiteralPath \$key -Name .ProfileImagePath.).ProfileImagePath|$env:USERPROFILE|' \
  has_job_hook_acl
mutate "the not-a-slot-profile refusal removed" \
  "s|notmatch '\\^ci-s\\[0-9\\]+\\\$'|match '.'|" \
  has_job_hook_acl
mutate "the gcloud credential store no longer cleaned" \
  's|AppData\\Roaming\\gcloud|AppData\\Local\\Temp\\turbo|' \
  has_job_hook_acl

# 6. OBLIGATION (a): the one read becomes a per-slot read, in both spellings.
mutate "the token read moved inside the slot loop" \
  's|^    \$regToken = Wait-RegistrationToken$|        $regToken = Wait-RegistrationToken|' \
  has_single_registration_token_read
mutate "the loop calling Wait-RegistrationToken inline per slot" \
  's|-RegistrationToken \$regToken|-RegistrationToken (Wait-RegistrationToken)|' \
  has_single_registration_token_read

# 7. OBLIGATION (b): the reboot-after-expiry path stops blocking.
mutate "the expired-token timeout returning empty instead of denying the boot" \
  "s|Deny-Boot (\"no \$script:RegistrationTokenKey on this instance|return '' #(\"no \$script:RegistrationTokenKey on this instance|" \
  has_blocking_registration_expiry
mutate "the empty-token guard removed from Register-SlotAgent" \
  's|if (\[string\]::IsNullOrWhiteSpace(\$RegistrationToken)) {|if ($false) {|' \
  has_blocking_registration_expiry
mutate "the wait made unbounded, so a token-less host hangs instead of blocking" \
  's|if ((Get-Date) -ge \$deadline) { break }|$null = $deadline|' \
  has_blocking_registration_expiry

# 8. Registration loses an argument or a per-slot property the contract needs.
mutate "--disableupdate dropped from the config arguments" \
  "s|'--unattended', '--replace', '--disableupdate', '--runasservice'|'--unattended', '--replace', '--runasservice'|" \
  has_agent_registration
mutate "one runner directory shared by every slot" \
  's|Copy-Item -Path (Join-Path \$script:RunnerTemplate|Copy-Item -Path (Join-Path $script:SlotRoot|' \
  has_agent_registration
mutate "the ACL not re-applied after config.cmd wrote .credentials" \
  's|^    Protect-CiDirectory -Path \$agent -SlotUser \$Slot\.User$||' \
  has_agent_registration
mutate "the environment block never written to the service" \
  's|^    Write-ServiceEnvironment -ServiceName \$serviceName -Environment \$Environment$||' \
  has_agent_registration
mutate "the service left running as the SCM default identity" \
  's|^    Grant-ServiceLogonAccount -ServiceName \$serviceName -Credential \$Slot\.Credential$||' \
  has_agent_registration
mutate "the slot password handed to config.cmd as plaintext" \
  's|^\$script:RunnerTemplate.*|$p = --windowslogonpassword|' \
  has_agent_registration

# 8b. The identity change applied to a service that never stopped, or to one that
#     was never this slot's. Every one of these leaves a boot whose every log
#     line says success.
mutate "the service left running under the SCM default across the identity change" \
  's|^        Stop-Service -Name \$serviceName -Force -ErrorAction Stop$||' \
  has_agent_registration
mutate "the stop fired but never waited for, so the config lands on a live process" \
  "s|WaitForStatus('Stopped'|WaitForStatus('Running'|" \
  has_agent_registration
mutate "the stop timeout left to surface as a bare .NET exception" \
  's|did not stop within|did not stop before|' \
  has_agent_registration
mutate "the marker trusted by shape alone, so a sibling's service can be claimed" \
  's|Get-RunnerServiceName -Marker \$marker -AgentName \$name|Get-RunnerServiceName -Marker $marker -AgentName ""|' \
  has_agent_registration
mutate "the ownership suffix check dropped from the validator" \
  's|EndsWith("\.\$AgentName"|EndsWith(""|' \
  has_agent_registration
mutate "Running accepted as proof of WHO it is running as" \
  's|Test-ServiceLogonAccount -StartName \$configured -SlotUser \$Slot\.User|$true|' \
  has_agent_registration
mutate "the captured config.cmd output logged verbatim again" \
  's|Get-RedactedLine -Line (\[string\] \$line) -Secret \$RegistrationToken|[string] $line|' \
  has_agent_registration

# 9. The recovery actions come back, in each shape a "resilience" edit takes.
mutate "the clear removed from the registration path" \
  's|^    Clear-ServiceRecoveryAction -ServiceName \$serviceName$||' \
  has_cleared_recovery_actions
mutate "a restart action written instead of an empty one" \
  's|reset= 0 actions= |reset= 86400 actions= restart/60000|' \
  has_cleared_recovery_actions
mutate "a failed clear downgraded to a warning" \
  's|Deny-Boot ("could not clear the recovery actions on \$ServiceName|Write-BootLog ("recovery actions not cleared on $ServiceName|' \
  has_cleared_recovery_actions

# 10. The boot probe stops proving the reduction, in each shape that still reads
#     like a passing probe.
mutate "the negative capability check softened to anything-but-200" \
  's|int\] \$StatusCode -eq 403|[int] $StatusCode -ne 200|' \
  has_worthless_host_identity_probe
mutate "the App-key capability no longer tried at all" \
  's|secretmanager\.googleapis\.com|example\.invalid|' \
  has_worthless_host_identity_probe
mutate "the demand-metric capability no longer tried at all" \
  's|monitoring\.googleapis\.com|example\.invalid|' \
  has_worthless_host_identity_probe
mutate "the probe spending a broker-minted token instead of the host's own" \
  's|$MetadataRoot/instance/service-accounts/default/token|$BrokerEndpoint/computeMetadata/v1/instance/service-accounts/default/token|' \
  has_worthless_host_identity_probe
mutate "a probe that wrote no verdict read as a probe that found nothing" \
  's|the probe produced no verdict at all|the probe reported nothing|' \
  has_worthless_host_identity_probe
mutate "the broker identity accepted without checking whose it is" \
  's|the broker vends|the broker answered as|' \
  has_worthless_host_identity_probe

# --- group 11: the payload builder trusts a metadata-derived value -----------
mutate "the interpolation allow-list dropped altogether" \
  's|Test-ProbeLiteral|Confirm-ProbeLiteral|g' \
  has_probe_literal_guard
mutate "a rejected value sanitized into a payload instead of stopping the boot" \
  's|throw ("probe |Write-BootLog ("probe |' \
  has_probe_literal_guard
mutate "an absent sibling workspace read as a denied one" \
  's|ItemNotFoundException|OperationCanceledException|' \
  has_probe_literal_guard
mutate "the untested-ACL sentence renamed out of the verdict" \
  's|never tested|not checked|' \
  has_probe_literal_guard

printf 'windows-host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
