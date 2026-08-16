# ci-runner-host-pool -- Windows host boot.
#
# The Linux counterpart is `host-startup.sh`, and the first paragraph of that
# file applies here word for word: this script INSTALLS NOTHING. The runner
# agent, the build toolchains and the warm caches are in the golden image
# (packer/ci-host-image-win.pkr.hcl). A pool that installs at boot has
# re-invented the per-job cost it exists to delete -- which is precisely what
# the retired one-VM-per-job Windows pool did.
#
# Agents are NOT --ephemeral, for the same reason they are not on Linux: the
# host stays hot and keeps serving. What differs is where the isolation comes
# from. On Linux each slot gets its own user, its own rootless container daemon
# and its own network namespace. On Windows a slot gets its own LOCAL ACCOUNT,
# and that is the whole boundary (see section 4 of docs/adr-windows-pool.md for
# what that does and does not buy).
#
# THIS FILE IS DELIVERED IN PHASES, AND THE ORDER IS THE SAFETY PROPERTY
#
#   phase 0  preflight, image assertion, and the beacon BEFORE anything else
#   phase 1  slot accounts, logon rights, ACLs, per-slot TEMP
#   phase 2  the metadata fence                                (DELETED, see below)
#   phase 3  the job credential broker
#   phase 4  the per-job credential reset hooks
#   phase 5  agent registration as a service
#   phase 6  the boot probe                                    (not yet)
#
# THE REGISTRATION TOKEN IS READ ONCE, AND A HOST THAT CANNOT GET ONE BLOCKS
#
# The controller mints the repository registration token, writes it to this
# instance's `ci-registration-token` metadata key, and DELETES that key the
# moment GitHub reports any of this host's agents registered -- `partial`, not
# only `present`. Two host-side obligations follow from that, and the controller
# cannot check either one:
#
#   (a) ONE read, above the slot loop. A per-slot read on a two-slot host reads
#       the key for slot 1, registers it, the controller's delete fires, and
#       slot 2 reads nothing -- a host stuck at half capacity with no error
#       anywhere. The single read is what makes the `partial` expiry safe.
#
#   (b) After the key is gone, a reboot LOGS AND BLOCKS. Windows hosts reboot for
#       updates, so this is ordinary behaviour here rather than an edge case: the
#       key was deleted, the controller will not mint a second, and the honest
#       outcome is a host that says so and registers nothing, so the register-
#       grace drain reclaims it and the MIG replaces it. Registering with an
#       empty token instead produces an agent-side failure that reads like a
#       GitHub outage.
#
# THERE IS NO PHASE 2, AND THERE WILL NOT BE ONE
#
# Section 3A of docs/adr-windows-pool.md deletes the metadata fence rather than
# deferring it: Windows Firewall gives an explicit block rule precedence over
# every conflicting allow rule, supports no administrator-assigned ordering, and
# offers no per-principal outbound filter that works without IPsec the metadata
# server does not speak. A host-wide block installs cleanly and takes the guest
# agent, the beacon and this broker down with the slot accounts. The safety
# property moved into IAM instead -- a Windows pool's host account is reduced
# until the token job code can mint is worth only what the broker was going to
# hand it anyway -- and that reduction is PR 4b's, not this file's.
#
# The consequence for THIS file is a rule, and it is the one the self-test
# guards: no credential of any kind is written to instance metadata or to guest
# attributes, and no `New-NetFirewallRule` appears anywhere in it. A fence
# reintroduced by a later edit would review as working and enforce the opposite
# of what it claims.
#
# Phase 1 builds the boundary; phases 3 and 4 build what job code is given
# INSIDE it -- a weaker credential, and a guarantee that it does not outlive the
# job. Nothing CONSUMES the slot credentials until phase 5 registers the agents.
#
# Until phase 5 exists this script registers no agent, so a host running it
# serves no jobs. That is the intended state of a half-delivered Windows pool
# and it is why `host_os` is not yet an input to the module.
#
# Every phase either succeeds or the host registers nothing. There is no partial
# host: one that came up without its broker turns every deploy step into a
# confusing auth failure, and one that came up without its hooks hands the next
# pull request the last job's credentials.
#
# WHY THE BEACON IS PHASE 0 AND NOT PHASE 5
#
# There must be no instant in this host's life at which a `Runner.Worker.exe`
# could exist without a publisher able to see it, and the cheapest way to
# guarantee that is to start the publisher before anything that could ever spawn
# one. (The second reason this file used to give -- that the phase-2 fence
# exempted the beacon by service SID, and a SID that does not exist yet cannot be
# exempted -- died with the fence. Section 3A, again.)

[CmdletBinding()]
param()

# Strict mode and the error preference are set at the entry point at the bottom,
# not here. Setting them at script scope makes dot-sourcing this file
# RECONFIGURE its host, and the host is Pester: strict mode leaking into the
# test runner's own scope chain aborts the whole container before a single test
# runs (pester/pester#2669). Dot-sourceable WITHOUT side effects is the file's
# contract, and two preference variables are side effects.

$script:CiRoot = 'C:\ci'
$script:SlotRoot = 'C:\ci\slots'
$script:BinRoot = 'C:\ci\bin'
$script:LogPath = 'C:\ci\ci-host.log'
$script:ImageMarker = 'C:\ci\image-version.txt'
$script:MetadataRoot = 'http://169.254.169.254/computeMetadata/v1'

# The service shim is an IMAGE component, not something this script installs.
# A PowerShell script cannot be a Windows service on its own: the service
# control manager expects SERVICE_RUNNING to be reported within its start
# timeout, `powershell.exe -File` never reports it, and the SCM kills the
# process. The shim is the thing that answers the SCM and supervises the script.
$script:ServiceShim = 'C:\ci\bin\ci-service-shim.exe'
$script:BeaconServiceName = 'ci-beacon'
$script:BrokerServiceName = 'ci-job-broker'

# The interpreter the broker runs under is an IMAGE component too, at a path this
# module fixes rather than discovers. Resolving `python.exe` through PATH would
# make the broker's identity depend on whatever the image last installed, and
# PATH is the one input to a service start that a future image change can alter
# without anybody reading this file.
$script:PythonExe = 'C:\ci\bin\python\python.exe'
$script:BrokerScript = 'C:\ci\bin\job-metadata-broker.py'

# The hooks do NOT live under C:\ci\bin. That directory is locked to SYSTEM and
# Administrators with no slot ACE at all (phase 1), and a hook a slot cannot read
# is a hook that fails every job on the host. They get their own directory with
# their own ACL: SYSTEM and Administrators full, every slot read-and-execute.
$script:JobHookRoot = 'C:\ci\job-hooks'
$script:JobHookPath = 'C:\ci\job-hooks\reset-credentials.ps1'

# The loopback port the broker answers on when metadata does not name one. The
# same default as the Linux broker, because it is the same broker.
$script:DefaultBrokerPort = 8081

# Where a slot's ADC is pointed when this pool has NO broker.
#
# Not a placeholder, and the single most load-bearing constant in this file.
# Leaving GCE_METADATA_* unset does NOT mean "no credentials": gcloud,
# google-auth and the Go and Java clients all fall through to the real
# 169.254.169.254 and authenticate as the HOST service account -- which is the
# exact silent downgrade the no-broker path claims never to make. Linux gets
# that property from fence_metadata, which runs unconditionally there and which
# section 3A deleted here; nothing replaced it until this constant did.
#
# A loopback port that is RESERVED, and therefore permanently unbindable,
# refuses the connection instantly. ADC then fails closed and says so, instead
# of succeeding as somebody else. Port 1 is chosen because no service anybody
# would run on a CI host wants it.
$script:ClosedMetadataPort = 1
$script:ClosedMetadataEndpoint = '127.0.0.1:1'

# The per-instance metadata key the controller writes the registration token to
# and deletes it from. Hard-coded on BOTH sides for the same reason
# controller-startup.sh hard-codes it: a configurable name is one more way for
# the delete to miss the key the write created.
$script:RegistrationTokenKey = 'ci-registration-token'

# The unconfigured agent baked into the golden image. COPIED per slot, never
# linked: config.cmd writes `.runner` and `.credentials` into the directory it
# runs in, and K agents must not share one identity.
$script:RunnerTemplate = 'C:\ci\bin\actions-runner'

# How long phase 5 waits for the controller to write the registration token.
# BOUNDED, and the bound is the whole point. `wait-for-change` on the metadata
# server would block until the key appears, which on a rebooted host past the
# expiry is forever -- and forever is the 2h55m outage: a host that never
# registers, never powers off, and counts against the pool's size the whole
# time. 300s is generous against a controller tick (POLL defaults to 20s) and
# still far inside the register grace that reclaims a host which gave up.
$script:RegistrationWaitSeconds = 300
$script:RegistrationPollSeconds = 5

# How long to wait for the agent service config.cmd auto-started to stop again,
# before its identity and environment are set. Bounded like everything else: a
# service that will not stop is a slot that would run every job as the shared
# machine account, and blocking forever hides that behind a hung boot.
$script:ServiceStopSeconds = 60

# Bounded, like every call this host makes. A host boot that HANGS is worse than
# one that fails: it never registers an agent, never powers off, and bills at
# warm-host size until the controller's register grace expires -- and while it
# waits it counts as a host the pool already has, so the pool does not add the
# one that would have taken the queued job. That is the 2h55m outage, restated.
$script:HttpTimeoutSeconds = 10

function Write-BootLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Message)
    $line = '[{0}] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
    Write-Output $line
    try {
        Add-Content -Path $script:LogPath -Value $line -ErrorAction Stop
    } catch {
        # The log is diagnostics. Losing it must not stop a boot.
        $null = $_
    }
}

function Deny-Boot {
    <#
      .SYNOPSIS
        Fail the boot loudly and stop.
      .DESCRIPTION
        There is no "continue without it" here. Every caller is a precondition
        whose absence makes the host either unsafe or useless, and a host that
        registers no agent is reclaimed by the controller's register-grace drain
        within minutes -- which is the cheap outcome. The expensive outcome is a
        host that half-worked.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Message)
    Write-BootLog "FATAL: $Message"
    throw $Message
}

# --- pure functions ----------------------------------------------------------
#
# Anything decidable without touching the machine lives here, so Pester can run
# it on ubuntu-latest (scripts/ci/windows-startup.Tests.ps1). A gate that READS
# code is not a test -- v5.1.4 passed every gate in ci.yml while every
# controller in the fleet died on its first tick.

function Test-ImageVersion {
    <#
      .SYNOPSIS
        Is this golden image at or above the floor the module requires?
      .DESCRIPTION
        The Linux script asserts `[ -d /opt/actions-runner ]` and refuses
        otherwise, because booting a bare image reintroduces the per-job install
        cost the pool exists to remove. A directory check is too weak here: a
        Windows image can carry a runner and still predate the service shim, the
        beacon source or the fence-proving probe, and each of those absences
        fails LATER and less legibly.

        So the Packer template writes an integer, and this compares it. Anything
        unreadable or non-numeric is a fail -- an image that cannot say what it
        is is not an image this pool knows how to run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Marker,
        [Parameter(Mandatory = $true)][int] $Floor
    )
    if ([string]::IsNullOrWhiteSpace($Marker)) { return $false }
    $trimmed = $Marker.Trim()
    if ($trimmed -notmatch '^[0-9]+$') { return $false }
    return ([int] $trimmed) -ge $Floor
}

function Get-SlotUserName {
    <#
      .SYNOPSIS
        The local account name for slot <Index>.
      .DESCRIPTION
        `ci-s<i>`, matching the Linux `ci-s<idx>`. This is not cosmetic: the agent
        registered by this slot is named `<instance>-s<i>`, and
        `orphan_decision()` on the controller parses that name back to an
        instance. A rename here silently un-reaps every Windows registration --
        the agent stays in GitHub's list, the host it named is long gone, and
        nothing in the controller notices because nothing can.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Index)
    return "ci-s$Index"
}

function Get-SlotWorkspacePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $Root = $script:SlotRoot
    )
    return (Join-Path $Root ([string] $Index))
}

