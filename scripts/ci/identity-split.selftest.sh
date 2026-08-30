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

# The helper carries the trap it was written to avoid, so it is tested next. A
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

# 9. The Windows host identity (ADR §3A). A Windows host cannot fence job code
#    off the metadata server — Windows Firewall resolves an explicit block ahead
#    of every conflicting allow, and the one documented override needs IPsec the
#    metadata server does not speak — so job code can mint a token for whatever
#    the host account is. The boundary is therefore the SIZE of that account:
#    tokenCreator on the job account, and nothing else. Each grant below dropping
#    out on `host_os = "windows"` is the whole control.
for res in \
  'resource "google_secret_manager_secret_iam_member" "runner_reads_key"' \
  'resource "google_project_iam_member" "metrics"' \
  'resource "google_project_iam_member" "logs"'; do
  if matches "$(block "^${res}" "$IDENTITY/main.tf")" '^  count = local\.host_grants'; then
    ok "host grant drops out on windows: ${res##* }"
  else
    bad "${res##* } is unconditional — a Windows host account keeps it, and any pull request running on that host can mint a token that holds it"
  fi
done

if matches "$(block '^locals \{' "$IDENTITY/main.tf")" 'host_grants = var\.host_os == "windows" \? 0 : 1'; then
  ok "host_grants is 0 on windows and 1 on linux"
else
  bad "host_grants no longer reduces the host account on windows"
fi

# 10. And Linux keeps every one of them. `host_os` defaults to linux, so a
#     consumer that says nothing gets today's identity exactly; a default of
#     "windows", or no default at all, would silently strip a working Linux
#     fleet of the grant its hosts mint registration tokens with.
if matches "$(block '^variable "host_os"' "$IDENTITY/variables.tf")" '^  default     = "linux"'; then
  ok "host_os defaults to linux, so an existing pool is unchanged"
else
  bad "host_os does not default to linux — existing pools would change identity on their next apply"
fi

# 11. Making those three conditional adds `[0]` to their addresses, and
#     Terraform treats `X` and `X[0]` as different objects. Without a `moved`
#     block the next apply of every EXISTING pool destroys and recreates live
#     IAM — a window in which hosts cannot read the App key and cannot register,
#     caused by a change that is supposed to leave Linux alone.
#
#     BOTH addresses are asserted, and as a PAIR inside one block. Checking only
#     the `to` line is the vacuous version of this test: a typo'd or stale `from`
#     names an address that is not in state, so the move is a no-op, the real
#     resource is still destroyed and recreated, and the check that was supposed
#     to prevent exactly that still says ok. awk pairs them per block so a `from`
#     borrowed from the neighbouring block cannot satisfy it either.
moved_pair() { # <address> -> yes|no
  awk -v a="$1" '
    /^moved \{/ { f=""; t=""; inb=1; next }
    inb && /^\}/ { if (f == a && t == a "[0]") { print "yes"; exit } inb=0; next }
    inb && $1 == "from" { f=$3 }
    inb && $1 == "to"   { t=$3 }
  ' "$IDENTITY/main.tf"
}
for addr in \
  'google_secret_manager_secret_iam_member.runner_reads_key' \
  'google_project_iam_member.metrics' \
  'google_project_iam_member.logs' \
  'google_secret_manager_secret.app_key'; do
  if matches "$(moved_pair "$addr")" '^yes$'; then
    ok "state move declared for $addr"
  else
    bad "no moved block pairing $addr with ${addr}[0] — an existing pool will DESTROY and recreate this binding"
  fi
done

# 12. The reduction only means anything while the controller is a separate
#     account. Collapsed onto the host account, the App-key read and
#     instance-admin are back on the machine that runs pull-request code, and
#     every check above still passes.
if matches "$(block 'resource "google_service_account" "runner"' "$IDENTITY/main.tf")" 'var\.host_os != "windows" \|\| var\.create_controller_service_account'; then
  ok "a windows pool is refused without the controller split"
else
  bad "nothing stops host_os = windows with create_controller_service_account = false, which hands the App key straight back to job code"
fi

# 13. A Windows host account cannot read the App key, so it cannot mint its own
#     registration token — the controller has to. The pool input that turns that
#     on must exist and must default OFF, or every Linux controller starts
#     writing credentials into instance metadata it has no reason to.
if matches "$(block '^variable "controller_mints_registration_token"' "$POOL/variables.tf")" '^  default     = false'; then
  ok "controller-minted registration is opt-in"
else
  bad "controller_mints_registration_token is missing or does not default to false"
fi

# 14. And the key it enables must be ABSENT from a pool that did not opt in. A
#     `"false"` value would be a metadata diff on every existing controller,
#     which is exactly the Linux churn this delivery promised not to cause. Both
#     halves are asserted: a local that renders an EMPTY map when the pool says
#     nothing, and that same local actually merged into the controller's
#     metadata. Checking only the local would pass on a local nothing reads.
if matches "$(grep -A2 'controller_registration_metadata = ' "$POOL/main.tf")" 'controller_mints_registration_token \? \{' &&
  matches "$(grep -A2 'controller_registration_metadata = ' "$POOL/main.tf")" '\} : \{\}'; then
  ok "the registration metadata local is empty unless the pool opts in"
else
  bad "the registration metadata key is rendered unconditionally — every existing controller gets a metadata diff"
fi

if matches "$(grep -c 'merge(local.controller_registration_metadata, {' "$POOL/main.tf")" '^1$'; then
  ok "and it is merged into the controller's metadata"
else
  bad "local.controller_registration_metadata is not merged into the controller metadata — the key is defined and never rendered"
fi

# 16. A second identity in a project — which is what a Windows pool alongside a
#     Linux one is — may point at the App key that already exists instead of
#     creating a second, empty one. The default has to stay TRUE: false on a
#     first pool means the grants land on a secret nobody created, which is a
#     404 at apply time on a plan that read clean.
if matches "$(block '^variable "create_app_key_secret"' "$IDENTITY/variables.tf")" '^  default     = true'; then
  ok "create_app_key_secret is opt-out, so a first pool still creates its key"
else
  bad "create_app_key_secret is missing or does not default to true — an existing pool would stop managing the secret its hosts read"
fi

# 17. And both grants and the output must read the LOCAL, not the resource.
#     Reading `google_secret_manager_secret.app_key[0].…` anywhere else is an
#     index into a zero-length list the moment a consumer opts out: the module
#     stops planning at all, for every caller, with an error about the resource
#     rather than about the flag. Asserting the local is defined is not enough —
#     the failure is in what still reads around it.
if matches "$(block '^locals \{' "$IDENTITY/main.tf")" 'app_key_secret_id = var\.create_app_key_secret \? google_secret_manager_secret\.app_key\[0\]' &&
  matches "$(awk '/^moved \{/ { inb=1 } !inb { print } inb && /^\}/ { inb=0 }' "$IDENTITY/main.tf" |
    grep -c 'google_secret_manager_secret\.app_key\[0\]')" '^1$' &&
  ! matches "$(cat "$IDENTITY/outputs.tf")" 'google_secret_manager_secret\.app_key'; then
  ok "the secret id is read through one local, so opting out plans cleanly"
else
  bad "something still reads google_secret_manager_secret.app_key directly — with create_app_key_secret = false that is an index into an empty list, and the module stops planning"
fi

if [ "$fail" -eq 0 ]; then
  echo "  identity split intact."
else
  echo "  identity split BROKEN."
fi
exit "$fail"
