#!/usr/bin/env bash
# Self-test for the per-lane suite reuse key.
#
# This exists because the rule's failure modes are asymmetric and one of them is
# silent. A MISS costs one suite and announces itself in the bill. A wrong HIT
# reports green over code no job read — the same class as a vacuous config gate,
# and worse than paying for the run.
#
# FIXTURES FIRST, on purpose. A key function that returned a constant would make
# every "identical trees produce the same key" assertion pass, and a key
# function that hashed the wrong bytes would make every "must differ" assertion
# pass. So each detector is proved to FIRE — a workflow edit changes every
# lane's key, a base move into this lane's inputs changes it, a rename with
# identical content changes it — before any positive result is believed.
#
# No network, no git, no arguments: the trees are fixtures, so every branch
# including the malformed ones is reachable here rather than in production.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/suite-reuse-key.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
  shift
  [ "$#" -eq 0 ] || printf '  %s\n' "$@"
}

# --- fixtures -----------------------------------------------------------------

# A stable fake object id per content tag. Any change of tag is a change of
# content; identical tags are byte-identical files. Memoised: the fixtures are
# rebuilt for every case and the digest tool is the expensive part.
# Precomputed in the parent shell, because the fixtures are built inside command
# substitutions and a cache filled in a subshell dies with it.
declare -A OIDS=()
for _t in w1 w2 a1 a2 g1 g2 m1 m2 W0 W1 W2 U1 U2 A1 A2 D1 D2 D9 L1 L2 t1 t2 X; do
  OIDS["$_t"]=$(printf '%s' "$_t" | sha256sum | cut -c1-40)
done
unset _t

oid() {
  if [ -z "${OIDS[$1]+set}" ]; then
    OIDS["$1"]=$(printf '%s' "$1" | sha256sum | cut -c1-40)
  fi
  printf '%s' "${OIDS[$1]}"
}

# mk <path=contenttag>… — one `git ls-tree -r` line per entry.
mk() {
  local a p c
  for a in "$@"; do
    p="${a%%=*}"
    c="${a#*=}"
    printf '100644 blob %s\t%s\n' "$(oid "$c")" "$p"
  done
}

ENTRIES=(
  '.github/workflows/ci.yml=w1'
  '.github/actions/setup/action.yml=a1'
  'scripts/ci/gate.sh=g1'
  '.mergify.yml=m1'
  'apps/web/src/app.ts=W0'
  'packages/ui/button.ts=U1'
  'apps/api/src/main.ts=A1'
  'README.md=D1'
  'docs/adr/0001.md=D2'
  'LICENSE=L1'
)

# tree <path=contenttag>… — the fixture tree with those entries replaced.
tree() {
  local -a out=()
  local e p ov
  for e in "${ENTRIES[@]}"; do
    p="${e%%=*}"
    for ov in "$@"; do
      [ "${ov%%=*}" = "$p" ] && e="$ov"
    done
    out+=("$e")
  done
  mk "${out[@]}"
}

FILTERS_DEFAULT="web:
  - 'apps/web/**'
  - 'packages/ui/**'
api:
  - 'apps/api/**'
docs:
  - '**/*.md'
rollup:
"

PINS_DEFAULT='runner-image=registry.example.invalid/ci-host@sha256:0000000000000000000000000000000000000000000000000000000000000000
ci-runner-infra=v0.0.0'

# doc <merge-tree> <base-tree> [pins] [filters] [process]
doc() {
  local merge="$1" base="$2"
  local pins="${3-$PINS_DEFAULT}" filters="${4-$FILTERS_DEFAULT}" process="${5-}"
  printf '%%%%pins\n%s\n' "$pins"
  [ -z "$process" ] || printf '%%%%process\n%s\n' "$process"
  printf '%%%%filters\n%s\n' "$filters"
  printf '%%%%tree-merge\n%s\n' "$merge"
  printf '%%%%tree-base\n%s\n' "$base"
}

k() { # k <lane> <document>
  printf '%s' "$2" | suite_reuse_key "$1"
}

