#!/usr/bin/env bash
# Self-test for the merge-queue pool's ceiling: the reader that turns a Mergify
# configuration into facts, and the rule that turns those facts into a number of
# hosts.
#
# WHY THIS IS WORTH A GATE
#
# Every way this rule can be wrong is silent, and they are silent in opposite
# directions:
#
#   a ceiling too LOW    throttles the queue. Its checks are PENDING, not
#                        failed, on pull requests whose own CI is green — the
#                        exact symptom this whole delivery exists to remove, and
#                        one that no red check anywhere would report.
#   a ceiling too HIGH   authorises hosts the queue can never keep busy. Only
#                        money, and money nobody chose to spend.
#   a FAIL-CLOSED bug    is the worst of the three: a transient 500 from the
#                        contents API, or a controller booting without
#                        python3-yaml, would take a healthy queue's capacity to
#                        zero. Half the cases below exist for that one.
#
# The fixtures are the fleet's real shapes, taken from the 2026-08-23 survey in
# issue #274 — one queue at `max_parallel_checks: 1`, IntegrateIT's 4 with
# `batch_size: 2`, and the several repos in between.
#
# Tenancy-agnostic — the repository names below are this fleet's own, not a
# customer's.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/mergify-capacity.sh"

PASS=0
FAIL=0

check() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
  fi
}

# facts_of <yaml> — run the reader over a literal document.
facts_of() { printf '%s\n' "$1" | mergify_queue_facts; }

# --- the reader ----------------------------------------------------------------

# Before anything else: prove PyYAML is here. Without it the reader exits 3 and
# every reader case below would compare two empty strings and pass, which is the
# same false green a missing dependency produces on the controller.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "SKIP-IMPOSSIBLE: python3-yaml is not installed, so the reader cannot be tested" >&2
  echo "  (install it: apt-get install -y python3-yaml)" >&2
  exit 1
fi

check "one queue, both knobs set — IntegrateIT's live shape" \
  "$(printf 'default\t4\t2')" \
  "$(facts_of 'queue_rules:
  - name: default
    batch_size: 2
    max_parallel_checks: 4')"

check "the fleet default — one queue, one check, no batch key" \
  "$(printf 'default\t1\t1')" \
  "$(facts_of 'queue_rules:
  - name: default
    max_parallel_checks: 1')"

# A queue that names no concurrency is NOT a queue with none. The reader reports
# the absence as 0 and the RULE supplies Mergify's default of 1 — one place, so
# "said nothing" and "said 1" cannot size a pool differently.
check "a queue that declares no concurrency is reported as 0, not as 1" \
  "$(printf 'default\t0\t1')" \
  "$(facts_of 'queue_rules:
  - name: default')"

check "speculative_checks, the old spelling, is the same knob" \
  "$(printf 'default\t3\t1')" \
  "$(facts_of 'queue_rules:
  - name: default
    speculative_checks: 3')"

check "a per-queue value beats the global one" \
  "$(printf 'default\t5\t1')" \
  "$(facts_of 'merge_queue:
  max_parallel_checks: 2
queue_rules:
  - name: default
    max_parallel_checks: 5')"

check "the global value fills a queue that omits it" \
  "$(printf 'default\t2\t1')" \
  "$(facts_of 'merge_queue:
  max_parallel_checks: 2
queue_rules:
  - name: default')"

check "a merge_queue section and no queue_rules is a single default queue" \
  "$(printf 'default\t2\t1')" \
  "$(facts_of 'merge_queue:
  max_parallel_checks: 2')"

check "several queues are several records" \
  "$(printf 'urgent\t2\t1\ndefault\t4\t2')" \
  "$(facts_of 'queue_rules:
  - name: urgent
    max_parallel_checks: 2
  - name: default
    max_parallel_checks: 4
    batch_size: 2')"

# `max_parallel_checks: yes` is a bool in YAML, and `isinstance(True, int)` is
# True in Python. Read as 1 it would report a repository that wrote nonsense as
# having deliberately chosen a concurrency of one.
check "a boolean concurrency is not read as 1" \
  "$(printf 'default\t0\t1')" \
  "$(facts_of 'queue_rules:
  - name: default
    max_parallel_checks: yes')"

check "a config with only pull_request_rules declares no queue" \
  "" \
  "$(facts_of 'pull_request_rules:
  - name: automerge
    conditions: []
    actions: {}')"

# The three unreadable shapes. Each must FAIL, not return an empty fact set:
# empty facts mean "no queue configured" and fail open with a different reason.
for bad in 'queue_rules: [' 'just a string' '- a
- list'; do
  if facts_of "$bad" >/dev/null 2>&1; then verdict=zero; else verdict=nonzero; fi
  check "unparseable input exits non-zero, never 'no queues': ${bad%%$'\n'*}" \
    "nonzero" "$verdict"
done

# --- the rule ------------------------------------------------------------------

# rule <description> <expected> <facts> <slots> <max_hosts> <jobs_per_check>
rule() {
  local desc="$1" want="$2"
  shift 2
  check "$desc" "$want" "$(mergify_capacity "$@")"
}

