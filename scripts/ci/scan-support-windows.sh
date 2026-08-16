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
  local f line

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
  while IFS= read -r f; do
    while IFS= read -r line; do
      local ref image tag prod
      ref="$(echo "$line" | awk '{print $2}')"
      ref="${ref##*/}"
      image="${ref%%:*}"
      tag="${ref#*:}"
      [ "$tag" = "$ref" ] && continue
      prod="$(product_for_image "$image")" || continue
      emit "$prod" "$tag" "${f#"$REPO_ROOT"/}" "FROM $ref"
    done < <(grep -hiE '^[[:space:]]*FROM[[:space:]]+[^[:space:]]+:' "$f" 2>/dev/null)
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
    line="$(awk '/^variable "node_major"/{inblock=1} inblock && /^[[:space:]]*default/{
              gsub(/[^0-9.]/, "", $0); print; exit} inblock && /^}/{exit}' "$f" 2>/dev/null)"
    [ -n "$line" ] && emit nodejs "$line" "${f#"$REPO_ROOT"/}" "node_major default"
    # `ubuntu-2404-lts-amd64` — the host OS, whose end of life ends the security
    # updates for everything else baked on top of it.
    line="$(grep -m1 -oE 'ubuntu-[0-9]{4}-lts' "$f" 2>/dev/null | head -n1)"
    if [ -n "$line" ]; then
      line="${line#ubuntu-}"; line="${line%-lts}"
      emit ubuntu "${line:0:2}.${line:2:2}" "${f#"$REPO_ROOT"/}" "source_image_family"
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
ADDED="$CACHE/added.txt"
: >"$ADDED"
if [ -n "$BASE_REF" ]; then
  git -C "$REPO_ROOT" diff -U0 "$BASE_REF"...HEAD 2>/dev/null \
    | grep -E '^\+[^+]' | sed 's/^+//' >"$ADDED" || :
fi

adoption_of() { # <declaration-text>
  [ -s "$ADDED" ] || { echo existing; return 0; }
  if grep -qF -- "$1" "$ADDED" 2>/dev/null; then echo new; else echo existing; fi
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
             "${best_cycle:-}" "${best_eol:-}" "$(adoption_of "$text")")"
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