function Get-SlotTempPath {
    <#
      .SYNOPSIS
        The slot's private TEMP.
      .DESCRIPTION
        The Linux rule this replaces: a workflow step naming a fixed path under
        /tmp -- and CI scripts name fixed paths there constantly -- creates it
        under whichever slot ran first, and every later slot gets Permission
        denied on a file it believes is its own. Linux fixes that with
        PrivateTmp=yes on the daemon. Windows has no mount namespace to give a
        service, so the mechanism is a per-slot directory carrying the slot's ACL,
        pointed at by TMP and TEMP in the runner SERVICE's environment (phase 5)
        rather than machine-wide, which would hand every slot the same one.

        Weaker than the Linux fix, and the difference is stated rather than
        discovered: this redirects the CONVENTIONAL temp path, and nothing stops a
        step writing to a literal C:\temp\build. What the ACLs do is turn that
        collision from a silent cross-slot read into an Access is denied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $Root = $script:SlotRoot
    )
    return (Join-Path (Get-SlotWorkspacePath -Index $Index -Root $Root) 'temp')
}

# The four character classes Windows complexity policy wants, minus every
# homoglyph (I, l, 1, O, 0) and every shell, quoting or XML metacharacter. This
# value reaches the service control manager, and a quoting bug here would be a
# quoting bug in the one place it is a credential; a password that cannot be read
# back off a console during an incident wastes the incident.
$script:SlotPasswordClasses = @(
    'ABCDEFGHJKLMNPQRSTUVWXYZ',
    'abcdefghijkmnpqrstuvwxyz',
    '23456789',
    '_-.~'
)

function Get-SlotPasswordCharacter {
    <#
      .SYNOPSIS
        The characters of one slot password, as a char array. Pure and testable.
      .DESCRIPTION
        Windows requires a password here: a service logon takes a credential and
        there is no `sudo -u` on this platform. That is a real difference from
        Linux, where no such secret exists, and it is contained by making the
        credential useless for anything else -- the account is granted
        SeServiceLogonRight and DENIED interactive, network and remote-interactive
        logon, is not in Administrators, and is not in Remote Desktop Users.

        One character from each class is placed first and the whole thing is then
        shuffled, so complexity is satisfied by construction rather than by luck.
        A password rejected by policy is a slot that never registers, and it would
        be discovered on the fleet rather than here.

        Returns chars, not a string, so the caller can build a SecureString
        without a plaintext String ever existing on the managed heap. The array is
        the caller's to clear.

        The verb is Get and not New because PSUseShouldProcessForStateChangingFunctions
        demands -WhatIf plumbing from a New-* function, and a boot script that
        half-honours -WhatIf is a worse thing than an imperfect verb.
    #>
    [CmdletBinding()]
    param([int] $Length = 40)

    $classes = $script:SlotPasswordClasses
    if ($Length -lt $classes.Count) {
        throw "slot password length $Length cannot satisfy $($classes.Count) character classes"
    }
    $all = -join $classes

    # Four bytes of entropy per character, drawn once. The modulo bias over a
    # 32-bit draw into an at-most-64-character alphabet is far below anything that
    # matters for a 40-character secret that never leaves the machine.
    $bytes = [byte[]]::new($Length * 4)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    $chars = [char[]]::new($Length)
    for ($i = 0; $i -lt $classes.Count; $i++) {
        $set = $classes[$i]
        $chars[$i] = $set[[int]([BitConverter]::ToUInt32($bytes, $i * 4) % [uint32] $set.Length)]
    }
    for ($i = $classes.Count; $i -lt $Length; $i++) {
        $chars[$i] = $all[[int]([BitConverter]::ToUInt32($bytes, $i * 4) % [uint32] $all.Length)]
    }
    for ($i = $Length - 1; $i -gt 0; $i--) {
        $j = [int]([BitConverter]::ToUInt32($bytes, $i * 4) % [uint32]($i + 1))
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    [array]::Clear($bytes, 0, $bytes.Length)
    return $chars
}

function Get-SlotPassword {
    <#
      .SYNOPSIS
        A slot password as a SecureString, with no plaintext String in between.
      .DESCRIPTION
        Deliberately never materialises a [string]. `ConvertTo-SecureString
        -AsPlainText -Force` is the usual shortcut and it is the wrong one twice
        over: it puts an immutable, un-erasable copy of the credential on the
        managed heap for the lifetime of the process, and PSScriptAnalyzer flags
        it -- which would mean either a failing gate or a suppression, and a
        suppressed warning about a credential is how the next one gets suppressed
        too.

        Everything downstream takes a SecureString or a PSCredential: New-LocalUser,
        Set-LocalUser, and the service registration in phase 5. So the plaintext
        form is never needed at all, and this script never writes it to disk, never
        logs it and never puts it in metadata. After registration LSA holds it as a
        service secret, readable only by SYSTEM.
    #>
    [CmdletBinding()]
    param([int] $Length = 40)

    $chars = Get-SlotPasswordCharacter -Length $Length
    $secure = New-Object System.Security.SecureString
    foreach ($c in $chars) { $secure.AppendChar($c) }
    [array]::Clear($chars, 0, $chars.Length)
    $secure.MakeReadOnly()
    return $secure
}

function Get-BeaconServiceConfig {
    <#
      .SYNOPSIS
        The shim's service definition for the beacon, as XML text.
      .DESCRIPTION
        Written as a pure string function so the parts that decide fleet
        behaviour are asserted by a test rather than by a host that has already
        booted. Three of them matter and none is cosmetic:

        `<onfailure action="restart">` -- the publisher stopping is the failure
        that strands a host. `beacon_decision()` reads a stale beacon as keep,
        forever, so a beacon that dies once and stays dead is a machine that
        bills until somebody notices.

        `<startmode>Automatic</startmode>` -- the host must come back beaconing
        after any restart, including one it did not choose.

        `-NonInteractive -NoProfile` -- a profile on the image, or a prompt from
        anything the script calls, would hang the service at start, which the SCM
        reports as a start failure and which looks nothing like its cause.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [string] $ServiceName = $script:BeaconServiceName,
        [int] $IntervalSeconds = 30
    )
    # Escaped, exactly as Get-BrokerServiceConfig escapes its inputs. Both of
    # these are module constants today, so there is no live injection here; the
    # point is that the two builders must not differ, because the next caller
    # will reuse whichever one it finds first and will not read this comment.
    $esc = { param($v) [System.Security.SecurityElement]::Escape([string] $v) }
    $svc = & $esc $ServiceName
    $shimArgs = & $esc ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" " +
        "-IntervalSeconds $IntervalSeconds")
    return @"
<service>
  <id>$svc</id>
  <name>$svc</name>
  <description>Publishes this CI host's liveness to GCE guest attributes.</description>
  <executable>powershell.exe</executable>
  <arguments>$shimArgs</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>2</keepFiles>
  </log>
</service>
"@
}

function Test-JobServiceAccountName {
    <#
      .SYNOPSIS
        Is this a service-account address, and nothing else?
      .DESCRIPTION
        Instance metadata is a trust boundary: section 3A accepts that job code on a
        Windows host can read it, and this module cannot assume nothing can write
        it either. The value goes into the broker's service definition, which is
        XML, and into the service's environment block, so a value carrying a
        quote, an angle bracket or a newline is a way to add an element or a
        variable to a service that runs as LocalSystem.

        Escaping alone would be enough for the XML and is done anyway. This is
        the other half: the only thing that may reach either place is something
        shaped like the address the broker is going to impersonate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return ($Name.Trim() -match '^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$')
}

function Get-BrokerPort {
    <#
      .SYNOPSIS
        The broker's loopback port, or the default when metadata gives nothing.
      .DESCRIPTION
        Same trust-boundary reasoning as the account name, with a narrower range:
        anything that is not a whole number in 1..65535 is a value the socket bind
        would refuse LATER, at which point the broker is a service that installed
        and never answered. Falling back is right here and would be wrong for the
        account: a default port serves the same broker, a default identity would
        be somebody else's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Value,
        [int] $Default = $script:DefaultBrokerPort
    )
    if ($Value -notmatch '^[0-9]+$') { return $Default }
    # TryParse, not a cast. `[int64] '99999999999999999999'` THROWS, and under the
    # entry point's $ErrorActionPreference = 'Stop' that throw is a dead host with
    # a cast error in its log instead of a working one on the default port. An
    # all-digits string is not the same thing as a number that fits, and the gap
    # between the two is exactly what a metadata value can be set to.
    [int64] $port = 0
    if (-not [int64]::TryParse($Value, [ref] $port)) { return $Default }
    if ($port -lt 1 -or $port -gt 65535) { return $Default }
    return [int] $port
}

