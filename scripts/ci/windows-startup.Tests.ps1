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

Describe 'slot naming' {
    # The controller parses `<instance>-s<i>` back to an instance in
    # orphan_decision(). A rename on this side does not fail: it silently stops
    # every Windows registration from ever being reaped, and the agents pile up in
    # GitHub's list pointing at hosts that no longer exist.
    It 'matches the name orphan_decision parses back to an instance' {
        Get-SlotUserName -Index 1 | Should -Be 'ci-s1'
        Get-SlotUserName -Index 12 | Should -Be 'ci-s12'
    }

    It 'gives each slot its own workspace' {
        $one = Get-SlotWorkspacePath -Index 1 -Root '/ci/slots'
        $two = Get-SlotWorkspacePath -Index 2 -Root '/ci/slots'
        $one | Should -Not -Be $two
    }

    # The temp directory is UNDER the workspace, not beside it, so the one ACL
    # applied to the workspace covers it. A sibling directory is one more thing to
    # remember to lock, and the one nobody does.
    It 'puts the private temp inside the slot it belongs to' {
        $ws = Get-SlotWorkspacePath -Index 3 -Root '/ci/slots'
        $tmp = Get-SlotTempPath -Index 3 -Root '/ci/slots'
        $tmp.StartsWith($ws) | Should -BeTrue
        $tmp | Should -Not -Be $ws
    }
}

Describe 'slot password' {
    # Complexity is satisfied BY CONSTRUCTION, not by luck. A password Windows
    # rejects is a slot that never registers, discovered on the fleet rather than
    # here -- so this runs the generator enough times that a one-class-missing bug
    # cannot hide behind a lucky draw.
    It 'always carries all four character classes' {
        foreach ($i in 1..50) {
            $chars = -join (Get-SlotPasswordCharacter -Length 20)
            $chars | Should -Match '[A-Z]'
            $chars | Should -Match '[a-z]'
            $chars | Should -Match '[0-9]'
            $chars | Should -Match '[_\-.~]'
        }
    }

    It 'is the length it was asked for' {
        (Get-SlotPasswordCharacter -Length 40).Length | Should -Be 40
        (Get-SlotPasswordCharacter -Length 16).Length | Should -Be 16
    }

    # This value reaches the service control manager. A quote, a backtick, a
    # percent or an ampersand in it is a quoting bug in the one place where the
    # string is a credential; the homoglyphs are out because a password that
    # cannot be read off a console during an incident wastes the incident.
    It 'contains nothing that quotes, expands or reads ambiguously' {
        foreach ($i in 1..50) {
            -join (Get-SlotPasswordCharacter -Length 40) | Should -Match '^[A-HJ-NP-Za-hj-km-np-z2-9_.~-]+$'
        }
    }

    It 'refuses a length that cannot satisfy the classes' {
        { Get-SlotPasswordCharacter -Length 3 } | Should -Throw
    }

    It 'does not hand out the same password twice' {
        $first = -join (Get-SlotPasswordCharacter -Length 40)
        $second = -join (Get-SlotPasswordCharacter -Length 40)
        $first | Should -Not -Be $second
    }

    # Read-only matters: a SecureString still writable after the fact is one a
    # later bug can extend or empty between generating it and registering the
    # service with it.
    It 'hands phase 5 a sealed SecureString, never a string' {
        $secure = Get-SlotPassword -Length 24
        $secure | Should -BeOfType [System.Security.SecureString]
        $secure.Length | Should -Be 24
        $secure.IsReadOnly() | Should -BeTrue
    }
}

Describe 'phase 1 ordering' {
    # THIS IS THE SECURITY TEST OF PHASE 1, AND IT IS ABOUT ORDER, NOT CONTENT.
    #
    # C:\ci\bin holds ci-beacon.ps1, which the SCM re-executes as LocalSystem on
    # every service restart and every reboot. Phase 0 created that directory with
    # whatever ACL C:\ hands down, which is harmless only while the host has no
    # unprivileged principal on it. Create the slot accounts first and there is a
    # window -- one that survives the reboot -- in which a slot can write the file
    # that comes back as SYSTEM.
    #
    # Nothing about that ordering is visible in the code's shape, and a later
    # refactor that groups "all the account work" together would reverse it
    # without looking wrong. So the order is recorded and asserted.
    BeforeEach {
        $script:Calls = @()
        Mock -CommandName Protect-CiDirectory -MockWith { $script:Calls += "protect:$Path" }
        Mock -CommandName Initialize-SlotAccount -MockWith {
            $script:Calls += "account:$Index"
            @{ Index = $Index; User = "ci-s$Index" }
        }
        Mock -CommandName Grant-SlotLogonRight -MockWith { $script:Calls += 'rights' }
        Mock -CommandName Write-BootLog -MockWith { }
    }

    It 'locks the beacon directory before any slot account exists' {
        Invoke-Phase1SlotSetup -Slots 2 | Out-Null
        $firstAccount = [array]::FindIndex([string[]] $script:Calls, [Predicate[string]] { $args[0] -like 'account:*' })
        $lastProtect = [array]::FindLastIndex([string[]] $script:Calls, [Predicate[string]] { $args[0] -eq 'protect:C:\ci\bin' })
        $lastProtect | Should -BeGreaterOrEqual 0
        $firstAccount | Should -BeGreaterThan $lastProtect
    }

    It 'locks the root and the slot root too, not only the bin' {
        Invoke-Phase1SlotSetup -Slots 1 | Out-Null
        $script:Calls | Should -Contain 'protect:C:\ci'
        $script:Calls | Should -Contain 'protect:C:\ci\slots'
    }

    # One policy write, after every account exists. Per-slot imports mean N full
    # policy writes, any one of which is the one that gets interrupted -- leaving
    # a host with the grant applied and the denies not, which is the state this
    # whole section exists to prevent.
    It 'applies logon rights once, after every account is made' {
        Invoke-Phase1SlotSetup -Slots 3 | Out-Null
        @($script:Calls | Where-Object { $_ -eq 'rights' }).Count | Should -Be 1
        $script:Calls[-1] | Should -Be 'rights'
    }

    It 'provisions exactly the number of slots it was given' {
        Invoke-Phase1SlotSetup -Slots 3 | Out-Null
        @($script:Calls | Where-Object { $_ -like 'account:*' }).Count | Should -Be 3
    }
}

