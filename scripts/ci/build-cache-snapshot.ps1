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

# THE SAME FILENAMES `publish-cache-snapshot.sh` REFUSES, AND THE SELF-TEST PINS
# THE TWO LISTS EQUAL.
#
# Duplicated rather than shared for the reason the host's copy of the hostility
# scan is: this script runs under Windows PowerShell on a runner that has no
# POSIX shell in the path it is invoked from, and `find -name` is not reachable
# from here. What makes a duplicate safe is that it cannot drift silently, so
# `has_agreeing_credential_names` in shared-cache.selftest.sh reads both lists
# and refuses if they differ by one name.
#
# WHY IT RUNS HERE AT ALL, when the publish job scans everything again. Between
# the two jobs the archive is an `upload-artifact`, and an artifact is
# downloadable by anyone who can read the repository the moment it is stored --
# a refusal in the publish job comes AFTER that and cannot take it back. So the
# cheap half of the credential scan runs on the side that produced the tree,
# before the archive exists.
#
# It is the cheap half only, and that is stated rather than glossed: this catches
# a credential a tool wrote to its OWN CONFIG, which is the common case (an
# `.npmrc` left behind by `npm login`, a `.netrc`, a service-account JSON). It
# does not see one embedded in cache CONTENT under a hash-named file, which is
# what `CREDENTIAL_PATTERNS` is for and which needs the shell script's regex
# engine. That pass still runs only in the publish job, and closing it on this
# side is tracked as its own issue.
$script:CredentialFileNames = @(
    '.npmrc', '.yarnrc', '.yarnrc.yml', '.netrc', '.pypirc', '.git-credentials',
    'auth.json', 'settings.xml', 'nuget.config', 'credentials',
    'gha-creds-*.json', '*.pem', 'id_rsa*', 'gradle.properties', '.dockercfg'
)