function Get-BrokerServiceConfig {
    <#
      .SYNOPSIS
        The shim's service definition for the job credential broker, as XML text.
      .DESCRIPTION
        Pure, for the same reason Get-BeaconServiceConfig is: the parts that
        decide whether job code gets the RIGHT identity are asserted by a test
        rather than by a host that has already registered agents.

        `CI_BROKER_HOST` is 127.0.0.1, and that is the one line here that looks
        like a regression against Linux. On Linux the broker binds 0.0.0.0 and the
        script then REJECTs the port on the primary interface, purely because each
        slot has its own network namespace and therefore its own loopback, so a
        broker on the host's 127.0.0.1 would be unreachable from every slot.
        Windows has no per-slot namespace (section 4 of the ADR), every slot shares one
        loopback, and binding the VM's address instead would add an exposure in
        exchange for nothing.

        The service runs as LocalSystem -- the shim's default, and deliberate. The
        broker is the one process on this host whose job is to hold a host-level
        credential briefly and hand back a weaker one; running it as a slot would
        put that exchange inside the boundary it exists to cross.

        Every value that comes from metadata is XML-escaped AND validated by the
        caller. Escaping alone stops a malformed document; validation stops a
        well-formed one that says something else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][int] $Port,
        [string] $ServiceName = $script:BrokerServiceName,
        [string] $PythonPath = $script:PythonExe
    )
    $esc = { param($v) [System.Security.SecurityElement]::Escape([string] $v) }
    $exe = & $esc $PythonPath
    $arg = & $esc "`"$ScriptPath`""
    $sa = & $esc $JobServiceAccount
    $svc = & $esc $ServiceName
    return @"
<service>
  <id>$svc</id>
  <name>$svc</name>
  <description>Vends job-scoped Google credentials to CI job code on this host.</description>
  <executable>$exe</executable>
  <arguments>$arg</arguments>
  <env name="CI_JOB_SERVICE_ACCOUNT" value="$sa"/>
  <env name="CI_BROKER_HOST" value="127.0.0.1"/>
  <env name="CI_BROKER_PORT" value="$Port"/>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>2</keepFiles>
  </log>
</service>
"@
}

function Test-MetadataAbsence {
    <#
      .SYNOPSIS
        Does this metadata failure mean "not set", as opposed to "not readable"?
      .DESCRIPTION
        Pure, so the distinction the whole fail-closed rule rests on is asserted
        by a test rather than by a host that has already registered agents. A
        $null status is the case that matters most: it is what a DNS failure, a
        refused connection or a read timeout looks like, and it is precisely the
        case the old catch-everything handler reported as an empty attribute.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()] $StatusCode)
    if ($null -eq $StatusCode) { return $false }
    return ([int] $StatusCode -eq 404)
}

function Get-PortReservationArgument {
    <#
      .SYNOPSIS
        The netsh argument vector that makes one TCP port unbindable, as an array.
      .DESCRIPTION
        Pure, because the arguments are the whole content: a reservation that
        names the wrong protocol or a range of the wrong length is a reservation
        that silently protects nothing, and there is no way to notice that on a
        host afterwards -- the port is simply free again the day somebody wants
        it.

        Used for the closed-metadata port only. The BROKER's port is deliberately
        not reserved: an excluded range blocks explicit binds too, so reserving
        it would lock out the one process that is supposed to have it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Port)
    return @(
        'int', 'ipv4', 'add', 'excludedportrange',
        'protocol=tcp', "startport=$Port", 'numberofports=1'
    )
}

function Test-BrokerListenerSid {
    <#
      .SYNOPSIS
        Is the process listening on the broker's port LocalSystem?
      .DESCRIPTION
        The readiness probe's other half, and pure for the same reason. Every
        slot on a Windows host shares one loopback (section 4) and nothing
        reserves the broker's port, so between a broker crash and the shim's
        10-second restart the port is free -- and a process a job left behind can
        take it and answer with a metadata-shaped document of its own choosing.
        The token probe cannot tell the difference; the owner can. A slot account
        cannot become S-1-5-18, so this is the property, not a heuristic.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Sid)
    if ([string]::IsNullOrWhiteSpace($Sid)) { return $false }
    return ($Sid.Trim() -eq 'S-1-5-18')
}

function Get-JobHookScript {
    <#
      .SYNOPSIS
        The body of the per-job credential reset hook.
      .DESCRIPTION
        THE FAULT THIS EXISTS FOR IS NOT gcloud-SPECIFIC AND WAS PAID FOR ON LINUX

        A slot account's profile outlives every job the slot serves. An action
        that persists a credential -- setup-gcloud writes the external account in
        as the ACTIVE account -- leaves it for whatever pull request lands on that
        slot next. On IntegrateIT that surfaced as a permanently cold remote cache
        because the leftover subject token had expired; the security half does not
        depend on the expiry at all.

        Both ends of the job, for the reason the Linux comment gives: COMPLETED
        alone leaves a live credential on disk for the whole idle window and does
        not run at all if the agent is killed mid-job, which is the case that
        leaves the most behind. STARTED alone leaves the idle window open.

        TWO DETAILS ARE THE SECURITY HALF AND MUST NOT BE SIMPLIFIED AWAY

        1. The profile directory is resolved from the ACCOUNT DATABASE -- the
           SID's ProfileImagePath under the ProfileList key -- and never from
           %USERPROFILE% or %APPDATA%. This runs inside the agent's environment,
           and the directory being deleted must be decided by the host rather than
           by a variable a job could have changed. The Linux hook reads
           `getent passwd` for exactly this reason.
        2. It refuses anything that is not a `ci-s<n>` profile. A resolution that
           somehow yields C:\Users\Administrator must abort, not recurse.

        A failing hook fails the job, and that is the intended trade: a job that
        could not be given a clean credential state must not run with the previous
        job's identity.

        Returned as text rather than shipped as a file of its own because the
        thing being installed is one file per host, ACL'd by the installer that
        writes it; a second tracked `.ps1` would have to be fetched from somewhere
        and the somewhere is the problem this avoids.
    #>
    [CmdletBinding()]
    param()
    # A single-quoted here-string: nothing in the body is interpolated by THIS
    # script, so the hook reads on disk exactly as it reads here.
    return @'
# Installed by windows-host-startup.ps1 (phase 4). Runs as the slot user, before
# every job starts and after every job ends. See Get-JobHookScript for why both.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The account database, not $env:USERPROFILE and not $env:APPDATA: this runs in
# the agent's environment, and the directory being deleted is the host's decision.
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
$raw = (Get-ItemProperty -LiteralPath $key -Name 'ProfileImagePath').ProfileImagePath
# ProfileImagePath is REG_EXPAND_SZ; on a stock image it reads %SystemDrive%\Users\...
$profileDir = [System.Environment]::ExpandEnvironmentVariables([string] $raw)

if ((Split-Path -Leaf $profileDir) -notmatch '^ci-s[0-9]+$') {
    [Console]::Error.WriteLine("credential reset: refusing to clean '$profileDir' -- not a slot profile")
    exit 1
}

$rc = 0
foreach ($leaf in @('AppData\Roaming\gcloud', 'AppData\Roaming\gsutil')) {
    $target = Join-Path $profileDir $leaf
    if (-not (Test-Path -LiteralPath $target)) { continue }
    try {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("credential reset: could not remove $target -- $($_.Exception.Message)")
        $rc = 1
    }
}
exit $rc
'@
}

function Get-SlotServiceEnvironment {
    <#
      .SYNOPSIS
        The environment block phase 5 writes onto one slot's runner service.
      .DESCRIPTION
        Per SERVICE, never machine-wide. A machine-wide TMP would hand every slot
        the same one, which is the collision the per-slot directory exists to
        remove; machine-wide GCE_METADATA_* would point the host's own tooling at
        the broker.

        ALL FIVE VALUES ARE SET UNCONDITIONALLY, AND THAT IS THE POINT OF THIS
        FUNCTION

        The tempting shape makes both halves conditional on there being a broker,
        since all five are "credential plumbing". That is exactly wrong, and it
        is wrong twice. A pool with no job service account is the pool where an
        inherited or ambient credential is MOST dangerous: nothing on the host
        competes with whatever the last workflow left behind, so the leftover is
        simply what the next job authenticates as.

        The hooks clear the leftover. The GCE_METADATA_* values close the other
        door -- unset, they do not withhold credentials, they hand ADC back to
        169.254.169.254 and the HOST service account, because section 3A deleted
        the fence that gives Linux that property for free. Phase 3 hands this
        function the closed endpoint for exactly that reason.

        Returns an ordered dictionary so the block phase 5 writes is stable, which
        is what makes a service key comparable across two boots of one host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $HookPath = $script:JobHookPath,
        [AllowEmptyString()][string] $BrokerEndpoint = '',
        # Injectable for the same reason Get-SlotTempPath's is: the Pester suite
        # runs on ubuntu-latest, where `Join-Path 'C:\ci\slots' 1` does not build
        # a string, it throws DriveNotFoundException. A pure function that cannot
        # be called off Windows is a pure function nothing tests.
        [string] $SlotRoot = $script:SlotRoot
    )

    $temp = Get-SlotTempPath -Index $Index -Root $SlotRoot
    $block = [ordered] @{
        TMP  = $temp
        TEMP = $temp
    }

    # What makes gcloud, google-auth and the Go and Java clients find the broker
    # instead of the real metadata server -- and, on a pool with no broker, what
    # makes them find NOTHING instead of the host identity. Never omitted: an
    # unpointed client on Windows is not an unauthenticated one.
    $endpoint = $BrokerEndpoint
    if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = $script:ClosedMetadataEndpoint }
    $block['GCE_METADATA_HOST'] = $endpoint
    $block['GCE_METADATA_IP'] = $endpoint
    $block['GCE_METADATA_ROOT'] = $endpoint

    $block['ACTIONS_RUNNER_HOOK_JOB_STARTED'] = $HookPath
    $block['ACTIONS_RUNNER_HOOK_JOB_COMPLETED'] = $HookPath
    return $block
}

function Get-ServiceEnvironmentValue {
    <#
      .SYNOPSIS
        One slot's environment block as the REG_MULTI_SZ the SCM reads. Pure.
      .DESCRIPTION
        A service's per-service environment is the `Environment` value under its
        own key, a REG_MULTI_SZ of `NAME=VALUE` strings. Built here rather than
        inline so the two ways it can be silently wrong are asserted by a test:

          * a NAME that is not an environment variable name. The values reaching
            this come from Get-SlotServiceEnvironment, but the block is the last
            thing standing between instance metadata and a service that starts as
            a local account, and section 3A accepts that a Windows host cannot
            assume its metadata is untampered.
          * a VALUE carrying CR, LF or NUL. REG_MULTI_SZ is NUL-delimited, so an
            embedded NUL does not corrupt the write -- it TRUNCATES the block at
            that entry, and every variable after it silently disappears. On this
            block the entries that would disappear are the reset hooks.

        Both throw rather than sanitise. A registration this cannot describe
        exactly is a registration that must not happen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Environment)

    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Environment.Keys) {
        $name = [string] $key
        $value = [string] $Environment[$key]
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "refusing to build a service environment block: '$name' is not an environment variable name"
        }
        if ($value -match "[`r`n`0]") {
            throw ("refusing to build a service environment block: the value of $name carries a " +
                'newline or a NUL, which would truncate every entry after it')
        }
        $entries.Add("$name=$value")
    }
    return $entries.ToArray()
}

