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
  # The broker LISTENS on this port, so the ephemeral range is out: a bind
  # inside 49152-65535 succeeds and then loses the port to an outbound socket
  # the host opened first, which reads in the log as a broker that installed
  # and never answered. Availability, not a credential -- but this picker is
  # the only place that can tell a chosen port from a handed-out one.
  matches "$code" '^\$script:EphemeralPortFloor = 49152$' || return 1
  matches "$code" 'if \(\$port -ge \$script:EphemeralPortFloor\) \{ return \$Default \}' || return 1
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
  # Anchored to the CALL SITE rather than to the words. `refusing to` also
  # appears in the job hook's text and in the account-name rejection, so the
  # bare string stayed true with Get-MetadataValue's refusal reworded, moved
  # or deleted outright -- a sub-check that could not go false, which reports
  # ok forever.
  matches "$code" 'Deny-Boot \("could not read metadata .* refusing to ' || return 1
  matches "$code" 'treat an unreadable attribute as an unset one' || return 1
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
  # Anchored to the CODE, because code_of keeps `<# ... #>` bodies and the
  # docstring above the hook says ProfileImagePath too -- so the bare token
  # was true whatever the hook actually read.
  matches "$code" 'Get-ItemProperty -LiteralPath \$key -Name .ProfileImagePath.' || return 1
  matches "$code" 'GetCurrent\(\)\.User\.Value' || return 1
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
  matches "$code" 'Clear-ServiceRecoveryAction -ServiceName \$serviceName -AgentName \$name' || return 1

  # OWNERSHIP travels with the name, at every call site. -AgentName is mandatory
  # on Get-RunnerServiceName because shape alone accepts a sibling slot's
  # well-formed service name, and one caller kept the old two-argument form --
  # a ParameterBindingException in phase 5 on every Windows boot, in a function
  # the parse gate and the analyzer both read and passed. A gate that reads text
  # cannot bind parameters, so the shape of the CALL is what it can check.
  local bare
  bare=$(printf '%s\n' "$code" | grep -E 'Get-RunnerServiceName -Marker' | grep -cvE '\-AgentName')
  [ "${bare:-0}" -eq 0 ] || return 1
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

  # THE POSITIVE CONTROL, and the reason it is in the same function as the two
  # negatives: it is what makes them mean anything. Secret Manager answers 403
  # for a resource the caller may not read AND for one that does not exist, so a
  # misspelled `ci-app-key-secret` scores exactly like a reduced identity -- and
  # an identity that can do nothing at all scores perfect on both checks above.
  # One assertion therefore runs the other way: the host token MUST still be
  # able to mint a token for the job service account.
  matches "$code" 'iamcredentials\.googleapis\.com' || return 1
  matches "$code" 'Test-PositiveCapability' || return 1
  matches "$code" 'int\] \$StatusCode -eq 200' || return 1

  # 200 and only 200, for the mirror image of the reason 403 is the only
  # negative pass: this is the check that certifies the measurement, so reading
  # a failure to measure as a pass would make it certify itself.
  matches "$code" 'not 200' || return 1
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

# --- phase 6's harness: the half that ACTS on the verdict --------------------
#
# The pure half is asserted above (has_worthless_host_identity_probe,
# has_probe_literal_guard). The three below are about the half that runs it, and
# each covers a way the phase could keep every one of those checks and still
# prove nothing:
#
#   proved too late   an agent registered before the probe finishes is an agent
#                     GitHub can hand a job to while the proof is still running.
#                     Phase 6's number is older than its position; only the ORDER
#                     of the two calls in Invoke-Main carries the property, and
#                     nothing in PowerShell notices if they swap.
#
#   proved and ignored a verdict nobody acts on is a comment. The two shapes that
#                     look most like working code are a finding logged instead of
#                     denied, and a probe that produced no verdict at all being
#                     read as a probe that found nothing.
#
#   proved by the subject the verdict is written by the very account under test.
#                     Without an ACL any slot could pre-answer it, and without a
#                     freshness guarantee a file left by the PREVIOUS boot is a
#                     complete, plausible, passing verdict for this one.

# Line number of the first line of <code> matching <ere>, or '' when there is
# none. Never `| head -1` -- head exits on the first line, the writer upstream
# takes SIGPIPE, and pipefail turns a successful match into a failure. sed
# consumes the whole stream, which is why it is the tool here.
line_of() { # <text> <ere>
  printf '%s\n' "$1" | grep -nE -- "$2" | sed -n '1s/^\([0-9][0-9]*\):.*/\1/p'
}

has_probe_before_registration() { # <file>
  local code probe reg
  code=$(code_of "$1")

  # Both calls are single statements of Invoke-Main's own body -- four spaces --
  # which is what makes the ordering decidable from the text at all, and what
  # stops either being folded into a branch the way the job hooks nearly were.
  matches "$code" '^    Invoke-Phase6BootProbe -Provisioned \$provisioned -Config \$cfg -BrokerEndpoint \$brokerEndpoint$' || return 1
  matches "$code" '^    Invoke-Phase5Registration -Provisioned \$provisioned -Config \$cfg' || return 1
  ! matches "$code" '^        Invoke-Phase6BootProbe' || return 1

  probe=$(line_of "$code" '^    Invoke-Phase6BootProbe ')
  reg=$(line_of "$code" '^    Invoke-Phase5Registration ')
  [ -n "$probe" ] && [ -n "$reg" ] || return 1
  [ "$probe" -lt "$reg" ] || return 1
}

has_fatal_boot_probe() { # <file>
  local code
  code=$(code_of "$1")

  # The verdict is handed to the pure decider, and the decider's answer is acted
  # on. Get-ProbeFailure already returns the missing-verdict case as a finding,
  # so $null flows through this same branch -- there is no separate "no file"
  # path that could be made lenient on its own.
  matches "$code" 'Get-ProbeFailure -Result \$verdict -JobServiceAccount \$Config\.JobSa' || return 1
  matches "$code" 'if \(\$findings\.Count -gt 0\) \{' || return 1
  matches "$code" 'Deny-Boot \("the boot probe found ' || return 1

  # A service that will not start is fatal WHERE IT HAPPENS. Both roads end in a
  # denied boot, but only this one names the fault; the other reports "no verdict
  # at all" three minutes later and sends the reader to the wrong place.
  matches "$code" 'Deny-Boot \("the boot probe service would not start as \$SlotUser' || return 1

  # …and the wait is BOUNDED, by a timeout short enough that the deny happens
  # while the host is still booting rather than an hour into its life. Wait-
  # ProbeVerdict's value IS its verdict, so the timeout is reported by the
  # caller and the function itself emits nothing else.
  matches "$code" '\[int\] \$TimeoutSeconds = \$script:ProbeWaitSeconds' || return 1
  matches "$code" '\$script:ProbeWaitSeconds = 180' || return 1
  matches "$code" 'if \(\(Get-Date\) -ge \$deadline\) \{ break \}' || return 1
}

