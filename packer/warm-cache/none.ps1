# The default "install nothing extra" layer for the Windows image -- the exact
# counterpart of none.sh, and it exists for the exact same reason: Packer
# validates a provisioner at PREPARE time and rejects an empty script list
# outright, so "nothing requested" cannot be expressed by passing no script.
# It has to be a real file that does nothing.
#
# DESPITE THE DIRECTORY NAME, A WINDOWS SCRIPT HERE WARMS NO CACHE. There is no
# host-wide cache tree on a Windows host and no per-slot copy of one -- see the
# warm_cache_script description in ci-host-image-win.pkr.hcl and issue #150. A
# pool that needs more than the baked toolchain passes a script that installs it
# MACHINE-WIDE; nothing about this file changes for that, and nothing here is
# repository-specific, because one image serves every Windows pool.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Output '[warm-cache] nothing requested -- building a toolchain-only image'
