<#
  The Windows host's `windows-startup-script-ps1`, and the whole of it. The
  script it unpacks is `windows-host-startup.ps1`; nothing about that file
  changes here.

  WHY THERE IS A LOADER AT ALL

  GCE caps ONE metadata value at 262,144 characters. Measured 2026-08-24:

      windows-host-startup.ps1         366,591   140% of the cap
      telemetry.sh + host-startup.sh   278,405   106% of the cap

  The failure is not at plan time and not at boot — it is the APPLY, against
  the API, `Error 413 ... is too large`. No pool could build an instance
  template, which is how three repositories lost all CI capacity for a day and
  a half (#378). Windows was over by more and had never been applied anywhere,
  so it had never said so; "the Linux one was fixed" is exactly the note that
  would have made this look like something new (#395).

  THE BLOB IS INLINE, NOT FETCHED. Terraform substitutes the gzipped, base64'd
  script for the sentinel below before this ever reaches metadata, so the
  loader and its payload are ONE value and a host cannot come up having found
  no script. A second metadata key read at boot was the other option and it is
  worse: it adds a round trip to the boot path and a new way to boot with
  nothing. Same reasoning, same shape, as the Linux arm in `main.tf` and as
  `ci-runner-cache-warmer`.

  `main.tf` asserts the RENDERED size against the cap as a plan-time
  precondition, so the next time this outgrows the value it is a plan that says
  so by name rather than a 413 in a nightly log nobody reads.
#>

$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:SystemRoot 'Temp\ci-host-startup.ps1'

function Write-LoaderLine([string] $Message) {
    # The guest agent captures stdout into the serial console and into the
    # `windows-startup-script-ps1` log lines, which is where anybody diagnosing
    # a host that never registered will actually be looking.
    Write-Output "boot loader: $Message"
}

# Restrict BEFORE writing, not after. On a WARM host's reboot the slot users
# already exist, and C:\Windows\Temp grants ordinary users the right to create
# files there — so a file created with inherited permissions and locked down a
# moment later is a window in which a slot could replace the script SYSTEM is
# about to run. Same reasoning, and the same builtin SIDs, as Set-CiAcl in the
# boot script itself: S-1-5-18 is SYSTEM and S-1-5-32-544 Administrators, named
# by SID because their display names are localised.
function New-LockedFile {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'create, restricted to SYSTEM and Administrators')) { return }
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
    # Not $input: that is one of PowerShell's automatic variables, and assigning
    # to it inside a function is how a pipeline enumerator gets quietly replaced.
    $compressed = New-Object System.IO.MemoryStream(, $bytes)
    $gzip = New-Object System.IO.Compression.GZipStream($compressed, [System.IO.Compression.CompressionMode]::Decompress)
    $plain = New-Object System.IO.MemoryStream
    try {
        $gzip.CopyTo($plain)
    }
    finally {
        $gzip.Dispose(); $compressed.Dispose()
    }
    # UTF8 without a BOM, and written back as such below: PowerShell reads a
    # BOM-less UTF8 file correctly, and a BOM prepended to a `<#` would be part
    # of the first token.
    [System.Text.Encoding]::UTF8.GetString($plain.ToArray())
}

# Terraform replaces the sentinel with `base64gzip(windows-host-startup.ps1)`.
# A single-quoted here-string: nothing in it expands, and base64's alphabet
# cannot close it. If the sentinel is still here the substitution did not
# happen, which is caught below rather than run.
$encoded = @'
__CI_BOOT_SCRIPT_GZ__
'@

# ASSERTED, NOT ASSUMED, and this is the whole reason there is a check at all on
# a value that travels inline. Decoding cannot fail for a truncated GCE value —
# the API refuses an oversized one outright — but it can fail for a template
# that rendered the sentinel, an empty local, or a blob a future edit mangled.
# Every one of those otherwise writes a short or empty script, runs it, exits 0,
# and reports a healthy host that serves nothing.
#
# The sentinel is spelled in two halves HERE ON PURPOSE. Terraform's `replace`
# substitutes every occurrence in the file, so a literal one written out in this
# test would be replaced along with the payload and the test would compare the
# blob against itself — a check that can never fire, in the one place where a
# check that never fires means a host that runs nothing.
$sentinel = '__CI_BOOT' + '_SCRIPT_GZ__'
$script = $null
if ($encoded -match [regex]::Escape($sentinel)) {
    Write-LoaderLine 'the boot script was never substituted into this loader; this host will not serve'
    exit 1
}
try {
    $script = Expand-GzipBase64 ($encoded.Trim())
}
catch {
    Write-LoaderLine "the inlined boot script would not decode: $($_.Exception.Message)"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($script)) {
    Write-LoaderLine 'the inlined boot script decoded to nothing; this host will not serve'
    exit 1
}

New-LockedFile $dest
[System.IO.File]::WriteAllText($dest, $script, (New-Object System.Text.UTF8Encoding($false)))

# A CHILD process, with the policy stated. Running the text in-process would
# mean relying on `exit` inside a script block leaving this script — true, but a
# subtlety to bet a fleet's boot path on — and on whatever execution policy the
# image happens to carry. A child with -File and -ExecutionPolicy Bypass has one
# reading, and $LASTEXITCODE is then the boot script's own exit code, which is
# what google-startup-scripts reports.
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dest
exit $LASTEXITCODE
