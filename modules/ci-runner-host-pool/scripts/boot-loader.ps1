<#
  The Windows host's `windows-startup-script-ps1`, and the whole of it. The boot
  script this fetches is `windows-host-startup.ps1`; nothing about it changes
  here.

  WHY THERE IS A LOADER AT ALL

  GCE caps ONE metadata value at 262,144 characters. Measured 2026-08-24:

      windows-host-startup.ps1   366,591   140% of the cap
      telemetry.sh + host-startup.sh   278,405   106% of the cap

  The Linux pair had just crossed it, and the failure is not at plan time and
  not at boot -- it is the APPLY, against the API, `Error 413 ... is too large`.
  No pool in the fleet could build an instance template, which is how three
  repositories lost all CI capacity for a day and a half (#378).

  Windows was over by more and had never been applied anywhere, so it had never
  said so. It is fixed here rather than left to be discovered by whoever first
  turns a Windows pool on, because "the Linux one was fixed" is exactly the note
  that makes the Windows failure look like something new.

  The text is carried in `ci-boot-script-gz`, gzipped and base64'd by
  Terraform's `base64gzip`, and this reads it back. `main.tf` asserts the
  COMPRESSED size against the cap as a plan-time precondition, so the next time
  this runs out it is a plan that says so by name.

  ONE key name for both operating systems, because the pairing that matters --
  and the one this module refuses at plan time -- is `startup-script` versus
  `windows-startup-script-ps1`. A second OS-specific name here would be a second
  chance to get that wrong for no gain.
#>

$ErrorActionPreference = 'Stop'

$src = 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/ci-boot-script-gz'
$dest = Join-Path $env:SystemRoot 'Temp\ci-host-startup.ps1'

function Write-LoaderLine([string] $Message) {
    # The guest agent captures stdout of this script into the serial console and
    # into `windows-startup-script-ps1` log lines, which is where anybody
    # diagnosing a host that never registered will actually be looking.
    Write-Output "boot loader: $Message"
}

# Restrict BEFORE writing, not after. On a WARM host's reboot the slot users
# already exist, and C:\Windows\Temp grants ordinary users the right to create
# files there -- so a file created with inherited permissions and locked down a
# moment later is a window in which a slot could replace the script that SYSTEM
# is about to run. Same reasoning, and the same builtin SIDs, as Set-CiAcl in
# the boot script itself: S-1-5-18 is SYSTEM and S-1-5-32-544 Administrators,
# named by SID because their display names are localised.
function New-LockedFile([string] $Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    New-Item -ItemType File -Path $Path -Force | Out-Null

    $acl = Get-Acl -Path $Path
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
    Set-Acl -Path $Path -AclObject $acl
}

function Expand-GzipBase64([string] $Text) {
    $bytes = [Convert]::FromBase64String($Text)
    $input = New-Object System.IO.MemoryStream(, $bytes)
    $gzip = New-Object System.IO.Compression.GZipStream($input, [System.IO.Compression.CompressionMode]::Decompress)
    $output = New-Object System.IO.MemoryStream
    try {
        $gzip.CopyTo($output)
    }
    finally {
        $gzip.Dispose(); $input.Dispose()
    }
    # UTF8 without a BOM, and written back as such below: PowerShell reads a
    # BOM-less UTF8 file correctly, and a BOM prepended to a `<#` would be part
    # of the first token.
    [System.Text.Encoding]::UTF8.GetString($output.ToArray())
}

# Retried, because this is the one fetch with nothing behind it: the metadata
# server answers microseconds after the guest agent starts, but "up" and
# "answering" are not the same instant, and a single 500 here is a host that
# boots to nothing. Five tries over ~30s, then fail LOUDLY -- the controller's
# register grace is what turns a failed boot into a replaced host, and it can
# only do that if the boot actually failed.
$script = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        $encoded = Invoke-RestMethod -Uri $src -Headers @{ 'Metadata-Flavor' = 'Google' } -TimeoutSec 30
        $script = Expand-GzipBase64 ([string] $encoded)
        break
    }
    catch {
        Write-LoaderLine "attempt $attempt could not read or decode ci-boot-script-gz: $($_.Exception.Message)"
        $script = $null
        Start-Sleep -Seconds ($attempt * 2)
    }
}

# Asserted, not assumed. A `catch` catches a fetch that FAILED; it says nothing
# about a key that exists and is empty, which is what a mis-rendered template
# produces and which would otherwise run an empty script, exit 0, and report a
# healthy host serving nothing.
if ([string]::IsNullOrWhiteSpace($script)) {
    Write-LoaderLine 'ci-boot-script-gz is missing, empty, or would not decode; this host will not serve'
    exit 1
}

New-LockedFile $dest
[System.IO.File]::WriteAllText($dest, $script, (New-Object System.Text.UTF8Encoding($false)))

# A CHILD process, with the policy stated. Running the text in-process would
# mean relying on `exit` inside a script block leaving this script -- true, but
# a subtlety to bet a fleet's boot path on -- and on whatever execution policy
# the image happens to carry. A child with -File and -ExecutionPolicy Bypass has
# one reading, and $LASTEXITCODE is then the boot script's own exit code, which
# is what google-startup-scripts reports.
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dest
exit $LASTEXITCODE
