#!/usr/bin/env bash
# ci-runner-infra — find every version a repository DECLARES, ask
# support-window-decision.sh whether it is still supported, and write the issue
# body. The verdict lives entirely in that rule; nothing here decides anything.
#
# WHY THE SPLIT
#
# This file reads a repository and a third-party feed — two things a self-test
# cannot pin. The rule it calls reads neither. Keeping the judgement on the
# other side of that line is what makes the judgement testable, and it is the
# same split `lane-decision.sh` and its callers already use here.
#
# WHAT "EVERYTHING IN THE LOCKFILES" HONESTLY MEANS
#
# Support lifetimes are published for runtimes, base images and major
# frameworks — 464 products on endoflife.date at the time of writing. They are
# NOT published for the several thousand transitive libraries in a lockfile,
# and no amount of scanning invents them.
#
# So the report has two halves, and conflating them is how a tool starts lying:
#
#   * A declared runtime, base image or tracked framework with no lifetime data
#     is a FINDING (SUP4). There are a handful of these and silence about one is
#     dangerous.
#   * A library no lifetime feed tracks is NOT a finding — it is counted, by
#     name, under "not covered". Reporting a SUP4 for each would bury the four
#     that matter under two thousand that do not, and that report gets muted
#     within a week. Counting them is what stops the report from claiming a
#     completeness it does not have.
#
# Usage:
#   scan-support-windows.sh [--repo-root DIR] [--today YYYY-MM-DD]
#                           [--window DAYS] [--base-ref REF]
#                           [--cache DIR] [--out FILE] [--offline]
#
# Exit status is 0 whenever the scan RAN. Findings are the output, not the exit
# code: this reports through an issue, and a red check for a Node release that
# happened overnight would block pull requests that did not cause it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./support-window-decision.sh
source "$HERE/support-window-decision.sh"

REPO_ROOT="."
TODAY=""
WINDOW=180
BASE_REF=""
CACHE=""
OUT=""
OFFLINE=0
FEED_BASE="${SUPPORT_FEED_BASE:-https://endoflife.date/api}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --today)     TODAY="$2"; shift 2 ;;
    --window)    WINDOW="$2"; shift 2 ;;
    --base-ref)  BASE_REF="$2"; shift 2 ;;
    --cache)     CACHE="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --offline)   OFFLINE=1; shift ;;
    *) printf 'scan-support-windows: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$TODAY" ] || TODAY="$(date -u +%Y-%m-%d)"
[ -n "$CACHE" ] || CACHE="$(mktemp -d)"
mkdir -p "$CACHE"

# --- which declaration maps to which upstream product ------------------------
#
# A table, not a chain of `if`s, because the fleet's next language arrives as a
# row here rather than as an edit to the logic. The left side is what appears in
# a repository; the right side is the endoflife.date product identifier.
#
# An image or package with no row is NOT scanned — see "not covered" above.
product_for_image() { # <image-name>
  case "$1" in
    node) echo nodejs ;;
    python) echo python ;;
    golang|go) echo go ;;
    postgres) echo postgresql ;;
    redis) echo redis ;;
    mongo) echo mongodb ;;
    nginx) echo nginx ;;
    ubuntu) echo ubuntu ;;
    debian) echo debian ;;
    ruby) echo ruby ;;
    php) echo php ;;
    *) return 1 ;;
  esac
}

product_for_package() { # <package-name>
  case "$1" in
    react|react-dom) echo react ;;
    next) echo nextjs ;;
    vue) echo vue ;;
    @angular/core) echo angular ;;
    django|Django) echo django ;;
    *) return 1 ;;
  esac
}

