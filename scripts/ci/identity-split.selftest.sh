#!/usr/bin/env bash
# Guards the host/controller identity split against being quietly undone.
#
# Scale-in is the controller deleting hosts, which needs
# roles/compute.instanceAdmin.v1. Across the whole fleet that grant sat on the
# account attached to every host VM, because `controller_service_account_email`
# defaulted to "reuse the host account" and every consumer took the default. A
# job escaping the container fence could have deleted the pool it ran on.
#
# The real enforcement is the variable's `validation` block, but that is only
# evaluated at PLAN time — `terraform validate` does not run validation on
# module inputs, so this repo's CI cannot catch a regression that way. Hence a
# static check on the module text itself: the properties below are what make
# the plan-time guard reachable at all, and each has already been wrong once.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POOL="$ROOT/modules/ci-runner-host-pool"
IDENTITY="$ROOT/modules/ci-runner-identity"

fail=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }

# Never `awk … | grep -q` under `set -o pipefail`. `grep -q` exits the moment it
# matches, awk upstream takes SIGPIPE and exits 141, and pipefail then makes the
# PIPELINE fail — so a match is reported as no-match, on a race with how much
# awk had already buffered. Check 1 below is the dangerous shape: its match is
# the FAILURE, so the artefact turns a real regression into a silent "ok".
# `grep -c` reads to end of input, so nothing upstream is ever signalled.
block()   { awk "/$1/,/^}/" "$2"; }          # <awk-start-re> <file>
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

echo "identity-split self-test:"

# The helper carries the trap it was written to avoid, so it is tested first. A
# match on the FIRST line of a large input is the worst case: with `grep -q` the
# writer is still pushing bytes when grep exits on the match, takes SIGPIPE, and
# pipefail reports the successful match as a failure.
if matches "$(seq 1 20000)" '^1$' && ! matches "$(seq 1 20000)" '^abc$'; then
  ok "matches() is reliable on a large input"
else
  bad "matches() is unreliable on a large input — the pipefail/SIGPIPE trap is back, and every check below is now untrustworthy"
fi

# 1. The permissive default must not come back. A default here is not a style
#    question: it silently picks the insecure side for anyone who says nothing.
if matches "$(block '^variable "controller_service_account_email"' "$POOL/variables.tf")" '^  default'; then
  bad "controller_service_account_email has a default (it must be required)"
else
  ok "controller_service_account_email is required"
fi

# 2. And the plan-time guard must still be there to reject a shared account.
if matches "$(block '^variable "controller_service_account_email"' "$POOL/variables.tf")" 'var\.controller_service_account_email != var\.service_account_email'; then
  ok "validation rejects controller == host account"
else
  bad "validation no longer compares controller against service_account_email"
fi

# 3. The old fallback expression is what made the default reachable. If it
#    returns, the variable being required stops meaning anything.
if grep -q 'controller_service_account_email != "" ?' "$POOL/main.tf"; then
  bad "main.tf still falls back to service_account_email for the controller"
else
  ok "no host-account fallback for the controller"
fi

# 4. instance-admin belongs to the controller. Bound to the host account it is
#    the original finding, exactly.
if matches "$(block 'resource "google_project_iam_member" "compute"' "$IDENTITY/main.tf")" 'local\.controller_email'; then
  ok "instanceAdmin binds the controller account"
else
  bad "instanceAdmin is not bound to local.controller_email"
fi

# 5. The controller account has to exist for any of the above to be reachable,
#    and consumers need its email to pass through.
if grep -q 'resource "google_service_account" "controller"' "$IDENTITY/main.tf"; then
  ok "controller service account is declared"
else
  bad "controller service account is missing"
fi

if grep -q 'output "controller_service_account_email"' "$IDENTITY/outputs.tf"; then
  ok "controller email is exported"
else
  bad "controller_service_account_email output is missing"
fi

# 6. A 30-character account id is a hard GCP cap, and a pool name is already
#    close to it (ci-runner-host-dataretrival is 26). Without truncation the
#    suffix pushes it over and the whole pool fails at plan time.
if matches "$(block 'resource "google_service_account" "controller"' "$IDENTITY/main.tf")" 'substr\(var\.account_id, 0, min\(26'; then
  ok "controller account id is truncated to fit the 30-char cap"
else
  bad "controller account id is not truncated — a long pool name will not plan"
fi

if [ "$fail" -eq 0 ]; then
  echo "  identity split intact."
else
  echo "  identity split BROKEN."
fi
exit "$fail"
