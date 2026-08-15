#!/usr/bin/env bash
# =============================================================================
# check-generic-literals.sh — a customer literal is a fork waiting to happen
#
# USAGE
#   bash scripts/ci/check-generic-literals.sh [--selftest] [--self=<owner/repo>]
#                                             [--root=<dir>] [<file>...]
#
# PURPOSE
#   This module is consumed by fourteen repositories in more than one
#   organisation, region and project. A hardcoded org, project, region or
#   repository name is how the vendored predecessor drifted into nine divergent
#   copies, so the gate refuses one.
#
#     LIT1  no literal in an executable tree — `*.tf`, `*.tfvars`, `*.hcl`,
#           `*.sh`, and the workflow/config YAML that decides what CI does
#     LIT2  no literal in a Markdown FENCED CODE BLOCK — the copy-pasteable half
#           of a document
#     LIT0  the gate found nothing to read, or was asked to read a file it
#           cannot — reported, never passed
#
# WHY THE YAML AND THE MARKDOWN ARE NOT AN AFTERTHOUGHT (issue #69)
#   Until this file existed the scan covered `*.tf`, `*.sh` and `*.hcl` and
#   stopped. Documentation and workflow examples are exactly where a customer
#   name, a region or a concrete repository label gets written down without
#   anyone treating it as code — and a document whose entire purpose is to be
#   copy-pasted into fourteen other repositories propagates a literal BY DESIGN.
#   `docs/onboarding-a-repository.md` is that document. The gate was blind to
#   the one file class with the widest blast radius.
#
# WHY PROSE IS EXEMPT AND A CODE FENCE IS NOT
#   This is the whole design, and a naive widening gets it backwards.
#
#   A literal in PROSE is evidence: "mot-face-blur #56" names an incident, and
#   "the peering to `mot-lz-vpc`" tells a reader in that landing zone what they
#   are looking at. Failing those makes the gate an obstacle to writing down why
#   a rule exists, and a gate that punishes the incident record is a gate whose
#   incident records stop being written.
#
#   A literal inside a ``` fence is a THING SOMEBODY WILL PASTE. That is the
#   entire difference, it is mechanically decidable, and it is the direction the
#   damage travels. So Markdown is scanned inside fences only — while YAML, HCL
#   and shell are scanned whole, because every line of those is already the
#   pasteable kind.
#
#   Consequence worth stating plainly: a literal moved from a fence into prose
#   passes. That is intended. The reader is then being TOLD about a value rather
#   than handed one, and the copy-paste path is what this gate guards.
#
# WHY PLACEHOLDERS NEED NO ALLOWLIST
#   The docs deliberately write `<org>`, `<Repo>`, `<RepoLabel>` and
#   `<40-char-commit-sha>` in their snippets. None of them can match a pattern
#   made of concrete values, so the placeholder shape stays legible for free and
#   anything concrete stands out beside it. An allowlist of placeholder spellings
#   would be a second list to keep in step with the docs, buying nothing.
#
# WHY THE OWNER IS DERIVED RATHER THAN WRITTEN DOWN
#   The predecessor of this gate carried `Dima-Spectorr` in its own pattern —
#   the gate against hardcoded org names, with a hardcoded org name in it, in a
#   PUBLIC repository. The owner is now read from `GITHUB_REPOSITORY` (or the
#   `origin` remote), which makes the rule "this repository's owner must not
#   appear except as this repository's own address" — true in a fork, true in a
#   consumer, and carrying no org literal to leak.
#
#   That exception is narrow on purpose: `<owner>/ci-runner-infra` IS this
#   module's address, and the quickstart line every consumer pastes has to name
#   it (`docs-pins.selftest.sh` asserts its VERSION separately). `<owner>/`
#   followed by any OTHER repository is a different repository's path in a shared
#   module, and still fails.
#
# WHAT IS NOT CHECKED
#   This file and its fixtures. A denylist must spell out what it denies, so the
#   gate necessarily contains every literal it bans; excluding itself is not a
#   loophole but the only way it can exist. The exclusion is exactly one path and
#   the self-test asserts that it is exactly one, so it cannot quietly grow into
#   a hiding place.
#
# EXIT CODES
#   0 — clean
#   1 — a literal, or a file the gate could not read
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$REPO_ROOT"

fail=0
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

# The one path this gate does not read, because it is the list of banned values.
# Relative to the repository root, and asserted as a single entry by the
# self-test — a growing exclusion list is how a denylist stops being one.
SELF_EXCLUDE='scripts/ci/check-generic-literals.sh'