# Output is: <hosts> <want> <checks> <batch> <reason>

# --- fail open. The half of this file that matters most. -----------------------
rule "unreadable config keeps the configured ceiling" \
  "7 7 0 0 unreadable" unreadable 4 7 1
rule "unreadable with no configured ceiling stays uncapped, not zero" \
  "0 0 0 0 unreadable" unreadable 4 0 1
# EMPTY IS NOT UNREADABLE. Both fail open to the same number and say entirely
# different things: one is a repository with no merge queue (somebody's bug to
# go and fix), the other is a controller that could not ask.
rule "a config that parsed and declares no queue fails open with its own reason" \
  "7 7 0 0 no-queues" "" 4 7 1

# --- the derivation ------------------------------------------------------------
rule "one check, one job, one slot: one host" \
  "1 1 1 1 derived" "$(printf 'default\t1\t1')" 1 10 1
rule "four checks of one job on four-slot hosts fit on one host" \
  "1 1 4 1 derived" "$(printf 'default\t4\t1')" 4 10 1
rule "four checks of six jobs on four-slot hosts round UP to six" \
  "6 6 4 1 derived" "$(printf 'default\t4\t1')" 4 10 6
rule "concurrency sums across queues" \
  "2 2 6 1 derived" "$(printf 'urgent\t2\t1\ndefault\t4\t1')" 4 10 1

# THE BATCH SIZE IS REPORTED AND NEVER MULTIPLIES. `batch_size: 2` covers two
# pull requests with ONE speculative check run, so it clears the backlog faster
# on the SAME capacity. A rule that multiplied here would double every
# IntegrateIT-shaped pool in the fleet for no reason at all.
rule "batch_size is reported and does not change the ceiling" \
  "1 1 4 2 derived" "$(printf 'default\t4\t2')" 4 10 1
rule "the largest batch size of any queue is the one reported" \
  "2 2 8 3 derived" "$(printf 'a\t4\t3\nb\t4\t1')" 4 10 1

# --- Mergify's own default, supplied once --------------------------------------
rule "a queue that declared no concurrency runs one check" \
  "1 1 1 1 derived" "$(printf 'default\t0\t1')" 4 10 1
rule "declaring 1 and declaring nothing size a pool identically" \
  "$(mergify_capacity "$(printf 'default\t1\t1')" 4 10 1)" \
  "$(printf 'default\t0\t1')" 4 10 1

# --- the configured ceiling still wins -----------------------------------------
# Terraform owns the MIG's maximum and the autoscaler's, so a derived number
# above it is a ceiling that exists only in a metric. `want` carries the number
# the queue asked for — that gap is the alert.
rule "max_hosts caps the derivation, and the shortfall is reported" \
  "3 8 8 1 capped-by-max-hosts" "$(printf 'default\t8\t1')" 1 3 1
rule "max_hosts of 0 means no configured ceiling, so nothing caps" \
  "8 8 8 1 derived" "$(printf 'default\t8\t1')" 1 0 1
rule "a derivation exactly at max_hosts is not a cap" \
  "3 3 3 1 derived" "$(printf 'default\t3\t1')" 1 3 1

# --- inputs a caller can get wrong ---------------------------------------------
# Every one of these would be a divide-by-zero or a zero ceiling — which is to
# say a strangled queue — if it were taken at face value.
rule "zero slots does not divide by zero" \
  "4 4 4 1 derived" "$(printf 'default\t4\t1')" 0 10 1
rule "zero jobs-per-check reads as one, never as no capacity" \
  "4 4 4 1 derived" "$(printf 'default\t4\t1')" 1 10 0
rule "a non-numeric concurrency in the facts reads as Mergify's default" \
  "1 1 1 1 derived" "$(printf 'default\tx\t1')" 1 10 1
rule "no arguments at all fails open rather than sizing a pool to nothing" \
  "0 0 0 0 unreadable"

# --- the fleet, end to end ------------------------------------------------------
# Reader and rule together, over the configurations issue #274 recorded live, on
# a pool of 4-slot hosts with a generous max. These are the numbers the
# migration will produce, and they are here so that a change to either half has
# to restate them on purpose.
fleet() { # <description> <expected-hosts> <yaml> <jobs-per-check>
  local got
  got=$(mergify_capacity "$(facts_of "$3")" 4 20 "$4")
  check "$1" "$2" "${got%% *}"
}
fleet "a 1-check repo needs one host for a 4-job workflow" 1 'queue_rules:
  - name: default
    max_parallel_checks: 1' 4
fleet "DataRetrival's 2 checks of a 4-job workflow need two hosts" 2 'queue_rules:
  - name: default
    max_parallel_checks: 2' 4
fleet "Print-Server's 3 checks of a 4-job workflow need three hosts" 3 'queue_rules:
  - name: default
    max_parallel_checks: 3' 4
fleet "IntegrateIT's 4 checks, batch of 2, still need only four hosts" 4 'queue_rules:
  - name: default
    batch_size: 2
    max_parallel_checks: 4' 4

