#!/usr/bin/env bash
# cloud-sdk-digest-watch — network caller for `.github/workflows/cloud-sdk-digest.yml` (#1614).
#
# 1. Reads the two `cloud-sdk` digest pins in this checkout via `csd_pins`.
# 2. Fetches the current manifest of `gcr.io/google.com/cloudsdktool/cloud-sdk:slim`
#    over anonymous Docker Registry HTTP v2 (with bounded timeouts) and verifies
#    its sha256 digest matches the downloaded bytes (`csd_verify_manifest`).
# 3. When upstream differs from the pinned digest, keeps ONE signed pull request
#    open on `automation/cloud-sdk-digest` via GitHub's GraphQL `createCommitOnBranch`.
# 4. Exits 0 when current or when a fresh bump PR (< CSD_GRACE_DAYS old) is open;
#    exits 1 when pins disagree, upstream cannot be verified, PR creation fails,
#    or an open bump PR has sat unmerged for CSD_GRACE_DAYS or longer.

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
# shellcheck source=scripts/ci/cloud-sdk-digest.sh
. "$HERE/cloud-sdk-digest.sh"

: "${CSD_REPO:?CSD_REPO is required}"
CSD_BASE="${CSD_BASE:-main}"
CSD_GRACE_DAYS="${CSD_GRACE_DAYS:-14}"
CSD_DRY_RUN="${CSD_DRY_RUN:-0}"
CSD_REPORT="${CSD_REPORT:-cloud-sdk-digest-report.txt}"
CSD_MANIFEST_URL="${CSD_MANIFEST_URL:-https://gcr.io/v2/google.com/cloudsdktool/cloud-sdk/manifests/slim}"
CSD_BRANCH="automation/cloud-sdk-digest"
OWNER="${CSD_REPO%%/*}"
NOW=$(date -u +%s)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

: >"$CSD_REPORT"
say() { printf '%s\n' "$*" | tee -a "$CSD_REPORT"; }

if ! pin=$(csd_pins "$ROOT" 2>"$WORK/pins.err"); then
  say "fail: this repository's cloud-sdk digest pins are unreadable or disagree"
  sed 's/^/  /' "$WORK/pins.err" | tee -a "$CSD_REPORT"
  exit 1
fi

ACCEPT_HDR="Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"
if ! curl -fsSL --connect-timeout 10 --max-time 30 \
  -D "$WORK/headers.txt" \
  -H "$ACCEPT_HDR" \
  "$CSD_MANIFEST_URL" \
  -o "$WORK/manifest.json" 2>"$WORK/curl.err"; then
  say "fail: could not fetch cloud-sdk:slim manifest: $(tr '\n' ' ' <"$WORK/curl.err" | cut -c1-300)"
  exit 1
fi

if ! target=$(csd_verify_manifest "$WORK/headers.txt" "$WORK/manifest.json" 2>"$WORK/verify.err"); then
  say "fail: could not verify cloud-sdk:slim manifest digest: $(tr '\n' ' ' <"$WORK/verify.err" | cut -c1-300)"
  exit 1
fi

if [ "$pin" = "$target" ]; then
  say "ok: cloud-sdk digest pin is current ($pin)"
  exit 0
fi

say "behind: repository pins $pin; upstream cloud-sdk:slim is $target"

open=$(gh api "repos/$CSD_REPO/pulls?state=open&head=$OWNER:$CSD_BRANCH&per_page=10" \
  --jq '.[0] // empty | [.number, .created_at, .title] | @tsv' 2>"$WORK/pr.err") || {
  say "fail: could not list open pull requests: $(tr '\n' ' ' <"$WORK/pr.err" | cut -c1-300)"
  exit 1
}

num=""
created_at=""
title=""
if [ -n "$open" ]; then
  IFS=$'\t' read -r num created_at title <<EOF
$open
EOF
fi

