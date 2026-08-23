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
# A regex, not a `case` glob. `v[0-9]*.[0-9]*.[0-9]*` reads as the intended
# shape and is not: in a glob `*` matches anything, and `.` is a literal with no
# quantifier attached to the digit class, so `v4x.2y.0junk` and `v4.2.0.1` both
# pass it. The pins are then asserted against a value that is not a tag.
if printf '%s' "$want" | grep -cE '^v[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null; then
  ok "VERSION is a tag-shaped version ($want)"
else
  bad "VERSION is not tag-shaped: '$want' (expected vMAJOR.MINOR.PATCH)"
  echo "  docs pins UNVERIFIABLE."
  exit 1
fi

# Markdown only. The consumer roots that legitimately pin an older version live
# in other repositories; this repo documents one version — its own.
# TRACKED markdown only, not everything on disk. `find` also walked nested
# checkouts that happen to live under the tree — a sibling worktree in
# .claude/worktrees/ pinning an old version failed this gate for content this
# repo does not ship and cannot fix from here.
mapfile -t docs < <(cd "$ROOT" && git ls-files -z -- '*.md' | tr '\0' '\n' | sed "s|^|$ROOT/|" | sort)
[ "${#docs[@]}" -gt 0 ] || { bad "no Markdown files found — the glob is wrong"; echo "  docs pins UNVERIFIABLE."; exit 1; }

found=0
readme_pins=0
for f in "${docs[@]}"; do
  # Only pins of THIS repo's modules. A pin of some other module in an example
  # is not this check's business.
  #
  # `ci-[a-z-]*`, not `ci-runner-[a-z-]*`: the narrower pattern was written when
  # every module was named `ci-runner-*`, and it silently stopped covering the
  # first one that was not (`ci-host-image-trigger`). A pin the gate does not
  # match is a pin that can drift, and it drifts the same silent way the README
  # did — the gate stays green because it never looked. The path prefix
  # `ci-runner-infra.git//modules/` already scopes this to this repo.
  while IFS= read -r line; do
    found=$((found + 1))
    [ "$f" = "$ROOT/README.md" ] && readme_pins=$((readme_pins + 1))
    got=${line##*\?ref=}
    got=${got%%[\"\ )]*}
    if [ "$got" = "$want" ]; then
      ok "${f#"$ROOT/"}: $got"
    else
      bad "${f#"$ROOT/"}: pins $got, VERSION says $want"
    fi
  done < <(grep -o 'ci-runner-infra\.git//modules/ci-[a-z-]*?ref=[^"[:space:])]*' -- "$f")
done

# A check that finds nothing passes, which is how the README drifted in the
# first place: the pin is the thing being asserted, so its absence is a failure,
# not a clean run.
if [ "$found" -eq 0 ]; then
  bad "no module pins found in any Markdown file — the README quickstart is the reason this test exists"
else
  ok "$found documented pin(s) checked"
fi

# Named specifically, because a count is not coverage. The README quickstart is
# the one line a new consumer pastes, and the pins in docs/ are enough to keep
# `found` above zero while it is deleted or edited into a shape the grep no
# longer recognises — leaving this check green over the exact line it exists to
# protect.
if [ "$readme_pins" -eq 0 ]; then
  bad "README.md documents no module pin of this repo — the quickstart snippet is gone or no longer matches, and the rest of the docs were hiding it"
else
  ok "README.md carries $readme_pins pin(s)"
fi

# THE OTHER WAY THIS REPO IS REFERENCED, and one the scan above cannot see.
#
# A consumer reaches this repo two ways: a Terraform module `?ref=`, checked
# above, and a workflow `uses:` — `<org>/ci-runner-infra/.github/{actions,
# workflows}/<name>@<ref>`. The grep above only matches `//modules/...?ref=`, so
# every documented `uses:` line was outside this gate entirely. It went stale
# exactly as the README quickstart did: the UI-testing guide shipped pinned to
# `@v5.8.0` and the repo published v5.19.1, eleven minors later, with nothing
# reporting it.
#
# Asserted against the MAJOR, not against VERSION. This repo publishes a
# floating major tag that moves forward on every release, and that is what the
# other guides already tell a consumer to use — an exact `@vX.Y.Z` in a document
# is stale the next time anything ships, which is the drift rather than the fix.
major=${want%%.*}
uses_found=0
for f in "${docs[@]}"; do
  while IFS= read -r ref; do
    uses_found=$((uses_found + 1))
    if [ "$ref" = "$major" ]; then
      ok "${f#"$ROOT/"}: uses @$ref"
    else
      bad "${f#"$ROOT/"}: a workflow/action reference pins @$ref, but this repo publishes the floating major $major — an exact version here is stale on the next release"
    fi
  done < <(grep -oE 'ci-runner-infra/\.github/(actions|workflows)/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*@[^"[:space:])]+' -- "$f" \
             | sed 's/.*@//')
done

# Same rule as above: a scan that matches nothing is not a pass. If the shape of
# these references changes, this must go red rather than quietly stop asserting.
if [ "$uses_found" -eq 0 ]; then
  bad "no workflow/action references of this repo found in any Markdown file — the guides publish them, so the grep no longer matches what the docs write"
else
  ok "$uses_found documented workflow/action reference(s) checked"
fi

if [ "$fail" -eq 0 ]; then
  echo "  docs pins match VERSION."
else
  echo "  docs pins DRIFTED."
fi
exit "$fail"
