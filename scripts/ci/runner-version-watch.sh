#!/usr/bin/env bash
# runner-version-watch — the network half of `runner-version.yml`. The rules
# live in runner-version.sh, as pure functions with a self-test; this file only
# reads GitHub, applies those rules, and writes the result.
#
# What one run does, in order:
#
#   1. DETECT   read the three pins in this checkout and actions/runner's stable
#               releases, and decide.
#   2. BUMP     when a newer release with both the Linux and Windows archives
#               exists, make sure exactly ONE pull request bumps all three pins
#               to it, on the fixed branch $RV_BRANCH. An open one for an older
#               version is moved forward in place, never duplicated.
#   3. FLEET    for each consumer root in fleet/image-pins.tsv, read the image it
#               pins, work out which ci-runner-infra commit built it, read the
#               runner version pinned at that commit, and decide again. This is
#               the part that would have caught 2026-11-05: the repository can be
#               current while every pool still boots an image that is not.
#
# Exit status: 0 when nothing is at risk, 1 when any pin (this repository's or a
# pool's) has been behind for RV_GRACE_DAYS or more, or could not be judged. The
# report goes to stdout and to $RV_REPORT for the workflow to post.
#
# Environment:
#   GH_TOKEN        App installation token: reads the consumer roots, pushes the
#                   bump branch, opens the pull request.
#   RV_REPO         owner/name of this repository.
#   RV_BASE         its default branch (the bump PR's base).
#   RV_GRACE_DAYS   days behind before a pin is "at risk"; default 14, half of
#                   GitHub's 30-day update window.
#   RV_DRY_RUN      1: decide and report, open nothing.
#   RV_REPORT       report file; default runner-version-report.txt.

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
# shellcheck source=scripts/ci/runner-version.sh
. "$HERE/runner-version.sh"

: "${RV_REPO:?RV_REPO is required}"
RV_BASE="${RV_BASE:-main}"
RV_GRACE_DAYS="${RV_GRACE_DAYS:-14}"
RV_DRY_RUN="${RV_DRY_RUN:-0}"
RV_REPORT="${RV_REPORT:-runner-version-report.txt}"
RV_MODE="${1:-all}"
case "$RV_MODE" in repo | fleet | all) ;; *) echo "usage: $0 [repo|fleet|all]" >&2; exit 2 ;; esac
RV_BRANCH="automation/runner-version"
OWNER="${RV_REPO%%/*}"
NOW=$(date -u +%s)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

: >"$RV_REPORT"
say() { printf '%s\n' "$*" | tee -a "$RV_REPORT"; }
rc=0

# --- 1. detect -----------------------------------------------------------------

if ! pin=$(rv_pins "$ROOT" 2>"$WORK/pins.err"); then
  say "fail: this repository's runner pins are unreadable or disagree"
  sed 's/^/  /' "$WORK/pins.err" | tee -a "$RV_REPORT"
  exit 1
fi

# Every stable release, with a flag for whether BOTH archives the images
# download are attached. A release whose Windows zip is still uploading is not
# a target yet; the next run picks it up. (The $v is jq's, not the shell's.)
# shellcheck disable=SC2016
if ! gh api --paginate 'repos/actions/runner/releases?per_page=100' --jq '
    .[] | select(.draft | not) | select(.prerelease | not)
    | (.tag_name | ltrimstr("v")) as $v
    | [ .published_at, $v,
        (if ([.assets[].name] | index("actions-runner-linux-x64-\($v).tar.gz")) != null
            and ([.assets[].name] | index("actions-runner-win-x64-\($v).zip")) != null
         then "1" else "0" end) ] | @tsv' >"$WORK/releases.tsv" 2>"$WORK/releases.err"; then
  say "fail: could not read actions/runner releases: $(head -c 300 "$WORK/releases.err")"
  exit 1
fi