check_pr_age() {
  local created="$1" pr_num="$2" created_s age_days
  [ -n "$created" ] || return 0
  if created_s=$(date -u -d "$created" +%s 2>/dev/null); then
    age_days=$(((NOW - created_s) / 86400))
    if [ "$age_days" -ge "$CSD_GRACE_DAYS" ]; then
      say "fail: bump PR #$pr_num has been open for ${age_days} day(s) (grace ${CSD_GRACE_DAYS}d) -- review and merge it"
      return 1
    fi
  fi
  return 0
}

if [ -n "$open" ] && [ "$(csd_pr_title_digest "$title")" = "$target" ]; then
  say "bump: #$num already targets $target -- nothing to rewrite"
  check_pr_age "$created_at" "$num" || exit 1
  exit 0
fi

if [ "$CSD_DRY_RUN" = 1 ]; then
  say "bump: would ${num:+move #$num forward and }pin $target (dry run)"
  check_pr_age "$created_at" "${num:-dry-run}" || exit 1
  exit 0
fi

base=$(git -C "$ROOT" rev-parse HEAD) || { say "fail: git rev-parse HEAD failed"; exit 1; }
mkdir -p "$WORK/repo/modules/ci-runner-apply-trigger" "$WORK/repo/modules/ci-runner-cache-warmer"
cp "$ROOT/$CSD_APPLY_FILE" "$WORK/repo/$CSD_APPLY_FILE" || exit 1
cp "$ROOT/$CSD_WARMER_FILE" "$WORK/repo/$CSD_WARMER_FILE" || exit 1
csd_bump "$WORK/repo" "$target" || { say "fail: csd_bump could not rewrite pins to $target"; exit 1; }

if ! gh api -X POST "repos/$CSD_REPO/git/refs" -f "ref=refs/heads/$CSD_BRANCH" -f "sha=$base" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$CSD_REPO/git/refs/heads/$CSD_BRANCH" -f "sha=$base" -F force=true >/dev/null || {
    say "fail: could not point $CSD_BRANCH at $base"
    exit 1
  }
fi

# shellcheck disable=SC2016
jq -n --arg repo "$CSD_REPO" --arg branch "$CSD_BRANCH" --arg head "$base" \
  --arg headline "$(csd_pr_title "$pin" "$target")" \
  --arg apply_path "$CSD_APPLY_FILE" \
  --arg warmer_path "$CSD_WARMER_FILE" \
  --arg a "$(base64 -w0 "$WORK/repo/$CSD_APPLY_FILE")" \
  --arg w "$(base64 -w0 "$WORK/repo/$CSD_WARMER_FILE")" '{
    query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
    variables: { input: {
      branch: { repositoryNameWithOwner: $repo, branchName: $branch },
      expectedHeadOid: $head,
      message: { headline: $headline },
      fileChanges: { additions: [
        { path: $apply_path, contents: $a },
        { path: $warmer_path, contents: $w } ] } } } }' >"$WORK/commit.json"

if ! out=$(gh api graphql --input "$WORK/commit.json" --jq '.data.createCommitOnBranch.commit.oid' 2>&1) || [ -z "$out" ]; then
  say "fail: could not commit bump to $CSD_BRANCH: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  exit 1
fi

csd_pr_body "$pin" "$target" >"$WORK/body.md"
if [ -n "$open" ]; then
  gh api -X PATCH "repos/$CSD_REPO/pulls/$num" -f "title=$(csd_pr_title "$pin" "$target")" \
    -F "body=@$WORK/body.md" >/dev/null || { say "fail: could not update #$num"; exit 1; }
  say "bump: moved #$num forward to $target"
  check_pr_age "$created_at" "$num" || exit 1
else
  num=$(gh api -X POST "repos/$CSD_REPO/pulls" -f "title=$(csd_pr_title "$pin" "$target")" \
    -f "head=$CSD_BRANCH" -f "base=$CSD_BASE" -F "body=@$WORK/body.md" --jq .number) || {
    say "fail: could not open bump pull request"
    exit 1
  }
  say "bump: opened #$num to pin $target"
fi
