#!/usr/bin/env bash
# Self-test for runner-version.sh (#1676): the rules behind the daily
# runner-version check and the pull request it opens.
#
# WHY THIS TEST EXISTS.
#
# The bump PR is opened by a bot, on a schedule, against the three files that
# decide which runner every pool boots. Two of its failures are silent:
#
#   a bump that rewrites only some of the pins builds an image with the OLD
#   runner and still looks merged and green (IntegrateIT#7704);
#   a deadline computed from the NEWEST release instead of the oldest missed
#   one resets on every release, and reads "fine" until GitHub deprecates the
#   baked version (2026-11-05).
#
# So the PR's contents are proved against copies of the REAL files: after a
# bump, the diff is exactly three lines, one per pin, each carrying the new
# version and nothing else. Then each rule is broken on purpose, and the suite
# must notice.

# The mutations match the library's TEXT, in which `$l` and `$missed` are
# literal characters -- so the single quotes are the point.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
LIB="$HERE/runner-version.sh"

TOP="$(mktemp -d)"
trap 'rm -rf "$TOP"' EXIT

DAY=86400
NOW=$(date -u -d 2026-11-05T12:00:00Z +%s)

# A release list shaped like actions/runner's on 2026-11-05.
RELEASES="$(printf '%s\t%s\t%s\n' \
  2026-10-26T10:00:00Z 2.338.2 1 \
  2026-10-06T10:00:00Z 2.338.0 1 \
  2026-08-26T10:00:00Z 2.337.0 1 \
  2026-07-20T10:00:00Z 2.336.0 1)"

