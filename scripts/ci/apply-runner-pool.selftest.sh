#!/usr/bin/env bash
# Self-test for the reusable workflow that applies a consumer's runner root.
#
# WHY: v5.7.0 fixed a job inheriting the previous job's cloud credentials. It
# merged into nine repositories on 2026-08-15 and reached ONE pool — the one
# whose apply a person ran by hand. The other eight kept the old startup script,
# and nothing anywhere was red: every pin was current, every gate green, every
# PR merged. A pin that is merged and never applied is indistinguishable from
# the outside from a pin that was never bumped.
#
# So the properties below are the ones that decide whether an automated apply
# can be TRUSTED to run unattended — because an apply nobody trusts is an apply
# somebody disables, and then we are back to the hand-run.
#
# STRUCTURAL, on the workflow text, with a paired mutation for each: a gate that
# only passes on correct input is not evidence.

# Every predicate matches the TEXT of the workflow, in which `${{ ... }}` are
# the literal characters that must be there.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$HERE/../../.github/workflows/apply-runner-pool.yml"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$WORKFLOW" ] || { echo "FAIL: missing $WORKFLOW"; exit 1; }

# Code only: full-line comments stripped, so the rationale written above each
# property can never satisfy the check for the property.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `... | grep -q` under `set -o pipefail`: grep exits on first match, the
# writer takes SIGPIPE, and a successful match reports as a failure.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# GitHub-hosted, deliberately. The pool being applied is the pool the consumer's
# own jobs run on: apply it from inside itself and the controller can drain the
# host running the apply, leaving terraform's state lock held by a process that
# no longer exists — and the next run, scheduled or human, fails on the lock.
runs_off_the_pool_it_applies() {
  local code; code=$(code_of "$1")
  matches "$code" 'runs-on: ubuntu-latest' || return 1
  ! matches "$code" 'runs-on:.*self-hosted' || return 1
}

# A reusable workflow, so the consumer owns the triggers — and must be able to
# schedule it, which is the only trigger that fires when a floating pin moves.
is_callable_by_a_consumer() {
  local code; code=$(code_of "$1")
  matches "$code" '^  workflow_call:' || return 1
  matches "$code" 'terraform_root:' || return 1
}

# No static key anywhere in this fleet. Without id-token the job cannot mint a
# federated credential at all, and the fallback is a JSON key in a secret.
authenticates_by_federation() {
  local code; code=$(code_of "$1")
  matches "$code" 'id-token: write' || return 1
  matches "$code" 'workload_identity_provider: \$\{\{ inputs\.' || return 1
  ! matches "$code" 'credentials_json' || return 1
}

# `-upgrade`, not a plain init. A consumer pinning ?ref=v5 keeps the previously
# resolved v5 in any reused .terraform, and a plain init keeps what it has — so
# the scheduled run re-applies the same module forever and reports success every
# time. That is the failure this whole workflow exists to remove, reproduced.
re_resolves_the_floating_pin() {
  local code; code=$(code_of "$1")
  matches "$code" 'terraform init .*-upgrade' || return 1
}

# `-detailed-exitcode` makes 0/2 mean no-changes/changes — which also means a
# plan FAILURE (exit 1) must be re-raised explicitly. Swallow it and a broken
# root reads as "nothing to apply", green, forever.
tells_no_changes_from_a_broken_plan() {
  local code; code=$(code_of "$1")
  matches "$code" '\-detailed-exitcode' || return 1
  matches "$code" 'changes=false' || return 1
  matches "$code" 'changes=true' || return 1
  matches "$code" 'exit "\$rc"' || return 1
}

# The SAVED plan, never a re-plan. Between plan and apply the floating tag can
# move; applying something nobody printed is precisely the unattended-apply
# failure that would justify turning this off.
applies_only_what_it_printed() {
  local code; code=$(code_of "$1")
  matches "$code" '\-out=tf\.plan' || return 1
  matches "$code" 'terraform apply .*tf\.plan' || return 1
  ! matches "$code" 'terraform apply .*-auto-approve' || return 1
}

# The wrapper replaces terraform's exit code with its own and captures stderr
# into an output — with -detailed-exitcode that is not a cosmetic difference,
# it destroys the very signal the plan step branches on.
reads_terraforms_own_exit_code() {
  local code; code=$(code_of "$1")
  matches "$code" 'terraform_wrapper: false' || return 1
}

# Two applies on one root race for the state lock. Terraform would fail the
# second rather than corrupt anything, but a failed apply is a red check
# somebody must read before learning it was only a race. Not cancel-in-progress:
# cancelling terraform mid-apply is how a lock is left behind.
serialises_applies_per_root() {
  local code; code=$(code_of "$1")
  matches "$code" 'group: apply-runner-pool-' || return 1
  matches "$code" 'inputs\.terraform_root' || return 1
  matches "$code" 'cancel-in-progress: false' || return 1
}