# --- assertions ---------------------------------------------------------------

is_key() {
  local desc="$1" got="$2"
  case "$got" in
    key:????????????????????????????????????????????????????????????????) ok ;;
    *) bad "$desc" "want: key:<64-hex>" "got:  $got" ;;
  esac
}

is_miss() {
  local desc="$1" got="$2"
  case "$got" in
    miss:?*) ok ;;
    *) bad "$desc" "want: miss:<reason>" "got:  $got" ;;
  esac
}

same() {
  local desc="$1" a="$2" b="$3"
  case "$a" in key:*) ;; *) bad "$desc (left is not a key)" "got: $a"; return ;; esac
  if [ "$a" = "$b" ]; then ok; else bad "$desc" "a: $a" "b: $b"; fi
}

differ() {
  local desc="$1" a="$2" b="$3"
  case "$a$b" in *miss:*) bad "$desc (a miss proves nothing here)" "a: $a" "b: $b"; return ;; esac
  if [ "$a" != "$b" ]; then ok; else bad "$desc" "both: $a"; fi
}

MERGE0=$(tree 'apps/web/src/app.ts=W1')
BASE0=$(tree)
DOC0=$(doc "$MERGE0" "$BASE0")

WEB0=$(k web "$DOC0")
API0=$(k api "$DOC0")
DOCS0=$(k docs "$DOC0")

# --- the key is producible at all ---------------------------------------------
is_key "a declared lane over well-formed trees produces a key" "$WEB0"
is_key "every declared lane produces a key" "$API0"
is_key "the documentation lane is an ordinary lane" "$DOCS0"

# One key PER LANE. If the function ignored its argument, every "must differ"
# assertion below would still pass while the whole point was lost.
differ "two lanes over the same trees do not share a key" "$WEB0" "$API0"
differ "a third lane is distinct from both" "$API0" "$DOCS0"

# The lane NAME is load-bearing on its own, not merely a consequence of the
# paths: two lanes may read the same files and still be different jobs — a lint
# lane and a type-check lane over one workspace. If the name were left out of
# the hash, one lane's green record would satisfy the other, and the cheaper of
# the two would silently stand in for the more expensive one.
TWIN=$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web:
  - 'apps/web/**'
webtypes:
  - 'apps/web/**'
")
differ "two lanes with IDENTICAL declared paths still have different keys" \
  "$(k web "$TWIN")" "$(k webtypes "$TWIN")"

# --- identical trees hit ------------------------------------------------------
same "the same inputs produce the same key" "$WEB0" "$(k web "$DOC0")"

# Order-independence: `git ls-tree` output order is not a property of the tree's
# content, and a key that depended on it would miss on every re-listing.
REV=$(printf '%s\n' "$MERGE0" | tac)
same "listing order is not part of the tree's identity" \
  "$WEB0" "$(k web "$(doc "$REV" "$BASE0")")"

# --- a source change misses ---------------------------------------------------
differ "a change to this lane's own source changes its key" \
  "$WEB0" "$(k web "$(doc "$(tree 'apps/web/src/app.ts=W2')" "$BASE0")")"
differ "a change under this lane's SECOND declared path also changes it" \
  "$WEB0" "$(k web "$(doc "$(tree 'apps/web/src/app.ts=W1' 'packages/ui/button.ts=U2')" "$BASE0")")"
same "a change to ANOTHER lane's source leaves this lane's key alone" \
  "$WEB0" "$(k web "$(doc "$(tree 'apps/web/src/app.ts=W1' 'apps/api/src/main.ts=A2')" "$BASE0")")"

# A rename with byte-identical content is a different tree for every lane that
# reads it — the path is an input, not a label.
RENAMED=$(mk \
  '.github/workflows/ci.yml=w1' '.github/actions/setup/action.yml=a1' \
  'scripts/ci/gate.sh=g1' '.mergify.yml=m1' \
  'apps/web/src/App.ts=W1' 'packages/ui/button.ts=U1' 'apps/api/src/main.ts=A1' \
  'README.md=D1' 'docs/adr/0001.md=D2' 'LICENSE=L1')