has_probe_verdict_acl() { # <file>
  local code prep inst
  code=$(code_of "$1")

  # ONE slot writes the verdict, and it is the slot being measured. -ReadOnlyUser
  # would be the tidy-looking edit and it is the wrong one twice over: it hands
  # every slot on the host read access to the file, and it takes the write away
  # from the account that has to produce it.
  matches "$code" 'Protect-CiDirectory -Path \$script:ProbeResultPath -SlotUser \$SlotUser' || return 1
  ! matches "$code" 'Protect-CiDirectory -Path \$script:ProbeResultPath -ReadOnlyUser' || return 1

  # FRESHNESS, and not staleness. A verdict left by the previous boot is a
  # complete, plausible, passing document, and "is it old?" is a question decided
  # from a timestamp the writer controls. Removed and re-created empty before the
  # service exists; a removal that did not take denies the boot.
  matches "$code" 'Remove-Item -LiteralPath \$script:ProbeResultPath -Force' || return 1
  matches "$code" 'Deny-Boot \("could not remove a pre-existing \$script:ProbeResultPath' || return 1

  # …and that happens BEFORE the service is installed, or the guarantee is that
  # the file was fresh some time after the probe already ran.
  prep=$(line_of "$code" 'Protect-ProbeVerdictFile -SlotUser \$slot\.User')
  inst=$(line_of "$code" 'Install-BootProbeService -ScriptText \$payload')
  [ -n "$prep" ] && [ -n "$inst" ] || return 1
  [ "$prep" -lt "$inst" ] || return 1

  # The payload the slot executes is readable by it and writable by nobody. A
  # slot that could rewrite the payload decides what its own verdict says.
  matches "$code" 'Protect-CiDirectory -Path \$script:ProbeScriptPath -ReadOnlyUser @\(\$SlotUser\)' || return 1
}

# --- §3A's third bullet: the token must be witnessed GONE --------------------
#
# The controller deletes `ci-registration-token` once GitHub reports the host
# registered. Nothing proved it had. A key left behind is a live repository
# registration token in instance metadata, which §3A says outright is readable by
# anything holding this machine's identity -- and by the time phase 5 ends, that
# includes pull-request code in a slot.

has_registration_token_witness() { # <file>
  local code reg wit
  code=$(code_of "$1")

  matches "$code" '^    Wait-RegistrationTokenRemoved$' || return 1
  # FATAL, not a log line, AND not only fatal -- see has_registration_token_-
  # containment for the half a bare throw does not buy here.
  matches "$code" 'Deny-Boot \("\$script:RegistrationTokenKey is STILL on this instance' || return 1

  # POLLED to a bound, not read once. The controller deletes on its own tick, so
  # a single read taken the instant the last agent came up fails on a healthy
  # fleet -- and an unbounded one is the 2h55m outage restated.
  matches "$code" 'Get-JitteredTimeout -BaseSeconds \$script:TokenRemovalWaitSeconds' || return 1
  matches "$code" 'if \(\(Get-Date\) -ge \$deadline\) \{ break \}' || return 1

  # …and the bound is SPREAD. One controller is the shared dependency of every
  # host booting at once, so a fixed deadline turns a controller hiccup during a
  # scale-out into every host in the window denying together -- a fleet-wide
  # refusal to serve at the moment capacity is being asked for. The jitter is
  # the difference between that and a stagger nobody notices, and "tidy it back
  # to a constant" is the edit this line exists to catch.
  matches "$code" '\$script:TokenRemovalJitterSeconds = [1-9]' || return 1
  matches "$code" '\-JitterSeconds \$script:TokenRemovalJitterSeconds' || return 1

  # …and it looks AFTER the agents registered. Before them it asserts nothing:
  # the key is supposed to still be there.
  reg=$(line_of "$code" 'Register-SlotAgent -Slot \$slot -RegistrationToken \$regToken')
  wit=$(line_of "$code" '^    Wait-RegistrationTokenRemoved$')
  [ -n "$reg" ] && [ -n "$wit" ] || return 1
  [ "$reg" -lt "$wit" ] || return 1
}

# --- and the witness is backed by an actual containment ----------------------
#
# Every OTHER Deny-Boot in the boot script fires before an agent exists, so the
# host reads reg=absent at the controller and drain_decision's
# `never-registered` arm reclaims it. THAT ARM IS NOT REACHABLE FROM HERE. By
# the time the witness runs the agents have registered, so the host reads
# `present`; and recycle_decision refuses anything whose instance template is
# not `stale`, which registration state has no bearing on. A bare throw would
# leave a host in the pool, taking jobs, with a live registration token in its
# metadata and a FATAL line nobody is reading.
#
# Stopping the runner services is what closes that. GitHub dispatches nothing to
# an offline runner; host_facts() counts by NAME so the host stays `present` and
# busy=0; drain_decision's ordinary idle rule then retires it. Stopped and NOT
# deregistered on purpose -- deregistering drops it to `absent`, where it is
# drained as a failed boot, which is the wrong diagnosis and loses the logs.
has_registration_token_containment() { # <file>
  local code stop deny
  code=$(code_of "$1")

  matches "$code" '^    Stop-RunnerService$' || return 1
  matches "$code" "NamePattern = 'actions\.runner\.\*'" || return 1

  # The pattern is CONSTRAINED. Stop-Service -Force stops dependents too, so a
  # widened pattern does not merely over-stop: a bare `*` takes the beacon and
  # the job broker down with the agents, and the beacon is what tells the
  # controller this host is alive. Nothing attacker-influenced reaches the
  # parameter today, which is a fact about the call sites and not the function.
  matches "$code" "ValidatePattern\('\^actions" || return 1
  matches "$code" 'A-Za-z0-9\._\*-\]\+' || return 1

  # BEFORE the throw. After it is dead code, and dead code here reads exactly
  # like a containment that is present.
  stop=$(line_of "$code" '^    Stop-RunnerService$')
  deny=$(line_of "$code" 'Deny-Boot \("\$script:RegistrationTokenKey is STILL on this instance')
  [ -n "$stop" ] && [ -n "$deny" ] || return 1
  [ "$stop" -lt "$deny" ] || return 1
}

# --- the probe has to say WHO answered ---------------------------------------
#
# Every other field in the verdict -- hostToken, secretStatus, metricStatus,
# dnsResolved -- is an answer from the metadata server, which answers the
# MACHINE and does not care which local account asked. So a probe that silently
# stayed LocalSystem passes all of them, and the one part of phase 6 with no
# hardware behind it is the very part that would go unnoticed.
#
# It is caught today only by accident: Protect-CiDirectory always grants
# S-1-5-18 FullControl, so a LocalSystem probe reads the sibling workspace and
# `siblingStatus` comes back `allowed`. That is an ACL side effect, not a check,
# and it dies the day someone adds a -ReadOnlyUser or widens C:\ci\bin.
has_probe_identity_assertion() { # <file>
  local code
  code=$(code_of "$1")

  # The process token, not the environment block. A service's environment is
  # data the SCM copies in and this script rewrites elsewhere, so it can say one
  # thing while the process runs as another -- the exact divergence being tested
  # for. GetCurrent() reads the token the access checks are made against.
  # Anchored on the ASSIGNMENT and not on the API: line 748 already calls
  # WindowsIdentity::GetCurrent().User.Value for an unrelated reason, so the
  # bare call is present whether the payload records anything or not.
  matches "$code" "runningAs = ''; hostToken" || return 1
  matches "$code" 'runningAs = \[string\] \(\[System.Security.Principal.WindowsIdentity\]::GetCurrent\(\).Name\)' || return 1

  # MANDATORY and defaulted to nothing. A default would make the one assertion
  # that distinguishes the two runs skippable by omission.
  matches "$code" 'Mandatory = \$true\)\]\[AllowEmptyString\(\)\]\[string\] \$ExpectedIdentity' || return 1
  matches "$code" "the probe ran as '\\\$ran' and not \\\$ExpectedIdentity" || return 1
  matches "$code" 'the probe did not report which account it ran as' || return 1

  # …and the harness hands it the account it actually repointed the service to,
  # rather than a constant that would agree with itself.
  matches "$code" '\-ExpectedIdentity \$slot\.User' || return 1
}

