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
# Installing at job time rather than baking it into the image is deliberate for
# now: baking it in means a Terraform apply plus recreating every host in every
# pool one at a time, and until that lands a consumer's lane would work or not
# depending on which host it happened to get. This makes the dependency
# explicit and identical everywhere. Bake it into the image later and this
# script becomes a no-op on the first line, which is exactly what should happen.
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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tarball="gh_${GH_VERSION}_linux_${arch}.tar.gz"
url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tarball}"

echo "ensure-gh: not on PATH — installing ${GH_VERSION} (${arch})"
curl -sSfL --retry 3 --retry-delay 2 -o "$tmp/$tarball" "$url"

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
