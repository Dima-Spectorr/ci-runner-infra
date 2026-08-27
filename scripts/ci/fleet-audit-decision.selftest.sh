#!/usr/bin/env bash
# Self-test for the fleet audit's per-repository rule.
#
# The workflow that calls it runs on a schedule from the default branch, so the
# pull request that changes this rule cannot exercise it. These cases are the
# test.
#
# The weighting is the inverse of the reaper's. That rule destroys, so almost
# every case there must NOT delete. This one only reports, and the failure it
# exists to prevent is a QUIET one — so most cases below assert that a specific
# broken state is still reported, and several assert that an unknown is reported
# rather than passed over.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/fleet-audit-decision.sh"

PASS=0
FAIL=0

WANT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# A fully healthy pool repository. Every case below is this string with one
# fact changed, so a diff between a case and this line is exactly the input
# under test.
HEALTHY_POOL="tier=pool;has_lane=1;has_guard=1;has_reaper=1"
HEALTHY_POOL="$HEALTHY_POOL;lane_pin=$WANT;guard_pin=$WANT;reaper_pin=$WANT;want_pin=$WANT"
HEALTHY_POOL="$HEALTHY_POOL;enabled=true;armed=true;app_id=1;app_key=1"
HEALTHY_POOL="$HEALTHY_POOL;checks_match=1;ruleset=1;runners=4;online=4"
HEALTHY_POOL="$HEALTHY_POOL;corpses=0;demand=0;page=50"

