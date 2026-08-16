#!/usr/bin/env bash
# Guards the properties that make `ci-runner-apply-trigger` acceptable as an
# UNATTENDED apply — none of which terraform can check for us.
#
# The module runs `terraform apply` on a schedule, with nobody reading the
# output, using an account that can rebuild the compute the fleet's own CI runs
# on. Two things keep that safe, and both are one edit away from gone:
#
#   1. IT MINTS NOTHING. The account is an input. A module that creates the
#      identity its own builds run as decides its own privileges, and the
#      decision lands in whatever apply happens to run it — reviewed once, by
#      whoever was looking at a terraform diff that day.
#
#   2. IT APPLIES THE PLAN IT PRINTED. `apply -auto-approve` re-plans, and
#      between the plan in the log and the apply a floating module tag can move.
#      Applying something nobody printed is the failure this arrangement exists
#      to remove, and `-auto-approve` is the first thing anybody reaches for
#      when a saved plan goes stale ("Saved plan is stale").
#
# Both edits make a red build go green, which is the most persuasive kind of
# wrong, and nothing else in this repository would notice: terraform validate
# accepts them, the plan succeeds, the apply succeeds.
#
# One property is deliberately NOT enforced here, and is worth stating so its
# absence is not read as an oversight: this module does not run
# `tf-apply-guard.sh`. That guard refuses an apply whose checkout is not the
# remote default branch and demands a plan-derived token before a destroy — a
# human-at-a-laptop defence, and the right one for that case. Inside a build
# triggered by a push to main, the checkout IS the merged commit, and a destroy
# token cannot be typed by anybody. What bounds destruction here instead is the
# ACCOUNT: the protected kinds the guard names — service accounts and secrets —
# are exactly what a compute-scoped CD account cannot delete. That is why
# check 1 below is not merely tidiness about where identities are created.
#
# Each mutation breaks one property the way a real edit plausibly would — every
# one phrased as "make the apply work" — and asserts this test notices. A gate
# that only passes on correct input is not evidence.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOD="$ROOT/modules/ci-runner-apply-trigger"
MAIN="$MOD/main.tf"
VARS="$MOD/variables.tf"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# A grep against a missing file is false, which would land some checks in the
# `ok` branch and quietly disable this gate. Assert the inputs first.
for f in "$MAIN" "$VARS"; do
  [ -r "$f" ] || { printf 'FAIL: input MISSING: %s — every check below would be vacuous\n' "$f"; exit 1; }
done

# Code only: full-line comments stripped, so the module's own rationale — which
# NAMES the things it must not do in order to explain why — can never be read as
# doing them. Without this, "creates no service account" fails on the paragraph
# that documents the rule.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `... | grep -q` under `set -o pipefail`: grep exits on first match, the
# writer takes SIGPIPE, and a successful match is reported as a failure. Worse
# than usual here — for a prohibition the MATCH is the failure, so the artefact
# would turn a real regression into a silent pass.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# variable "<name>" { ... } as one block, so a `default` can be attributed to the
# variable it belongs to. The range restarts, so every block is included.
var_block() { # <variable-name> <file>
  awk "/^variable \"$1\"/,/^}/" "$2" | grep -vE '^[[:space:]]*#'
}

# 1. THE prohibition. Not "no google_service_account" specifically — no
#    authority-granting resource at all. A module that can grant is a module
#    whose blast radius is decided by its own diff.
mints_and_grants_nothing() {
  local code; code=$(code_of "$1")
  ! matches "$code" 'resource "google_service_account"'            || return 1
  ! matches "$code" 'resource "google_project_iam_'                || return 1
  ! matches "$code" 'resource "google_service_account_iam_'        || return 1
  ! matches "$code" 'resource "google_storage_bucket_iam_'         || return 1
  ! matches "$code" 'resource "google_organization_iam_'           || return 1
  ! matches "$code" 'resource "google_folder_iam_'                 || return 1
}

