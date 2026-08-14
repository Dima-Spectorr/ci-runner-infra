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

echo "identity-split self-test:"

# 0. Every check below is `if grep …; then ok; else bad`, and a grep against a
#    MISSING file is also false — which lands in whichever branch the check
#    happens to use. A renamed or moved file would therefore turn some checks
#    green rather than red, i.e. quietly disable the guard this script exists to
#    be. So assert the inputs exist before asserting anything about them.
for f in "$POOL/variables.tf" "$POOL/main.tf" "$IDENTITY/main.tf" "$IDENTITY/outputs.tf"; do
  if [ -r "$f" ]; then
    ok "input readable: ${f#"$ROOT/"}"
  else
    bad "input MISSING: ${f#"$ROOT/"} — the checks below would be vacuous"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "  identity split UNVERIFIABLE."; exit 1; }

# 1. The permissive default must not come back. A default here is not a style
#    question: it silently picks the insecure side for anyone who says nothing.
if awk '/^variable "controller_service_account_email"/,/^}/' "$POOL/variables.tf" \
     | grep -qE '^  default'; then
  bad "controller_service_account_email has a default (it must be required)"
else
  ok "controller_service_account_email is required"
fi

# 2. And the plan-time guard must still be there to reject a shared account.
if awk '/^variable "controller_service_account_email"/,/^}/' "$POOL/variables.tf" \
     | grep -q 'var.controller_service_account_email != var.service_account_email'; then
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
if awk '/resource "google_project_iam_member" "compute"/,/^}/' "$IDENTITY/main.tf" \
     | grep -q 'local.controller_email'; then
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
if awk '/resource "google_service_account" "controller"/,/^}/' "$IDENTITY/main.tf" \
     | grep -q 'substr(var.account_id, 0, min(26'; then
  ok "controller account id is truncated to fit the 30-char cap"
else
  bad "controller account id is not truncated — a long pool name will not plan"
fi

# 7. The job identity must differ from the controller's too. Each variable's own
#    validation only compares against the HOST account, so controller == job
#    passes both; the pairing is rejected by a precondition in main.tf instead.
if grep -q 'var.job_service_account_email != var.controller_service_account_email' "$POOL/main.tf"; then
  ok "precondition rejects job == controller account"
else
  bad "nothing rejects job_service_account_email == controller_service_account_email"
fi

# 8. The drain verifies live workers over IAP before deleting a host. Without
#    the tunnel role that SSH fails, the failure is suppressed, and the host is
#    deleted having verified nothing — a silent downgrade, not an outage.
if grep -q 'roles/iap.tunnelResourceAccessor' "$IDENTITY/main.tf"; then
  ok "controller holds the IAP tunnel role the drain probe needs"
else
  bad "controller has no roles/iap.tunnelResourceAccessor — the drain's worker check cannot run"
fi

if [ "$fail" -eq 0 ]; then
  echo "  identity split intact."
else
  echo "  identity split BROKEN."
fi
exit "$fail"
