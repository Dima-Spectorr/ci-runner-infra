#!/usr/bin/env bash
# The default "warm nothing" cache layer — a toolchain-only image.
#
# It exists because Packer validates a `shell` provisioner at PREPARE time and
# rejects an empty `scripts` list outright ("Either a script file or inline
# script must be specified"), so "no warming requested" cannot be expressed by
# passing no script. It has to be a real file that does nothing.
#
# A consumer that wants warm caches passes its own script via
# _WARM_CACHE_SCRIPT; nothing about this file needs to change for that.
set -eu
echo "[warm-cache] none requested — building a toolchain-only image"