function Test-ServiceLogonAccount {
    <#
      .SYNOPSIS
        Does a service's configured StartName name this slot's account? Pure.
      .DESCRIPTION
        The SCM reports a local account as `.\ci-s1`, and there are three other
        spellings of the same account -- bare `ci-s1`, `<HOST>\ci-s1`, and the
        `.\` form with different casing -- so a plain equality test against the
        name phase 1 created reports a correctly configured service as wrong.

        Everything ELSE must be rejected, and the ones that matter are the SCM
        defaults this whole sequence exists to displace: LocalSystem,
        `NT AUTHORITY\NetworkService` and `NT AUTHORITY\LocalService` are
        machine-wide, shared by every slot, and each of them is what the service
        runs as if the identity change silently did nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $StartName,
        [Parameter(Mandatory = $true)][string] $SlotUser
    )

    if ([string]::IsNullOrWhiteSpace($StartName)) { return $false }
    $account = $StartName.Trim()
    # Whatever precedes the last backslash is a machine or authority name; the
    # account itself is what follows it. `.\ci-s1` and `WIN-ABC\ci-s1` both
    # reduce to `ci-s1`, and `NT AUTHORITY\NetworkService` reduces to
    # `NetworkService`, which is not a slot user and so fails the comparison.
    $leaf = $account.Substring($account.LastIndexOf('\') + 1)
    return ($leaf -eq $SlotUser)
}

function Get-RedactedLine {
    <#
      .SYNOPSIS
        One captured output line with a known secret struck out of it. Pure.
      .DESCRIPTION
        config.cmd does not echo its --token today, and the boot log is
        SYSTEM-and-Administrators-only while the serial console sits behind
        project IAM. This exists so that none of those three sentences has to
        stay true forever: the redaction is the only one of them this repository
        controls.

        A literal replace, not a regex, because the secret is not a pattern and
        a pattern is what would miss it. An empty or absent secret returns the
        line unchanged rather than redacting everything -- '' is a substring of
        every string, and a log of nothing but asterisks is how a boot stops
        being diagnosable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Secret
    )

    if ([string]::IsNullOrEmpty($Line)) { return '' }
    if ([string]::IsNullOrWhiteSpace($Secret)) { return $Line }
    return $Line.Replace($Secret, '***')
}

function Get-RunnerServiceName {
    <#
      .SYNOPSIS
        The runner service name from the agent's own `.service` marker. Pure.
      .DESCRIPTION
        `config.cmd --runasservice` records the service it installed in a
        `.service` file in the runner directory; that file, not a name this script
        reconstructs, is the answer. Reconstructing it would mean encoding
        GitHub's naming scheme here, and a scheme that changes upstream would
        leave phase 5 configuring the environment and the recovery policy of a
        service that does not exist -- while the agent that DOES exist starts with
        neither, takes jobs, and restarts itself out of a cordon.

        VALIDATED TWICE, because the file is inside a directory the slot account
        can write and the name it holds reaches sc.exe, Start-Service and an HKLM
        service key:

          * shape -- literally `actions.runner.<...>`, refused rather than
            escaped;
          * OWNERSHIP -- the name must end in this slot's own agent name.
            GitHub's scheme is `actions.runner.<owner>-<repo>.<agent>` and the
            agent name is `<instance>-s<i>`, unique per slot on this host. Shape
            alone accepts any well-formed name, and a stale or restored `.service`
            from a previous boot or a sibling slot would then send this slot's
            logon account, environment block and recovery policy at ANOTHER
            slot's already-registered service. Suffix, not equality: the owner and
            repo halves are sanitised upstream and this file does not get to
            encode how.

        Returns '' on anything it will not vouch for; the caller denies the boot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Marker,
        [Parameter(Mandatory = $true)][string] $AgentName
    )

    if ([string]::IsNullOrWhiteSpace($Marker)) { return '' }
    $name = $Marker.Trim()
    if ($name -notmatch '^actions\.runner\.[A-Za-z0-9._-]+$') { return '' }
    if (-not $name.EndsWith(".$AgentName", [StringComparison]::Ordinal)) { return '' }
    return $name
}

function Get-RunnerConfigArgument {
    <#
      .SYNOPSIS
        The config.cmd argument list for one slot, WITHOUT the token. Pure.
      .DESCRIPTION
        The token is appended by the caller and is deliberately not a parameter
        here: a pure function that never receives the credential cannot leak it
        into a test fixture, a log line or an error message, and this is the one
        function in phase 5 a test calls directly.

        --disableupdate transfers verbatim from Linux and matters MORE here.
        GitHub otherwise forces a runner self-update that leaves the process alive
        while the agent is offline and undispatchable -- 90 minutes of stalled CI
        on the pool this replaces -- and on a warm host that takes K slots down at
        once instead of one short-lived VM. The image pins the agent version;
        upgrades ship by rebuilding the image, which is reviewable.

        --replace, because a host that rebooted has an agent of this name already
        in GitHub's list and a refused registration is a slot that never comes
        back.

        --runasservice with NO account flags. The ADR's sketch passes the pair of
        logon-account flags config.cmd accepts, and the password one of them takes
        is a PLAINTEXT argument -- in the process table of a host whose local
        accounts run pull-request code. The service is installed under the SCM
        default instead and its logon account is changed afterwards through
        ChangeServiceConfigW, which takes the password as unmanaged memory
        marshalled straight out of the SecureString. See Grant-ServiceLogonAccount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Owner,
        [Parameter(Mandatory = $true)][string] $Repo,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Labels,
        [Parameter(Mandatory = $true)][string] $WorkPath,
        [AllowEmptyString()][string] $RunnerGroup = ''
    )

    $configArgs = [System.Collections.Generic.List[string]]::new()
    $configArgs.AddRange([string[]] @('--unattended', '--replace', '--disableupdate', '--runasservice'))
    $configArgs.AddRange([string[]] @('--url', "https://github.com/$Owner/$Repo"))
    $configArgs.AddRange([string[]] @('--name', $Name))
    $configArgs.AddRange([string[]] @('--work', $WorkPath))
    if (-not [string]::IsNullOrWhiteSpace($Labels)) {
        $configArgs.AddRange([string[]] @('--labels', $Labels.Trim()))
    }
    if (-not [string]::IsNullOrWhiteSpace($RunnerGroup)) {
        $configArgs.AddRange([string[]] @('--runnergroup', $RunnerGroup.Trim()))
    }
    return $configArgs.ToArray()
}

function Get-SlotAgentName {
    <#
      .SYNOPSIS
        The agent name slot <Index> registers under. Pure.
      .DESCRIPTION
        `<instance>-s<i>`, and it is not cosmetic: `orphan_decision()` on the
        controller parses this name back to an instance, so a rename here silently
        un-reaps every Windows registration -- the agent stays in GitHub's list,
        the host it named is long gone, and nothing in the controller notices
        because nothing can.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstanceName,
        [Parameter(Mandatory = $true)][int] $Index
    )
    return "$InstanceName-s$Index"
}

# --- phase 0 -----------------------------------------------------------------

function Get-MetadataValue {
    <#
      .SYNOPSIS
        Read one metadata value. Empty string when absent.
      .DESCRIPTION
        Every STATIC attribute is read in phase 0, once. The original reason was
        the phase-2 fence, which would have taken this script's own access to
        169.254.169.254:80 away; section 3A deleted the fence, so the endpoint
        stays reachable all boot long. The constraint survives on a different
        footing: one read site is one place to look when a boot fails on a missing
        attribute, and a later phase that reads its own metadata is a phase whose
        inputs no test can construct.

        There is exactly ONE other caller, Wait-RegistrationToken, and it is not
        an exception to that rule -- it is the reason the rule says STATIC. The
        registration token is written by the CONTROLLER, after this host has
        started booting, and deleted again once the host registers; it is the one
        attribute whose value at phase 0 says nothing about its value later. It is
        still read once, above the slot loop, for the reason at the top of this
        file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        return [string](Invoke-RestMethod `
                -Uri "$script:MetadataRoot/$Path" `
                -Headers @{ 'Metadata-Flavor' = 'Google' } `
                -TimeoutSec $script:HttpTimeoutSeconds)
    } catch {
        # Fail CLOSED on anything that is not a 404. An earlier version of this
        # function swallowed every exception into '', which made one flaky read
        # indistinguishable from "the attribute is not set" -- and the two
        # attributes where that matters are the two where '' is a decision, not
        # a default: an unread ci-job-service-account silently converts a broker
        # pool into a no-broker pool, and an unread ci-image-min-version drops
        # the image floor to 1 and lets a host boot from an image with no shim.
        # A transport error choosing which identity a pool runs as is not an
        # error path anybody would have signed off on. Losing the host is the
        # cheaper outcome, every time.
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode
        }
        if (Test-MetadataAbsence -StatusCode $status) { return '' }
        Deny-Boot ("could not read metadata '$Path' ($($_.Exception.Message)) -- refusing to " +
            'treat an unreadable attribute as an unset one')
    }
}

function Install-BeaconService {
    <#
      .SYNOPSIS
        Materialise the beacon script and run it under the image's shim.
      .DESCRIPTION
        The script arrives as instance metadata rather than living in the image,
        so a beacon fix ships by rolling instances instead of by rebuilding and
        re-rolling an image. The shim does NOT arrive that way: an executable
        delivered through a channel any process on the VM can write is a
        different kind of thing entirely, and it stays in the image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptText,
        [int] $IntervalSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $script:ServiceShim)) {
        Deny-Boot ("the service shim $script:ServiceShim is missing -- this image predates the " +
            'beacon and cannot run one, and a host that cannot say whether it is busy can ' +
            'never be safely deleted')
    }

    # UTF-8 WITH a BOM, written through .NET rather than Set-Content. The two
    # PowerShells disagree: `-Encoding UTF8` means with-BOM on Windows
    # PowerShell 5.1 and without-BOM on 7. A BOM-less file read back by 5.1 --
    # which is what runs the service -- is decoded as ANSI, so the first
    # non-ASCII byte anyone ever adds to the beacon becomes a parse error on a
    # host nobody is watching. Naming the encoding removes the disagreement.
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $scriptPath = Join-Path $script:BinRoot 'ci-beacon.ps1'
    [System.IO.File]::WriteAllText($scriptPath, $ScriptText, $utf8Bom)

    $configPath = Join-Path $script:BinRoot 'ci-beacon.xml'
    [System.IO.File]::WriteAllText($configPath,
        (Get-BeaconServiceConfig -ScriptPath $scriptPath -IntervalSeconds $IntervalSeconds),
        $utf8Bom)

    # Install then start, each checked. `& shim install` is the one call here
    # whose failure is silent by default: it writes to stderr and returns
    # non-zero, and nothing in PowerShell turns that into an exception.
    #
    # The preference is dropped around it deliberately. Under
    # $ErrorActionPreference = 'Stop' -- which the entry point sets -- `2>&1` on
    # a NATIVE command turns each stderr line into a terminating
    # NativeCommandError, so a shim that merely warns would abort the boot here
    # and never reach the exit-code check three lines down. The exit code is the
    # signal; stderr is commentary.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $shimOutput = & $script:ServiceShim 'install' $configPath 2>&1
    $shimExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($shimOutput)) { Write-BootLog "shim: $line" }
    if ($shimExit -ne 0) {
        Deny-Boot "the service shim refused to install the beacon (exit $shimExit)"
    }

    Start-Service -Name $script:BeaconServiceName -ErrorAction Stop
    $svc = Get-Service -Name $script:BeaconServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Deny-Boot "the beacon service is '$($svc.Status)', not Running"
    }
    Write-BootLog "phase 0: beacon service running, interval ${IntervalSeconds}s"
    return $scriptPath
}

function Invoke-Phase0Preflight {
    <#
      .SYNOPSIS
        Read the metadata, assert the OS and the image, start the beacon.
      .DESCRIPTION
        A failed first beacon write is FATAL. A host that cannot say whether it
        is busy is a host that can never be safely deleted -- `beacon_decision()`
        correctly returns keep, forever -- and it is far cheaper to lose it to
        the register-grace drain now than to keep it, billing and invisible,
        later.
    #>
    [CmdletBinding()]
    param()

    Write-BootLog 'phase 0: preflight'
    New-Item -ItemType Directory -Force -Path $script:CiRoot, $script:BinRoot, $script:SlotRoot | Out-Null

    $cfg = [ordered] @{
        Owner          = Get-MetadataValue 'instance/attributes/ci-github-owner'
        Repo           = Get-MetadataValue 'instance/attributes/ci-github-repo'
        HostOs         = Get-MetadataValue 'instance/attributes/ci-host-os'
        Slots          = Get-MetadataValue 'instance/attributes/ci-slots'
        Pool           = Get-MetadataValue 'instance/attributes/ci-pool'
        ImageFloor     = Get-MetadataValue 'instance/attributes/ci-image-min-version'
        BeaconScript   = Get-MetadataValue 'instance/attributes/ci-beacon-script'
        BeaconInterval = Get-MetadataValue 'instance/attributes/ci-beacon-interval'
        InstanceName   = Get-MetadataValue 'instance/name'
        Labels         = Get-MetadataValue 'instance/attributes/ci-runner-labels'
        RunnerGroup    = Get-MetadataValue 'instance/attributes/ci-runner-group'
        JobSa          = Get-MetadataValue 'instance/attributes/ci-job-service-account'
        BrokerPort     = Get-MetadataValue 'instance/attributes/ci-job-broker-port'
        BrokerSource   = Get-MetadataValue 'instance/attributes/ci-job-broker-py'
    }

    if ([string]::IsNullOrWhiteSpace($cfg.Owner) -or [string]::IsNullOrWhiteSpace($cfg.Repo)) {
        Deny-Boot 'missing ci-github-owner/ci-github-repo metadata'
    }

    # An empty label set is the silent version of a dead pool. The controller
    # exits outright on it, because demand would match nothing and the pool would
    # sit at zero hosts while jobs queue; a HOST with no labels is the other half
    # of the same fault -- it registers, GitHub sends it nothing, and the boot log
    # reads as a success. An empty instance name is the same shape one layer down:
    # the agent registers as `-s1`, which orphan_decision() cannot parse back to
    # any instance, so the registration outlives the host forever.
    if ([string]::IsNullOrWhiteSpace($cfg.Labels)) {
        Deny-Boot ('ci-runner-labels metadata is missing or empty -- agents registered without ' +
            'labels are never sent a job, and the host would look perfectly healthy doing nothing')
    }
    if ([string]::IsNullOrWhiteSpace($cfg.InstanceName)) {
        Deny-Boot ('the metadata server did not name this instance -- an agent registered without ' +
            'it cannot be traced back to a host and would never be reaped')
    }

    # The OS marker is asserted, not assumed. Terraform decides which metadata
    # key carries which boot script; a mis-wired pool would otherwise deliver
    # this script to a Linux template and fail in some unrelated place minutes
    # later. Refusing here names the actual mistake.
    if ($cfg.HostOs -ne 'windows') {
        Deny-Boot "ci-host-os is '$($cfg.HostOs)', not 'windows' -- this host was given the wrong boot script"
    }

    $floor = 1
    if ($cfg.ImageFloor -match '^[0-9]+$') { $floor = [int] $cfg.ImageFloor }
    $marker = ''
    if (Test-Path -LiteralPath $script:ImageMarker) {
        $marker = Get-Content -Raw -LiteralPath $script:ImageMarker
    }
    if (-not (Test-ImageVersion -Marker $marker -Floor $floor)) {
        Deny-Boot ("golden image version '$($marker.Trim())' is below the required $floor -- " +
            'this host was booted from the wrong image, and booting a bare one here would ' +
            'reintroduce the per-job install cost this pool removes')
    }
    Write-BootLog "phase 0: image version $($marker.Trim()) >= $floor"

    if ([string]::IsNullOrWhiteSpace($cfg.BeaconScript)) {
        Deny-Boot ('ci-beacon-script metadata is empty -- this host would have no liveness ' +
            'beacon, and a host that cannot say whether it is busy can never be safely deleted')
    }

    if (-not [System.Diagnostics.EventLog]::SourceExists($script:BeaconServiceName)) {
        New-EventLog -LogName Application -Source $script:BeaconServiceName -ErrorAction SilentlyContinue
    }

    $interval = 30
    if ($cfg.BeaconInterval -match '^[0-9]+$') { $interval = [int] $cfg.BeaconInterval }
    $beaconPath = Install-BeaconService -ScriptText $cfg.BeaconScript -IntervalSeconds $interval

    # `ci/boot` is what makes the ABSENT case decidable on the controller: a host
    # past its register grace with no beacon at all and no agent in GitHub's list
    # never ran this script, so no worker can exist on it. Writing it here, from
    # this process, is also the first proof that the guest-attributes path works
    # at all on this instance -- and it is deliberately NOT delegated to the
    # service, whose own first write happens on its own schedule and whose
    # failure this process would never see.
    . $beaconPath
    if (-not (Write-GuestAttribute -Key 'boot' -Value (Get-BeaconTimestamp) -TimeoutSeconds $script:HttpTimeoutSeconds)) {
        Deny-Boot ('the first guest-attribute write failed -- this host could never be safely ' +
            'deleted, so it refuses to serve')
    }
    Write-BootLog 'phase 0: ci/boot published'

    return $cfg
}