function Get-CredentialFileRefusal {
    <#
      .SYNOPSIS
        Why a staged tree must not be packed because of a file's NAME, or $null.
        Pure over what it is given.
      .DESCRIPTION
        Names only. The name is compared case-insensitively because NTFS is, so
        `NuGet.Config` and `nuget.config` are one file here -- which is the same
        answer the shell side reaches by spelling that one entry `-iname`.

        The refusal names the file and nothing else. A path is not a secret; the
        bytes on the line are, and a CI log is readable by everyone who can see
        the run.

        Given entries rather than a path for the same reason Get-StagedTreeRefusal
        is: the walk stays in the caller, and this stays testable off Windows.
    #>
    param($Entries)
    if (-not $Entries) { return $null }
    foreach ($e in $Entries) {
        if ($e.PSIsContainer) { continue }
        foreach ($pattern in $script:CredentialFileNames) {
            if ($e.Name -like $pattern) {
                return ("the staged tree holds what looks like a credential file at " +
                    "$(Get-SafeText $e.FullName) (matched '$pattern') -- refusing to pack it, " +
                    'because the artifact this job uploads is downloadable before the publish job ever scans it')
            }
        }
    }
    return $null
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

function Resolve-StagedHardLink {
    <#
      .SYNOPSIS
        Give every packed file its own bytes, so the archive has no hard-link
        members. Returns how many names had to be broken apart.
      .DESCRIPTION
        WHY THE ARCHIVE MAY NOT CARRY ONE. `publish-cache-snapshot.sh` builds its
        own archives with GNU tar's `--hard-dereference`, and `archive_is_flat`
        rejects any member that is a hard link -- deliberately, because a host
        unpacking one gets two names over a single inode inside a tree that is
        then copied per slot and sealed read-only, and the seal on one name is
        the seal on the other. That rule is not re-derived for Windows; the
        publish job applies it to whatever arrives.

        So an archive built here with a hard-link member is not a security
        problem, it is a WASTED RUN: the build reports success, uploads its
        artifact, and the publish job refuses it deterministically. Breaking the
        links here is what makes the Windows archive satisfy the same plain-file
        layout the Linux one does. Windows tar.exe is bsdtar, which has no
        `--hard-dereference` to pass, so the flattening happens on the tree.

        Copy, delete, rename -- in that order, and never in place. The copy is a
        second inode with the same bytes; deleting the original name drops the
        link count of the shared inode by one; the rename puts the name back over
        the new bytes. Two names sharing an inode therefore cost one copy, not
        two: after the first is broken the second reports a count of 1 and is
        skipped.

        A link count that could not be READ is a refusal, not a pass. See
        CiJobObject.LinkCount for why -1 is its own answer.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory = $true)] $Files)

    $flattened = 0
    foreach ($f in $Files) {
        $links = [CiJobObject]::LinkCount($f.FullName)
        if ($links -lt 0) {
            throw ("the link count of $(Get-SafeText $f.FullName) could not be read, so this archive " +
                'cannot be shown to be free of hard links -- and the publish job refuses one that is not')
        }
        if ($links -le 1) { continue }
        if (-not $PSCmdlet.ShouldProcess($f.FullName, 'break the hard link by copying')) { continue }
        # A NAME NOTHING IN THE TREE CAN ALREADY OWN. `<name>.ci-flatten` is a
        # path inside the cache, and the cache is written by third-party install
        # code: a package shipping both `foo` and `foo.ci-flatten` had the second
        # one OVERWRITTEN by the copy and then unlinked by the move -- a real
        # cache file deleted, and its stale $Files entry then either fails the
        # link-count read below or is silently dropped from the archive. So the
        # scratch sibling is a fresh GUID and the copy refuses to overwrite:
        # a collision is an error to retry, never a file to replace.
        $spare = $null
        for ($i = 0; $i -lt 8 -and -not $spare; $i++) {
            $candidate = $f.FullName + '.ci-flatten-' + [guid]::NewGuid().ToString('n')
            try {
                [System.IO.File]::Copy($f.FullName, $candidate, $false)
                $spare = $candidate
            } catch [System.IO.IOException] {
                # Only a name that turned out to exist is retried. Anything else
                # -- no space, a denied path -- is the real failure and is raised.
                if (-not ([System.IO.File]::Exists($candidate) -or
                          [System.IO.Directory]::Exists($candidate))) { throw }
            }
        }
        if (-not $spare) {
            throw ("no free scratch name could be found next to $(Get-SafeText $f.FullName), so its " +
                'hard link cannot be broken -- and the publish job refuses an archive that still has one')
        }
        [System.IO.File]::Delete($f.FullName)
        [System.IO.File]::Move($spare, $f.FullName)
        $flattened++
    }
    return $flattened
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
    private static extern IntPtr GetStdHandle(int stdHandle);

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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string fileName, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(IntPtr file, out ByHandleFileInformation info);

    private const int BasicAccountingInformation = 1;
    private const uint CreateSuspended = 0x00000004;
    private const uint WaitTimeout = 0x00000102;
    private const uint StillActive = 259;
    private const int ExtendedLimitInformation = 9;
    private const int LimitKillOnJobClose = 0x2000;
    private const int UseStdHandles = 0x00000100;
    private const int StdInputHandle = -10;
    private const int StdOutputHandle = -11;
    private const int StdErrorHandle = -12;
    private static readonly IntPtr InvalidHandle = new IntPtr(-1);
    private const uint OpenExisting = 3;
    private const uint ShareAll = 7;
    private const uint BackupSemantics = 0x02000000;
    private const uint OpenReparsePoint = 0x00200000;

    // The two structures are laid out by hand because the managed shape has to
    // match the native one byte for byte on both 32- and 64-bit; getting it
    // wrong does not fail loudly, it sets a limit the kernel reads from the
    // wrong offset.
    // GetFileInformationByHandle's shape, and the only field of it anyone here
    // wants: NumberOfLinks. Laid out by hand for the same reason the two job
    // structures below are -- a mismatched offset does not fail, it reads the
    // wrong four bytes and reports a flat file.
    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

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
    private static IntPtr Usable(IntPtr handle)
    {
        return handle == InvalidHandle ? IntPtr.Zero : handle;
    }

    // HOW MANY NAMES THIS FILE HAS, or -1 if that could not be established.
    //
    // .NET has no answer for this and neither does PowerShell 5.1: FileInfo
    // exposes length, attributes and times, and nothing that distinguishes one
    // name from two. NTFS hard links are a property of the FILE, not of either
    // name, so the only way to ask is to open a handle and ask the volume.
    //
    // Access 0 asks for metadata only -- no read, no write -- so a file another
    // process holds open exclusively still answers. FILE_SHARE 7 (read|write|
    // delete) is the matching promise in the other direction. BACKUP_SEMANTICS
    // lets a directory be opened, and OPEN_REPARSE_POINT means a link is asked
    // about ITSELF rather than about what it names -- which matters because the
    // caller's job is to decide about the entry in the staged tree, not about
    // whatever lives at the far end of it.
    //
    // -1 IS NOT ZERO AND IT IS NOT ONE. A file that could not be opened is a
    // file whose link count is unknown, and the caller must treat that as a
    // refusal: "I could not check" and "it is flat" are the same value only in
    // code that has stopped distinguishing them.
    public static int LinkCount(string path)
    {
        IntPtr handle = CreateFile(path, 0, ShareAll, IntPtr.Zero, OpenExisting,
            BackupSemantics | OpenReparsePoint, IntPtr.Zero);
        if (handle == InvalidHandle) { return -1; }
        try
        {
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) { return -1; }
            return (int) info.NumberOfLinks;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    public static ProcessInformation StartSuspendedInJob(IntPtr job, string commandLine, string workingDirectory)
    {
        // HAND THE CHILD THIS PROCESS'S STANDARD HANDLES, EXPLICITLY.
        //
        // A zeroed STARTUPINFO with bInheritHandles=FALSE gives the child no
        // usable standard handles at all, and every byte the prepare command
        // writes goes nowhere: not to the workflow log, not to the job summary,
        // not into a file. A prepare step that fails would fail SILENTLY, and
        // the only evidence left would be an exit code. That is precisely the
        // failure this whole script exists to make visible.
        //
        // STARTF_USESTDHANDLES is what makes CreateProcess read the three
        // fields, and it is only honoured together with bInheritHandles=TRUE --
        // the flag alone is ignored. Inheriting is safe here because this
        // process is a workflow-job PowerShell whose only other open handles are
        // its own; there is no privileged handle to leak into the prepare
        // command, and the command is already running as this same user.
        //
        // A handle that comes back INVALID_HANDLE_VALUE is passed through as
        // IntPtr.Zero rather than as -1: -1 would be inherited as a broken
        // handle the child could still try to write to, while zero reads as "no
        // such stream", which is what it actually is.
        StartupInformation si = new StartupInformation();
        si.Cb = Marshal.SizeOf(typeof(StartupInformation));
        si.Flags = UseStdHandles;
        si.StdInput = Usable(GetStdHandle(StdInputHandle));
        si.StdOutput = Usable(GetStdHandle(StdOutputHandle));
        si.StdError = Usable(GetStdHandle(StdErrorHandle));
        ProcessInformation pi;
        System.Text.StringBuilder line = new System.Text.StringBuilder(commandLine);
        if (!CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, true,
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

# Set only by the drain failure in Invoke-PrepareInJob, read only by
# Remove-StageSafely. Script scope rather than a parameter because the cleanup is
# in a `finally` that the throwing path does not get to pass anything to.
$script:StageNotQuiesced = $false

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

    # THE SCAN BELOW IS ONLY EVIDENCE ABOUT A TREE NOTHING IS WRITING. If the
    # job object did not drain, a member of it may still be alive with this path
    # in reach, and it can create a junction in the window between the scan and
    # the delete -- which 5.1's Remove-Item then follows out of the tree. There
    # is no ordering that closes that window, so the delete is not attempted.
    if ($script:StageNotQuiesced) {
        Write-BuildLog ("left $Path on disk: the prepare command's job object never drained, so a process " +
            'may still be writing this tree and a recursive delete could follow a reparse point planted ' +
            'after the scan. This runner is ephemeral; its teardown reclaims the disk.')
        return
    }

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

    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove-Item -Recurse')) { return }
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
        try {
            # Kill THEN close: closing alone would kill on the last handle anyway,
            # but only once every handle to the job had gone, and "the tree is
            # quiet now" has to be true at the point the next line reads it.
            #
            # INSIDE the try, not before it. TerminateJobObject can report
            # failure, and the wrapper now raises when it does -- which, thrown
            # from in front of the try, skipped both the flag below and the
            # handle-closing finally, and handed Remove-StageSafely the exact
            # state the flag exists to keep it away from.
            [CiJobObject]::Kill($job)
            Wait-JobObjectDrained -Job $job -TimeoutSeconds 60
        } catch {
            # THE ONE STATE THE CLEANUP MUST NOT ACT ON. Everything
            # Remove-StageSafely does is safe because the tree is quiet: it scans
            # for reparse points and then recursively deletes what scanned clean.
            # A drain that did not finish -- or a kill that was never carried
            # out, which is the same statement one step earlier -- is the
            # statement that the tree is NOT quiet: a surviving process can
            # plant a junction in the window
            # between that scan and the delete, and 5.1's Remove-Item follows it.
            # The scan cannot be made atomic, so the delete is given up instead.
            # This runner is ephemeral; the stage goes when the machine does.
            $script:StageNotQuiesced = $true
            throw
        } finally {
            [CiJobObject]::Close($job)
            [CiJobObject]::CloseProcess($handle)
        }
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

        # BEFORE THE COUNT AND BEFORE THE PACK, because what this refuses must
        # never become the artifact. The emptiness throw below is about whether
        # there is a cache worth publishing; this is about whether there is one
        # that may leave the machine at all, and that question comes first.
        $credential = Get-CredentialFileRefusal -Entries $entries
        if ($credential) {
            # Same treatment as a hostile tree: thrown, not deleted here.
            # Remove-StageSafely decides what may be recursively removed.
            throw "refusing to pack: $credential"
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
        # BEFORE TAR, because tar is what would record the link. bsdtar has no
        # --hard-dereference, so the tree is what gets flattened.
        $flattened = Resolve-StagedHardLink -Files $files
        if ($flattened -gt 0) {
            Write-BuildLog ("$flattened staged file(s) shared an inode with another name and were copied " +
                'apart -- the publish job refuses an archive with hard-link members')
        }

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
