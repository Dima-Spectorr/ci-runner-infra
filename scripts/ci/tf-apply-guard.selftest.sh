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

# ── plan ──────────────────────────────────────────────────────────────────────
check "create-only plan applies" \
  ok "$(plan_verdict 0 0 '')"

check "destroying a protected identity refuses" \
  refuse-protected "$(plan_verdict 35 4 '')"

# The override is a count, not a boolean, so it cannot be carried over from an
# earlier run or pasted past a plan that grew.
check "protected destroy is NOT overridable by the count token" \
  refuse-protected "$(plan_verdict 35 4 35)"

check "unprotected destroys refuse without confirmation" \
  refuse-destroy "$(plan_verdict 3 0 '')"

check "a stale confirmation count still refuses" \
  refuse-destroy "$(plan_verdict 4 0 3)"

check "exact confirmation count applies" \
  ok "$(plan_verdict 3 0 3)"

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

if [ "$fails" -eq 0 ]; then
  printf '\nPASS — a stale or dirty checkout, and any identity-destroying plan, are refused before apply.\n'
else
  printf '\n%d assertion(s) failed.\n' "$fails"; exit 1
fi
