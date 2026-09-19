#!/usr/bin/env bash
# =============================================================================
# check-version-bump.sh — a change to a released surface must move VERSION
#
# USAGE
#   bash scripts/ci/check-version-bump.sh --selftest
#   bash scripts/ci/check-version-bump.sh [--repo=<dir>]
#
#   Inputs arrive as ENVIRONMENT VARIABLES, never from an API call in here:
#
#     PR_BASE_SHA   the pull request's base sha. UNSET OR EMPTY MEANS "this is
#                   not a pull request" — see NOT A PULL REQUEST below.
#     PR_HEAD_SHA   the pull request's head sha. Defaults to HEAD.
#     PR_LABELS     the labels on the pull request, one per line (or comma
#                   separated). The escape hatch is read from here.
#
#   Everything this gate decides is a pure function of those three strings and
#   the git history already on disk, which is what lets the self-test below
#   drive it over REAL repositories instead of a mock.
#
# WHAT IT PROTECTS
#   Fourteen repositories consume this one by pinning `?ref=v5`, and that
#   floating tag is moved by `publish-tag.yml` — which moves it only when
#   `VERSION` changes. So a change that merges to main without a `VERSION` bump
#   is in main and released NOWHERE, and there is no signal anywhere that says
#   so: the pull request is green, the merge is clean, the fix demonstrably
#   works on main, and `publish-tag.yml` reports — correctly — that there was
#   nothing to move.
#
#   Measured, issue #960: `afc9bf3` ("don't abandon the pass on a
#   required-status-check 405", #957) merged at 11:30Z on 2026-09-19 after the
#   v5.105.0 release commit and did not bump `VERSION`. `git ls-remote origin
#   refs/tags/v5 refs/tags/v5.105.0` returned the same object for both, and
#   `git log v5..origin/main` listed exactly that commit. No consumer had the
#   fix. Every gate was green.
#
#   `docs-pins.selftest.sh` cannot see this and is not meant to: it asserts that
#   every documented pin names the version in `VERSION`, so a `VERSION` NOBODY
#   TOUCHED is trivially self-consistent and passes. It is well aimed at the
#   mirror-image lapse (the docs drifting behind the fleet) and structurally
#   blind to this one. This gate is the other half of that pair.
#
# FAIL THE PULL REQUEST, NOT THE RELEASE
#   A post-merge detector would report an omission that can then only be
#   corrected by a second pull request. Gating the pull request makes the bump
#   part of the change, which is what the README's rule — bump `VERSION` in the
#   same pull request as the change being released — has always asked for. It
#   was prose only until this file existed, and prose has no run to go red.
#
# THE RELEASED SURFACE, DECLARED ONCE
#   `RELEASED_PATHS` below is the single declaration; the self-test asserts
#   against it rather than against a second copy of the list.
#
#     modules/   what a consumer's `source = "...//modules/X?ref=v5"` resolves
#                to. A change here reaches a consumer only through the tag.
#     scripts/   the decision scripts and the boot/lane shell the modules embed
#                and the reusable workflows call at the pinned ref.
#
#   Deliberately NOT on the list, and why each one is genuinely different:
#
#     docs/, README.md   read on github.com at whatever main says. A reader
#                        never resolves them through `?ref=`, so a doc fix that
#                        does not move the tag has still reached everybody.
#     .github/           this repository's own CI. Consumers call the REUSABLE
#                        workflows by SHA (`check-action-pins.sh` enforces it),
#                        which no tag move affects, and the rest of it runs
#                        only here.
#     fleet/             the fleet's own roots and inventory — inputs to an
#                        apply run from this repository, not something another
#                        repository sources.
#     packer/           the host image, published through an image FAMILY by the
#                        Cloud Build trigger in `cloudbuild.yaml`. A consumer
#                        selects it by family, never by `?ref=`, so the git tag
#                        is not the channel it travels on.
#
#   The list is deliberately coarse. A self-test-only edit under `scripts/ci`
#   is caught by it and genuinely does not need a release — that is what the
#   escape hatch is for, and putting the justification on the ESCAPE rather
#   than on the bump is the direction issue #960 asked for.
#
# NOT A PULL REQUEST
#   A push to main has no merge base to gate on, and guessing one (yesterday's
#   tag? the first parent?) would invent an answer the event does not contain.
#   With `PR_BASE_SHA` empty this gate does nothing and SAYS it did nothing, so
#   a reader of a push log is never left wondering whether it ran and passed.
#   A `PR_BASE_SHA` that is set but unreachable is the opposite case — a broken
#   or shallow checkout — and is a hard error, because that is this gate's own
#   vacuous-green shape.
#
# FAILING CLOSED
#   A missing or non-tag-shaped `VERSION` on either side is a hard error, never
#   a pass. Two unreadable versions compare equal, and "they match" over
#   nothing is precisely the silent success this file exists to end.
# =============================================================================
set -euo pipefail