# --- phase 1: slot accounts, ACLs, TEMP --------------------------------------
#
# THE VERBS IN THIS SECTION ARE CHOSEN AROUND THE ANALYZER, ONCE, HERE
#
# PSUseShouldProcessForStateChangingFunctions is Warning severity and
# powershell-gate.sh fails on it, so a `Set-`, `New-` or `Remove-` function here
# would have to carry -WhatIf plumbing. A boot script that half-honours -WhatIf
# is a worse object than one with slightly unusual verbs, so the state-changing
# functions use approved verbs outside that rule's list -- Protect-, Grant-,
# Initialize- -- and say so rather than leaving the next reader to wonder.

function Get-AclInheritanceFlag {
    <#
      .SYNOPSIS
        The InheritanceFlags an ACE may carry on this path. Pure.
      .DESCRIPTION
        A DIRECTORY ACE is inheritable: ContainerInherit + ObjectInherit is what
        makes the lock apply to everything created underneath it later.

        A FILE ACE may carry NO flags at all, and this is not a style preference.
        FileSecurity.AddAccessRule REJECTS a rule with inheritance flags on a file:

            Exception calling "AddAccessRule" with "1" argument(s):
            "No flags can be set. Parameter name: inheritanceFlags"

        That throw lands under the entry point's $ErrorActionPreference = 'Stop',
        so the wrong constant here is not a cosmetically loose ACL -- it is a host
        that never finishes booting. Separated out and returned rather than set,
        so a test can assert both answers without an NTFS volume.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool] $IsContainer)

    if ($IsContainer) {
        return [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    return [System.Security.AccessControl.InheritanceFlags]::None
}

function Protect-CiDirectory {
    <#
      .SYNOPSIS
        Lock one directory or file to SYSTEM, Administrators and (optionally) one slot.
      .DESCRIPTION
        Windows creates C:\Users\ci-s<i> at first logon with an ACL of the user,
        SYSTEM and Administrators -- the default is already close to what we want.
        That is not a reason to skip this; it is the reason it is cheap. "Windows
        does the right thing by default" is a claim about an IMAGE, and the image
        changes.

        Inheritance is DISABLED and not copied. Copying it would preserve exactly
        the Users / Authenticated Users entries this exists to remove, and would
        leave a directory that looks locked in the UI and is not -- the same class
        of mistake as a firewall rule that installs and filters nothing.

        Omitting -SlotUser locks the directory to SYSTEM and Administrators only,
        which is how C:\ci and C:\ci\bin are treated: the beacon script lives
        there, the SCM re-executes it as LocalSystem on every restart and reboot,
        and a slot account able to write it would own SYSTEM on this host without
        ever touching the job boundary.

        -ReadOnlyUser is the job-hook shape: every slot must be able to RUN the
        file and none may rewrite it. One hook is executed by every slot on the
        host, so a slot that could write it would be running code in every other
        slot's identity -- this is the Windows spelling of `chown root:root` plus
        `0755`, and it is not optional.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $SlotUser,
        [string[]] $ReadOnlyUser = @()
    )

    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }

    $inherit = Get-AclInheritanceFlag -IsContainer ((Get-Item -LiteralPath $Path).PSIsContainer)
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    # SIDs for the builtins, because their NAMES are localised and this module has
    # no say in which image a customer builds from. 'BUILTIN\Administrators' is
    # 'BUILTIN\Administratoren' on a German image and Get-Acl would reject it.
    $grants = @(
        @{ Id = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'); Rights = 'FullControl' },
        @{ Id = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'); Rights = 'FullControl' }
    )
    if ($SlotUser) {
        $grants += @{ Id = [System.Security.Principal.NTAccount]::new($SlotUser); Rights = 'Modify' }
    }
    foreach ($reader in @($ReadOnlyUser)) {
        $grants += @{ Id = [System.Security.Principal.NTAccount]::new($reader); Rights = 'ReadAndExecute' }
    }

    foreach ($grant in $grants) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $grant.Id, $grant.Rights, $inherit, $none, $allow))) | Out-Null
    }
    Set-Acl -Path $Path -AclObject $acl
}

function Edit-InfPrivilege {
    <#
      .SYNOPSIS
        Set one privilege's account list in a security-policy INF. Pure.
      .DESCRIPTION
        There is no in-box cmdlet for user rights assignment, so the mechanism is
        secedit: export the local policy to an INF, rewrite the [Privilege Rights]
        line, import it back. This function is the rewrite, separated out so
        Pester can assert it on ubuntu-latest -- the alternative is discovering a
        malformed INF on a booting host, where secedit's report of it is a
        non-zero exit code and a log file nobody reads.

        Returns new text; the input string is untouched. Four semantics matter and
        each is asserted by a test:

          * an ABSENT privilege line is ADDED, not silently skipped. A fresh image
            has no SeDenyNetworkLogonRight line at all, and skipping is how a deny
            the code claims to apply ends up not applied;
          * an existing line is REPLACED, not appended to. Appending would leave
            the previous membership in place, which for a deny right reads as
            working and for SeServiceLogonRight quietly widens it;
          * the [Privilege Rights] section is created when the export has none;
          * accounts are written as-is. The caller passes SIDs, because secedit
            resolves names against a locale-dependent account database and this
            script must behave the same on a non-English image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $InfText,
        [Parameter(Mandatory = $true)][string] $Privilege,
        [Parameter(Mandatory = $true)][string[]] $Accounts
    )

    $line = "$Privilege = " + ($Accounts -join ',')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($InfText -split "`r?`n"))

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Privilege))\s*=") {
            $lines[$i] = $line
            return ($lines -join "`r`n")
        }
    }

    $section = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[Privilege Rights\]\s*$') { $section = $i; break }
    }
    if ($section -lt 0) {
        $lines.Add('[Privilege Rights]')
        $lines.Add($line)
    } else {
        $lines.Insert($section + 1, $line)
    }
    return ($lines -join "`r`n")
}

function Grant-SlotLogonRight {
    <#
      .SYNOPSIS
        Grant the slots service logon; deny them every other way in.
      .DESCRIPTION
        SeServiceLogonRight is granted EXPLICITLY here, before config.cmd is ever
        called. GitHub's --runasservice may grant it as a side effect of its own
        installer; that is not established from primary documentation, and a
        safety property that depends on somebody else's installer is not a
        property.

        The three denies are what make the service password harmless. It has to
        exist -- a Windows service logon takes a credential -- so the containment
        is that the credential buys nothing else: no console session, no session
        over the network, no RDP. Deny entries beat allow entries in Windows, so
        this holds even if a later change adds one of these accounts to a group
        that has the right.

        Applied in ONE secedit import, not four. Each import is a full policy
        write, and a host that took four of them could be interrupted between two
        and come up with the grant applied and the denies not -- the exact state
        this exists to prevent, reached by the code meant to prevent it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]] $SlotUsers)

    # SIDs, not names, for the reason given in Edit-InfPrivilege.
    $sids = @($SlotUsers | ForEach-Object {
            '*' + ([System.Security.Principal.NTAccount]::new($_)).Translate(
                [System.Security.Principal.SecurityIdentifier]).Value
        })

    # C:\ci, not $env:TEMP. Under SYSTEM that resolves to C:\Windows\Temp, where
    # unprivileged principals can create files -- and this is the file that
    # decides who holds SeServiceLogonRight and the three deny rights. C:\ci is
    # already SYSTEM-and-Administrators-only by the time this runs.
    $work = Join-Path $script:CiRoot ('ci-secpol-' + [guid]::NewGuid().ToString('N'))
    $exported = "$work.inf"
    $db = "$work.sdb"
    try {
        # The preference is dropped around both native calls for the reason given
        # in Install-BeaconService: under Stop, `2>&1` on a native command turns
        # each stderr line into a terminating NativeCommandError, and secedit
        # writes progress chatter there even when it succeeds.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $exportOutput = & secedit.exe /export /cfg $exported /areas USER_RIGHTS 2>&1
        $exportExit = $LASTEXITCODE
        $ErrorActionPreference = $previous
        foreach ($line in @($exportOutput)) { Write-BootLog "secedit: $line" }
        if ($exportExit -ne 0 -or -not (Test-Path -LiteralPath $exported)) {
            Deny-Boot ("secedit could not export the local security policy (exit $exportExit), " +
                'so slot logon rights cannot be proven applied')
        }

        $inf = Get-Content -Raw -LiteralPath $exported
        # The grant is MERGED with whatever already holds it -- taking
        # SeServiceLogonRight away from the image's own services would stop them.
        # The denies are set to exactly the slots: a deny list is this script's to
        # own, and anything else in it came from an image change nobody reviewed.
        $existingGrant = @()
        if ($inf -match '(?m)^\s*SeServiceLogonRight\s*=\s*(.+)$') {
            $existingGrant = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $grant = @($existingGrant + $sids | Select-Object -Unique)

        $inf = Edit-InfPrivilege -InfText $inf -Privilege 'SeServiceLogonRight' -Accounts $grant
        foreach ($deny in @('SeDenyInteractiveLogonRight',
                'SeDenyNetworkLogonRight',
                'SeDenyRemoteInteractiveLogonRight')) {
            $inf = Edit-InfPrivilege -InfText $inf -Privilege $deny -Accounts $sids
        }

        # UTF-16LE with a BOM, named through .NET rather than through -Encoding.
        # secedit REQUIRES Unicode and reports a file it cannot parse as a generic
        # non-zero exit; `Set-Content -Encoding Unicode` happens to agree today,
        # but the same parameter already means two different things for UTF8 on
        # 5.1 and 7, which is exactly how this class of bug arrives.
        [System.IO.File]::WriteAllText($exported, $inf, [System.Text.UnicodeEncoding]::new($false, $true))

        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $configOutput = & secedit.exe /configure /db $db /cfg $exported /areas USER_RIGHTS 2>&1
        $configExit = $LASTEXITCODE
        $ErrorActionPreference = $previous
        foreach ($line in @($configOutput)) { Write-BootLog "secedit: $line" }
        if ($configExit -ne 0) {
            Deny-Boot ("secedit could not apply slot logon rights (exit $configExit); the slot " +
                'service password would buy an interactive session')
        }
        Write-BootLog "phase 1: service logon granted, interactive/network/RDP denied for $($SlotUsers -join ', ')"
    } finally {
        Remove-Item -LiteralPath $exported, $db -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-SlotAccount {
    <#
      .SYNOPSIS
        Create (or adopt) one slot's local account and its directories.
      .DESCRIPTION
        The account is NOT in Administrators and NOT in Remote Desktop Users, and
        membership is removed rather than merely not granted -- an image that
        ships a `ci-s1` in Administrators would otherwise hand every job on this
        host the machine.

        Adopted rather than recreated when it already exists: a reboot must not
        orphan the profile, the workspace and the warm cache under it. The
        password is rotated on every boot regardless, because the previous one was
        only ever needed to register a service that is about to be re-registered.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Index)

    $user = Get-SlotUserName -Index $Index
    $secure = Get-SlotPassword

    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $user -Password $secure
    } else {
        New-LocalUser -Name $user -Password $secure -AccountNeverExpires `
            -PasswordNeverExpires -UserMayNotChangePassword `
            -Description "ci-runner-host-pool slot $Index" | Out-Null
    }

    foreach ($group in @('Administrators', 'Remote Desktop Users')) {
        if (Get-LocalGroupMember -Group $group -Member $user -ErrorAction SilentlyContinue) {
            Remove-LocalGroupMember -Group $group -Member $user -ErrorAction SilentlyContinue
            Write-BootLog "phase 1: removed $user from $group"
        }
    }

    foreach ($dir in @((Get-SlotWorkspacePath -Index $Index), (Get-SlotTempPath -Index $Index))) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Protect-CiDirectory -Path $dir -SlotUser $user
    }

    # A PSCredential, not a password. Phase 5 hands this straight to the service
    # registration; nothing in between has any use for the plaintext, and not
    # producing it is cheaper than protecting it.
    Write-BootLog "phase 1: slot $Index provisioned as $user"
    return @{
        Index      = $Index
        User       = $user
        Credential = New-Object System.Management.Automation.PSCredential(".\$user", $secure)
    }
}