# --- the slot has to be able to LOAD the thing it is started as --------------
#
# The probe service's binPath is the shim itself, and phase 1 locks C:\ci,
# C:\ci\bin and C:\ci\slots to SYSTEM and Administrators with inheritance
# disabled -- so ci-service-shim.exe carries no ACE for any slot. Repointing the
# service at the slot and starting it makes the SCM launch an image that token
# may neither read nor execute: ERROR_ACCESS_DENIED, a 1053, and a Deny-Boot on
# every host in the pool. The payload and its config were granted for exactly
# this reason; the binary that reads them was missed, and the shape of the bug
# is that the whole phase looks correct and denies every boot.
has_probe_shim_loadable_by_slot() { # <file>
  local code raw grant inst
  code=$(code_of "$1")
  # The bypass-traverse assertion below is the one thing in this file that has to
  # be checked against the RAW text: it lives in a comment, and code_of strips
  # exactly those. Everything else uses $code, so a comment can never satisfy it.
  raw=$(cat "$1")

  # READ AND EXECUTE, never Modify. A slot able to write this binary owns the
  # beacon and the broker, which the SCM re-executes as LocalSystem next reboot.
  matches "$code" 'Protect-CiDirectory -Path \$script:ServiceShim -ReadOnlyUser @\(\$SlotUser\)' || return 1
  ! matches "$code" 'Protect-CiDirectory -Path \$script:ServiceShim -SlotUser' || return 1

  # …and it is granted BEFORE the shim is asked to install the service, not after
  # the SCM has already failed to load it.
  grant=$(line_of "$code" 'Protect-CiDirectory -Path \$script:ServiceShim -ReadOnlyUser')
  inst=$(line_of "$code" 'Grant-ServiceLogonAccount -ServiceName \$script:ProbeServiceName')
  [ -n "$grant" ] && [ -n "$inst" ] || return 1
  [ "$grant" -lt "$inst" ] || return 1

  # The reliance on bypass-traverse-checking is WRITTEN DOWN. C:\ci and C:\ci\bin
  # stay SYSTEM-and-Administrators-only, so a file-level ACE is reachable only
  # because SeChangeNotifyPrivilege is granted to Everyone by default -- the kind
  # of default a hardened image removes, and an undocumented dependency on it is
  # how the next image bump becomes an unexplainable fleet-wide 1053.
  matches "$raw" 'THIS RELIES ON BYPASS-TRAVERSE-CHECKING' || return 1
}

# --- and it must not still be able to afterwards -----------------------------
#
# Phase 6 hands the probing slot three grants; phase 5 then starts pull-request
# code as that same account. No exploit route through them was found, and that
# is a statement about today's layout rather than an invariant. Revoking makes
# "no slot ACE anywhere under C:\ci" literally true instead of true-by-argument.
has_probe_teardown_invariants() { # <file>
  local code clear revoke
  code=$(code_of "$1")

  matches "$code" '^        Revoke-ProbeSlotAccess$' || return 1
  matches "$code" '\$script:ProbeRoot, \$script:ProbeResultPath, \$script:ServiceShim' || return 1

  # The revert is Protect-CiDirectory with NO -SlotUser. The function rewrites
  # the ACL from scratch, so there is no ACE to remove by hand.
  matches "$code" '^            Protect-CiDirectory -Path \$path$' || return 1

  # FATAL, unlike the service delete. A service left installed runs nothing; an
  # ACE left behind is a standing grant to the account about to run job code.
  matches "$code" "Deny-Boot \\(\"could not take the boot probe's grant on \\\$path" || return 1

  # AFTER the stop-and-delete, or it races the measurement, and inside the
  # finally, because Install-BootProbeService's own denials pass through here.
  clear=$(line_of "$code" '^        Clear-BootProbeService$')
  revoke=$(line_of "$code" '^        Revoke-ProbeSlotAccess$')
  [ -n "$clear" ] && [ -n "$revoke" ] || return 1
  [ "$clear" -lt "$revoke" ] || return 1

  # sc.exe by ABSOLUTE PATH. This process is LocalSystem and a bare name is
  # resolved by CreateProcess's search order; SystemPaths.Tool in
  # ci-service-shim.cs states the rule and this was the one call that broke it.
  matches "$code" "Join-Path \\\$env:SystemRoot 'System32.sc\.exe'" || return 1
  ! matches "$code" '& sc\.exe delete' || return 1
}

# --- the sibling verdict has to say WHICH exception it saw -------------------
#
# `denied` passes and `missing` denies the boot, and the payload tells them apart
# by exception type. Which exception Windows PowerShell 5.1 raises for an
# ACL-denied Get-ChildItem is NOT observed on a real host: it is documented as
# UnauthorizedAccessException and also reported as surfacing item-not-found-
# shaped. If the second is what happens, every host in the pool reports `missing`
# and denies its boot -- the same fleet-wide outcome as an unloadable shim, from
# a second unverified assumption on the same path. Recording the concrete type
# means the first real boot answers the question instead of the next reader
# re-deriving it, and is the difference between fixing phase 6 and weakening it.
has_sibling_exception_type_recorded() { # <file>
  local code
  code=$(code_of "$1")

  matches "$code" "siblingStatus = 'unrun'; siblingErrorType = ''" || return 1
  matches "$code" 'siblingErrorType = \[string\] .\$_\.Exception\.GetType\(\)\.FullName' || return 1

  # Both non-denied findings carry it. A type recorded into a file nothing prints
  # is a type nobody reads.
  matches "$code" "\\\$siblingType = \\[string\\] \\(& \\\$get 'siblingErrorType'\\)" || return 1
  matches "$code" 'the exception was \$siblingType' || return 1
  matches "$code" '\-\- \$sawType, and if that names an access denial' || return 1
  matches "$code" 'ACLs are unproved, and \$sawType' || return 1
}

# --- the runtime this script is actually executed by -------------------------
#
# The boot script reaches a host as the `windows-startup-script-ps1` metadata
# key, and the guest agent runs that key with the in-box powershell.exe: Windows
# PowerShell 5.1, on .NET Framework 4.8. Never pwsh. Nothing else in this
# repository can see that, and all three existing gates are blind to it in the
# same way: the parser and PSScriptAnalyzer only READ the text, and the Pester
# suite runs the very same functions under pwsh 7 on a Linux runner, where the
# whole .NET Core surface exists. So a .NET Core-only call passes every check
# here and then throws MethodNotFound on the first real boot, in phase 1, before
# a single slot account exists -- which is how `RandomNumberGenerator::Fill`
# shipped and how every host in the pool came to deny its own boot.
#
# This is the third time a gate that reads has passed code that dies, so the
# deny-list below is checked against the text the same way, and is deliberately
# small: every entry is documented as absent from .NET Framework or from Windows
# PowerShell 5.1, and every entry is something a reasonable person would reach
# for while editing THIS file. A general "is it 5.1-safe" rule is not expressible
# in grep, and PSScriptAnalyzer's PSUseCompatibleSyntax would not have helped
# either -- it checks language syntax, and `::Fill(...)` is valid 5.1 syntax for
# a method 5.1 does not have.
# --- invariant: the boot log never enters the success stream -----------------
#
# Write-BootLog is called 28 times and several of its callers CAPTURE the value
# of the function that called it. `Write-Output` puts the line on the success
# stream, so every one of those captures becomes an object[] of the log lines
# followed by the value -- and that is boot-fatal in three separate places, none
# of which is a diagnostics problem:
#
#   phase 0 never starts   Install-BeaconService logs and returns $scriptPath;
#                          Invoke-Phase0Preflight dot-sources it with
#                          `. $beaconPath`. Dot-sourcing an object[] fails, so
#                          the FIRST phase denies the boot on every host.
#
#   every slot mis-registers  Wait-RegistrationToken logs and returns the token.
#                          Register-SlotAgent takes [string], and PowerShell
#                          coerces an object[] to a string by joining its
#                          elements with a space -- so config.cmd's --token gets
#                          a timestamped log line with the real token stuck on
#                          the end.
#
#   phase 5 never binds    Invoke-Phase0Preflight returns $cfg, and
#                          Invoke-Phase5Registration's -Config is
#                          [System.Collections.IDictionary]. Member access like
#                          $cfg.Slots survives by member enumeration, which is
#                          precisely why this looks like it works, but the
#                          parameter bind does not.
#
# The Pester suite cannot see any of this: it runs the pure functions, and the
# one impure path it touches does `Mock -CommandName Write-BootLog -MockWith {}`,
# which removes the pollution as a side effect of the mock. So the assertion
# lives here, on the text, scoped to the function -- `Write-Output` elsewhere in
# a 2700-line file is nobody's bug, and it is only inside this one function that
# it poisons every caller's return value.
bootlog_body_of() { # <file>
  code_of "$1" | sed -n '/^function Write-BootLog {$/,/^}$/p'
}

