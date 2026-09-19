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
BACKLOG_SCAN_MAX="${BACKLOG_SCAN_MAX:-40}"
# The tag the backlog is measured from. Empty — the normal case — derives it
# from VERSION's major, which is the ref consumers pin. An override exists so
# the collector can be exercised by hand against a tag that is known to be
# behind the default branch; on a healthy repository the derived tag is at the
# tip, so every code path past the first comparison would otherwise be dead on
# the only repository it ever runs against.
FLOATING_TAG="${FLOATING_TAG:-}"

command -v gh >/dev/null 2>&1 || { echo "fleet-audit: gh is not on PATH" >&2; exit 2; }
[ -r "$MANIFEST" ] || { echo "fleet-audit: cannot read $MANIFEST" >&2; exit 2; }
# Exit 2, not a run against an empty owner: every read would 404 and the rule
# would report an unknown for every fact in the fleet, which reads like a fleet
# in trouble rather than an audit that could not start.
[ -n "$OWNER" ] || { echo "fleet-audit: cannot determine the account owner; set FLEET_OWNER" >&2; exit 2; }

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

# pin_in <file-contents> <callee> — the sha a caller pins for one callee.
pin_in() {
  printf '%s' "$1" \
    | grep -oE "ci-runner-infra/\.github/workflows/$2@[0-9a-f]{40}" \
    | head -1 | grep -oE '[0-9a-f]{40}$'
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
  base_ts=$(date -u -d "$(printf '%s' "$cmp" | jq -r '.base_commit.commit.committer.date // empty' 2>/dev/null | tr -d '\r')" +%s 2>/dev/null)
  now_ts=$(date -u +%s)

  # THE CHEAP ANSWER FIRST. The compare response already carries the union of
  # every file changed across the range, so a range that touches no released
  # surface at all is settled without a single further call — which is the
  # common case on a documentation-only day. Only when the union is complete,
  # though: the endpoint caps `files` at 300, and "no match in the first 300"
  # is not "no match".
  local nfiles nmatch
  nfiles=$(printf '%s' "$cmp" | jq -r '(.files // []) | length' 2>/dev/null | tr -d '\r')
  nmatch=$(printf '%s' "$cmp" | jq -r '(.files // [])[].filename // empty' 2>/dev/null \
           | tr -d '\r' | grep -cE "$RELEASED_SURFACE")
  if [ -n "$nfiles" ] && [ "$nfiles" -lt 300 ] 2>/dev/null && [ "${nmatch:-0}" = "0" ]; then
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

  local entry csha cdate cts hits n=0 count=0 oldest="" capped=0
  for entry in "${list[@]}"; do
    [ -z "$entry" ] && continue
    n=$((n + 1))
    if [ "$n" -gt "$BACKLOG_SCAN_MAX" ]; then capped=1; break; fi
    csha="${entry%% *}"
    cdate="${entry#* }"
    hits=$(api "repos/$OWNER/$repo/commits/$csha" \
           | jq -r '(.files // [])[].filename // empty' 2>/dev/null | tr -d '\r' \
           | grep -cE "$RELEASED_SURFACE")
    [ "${hits:-0}" -gt 0 ] 2>/dev/null || continue
    count=$((count + 1))
    if [ -z "$oldest" ]; then
      cts=$(date -u -d "$cdate" +%s 2>/dev/null)
      [ -z "$cts" ] && continue
      [ -n "$base_ts" ] && [ "$cts" -lt "$base_ts" ] 2>/dev/null && cts="$base_ts"
      oldest=$(( (now_ts - cts) / 3600 ))
      [ "$oldest" -lt 0 ] && oldest=0
    fi
  done

  if [ -n "$oldest" ]; then
    printf 'tag_readable=1;backlog=%s;backlog_hours=%s' "$count" "$oldest"
  elif [ "$capped" = "1" ]; then
    # Walked the cap and found nothing released yet, with more to go. The count
    # is real and the age is not known, so it is reported WITHOUT an age and the
    # rule warns — never as a young backlog, and never as an empty one.
    printf 'tag_readable=1;backlog=%s' "$ahead"
  else
    printf 'tag_readable=1;backlog=0;backlog_hours=0'
  fi
}

facts_for() {
  local repo="$1" tier="$2" want="$3"
  local lane guard reaper workflows
  local has_lane=0 has_guard=0 has_reaper=0 has_ci=""

  workflows=$(api "repos/$OWNER/$repo/contents/.github/workflows" | jq -r '.[].name // empty' 2>/dev/null)
  if [ -n "$workflows" ]; then
    has_ci=1
    # `grep -cx … >/dev/null`, never `grep -qx`. Under `pipefail` a `-q` reader
    # exits on its first match while the in-process writer is still going, the
    # writer dies of EPIPE, and a pipeline that FOUND its text reports failure.
    # `-c` reads to end of input and still exits 1 when there is no match.
    printf '%s\n' "$workflows" | grep -cx 'merge-lane.yml' >/dev/null && has_lane=1
    printf '%s\n' "$workflows" | grep -cx 'pr-guard-self.yml' >/dev/null && has_guard=1
    printf '%s\n' "$workflows" | grep -cx 'branch-reaper-self.yml' >/dev/null && has_reaper=1
  else
    # An empty listing is either "no workflows" or "the read failed", and the
    # two must not render alike. The repository itself answers: a repository
    # that exists with a default branch and no `.github` directory is the
    # former, and a 404 on the repository is the latter.
    api "repos/$OWNER/$repo" | jq -e '.default_branch' >/dev/null 2>&1 && has_ci=0
  fi

  local facts="tier=$tier;has_lane=$has_lane;has_guard=$has_guard;has_reaper=$has_reaper"
  facts="$facts;has_ci=$has_ci;want_pin=$want"

  if [ "$has_lane" = "1" ]; then
    lane=$(file_at "$repo" ".github/workflows/merge-lane.yml")
    facts="$facts;lane_pin=$(pin_in "$lane" 'merge-lane\.yml')"
    [ "$has_guard" = "1" ] && {
      guard=$(file_at "$repo" ".github/workflows/pr-guard-self.yml")
      facts="$facts;guard_pin=$(pin_in "$guard" 'pr-guard\.yml')"
    }
    [ "$has_reaper" = "1" ] && {
      reaper=$(file_at "$repo" ".github/workflows/branch-reaper-self.yml")
      facts="$facts;reaper_pin=$(pin_in "$reaper" 'branch-reaper\.yml')"
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
ONLY="${1:-}"
WANT_PIN=$(resolve_want_pin)
[ -z "$WANT_PIN" ] && echo "fleet-audit: could not resolve the expected pin; every pin will read as unknown" >&2

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