function Invoke-Phase1SlotSetup {
    <#
      .SYNOPSIS
        Provision every slot: accounts, directories, ACLs, logon rights.
      .DESCRIPTION
        THE ORDER HERE IS THE SAFETY PROPERTY, AGAIN.

        C:\ci and C:\ci\bin are locked to SYSTEM and Administrators BEFORE the
        first slot account exists. Phase 0 created them with whatever ACL C:\
        hands down, which is harmless while the host has no unprivileged
        principal on it -- and stops being harmless the instant this function
        creates one. C:\ci\bin holds ci-beacon.ps1, which the SCM re-executes as
        LocalSystem on every service restart and every reboot; a slot account able
        to write that file owns SYSTEM on this host without going anywhere near
        the job boundary.

        Logon rights come last and in one write, after every account exists, for
        the reason given in Grant-SlotLogonRight.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Slots)

    Write-BootLog "phase 1: provisioning $Slots slot(s)"
    foreach ($dir in @($script:CiRoot, $script:BinRoot, $script:SlotRoot)) {
        Protect-CiDirectory -Path $dir
    }
    Write-BootLog 'phase 1: C:\ci, C:\ci\bin and C:\ci\slots locked to SYSTEM and Administrators'

    $provisioned = @()
    for ($i = 1; $i -le $Slots; $i++) {
        $provisioned += (Initialize-SlotAccount -Index $i)
    }
    Grant-SlotLogonRight -SlotUsers @($provisioned | ForEach-Object { $_.User })
    return $provisioned
}

# --- phase 3: the job credential broker --------------------------------------
#
# WHAT THE BROKER IS FOR, NOW THAT THERE IS NO FENCE
#
# On Linux the fence removes the host identity from job code and the broker hands
# back a weaker one. Section 3A is blunt about what that leaves on Windows: job code can
# reach the metadata server regardless, so a job that wants the host token can
# mint one, and the broker is therefore largely COSMETIC as a boundary. It is
# still built, and the ADR is explicit about why rather than dropping it:
#
#   * it is what makes the reduced identity WORK. `gcloud builds submit` and
#     friends need ADC, the host account has been stripped to
#     serviceAccountTokenCreator on the job account, and the broker is what turns
#     that grant into a credential a job's tooling finds without being rewritten;
#   * a job that mints a host token and impersonates gets exactly what the broker
#     was going to hand it, so the broker costs the attacker nothing and saves
#     every honest workflow a rewrite;
#   * it keeps ONE broker contract across both operating systems. The Python is
#     byte-identical and stays covered by scripts/ci/job-broker.selftest.py.
#
# What it is NOT is a security control on this platform, and this comment exists
# so nobody re-derives one from its presence.
function Install-JobBrokerService {
    <#
      .SYNOPSIS
        Materialise the broker source and run it under the image's shim.
      .DESCRIPTION
        The Python arrives as instance metadata, exactly as the beacon script
        does and exactly as it does on Linux, so one image keeps serving every
        pool while the broker stays versioned with the module. The interpreter and
        the shim do NOT arrive that way: an executable delivered through a channel
        any process on the VM can write is a different kind of thing entirely.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $SourceText,
        [Parameter(Mandatory = $true)][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][int] $Port
    )

    if (-not (Test-Path -LiteralPath $script:ServiceShim)) {
        Deny-Boot ("the service shim $script:ServiceShim is missing -- this image cannot run the " +
            'job credential broker')
    }
    if (-not (Test-Path -LiteralPath $script:PythonExe)) {
        Deny-Boot ("no interpreter at $script:PythonExe -- this image predates the job credential " +
            'broker, and a pool with a job service account whose jobs get no credentials fails ' +
            'at every deploy step instead of at boot')
    }

    # UTF-8 WITHOUT a BOM. CPython accepts a BOM in a source file, but the broker
    # is byte-identical to the Linux one by design and a Windows-only BOM would
    # make the two copies differ for no reason anybody could later explain.
    [System.IO.File]::WriteAllText($script:BrokerScript, $SourceText,
        (New-Object System.Text.UTF8Encoding($false)))

    # The config, by contrast, is read by the shim -- same encoding as the
    # beacon's, for the same 5.1-decodes-a-BOM-less-file-as-ANSI reason.
    $configPath = Join-Path $script:BinRoot 'ci-job-broker.xml'
    [System.IO.File]::WriteAllText($configPath,
        (Get-BrokerServiceConfig -ScriptPath $script:BrokerScript `
                -JobServiceAccount $JobServiceAccount -Port $Port),
        (New-Object System.Text.UTF8Encoding($true)))

    # The preference is dropped around the native call for the reason given in
    # Install-BeaconService: under Stop, `2>&1` on a native command turns each
    # stderr line into a terminating NativeCommandError, so a shim that merely
    # warns would abort the boot before the exit-code check below ever runs.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $shimOutput = & $script:ServiceShim 'install' $configPath 2>&1
    $shimExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($shimOutput)) { Write-BootLog "shim: $line" }
    if ($shimExit -ne 0) {
        Deny-Boot "the service shim refused to install the job credential broker (exit $shimExit)"
    }

    Start-Service -Name $script:BrokerServiceName -ErrorAction Stop
    $svc = Get-Service -Name $script:BrokerServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Deny-Boot "the job credential broker service is '$($svc.Status)', not Running"
    }
}

function Test-JobBrokerReady {
    <#
      .SYNOPSIS
        Does the broker actually VEND a token? Returns $true when it does.
      .DESCRIPTION
        Asserted before any agent registers, because a broker that LOOKS up and
        vends nothing turns every deploy step into a confusing auth failure at job
        time -- the Linux script proves the same thing for the same reason. This
        is the capability, not the daemon: `Get-Service` returning Running is the
        check that passed on the hosts where nothing worked.

        Each attempt is bounded. A broker that ACCEPTS a connection and never
        answers would otherwise turn a 30x2s readiness probe into an unbounded
        wait, which is the 2h55m outage in miniature.

        A vended token proves a broker is THERE, not that it is OURS. The owner
        check after the loop is the second half, and it is deliberately outside
        the retry: a squatter does not go away on attempt 12, and Deny-Boot
        raised inside the `try` would be caught by the very handler that exists
        to tolerate a broker that has not finished starting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Port,
        [int] $Attempts = 30,
        [int] $DelaySeconds = 2
    )
    $uri = "http://127.0.0.1:$Port/computeMetadata/v1/instance/service-accounts/default/token"
    $vended = $false
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $token = Invoke-RestMethod -Uri $uri `
                -Headers @{ 'Metadata-Flavor' = 'Google' } `
                -TimeoutSec $script:HttpTimeoutSeconds
            # A body, not merely a 200. The broker answers 200 with an error
            # document on some paths, and "it responded" is the weaker question.
            if ($token -and $token.access_token) {
                $vended = $true
                break
            }
        } catch {
            $null = $_
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    if (-not $vended) { return $false }

    if (-not (Test-BrokerListenerSid -Sid (Get-PortListenerSid -Port $Port))) {
        Deny-Boot ("something other than LocalSystem is listening on 127.0.0.1:$Port -- refusing " +
            'to point job credentials at a socket this host does not own')
    }
    return $true
}

function Get-PortListenerSid {
    <#
      .SYNOPSIS
        The SID of the process listening on a loopback port, or '' when none is.
      .DESCRIPTION
        Split out from the predicate so the predicate stays pure and testable.
        Returns '' rather than throwing on every failure mode -- no listener, a
        process that exited between the two lookups, a CIM call that did not
        answer -- because Test-BrokerListenerSid treats '' as "not ours", which
        is the fail-closed reading of every one of them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Port)
    try {
        $listener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)[0]
        if (-not $listener) { return '' }
        $proc = Get-CimInstance -ClassName Win32_Process `
            -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction Stop
        if (-not $proc) { return '' }
        # The SID, not the account name. `NT AUTHORITY\SYSTEM` is localised and
        # this image is only en-US until the day somebody builds one that is not.
        return [string](Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop).Sid
    } catch {
        $null = $_
        return ''
    }
}

function Lock-LoopbackPort {
    <#
      .SYNOPSIS
        Make one TCP port permanently unbindable on this host.
      .DESCRIPTION
        Used for the closed-metadata port, and the reason it is not merely
        cosmetic: with GCE_METADATA_* now always set, a pool with no broker
        points every slot's ADC at 127.0.0.1:1. If a job could BIND that port it
        would be handing the next job on this warm host a token of its own
        choosing -- the no-broker pool would go from "no credentials" to "the
        previous pull request's credentials", which is worse than what this
        change set out to fix.

        Fatal when it fails, because the alternative is a host whose fail-closed
        endpoint is open for anyone to answer on, and the boot log would say
        nothing at all about it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Port)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & netsh @(Get-PortReservationArgument -Port $Port) 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($out)) { Write-BootLog "netsh: $line" }
    # Already reserved is success. The host may have been rebooted, and an
    # excluded port range survives a reboot.
    if ($code -ne 0 -and ($out -join ' ') -notmatch 'already|exists') {
        Deny-Boot ("could not reserve loopback port $Port (netsh exit $code) -- a job could bind " +
            "the endpoint this host's credential-free slots are pointed at")
    }
}

function Invoke-Phase3JobBroker {
    <#
      .SYNOPSIS
        Start the broker, or decide deliberately that this pool has none.
      .DESCRIPTION
        An empty `ci-job-service-account` means no broker and no Google
        credentials for jobs at all. That is a VALID pool -- a repository whose CI
        never touches GCP -- but it is NOT self-enforcing on Windows, and that is
        the correction here. There is no metadata fence (section 3A), so a slot
        whose ADC is unpointed reaches 169.254.169.254 and authenticates as the
        host. The no-broker path therefore has real work to do: it reserves the
        closed loopback port that Get-SlotServiceEnvironment points those slots
        at, so ADC is refused rather than redirected to the host identity.

        Said in the log either way, because "no broker" and "broker that failed"
        must not look the same to whoever reads the boot afterwards.

        Returns the endpoint phase 5 points the slots at, or '' when there is no
        broker -- '' being what Get-SlotServiceEnvironment turns into the closed
        endpoint, which is why it is a return value rather than a flag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $BrokerSource,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $BrokerPort
    )

    if ([string]::IsNullOrWhiteSpace($JobServiceAccount)) {
        Lock-LoopbackPort -Port $script:ClosedMetadataPort
        Write-BootLog ('phase 3: no ci-job-service-account -- no broker. Slots are pointed at ' +
            "$script:ClosedMetadataEndpoint, which is reserved and unbindable, so job code gets " +
            'no Google credentials rather than the host identity.')
        return ''
    }

    # Refused, not defaulted. A port that cannot be parsed serves the same broker;
    # an identity that cannot be parsed would be somebody else's.
    $account = $JobServiceAccount.Trim()
    if (-not (Test-JobServiceAccountName -Name $account)) {
        Deny-Boot ('ci-job-service-account is not a service-account address -- refusing to put it ' +
            "in a service definition or a service environment block")
    }

    if ([string]::IsNullOrWhiteSpace($BrokerSource)) {
        Deny-Boot ('a job service account is configured but ci-job-broker-py is empty -- every ' +
            'deploy step on this host would fail at job time with an auth error')
    }

    $port = Get-BrokerPort -Value $BrokerPort
    Install-JobBrokerService -SourceText $BrokerSource -JobServiceAccount $account -Port $port
    if (-not (Test-JobBrokerReady -Port $port)) {
        Deny-Boot ("the job credential broker did not vend a token on 127.0.0.1:$port -- a host " +
            'that registers without it turns every deploy step into a confusing auth failure')
    }

    Write-BootLog "phase 3: job credential broker serving $account on 127.0.0.1:$port"
    return "127.0.0.1:$port"
}

