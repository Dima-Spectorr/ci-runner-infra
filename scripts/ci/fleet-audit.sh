#!/usr/bin/env bash
# fleet-audit — collect the facts for every repository in the fleet and run the
# rule in fleet-audit-decision.sh over them.
#
# This file is the IMPURE half: it talks to GitHub, and it holds no rule. Every
# judgement lives in the decision script beside it, which has a self-test — the
# split exists because the workflow that runs this cannot be exercised by the
# pull request that changes it.
#
#   scripts/ci/fleet-audit.sh                 # audit the whole manifest
#   scripts/ci/fleet-audit.sh IntegrateIT     # audit one repository
#   FLEET_OWNER=someone scripts/ci/fleet-audit.sh
#
# Exit status: 0 when nothing failed, 1 when any repository has a `fail:`
# finding, 2 when the audit could not run at all. Warnings never fail the run —
# a dry-run lane is a legitimate place to sit, and an audit that goes red for it
# is an audit people stop reading.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/fleet-audit-decision.sh"

# THE ACCOUNT IS DISCOVERED, NEVER WRITTEN DOWN. A literal owner here would be
# the same defect this repository's own `check-generic-literals.sh` refuses in
# every other executable file: the fleet is a product, and the account it audits
# is a deployment fact. In Actions the owner is in the environment; on a
# workstation it is whatever `origin` points at.
default_owner() {
  if [ -n "${GITHUB_REPOSITORY_OWNER:-}" ]; then
    printf '%s' "$GITHUB_REPOSITORY_OWNER"
    return 0
  fi
  git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#/.*$##'
}
OWNER="${FLEET_OWNER:-$(default_owner)}"
MANIFEST="${FLEET_MANIFEST:-$ROOT/fleet/repos.tsv}"
# The window the controller's demand sweep uses. A queued run older than this is
# one the sweep will never act on; see collect_demand() in controller-startup.sh.
DEMAND_MAX_AGE="${DEMAND_MAX_AGE:-21600}"
# The page the controller reads. Corpses are counted against it because the harm
# is proportional to it, not to an absolute number.
QUEUED_PAGE="${QUEUED_PAGE:-50}"
# How long a queued run is allowed to wait before its pool owes it a runner.
# These pools scale from zero: demand appears, the autoscaler reacts, a host
# boots, installs and registers — measured on this fleet, two to four minutes.
# A run queued more recently than this is not evidence of a pool that will not
# scale; it is a pool that has not finished scaling, and reporting it turns
# every repository with a fresh pull request red once a day.
DEMAND_GRACE="${DEMAND_GRACE:-900}"

# How long unreleased work may sit on the default branch. PASSED THROUGH
# UNCHANGED, with no default of its own: the number and the reasoning behind it
# live in fleet-audit-decision.sh, and a second copy here is a copy that drifts.
# Empty means "whatever the rule's default is"; `0` turns the watchdog off.
BACKLOG_MAX_HOURS="${BACKLOG_MAX_HOURS:-}"
# The released surfaces. A change outside these reaches consumers without a tag:
# `docs/`, `fleet/` and `.github/` are read from the default branch, and
# `packer/` is built by a push-to-branch Cloud Build trigger
# (modules/ci-host-image-trigger/main.tf) rather than through any `?ref=` pin.
RELEASED_SURFACE="${RELEASED_SURFACE:-^(modules|scripts)/}"
# How many commits of backlog are walked one-by-one for their file lists. A
# bounded walk, because one API call per commit against a tag that has not moved
# in months would be hundreds. Past the cap the age is reported as unknown
# rather than guessed — see backlog_facts().
#
# A NON-NUMERIC OVERRIDE MUST NOT REMOVE THE CAP. `[ "$n" -gt abc ]` is an
# ERROR, not a false: `test` writes "integer expression expected" and exits 2,
# the `if` reads that as "not past the cap", and the walk then makes one API
# call per commit with nothing bounding it — an operator's typo quietly turning
# a bounded audit into an unbounded one while it still reports facts. Refuse
# the value once, here, rather than once per commit on stderr.
BACKLOG_SCAN_MAX_DEFAULT=40
BACKLOG_SCAN_MAX="${BACKLOG_SCAN_MAX:-$BACKLOG_SCAN_MAX_DEFAULT}"
if ! _fleet_is_number "$BACKLOG_SCAN_MAX"; then
  echo "fleet-audit: BACKLOG_SCAN_MAX=\"$BACKLOG_SCAN_MAX\" is not a whole number;" \
       "using $BACKLOG_SCAN_MAX_DEFAULT" >&2
  BACKLOG_SCAN_MAX="$BACKLOG_SCAN_MAX_DEFAULT"
fi
# The tag the backlog is measured from. Empty — the normal case — derives it
# from VERSION's major, which is the ref consumers pin. An override exists so
# the collector can be exercised by hand against a tag that is known to be
# behind the default branch; on a healthy repository the derived tag is at the
# tip, so every code path past the first comparison would otherwise be dead on
# the only repository it ever runs against.
FLOATING_TAG="${FLOATING_TAG:-}"
# The repositories bound to the shared utility host, whose LIVE fork-PR setting
# is audited (#1704). A deployment fact, so it is an input and never a list in
# this file: comma-, space- or newline-separated, bare names (the owner above)
# or `owner/name`. Empty skips the check and says so in the report.
UTILITY_HOST_REPOS="${UTILITY_HOST_REPOS:-}"

# The preconditions for RUNNING the audit are asserted in the run section at the
# bottom, not here, because everything between is function definitions and the
# collector self-test sources this file for them with no `gh` and no account.

# api <path> — a GET that returns empty rather than dying. Every caller treats
# empty as UNKNOWN and the rule reports unknowns, so a failed read surfaces as a
# finding instead of a silent pass.
#
# `</dev/null` is load-bearing. `gh` reads standard input, so an `api` call
# inside a `while read` loop fed by a pipe eats the rest of that pipe: the loop
# runs once, or not at all, and prints nothing. It looks exactly like a query
# that returned no rows — which the rule would then report as "uncomparable"
# for every repository in the fleet.
api() { gh api "$1" </dev/null 2>/dev/null; }

# file_at <repo> <path> — the decoded contents of one file, or empty.
file_at() {
  local body
  body=$(api "repos/$OWNER/$1/contents/$2" | jq -r '.content // empty' 2>/dev/null) || return 0
  [ -z "$body" ] && return 0
  # `tr -d` first: the API wraps base64 at 60 columns, and on this platform the
  # newlines arrive as CRLF, which `base64 -d` rejects 45 bytes in.
  printf '%s' "$body" | tr -d '\r\n' | base64 -d 2>/dev/null
}

# --- fleet references: find every candidate, then demand the canonical form ---
#
# THE MATCHING IS INVERTED (#1716, security review round 4). Listing the shapes
# that count as a fleet call — `[A-Za-z0-9._-]+\.ya?ml@`, single slashes — let
# every shape outside the list read clean: `merge+lane.yml`, `m~l.yml`,
# `mergé.yml`, `merge lane.yml`, `ci-runner-infra//.github/…` (GitHub drops the
# empty segment) and `…/workflows/merge-lane@<sha>` (no extension), each pinned
# to an imposter, were COMPLIANT. So the scan now finds every CANDIDATE — any
# token that names `ci-runner-infra` (any case) and runs to an `@` — keeps the
# ones that also name `.github` and `workflows`, and requires each to FULLY
# match FLEET_CANON_ERE. A candidate that does not is `workflow-pin-not-a-sha`;
# one that does goes on to provenance. A new shape can only fail, never pass.
#
# THE TOKEN. It starts at the first character after whitespace, a quote, a
# bracket, a brace or a comma before `ci-runner-infra`, runs through anything
# but `@` and quotes (so a space, `+`, `~`, a doubled slash or a non-ASCII byte
# stays INSIDE it and fails the canonical match), then takes the ref after the
# `@` up to whitespace, a quote, a comma, a bracket or a brace. Bytes, not
# characters (LC_ALL=C), so a non-UTF-8 file cannot make grep skip a line.
#
# PROSE IS NOT A CALL. A line that names `ci-runner-infra/.github/workflows/<x>`
# with no `@` after it on the same line — a comment saying which callee a job
# uses, a docs URL (`…/ci-runner-infra/blob/main/.github/workflows/x.yml`) — is
# not a reference GitHub could resolve (a reusable-workflow call must carry
# `@<ref>`), so it yields no token and is not judged. A line that does carry an
# `@` after the name is judged even in a comment (see pins_in), so prose that
# writes `…/x.yml@v5`, or mentions an e-mail address after the name, fails:
# visible noise in the consumer's own file, never a silent pass.
FLEET_TOKEN_ERE="[^][[:space:]\"'{},]*ci-runner-infra[^@\"']*@[^][[:space:]\"',{}]*"
# Matched case-insensitively (grep -i): GitHub resolves the owner and the
# repository in any case, and the SHA is lowercased before it is compared.
FLEET_CANON_ERE='^[A-Za-z0-9-]+/ci-runner-infra/\.github/workflows/[^/@[:space:]]+@[0-9a-f]{40}$'