# 2. And the account cannot arrive by default either. A default here is the
#    same failure wearing a different hat: the reviewer of a consumer root sees
#    no account named, so there is nothing to review.
takes_the_account_as_a_required_input() {
  local block; block=$(var_block 'service_account' "$1")
  matches "$block" 'type *= *string' || return 1
  ! matches "$block" '^[[:space:]]*default' || return 1
}

# 3. The saved plan. `-auto-approve` re-plans at apply time, and the log's plan
#    then describes a different apply than the one that ran.
applies_the_plan_it_printed() {
  local code; code=$(code_of "$1")
  matches "$code" 'terraform apply .*tf\.plan'   || return 1
  matches "$code" 'terraform plan .*-out=tf\.plan' || return 1
  ! matches "$code" 'auto-approve'               || return 1
}

# 4. One literal branch in, both spellings derived. Given as two inputs there is
#    a state where each field is individually valid and the schedule fires on a
#    branch the trigger does not watch — the run API matches literally and
#    rejects a regex, so `^main$` there is a not-found on a branch nobody typed.
derives_both_branch_spellings_from_one_input() {
  local code; code=$(code_of "$1")
  matches "$code" 'branch_regex *= *"\^\$\{var\.branch\}\$"' || return 1
  matches "$code" 'branchName *= *var\.branch'               || return 1
  ! matches "$code" 'branchName *= *local\.branch_regex'     || return 1
}

# 5. A build that names its own service account has no default log destination
#    and Cloud Build refuses it at SUBMIT time. Legible, but it arrives on the
#    first push — the worst moment to learn it, and the moment somebody decides
#    the trigger itself is broken.
declares_where_logs_go() {
  local code; code=$(code_of "$1")
  matches "$code" 'logging *= *"CLOUD_LOGGING_ONLY"' || return 1
}

# 6. An exact image tag. A floating one means an unattended apply can start
#    failing on a morning when nothing was merged, which is the single hardest
#    class of CI failure to attribute.
pins_the_terraform_image() {
  local code; code=$(code_of "$1")
  matches "$code" 'hashicorp/terraform:\$\{var\.terraform_version\}' || return 1
  ! matches "$code" 'hashicorp/terraform:latest'                     || return 1
  matches "$(var_block 'terraform_version' "$VARS")" 'regex\("\^\[0-9\]' || return 1
}

# 7. Scoped to the root's own tree. Unscoped, every commit in the repository
#    queues an apply behind a terraform state lock to discover that nothing
#    changed — and the queue is what makes the ONE apply that mattered late.
fires_only_for_the_root_it_applies() {
  local code; code=$(code_of "$1")
  matches "$code" 'included_files *= *concat\(\["\$\{trim\(var\.terraform_root' || return 1
  matches "$code" 'included_files *= *local\.included_files'                    || return 1
}

# 8. Every step names its own image, and no image here has both tools: the
#    terraform image has no gcloud, the cloud-sdk image has no terraform. The
#    report step needs a terraform OUTPUT and a gcloud CALL, and the honest way
#    across is the workspace. Written the obvious way it is `terraform: not
#    found` in a step whose whole job is to print one sentence — a failure that
#    looks like the report is broken, and gets fixed by deleting the report.
runs_each_tool_in_an_image_that_has_it() {
  local sdk_step
  sdk_step=$(awk '/name .*cloudsdktool/,/^    }/' "$1")
  # The step must exist, or this check is vacuous — and a vacuous check here
  # reads as "the tools are correctly separated".
  matches "$sdk_step" 'gcloud compute instance-groups' || return 1
  ! matches "$sdk_step" 'terraform '                   || return 1
}

echo "apply-trigger self-test:"

# The helpers carry the traps they were written to avoid, so they are checked
# before anything relies on them. A match on the FIRST line of a large input is
# the pipefail/SIGPIPE worst case; and `var_block` must isolate ONE variable, or
# check 2 reads a `default` belonging to a different variable and passes on a
# module that has one.
if matches "$(seq 1 20000)" '^1$' && ! matches "$(seq 1 20000)" '^abc$'; then
  ok
else
  bad "matches() is unreliable on a large input — every check below is untrustworthy"
