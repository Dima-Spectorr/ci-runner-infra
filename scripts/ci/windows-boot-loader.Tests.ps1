# Pester tests for the Windows boot LOADER -- the wrapper Terraform renders into
# `windows-startup-script-ps1`, which unpacks the real boot script and runs it.
#
# The companion headers in windows-beacon.Tests.ps1 and windows-startup.Tests.ps1
# apply here too: a gate that READS code is not a test, so what can be decided
# without a Windows host is RUN, on ubuntu-latest.
#
# The loader cannot be dot-sourced the way those two can. It is not a library
# with an entry-point guard -- it is a script whose whole body is the boot path,
# and importing it would try to write C:\Windows\Temp and spawn powershell.exe.
# So its one pure function is lifted out through the parser's AST and run here,
# and the substitution Terraform performs is REPRODUCED rather than described:
# the test gzips the real boot script, renders the loader the way `main.tf`
# does, pulls the payload back out of the rendered text and decodes it. If any
# link in that chain is wrong, every Windows host writes a short or empty script,
# runs it, exits 0 and reports a host that serves nothing (#395).
#
# What this cannot cover is the half that only exists on a Windows host: the ACL
# on C:\Windows\Temp, the child powershell.exe, $LASTEXITCODE reaching the guest
# agent. That half is proved by the boot probe on the host.

BeforeAll {
    # $PSScriptRoot, not $PSCommandPath -- see the note in
    # windows-beacon.Tests.ps1 for what the difference costs.
    $script:LoaderPath = Join-Path $PSScriptRoot '../../modules/ci-runner-host-pool/scripts/windows-boot-loader.ps1'
    $script:StartupPath = Join-Path $PSScriptRoot '../../modules/ci-runner-host-pool/scripts/windows-host-startup.ps1'
    foreach ($p in @($script:LoaderPath, $script:StartupPath)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "no such file: $p" }
    }

    $script:LoaderText = [System.IO.File]::ReadAllText($script:LoaderPath)

    # The sentinel, spelled in halves for the same reason the loader spells it in
    # halves: a literal one in this file would be indistinguishable from the
    # placeholder to anything doing a textual substitution over the tree.
    $script:Sentinel = '__CI_BOOT' + '_SCRIPT_GZ__'

    # Lift Expand-GzipBase64 out through the AST and define it globally, so the
    # `It` blocks can call it by name. Parsing is also the assertion that the
    # loader is syntactically valid PowerShell before anything else is claimed.
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $script:LoaderPath).ProviderPath, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "the loader does not parse: $($parseErrors[0].Message)" }

    $fn = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Expand-GzipBase64'
        }, $true)
    if ($fn.Count -ne 1) { throw "expected exactly one Expand-GzipBase64 in the loader, found $($fn.Count)" }
    . ([scriptblock]::Create(($fn[0].Extent.Text -replace '^function\s+Expand-GzipBase64', 'function global:Expand-GzipBase64')))

    # What Terraform's `base64gzip` does, in .NET. Used to render the loader the
    # way main.tf renders it; the FOREIGN-encoder case is covered separately by
    # the fixture below, because a decoder tested only against its own encoder
    # proves nothing about the bytes Terraform will actually produce.
    function global:ConvertTo-GzipBase64([string] $Text) {
        $plain = New-Object System.IO.MemoryStream(, [System.Text.Encoding]::UTF8.GetBytes($Text))
        $out = New-Object System.IO.MemoryStream
        $gzip = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress, $true)
        try { $plain.CopyTo($gzip) } finally { $gzip.Dispose(); $plain.Dispose() }
        [Convert]::ToBase64String($out.ToArray())
    }
}

Describe 'Expand-GzipBase64' {
    # Produced OUTSIDE .NET, by GNU gzip, and pasted here on purpose: Go's
    # compress/gzip -- which is what `base64gzip` uses -- and GNU gzip write
    # standard members, .NET writes its own, and a decoder round-tripped only
    # against its own encoder would pass while failing on every real host.
    It 'decodes a blob written by a different gzip implementation' {
        $blob = 'H4sIAAAAAAAAA7NRVsjILy5RSMrPL1FQtuMKL8osSdX1Ly0pKC1RULq+8vqc61Ovz1XiSq3ILFEw4AIAXu4yWi8AAAA='
        $expected = "<# host boot #>`nWrite-Output `"שלום`"`nexit 0`n"
        Expand-GzipBase64 $blob | Should -BeExactly $expected
    }

    It 'returns text with no byte-order mark on the front' {
        # A BOM prepended to the boot script's opening `<#` is part of the first
        # token, and PowerShell then fails on a comment block it cannot see.
        $decoded = Expand-GzipBase64 (ConvertTo-GzipBase64 '<# nothing #>')
        [int] $decoded[0] | Should -Be ([int] '<'[0])
    }

    It 'round-trips the real boot script byte for byte' {
        $original = [System.IO.File]::ReadAllText($script:StartupPath)
        Expand-GzipBase64 (ConvertTo-GzipBase64 $original) | Should -BeExactly $original
    }

    It 'throws on text that is not base64 at all' {
        { Expand-GzipBase64 'this is not base64 %%%' } | Should -Throw
    }

    It 'throws on base64 that is not gzip' {
        # The case that matters: a payload that decodes as base64 and is garbage
        # underneath reaches the loader's catch, which refuses the boot. Silently
        # returning empty here is a host that runs nothing and reports success.
        { Expand-GzipBase64 ([Convert]::ToBase64String([byte[]] (1..64))) } | Should -Throw
    }
}

Describe 'the loader as Terraform renders it' {
    BeforeAll {
        $script:Original = [System.IO.File]::ReadAllText($script:StartupPath)
        # `replace(file(...), sentinel, base64gzip(...))` -- every occurrence,
        # exactly as Terraform does it.
        $script:Rendered = $script:LoaderText.Replace($script:Sentinel, (ConvertTo-GzipBase64 $script:Original))
    }

    It 'carries a payload that decodes back to the boot script' {
        # Pulled out of the RENDERED text rather than handed over directly: this
        # is the single-quoted here-string doing its job, and base64's alphabet
        # not being able to close it early.
        $m = [regex]::Match($script:Rendered, "(?ms)^\`$encoded = @'\r?\n(.*?)\r?\n'@")
        $m.Success | Should -BeTrue
        Expand-GzipBase64 ($m.Groups[1].Value.Trim()) | Should -BeExactly $script:Original
    }

    It 'leaves the guard able to fire after substitution' {
        # The guard spells the sentinel in two halves because `replace` hits every
        # occurrence. Were it spelled whole, substitution would rewrite the guard
        # too and it would compare the payload against itself -- a check that can
        # never fire, in the one place where never firing means a host that runs
        # nothing. So: no placeholder survives, and the guard still reassembles it.
        $script:Rendered | Should -Not -BeLike "*$($script:Sentinel)*"
        $reassembled = [scriptblock]::Create(
            [regex]::Match($script:Rendered, "\`$sentinel = ('.*?' \+ '.*?')").Groups[1].Value).Invoke()[0]
        $reassembled | Should -BeExactly $script:Sentinel
    }

    It 'fits inside a GCE metadata value' {
        # 262144 is the hard cap; the margin is the same one host-startup.selftest.sh
        # applies, and the cost of crossing it is an Error 413 at apply time on a
        # plan that read clean.
        $script:Rendered.Length | Should -BeLessThan 245760
    }
}