# Concrete values that must not appear in a shared module. Regions, the
# customer's project prefix, its domain, and a bucket URL — each one a value a
# second consumer cannot possibly want, which is what makes copying it a fork.
#
# The organisation is NOT here; see "WHY THE OWNER IS DERIVED" above.
#
# `gs://` requires a bucket-name character after it, and that is not pedantry —
# it was the widening's first real-world finding. `cloudbuild.yaml` documents
# its own invocation with `gs://<bucket-in-an-allowed-location>/source`, which
# names no bucket and is the OPPOSITE of the defect: a placeholder written down
# precisely so nobody hardcodes theirs. The banned thing is a bucket somebody
# owns, so the rule asks for one. `gs://$VAR`, `gs://${…}` and `gs://<…>` are
# all a caller's value by construction.
PATTERN_STATIC='me-west1|europe-west1|mot-[a-z0-9-]+|\.gov\.il|gs://[a-z0-9]'

# owner/repo this checkout IS. `GITHUB_REPOSITORY` is set by Actions; the remote
# is the local fallback, and an empty value simply means the owner rule is not
# applied rather than that the gate reports something it did not measure.
SELF_SLUG="${GITHUB_REPOSITORY:-}"

resolve_self() {
  local url
  [ -n "$SELF_SLUG" ] && return 0
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || return 0
  url="${url%.git}"
  case "$url" in
    *[:/]*/*) SELF_SLUG="$(printf '%s' "$url" | sed 's#^.*[:/]\([^/:]*/[^/]*\)$#\1#')" ;;
  esac
  return 0
}

# ERE metacharacters in a value about to become a pattern. A repository name
# carries `.` routinely, and an unescaped `.` matches any character — which
# reads in the PASSING direction here, because a wider self-reference exempts
# more. `/` is deliberately NOT escaped: it is not an ERE metacharacter, and
# `\/` in an awk dynamic regex is an unknown escape that gawk warns about.
#
# Written character by character rather than as one `sed` bracket expression,
# because the bracket expression that spells this set is read differently by
# different seds — on one of the machines this repository is edited from it is
# rejected outright as an unterminated command. A failing `re_quote` returns the
# EMPTY string, which appends an empty alternative to the scan pattern and makes
# it match every line of every file: a quoting helper whose failure mode is
# "everything is a literal" is worse than no helper, and it fails in the
# direction that looks like the gate working very hard.
re_quote() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      '.'|'^'|'$'|'*'|'+'|'?'|'('|')'|'{'|'}'|'|'|'['|']'|'\\') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

# The full pattern, and the text that is allowed to contain the owner.
#
# Order matters in the scanner: this repository's own slug is REMOVED from a
# line before the line is matched, so `<owner>/ci-runner-infra` disappears while
# a bare `<owner>/SomeOtherRepo` keeps its owner and fails.
scan_pattern() {
  local owner="" quoted=""
  [ -n "$SELF_SLUG" ] && owner="${SELF_SLUG%%/*}"
  [ -n "$owner" ] && quoted="$(re_quote "$owner")"
  # The emptiness is re-tested AFTER quoting, not only before it. An empty
  # alternative (`…|gs://|`) matches every line of every file, so the one thing
  # this gate must never do is append one — see `re_quote`.
  if [ -n "$quoted" ]; then
    printf '%s|%s' "$PATTERN_STATIC" "$quoted"
  else
    printf '%s' "$PATTERN_STATIC"
  fi
}

