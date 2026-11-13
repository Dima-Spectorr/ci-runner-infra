#!/usr/bin/env bash
# Self-test for `cloud-sdk-digest.sh` (#1614): proves both real module pins
# agree, the bump rewrites ONLY the two pinned lines, manifest verification
# hashes the body rather than trusting headers, and every rule fails under
# mutation.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
LIB="$HERE/cloud-sdk-digest.sh"

TOP="$(mktemp -d)"
trap 'rm -rf "$TOP"' EXIT

check_all() (
  lib="$1"
  fail() { printf '%s\n' "$1"; }
  # shellcheck source=scripts/ci/cloud-sdk-digest.sh
  . "$lib"
  d="$(mktemp -d "$TOP/c.XXXXXX")"
  mkdir -p "$d/repo/modules/ci-runner-apply-trigger" "$d/repo/modules/ci-runner-cache-warmer"
  cp "$ROOT/modules/ci-runner-apply-trigger/main.tf" "$d/repo/modules/ci-runner-apply-trigger/main.tf"
  cp "$ROOT/modules/ci-runner-cache-warmer/variables.tf" "$d/repo/modules/ci-runner-cache-warmer/variables.tf"
  cp -R "$d/repo" "$d/orig"

  # 1. Both pins in the real repository agree and are valid sha256 digests.
  pin=$(csd_pins "$d/repo" 2>/dev/null) || { fail "csd_pins rejected this repository's real pins"; exit 0; }
  csd_valid "$pin" || fail "csd_pins printed '$pin', which is not sha256:<64-hex>"

  # 2. Bump rewrites exactly one line in each file and nothing else.
  new="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  [ "$pin" != "$new" ] || new="sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
  if ! csd_bump "$d/repo" "$new" 2>/dev/null; then
    fail "csd_bump failed on copies of the real module files"
  else
    [ "$(csd_pins "$d/repo" 2>/dev/null)" = "$new" ] || fail "after csd_bump, csd_pins did not return $new"
    for f in modules/ci-runner-apply-trigger/main.tf modules/ci-runner-cache-warmer/variables.tf; do
      minus=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | grep -c '^-[^-]')
      plus=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | grep -c '^+[^+]')
      { [ "$minus" = 1 ] && [ "$plus" = 1 ]; } || fail "$f: csd_bump changed $minus/$plus lines, expected 1/1"
      old_l=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | sed -n 's/^-\([^-].*\)$/\1/p')
      new_l=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | sed -n 's/^+\([^+].*\)$/\1/p')
      { [ "${old_l//$pin/$new}" = "$new_l" ] && [ -n "$new_l" ]; } ||
        fail "$f: changed line did not simply swap $pin -> $new"
    done
  fi

  # 3. Disagreeing pins or invalid digests refuse and leave files untouched.
  cp -R "$d/orig" "$d/split"
  other="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$other" != "$pin" ] || other="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  sed -i "s|$pin|$other|" "$d/split/modules/ci-runner-apply-trigger/main.tf"
  csd_pins "$d/split" >/dev/null 2>&1 && fail "csd_pins succeeded when apply-trigger and cache-warmer disagreed"
  cp -R "$d/split" "$d/split.before"
  csd_bump "$d/split" "$new" >/dev/null 2>&1 && fail "csd_bump succeeded on disagreeing pins"
  diff -r "$d/split.before" "$d/split" >/dev/null || fail "refused csd_bump mutated files"

  for bad_d in '' 'slim' 'sha256:0123abcd' "sha256:$(printf 'a%.0s' {1..63})" "sha256:$(printf 'a%.0s' {1..65})" 'sha256:short' "sha256:$(printf 'A%.0s' {1..64})" 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg' "$new; evil"; do
    csd_valid "$bad_d" && fail "csd_valid accepted '$bad_d'"
  done
  cp -R "$d/orig" "$d/bad"
  csd_bump "$d/bad" 'sha256:not-hex' >/dev/null 2>&1 && fail "csd_bump accepted malformed digest"
  diff -r "$d/orig" "$d/bad" >/dev/null || fail "refused malformed digest mutated files"

  # 4. Manifest verification hashes body and checks Docker-Content-Digest (with CRLF).
  printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","manifests":[{"digest":"%s"}]}' "$new" >"$d/m.json"
  want_sha="sha256:$(sha256sum "$d/m.json" | awk '{print $1}')"
  printf 'HTTP/2 200\r\nDocker-Content-Digest: %s\r\n\r\n' "$want_sha" >"$d/h.ok"
  [ "$(csd_verify_manifest "$d/h.ok" "$d/m.json" 2>/dev/null)" = "$want_sha" ] ||
    fail "csd_verify_manifest rejected a valid manifest + CRLF header"
  printf 'HTTP/2 200\r\nDocker-Content-Digest: %s\r\n\r\n' "$other" >"$d/h.bad"
  csd_verify_manifest "$d/h.bad" "$d/m.json" >/dev/null 2>&1 &&
    fail "csd_verify_manifest accepted a mismatched Docker-Content-Digest header"
  printf '<html>error</html>' >"$d/html"
  csd_verify_manifest /dev/null "$d/html" >/dev/null 2>&1 &&
    fail "csd_verify_manifest accepted non-JSON body"
  printf '{"error":"not a manifest"}' >"$d/err.json"
  csd_verify_manifest /dev/null "$d/err.json" >/dev/null 2>&1 &&
    fail "csd_verify_manifest accepted JSON without manifest fields"

  # 5. Title & body round-trip and release-please prefix.
  t=$(csd_pr_title "$pin" "$new")
  [ "$(csd_pr_title_digest "$t")" = "$new" ] || fail "csd_pr_title_digest did not invert csd_pr_title ('$t')"
  [ -z "$(csd_pr_title_digest 'fix(deps): unrelated title')" ] || fail "csd_pr_title_digest matched an unrelated title"
  case "$t" in fix\(deps\):*) ;; *) fail "PR title does not use fix(deps): prefix" ;; esac
  b=$(csd_pr_body "$pin" "$new")
  for want in modules/ci-runner-apply-trigger/main.tf modules/ci-runner-cache-warmer/variables.tf "$pin" "$new" 'Tier: direct'; do
    case "$b" in *"$want"*) ;; *) fail "PR body missing '$want'" ;; esac
  done
  exit 0
)

