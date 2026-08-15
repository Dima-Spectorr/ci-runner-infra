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
#   phase 2  the metadata fence                                (not yet)
#   phase 3  the job credential broker                         (not yet)
#   phase 4  the per-job credential reset hooks                (not yet)
#   phase 5  agent registration as a service                   (not yet)
#   phase 6  the boot probe, which PROVES 2 and 1              (not yet)
#
# Phase 1 builds the boundary and hands back the credentials that will sit
# behind it; nothing CONSUMES them until phase 5 registers the agents. A host
# that stops here has the accounts, the rights and the ACLs in place and no job
# code on the machine to test them against, which is the safe half to ship first.
#
# Until phase 5 exists this script registers no agent, so a host running it
# serves no jobs. That is the intended state of a half-delivered Windows pool
# and it is why `host_os` is not yet an input to the module.
#
# Every phase either succeeds or the host registers nothing. There is no partial
# host: one that came up without its fence is a host on which any pull request
# owns the fleet.
#
# WHY THE BEACON IS PHASE 0 AND NOT PHASE 5
#
# Two orderings force it. First, there must be no instant in this host's life at
# which a `Runner.Worker.exe` could exist without a publisher able to see it, and
# the cheapest way to guarantee that is to start the publisher before anything
# that could ever spawn one. Second, the phase-2 metadata fence exempts the
# beacon by SERVICE SID, and a SID that does not exist yet cannot be exempted --
# an ordering bug there would fence the beacon out of the metadata server and
# strand every host in the pool.

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
    $shimArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" " +
    "-IntervalSeconds $IntervalSeconds"
    return @"
<service>
  <id>$ServiceName</id>
  <name>$ServiceName</name>
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

# --- phase 0 -----------------------------------------------------------------

function Get-MetadataValue {
    <#
      .SYNOPSIS
        Read one metadata value. Empty string when absent.
      .DESCRIPTION
        Called ONLY in phase 0, and that is a design constraint rather than an
        accident of ordering: after the fence goes in (phase 2) this script's own
        access to 169.254.169.254:80 is gone. Everything the boot needs is read
        here, while the read still works.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        return [string](Invoke-RestMethod `
                -Uri "$script:MetadataRoot/$Path" `
                -Headers @{ 'Metadata-Flavor' = 'Google' } `
                -TimeoutSec $script:HttpTimeoutSeconds)
    } catch {
        $null = $_
        return ''
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
    }

    if ([string]::IsNullOrWhiteSpace($cfg.Owner) -or [string]::IsNullOrWhiteSpace($cfg.Repo)) {
        Deny-Boot 'missing ci-github-owner/ci-github-repo metadata'
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

function Protect-CiDirectory {
    <#
      .SYNOPSIS
        Lock one directory to SYSTEM, Administrators and (optionally) one slot.
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $SlotUser
    )

    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }

    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
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

    $work = Join-Path $env:TEMP ('ci-secpol-' + [guid]::NewGuid().ToString('N'))
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
    Invoke-Phase1SlotSetup -Slots $slots | Out-Null

    # Phases 2-6 are not here yet, and this host therefore registers no agent.
    # Said out loud in the log rather than left as silence, because a host that
    # boots cleanly and serves nothing is otherwise indistinguishable from one
    # that is merely slow to register.
    Write-BootLog ('phases 2-6 are not delivered yet: this host registers no agent and will be ' +
        'reclaimed by the register-grace drain')
}

# Dot-sourceable without side effects, so Pester can import the pure functions
# above on ubuntu-latest. A requirement of the design, not a style preference,
# and asserted by a test rather than trusted.
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Invoke-Main
}