# check_all <runner-version.sh> -> one line per failure. A subshell: it sources
# the library, and a mutant's functions must not leak into the next call.
check_all() (
  lib="$1"
  fail() { printf '%s\n' "$1"; }
  # shellcheck source=scripts/ci/runner-version.sh
  . "$lib"
  d="$(mktemp -d "$TOP/c.XXXXXX")"
  mkdir -p "$d/repo/packer"
  cp "$ROOT/packer/ci-host-image.pkr.hcl" "$ROOT/packer/ci-host-image-win.pkr.hcl" "$d/repo/packer/"
  cp "$ROOT/cloudbuild.yaml" "$d/repo/"
  cp -R "$d/repo" "$d/orig"

  # --- 1. the three pins are read, and agree ------------------------------------
  pin=$(rv_pins "$d/repo" 2>/dev/null) || { fail "rv_pins refuses this repository's own pins"; exit 0; }
  rv_valid "$pin" || fail "rv_pins printed '$pin', which is not a version"

  # --- 2. the bump PR's contents: exactly three lines, one per pin --------------
  new=9.88.7
  [ "$pin" != "$new" ] || { fail "fixture version collides with the real pin"; exit 0; }
  if ! rv_bump "$d/repo" "$new" 2>/dev/null; then
    fail "rv_bump $new failed on copies of the real files"
  else
    [ "$(rv_pins "$d/repo" 2>/dev/null)" = "$new" ] || fail "after rv_bump the pins do not all read $new"
    for f in packer/ci-host-image.pkr.hcl packer/ci-host-image-win.pkr.hcl cloudbuild.yaml; do
      minus=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | grep -c '^-[^-]')
      plus=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | grep -c '^+[^+]')
      { [ "$minus" = 1 ] && [ "$plus" = 1 ]; } || fail "$f: the bump changed $minus/$plus lines, not exactly one"
      old_l=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | sed -n 's/^-\([^-].*\)$/\1/p')
      new_l=$(diff -U0 "$d/orig/$f" "$d/repo/$f" | sed -n 's/^+\([^+].*\)$/\1/p')
      # The changed line is the old one with ONLY the version replaced.
      { [ "${old_l//$pin/$new}" = "$new_l" ] && [ -n "$new_l" ]; } ||
        fail "$f: the changed line is not the pinned line with $pin -> $new ('$old_l' -> '$new_l')"
    done
    # The Linux template's OTHER variables' defaults are untouched (the first
    # `default =` in the file belongs to a different variable).
    for f in packer/ci-host-image.pkr.hcl packer/ci-host-image-win.pkr.hcl; do
      grep -n "$new" "$d/repo/$f" | grep -q 'default' || fail "$f: the new version is not on a default line"
    done
  fi

  # --- 3. disagreeing or broken pins refuse, and the bump writes none -----------
  cp -R "$d/orig" "$d/split"
  sed -i "s/^  _RUNNER_VERSION:.*/  _RUNNER_VERSION: 1.2.3/" "$d/split/cloudbuild.yaml"
  rv_pins "$d/split" >/dev/null 2>&1 && fail "rv_pins answered although cloudbuild.yaml disagrees with the packer defaults"
  cp -R "$d/split" "$d/split.before"
  rv_bump "$d/split" "$new" >/dev/null 2>&1 && fail "rv_bump bumped a repository whose pins disagree"
  diff -r "$d/split.before" "$d/split" >/dev/null || fail "a refused rv_bump still rewrote files"
  cp -R "$d/orig" "$d/bad"
  rv_bump "$d/bad" '2.0.0"; rm -rf /' >/dev/null 2>&1 && fail "rv_bump accepted a version that is not X.Y.Z"
  diff -r "$d/orig" "$d/bad" >/dev/null || fail "a refused version still rewrote files"

  for v in 2.338.2 10.0.1; do rv_valid "$v" || fail "rv_valid rejects '$v'"; done
  for v in '' 2.338 2.338.2.1 v2.338.2 2..3 .2.3 2.3. 2.3.x '2.3.4 '; do
    rv_valid "$v" && fail "rv_valid accepts '$v'"
  done

  # --- 4. title and body ---------------------------------------------------------
  t=$(rv_pr_title 2.336.0 2.338.2)
  [ "$(rv_pr_title_version "$t")" = 2.338.2 ] || fail "rv_pr_title_version does not invert rv_pr_title ('$t')"
  [ -z "$(rv_pr_title_version "fix(image): something else")" ] || fail "rv_pr_title_version reads a version from a foreign title"
  case "$t" in fix\(image\):*) ;; *) fail "the title is not a fix(image): conventional commit -- the release-please lane ignores it" ;; esac
  b=$(rv_pr_body 2.336.0 2.338.2 2.337.0 70)
  for want in packer/ci-host-image.pkr.hcl packer/ci-host-image-win.pkr.hcl cloudbuild.yaml \
    'Merging it changes no host' 'Rolling a new runner version out' 2.337.0 '70 day' 'Tier: direct'; do
    case "$b" in *"$want"*) ;; *) fail "the PR body does not say '$want'" ;; esac
  done

  # --- 5. the deadline belongs to the oldest missed release ----------------------
  dec() { printf '%s\n' "$RELEASES" | rv_decide "$1" "$2" 14; }
  expect() { # <pin> <now> <want lines...>
    local p="$1" n="$2" out w
    shift 2
    out=$(dec "$p" "$n")
    for w in "$@"; do
      printf '%s\n' "$out" | grep -qx "$w" || fail "rv_decide $p: want '$w', got: $(printf '%s' "$out" | tr '\n' ' ')"
    done
  }
  # The outage itself: 2.336.0 had missed 2.337.0 for 71 days.
  expect 2.336.0 "$NOW" target=2.338.2 missed=2.337.0 age_days=71 verdict=at-risk
  expect 2.338.2 "$NOW" target=2.338.2 missed= verdict=current
  # 2.338.0 missed 2.338.2 ten days ago: behind, not yet at risk.
  expect 2.338.0 "$NOW" missed=2.338.2 age_days=10 verdict=behind
  expect 2.338.0 $((NOW + 4 * DAY)) age_days=14 verdict=at-risk
  expect 2.339.0 "$NOW" verdict=ahead
  expect not-a-version "$NOW" verdict=unknown
  [ "$(printf 'garbage\n' | rv_decide 2.336.0 "$NOW" 14 | grep '^verdict=')" = verdict=unknown ] ||
    fail "an unparseable release list does not read as unknown"
  # A release whose Windows zip is not attached yet is missed, never the target.
  out=$(printf '%s\n%s\n' "$RELEASES" "$(printf '2026-11-04T10:00:00Z\t2.339.0\t0')" | rv_decide 2.338.2 "$NOW" 14)
  printf '%s\n' "$out" | grep -qx target=2.338.2 || fail "a release without both archives became the target"
  printf '%s\n' "$out" | grep -qx missed=2.339.0 || fail "a release without both archives does not count as missed"
  # Input order must not matter.
  out=$(printf '%s\n' "$RELEASES" | sort | rv_decide 2.336.0 "$NOW" 14 | grep -E '^(target|missed)=' | tr '\n' ' ')
  [ "$out" = "target=2.338.2 missed=2.337.0 " ] || fail "rv_decide depends on input order: $out"

  # --- 6. image name -> ci-runner-infra ref, and the consumer pin rewrite --------
  [ "$(rv_image_ref projects/p/global/images/ci-runner-host-gdeb7801)" = deb7801 ] || fail "rv_image_ref misreads a trigger image path"
  [ "$(rv_image_ref ci-runner-host-v5-110-0)" = v5.110.0 ] || fail "rv_image_ref misreads a tag image"
  for n in ci-runner-host-gXYZ1234 ci-runner-host-gabc ci-runner-host-v5-110 ci-runner-win-v3 ''; do
    rv_image_ref "$n" >/dev/null && fail "rv_image_ref accepts '$n'"
  done
  printf 'other = "x"\nhost_image = "projects/p-1/global/images/ci-runner-host-gdeb7801"\n' >"$d/t.tfvars"
  rv_retarget_tfvar "$d/t.tfvars" host_image ci-runner-host-g0123abc || fail "rv_retarget_tfvar failed"
  [ "$(rv_tfvar "$d/t.tfvars" host_image)" = projects/p-1/global/images/ci-runner-host-g0123abc ] ||
    fail "rv_retarget_tfvar did not keep the project path: $(rv_tfvar "$d/t.tfvars" host_image)"
  grep -qx 'other = "x"' "$d/t.tfvars" || fail "rv_retarget_tfvar touched another variable"
  rv_retarget_tfvar "$d/t.tfvars" host_image 'x"; evil' >/dev/null 2>&1 && fail "rv_retarget_tfvar accepted a bad image name"
  exit 0
)

