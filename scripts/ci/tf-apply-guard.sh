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
#   2. PLAN      -- destroys must be confirmed with a token DERIVED FROM THE PLAN
#                   ITSELF, so a confirmation cannot be carried over from an
#                   earlier run or reused by a plan that grew a resource.
#
# Usage:  scripts/ci/tf-apply-guard.sh <runner-root-dir> [terraform-args...]
#
#   The script lives here, in ci-runner-infra; the runner roots live in the
#   consuming repositories. Run it from this checkout and point it at the root:
#     ~/src/ci-runner-infra/scripts/ci/tf-apply-guard.sh ~/src/<repo>/infra/terraform/ci-runners
#   Every git and terraform call is made against that directory (`git -C` /
#   `terraform -chdir`), never the current one.
#
# Confirmation tokens (printed by the refusal that asks for them):
#   TF_GUARD_CONFIRM_DESTROY=<digest>    ordinary destroys
#   TF_GUARD_CONFIRM_PROTECTED=<digest>  destroys an identity — see below
#   TF_GUARD_ALLOW_UNMERGED=1            HEAD may differ from origin/HEAD (branch testing)

set -euo pipefail

# ── protected kinds ───────────────────────────────────────────────────────────
# Destroying these is never recoverable by re-applying:
#   - a secret takes its versions with it, and the App-key PEM exists nowhere else
#   - a service account id is unusable for 30 days after deletion, and every IAM
#     binding that referenced it silently detaches
#
# Matched ANCHORED against the whole type. Unanchored, this also caught
# google_service_account_iam_member and google_secret_manager_secret_iam_member,
# so routine IAM churn -- a binding replaced, a grant moved -- would have been
# refused as identity destruction. A guard that cries wolf on ordinary applies is
# a guard operators learn to override.
PROTECTED_TYPES='^(google_secret_manager_secret|google_service_account)$'

# ── pure decision functions (exercised by tf-apply-guard.selftest.sh) ─────────

# checkout_verdict <head_sha> <remote_sha> <porcelain_status> <allow_unmerged>
# -> ok | stale | dirty
checkout_verdict() {
  local head="$1" remote="$2" status="$3" allow="${4:-0}"
  [ -n "$status" ] && { echo dirty; return; }
  if [ "$head" != "$remote" ] && [ "$allow" != "1" ]; then echo stale; return; fi
  echo ok
}

# plan_digest <newline-separated destroyed addresses> -> short content hash
# The confirmation token is derived from WHAT is destroyed, not how many. A count
# is reusable: an exported TF_GUARD_CONFIRM_DESTROY=3 from an earlier root would
# wave through a different plan that also destroys three things. A digest changes
# the moment the plan does.
plan_digest() {
  printf '%s\n' "$1" | LC_ALL=C sort | sha256sum | cut -c1-12
}

# plan_verdict <destroy_count> <protected_count> <digest> <confirm_destroy> <confirm_protected>
# -> ok | refuse-protected | refuse-destroy
plan_verdict() {
  local destroys="$1" protected="$2" digest="$3" confirm="${4:-}" confirm_protected="${5:-}"
  if [ "$protected" -gt 0 ]; then
    # Decommissioning a pool is a legitimate operation, so this cannot be an
    # absolute refusal -- an operator who can only proceed by bypassing the guard
    # bypasses it for everything. It takes its own token, which no ordinary
    # destroy confirmation satisfies, and that token is bound to this exact plan.
    [ -n "$confirm_protected" ] && [ "$confirm_protected" = "$digest" ] && { echo ok; return; }
    echo refuse-protected; return
  fi
  if [ "$destroys" -gt 0 ] && [ "$confirm" != "$digest" ]; then
    echo refuse-destroy; return
  fi
  echo ok
}

# The plan reader is jq if present, python3 otherwise. Not a nicety: the Windows
# administration host these roots are applied from has no jq, so a jq-only guard
# refuses every apply — and a guard that blocks the normal path is a guard that
# gets skipped, which returns us to bare `terraform apply -auto-approve`, the
# exact command that destroyed Print-Server's identity. There is no third
# fallback: parsing the plan with grep would be guessing, and this script's whole
# value is that it does not guess about what is being destroyed.
#
# Both readers are exercised by the self-test against the same fixture, on
# whichever of them the machine has: two implementations of "what does this plan
# destroy" that disagree would be worse than one, since the digest an operator is
# told to re-run with is computed from the answer.
pick_plan_reader() {
  if command -v jq >/dev/null 2>&1; then echo jq
  elif command -v python3 >/dev/null 2>&1; then echo python3
  else echo none
  fi
}
PLAN_READER="${PLAN_READER:-$(pick_plan_reader)}"