decide() { # <pin> -> sets D_target D_missed D_age D_verdict
  local out
  out=$(rv_decide "$1" "$NOW" "$RV_GRACE_DAYS" <"$WORK/releases.tsv")
  D_target=$(printf '%s\n' "$out" | sed -n 's/^target=//p')
  D_missed=$(printf '%s\n' "$out" | sed -n 's/^missed=//p')
  D_age=$(printf '%s\n' "$out" | sed -n 's/^age_days=//p')
  D_verdict=$(printf '%s\n' "$out" | sed -n 's/^verdict=//p')
}

decide "$pin"
repo_target="$D_target"
if [ "$RV_MODE" != fleet ]; then
say "repository pin: runner $pin -- $D_verdict${D_missed:+ (first missed $D_missed, ${D_age} day(s) ago)}; newest bakeable release: ${repo_target:-none}"
case "$D_verdict" in
  at-risk) say "fail: this repository has pinned $pin for ${D_age} day(s) past $D_missed -- merge the bump pull request"; rc=1 ;;
  unknown) say "fail: could not judge this repository's pin"; rc=1 ;;
esac

# --- 2. bump -------------------------------------------------------------------

ensure_bump_pr() { # <target> <missed> <age>
  local target="$1" missed="$2" age="$3" open num title base out
  rv_valid "$target" || return 1
  open=$(gh api "repos/$RV_REPO/pulls?state=open&head=$OWNER:$RV_BRANCH&per_page=10" \
    --jq '.[0] // empty | [.number, .title] | @tsv') || { say "fail: could not list open pull requests"; return 1; }
  num="${open%%$'\t'*}"
  title="${open#*$'\t'}"
  if [ -n "$open" ] && [ "$(rv_pr_title_version "$title")" = "$target" ]; then
    say "bump: #$num already bakes $target -- nothing to do"
    return 0
  fi
  if [ "$RV_DRY_RUN" = 1 ]; then
    say "bump: would ${num:+move #$num forward and }bake $target (dry run)"
    return 0
  fi

  # The commit is built from THIS checkout, so its parent must be this
  # checkout's commit, not whatever the base has moved to since.
  base=$(git -C "$ROOT" rev-parse HEAD) || return 1
  cp -R "$ROOT/packer" "$WORK/" && cp "$ROOT/cloudbuild.yaml" "$WORK/" || return 1
  rv_bump "$WORK" "$target" || { say "fail: rv_bump could not rewrite the pins to $target"; return 1; }

  # Point the branch at the checkout's commit: create it, or force it back if it
  # is left over from an earlier bump.
  if ! gh api -X POST "repos/$RV_REPO/git/refs" -f "ref=refs/heads/$RV_BRANCH" -f "sha=$base" >/dev/null 2>&1; then
    gh api -X PATCH "repos/$RV_REPO/git/refs/heads/$RV_BRANCH" -f "sha=$base" -F force=true >/dev/null ||
      { say "fail: could not point $RV_BRANCH at $base"; return 1; }
  fi

  # createCommitOnBranch, not a git push: GitHub signs the commit, and the
  # expected-head check makes a concurrent run fail instead of racing.
  jq -n --arg repo "$RV_REPO" --arg branch "$RV_BRANCH" --arg head "$base" \
    --arg headline "$(rv_pr_title "$pin" "$target")" \
    --arg l "$(base64 -w0 "$WORK/packer/ci-host-image.pkr.hcl")" \
    --arg w "$(base64 -w0 "$WORK/packer/ci-host-image-win.pkr.hcl")" \
    --arg c "$(base64 -w0 "$WORK/cloudbuild.yaml")" '{
      query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
      variables: { input: {
        branch: { repositoryNameWithOwner: $repo, branchName: $branch },
        expectedHeadOid: $head,
        message: { headline: $headline },
        fileChanges: { additions: [
          { path: "packer/ci-host-image.pkr.hcl", contents: $l },
          { path: "packer/ci-host-image-win.pkr.hcl", contents: $w },
          { path: "cloudbuild.yaml", contents: $c } ] } } } }' >"$WORK/commit.json"
  if ! out=$(gh api graphql --input "$WORK/commit.json" --jq '.data.createCommitOnBranch.commit.oid' 2>&1) || [ -z "$out" ]; then
    say "fail: could not commit the bump to $RV_BRANCH: $(printf '%s' "$out" | head -c 300)"
    return 1
  fi

  rv_pr_body "$pin" "$target" "$missed" "$age" >"$WORK/body.md"
  if [ -n "$open" ]; then
    gh api -X PATCH "repos/$RV_REPO/pulls/$num" -f "title=$(rv_pr_title "$pin" "$target")" \
      -F "body=@$WORK/body.md" >/dev/null || { say "fail: could not retitle #$num"; return 1; }
    say "bump: moved #$num forward to $target"
  else
    num=$(gh api -X POST "repos/$RV_REPO/pulls" -f "title=$(rv_pr_title "$pin" "$target")" \
      -f "head=$RV_BRANCH" -f "base=$RV_BASE" -F "body=@$WORK/body.md" --jq .number) ||
      { say "fail: could not open the bump pull request"; return 1; }
    say "bump: opened #$num to bake $target"
  fi
}