# has <expected-substring> <description> <facts>
has() {
  local want="$1" desc="$2" facts="$3" got
  got=$(fleet_verdict "$facts")
  if [[ "$got" == *"$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want line containing: %s\n  got:\n%s\n' "$desc" "$want" "$got"
  fi
}

# hasnt <forbidden-substring> <description> <facts>
hasnt() {
  local nope="$1" desc="$2" facts="$3" got
  got=$(fleet_verdict "$facts")
  if [[ "$got" != *"$nope"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  must not contain: %s\n  got:\n%s\n' "$desc" "$nope" "$got"
  fi
}

# swap <fact-key> <new-value> — the healthy pool with one fact replaced.
swap() {
  local key="$1" value="$2"
  printf '%s' "$HEALTHY_POOL" | sed "s/;$key=[^;]*/;$key=$value/"
}

# --- the compliant case, and the invariant that it is never silent ------------
has "ok:compliant" "a healthy pool repository is compliant" "$HEALTHY_POOL"
has "ok:compliant" "a healthy lane repository is compliant" \
  "tier=lane;has_lane=1;has_guard=1;has_reaper=1;lane_pin=$WANT;guard_pin=$WANT;reaper_pin=$WANT;want_pin=$WANT;enabled=true;armed=true;app_id=1;app_key=1;checks_match=1;ruleset=1"

# THE INVARIANT THE WHOLE AUDIT RESTS ON. An empty result and a clean result
# must never render the same, in any tier — including a tier nobody recognised.
for t in pool lane dormant empty source nonsense ""; do
  out=$(fleet_verdict "tier=$t")
  if [ -n "$out" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: tier=%s printed nothing at all\n' "${t:-<empty>}"
  fi
done

# --- tier handling ------------------------------------------------------------
has "fail:unknown-tier" "an unrecognised tier is a finding, not a default" "tier=wat"
has "fail:unknown-tier" "an empty tier is a finding" ""
has "ok:compliant" "a dormant repository with no CI is compliant" "tier=dormant;has_ci=0"
has "fail:dormant-repo-has-ci" "a dormant repository that grew CI must be reclassified" \
  "tier=dormant;has_ci=1"
has "warn:ci-unknown" "a dormant repository whose workflows could not be listed is a warning" \
  "tier=dormant"
has "ok:compliant" "an empty repository is compliant" "tier=empty;has_ci=0"
has "fail:empty-repo-has-ci" "an empty repository that grew CI must be reclassified" \
  "tier=empty;has_ci=1"
has "ok:compliant" "the source repository has no pin to itself" "tier=source"
hasnt "pin-stale" "the source repository is never reported as stale" \
  "tier=source;lane_pin=$OLD;want_pin=$WANT"

# --- onboarding ---------------------------------------------------------------
has "fail:no-merge-lane" "a pool repository with no lane is a failure" \
  "tier=pool;has_lane=0"
has "fail:no-merge-lane" "a lane repository with no lane is a failure" \
  "tier=lane;has_lane=0"
hasnt "lane-not-enabled" "a repository with no lane is not also reported as unarmed" \
  "tier=lane;has_lane=0"
has "warn:no-pr-guard" "a missing pr-guard is a warning" "$(swap has_guard 0)"
has "warn:no-branch-reaper" "a missing branch reaper is a warning" "$(swap has_reaper 0)"

# --- pins ---------------------------------------------------------------------
has "fail:lane-pin-stale" "a stale lane pin is a failure" "$(swap lane_pin "$OLD")"
has "fail:guard-pin-stale" "a stale guard pin is a failure" "$(swap guard_pin "$OLD")"
has "fail:reaper-pin-stale" "a stale reaper pin is a failure" "$(swap reaper_pin "$OLD")"
# Measured 2026-08-27: the lane sat at v5.73.0 in ten repositories while the
# guard and reaper beside it were still on v5.71.0. One report per caller.
got=$(fleet_verdict "$(swap guard_pin "$OLD" | sed "s/;reaper_pin=[^;]*/;reaper_pin=$OLD/")")
if [ "$(printf '%s' "$got" | grep -c 'pin-stale')" = "2" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL: two stale callers must produce two findings\n  got:\n%s\n' "$got"
fi
has "warn:expected-pin-unknown" "an unknown expected pin is reported, not assumed" \
  "$(swap want_pin '')"
hasnt "pin-stale" "an unknown expected pin does not also report every caller stale" \
  "$(swap want_pin '')"
# The hole this rule exists to close: a caller whose file downloaded as empty
# has an unreadable pin, and reading that as "not stale" makes a repository the
# audit FAILED to check indistinguishable from one it checked and found current.
has "warn:lane-pin-unreadable" "a caller that exists with an unreadable pin is reported" \
  "$(swap lane_pin '')"
has "warn:guard-pin-unreadable" "an unreadable guard pin is reported" "$(swap guard_pin '')"
has "warn:reaper-pin-unreadable" "an unreadable reaper pin is reported" "$(swap reaper_pin '')"
hasnt "lane-pin-stale" "an unreadable pin is not ALSO reported as stale" "$(swap lane_pin '')"
# An ABSENT caller has no pin to be unreadable; it is already reported missing,
# and a second line about its pin would read as two separate problems.
hasnt "guard-pin-unreadable" "a missing caller is not reported for its missing pin" \
  "$(swap has_guard 0 | sed "s/;guard_pin=[^;]*/;guard_pin=/")"

# --- arming -------------------------------------------------------------------
has "fail:lane-not-enabled" "an unset MERGE_LANE_ENABLED is a failure" "$(swap enabled '')"
has "fail:lane-not-enabled" "MERGE_LANE_ENABLED=false is a failure" "$(swap enabled false)"
has "warn:lane-dry-run" "enabled but not armed is the deliberate dry run" "$(swap armed '')"
hasnt "fail:lane-not-enabled" "a dry run is not also reported as disabled" "$(swap armed '')"
has "fail:missing-app-id-secret" "an enabled lane without the app id fails" "$(swap app_id 0)"
has "fail:missing-app-key-secret" "an enabled lane without the app key fails" "$(swap app_key 0)"
# General-IT, 2026-08-27: variables set, secrets absent, lane job skipped. The
# secrets are only a finding once the lane is on — reporting them for a
# repository that never enabled the lane is noise on top of the real finding.
hasnt "missing-app-id-secret" "a disabled lane does not also report its missing secrets" \
  "tier=lane;has_lane=1;has_guard=1;has_reaper=1;want_pin=$WANT;lane_pin=$WANT;guard_pin=$WANT;reaper_pin=$WANT;enabled=;app_id=0;app_key=0"

# UNREADABLE IS NOT UNSET. The variables and secrets APIs answer a token
# without the scope with a 403, whose body is as empty as a repository that
# genuinely has none. On 2026-08-27 the first live run under the App token
# reported all seventeen armed and unarmed repositories alike as
# `lane-not-enabled`, because the App had no `Variables: read` — the audit
# stating the opposite of the truth, in the one place it exists to be trusted.
UNREADABLE_VARS="$(swap enabled '');vars_readable=0"
has "warn:lane-arming-unreadable" "a token that cannot read variables says so" \
  "$UNREADABLE_VARS"
hasnt "fail:lane-not-enabled" "an unreadable variable is never called unset" \
  "$UNREADABLE_VARS"
hasnt "warn:lane-dry-run" "an unreadable variable is not called a dry run either" \
  "$HEALTHY_POOL;vars_readable=0"
UNREADABLE_SECRETS="$(swap app_id 0);secrets_readable=0"
has "warn:lane-secrets-unreadable" "a token that cannot read secrets says so" \
  "$UNREADABLE_SECRETS"
hasnt "fail:missing-app-id-secret" "an unreadable secret list is not a missing secret" \
  "$UNREADABLE_SECRETS"
# The common case must stay quiet: a readable token supplies `1`, and a caller
# that supplies neither fact is read as readable rather than warning on every
# repository in the fleet.
hasnt "unreadable" "a readable token produces no readability finding" \
  "$HEALTHY_POOL;vars_readable=1;secrets_readable=1"

# --- the phantom required check -----------------------------------------------
has "fail:required-checks-disagree" "the lane list and the ruleset must agree" \
  "$(swap checks_match 0)"
has "warn:required-checks-uncomparable" "an unreadable ruleset is reported, not passed" \
  "$(swap checks_match '')"
has "warn:no-ruleset-on-default-branch" "an armed lane with no ruleset is a warning" \
  "$(swap ruleset 0)"
# A dry-run lane merges nothing, so a disagreement cannot block anything yet.
hasnt "required-checks-disagree" "a dry-run lane does not report a check disagreement" \
  "$(swap armed false | sed 's/;checks_match=[^;]*/;checks_match=0/')"

# --- pool health --------------------------------------------------------------
# ZERO REGISTERED IS THE HEALTHY IDLE STATE — these pools scale to zero. The
# first live run of this audit reported four healthy repositories as failures
# for it, which is the noise that teaches people to stop reading an audit.
hasnt "fail:" "an idle pool at zero runners is not a failure" \
  "$(swap runners 0 | sed 's/;online=[^;]*/;online=0/')"
has "fail:no-runners-under-demand" "zero runners WITH queued work is the failure" \
  "$(swap runners 0 | sed 's/;online=[^;]*/;online=0/;s/;demand=[^;]*/;demand=7/')"
has "warn:demand-unknown" "an empty pool whose demand could not be read is reported" \
  "$(swap runners 0 | sed 's/;online=[^;]*/;online=0/;s/;demand=[^;]*/;demand=/')"
# Unconditional on demand: hosts that registered and then went unreachable are
# a fault whether or not anything is queued this minute.
has "fail:all-runners-offline" "registered but all offline is a failure even when idle" \
  "$(swap online 0)"
has "warn:runner-count-unknown" "an unreadable runner count is reported" \
  "$(swap runners '')"
hasnt "runners" "a lane repository is never audited for runners" \
  "tier=lane;has_lane=1;has_guard=1;has_reaper=1;want_pin=$WANT;lane_pin=$WANT;guard_pin=$WANT;reaper_pin=$WANT;enabled=true;armed=true;app_id=1;app_key=1;checks_match=1;ruleset=1"

# --- the corpse page cap ------------------------------------------------------
# Apigee-Portal, 2026-08-27: 24 unclearable queued runs against a page of 50 —
# half the page gone, and no metric anywhere reporting it, because the
# truncation happens at the API before the demand budget is spent.
has "warn:queued-page-filling" "half a page of corpses is a warning" "$(swap corpses 25)"
has "fail:queued-page-full" "a full page of corpses is a failure" "$(swap corpses 50)"
hasnt "queued-page" "a handful of corpses is not yet a finding" "$(swap corpses 3)"
hasnt "queued-page" "an unknown corpse count does not divide by an unknown page" \
  "$(swap page '')"

printf 'fleet-audit-decision: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