fi
if matches "$(var_block 'branch' "$VARS")" 'default *= *"main"' \
   && ! matches "$(var_block 'service_account' "$VARS")" 'default *= *"main"'; then
  ok
else
  bad "var_block() does not isolate one variable — the required-input check would read another variable's default"
fi

check() { if "$1" "$2"; then ok; else bad "$3"; fi; }

check mints_and_grants_nothing                    "$MAIN" "the trigger module creates an identity or grants a role — its blast radius is now decided by its own diff"
check takes_the_account_as_a_required_input       "$VARS" "service_account has a default — a consumer root can name no account, and there is nothing to review"
check applies_the_plan_it_printed                 "$MAIN" "the apply re-plans instead of applying the saved plan"
check derives_both_branch_spellings_from_one_input "$MAIN" "the scheduled run and the push filter can disagree about which branch applies"
check declares_where_logs_go                      "$MAIN" "no logging option — the build is refused at submit time, on the first push"
check pins_the_terraform_image                    "$MAIN" "the terraform image floats — an unattended apply can break with nothing merged"
check fires_only_for_the_root_it_applies          "$MAIN" "the trigger fires on every commit in the repository"
check runs_each_tool_in_an_image_that_has_it      "$MAIN" "a step calls a tool its image does not carry — the report fails with 'not found' and looks broken"

mutate() { # <description> <file> <sed-program> <predicate> — predicate must go false
  local desc="$1" f="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
  sed "$prog" "$f" >"$tmp"
  if "$pred" "$tmp"; then bad "mutation not detected: $desc"; else ok; fi
  rm -f "$tmp"
}

# Every mutation is phrased the way the real edit would be: something failed,
# and this makes it pass.
mutate "'the CD account is missing in the new project' — the module creates one" "$MAIN" \
  's|resource "google_cloudbuild_trigger"|resource "google_service_account"|' mints_and_grants_nothing
mutate "'the apply cannot write state' — one small grant added here" "$MAIN" \
  's|resource "google_cloud_scheduler_job"|resource "google_storage_bucket_iam_member"|' mints_and_grants_nothing
mutate "'every project uses the same CD account' — made a default" "$VARS" \
  's|^variable "service_account" {|variable "service_account" {\n  default = "cd@example.iam.gserviceaccount.com"|' takes_the_account_as_a_required_input
# SC2016 off for the three below: the `${...}` is HCL interpolation being matched
# LITERALLY in the module source. Expanding it in the shell is the bug the
# warning describes in reverse — `${var.terraform_version}` would become empty,
# the sed would match nothing, and the mutation would be silently vacuous:
# a mutation that changes nothing always "goes false" and reports a pass.
# shellcheck disable=SC2016
mutate "'Saved plan is stale' — apply re-plans instead" "$MAIN" \
  's|terraform apply -input=false -lock-timeout=${var.lock_timeout} tf.plan|terraform apply -input=false -auto-approve|' applies_the_plan_it_printed
mutate "'the scheduled run cannot find the branch' — the push regex reused for the run" "$MAIN" \
  's|source    = { branchName = var.branch }|source    = { branchName = local.branch_regex }|' derives_both_branch_spellings_from_one_input
mutate "'logs are in Cloud Logging anyway' — the option dropped" "$MAIN" \
  's|logging = "CLOUD_LOGGING_ONLY"|logging = "NONE"|' declares_where_logs_go
# shellcheck disable=SC2016
mutate "'pin a version nobody has to bump' — floating image" "$MAIN" \
  's|hashicorp/terraform:${var.terraform_version}|hashicorp/terraform:latest|' pins_the_terraform_image
# shellcheck disable=SC2016
mutate "'one step instead of two' — terraform output moved into the gcloud image" "$MAIN" \
  's|mig=$(cat /workspace/.mig-name 2>/dev/null \|\| true)|mig=$(terraform output -raw mig_name)|' runs_each_tool_in_an_image_that_has_it
mutate "'the tfvars live outside the root and the apply never fires' — scope removed" "$MAIN" \
  's|included_files = local.included_files|included_files = []|' fires_only_for_the_root_it_applies

printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
