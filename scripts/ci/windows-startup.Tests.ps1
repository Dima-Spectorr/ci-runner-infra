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
        # &quot;, not " -- the argument string is XML-escaped now, exactly as the
        # broker's is, and the shim's parser decodes it back to a quote before
        # anything sees it. Asserting the raw quote here would be asserting that
        # the two service builders differ.
        Get-BeaconServiceConfig -ScriptPath 'C:\ci apps\bin\ci-beacon.ps1' |
        Should -Match '-File &quot;C:\\ci apps\\bin\\ci-beacon\.ps1&quot;'
    }

    # The beacon builder used to interpolate its inputs raw while the broker's
    # escaped them. Both take module constants today, so neither was injectable;
    # the divergence itself is the defect, because the next caller reuses
    # whichever builder it finds first.
    It 'escapes its inputs the same way the broker builder does' {
        $xml = Get-BeaconServiceConfig -ScriptPath 'C:\ci\bin\b.ps1' `
            -ServiceName 'x"/><env name="EVIL" value="1'
        $xml | Should -Not -Match '<env name="EVIL"'
    }

    It 'passes the interval through instead of hardcoding one' {
        $script:Xml | Should -Match '-IntervalSeconds 45'
    }

    # The service id is what phase 0 starts by name. It was ALSO what phase 2
    # exempted from the metadata fence by service SID; section 3A deleted the fence, so
    # this string now has two owners rather than three. Two files still have to
    # agree on it and only this test compares them.
    It 'is named the same thing the starter uses' {
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
            # I, O, l, o, 0 and 1 are out; lowercase i is not a homoglyph of
            # anything in this alphabet once uppercase I is already gone.
            -join (Get-SlotPasswordCharacter -Length 40) | Should -Match '^[A-HJ-NP-Za-km-np-z2-9_.~-]+$'
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

# --- phase 3, the job credential broker ---------------------------------------

Describe 'job service account validation' {
    # Instance metadata is a trust boundary on a Windows pool -- section 3A accepts that
    # job code can read it and does not assume nothing can write it. The value
    # lands in service XML and in a LocalSystem service's environment block, so
    # the check is a whitelist of the shape, not a blacklist of characters.
    It 'accepts a service-account address' {
        Test-JobServiceAccountName -Name 'ci-job@example-project.iam.gserviceaccount.com' | Should -BeTrue
    }

    It 'rejects nothing at all' {
        Test-JobServiceAccountName -Name '' | Should -BeFalse
        Test-JobServiceAccountName -Name '   ' | Should -BeFalse
        Test-JobServiceAccountName -Name $null | Should -BeFalse
    }

    # The two shapes that would turn a value into markup or into a second
    # variable. Escaping handles the first anyway; this is the half that stops a
    # WELL-FORMED document from saying something other than what phase 3 meant.
    It 'rejects a value that could close an element or open a line' {
        Test-JobServiceAccountName -Name 'a@b.com"/><env name="X" value="y' | Should -BeFalse
        Test-JobServiceAccountName -Name "a@b.com`nCI_BROKER_PORT=1" | Should -BeFalse
    }

    It 'rejects something that is not an address' {
        Test-JobServiceAccountName -Name 'ci-job' | Should -BeFalse
        Test-JobServiceAccountName -Name 'ci-job@localhost' | Should -BeFalse
    }
}