has_uncapturable_boot_log() { # <file>
  local body
  body=$(bootlog_body_of "$1")

  # The anchor first. A rename or a reformat that makes the range extract
  # nothing would leave every check below vacuously true -- the same green-over-
  # an-assertion-never-made hole the mutate() harness refuses to score.
  matches "$body" '^function Write-BootLog \{$' || return 1

  # The regression itself.
  ! matches "$body" 'Write-Output' || return 1
  # The same fault with no cmdlet to grep for: a bare `$line` on its own is an
  # expression statement, and an expression statement IS the success stream.
  ! matches "$body" '^[[:space:]]*\$line[[:space:]]*$' || return 1
  # Behaviourally correct and CI-fatal: PSAvoidUsingWriteHost is Warning
  # severity and powershell-gate.sh runs PSScriptAnalyzer at
  # -Severity Error,Warning with no exclusions.
  ! matches "$body" 'Write-Host' || return 1

  # And the form that must be there. [Console]::Out writes to the process's own
  # stdout handle -- which is what the guest agent captures, so the boot log is
  # unchanged where anyone reads it -- and is unreachable from `$x = f`. It is
  # .NET Framework 4.8-safe, so it does not need a has_5_1_compatible_apis
  # entry; the same class is already used at [Console]::Error.WriteLine in the
  # job-hook payload.
  matches "$body" '\[Console\]::Out\.WriteLine\(\$line\)' || return 1

  # Losing the log must still never stop a boot: the file write stays wrapped
  # and its failure stays swallowed.
  matches "$body" 'Add-Content -Path \$script:LogPath -Value \$line -ErrorAction Stop' || return 1
}