# --- reading a version out of whatever wrote it ------------------------------
#
# `^18.2.0`, `>=20`, `v22.1`, `18.x`, `node:24-bookworm` and `1.22` are all the
# same statement in six notations. The cycle is what the feed keys on: the major
# for most products, major.minor for Go and Python, whose release lines are
# numbered that way.
cycle_of() { # <product> <raw-version> — echoes the cycle, or returns 1
  local product="$1" raw="$2" v

  # Strip range operators, leading v, and any pre-release or image suffix.
  v="${raw#"${raw%%[!^~>=< v]*}"}"
  v="${v%%[-+]*}"
  v="${v//x/0}"
  v="${v//\*/0}"
  case "$v" in
    [0-9]*) ;;
    *) return 1 ;;
  esac

  case "$product" in
    go|python|ubuntu|debian)
      # 1.22.3 -> 1.22 ; 1.22 -> 1.22 ; 3 -> 3 (incomplete, but never wrong).
      # Ubuntu's release lines are 24.04, not 24 — a major-only cycle matches
      # nothing in the feed and would silently report the host OS undecided.
      case "$v" in
        *.*) echo "${v%%.*}.$(x="${v#*.}"; echo "${x%%.*}")" ;;
        *) echo "$v" ;;
      esac
      ;;
    *) echo "${v%%.*}" ;;
  esac
}

# --- the inventory -----------------------------------------------------------
#
# Emits `product<TAB>cycle<TAB>source-file<TAB>declaration-text`. Every source
# here is a place a version is CHOSEN, which is why the list is short and why
# each entry is worth a finding.
INVENTORY="$CACHE/inventory.tsv"
: >"$INVENTORY"

emit() { # <product> <raw-version> <file> <text>
  local cycle
  cycle="$(cycle_of "$1" "$2")" || return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "$cycle" "$3" "$4" >>"$INVENTORY"
}