# --- phase 4: the per-job credential reset hooks ------------------------------

function Install-JobHook {
    <#
      .SYNOPSIS
        Write the reset hook and lock it: every slot may run it, none may edit it.
      .DESCRIPTION
        The ACL is the security half and it is not optional. ONE file is executed
        by every slot on the host, so a slot that could rewrite it would be
        running code in every other slot's identity -- and, the host being warm,
        in every later job's too. This is the Windows spelling of `chown
        root:root` plus `0755`.

        Installed BEFORE any agent registers (phase 5), and fatal if it fails: an
        agent whose JOB_STARTED hook points at a missing file takes work and fails
        all of it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]] $SlotUsers)

    New-Item -ItemType Directory -Force -Path $script:JobHookRoot | Out-Null
    [System.IO.File]::WriteAllText($script:JobHookPath, (Get-JobHookScript),
        (New-Object System.Text.UTF8Encoding($true)))

    # The directory and the file both. Locking only the file leaves a directory a
    # slot could rename the hook out of, which fails every job rather than
    # subverting one -- but it is the same missing-hook fault by a longer path.
    Protect-CiDirectory -Path $script:JobHookRoot -ReadOnlyUser $SlotUsers
    Protect-CiDirectory -Path $script:JobHookPath -ReadOnlyUser $SlotUsers
    Write-BootLog ("phase 4: reset hook at $script:JobHookPath, runnable by " +
        "$($SlotUsers -join ', ') and writable by none of them")
}

function Invoke-Phase4JobHook {
    <#
      .SYNOPSIS
        Install the reset hook. Returns the path phase 5 points both hooks at.
      .DESCRIPTION
        UNCONDITIONAL, and that is the whole design decision in this phase. There
        is no `if a job service account is configured` around it: a pool with no
        broker is where an inherited credential is MOST dangerous, because nothing
        on the host competes with whatever a workflow left behind and the leftover
        is simply what the next job authenticates as.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]] $SlotUsers)
    Install-JobHook -SlotUsers $SlotUsers
    return $script:JobHookPath
}

# --- phase 5: agent registration as a per-slot service ------------------------

function Wait-RegistrationToken {
    <#
      .SYNOPSIS
        The controller-minted registration token, or a denied boot. Never ''.
      .DESCRIPTION
        CALLED ONCE PER HOST, ABOVE THE SLOT LOOP. See obligation (a) at the top
        of this file: the controller deletes the key as soon as GitHub reports
        ANY of this host's agents registered, so a second read taken after slot 1
        comes up returns nothing and strands slot 2 silently.

        A Windows host cannot mint its own token. Section 3A reduced its service
        account to serviceAccountTokenCreator on the job account and nothing else
        precisely because job code on this platform can reach the metadata server
        and mint whatever the host can -- so the Secret Manager grant the Linux
        host uses to sign its own App JWT is exactly the thing that must not be
        here. The controller mints instead and writes the token to this instance.

        OBLIGATION (b) IS THE TIMEOUT ARM, AND IT IS NOT AN ERROR PATH

        A host that reboots after the key was deleted -- and Windows hosts reboot
        for updates, so this is ordinary -- finds nothing here, and the controller
        will not mint a second: the `<key>-issued` marker it wrote in the same
        metadata call is never removed, and the mint is refused unless that
        marker is provably absent. Blocking is therefore the DESIGNED outcome, not
        a failure to handle one. The host registers nothing, the register-grace
        drain reclaims it, and the MIG replaces it with an instance the controller
        has never issued a token to.

        The alternative -- carrying on with an empty token -- is strictly worse in
        both directions: config.cmd fails with an authentication error that reads
        like a GitHub outage, and if it ever did not, the host would be serving
        jobs the controller believes it deregistered.

        Polled rather than `wait-for-change`d. The long-poll would block until the
        key appears, which on the reboot case above is forever, and forever is the
        2h55m outage: a host that never registers, never powers off, and counts
        against the pool's size the whole time it does not exist.
    #>
    [CmdletBinding()]
    param(
        [int] $TimeoutSeconds = $script:RegistrationWaitSeconds,
        [int] $PollSeconds = $script:RegistrationPollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $announced = $false
    while ($true) {
        $token = Get-MetadataValue "instance/attributes/$script:RegistrationTokenKey"
        # Trimmed and tested for EMPTY, not for null. An interrupted controller
        # write leaves a zero-length value, and a zero-length token is the case
        # that must block rather than register.
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            Write-BootLog 'phase 5: registration token present'
            return $token.Trim()
        }
        if (-not $announced) {
            Write-BootLog ("phase 5: waiting up to ${TimeoutSeconds}s for the controller to write " +
                "$script:RegistrationTokenKey")
            $announced = $true
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    Deny-Boot ("no $script:RegistrationTokenKey on this instance after ${TimeoutSeconds}s. If this " +
        'host has registered before, this is the EXPECTED transition after a reboot: the ' +
        'controller deleted the key once the agents appeared and will not mint a second one for ' +
        'this instance. Registering with an empty token is refused -- the host registers nothing, ' +
        'the register-grace drain reclaims it, and the MIG replaces it.')
}

function Grant-ServiceLogonAccount {
    <#
      .SYNOPSIS
        Point one service at a slot's local account, without a plaintext password.
      .DESCRIPTION
        THE REASON THIS IS P/INVOKE AND NOT sc.exe OR config.cmd

        Every documented way of setting a service's logon account takes the
        password as a STRING: the sc.exe config form puts it in the process table,
        config.cmd's own logon-password flag does the same, and
        Win32_Service.Change takes a managed String that cannot be
        erased and lives until the GC decides otherwise. On this host the process
        table is readable by the very accounts whose credentials those are, and
        those accounts run pull-request code.

        ChangeServiceConfigW takes the password as a pointer.
        SecureStringToGlobalAllocUnicode marshals it out of the SecureString into
        unmanaged memory, ZeroFreeGlobalAllocUnicode wipes and frees it in a
        `finally`, and no [string] of the password exists at any point. That is
        what keeps the file's standing rule -- the slot password never leaves the
        SecureString it was born in -- true through the one phase that has to
        spend it.

        SERVICE_NO_CHANGE for every field but the account, so this changes the
        logon identity and nothing else about a service config.cmd just wrote.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential] $Credential
    )

    if (-not ('CiHostPool.ServiceConfig' -as [type])) {
        Add-Type -Namespace 'CiHostPool' -Name 'ServiceConfig' -MemberDefinition @'
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr OpenSCManagerW(string machineName, string databaseName, uint access);

[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr OpenServiceW(IntPtr manager, string serviceName, uint access);

[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool ChangeServiceConfigW(IntPtr service, uint serviceType, uint startType,
    uint errorControl, string binaryPath, string loadOrderGroup, IntPtr tagId, string dependencies,
    string startName, IntPtr password, string displayName);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool CloseServiceHandle(IntPtr handle);
'@
    }

    $noChange = [uint32]::MaxValue
    $manager = [CiHostPool.ServiceConfig]::OpenSCManagerW($null, $null, 0x0001)
    if ($manager -eq [IntPtr]::Zero) {
        Deny-Boot "cannot open the service control manager (win32 $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    $service = [IntPtr]::Zero
    $password = [IntPtr]::Zero
    try {
        # SERVICE_CHANGE_CONFIG only. Nothing here needs to start, stop or query
        # the service, and a handle that could is a handle a later edit would use.
        $service = [CiHostPool.ServiceConfig]::OpenServiceW($manager, $ServiceName, 0x0002)
        if ($service -eq [IntPtr]::Zero) {
            Deny-Boot ("cannot open service $ServiceName to set its logon account " +
                "(win32 $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))")
        }
        $password = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode(
            $Credential.Password)
        $ok = [CiHostPool.ServiceConfig]::ChangeServiceConfigW($service, $noChange, $noChange,
            $noChange, $null, $null, [IntPtr]::Zero, $null, $Credential.UserName, $password, $null)
        if (-not $ok) {
            Deny-Boot ("cannot set $ServiceName to run as $($Credential.UserName) " +
                "(win32 $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())) -- an agent " +
                'left on the SCM default would run every job on this slot as a shared machine account')
        }
    } finally {
        if ($password -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($password)
        }
        if ($service -ne [IntPtr]::Zero) { [CiHostPool.ServiceConfig]::CloseServiceHandle($service) | Out-Null }
        [CiHostPool.ServiceConfig]::CloseServiceHandle($manager) | Out-Null
    }
}

function Write-ServiceEnvironment {
    <#
      .SYNOPSIS
        Write one service's own environment block. Per service, never machine-wide.
      .DESCRIPTION
        A machine-wide TMP hands every slot the same one, which is the collision
        the per-slot directory exists to remove, and machine-wide GCE_METADATA_*
        would point the HOST's own tooling at the broker -- including, on a later
        boot, anything this script runs. The SCM reads `Environment` off the
        service's own key and hands it to that process and nothing else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Environment
    )
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path -LiteralPath $key)) {
        Deny-Boot "no service key at $key -- the runner service was not installed under the name it reported"
    }
    New-ItemProperty -LiteralPath $key -Name 'Environment' `
        -PropertyType MultiString -Force `
        -Value (Get-ServiceEnvironmentValue -Environment $Environment) | Out-Null
}

function Clear-ServiceRecoveryAction {
    <#
      .SYNOPSIS
        Take away the SCM's restart-on-failure policy for one runner service.
      .DESCRIPTION
        THIS IS THE WINDOWS SPELLING OF THE LINUX UNIT'S `Restart=no`, AND THE
        README'S RECYCLE CONTRACT DEPENDS ON IT.

        Agents here are not --ephemeral, so the controller drains a host by
        DEREGISTERING its agents through the GitHub API -- which GitHub refuses
        while an agent is executing a job, and which is exactly what makes a
        cordoned host lose its idle slots permanently while its working slot
        finishes. A deregistered slot must STAY deregistered.

        A service installed by config.cmd carries the SCM's recovery actions. An
        agent that auto-restarts after a job-time failure re-registers itself,
        takes more work, and does it on a host the controller believes is draining
        -- so the host that was supposed to be retiring never retires, and the
        pool holds a machine nobody can delete. A cleanly exiting agent is not a
        "failure" and should not trigger recovery at all; the guarantee this
        design needs is not "should not".

        `reset= 0 actions= ""` is empty-string-terminated on sc.exe's own command
        line, and Windows PowerShell 5.1 DROPS an empty argument when it builds a
        native command line -- so `& sc.exe ... 'actions=' ''` would send
        `actions=` with nothing after it and sc.exe would reject the whole call.
        Handing cmd.exe one string is what keeps the empty argument. $ServiceName
        is safe to interpolate only because Get-RunnerServiceName refused anything
        that was not literally `actions.runner.<...>`, and it came out of a file
        the slot account can write.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $ServiceName)

    if ((Get-RunnerServiceName -Marker $ServiceName) -ne $ServiceName) {
        Deny-Boot "refusing to pass '$ServiceName' to sc.exe -- it is not a runner service name"
    }

    # The preference is dropped around the native call for the reason given in
    # Install-BeaconService: under Stop, `2>&1` on a native command turns each
    # stderr line into a terminating NativeCommandError before the exit code is
    # ever read.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & cmd.exe /c "sc.exe failure `"$ServiceName`" reset= 0 actions= `"`"" 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($output)) { Write-BootLog "sc: $line" }
    if ($exit -ne 0) {
        Deny-Boot ("could not clear the recovery actions on $ServiceName (exit $exit) -- an agent " +
            'that restarts itself out of a cordon re-registers, takes more work, and keeps a host ' +
            'the controller is draining alive forever')
    }
}

