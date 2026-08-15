#!/usr/bin/env bash
# =============================================================================
# check-playwright-pin.sh — the baked browser image and the documented one agree
#
# USAGE
#   bash scripts/ci/check-playwright-pin.sh [--selftest] [<root>]
#
# PURPOSE
#   PW1  the warm-cache script states a pin this gate can read.
#   PW2  every `mcr.microsoft.com/playwright:v<x>-noble` written anywhere in the
#        repository names that same release.
#   PW3  the warm-cache script exists at all.
#
#   PW3 is separate from PW1 because a missing file and an unreadable pin need
#   different words to act on, and because an id shared with PW1 would let the
#   missing-file branch be deleted with every self-test case still passing —
#   the fall-through reports PW1 anyway, just with the wrong explanation.
#
# WHY THIS IS A GATE AND NOT A STYLE RULE
#   The pin exists twice by necessity and it cannot be collapsed into one place.
#   `packer/warm-cache/playwright.sh` decides which image a pool BAKES; the
#   `container:` line in a consumer's workflow decides which image a job RUNS,
#   and that line lives in the consumer's repository because it also has to
#   match the `@playwright/test` that repository installs. This repository owns
#   only the example the consumer copies.
#
#   When the two drift, nothing breaks and nothing is reported. The container
#   the job asks for is simply not the one on disk, so every UI job downloads
#   about two gigabytes it was supposed to find warm, and the baked archive sits
#   on every host in the pool as dead weight. The suite still passes. The only
#   symptom is that UI jobs are slow — which reads as "browser tests are slow",
#   the most believable false explanation available, and the reason this would
#   otherwise survive indefinitely.
#
#   So the gate does not check that the pin is CORRECT — nothing here can know
#   that. It checks that the repository tells one story about it.
#
# EXIT CODES
#   0 — clean
#   1 — a property is broken
# =============================================================================
set -uo pipefail

fail=0
# Findings carry their id, and the self-test asserts the ID SET a fixture
# produces rather than a count — a count lets one detector's regression hide
# behind another firing on the same fixture.
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

WARM_SCRIPT="packer/warm-cache/playwright.sh"

# Any `mcr.microsoft.com/playwright:v<version>-<codename>` reference. Written to
# match the codename too, so that moving the fleet to a new Ubuntu base cannot
# leave a stale codename passing on the strength of a matching version.
IMAGE_RE='mcr\.microsoft\.com/playwright:v[0-9][0-9.]*-[a-z]+'

check_tree() { # <root>
  local root="$1"
  local pin codename want line file ref

  if [ ! -f "$root/$WARM_SCRIPT" ]; then
    err PW3 "$WARM_SCRIPT is missing — the fleet's baked browser image has no declared version"
    return
  fi

  # The default in the assignment, not a value the environment happens to hold:
  # this gate reads the file, it does not run it.
  # shellcheck disable=SC2016  # the `$` is sed's, not the shell's: `\$` makes
  # sed read a literal `$` instead of its end-of-line anchor, and the text being
  # matched is the unexpanded `${PLAYWRIGHT_VERSION:-…}` as written in the file.
  pin=$(sed -n 's/^PLAYWRIGHT_VERSION="\${PLAYWRIGHT_VERSION:-\([0-9][0-9.]*\)}"$/\1/p' \
        "$root/$WARM_SCRIPT" | head -1)

  if [ -z "$pin" ]; then
    err PW1 "$WARM_SCRIPT declares no readable PLAYWRIGHT_VERSION default — the gate cannot tell which image is baked"
    return
  fi

  # The base too, not only the version. The browsers in the image are linked
  # against that Ubuntu release's system libraries, so `v<pin>-jammy` is as
  # much a cache miss as a wrong version — and comparing versions alone would
  # pass it, because the codename is the part that differs.
  codename=$(sed -n 's/^PLAYWRIGHT_IMAGE=.*-\([a-z][a-z]*\)"$/\1/p' \
             "$root/$WARM_SCRIPT" | head -1)
  if [ -z "$codename" ]; then
    err PW1 "$WARM_SCRIPT declares no readable image base — the gate cannot tell which Ubuntu release is baked"
    return
  fi

  # One string to compare against, so a reference is wrong unless it is exactly
  # what the pool bakes.
  want="mcr.microsoft.com/playwright:v$pin-$codename"

  # Every literal reference in the tree. Not the warm script's own
  # PLAYWRIGHT_IMAGE line, despite it being scanned: that line spells the
  # version as `${PLAYWRIGHT_VERSION}`, and IMAGE_RE needs a digit after the
  # `v`, so it never matches. That is the correct outcome rather than a gap —
  # the warm script is where `want` comes from, so comparing it to itself could
  # only ever pass.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"
    ref="${line#*:}"
    if [ "$ref" != "$want" ]; then
      err PW2 "${file#"$root"/}: names $ref, but the pool bakes $want — a job asking for an image the pool did not bake downloads it instead, and the baked archive is never used"
    fi
  done <<EOF
$(grep -rEo "$IMAGE_RE" "$root" \
    --include='*.sh' --include='*.yml' --include='*.yaml' --include='*.md' --include='*.hcl' \
    --include='*.tf' --include='*.tfvars' --include='*.json' \
    --exclude-dir=.git 2>/dev/null)
EOF
}