differ "a rename with identical content is still a different tree" \
  "$WEB0" "$(k web "$(doc "$RENAMED" "$BASE0")")"

# --- a CI-process change misses on EVERY lane ---------------------------------
# This is the invariant, not an optimisation to be relaxed later. A workflow or
# gate-script change alters what "green" means, so a lane that reused across one
# would be asserting a result its own definition no longer produces.
for change in \
  '.github/workflows/ci.yml=w2' \
  '.github/actions/setup/action.yml=a2' \
  'scripts/ci/gate.sh=g2' \
  '.mergify.yml=m2'; do
  D=$(doc "$(tree 'apps/web/src/app.ts=W1' "$change")" "$BASE0")
  differ "a CI-process change ($change) invalidates the web lane" "$WEB0" "$(k web "$D")"
  differ "a CI-process change ($change) invalidates the api lane" "$API0" "$(k api "$D")"
  differ "a CI-process change ($change) invalidates the docs lane" "$DOCS0" "$(k docs "$D")"
done

# The same change arriving through the BASE — which is how it actually arrives
# for a pull request still in flight when a CI change merges.
DCI=$(doc "$MERGE0" "$(tree '.github/workflows/ci.yml=w2')")
differ "a CI-process change in the BASE invalidates the web lane" "$WEB0" "$(k web "$DCI")"
differ "a CI-process change in the BASE invalidates the api lane" "$API0" "$(k api "$DCI")"

# A pin is a CI input the tree does not contain. If it were left out of the key,
# a runner-image bump would reuse suites that ran on the old toolchain.
DPIN=$(doc "$MERGE0" "$BASE0" "runner-image=registry.example.invalid/ci-host@sha256:1111111111111111111111111111111111111111111111111111111111111111
ci-runner-infra=v0.0.0")
differ "a runner image pin bump invalidates the web lane" "$WEB0" "$(k web "$DPIN")"
differ "a runner image pin bump invalidates the api lane" "$API0" "$(k api "$DPIN")"

# --- base moves: the second lever ---------------------------------------------
# A base move that touched only another lane's inputs cannot change this lane's
# result, and must not cost it a suite.
BOTHER=$(doc "$MERGE0" "$(tree 'apps/api/src/main.ts=A2')")
same "a base move into ANOTHER lane's inputs leaves this lane's key unchanged" \
  "$WEB0" "$(k web "$BOTHER")"
differ "…and does invalidate the lane whose inputs it touched" \
  "$API0" "$(k api "$BOTHER")"

# A base move into THIS lane's inputs is exactly the semantic-conflict case the
# queue exists to catch. It must invalidate.
differ "a base move into this lane's inputs changes its key" \
  "$WEB0" "$(k web "$(doc "$MERGE0" "$(tree 'packages/ui/button.ts=U2')")")"

# A documentation-only merge is the largest source of provably-free re-runs.
BDOCS=$(doc "$MERGE0" "$(tree 'README.md=D9' 'docs/adr/0001.md=D9')")
same "a docs-only base move does not invalidate the web lane" "$WEB0" "$(k web "$BDOCS")"
same "a docs-only base move does not invalidate the api lane" "$API0" "$(k api "$BDOCS")"
differ "…but it does invalidate the lane that DECLARES the documentation" \
  "$DOCS0" "$(k docs "$BDOCS")"

# The boundary of the saving, stated so it cannot drift into a surprise: reuse
# is scoped to DECLARED inputs, so a path no lane declares and no CI-process
# glob covers is invisible to every lane's key. That is the design — and it is
# the whole reason the declared paths must come from the filter config the lane
# is really gated on, never from a second list.
same "a path outside every declared filter does not invalidate a lane" \
  "$WEB0" "$(k web "$(doc "$(tree 'apps/web/src/app.ts=W1' 'LICENSE=L2')" "$BASE0")")"

# --- lanes that must never reuse ----------------------------------------------
is_miss "an always-on lane with no path filter never reuses" "$(k rollup "$DOC0")"
is_miss "a lane the filter config does not declare never reuses" "$(k nosuch "$DOC0")"
is_miss "an empty lane name is not a lane" "$(k '' "$DOC0")"
is_miss "a lane name outside the safe charset is refused" "$(k 'web;rm' "$DOC0")"

# A lane declared twice: YAML would silently take one of them, and which one is
# not a thing this file should be deciding.
is_miss "a lane declared twice is ambiguous, so it does not reuse" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web:
  - 'apps/web/**'
api:
  - 'apps/api/**'
web:
  - 'apps/other/**'
")")"

