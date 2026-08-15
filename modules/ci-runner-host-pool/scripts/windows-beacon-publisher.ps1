# ci-runner-host-pool -- the Windows host's LIVENESS BEACON.
#
# The controller may not delete a host until it knows no job worker is running
# on it. On Linux it asks over SSH and reads `pgrep -fc Runner.Worker`. Windows
# has no sshd and no pgrep, so the host answers the same question OUTBOUND: it
# writes the count into its own guest attributes, and the controller reads it
# through the compute API it already calls. `beacon_decision()` on the
# controller turns that reading into a verdict; this file produces the reading.
#
# WHY IT IS A SEPARATE, TRACKED FILE
#
# It is delivered as instance metadata, exactly as `job-metadata-broker.py` is,
# rather than written to disk by the boot script from a here-string. A
# here-string would be invisible to `scripts/ci/powershell-gate.sh` and to
# `scripts/ci/bounded-calls.selftest.sh` -- this repository's two ways of reading
# PowerShell -- and the one process whose silence makes a host undeletable is the
# last one that should be exempt from both.
#
# WHY IT RUNS AS A SERVICE AND NOT A SCHEDULED TASK
#
# The metadata fence blocks every process on the machine from reaching
# 169.254.169.254:80, and the exemptions are scoped by SERVICE SID. A scheduled
# task does not have one, so a scheduled beacon would be fenced out of the very
# endpoint it must write to.
#
# THE FAILURE MODE THIS FILE IS SHAPED AROUND
#
# A publisher that dies silently makes its host permanently undeletable: the
# controller reads a stale beacon, `beacon_decision()` correctly returns `keep:`,
# and the host bills forever while the pool reports the right number of machines.
# So every loop iteration is bounded, no iteration can throw its way out of the
# loop, and a failed write is logged and retried rather than being fatal -- the
# staleness itself is the signal, and the controller already knows how to read
# it.
#
# WHAT THIS BEACON IS NOT
#
# It is not a security control. Google documents guest attributes as writable by
# ANY process on the VM, and job code runs on this VM, so a build can overwrite
# `ci/workers` with whatever it likes. The honest boundary is that doing so can
# only harm the host doing it -- a low count deletes its own machine mid-job, a
# high count keeps its own machine billing -- and never another tenant's. The
# gate against a job holding a host forever is GitHub's job timeout and the
# controller's max-host-age, not this file. `beacon_decision()` carries the
# matching refusal for the one cross-cutting case, a timestamp from the future.

[CmdletBinding()]
param(
    # Seconds between publishes. Guest attributes are rate-limited to 10 queries
    # per minute per instance; at the default this is 2/min, which leaves the
    # controller's own reads an order of magnitude of headroom.
    [int] $IntervalSeconds = 30,

    # Bound on the metadata write. Unbounded is how a Windows pool sat for 2h55m
    # with a job queued and every metric holding its last value.
    [int] $TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MetadataRoot = 'http://169.254.169.254/computeMetadata/v1'
$script:GuestNamespace = 'ci'

# --- pure functions ----------------------------------------------------------
#
# Everything below that can be decided without touching the machine is a
# function with no side effects, so `scripts/ci/windows-beacon.Tests.ps1` can
# run it under Pester on ubuntu-latest. This repository's rule is that a gate
# which READS code is not a test: v5.1.4 passed every gate in ci.yml while every
# controller in the fleet died on its first tick.

function Get-BoundedDuration {
    <#
      .SYNOPSIS
        A duration clamped into a range the pool can survive.
      .DESCRIPTION
        Both durations here arrive from instance metadata, which is to say from
        Terraform, which is to say from a consuming repository's variables. Two
        values are load-bearing and neither is obviously wrong on sight:

          interval 0  -- a hot loop. It spins a CPU on a machine whose whole
                         purpose is to run somebody's build, and it exhausts the
                         10-queries-per-minute-per-instance guest-attribute quota
                         in the first second. Every write then fails, the beacon
                         goes stale, and NO host in the pool ever scales in. The
                         symptom is a cost graph, weeks later.
          timeout 0   -- PowerShell documents -TimeoutSec 0 as INDEFINITE. One
                         hung write and the publisher never reaches another,
                         which is the same permanent staleness by a shorter path.

        Clamped rather than rejected. A publisher that refuses to start over a
        bad number leaves the host with no beacon at all, and `keep:` forever is
        a worse answer than a slightly-different interval.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Requested,
        [Parameter(Mandatory = $true)][int] $Minimum,
        [Parameter(Mandatory = $true)][int] $Maximum
    )
    if ($Requested -lt $Minimum) { return $Minimum }
    if ($Requested -gt $Maximum) { return $Maximum }
    return $Requested
}

