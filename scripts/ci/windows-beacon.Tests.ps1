# Pester tests for the Windows liveness beacon's PURE functions.
#
# WHY THESE EXIST, AND WHAT THEY ARE NOT
#
# This repository's rule is that a gate which READS code is not a test. `v5.1.4`
# passed every gate in `ci.yml` while every controller in the fleet died on its
# first tick, because all of those gates read the controller's text and none of
# them ran it. `scripts/ci/powershell-gate.sh` parses and lints the Windows
# scripts; that is necessary and it is still only reading.
#
# So the decidable half of the Windows path is written as functions with no side
# effects, and this file RUNS them -- on `ubuntu-latest`, because this repository
# must never need the fleet to be healthy in order to fix the fleet.
#
# What this cannot cover is the half that only exists on a Windows host: the
# service, the firewall exemption, Get-Process against a real worker. That half
# is proved by the boot probe on the host, where a failure refuses registration
# instead of serving jobs from a broken boundary.
#
# Dot-sourcing the script is what makes this possible, and it is why it ends
# with `if ($MyInvocation.InvocationName -ne '.') { ... }`. That guard is a
# requirement of the design, not a style preference.

BeforeAll {
    # $PSScriptRoot, not $PSCommandPath. Pester sets $PSScriptRoot to the test
    # file's directory inside BeforeAll; $PSCommandPath is not guaranteed to be
    # the test file there, and a wrong or empty value turns this into a
    # container-level failure that reports itself as every test in the file
    # failing at once, with no path in the message to point at the cause.
    $script:PublisherPath = Join-Path $PSScriptRoot '../../modules/ci-runner-host-pool/scripts/windows-beacon-publisher.ps1'
    if (-not (Test-Path -LiteralPath $script:PublisherPath)) {
        throw "the beacon publisher is not at $script:PublisherPath"
    }

    # Sampled either side of the import, because the question is what the FILE
    # changed, not what the preferences happen to be. Pester sets
    # $ErrorActionPreference to Stop inside a test block on its own account, so
    # asserting the value in an `It` measures Pester and calls it a result.
    $script:EapBefore = $ErrorActionPreference
    $script:StrictBefore = try { $null = $script:NeverAssigned; $false } catch { $true }

    . $script:PublisherPath

    $script:EapAfter = $ErrorActionPreference
    $script:StrictAfter = try { $null = $script:NeverAssigned; $false } catch { $true }
}

Describe 'dot-sourcing is inert' {
    # This is a regression guard with a receipt. The script originally set
    # `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` at
    # script scope, so dot-sourcing it RECONFIGURED its host -- and the host is
    # Pester. Strict mode leaking into the runner's own scope chain aborted the
    # whole container with a stray-`break` error (pester/pester#2669) and marked
    # every test in this file failed before one of them had run.
    #
    # The file's header claims it is dot-sourceable without side effects. Two
    # preference variables are side effects, and nothing but this asserts it.
    It 'leaves the caller error preference exactly as it found it' {
        $script:EapAfter | Should -Be $script:EapBefore
    }

    It 'does not turn strict mode on in the caller' {
        # Probed by reading an unset variable, which throws under
        # Set-StrictMode -Version Latest and yields $null without it.
        $script:StrictAfter | Should -Be $script:StrictBefore
    }
}

Describe 'beacon payload' {
    # The controller parses this into epoch seconds and compares it with its own
    # clock. A local-time or offset-bearing stamp is not an error -- it is a
    # beacon that reads hours stale (a host that never scales in) or hours in
    # the future (a staleness check defeated).
    It 'is RFC3339 UTC with an explicit Z' {
        Get-BeaconTimestamp -Instant ([DateTime]::new(2026, 8, 15, 10, 0, 0, [DateTimeKind]::Utc)) |
        Should -Be '2026-08-15T10:00:00Z'
    }

    It 'converts a non-UTC instant rather than relabelling it' {
        $local = [DateTime]::new(2026, 8, 15, 10, 0, 0, [DateTimeKind]::Local)
        $stamp = Get-BeaconTimestamp -Instant $local
        $stamp | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        [DateTime]::Parse($stamp).ToUniversalTime().Ticks |
        Should -Be $local.ToUniversalTime().Ticks
    }

    # Second precision, no fractional part: the controller parses this with
    # `date -d`, and a stamp it cannot parse becomes ts=0, which
    # `beacon_decision()` reads as `keep:unparseable-timestamp` -- a host that
    # never scales in, on every host in the pool at once.
    It 'carries no sub-second component for the controller to trip over' {
        $t = [DateTime]::new(2026, 8, 15, 10, 0, 0, [DateTimeKind]::Utc).AddMilliseconds(456)
        Get-BeaconTimestamp -Instant $t | Should -Be '2026-08-15T10:00:00Z'
    }

    It 'writes into the ci namespace on the metadata server' {
        Get-GuestAttributeUri -Key 'workers' -Namespace 'ci' -Root 'http://169.254.169.254/computeMetadata/v1' |
        Should -Be 'http://169.254.169.254/computeMetadata/v1/instance/guest-attributes/ci/workers'
    }

    # The three keys `beacon_decision()` reads. Spelled out here because the
    # controller's side of this contract is a bash string literal in another
    # file: nothing else in the build would notice them drifting apart.
    It 'agrees with the controller on every key name' {
        foreach ($k in @('workers', 'ts', 'boot')) {
            Get-GuestAttributeUri -Key $k | Should -BeLike "*/guest-attributes/ci/$k"
        }
    }
}