Describe 'broker port parsing' {
    It 'takes a port metadata actually set' {
        Get-BrokerPort -Value '9099' | Should -Be 9099
    }

    # Falling back is right for the port and would be WRONG for the account: a
    # default port serves the same broker, a default identity is somebody else's.
    It 'falls back when metadata says nothing' {
        Get-BrokerPort -Value '' | Should -Be $script:DefaultBrokerPort
        Get-BrokerPort -Value $null | Should -Be $script:DefaultBrokerPort
    }

    It 'falls back on anything that is not a whole number' {
        Get-BrokerPort -Value '80 80' | Should -Be $script:DefaultBrokerPort
        Get-BrokerPort -Value '-1' | Should -Be $script:DefaultBrokerPort
        Get-BrokerPort -Value '8.0' | Should -Be $script:DefaultBrokerPort
    }

    It 'falls back outside the range a socket would accept' {
        Get-BrokerPort -Value '0' | Should -Be $script:DefaultBrokerPort
        Get-BrokerPort -Value '65536' | Should -Be $script:DefaultBrokerPort
    }

    # This case was a real defect, found by running the function rather than by
    # reading it. All-digits is not the same thing as a number that fits, and
    # `[int64] '99999999999999999999'` THROWS -- which under the entry point's
    # $ErrorActionPreference = 'Stop' is a dead host with a cast error in its log
    # instead of a live one on the default port.
    It 'falls back on a number too large to be one, instead of throwing' {
        { Get-BrokerPort -Value '99999999999999999999' } | Should -Not -Throw
        Get-BrokerPort -Value '99999999999999999999' | Should -Be $script:DefaultBrokerPort
    }
}

Describe 'broker service definition' {
    BeforeAll {
        $script:BrokerXml = Get-BrokerServiceConfig -ScriptPath 'C:\ci\bin\job-metadata-broker.py' `
            -JobServiceAccount 'ci-job@example-project.iam.gserviceaccount.com' -Port 8081
    }

    # Loopback, not 0.0.0.0 as on Linux. Windows gives the slots no network
    # namespace of their own, so binding the VM's address would widen who can
    # reach a credential vendor without narrowing anything for the slots.
    It 'binds loopback and never the host address' {
        $script:BrokerXml | Should -Match '<env name="CI_BROKER_HOST" value="127\.0\.0\.1"/>'
        $script:BrokerXml | Should -Not -Match '0\.0\.0\.0'
    }

    It 'vends the identity it was given, on the port it was given' {
        $script:BrokerXml | Should -Match 'CI_JOB_SERVICE_ACCOUNT" value="ci-job@example-project\.iam\.gserviceaccount\.com"'
        $script:BrokerXml | Should -Match 'CI_BROKER_PORT" value="8081"'
    }

    # Escaping is the half that survives a value the caller's validation did not
    # see -- a future caller, a future metadata key. The angle bracket must come
    # out as text, so the document still has exactly the elements phase 3 wrote.
    It 'escapes a hostile value into text rather than markup' {
        $xml = Get-BrokerServiceConfig -ScriptPath 'C:\ci\bin\b.py' `
            -JobServiceAccount 'x"/><env name="EVIL" value="1' -Port 8081
        $xml | Should -Not -Match '<env name="EVIL"'
        $xml | Should -Match '&quot;|&lt;'
    }

    # A broker that dies stops every job on the host from authenticating. The
    # service manager restarting it is the only thing watching.
    It 'restarts itself rather than staying dead' {
        $script:BrokerXml | Should -Match '<onfailure action="restart"'
        $script:BrokerXml | Should -Match '<startmode>Automatic</startmode>'
    }
}

# --- phase 4, the per-job credential reset hooks -------------------------------

