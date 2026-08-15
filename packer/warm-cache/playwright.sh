#!/usr/bin/env bash
# Warm-cache layer: bake the official Playwright container into the image, so a
# UI test job starts driving a browser instead of downloading one.
#
# Opt-in, per pool. Point `warm_cache_script` at this file for pools that run
# browser tests; every other pool keeps the toolchain-only image and pays
# nothing. A browser image helps only the repositories that run UI tests, and it
# is the single largest thing anyone has proposed adding to an image every
# repository boots — so it is a pool's choice, not the fleet baseline.
#
# WHY A TARBALL AND NOT A PULL
#
# `docker pull` here would be wasted work, and the warm_cache_script contract
# says so directly: each slot runs its own rootless daemon with its own data
# root under the slot user's home, so an image pulled into this build VM's
# root-owned /var/lib/docker is invisible to every one of them. A baked FILE is
# visible to all of them, because every slot user can read /opt/ci-images.
# host-startup.sh's load_baked_images() loads every archive found here into each
# slot's daemon at boot.
#
# NOT under /opt/ci-cache, which host-startup.sh copies into a writable per-slot
# tree at boot. What is written here is `docker load`ed into every slot on the
# host at every boot, so a job able to write it would be running its own image in
# every other slot — and write+execute on the copy's non-sticky parent would be
# enough to swap this whole directory out, checksums and all, however the files
# inside it are owned.
#
# The version is pinned deliberately. Playwright refuses to run when the browser
# build in the image does not match the `@playwright/test` the repository
# installed, so "latest" would break every consumer the day it moved.
# `check-playwright-pin.sh` holds this constant and every image reference
# written anywhere in this repository — the composite action, the docs, the
# examples a consumer copies — to the same value.
set -euo pipefail

# Override at build time with a packer environment_var if a pool needs a
# different release; keep it in step with the image references the docs and the
# composite action publish, or the gate fails the build.
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.62.1}"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"

# noble, to match the host's Ubuntu 24.04. The tag family is not cosmetic: the
# browser binaries in the image are linked against that release's system
# libraries.

IMAGE_DIR="/opt/ci-images"
ARCHIVE="$IMAGE_DIR/playwright-v${PLAYWRIGHT_VERSION}-noble.tar.gz"

echo "[warm-cache] baking $PLAYWRIGHT_IMAGE"

mkdir -p "$IMAGE_DIR"

# Idempotent: a re-run over an existing archive is a no-op, not a second copy.
if [ -s "$ARCHIVE" ]; then
  echo "[warm-cache] $ARCHIVE already present — nothing to do"
  exit 0
fi

# The rootful daemon is `systemctl disable`d earlier in the build so it does not
# come up on a HOST, but disable does not stop it here and the build VM still
# needs one to pull with. Start it if it is not already running; this is the
# build VM, which is discarded, not the image's boot state.
if ! docker info >/dev/null 2>&1; then
  systemctl start docker.service
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
fi
docker info >/dev/null 2>&1 || {
  echo "[warm-cache] no docker daemon in the build VM — cannot bake an image archive" >&2
  exit 1
}

# THE ASSERTION THIS WHOLE FEATURE RESTS ON.
#
# The runner does not check whether the `container:` image is already present —
# it runs `docker pull` unconditionally before starting the job's container. So
# baking the image saves the download only if that pull can recognise the loaded
# layers as the ones it was about to fetch, and that is true only under the
# containerd image store, which keeps each layer's registry blob digest through
# a save/load round trip. The legacy graphdriver store does not: the image loads
# fine, `docker images` looks right, and the pull then re-downloads every byte.
#
# Measured on a host booted from this image (docker 29.7.2, storage driver
# `overlayfs`, driver-type `io.containerd.snapshotter.v1`): load 53s, and the
# subsequent pull of the same tag returned "Image is up to date" in 2.1s having
# transferred nothing.
#
# Nothing pins us to that store — docker-ce is installed unversioned and sets no
# `features.containerd-snapshotter` — so this asserts it instead of assuming it.
# Failing the bake is the only place the problem is visible: on a host the
# feature would simply stop paying off, and the symptom is "the UI tests got
# slow", which is the most believable wrong explanation there is.
#
# Checked on the BUILD VM's daemon, while the slot daemons that do the loading
# are rootless and per-user. Neither sets the feature flag, so both follow the
# same engine default and this is a faithful proxy — but it is a proxy, which is
# why host-startup.sh logs the store it actually got on each slot at boot.
image_store="$(docker info --format '{{.DriverStatus}}' 2>/dev/null || true)"
case "$image_store" in
  *io.containerd.snapshotter.v1*) : ;;
  *)
    echo "[warm-cache] this daemon is NOT using the containerd image store" >&2
    echo "[warm-cache]   docker info DriverStatus: ${image_store:-<empty>}" >&2
    echo "[warm-cache] a baked archive would load but the runner's own pull would" >&2
    echo "[warm-cache] re-download the whole image, so the bake would cost ~900MB" >&2
    echo "[warm-cache] of image size and buy nothing. Refusing to bake it." >&2
    exit 1
    ;;
esac

# The pull IS the check that the tag exists. Failing here costs one image build;
# the alternative is discovering a typo'd tag on every host, hours later, as a
# job that cannot start its container.
if ! docker pull "$PLAYWRIGHT_IMAGE"; then
  echo "[warm-cache] could not pull $PLAYWRIGHT_IMAGE — is v${PLAYWRIGHT_VERSION}-noble a published tag?" >&2
  exit 1
fi

# `docker load` reads gzip transparently, and `-1` is the cheap end of the
# trade: some saving for little CPU at each slot's load. Do not expect much from
# it — under the containerd image store the layers in the archive are already
# the registry's compressed blobs, so this is re-compressing compressed data.
# The measured result for this tag is a 942MB archive, and the image reports
# 3.52GB on disk once loaded. Written to a temp path and moved, so an
# interrupted build cannot leave a truncated archive that every host then fails
# to load.
echo "[warm-cache] saving $PLAYWRIGHT_IMAGE to $ARCHIVE"
docker save "$PLAYWRIGHT_IMAGE" | gzip -1 >"$ARCHIVE.partial"
mv "$ARCHIVE.partial" "$ARCHIVE"

# A checksum recorded at bake time, verified by each slot before it loads.
#
# The image build is the only moment this archive is known-good, so the digest
# has to be taken here. It is defence in depth rather than the primary control
# — the primary control is that /opt/ci-images and its parent are root-owned
# and not writable by any slot — but it is the half that still holds if that
# ownership is ever widened by a later change, and it turns a truncated or
# half-copied archive into a clean skip instead of a `docker load` failure
# nobody reads.
# Appended, not rewritten: another warm script may have baked its own archive
# into this directory, and its line must survive.
( cd "$IMAGE_DIR" && sha256sum "$(basename "$ARCHIVE")" >>SHA256SUMS )

# Reclaim the build VM's copy: it is dead weight in the final image, and the
# slots read the archive, never this.
docker rmi "$PLAYWRIGHT_IMAGE" >/dev/null 2>&1 || true

echo "[warm-cache] baked $(du -h "$ARCHIVE" | cut -f1) archive for $PLAYWRIGHT_IMAGE"