# A lane whose filter matches nothing in the tree has drifted from the tree. Its
# key would then be stable across every change it actually reads.
is_miss "a lane whose declared paths match no file has drifted, so it does not reuse" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web:
  - 'apps/gone/**'
")")"

# --- filter forms this parser must refuse rather than guess -------------------
# Each of these means the lane reads paths the parser did not see. A lane whose
# inputs are partly invisible is a lane whose key is partly wrong.
is_miss "a YAML alias hides the paths it expands to" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "shared: &shared
  - 'apps/web/**'
web: *shared
")")"
is_miss "a per-change-type map is a nested structure this subset cannot read" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web:
  added|modified: 'apps/web/**'
")")"
is_miss "a flow sequence is not enumerated" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web: ['apps/web/**']
")")"
is_miss "a negation is order-dependent and is refused, not approximated" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web:
  - '!apps/web/vendor/**'
  - 'apps/web/**'
")")"
is_miss "a glob outside the supported subset is refused" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web:
  - 'apps/web/*.{ts,tsx}'
")")"
is_miss "a character class is refused too" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web:
  - 'apps/web/v[0-9]/**'
")")"
is_miss "a filter document that is not a mapping at all is malformed" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "- 'apps/web/**'
")")"

# The scalar shorthand IS supported — `dorny/paths-filter` accepts it and
# refusing it would push repositories into a second, divergent config.
is_key "the single-glob scalar shorthand is read, not refused" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" "web: 'apps/web/**'
")")"

# --- malformed input misses, never errors -------------------------------------
# Every one of these is a caller bug. The function's job is to make the caller
# run the suite, not to fail the job with a stack of shell errors — and above
# all not to emit a key.
is_miss "a missing base tree section misses" \
  "$(printf '%%%%pins\n%s\n%%%%filters\n%s\n%%%%tree-merge\n%s\n' \
      "$PINS_DEFAULT" "$FILTERS_DEFAULT" "$MERGE0" | suite_reuse_key web)"
is_miss "a missing merge tree section misses" \
  "$(printf '%%%%pins\n%s\n%%%%filters\n%s\n%%%%tree-base\n%s\n' \
      "$PINS_DEFAULT" "$FILTERS_DEFAULT" "$BASE0" | suite_reuse_key web)"
is_miss "a missing filters section misses" \
  "$(printf '%%%%pins\n%s\n%%%%tree-merge\n%s\n%%%%tree-base\n%s\n' \
      "$PINS_DEFAULT" "$MERGE0" "$BASE0" | suite_reuse_key web)"
is_miss "a missing pins section misses — an undeclared pin is an uncovered input" \
  "$(printf '%%%%filters\n%s\n%%%%tree-merge\n%s\n%%%%tree-base\n%s\n' \
      "$FILTERS_DEFAULT" "$MERGE0" "$BASE0" | suite_reuse_key web)"
is_miss "a pins section present but empty misses — it looks supplied and is not" \
  "$(printf '%%%%pins\n%%%%filters\n%s\n%%%%tree-merge\n%s\n%%%%tree-base\n%s\n' \
      "$FILTERS_DEFAULT" "$MERGE0" "$BASE0" | suite_reuse_key web)"
# A section made of blank lines is the same lie as an empty one, and it used to
# pass: the reader appended the blank lines, so `pins` was non-empty and the key
# was computed over zero declared pins. Every caller emitting that document
# would agree with every other one — a hit across toolchains never compared.
is_miss "a pins section of blank lines misses — it is empty, whatever it looks like" \
  "$(printf '%%%%pins\n   \n\n%%%%filters\n%s\n%%%%tree-merge\n%s\n%%%%tree-base\n%s\n' \
      "$FILTERS_DEFAULT" "$MERGE0" "$BASE0" | suite_reuse_key web)"
