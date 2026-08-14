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
#   Identity (4) is asserted as the ANCHOR SPELLING — `queue_conditions: &gate`
#   with `merge_conditions: *gate` — rather than by comparing two lists. Two
#   lists that happen to match today drift apart on the next check added to one
#   of them, and the drift is invisible: the queue keeps merging, it merely
#   costs a second full CI run. The anchor makes them the same YAML node, so
#   they cannot diverge.
#
# CHECK 5 — nothing may reach the queue through a `pull_request_rules` queue
#   action, because that rule's `conditions:` are a SECOND list and a second
#   list differs by construction (if only by carrying `base`/`-draft`).
#
# CHECK 6 — but SOMETHING must still queue a green pull request without a human.
#   Removing the queue action is only half the change. With no queue action and
#   no `auto_merge_conditions`, Mergify posts a "tick the box to queue" comment
#   and waits: the PR is green, no merge happens, and NO check anywhere goes red
#   to say why. That regression shipped once (DataRetrival #2378, fixed in
#   #2384) and is the reason this check exists as a pair with CHECK 5.
#
# CHECK 7 — `auto_merge_conditions` must not restate the required checks. They
#   live once, in the anchored list, which is what governs when a queued pull
#   request embarks; a second copy is a list to keep in sync, and the anchor
#   exists precisely so that no such copy exists.
#
# HOW IT READS THE FILE — BY PATH, NOT BY KEYWORD
#   Every check below matches an EXACT YAML PATH (`merge_queue.max_parallel_checks`,
#   `queue_rules[1].batch_size`), never a key name found anywhere in the text.
#   The difference is the whole gate: `max_parallel_checks` written one level
#   too deep, inside a queue rule, is a file Mergify REJECTS OUTRIGHT — no rule
#   loads, nothing queues — while a keyword scan sees the value it wanted and
#   reports in-place checking. Same for `auto_merge_conditions` under a queue
#   rule, and for a per-rule `batch_size` that a whole-file count says exists
#   because a DIFFERENT rule declares it. A gate whose characteristic failure is
#   a vacuous pass has to know where it is looking.
#
#   `yaml_paths` below is a small indentation-tracking reader for the subset
#   Mergify configs use (block mappings, block sequences, anchors, aliases,
#   inline flow values). It emits one `path<TAB>value` record per node. It is not
#   a YAML implementation, and it is not asked to be one: CHECK 0 hands the file
#   to a real parser when one is on the runner, because a file this reader walks
#   happily can still be a file Mergify cannot load.
#
# EXIT CODES
#   0 — clean
#   1 — an invariant is broken
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0
err() { echo "::error::$*"; fail=1; }

# A YAML comment stripped from a line, leaving `#` inside a quoted scalar alone.
# Without this, `batch_size: 4 # was 1` and a commented-out `queue:` action are
# read as configuration.
strip_comment() {
  awk '{
    s = $0; out = ""; q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q != "") { if (c == q) q = ""; out = out c; continue }
      if (c == "\047" || c == "\"") { q = c; out = out c; continue }
      if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) break
      out = out c
    }
    print out
  }'
}

# One `path<TAB>value` record per node, comments already stripped. Sequence
# entries are indexed (`queue_rules[0]`), so every check can name the exact
# position it means instead of the key it hopes is in the right place.
yaml_paths() {
  strip_comment <"$1" | sed 's/[[:space:]]*$//' | awk '
    function pathstr(   i, s) {
      s = ""
      for (i = 1; i <= top; i++) {
        if (fseq[i]) s = s fname[i]
        else s = (s == "" ? fname[i] : s "." fname[i])
      }
      return s
    }
    /^[[:space:]]*$/ { next }
    {
      ind = match($0, /[^ ]/) - 1
      rest = substr($0, ind + 1)
      isitem = 0

      # A sequence entry belongs to the nearest key ABOVE it, whether written
      # indented under that key or at the same column — both are legal YAML and
      # both appear in the wild, so neither may silently reparent the entry.
      if (rest ~ /^-([[:space:]]|$)/) {
        while (top > 0 && find[top] > ind) top--
        while (top > 0 && find[top] == ind && fseq[top]) top--
        parent = pathstr()
        idx = cnt[parent]; cnt[parent] = idx + 1
        top++; find[top] = ind; fname[top] = "[" idx "]"; fseq[top] = 1
        sub(/^-[[:space:]]*/, "", rest)
        ind = ind + 2
        isitem = 1
        if (rest == "") next
      }

      # A key is an unquoted identifier followed by a colon. Deliberately narrow:
      # a Mergify condition such as `check-success = "build: api"` is a SCALAR
      # that contains a colon, and reading it as a key would invent a path.
      if (rest ~ /^[A-Za-z_][A-Za-z0-9_.-]*[[:space:]]*:([[:space:]]|$)/) {
        while (top > 0 && find[top] >= ind) top--
        k = rest; sub(/[[:space:]]*:.*$/, "", k)
        v = rest; sub(/^[A-Za-z_][A-Za-z0-9_.-]*[[:space:]]*:[[:space:]]*/, "", v)
        p = pathstr(); p = (p == "" ? k : p "." k)
        printf "%s\t%s\n", p, v
        top++; find[top] = ind; fname[top] = k; fseq[top] = 0; cnt[p] = 0
      } else if (isitem) {
        printf "%s\t%s\n", pathstr(), rest
      }
    }'
}