function Get-BeaconTimestamp {
    <#
      .SYNOPSIS
        RFC3339 UTC, second precision, always with the 'Z' designator.
      .DESCRIPTION
        The controller parses this into epoch seconds and compares it against its
        own clock. A local-time or offset-bearing stamp would be parsed as a
        different instant, and the failure would not be an error -- it would be a
        beacon that reads hours stale or hours in the future, i.e. a host that
        never scales in, or one whose staleness check is defeated.
    #>
    [CmdletBinding()]
    param([DateTime] $Instant = (Get-Date))
    return $Instant.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-BeaconWorkerCount {
    <#
      .SYNOPSIS
        How many job workers are running on this host.
      .DESCRIPTION
        `Runner.Worker` is the process the runner's listener spawns per job; on
        Windows the image is `Runner.Worker.exe`, and Get-Process takes the name
        WITHOUT the extension. This is the same host-local question the Linux
        gate asks with `pgrep -fc Runner.Worker`.

        A failure to enumerate returns $null, NOT 0. Zero is the one value that
        authorises deleting the machine, and it must never be produced by an
        error path.
    #>
    [CmdletBinding()]
    param()
    try {
        $procs = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue)
        return $procs.Count
    } catch {
        return $null
    }
}

function Get-GuestAttributeUri {
    <#
      .SYNOPSIS
        The write endpoint for one guest-attribute key.
      .DESCRIPTION
        Kept a function so the namespace and path shape are asserted by a test
        rather than spelled out at three call sites, one of which will
        eventually be spelled differently.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Key,
        [string] $Namespace = $script:GuestNamespace,
        [string] $Root = $script:MetadataRoot
    )
    return "$Root/instance/guest-attributes/$Namespace/$Key"
}

# --- the one call that touches the network -----------------------------------

function Write-GuestAttribute {
    <#
      .SYNOPSIS
        PUT one guest-attribute value. Returns $true on success.
      .DESCRIPTION
        Bounded explicitly. In PowerShell 6+ an Invoke-* web call with no
        -TimeoutSec waits INDEFINITELY, and -TimeoutSec 0 is documented as
        meaning the same thing; `scripts/ci/bounded-calls.selftest.sh` fails the
        build over either, and this call is exactly why that gate learned to read
        PowerShell.

        Never throws. A publisher that dies on one bad write leaves its host
        undeletable forever, which is a far worse outcome than a gap in the
        series the controller already knows how to interpret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value,
        [int] $TimeoutSeconds = 10
    )
    try {
        Invoke-RestMethod -Method Put `
            -Uri (Get-GuestAttributeUri -Key $Key) `
            -Headers @{ 'Metadata-Flavor' = 'Google' } `
            -Body $Value `
            -TimeoutSec $TimeoutSeconds | Out-Null
        return $true
    } catch {
        Write-EventLogSafe -Message "beacon: write of '$Key' failed: $($_.Exception.Message)"
        return $false
    }
}