# fleet_tokens_in <text> — every candidate fleet reference in free text, one per
# line, in order (duplicates kept; callers de-duplicate).
fleet_tokens_in() {
  printf '%s\n' "$1" | tr -d '\r' | LC_ALL=C grep -oiE "$FLEET_TOKEN_ERE" \
    | LC_ALL=C grep -iF '.github' | LC_ALL=C grep -iF 'workflows'
}

# fleet_canonical / fleet_noncanonical — filter a token list (stdin) to the
# tokens that do / do not fully match FLEET_CANON_ERE.
fleet_canonical() { LC_ALL=C grep -iE "$FLEET_CANON_ERE"; }
fleet_noncanonical() { LC_ALL=C grep -viE "$FLEET_CANON_ERE"; }

# pins_in <file-contents> <callee-regex> — EVERY sha a file pins for the callee,
# one per line, lowercased, de-duplicated in first-appearance order (#1716).
# Only canonical tokens are pins; the callee regex is matched against the file
# name segment of one.
#
# EVERY MATCH, COMMENTS INCLUDED. A commented decoy pin (in history) above the
# real `uses:` line (an imposter) read as the pin when only the first match was
# taken. Stripping comments was tried and is WRONG: line-based YAML comment
# detection cannot see quoting, so `{name: "a #", uses: …@<imposter>}` and a
# `#`-led line inside a multi-line double-quoted scalar hid the real pin. With
# every match judged and the worst verdict winning, a decoy can only ADD a pin
# to judge, never hide one. A commented pin is therefore judged too (stale or
# foreign, it is reported) — visible noise, never a silent pass.
#
# THE SHA MUST END THERE. `@<40 hex>` followed by another ref character (`x`,
# `/`, `.`, `-`, `_`) is not a SHA pin — it is a branch or tag that starts like
# one — so it is not returned here; refs_not_sha_in reports it.
#
# CASE-INSENSITIVE on the path, and the SHA is lowercased. GitHub resolves an
# owner/repository in any case (measured 2026-11-06: `compare` on
# `CI-Runner-Infra` and on an upper-case SHA both answer `identical`), so a
# `CI-Runner-Infra/...@<sha>` pin is the same fleet call and must not slip past
# a lower-case match. Lowercasing is what lets the SHA pass is_sha and be
# compared; it is correct whether or not Actions itself accepts upper-case hex.
pins_in() {
  fleet_tokens_in "$1" | fleet_canonical \
    | LC_ALL=C grep -iE "/\.github/workflows/$2@[0-9a-f]{40}$" \
    | sed -E 's/.*@//' | tr 'A-F' 'a-f' | awk '!seen[$0]++'
}

# canonical_shas <token-list> — the lowercased SHA of every canonical token,
# de-duplicated in first-appearance order.
canonical_shas() {
  printf '%s\n' "$1" | fleet_canonical | sed -E 's/.*@//' | tr 'A-F' 'a-f' | awk '!seen[$0]++'
}

# refs_not_sha_in <file-contents> — every candidate fleet reference that is NOT
# in canonical form, whole, one per line, de-duplicated: a tag, a branch,
# `refs/pull/N/head`, a short SHA, `<40 hex>x`, an empty ref, a doubled slash,
# a callee name with a character outside the canonical set's reach.
refs_not_sha_in() {
  fleet_tokens_in "$1" | fleet_noncanonical | awk '!seen[$0]++'
}

# obfuscated_in <file-contents> — 1 when a line could spell a fleet reference
# through a YAML double-quoted escape, nothing otherwise. A backslash in such a
# scalar can write any character (`c\x69-runner-infra`) or join two lines
# (`@bbbb\` + newline + `bbbb`), and neither pins_in nor refs_not_sha_in can see
# through it. The rule, chosen to be quiet on real workflows: a backslash on a
# line that (case-insensitively) holds a `uses:` key, the text `runner-infra`
# or `.github/workflows`, or that follows a `uses:` whose value starts on the
# next line. A `uses:` value never needs a backslash, and the other two strings
# appear in shell `run:` text far less often than escapes do in general.
obfuscated_in() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    { l = tolower($0); bs = index($0, "\\") > 0
      if (bs && (l ~ /uses[ \t"'\'']*:/ || l ~ /runner-infra/ || l ~ /\.github\/workflows/ || next_is_value)) found = 1
      if (l ~ /uses[ \t"'\'']*:[ \t]*([>|][-+0-9]*)?[ \t]*$/) next_is_value = 1
      else if (l !~ /^[ \t]*$/) next_is_value = 0 }
    END { if (found) print 1 }'
}

# --- the decoded layer (#1716, security review round 3) -----------------------
# Every check above reads the file AS TEXT, and YAML is not text: `"uses"`
# is the key `uses`, `ci-runner-infra` is `ci-runner-infra`, `\x2f` is `/`,
# a `uses:` value can sit under a comment on the next line, and `? uses` /
# `: "…"` is an explicit key. Each of those spelled a fleet call no grep saw.
# So every workflow is also DECODED with a real YAML parser. Two kinds of string
# leave it (decoded_fleet_refs):
#   - the VALUE of any `uses` key (any case, surrounding whitespace ignored)
#     that names `ci-runner-infra`, `.github` and `workflows`: that string IS
#     what GitHub reads, so it is a candidate WHOLE — a space, a quote or an
#     `@`-less value inside it fails the canonical match rather than splitting
#     the token. (Only a str value: a `!!binary` or other tagged node is not a
#     call GitHub accepts.)
#   - every other string (keys and values, anchors resolved, every document in
#     the stream) that names `ci-runner-infra`: free text, tokenized exactly
#     like a raw line (fleet_tokens_in).
# The literal scan stays as the first layer, so a commented pin (which a parser
# drops) is still judged.
#
# The parser is PyYAML, the reader check-runner-policy.sh already depends on;
# py_usable/ensure_yaml are that script's (copied, not sourced: sourcing it
# runs the gate). The audit job makes PyYAML a precondition and stops if it
# cannot install it. A missing parser, or a file it cannot load, FAILS the
# repository (`workflow-pin-yaml-parser-unavailable`, `workflow-pin-unparsed`):
# GitHub runs a file the audit could not decode, so it can never read clean.
export PY_BIN="${PY_BIN:-}"
py_usable() {
  command -v "$1" >/dev/null 2>&1 &&
    "$1" -I -c 'import sys, yaml; sys.exit(0 if sys.version_info >= (3, 7) else 1)' >/dev/null 2>&1
}

ensure_yaml() {
  local c
  if [ -n "$PY_BIN" ]; then
    py_usable "$PY_BIN" && return 0
    PY_BIN=""
  fi
  for c in python3 /usr/bin/python3 /usr/bin/python /usr/local/bin/python3 python; do
    if py_usable "$c"; then
      PY_BIN="$c"
      return 0
    fi
  done
  return 1
}

# The decoder. The workflow arrives on stdin (no argv size limit). Each string
# leaves on its own line with its whitespace collapsed (so a newline inside a
# value cannot split it), prefixed `U ` for a whole `uses` value and `S ` for
# free text; a document that does not load prints `#ERR` alone. The walk is
# breadth-first in document order and tracks containers by id, because a YAML
# alias can make the structure recursive.
DECODE_PY='
import sys
from collections import deque
import yaml
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n", encoding="utf-8")
def names_fleet(s):
    return "ci-runner-infra" in s.lower()
def names_call(s):
    low = s.lower()
    return "ci-runner-infra" in low and ".github" in low and "workflows" in low
try:
    docs = list(yaml.safe_load_all(sys.stdin.buffer.read().decode("utf-8")))
except Exception:
    print("#ERR")
    sys.exit(0)
seen, queue = set(), deque(docs)
while queue:
    node = queue.popleft()
    if isinstance(node, (dict, list)):
        if id(node) in seen:
            continue
        seen.add(id(node))
        if isinstance(node, dict):
            for key, value in node.items():
                if (isinstance(key, str) and key.strip().lower() == "uses"
                        and isinstance(value, str) and names_call(value)):
                    print("U " + " ".join(value.split()))
                queue.append(key)
                queue.append(value)
        else:
            queue.extend(node)
    elif isinstance(node, str) and names_fleet(node):
        print("S " + " ".join(node.split()))
'

# The decoder's bounds. A workflow larger than this is not decoded (it is
# reported unparsed), and a decode that runs longer than DECODE_TIMEOUT seconds is killed and
# reported the same way. Neither bound can make a file read clean.
DECODE_MAX_BYTES=1048576
DECODE_TIMEOUT=30

# decoded_fleet_refs <file-contents> — the candidate fleet references the
# parser sees, one per line, de-duplicated, or `#ERR` when the document does not
# load (or is too large, or the decode timed out). Needs ensure_yaml.
decoded_fleet_refs() {
  local bytes out
  bytes=$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')
  if [ "${bytes:-0}" -gt "$DECODE_MAX_BYTES" ]; then
    echo "#ERR"
    return 0
  fi
  # `head -c` as well as the size check: the check guards the verdict (a cut
  # document could load and silently drop its tail), the cap guards the parser.
  out=$(printf '%s' "$1" | head -c "$DECODE_MAX_BYTES" \
          | timeout "$DECODE_TIMEOUT" "${PY_BIN:-python3}" -I -c "$DECODE_PY" 2>/dev/null) || out="#ERR"
  if printf '%s\n' "$out" | grep -cx '#ERR' >/dev/null; then
    echo "#ERR"
    return 0
  fi
  {
    printf '%s\n' "$out" | sed -n 's/^U //p'
    fleet_tokens_in "$(printf '%s\n' "$out" | sed -n 's/^S //p')"
  } | grep -v '^$' | awk '!seen[$0]++'
}

# pin_in <file-contents> <callee> — the first pin. Both the stale rule and
# provenance judge EVERY pin, through `<caller>_pins` and pins_history.
pin_in() {
  pins_in "$1" "$2" | sed -n 1p
}

# --- pin provenance (#1715) ------------------------------------------------------
#
# A 40-hex pin is NOT proof the code came from the fleet repository. GitHub
# resolves `<owner>/ci-runner-infra/...@<sha>` for a commit that exists only in
# a FORK of it (an "imposter commit"): forks share object storage, so a caller
# can pin code nobody reviewed here and RUNNER18 — which checks the owner and
# the SHA's shape — accepts it. What proves provenance is reachability: the
# pinned commit is an ancestor of (or equal to) the fleet's default branch.
#
# `compare/<branch>...<sha>` answers in the head's terms, measured 2026-11-06
# against this repository: an older default-branch commit reads `behind`, the
# tip reads `identical`; a commit with work the branch lacks reads `ahead` or
# `diverged`; a SHA the repository's network does not hold is a 404.

# fleet_history_branch — the fleet repository's default branch, or empty when
# the token cannot read the fleet repository at all. Read ONCE, before any
# compare: under a token that cannot see the fleet repository every compare is a
# 404, and a 404 is otherwise the imposter answer. Without this check an App
# not installed on the fleet repository would fail every consumer in the fleet.
fleet_history_branch() {
  api "repos/$OWNER/ci-runner-infra" | jq -r '.default_branch // empty' 2>/dev/null | tr -d '\r'
}

# history_of_compare <compare-body> — 1 when the head is reachable from the
# base, 0 when it is not (or does not exist there), empty when the body is
# anything else. `.status` carries both answers: the comparison's own word on a
# success, and gh's error document's HTTP code ("404") on a refusal.
history_of_compare() {
  local status
  status=$(printf '%s' "${1:-}" | jq -r 'if type=="object" then (.status // empty | tostring) else empty end' 2>/dev/null | tr -d '\r')
  case "$status" in
    behind|identical) echo 1 ;;
    ahead|diverged|404) echo 0 ;;
    # 403, 422, 5xx, an empty body: a read that failed, never a verdict.
    *) : ;;
  esac
}

# pin_in_history <sha> — 1 / 0 / empty (unknown) for one pinned commit.
#
# CACHED PER SHA FOR THE RUN. Most of the fleet pins the same release, so one
# compare answers every repository. The cache is a directory, not a variable:
# facts_for runs inside `$(…)`, and a variable set in a subshell is gone when it
# returns. Empty when FLEET_HISTORY_BRANCH is empty — the fleet repository was
# unreadable, so no answer here could be told apart from a refusal.
pin_in_history() {
  local sha="${1:-}" cache="${PIN_HISTORY_CACHE:-}" branch="${FLEET_HISTORY_BRANCH:-}" verdict
  is_sha "$sha" || return 0
  [ -n "$branch" ] || return 0
  if [ -n "$cache" ] && [ -f "$cache/$sha" ]; then
    cat "$cache/$sha"
    return 0
  fi
  verdict=$(history_of_compare "$(api "repos/$OWNER/ci-runner-infra/compare/$branch...$sha")")
  [ -n "$cache" ] && [ -d "$cache" ] && printf '%s' "$verdict" > "$cache/$sha"
  printf '%s' "$verdict"
}

# pins_history <sha-list> — "<verdict> <sha>" for a newline-separated list:
# the WORST verdict and the pin it names. Any pin not in history is 0; else any
# unknown is empty; else 1, naming the first pin. Nothing for an empty list.
pins_history() {
  local sha v worst=1 named="" first=""
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    [ -z "$first" ] && first="$sha"
    v=$(pin_in_history "$sha")
    case "$v" in
      1) : ;;
      0) worst=0; named="$sha"; break ;;
      *) [ "$worst" = "1" ] && { worst=""; named="$sha"; } ;;
    esac
  done <<< "${1:-}"
  [ -z "$first" ] && return 0
  printf '%s %s' "$worst" "${named:-$first}"
}

