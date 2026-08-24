<#
  .SYNOPSIS
    Refuse a warm cache holding a file whose other name lies outside the tree.

  .DESCRIPTION
    Step 7b of packer/ci-host-image-win.pkr.hcl refuses reparse points, and for
    a stated reason: `icacls /reset /T` and robocopy both follow one, so a
    junction in the master applies an ACL, and copies content, somewhere nobody
    chose. An NTFS HARDLINK has the same shape and the inline scan cannot see it.

    A file's security descriptor lives on its MFT record, not on the directory
    entry, so every name for a file shares ONE ACL. `warm_cache_script` is
    arbitrary repo-supplied code running elevated in the build VM: it can drop a
    hardlink at C:\ci-cache\npm\x pointing at a file under C:\Windows, and the
    seal that follows rewrites THAT file's descriptor at its real path -- into
    the captured image, and again on every host that boots it.

    A SEPARATE FILE, NOT ANOTHER `inline` LINE, because detecting this needs a
    link count and nothing in the managed API surface of Windows PowerShell 5.1
    exposes one. It takes a P/Invoke, and a P/Invoke does not survive being
    folded into an array of one-line HCL strings.

    COUNTED RATHER THAN FORBIDDEN. The Linux scan spent a release refusing every
    tree with a link count above one and had to take it back out: pnpm's
    content-addressed store hardlinks internally, `cp -al` in a warm script does
    too, and both are safe because every name is inside the tree and the ACL walk
    reaches all of them. So the question asked here is the exact one -- are all of
    this file's names in this tree? -- and not the cheap approximation of it.

    The boot script carries the same rule in Get-CacheHardlinkReason, applied to
    a hydrated snapshot; an image is not the only way content reaches the master.
    scripts/ci/windows-host-startup.selftest.sh asserts the two agree.

    Build time, so unbounded: the cost is paid once per image rather than once
    per host, which is the reason the boot script's copy runs only on the hydrate
    path.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $Root)

$ErrorActionPreference = 'Stop'

# FILE_READ_ATTRIBUTES (0x80) and nothing more -- the probe never needs the
# contents. FILE_FLAG_OPEN_REPARSE_POINT (0x00200000) so it judges the name in
# the tree rather than whatever it points at. Full sharing (7), because a file
# something else holds open is not evidence of anything.
Add-Type -Namespace 'CiCache' -Name 'Fs' -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct BY_HANDLE_FILE_INFORMATION {
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
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode, System.IntPtr lpSecurityAttributes,
    uint dwCreationDisposition, uint dwFlagsAndAttributes, System.IntPtr hTemplateFile);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetFileInformationByHandle(
    Microsoft.Win32.SafeHandles.SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);
'@

# -Force so a hidden name is scanned too: a warm script that wanted to hide one
# would set exactly that attribute. Reparse points are not descended into --
# Get-ChildItem does not without -FollowSymlink, and the inline scan that runs
# before this one has already refused the tree if it holds any.
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop |
        Where-Object { -not $_.PSIsContainer })

$names = @{}
$links = @{}
$order = New-Object System.Collections.ArrayList

foreach ($file in $files) {
    # \\?\ so a path past MAX_PATH is probed rather than counted as a failure: a
    # deep node_modules tree is the ordinary case in a warm cache.
    $handle = [CiCache.Fs]::CreateFileW(('\\?\' + $file.FullName), 0x80, 7, [System.IntPtr]::Zero, 3, 0x00200000, [System.IntPtr]::Zero)
    if ($handle.IsInvalid) {
        $handle.Dispose()
        # FAIL THE BUILD. A file the build VM's own LocalSystem cannot open the
        # attributes of is not a file this scan may report as clean.
        throw "the warm cache holds a file whose attributes could not be read: $($file.FullName)"
    }
    try {
        $info = New-Object 'CiCache.Fs+BY_HANDLE_FILE_INFORMATION'
        if (-not [CiCache.Fs]::GetFileInformationByHandle($handle, [ref] $info)) {
            throw "the warm cache holds a file whose link count could not be read: $($file.FullName)"
        }
        if ($info.NumberOfLinks -le 1) { continue }
        # (volume serial, file index) is the Windows spelling of (device, inode):
        # two names of one file agree on it and no two files do.
        $id = '{0}:{1}:{2}' -f $info.VolumeSerialNumber, $info.FileIndexHigh, $info.FileIndexLow
        if ($names.ContainsKey($id)) { $names[$id] = $names[$id] + 1 } else { $names[$id] = 1 }
        $links[$id] = [int] $info.NumberOfLinks
        [void] $order.Add([pscustomobject] @{ Id = $id; Path = [string] $file.FullName })
    } finally {
        $handle.Dispose()
    }
}

# Re-read IN ORDER rather than enumerating the table: a hashtable's order is
# unspecified, and a refusal that names a different file each run is a refusal
# nobody can act on.
foreach ($entry in $order) {
    if ($names[$entry.Id] -ge $links[$entry.Id]) { continue }
    # The name is repo-supplied text, so it is stripped of control characters and
    # bounded before it reaches the build log -- the same reason the Linux
    # template pipes its refusal through `tr`.
    $safe = $entry.Path -replace '[\x00-\x1f]', ' '
    if ($safe.Length -gt 300) { $safe = $safe.Substring(0, 300) }
    throw ("the warm cache holds an out-of-tree hardlink " +
        "($($names[$entry.Id]) of $($links[$entry.Id]) names are in the tree): $safe")
}

Write-Output "cache hardlink scan: $($files.Count) file(s), $($order.Count) with more than one name, all accounted for"
