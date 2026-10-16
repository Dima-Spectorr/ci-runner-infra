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
if [ "$d1" != "$d2" ]; then printf 'ok   a plan that grows gets a different digest\n'
else printf 'FAIL a plan that grows kept its digest\n'; fails=$((fails + 1)); fi

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
type_fails=0
for t in google_secret_manager_secret google_service_account; do
  if ! echo "$t" | grep -cE "$PROTECTED_TYPES" >/dev/null; then
    printf 'FAIL %s is not matched as protected\n' "$t"; type_fails=$((type_fails + 1))
  fi
done
for t in google_service_account_iam_member google_secret_manager_secret_iam_member \
         google_secret_manager_secret_version google_service_account_key; do
  if echo "$t" | grep -cE "$PROTECTED_TYPES" >/dev/null; then
    printf 'FAIL %s is matched as protected — IAM churn would be refused\n' "$t"; type_fails=$((type_fails + 1))
  fi
done
if [ "$type_fails" -eq 0 ]; then
  printf 'ok   protected types match exactly, not as a prefix of IAM types\n'
else
  fails=$((fails + type_fails))
fi

# ── plan readers agree ────────────────────────────────────────────────────────
# The guard reads the plan with jq, or with python3 where jq is absent (the
# Windows administration host these roots are applied from has no jq, and a guard
# that refuses every apply is a guard that gets skipped). Two implementations of
# "what does this plan destroy" that disagree would be worse than one: the digest
# the operator is told to re-run with is computed from that answer, so a reader
# that misses a resource hands out a token which waves the miss through.
plan_fixture="$(mktemp)"; trap 'rm -f "$plan_fixture"' EXIT
cat >"$plan_fixture" <<'JSON'
{"resource_changes":[
  {"address":"module.id.google_secret_manager_secret.app_key","type":"google_secret_manager_secret","change":{"actions":["delete"]}},
  {"address":"module.id.google_service_account.host","type":"google_service_account","change":{"actions":["delete","create"]}},
  {"address":"module.id.google_service_account_iam_member.tokencreator","type":"google_service_account_iam_member","change":{"actions":["delete"]}},
  {"address":"module.pool.google_compute_instance.controller","type":"google_compute_instance","change":{"actions":["update"]}},
  {"address":"module.pool.google_compute_region_autoscaler.hosts","type":"google_compute_region_autoscaler","change":{"actions":["delete"]}}
]}
JSON

reader_fails=0
avail=""
command -v jq      >/dev/null 2>&1 && avail="$avail jq"
command -v python3 >/dev/null 2>&1 && avail="$avail python3"
[ -n "$avail" ] || { printf 'FAIL neither jq nor python3 is available — the guard cannot read a plan here\n'; fails=$((fails + 1)); }

for r in $avail; do
  # shellcheck disable=SC2034  # read_plan, sourced from the guard, reads this.
  PLAN_READER="$r"
  got_all="$(read_plan "$plan_fixture" all | sort | tr '\n' ',')"
  got_prot="$(read_plan "$plan_fixture" protected | sort | tr '\n' ',')"
  want_all='module.id.google_secret_manager_secret.app_key,module.id.google_service_account.host,module.id.google_service_account_iam_member.tokencreator,module.pool.google_compute_region_autoscaler.hosts,'
  want_prot='module.id.google_secret_manager_secret.app_key,module.id.google_service_account.host,'
  # The service account is a delete+create REPLACE. It must still count: a
  # replaced service account is a new id, and every binding to the old one
  # detaches silently.
  if [ "$got_all" = "$want_all" ]; then
    printf 'ok   %s lists every destroy, including a delete+create replacement\n' "$r"
  else
    printf 'FAIL %s destroy list: %s\n' "$r" "$got_all"; reader_fails=$((reader_fails + 1))
  fi
  if [ "$got_prot" = "$want_prot" ]; then
    printf 'ok   %s counts only true identities as protected, not the iam_member\n' "$r"
  else
    printf 'FAIL %s protected list: %s\n' "$r" "$got_prot"; reader_fails=$((reader_fails + 1))
  fi
done
unset PLAN_READER
fails=$((fails + reader_fails))