# caller_pin_facts <prefix> <file-contents> <callee-regex> — the named caller's
# facts: `<prefix>_pin` (the first pin), `<prefix>_pins` (EVERY pin,
# comma-separated, which the stale rule judges — worst wins), its provenance
# over every pin, and `<prefix>_history_pin`, the pin that verdict names.
caller_pin_facts() {
  local pins r
  pins=$(pins_in "$2" "$3")
  r=$(pins_history "$pins")
  printf '%s_pin=%s;%s_pins=%s;%s_pin_in_history=%s;%s_history_pin=%s' \
    "$1" "$(printf '%s\n' "$pins" | sed -n 1p)" \
    "$1" "$(printf '%s\n' "$pins" | paste -sd, -)" \
    "$1" "${r%% *}" "$1" "${r#* }"
}

# --- every workflow's fleet pins (#1716) -----------------------------------------
#
# The named callers above are four files. Any other workflow can call a fleet
# reusable workflow at an imposter SHA, so every `.github/workflows/*.y(a)ml`
# is read, every candidate fleet reference in it must be canonical, and every
# canonical one is judged for provenance. Cost: one read per workflow file not already
# read for the named callers (WORKFLOW_TEXT), plus one compare per DISTINCT SHA
# in the run (pin_in_history's cache) — the listing is the one facts_for has.
declare -A WORKFLOW_TEXT=()

# workflow_pin_facts <repo> <workflow-names> — the scan's facts:
#   wf_scanned=1, wf_pins (count of file/pin pairs), wf_pin_in_history (worst
#   verdict: 0 / "" / 1), wf_history_pin (the pin it names), wf_history_files
#   (the files holding a pin with that verdict), wf_unread (files whose read
#   came back empty — an unread file is unscanned, never clean), wf_refused
#   (names not safe to put in a URL or a fact, also unscanned), wf_not_sha
#   (files holding a candidate fleet reference not in canonical form —
#   FLEET_CANON_ERE), wf_obfuscated (files where an escape could spell one —
#   obfuscated_in), wf_unparsed (files the YAML parser could not load: their
#   literal text is still judged, and the file FAILS), wf_no_parser (1 when no
#   PyYAML was found, so no file was decoded: FAILS).
#   facts_for adds wf_listing_unreadable=1 instead when the listing failed or
#   came back truncated.
workflow_pin_facts() {
  local repo="$1" names="$2" name text tokens pins sha v count=0 refused=0
  local unread="" bad="" bad_files="" unk="" unk_files="" not_sha="" obf=""
  local unparsed="" no_parser=0 decoded
  ensure_yaml || no_parser=1
  while IFS= read -r name; do
    name="${name%$'\r'}"
    # Any case: `CI.YML` runs exactly like `ci.yml`, so it is scanned too.
    case "${name,,}" in *.yml|*.yaml) ;; *) continue ;; esac
    if ! printf '%s' "$name" | grep -cE '^[A-Za-z0-9._-]+$' >/dev/null; then
      refused=$((refused + 1))
      continue
    fi
    if [ -n "${WORKFLOW_TEXT[$name]+set}" ]; then
      text="${WORKFLOW_TEXT[$name]}"
    else
      text=$(file_at "$repo" ".github/workflows/$name")
    fi
    if [ -z "$text" ]; then
      unread="${unread:+$unread,}$name"
      continue
    fi
    # The literal text's candidates first (comments count), then the parser's.
    # The decoded candidates are ALREADY tokens and are not re-tokenized: a
    # whole `uses` value may hold a quote or a space that would split it.
    tokens=$(fleet_tokens_in "$text")
    if [ "$no_parser" = "0" ]; then
      decoded=$(decoded_fleet_refs "$text")
      if printf '%s\n' "$decoded" | grep -cx '#ERR' >/dev/null; then
        # A file that does not load yields NO decoded candidates, even when
        # the decoder printed some before it failed (a decode killed by the
        # timeout): strings from a document the parser rejected are not what
        # GitHub would read, so half of them is neither a verdict nor safe to
        # pass. The file is FAILED as unparsed instead, and its literal text is
        # still judged above, so a visible bad pin in it is reported as well.
        unparsed="${unparsed:+$unparsed,}$name"
      else
        tokens="$tokens"$'\n'"$decoded"
      fi
    fi
    tokens=$(printf '%s\n' "$tokens" | grep -v '^$' | awk '!seen[$0]++')
    [ -n "$(printf '%s\n' "$tokens" | fleet_noncanonical)" ] && not_sha="${not_sha:+$not_sha,}$name"
    [ -n "$(obfuscated_in "$text")" ] && obf="${obf:+$obf,}$name"
    pins=$(canonical_shas "$tokens")
    while IFS= read -r sha; do
      [ -z "$sha" ] && continue
      count=$((count + 1))
      v=$(pin_in_history "$sha")
      case "$v" in
        1) : ;;
        0) [ -z "$bad" ] && bad="$sha"
           case ",$bad_files," in *",$name,"*) ;; *) bad_files="${bad_files:+$bad_files,}$name" ;; esac ;;
        *) [ -z "$unk" ] && unk="$sha"
           case ",$unk_files," in *",$name,"*) ;; *) unk_files="${unk_files:+$unk_files,}$name" ;; esac ;;
      esac
    done <<< "$pins"
  done <<< "$names"
  local verdict=1 named="" files=""
  if [ -n "$bad" ]; then verdict=0; named="$bad"; files="$bad_files"
  elif [ -n "$unk" ]; then verdict=""; named="$unk"; files="$unk_files"
  fi
  printf 'wf_scanned=1;wf_pins=%s;wf_pin_in_history=%s;wf_history_pin=%s;wf_history_files=%s;wf_unread=%s;wf_refused=%s;wf_not_sha=%s;wf_obfuscated=%s;wf_unparsed=%s;wf_no_parser=%s' \
    "$count" "$verdict" "$named" "$files" "$unread" "$refused" "$not_sha" "$obf" "$unparsed" "$no_parser"
}

