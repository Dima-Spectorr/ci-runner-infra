#!/usr/bin/env bash
# Every module pin printed in this repo's documentation must name the version
# this repo currently publishes.
#
# The README's quickstart snippet sat at `?ref=v3.0.0` while the fleet ran
# v4.1.0 — three minor versions of drift in the ONE copy-pasteable line in the
# repository, and the line a new consumer is most likely to paste verbatim. It
# drifted silently because nothing connected it to a release: tagging happens in
# git, the snippet lives in Markdown, and neither knows about the other.
#
# `VERSION` is that connection. It is the version this repo claims to publish,
# it is bumped in the same pull request as the change being released, and every
# documented pin is asserted against it here.
#
# Deliberately NOT asserted against `git tag`: at pull-request time the tag for
# the version being released does not exist yet, so a tag-based check would
# either fail every release PR or be skipped exactly when it matters.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$ROOT/VERSION"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

echo "docs-pins self-test:"

if [ -r "$VERSION_FILE" ]; then
  ok "VERSION is readable"
else
  echo "  FAIL  VERSION is missing — every check below would be vacuous"
  exit 1
fi

want=$(tr -d '[:space:]' < "$VERSION_FILE")
case "$want" in
  v[0-9]*.[0-9]*.[0-9]*) ok "VERSION is a tag-shaped version ($want)" ;;
  *) bad "VERSION is not tag-shaped: '$want' (expected vMAJOR.MINOR.PATCH)"; echo "  docs pins UNVERIFIABLE."; exit 1 ;;
esac

# Markdown only. The consumer roots that legitimately pin an older version live
# in other repositories; this repo documents one version — its own.
mapfile -t docs < <(find "$ROOT" -name '*.md' -not -path '*/.git/*' | sort)
[ "${#docs[@]}" -gt 0 ] || { bad "no Markdown files found — the glob is wrong"; echo "  docs pins UNVERIFIABLE."; exit 1; }

found=0
for f in "${docs[@]}"; do
  # Only pins of THIS repo's modules. A pin of some other module in an example
  # is not this check's business.
  while IFS= read -r line; do
    found=$((found + 1))
    got=${line##*\?ref=}
    got=${got%%[\"\ )]*}
    if [ "$got" = "$want" ]; then
      ok "${f#"$ROOT/"}: $got"
    else
      bad "${f#"$ROOT/"}: pins $got, VERSION says $want"
    fi
  done < <(grep -o 'ci-runner-infra\.git//modules/ci-runner-[a-z-]*?ref=[^"[:space:])]*' "$f")
done

# A check that finds nothing passes, which is how the README drifted in the
# first place: the pin is the thing being asserted, so its absence is a failure,
# not a clean run.
if [ "$found" -eq 0 ]; then
  bad "no module pins found in any Markdown file — the README quickstart is the reason this test exists"
else
  ok "$found documented pin(s) checked"
fi

if [ "$fail" -eq 0 ]; then
  echo "  docs pins match VERSION."
else
  echo "  docs pins DRIFTED."
fi
exit "$fail"
