#!/usr/bin/env bash
# propagate-host-image.sh -- carry a freshly built host image to every pool
# root that pins one (#1676, step 3 of "Rolling a new runner version out" in
# docs/applying-runner-infra.md).
#
#   scripts/ci/propagate-host-image.sh <image> <build project>          # plan only
#   scripts/ci/propagate-host-image.sh <image> <build project> --apply  # do it
#
# For each row of fleet/image-pins.tsv it reads the root's pinned image path
# (projects/<pool project>/global/images/<old>) and then:
#   1. copies <image> from <build project> into <pool project>, labelled
#      copied-from=<build project>, unless an image of that name is already
#      there (a copy is immutable; a name that exists is the same bytes);
#   2. opens ONE pin-bump PR in that root that swaps only the image name,
#      unless one is already open for this image.
#
# OPERATOR-RUN, by design. A copy needs compute.images.create in every pool
# project and the PR needs write on every root; no automation identity holds
# both, and granting one would let a single token change what every pool boots.
# Run it with your own gcloud account and gh login. Merging the PR applies the
# root within the hour, which moves the instance TEMPLATE; each pool's
# controller then recycles the hosts onto it, a few at a time (the doc's step 5).
#
# Without --apply it changes nothing and prints what it would do.

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
# shellcheck source=scripts/ci/runner-version.sh
. "$HERE/runner-version.sh"

IMAGE="${1:-}"
FROM="${2:-}"
APPLY=0
[ "${3:-}" = --apply ] && APPLY=1
PINS="${RV_PINS_FILE:-$ROOT/fleet/image-pins.tsv}"
OWNER="${RV_OWNER:-$(gh repo view --json owner -q .owner.login 2>/dev/null)}"

die() { echo "propagate-host-image: $*" >&2; exit 2; }
run() { # print, and run only under --apply
  printf '  %s %s\n' "$([ "$APPLY" = 1 ] && echo '+' || echo 'would:')" "$*"
  [ "$APPLY" = 1 ] || return 0
  "$@"
}

rv_image_ref "$IMAGE" >/dev/null || die "'$IMAGE' is not a ci-runner-host-g<sha> or -vX-Y-Z image name"
case "$FROM" in '' | *[!a-z0-9-]*) die "build project '$FROM' is not a project id" ;; esac
[ -n "$OWNER" ] || die "cannot tell the repository owner (set RV_OWNER)"
[ -r "$PINS" ] || die "no pins file at $PINS"
gcloud compute images describe "$IMAGE" --project="$FROM" --format='value(name)' >/dev/null 2>&1 ||
  die "$IMAGE does not exist in $FROM -- has the build finished?"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rc=0
while IFS=$'\t' read -r repo branch path var; do
  case "$repo" in '' | '#'*) continue ;; esac
  echo "== $OWNER/$repo:$path ($var)"
  f="$work/$repo.tfvars"
  meta="$(gh api "repos/$OWNER/$repo/contents/$path?ref=$branch" 2>/dev/null)" ||
    { echo "  FAIL: cannot read the root"; rc=1; continue; }
  # jq on Windows ends lines with CR; base64 refuses it.
  jq -r .content <<<"$meta" | tr -d '\r\n' | base64 -d >"$f" 2>/dev/null || { echo "  FAIL: cannot decode $path"; rc=1; continue; }
  cur="$(rv_tfvar "$f" "$var")"
  proj="$(sed -n 's#^projects/\([a-z0-9-]*\)/global/images/.*#\1#p' <<<"$cur")"
  [ -n "$proj" ] || { echo "  FAIL: $var='$cur' does not name projects/<p>/global/images/<image>"; rc=1; continue; }
  if [ "${cur##*/}" = "$IMAGE" ]; then echo "  ok: already pinned"; continue; fi

  # 1. the copy
  if gcloud compute images describe "$IMAGE" --project="$proj" --format='value(name)' >/dev/null 2>&1; then
    echo "  ok: $IMAGE already exists in $proj"
  else
    run gcloud compute images create "$IMAGE" --project="$proj" \
      --source-image="$IMAGE" --source-image-project="$FROM" \
      --labels="copied-from=$FROM,component=ci-runner-host-pool" || { echo "  FAIL: copy"; rc=1; continue; }
  fi

  # 2. the pin-bump PR
  head="automation/host-image-$IMAGE"
  open="$(gh pr list -R "$OWNER/$repo" --head "$head" --state open --json url -q '.[0].url' 2>/dev/null)"
  if [ -n "$open" ]; then echo "  ok: PR already open: $open"; continue; fi
  rv_retarget_tfvar "$f" "$var" "$IMAGE" || { echo "  FAIL: could not retarget $var"; rc=1; continue; }
  title="fix(image): boot $IMAGE (was ${cur##*/})"
  body="Moves \`$var\` in \`$path\` from \`${cur##*/}\` to \`$IMAGE\`, copied from \`$FROM\` (label \`copied-from\`).

Opened by \`ci-runner-infra/scripts/ci/propagate-host-image.sh\`. The hourly apply moves the instance template; each pool's controller then recycles its hosts onto it, at most \`recycle_max_unavailable\` at a time. To stop a rollout, revert this PR. See ci-runner-infra's docs/applying-runner-infra.md, \"Rolling a new runner version out\"."
  if [ "$APPLY" = 0 ]; then
    echo "  would: open PR '$title' on $head"
    continue
  fi
  if ! {
    base_sha="$(gh api "repos/$OWNER/$repo/git/ref/heads/$branch" -q .object.sha)" &&
      gh api -X POST "repos/$OWNER/$repo/git/refs" -f ref="refs/heads/$head" -f sha="$base_sha" >/dev/null &&
      gh api -X PUT "repos/$OWNER/$repo/contents/$path" -f message="$title" -f branch="$head" \
        -f sha="$(jq -r .sha <<<"$meta" | tr -d '\r')" -f content="$(base64 -w0 <"$f")" >/dev/null &&
      gh pr create -R "$OWNER/$repo" --base "$branch" --head "$head" --title "$title" --body "$body"
  }; then
    echo "  FAIL: could not open the PR"
    rc=1
  fi
done <"$PINS"
[ "$APPLY" = 1 ] || echo "(plan only -- rerun with --apply)"
exit "$rc"
