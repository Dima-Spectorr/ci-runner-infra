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
#   phase 1  slot accounts, logon rights, ACLs, per-slot TEMP  (not yet)
#   phase 2  the metadata fence                                (not yet)
#   phase 3  the job credential broker                         (not yet)
#   phase 4  the per-job credential reset hooks                (not yet)
#   phase 5  agent registration as a service                   (not yet)
#   phase 6  the boot probe, which PROVES 2 and 1              (not yet)
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

function Invoke-Main {
    [CmdletBinding()]
    param()
    Invoke-Phase0Preflight | Out-Null

    # Phases 1-6 are not here yet, and this host therefore registers no agent.
    # Said out loud in the log rather than left as silence, because a host that
    # boots cleanly and serves nothing is otherwise indistinguishable from one
    # that is merely slow to register.
    Write-BootLog ('phases 1-6 are not delivered yet: this host registers no agent and will be ' +
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
