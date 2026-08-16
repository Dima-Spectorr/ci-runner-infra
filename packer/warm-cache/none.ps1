# The default "warm nothing" cache layer for the Windows image -- the exact
# counterpart of none.sh, and it exists for the exact same reason: Packer
# validates a provisioner at PREPARE time and rejects an empty script list
# outright, so "no warming requested" cannot be expressed by passing no script.
# It has to be a real file that does nothing.
#
# A pool that wants warm caches passes its own script instead; nothing about
# this file changes for that, and nothing here is repository-specific, because
# one image serves every Windows pool.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Output '[warm-cache] none requested -- building a toolchain-only image'