Describe 'duration clamping' {
    # Both durations reach this script from instance metadata, i.e. from a
    # consuming repository's Terraform variables. The two values that matter are
    # the ones that look harmless.
    It 'leaves a sane value alone' {
        Get-BoundedDuration -Requested 30 -Minimum 20 -Maximum 600 | Should -Be 30
    }

    # Interval 0 is a hot loop: it spins a CPU on a machine meant to be running
    # somebody's build, and it burns the 10-queries-per-minute guest-attribute
    # quota in the first second. Every write then fails, the beacon goes stale,
    # and no host in the pool ever scales in again.
    It 'refuses to turn a zero interval into a hot loop' {
        Get-BoundedDuration -Requested 0 -Minimum 20 -Maximum 600 | Should -Be 20
        Get-BoundedDuration -Requested -5 -Minimum 20 -Maximum 600 | Should -Be 20
    }

    # -TimeoutSec 0 is documented as INDEFINITE. One hung write and the
    # publisher never reaches another, which is the same permanent staleness by
    # a shorter path -- and the exact outage bounded-calls.selftest.sh exists to
    # prevent one layer up.
    It 'refuses to turn a zero timeout into an indefinite wait' {
        Get-BoundedDuration -Requested 0 -Minimum 1 -Maximum 60 | Should -Be 1
    }

    It 'caps a value that would make the beacon look permanently dead' {
        Get-BoundedDuration -Requested 86400 -Minimum 20 -Maximum 600 | Should -Be 600
    }
}

Describe 'worker count' {
    # Zero is the ONE value that authorises deleting the machine. It must be
    # producible only by a successful enumeration that genuinely found nothing --
    # never by an error path. `$null` is the "we do not know" that
    # `Publish-BeaconOnce` turns into publishing nothing at all, which the
    # controller then reads as a stale beacon and keeps.
    # Mocked, and the reason is worth recording: the first version of this test
    # called the real Get-Process and asserted 0, and it failed with "expected
    # 0, but got 1". The machine running the suite is a GitHub Actions runner,
    # and a GitHub Actions runner executing a job has a Runner.Worker process --
    # the very process this function counts. The environment the test runs in
    # was the environment the test was pretending to describe.
    It 'reports a number when nothing is running, not a null' {
        Mock -CommandName Get-Process -MockWith { }
        $count = Get-BeaconWorkerCount
        $count | Should -Be 0
        $count | Should -BeOfType [int]
    }

    # The `@()` wrapper in the function is what makes this true, and without a
    # test it looks like noise somebody could tidy away. A single object has no
    # .Count in Windows PowerShell 5.1 -- which is the PowerShell that runs on
    # the host -- so an unwrapped result would yield $null for exactly one busy
    # worker: the beacon publishes nothing, the reading goes stale, and the one
    # host actually running a job is the one the controller stops trusting.
    It 'reports one, not a scalar with no Count' {
        Mock -CommandName Get-Process -MockWith { [pscustomobject] @{ Id = 1 } }
        Get-BeaconWorkerCount | Should -Be 1
    }

    It 'counts every worker it finds' {
        Mock -CommandName Get-Process -MockWith {
            [pscustomobject] @{ Id = 1 }, [pscustomobject] @{ Id = 2 }
        }
        Get-BeaconWorkerCount | Should -Be 2
    }

    It 'never reports zero from a failure' {
        # Get-Process itself is what can fail -- on a real host, by access denial
        # against a worker running as another slot's user. Exercised rather than
        # argued about.
        Mock -CommandName Get-Process -MockWith { throw 'access denied' }
        # Assigned rather than piped: `$null | Should -Be $null` sends an empty
        # pipeline and asserts nothing at all, which is how this test would
        # pass while the function returned 0 and deleted a busy host.
        $count = Get-BeaconWorkerCount
        $count | Should -BeNullOrEmpty
        0 | Should -Not -BeNullOrEmpty
    }
}
