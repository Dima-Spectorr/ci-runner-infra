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
# visible to all of them, because /opt/ci-cache is the one tree slots share.
# host-startup.sh's load_baked_images() loads every archive found here into each
# slot's daemon at boot.
#
# The version is pinned deliberately. Playwright refuses to run when the browser
# build in the image does not match the `@playwright/test` the repository
# installed, so "latest" would break every consumer the day it moved.
# `check-playwright-pin.sh` holds this constant and the reusable workflow's
# `container:` image to the same value.
set -euo pipefail

# Override at build time with a packer environment_var if a pool needs a
# different release; keep it in step with the reusable workflow or the gate
# fails the build.
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.62.1}"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"

# noble, to match the host's Ubuntu 24.04. The tag family is not cosmetic: the
# browser binaries in the image are linked against that release's system
# libraries.

IMAGE_DIR="/opt/ci-cache/images"
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

# The pull IS the check that the tag exists. Failing here costs one image build;
# the alternative is discovering a typo'd tag on every host, hours later, as a
# job that cannot start its container.
if ! docker pull "$PLAYWRIGHT_IMAGE"; then
  echo "[warm-cache] could not pull $PLAYWRIGHT_IMAGE — is v${PLAYWRIGHT_VERSION}-noble a published tag?" >&2
  exit 1
fi

# Gzipped: it trades a little CPU at each slot's load for roughly a third of the
# bytes in the image, and `docker load` reads gzip transparently. Written to a
# temp path and moved, so an interrupted build cannot leave a truncated archive
# that every host then fails to load.
echo "[warm-cache] saving $PLAYWRIGHT_IMAGE to $ARCHIVE"
docker save "$PLAYWRIGHT_IMAGE" | gzip -1 >"$ARCHIVE.partial"
mv "$ARCHIVE.partial" "$ARCHIVE"

# Reclaim the build VM's copy: it is dead weight in the final image, and the
# slots read the archive, never this.
docker rmi "$PLAYWRIGHT_IMAGE" >/dev/null 2>&1 || true

echo "[warm-cache] baked $(du -h "$ARCHIVE" | cut -f1) archive for $PLAYWRIGHT_IMAGE"
