# Pester tests for the Windows snapshot BUILD phase's pure functions.
#
# Same argument as windows-startup.Tests.ps1: a gate that READS code is not a
# test, so the decidable half of this script is written as functions with no side
# effects and this file RUNS them on ubuntu-latest. What cannot be covered here
# is the half that only exists on Windows -- the job object, cmd.exe, tar.exe --
# and that half is proved by the build job itself, where a failure fails the run
# instead of publishing a snapshot nobody checked.

BeforeAll {
    $script:BuildPath = Join-Path $PSScriptRoot 'build-cache-snapshot.ps1'
    if (-not (Test-Path -LiteralPath $script:BuildPath)) {
        throw "the build script is not at $script:BuildPath"
    }

    # Sampled either side of the import: Pester sets $ErrorActionPreference to
    # Stop inside a test block on its own account, so reading it in an `It`
    # measures Pester. The question is what the FILE changed.
    $script:EapBefore = $ErrorActionPreference
    $script:StrictBefore = try { $null = $script:NeverAssigned; $false } catch { $true }

    . $script:BuildPath

    $script:EapAfter = $ErrorActionPreference
    $script:StrictAfter = try { $null = $script:NeverAssigned; $false } catch { $true }
}

Describe 'dot-sourcing is inert' {
    It 'leaves the caller error preference exactly as it found it' {
        $script:EapAfter | Should -Be $script:EapBefore
    }

    It 'does not turn strict mode on in the caller' {
        $script:StrictAfter | Should -Be $script:StrictBefore
    }

    # Reaching here is itself the result: an unguarded main would have thrown on
    # the missing CACHE_PREPARE inside BeforeAll and failed the whole container.
    It 'defines its functions instead of running them' {
        Get-Command -Name 'Invoke-Main' -CommandType Function -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
        Get-Command -Name 'Invoke-PrepareInJob' -CommandType Function -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    # The P/Invoke is in a function for this reason: the type binds kernel32, and
    # this container is Linux. A script-scope Add-Type would compile on import.
    It 'does not compile the job-object type on import' {
        ('CiJobObject' -as [type]) | Should -BeNullOrEmpty
    }
}

Describe 'the bound on the install' {
    It 'defaults to an hour when nothing is set' {
        Get-PrepareTimeout -Raw '' | Should -Be 3600
    }

    It 'takes a positive whole number of seconds' {
        Get-PrepareTimeout -Raw '900' | Should -Be 900
    }

    It 'ignores surrounding whitespace rather than refusing a YAML scalar' {
        Get-PrepareTimeout -Raw "  900 `n" | Should -Be 900
    }

    # The one value that must not be honoured: `timeout 0` is no limit at all,
    # and 0 is also what an operator reaches for to mean "do not wait".
    It 'refuses zero instead of reading it as no limit' {
        { Get-PrepareTimeout -Raw '0' } | Should -Throw '*positive*'
    }

    It 'refuses a negative value' {
        { Get-PrepareTimeout -Raw '-1' } | Should -Throw '*positive*'
    }

    It 'refuses something that is not a number at all' {
        { Get-PrepareTimeout -Raw '10m' } | Should -Throw '*whole number*'
    }
}

Describe 'the two-job split, enforced' {
    It 'runs the install when the job holds no publishing input' {
        Get-BuildPhaseRefusal -Pool '' -Bucket '' -IdTokenUrl '' | Should -BeNullOrEmpty
    }

    It 'refuses when the pool is named here' {
        Get-BuildPhaseRefusal -Pool 'p' -Bucket '' -IdTokenUrl '' | Should -Match 'CACHE_POOL'
    }

    It 'refuses when the bucket is named here' {
        Get-BuildPhaseRefusal -Pool '' -Bucket 'b' -IdTokenUrl '' | Should -Match 'CACHE_BUCKET'
    }

    # The one that matters most: the pool and bucket are only inputs, but an
    # OIDC token in this job puts the publishing credential inside the blast
    # radius of a postinstall script.
    It 'refuses when this job can mint an OIDC token' {
        Get-BuildPhaseRefusal -Pool '' -Bucket '' -IdTokenUrl 'https://x/token' |
            Should -Match 'id-token'
    }
}

Describe 'which events may build a snapshot' {
    It 'allows the three the workflow triggers on' {
        Test-SnapshotEventAllowed -EventName 'schedule' | Should -BeTrue
        Test-SnapshotEventAllowed -EventName 'workflow_dispatch' | Should -BeTrue
        Test-SnapshotEventAllowed -EventName 'push' | Should -BeTrue
    }

    It 'allows a local build, where there is no event at all' {
        Test-SnapshotEventAllowed -EventName '' | Should -BeTrue
    }

    # The three that execute untrusted code while asserting the default branch.
    It 'refuses the events that run fork-authored code' {
        Test-SnapshotEventAllowed -EventName 'pull_request_target' | Should -BeFalse
        Test-SnapshotEventAllowed -EventName 'workflow_run' | Should -BeFalse
        Test-SnapshotEventAllowed -EventName 'issue_comment' | Should -BeFalse
    }
}

Describe 'the cache variables the install runs under' {
    It 'points every one of them inside the staging tree' {
        $vars = Get-CacheToolEnvironment -Root 'C:\stage'
        foreach ($v in $vars.Values) {
            $v | Should -Match ([regex]::Escape('C:\stage'))
        }
    }

    # pnpm 11 reads pnpm_config_store_dir and silently ignores the npm_config_
    # form it honoured before. A single-spelling guess stores nothing where we
    # asked and publishes a snapshot missing a whole tool.
    It 'carries both pnpm spellings, at the same path' {
        $vars = Get-CacheToolEnvironment -Root 'C:\stage'
        $vars['pnpm_config_store_dir'] | Should -Be 'C:\stage\pnpm-store'
        $vars['npm_config_store_dir'] | Should -Be 'C:\stage\pnpm-store'
    }

    # Maven takes a -D on the command line rather than a variable of its own,
    # and mvn.cmd re-splits MAVEN_ARGS on whitespace: the staging root is under
    # RUNNER_TEMP on Actions but under a user profile on a local build, and
    # 'C:\Users\Some One\AppData\...' unquoted is two arguments and a Maven
    # repository somewhere nobody packs.
    It 'passes the maven repository as an argument, not as a path' {
        (Get-CacheToolEnvironment -Root 'C:\stage')['MAVEN_ARGS'] |
            Should -Be '-Dmaven.repo.local="C:\stage\m2"'
    }

    It 'quotes a staging root containing a space' {
        (Get-CacheToolEnvironment -Root 'C:\Users\Some One\stage')['MAVEN_ARGS'] |
            Should -Be '-Dmaven.repo.local="C:\Users\Some One\stage\m2"'
    }

    # The list here and the host's $script:CacheDirs are two copies of one fact:
    # a name in the archive the host does not know is downloaded and discarded.
    It 'names every tool directory the Windows host unpacks' {
        $hostScript = Join-Path $PSScriptRoot '../../modules/ci-runner-host-pool/scripts/windows-host-startup.ps1'
        $line = (Get-Content -LiteralPath $hostScript |
            Where-Object { $_ -match '^\$script:CacheDirs\s*=' })
        $line | Should -Not -BeNullOrEmpty
        foreach ($d in $script:CacheDirs) {
            $line | Should -Match ("'" + [regex]::Escape($d) + "'")
        }
    }
}

Describe 'a staged tree that must not be packed' {
    It 'packs a tree of ordinary files' {
        $entries = @(
            [pscustomobject] @{ FullName = 'C:\stage\npm\a'; Attributes = [System.IO.FileAttributes]::Normal }
            [pscustomobject] @{ FullName = 'C:\stage\npm'; Attributes = [System.IO.FileAttributes]::Directory }
        )
        Get-StagedTreeRefusal -Entries $entries | Should -BeNullOrEmpty
    }

    # Refused here, once, in a run someone is watching -- rather than silently on
    # every boot of every host, which is where the same content would be refused.
    It 'refuses a reparse point, naming it' {
        $entries = @(
            [pscustomobject] @{ FullName = 'C:\stage\npm\a'; Attributes = [System.IO.FileAttributes]::Normal }
            [pscustomobject] @{
                FullName   = 'C:\stage\npm\link'
                Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint
            }
        )
        Get-StagedTreeRefusal -Entries $entries | Should -Match 'reparse point'
        Get-StagedTreeRefusal -Entries $entries | Should -Match 'link'
    }

    It 'has nothing to say about an empty tree' {
        Get-StagedTreeRefusal -Entries @() | Should -BeNullOrEmpty
    }
}

Describe 'a name from the staged tree on its way into the log' {
    # A file name is written by third-party install code. Printed raw into an
    # Actions log, one carrying a newline forges log lines, and one carrying
    # `::add-mask::` writes workflow commands.
    It 'folds a newline rather than forging a log line' {
        Get-SafeText -Text "a`n::error::x" | Should -Be 'a?::error::x'
    }

    It 'keeps ordinary text exactly as it was' {
        Get-SafeText -Text 'C:\stage\npm\lodash' | Should -Be 'C:\stage\npm\lodash'
    }

    It 'is empty for nothing' {
        Get-SafeText -Text '' | Should -Be ''
    }
}