# read_plan <plan.json> <mode: all|protected> -> destroyed addresses, one per line
read_plan() {
  if [ "$PLAN_READER" = jq ]; then
    if [ "$2" = protected ]; then
      jq -r --arg t "$PROTECTED_TYPES" \
        '.resource_changes[]? | select(.change.actions | index("delete")) | select(.type | test($t)) | .address' "$1"
    else
      jq -r '.resource_changes[]? | select(.change.actions | index("delete")) | .address' "$1"
    fi
  else
    PROTECTED_TYPES="$PROTECTED_TYPES" python3 -c '
import json, os, re, sys
# On Windows, text-mode stdout translates \n to \r\n. The trailing CR then rides
# into every address, so the digest computed from this list differs from the one
# jq would produce for the same plan -- two readers disagreeing on the token the
# operator is told to re-run with.
sys.stdout.reconfigure(newline="\n")
mode = sys.argv[2]
pat = re.compile(os.environ["PROTECTED_TYPES"])
with open(sys.argv[1], encoding="utf-8") as fh:
    plan = json.load(fh)
for rc in plan.get("resource_changes") or []:
    if "delete" not in (rc.get("change") or {}).get("actions", []):
        continue
    # `search`, matching jq test(): the pattern carries its own ^...$ anchors so
    # that neighbouring types like google_service_account_iam_member do not match.
    if mode == "protected" and not pat.search(rc.get("type", "")):
        continue
    print(rc["address"])
' "$1" "$2"
  fi
}

# Sourced by the self-test; everything below is the live path only.
[ "${TF_APPLY_GUARD_LIB:-0}" = "1" ] && return 0

# ── live path ─────────────────────────────────────────────────────────────────
die() { printf 'tf-apply-guard: REFUSED — %s\n' "$*" >&2; exit 2; }

dir="${1:?usage: tf-apply-guard.sh <runner-root-dir> [terraform-args...]}"; shift || true
[ -d "$dir" ] || die "no such directory: $dir"
[ "$PLAN_READER" = none ] && die "need jq or python3 to read the plan JSON; refusing to apply blind"

# 1. checkout ------------------------------------------------------------------
git -C "$dir" fetch --quiet origin
# Resolve the remote default branch rather than assuming `main`: two of these
# repos are still on `master`. Re-resolve it on EVERY run -- `git fetch` does not
# update an existing refs/remotes/origin/HEAD, so a repository whose default
# branch moved after cloning would keep being compared against the old one, and a
# checkout at that old tip would pass as current.
git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
default_ref="$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
[ -n "$default_ref" ] || die "cannot resolve origin/HEAD in $dir — refusing to apply from an unknown branch"

head_sha="$(git -C "$dir" rev-parse HEAD)"
remote_sha="$(git -C "$dir" rev-parse "$default_ref")"
# Exclude Terraform's own working DIRECTORY by pathspec, not by filtering the
# porcelain output for the substring `.terraform`: that substring also matches
# `.terraform.lock.hcl`, a tracked, reviewable file whose uncommitted edits are
# exactly the kind of unreviewed provider change this gate exists to stop.
status="$(git -C "$dir" status --porcelain -- . ':(exclude,glob)**/.terraform/**' ':(exclude,glob).terraform/**')"

case "$(checkout_verdict "$head_sha" "$remote_sha" "$status" "${TF_GUARD_ALLOW_UNMERGED:-0}")" in
  dirty) die "working tree in $dir has uncommitted changes:
$status
An apply must reflect a reviewed commit, not a local edit." ;;
  stale) die "HEAD ($(git -C "$dir" rev-parse --short HEAD)) is not $default_ref ($(git -C "$dir" rev-parse --short "$default_ref")).
This is the Print-Server failure exactly: applying an old tree reverts live infrastructure.
Fix the checkout — do not set TF_GUARD_ALLOW_UNMERGED unless you are deliberately testing a branch." ;;
esac

# 2. plan ----------------------------------------------------------------------
# A private directory, not `mktemp -u`: that only prints an unused NAME, so on a
# shared administration host another user can win the race and plant a symlink at
# the path this script is about to redirect into. The plan JSON is the whole
# configuration, including every attribute of every resource.
workdir="$(mktemp -d)"; chmod 700 "$workdir"
trap 'rm -rf "$workdir"' EXIT
planfile="$workdir/tf.plan"

terraform -chdir="$dir" plan -out="$planfile" "$@"
terraform -chdir="$dir" show -json "$planfile" >"$workdir/plan.json"

destroyed_addrs="$(read_plan "$workdir/plan.json" all)"
protected_addrs="$(read_plan "$workdir/plan.json" protected)"
destroys="$(printf '%s' "$destroyed_addrs" | grep -c . || true)"
protected="$(printf '%s' "$protected_addrs" | grep -c . || true)"
digest="$(plan_digest "$destroyed_addrs")"

case "$(plan_verdict "$destroys" "$protected" "$digest" \
          "${TF_GUARD_CONFIRM_DESTROY:-}" "${TF_GUARD_CONFIRM_PROTECTED:-}")" in
  refuse-protected)
    printf '%s\n' "$protected_addrs" | sed 's/^/  /' >&2
    die "the plan destroys $protected protected identity resource(s), listed above.
A secret takes its versions with it and a service-account id is unusable for 30 days.
Decommissioning a pool is legitimate — but the removal must already be on the default
branch (this checkout is, or you would not have got here). If every line above is meant
to go, re-run with TF_GUARD_CONFIRM_PROTECTED=$digest" ;;
  refuse-destroy)
    printf '%s\n' "$destroyed_addrs" | sed 's/^/  /' >&2
    die "the plan destroys $destroys resource(s), listed above.
Re-run with TF_GUARD_CONFIRM_DESTROY=$digest if every one of them is intended.
The token is a hash of that list, so it stops matching the moment the plan changes." ;;
esac

# 3. apply the plan that was inspected, never a fresh one ----------------------
# Applying the saved plan file closes the gap between what was checked and what
# runs: a bare `terraform apply -auto-approve` re-plans, so state that moved in
# between is applied unreviewed.
terraform -chdir="$dir" apply "$planfile"