scan_file() {
  local f="$1" doc mpc misplaced rules r b qc mc anchor alias
  if [ ! -f "$f" ]; then
    err "no Mergify configuration at $f. This gate cannot show that the queue checks in place, and a missing config is not an absent queue — Mergify falls back to its own defaults."
    return
  fi
  doc="$(yaml_paths "$f")"

  # Exact-path readers. `$1 == p` and nothing looser: a check that matches a
  # SUFFIX is a check that accepts the key one level too deep, which is the
  # misplacement this gate exists to catch.
  val_at()  { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }
  has_path() { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { found = 1 } END { exit !found }'; }
  paths_re() { printf '%s\n' "$doc" | awk -F'\t' -v re="$1" '$1 ~ re { print $1 }'; }

  # --- CHECK 0: it has to be loadable at all ---------------------------------
  # Every check below reads a reader that tolerates what Mergify would refuse.
  # An unterminated flow sequence three keys away leaves all seven invariants
  # matching while Mergify loads NOTHING and no pull request can queue — so a
  # real parser runs first when the runner has one.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    local perr
    if ! perr="$(python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$f" 2>&1)"; then
      err "\`$f\` is not loadable YAML, so nothing below it is worth asserting: Mergify refuses the whole file and NO pull request queues. Parser said: $(printf '%s' "$perr" | tr '\n' ' ' | tail -c 400)"
      return
    fi
  else
    echo "NOTE — no YAML parser on this runner (python3 with PyYAML), so this run asserts structure only. A file that is well-formed to this reader but malformed to a real parser is caught by Mergify's own \`Configuration changed\` check on the pull request, not here."
  fi

  # --- CHECK 1: max_parallel_checks, at the top level and nowhere else -------
  misplaced="$(paths_re '(^|\\.)max_parallel_checks$' | grep -vx 'merge_queue.max_parallel_checks')"
  if [ -n "$misplaced" ]; then
    err "\`max_parallel_checks\` is declared at \`$(printf '%s' "$misplaced" | tr '\n' ' ')\`, not at the top-level \`merge_queue.max_parallel_checks\`. Mergify permits it in exactly one place and REJECTS the whole file otherwise (\`Extra inputs are not permitted\`) — so this is not a value in the wrong spot, it is a configuration that loads nothing and queues nothing."
  else
    mpc="$(val_at merge_queue.max_parallel_checks)"
    if [ -z "$mpc" ]; then
      err "\`.mergify.yml\` declares no \`merge_queue.max_parallel_checks\`. Left unset it inherits a vendor default above 1, and parallel queue checks are performed on throwaway \`mergify/merge-queue/<sha>\` branches — a second full CI run per pull request."
    elif [ "$mpc" != "1" ]; then
      err "\`merge_queue.max_parallel_checks\` is \`$mpc\`, not 1. Anything above 1 makes Mergify check on throwaway \`mergify/merge-queue/<sha>\` branches instead of in place, which re-runs every \`pull_request\` workflow a second time."
    fi
  fi

  # --- CHECK 2: batch_size, once per rule ------------------------------------
  # Per rule, because the default is inherited PER RULE. A whole-file count says
  # `batch_size: 1` exists; the rule that omitted it still batches.
  rules="$(paths_re '^queue_rules\\[[0-9]+\\]\\.' | sed -E 's/^(queue_rules\[[0-9]+\]).*/\1/' | sort -u)"
  if [ -z "$rules" ]; then
    err "\`.mergify.yml\` declares no \`queue_rules\`. Mergify then supplies its own defaults, which batch pull requests together and validate the batch on a throwaway queue branch — the second CI run this gate exists to prevent."
  else
    while read -r r; do
      [ -n "$r" ] || continue
      b="$(val_at "$r.batch_size")"
      if [ -z "$b" ]; then
        err "queue rule \`$r\` declares no \`batch_size\`. It inherits the batching default, and a batch is validated on a throwaway \`mergify/merge-queue/<sha>\` branch — every \`pull_request\` workflow runs a second time for any pull request this rule admits, whatever the other rules declare."
      elif [ "$b" != "1" ]; then
        err "queue rule \`$r\` sets \`batch_size: $b\`. Any batch larger than 1 is checked on a throwaway \`mergify/merge-queue/<sha>\` branch, re-running every \`pull_request\` workflow, and a failure anywhere in the batch sends every member back through CI."
      fi
    done <<EOF
$rules
EOF
  fi

  # --- CHECK 3: max_checks_retries ------------------------------------------
  if [ -n "$(paths_re '(^|\\.)max_checks_retries$')" ]; then
    err "\`max_checks_retries\` is set at \`$(paths_re '(^|\\.)max_checks_retries$' | tr '\n' ' ')\`. Retrying checks requires a queue branch to retry them ON, so declaring it disables in-place checking outright."
  fi

  # --- CHECK 4: single-step, via the anchor, matched WITHIN each rule --------
  # The anchor NAME is compared per rule. Counting anchors and aliases across
  # the file passes a two-rule config where the second rule aliases the FIRST
  # rule's anchor: the counts balance, the nodes differ, and every pull request
  # that second rule admits gets two-step CI.
  if [ -n "$rules" ]; then
    while read -r r; do
      [ -n "$r" ] || continue
      has_path "$r.merge_conditions" || continue   # absent is the other single-step spelling
      qc="$(val_at "$r.queue_conditions")"
      mc="$(val_at "$r.merge_conditions")"
      anchor=""; alias=""
      case "$qc" in '&'*) anchor="${qc#&}" ;; esac
      case "$mc" in '*'*) alias="${mc#\*}" ;; esac
      if [ -z "$anchor" ] || [ -z "$alias" ] || [ "$anchor" != "$alias" ]; then
        err "queue rule \`$r\` does not share ONE node between \`queue_conditions\` (${qc:-a written-out list}) and \`merge_conditions\` (${mc:-a written-out list}). Mergify checks a queued pull request in place only when \`merge_conditions\` is empty or IDENTICAL to \`queue_conditions\`; two separately written lists — or an alias pointing at another rule's anchor — match only until the next check is added to one of them, and the drift is silent: merges keep working, each pull request merely pays a second full CI run. Write \`queue_conditions: &<name>\` and \`merge_conditions: *<name>\` with THIS rule's own name, or drop \`merge_conditions\` entirely."
      fi
    done <<EOF