# --- self-test ---------------------------------------------------------------
# Fixtures, then the real tree. A gate that reads no file reports clean, so the
# fixtures are what prove the detectors still fire at all.
selftest() {
  local tmp out ids
  local t=0 f=0

  run_case() { # <name> <expected-id-set>
    local name="$1" expect="$2"
    out=$(check_tree "$tmp" 2>&1)
    ids=$(printf '%s\n' "$out" | grep -oE '\[(PW[0-9]+)\]' | tr -d '[]' | sort -u | tr '\n' ',' | sed 's/,$//')
    t=$((t + 1))
    if [ "$ids" = "$expect" ]; then
      echo "ok   — $name"
    else
      echo "FAIL — $name: expected [$expect], got [$ids]"
      printf '%s\n' "$out" | sed 's/^/       /'
      f=$((f + 1))
    fi
    fail=0
  }

  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  mkdir -p "$tmp/packer/warm-cache" "$tmp/docs"

  # The fixtures below are assembled from this prefix rather than written out.
  # A whole reference spelled literally here would be matched by the gate's own
  # scan — this file is a `.sh` in the tree it walks — so the fixtures for the
  # STALE cases would be reported as real drift on every run, and the gate would
  # fail CI forever over its own test data. The prefix alone cannot match:
  # IMAGE_RE requires a digit after the `v`.
  local img='mcr.microsoft.com/playwright:v'

  # A tree that agrees with itself.
  cat >"$tmp/$WARM_SCRIPT" <<'FIX'
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.62.1}"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"
FIX
  echo "use ${img}1.62.1-noble" >"$tmp/docs/ui.md"
  run_case "agreeing tree is clean" ""

  # The drift this gate exists for: a doc left on the previous release.
  echo "use ${img}1.61.0-noble" >"$tmp/docs/ui.md"
  run_case "a stale documented pin is reported" "PW2"

  # A matching version but a stale BASE — same silent miss, different spelling.
  echo "use ${img}1.62.1-jammy" >"$tmp/docs/ui.md"
  run_case "a stale codename is reported" "PW2"

  # THE DIRECTION THIS GATE ACTUALLY EXISTS FOR, and the one the cases above do
  # not cover: they all move the DOC while the warm script holds still, so a
  # `want` hardcoded to the current image would satisfy every one of them and
  # the gate would have stopped reading the pin without any case noticing. Here
  # the warm script is the side that moves — a real version bump, with the doc
  # left on the old release.
  cat >"$tmp/$WARM_SCRIPT" <<'FIX'
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.63.0}"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"
FIX
  echo "use ${img}1.62.1-noble" >"$tmp/docs/ui.md"
  run_case "a bumped warm script with a stale doc is reported" "PW2"

  # The same, for the base: the fleet moves to a new Ubuntu release and the doc
  # keeps the old codename. Pins the codename half of `want` to the warm script
  # for the same reason.
  cat >"$tmp/$WARM_SCRIPT" <<'FIX'
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.62.1}"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-jammy"
FIX
  echo "use ${img}1.62.1-noble" >"$tmp/docs/ui.md"
  run_case "a rebased warm script with a stale doc codename is reported" "PW2"

  # An unreadable pin must not be spent as "no drift found".
  echo "use ${img}1.62.1-noble" >"$tmp/docs/ui.md"
  echo 'PLAYWRIGHT_VERSION="latest"' >"$tmp/$WARM_SCRIPT"
  run_case "an unreadable pin is reported, not passed" "PW1"

  # …and so must an unreadable BASE, which is the half of the reference a
  # version-only check would silently stop asserting.
  cat >"$tmp/$WARM_SCRIPT" <<'FIX'
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.62.1}"
PLAYWRIGHT_IMAGE="$SOMETHING_ELSE"
FIX
  run_case "an unreadable image base is reported, not passed" "PW1"

  rm -f "$tmp/$WARM_SCRIPT"
  run_case "a missing warm script is reported, not passed" "PW3"

  rm -rf "$tmp"; trap - EXIT
  echo "--- $t case(s), $f failure(s)"
  [ "$f" -eq 0 ]
}

main() {
  local root="."
  case "${1:-}" in
    --selftest) selftest; exit $? ;;
    "") ;;
    *) root="$1" ;;
  esac
  check_tree "$root"
  exit "$fail"
}

main "$@"
