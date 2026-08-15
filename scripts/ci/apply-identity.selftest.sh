#!/usr/bin/env bash
# Guards the ONE property that makes an unattended apply acceptable: the
# identity it runs as cannot change IAM.
#
# `apply-runner-pool.yml` is assumable by a GitHub Actions run, so everything
# this account can do, a workflow file can do. The runner root creates service
# accounts and project IAM bindings, so the "obvious" fix for any permission
# error the apply hits is to widen the account until the apply stops failing —
# and the end of that road is roles/resourcemanager.projectIamAdmin, which is
# "can grant itself owner", reachable from CI, in a fleet whose pull requests
# auto-merge on green.
#
# That widening is a ONE-LINE change that makes a red check go green, which is
# the most persuasive kind of wrong. Nothing else in this repository would
# notice: terraform validate accepts it, the plan succeeds, the apply succeeds,
# and the fleet is quietly one merged pull request away from project owner.
#
# So the checks are STATIC, on the module text, and stated as prohibitions.
# `terraform validate` does not evaluate variable validation on module inputs,
# so plan-time guards are not reachable from this repo's CI at all — text is
# what there is.
#
# Each mutation below breaks one property the way a real edit plausibly would —
# every one of them phrased as "make the apply work" — and asserts this test
# notices. A gate that only passes on correct input is not evidence.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOD="$ROOT/modules/ci-runner-apply-identity"
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

# Code only: full-line comments stripped, so the long rationale in the module —
# which NAMES the forbidden roles in order to explain why they are forbidden —
# can never be mistaken for a grant of them. Without this, check 1 reads the
# word "projectIamAdmin" in a comment explaining that it must never appear, and
# fails on the very text that documents the rule.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `... | grep -q` under `set -o pipefail`: grep exits on first match, the
# writer takes SIGPIPE, and a successful match is reported as a failure. Worse
# here than usual — for a prohibition the MATCH is the failure, so the artefact
# would turn a real escalation into a silent pass.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# grep is LINE-based, so a role and the resource type that grants it are never on
# the same line and no single pattern can relate them. Written as one regex with
# a `\n` in it, such a check matches nothing, passes always, and tests nothing —
# which is worse than absent, because the report says the property is covered.
# So: extract the blocks, then match inside them. The range restarts, so every
# block of the type is included, not just the first.
# Comments stripped here too: a block's own comment explaining which role it
# must NOT carry would otherwise read as carrying it.
blocks() { awk "/^resource \"$1\"/,/^}/" "$2" | grep -vE '^[[:space:]]*#'; }  # <resource-type> <file>

# 1. THE prohibition. Not a list of bad role names — a list of every role that
#    can write an IAM policy or mint an identity, which is the capability being
#    denied. Named individually so a failure says which one arrived.
grants_no_iam_authority() {
  local code; code=$(code_of "$1")
  ! matches "$code" 'roles/resourcemanager\.projectIamAdmin' || return 1
  ! matches "$code" 'roles/iam\.serviceAccountAdmin'         || return 1
  ! matches "$code" 'roles/iam\.securityAdmin'               || return 1
  ! matches "$code" 'roles/iam\.serviceAccountKeyAdmin'      || return 1
  ! matches "$code" 'roles/owner'                            || return 1
  ! matches "$code" 'roles/editor'                           || return 1
}

# 2. The escalation that does not look like one. compute.admin plus actAs on the
#    PROJECT means this identity can attach any service account in the project
#    to an instance it creates and then run code as it — including accounts far
#    more privileged than itself. Scoping actAs to an enumerated list is what
#    keeps compute.admin bounded, so the two are one property, not two.
scopes_act_as_to_named_accounts() {
  local code; code=$(code_of "$1")
  matches "$code" 'google_service_account_iam_member" "act_as"'      || return 1
  matches "$code" 'for_each *= *toset\(var\.impersonable_service_accounts\)' || return 1
  # And the same role must not arrive project-wide by another route — which is
  # the one-line "actAs keeps failing" fix, and undoes the scoping above without
  # touching it.
  ! matches "$(blocks 'google_project_iam_member' "$1")" 'roles/iam\.serviceAccountUser' || return 1
}

# 3. Read access is deliberately read-only. secretmanager.viewer is metadata;
#    secretAccessor reads the GitHub App private key, and an apply has no reason
#    to — the pool is built AROUND that secret, never from it.
reads_secrets_without_reading_values() {
  local code; code=$(code_of "$1")
  matches "$code" 'roles/secretmanager\.viewer'          || return 1
  ! matches "$code" 'roles/secretmanager\.secretAccessor' || return 1
  ! matches "$code" 'roles/secretmanager\.admin'          || return 1
}

# 4. State lives in a bucket that usually sits beside build-artifact and cache
#    buckets. A project-wide storage grant to store one .tfstate hands CI write
#    access to all of them.
scopes_state_to_one_bucket() {
  local code; code=$(code_of "$1")
  matches "$code" 'google_storage_bucket_iam_member" "state"' || return 1
  matches "$code" 'bucket *= *var\.state_bucket'              || return 1
  ! matches "$code" 'google_project_iam_member.*storage'      || return 1
}

