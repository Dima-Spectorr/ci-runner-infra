<#
  THE WHOLE OF `windows-startup-script-ps1`, AND ALMOST NONE OF THE BOOT.

  This is the Windows counterpart of the `host_startup` wrapper in main.tf. It
  carries `windows-host-startup.ps1` gzipped and base64'd, unpacks it, and runs
  it. Nothing about the boot script itself changes here.

  WHY THERE IS A WRAPPER AT ALL

  A GCE metadata VALUE is capped at 256 KiB. Measured 2026-08-24:

      windows-host-startup.ps1        366,591   140% of the cap
      telemetry.sh + host-startup.sh  278,405   106% of the cap

  The Linux pair had only just crossed it, and what that cost is the reason
  this file exists: `terraform plan` was clean and the APPLY died at create
  time with `Error 413 ... is too large`, inside an unattended nightly build.
  Three repositories then ran a known-broken boot script for a day while every
  merged fix looked shipped.

  Windows was over by far more and had simply never been applied anywhere, so
  it had never said so. Left alone it would have been the first thing to fail
  for whoever turned a Windows pool on, and it would have looked new, because
  "the boot-script metadata bug was fixed" was by then in the history.

  Gzipped and base64'd this is about 149 KiB -- 57% of the cap, with room for
  the script to grow by three quarters again. `terraform fmt` never reflows the
  blob because it is a single line inside a single-quoted here-string.

  IT UNPACKS INTO C:\ci, NOT C:\Windows\Temp.

  Under SYSTEM the process temp directory resolves to C:\Windows\Temp, where unprivileged
  principals may create files -- and on a WARM host's reboot the slot users
  already exist. This is the script SYSTEM is about to execute, so a file
  created there with inherited permissions and locked down a moment later is a
  window in which a slot could replace it. The boot script itself refuses
  C:\Windows\Temp for the same reason when it writes the security-policy
  export. C:\ci is created here with an explicit ACL when it is absent, and is
  already SYSTEM-and-Administrators-only on every reboot after the first.

  Nothing deletes C:\ci between boots, so unlike a path the boot script
  recreates there is no way for this file to be removed out from under the
  process reading it.
#>

$ErrorActionPreference = 'Stop'

# A single-quoted here-string: no PowerShell expansion, no escape processing,
# and base64's alphabet cannot terminate it. The terminator has to sit at the
# start of a line, which is why it is not indented with the rest.
$b64 = @'
${gz}
'@

$root = 'C:\ci'
$dest = Join-Path $root 'ci-host-startup.ps1'

function Write-WrapperLine([string] $Message) {
    # The guest agent copies this script's output into the serial console and
    # the `windows-startup-script-ps1` log, which is where anyone diagnosing a
    # host that registered nothing will actually be looking.
    Write-Output "boot wrapper: $Message"
}

# SYSTEM and Administrators, named by SID because their display names are
# localised -- the same idiom, and the same two principals, as Protect-CiDirectory
# in the boot script. Applied BEFORE anything is written underneath.
function Protect-Path([string] $Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    [System.Security.Principal.SecurityIdentifier]::new($sid),
                    'FullControl',
                    [System.Security.AccessControl.InheritanceFlags]::None,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow))) | Out-Null
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$plain = $null
try {
    $bytes = [Convert]::FromBase64String($b64)
    $compressed = New-Object System.IO.MemoryStream(, $bytes)
    $gzip = New-Object System.IO.Compression.GZipStream(
        $compressed, [System.IO.Compression.CompressionMode]::Decompress)
    $expanded = New-Object System.IO.MemoryStream
    try {
        $gzip.CopyTo($expanded)
    }
    finally {
        $gzip.Dispose(); $compressed.Dispose()
    }
    $plain = [System.Text.Encoding]::UTF8.GetString($expanded.ToArray())
}
catch {
    Write-WrapperLine "the boot script would not decode: $($_.Exception.Message)"
    exit 1
}

# Asserted, not assumed. The catch above covers a blob that failed to decode;
# it says nothing about one that decoded to nothing, which is what a
# mis-rendered template produces and which would otherwise run an empty script,
# exit 0, and report a healthy host serving nothing. Failing loudly is what
# lets the controller's register grace drain the host and rebuild it.
if ([string]::IsNullOrWhiteSpace($plain)) {
    Write-WrapperLine 'the boot script decoded to nothing; this host will not serve'
    exit 1
}

if (-not (Test-Path -LiteralPath $root)) {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Protect-Path $root
}

if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
New-Item -ItemType File -Path $dest -Force | Out-Null
Protect-Path $dest

# UTF8 WITHOUT a BOM. PowerShell reads a BOM-less UTF8 file correctly, and a
# BOM in front of the boot script's leading `<#` would be part of the first
# token.
[System.IO.File]::WriteAllText($dest, $plain, (New-Object System.Text.UTF8Encoding($false)))

# A CHILD process, with the policy stated. Running the text in-process would
# rest on `exit` inside a script block leaving this script -- true, but a
# subtlety to bet a fleet's boot path on -- and on whatever execution policy the
# image happens to carry. $LASTEXITCODE is then the boot script's own exit code,
# which is what google-startup-scripts reports.
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dest
exit $LASTEXITCODE