# --- the sweep that feeds the rule ----------------------------------------------
#
# collect_queue_config lives in controller-startup.sh and is extracted here,
# because the two mistakes it can make are invisible to the rule: both of them
# hand the rule a perfectly well-formed answer that happens to be about a
# different repository's situation than the real one.
#
#   an unreachable API reported as an absent file — gh_api returns 1 for EVERY
#   non-2xx, so without reading the status a revoked token walks all three
#   candidate paths and records "this repository has no queue".
#   a fresh timestamp on a failed read — QUEUE_CONFIG_AT is what
#   ci_queue_config_age_seconds is computed from, and it is the only series that
#   can say a ceiling is being enforced from facts nobody can refresh.
CTRL="$HERE/../../modules/ci-runner-host-pool/scripts/controller-startup.sh"

sweep() { # <description> <expected: facts|file|aged> <status:body pairs, one per path>
  local desc="$1" want="$2"
  shift 2
  local got
  got=$(
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$HERE/../../modules/ci-runner-host-pool/scripts/mergify-capacity.sh"
    # shellcheck disable=SC1090
    eval "$(sed -n '/^collect_queue_config() {/,/^}/p' "$CTRL")"

    STATE_DIR=$(mktemp -d)
    # The controller's own globals. Their only reader is collect_queue_config,
    # which arrives through the `eval` above — invisible to shellcheck, hence the
    # block directive rather than a reader it can see.
    # shellcheck disable=SC2034
    {
      REPO_FULL="owner/repo"
      QUEUE_CONFIG_INTERVAL=300
      QUEUE_CONFIG_LAST=0
      QUEUE_CONFIG_PATHS=".mergify.yml .mergify/config.yml .github/mergify.yml"
    }
    QUEUE_CONFIG_AT=0
    QUEUE_CONFIG_FILE=""
    # The previous sweep's answer, so that "kept" is distinguishable from
    # "overwritten with the same thing".
    QUEUE_FACTS="previous"
    # Both stubs are called only from the eval'd function, so shellcheck reads
    # their bodies as dead code (SC2317). They are the opposite: they are the
    # whole experiment.
    # shellcheck disable=SC2317
    log() { :; }

    # One `<status>:<body>` per candidate path, in order. gh_api's contract is
    # reproduced exactly: the status is written to the state file whatever
    # happens, and a non-2xx returns 1 having printed nothing.
    RESPONSES=("$@")
    # The call counter lives in a FILE, not a variable. gh_api is invoked as
    # `$(gh_api ...)`, which is a subshell, so a variable increment inside it is
    # discarded and every candidate path would be answered with the first
    # response — a stub that silently ignores its own script.
    echo 0 >"$STATE_DIR/calls"
    # shellcheck disable=SC2317
    gh_api() {
      local call pair
      call=$(cat "$STATE_DIR/calls")
      pair="${RESPONSES[$call]:-404:}"
      echo $((call + 1)) >"$STATE_DIR/calls"
      printf '%s' "${pair%%:*}" >"$STATE_DIR/api.status"
      case "${pair%%:*}" in
        2*) printf '{"content":"%s"}' "$(printf '%s' "${pair#*:}" | base64 -w0)" ;;
        *) return 1 ;;
      esac
    }

    collect_queue_config
    # `aged` is whether the read counted as fresh, not the age itself — the
    # clock is the caller's and a self-test that asserted seconds would be
    # asserting how fast it ran.
    printf '%s|%s|%s' "${QUEUE_FACTS//$'\n'/;}" "$QUEUE_CONFIG_FILE" \
      "$([ "$QUEUE_CONFIG_AT" -gt 0 ] && echo fresh || echo stale)"
    rm -rf "$STATE_DIR"
  )
  check "$desc" "$want" "$got"
}

sweep "the first candidate path that exists is the one read" \
  'default	2	1|.mergify.yml|fresh' \
  '200:queue_rules:
  - name: default
    max_parallel_checks: 2'

sweep "a 404 walks on to the next candidate path" \
  'default	3	1|.github/mergify.yml|fresh' \
  '404:' '404:' '200:queue_rules:
  - name: default
    max_parallel_checks: 3'

sweep "no config anywhere is the FACT of no queue, not an unreadable repository" \
  '||fresh' \
  '404:' '404:' '404:'

# The fix this case exists for: a 500 is not a 404. Reported as an absence it
# would fail open to the same ceiling, look identical on every chart, and quietly
# stop being about the repository's configuration at all.
sweep "an unreachable API keeps the previous facts and does NOT claim there is no queue" \
  'previous||stale' \
  '500:' '404:' '404:'

sweep "a token the App no longer holds keeps the previous facts" \
  'previous||stale' \
  '401:' '401:' '401:'

# A file that EXISTS and does not parse must not fall through to the next
# candidate: reporting the absence of a path the repository does not use as the
# reason the one it does use failed is a diagnosis pointing at the wrong file.
sweep "an unparseable config keeps the previous facts and stops at that file" \
  'previous||stale' \
  '200:queue_rules: [' '200:queue_rules:
  - name: default
    max_parallel_checks: 9'

sweep "a config that parses to no queue at all is recorded as read" \
  '|.mergify.yml|fresh' \
  '200:pull_request_rules: []'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
