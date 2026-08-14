#!/usr/bin/env bash
# =============================================================================
# check-merge-queue-single-step.sh — one CI run per pull request, enforced
#
# USAGE
#   bash scripts/ci/check-merge-queue-single-step.sh [--selftest] [<file>]
#
# PURPOSE
#   Mergify re-checks a queued pull request IN PLACE — on the PR branch, reusing
#   the run that already happened — only when FOUR things hold at once. Break
#   any one and it instead pushes a throwaway draft to
#   `mergify/merge-queue/<sha>`, where EVERY `pull_request` workflow in this
#   repository runs a second time:
#
#     1. `merge_queue.max_parallel_checks: 1`
#     2. every queue rule's `batch_size: 1`
#     3. no `max_checks_retries`
#     4. SINGLE-STEP CI — `merge_conditions` is EMPTY or IDENTICAL to
#        `queue_conditions`
#
#   The evidence is in the Mergify payload: a two-step pull request carries
#   `speculative_check_pr: <n>` and shows a `mergify/merge-queue/*` workflow run
#   alongside its own (measured on DataRetrival #2383, 2026-08-14). A single-step
#   one reports `speculative_check_pr: null` and "Checks skipped - PR is already
#   up-to-date".
#
# WHY IT PARSES INSTEAD OF PATTERN-MATCHING
#   Every invariant here is a statement about the document Mergify LOADS, and
#   that document is not the text. `queue: {name: default}` and a block mapping
#   are the same action; `"max_checks_retries": 2` and the bare spelling are the
#   same key; `<<: *shared` splices keys that appear nowhere near the rule they
#   land in; an alias is not a copy of a list but the SAME list. A reader that
#   walks lines gets each of those wrong in the safe-looking direction — it
#   reports clean — and a config gate's characteristic failure is exactly that
#   vacuous pass. So the file goes through a real YAML parser (`python3` +
#   PyYAML, which the runner image carries — see `ensure_yaml`) and every check
#   below reads the loaded document by EXACT PATH: `merge_queue.max_parallel_checks`,
#   `queue_rules[1].batch_size`. Never a key name found somewhere in the text —
#   `max_parallel_checks` one level too deep is not a value in an odd spot, it is
#   a file Mergify REJECTS OUTRIGHT, and the queue then fails closed.
#
#   Identity (4) is asserted as NODE IDENTITY — `merge_conditions` and
#   `queue_conditions` being the same object after the parser resolves aliases,
#   which is precisely what Mergify's schema means by "identical". Two lists that
#   happen to match today are two nodes, and they drift on the next check added
#   to one of them; the drift is invisible, because the queue keeps merging and
#   only the runner bill changes.
#
# CHECK 5 — nothing may reach the queue through a `pull_request_rules` queue
#   action, because that rule's `conditions:` are a SECOND list and a second
#   list differs by construction (if only by carrying `base`/`-draft`).
#
# CHECK 6 — but SOMETHING must still queue a green pull request without a human,
#   and it must be able to admit one. Removing the queue action is only half the
#   change: with no queue action and no `auto_merge_conditions`, Mergify posts a
#   "tick the box to queue" comment and waits, so the PR is green, no merge
#   happens, and NO check anywhere goes red to say why (DataRetrival #2378,
#   fixed in #2384). An `auto_merge_conditions` that is empty, null, or aimed at
#   a branch no queue rule serves fails the same way with the key present.
#
# CHECK 7 — `auto_merge_conditions` must not restate the required checks. They
#   live once, in the anchored list, which is what governs when a queued pull
#   request embarks; a second copy is a list to keep in sync, and the anchor
#   exists precisely so that no such copy exists.
#
# CHECK 10 — and each rule must OWN the list it shares. Identity between one
#   rule's two fields does not say the list is that rule's: a second rule can
#   alias the FIRST rule's anchor for both of its fields, pass CHECK 4, and
#   leave two rules sharing one list — where a check added for one base is
#   silently required of the other.
#
# CHECK 9 — a queue rule with no `queue_conditions`, or with conditions naming
#   no check at all, admits pull requests on base/draft state alone. The gate
#   would then be certifying a queue that merges before CI succeeds.
#
# EXIT CODES
#   0 — clean
#   1 — an invariant is broken
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0
# Every diagnostic carries its check id. The self-test asserts the ID SET a
# fixture produces, not a count: counts let one detector's regression hide
# behind another detector firing on the same fixture.
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