function Register-SlotAgent {
    <#
      .SYNOPSIS
        Configure and start one slot's agent as a service running as that slot.
      .DESCRIPTION
        The order is the safety property, again, and every step is fatal:

          1. copy the baked agent, per slot. config.cmd writes `.runner` and
             `.credentials` into the directory it runs in, so K agents sharing one
             directory would share one identity;
          2. config.cmd, ELEVATED. It creates a service and touches an account
             right, so it cannot run as the slot -- which is why step 4 exists;
          3. read the service name the agent itself recorded, and refuse anything
             that is not one, or that is not THIS slot's;
          4. STOP it. config.cmd --runasservice starts the service it installs,
             under the SCM default account, before this script has said anything
             about identity -- and neither the logon account nor the environment
             block reaches a process that is already running;
          5. re-apply the ACL. config.cmd wrote `.runner` and `.credentials` as
             the elevated identity, so without this the agent cannot read its own
             credentials -- or, worse, a sibling can. The Linux script's
             `chown -R "$u:$u" "$dir"` is the same step;
          6. environment, then recovery actions, then the logon account -- all
             while it is stopped. A service started once with the SCM's default
             account has already written its own state as the wrong identity;
          7. start, and verify it is Running rather than assume it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Slot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RegistrationToken,
        [Parameter(Mandatory = $true)][string] $Owner,
        [Parameter(Mandatory = $true)][string] $Repo,
        [Parameter(Mandatory = $true)][string] $InstanceName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Labels,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RunnerGroup,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Environment
    )

    # OBLIGATION (b), AT THE LAST POSSIBLE MOMENT. Wait-RegistrationToken already
    # denies the boot rather than returning empty, so reaching here with nothing
    # means a later edit made the token optional somewhere in between. config.cmd
    # with an empty --token produces an agent-side authentication failure that
    # reads like a GitHub outage; blocking produces a host the register-grace
    # drain reclaims, which is the designed outcome.
    if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
        Deny-Boot ("slot $($Slot.Index): refusing to run config.cmd with an empty registration " +
            'token -- a host that cannot register must block and be reclaimed, not register wrong')
    }

    if (-not (Test-Path -LiteralPath $script:RunnerTemplate)) {
        Deny-Boot ("no agent at $script:RunnerTemplate -- this image predates the runner and a host " +
            'that installed one at boot would have re-invented the per-job cost this pool removes')
    }

    $dir = Get-SlotWorkspacePath -Index $Slot.Index
    $agent = Join-Path $dir 'runner'
    $name = Get-SlotAgentName -InstanceName $InstanceName -Index $Slot.Index
    New-Item -ItemType Directory -Force -Path $agent | Out-Null
    Copy-Item -Path (Join-Path $script:RunnerTemplate '*') -Destination $agent -Recurse -Force

    $configArgs = Get-RunnerConfigArgument -Owner $Owner -Repo $Repo -Name $name `
        -Labels $Labels -WorkPath (Join-Path $agent '_work') -RunnerGroup $RunnerGroup

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # The token is appended HERE and nowhere a test or a log can reach it. It is
    # still an argument to config.cmd and therefore visible in this host's process
    # table for the length of that call -- accepted, because section 3A already
    # accepts that job code on this host can read the same value straight out of
    # instance metadata, and the controller's delete is what bounds both.
    $configOutput = & (Join-Path $agent 'config.cmd') @configArgs --token $RegistrationToken 2>&1
    $configExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    # Redacted, and not because config.cmd is known to echo it. It is not, today.
    # The log sink is SYSTEM-and-Administrators-only and the serial console is
    # behind project IAM, so this is the third lock on a door that is already
    # shut -- and the one that does not depend on upstream never changing its
    # error text.
    foreach ($line in @($configOutput)) {
        Write-BootLog ("slot $($Slot.Index) config: " +
            (Get-RedactedLine -Line ([string] $line) -Secret $RegistrationToken))
    }
    if ($configExit -ne 0) {
        Deny-Boot "slot $($Slot.Index): config.cmd failed (exit $configExit)"
    }

    $marker = ''
    $markerPath = Join-Path $agent '.service'
    if (Test-Path -LiteralPath $markerPath) {
        $marker = Get-Content -Raw -LiteralPath $markerPath
    }
    $serviceName = Get-RunnerServiceName -Marker $marker -AgentName $name
    if (-not $serviceName) {
        Deny-Boot ("slot $($Slot.Index): the agent did not record a usable service name for $name in " +
            "$markerPath -- its environment, its logon account and its recovery policy would all " +
            'be set on a service that does not exist or belongs to another slot, while the one that ' +
            'does starts with none of them')
    }

    # THE STEP WITHOUT WHICH EVERY STEP BELOW IT IS DECORATION
    #
    # `config.cmd --runasservice` does not just install the service, it STARTS
    # it -- under the SCM default account, before this script has said a word
    # about identity. ChangeServiceConfigW edits the registry, not a running
    # process, and the SCM reads `Environment` at start; so a service left
    # running here keeps the shared machine account and none of the environment
    # block for its whole life, while `Start-Service` on an already-running
    # service returns success and the Running check below agrees. The agent would
    # take pull-request jobs as the wrong identity with no hooks, and every log
    # line would say it worked.
    #
    # Inline rather than a helper, because the helper would be named
    # Stop-Something and the analyzer demands a ShouldProcess block on that verb.
    $installed = Get-Service -Name $serviceName -ErrorAction Stop
    if ($installed.Status -ne 'Stopped') {
        Write-BootLog ("slot $($Slot.Index): $serviceName came up under the SCM default account " +
            'during config.cmd -- stopping it before its identity and environment are set')
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
        $installed.WaitForStatus('Stopped', [timespan]::FromSeconds($script:ServiceStopSeconds))
        $installed.Refresh()
        if ($installed.Status -ne 'Stopped') {
            Deny-Boot ("slot $($Slot.Index): $serviceName will not stop, so it would keep the shared " +
                'machine account and none of the per-slot environment for the life of this host')
        }
    }

    # After config.cmd, and re-proved rather than assumed. `.runner` and
    # `.credentials` were written by the elevated identity; an agent that cannot
    # read its own credentials never comes up, and a sibling that can read them is
    # the boundary this whole design is built on.
    Protect-CiDirectory -Path $agent -SlotUser $Slot.User

    Write-ServiceEnvironment -ServiceName $serviceName -Environment $Environment
    Clear-ServiceRecoveryAction -ServiceName $serviceName
    Grant-ServiceLogonAccount -ServiceName $serviceName -Credential $Slot.Credential

    Start-Service -Name $serviceName -ErrorAction Stop
    $svc = Get-Service -Name $serviceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Deny-Boot "slot $($Slot.Index): $serviceName is '$($svc.Status)', not Running"
    }

    # Running is not the assertion. WHO it is running as is. Everything above
    # this line is an attempt to make the answer be the slot account, and the
    # failure this file spent the most care on -- an agent that quietly kept the
    # SCM default -- looks exactly like success from the Status alone.
    $configured = (Get-CimInstance -ClassName Win32_Service `
            -Filter "Name='$serviceName'" -ErrorAction Stop).StartName
    if (-not (Test-ServiceLogonAccount -StartName $configured -SlotUser $Slot.User)) {
        Deny-Boot ("slot $($Slot.Index): $serviceName is running as '$configured', not $($Slot.User) " +
            '-- every job on this slot would run as a machine-wide account shared with the other slots')
    }
    Write-BootLog ("phase 5: slot $($Slot.Index) registered as $name, service $serviceName " +
        "running as $configured, recovery actions cleared")
}

function Invoke-Phase5Registration {
    <#
      .SYNOPSIS
        Register every slot's agent from ONE read of the registration token.
      .DESCRIPTION
        OBLIGATION (a) IS THE SHAPE OF THIS FUNCTION, NOT A CHECK INSIDE IT

        The read is above the loop and its value is passed down. Moving it into
        Register-SlotAgent -- which is the tidier-looking edit, since that is
        where the token is used -- breaks a two-slot host in a way nothing on the
        controller can see: slot 1 registers, GitHub reports the host `partial`,
        the controller deletes the key, and slot 2's read comes back empty. The
        host runs at half capacity and every log line says success. The bash
        self-test asserts the read's position for exactly this reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array] $Provisioned,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Config,
        [Parameter(Mandatory = $true)][string] $HookPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $BrokerEndpoint
    )

    $regToken = Wait-RegistrationToken
    foreach ($slot in $Provisioned) {
        $block = Get-SlotServiceEnvironment -Index $slot.Index `
            -HookPath $HookPath -BrokerEndpoint $BrokerEndpoint
        Register-SlotAgent -Slot $slot -RegistrationToken $regToken `
            -Owner $Config.Owner -Repo $Config.Repo -InstanceName $Config.InstanceName `
            -Labels $Config.Labels -RunnerGroup $Config.RunnerGroup -Environment $block
    }
    Write-BootLog "phase 5: $($Provisioned.Count) agent(s) registered"
}

function Invoke-Main {
    [CmdletBinding()]
    param()
    $cfg = Invoke-Phase0Preflight

    # One slot is the fallback, not an error. `ci-slots` is written by Terraform
    # and the Windows pool pins it to 1; a host that arrived without it is still a
    # host, and refusing the boot over a missing count would trade a working
    # single-slot machine for none.
    $slots = 1
    if ($cfg.Slots -match '^[0-9]+$' -and [int] $cfg.Slots -ge 1) { $slots = [int] $cfg.Slots }
    $provisioned = @(Invoke-Phase1SlotSetup -Slots $slots)
    $slotUsers = @($provisioned | ForEach-Object { $_.User })

    # Named, not counted. Phase 5 registers one agent per account listed here, so
    # a boot log that says "3 slots" and a host that has ci-s1 and ci-s3 read the
    # same -- and the difference is which agent never came back.
    Write-BootLog ('phase 1: slot accounts ' + ($slotUsers -join ', '))

    # Both before phase 5, and that ordering is the same safety property the rest
    # of this file is built on: an agent registered before its broker turns every
    # deploy step into an auth failure, and an agent registered before its hook
    # takes work whose JOB_STARTED points at a file that is not there.
    $brokerEndpoint = Invoke-Phase3JobBroker `
        -JobServiceAccount $cfg.JobSa -BrokerSource $cfg.BrokerSource -BrokerPort $cfg.BrokerPort
    $hookPath = Invoke-Phase4JobHook -SlotUsers $slotUsers

    # LAST, and the only phase that makes this host reachable by a job. Everything
    # above it is a boundary; this is what is let inside one.
    Invoke-Phase5Registration -Provisioned $provisioned -Config $cfg `
        -HookPath $hookPath -BrokerEndpoint $brokerEndpoint

    # Phase 6 is not here yet. Said out loud rather than left as silence: until
    # the probe exists, nothing on this host PROVES from a slot's own context that
    # the boundaries above hold -- and a boundary nobody checks is a comment.
    Write-BootLog ('phase 6 is not delivered yet: this host registers agents without proving the ' +
        'slot boundary from a slot context')
}

# Dot-sourceable without side effects, so Pester can import the pure functions
# above on ubuntu-latest. A requirement of the design, not a style preference,
# and asserted by a test rather than trusted.
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Invoke-Main
}