has_5_1_compatible_apis() { # <file>
  local code
  code=$(code_of "$1")

  # RandomNumberGenerator.Fill(Span<byte>): netcore-2.1 and netstandard-2.1
  # onward, with no netframework moniker at all. The original bug.
  ! matches "$code" 'RandomNumberGenerator\]::Fill' || return 1
  # RandomNumberGenerator.GetInt32: netcore-3.0/netstandard-2.1 onward, also
  # absent from .NET Framework. It is what the next reader reaches for to remove
  # the modulo bias the slot-password comment discusses, and it fails the same
  # way in the same function.
  ! matches "$code" 'RandomNumberGenerator\]::GetInt32' || return 1
  # ConvertFrom-Json -AsHashtable: introduced in PowerShell 6.0. The metadata
  # reads in this script all parse JSON, so this one is a step away at all times.
  ! matches "$code" '\-AsHashtable' || return 1
  # -SkipHttpErrorCheck on Invoke-WebRequest/Invoke-RestMethod: PowerShell 7.0.
  # This script catches WebException specifically BECAUSE 5.1 has no such switch,
  # so "simplifying" that error handling is the obvious edit.
  ! matches "$code" '\-SkipHttpErrorCheck' || return 1
  # ForEach-Object -Parallel: PowerShell 7.0. Boot time is the thing every
  # optimisation aims at, and the slot loops are the obvious target.
  ! matches "$code" 'ForEach-Object[[:space:]]+-Parallel' || return 1
  # Split-Path -LeafBase: PowerShell 6.0. This script already calls
  # `Split-Path -Leaf` on a profile directory.
  ! matches "$code" '\-LeafBase' || return 1
  # ConvertFrom-Json -Depth: PowerShell 6.2. Phase 6 parses the probe's verdict
  # with ConvertFrom-Json, and -Depth is the first thing anybody reaches for the
  # day a nested field is added to it.
  # `.*` and not `[^\n]*`: grep is line-based, so a bracket expression written
  # `[^\n]` is read as "not the letter n and not a backslash" -- which excludes
  # the `n` in `-InputObject` and quietly stops the pattern matching anything.
  ! matches "$code" 'ConvertFrom-Json.*-Depth' || return 1
  # Get-Content -AsByteStream: PowerShell 6.0, where it replaced 5.1's
  # `-Encoding Byte`. Phase 6 reads the verdict file back with `Get-Content
  # -Raw` while another process may still be writing it, which is exactly the
  # situation that invites a byte-level read.
  ! matches "$code" '\-AsByteStream' || return 1

  # A deny-list on its own also passes a file that draws no entropy whatsoever,
  # so the compatible form has to be positively present. Create(), the instance
  # GetBytes(byte[]) and Dispose() are in every .NET Framework this fleet can
  # boot on and in .NET Core, which is what makes them the one form that runs in
  # both runtimes.
  matches "$code" 'RandomNumberGenerator\]::Create\(\)' || return 1
  matches "$code" '\$rng\.GetBytes\(' || return 1
  matches "$code" '\$rng\.Dispose\(\)' || return 1
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

if has_probe_before_registration "$SCRIPT"; then
  ok
else
  bad "the boot probe does not run before agent registration — a host that proves its identity is not worthless must never accept a job, and an agent registered first can be handed one while the proof is still running"
fi

if has_fatal_boot_probe "$SCRIPT"; then
  ok
else
  bad "a boot-probe finding, a probe service that will not start, or a verdict that never arrived no longer stops the boot — a probe that silently no-ops is worse than no probe, because it puts a phase-6 line in the boot log of a host nothing has ever proved anything about"
fi

if has_probe_verdict_acl "$SCRIPT"; then
  ok
else
  bad "the boot probe's verdict file is writable by more than the slot under test, or is not proven to have been created by THIS boot — the file decides whether the host registers and is written by the account being measured, so a shared ACL lets a job pre-answer it and a leftover file answers it from the previous boot"
fi

if has_registration_token_witness "$SCRIPT"; then
  ok
else
  bad "nothing witnesses that the registration token left this instance's metadata, or the wait for it is a constant every host crosses at the same instant — §3A requires the host to confirm the controller's delete, because a key left behind is a live repository registration token readable by every job on the host; and one controller is the shared dependency of every host booting at once, so an unjittered bound turns a controller hiccup during a scale-out into a fleet-wide refusal to serve"
fi

if has_registration_token_containment "$SCRIPT"; then
  ok
else
  bad "the witness throws without stopping this host's runner services — no drain rule reclaims a host whose agents DID register, so a bare throw leaves it in the pool taking jobs with a live registration token in its metadata and a FATAL line nobody is reading"
fi

if has_probe_identity_assertion "$SCRIPT"; then
  ok
else
  bad "the boot probe does not report or assert which account produced its verdict — every other field it writes is an answer from the metadata server, which answers the machine and not the caller, so a probe that silently stayed LocalSystem proves nothing about the boundary a job runs behind and says it proved everything"
fi

if has_probe_shim_loadable_by_slot "$SCRIPT"; then
  ok
else
  bad "the probe service is repointed at a slot account that has no right to read or execute the shim the SCM must load for it — C:\\ci\\bin is SYSTEM-and-Administrators-only with inheritance disabled, so the start fails with a 1053 and phase 6 denies the boot of every host in the pool while every line of the phase reads as correct"
fi

if has_probe_teardown_invariants "$SCRIPT"; then
  ok
else
  bad "the grants phase 6 hands the probing slot are still in place when phase 5 starts pull-request code as that same account, or the service delete resolves sc.exe from PATH in a LocalSystem process — 'no slot ACE under C:\\ci' has to be true of the host, not an argument about which of today's files happen to be exploitable"
fi

if has_sibling_exception_type_recorded "$SCRIPT"; then
  ok
else
  bad "the sibling check maps an exception type to a pass-or-deny verdict without recording which exception it actually saw — an ACL-denied enumeration on 5.1 is unobserved and may surface item-not-found-shaped, in which case every host reports 'missing' and denies its boot, and the verdict file will not say whether the ACL held or the mapping is wrong"
fi

if has_5_1_compatible_apis "$SCRIPT"; then
  ok
else
  bad "the boot script calls an API that PowerShell 7 has and Windows PowerShell 5.1 does not, or no longer draws its entropy the way both runtimes support — the guest agent runs this file with the in-box powershell.exe, so the call throws MethodNotFound at boot and every host in the pool denies itself, while the parser, the analyzer and a Pester suite running under pwsh 7 all stay green"
fi

if has_uncapturable_boot_log "$SCRIPT"; then
  ok
else
  bad "Write-BootLog writes to the SUCCESS stream, so every function that logs and then returns a value returns an object[] of the log lines plus the value -- phase 0 cannot dot-source the beacon path it captured, config.cmd's --token receives a timestamped log line joined to the token, and the phase 0 config no longer binds to Invoke-Phase5Registration's [IDictionary]. The Pester suite cannot see this: it mocks Write-BootLog away on the one impure path it touches"
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
mutate "the unreadable-metadata refusal reworded out of existence" \
  's|could not read metadata|metadata was not available|' \
  has_fail_closed_metadata
mutate "the refusal stops saying what it will not do with the value" \
  's|treat an unreadable attribute as an unset one|carry on|' \
  has_fail_closed_metadata
mutate "the broker may be handed an ephemeral port" \
  '/-ge \$script:EphemeralPortFloor/d' \
  has_job_broker
mutate "the ephemeral floor moves above the range a socket accepts" \
  's|EphemeralPortFloor = 49152|EphemeralPortFloor = 65536|' \
  has_job_broker
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
mutate "the profile resolved without touching the account database" \
  '/Get-ItemProperty -LiteralPath \$key -Name .ProfileImagePath./d' \
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
  's|^    Clear-ServiceRecoveryAction -ServiceName \$serviceName -AgentName \$name$||' \
  has_cleared_recovery_actions
mutate "the recovery clear given a name without the slot that owns it" \
  's|Clear-ServiceRecoveryAction -ServiceName \$serviceName -AgentName \$name|Clear-ServiceRecoveryAction -ServiceName $serviceName|' \
  has_cleared_recovery_actions
mutate "the guard re-validating shape but no longer ownership" \
  's|Get-RunnerServiceName -Marker \$ServiceName -AgentName \$AgentName|Get-RunnerServiceName -Marker $ServiceName|' \
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

# --- group 12: a .NET Core-only API in a file 5.1 has to run -----------------
#     Each of these is the edit that reintroduces one deny-list entry, plus the
#     two that remove the compatible entropy draw. They all lint, parse and pass
#     Pester under pwsh 7.
mutate "the original regression: the static Fill back in place of Create()" \
  's|RandomNumberGenerator\]::Create()|RandomNumberGenerator]::Fill($bytes)|' \
  has_5_1_compatible_apis
mutate "the modulo bias 'fixed' with the class's bounded-integer helper" \
  's|RandomNumberGenerator\]::Create()|RandomNumberGenerator]::GetInt32(0, 255)|' \
  has_5_1_compatible_apis
mutate "a metadata response parsed straight into a hash table" \
  's|Invoke-RestMethod|ConvertFrom-Json -AsHashtable|' \
  has_5_1_compatible_apis
mutate "the WebException handling simplified into an error-check switch" \
  's|Invoke-WebRequest|Invoke-WebRequest -SkipHttpErrorCheck|' \
  has_5_1_compatible_apis
mutate "the slot loop parallelised to shorten boot" \
  's|ForEach-Object {|ForEach-Object -Parallel {|' \
  has_5_1_compatible_apis
mutate "the profile name taken with the base-name switch" \
  's|Split-Path -Leaf |Split-Path -LeafBase |' \
  has_5_1_compatible_apis
mutate "the generator leaked instead of disposed" \
  's|\$rng\.Dispose()||' \
  has_5_1_compatible_apis
mutate "the byte draw removed, leaving a password built from an empty buffer" \
  's|\$rng\.GetBytes(\$bytes)||' \
  has_5_1_compatible_apis
mutate "the verdict parse given a depth limit" \
  's|ConvertFrom-Json -InputObject \$raw|ConvertFrom-Json -InputObject $raw -Depth 8|' \
  has_5_1_compatible_apis
mutate "the verdict read byte-wise to survive a partial write" \
  's|Get-Content -Raw -LiteralPath \$script:ProbeResultPath|Get-Content -AsByteStream -LiteralPath $script:ProbeResultPath|' \
  has_5_1_compatible_apis

# --- group 13: the probe proves the boundary too late, or not at all ---------
#     sed cannot reorder, so the ordering case is spelled as a delete plus a
#     re-insert of the identical call after phase 5 -- which is exactly the edit
#     a reader "tidying the phases into numeric order" would make.
mutate "the probe moved after registration, where a job can arrive mid-proof" \
  's|^    Invoke-Phase6BootProbe .*||
   s|^        -HookPath \$hookPath -BrokerEndpoint \$brokerEndpoint$|        -HookPath $hookPath -BrokerEndpoint $brokerEndpoint\n    Invoke-Phase6BootProbe -Provisioned $provisioned -Config $cfg -BrokerEndpoint $brokerEndpoint|' \
  has_probe_before_registration
mutate "the probe dropped from the boot altogether" \
  's|^    Invoke-Phase6BootProbe .*||' \
  has_probe_before_registration
mutate "the probe folded into a branch, the way the job hooks nearly were" \
  's|^    Invoke-Phase6BootProbe |        Invoke-Phase6BootProbe |' \
  has_probe_before_registration

# --- group 14: the verdict is reached and then ignored -----------------------
mutate "a finding downgraded from a denied boot to a log line" \
  's|Deny-Boot ("the boot probe found |Write-BootLog ("the boot probe found |' \
  has_fatal_boot_probe
mutate "the findings list tested against a threshold no verdict reaches" \
  's|\$findings\.Count -gt 0|$findings.Count -gt 99|' \
  has_fatal_boot_probe
mutate "a probe service that would not start no longer stops the boot" \
  's|Deny-Boot ("the boot probe service would not start as \$SlotUser|Write-BootLog ("the boot probe service would not start as $SlotUser|' \
  has_fatal_boot_probe
mutate "the verdict wait stretched past the boot it is supposed to gate" \
  's|\$script:ProbeWaitSeconds = 180|$script:ProbeWaitSeconds = 86400|' \
  has_fatal_boot_probe
mutate "the verdict wait unbounded, so a stuck payload hangs the boot instead" \
  's|if ((Get-Date) -ge \$deadline) { break }||' \
  has_fatal_boot_probe

# --- group 15: the verdict file stops being this boot's, or this slot's ------
mutate "the verdict file made readable and writable across slots" \
  's|Protect-CiDirectory -Path \$script:ProbeResultPath -SlotUser \$SlotUser|Protect-CiDirectory -Path $script:ProbeResultPath -ReadOnlyUser @($SlotUser)|' \
  has_probe_verdict_acl
mutate "the verdict file left on whatever ACL C:\\ci hands down" \
  's|^    Protect-CiDirectory -Path \$script:ProbeResultPath -SlotUser \$SlotUser$||' \
  has_probe_verdict_acl
mutate "a passing verdict left by the previous boot accepted as this boot's" \
  's|^    Remove-Item -LiteralPath \$script:ProbeResultPath -Force -ErrorAction SilentlyContinue$||' \
  has_probe_verdict_acl
mutate "a removal that did not take downgraded to a warning" \
  's|Deny-Boot ("could not remove a pre-existing|Write-BootLog ("could not remove a pre-existing|' \
  has_probe_verdict_acl
mutate "the file prepared after the service that writes it was already started" \
  's|^    Protect-ProbeVerdictFile -SlotUser \$slot\.User$||
   s|^        \$verdict = Wait-ProbeVerdict$|        Protect-ProbeVerdictFile -SlotUser $slot.User\n        $verdict = Wait-ProbeVerdict|' \
  has_probe_verdict_acl
mutate "the payload made writable by the account it measures" \
  's|Protect-CiDirectory -Path \$script:ProbeScriptPath -ReadOnlyUser @(\$SlotUser)|Protect-CiDirectory -Path $script:ProbeScriptPath -SlotUser $SlotUser|' \
  has_probe_verdict_acl

# --- group 16: §3A's third bullet stops being witnessed ----------------------
mutate "the post-registration witness removed" \
  's|^    Wait-RegistrationTokenRemoved$||' \
  has_registration_token_witness
mutate "a live token left in metadata downgraded to a log line" \
  's|Deny-Boot ("\$script:RegistrationTokenKey is STILL on this instance|Write-BootLog ("$script:RegistrationTokenKey is STILL on this instance|' \
  has_registration_token_witness
mutate "the witness reading once instead of polling the controller's own tick" \
  's|Get-JitteredTimeout -BaseSeconds \$script:TokenRemovalWaitSeconds|0 * (0|' \
  has_registration_token_witness
mutate "the jittered bound tidied back into a constant every host crosses together" \
  's|\$script:TokenRemovalJitterSeconds = 300|$script:TokenRemovalJitterSeconds = 0|' \
  has_registration_token_witness
mutate "the spread dropped from the call while the constant stays, which reads as jittered" \
  's| -JitterSeconds \$script:TokenRemovalJitterSeconds||' \
  has_registration_token_witness
mutate "the witness moved above registration, where the key is supposed to be there" \
  's|^    Wait-RegistrationTokenRemoved$||
   s|^    \$regToken = Wait-RegistrationToken$|    Wait-RegistrationTokenRemoved\n    $regToken = Wait-RegistrationToken|' \
  has_registration_token_witness

# --- group 17: the boot log goes back into the success stream ----------------
#     Renumbered from 13 on the rebase: this branch had already taken 13-16 for
#     the phase-6 harness, and two group 13s would make a failure report name a
#     group the reader cannot find.
#     The original regression plus the two other spellings of it. All three
#     parse, all three lint (except Write-Host, which is the point of the third
#     case being separate), and all three pass the Pester suite unchanged.
mutate "the original regression: Write-Output back in Write-BootLog" \
  's|\[Console\]::Out\.WriteLine(\$line)|Write-Output $line|' \
  has_uncapturable_boot_log
mutate "the bare expression statement, which is the success stream with no cmdlet to grep for" \
  's|\[Console\]::Out\.WriteLine(\$line)|$line|' \
  has_uncapturable_boot_log
mutate "Write-Host, which is out-of-band but fails PSAvoidUsingWriteHost in powershell-gate.sh" \
  's|\[Console\]::Out\.WriteLine(\$line)|Write-Host $line|' \
  has_uncapturable_boot_log
mutate "the file write dropped, so a host that boots leaves no boot log behind" \
  's|Add-Content -Path \$script:LogPath -Value \$line -ErrorAction Stop||' \
  has_uncapturable_boot_log

# --- group 18: the witness stops containing anything -------------------------
mutate "the containment removed, leaving a FATAL line on a host still taking jobs" \
  's|^    Stop-RunnerService$||' \
  has_registration_token_containment
mutate "the containment moved below the throw, where it is dead code that reads as present" \
  's|^    Stop-RunnerService$||
   s|^    Write-BootLog "phase 5: \$script:RegistrationTokenKey is gone|    Stop-RunnerService\n    Write-BootLog "phase 5: $script:RegistrationTokenKey is gone|' \
  has_registration_token_containment
mutate "the service pattern narrowed to something no runner service matches" \
  "s|NamePattern = 'actions.runner.\\*'|NamePattern = 'ci-no-such-service'|" \
  has_registration_token_containment

# --- group 19: the probe stops saying who answered ---------------------------
mutate "the identity check removed, so a LocalSystem probe passes every field" \
  "s|the probe ran as '\\\$ran' and not \\\$ExpectedIdentity|the probe ran as somebody|" \
  has_probe_identity_assertion
mutate "the expected identity made optional, so omitting it skips the assertion" \
  's|\[Parameter(Mandatory = \$true)\]\[AllowEmptyString()\]\[string\] \$ExpectedIdentity|[AllowEmptyString()][string] $ExpectedIdentity|' \
  has_probe_identity_assertion
mutate "the harness asserting a constant that agrees with itself instead of the slot" \
  "s| -ExpectedIdentity \\\$slot\\.User| -ExpectedIdentity 'ci-s1'|" \
  has_probe_identity_assertion
mutate "the payload reading its account from the environment block it does not control" \
  's|\[System.Security.Principal.WindowsIdentity\]::GetCurrent().Name|$env:USERNAME|' \
  has_probe_identity_assertion
mutate "an unattributed verdict no longer reported as a finding" \
  's|the probe did not report which account it ran as|the probe was quiet about it|' \
  has_probe_identity_assertion

# --- group 20: the slot cannot load the image it is started as ---------------
mutate "the shim grant dropped, which is the H1 regression: a 1053 on every host" \
  's|^    Protect-CiDirectory -Path \$script:ServiceShim -ReadOnlyUser @(\$SlotUser)$||' \
  has_probe_shim_loadable_by_slot
mutate "the shim made slot-WRITABLE, which starts the service and hands away LocalSystem" \
  's|Protect-CiDirectory -Path \$script:ServiceShim -ReadOnlyUser @(\$SlotUser)|Protect-CiDirectory -Path $script:ServiceShim -SlotUser $SlotUser|' \
  has_probe_shim_loadable_by_slot
mutate "the grant moved below the repoint, where the SCM has already failed to load it" \
  's|^    Protect-CiDirectory -Path \$script:ServiceShim -ReadOnlyUser @(\$SlotUser)$||
   s|^    Grant-ServiceLogonAccount -ServiceName \$script:ProbeServiceName -Credential \$Credential$|    Grant-ServiceLogonAccount -ServiceName $script:ProbeServiceName -Credential $Credential\n    Protect-CiDirectory -Path $script:ServiceShim -ReadOnlyUser @($SlotUser)|' \
  has_probe_shim_loadable_by_slot
mutate "the bypass-traverse dependency left undocumented for the next image bump" \
  's|THIS RELIES ON BYPASS-TRAVERSE-CHECKING|The traversal works out|' \
  has_probe_shim_loadable_by_slot

# --- group 21: phase 6's grants outlive phase 6 ------------------------------
mutate "the revocation removed, so job code inherits every ACE the probe needed" \
  's|^        Revoke-ProbeSlotAccess$||' \
  has_probe_teardown_invariants
mutate "the revocation moved above the delete, where it races the running probe" \
  's|^        Revoke-ProbeSlotAccess$||
   s|^        Clear-BootProbeService$|        Revoke-ProbeSlotAccess\n        Clear-BootProbeService|' \
  has_probe_teardown_invariants
mutate "the shim left out of the revert, which is the one grant on an executable" \
  's|\$script:ProbeRoot, \$script:ProbeResultPath, \$script:ServiceShim|$script:ProbeRoot, $script:ProbeResultPath|' \
  has_probe_teardown_invariants
mutate "a revert that did not take downgraded to a log line" \
  's|Deny-Boot ("could not take|Write-BootLog ("could not take|' \
  has_probe_teardown_invariants
mutate "the revert given -SlotUser, so it re-grants what it claims to take back" \
  's|^            Protect-CiDirectory -Path \$path$|            Protect-CiDirectory -Path $path -SlotUser $SlotUser|' \
  has_probe_teardown_invariants
mutate "sc.exe back to PATH resolution in a LocalSystem process" \
  "s|\\\$sc = Join-Path \\\$env:SystemRoot 'System32.sc.exe'||
   s|& \\\$sc delete|\& sc.exe delete|" \
  has_probe_teardown_invariants

# --- group 22: the sibling verdict stops saying what it saw ------------------
mutate "the exception type no longer recorded, leaving the fleet-wide arm unexplained" \
  's|`\$r.siblingErrorType = \[string\] `\$_.Exception.GetType().FullName|`$null = `$_|' \
  has_sibling_exception_type_recorded
mutate "the field dropped from the verdict shape" \
  "s|siblingStatus = 'unrun'; siblingErrorType = ''|siblingStatus = 'unrun'|" \
  has_sibling_exception_type_recorded
mutate "the type recorded but never printed, so it reaches nobody" \
  "s|\\\$siblingType = \\[string\\] (& \\\$get 'siblingErrorType')|\$siblingType = ''|" \
  has_sibling_exception_type_recorded
mutate "the missing-arm finding stripped back to the sentence that says nothing" \
  's|-- \$sawType, and if that names an access denial|and nothing else|' \
  has_sibling_exception_type_recorded

# --- group 23: the stop pattern stops being constrained ----------------------
mutate "the pattern validation removed, so a wildcard can take the beacon with it" \
  's|^        \[ValidatePattern.*$||' \
  has_registration_token_containment

# --- invariant 9: the dependency cache does not become a cross-slot channel ---
#
# Phase 7 gives every slot a copy of a tree that arrived in the image from
# repo-supplied code (`warm_cache_script`). Three things make that safe, and each
# of them can be undone by an edit that looks like a simplification and produces
# no error at boot:
#
#   the master goes writable   `-ReadOnlyUser` becoming `-SlotUser` on C:\ci-cache
#                              reads as one word and hands every slot Modify on
#                              the tree every OTHER slot copies from. `npx`
#                              executes out of the npm cache and NuGet does not
#                              re-verify a package it already has, so that is one
#                              job handing the next one code to run — on a host
#                              whose slots are the whole boundary.
#
#   the scan moves            Sealing follows a junction, so a scan that ran
#                              after the seal would be reporting on a tree whose
#                              read-and-execute grant had already been applied
#                              somewhere else. An ACL applied to the wrong tree
#                              outlives the boot that applied it.
#
#   the marker moves          `.ready` says "every directory below is present and
#                              reachable by this slot". It lives in a directory
#                              only SYSTEM can create names in. One level down, a
#                              slot forges it and phase 5 points ten variables at
#                              directories the slot itself laid out.

has_cache_master_sealed_readonly() { # <file>
  local code
  code=$(code_of "$1")

  # READ-and-execute, never Modify. This is the whole isolation: one shared tree,
  # K readers, no writer but SYSTEM.
  matches "$code" 'Protect-CiDirectory -Path \$Master -ReadOnlyUser \$SlotUsers' || return 1
  ! matches "$code" 'Protect-CiDirectory -Path \$Master.*-SlotUser' || return 1

  # The scan is called, and it is called BEFORE icacls touches anything. Line
  # order is what makes this decidable from the text: the reason line must appear
  # earlier in the file than the reset.
  local scan_at seal_at
  scan_at=$(printf '%s\n' "$code" | grep -nE 'Get-CacheHostileReason -Entries \$entries' | head -1 | cut -d: -f1)
  seal_at=$(printf '%s\n' "$code" | grep -nE 'icacls\.exe \$Master' | head -1 | cut -d: -f1)
  [ -n "$scan_at" ] && [ -n "$seal_at" ] || return 1
  [ "$scan_at" -lt "$seal_at" ] || return 1

  # The refusal is acted on, not merely computed. ANCHORED ON ITS INDENTATION:
  # there are two `if ($reason)` sites now -- this one and the retired-slot sweep
  # in Invoke-Phase7DependencyCache -- and an unanchored match is satisfied by
  # either, so neutering this one would leave the assertion green.
  matches "$code" '^    if \(\$reason\) \{$' || return 1

  # `/C` makes icacls continue past per-file errors AND still exit 0, which turns
  # "half the tree kept its inherited ACE" into a silent success.
  ! matches "$code" "icacls\.exe \\\$Master.*'/C'" || return 1
  # And the exit code is checked at all.
  matches "$code" 'if \(\$exit -ne 0\)' || return 1

  # The root itself is scanned, not only its children: a master that IS a junction
  # is the case where everything below it already belongs to another tree.
  matches "$code" '\$entries = @\(\$root\) \+' || return 1
}

has_slot_cache_isolation() { # <file>
  local code
  code=$(code_of "$1")

  # The slot's own directory is SYSTEM-and-Administrators only. It is root's work
  # area: the staging name is created in it and the marker is written in it, and a
  # slot that could create a name there could substitute either.
  matches "$code" 'Protect-CiDirectory -Path \$dst$' || return 1
  ! matches "$code" 'Protect-CiDirectory -Path \$dst.*-SlotUser' || return 1
  matches "$code" 'Protect-CiDirectory -Path \$script:CacheSlots$' || return 1

  # The marker is cleared before the loop and written after it. Written first, it
  # would mean "seeding was attempted"; and phase 5 reads it to decide whether to
  # emit ten variables that name paths inside it.
  local clear_at write_at
  clear_at=$(printf '%s\n' "$code" | grep -nE 'Remove-Item -LiteralPath \$marker' | head -1 | cut -d: -f1)
  write_at=$(printf '%s\n' "$code" | grep -nE 'Set-Content -LiteralPath \$marker' | head -1 | cut -d: -f1)
  [ -n "$clear_at" ] && [ -n "$write_at" ] || return 1
  [ "$clear_at" -lt "$write_at" ] || return 1

  # The copy does NOT carry the master's security descriptor, or the slot gets a
  # cache it cannot write; and it does not descend into a junction.
  matches "$code" "'/COPY:DAT'" || return 1
  ! matches "$code" '/COPYALL|/COPY:DATS' || return 1
  matches "$code" "'/XJ'" || return 1

  # Robocopy's exit code is a BITMAP and 1 means "files were copied". A `-ne 0`
  # check here would report every successful seed as a failure; a bare `-lt 8`
  # would accept the NEGATIVE code a killed robocopy exits with and publish a
  # partial tree as a complete cache.
  matches "$code" 'Test-RobocopySuccess -ExitCode \$exit' || return 1
  matches "$code" 'ExitCode -ge 0 -and \$ExitCode -lt 8' || return 1

  # Published by rename, so the directory the variables name either is absent (a
  # cache miss, which is correct) or is complete.
  matches "$code" 'Move-Item -LiteralPath \$stage -Destination \$final' || return 1

  # Room is checked per slot, inside the loop, so the slots that fit are seeded
  # and the rest run cold instead of the volume filling under the jobs.
  matches "$code" 'Test-CacheSeedAffordable -MasterBytes \$masterBytes' || return 1

  # This phase FAILS OPEN. Every other phase ends in Deny-Boot; a host that
  # refuses to register over a cache problem is a missing host, and the pool
  # answers missing hosts by queueing jobs.
  #
  # `.*` and not `[^\n]*`, for the reason recorded above on ConvertFrom-Json:
  # grep is line-based, so `[^\n]` reads as "not the letter n and not a
  # backslash" -- and the line this has to catch is `Deny-Boot "phase 7: the
  # dependency cache ..."`, whose `n` in `dependency` sits between the two
  # anchors. Written that way the assertion could not fail, which its own
  # mutation caught.
  ! matches "$code" 'Deny-Boot.*cache' || return 1

  # The retired-index sweep is the ONE recursive delete on this host that reaches
  # a tree job code could write: `<idx>` is SYSTEM's, but `<idx>\<tool>` carries
  # the slot's Modify grant. Windows PowerShell 5.1 -- which is what runs the boot
  # script -- follows a junction on `Remove-Item -Recurse` and deletes what it
  # points at (PowerShell/PowerShell#621, fixed in 6.0, never backported), so the
  # tree is scanned first and a hostile one is left on disk rather than deleted.
  local scan_at del_at
  scan_at=$(printf '%s\n' "$code" | grep -nE '\$reason = Get-CacheHostileReason -Entries \(@\(\$dir\)' | head -1 | cut -d: -f1)
  del_at=$(printf '%s\n' "$code" | grep -nE 'Remove-Item -LiteralPath \$dir\.FullName -Recurse' | head -1 | cut -d: -f1)
  [ -n "$scan_at" ] && [ -n "$del_at" ] || return 1
  [ "$scan_at" -lt "$del_at" ] || return 1
  # And the refusal is acted on. Anchored the same way, and for the same reason.
  matches "$code" '^            if \(\$reason\) \{$' || return 1

  # The cache variables are emitted only for a slot that actually got a cache.
  # Unconditional, they would name directories phase 7 never built — and a tool
  # that cannot open the cache it was told to use fails the job rather than
  # missing it.
  matches "$code" 'if \(-not \[string\]::IsNullOrWhiteSpace\(\$CachePath\)\)' || return 1
}

if has_cache_master_sealed_readonly "$SCRIPT"; then
  ok
else
  bad "the master dependency cache is not sealed read-only before it is scanned, or a slot can write it — C:\\ci-cache is copied into every slot, so a slot that can write it hands the next job on every other slot code to run, and a seal applied before the reparse-point scan applies that grant to whatever a junction names"
fi

if has_slot_cache_isolation "$SCRIPT"; then
  ok
else
  bad "a slot's cache copy is not isolated, not published atomically, or its readiness marker is forgeable — phase 5 reads that marker to decide whether to point npm, NuGet, pip and seven others at the tree, and a half-built or slot-laid-out tree is a hard per-job failure rather than the cache miss this layer promises"
fi

# --- group 24: the master cache stops being read-only ------------------------
mutate "the master handed to every slot as Modify" \
  's|Protect-CiDirectory -Path \$Master -ReadOnlyUser \$SlotUsers|Protect-CiDirectory -Path $Master -SlotUser $SlotUsers[0]|' \
  has_cache_master_sealed_readonly
mutate "the hostile-content scan computed and never acted on" \
  's|^    if (\$reason) {$|    if ($false) {|' \
  has_cache_master_sealed_readonly
mutate "icacls given /C, so a half-applied reset still exits 0" \
  "s|& icacls.exe \\\$Master '/reset'|\& icacls.exe \$Master '/C' '/reset'|" \
  has_cache_master_sealed_readonly
mutate "the icacls exit code dropped" \
  's|^    if (\$exit -ne 0) {$|    if ($false) {|' \
  has_cache_master_sealed_readonly
mutate "the root left out of the scan, so a junction as the master is walked into" \
  's|\$entries = @(\$root) + @(Get-ChildItem|$entries = @(Get-ChildItem|' \
  has_cache_master_sealed_readonly

# --- group 25: a slot's copy stops being its own -----------------------------
mutate "the slot given write on its own cache directory, where the marker lives" \
  's|^    Protect-CiDirectory -Path \$dst$|    Protect-CiDirectory -Path $dst -SlotUser $User|' \
  has_slot_cache_isolation
mutate "the readiness marker written before the tools are copied" \
  's|^    Remove-Item -LiteralPath \$marker -Force -ErrorAction SilentlyContinue$|    Set-Content -LiteralPath $marker -Value "" -Encoding Ascii|' \
  has_slot_cache_isolation
mutate "the copy told to carry the master ACL, so no slot can write its own cache" \
  "s|'/COPY:DAT'|'/COPYALL'|" \
  has_slot_cache_isolation
mutate "junction exclusion dropped from the copy" \
  "s| '/XJ'||" \
  has_slot_cache_isolation
mutate "robocopy's bitmap read as a plain exit code" \
  's|Test-RobocopySuccess -ExitCode \$exit|$exit -eq 0|' \
  has_slot_cache_isolation
mutate "a killed robocopy's negative exit accepted as success" \
  's|(\$ExitCode -ge 0 -and \$ExitCode -lt 8)|($ExitCode -lt 8)|' \
  has_slot_cache_isolation
mutate "the half-copied tree published in place instead of renamed" \
  's|Move-Item -LiteralPath \$stage -Destination \$final|Copy-Item -LiteralPath $stage -Destination $final -Recurse|' \
  has_slot_cache_isolation
mutate "the free-space floor dropped, so the last copy fills the volume" \
  's|Test-CacheSeedAffordable -MasterBytes \$masterBytes -FreeBytes \$free `|$true; $null = $free; $null = @( `|' \
  has_slot_cache_isolation
mutate "a cache failure promoted to a boot refusal, which strands the host" \
  's|Write-BootLog "phase 7: the dependency cache could not be prepared|Deny-Boot "phase 7: the dependency cache could not be prepared|' \
  has_slot_cache_isolation
mutate "a retired tree scanned, found hostile, and deleted anyway" \
  's|^            if (\$reason) {$|            if ($false) {|' \
  has_slot_cache_isolation
mutate "a retired slot's cache tree deleted recursively without being scanned" \
  's|$reason = Get-CacheHostileReason -Entries (@($dir)|$reason = $null; $null = (@($dir)|' \
  has_slot_cache_isolation
mutate "the cache variables emitted for a slot that never got a cache" \
  's|if (-not \[string\]::IsNullOrWhiteSpace(\$CachePath)) {|if ($true) {|' \
  has_slot_cache_isolation

printf 'windows-host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