# --- the parser is a hard dependency, not a nice-to-have ---------------------
# Made conditional, this is worse than useless: on a runner without PyYAML the
# gate would report PASS over a file Mergify cannot load.
#
# It does NOT install anything. A required check that pip-installs an unpinned
# package at gate time makes every pull request in fourteen repositories depend
# on PyPI being up and shipping a compatible release — and it runs that install
# on self-hosted hosts holding a GCP service identity. PyYAML is present on
# `ubuntu-latest` and baked into the golden host image; if it is ever missing
# the gate says so and fails, which is a runner-image bug with one owner rather
# than a supply-chain surface on every merge.
ensure_yaml() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import yaml' >/dev/null 2>&1
}

# Loads the file and emits one TAB-separated record per node:
#
#   <path>\t<scalar or "">\t<map|seq|str|int|bool|null>
#
# plus two kinds of finding the path stream cannot express:
#
#   #ERR\t<parser message>          the document does not load
#   #DUP\t<key>                     a mapping declares the same key twice
#   #RULE\t<rule path>\t<state>     same | different | absent | empty
#
# `#RULE` is the identity verdict, taken on the constructed objects: an alias
# yields the SAME list, two written-out lists never do, and an alias pointing at
# ANOTHER rule's anchor yields a list that is not this rule's.
read_yaml() {
  python3 - "$1" <<'PY'
import sys, yaml

# LF only. On Windows `print` emits CRLF, and the trailing CR lands inside the
# last field — so a type reads as `seq\r`, never equals `seq`, and the check
# that branches on it quietly takes the other path.
sys.stdout.reconfigure(newline="\n")

dups = []


class Loader(yaml.SafeLoader):
    pass


def no_duplicates(loader, node, deep=False):
    # PyYAML silently keeps the last of a repeated key. Mergify's own loader may
    # keep either, and a config whose effective value depends on that is not a
    # config this gate can certify.
    seen = set()
    for key_node, _ in node.value:
        # `<<` has no constructor of its own — it is spliced by the mapping
        # constructor below. Keys it brings in are NOT duplicates of the local
        # ones: YAML says the local key wins, unambiguously.
        if key_node.tag == "tag:yaml.org,2002:merge":
            continue
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            dups.append(str(key))
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.load(fh, Loader=Loader)
except Exception as exc:  # noqa: BLE001 - any load failure is the same verdict
    print("#ERR\t%s" % " ".join(str(exc).split())[:400])
    sys.exit(0)

for key in dups:
    print("#DUP\t%s" % key)

if doc is None:
    doc = {}


def kind(value):
    if isinstance(value, dict):
        return "map"
    if isinstance(value, list):
        return "seq"
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    return "str"


def scalar(value):
    if isinstance(value, (dict, list)) or value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value).replace("\t", " ").replace("\n", " ")


def walk(node, path):
    if isinstance(node, dict):
        items = node.items()
    elif isinstance(node, list):
        items = ((i, v) for i, v in enumerate(node))
    else:
        return
    for key, value in items:
        child = "%s[%d]" % (path, key) if isinstance(node, list) else (
            "%s.%s" % (path, key) if path else str(key)
        )
        print("%s\t%s\t%s" % (child, scalar(value), kind(value)))
        walk(value, child)


walk(doc, "")

rules = doc.get("queue_rules") if isinstance(doc, dict) else None
# Which rule each condition list belongs to. Identity between a rule's OWN two
# fields does not say the rule owns its list: a second rule can point both of
# its fields at the FIRST rule's anchor, and then every per-rule verdict below
# reads `same` while the two rules are silently one list.
owners = {}
if isinstance(rules, list):
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict):
            continue
        qc = rule.get("queue_conditions")
        if isinstance(qc, list):
            # The document stays referenced for the life of this process, so no
            # id() is recycled underneath this map.
            if id(qc) in owners:
                print("#ALIAS\tqueue_rules[%d]\tqueue_rules[%d]" % (i, owners[id(qc)]))
            else:
                owners[id(qc)] = i
        if "merge_conditions" not in rule:
            state = "absent"
        else:
            mc = rule.get("merge_conditions")
            # An explicitly empty list is one of the two single-step spellings,
            # exactly as omitting the key is.
            if mc is None or (isinstance(mc, list) and not mc):
                state = "empty"
            elif mc is qc:
                state = "same"
            else:
                state = "different"
        print("#RULE\tqueue_rules[%d]\t%s" % (i, state))
