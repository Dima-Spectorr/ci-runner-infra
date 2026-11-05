#!/usr/bin/env bash
# runner-version — keep the GitHub Actions runner baked into the host images
# inside GitHub's support window. Library of pure functions plus a small CLI;
# `.github/workflows/runner-version.yml` is the only caller that touches the
# network, and `runner-version.selftest.sh` is what proves every function here.
#
# WHY THIS EXISTS (#1676)
#
# The runner is baked with `--disableupdate`, so a host never updates itself.
# On 2026-11-05 GitHub deprecated v2.336.0, the version in image
# `ci-runner-host-gdeb7801`. Every slot registered, printed "Listening for
# Jobs", then exited about 3 s later with
#
#   Runner version v2.336.0 is deprecated and cannot receive messages.
#
# CI was down fleet-wide, and the re-registration loop used up the GitHub App
# installation's hourly API budget, so the outage first read as a rate limit.
# The version had first fallen behind 71 days earlier, when v2.337.0 shipped.
# Nothing compared the pin with GitHub's release list. This file does.
#
# THREE PINS, ONE VERSION
#
#   packer/ci-host-image.pkr.hcl       variable "runner_version" default
#   packer/ci-host-image-win.pkr.hcl   variable "runner_version" default
#   cloudbuild.yaml                    _RUNNER_VERSION substitution
#
# cloudbuild.yaml passes `-var runner_version=${_RUNNER_VERSION}`, so the
# substitution is the one a triggered build bakes. The packer defaults are what
# a direct `packer build` bakes. Bumping only some of them builds an image with
# the OLD runner (IntegrateIT#7704), so `rv_pins` refuses to answer when the
# three disagree and `rv_bump` writes all three or none.
#
# THE DEADLINE BELONGS TO THE OLDEST RELEASE THE PIN HAS MISSED
#
# GitHub says a runner with updates disabled must be updated within 30 days of a
# new release. It also deprecates old versions outright, which is what happened
# here. `/releases/latest` cannot answer "how long have we been behind": its
# date is the NEWEST release's, so every release resets the clock. The age that
# matters is that of the first release newer than the pin (IntegrateIT#6505).
#
# Tenancy-agnostic: no owner, project or customer literal. Callers pass paths,
# release lists and thresholds.

set -uo pipefail

# rv_valid <version> -- 0 when <version> is a plain X.Y.Z. Every version this
# file writes into a repository file or a pull request passes through here
# first: a release tag is text that GitHub serves and that someone else chose.
rv_valid() {
  case "${1:-}" in
    '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  [ "$(printf '%s' "$1" | tr -cd . | wc -c)" -eq 2 ]
}

