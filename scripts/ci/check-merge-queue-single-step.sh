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
#   repository runs a second time on the self-hosted fleet:
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

# Every non-comment line of the file, comments stripped. Every check below reads
# THIS, never the raw text — a rule that a commented-out block can satisfy is a
# rule that passes on configuration Mergify never sees.
live_lines() { strip_comment <"$1" | sed 's/[[:space:]]*$//'; }

scan_file() {
  local f="$1" live mpc batch amc
  if [ ! -f "$f" ]; then
    err "no Mergify configuration at $f. This gate cannot show that the queue checks in place, and a missing config is not an absent queue — Mergify falls back to its own defaults."
    return
  fi
  live="$(live_lines "$f")"

  # --- CHECK 1: max_parallel_checks -----------------------------------------
  # `values_of` keeps ONE VALUE PER LINE. An earlier revision piped the whole
  # match through `tr -d '[:space:]'`, which deleted the newlines too: a file
  # with two queue rules, each `batch_size: 1`, became the single value `11` and
  # was reported as a batch of eleven. A gate that fails on conforming config is
  # a gate that gets deleted.
  values_of() {
    printf '%s\n' "$live" | grep -E "^[[:space:]]*$1[[:space:]]*:" \
      | sed -E "s/.*:[[:space:]]*//" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
      | sed '/^$/d'
  }
  mpc="$(values_of max_parallel_checks | head -1)"
  if [ -z "$mpc" ]; then
    err "\`.mergify.yml\` declares no \`merge_queue.max_parallel_checks\`. Left unset it inherits a vendor default above 1, and parallel queue checks are performed on throwaway \`mergify/merge-queue/<sha>\` branches — a second full CI run per pull request on the self-hosted fleet."
  elif [ "$mpc" != "1" ]; then
    err "\`max_parallel_checks\` is \`$mpc\`, not 1. Anything above 1 makes Mergify check on throwaway \`mergify/merge-queue/<sha>\` branches instead of in place, which re-runs every \`pull_request\` workflow a second time."
  fi

  # --- CHECK 2: batch_size ---------------------------------------------------
  batch="$(values_of batch_size)"
  if [ -z "$batch" ]; then
    err "no queue rule declares \`batch_size\`. The default batches pull requests together, and a batch is validated on a throwaway queue branch — the second CI run this gate exists to prevent."
  else
    # One finding per offending rule, and the loop runs in THIS shell so `fail`
    # survives it — a `| while` body is a subshell and its assignment is lost.
    while read -r b; do
      [ "$b" = "1" ] || err "a queue rule sets \`batch_size: $b\`. Any batch larger than 1 is checked on a throwaway \`mergify/merge-queue/<sha>\` branch, re-running every \`pull_request\` workflow, and a failure anywhere in the batch sends every member back through CI."
    done <<EOF
$batch
EOF
  fi

  # --- CHECK 3: max_checks_retries ------------------------------------------
  if printf '%s\n' "$live" | grep -qE '^[[:space:]]*max_checks_retries[[:space:]]*:'; then
    err "\`max_checks_retries\` is set. Retrying checks requires a queue branch to retry them ON, so declaring it disables in-place checking outright."
  fi

  # --- CHECK 4: single-step, via the anchor ----------------------------------
  # Counted PER RULE, not per file. A repository with a routing queue has two
  # rules, and "an anchor exists somewhere" passes a file where one rule shares
  # its node and the other writes two lists out — two-step CI for every pull
  # request that rule admits, on a file that looks compliant.
  local qc_total qc_anchored mc_total mc_aliased
  qc_total="$(printf '%s\n' "$live" | grep -cE '^[[:space:]]*queue_conditions[[:space:]]*:')"
  qc_anchored="$(printf '%s\n' "$live" | grep -cE '^[[:space:]]*queue_conditions[[:space:]]*:[[:space:]]*&[A-Za-z0-9_-]+[[:space:]]*$')"
  mc_total="$(printf '%s\n' "$live" | grep -cE '^[[:space:]]*merge_conditions[[:space:]]*:')"
  mc_aliased="$(printf '%s\n' "$live" | grep -cE '^[[:space:]]*merge_conditions[[:space:]]*:[[:space:]]*\*[A-Za-z0-9_-]+[[:space:]]*$')"
  # `merge_conditions` absent altogether is the OTHER single-step spelling:
  # Mergify then merges on `queue_conditions`. Nothing to assert in that case.
  if [ "$mc_total" -gt 0 ]; then
    if [ "$mc_aliased" -ne "$mc_total" ] || [ "$qc_anchored" -ne "$qc_total" ] || [ "$qc_total" -eq 0 ]; then
      err "a queue rule's \`queue_conditions\` and \`merge_conditions\` are not the same YAML node ($qc_anchored of $qc_total \`queue_conditions\` anchored, $mc_aliased of $mc_total \`merge_conditions\` aliased). Mergify checks a queued pull request in place only when \`merge_conditions\` is empty or IDENTICAL to \`queue_conditions\`; two separately written lists match only until the next check is added to one of them, and the drift is silent — merges keep working, each pull request merely pays a second full CI run. Write \`queue_conditions: &gate\` and \`merge_conditions: *gate\` in EVERY queue rule, or drop \`merge_conditions\` entirely."
    fi
  fi

  # --- CHECK 5: no queue action ---------------------------------------------
  if printf '%s\n' "$live" | grep -qE '^[[:space:]]*queue[[:space:]]*:[[:space:]]*$' \
    && printf '%s\n' "$live" | grep -qE '^pull_request_rules[[:space:]]*:'; then
    err "a \`pull_request_rules\` queue action is back. Its \`conditions:\` are a SEPARATE list from \`merge_conditions\` — different by construction, since it must carry \`base\`/\`-draft\` — so every pull request is checked twice: once on its own branch and once on a throwaway \`mergify/merge-queue/<sha>\` draft. Queue via \`merge_protections_settings.auto_merge_conditions\` instead."
  fi

  # --- CHECK 6: something still queues a green PR ----------------------------
  if ! printf '%s\n' "$live" | grep -qE '^[[:space:]]*auto_merge_conditions[[:space:]]*:' \
    && ! printf '%s\n' "$live" | grep -qE '^[[:space:]]*autoqueue[[:space:]]*:[[:space:]]*true' \
    && ! printf '%s\n' "$live" | grep -qE '^[[:space:]]*queue[[:space:]]*:[[:space:]]*$'; then
    err "nothing in \`.mergify.yml\` puts a pull request INTO the queue: no \`merge_protections_settings.auto_merge_conditions\`, no \`autoqueue\`, no queue action. Mergify then posts a \"tick the box to queue\" comment and waits for a human — the pull request sits green and unmerged with no red check anywhere to say why (DataRetrival #2378)."
  fi

  # --- CHECK 7: auto_merge_conditions must not restate the checks ------------
  amc="$(printf '%s\n' "$live" | awk '
    /^[[:space:]]*auto_merge_conditions[[:space:]]*:/ { grab = 1; ind = match($0, /[^ ]/); next }
    grab && /^[[:space:]]*$/ { next }
    grab { if (match($0, /[^ ]/) <= ind) { grab = 0 } else { print } }')"
  if printf '%s\n' "$amc" | grep -q 'check-success'; then
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
  # Both halves of #2378 removed: nothing queues at all.
  expect nothing-queues 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\n' || return 1
  expect amc-checks 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - check-success = "Lint"\n' || return 1
  # A COMMENTED-OUT queue action must not satisfy CHECK 6, and must not trip
  # CHECK 5: Mergify never sees it, so reading raw text gets both wrong.
  expect commented-out 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n    merge_conditions: *gate\n    batch_size: 1\n# pull_request_rules:\n#   - name: auto-queue\n#     actions:\n#       queue:\n#         name: default\n' || return 1
  # TWO queue rules, each conforming. The values are read one per line for this
  # reason: collapsing whitespace fused `1` and `1` into `11`, and a repository
  # with a routing queue (IntegrateIT's `low-risk`/`default`) was told it had a
  # batch of eleven.
  expect two-queues 0 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - -files~=^apps/\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n    merge_conditions: *def\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # And the same two-rule shape with ONE rule unanchored: the count comparison
  # is what catches a per-rule regression a whole-file "an anchor exists" test
  # would pass.
  expect two-queues-one-split 1 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions:\n      - base = main\n    merge_conditions:\n      - base = main\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
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
echo "PASS — the queue checks in place (serial, unbatched, no retries, one anchored condition list) and auto_merge_conditions queues green pull requests without a human."