Describe 'security policy rewriting' {
    # The \r? in every anchored pattern below is load-bearing, not noise. The INF
    # this code writes is CRLF on purpose (secedit reads nothing else), and .NET's
    # multiline $ anchors before the \n with the \r still ahead of it, so a bare $
    # never matches a line of the very file format under test.
    # A fresh image has no SeDenyNetworkLogonRight line at all. Skipping an absent
    # privilege is how a deny the code claims to apply ends up not applied, and
    # nothing downstream would report it: secedit imports the file happily and the
    # slots keep the right they were supposed to lose.
    It 'adds a privilege the exported policy never had' {
        $inf = "[Unicode]`r`nUnicode=yes`r`n[Privilege Rights]`r`nSeServiceLogonRight = *S-1-5-80-0`r`n"
        $out = Edit-InfPrivilege -InfText $inf -Privilege 'SeDenyNetworkLogonRight' -Accounts @('*S-1-5-21-1-1-1-1001')
        $out | Should -Match '(?m)^SeDenyNetworkLogonRight = \*S-1-5-21-1-1-1-1001\r?$'
        $out | Should -Match '(?m)^SeServiceLogonRight = \*S-1-5-80-0\r?$'
    }

    # REPLACED, not appended to. Appending leaves the previous membership in
    # place, which for a deny right reads as working and for SeServiceLogonRight
    # quietly widens who may log on as a service.
    It 'replaces an existing line instead of appending to it' {
        $inf = "[Privilege Rights]`r`nSeDenyNetworkLogonRight = *S-1-5-32-546`r`n"
        $out = Edit-InfPrivilege -InfText $inf -Privilege 'SeDenyNetworkLogonRight' -Accounts @('*S-1-5-21-9')
        $out | Should -Match '(?m)^SeDenyNetworkLogonRight = \*S-1-5-21-9\r?$'
        $out | Should -Not -Match 'S-1-5-32-546'
        ([regex]::Matches($out, 'SeDenyNetworkLogonRight')).Count | Should -Be 1
    }

    It 'creates the section when the export has none' {
        $out = Edit-InfPrivilege -InfText "[Unicode]`r`nUnicode=yes" -Privilege 'SeServiceLogonRight' -Accounts @('*S-1-5-21-7')
        $out | Should -Match '(?m)^\[Privilege Rights\]\r?$'
        $out | Should -Match '(?m)^SeServiceLogonRight = \*S-1-5-21-7\r?$'
    }

    It 'writes every account on the one line secedit reads' {
        $out = Edit-InfPrivilege -InfText '[Privilege Rights]' -Privilege 'SeServiceLogonRight' `
            -Accounts @('*S-1-5-21-1', '*S-1-5-21-2', '*S-1-5-21-3')
        $out | Should -Match '(?m)^SeServiceLogonRight = \*S-1-5-21-1,\*S-1-5-21-2,\*S-1-5-21-3\r?$'
    }

    # An INF is a Windows file and secedit is a Windows tool: a rewrite that
    # emitted bare LF would be read back by an OS that expects CRLF, and the
    # failure mode is a policy import that reports success having applied part of
    # the file.
    It 'keeps the line endings secedit expects' {
        $out = Edit-InfPrivilege -InfText "[Privilege Rights]`r`nSeServiceLogonRight = *S-1-5-80-0`r`n" `
            -Privilege 'SeDenyInteractiveLogonRight' -Accounts @('*S-1-5-21-4')
        $out | Should -Match "`r`n"
        ($out -split "`r`n" | Where-Object { $_ -match '^\[Privilege Rights\]$' }).Count | Should -Be 1
    }

    # Nothing outside the one line changes. secedit's INF carries sections this
    # script has no business editing, and a rewrite that dropped [Unicode] gives
    # an import failure whose message is about encoding.
    It 'leaves every other line of the policy alone' {
        $inf = "[Unicode]`r`nUnicode=yes`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`n[Privilege Rights]`r`nSeBatchLogonRight = *S-1-5-32-544`r`n"
        $out = Edit-InfPrivilege -InfText $inf -Privilege 'SeServiceLogonRight' -Accounts @('*S-1-5-21-5')
        $out | Should -Match '(?m)^Unicode=yes\r?$'
        $out | Should -Match '(?m)^signature='
        $out | Should -Match '(?m)^SeBatchLogonRight = \*S-1-5-32-544\r?$'
    }
}