# rv_packer_default <file> -- the default of variable "runner_version" in a
# packer template. The first `default =` INSIDE that block, never one from
# another variable; prints nothing if the block or its default is missing.
rv_packer_default() {
  awk '
    /^variable "runner_version" \{/ { inblk = 1; next }
    inblk && /^\}/ { exit }
    inblk && /^[[:space:]]*default[[:space:]]*=/ {
      line = $0
      sub(/^[^"]*"/, "", line); sub(/".*$/, "", line)
      print line; exit
    }
  ' "$1" 2>/dev/null
}

# rv_cloudbuild_pin <file> -- the _RUNNER_VERSION substitution in cloudbuild.yaml.
rv_cloudbuild_pin() {
  sed -n 's/^  _RUNNER_VERSION:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "$1" 2>/dev/null | head -n 1
}

# rv_pins <repo root> -- prints the one pinned version. Returns 1, with each pin
# on stderr, when any pin is missing, malformed or different from the others.
rv_pins() {
  local root="$1" l w c
  l=$(rv_packer_default "$root/packer/ci-host-image.pkr.hcl")
  w=$(rv_packer_default "$root/packer/ci-host-image-win.pkr.hcl")
  c=$(rv_cloudbuild_pin "$root/cloudbuild.yaml")
  if rv_valid "$l" && [ "$l" = "$w" ] && [ "$l" = "$c" ]; then
    printf '%s\n' "$l"
    return 0
  fi
  {
    echo "runner pins disagree or are unreadable:"
    echo "  packer/ci-host-image.pkr.hcl     runner_version default = '${l}'"
    echo "  packer/ci-host-image-win.pkr.hcl runner_version default = '${w}'"
    echo "  cloudbuild.yaml                  _RUNNER_VERSION        = '${c}'"
  } >&2
  return 1
}

# rv_older <a> <b> -- 0 when version <a> sorts strictly before <b>.
rv_older() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

# rv_decide <pin> <now epoch> <grace days>  (release list on stdin)
#
# stdin: one line per STABLE release, `published_at<TAB>version<TAB>assets`,
# where assets is 1 when both the Linux x64 tarball and the Windows x64 zip are
# attached, else 0. Order does not matter. Lines that do not parse are ignored.
#
# stdout: key=value lines --
#   target    the newest release with both assets; the version to bake
#   missed    the oldest release newer than <pin> ("" when none)
#   age_days  whole days since <missed> was published ("" when none)
#   verdict   current   the pin is the target (or newer: `ahead`)
#             behind    a newer release exists, younger than <grace days>
#             at-risk   the oldest missed release is <grace days> old or more
#             unknown   no release parsed, or <pin> is not a version
#
# Never fails on its input; a broken input is the `unknown` verdict, which the
# workflow turns red, because "could not tell" must not read as "fine".
rv_decide() {
  local pin="$1" now="$2" grace="$3" tab target="" missed="" missed_pub="" age=""
  local pub ver assets rows
  tab=$(printf '\t')
  rows=""
  while IFS="$tab" read -r pub ver assets; do
    ver="${ver#v}"
    rv_valid "$ver" || continue
    case "$pub" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;; *) continue ;; esac
    rows="${rows}${ver}${tab}${pub}${tab}${assets}"$'\n'
  done
  if [ -z "$rows" ] || ! rv_valid "$pin"; then
    printf 'target=\nmissed=\nage_days=\nverdict=unknown\n'
    return 0
  fi
  rows=$(printf '%s' "$rows" | sort -t "$tab" -k1,1V)
  while IFS="$tab" read -r ver pub assets; do
    [ "$assets" = 1 ] && target="$ver"
    if [ -z "$missed" ] && rv_older "$pin" "$ver"; then
      missed="$ver"
      missed_pub="$pub"
    fi
  done <<EOF
$rows
EOF
  if [ -n "$missed" ]; then
    local then_s
    if then_s=$(date -u -d "$missed_pub" +%s 2>/dev/null); then
      age=$(((now - then_s) / 86400))
      [ "$age" -ge 0 ] || age=0
    fi
  fi
  local verdict
  if [ -z "$missed" ]; then
    verdict=current
    [ -n "$target" ] && rv_older "$target" "$pin" && verdict=ahead
  elif [ -z "$age" ]; then
    verdict=unknown
  elif [ "$age" -ge "$grace" ]; then
    verdict=at-risk
  else
    verdict=behind
  fi
  printf 'target=%s\nmissed=%s\nage_days=%s\nverdict=%s\n' "$target" "$missed" "$age" "$verdict"
}

# rv_bump <repo root> <new version> -- rewrite all three pins to <new version>.
# Touches exactly the three pinned lines and nothing else (the self-test diffs
# the files to prove it). Writes through temp files and checks the result with
# rv_pins, so a pattern that stopped matching fails instead of silently bumping
# two of the three.
rv_bump() {
  local root="$1" new="$2" f tmp
  rv_valid "$new" || { echo "rv_bump: '$new' is not a version" >&2; return 1; }
  rv_pins "$root" >/dev/null || return 1
  for f in packer/ci-host-image.pkr.hcl packer/ci-host-image-win.pkr.hcl; do
    tmp="$root/$f.rv-tmp"
    awk -v new="$new" '
      /^variable "runner_version" \{/ { inblk = 1 }
      inblk && !done && /^[[:space:]]*default[[:space:]]*=/ {
        sub(/"[^"]*"/, "\"" new "\""); done = 1
      }
      inblk && /^\}/ { inblk = 0 }
      { print }
    ' "$root/$f" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$root/$f" || return 1
  done
  tmp="$root/cloudbuild.yaml.rv-tmp"
  sed "s/^\(  _RUNNER_VERSION:[[:space:]]*\"\{0,1\}\)[0-9.]*/\1$new/" "$root/cloudbuild.yaml" >"$tmp" ||
    { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$root/cloudbuild.yaml" || return 1
  [ "$(rv_pins "$root")" = "$new" ]
}

# rv_pr_title <old> <new> / rv_pr_title_version <title>
# The bump pull request's title, and the version read back out of it. The
# workflow dedupes on that version, so the two must stay inverses; the
# self-test proves they are.
rv_pr_title() { printf 'fix(image): bake runner %s (was %s)\n' "$2" "$1"; }
rv_pr_title_version() { printf '%s\n' "$1" | sed -n 's/^fix(image): bake runner \([0-9][0-9.]*\) (was .*$/\1/p'; }

# rv_pr_body <old> <new> <missed> <age days> -- the bump pull request's body.
# Says what merging does and what it does NOT do, because the second half is
# where 2026-11-05 happened: a merged bump changes no running host.
rv_pr_body() {
  local old="$1" new="$2" missed="$3" age="$4"
  cat <<EOF
Opened by \`runner-version.yml\`, the daily runner-version check.

The host images bake GitHub Actions runner **$old**. The newest release with both
the Linux and Windows archives attached is **$new**.${missed:+ The first release the pin missed, \`$missed\`, came out **$age day(s)** ago.}
Hosts run with \`--disableupdate\`, so they never update themselves. GitHub stops
sending jobs to a runner that has not been updated within 30 days of a release,
and it deprecates old versions outright (#1676). Either way, every slot
registers and then exits about 3 s later.

This PR changes three pins, one line each:

- \`packer/ci-host-image.pkr.hcl\`: \`runner_version\` default
- \`packer/ci-host-image-win.pkr.hcl\`: \`runner_version\` default
- \`cloudbuild.yaml\`: \`_RUNNER_VERSION\`

**Merging it changes no host.** It fires the image trigger, which builds
\`ci-runner-host-g<sha>\`. That image then has to be copied into each pool's
project and pinned in each consumer root; once a root applies, its controller
recycles the hosts onto the new image a few at a time. See
docs/applying-runner-infra.md, "Rolling a new runner version out". Until that is
done, the daily check keeps reporting each pool that is still behind.

If the next release ships before this merges, the same run moves this PR forward
instead of opening a second one.

Tier: direct
EOF
}

# rv_image_ref <image> -- which ci-runner-infra commit an image was built from.
# Accepts a bare name or a full `projects/<p>/global/images/<name>` path.
#   ci-runner-host-g<sha>       -> <sha>      (the trigger's g$SHORT_SHA name)
#   ci-runner-host-vX-Y-Z       -> vX.Y.Z     (a manual build named after a tag)
#   anything else (Windows contract versions included) -> nothing, return 1.
rv_image_ref() {
  local n="${1##*/}" v
  case "$n" in
    ci-runner-host-g*)
      v="${n#ci-runner-host-g}"
      case "$v" in '' | *[!0-9a-f]*) return 1 ;; esac
      [ "${#v}" -ge 7 ] || return 1
      printf '%s\n' "$v"
      ;;
    ci-runner-host-v*)
      v="${n#ci-runner-host-}"
      v="${v//-/.}"
      rv_valid "${v#v}" || return 1
      printf '%s\n' "$v"
      ;;
    *) return 1 ;;
  esac
}

# rv_tfvar <file> <name> -- the quoted value of `<name> = "..."` in a tfvars file.
rv_tfvar() {
  sed -n "s/^$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -n 1
}

# rv_retarget_tfvar <file> <name> <new image name> -- swap the image NAME at the
# end of `<name> = "projects/<p>/global/images/<old>"`, keeping the project path.
# Used by the consumer pin-bump PR; the copy must already exist in <p>.
rv_retarget_tfvar() {
  local f="$1" name="$2" img="$3" tmp
  case "$img" in '' | *[!a-z0-9-]*) echo "rv_retarget_tfvar: bad image name '$img'" >&2; return 1 ;; esac
  tmp="$f.rv-tmp"
  sed "s#^\(${name}[[:space:]]*=[[:space:]]*\"[^\"]*/images/\)[a-z0-9-]*\"#\1${img}\"#" "$f" >"$tmp" ||
    { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || return 1
  [ "$(rv_tfvar "$f" "$name")" != "" ] && [ "$(basename "$(rv_tfvar "$f" "$name")")" = "$img" ]
}

# --- CLI ----------------------------------------------------------------------
# Sourced by the self-test and the workflow; executed, it is a small CLI.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    pins) rv_pins "${1:-.}" ;;
    decide) rv_decide "$@" ;;
    bump) rv_bump "$@" ;;
    image-ref) rv_image_ref "$@" ;;
    *)
      echo "usage: $0 pins [root] | decide <pin> <now> <grace> <releases.tsv | bump <root> <ver> | image-ref <image>" >&2
      exit 2
      ;;
  esac
fi