scan_inventory() {
  local f line raw

  # `.nvmrc` / `.node-version` — one line, the whole file.
  for f in .nvmrc .node-version; do
    [ -f "$REPO_ROOT/$f" ] || continue
    line="$(head -n1 "$REPO_ROOT/$f" | tr -d '[:space:]')"
    [ -n "$line" ] && emit nodejs "$line" "$f" "$line"
  done

  if [ -f "$REPO_ROOT/.python-version" ]; then
    line="$(head -n1 "$REPO_ROOT/.python-version" | tr -d '[:space:]')"
    [ -n "$line" ] && emit python "$line" .python-version "$line"
  fi

  # `go.mod` — the `go` directive is the language version the module targets.
  while IFS= read -r f; do
    line="$(grep -m1 -E '^go[[:space:]]+[0-9]' "$f" 2>/dev/null | awk '{print $2}')"
    [ -n "$line" ] && emit go "$line" "${f#"$REPO_ROOT"/}" "go $line"
  done < <(find "$REPO_ROOT" -name go.mod -not -path '*/vendor/*' 2>/dev/null)

  # Workflow `setup-*` steps — where CI's own toolchain is chosen, and the one
  # place a repository can be on a dead runtime without any manifest saying so.
  while IFS= read -r f; do
    while IFS= read -r line; do
      case "$line" in
        *node-version*) emit nodejs "$(decl_value "$line")" "${f#"$REPO_ROOT"/}" "$(trim "$line")" ;;
        *python-version*) emit python "$(decl_value "$line")" "${f#"$REPO_ROOT"/}" "$(trim "$line")" ;;
        *go-version*) emit go "$(decl_value "$line")" "${f#"$REPO_ROOT"/}" "$(trim "$line")" ;;
      esac
    done < <(grep -hE '^[[:space:]]*(node|python|go)-version:' "$f" 2>/dev/null)
  done < <(find "$REPO_ROOT/.github/workflows" -name '*.yml' -o -name '*.yaml' 2>/dev/null)

  # `FROM image:tag` — a base image is a runtime declaration wearing a hat.
  #
  # The image reference is NOT simply `$2`. `FROM --platform=linux/amd64
  # node:20-bookworm AS build` is ordinary Dockerfile syntax, and both halves of
  # the naive reading fail on it: the token after `FROM` is the flag, so a grep
  # demanding a colon there never matches the line at all, and the whole
  # declaration is skipped without a word. A base image that is silently not
  # scanned is a clean report about a version nobody read — the exact failure
  # this gate exists to end. So: match any `FROM`, then take the first token
  # that is not a flag, and let the missing colon be the only thing that
  # disqualifies a line.
  while IFS= read -r f; do
    while IFS= read -r line; do
      local ref image tag prod
      ref="$(printf '%s\n' "$line" |
             awk '{ for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; exit } }')"
      [ -n "$ref" ] || continue
      ref="${ref##*/}"
      image="${ref%%:*}"
      tag="${ref#*:}"
      # No tag is no declaration: `FROM node` and `FROM node:latest` both name a
      # version that is whatever the registry served that day.
      [ "$tag" = "$ref" ] && continue
      prod="$(product_for_image "$image")" || continue
      # The RAW line, not a reconstruction of it. "Did this pull request choose
      # this?" is answered by matching the declaration against the diff, and a
      # rebuilt `FROM node:20` never appears in a diff that added
      # `FROM --platform=... node:20 AS build`.
      emit "$prod" "$tag" "${f#"$REPO_ROOT"/}" "$(trim "$line")"
    done < <(grep -hiE '^[[:space:]]*FROM[[:space:]]' "$f" 2>/dev/null)
  done < <(find "$REPO_ROOT" -iname 'Dockerfile*' -not -path '*/node_modules/*' 2>/dev/null)

  # The golden image's own baked versions.
  #
  # This is the declaration with the widest blast radius and the least
  # visibility: no application manifest mentions it, no Dependabot ecosystem
  # covers it, and it is chosen once in a Packer variable and then inherited by
  # every host in the fleet until someone edits that line. `node_major` was 22
  # when this scan was written — a line whose active support had ended ten
  # months earlier. An image that ages quietly is the whole complaint.
  #
  # A repository that wants a major the image does not bake still gets it:
  # `actions/setup-node` prepends its own toolchain to PATH, and the per-slot
  # tool cache in host-startup.sh is left to the setup actions on purpose. The
  # baked version is a HOST BASELINE, so what matters is that the baseline stays
  # supported, not that it is the newest.
  while IFS= read -r f; do
    # awk over the whole block, not `grep -A<n>`: a multi-line `description`
    # heredoc sits between the variable and its `default`, so any fixed context
    # window either misses the value or reads the next variable's.
    # The RAW line is kept beside the value, because "did this pull request
    # choose this?" can only be asked about the line itself. Asking it about a
    # description of the line is what shipped broken: the evidence text used to
    # be the literal words `node_major default`, this scanner's own source
    # contains those words, and so the pull request that ADDED the scanner was
    # told it had just adopted the golden image's node 22.
    raw="$(awk '/^variable "node_major"/{inblock=1} inblock && /^[[:space:]]*default/{
              print; exit} inblock && /^}/{exit}' "$f" 2>/dev/null)"
    line="$(printf '%s' "$raw" | tr -cd '0-9.')"
    [ -n "$line" ] && emit nodejs "$line" "${f#"$REPO_ROOT"/}" "$(trim "$raw")"
    # `ubuntu-2404-lts-amd64` — the host OS, whose end of life ends the security
    # updates for everything else baked on top of it.
    raw="$(grep -m1 -E 'ubuntu-[0-9]{4}-lts' "$f" 2>/dev/null | head -n1)"
    line="$(printf '%s' "$raw" | grep -oE 'ubuntu-[0-9]{4}-lts' | head -n1)"
    if [ -n "$line" ]; then
      line="${line#ubuntu-}"; line="${line%-lts}"
      emit ubuntu "${line:0:2}.${line:2:2}" "${f#"$REPO_ROOT"/}" "$(trim "$raw")"
    fi
  done < <(find "$REPO_ROOT/packer" -name '*.pkr.hcl' 2>/dev/null)

  # Manifests, via python3 — a JSON manifest read with grep is a manifest read
  # wrongly, and the repository already depends on python3 for the job broker.
  while IFS= read -r f; do
    python3 "$HERE/support-window-feed.py" --manifest "$f" 2>/dev/null | while IFS=$'\t' read -r pkg ver; do
      local prod
      prod="$(product_for_package "$pkg")" || continue
      emit "$prod" "$ver" "${f#"$REPO_ROOT"/}" "$pkg $ver"
    done
  done < <(find "$REPO_ROOT" -name package.json -not -path '*/node_modules/*' 2>/dev/null)
}