$rules
EOF
  fi

  # --- CHECK 5: no queue action ---------------------------------------------
  # Matched on the ACTION PATH, so `queue:` as a block mapping and `queue: {name: default}`
  # inline are the same finding. An end-anchored text match sees only the former.
  local qaction; qaction="$(paths_re '^pull_request_rules\\[[0-9]+\\]\\.actions\\.queue$')"
  if [ -n "$qaction" ]; then
    err "a \`pull_request_rules\` queue action is back at \`$(printf '%s' "$qaction" | tr '\n' ' ')\`. Its \`conditions:\` are a SEPARATE list from \`merge_conditions\` — different by construction, since it must carry \`base\`/\`-draft\` — so every pull request is checked twice: once on its own branch and once on a throwaway \`mergify/merge-queue/<sha>\` draft. Queue via \`merge_protections_settings.auto_merge_conditions\` instead."
  fi

  # --- CHECK 6: something still queues a green PR ----------------------------
  local amc_misplaced; amc_misplaced="$(paths_re '(^|\\.)auto_merge_conditions$' | grep -vx 'merge_protections_settings.auto_merge_conditions')"
  if [ -n "$amc_misplaced" ]; then
    err "\`auto_merge_conditions\` is declared at \`$(printf '%s' "$amc_misplaced" | tr '\n' ' ')\`, not at \`merge_protections_settings.auto_merge_conditions\`. Only that path queues anything; written anywhere else it is an unknown key in a rule Mergify then refuses, and green pull requests sit unqueued with no red check to say why."
  fi
  if ! has_path merge_protections_settings.auto_merge_conditions \
    && [ -z "$(paths_re '(^|\\.)autoqueue$')" ] \
    && [ -z "$qaction" ]; then
    err "nothing in \`.mergify.yml\` puts a pull request INTO the queue: no \`merge_protections_settings.auto_merge_conditions\`, no \`autoqueue\`, no queue action. Mergify then posts a \"tick the box to queue\" comment and waits for a human — the pull request sits green and unmerged with no red check anywhere to say why (DataRetrival #2378)."
  fi

  # --- CHECK 7: auto_merge_conditions must not restate the checks ------------
  if printf '%s\n' "$doc" \
    | awk -F'\t' '$1 ~ /^merge_protections_settings\.auto_merge_conditions\[[0-9]+\]$/ { print $2 }' \
    | grep -q 'check-success'; then
    err "\`auto_merge_conditions\` restates required checks. They belong once, in the anchored condition list, which is what decides when a queued pull request embarks; a second copy is one more list to keep in sync and it will drift. Keep this list to the \`base\`/\`-draft\`/label facts."
  fi
}