is_miss "a process section of blank lines misses on the same rule" \
  "$(printf '%%%%pins\n%s\n%%%%process\n \n%%%%filters\n%s\n%%%%tree-merge\n%s\n%%%%tree-base\n%s\n' \
      "$PINS_DEFAULT" "$FILTERS_DEFAULT" "$MERGE0" "$BASE0" | suite_reuse_key web)"

# A blank line BETWEEN pins is ordinary formatting and must not change the key:
# dropping whitespace-only lines has to be a normalisation, not a second way to
# spell a different document.
same "a blank line between pins does not change the key" "$WEB0" \
  "$(k web "$(doc "$MERGE0" "$BASE0" "$(printf '%s\n\n%s' \
      "${PINS_DEFAULT%%$'\n'*}" "${PINS_DEFAULT##*$'\n'}")")")"

# The lane-name charset is one charset. A leading `.` is legal in the name test
# and used to be rejected by the header test, which returns "malformed" — so
# every OTHER lane missed as well, over a name only this one uses.
DOTLANE=$(doc "$MERGE0" "$BASE0" "$PINS_DEFAULT" \
  "$(printf '%s.ci:\n  - %s\n' "$FILTERS_DEFAULT" "'apps/web/**'")")
is_key "a sibling lane named with a leading dot does not make the document malformed" \
  "$(k web "$DOTLANE")"
is_key "and that lane is itself usable" "$(k .ci "$DOTLANE")"

is_miss "an empty base tree section misses" "$(k web "$(doc "$MERGE0" "")")"
is_miss "an empty document misses" "$(printf '' | suite_reuse_key web)"
is_miss "an unknown section name misses" \
  "$(printf '%%%%pins\n%s\n%%%%trees\n%s\n' "$PINS_DEFAULT" "$MERGE0" | suite_reuse_key web)"
is_miss "content before any section header misses" \
  "$(printf 'stray\n%%%%pins\n%s\n%%%%filters\n%s\n%%%%tree-merge\n%s\n%%%%tree-base\n%s\n' \
      "$PINS_DEFAULT" "$FILTERS_DEFAULT" "$MERGE0" "$BASE0" | suite_reuse_key web)"

# Tree listings that are not what they claim to be.
is_miss "an ls-tree line with no tab misses" \
  "$(k web "$(doc "$MERGE0
100644 blob $(oid X) apps/web/src/b.ts" "$BASE0")")"
is_miss "a listing without -r (a tree entry) misses rather than hashing a partial tree" \
  "$(k web "$(doc "$MERGE0
040000 tree $(oid X)	apps/web/nested" "$BASE0")")"
is_miss "a truncated object id misses" \
  "$(k web "$(doc "$MERGE0
100644 blob deadbeef	apps/web/src/b.ts" "$BASE0")")"
is_miss "a git-quoted path misses rather than being silently excluded" \
  "$(k web "$(doc "$MERGE0
100644 blob $(oid X)	\"apps/web/src/caf\\303\\251.ts\"" "$BASE0")")"
is_miss "a duplicated path means two listings were concatenated" \
  "$(k web "$(doc "$MERGE0
100644 blob $(oid X)	apps/web/src/app.ts" "$BASE0")")"
is_miss "a tree with no CI-process path at all is not a tree this key can cover" \
  "$(k web "$(doc "$(mk 'apps/web/src/app.ts=W1' 'packages/ui/button.ts=U1')" "$BASE0")")"

# --- the process section is additive, never a replacement ---------------------
# A repository whose gate scripts live outside `scripts/ci/**` declares them
# here. It must not thereby stop covering the built-in list.
EXTRA=$(mk \
  '.github/workflows/ci.yml=w1' '.github/actions/setup/action.yml=a1' \
  'scripts/ci/gate.sh=g1' '.mergify.yml=m1' 'tools/ci/verify.sh=t1' \
  'apps/web/src/app.ts=W1' 'packages/ui/button.ts=U1' 'apps/api/src/main.ts=A1' \
  'README.md=D1' 'docs/adr/0001.md=D2' 'LICENSE=L1')
EXTRA2=${EXTRA//$(oid t1)/$(oid t2)}
WEBX=$(k web "$(doc "$EXTRA" "$BASE0" "$PINS_DEFAULT" "$FILTERS_DEFAULT" 'tools/ci/**')")
is_key "a declared extra process path still yields a key" "$WEBX"
differ "a change under an extra process path invalidates the lane" \
  "$WEBX" "$(k web "$(doc "$EXTRA2" "$BASE0" "$PINS_DEFAULT" "$FILTERS_DEFAULT" 'tools/ci/**')")"
same "…and the built-in process globs are still covered alongside it" \
  "$WEBX" "$(k web "$(doc "$EXTRA" "$BASE0" "$PINS_DEFAULT" "$FILTERS_DEFAULT" 'tools/ci/**')")"
differ "…the built-in list is not replaced by the extra one" \
  "$WEBX" "$(k web "$(doc "${EXTRA//$(oid w1)/$(oid w2)}" "$BASE0" "$PINS_DEFAULT" "$FILTERS_DEFAULT" 'tools/ci/**')")"
is_miss "an unsupported glob in the process section misses" \
  "$(k web "$(doc "$EXTRA" "$BASE0" "$PINS_DEFAULT" "$FILTERS_DEFAULT" 'tools/ci/**/*.{sh,py}')")"

# --- glob semantics the whole rule rests on -----------------------------------
# `**` spans directories, `*` does not, and a prefix is a path prefix rather
# than a string prefix — `apps/web/**` must not swallow `apps/webx/`.
gm() {
  local want="$1" glob="$2" path="$3" got
  if _srk_match "$glob" "$path"; then got=yes; else got=no; fi
  if [ "$got" = "$want" ]; then ok; else bad "glob '$glob' vs '$path'" "want: $want" "got:  $got"; fi
}
gm yes 'apps/web/**' 'apps/web/src/app.ts'
gm no  'apps/web/**' 'apps/webx/src/app.ts'
gm no  'apps/web/**' 'apps/api/src/app.ts'
gm yes '**/*.md'     'README.md'
gm yes '**/*.md'     'docs/adr/0001.md'
gm no  '**/*.md'     'docs/adr/0001.txt'
gm yes 'scripts/ci/*.sh' 'scripts/ci/gate.sh'
gm no  'scripts/ci/*.sh' 'scripts/ci/nested/gate.sh'
gm yes '.mergify.yml' '.mergify.yml'
gm no  '.mergify.yml' 'sub/.mergify.yml'
gm yes 'a/**/c.ts' 'a/b/c.ts'
gm yes 'a/**/c.ts' 'a/c.ts'
gm yes 'a/**/c.ts' 'a/b/b2/c.ts'
gm no  'a/**/c.ts' 'a/b/c.tsx'

# --- the format itself, pinned ------------------------------------------------
# Every assertion above is relative: it compares one key to another, so a change
# that shifted EVERY key uniformly — a reordered preimage, a dropped version
# prefix, a different digest — would pass the whole suite while silently
# colliding with keys already recorded under the old meaning. A green suite
# would then be inherited by a tree it never ran on.
#
# So one absolute vector. If this fails and the change to the preimage was
# deliberate, bump `srk1` in suite-reuse-key.sh — that is what retires the
# recorded keys — and update the value here in the same commit.
GOLDEN=key:02b4ecd03e3c1a9e323b4ebec638c1249afca1feefff27b3c141ca729f561153
if [ "$WEB0" = "$GOLDEN" ]; then
  ok
else
  bad "the recorded key format changed" \
    "want: $GOLDEN" \
    "got:  $WEB0" \
    "if this was deliberate, bump the srk1 version prefix in the same commit"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