# An apply is not the same thing as in effect: the MIG updates OPPORTUNISTIC-ally
# so a new template does NOT replace running hosts. Reporting the gap is what
# stops "applied" being read as "the fleet has the fix".
says_applied_is_not_in_effect() {
  local code; code=$(code_of "$1")
  matches "$code" 'GITHUB_STEP_SUMMARY' || return 1
  matches "$code" 'PREVIOUS startup script' || return 1
}

# Called from a pull_request trigger, this job would apply terraform taken from
# the PR BRANCH using an identity that can rebuild the consumer's whole CI fleet
# — and the reviewer's diff is not what runs, because a floating module ref and
# a branch `.auto.tfvars` both resolve from the checkout. A fork PR is starved of
# id-token; a same-repo branch is not. Consumers copy the caller and edit its
# triggers, which is exactly where a `pull_request:` gets added.
refuses_a_pull_request_apply() {
  local code; code=$(code_of "$1")
  matches "$code" "github\.event_name == 'pull_request'" || return 1
  matches "$code" "github\.event_name == 'pull_request_target'" || return 1
  matches "$code" 'exit 1' || return 1
}

# A moved tag on a third-party action is arbitrary code inside a job holding an
# infra-admin credential. The fleet-wide rule, at the one call site that applies.
pins_every_action_by_sha() {
  local code line
  code=$(code_of "$1")
  while IFS= read -r line; do
    matches "$line" 'uses: [^@]+@[0-9a-f]{40}' || return 1
  done < <(printf '%s\n' "$code" | grep -E '^[[:space:]]*(-[[:space:]]+)?uses:')
}

check() { # <predicate> <description>
  if "$1" "$WORKFLOW"; then ok; else bad "$2"; fi
}

echo "apply-runner-pool self-test:"
check runs_off_the_pool_it_applies      "the apply runs on the pool it is applying"
check is_callable_by_a_consumer         "a consumer cannot call it"
check authenticates_by_federation       "the job does not authenticate by federation"
check re_resolves_the_floating_pin      "init does not re-resolve a floating pin"
check tells_no_changes_from_a_broken_plan "a failed plan is indistinguishable from no changes"
check applies_only_what_it_printed      "the apply is not the plan that was printed"
check reads_terraforms_own_exit_code    "the setup wrapper masks terraform's exit code"
check serialises_applies_per_root       "two applies on one root are not serialised"
check says_applied_is_not_in_effect     "the run does not report that applied != in effect"
check refuses_a_pull_request_apply      "a pull-request-triggered apply is not refused"
check pins_every_action_by_sha          "an action is not pinned by sha"

mutate() { # <description> <sed-program> <predicate> — predicate must go false
  local desc="$1" prog="$2" pred="$3" tmp
  tmp=$(mktemp)
  sed "$prog" "$WORKFLOW" >"$tmp"
  if "$pred" "$tmp"; then bad "mutation not detected: $desc"; else ok; fi
  rm -f "$tmp"
}

mutate "moved onto the fleet it applies" \
  's|runs-on: ubuntu-latest|runs-on: [self-hosted, linux]|'        runs_off_the_pool_it_applies
mutate "no longer reusable" \
  's|^  workflow_call:|  workflow_dispatch:|'                      is_callable_by_a_consumer
mutate "id-token permission dropped" \
  's|id-token: write|id-token: none|'                              authenticates_by_federation
mutate "federation replaced by a static key" \
  's|workload_identity_provider: |credentials_json: |'             authenticates_by_federation
mutate "init no longer upgrades the module" \
  's|init -input=false -upgrade|init -input=false|'                re_resolves_the_floating_pin
mutate "plan no longer distinguishes changes" \
  's|-detailed-exitcode ||'                                        tells_no_changes_from_a_broken_plan
mutate "a failed plan swallowed as no changes" \
  's|exit "\$rc"|echo "changes=false" >> "$GITHUB_OUTPUT"|'        tells_no_changes_from_a_broken_plan
mutate "apply re-plans instead of using the saved plan" \
  's|terraform apply -input=false -lock-timeout=5m tf.plan|terraform apply -input=false -auto-approve|' applies_only_what_it_printed
mutate "plan no longer saved" \
  's|-out=tf.plan||'                                               applies_only_what_it_printed
mutate "wrapper re-enabled" \
  's|terraform_wrapper: false|terraform_wrapper: true|'            reads_terraforms_own_exit_code
mutate "concurrency keyed off the root, so roots collide" \
  's|group: apply-runner-pool-|group: apply-|'                     serialises_applies_per_root
mutate "in-flight apply becomes cancellable" \
  's|cancel-in-progress: false|cancel-in-progress: true|'          serialises_applies_per_root
mutate "the applied-is-not-in-effect warning dropped" \
  's|PREVIOUS startup script|latest startup script|'               says_applied_is_not_in_effect
mutate "pull_request_target left open" \
  "s|github.event_name == 'pull_request_target'||"                 refuses_a_pull_request_apply
mutate "the refusal downgraded to a warning" \
  's|^          exit 1$||'                                         refuses_a_pull_request_apply
mutate "an action pinned by tag" \
  's|uses: hashicorp/setup-terraform@[0-9a-f]*|uses: hashicorp/setup-terraform@v3|' pins_every_action_by_sha

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
