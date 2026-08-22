#Requires -Version 5.1
<#
  .SYNOPSIS
    Build one Windows pool's dependency snapshot. THE BUILD PHASE ONLY.

  .DESCRIPTION
    USAGE -- one job, no credential, an artifact out:

      $env:CACHE_PREPARE     = 'npm ci --ignore-scripts'
      $env:CACHE_ARCHIVE_OUT = "$env:RUNNER_TEMP\snap.tar.gz"
      pwsh -File scripts/ci/build-cache-snapshot.ps1

    The archive it writes is then published by the EXISTING Linux publish phase
    -- `publish-cache-snapshot.sh` with `CACHE_ARCHIVE_IN` -- which re-scans it,
    names it, and uploads it under `cache/<pool>/`. Nothing about the credential,
    the content scan, the size bounds, the write-once name or the pointer swap is
    restated here, because none of it is re-derived here: this file is the half
    that cannot run on Linux, and it stops where the half that can begins.

  .NOTES
    WHY THIS FILE EXISTS AT ALL

    A Windows pool has a per-slot cache layer (#150) and, until this, nothing to
    hydrate it from: `C:\ci-cache` held whatever `warm_cache_script` baked into
    the image and nothing any host learned was ever shared. The Linux snapshot
    already solves that, and the obvious move -- run `publish-cache-snapshot.sh`
    under git-bash on `windows-latest` -- does not work, for reasons that are
    controls rather than inconveniences:

      * the install is bounded by a PROCESS GROUP (`set -m`, `kill -- -$pgid`),
        read back from `ps` or `/proc`. Windows has no process groups and no
        `/proc`; the equivalent bound is a JOB OBJECT, which is what this file
        uses.
      * the staging tree is a msys path (`/tmp/...`). Native npm, NuGet and
        Maven on Windows do not read one, so a prepare command pointed at it
        silently caches somewhere else and publishes an empty snapshot -- the
        failure mode that looks exactly like success.

    WHAT THIS FILE DOES NOT DO, ON PURPOSE

    It does not scan for credentials, it does not size-bound the archive, and it
    never touches a bucket. The publish phase does all three on what it receives,
    which it must anyway: an artifact that crossed a job boundary is input. One
    copy of those rules, on the side that already has them.

    THE POOL PREFIX NEEDS NO NEW KEY SCHEME. `host_os` is a property of a POOL
    and a pool name is unique, so a Windows pool is its own `cache/<pool>/` and
    cannot collide with a Linux one by construction. #236 asked for a
    non-colliding key; this is why one did not have to be invented.
#>
[CmdletBinding()]
param()

# NOTHING at script scope changes the caller's preferences, and NOTHING at script
# scope runs: this file is dot-sourced by scripts/ci/build-cache-snapshot.Tests.ps1
# on ubuntu-latest so its pure functions can be RUN rather than read. Same
# requirement, same guard at the bottom, as windows-host-startup.ps1.

# The tool directories a Windows host will accept, by name, in the host's own
# order. `$script:CacheDirs` in windows-host-startup.ps1 is the other copy: a
# name here that is not there is downloaded and discarded, and a name there that
# is not here is never warmed. Same list, same order, so the two diff by eye.
$script:CacheDirs = @('npm', 'yarn', 'pnpm-store', 'go-mod', 'pip', 'uv', 'm2', 'nuget', 'composer')

# An hour, and it is a bound on the INSTALL, not on the job. The Linux side's
# default, deliberately: a repository whose install legitimately takes longer
# raises it in one place for both.
$script:DefaultPrepareTimeoutSeconds = 3600

function Write-BuildLog {
    param([Parameter(Mandatory = $true)][string] $Message)
    # NOT Write-Host, which fails PSAvoidUsingWriteHost -- powershell-gate.sh
    # runs the analyzer at -Severity Error,Warning with no exclusions -- and NOT
    # Write-Output, which would put the line on the success stream and make every
    # logging function return its log lines alongside its value. The same
    # decision, for the same two reasons, as Write-BootLog on the host.
    [Console]::Out.WriteLine("build-cache-snapshot: $Message")
}

function Get-SafeText {
    <#
      .SYNOPSIS
        A string from an untrusted tree, made safe to print. Pure.
      .DESCRIPTION
        The staging tree is populated by third-party install code and a file name
        may hold anything the filesystem accepts. Printed raw into an Actions log,
        a name carrying a newline forges log lines -- and one carrying
        `::add-mask::` or `::error::` writes workflow commands. Non-printables
        become `?`, which keeps the fact that something was there.
    #>
    param([string] $Text)
    if (-not $Text) { return '' }
    return ($Text -replace '[^\x20-\x7e]', '?')
}

function Get-PrepareTimeoutSeconds {
    <#
      .SYNOPSIS
        CACHE_PREPARE_TIMEOUT as a positive whole number of seconds. Pure.
      .DESCRIPTION
        Zero is refused rather than honoured, and that is the same decision the
        Linux side makes for the same reason: `timeout 0` means NO LIMIT AT ALL,
        and `0` is also what an operator reaches for to mean "do not wait". A
        value that disarms the bound while reading as if it tightened it is the
        one value that must not be accepted quietly.
    #>
    param([string] $Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $script:DefaultPrepareTimeoutSeconds }
    $n = 0
    if (-not [int]::TryParse($Raw.Trim(), [ref] $n)) {
        throw "CACHE_PREPARE_TIMEOUT must be a whole number of seconds, not $(Get-SafeText $Raw)"
    }
    if ($n -le 0) {
        throw ('CACHE_PREPARE_TIMEOUT must be a positive whole number of seconds; ' +
            '0 reads as no limit at all, which is the opposite of what setting it means')
    }
    return $n
}

function Get-BuildPhaseRefusal {
    <#
      .SYNOPSIS
        Refuse to run the install in a process that also holds the credential. Pure.
      .DESCRIPTION
        This is the two-job split, enforced in the same place the Linux script
        enforces it, because it is the same split. CACHE_PREPARE is arbitrary
        third-party install code running as this user; a job with `id-token: write`
        exports ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN to every process in it. One
        compromised transitive dependency in a job holding both publishes a snapshot
        of its choosing, and every host in the pool unpacks it as SYSTEM.

        Returns the refusal, or $null when the invocation is build-only.
    #>
    param(
        [string] $Pool,
        [string] $Bucket,
        [string] $IdTokenUrl
    )
    if ($Pool)       { return 'CACHE_POOL is set: this script builds and never publishes. Publish with publish-cache-snapshot.sh in a separate job.' }
    if ($Bucket)     { return 'CACHE_BUCKET is set: this script builds and never publishes. Publish with publish-cache-snapshot.sh in a separate job.' }
    if ($IdTokenUrl) { return 'this job can mint an OIDC token (ACTIONS_ID_TOKEN_REQUEST_URL is set) and is about to run CACHE_PREPARE. Drop id-token: write from the build job -- the split is void without it.' }
    return $null
}

function Test-SnapshotEventAllowed {
    <#
      .SYNOPSIS
        Which GitHub events may build a snapshot. Pure.
      .DESCRIPTION
        Not redundant with the publish job's identity binding, and not redundant
        with the same guard on the Linux side either: this phase is where the
        untrusted code RUNS, so a `pull_request_target` run reaching it produces
        an artifact the publish job would then upload having scanned only what
        the fork chose to leave scannable. Absent means "not on Actions", which
        is a local build and is allowed.
    #>
    param([string] $EventName)
    if ([string]::IsNullOrWhiteSpace($EventName)) { return $true }
    return @('schedule', 'workflow_dispatch', 'push') -contains $EventName
}

function Get-CacheToolEnvironment {
    <#
      .SYNOPSIS
        Every cache variable a Windows host sets for a slot, pointed at $Root. Pure.
      .DESCRIPTION
        The other copy is Get-SlotCacheEnvironment in windows-host-startup.ps1, and
        the two must agree name for name: what the prepare command populates here
        is unpacked into the tree those variables point at there. Both pnpm
        spellings for the reason the host carries both -- pnpm 11 reads
        pnpm_config_store_dir and silently ignores the npm_config_ form.
    #>
    param([Parameter(Mandatory = $true)][string] $Root)
    return [ordered] @{
        npm_config_cache      = "$Root\npm"
        YARN_CACHE_FOLDER     = "$Root\yarn"
        pnpm_config_store_dir = "$Root\pnpm-store"
        npm_config_store_dir  = "$Root\pnpm-store"
        GOMODCACHE            = "$Root\go-mod"
        PIP_CACHE_DIR         = "$Root\pip"
        UV_CACHE_DIR          = "$Root\uv"
        MAVEN_ARGS            = "-Dmaven.repo.local=$Root\m2"
        NUGET_PACKAGES        = "$Root\nuget"
        COMPOSER_CACHE_DIR    = "$Root\composer"
    }
}

function Get-StagedTreeRefusal {
    <#
      .SYNOPSIS
        Why a staged tree must not be packed, or $null. Pure over what it is given.
      .DESCRIPTION
        A REPARSE POINT, and only that, for the same reason the host refuses one
        on arrival (Get-CacheHostileReason): the master is copied into every slot,
        and a junction in it names a path outside the tree that the copy would
        follow and the seal would rewrite. A snapshot carrying one is a snapshot
        every host in the pool would refuse -- so it is refused HERE, once, in a
        run someone is watching, rather than silently on every boot of every host.

        Given entries rather than a path so the walk stays in the caller and this
        stays testable off Windows.
    #>
    param($Entries)
    if (-not $Entries) { return $null }
    foreach ($e in $Entries) {
        if (([int] $e.Attributes -band [int] [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return "the staged tree holds a reparse point at $(Get-SafeText $e.FullName) -- every host would refuse this snapshot on arrival"
        }
    }
    return $null
}

function Get-ArchiveDigest {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# --- the install, inside a job object ----------------------------------------
#
# WHY A JOB OBJECT AND NOT `taskkill /T`
#
# `sh -euc` returning is not evidence the install stopped, and neither is
# Start-Process returning: a lifecycle script that spawns a background service
# keeps running as this user with the staging tree in reach, which would make
# everything downstream a statement about a tree that is still being written.
#
# `taskkill /T` walks the parent-PID chain, and a re-parented process is not on
# it -- exactly the escape `setsid` is on Linux. A job object is a kernel-held
# SET: a process assigned to one cannot leave it, its children join it, and
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE terminates every member when the last
# handle closes. That is the property the process-group argument needs and the
# only Windows primitive that has it.
function Initialize-CiJobObjectType {
    <#
      .SYNOPSIS
        Compile the job-object P/Invoke, once. Windows only, by construction.
      .DESCRIPTION
        In a function and not at script scope so this file stays dot-sourceable
        on a machine with no kernel32 to bind against. The compile happens in the
        build job on a GitHub-hosted Windows runner, where paying it once is
        nothing -- unlike the boot path, where a C# compile is a cost this fleet
        refuses.
    #>
    if ('CiJobObject' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CiJobObject
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private const int ExtendedLimitInformation = 9;
    private const int LimitKillOnJobClose = 0x2000;

    // The two structures are laid out by hand because the managed shape has to
    // match the native one byte for byte on both 32- and 64-bit; getting it
    // wrong does not fail loudly, it sets a limit the kernel reads from the
    // wrong offset.
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformationStruct
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    public static IntPtr CreateKillOnClose()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
        {
            throw new InvalidOperationException("CreateJobObject failed: " + Marshal.GetLastWin32Error());
        }

        ExtendedLimitInformationStruct info = new ExtendedLimitInformationStruct();
        info.BasicLimitInformation.LimitFlags = LimitKillOnJobClose;

        int length = Marshal.SizeOf(typeof(ExtendedLimitInformationStruct));
        IntPtr block = Marshal.AllocHGlobal(length);
        try
        {
            Marshal.StructureToPtr(info, block, false);
            if (!SetInformationJobObject(job, ExtendedLimitInformation, block, (uint)length))
            {
                int err = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new InvalidOperationException("SetInformationJobObject failed: " + err);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(block);
        }

        return job;
    }

    public static void Assign(IntPtr job, IntPtr process)
    {
        if (!AssignProcessToJobObject(job, process))
        {
            throw new InvalidOperationException("AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error());
        }
    }

    public static void Kill(IntPtr job)
    {
        TerminateJobObject(job, 1);
    }

    public static void Close(IntPtr job)
    {
        CloseHandle(job);
    }
}
'@
}

function Invoke-PrepareInJob {
    <#
      .SYNOPSIS
        Run CACHE_PREPARE inside a kill-on-close job object, under a deadline.
      .DESCRIPTION
        Returns a result carrying the exit code, whether the deadline was hit, and
        whether the whole job was terminated. The job is terminated on EVERY path,
        including the one where the command exited cleanly: a clean exit says
        nothing about what it left running, and the reap has to happen before
        anything else reads the tree.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory
    )

    Initialize-CiJobObjectType
    $job = [CiJobObject]::CreateKillOnClose()
    $proc = $null
    $timedOut = $false
    $exit = -1
    try {
        # cmd.exe /d /s /c, because the caller supplies a command LINE with its
        # own flags and quoting -- the same decision, for the same reason, as the
        # Linux side's `sh -euc` rather than an array. /d skips AutoRun, which is
        # a registry value any earlier step could have written.
        $proc = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
            -ArgumentList @('/d', '/s', '/c', $Command) `
            -WorkingDirectory $WorkingDirectory -PassThru -NoNewWindow

        # Assigned AFTER the start and that is a real, narrow race: a process that
        # forks a descendant before it is assigned leaves that descendant outside
        # the job. Windows PowerShell 5.1 cannot start a process suspended without
        # a second P/Invoke of CreateProcess itself, which would replace this
        # whole function; the window is microseconds of process startup, and the
        # digest pin on the archive is the detector for what it cannot bound.
        [CiJobObject]::Assign($job, $proc.Handle)

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
        } else {
            $proc.WaitForExit()
            $exit = $proc.ExitCode
        }
    } finally {
        # Kill THEN close: closing alone would kill on the last handle anyway, but
        # only once the .NET finalizer got round to the process handle, and "the
        # tree is quiet now" has to be true at the point the next line reads it.
        [CiJobObject]::Kill($job)
        [CiJobObject]::Close($job)
        if ($proc) { $proc.Dispose() }
    }

    return [pscustomobject] @{
        ExitCode = $exit
        TimedOut = $timedOut
    }
}

# --- main --------------------------------------------------------------------

function Invoke-Main {
    $refusal = Get-BuildPhaseRefusal -Pool $env:CACHE_POOL -Bucket $env:CACHE_BUCKET `
        -IdTokenUrl $env:ACTIONS_ID_TOKEN_REQUEST_URL
    if ($refusal) { throw "refusing to build: $refusal" }

    if (-not (Test-SnapshotEventAllowed -EventName $env:GITHUB_EVENT_NAME)) {
        throw ("refusing to build a snapshot from a '$(Get-SafeText $env:GITHUB_EVENT_NAME)' run -- " +
            'a snapshot may only be built by schedule, workflow_dispatch or push. Runs triggered by ' +
            'pull_request_target, workflow_run or issue_comment execute untrusted code while asserting the default branch.')
    }

    if (-not $env:CACHE_PREPARE) {
        throw 'CACHE_PREPARE is required (the command that installs dependencies)'
    }
    if (-not $env:CACHE_ARCHIVE_OUT) {
        throw 'CACHE_ARCHIVE_OUT is required (where to write the archive this job hands to the publish job)'
    }

    $timeout = Get-PrepareTimeoutSeconds -Raw $env:CACHE_PREPARE_TIMEOUT

    # tar.exe is bsdtar, in System32 on every supported Windows build and on every
    # windows-latest image. Checked before the install rather than after it: an hour
    # of downloading, then discovering there is nothing to pack it with, costs the
    # whole run.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) {
        throw "tar.exe is not at $tar -- there is nothing here to pack the snapshot with"
    }

    $stage = Join-Path $env:RUNNER_TEMP ('cache-stage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($d in $script:CacheDirs) {
        New-Item -ItemType Directory -Path (Join-Path $stage $d) -Force | Out-Null
    }

    try {
        foreach ($kv in (Get-CacheToolEnvironment -Root $stage).GetEnumerator()) {
            Set-Item -Path "env:$($kv.Key)" -Value $kv.Value
        }

        # Not logged with its value. A prepare command for a private registry
        # routinely carries a token in its arguments, repository VARIABLES are not
        # masked, and this log is readable by anyone who can read the repository.
        Write-BuildLog "installing dependencies into a clean tree (timeout ${timeout}s)"
        $run = Invoke-PrepareInJob -Command $env:CACHE_PREPARE -TimeoutSeconds $timeout -WorkingDirectory (Get-Location).Path

        if ($run.TimedOut) {
            throw ("CACHE_PREPARE did not finish within ${timeout}s and its job object was terminated. " +
                'A half-populated cache is not published; raise CACHE_PREPARE_TIMEOUT if the install legitimately takes longer.')
        }
        if ($run.ExitCode -ne 0) {
            throw "CACHE_PREPARE exited $($run.ExitCode); nothing is packed from a failed install"
        }

        # Read only AFTER the job object was terminated, which the function does on
        # every path. Everything below is a statement about a tree nothing is still
        # writing, and that ordering is the whole reason the reap is not deferred to
        # the end.
        $entries = @(Get-ChildItem -LiteralPath $stage -Recurse -Force -ErrorAction Stop)
        $hostile = Get-StagedTreeRefusal -Entries $entries
        if ($hostile) { throw "refusing to pack: $hostile" }

        $files = @($entries | Where-Object { -not $_.PSIsContainer })
        Write-BuildLog "staged $($files.Count) file(s) across $($script:CacheDirs.Count) tool director(ies)"
        if ($files.Count -eq 0) {
            throw ('the staged tree is empty: CACHE_PREPARE installed nothing, or installed it somewhere ' +
                'other than the cache variables this script exported. An empty snapshot would replace every ' +
                "host's warm master with nothing.")
        }

        $out = $env:CACHE_ARCHIVE_OUT
        $outDir = Split-Path -Parent $out
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }

        # -C the stage and name the directories, so the archive's members are
        # `npm/...` and not `Users/runneradmin/...`. The host unpacks it expecting
        # exactly the top-level names in $script:CacheDirs and drops everything else,
        # so a path prefix here is a snapshot that arrives and hydrates nothing.
        Write-BuildLog "packing $out"
        & $tar -czf $out -C $stage @script:CacheDirs
        if ($LASTEXITCODE -ne 0) {
            throw "tar exited $LASTEXITCODE; no archive was produced"
        }

        $digest = Get-ArchiveDigest -Path $out
        $bytes = (Get-Item -LiteralPath $out).Length
        # PRINTED, not enforced. The publish phase re-digests what it receives and
        # pins it across every later use; this line is what lets an operator compare
        # the two ends of the artifact upload when they disagree.
        Write-BuildLog "archive $bytes byte(s), sha256 $digest"
        Write-BuildLog 'built. The publish job scans this archive and uploads it; this job holds no credential.'
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Dot-sourceable without side effects, so Pester can import the pure functions
# above and RUN them on ubuntu-latest -- the same requirement, the same guard,
# as windows-host-startup.ps1, and asserted by a test rather than trusted.
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Invoke-Main
}