selftest() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local cases=0

  # expect <name> <expected-diagnostics> <config body>
  expect() {
    local name="$1" want="$2" body="$3" got
    printf '%b' "$body" >"$tmp/$name.yml"
    fail=0
    got="$(scan_file "$tmp/$name.yml" 2>&1 | grep -c '^::error::')"
    if [ "$got" -ne "$want" ]; then
      echo "SELFTEST FAILED — fixture \`$name\` plants $want violation(s); the detector reported $got. That detector is not seeing what this fixture exists to prove."
      return 1
    fi
    cases=$((cases + 1))
  }

  local CLEAN='merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n'

  expect clean 0 "$CLEAN" || return 1
  # The four in-place preconditions, one fixture each.
  expect no-mpc 1 "$(printf '%s' "$CLEAN" | sed 's/merge_queue:\\n  max_parallel_checks: 1\\n//')" || return 1
  expect mpc-5 1 "$(printf '%s' "$CLEAN" | sed 's/max_parallel_checks: 1/max_parallel_checks: 5/')" || return 1
  expect batch-5 1 "$(printf '%s' "$CLEAN" | sed 's/batch_size: 1/batch_size: 5/')" || return 1
  expect retries 1 "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 1\\n    max_checks_retries: 2/')" || return 1
  # The identity, broken the way it actually breaks: two lists written out, equal
  # today. A value comparison passes this; the anchor test is what catches it.
  expect split-lists 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions:\n      - base = main\n      - check-success = "Lint"\n    merge_conditions:\n      - base = main\n      - check-success = "Lint"\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A queue action returning: CHECK 5 fires, CHECK 6 stays silent (it does queue).
  expect queue-action 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions:\n      queue:\n        name: default\n' || return 1
  # The SAME action in inline flow style. Mergify reads the two identically; a
  # text match anchored at end-of-line reads only the block one.
  expect queue-action-inline 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions:\n      queue: {name: default}\n' || return 1
  # Both halves of #2378 removed: nothing queues at all.
  expect nothing-queues 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\n' || return 1
  expect amc-checks 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - check-success = "Lint"\n' || return 1
  # A COMMENTED-OUT queue action must not satisfy CHECK 6, and must not trip
  # CHECK 5: Mergify never sees it, so reading raw text gets both wrong.
  expect commented-out 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\n# pull_request_rules:\n#   - name: auto-queue\n#     actions:\n#       queue:\n#         name: default\n' || return 1
  # TWO queue rules, each conforming, each with its OWN anchor.
  expect two-queues 0 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - -files~=^apps/\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n    merge_conditions: *def\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # And the same two-rule shape with ONE rule unanchored: a per-rule regression
  # that a whole-file "an anchor exists" test would pass.
  expect two-queues-one-split 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions:\n      - base = main\n    merge_conditions:\n      - base = main\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The counts BALANCE here — two anchors, two aliases — but the second rule
  # aliases the FIRST rule's node, so its own conditions are a different list.
  expect cross-aliased 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # Second rule omits batch_size. A whole-file count sees the first rule's `1`
  # and passes; this rule batches.
  expect rule-without-batch 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n    merge_conditions: *def\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `max_parallel_checks` one level too deep: Mergify rejects the file outright.
  # A keyword scan finds the value it wanted and reports in-place checking.
  expect mpc-misplaced 1 \
    'queue_rules:\n  - name: default\n    max_parallel_checks: 1\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `auto_merge_conditions` in a queue rule: misplaced AND nothing queues.
  expect amc-misplaced 2 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\n    auto_merge_conditions:\n      - base = main\n' || return 1
  # A condition scalar containing a colon is a VALUE, not a key. Misreading it
  # invents a path and can silently satisfy a check nothing declared.
  expect colon-in-condition 0 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "build: api"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A missing file is a finding, not a pass.
  expect_missing() {
    fail=0
    local got; got="$(scan_file "$tmp/absent.yml" 2>&1 | grep -c '^::error::')"
    [ "$got" -eq 1 ] || { echo "SELFTEST FAILED — a missing .mergify.yml reported $got findings, not 1."; return 1; }
    cases=$((cases + 1))
  }
  expect_missing || return 1

  echo "PASS — selftest: $cases fixtures, each asserted on its own."
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
echo "PASS — the queue checks in place (serial, unbatched, no retries, one anchored condition list per rule) and auto_merge_conditions queues green pull requests without a human."