PY
}

scan_file() {
  local f="$1" doc mpc misplaced rules r b state amc_base rule_bases
  if [ ! -f "$f" ]; then
    err CHECK0 "no Mergify configuration at $f. This gate cannot show that the queue checks in place, and a missing config is not an absent queue — Mergify falls back to its own defaults."
    return
  fi

  # --- CHECK 0: it has to load at all, and mean one thing --------------------
  if ! ensure_yaml; then
    err CHECK0 "no YAML parser available (python3 with PyYAML, which the runner image is expected to carry — this gate deliberately installs nothing). Without one it cannot tell a config Mergify loads from one it refuses, and reporting PASS on that basis is the vacuous pass this gate exists to prevent. Install python3 + PyYAML on the runner."
    return
  fi
  doc="$(read_yaml "$f")"

  if printf '%s\n' "$doc" | grep -q '^#ERR	'; then
    err CHECK0 "\`$f\` is not loadable YAML, so nothing below it is worth asserting: Mergify refuses the whole file and NO pull request queues. Parser said: $(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#ERR" { print $2; exit }')"
    return
  fi
  local dups; dups="$(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#DUP" { print $2 }' | sort -u | tr '\n' ' ')"
  if [ -n "${dups// /}" ]; then
    err CHECK0 "\`$f\` declares the same key twice: ${dups}. Which declaration wins is loader-dependent, so \`max_parallel_checks: 1\` followed by \`max_parallel_checks: 5\` can read as compliant here and run parallel queue checks in production. Remove the duplicate."
  fi

  # Exact-path readers. `$1 == p` and nothing looser: a check that matches a
  # SUFFIX is a check that accepts the key one level too deep, which is the
  # misplacement this gate exists to catch.
  val_at()   { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }
  kind_at()  { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { print $3; exit }'; }
  has_path() { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { found = 1 } END { exit !found }'; }
  paths_re() { printf '%s\n' "$doc" | awk -F'\t' -v re="$1" '$1 ~ re { print $1 }'; }
  # Values of a sequence's items, addressed by the EXACT parent path. Done with
  # string comparison rather than an interpolated regex: a path built into a
  # pattern has to survive both the shell and `awk -v`, and `queue_rules[0]`
  # that loses one level of escaping stops being a literal and becomes a
  # character class — which matches nothing, and a check that matches nothing
  # reports clean.
  # Every scalar ANYWHERE under a path. Condition lists nest: a skip-aware
  # requirement is written `- or: [check-success = X, check-skipped = X]`, so the
  # checks live one level down and a top-level scan of the list finds none of
  # them — and then reports a queue that gates on nothing.
  subtree_vals() {
    printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '
      index($1, p "[") == 1 || index($1, p ".") == 1 { print $2 }'
  }

  # --- CHECK 1: max_parallel_checks, at the top level and nowhere else -------
  misplaced="$(paths_re '(^|\\.)max_parallel_checks$' | grep -vx 'merge_queue.max_parallel_checks')"
  if [ -n "$misplaced" ]; then
    err CHECK1 "\`max_parallel_checks\` is declared at \`$(printf '%s' "$misplaced" | tr '\n' ' ')\`, not at the top-level \`merge_queue.max_parallel_checks\`. Mergify permits it in exactly one place and REJECTS the whole file otherwise (\`Extra inputs are not permitted\`) — so this is not a value in the wrong spot, it is a configuration that loads nothing and queues nothing."
  else
    mpc="$(val_at merge_queue.max_parallel_checks)"
    if [ -z "$mpc" ]; then
      err CHECK1 "\`.mergify.yml\` declares no \`merge_queue.max_parallel_checks\`. Left unset it inherits a vendor default above 1, and parallel queue checks are performed on throwaway \`mergify/merge-queue/<sha>\` branches — a second full CI run per pull request."
    elif [ "$mpc" != "1" ]; then
      err CHECK1 "\`merge_queue.max_parallel_checks\` is \`$mpc\`, not 1. Anything above 1 makes Mergify check on throwaway \`mergify/merge-queue/<sha>\` branches instead of in place, which re-runs every \`pull_request\` workflow a second time."
    fi
  fi

  # --- CHECK 2: batch_size, once per rule ------------------------------------
  # Per rule, because the default is inherited PER RULE. A whole-file count says
  # `batch_size: 1` exists; the rule that omitted it still batches.
  rules="$(paths_re '^queue_rules\\[[0-9]+\\]' | sed -E 's/^(queue_rules\[[0-9]+\]).*/\1/' | sort -u)"
  if [ -z "$rules" ]; then
    err CHECK2 "\`.mergify.yml\` declares no \`queue_rules\`. Mergify then supplies its own defaults, which batch pull requests together and validate the batch on a throwaway queue branch — the second CI run this gate exists to prevent."
  else
    while read -r r; do
      [ -n "$r" ] || continue
      b="$(val_at "$r.batch_size")"
      if [ -z "$b" ]; then
        err CHECK2 "queue rule \`$r\` declares no \`batch_size\`. It inherits the batching default, and a batch is validated on a throwaway \`mergify/merge-queue/<sha>\` branch — every \`pull_request\` workflow runs a second time for any pull request this rule admits, whatever the other rules declare."
      elif [ "$b" != "1" ]; then
        err CHECK2 "queue rule \`$r\` sets \`batch_size: $b\`. Any batch larger than 1 is checked on a throwaway \`mergify/merge-queue/<sha>\` branch, re-running every \`pull_request\` workflow, and a failure anywhere in the batch sends every member back through CI."
      fi
    done <<EOF
$rules
EOF
  fi

  # --- CHECK 3: max_checks_retries ------------------------------------------
  if [ -n "$(paths_re '(^|\\.)max_checks_retries$')" ]; then
    err CHECK3 "\`max_checks_retries\` is set at \`$(paths_re '(^|\\.)max_checks_retries$' | tr '\n' ' ')\`. Retrying checks requires a queue branch to retry them ON, so declaring it disables in-place checking outright."
  fi

  # --- CHECK 4: single-step, as node identity, per rule ----------------------
  # The verdict comes from the loaded objects, so an alias pointing at ANOTHER
  # rule's anchor reads as `different` — the counts balance in the text, the
  # nodes do not, and every pull request that rule admits gets two-step CI.
  while IFS=$'\t' read -r _ r state; do
    [ -n "$r" ] || continue
    [ "$state" = "different" ] || continue
    err CHECK4 "queue rule \`$r\` does not share ONE node between \`queue_conditions\` and \`merge_conditions\`. Mergify checks a queued pull request in place only when \`merge_conditions\` is empty or IDENTICAL to \`queue_conditions\`; two separately written lists — or an alias pointing at another rule's anchor — match only until the next check is added to one of them, and the drift is silent: merges keep working, each pull request merely pays a second full CI run. Write \`queue_conditions: &<name>\` and \`merge_conditions: *<name>\` with THIS rule's own name, or drop \`merge_conditions\` entirely."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#RULE"')

  # --- CHECK 10: each rule owns its condition list ---------------------------
  # CHECK 4 asks whether a rule's two fields are one node; that says nothing
  # about WHOSE node it is. A rule aliasing an earlier rule's anchor for both
  # fields passes CHECK 4 cleanly while the two rules share one list — so a
  # check added for one rule's base silently lands on the other's too.
  while IFS=$'\t' read -r _ r owner; do
    [ -n "$r" ] || continue
    err CHECK10 "queue rule \`$r\` uses the SAME condition list object as \`$owner\` — it aliases that rule's anchor instead of declaring its own. The two rules are then one list: a check added for one rule's base is silently required of the other's, and removing it from one removes it from both. Give each rule its own \`&anchor\`."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#ALIAS"')

  # --- CHECK 9: the queue rule actually gates on CI --------------------------
  # `merge_conditions` being absent or empty is a valid single-step spelling,
  # which makes `queue_conditions` the ONLY thing standing between a pull
  # request and a merge. A rule that names no check merges on base/draft state.
  if [ -n "$rules" ]; then
    while read -r r; do
      [ -n "$r" ] || continue
      if ! has_path "$r.queue_conditions"; then
        err CHECK9 "queue rule \`$r\` declares no \`queue_conditions\`. Entry to the queue is then decided by \`auto_merge_conditions\` alone — which carries base/draft facts and is forbidden from carrying checks — so a pull request can embark and merge before CI has succeeded."
      # Same left-hand-operator anchor as CHECK 7, and here the loose spelling
      # fails the DANGEROUS way: a rule whose only condition is
      # `label = check-success-waived` would read as gated on CI. Negated forms
      # are deliberately NOT accepted — `-check-failure = X` requires nothing to
      # have succeeded.
      elif ! subtree_vals "$r.queue_conditions" \
        | grep -qE '^[[:space:]]*check-(success|neutral|skipped)[[:space:]]*[=:~]'; then
        err CHECK9 "queue rule \`$r\` has \`queue_conditions\` that name no check (\`check-success\`/\`check-neutral\`/\`check-skipped\`). This is the ONE list that decides when a queued pull request embarks, so with the checks gone it merges on base/draft state alone."
      fi
    done <<EOF
$rules
EOF
  fi

  # --- CHECK 5: no queue action ---------------------------------------------
  # Matched on the ACTION PATH in the LOADED document, so a block mapping, an
  # inline `queue: {name: default}`, and a `queue` spliced in through a `<<`
  # merge key are one finding rather than one caught and two missed.
  local qaction; qaction="$(paths_re '^pull_request_rules\\[[0-9]+\\]\\.actions\\.queue$')"
  if [ -n "$qaction" ]; then
    err CHECK5 "a \`pull_request_rules\` queue action is back at \`$(printf '%s' "$qaction" | tr '\n' ' ')\`. Its \`conditions:\` are a SEPARATE list from \`merge_conditions\` — different by construction, since it must carry \`base\`/\`-draft\` — so every pull request is checked twice: once on its own branch and once on a throwaway \`mergify/merge-queue/<sha>\` draft. Queue via \`merge_protections_settings.auto_merge_conditions\` instead."
  fi

  # --- CHECK 6: something still queues a green PR, and CAN admit one ---------
  local amc_misplaced; amc_misplaced="$(paths_re '(^|\\.)auto_merge_conditions$' | grep -vx 'merge_protections_settings.auto_merge_conditions')"
  if [ -n "$amc_misplaced" ]; then
    err CHECK6 "\`auto_merge_conditions\` is declared at \`$(printf '%s' "$amc_misplaced" | tr '\n' ' ')\`, not at \`merge_protections_settings.auto_merge_conditions\`. Only that path queues anything; written anywhere else it is an unknown key in a rule Mergify then refuses, and green pull requests sit unqueued with no red check to say why."
  fi

  local amc_kind amc_items autoqueue_on
  amc_kind="$(kind_at merge_protections_settings.auto_merge_conditions)"
  amc_items="$(paths_re '^merge_protections_settings\\.auto_merge_conditions\\[[0-9]+\\]$')"
  # `autoqueue` is deprecated but still honoured, so it counts — only when it is
  # at a queue rule's own path AND actually enabled. Any node merely NAMED
  # `autoqueue` satisfies nothing, and `autoqueue: false` disables the very
  # thing this check is looking for.
  autoqueue_on=""
  while read -r r; do
    [ -n "$r" ] || continue
    [ "$(val_at "$r.autoqueue")" = "true" ] && autoqueue_on="yes"
  done <<EOF
$rules
EOF

  if [ -n "$amc_items" ]; then
    :
  elif [ -n "$autoqueue_on" ] || [ -n "$qaction" ]; then
    :
  elif [ "$amc_kind" = "seq" ] || [ "$amc_kind" = "null" ]; then
    err CHECK6 "\`merge_protections_settings.auto_merge_conditions\` is present but empty. An empty condition list is not \"queue everything\" — nothing matches it, so green pull requests sit unqueued exactly as if the key were missing, and no check goes red to say why."
  else
    err CHECK6 "nothing in \`.mergify.yml\` puts a pull request INTO the queue: no \`merge_protections_settings.auto_merge_conditions\`, no enabled \`queue_rules[].autoqueue\`, no queue action. Mergify then posts a \"tick the box to queue\" comment and waits for a human — the pull request sits green and unmerged with no red check anywhere to say why (DataRetrival #2378)."
  fi

  # --- CHECK 7: auto_merge_conditions must not restate the checks ------------
  # Read from the loaded list, so an aliased `auto_merge_conditions: *admission`
  # is inspected like any other.
  #
  # Anchored on the LEFT-HAND OPERATOR, not a substring. `check-` occurs inside
  # ordinary VALUES too — `label = check-success-waived` names a label, restates
  # nothing — and a gate that rejects a correct config teaches its next reader
  # to delete it. The leading `-?` keeps the negated form (`-check-success = X`)
  # in scope, since that is a restated check as well.
  if subtree_vals merge_protections_settings.auto_merge_conditions \
    | grep -qE '^[[:space:]]*-?[[:space:]]*check-(success|neutral|skipped|failure|pending)[[:space:]]*[=:~]'; then
    err CHECK7 "\`auto_merge_conditions\` restates required checks. They belong once, in the anchored condition list, which is what decides when a queued pull request embarks; a second copy is one more list to keep in sync and it will drift. Keep this list to the \`base\`/\`-draft\`/label facts."
  fi

  # --- CHECK 8: auto_merge_conditions must aim at a branch a rule serves -----
  # `base = develop` against queue rules that only serve `main` is the CHECK 6
  # failure with the key present: the list exists, nothing ever matches it.
  amc_base="$(subtree_vals merge_protections_settings.auto_merge_conditions \
    | sed -n 's/^base[[:space:]]*=[[:space:]]*//p' | sed 's/^"//; s/"$//' | sort -u)"
  rule_bases="$(while read -r r; do
      [ -n "$r" ] || continue
      subtree_vals "$r.queue_conditions"
    done <<EOF
$rules
EOF
  )"
  rule_bases="$(printf '%s\n' "$rule_bases" | sed -n 's/^base[[:space:]]*=[[:space:]]*//p' | sed 's/^"//; s/"$//' | sort -u)"
  # A BASE-LESS list is the third spelling, and the loop below cannot see it:
  # with no `base = …` there is nothing to compare, so the check passes. But if
  # the rules DO constrain the base, an unconstrained auto-merge list matches
  # pull requests targeting branches no rule admits — queued into nothing, green
  # and unmerged, nothing red. Only demanded when the rules constrain a base;
  # rules that take any base have nothing for this to disagree with.
  if [ -n "$amc_items" ] && [ -z "$amc_base" ] && [ -n "$rule_bases" ]; then
    err CHECK8 "\`auto_merge_conditions\` names no \`base\`, but the queue rules only admit: $(printf '%s' "$rule_bases" | tr '\n' ' '). Pull requests targeting any other branch are matched for auto-merge and then have no rule to queue into — they sit green and unmerged with no red check to say why. Name the base this repository queues."
  fi
  if [ -n "$amc_base" ] && [ -n "$rule_bases" ]; then
    while read -r b; do
      [ -n "$b" ] || continue
      if ! printf '%s\n' "$rule_bases" | grep -qx -- "$b"; then
        err CHECK8 "\`auto_merge_conditions\` queues pull requests based on \`$b\`, but no queue rule admits that base (the rules serve: $(printf '%s' "$rule_bases" | tr '\n' ' ')). Auto-queueing then matches pull requests no rule can take, or matches nothing at all — either way the pull request sits green and unmerged with no red check to say why."
      fi
    done <<EOF
$amc_base
EOF
  fi
}

selftest() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local cases=0

  # expect <name> "<expected check ids, space-separated>" <config body>
  #
  # The ID SET, not a count: asserting counts lets a regressed detector hide
  # behind a different one firing the same number of times on the same fixture.
  expect() {
    local name="$1" want="$2" body="$3" got
    printf '%b' "$body" >"$tmp/$name.yml"
    fail=0
    got="$(scan_file "$tmp/$name.yml" 2>&1 \
      | sed -n 's/^::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort | tr '\n' ' ' | sed 's/ *$//')"
    want="$(printf '%s' "$want" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
    if [ "$got" != "$want" ]; then
      echo "SELFTEST FAILED — fixture \`$name\` should raise [${want:-none}]; the gate raised [${got:-none}]. A detector is not seeing what this fixture exists to prove."
      return 1
    fi
    cases=$((cases + 1))
  }

  local CLEAN='merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n'

  expect clean '' "$CLEAN" || return 1
  # The four in-place preconditions, one fixture each.
  expect no-mpc CHECK1 "$(printf '%s' "$CLEAN" | sed 's/merge_queue:\\n  max_parallel_checks: 1\\n//')" || return 1
  expect mpc-5 CHECK1 "$(printf '%s' "$CLEAN" | sed 's/max_parallel_checks: 1/max_parallel_checks: 5/')" || return 1
  expect batch-5 CHECK2 "$(printf '%s' "$CLEAN" | sed 's/batch_size: 1/batch_size: 5/')" || return 1
  expect retries CHECK3 "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 1\\n    max_checks_retries: 2/')" || return 1
  # The same key QUOTED, and the same key spliced in through a merge key. Both
  # are the setting; only a parser sees either.
  expect retries-quoted CHECK3 "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 1\\n    "max_checks_retries": 2/')" || return 1
  expect retries-merge-key CHECK3 \
    'defaults: &d\n  max_checks_retries: 2\nmerge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    <<: *d\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The identity, broken the way it actually breaks: two lists written out, equal
  # today. A value comparison passes this; node identity is what catches it.
  expect split-lists CHECK4 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions:\n      - base = main\n      - check-success = "Lint"\n    merge_conditions:\n      - base = main\n      - check-success = "Lint"\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `merge_conditions: []` is the OTHER valid single-step spelling, exactly as
  # omitting the key is. Flagging it would push repos back to a written-out list.
  expect merge-conditions-empty '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions:\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: []\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A queue action returning: CHECK 5 fires, CHECK 6 stays silent (it does queue).
  expect queue-action CHECK5 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions:\n      queue:\n        name: default\n' || return 1
  # The SAME action inline, and again with the whole `actions` mapping inline.
  expect queue-action-inline CHECK5 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions:\n      queue: {name: default}\n' || return 1
  expect queue-action-flow-actions CHECK5 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions: {queue: {name: default}}\n' || return 1
  # Both halves of #2378 removed: nothing queues at all.
  expect nothing-queues CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n' || return 1
  # The key is present and empty. Nothing matches an empty list, so this queues
  # exactly as much as the fixture above: nothing.
  expect amc-empty CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions: []\n' || return 1
  # `autoqueue` is the deprecated path — accepted, but only when enabled.
  expect autoqueue-true '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n    autoqueue: true\n' || return 1
  expect autoqueue-false CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n    autoqueue: false\n' || return 1
  expect amc-checks CHECK7 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - check-success = "Lint"\n' || return 1
  # The same restatement reached through an ALIAS. The list is not written under
  # the key at all; only the loaded document has it there.
  expect amc-checks-aliased CHECK7 \
    'admission: &adm\n  - base = main\n  - check-success = "Lint"\nmerge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions: *adm\n' || return 1
  # Auto-queueing aimed at a branch no queue rule serves: the key is present and
  # the queue still never admits anything.
  expect amc-wrong-base CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = develop\n' || return 1
  # A COMMENTED-OUT queue action must not satisfy CHECK 6, and must not trip
  # CHECK 5: Mergify never sees it, so reading raw text gets both wrong.
  expect commented-out CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n# pull_request_rules:\n#   - name: auto-queue\n#     actions:\n#       queue:\n#         name: default\n' || return 1
  # TWO queue rules, each conforming, each with its OWN anchor.
  expect two-queues '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *def\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # And the same two-rule shape with ONE rule unanchored: a per-rule regression
  # that a whole-file "an anchor exists" test would pass.
  expect two-queues-one-split CHECK4 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions:\n      - base = main\n      - check-success = "Lint"\n    merge_conditions:\n      - base = main\n      - check-success = "Lint"\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The counts BALANCE here — two anchors, two aliases — but the second rule
  # aliases the FIRST rule's node, so its own conditions are a different list.
  expect cross-aliased CHECK4 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n      - check-success = "Build"\n    merge_conditions: *low\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # Second rule omits batch_size. A whole-file count sees the first rule's `1`
  # and passes; this rule batches.
  expect rule-without-batch CHECK2 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *def\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `max_parallel_checks` one level too deep: Mergify rejects the file outright.
  # A keyword scan finds the value it wanted and reports in-place checking.
  expect mpc-misplaced CHECK1 \
    'queue_rules:\n  - name: default\n    max_parallel_checks: 1\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `auto_merge_conditions` in a queue rule: misplaced AND nothing queues.
  expect amc-misplaced 'CHECK6 CHECK6' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n    auto_merge_conditions:\n      - base = main\n' || return 1
  # A required context whose name contains a colon. Quoted, it is one scalar;
  # a reader that splits on `:` invents a path from it and can satisfy a check
  # nothing in the file declares.
  expect colon-in-condition '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - '"'"'check-success = "build: api"'"'"'\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The required check deleted from the one list that gates the queue. Every
  # structural invariant still holds; the queue would merge before CI passes.
  expect no-check-condition CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The skip-aware shape the fleet actually uses: each required check is
  # `or: [check-success = X, check-skipped = X]`, because a path-filtered job
  # legitimately skips and a skipped check is not a success. The checks are then
  # one level below the condition list, where a top-level scan does not see them.
  expect nested-or-conditions '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - or:\n          - check-success = "Lint"\n          - check-skipped = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # And the same nesting used to smuggle the checks into auto_merge_conditions.
  expect amc-checks-nested CHECK7 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - or:\n        - check-success = "Lint"\n        - check-skipped = "Lint"\n' || return 1
  expect no-queue-conditions CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # Two rules, one list: the second aliases the first rule's anchor for BOTH of
  # its fields, so every per-rule identity verdict is `same` and CHECK 4 is
  # silent — while `release` in fact requires the check written for `main`.
  expect shared-condition-list CHECK10 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n  - name: release\n    queue_conditions: *gate\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `auto_merge_conditions` present, non-empty, and naming NO base. The orphan
  # loop has nothing to compare and passes; the list matches pull requests on
  # every branch, and the ones the rule does not admit queue into nothing.
  expect amc-no-base CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - -draft\n' || return 1
  # …but a base-less list is FINE when no rule constrains the base either:
  # there is nothing for it to disagree with, and demanding a base here would
  # reject a correct config.
  expect amc-no-base-unconstrained-rules '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - -draft\n' || return 1
  # `check-success` inside a VALUE, not as the operator. This is a label name;
  # it restates no check, and rejecting it would teach the next reader that
  # CHECK 7 fires on correct configurations and can be deleted.
  expect amc-label-lookalike '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - label != check-success-waived\n' || return 1
  # The same lookalike on the QUEUE side, where the loose reading fails the
  # dangerous way: this rule gates on a label and nothing else, and a substring
  # match reads it as gated on CI.
  expect queue-label-lookalike CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - label != check-success-waived\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A duplicate key: which declaration wins is the loader's business, not this
  # gate's. Both findings are wanted — the second value is also non-compliant,
  # and a reader that stops at the first `max_parallel_checks: 1` reports clean.
  expect duplicate-key 'CHECK0 CHECK1' \
    'merge_queue:\n  max_parallel_checks: 1\n  max_parallel_checks: 5\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # Every invariant above still matches textually; the document does not load,
  # so Mergify refuses the file and the queue stops.
  expect unloadable CHECK0 "${CLEAN}broken: [\n" || return 1
  # A missing file is a finding, not a pass.
  expect_missing() {
    fail=0
    local got; got="$(scan_file "$tmp/absent.yml" 2>&1 | grep -c '^::error::')"
    [ "$got" -eq 1 ] || { echo "SELFTEST FAILED — a missing .mergify.yml reported $got findings, not 1."; return 1; }
    cases=$((cases + 1))
  }
  expect_missing || return 1

  echo "PASS — selftest: $cases fixtures, each asserted on the check ids it plants."
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  selftest || exit 1
  exit 0
fi

scan_file "${1:-$REPO_ROOT/.mergify.yml}"

if [ "$fail" -ne 0 ]; then
  echo "FAILED — the merge queue would check pull requests on a throwaway branch, or nothing would queue them at all."
  exit 1
fi
echo "PASS — the queue checks in place (serial, unbatched, no retries, one anchored condition list per rule), each rule gates on CI, and auto_merge_conditions queues green pull requests without a human."
