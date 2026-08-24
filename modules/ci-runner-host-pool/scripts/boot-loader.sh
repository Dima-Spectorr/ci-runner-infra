#!/usr/bin/env bash
#
# The Linux host's `startup-script`, and the whole of it. The boot script this
# fetches is the one in `host-startup.sh`; nothing about it changes here.
#
# WHY THERE IS A LOADER AT ALL
#
# GCE caps ONE metadata value at 262,144 characters. The rendered Linux boot
# script -- `telemetry.sh` plus `host-startup.sh` -- passed it: 278,405
# characters on 2026-08-24. The failure is not at plan time and not at boot; it
# is the APPLY, against the API:
#
#   Error 413: Value for field 'resource.properties.metadata.items[27].value'
#   is too large: maximum size 262144 character(s); actual size 277764.
#
# So NO pool in the fleet could build an instance template, which is how three
# repositories ended up with zero CI capacity for a day and a half (#378): their
# running hosts were pinned to a template predating the fix they needed, and the
# apply that would have replaced it could not complete.
#
# The text is therefore carried in `ci-boot-script-gz`, gzipped and base64'd by
# Terraform's `base64gzip`, and this reads it back. 278,405 characters become
# 128,344 -- 49% of the cap, against 106% before -- and the boot script stays
# ONE reviewed, unit-tested file rather than being split across metadata keys
# whose seams would have to be reassembled correctly at 04:00 in the dark.
#
# The cap is still there. `main.tf` asserts the COMPRESSED size against it as a
# plan-time precondition, so the next time this runs out it is a plan that says
# so by name and not an apply that dies at the API.

set -euo pipefail

# The same bounds every other call this host makes carries. A boot that hangs is
# worse than one that fails: the instance never registers, never powers off, and
# bills at warm-host size while counting as a host the pool already has.
readonly CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)
readonly SRC="http://metadata.google.internal/computeMetadata/v1/instance/attributes/ci-boot-script-gz"
readonly DEST=/run/ci-host-startup.sh

say() { printf 'boot loader: %s\n' "$1" >&2; }

# /run is tmpfs, root-owned and cleared on reboot, so the script is re-fetched
# on every boot and never lingers on disk. 0700 because it is about to be run as
# root and a slot user must not be able to read -- let alone edit -- the thing
# root executes.
umask 077

# Retried, because this is the one fetch with nothing behind it: the metadata
# server is up microseconds after the guest agent, but "up" and "answering" are
# not the same instant, and a single 500 here is a host that boots to nothing.
# Five tries over ~30s of backoff, then fail LOUDLY -- the register grace is
# what turns a failed boot into a replaced host, and it can only do that if the
# boot actually failed.
ok=0
for attempt in 1 2 3 4 5; do
  # Truncate first. A partial body from a previous attempt that gzip accepted
  # the head of would otherwise be appended to, and `gzip -d` reads the leading
  # member and stops -- which is a TRUNCATED boot script that runs.
  : >"$DEST"
  if curl "${CURL_TIMEOUTS[@]}" -fsS -H "Metadata-Flavor: Google" "$SRC" \
    | base64 -d \
    | gzip -d >"$DEST"; then
    ok=1
    break
  fi
  say "attempt $attempt could not read or decode ci-boot-script-gz"
  sleep $((attempt * 2))
done

if [ "$ok" != 1 ]; then
  say "gave up after 5 attempts; this host will not serve"
  exit 1
fi

# Asserted, not assumed. `set -o pipefail` catches a curl or gzip that FAILED;
# it says nothing about a key that exists and is empty, which is what a
# mis-rendered template produces and which would otherwise `exec bash` an empty
# file, exit 0, and report a healthy host serving nothing -- the exact shape of
# the empty-hook bug in #378.
if [ ! -s "$DEST" ]; then
  say "ci-boot-script-gz decoded to an empty file; this host will not serve"
  exit 1
fi

chmod 0700 "$DEST"

# `exec`, so the boot script IS this process: its exit status is the startup
# script's exit status, its output is the startup script's output, and
# google-startup-scripts.service sees exactly what it saw before this loader
# existed.
exec bash "$DEST"
