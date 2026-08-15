# Pester tests for the Windows host boot script's PURE functions.
#
# The companion file is windows-beacon.Tests.ps1 and its header applies here
# too: a gate that READS code is not a test, so the decidable half of the boot
# is written as functions with no side effects and this file RUNS them on
# ubuntu-latest.
#
# What this cannot cover is the half that only exists on a Windows host: the
# service control manager, the shim, the metadata server, local accounts. That
# half is proved by the boot probe on the host, where a failure refuses
# registration instead of serving jobs from a broken boundary.

BeforeAll {
    # $PSScriptRoot, not $PSCommandPath -- see the note in
    # windows-beacon.Tests.ps1 for what the difference costs.
    $script:StartupPath = Join-Path $PSScriptRoot '../../modules/ci-runner-host-pool/scripts/windows-host-startup.ps1'
    if (-not (Test-Path -LiteralPath $script:StartupPath)) {
        throw "the boot script is not at $script:StartupPath"
    }
    # Sampled either side of the import, for the reason spelled out in
    # windows-beacon.Tests.ps1: Pester sets $ErrorActionPreference to Stop inside
    # a test block on its own account, so reading the value in an `It` measures
    # Pester and calls it a result. The question is what the FILE changed.
    $script:EapBefore = $ErrorActionPreference
    $script:StrictBefore = try { $null = $script:NeverAssigned; $false } catch { $true }

    . $script:StartupPath

    $script:EapAfter = $ErrorActionPreference
    $script:StrictAfter = try { $null = $script:NeverAssigned; $false } catch { $true }
}

Describe 'dot-sourcing is inert' {
    # Same guard, same reason, as in windows-beacon.Tests.ps1: a script that
    # sets Set-StrictMode or $ErrorActionPreference at script scope reconfigures
    # whoever dot-sources it, and here that is Pester.
    It 'leaves the caller error preference exactly as it found it' {
        $script:EapAfter | Should -Be $script:EapBefore
    }

    It 'does not turn strict mode on in the caller' {
        $script:StrictAfter | Should -Be $script:StrictBefore
    }

    # The entry-point guard is the only thing standing between a dot-source and
    # a full host boot -- Invoke-Main creates directories, reads the metadata
    # server and installs a service.
    #
    # The assertion is that this test EXISTS to be run. A guard that let
    # Invoke-Main go would have called Deny-Boot on the missing
    # ci-github-owner metadata, thrown inside BeforeAll, and failed the whole
    # container before reaching here. So reaching here is the result, and the
    # two checks below confirm the import did the other half of its job.
    It 'defines its functions instead of running them' {
        Get-Command -Name 'Invoke-Main' -CommandType Function | Should -Not -BeNullOrEmpty
        Get-Command -Name 'Invoke-Phase0Preflight' -CommandType Function | Should -Not -BeNullOrEmpty
    }
}

Describe 'golden image assertion' {
    # The Linux script refuses a bare image with `[ -d /opt/actions-runner ]`.
    # A directory check is too weak on Windows: an image can carry a runner and
    # still predate the service shim, the beacon or the boot probe, and each of
    # those absences fails later and less legibly.
    It 'accepts an image at or above the floor' {
        Test-ImageVersion -Marker '3' -Floor 3 | Should -BeTrue
        Test-ImageVersion -Marker '4' -Floor 3 | Should -BeTrue
    }

    It 'refuses an image below the floor' {
        Test-ImageVersion -Marker '2' -Floor 3 | Should -BeFalse
    }

    It 'tolerates the trailing newline every file writer leaves' {
        Test-ImageVersion -Marker "3`r`n" -Floor 3 | Should -BeTrue
        Test-ImageVersion -Marker '  3  ' -Floor 3 | Should -BeTrue
    }

    # An unreadable marker must be a REFUSAL, not a pass. The tempting bug is to
    # treat "no marker" as an old image and carry on; a host that cannot say
    # what it is is not a host this pool knows how to run.
    It 'refuses a marker it cannot read as a number' {
        Test-ImageVersion -Marker '' -Floor 1 | Should -BeFalse
        Test-ImageVersion -Marker '   ' -Floor 1 | Should -BeFalse
        Test-ImageVersion -Marker 'v3' -Floor 1 | Should -BeFalse
        Test-ImageVersion -Marker '3.1' -Floor 1 | Should -BeFalse
        Test-ImageVersion -Marker '-1' -Floor 1 | Should -BeFalse
    }
}

Describe 'beacon service definition' {
    BeforeAll {
        $script:Xml = Get-BeaconServiceConfig -ScriptPath 'C:\ci\bin\ci-beacon.ps1' -IntervalSeconds 45
    }

    # The publisher stopping is the failure that strands a host:
    # `beacon_decision()` reads a stale beacon as keep, forever. A beacon that
    # dies once and stays dead is a machine that bills until somebody notices,
    # which on the Linux side took 2h55m the one time it happened.
    It 'restarts the beacon rather than leaving the host stranded' {
        $script:Xml | Should -Match '<onfailure action="restart"'
    }

    It 'comes back after a restart the host did not choose' {
        $script:Xml | Should -Match '<startmode>Automatic</startmode>'
    }

    # A profile on the image, or a prompt from anything the script calls, hangs
    # the service at start. The SCM reports that as a start failure, which looks
    # nothing like its cause.
    It 'starts powershell with no profile and no prompts' {
        $script:Xml | Should -Match '-NoProfile'
        $script:Xml | Should -Match '-NonInteractive'
    }

    # C:\ci\bin has no space in it today. Someone moving it is exactly the
    # change that would not be re-tested, and an unquoted path there silently
    # truncates the argument list into a service that starts and does nothing.
    It 'quotes the script path against a directory with a space in it' {
        Get-BeaconServiceConfig -ScriptPath 'C:\ci apps\bin\ci-beacon.ps1' |
        Should -Match '-File "C:\\ci apps\\bin\\ci-beacon\.ps1"'
    }

    It 'passes the interval through instead of hardcoding one' {
        $script:Xml | Should -Match '-IntervalSeconds 45'
    }

    # The service id is what phase 2 exempts from the metadata fence, by service
    # SID, and what phase 0 starts by name. Three files have to agree on this
    # string and only this test compares them.
    It 'is named the same thing the fence and the starter use' {
        $script:Xml | Should -Match '<id>ci-beacon</id>'
    }
}
