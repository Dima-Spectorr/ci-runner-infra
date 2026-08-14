#!/usr/bin/env bash
# Proves the two refusal decisions in tf-apply-guard.sh, including the exact
# Print-Server case: a clean tree at the wrong commit must refuse.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_APPLY_GUARD_LIB=1 . "$here/tf-apply-guard.sh"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# ── checkout ──────────────────────────────────────────────────────────────────
check "clean tree at origin default applies" \
  ok "$(checkout_verdict abc123 abc123 '' 0)"

# The incident: `git pull` failed, the tree was clean, and every other signal
# looked normal. Clean is not current.
check "clean tree at a STALE commit refuses" \
  stale "$(checkout_verdict b7713a2 cf22d83 '' 0)"

check "dirty tree refuses even at the right commit" \
  dirty "$(checkout_verdict abc123 abc123 ' M infra/terraform/ci-runners/main.tf' 0)"

# Dirty outranks stale: reporting "stale" first would send the operator to fix
# the checkout, and the local edit would then be silently discarded.
check "dirty outranks stale" \
  dirty "$(checkout_verdict b7713a2 cf22d83 ' M main.tf' 0)"

check "TF_GUARD_ALLOW_UNMERGED permits a branch" \
  ok "$(checkout_verdict b7713a2 cf22d83 '' 1)"

check "TF_GUARD_ALLOW_UNMERGED does NOT permit a dirty tree" \
  dirty "$(checkout_verdict abc123 abc123 ' M main.tf' 1)"

# ── digest ────────────────────────────────────────────────────────────────────
d1="$(plan_digest 'a
b')"
d2="$(plan_digest 'a
b
c')"
check "digest is stable for the same address set" "$d1" "$(plan_digest 'a
b')"
check "digest ignores address order" "$d1" "$(plan_digest 'b
a')"
[ "$d1" != "$d2" ] && printf 'ok   a plan that grows gets a different digest\n' \
  || { printf 'FAIL a plan that grows kept its digest\n'; fails=$((fails + 1)); }

# ── plan ──────────────────────────────────────────────────────────────────────
check "create-only plan applies" \
  ok "$(plan_verdict 0 0 "$d1" '' '')"

check "destroying a protected identity refuses" \
  refuse-protected "$(plan_verdict 35 4 "$d1" '' '')"

# The ordinary destroy token must not unlock an identity destroy, even when it is
# the correct digest for this plan — decommissioning a pool is a deliberate act.
check "ordinary confirmation does NOT unlock a protected destroy" \
  refuse-protected "$(plan_verdict 35 4 "$d1" "$d1" '')"

# ...but the removal path has to be completable, or operators bypass the wrapper
# entirely and it stops guarding anything.
check "TF_GUARD_CONFIRM_PROTECTED with the plan's digest applies" \
  ok "$(plan_verdict 35 4 "$d1" '' "$d1")"

check "a protected token from another plan refuses" \
  refuse-protected "$(plan_verdict 35 4 "$d1" '' "$d2")"

check "unprotected destroys refuse without confirmation" \
  refuse-destroy "$(plan_verdict 3 0 "$d1" '' '')"

# The token is content-bound, so a confirmation left exported by an earlier run
# cannot wave through a different plan that happens to destroy as much.
check "a confirmation from another plan refuses" \
  refuse-destroy "$(plan_verdict 3 0 "$d2" "$d1" '')"

check "matching confirmation applies" \
  ok "$(plan_verdict 3 0 "$d1" "$d1" '')"

# ── the module-level guard this script backstops ──────────────────────────────
# prevent_destroy on the App-key secret was live during the incident and did not
# fire, because the stale tree had no module block for it to be attached to. If
# it is ever removed, the last line of defence would be this script alone.
identity_main="$here/../../modules/ci-runner-identity/main.tf"
if grep -qE 'prevent_destroy[[:space:]]*=[[:space:]]*true' "$identity_main"; then
  printf 'ok   ci-runner-identity still declares prevent_destroy on the App-key secret\n'
else
  printf 'FAIL ci-runner-identity lost prevent_destroy on the App-key secret\n'; fails=$((fails + 1))
fi

# ── protected-type matching ───────────────────────────────────────────────────
# Unanchored, PROTECTED_TYPES matched every *_iam_member of a secret or service
# account, so routine IAM churn would have been refused as identity destruction.
for t in google_secret_manager_secret google_service_account; do
  echo "$t" | grep -qE "$PROTECTED_TYPES" \
    || { printf 'FAIL %s is not matched as protected\n' "$t"; fails=$((fails + 1)); }
done
for t in google_service_account_iam_member google_secret_manager_secret_iam_member \
         google_secret_manager_secret_version google_service_account_key; do
  if echo "$t" | grep -qE "$PROTECTED_TYPES"; then
    printf 'FAIL %s is matched as protected — IAM churn would be refused\n' "$t"; fails=$((fails + 1))
  fi
done
[ "$fails" -eq 0 ] && printf 'ok   protected types match exactly, not as a prefix of IAM types\n'

if [ "$fails" -eq 0 ]; then
  printf '\nPASS — a stale or dirty checkout, and any unconfirmed destroy, are refused before apply.\n'
else
  printf '\n%d assertion(s) failed.\n' "$fails"; exit 1
fi
