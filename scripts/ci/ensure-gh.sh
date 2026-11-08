#!/usr/bin/env bash
# Make `gh` available to a job, on a runner that may not have it.
#
# WHY THIS EXISTS. GitHub-hosted images ship the CLI; the fleet's self-hosted
# pool images do not. Nothing noticed until the merge lane ran there, and the
# way it failed is the reason this script is a hard dependency rather than a
# nicety: `merge-lane.sh` reads every fact through `gh api ... || true`, so a
# missing binary read as "no facts available", the lane concluded there was
# nothing to merge, and the job went green. Seven repositories reported a
# healthy lane that could not have merged anything.
#
# The host image now bakes gh into /usr/local/bin by running THIS script at
# build time (packer step 4b, #441), so on a current pool host it exits on its
# first check. The job-time download remains for hosts still on an older image
# and for GitHub-hosted runners without gh. The version and digest below are
# the single pin for both. Changing them rebuilds the image, because the image
# trigger watches this file.
#
# PINNED BY DIGEST, NOT BY TAG. The lane holds an App token with write access to
# every repository in the fleet, so an unpinned download here would be a far
# larger hole than the moving `uses:` tag this repository already refuses to
# allow. A release retagged upstream fails the checksum and the job stops.
set -euo pipefail

GH_VERSION="${GH_VERSION:-2.98.0}"
# `gh_<version>_linux_<arch>.tar.gz` from cli/cli's release assets. Read below
# by indirect expansion, which shellcheck cannot follow — hence the directive.
# shellcheck disable=SC2034
GH_SHA256_amd64="3b8ac6b30336802fc1a858d7c084e11cdf24ac1a761ca90b68022d7d729208de"
# shellcheck disable=SC2034
GH_SHA256_arm64="cf689084f3a3618f7eae4a2420d335d74626d65f5e594b9828d125d69f800d86"
# The same two assets' ids in the releases API, for the fallback below. An
# asset id never changes for the life of the asset, and the digest above still
# decides what is accepted, so a wrong id can only fail, never install.
# shellcheck disable=SC2034
GH_ASSET_amd64="522857901"
# shellcheck disable=SC2034
GH_ASSET_arm64="522857902"

if command -v gh >/dev/null 2>&1; then
  echo "ensure-gh: already present — $(gh --version | head -1)"
  exit 0
fi

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "ensure-gh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

# Indirect expansion rather than a case block so adding an architecture means
# adding one constant, not two places that have to agree.
sha_var="GH_SHA256_${arch}"
want="${!sha_var}"
asset_var="GH_ASSET_${arch}"
asset="${!asset_var}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tarball="gh_${GH_VERSION}_linux_${arch}.tar.gz"
url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tarball}"

echo "ensure-gh: not on PATH — installing ${GH_VERSION} (${arch})"
# --retry-all-errors: a plain --retry skips a dropped connection (curl 56,
# "Connection reset by peer"), which is exactly what a pool full of freshly
# booted hosts downloading this at once produced on 2026-11-05 (#1683).
#
# FALLBACK. From 2026-11-08 the releases/download URL answered 504 from
# GitHub's own edge (israelcentral) on every try while the releases API served
# the same bytes, and every PR guard in the fleet went red. So the first path
# gets fewer tries, and then the API's asset endpoint is asked for the same
# file. The job's token is sent when there is one: anonymous API calls share 60
# an hour per address, and a pool's hosts share one. curl does not carry the
# Authorization header across the redirect to the storage host.
if ! curl -sSfL --retry 2 --retry-delay 3 --retry-all-errors --connect-timeout 20 -o "$tmp/$tarball" "$url"; then
  api="https://api.github.com/repos/cli/cli/releases/assets/${asset}"
  echo "ensure-gh: the release download failed — fetching the same asset from ${api}" >&2
  auth=()
  token="${GH_DOWNLOAD_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
  if [ -n "$token" ]; then
    auth=(-H "Authorization: Bearer ${token}")
  fi
  curl -sSfL --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20 \
    -H "Accept: application/octet-stream" "${auth[@]}" -o "$tmp/$tarball" "$api"
fi

got="$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)"
if [ "$got" != "$want" ]; then
  echo "ensure-gh: checksum mismatch for $tarball" >&2
  echo "  expected $want" >&2
  echo "  got      $got" >&2
  exit 1
fi

tar -xzf "$tmp/$tarball" -C "$tmp"

# `$RUNNER_TEMP/bin` rather than /usr/local/bin: the pool runs several slots per
# host as an unprivileged user, and two concurrent jobs writing the same
# system path is a race that would only ever show up under load.
#
# The fallback must NOT be under `$tmp`, which the EXIT trap removes: the binary
# would be deleted as this script exits, `$GITHUB_PATH` would name a directory
# that no longer exists, and the caller would see a successful install and no
# `gh` — the precise failure this script was written to remove. Actions always
# sets `RUNNER_TEMP`; the fallback is for running this by hand.
dest="${RUNNER_TEMP:-${HOME:-/tmp}/.cache/ensure-gh}/bin"
mkdir -p "$dest"
install -m 0755 "$tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" "$dest/gh"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dest" >> "$GITHUB_PATH"
fi
export PATH="$dest:$PATH"

echo "ensure-gh: installed — $("$dest/gh" --version | head -1)"