failures=$(check_all "$LIB")
if [ -n "$failures" ]; then
  printf 'FAIL: %s\n' "$failures"
  exit 1
fi
echo "ok: cloud-sdk-digest rules hold on the real files"

mrc=0
mutate() {
  local name="$1" expr="$2" m="$TOP/m.$RANDOM.sh"
  sed "$expr" "$LIB" >"$m"
  if cmp -s "$LIB" "$m"; then
    echo "FAIL: mutation '$name' did not change $LIB"
    mrc=1
    return
  fi
  if [ -z "$(check_all "$m")" ]; then
    echo "FAIL: mutation '$name' survived"
    mrc=1
  fi
}

mutate "csd_pins ignores cache-warmer agreement" 's/\[ "\$a" = "\$w" \]/true/'
mutate "csd_bump skips cache-warmer rewrite" 's/mv -f "\$tmp_w" "\$root\/\$CSD_WARMER_FILE"/rm -f "$tmp_w"/'
mutate "csd_bump rewrites every default in variables.tf" 's/inblk && !done/!done/'
mutate "csd_valid accepts short hex" 's/\[ "\${#hex}" -eq 64 \]/true/'
mutate "csd_verify_manifest ignores mismatched header" 's/\[ "\$header_digest" != "\$computed" \]/false/'
mutate "title and parser drift" 's/pin cloud-sdk:slim to %s/bump cloud-sdk:slim to %s/'
mutate "PR title loses fix(deps): prefix" 's/fix(deps): pin/chore(deps): pin/'

[ "$mrc" = 0 ] && echo "ok: every cloud-sdk-digest mutation was caught"
exit "$mrc"
