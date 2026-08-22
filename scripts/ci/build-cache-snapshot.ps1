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

function Get-PrepareTimeout {
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
        # QUOTED, where the host's copy is not. mvn.cmd expands MAVEN_ARGS onto a
        # command line, so an unquoted path containing a space becomes two
        # arguments and Maven writes its repository somewhere else -- or fails.
        # The host's slot caches live at C:\ci\cache\<idx>\m2, a path this
        # module chooses and which cannot contain a space; a staging root can sit
        # under a user profile, which routinely can.
        MAVEN_ARGS            = "-Dmaven.repo.local=`"$Root\m2`""
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
    private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, out uint returned);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName, System.Text.StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint creationFlags, IntPtr environment, string currentDirectory,
        ref StartupInformation startupInformation, out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private const int BasicAccountingInformation = 1;
    private const uint CreateSuspended = 0x00000004;
    private const uint WaitTimeout = 0x00000102;
    private const uint StillActive = 259;
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
    public struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public int ProcessId;
        public int ThreadId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInformation
    {
        public int Cb;
        public string Reserved;
        public string Desktop;
        public string Title;
        public int X;
        public int Y;
        public int XSize;
        public int YSize;
        public int XCountChars;
        public int YCountChars;
        public int FillAttribute;
        public int Flags;
        public short ShowWindow;
        public short Reserved2Length;
        public IntPtr Reserved2;
        public IntPtr StdInput;
        public IntPtr StdOutput;
        public IntPtr StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicAccountingInformationStruct
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
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

    // START SUSPENDED, ASSIGN, THEN RESUME -- IN THAT ORDER, AND THE ORDER IS
    // THE WHOLE POINT.
    //
    // Start-Process returns a RUNNING process, and AssignProcessToJobObject adds
    // that process to the job without retroactively adopting anything it has
    // already spawned. cmd.exe's first act is to spawn the package manager, so a
    // start-then-assign is a real race whose loser is a descendant OUTSIDE the
    // job: unbounded by the deadline, unreached by kill-on-close, and still
    // writing into the staged tree while it is scanned and packed. The archive
    // digest cannot see it -- it hashes whatever was produced, partial or not.
    //
    // CREATE_SUSPENDED closes the window by construction rather than narrowing
    // it: the process exists, has a pid and a handle, and has not executed one
    // instruction. It is in the job before it is allowed to run, so every
    // descendant it ever has is in the job too.
    //
    // The command LINE is built by the caller, not an argument array, for the
    // same reason the Linux side uses `sh -euc`: CACHE_PREPARE arrives as a
    // command line with its own flags and quoting. `cmd /s /c "<line>"` strips
    // exactly the first and last quote and takes the rest literally, which is
    // what a caller writing a shell command expects -- and is NOT what .NET's
    // argument escaping would have produced for a command containing quotes.
    public static ProcessInformation StartSuspendedInJob(IntPtr job, string commandLine, string workingDirectory)
    {
        StartupInformation si = new StartupInformation();
        si.Cb = Marshal.SizeOf(typeof(StartupInformation));
        ProcessInformation pi;
        System.Text.StringBuilder line = new System.Text.StringBuilder(commandLine);
        if (!CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, false,
                CreateSuspended, IntPtr.Zero, workingDirectory, ref si, out pi))
        {
            throw new InvalidOperationException("CreateProcess failed: " + Marshal.GetLastWin32Error());
        }

        try
        {
            if (!AssignProcessToJobObject(job, pi.Process))
            {
                throw new InvalidOperationException("AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error());
            }
            if (ResumeThread(pi.Thread) == 0xFFFFFFFF)
            {
                throw new InvalidOperationException("ResumeThread failed: " + Marshal.GetLastWin32Error());
            }
        }
        catch
        {
            // It never ran, so there is nothing of it anywhere else -- but the
            // handles are ours, and a suspended process nobody resumes would sit
            // there holding the staging tree open.
            TerminateProcess(pi.Process, 1);
            CloseHandle(pi.Thread);
            CloseHandle(pi.Process);
            throw;
        }

        CloseHandle(pi.Thread);
        pi.Thread = IntPtr.Zero;
        return pi;
    }

    // The process HANDLE, never the pid. It is held for the whole life of the
    // call, which is what keeps Windows from recycling the pid underneath us --
    // a Get-Process by pid after the resume could name a different process.
    public static bool Wait(IntPtr process, int milliseconds)
    {
        return WaitForSingleObject(process, (uint)milliseconds) != WaitTimeout;
    }

    public static int ExitCodeOf(IntPtr process)
    {
        uint code;
        if (!GetExitCodeProcess(process, out code))
        {
            throw new InvalidOperationException("GetExitCodeProcess failed: " + Marshal.GetLastWin32Error());
        }
        if (code == StillActive) { return -1; }
        return unchecked((int)code);
    }

    public static void CloseProcess(IntPtr process)
    {
        if (process != IntPtr.Zero) { CloseHandle(process); }
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
        if (!TerminateJobObject(job, 1))
        {
            throw new InvalidOperationException("TerminateJobObject failed: " + Marshal.GetLastWin32Error());
        }
    }

    // TerminateJobObject only REQUESTS termination: like TerminateProcess it
    // returns before the members have finished dying, and a child's pending I/O
    // can still land in the staged tree after it does. The job HANDLE is
    // signalled by a time limit, not by emptiness, so the only thing that
    // answers "is the tree quiet now" is the live member count.
    public static uint ActiveProcesses(IntPtr job)
    {
        int length = Marshal.SizeOf(typeof(BasicAccountingInformationStruct));
        IntPtr block = Marshal.AllocHGlobal(length);
        try
        {
            uint returned;
            if (!QueryInformationJobObject(job, BasicAccountingInformation, block, (uint)length, out returned))
            {
                throw new InvalidOperationException("QueryInformationJobObject failed: " + Marshal.GetLastWin32Error());
            }

            BasicAccountingInformationStruct info =
                (BasicAccountingInformationStruct)Marshal.PtrToStructure(block, typeof(BasicAccountingInformationStruct));
            return info.ActiveProcesses;
        }
        finally
        {
            Marshal.FreeHGlobal(block);
        }
    }

    public static void Close(IntPtr job)
    {
        CloseHandle(job);
    }
}
'@
}

function Wait-JobObjectDrained {
    <#
      .SYNOPSIS
        Block until the job object holds no live process, or give up loudly.
      .DESCRIPTION
        Kill() asks; this is what waits for the answer. Everything the caller does
        next -- enumerating the tree, refusing a reparse point, packing the archive
        -- is a statement about a tree nothing is still writing, and a member that
        is still dying invalidates every one of them. Failing to drain is fatal
        rather than logged: the alternative is publishing a snapshot that was
        packed while a child was mid-write, which is indistinguishable from a good
        one until a host unpacks it.
    #>
    param(
        [Parameter(Mandatory = $true)] $Job,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $live = [CiJobObject]::ActiveProcesses($Job)
        if ($live -eq 0) { return }
        if ((Get-Date) -ge $deadline) {
            throw ("the prepare command's job object still holds $live process(es) ${TimeoutSeconds}s after it was " +
                'terminated -- something is wedged in kernel or filter-driver I/O, and a tree it may still be ' +
                'writing is not packed')
        }
        Start-Sleep -Milliseconds 100
    }
}

function Remove-StageSafely {
    <#
      .SYNOPSIS
        Delete the staging tree, unless it cannot be shown to be safe to delete.
      .DESCRIPTION
        Windows PowerShell 5.1's `Remove-Item -Recurse` DESCENDS a directory
        junction and deletes what it POINTS AT (PowerShell/PowerShell#621, fixed
        in 6.0 and never backported). The staging tree is written by CACHE_PREPARE
        -- third-party install code -- so "is there a reparse point in here" is
        not a question the cleanup may skip.

        And it may not skip it on the FAILURE paths either, which is the whole
        reason this is a function rather than a flag on the success path. A
        prepare command that times out, exits non-zero, or plants a junction over
        the staging root reaches the cleanup without the pack-time scan ever
        having run -- and those are exactly the runs most likely to have left one.

        The scan must SUCCEED before its result means anything: an entry that
        could not be read is not an entry that came back clean. So a scan error
        leaves the tree too. What is left costs the runner some disk until its own
        teardown reclaims it; the other branch costs whatever the junction named.

        Get-ChildItem -Recurse does not descend a reparse point unless
        -FollowSymlink is given, so the scan itself is safe on the tree it judges.
    #>
    # ConfirmImpact stays Low deliberately. This runs unattended in a workflow
    # job, and $ConfirmPreference is High there, so nothing prompts -- the
    # declaration is what lets -WhatIf report the delete instead of doing it, and
    # the analyzer is right that a function whose name says Remove should support
    # that. Raising the impact would turn every clean-up into a hang.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $rootErrors = @()
    $treeErrors = @()
    $entries = @(Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable rootErrors) +
        @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable treeErrors)
    if ($rootErrors.Count -gt 0 -or $treeErrors.Count -gt 0) {
        Write-BuildLog ("left $Path on disk: $($rootErrors.Count + $treeErrors.Count) entr(ies) could not be " +
            'read, so it cannot be shown to be free of reparse points and a recursive delete might follow one')
        return
    }

    $hostile = Get-StagedTreeRefusal -Entries $entries
    if ($hostile) {
        Write-BuildLog "left $Path on disk: $hostile, and a recursive delete would follow it"
        return
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
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
    $handle = [IntPtr]::Zero
    $timedOut = $false
    $exit = -1
    try {
        # cmd.exe /d /s /c: /d skips AutoRun, which is a registry value any
        # earlier step could have written. The quoting is /s's contract -- see
        # StartSuspendedInJob for why a command LINE and not an argument array.
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $line = '"' + $cmd + '" /d /s /c "' + $Command + '"'
        $started = [CiJobObject]::StartSuspendedInJob($job, $line, $WorkingDirectory)
        $handle = $started.Process

        if (-not [CiJobObject]::Wait($handle, $TimeoutSeconds * 1000)) {
            $timedOut = $true
        } else {
            $exit = [CiJobObject]::ExitCodeOf($handle)
        }
    } finally {
        # Kill THEN close: closing alone would kill on the last handle anyway, but
        # only once every handle to the job had gone, and "the tree is quiet now"
        # has to be true at the point the next line reads it.
        [CiJobObject]::Kill($job)
        Wait-JobObjectDrained -Job $job -TimeoutSeconds 60
        [CiJobObject]::Close($job)
        [CiJobObject]::CloseProcess($handle)
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

    $timeout = Get-PrepareTimeout -Raw $env:CACHE_PREPARE_TIMEOUT

    # tar.exe is bsdtar, in System32 on every supported Windows build and on every
    # windows-latest image. Checked before the install rather than after it: an hour
    # of downloading, then discovering there is nothing to pack it with, costs the
    # whole run.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) {
        throw "tar.exe is not at $tar -- there is nothing here to pack the snapshot with"
    }

    # RUNNER_TEMP on Actions; the system temp directory otherwise. A local run is
    # explicitly allowed -- Test-SnapshotEventAllowed accepts an empty event name,
    # and there is a test for it -- so a Join-Path that throws on the one variable
    # only Actions sets would make that allowance a lie.
    $tempRoot = $env:RUNNER_TEMP
    if (-not $tempRoot) { $tempRoot = [System.IO.Path]::GetTempPath() }
    $stage = Join-Path $tempRoot ('cache-stage-' + [guid]::NewGuid().ToString('N'))
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
        # The ROOT is first, and it is not decoration: Get-ChildItem returns the
        # descendants of whatever $stage resolves to and never the starting item,
        # so a prepare command that removes $stage and puts a junction in its place
        # produces a tree that scans clean while `tar -C $stage` packs from
        # somewhere else entirely. The host-side scan includes its root for the
        # same reason.
        $entries = @(Get-Item -LiteralPath $stage -Force -ErrorAction Stop) +
            @(Get-ChildItem -LiteralPath $stage -Recurse -Force -ErrorAction Stop)
        $hostile = Get-StagedTreeRefusal -Entries $entries
        if ($hostile) {
            # Not deleted here, and not deleted by the cleanup either:
            # Remove-StageSafely re-runs this same scan and leaves what it refuses.
            throw "refusing to pack: $hostile"
        }

        # ONLY WHAT TAR WILL PACK COUNTS. The tar line names the cache
        # directories, so a file the prepare command drops anywhere else under the
        # staging root -- a log, a marker, a lockfile -- is silently absent from
        # the archive. Counted as evidence of a warm cache it turns "every cache
        # directory is empty" into a published snapshot of nothing but empty
        # directories, which the Linux publish phase accepts and every host in the
        # pool then unpacks OVER its warm master. This check is the only thing
        # between an install that populated nothing and that outcome, so it counts
        # the same set of files tar does.
        $prefix = $stage.TrimEnd('\') + '\'
        $files = @($entries | Where-Object {
                -not $_.PSIsContainer -and
                $_.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                ($script:CacheDirs -contains $_.FullName.Substring($prefix.Length).Split('\')[0])
            })
        # Logged, not refused: tar drops them, so they change nothing about what is
        # published -- but a prepare command whose output lands outside every cache
        # directory is the shape of a misconfigured CACHE_PREPARE, and the
        # emptiness throw below says nothing about where the files went.
        $strays = @($entries | Where-Object { -not $_.PSIsContainer }).Count - $files.Count
        if ($strays -gt 0) {
            Write-BuildLog ("$strays file(s) under the staging root are outside every cache directory " +
                'and are NOT packed -- check that CACHE_PREPARE honours the cache variables')
        }
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
        & $tar -czf $out -C $stage $script:CacheDirs
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
        Remove-StageSafely -Path $stage
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