# --- the scanner -------------------------------------------------------------
#
# One awk program for both file classes. `fenced_only` decides whether a line is
# eligible at all; the pattern decides whether it offends.
#
# Fence tracking is deliberately simple — a line whose first non-space run is
# ``` or ~~~ toggles — because the failure direction of getting it wrong is to
# scan MORE of the document, and a false positive in prose is a sentence to
# rewrite while a false negative in a snippet is a literal in fourteen
# repositories.
scan_file() {
  local file="$1" rel="$2" fenced_only="$3" id="$4" pattern="$5" strip="$6"
  local hits

  if [ ! -r "$file" ]; then
    err LIT0 "$rel: unreadable — a file this gate cannot open is not a file it checked"
    return
  fi

  # The pattern travels through the ENVIRONMENT, not through `-v`. `awk -v`
  # processes escape sequences in the value it is handed, so `\.gov\.il` would
  # arrive as `.gov.il` — every escaped dot silently widened to "any character",
  # with a warning on stderr nobody reads. `ENVIRON` hands the string over
  # unaltered.
  hits="$(PAT="$pattern" STRIP="$strip" FENCED="$fenced_only" awk '
    BEGIN { infence = 0; pat = ENVIRON["PAT"]; strip = ENVIRON["STRIP"]; fenced_only = ENVIRON["FENCED"] }
    {
      line = $0
      trimmed = line
      sub(/^[ \t]*/, "", trimmed)
      if (trimmed ~ /^(```|~~~)/) { infence = !infence; next }
      if (fenced_only == "1" && !infence) next
      if (strip != "") gsub(strip, "", line)
      if (line ~ pat) printf "%d\t%s\n", NR, substr(line, 1, 160)
    }
  ' "$file" 2>/dev/null)"

  [ -n "$hits" ] || return 0

  local n text
  while IFS=$'\t' read -r n text; do
    [ -n "$n" ] || continue
    err "$id" "$rel:$n: $text"
  done <<EOF
$hits
EOF
}

# Which rule a path answers to. Markdown is fenced-only (LIT2); everything else
# discovery hands over is read whole (LIT1).
check_file() {
  local file="$1" rel pattern strip=""
  rel="${file#"$ROOT"/}"

  case "$rel" in
    "$SELF_EXCLUDE") return 0 ;;
  esac

  pattern="$(scan_pattern)"
  [ -n "$SELF_SLUG" ] && strip="$(re_quote "$SELF_SLUG")"

  case "${rel,,}" in
    *.md|*.mdx) scan_file "$file" "$rel" 1 LIT2 "$pattern" "$strip" ;;
    *)          scan_file "$file" "$rel" 0 LIT1 "$pattern" "$strip" ;;
  esac
}

# --- fixtures ----------------------------------------------------------------
#
# The fixtures run FIRST and they run against a fake owner, so this gate's own
# tests carry no real organisation name. A config gate's characteristic failure
# is the vacuous pass — it reads a file it never matches and reports clean — so
# each detector is proved to fire before this repository's own tree is believed.
#
# shellcheck disable=SC2030  # each expectation scores inside `$( )` with its own
# `fail=0`; the subshell IS the isolation.
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"
  SELF_SLUG="acme/ci-runner-infra"

  expect() {
    local name="$1" want="$2" ext="$3" body="$4"
    local got out_text f="$tmp/fixture.$ext"
    printf '%s\n' "$body" > "$f"
    out_text="$(fail=0; ROOT="$tmp"; check_file "$f" 2>&1)"
    got="$(printf '%s\n' "$out_text" | sed -n 's/.*::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort -u | tr '\n' ' ')"
    got="$(printf '%s' "$got" | sed 's/ *$//')"
    if [ "$got" != "$want" ]; then
      echo "FAIL $name: want ids [$want], got [$got]"
      printf '%s\n' "$out_text" | sed 's/^/      /'
      status=1
    else
      echo "ok   $name [$want]"
    fi
  }

  # --- LIT1: the executable trees, unchanged in intent from the inline scan ---
  expect "a region in terraform" "LIT1" tf \
'variable "region" {
  default = "me-west1"
}'

  expect "a project prefix in shell" "LIT1" sh \
'project=mot-runner-prod'

  expect "a bucket url in hcl" "LIT1" hcl \
'state = "gs://some-bucket/path"'

  # The widening's first real finding was a FALSE one: `cloudbuild.yaml`
  # documents its own invocation with a placeholder staging bucket, which is a
  # value written down so nobody hardcodes theirs. The banned thing is a bucket
  # somebody owns, so the pattern asks for a bucket-name character.
  # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
  expect "a placeholder bucket is not a bucket" "" yml \
'# --gcs-source-staging-dir=gs://<bucket-in-an-allowed-location>/source
# or gs://${STAGING_BUCKET}/source'

  expect "a generic module is clean" "" tf \
'variable "region" {
  type = string
}'

  # --- LIT1: the file class the inline scan never read (issue #69) ------------
  #
  # A workflow is not documentation with a colon in it. Every line of it decides
  # what CI does, on which pool, in which project.
  expect "a region in workflow yaml" "LIT1" yml \
'jobs:
  apply:
    runs-on: ubuntu-latest
    env:
      REGION: me-west1'

  # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
  expect "a placeholder workflow is clean" "" yml \
'jobs:
  apply:
    runs-on: ubuntu-latest
    env:
      REGION: ${REGION}'

  # --- LIT2: Markdown, and the prose/fence distinction that is the whole rule -
  expect "a region inside a code fence" "LIT2" md \
'Set the region:

```hcl
region = "me-west1"
```'

  # The exemption, stated as a test so that removing it is a visible change
  # rather than a surprise: an incident reference is why a rule exists.
  expect "the same value in prose is evidence, not a leak" "" md \
'This was first seen on mot-face-blur #56, in the me-west1 pool.'

  expect "an inline code span is still prose" "" md \
'The peering to `mot-lz-vpc` goes through the central firewall.'

  expect "a tilde fence counts as a fence" "LIT2" md \
'~~~sh
gcloud config set project mot-runner-prod
~~~'

  expect "a fence that closes stops the scan" "" md \
'```sh
echo hello
```

Later prose about mot-face-blur #61.'

  # --- the owner rule --------------------------------------------------------
  expect "this module own address is not a leak" "" md \
'```hcl
source = "git::https://github.com/acme/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.8.0"
```'

  # …and the half that makes the exception narrow. Another repository under the
  # same owner is a different repository's path in a shared module.
  expect "another repository under the same owner still fails" "LIT2" md \
'```yaml
uses: acme/Apigee-Portal/.github/workflows/ci.yml@v1
```'

  expect "the owner in an executable tree is not exempt by class" "LIT1" sh \
'gh repo clone acme/Apigee-Portal'

  # A document that is all prose has nothing to scan, and that is a PASS with
  # nothing read — the one shape most likely to be a vacuous pass. Asserted so
  # the fence tracker cannot silently start treating everything as prose: the
  # test above ("a region inside a code fence") is what fails if it does.
  expect "a fenceless document is clean" "" md \
'No snippets here at all.'

  # --- LIT0 ------------------------------------------------------------------
  local missing="$tmp/does-not-exist.tf"
  local out_text got
  out_text="$(fail=0; ROOT="$tmp"; check_file "$missing" 2>&1)"
  got="$(printf '%s\n' "$out_text" | sed -n 's/.*::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort -u | tr -d '\n')"
  if [ "$got" = "LIT0" ]; then
    echo "ok   an unreadable file is reported, not passed [LIT0]"
  else
    echo "FAIL an unreadable file is reported, not passed: want [LIT0], got [$got]"
    status=1
  fi

  # --- the exclusion cannot grow ---------------------------------------------
  #
  # This gate must contain the values it bans, so it must skip itself. One path
  # is the price; a list of them is a hiding place, and the difference is one
  # careless commit wide.
  local n_excluded
  n_excluded="$(printf '%s\n' "$SELF_EXCLUDE" | grep -c .)"
  if [ "$n_excluded" -eq 1 ]; then
    echo "ok   the self-exclusion is exactly one path"
  else
    echo "FAIL the self-exclusion is $n_excluded paths — a denylist that skips a list of files is not a denylist"
    status=1
  fi

  rm -rf "$tmp"
  return "$status"
}

# --- discovery ---------------------------------------------------------------
#
# `git ls-files`, not `find`. The gate's subject is what the repository
# PUBLISHES, and a literal in an untracked scratch file is nobody's problem —
# while a `find` that walks `.terraform/` or a vendored provider reports on
# somebody else's code and gets the gate switched off.
discover() {
  git -C "$ROOT" ls-files -z -- \
    '*.tf' '*.tfvars' '*.hcl' '*.sh' '*.yml' '*.yaml' '*.md' '*.mdx' 2>/dev/null
}

# shellcheck disable=SC2031  # `fail` is read after the fixtures wrote their own
# copies inside subshells — intended, a fixture failure must not reach this exit
# status. On the real path `check_file` runs in this shell.
main() {
  local run_selftest=0 arg n=0
  local -a files=()

  for arg in "$@"; do
    case "$arg" in
      --selftest) run_selftest=1 ;;
      --self=*)   SELF_SLUG="${arg#--self=}" ;;
      --root=*)   ROOT="${arg#--root=}" ;;
      -*)         echo "::error::[LIT0] unknown option: $arg"; return 1 ;;
      *)          files+=("$arg") ;;
    esac
  done

  if [ "$run_selftest" -eq 1 ]; then
    selftest
    return
  fi

  resolve_self

  if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r -d '' arg; do
      [ -n "$arg" ] || continue
      files+=("$ROOT/$arg")
    done < <(discover)
  fi

  # Zero files is not a clean tree, it is this gate failing to run — a wrong
  # `--root`, a checkout without git metadata, or a `ls-files` that errored. The
  # vacuous pass, one level up from the one the fixtures guard against.
  if [ "${#files[@]}" -eq 0 ]; then
    echo "::error::[LIT0] no tracked file matched the scanned extensions — nothing was checked"
    return 1
  fi

  for arg in "${files[@]}"; do
    check_file "$arg"
    n=$((n + 1))
  done

  if [ "$fail" -eq 0 ]; then
    echo "generic literals clean: $n tracked file(s), owner rule ${SELF_SLUG:-not applied}"
  fi
  return "$fail"
}

main "$@"