Describe 'credential reset hook body' {
    BeforeAll { $script:Hook = Get-JobHookScript }

    # The hook runs inside the agent's environment. %USERPROFILE% and %APPDATA%
    # are values a job could have changed, so what gets deleted would be the
    # job's decision rather than the host's. The account database is not.
    It 'resolves the profile from the account database, not the environment' {
        $script:Hook | Should -Match 'ProfileList'
        $script:Hook | Should -Match 'ProfileImagePath'
        $code = ($script:Hook -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $code | Should -Not -Match '\$env:USERPROFILE'
        $code | Should -Not -Match '\$env:APPDATA'
    }

    # A resolution that somehow yields C:\Users\Administrator must abort, not
    # recurse. This is the difference between a cleanup and an incident.
    It 'refuses a profile that is not a slot profile' {
        $script:Hook | Should -Match "notmatch '\^ci-s\[0-9\]\+\`$'"
        $script:Hook | Should -Match 'exit 1'
    }

    It 'removes the credential state a previous job could have left' {
        $script:Hook | Should -Match 'AppData\\Roaming\\gcloud'
        $script:Hook | Should -Match 'AppData\\Roaming\\gsutil'
        $script:Hook | Should -Match 'Remove-Item -LiteralPath \$target -Recurse -Force'
    }

    # A hook whose meaning a job's own preference variables could change is not a
    # control. It sets its own.
    It 'sets its own error handling rather than inheriting the agent''s' {
        $script:Hook | Should -Match 'Set-StrictMode -Version Latest'
        $script:Hook | Should -Match "\`$ErrorActionPreference = 'Stop'"
    }
}

Describe 'slot service environment' {
    # THE ASSERTION THIS WHOLE DESCRIBE EXISTS FOR. A pool with no job service
    # account starts no broker, and it is the pool where an inherited or ambient
    # credential is MOST dangerous: nothing on the host is competing with whatever
    # the last workflow left behind, so the leftover is simply what the next job
    # authenticates as. The hooks clear the leftover; the GCE_METADATA_* values
    # close the other door. All five are set here, and the second half is why:
    # unset, GCE_METADATA_* does not withhold credentials, it hands ADC back to
    # 169.254.169.254 and the HOST service account, because section 3A deleted the
    # fence that gives Linux that property for free.
    It 'sets both hooks when there is no broker at all' {
        $block = Get-SlotServiceEnvironment -Index 1 -BrokerEndpoint '' -SlotRoot '/ci/slots'
        $block['ACTIONS_RUNNER_HOOK_JOB_STARTED'] | Should -Be $script:JobHookPath
        $block['ACTIONS_RUNNER_HOOK_JOB_COMPLETED'] | Should -Be $script:JobHookPath
        $block['GCE_METADATA_HOST'] | Should -Be $script:ClosedMetadataEndpoint
        $block['GCE_METADATA_IP'] | Should -Be $script:ClosedMetadataEndpoint
        $block['GCE_METADATA_ROOT'] | Should -Be $script:ClosedMetadataEndpoint
    }

    It 'sets both hooks when there is one' {
        $block = Get-SlotServiceEnvironment -Index 1 -BrokerEndpoint '127.0.0.1:8081' -SlotRoot '/ci/slots'
        $block['ACTIONS_RUNNER_HOOK_JOB_STARTED'] | Should -Be $script:JobHookPath
        $block['ACTIONS_RUNNER_HOOK_JOB_COMPLETED'] | Should -Be $script:JobHookPath
    }

    # All three, or the client libraries disagree about where the metadata server
    # is and one of them reaches the real one -- which answers with the HOST's
    # identity, the exact downgrade the broker exists to prevent.
    It 'points every metadata client at the broker when there is one' {
        $block = Get-SlotServiceEnvironment -Index 2 -BrokerEndpoint '127.0.0.1:8081' -SlotRoot '/ci/slots'
        $block['GCE_METADATA_HOST'] | Should -Be '127.0.0.1:8081'
        $block['GCE_METADATA_IP'] | Should -Be '127.0.0.1:8081'
        $block['GCE_METADATA_ROOT'] | Should -Be '127.0.0.1:8081'
    }

    # Per service, never machine-wide: a machine-wide TMP hands every slot the
    # same one, which is the collision the per-slot directory removes.
    It 'gives each slot its own temp' {
        $one = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots'
        $two = Get-SlotServiceEnvironment -Index 2 -SlotRoot '/ci/slots'
        $one['TMP'] | Should -Be $one['TEMP']
        $one['TMP'] | Should -Not -Be $two['TMP']
    }
}

# The job hook is a FILE locked by the same function that locks the directories,
# and .NET does not let a file ACE carry inheritance flags -- AddAccessRule throws
# "No flags can be set" rather than ignoring them. Under the entry point's
# 'Stop' preference that throw is a host that never finishes booting, so the
# distinction is asserted here rather than discovered there.
Describe 'acl inheritance flags' {
    It 'makes a directory ACE inheritable' {
        $flags = Get-AclInheritanceFlag -IsContainer $true
        $flags.HasFlag([System.Security.AccessControl.InheritanceFlags]::ContainerInherit) | Should -BeTrue
        $flags.HasFlag([System.Security.AccessControl.InheritanceFlags]::ObjectInherit) | Should -BeTrue
    }

    It 'gives a file ACE no flags at all, because .NET rejects any' {
        Get-AclInheritanceFlag -IsContainer $false |
            Should -Be ([System.Security.AccessControl.InheritanceFlags]::None)
    }
}

# THE DISTINCTION THIS SUITE EXISTS FOR MOST
#
# Get-MetadataValue used to swallow every exception into '', which made a flaky
# read indistinguishable from an unset attribute. Two attributes make that
# fatal: an unread ci-job-service-account turns a broker pool into a no-broker
# pool, and an unread ci-image-min-version drops the image floor to 1 and lets a
# host boot from an image with no shim. Neither failure says anything in the log
# that a healthy boot does not also say.
Describe 'metadata read failures' {
    It 'treats a 404 as an attribute that is genuinely not set' {
        Test-MetadataAbsence -StatusCode 404 | Should -BeTrue
    }

    # The case the old handler got wrong, and the one that actually happens: a
    # refused connection, a DNS failure or a read timeout never produces an HTTP
    # status at all.
    It 'refuses to read a transport failure as an unset attribute' {
        Test-MetadataAbsence -StatusCode $null | Should -BeFalse
    }

    It 'refuses to read a server error as an unset attribute' {
        Test-MetadataAbsence -StatusCode 500 | Should -BeFalse
        Test-MetadataAbsence -StatusCode 503 | Should -BeFalse
        Test-MetadataAbsence -StatusCode 403 | Should -BeFalse
    }

    It 'reads the status the same whether it arrives as an enum or a number' {
        Test-MetadataAbsence -StatusCode ([System.Net.HttpStatusCode]::NotFound) | Should -BeTrue
        Test-MetadataAbsence -StatusCode ([System.Net.HttpStatusCode]::InternalServerError) |
            Should -BeFalse
    }
}

# A vended token proves a broker is THERE, not that it is OURS. Every slot on a
# Windows host shares one loopback, nothing reserves the broker's port, and the
# shim's restart delay leaves it free for ten seconds after any crash -- long
# enough for a process a previous job left behind to take it and answer with a
# metadata document of its own choosing.
Describe 'broker listener ownership' {
    It 'accepts the one SID a slot account can never hold' {
        Test-BrokerListenerSid -Sid 'S-1-5-18' | Should -BeTrue
    }

    It 'rejects a local account, which is what a squatter would be' {
        Test-BrokerListenerSid -Sid 'S-1-5-21-1-2-3-1001' | Should -BeFalse
    }

    # Get-PortListenerSid returns '' for no listener, a process that exited
    # between the two lookups, and a CIM call that did not answer. All three mean
    # "not ours", and this is where that reading is made explicit.
    It 'reads an unknown owner as not ours rather than as ours' {
        Test-BrokerListenerSid -Sid '' | Should -BeFalse
        Test-BrokerListenerSid -Sid '   ' | Should -BeFalse
        Test-BrokerListenerSid -Sid $null | Should -BeFalse
    }

    It 'ignores the whitespace a CIM property arrives with' {
        Test-BrokerListenerSid -Sid " S-1-5-18`n" | Should -BeTrue
    }
}

# The reservation is the only thing that makes 127.0.0.1:1 a CLOSED endpoint
# rather than a free one. A netsh call that names the wrong protocol or a range
# of the wrong length protects nothing, and there is no way to notice that on a
# host afterwards: the port is simply available the day somebody wants it.
Describe 'closed metadata endpoint' {
    It 'reserves exactly one TCP port, at the port it was given' {
        $args1 = Get-PortReservationArgument -Port 1
        $args1 | Should -Contain 'protocol=tcp'
        $args1 | Should -Contain 'startport=1'
        $args1 | Should -Contain 'numberofports=1'
        $args1 | Should -Contain 'excludedportrange'
    }

    It 'passes the port through instead of hardcoding one' {
        Get-PortReservationArgument -Port 9999 | Should -Contain 'startport=9999'
    }

    # The constant and the port must name the same socket. They are read in two
    # different phases -- the port by phase 3's reservation, the endpoint by the
    # slot environment block -- so nothing but this compares them.
    It 'reserves the port the slots are actually pointed at' {
        $script:ClosedMetadataEndpoint | Should -Be "127.0.0.1:$script:ClosedMetadataPort"
    }

    # Not the broker's default, and not the real metadata server. Either would
    # turn the fail-closed endpoint back into a working one.
    It 'is not a port anything on this host answers on' {
        $script:ClosedMetadataPort | Should -Not -Be $script:DefaultBrokerPort
        $script:ClosedMetadataEndpoint | Should -Not -Match '169\.254\.169\.254'
    }
}

# --- phase 5 -----------------------------------------------------------------

Describe 'runner config arguments' {
    # The recycle contract and the 90-minute stall this pool replaces both live in
    # this argument list, and every one of them is a silent loss: a runner that
    # self-updates is alive, offline and undispatchable, and on a warm host that
    # is K slots at once rather than one short-lived VM.
    It 'pins the agent version by refusing the self-update' {
        $a = Get-RunnerConfigArgument -Owner 'o' -Repo 'r' -Name 'h-s1' -Labels 'x' -WorkPath '/w'
        $a | Should -Contain '--disableupdate'
    }

    # A rebooted host has an agent of this name already in GitHub's list, and a
    # refused registration is a slot that never comes back.
    It 'replaces the registration a reboot left behind' {
        $a = Get-RunnerConfigArgument -Owner 'o' -Repo 'r' -Name 'h-s1' -Labels 'x' -WorkPath '/w'
        $a | Should -Contain '--replace'
        $a | Should -Contain '--unattended'
        $a | Should -Contain '--runasservice'
    }

    # No account flags, ever. config.cmd takes a logon password as a plaintext
    # argument, in the process table of a host whose local accounts run
    # pull-request code; the logon account is set afterwards through
    # ChangeServiceConfigW instead.
    It 'passes no logon account and no password' {
        $a = Get-RunnerConfigArgument -Owner 'o' -Repo 'r' -Name 'h-s1' -Labels 'x' -WorkPath '/w'
        ($a -join ' ') | Should -Not -Match 'logon'
        ($a -join ' ') | Should -Not -Match 'password'
    }

    It 'builds the repository url from the owner and repo' {
        $a = Get-RunnerConfigArgument -Owner 'acme' -Repo 'infra' -Name 'h-s1' -Labels 'x' -WorkPath '/w'
        $a[[array]::IndexOf($a, '--url') + 1] | Should -Be 'https://github.com/acme/infra'
    }

    # An empty label string must not become a `--labels ''` pair: PowerShell 5.1
    # drops an empty native-command argument, so config.cmd would see `--labels`
    # followed by whatever came next and register with the wrong flag value.
    It 'omits labels entirely when there are none' {
        $a = Get-RunnerConfigArgument -Owner 'o' -Repo 'r' -Name 'h-s1' -Labels '' -WorkPath '/w'
        $a | Should -Not -Contain '--labels'
    }

    It 'omits the runner group when there is none' {
        $a = Get-RunnerConfigArgument -Owner 'o' -Repo 'r' -Name 'h-s1' -Labels 'x' -WorkPath '/w'
        $a | Should -Not -Contain '--runnergroup'
    }

    It 'passes the runner group when there is one' {
        $a = Get-RunnerConfigArgument -Owner 'o' -Repo 'r' -Name 'h-s1' -Labels 'x' `
            -WorkPath '/w' -RunnerGroup 'warm'
        $a[[array]::IndexOf($a, '--runnergroup') + 1] | Should -Be 'warm'
    }
}

Describe 'slot agent name' {
    # orphan_decision() on the controller parses this name back to an instance, so
    # a rename here silently un-reaps every Windows registration: the agent stays
    # in GitHub's list, the host it names is gone, and nothing notices.
    It 'is the instance name and the slot index' {
        Get-SlotAgentName -InstanceName 'ci-w-abcd' -Index 2 | Should -Be 'ci-w-abcd-s2'
    }

    It 'gives two slots on one host two different names' {
        (Get-SlotAgentName -InstanceName 'h' -Index 1) |
            Should -Not -Be (Get-SlotAgentName -InstanceName 'h' -Index 2)
    }
}

Describe 'runner service name' {
    # The marker file lives in a directory the slot account can write, and the
    # name reaches sc.exe. Anything not vouched for comes back '' and the caller
    # denies the boot -- refused, never escaped.
    It 'accepts the name config.cmd records' {
        Get-RunnerServiceName -Marker 'actions.runner.acme-infra.h-s1' |
            Should -Be 'actions.runner.acme-infra.h-s1'
    }

    It 'trims the trailing newline the marker file carries' {
        Get-RunnerServiceName -Marker "actions.runner.a.b`r`n" | Should -Be 'actions.runner.a.b'
    }

    It 'refuses a name a slot could use to reach another service' {
        Get-RunnerServiceName -Marker 'actions.runner.a.b" delete "ci-beacon' | Should -Be ''
    }

    It 'refuses a name that is not a runner service at all' {
        Get-RunnerServiceName -Marker 'ci-beacon' | Should -Be ''
    }

    It 'refuses an empty or missing marker' {
        Get-RunnerServiceName -Marker '' | Should -Be ''
        Get-RunnerServiceName -Marker '   ' | Should -Be ''
    }
}

Describe 'service environment block' {
    It 'renders each entry as NAME=VALUE' {
        $v = Get-ServiceEnvironmentValue -Environment ([ordered] @{ TMP = '/t'; TEMP = '/t' })
        $v | Should -Contain 'TMP=/t'
        $v.Count | Should -Be 2
    }

    # REG_MULTI_SZ is NUL-delimited: an embedded NUL does not corrupt the write,
    # it TRUNCATES the block there, and on this block the entries that would
    # disappear are the per-job credential reset hooks.
    It 'refuses a value carrying a NUL, which would truncate the block' {
        { Get-ServiceEnvironmentValue -Environment ([ordered] @{ TMP = "/t`0X=1" }) } | Should -Throw
    }

    It 'refuses a value carrying a newline' {
        { Get-ServiceEnvironmentValue -Environment ([ordered] @{ TMP = "/t`nX=1" }) } | Should -Throw
    }

    # The block is the last thing between instance metadata and a service that
    # starts as a local account, and section 3A accepts that a Windows host cannot
    # assume its metadata is untampered.
    It 'refuses a name that is not an environment variable name' {
        { Get-ServiceEnvironmentValue -Environment ([ordered] @{ 'TMP X' = '/t' }) } | Should -Throw
    }

    It 'carries the reset hooks straight through from the slot block' {
        $block = Get-SlotServiceEnvironment -Index 1 -BrokerEndpoint '' -SlotRoot '/ci/slots'
        $v = Get-ServiceEnvironmentValue -Environment $block
        ($v -join "`n") | Should -Match 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED='
    }
}