# ── unattended mode (ci-runner-apply-trigger, #1567) ──────────────────────────
# Nobody can type a token inside a build, so the rule is absolute: only the
# second half of a create-before-destroy replacement (or a deposed leftover of
# one) of an allowed type gets through. Each row below is a way a destroy could
# plausibly slip past a looser reading of "replacement".
unattended_fixture="$(mktemp)"
cat >"$unattended_fixture" <<'JSON'
{"format_version":"1.2","resource_changes":[
  {"address":"module.pool.google_compute_instance_template.host","type":"google_compute_instance_template","change":{"actions":["create","delete"]}},
  {"address":"module.pool.google_compute_instance_template.old","type":"google_compute_instance_template","deposed":"0a1b2c3d","change":{"actions":["delete"]}},
  {"address":"module.pool.google_compute_instance_template.controller","type":"google_compute_instance_template","change":{"actions":["delete","create"]}},
  {"address":"module.pool.google_compute_instance_template.gone","type":"google_compute_instance_template","change":{"actions":["delete"]}},
  {"address":"module.pool.google_compute_region_instance_group_manager.hosts","type":"google_compute_region_instance_group_manager","change":{"actions":["create","delete"]}},
  {"address":"module.id.google_service_account.host","type":"google_service_account","change":{"actions":["create","delete"]}},
  {"address":"module.pool.google_compute_instance_template_x.y","type":"google_compute_instance_template_x","change":{"actions":["create","delete"]}},
  {"address":"module.pool.google_compute_instance.controller","type":"google_compute_instance","change":{"actions":["update"]}},
  {"address":"module.pool.google_compute_firewall.ssh","type":"google_compute_firewall","change":{"actions":["create"]}}
]}
JSON
# What must be refused, and only that: the delete-first replacement (a gap with
# no template), the plain delete, the non-allowed types even as create-first
# replacements, and a type whose NAME merely starts with an allowed one.
want_refused='module.id.google_service_account.host [create,delete],module.pool.google_compute_instance_template.controller [delete,create],module.pool.google_compute_instance_template.gone [delete],module.pool.google_compute_instance_template_x.y [create,delete],module.pool.google_compute_region_instance_group_manager.hosts [create,delete],'
allow_tpl='google_compute_instance_template
google_compute_region_instance_template'

ua_fails=0
for r in $avail; do
  # shellcheck disable=SC2034  # unattended_refusals, sourced from the guard, reads this.
  PLAN_READER="$r"
  got="$(unattended_refusals "$unattended_fixture" "$allow_tpl" | LC_ALL=C sort | tr '\n' ',')"
  if [ "$got" = "$want_refused" ]; then
    printf 'ok   %s unattended: refuses every destroy but a create-first template replacement\n' "$r"
  else
    printf 'FAIL %s unattended refusals: %s\n' "$r" "$got"; ua_fails=$((ua_fails + 1))
  fi
  # An empty allow-list makes every destroy a manual one.
  n="$(unattended_refusals "$unattended_fixture" '' | grep -c . || true)"
  if [ "$n" = 7 ]; then printf 'ok   %s unattended: an empty allow-list refuses all 7 destroys\n' "$r"
  else printf 'FAIL %s unattended with no allow-list refused %s of 7\n' "$r" "$n"; ua_fails=$((ua_fails + 1)); fi
  # A file that is not a plan must be an ERROR, never "nothing destroyed".
  if printf '{"resource_changes":[]}' >"$unattended_fixture.bad" && ! unattended_refusals "$unattended_fixture.bad" "$allow_tpl" >/dev/null 2>&1; then
    printf 'ok   %s unattended: a JSON that is not a plan is an error, not a pass\n' "$r"
  else
    printf 'FAIL %s unattended: a JSON with no format_version read as a clean plan\n' "$r"; ua_fails=$((ua_fails + 1))
  fi
done
unset PLAN_READER

# ── a change with no actions array is an error, in both readers (#1588) ───────
# jq's `null | index("delete")` is null, so a row whose `actions` was null or
# missing used to be dropped as "not a destroy" by the jq reader while python
# raised on it: the two readers disagreed, and the lenient one decided. Every
# shape below must be an ERROR from every reader, in both the attended reader
# (read_plan) and the unattended one — never an empty list, because an empty
# list is what a plan that destroys nothing looks like.
shape_fails=0
shape_dir="$(mktemp -d)"
n_shape=0
for rc in '{"address":"a.b","type":"google_compute_instance_template","change":{"actions":null}}' \
          '{"address":"a.b","type":"google_compute_instance_template","change":{}}' \
          '{"address":"a.b","type":"google_compute_instance_template"}' \
          '{"address":"a.b","type":"google_compute_instance_template","change":{"actions":"delete"}}' \
          '{"address":"a.b","type":"google_compute_instance_template","change":{"actions":{"0":"delete"}}}'; do
  n_shape=$((n_shape + 1))
  printf '{"format_version":"1.2","resource_changes":[%s]}' "$rc" >"$shape_dir/$n_shape.json"