decl_value() { # `  node-version: '20.x'` -> 20.x
  # A matrix (`node-version: [18, 20]`) yields `[18` here, which `cycle_of`
  # rejects — a version this scan does not read is better than a version it
  # reads wrongly. Named as a known gap in docs/dependency-freshness.md.
  local v="${1#*:}"
  v="${v//[\'\" ]/}"
  v="${v//$'\t'/}"
  echo "${v%%,*}"
}
trim() { # parameter expansion, not `sed` — shellcheck's SC2001 is a gate failure here
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  echo "${v%"${v##*[![:space:]]}"}"
}

# --- the feed ----------------------------------------------------------------
#
# A third party this scan cannot control. When it does not answer, every
# affected declaration becomes SUP4 and the report says so at the top: an
# outage must look like an outage, never like a clean repository.
FEED_OK=1
fetch_product() { # <product> — caches <cache>/<product>.json, returns 1 if absent
  # Two statements, not one: a single `local a=… b="$a"` expands every word
  # before it assigns any of them, so `b` reads an unset `a` under `set -u`.
  local p="$1"
  local dest="$CACHE/$p.json"
  [ -s "$dest" ] && return 0
  # A cache miss with the network switched off is still an absence of data, and
  # the report must say so. Returning early here without marking the feed
  # unavailable printed a report that looked complete and was not.
  if [ "$OFFLINE" -eq 1 ]; then FEED_OK=0; return 1; fi
  if curl -fsS --max-time 20 --retry 2 --retry-delay 2 \
      "$FEED_BASE/$p.json" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
    return 0
  fi
  rm -f "$dest"
  FEED_OK=0
  return 1
}

# --- scan --------------------------------------------------------------------
scan_inventory

# A declaration is `new` when this pull request added the line that makes it.
# Reversing a version choice is free on the day it is proposed and expensive a
# year later, which is the entire reason the rule treats the two differently.
# Scoped to the DECLARING FILE. A single pool of every added line in the diff
# means a line added in one file marks a declaration in another as newly
# chosen, and the version strings involved — `18`, `22`, `1.21` — are exactly
# the sort of text that appears incidentally in a table, a changelog or a
# comment. The question is per-file or it is not being asked.
ADDED_DIR="$CACHE/added"
mkdir -p "$ADDED_DIR"
if [ -n "$BASE_REF" ]; then
  git -C "$REPO_ROOT" diff -U0 "$BASE_REF"...HEAD 2>/dev/null | awk -v dir="$ADDED_DIR" '
    /^\+\+\+ b\// { path = substr($0, 7); gsub(/[^A-Za-z0-9._-]/, "_", path)
                    out = dir "/" path; next }
    /^\+\+\+/     { out = ""; next }
    /^\+/ && out != "" { print substr($0, 2) >>out }
  ' || :
fi

