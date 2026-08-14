#!/usr/bin/env bash
# tf-apply-guard.sh — the gate every runner-root `terraform apply` goes through.
#
# WHY THIS EXISTS (2026-08-14, Print-Server):
#   A loop ran `git checkout main && git pull` across two repos. The pull failed
#   for one of them ("There is no tracking information for the current branch"),
#   the loop did not stop, and the next line -- `terraform apply -auto-approve` --
#   ran against a STALE local main from before the warm-host migration. Terraform
#   did exactly what it was told: it reconciled live state against a months-old
#   configuration and destroyed 35 resources, including the Secret Manager secret
#   holding the GitHub App private key.
#
#   `lifecycle { prevent_destroy = true }` was already on that secret and did not
#   help. prevent_destroy is enforced from the CONFIGURATION, so when the whole
#   module is absent from the checked-out tree the protection is absent with it.
#   A config-level guard cannot defend against the wrong config. The defence has
#   to sit above Terraform, which is what this script is.
#
# Two refusals, both cheap, both before anything is touched:
#   1. CHECKOUT  -- HEAD must equal the remote default branch and the tree must be
#                   clean. An apply is a statement about what is on the default
#                   branch; if the tree is not that, the statement is false.
#   2. PLAN      -- a plan that destroys a protected identity (service account,
#                   App-key secret) is refused outright. Any other destroy needs
#                   the operator to name the exact count, so "yes" cannot be typed
#                   past a number nobody read.
#
# Usage:  scripts/ci/tf-apply-guard.sh <runner-root-dir> [terraform-args...]
# Override (deliberate destroys): TF_GUARD_CONFIRM_DESTROY=<exact-count>
# Override (checkout, e.g. testing a branch): TF_GUARD_ALLOW_UNMERGED=1

set -euo pipefail

# ── protected kinds ───────────────────────────────────────────────────────────
# Destroying these is never recoverable by re-applying:
#   - a secret takes its versions with it, and the App-key PEM exists nowhere else
#   - a service account id is unusable for 30 days after deletion, and every IAM
#     binding that referenced it silently detaches
PROTECTED_TYPES='google_secret_manager_secret|google_service_account'

# ── pure decision functions (exercised by tf-apply-guard.selftest.sh) ─────────

# checkout_verdict <head_sha> <remote_sha> <porcelain_status> <allow_unmerged>
# -> ok | stale | dirty
checkout_verdict() {
  local head="$1" remote="$2" status="$3" allow="${4:-0}"
  [ -n "$status" ] && { echo dirty; return; }
  if [ "$head" != "$remote" ] && [ "$allow" != "1" ]; then echo stale; return; fi
  echo ok
}

# plan_verdict <destroy_count> <protected_destroy_count> <confirm_token>
# -> ok | refuse-protected | refuse-destroy
plan_verdict() {
  local destroys="$1" protected="$2" confirm="${3:-}"
  # Protected destroys are refused unconditionally. There is no env var for this
  # branch on purpose: the only correct way to remove an identity is to delete its
  # module block on the default branch, in a reviewed PR, where the diff is visible.
  [ "$protected" -gt 0 ] && { echo refuse-protected; return; }
  if [ "$destroys" -gt 0 ] && [ "$confirm" != "$destroys" ]; then
    echo refuse-destroy; return
  fi
  echo ok
}

# Sourced by the self-test; everything below is the live path only.
[ "${TF_APPLY_GUARD_LIB:-0}" = "1" ] && return 0

# ── live path ─────────────────────────────────────────────────────────────────
die() { printf 'tf-apply-guard: REFUSED — %s\n' "$*" >&2; exit 2; }

dir="${1:?usage: tf-apply-guard.sh <runner-root-dir> [terraform-args...]}"; shift || true
[ -d "$dir" ] || die "no such directory: $dir"

command -v jq >/dev/null 2>&1 || die "jq is required to read the plan; refusing to apply blind"

# 1. checkout ------------------------------------------------------------------
git -C "$dir" fetch --quiet origin
# Resolve the remote default branch rather than assuming `main`: two of these
# repos are still on `master`, and guessing wrong would compare against a ref
# that does not exist and pass on an empty string.
default_ref="$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
if [ -z "$default_ref" ]; then
  git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
  default_ref="$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
fi
[ -n "$default_ref" ] || die "cannot resolve origin/HEAD in $dir — refusing to apply from an unknown branch"

head_sha="$(git -C "$dir" rev-parse HEAD)"
remote_sha="$(git -C "$dir" rev-parse "$default_ref")"
# Ignore Terraform's own working files: .terraform/ and the plan file this script
# writes are not repository content and are always "dirty" during an apply.
status="$(git -C "$dir" status --porcelain -- . | grep -v '\.terraform' || true)"

case "$(checkout_verdict "$head_sha" "$remote_sha" "$status" "${TF_GUARD_ALLOW_UNMERGED:-0}")" in
  dirty) die "working tree in $dir has uncommitted changes:
$status
An apply must reflect a reviewed commit, not a local edit." ;;
  stale) die "HEAD ($(git -C "$dir" rev-parse --short HEAD)) is not $default_ref ($(git -C "$dir" rev-parse --short "$default_ref")).
This is the Print-Server failure exactly: applying an old tree reverts live infrastructure.
Fix the checkout — do not set TF_GUARD_ALLOW_UNMERGED unless you are deliberately testing a branch." ;;
esac

# 2. plan ----------------------------------------------------------------------
planfile="$(mktemp -u "${TMPDIR:-/tmp}/tfguard.XXXXXX.plan")"
trap 'rm -f "$planfile" "$planfile.json"' EXIT
terraform -chdir="$dir" plan -out="$planfile" "$@"
terraform -chdir="$dir" show -json "$planfile" >"$planfile.json"

destroys="$(jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' "$planfile.json")"
protected="$(jq --arg t "$PROTECTED_TYPES" \
  '[.resource_changes[]? | select(.change.actions | index("delete")) | select(.type | test($t))] | length' \
  "$planfile.json")"

case "$(plan_verdict "$destroys" "$protected" "${TF_GUARD_CONFIRM_DESTROY:-}")" in
  refuse-protected)
    jq -r --arg t "$PROTECTED_TYPES" \
      '.resource_changes[]? | select(.change.actions | index("delete")) | select(.type | test($t)) | "  " + .address' \
      "$planfile.json" >&2
    die "the plan destroys $protected protected identity resource(s), listed above.
A secret takes its versions with it and a service-account id is unusable for 30 days.
If this is genuinely intended, remove the module block on the default branch in a reviewed PR." ;;
  refuse-destroy)
    jq -r '.resource_changes[]? | select(.change.actions | index("delete")) | "  " + .address' "$planfile.json" >&2
    die "the plan destroys $destroys resource(s), listed above.
Re-run with TF_GUARD_CONFIRM_DESTROY=$destroys if every one of them is intended." ;;
esac

# 3. apply the plan that was inspected, never a fresh one ----------------------
# Applying the saved plan file closes the gap between what was checked and what
# runs: a bare `terraform apply -auto-approve` re-plans, so state that moved in
# between is applied unreviewed.
terraform -chdir="$dir" apply "$planfile"