# 5. The security boundary itself. A principalSet on attribute.repository binds
#    the whole repository — every branch, including one pushed by anyone who can
#    push, running a workflow file they wrote. Branch protection is no defence:
#    that workflow never goes near main.
binds_to_one_ref_not_the_repository() {
  local code; code=$(code_of "$1")
  matches "$code" 'attribute\.ref/\$\{var\.allowed_ref\}' || return 1
  ! matches "$code" 'attribute\.repository/'              || return 1
  ! matches "$code" 'principalSet://[^"]*\*'              || return 1
}

# 6. `allowed_ref = "main"` is the plausible typo and the dangerous one: it
#    yields a valid principalSet matching NO ref, so the binding authorises
#    nobody and surfaces later as an opaque permission error at assume time —
#    which reads as a broken deploy and gets "fixed" by widening the binding.
refuses_a_ref_that_is_not_a_ref() {
  local code; code=$(code_of "$1")
  matches "$code" 'startswith\(var\.allowed_ref, "refs/"\)' || return 1
  # IAM matches the attribute literally; a wildcard authorises a branch named "*".
  matches "$code" 'regex\("\[\*\?\]", var\.allowed_ref\)'   || return 1
}

echo "apply-identity self-test:"

# The helpers carry the traps they were written to avoid, so they are checked
# before anything relies on them. A match on the FIRST line of a large input is
# the pipefail/SIGPIPE worst case; and `blocks` must find a LATER block, not
# only the first, or "no project-wide grant" silently stops looking after one.
if matches "$(seq 1 20000)" '^1$' && ! matches "$(seq 1 20000)" '^abc$'; then
  ok
else
  bad "matches() is unreliable on a large input — every check below is untrustworthy"
fi
if matches "$(blocks 'google_project_iam_member' "$MAIN")" 'roles/secretmanager\.viewer'; then
  ok
else
  bad "blocks() does not reach past the first matching block — the prohibitions below would only inspect one"
fi

check() { if "$1" "$2"; then ok; else bad "$3"; fi; }

check grants_no_iam_authority              "$MAIN" "the apply identity can write IAM policy or mint identities"
check scopes_act_as_to_named_accounts      "$MAIN" "actAs is not scoped to named accounts — compute.admin becomes act-as-anything"
check reads_secrets_without_reading_values "$MAIN" "the apply identity can read secret VALUES"
check scopes_state_to_one_bucket           "$MAIN" "storage is granted wider than the state bucket"
check binds_to_one_ref_not_the_repository  "$MAIN" "any branch in the repository can assume the apply identity"
check refuses_a_ref_that_is_not_a_ref      "$VARS" "a ref that matches nothing is accepted"

mutate() { # <description> <file> <sed-program> <predicate> — predicate must go false
  local desc="$1" f="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
  sed "$prog" "$f" >"$tmp"
  if "$pred" "$tmp"; then bad "mutation not detected: $desc"; else ok; fi
  rm -f "$tmp"
}

# Every mutation below is phrased the way the real edit would be: something
# failed, and this makes it pass.
mutate "'the apply cannot create the service accounts' — projectIamAdmin added" "$MAIN" \
  's|roles/compute.admin|roles/resourcemanager.projectIamAdmin|'    grants_no_iam_authority
mutate "'just let it manage its own accounts' — serviceAccountAdmin added" "$MAIN" \
  's|roles/compute.admin|roles/iam.serviceAccountAdmin|'            grants_no_iam_authority
mutate "'simplest thing that works' — editor" "$MAIN" \
  's|roles/compute.admin|roles/editor|'                             grants_no_iam_authority
mutate "'actAs kept failing' — scoping replaced by a project-wide grant" "$MAIN" \
  's|for_each = toset(var.impersonable_service_accounts)|for_each = toset(["*"])|' scopes_act_as_to_named_accounts
mutate "'actAs kept failing' — same role granted project-wide alongside the scoped one" "$MAIN" \
  's|roles/iam.serviceAccountViewer|roles/iam.serviceAccountUser|'  scopes_act_as_to_named_accounts
mutate "'the apply needs the App key' — accessor added" "$MAIN" \
  's|roles/secretmanager.viewer|roles/secretmanager.secretAccessor|' reads_secrets_without_reading_values
mutate "'state moved, easier to grant the project' — bucket scope dropped" "$MAIN" \
  's|bucket = var.state_bucket|bucket = "some-bucket"|'             scopes_state_to_one_bucket
mutate "'it fails from the release branch too' — bound to the repository" "$MAIN" \
  's|attribute.ref/\${var.allowed_ref}|attribute.repository/${var.repository}|' binds_to_one_ref_not_the_repository
mutate "'let any branch apply' — wildcard principalSet" "$MAIN" \
  's|attribute.ref/\${var.allowed_ref}|attribute.ref/*|'            binds_to_one_ref_not_the_repository
mutate "'refs/ prefix is fiddly' — bare branch names allowed" "$VARS" \
  's|startswith(var.allowed_ref, "refs/")|true|'                    refuses_a_ref_that_is_not_a_ref
mutate "'we want a wildcard ref' — wildcard guard dropped" "$VARS" \
  's|regex("\[\*?\]", var.allowed_ref)|false|'                      refuses_a_ref_that_is_not_a_ref

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