if [ -n "$repo_target" ] && rv_older "$pin" "$repo_target"; then
  ensure_bump_pr "$repo_target" "$D_missed" "$D_age" || rc=1
fi
fi # repo
[ "$RV_MODE" != repo ] || exit "$rc"

# --- 3. fleet ------------------------------------------------------------------

# file_at <owner/repo> <ref> <path> -> the file's text on stdout
file_at() {
  gh api "repos/$1/contents/$3?ref=$2" --jq .content 2>/dev/null | base64 -d 2>/dev/null
}

manifest="$ROOT/fleet/image-pins.tsv"
while IFS=$'\t' read -r repo branch path var; do
  case "$repo" in '' | '#'*) continue ;; esac
  label="$repo:$path $var"
  if ! file_at "$OWNER/$repo" "$branch" "$path" >"$WORK/tfvars" || [ ! -s "$WORK/tfvars" ]; then
    say "fail: $label -- could not read the root"
    rc=1
    continue
  fi
  img=$(rv_tfvar "$WORK/tfvars" "$var")
  if [ -z "$img" ]; then
    say "fail: $label -- the root sets no $var"
    rc=1
    continue
  fi
  # A name that does not resolve to a commit of this repository (a hand-built
  # `-vX-Y-Z` whose tag was never pushed, say) is reported, not failed: the
  # check cannot judge it, and a red that nobody can clear by fixing a pool
  # trains people to ignore the red that matters. Repinning the root to a
  # `ci-runner-host-g<sha>` build makes it judgeable.
  baked=""
  if ref=$(rv_image_ref "$img"); then
    file_at "$RV_REPO" "$ref" cloudbuild.yaml >"$WORK/cb.yaml"
    baked=$(rv_cloudbuild_pin "$WORK/cb.yaml")
    if ! rv_valid "$baked"; then
      # Older trees had no substitution; the packer default was the pin.
      file_at "$RV_REPO" "$ref" packer/ci-host-image.pkr.hcl >"$WORK/l.pkr.hcl"
      baked=$(rv_packer_default "$WORK/l.pkr.hcl")
    fi
  fi
  if ! rv_valid "$baked"; then
    say "warn: $label: ${img##*/} -- cannot tell which runner it bakes (no ci-runner-infra commit or tag by that name); repin to a ci-runner-host-g<sha> build"
    continue
  fi
  decide "$baked"
  line="$label: ${img##*/} bakes runner ${baked:-?} -- $D_verdict${D_missed:+ (first missed $D_missed, ${D_age} day(s) ago)}"
  case "$D_verdict" in
    at-risk | unknown)
      say "fail: $line"
      say "  next: copy the newest image into this root's project and bump $var -- docs/applying-runner-infra.md, 'Rolling a new runner version out'"
      rc=1
      ;;
    behind)
      say "warn: $line"
      rv_older "$baked" "$pin" && say "  next: an image with runner $pin exists or is building -- propagate it (scripts/ci/propagate-host-image.sh)"
      ;;
    *) say "ok: $line" ;;
  esac
done <"$manifest"

exit "$rc"