# Same sanitising as the awk above, so a path resolves to the same file on both
# sides. `tr`, not `sed`, because a `sed 's/.../_/g'` here is a shellcheck
# finding and this repository runs shellcheck with no severity filter.
added_lines_for() { # <repo-relative path>
  printf '%s/%s' "$ADDED_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

adoption_of() { # <repo-relative file> <the declaration line itself>
  local pool
  # No base to compare against — a scheduled run, or a push. Everything is
  # inherited, which is the quiet answer, and the right one: nothing here was
  # chosen by an event that has a diff.
  [ -n "$BASE_REF" ] || { echo existing; return 0; }
  pool="$(added_lines_for "$1")"
  [ -s "$pool" ] || { echo existing; return 0; }
  if grep -qF -- "$2" "$pool" 2>/dev/null; then echo new; else echo existing; fi
}

RESULTS="$CACHE/results.tsv"
: >"$RESULTS"

while IFS=$'\t' read -r product cycle source text; do
  [ -n "$product" ] || continue
  eol=""; support=""; best_cycle=""; best_eol=""
  if fetch_product "$product"; then
    facts="$(python3 "$HERE/support-window-feed.py" --lifetime "$CACHE/$product.json" \
             --cycle "$cycle" --today "$TODAY" 2>/dev/null)"
    IFS=$'\t' read -r eol support best_cycle best_eol <<<"$facts"
  fi
  verdict="$(support_verdict "$TODAY" "$WINDOW" "$cycle" "${eol:-}" "${support:-}" \
             "${best_cycle:-}" "${best_eol:-}" "$(adoption_of "$source" "$text")")"
  printf '%s\t%s\t%s\t%s\t%s\n' "${verdict%%:*}" "$product" "$cycle" "$source" "$verdict" >>"$RESULTS"
done <"$INVENTORY"

# --- the report --------------------------------------------------------------
#
# Ordered by what a reader should do, not by product name. SUP3 sits second
# because it is the only row with a deadline that has not passed and a fix that
# is still free.
count_of() { # <code> — awk, not `grep -c`: grep exits 1 on zero matches, and a
             # `|| echo 0` beside it prints TWO zeros into an arithmetic test.
  awk -F'\t' -v c="$1" '$1==c {n++} END {print n+0}' "$RESULTS"
}

render() {
  local code="$1" heading="$2" blurb="$3" n
  n="$(count_of "$code")"
  [ "$n" -gt 0 ] || return 0
  printf '### %s (%s)\n\n%s\n\n' "$heading" "$n" "$blurb"
  printf '| what | version | where | detail |\n|---|---|---|---|\n'
  awk -F'\t' -v c="$code" '$1==c {print "| `" $2 "` | " $3 " | `" $4 "` | " substr($5, index($5,":")+1) " |"}' "$RESULTS"
  printf '\n'
}

{
  printf '<!-- support-window-scan -->\n'
  # Machine-readable, on its own line, so a caller deciding whether to open or
  # CLOSE an issue does not have to count table rows. The distinction matters:
  # SUP5 is informational and shown in the body, but an issue held open by
  # informational rows alone never closes, and an issue that never closes stops
  # being read.
  printf '<!-- counts actionable=%s SUP1=%s SUP2=%s SUP3=%s SUP4=%s SUP5=%s SUP0=%s -->\n' \
    "$(( $(count_of SUP1) + $(count_of SUP2) + $(count_of SUP3) + $(count_of SUP4) ))" \
    "$(count_of SUP1)" "$(count_of SUP2)" "$(count_of SUP3)" \
    "$(count_of SUP4)" "$(count_of SUP5)" "$(count_of SUP0)"
  printf '# Versions past, or near, the end of their support\n\n'
  printf '_Scanned %s against endoflife.date. Migration window: %s days._\n\n' "$TODAY" "$WINDOW"

  if [ "$FEED_OK" -eq 0 ]; then
    printf '> **The lifetime feed did not answer for every product in this scan.**\n'
    printf '> Those rows are reported as undecided below. This report is incomplete,\n'
    printf '> which is not the same as clean.\n\n'
  fi

  if ! [ -s "$RESULTS" ]; then
    printf 'No version declaration was found to scan.\n'
  fi

  render SUP1 'Unsupported — running past end of support' \
    'No security fixes are being published for these. This is the row to act on.'
  render SUP3 'Newly adopted with a shorter runway than was available' \
    'These arrived in this pull request. Changing the choice now costs one line; changing it after release costs a migration.'
  render SUP2 'Inside the migration window' \
    'Still supported, with an end date close enough to plan for.'
  render SUP4 'Undecided — no lifetime data' \
    'The feed published nothing for these. Undecided is not a pass; check them by hand.'
  render SUP5 'Maintenance only — security fixes, no features' \
    'Out of active support, end of life still ahead. Informational: this is what a deliberate postponement looks like.'

  printf -- '---\n\n%s declaration(s) are fully supported.\n' "$(count_of SUP0)"
  printf 'Libraries without a published support lifetime are not scanned — no feed tracks them, and a row per library would bury the ones above.\n'
} >"$CACHE/report.md"

# Written to a file and then copied, never redirected straight at `/dev/stdout`:
# that path is not a plain file on every platform this runs on, and a truncating
# redirect at it silently ate the first half of the report.
if [ -n "$OUT" ]; then cp "$CACHE/report.md" "$OUT"; else cat "$CACHE/report.md"; fi

exit 0