done
n_shape=$((n_shape + 1))
printf '{"format_version":"1.2","resource_changes":{"a.b":{"change":{"actions":["delete"]}}}}' >"$shape_dir/$n_shape.json"
# `false` is not "absent": jq's `//` would read it as an empty plan.
n_shape=$((n_shape + 1))
printf '{"format_version":"1.2","resource_changes":false}' >"$shape_dir/$n_shape.json"
# A plan with no changes at all is still a clean plan, not an error — or the
# rule above would turn every no-op plan red.
printf '{"format_version":"1.2"}' >"$shape_dir/none.json"
for r in $avail; do
  # shellcheck disable=SC2034  # read by the sourced readers.
  PLAN_READER="$r"
  before=$shape_fails
  for i in $(seq 1 "$n_shape"); do
    f="$shape_dir/$i.json"
    if unattended_refusals "$f" 'google_compute_instance_template' >/dev/null 2>&1; then
      printf 'FAIL %s unattended: malformed shape %s (%s) read as a plan\n' "$r" "$i" "$(cat "$f")"; shape_fails=$((shape_fails + 1))
    fi
    if read_plan "$f" all >/dev/null 2>&1; then
      printf 'FAIL %s read_plan: malformed shape %s (%s) read as a plan\n' "$r" "$i" "$(cat "$f")"; shape_fails=$((shape_fails + 1))
    fi
  done
  if unattended_refusals "$shape_dir/none.json" 'google_compute_instance_template' >/dev/null 2>&1 \
     && [ -z "$(read_plan "$shape_dir/none.json" all)" ]; then :; else
    printf 'FAIL %s a plan with no resource_changes is refused — every no-op plan would go red\n' "$r"; shape_fails=$((shape_fails + 1))
  fi
  [ "$shape_fails" -eq "$before" ] && printf 'ok   %s refuses all %s change shapes without an actions array, in both readers\n' "$r" "$n_shape"
done
unset PLAN_READER
check "unattended: a change whose actions is null stops red" 2 \
  "$(bash "$here/tf-apply-guard.sh" --unattended-plan "$shape_dir/1.json" google_compute_instance_template >/dev/null 2>&1; echo $?)"
rm -rf "$shape_dir"
fails=$((fails + shape_fails))

# The live entry point, end to end: exit status is what Cloud Build reads.
ua_run() { bash "$here/tf-apply-guard.sh" --unattended-plan "$@" >/dev/null 2>&1; echo $?; }
clean_fixture="$(mktemp)"
printf '%s' '{"format_version":"1.2","resource_changes":[{"address":"t.a","type":"google_compute_instance_template","change":{"actions":["create","delete"]}}]}' >"$clean_fixture"
: >"$unattended_fixture.empty"
check "unattended: a create-first template replacement applies" 0 "$(ua_run "$clean_fixture" google_compute_instance_template)"
check "unattended: the mixed plan stops red" 2 "$(ua_run "$unattended_fixture" google_compute_instance_template google_compute_region_instance_template)"
check "unattended: the same replacement with NO allowed type stops red" 2 "$(ua_run "$clean_fixture")"
check "unattended: an empty plan JSON stops red" 2 "$(ua_run "$unattended_fixture.empty" google_compute_instance_template)"
check "unattended: a missing plan JSON stops red" 2 "$(ua_run "$unattended_fixture.missing" google_compute_instance_template)"
# Beside a valid type, so the plan alone would pass: only the input check refuses.
check "unattended: a pattern as an allowed type stops red" 2 "$(ua_run "$clean_fixture" google_compute_instance_template 'google_.*')"
check "unattended: a protected identity type cannot be allowed" 2 "$(ua_run "$clean_fixture" google_compute_instance_template google_service_account)"
# There is no token in this mode: a confirmation left in the environment by an
# attended run must not unlock an unattended destroy.
ua_digest="$(plan_digest 'module.pool.google_compute_instance_template.gone')"
check "unattended: a confirmation token in the environment unlocks nothing" 2 \
  "$(TF_GUARD_CONFIRM_DESTROY="$ua_digest" TF_GUARD_CONFIRM_PROTECTED="$ua_digest" ua_run "$unattended_fixture" google_compute_instance_template)"
rm -f "$unattended_fixture" "$unattended_fixture.bad" "$unattended_fixture.empty" "$clean_fixture"
fails=$((fails + ua_fails))

if [ "$fails" -eq 0 ]; then
  printf '\nPASS — a stale or dirty checkout, and any unconfirmed destroy, are refused before apply.\n'
else
  printf '\n%d assertion(s) failed.\n' "$fails"; exit 1
fi