REPO="."
SELFTEST=0

for arg in "$@"; do
  case "$arg" in
    --selftest) SELFTEST=1 ;;
    --repo=*) REPO="${arg#*=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# THE ONE DECLARATION. Path prefixes, matched against `git diff --name-only`
# output, which is always repo-root-relative and slash-separated.
RELEASED_PATHS=("modules/" "scripts/")

# The label that says "this change is genuinely unreleasable". One string, so
# the workflow, the README and the self-test cannot drift apart.
ESCAPE_LABEL="no-release"

fail() { echo "ERROR: $*" >&2; exit 2; }

# --- pure helpers -----------------------------------------------------------

is_released_path() { # $1 = a path from the diff
  local p="$1" prefix
  for prefix in "${RELEASED_PATHS[@]}"; do
    case "$p" in "$prefix"*) return 0 ;; esac
  done
  return 1
}

# `grep -c … >/dev/null`, never `grep -q`: under `pipefail` a `-q` reader exits
# on its first match, the in-process writer dies of EPIPE, and the pipeline that
# FOUND its text reports 141. `-c` reads to end of input and still exits 1 on no
# match. (`scripts/ci/check-pipefail-readers.sh` [PFR2] is the gate for this.)
tag_shaped() { printf '%s' "$1" | grep -cE '^v[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null; }

# A zero-padded key so `<` compares versions rather than strings: without it
# v5.9.0 sorts after v5.10.0 and a real forward bump reads as a downgrade.
version_key() {
  printf '%s' "${1#v}" | awk -F. '{ printf "%010d%010d%010d", $1, $2, $3 }'
}

next_minor() {
  printf '%s' "${1#v}" | awk -F. '{ printf "v%d.%d.0", $1, $2 + 1 }'
}

# The labels, however they arrive. The Actions expression that fills PR_LABELS
# can produce either one-per-line or a comma-joined string depending on how it
# is written, and a gate whose escape hatch depends on which is a gate that
# fails a release for a formatting reason.
has_escape_label() { # $1 = raw label blob
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
    grep -cxF "$ESCAPE_LABEL" >/dev/null
}

# --- the gate ---------------------------------------------------------------

check_repo() {
  local base="${PR_BASE_SHA:-}" head="${PR_HEAD_SHA:-}" labels="${PR_LABELS:-}"

  if [ -z "$base" ]; then
    echo "skipped — PR_BASE_SHA is empty, so this is not a pull request."
    echo "  A push has no merge base to compare against and this gate does not"
    echo "  invent one. The rule is enforced before the merge, not after it."
    return 0
  fi

  head="${head:-HEAD}"

  git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    fail "base '$base' is not a commit in this checkout. That is a shallow or
  wrong checkout, not a clean tree: pass fetch-depth: 0 and fetch the base ref.
  Passing here would be this gate reporting green over a comparison it never
  made."
  git rev-parse --verify --quiet "$head^{commit}" >/dev/null ||
    fail "head '$head' is not a commit in this checkout."

  local mb
  mb="$(git merge-base "$base" "$head")" ||
    fail "no merge base between '$base' and '$head' — unrelated histories."

  # `git diff <merge-base> <head>`, never `git diff <base-tip> <head>`: the base
  # branch moves while a pull request is open, and diffing against its tip
  # attributes every commit merged in the meantime to this pull request. That
  # would fail a documentation-only change for somebody else's module edit.
  local touched released=""
  touched="$(git diff --name-only "$mb" "$head")"

  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_released_path "$p"; then
      released="$released$p"$'\n'
    fi
  done <<<"$touched"

  echo "base $mb .. head $(git rev-parse --short "$head")"

  if [ -z "$released" ]; then
    echo "ok — nothing under ${RELEASED_PATHS[*]} changed; no release is implied."
    return 0
  fi

  local base_version head_version
  base_version="$(git show "$mb:VERSION" 2>/dev/null | tr -d '[:space:]')" || true
  head_version="$(git show "$head:VERSION" 2>/dev/null | tr -d '[:space:]')" || true

  tag_shaped "$base_version" ||
    fail "VERSION at the merge base is missing or not tag-shaped ('$base_version').
  Two unreadable versions compare equal, so this fails rather than passing."
  tag_shaped "$head_version" ||
    fail "VERSION at the head is missing or not tag-shaped ('$head_version').
  Expected vMAJOR.MINOR.PATCH."

  echo "released surface touched:"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "  $p"
  done <<<"$released"

  if [ "$head_version" != "$base_version" ]; then
    # Forward only, exactly as `publish-tag.yml` is. A revert, a bad
    # cherry-pick or a merge restoring an older VERSION walks the floating tag
    # BACKWARDS at every consumer's next apply, with no pull request anywhere
    # and nothing red. publish-tag refuses the move; catching it here means the
    # pull request that would cause it is what goes red, rather than a release
    # run after the fact.
    if [[ "$(version_key "$head_version")" < "$(version_key "$base_version")" ]]; then
      echo "FAIL  VERSION moves BACKWARDS: $base_version -> $head_version" >&2
      echo "      The floating major tag is forward-only. publish-tag.yml will" >&2
      echo "      refuse this move, so the release would simply not happen —" >&2
      echo "      the same invisible non-release this gate exists to catch." >&2
      echo "      Set VERSION to $(next_minor "$base_version") or later." >&2
      return 1
    fi
    echo "ok — VERSION moves $base_version -> $head_version, so the change ships."
    return 0
  fi

  # Unchanged. The escape hatch applies HERE and only here: a backwards move is
  # never a thing anybody needs, so the label does not buy one above.
  if has_escape_label "$labels"; then
    echo "WARNING — a released surface changed and VERSION stays at $base_version."
    echo "  Honoured because the '$ESCAPE_LABEL' label is on this pull request."
    echo "  That label is the assertion that these changes reach no consumer —"
    echo "  a self-test-only edit, a comment, a revert of something never"
    echo "  released. If it is on the wrong pull request, the change merges and"
    echo "  is released nowhere, which is issue #960 happening again with a"
    echo "  label on it. Remove the label and bump to $(next_minor "$base_version")."
    return 0
  fi

  echo "FAIL  a released surface changed and VERSION is unchanged at $base_version." >&2
  echo "      Consumers pin ?ref=v5, and publish-tag.yml moves that tag only" >&2
  echo "      when VERSION changes — so merging this leaves the change in main" >&2
  echo "      and released nowhere, with every check green. That is #960." >&2
  echo "" >&2
  echo "      Fix: set VERSION to $(next_minor "$base_version") in this pull" >&2
  echo "      request, and update the documented module pins to match" >&2
  echo "      (bash scripts/ci/docs-pins.selftest.sh names any that are stale)." >&2
  echo "" >&2
  echo "      current  $base_version" >&2
  echo "      next     $(next_minor "$base_version")" >&2
  echo "" >&2
  echo "      If this change genuinely reaches no consumer, label the pull" >&2
  echo "      request '$ESCAPE_LABEL' — the escape is what gets justified," >&2
  echo "      never the bump." >&2
  return 1
}

# --- self-test --------------------------------------------------------------
#
# Real git repositories in a temp dir, built commit by commit. Nothing about
# `git` is stubbed: a stub would accept whatever this script asks it, including
# the argument orders that are the easy way to get a diff subtly wrong.

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

selftest() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/nohooks"

  # A fixture repository with a base commit on `main` and a `feature` branch
  # checked out. Hooks and signing are switched off so the fixture does not
  # inherit this machine's git configuration and fail for an unrelated reason.
  seed() {
    rm -rf "$tmp/r"
    mkdir -p "$tmp/r"
    (
      cd "$tmp/r"
      git init -q
      git symbolic-ref HEAD refs/heads/main
      git config user.email selftest@example.invalid
      git config user.name selftest
      git config commit.gpgsign false
      git config core.hooksPath "$tmp/nohooks"
      # The fixture is compared byte for byte; a line-ending rewrite inherited
      # from the host's global config would make VERSION differ for a reason
      # that has nothing to do with the rule under test.
      git config core.autocrlf false
      mkdir -p modules/ci-runner-host-pool scripts/ci docs
      printf 'v5.10.0\n' >VERSION
      printf 'locals { a = 1 }\n' >modules/ci-runner-host-pool/main.tf
      printf 'echo hi\n' >scripts/ci/thing.sh
      printf 'a doc\n' >docs/guide.md
      git add -A
      git commit -qm base
      git checkout -qb feature
    )
  }

  commit_in() { # $1 = path, $2 = content — one commit on `feature`
    (
      cd "$tmp/r"
      mkdir -p "$(dirname "$1")"
      printf '%s\n' "$2" >"$1"
      git add -A
      git commit -qm "change $1"
    )
  }

  run() { # runs the gate over the fixture; PR_LABELS from $1
    (
      cd "$tmp/r"
      PR_BASE_SHA="$(git rev-parse main)" \
      PR_HEAD_SHA="$(git rev-parse feature)" \
      PR_LABELS="${1:-}" \
        bash "$SELF"
    )
  }

  local out

  # CASE 1 — THE MEASURED FAILURE. A module changes, VERSION does not. This is
  # #957 exactly, and it must be the thing that goes red.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 2 }'
  if out="$(run 2>&1)"; then
    printf '%s\n' "$out" >&2
    echo "selftest FAILED (must-fire, module + no bump): the measured failure
  from #960 must not pass." >&2
    return 1
  fi
  # The number, not just a verdict: issue #960 asks for the failure to name the
  # current version and the next minor so the fix is one edit.
  printf '%s' "$out" | grep -c 'current  v5\.10\.0' >/dev/null || {
    echo "selftest FAILED: the failure must name the current VERSION." >&2; return 1; }
  printf '%s' "$out" | grep -c 'next     v5\.11\.0' >/dev/null || {
    echo "selftest FAILED: the failure must name the next minor — and compute it
  numerically, so v5.10.0 goes to v5.11.0 and not to v5.2.0." >&2; return 1; }

  # CASE 2 — the same change WITH the bump passes. Without this the arms below
  # prove only that the gate can fail.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 2 }'
  commit_in VERSION 'v5.11.0'
  run >/dev/null || {
    echo "selftest FAILED (must-be-quiet, module + bump)." >&2; return 1; }

  # CASE 3 — the other released prefix. `scripts/` is on the list for the same
  # reason `modules/` is, and an implementation that only ever looked at the
  # first entry of RELEASED_PATHS would pass everything below.
  seed
  commit_in scripts/ci/thing.sh 'echo changed'
  run >/dev/null 2>&1 && {
    echo "selftest FAILED (must-fire, scripts/ + no bump): scripts/ is a
  released surface too." >&2; return 1; }

  # CASE 4 — documentation only. Nothing reaches a consumer through the tag, so
  # requiring a release here would make the gate something people route around.
  seed
  commit_in docs/guide.md 'a better doc'
  run >/dev/null || {
    echo "selftest FAILED (must-be-quiet, docs-only + no bump)." >&2; return 1; }

  # CASE 5 — the escape hatch, and that it SAYS WHY. A silent escape is
  # indistinguishable in a log from a gate that did not notice.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 3 }'
  out="$(run "$ESCAPE_LABEL" 2>&1)" || {
    echo "selftest FAILED (must-be-quiet, escape label)." >&2; return 1; }
  printf '%s' "$out" | grep -c "Honoured because the '$ESCAPE_LABEL' label" >/dev/null || {
    echo "selftest FAILED: the escape must print why it is being honoured." >&2
    return 1; }

  # …and that it is the LABEL doing the work, not the mere presence of some
  # label. A substring match on the blob would honour 'no-release-notes'.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 3 }'
  run "documentation,no-release-notes" >/dev/null 2>&1 && {
    echo "selftest FAILED: only the exact label '$ESCAPE_LABEL' may escape." >&2
    return 1; }

  # CASE 6 — VERSION walks BACKWARDS. The bump is present, so every
  # "did it change?" reading of the rule passes; publish-tag.yml would then
  # refuse the move and the release silently would not happen.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 4 }'
  commit_in VERSION 'v5.9.0'
  out="$(run 2>&1)" && {
    echo "selftest FAILED (must-fire, backwards): the floating tag is
  forward-only, so a backwards VERSION releases nothing." >&2; return 1; }
  printf '%s' "$out" | grep -c 'BACKWARDS' >/dev/null || {
    echo "selftest FAILED: a backwards move must be reported as such, not as a
  missing bump — the fix is different." >&2; return 1; }

  # …and the escape label must NOT buy a backwards move. Nobody needs one.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 4 }'
  commit_in VERSION 'v5.9.0'
  run "$ESCAPE_LABEL" >/dev/null 2>&1 && {
    echo "selftest FAILED: '$ESCAPE_LABEL' must not license a backwards
  VERSION." >&2; return 1; }

  # CASE 7 — not a pull request. No base sha, no merge base, no guess.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 5 }'
  out="$( cd "$tmp/r" && PR_BASE_SHA="" PR_HEAD_SHA="" PR_LABELS="" bash "$SELF" 2>&1 )" || {
    echo "selftest FAILED: a non-pull-request context must be a no-op." >&2
    return 1; }
  printf '%s' "$out" | grep -c 'not a pull request' >/dev/null || {
    echo "selftest FAILED: the no-op must say so, or a push log cannot be told
  apart from a pass." >&2; return 1; }

  # CASE 8 — the no-op is for a MISSING base, not an unreachable one. A base
  # sha that is set and not in the checkout is a shallow clone, and passing
  # there is exactly the vacuous green this gate is about.
  seed
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 6 }'
  out="$( cd "$tmp/r" && PR_BASE_SHA="0000000000000000000000000000000000000000" \
      PR_HEAD_SHA="" PR_LABELS="" bash "$SELF" 2>&1 )" && {
    echo "selftest FAILED: an unreachable base must be a hard error, not a
  no-op." >&2; return 1; }
  # Same reason as CASE 9: `git merge-base` would also exit non-zero here, so
  # an exit-code-only assertion would survive the shallow-checkout check being
  # deleted and the operator would lose the message that names the cause.
  printf '%s' "$out" | grep -c 'is not a commit in this checkout' >/dev/null || {
    echo "selftest FAILED: the shallow-checkout case must say so by name." >&2
    return 1; }

  # CASE 9 — VERSION unreadable at the head. Two empty strings compare equal,
  # so a reader that does not fail closed here reports "unchanged"… or worse,
  # "changed", depending on which side it lost.
  #
  # THE TEXT IS ASSERTED, NOT JUST THE EXIT CODE, and that is not pedantry:
  # measured while writing this file, deleting the fail-closed check left the
  # whole self-test green, because an empty version sorts below every real one
  # and the BACKWARDS arm reported the failure instead. A non-zero exit here
  # can be earned by an arm that has nothing to do with what this case claims
  # to cover.
  seed
  ( cd "$tmp/r" && rm VERSION && git add -A && git commit -qm "drop VERSION" )
  commit_in modules/ci-runner-host-pool/main.tf 'locals { a = 7 }'
  out="$( cd "$tmp/r" && PR_BASE_SHA="$(git rev-parse main)" \
      PR_HEAD_SHA="$(git rev-parse feature)" PR_LABELS="" bash "$SELF" 2>&1 )" && {
    echo "selftest FAILED: a missing VERSION must fail closed." >&2; return 1; }
  printf '%s' "$out" | grep -c 'VERSION at the head is missing or not tag-shaped' >/dev/null || {
    echo "selftest FAILED: an unreadable VERSION must be reported as unreadable.
  It went red for some other reason, which means this case asserts nothing." >&2
    return 1; }

  # CASE 9b — the SAME fail-closed on the other side. Added because mutation
  # testing found it unguarded: deleting the merge-base check alone left every
  # arm above green, since no fixture had ever presented a base without a
  # readable VERSION. One side covered is not the rule covered.
  seed
  (
    cd "$tmp/r"
    git checkout -q main
    rm VERSION
    git add -A
    git commit -qm "a base with no VERSION"
    git checkout -qb no-base-version
    printf 'locals { a = 8 }\n' >modules/ci-runner-host-pool/main.tf
    printf 'v5.10.0\n' >VERSION
    git add -A
    git commit -qm "module change plus a VERSION"
  )
  out="$( cd "$tmp/r" && PR_BASE_SHA="$(git rev-parse main)" \
      PR_HEAD_SHA="$(git rev-parse no-base-version)" PR_LABELS="" bash "$SELF" 2>&1 )" && {
    echo "selftest FAILED: an unreadable VERSION at the merge base must fail
  closed — there is nothing to compare against." >&2; return 1; }
  printf '%s' "$out" | grep -c 'VERSION at the merge base is missing' >/dev/null || {
    echo "selftest FAILED: the merge-base side must be reported by name." >&2
    return 1; }

  # CASE 10 — the base branch moved while the pull request was open. Somebody
  # else's module edit landed on main; this pull request changed only a doc.
  # Diffing against the base TIP would blame it for their commit.
  seed
  commit_in docs/guide.md 'a doc, changed on the branch'
  (
    cd "$tmp/r"
    git checkout -q main
    printf 'locals { a = 99 }\n' >modules/ci-runner-host-pool/main.tf
    printf 'v5.11.0\n' >VERSION
    git add -A
    git commit -qm "someone else's release"
    git checkout -q feature
  )
  run >/dev/null || {
    echo "selftest FAILED: a docs-only pull request must not be charged for a
  module change that landed on the base after it branched." >&2; return 1; }

  echo "selftest OK — fires on a released change with no bump (and names the"
  echo "numbers), on scripts/ as well as modules/, on a backwards VERSION, on an"
  echo "unreachable base, and on an unreadable VERSION at either end; quiet on a"
  echo "bump, on docs-only, under the exact escape label, and when the base moved."
}

if [ "$SELFTEST" -eq 1 ]; then
  selftest
  exit 0
fi

cd "$REPO"
check_repo