failures=$(check_all "$LIB")
if [ -n "$failures" ]; then
  printf 'FAIL: %s\n' "$failures"
  exit 1
fi
echo "ok: runner-version rules hold on the real files"

# --- mutations: every rule above must be load-bearing ---------------------------
# mutate <name> <sed expression> -- apply to a copy of the library; the suite
# must report at least one failure, or the assertion guarding that rule is dead.
mrc=0
mutate() {
  local name="$1" expr="$2" m="$TOP/m.$RANDOM.sh"
  sed "$expr" "$LIB" >"$m"
  if cmp -s "$LIB" "$m"; then
    echo "FAIL: mutation '$name' did not change the library -- its pattern is stale"
    mrc=1
    return
  fi
  if [ -z "$(check_all "$m")" ]; then
    echo "FAIL: mutation '$name' survived"
    mrc=1
  fi
}
mutate "bump skips cloudbuild.yaml" 's/^  sed "s\/^\\(  _RUNNER_VERSION/  : sed "s\/^\\(  _RUNNER_VERSION/'
mutate "bump skips the Windows template" 's#for f in packer/ci-host-image.pkr.hcl packer/ci-host-image-win.pkr.hcl; do#for f in packer/ci-host-image.pkr.hcl; do#'
mutate "bump rewrites every default" 's/inblk \&\& !done \&\& \/\^/!done \&\& \/^/'
mutate "pins ignore cloudbuild.yaml" 's/\[ "\$l" = "\$w" \] \&\& \[ "\$l" = "\$c" \]/[ "$l" = "$w" ]/'
mutate "deadline from the newest release" 's/if \[ -z "\$missed" \] \&\& rv_older/if rv_older/'
mutate "target ignores missing archives" 's/\[ "\$assets" = 1 \] \&\& target=/target=/'
mutate "grace is exclusive" 's/\[ "\$age" -ge "\$grace" \]/[ "$age" -gt "$grace" ]/'
mutate "any text is a version" 's/^  \[ "\$(printf .%s. "\$1" | tr -cd . | wc -c)" -eq 2 \]$/  true/'
mutate "title and parser drift" 's/bake runner %s (was %s)/bake GitHub runner %s (was %s)/'
mutate "body forgets the rollout" 's/^\*\*Merging it changes no host\.\*\*/Merging it rebuilds the image./'
mutate "short sha accepted" 's/\[ "\${#v}" -ge 7 \] || return 1/:/'
[ "$mrc" = 0 ] && echo "ok: every mutation was caught"
exit "$mrc"