# --- the two-file lane (#1380, #1382) ------------------------------------------
#
# A private consumer's lane is `merge-lane.yml` (CI completions, pool label) and
# `merge-lane-events.yml` (everything else, hosted), woken on a review by
# `merge-lane-review-relay.yml`. Three things drift between those files and
# nothing in the consumer says so: the events file's pin, the relay's `name:`
# against the events file's `workflows:` entry (a rename detaches the wake-up
# silently), and the two `with:` blocks, which must be the same lane reached two
# ways. Pure text functions, so the collector self-test holds them.

# workflow_name_of <text> — the top-level `name:`, unquoted; empty if absent.
workflow_name_of() {
  printf '%s\n' "$1" | tr -d '\r' | grep -m1 -E '^name:' |
    sed -E "s/^name:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/"
}

# workflow_run_names_of <text> — one line per name in `workflow_run.workflows`,
# inline `[a, b]` or a YAML sequence, unquoted.
workflow_run_names_of() {
  # No interval expressions and no POSIX classes inside awk: the hosted image's
  # default awk is not guaranteed to be gawk.
  printf '%s\n' "$1" | tr -d '\r' | grep -vE '^[[:space:]]*#' | awk '
    /^  workflow_run:/                 { wr = 1; next }
    wr && /^  [^ ]/                    { wr = 0 }
    wr && /^[^ ]/                      { wr = 0 }
    wr && /^    workflows:/            { ws = 1
                                         line = $0
                                         sub(/^    workflows:[ \t]*/, "", line)
                                         sub(/[ \t]+#.*$/, "", line)
                                         if (line ~ /^\[/) {
                                           sub(/^\[/, "", line); sub(/\][ \t]*$/, "", line)
                                           n = split(line, parts, ",")
                                           for (i = 1; i <= n; i++) print parts[i]
                                           ws = 0
                                         }
                                         next }
    wr && ws && /^      - /            { line = $0; sub(/^      - /, "", line)
                                         sub(/[ \t]+#.*$/, "", line); print line; next }
    wr && ws                           { ws = 0 }
  ' | sed -E "s/^[[:space:]]+//; s/[[:space:]]+$//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/" | grep -v '^$'
}

# relay_agrees <events-text> <relay-text> — 1 when the relay's `name:` is one of
# the names the events file's `workflow_run` hears, 0 when it is not, empty when
# either side could not be read.
relay_agrees() {
  local name heard
  [ -n "$1" ] && [ -n "$2" ] || return 0
  name=$(workflow_name_of "$2")
  [ -n "$name" ] || return 0
  heard=$(workflow_run_names_of "$1")
  # Nothing heard is the PARSER's silence as often as the file's: an indent or
  # a list form it does not read yields the same empty list. Unknown, never a
  # mismatch — docs/fleet-audit.md: an unread fact is a warning, not a fail.
  [ -n "$heard" ] || return 0
  if printf '%s\n' "$heard" | grep -cxF -- "$name" >/dev/null; then echo 1; else echo 0; fi
}

# lane_with_of <text> — the lane job's `with:` block, comments, blank lines and
# the `runs-on:` key removed: the one input the two files legitimately differ in.
lane_with_of() {
  # A line indented four spaces or fewer ends the block. Blank lines and
  # full-line comments do not — they are dropped BEFORE the indentation test,
  # so a comment at any indent inside the block can neither end it nor count.
  # A trailing ` # …` is stripped from each kept line.
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^    with:[ \t]*(#.*)?$/  { w = 1; next }
    w && /^[ \t]*(#.*)?$/      { next }
    w                          { match($0, /^ */); if (RLENGTH <= 4) w = 0 }
    w                          { sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, ""); print }
  ' | grep -vE '^      runs-on:'
}

# with_agrees <lane-text> <events-text> — 1 when the two `with:` blocks are the
# same apart from `runs-on`, 0 when they differ, empty when either is unread.
with_agrees() {
  local a b
  a=$(lane_with_of "$1")
  b=$(lane_with_of "$2")
  [ -n "$a" ] && [ -n "$b" ] || return 0
  if [ "$a" = "$b" ]; then echo 1; else echo 0; fi
}

# want_pin — the commit every caller should pin: the tag this repository's
# VERSION names, dereferenced. NOT the tag name and NOT the floating `v5`: a
# caller runs on hosts holding a GCP identity, so it pins an immutable commit.
resolve_want_pin() {
  local version
  version=$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null)
  [ -z "$version" ] && return 0
  # VERSION carries its own `v`. Prepending a second one produced `vv5.75.0`
  # and a 422, which the rule then reported as an unknown pin for every
  # repository in the fleet — an audit-wide false negative from one character.
  # Stripping and re-adding normalises both spellings.
  api "repos/$OWNER/ci-runner-infra/commits/v${version#v}" \
    | jq -r '.sha // empty' 2>/dev/null | tr -d '\r'
}

# checks_agree <lane-file> <repo> — 1 when the caller's required-checks list and
# the default branch's ruleset name the same checks, 0 when they differ, empty
# when either side could not be read.
#
# THE TWO LISTS ARE SEPARATE EDITS AND NEITHER READS THE OTHER. A name in only
# one of them is silent in both directions, and a name in neither that no
# workflow emits blocks every merge with nothing anywhere going red.
checks_agree() {
  local lane="$1" repo="$2" from_lane from_ruleset
  # The block ends at the first line indented no deeper than the key itself.
  # Matching on "the next thing that looks like a key" instead swallowed the
  # comment block underneath, and these callers carry more comment than YAML —
  # the extracted list came back as fifteen lines of English and compared
  # unequal to every ruleset on earth.
  from_lane=$(printf '%s' "$lane" \
    | awk '/^ *required-checks: *\|/ { key = match($0, /[^ ]/); f = 1; next }
           !f { next }
           /^ *$/ { next }
           /^ *#/ { next }
           { here = match($0, /[^ ]/) }
           here <= key { f = 0; next }
           { sub(/^ +/, ""); print }' | tr -d '\r' | sort -u)
  [ -z "$from_lane" ] && return 0

  # The ids are captured into a variable and walked with `for`, NOT piped into
  # a `while read` that calls `gh` again. That shape returns nothing here: the
  # loop body's `gh` and the loop share a standard input, and the result is an
  # empty list indistinguishable from a repository with no ruleset at all.
  #
  # Both sides are stripped of carriage returns before they are compared. On a
  # Windows workstation `jq` terminates its lines with CRLF while the awk side
  # does not, so `ci` and `ci\r` compared unequal and the audit reported a
  # required-check disagreement on a repository whose two lists were identical.
  # A comparison that reports differently depending on the machine it ran on is
  # the same defect as no comparison at all.
  local ids id
  local -a idlist=()
  ids=$(api "repos/$OWNER/$repo/rulesets?includes_parents=false" \
    | jq -r '.[].id // empty' 2>/dev/null | tr -d '\r')
  [ -z "$ids" ] && return 0
  mapfile -t idlist <<< "$ids"
  from_ruleset=$(
    for id in "${idlist[@]}"; do
      api "repos/$OWNER/$repo/rulesets/$id" \
        | jq -r '.rules[]?
                 | select(.type=="required_status_checks")
                 | .parameters.required_status_checks[]?.context // empty' 2>/dev/null
    done | tr -d '\r' | sort -u
  )
  [ -z "$from_ruleset" ] && return 0

  if [ "$from_lane" = "$from_ruleset" ]; then echo 1; else echo 0; fi
}

# queue_facts <repo> — prints `<corpses> <demand> <settled>`, or nothing if any
# read failed. Corpses are queued runs the demand sweep will never act on;
# demand is the queued runs inside the window, which is what the controller
# scales on; settled is the subset of that demand old enough that a healthy
# pool would already be serving it.
#
# ALL THREE, FROM ONE PLACE, BECAUSE THE POOL RULE NEEDS THEM TOGETHER. A pool
# with no registered runners is the normal state of a healthy pool — these
# scale to zero — and is a failure only when something has been waiting for it
# longer than it takes to boot a host.
queue_facts() {
  local total recent settled since until_
  total=$(api "repos/$OWNER/$1/actions/runs?status=queued&per_page=$QUEUED_PAGE" \
          | jq -r '.total_count // empty' 2>/dev/null)
  [ -z "$total" ] && return 0
  # `gh api` hands the path to curl verbatim, so `>=` and the timestamp's colons
  # are encoded here rather than by a library.
  since=$(date -u -d "@$(( $(date -u +%s) - DEMAND_MAX_AGE ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  until_=$(date -u -d "@$(( $(date -u +%s) - DEMAND_GRACE ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  { [ -z "$since" ] || [ -z "$until_" ]; } && return 0
  recent=$(api "repos/$OWNER/$1/actions/runs?status=queued&per_page=$QUEUED_PAGE&created=%3E%3D${since//:/%3A}" \
           | jq -r '.total_count // empty' 2>/dev/null)
  [ -z "$recent" ] && return 0
  # The range is the whole point: inside the controller's window AND outside the
  # boot grace. A run in neither is not the pool's debt yet.
  settled=$(api "repos/$OWNER/$1/actions/runs?status=queued&per_page=$QUEUED_PAGE&created=${since//:/%3A}..${until_//:/%3A}" \
            | jq -r '.total_count // empty' 2>/dev/null)
  [ -z "$settled" ] && return 0
  echo "$(( total - recent )) $recent $settled"
}

# floating_tag — the major tag consumers pin, derived from VERSION rather than
# written down. A literal `v5` here would be a version literal in a file that
# outlives the major, and it would keep reading a tag that stopped moving.
floating_tag() {
  local version
  version=$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null)
  [ -z "$version" ] && return 0
  version="${version#v}"
  [ -z "${version%%.*}" ] && return 0
  printf 'v%s' "${version%%.*}"
}

# is_sha <string> — a full, lowercase object name and nothing else.
is_sha() {
  [ "${#1}" = 40 ] || return 1
  [ -z "$(printf '%s' "$1" | tr -d '0-9a-f')" ]
}

# epoch_of <timestamp> — seconds since the epoch, or nothing at all.
#
# `date -u -d "" +%s` DOES NOT FAIL. GNU date reads an empty argument as today
# at midnight UTC and exits 0 — measured on this machine, an empty string
# yielded 1789776000 — so a field a `// empty` filter declined to produce comes
# back as a perfectly plausible timestamp a few hours old. Fed to the backlog
# clamp below, that rewrote a four-hundred-hour-old commit as fifteen hours old
# and reported the repository compliant: a missing fact rendering as a clean
# bill of health, which is #960's own defect rebuilt one layer down.
#
# BOTH ENDS ARE CHECKED, because neither alone is enough: the input must be
# non-empty before `date` sees it, and the output must be a number afterwards,
# since a parse failure on some inputs prints to stderr and leaves nothing while
# on others it does not fail at all.
epoch_of() {
  local out
  [ -n "${1:-}" ] || return 0
  out=$(date -u -d "$1" +%s 2>/dev/null) || return 0
  _fleet_is_number "$out" || return 0
  printf '%s' "$out"
}

# backlog_facts <repo> — how much finished work is sitting on the default branch
# that no consumer can reach yet, and how old the oldest of it is.
#
# THE TAG IS READ FROM THE API, NEVER FROM THE CHECKOUT. `git fetch --tags` does
# not move a local tag that already exists, so a workspace that has ever fetched
# `v5` keeps whatever it saw first — and a floating tag is the one ref where
# that is guaranteed to be wrong. It fails in BOTH directions: a stale local tag
# behind the real one invents a backlog that was published days ago, and a local
# tag ahead of it (a fetch from a workspace that pushed one) reports an empty
# backlog while real work sits unreleased. `--force` would fix the fetch and not
# the class of bug; reading the ref the consumer reads cannot be stale at all.
#
# The tag is ANNOTATED — publish-tag.yml creates it that way — so `git/ref`
# answers with the tag object, and the commit is one dereference further in.
# Comparing the tag object's own sha against the branch is a comparison between
# two different kinds of object, which the compare endpoint answers with a 404
# that would read here as "could not compare" every single day.
#
# Prints a fact string; `tag_readable=0` on any failure to resolve the tag,
# which the rule treats as a failure rather than an empty backlog.
backlog_facts() {
  local repo="$1" tag ref otype sha head cmp ahead
  tag="${FLOATING_TAG:-$(floating_tag)}"
  [ -z "$tag" ] && { printf 'tag_readable=0'; return 0; }

  ref=$(api "repos/$OWNER/$repo/git/ref/tags/$tag")
  otype=$(printf '%s' "$ref" | jq -r '.object.type // empty' 2>/dev/null | tr -d '\r')
  sha=$(printf '%s' "$ref" | jq -r '.object.sha // empty' 2>/dev/null | tr -d '\r')
  case "$otype" in
    tag) sha=$(api "repos/$OWNER/$repo/git/tags/$sha" | jq -r '.object.sha // empty' 2>/dev/null | tr -d '\r') ;;
    commit) : ;;
    # Neither, which includes the empty body a 404 leaves behind. "Resolves to
    # something unexpected" and "does not resolve" are the same finding: the
    # audit cannot bound the backlog either way.
    *) sha="" ;;
  esac
  is_sha "$sha" || { printf 'tag_readable=0'; return 0; }

  head=$(api "repos/$OWNER/$repo" | jq -r '.default_branch // empty' 2>/dev/null | tr -d '\r')
  [ -z "$head" ] && { printf 'tag_readable=1'; return 0; }

  cmp=$(api "repos/$OWNER/$repo/compare/$sha...$head?per_page=100")
  ahead=$(printf '%s' "$cmp" | jq -r '.ahead_by // empty' 2>/dev/null | tr -d '\r')
  # Empty, not zero. `.ahead_by // empty` on a refusal body yields nothing, and
  # reading that as zero is precisely the "backlog is empty" answer this
  # function must never give by accident.
  [ -z "$ahead" ] && { printf 'tag_readable=1'; return 0; }
  [ "$ahead" = "0" ] && { printf 'tag_readable=1;backlog=0;backlog_hours=0'; return 0; }

  # THE BACKLOG CLOCK CANNOT START BEFORE THE TAG MOVED. A commit's own date is
  # when it was written, which on a branch that sat open for a week is earlier
  # than the day it landed. Nothing can have been waiting for publication longer
  # than the current tag has been the current tag, so the tag's commit date is
  # the floor — free, from the compare response that was fetched anyway.
  local base_ts now_ts
  base_ts=$(epoch_of "$(printf '%s' "$cmp" | jq -r '.base_commit.commit.committer.date // empty' 2>/dev/null | tr -d '\r')")
  now_ts=$(date -u +%s)

  # THE CHEAP ANSWER FIRST. The compare response already carries the union of
  # every file changed across the range, so a range that touches no released
  # surface at all is settled without a single further call — which is the
  # common case on a documentation-only day.
  #
  # ONLY WHEN THE UNION IS ACTUALLY THERE. Two different bodies produce a zero
  # count and they mean opposite things: a complete `files` array in which
  # nothing matches, and no `files` key at all. The second is what a truncated,
  # refused or unexpected response looks like, and taking the shortcut on it
  # printed `backlog=0` for a range that was five commits ahead. So a non-empty
  # array is required before the shortcut may be taken, and anything else falls
  # through to the walk, which reads each commit for itself. The upper bound is
  # a separate hazard: the endpoint caps `files` at 300, and "no match in the
  # first 300" is not "no match".
  local nfiles nmatch
  nfiles=$(printf '%s' "$cmp" | jq -r '(.files // []) | length' 2>/dev/null | tr -d '\r')
  nmatch=$(printf '%s' "$cmp" | jq -r '(.files // [])[].filename // empty' 2>/dev/null \
           | tr -d '\r' | grep -cE "$RELEASED_SURFACE")
  if _fleet_is_number "$nfiles" && [ "$nfiles" -gt 0 ] && [ "$nfiles" -lt 300 ] \
     && [ "${nmatch:-0}" = "0" ]; then
    printf 'tag_readable=1;backlog=0;backlog_hours=0'
    return 0
  fi

  # Otherwise one commit at a time, OLDEST FIRST — which is the order compare
  # returns them in, and the order the rule needs, because the finding is about
  # the oldest thing waiting rather than how many things are waiting.
  local entries
  entries=$(printf '%s' "$cmp" \
    | jq -r '(.commits // [])[] | "\(.sha) \(.commit.committer.date)"' 2>/dev/null | tr -d '\r')
  [ -z "$entries" ] && { printf 'tag_readable=1'; return 0; }
  local -a list=()
  mapfile -t list <<< "$entries"

  local entry csha cdate cts body hits n=0 count=0 oldest="" capped=0 unread=0 skew=0 undated=0
  for entry in "${list[@]}"; do
    [ -z "$entry" ] && continue
    n=$((n + 1))
    if [ "$n" -gt "$BACKLOG_SCAN_MAX" ]; then capped=1; break; fi
    csha="${entry%% *}"
    cdate="${entry#* }"

    # A COMMIT WHOSE FILE LIST DID NOT ARRIVE IS NOT A COMMIT THAT TOUCHED
    # NOTHING. `api` answers a failure with an empty body, `jq` then yields no
    # filenames, and the match count is zero — the same zero a genuine
    # documentation commit produces. Read as "not a released surface" that is a
    # refused API call quietly shrinking the backlog, so the body is checked for
    # the commit it was supposed to describe before its file list is trusted.
    body=$(api "repos/$OWNER/$repo/commits/$csha")
    if ! printf '%s' "$body" | jq -e '.sha' >/dev/null 2>&1; then
      unread=$((unread + 1))
      continue
    fi
    hits=$(printf '%s' "$body" | jq -r '(.files // [])[].filename // empty' 2>/dev/null \
           | tr -d '\r' | grep -cE "$RELEASED_SURFACE")
    [ "${hits:-0}" -gt 0 ] 2>/dev/null || continue
    count=$((count + 1))

    [ -n "$oldest" ] && continue
    cts=$(epoch_of "$cdate")
    # Unparseable or absent: this commit cannot date the backlog. The loop moves
    # on rather than substituting a number, and the tail below refuses to call
    # the result an age. It is REMEMBERED, because "the oldest thing waiting has
    # no readable date" is not the same as "there is nothing older than what I
    # did date" — the self-test caught a matching commit with an unparseable
    # date rendering as an entirely empty backlog.
    if [ -z "$cts" ]; then
      undated=$((undated + 1))
      continue
    fi
    # A COMMIT DATED IN THE FUTURE IS SKEW, AND SKEW IS UNKNOWN, NOT HEALTHY.
    # Clamping a negative age to zero read as "published moments ago" and, since
    # the age is taken from the FIRST match, it also stopped genuinely old
    # commits behind it from ever being considered — one bad clock turning a
    # four-hundred-hour backlog into `backlog_hours=0`. It contributes to the
    # count, dates nothing, and is remembered so the tail can refuse to report
    # an age it never established.
    if [ "$cts" -gt "$now_ts" ]; then
      skew=$((skew + 1))
      continue
    fi
    # THE BACKLOG CLOCK CANNOT START BEFORE THE TAG MOVED — only applied when
    # the tag's own date was actually readable, never as a default.
    [ -n "$base_ts" ] && [ "$cts" -lt "$base_ts" ] && cts="$base_ts"
    oldest=$(( (now_ts - cts) / 3600 ))
  done

  # THE ONLY WAY TO PRINT `backlog=0` IS TO HAVE LOOKED AT EVERY COMMIT AND
  # READ EVERY ONE OF THEM — AND THE ONLY WAY TO PRINT AN AGE IS THE SAME.
  # Anything the walk could not resolve — a truncated scan, a refused commit
  # read, a clock in the future, a date that would not parse — reports the count
  # it has and NO age, which the rule turns into a warning.
  #
  # THE UNKNOWNS ARE CHECKED BEFORE THE AGE, not after, and that ordering is the
  # correction the self-test forced. The age is taken from the OLDEST matching
  # commit, so when that one is the unreadable one, the first age the walk does
  # establish belongs to a YOUNGER commit — and reporting it understates the
  # backlog in exactly the direction that lets it slip under the threshold. An
  # age established while something older was unreadable is not an age.
  local unknown=$(( unread + skew + undated ))
  if [ "$capped" = "1" ]; then
    printf 'tag_readable=1;backlog=%s' "$ahead"
  elif [ "$unknown" -gt 0 ]; then
    printf 'tag_readable=1;backlog=%s' "$(( count > unknown ? count : unknown ))"
  elif [ -n "$oldest" ]; then
    printf 'tag_readable=1;backlog=%s;backlog_hours=%s' "$count" "$oldest"
  else
    printf 'tag_readable=1;backlog=0;backlog_hours=0'
  fi
}

# --- the utility host's fork posture (#1704) -----------------------------------

# utility_repos_of <text> — one repository per line from a comma-, space- or
# newline-separated list, blanks dropped, first occurrence kept.
utility_repos_of() {
  # `tr -d '\r'` explicitly: Git Bash's awk drops a CR on input and a Linux awk
  # does not, so leaving it to the awk would make the result machine-dependent.
  printf '%s\n' "${1:-}" | tr -d '\r' | awk '{ gsub(/[,\t ]+/, "\n"); print }' | awk 'NF && !seen[$0]++'
}

# fork_pr_facts <repo> — the LIVE "run workflows from fork pull requests"
# setting: `true`, `false`, `public`, or `unreadable`. Never empty.
#
# THE BOOLEAN IS TYPE-CHECKED, NOT DEFAULTED. A 403 or 404 body has no such key,
# and `.run_workflows_from_fork_pull_requests // false` would read a refusal as
# "disabled" — a token without `Administration: read` reporting every repository
# safe, the 2026-08-27 variables trap in its quietest form.
#
# A PUBLIC REPOSITORY ANSWERS 422 ("not allowed for public repositories"),
# measured 2026-11-05 against this repository. That is not a read failure: it is
# GitHub saying the setting does not exist there, because fork workflows cannot
# be turned off on a public repository. Reported as its own value so the rule
# can fail it for what it is. Any other refusal is `unreadable`.
#
# A name that is not a plain repository name is refused before it reaches a
# URL: the list is operator input, and `..` in a path is not a repository.
fork_pr_facts() {
  local repo="$1" path body value status message
  if ! printf '%s' "$repo" | grep -cE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$' >/dev/null \
     || printf '%s' "$repo" | grep -cE '(^|/)\.\.?($|/)' >/dev/null; then
    printf 'unreadable'
    return 0
  fi
  case "$repo" in */*) path="$repo" ;; *) path="$OWNER/$repo" ;; esac
  body=$(api "repos/$path/actions/permissions/fork-pr-workflows-private-repos")
  value=$(printf '%s' "$body" | jq -r 'if type=="object" and (.run_workflows_from_fork_pull_requests|type)=="boolean"
                                       then (.run_workflows_from_fork_pull_requests|tostring) else empty end' 2>/dev/null | tr -d '\r')
  case "$value" in
    true|false) printf '%s' "$value"; return 0 ;;
  esac
  status=$(printf '%s' "$body" | jq -r 'if type=="object" then (.status // empty | tostring) else empty end' 2>/dev/null | tr -d '\r')
  message=$(printf '%s' "$body" | jq -r 'if type=="object" then (.message // empty) else empty end' 2>/dev/null | tr -d '\r')
  if [ "$status" = "422" ] && printf '%s' "$message" | grep -ciE 'public' >/dev/null; then
    printf 'public'
  else
    printf 'unreadable'
  fi
}

facts_for() {
  local repo="$1" tier="$2" want="$3"
  local lane guard reaper events relay workflows=""
  local has_lane=0 has_guard=0 has_reaper=0 has_events=0 has_relay=0 has_ci=""
  # Per repository: the texts already read, so the workflow scan does not read
  # them twice. facts_for runs in `$(…)`, but a direct call must not inherit
  # another repository's files.
  WORKFLOW_TEXT=()

  # THE LISTING COMES FROM THE GIT TREE, NEVER THE CONTENTS API (#1716). The
  # contents API returns at most 1000 entries of a directory, alphabetically,
  # with no paging: 1000 decoy files followed by `zz.yml` pinned to an imposter
  # hid that file from the scan, and the repository read compliant. The trees
  # API returns the whole directory or says `truncated: true`, and a truncated
  # (or malformed) listing is unscanned — wf_listing_unreadable — never clean.
  # The ref is `<default branch>:.github/workflows`, fully URL-encoded (GitHub
  # 404s an unencoded `:` or `/` there), i.e. the tree file_at reads from.
  # Only `blob` entries are workflows: GitHub runs top-level files of
  # .github/workflows and nothing in a subdirectory, so a `tree` entry (or a
  # submodule `commit`) is not a workflow and is skipped. A control character
  # in a name becomes `?`, which workflow_pin_facts then refuses (unscanned);
  # by code point, not `gsub`: Oniguruma reads `\u0000-…` in a class as a
  # range over ordinary letters and mangled every name.
  local branch tree listing listing_truncated=0
  branch=$(api "repos/$OWNER/$repo" | jq -r '.default_branch // empty' 2>/dev/null | tr -d '\r')
  if [ -n "$branch" ]; then
    tree=$(api "repos/$OWNER/$repo/git/trees/$(printf '%s' "$branch:.github/workflows" | jq -sRr @uri | tr -d '\r')")
    listing=$(printf '%s' "$tree" | jq -r 'if type=="object" and (.tree|type)=="array"
        then (if .truncated == false then "#OK" else "#TRUNCATED" end),
             (.tree[] | select(.type=="blob") | .path | strings
              | explode | map(if . < 32 or . == 127 then 63 else . end) | implode)
        else empty end' 2>/dev/null | tr -d '\r')
    case "$listing" in
      '#TRUNCATED'*) listing_truncated=1 ;;
    esac
    workflows=$(printf '%s\n' "$listing" | sed '1d')
  fi
  if [ "$listing_truncated" = "1" ]; then
    # Some of the directory is missing, so the scan below never runs on it.
    # The named callers are still looked for among the names that did arrive.
    has_ci=1
    printf '%s\n' "$workflows" | grep -cx 'merge-lane.yml' >/dev/null && has_lane=1
    printf '%s\n' "$workflows" | grep -cx 'pr-guard-self.yml' >/dev/null && has_guard=1
    printf '%s\n' "$workflows" | grep -cx 'branch-reaper-self.yml' >/dev/null && has_reaper=1
    printf '%s\n' "$workflows" | grep -cx 'merge-lane-events.yml' >/dev/null && has_events=1
    printf '%s\n' "$workflows" | grep -cx 'merge-lane-review-relay.yml' >/dev/null && has_relay=1
  elif [ -n "$workflows" ]; then
    has_ci=1
    # `grep -cx … >/dev/null`, never `grep -qx`. Under `pipefail` a `-q` reader
    # exits on its first match while the in-process writer is still going, the
    # writer dies of EPIPE, and a pipeline that FOUND its text reports failure.
    # `-c` reads to end of input and still exits 1 when there is no match.
    printf '%s\n' "$workflows" | grep -cx 'merge-lane.yml' >/dev/null && has_lane=1
    printf '%s\n' "$workflows" | grep -cx 'pr-guard-self.yml' >/dev/null && has_guard=1
    printf '%s\n' "$workflows" | grep -cx 'branch-reaper-self.yml' >/dev/null && has_reaper=1
    printf '%s\n' "$workflows" | grep -cx 'merge-lane-events.yml' >/dev/null && has_events=1
    printf '%s\n' "$workflows" | grep -cx 'merge-lane-review-relay.yml' >/dev/null && has_relay=1
  else
    # An empty listing is either "no workflows" or "the read failed", and the
    # two must not render alike. The repository itself answers: a repository
    # that exists with a default branch and no `.github` directory is the
    # former, and a 404 on the repository is the latter.
    [ -n "$branch" ] && has_ci=0
  fi

  local facts="tier=$tier;has_lane=$has_lane;has_guard=$has_guard;has_reaper=$has_reaper"
  facts="$facts;has_ci=$has_ci;want_pin=$want"

  if [ "$has_lane" = "1" ]; then
    lane=$(file_at "$repo" ".github/workflows/merge-lane.yml")
    WORKFLOW_TEXT[merge-lane.yml]="$lane"
    # Every pin also carries whether it is in the fleet's history (#1715): one
    # cached compare per distinct SHA, so the guard and reaper ride along free.
    # EVERY non-comment pin is judged, worst verdict wins (#1716).
    facts="$facts;$(caller_pin_facts lane "$lane" 'merge-lane\.yml')"
    facts="$facts;has_events=$has_events"
    [ "$has_events" = "1" ] && {
      # The events file calls the same callee, so it carries the same kind of
      # pin — and drifts from merge-lane.yml's exactly the way the guard and
      # reaper pins drifted from each other.
      events=$(file_at "$repo" ".github/workflows/merge-lane-events.yml")
      WORKFLOW_TEXT[merge-lane-events.yml]="$events"
      facts="$facts;$(caller_pin_facts events "$events" 'merge-lane\.yml')"
      facts="$facts;with_match=$(with_agrees "$lane" "$events")"
      if [ "$has_relay" = "1" ]; then
        relay=$(file_at "$repo" ".github/workflows/merge-lane-review-relay.yml")
        WORKFLOW_TEXT[merge-lane-review-relay.yml]="$relay"
        facts="$facts;relay_match=$(relay_agrees "$events" "$relay")"
      else
        # No relay at all: whatever name the events file listens for, nothing
        # emits it, so a review never wakes the lane.
        facts="$facts;relay_match=0"
      fi
    }
    [ "$has_guard" = "1" ] && {
      guard=$(file_at "$repo" ".github/workflows/pr-guard-self.yml")
      WORKFLOW_TEXT[pr-guard-self.yml]="$guard"
      facts="$facts;$(caller_pin_facts guard "$guard" 'pr-guard\.yml')"
    }
    [ "$has_reaper" = "1" ] && {
      reaper=$(file_at "$repo" ".github/workflows/branch-reaper-self.yml")
      WORKFLOW_TEXT[branch-reaper-self.yml]="$reaper"
      facts="$facts;$(caller_pin_facts reaper "$reaper" 'branch-reaper\.yml')"
    }

    # A 403 AND AN EMPTY LIST ARE THE SAME BYTES HERE, so the exit status is
    # captured as its own fact. Without it a token that cannot see variables
    # reports every repository in the fleet as `lane-not-enabled`, which is
    # what the first live run under the App token did.
    local vars vars_ok=1
    vars=$(api "repos/$OWNER/$repo/actions/variables?per_page=100") || vars_ok=0
    # per_page=100 is load-bearing: variables paginate at 30, and a repository
    # with a wall of CI_* variables reports MERGE_LANE_* as absent on page one.
    facts="$facts;vars_readable=$vars_ok"
    facts="$facts;enabled=$(printf '%s' "$vars" | jq -r '.variables[]?|select(.name=="MERGE_LANE_ENABLED").value // empty' 2>/dev/null)"
    facts="$facts;armed=$(printf '%s' "$vars" | jq -r '.variables[]?|select(.name=="MERGE_LANE_ARMED").value // empty' 2>/dev/null)"

    local secrets raw_secrets secrets_ok=1
    raw_secrets=$(api "repos/$OWNER/$repo/actions/secrets?per_page=100") || secrets_ok=0
    facts="$facts;secrets_readable=$secrets_ok"
    secrets=$(printf '%s' "$raw_secrets" | jq -r '.secrets[]?.name // empty' 2>/dev/null)
    facts="$facts;app_id=$(printf '%s\n' "$secrets" | grep -cx MERGE_APP_ID >/dev/null && echo 1 || echo 0)"
    facts="$facts;app_key=$(printf '%s\n' "$secrets" | grep -cx MERGE_APP_PRIVATE_KEY >/dev/null && echo 1 || echo 0)"

    facts="$facts;checks_match=$(checks_agree "$lane" "$repo")"
    facts="$facts;ruleset=$(api "repos/$OWNER/$repo/rulesets" | jq -r 'if type=="array" then (if length>0 then 1 else 0 end) else empty end' 2>/dev/null)"
  fi

  # Every workflow's fleet pins (#1716), in the tiers whose rule judges them.
  # `source` calls itself through local paths; `dormant` and `empty` are judged
  # only for having CI at all. The named callers' texts are reused, not re-read.
  case "$tier" in
    pool|lane|checks)
      if [ "$listing_truncated" = "0" ] && [ -n "$workflows" ]; then
        facts="$facts;$(workflow_pin_facts "$repo" "$workflows")"
      elif [ "$has_ci" != "0" ]; then
        # The listing failed or was truncated (has_ci=0 is a readable
        # repository with no workflows, which has nothing to scan). Unscanned
        # is never clean.
        facts="$facts;wf_scanned=1;wf_listing_unreadable=1"
      fi
      ;;
  esac

  # The source repository is the only one with an unreleased backlog to have:
  # it is what every other repository pins. Collected only here, because these
  # are several API calls and they answer a question no other tier can ask.
  if [ "$tier" = "source" ]; then
    facts="$facts;backlog_max_hours=$BACKLOG_MAX_HOURS;$(backlog_facts "$repo")"
  fi

  if [ "$tier" = "pool" ]; then
    local runners
    runners=$(api "repos/$OWNER/$repo/actions/runners?per_page=100")
    # THE SAME 403-READS-AS-ZERO TRAP AS THE VARIABLES ENDPOINT, and it bit in
    # the quiet direction first: `.runners` is null on a refusal body, `null |
    # length` is 0, and the 2026-08-27 run reported three repositories with a
    # combined 37 registered runners as having none under demand. The type
    # check is what turns that into `warn:runner-count-unknown`. Reading
    # runners needs `Administration: read` on the App.
    local runner_count='if (.runners|type)=="array" then'
    facts="$facts;runners=$(printf '%s' "$runners" \
      | jq -r "$runner_count (.runners|length) else empty end" 2>/dev/null)"
    facts="$facts;online=$(printf '%s' "$runners" \
      | jq -r "$runner_count ([.runners[]|select(.status==\"online\")]|length) else empty end" 2>/dev/null)"
    local q corpses="" demand="" settled=""
    q=$(queue_facts "$repo")
    [ -n "$q" ] && { corpses=${q%% *}; settled=${q##* }; demand=$(printf %s "$q" | cut -d" " -f2); }
    facts="$facts;corpses=$corpses;demand=$demand;settled=$settled;page=$QUEUED_PAGE"
  fi

  # ONE strip for every fact, at the boundary. `jq` on a Windows workstation
  # terminates its output with CRLF, so a value read through it arrives as
  # `true\r` and compares unequal to `true` — which the rule reports as a lane
  # that was never enabled, on a repository where it is. Normalising per-value
  # would mean remembering it at every call site; normalising here means the
  # rule only ever sees facts, never the platform they were read on.
  printf '%s' "${facts//$'\r'/}"
}

# --- run ----------------------------------------------------------------------
#
# EVERYTHING ABOVE IS DEFINITIONS; EVERYTHING BELOW TALKS TO GITHUB.
#
# `backlog_facts` is the one part of this file with a self-test, and it can only
# have one because the test stubs `api` and sources this file for the functions
# without running the audit.
#
# THE GUARD HAS TO MEAN THE SAME THING IN BOTH MODES. `return` at the top level
# of a SOURCED file is legal and ends the source; in an EXECUTED file it is an
# error, and since this script runs under `set -uo pipefail` rather than `-e`
# that error does not stop anything — bash writes "can only `return' from a
# function or sourced script" and then runs the entire audit that the variable
# just asked it not to run. Falling through to `exit 0` makes the two readings
# agree: asked not to run, it does not run, however it was invoked.
# Asking `return` whether it worked is the only reading that cannot be fooled.
# Comparing BASH_SOURCE[0] with $0 looks tidier and is wrong: `bash -c 'source
# "$0"' <path>` sets $0 TO that path, so a genuine source reads as an execution
# and this exits the caller's shell. Found by the assertions below.
# shellcheck disable=SC2317  # reachable when EXECUTED, where `return` fails
if [ "${FLEET_AUDIT_LIB:-}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "fleet-audit: gh is not on PATH" >&2; exit 2; }
[ -r "$MANIFEST" ] || { echo "fleet-audit: cannot read $MANIFEST" >&2; exit 2; }
# Exit 2, not a run against an empty owner: every read would 404 and the rule
# would report an unknown for every fact in the fleet, which reads like a fleet
# in trouble rather than an audit that could not start.
[ -n "$OWNER" ] || { echo "fleet-audit: cannot determine the account owner; set FLEET_OWNER" >&2; exit 2; }

ONLY="${1:-}"
WANT_PIN=$(resolve_want_pin)
[ -z "$WANT_PIN" ] && echo "fleet-audit: could not resolve the expected pin; every pin will read as unknown" >&2
# Read once, here, outside the per-repository subshells — see pin_in_history.
FLEET_HISTORY_BRANCH=$(fleet_history_branch)
[ -z "$FLEET_HISTORY_BRANCH" ] && echo "fleet-audit: cannot read $OWNER/ci-runner-infra; every pin's provenance will read as unknown" >&2
PIN_HISTORY_CACHE=$(mktemp -d 2>/dev/null) || PIN_HISTORY_CACHE=""
cleanup_pin_cache() { [ -n "$PIN_HISTORY_CACHE" ] && rm -rf "$PIN_HISTORY_CACHE"; }
trap cleanup_pin_cache EXIT

declare -i FAILS=0 WARNS=0 OKS=0
declare -a LISTED=()

while IFS=$'\t' read -r repo tier _reason; do
  case "$repo" in ''|\#*) continue ;; esac
  LISTED+=("$repo")
  [ -n "$ONLY" ] && [ "$repo" != "$ONLY" ] && continue

  findings=$(fleet_verdict "$(facts_for "$repo" "$tier" "$WANT_PIN")")
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%-22s %s\n' "$repo" "$line"
    case "$line" in
      fail:*) FAILS+=1 ;;
      warn:*) WARNS+=1 ;;
      ok:*) OKS+=1 ;;
    esac
  done <<< "$findings"
done < "$MANIFEST"

# --- the utility host's fork posture (#1704) -----------------------------------
#
# Its own list, not the manifest's tiers: which repositories share the utility
# host is a deployment fact the manifest does not hold. Unset is NOT silence —
# a skipped check and a clean one must never render alike — but it is a note,
# not a warning, because a fleet with no utility host has nothing to set.
UTILITY_LIST=$(utility_repos_of "$UTILITY_HOST_REPOS")
if [ -z "$UTILITY_LIST" ]; then
  printf '%-22s %s\n' "-" "note:fork-pr-audit-skipped UTILITY_HOST_REPOS-is-unset"
else
  while IFS= read -r urepo; do
    [ -z "$urepo" ] && continue
    [ -n "$ONLY" ] && [ "${urepo##*/}" != "$ONLY" ] && continue
    line=$(fork_pr_verdict "$(fork_pr_facts "$urepo")")
    printf '%-22s %s\n' "${urepo##*/}" "$line"
    case "$line" in
      fail:*) FAILS+=1 ;;
      warn:*) WARNS+=1 ;;
      ok:*) OKS+=1 ;;
    esac
  done <<< "$UTILITY_LIST"
fi

# --- the manifest against reality ---------------------------------------------
#
# Reported in BOTH directions. A repository with no row is the one this whole
# file exists to catch: nobody onboarded it, and a discovery-only audit would
# have to treat it as fine because it looks exactly like a deliberate
# exemption. A row with no repository is a manifest nobody pruned, which makes
# every other row less trustworthy.
if [ -z "$ONLY" ]; then
  # TWO SOURCES, AND WHICH ONE ANSWERED IS PART OF THE FINDING.
  #
  # `gh repo list` needs a user token; the scheduled run authenticates as the
  # merge App, whose installation token cannot enumerate an account. The App
  # CAN list its own installation, which equals the account only when it is
  # installed on all repositories — so a fallback answer is a NARROWER claim,
  # and a repository nobody onboarded is exactly the one the App is least
  # likely to be installed on. Saying so is the difference between "no
  # unmanaged repositories exist" and "none that I could see".
  scope=account
  actual=$(gh repo list "$OWNER" --limit 300 --json name --jq '.[].name' 2>/dev/null | tr -d '\r' | sort)
  if [ -z "$actual" ]; then
    scope=installation
    actual=$(api "installation/repositories?per_page=100" \
      | jq -r '.repositories[]?.name // empty' 2>/dev/null | tr -d '\r' | sort)
    [ -n "$actual" ] && {
      printf '%-22s %s\n' "-" "warn:repo-list-scope-narrowed source=app-installation"
      WARNS+=1
    }
  fi
  if [ -z "$actual" ]; then
    echo "fleet-audit: could not list the account's repositories" >&2
    WARNS+=1
  else
    listed=$(printf '%s\n' "${LISTED[@]}" | sort)
    while read -r r; do
      [ -z "$r" ] && continue
      printf '%-22s %s\n' "$r" "fail:not-in-manifest classify-it-in-fleet/repos.tsv"
      FAILS+=1
    done < <(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed"))
    while read -r r; do
      [ -z "$r" ] && continue
      # Under the narrowed scope this reads "the App is not installed here",
      # which is a different sentence from "the repository is gone" — and one
      # of them is a manifest to prune while the other is an install to finish.
      printf '%-22s %s\n' "$r" "warn:in-manifest-but-not-visible scope=$scope"
      WARNS+=1
    done < <(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed"))
  fi
fi

printf '\nfleet-audit: %d compliant, %d warnings, %d failures\n' "$OKS" "$WARNS" "$FAILS"
[ "$FAILS" -eq 0 ]