function Write-EventLogSafe {
    <#
      .SYNOPSIS
        Log without ever becoming the reason the loop stops.
      .DESCRIPTION
        The event source is registered by the boot script. If it is not there,
        or the log is full, or the write races a rotation, the beacon still has
        to publish -- so every failure here is swallowed deliberately.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Message)
    try {
        Write-EventLog -LogName Application -Source 'ci-beacon' `
            -EventId 1000 -EntryType Warning -Message $Message -ErrorAction Stop
    } catch {
        # Swallowed on purpose -- see the description. Written as a statement
        # rather than a bare comment because an empty catch block is also the
        # shape of an accident, and PSScriptAnalyzer is right to refuse to tell
        # the two apart.
        $null = $_
    }
}

# --- the loop ----------------------------------------------------------------

function Publish-BeaconOnce {
    <#
      .SYNOPSIS
        One publish. Returns $true if the count was published.
      .DESCRIPTION
        `ci/ts` is written only when `ci/workers` was written, and in that order.
        The controller ages the count by the timestamp, so a fresh timestamp over
        a stale count is the one combination that must never exist: it would
        present an old "zero workers" as current evidence and authorise deleting
        a busy machine.

        The stamp is taken BEFORE the count and carried, rather than generated
        at the moment of its own write. Generating it afterwards dates the
        reading later than the instant it describes -- by however long the
        workers write took, which is up to a full -TimeoutSec. That is a count
        presented as fresher than it is, in the one direction that shortens the
        staleness check, and it costs nothing to not do.
    #>
    [CmdletBinding()]
    param([int] $TimeoutSeconds = 10)

    $stamp = Get-BeaconTimestamp
    $count = Get-BeaconWorkerCount
    if ($null -eq $count) {
        Write-EventLogSafe -Message 'beacon: could not enumerate Runner.Worker; publishing nothing'
        return $false
    }

    if (-not (Write-GuestAttribute -Key 'workers' -Value ([string] $count) -TimeoutSeconds $TimeoutSeconds)) {
        return $false
    }
    return (Write-GuestAttribute -Key 'ts' -Value $stamp -TimeoutSeconds $TimeoutSeconds)
}

function Invoke-BeaconLoop {
    <#
      .SYNOPSIS
        Publish forever. Returns only if the process is stopped.
      .DESCRIPTION
        Named Invoke- rather than Start- deliberately: Start- is a state-changing
        verb, and PSScriptAnalyzer would require -WhatIf/-Confirm support on it.
        A service entry point that can be asked not to do the thing it exists to
        do is worse than a naming quibble, and Invoke- is the honest verb anyway
        -- this runs the loop in-process, it does not start one elsewhere.
    #>
    [CmdletBinding()]
    param(
        [int] $IntervalSeconds = 30,
        [int] $TimeoutSeconds = 10
    )
    # The floor is a quota, not a preference. Guest attributes allow 10 queries
    # per minute per instance and each publish spends two of them, so 20s leaves
    # the controller's own reads room inside the same budget. The ceilings stop a
    # typo becoming a beacon nobody ever sees move.
    $interval = Get-BoundedDuration -Requested $IntervalSeconds -Minimum 20 -Maximum 600
    $timeout = Get-BoundedDuration -Requested $TimeoutSeconds -Minimum 1 -Maximum 60

    while ($true) {
        try {
            Publish-BeaconOnce -TimeoutSeconds $timeout | Out-Null
        } catch {
            # Nothing above is supposed to throw. If something does, the loop
            # still has to survive it: this process stopping is the failure that
            # strands a host, and a strand costs more than a missed reading.
            Write-EventLogSafe -Message "beacon: unexpected error: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $interval
    }
}

# Dot-sourceable without side effects, so Pester can import the functions above
# on ubuntu-latest. This is a requirement of the design, not a style choice: it
# is the only way any Windows code in this repository gets RUN by a gate rather
# than read by one.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-BeaconLoop -IntervalSeconds $IntervalSeconds -TimeoutSeconds $TimeoutSeconds
}
