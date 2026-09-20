#!/usr/bin/env bash
# Self-test for ensure_log_metric()'s failure mode in ensure-alert-policies.sh.
#
# WHY THIS TEST EXISTS.
#
# ensure-alert-policies.sh runs under `set -euo pipefail`, and it creates its
# log-based metrics BEFORE the loop that syncs the fourteen alert policies. For
# most of the script's life that create was unchecked, so an account without
# `logging.logMetrics.create` ended the script on line one of the metric step
# and skipped ALL FOURTEEN POLICIES — not just the one policy that needs the
# metric.
#
# Measured 2026-09-20: five of the ten pool projects, including ones whose apply
# had been green for months, held no `logging.logMetrics.create`, so the policy
# loop had never run in ANY of them. Thirteen policies existed as residue
# from an older manual bootstrap; the fourteenth, `applystale`, was added after
# that bootstrap and was therefore missing from all five. That is
# the alert that reports a project which has stopped receiving infrastructure —
# so the bug deleted precisely the alarm for the outage it was causing, and two
# projects then sat un-applied for three weeks before a human noticed.
#
# The apply step is non-blocking by design, so nothing turned red for any of it.
# That is why this is a test and not a comment: the failure is invisible in
# production by construction, and the only place it can be caught is here.
#
# Both directions are asserted, because either one alone is satisfiable by a
# script that is still broken:
#
#   a DENIED metric must not stop the run   -- or all fourteen policies vanish;
#   a DENIED metric must still be reported  -- or the run reports success while
#                                              an alert the fleet expects is
#                                              missing, which is how this hid.

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
SRC="$HERE/ensure-alert-policies.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

# Lifted from the shipping script rather than copied, so the two cannot drift.
FN="$(sed -n '/^ensure_log_metric() {/,/^}$/p' "$SRC")"
if [ -z "$FN" ]; then
  echo "FAIL: ensure_log_metric() not found in ensure-alert-policies.sh"
  exit 1
fi

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT

# Run the function exactly as the script runs it: under `set -euo pipefail`, in
# a subshell, with `g` stubbed. The marker printed AFTER the call is the whole
# point — under the old unchecked code the subshell died before reaching it.
run_case() { # <ok|denied|already_exists|transient>  -> stdout; rc is the subshell's
  local behaviour="$1"
  (
    set -euo pipefail
    # All three are read by the lifted function through `eval`, and the stub
    # replaces the gcloud wrapper it calls — none of which shellcheck can see.
    # shellcheck disable=SC2034
    PROJECT=testproject
    # shellcheck disable=SC2034
    DRY=0
    # shellcheck disable=SC2034
    tmp="$tmpd"
    # shellcheck disable=SC2317
    g() {
      # Each arm emits the real API's wording, because the function now
      # SELECTS its remediation by matching this text. A single generic
      # failure stub would let one arm's assertion pass on another arm's
      # output — the function would look error-aware while printing the same
      # advice for everything.
      #
      # Every message carries a sentinel the script's own text cannot contain,
      # so "the underlying error survived" is asserted independently of "we
      # named the right cause": our message already names the permission, so
      # matching on that alone would pass even if gcloud's stderr were dropped.
      case "$behaviour" in
        denied)
          echo "GCLOUD_STDERR_SENTINEL_7f3a: PERMISSION_DENIED: caller lacks permission" >&2
          return 1 ;;
        already_exists)
          echo "GCLOUD_STDERR_SENTINEL_7f3a: ALREADY_EXISTS: metric already exists" >&2
          return 1 ;;
        transient)
          echo "GCLOUD_STDERR_SENTINEL_7f3a: INTERNAL: backend error, please retry" >&2
          return 1 ;;
      esac
      return 0
    }
    eval "$FN"
    log_metric_denied=""
    ensure_log_metric ci_egress_denied "a description" 'some="filter"'
    # Reached only if the function returned without ending the script.
    printf 'REACHED_POLICY_LOOP\n'
    printf 'DENIED=[%s]\n' "$(printf '%s' "$log_metric_denied" | tr '\n' ',')"
  ) 2>"$tmpd/stderr.txt"
}

# ── denied: the regression case ──────────────────────────────────────────────
out="$(run_case denied)"; rc=$?
err="$(cat "$tmpd/stderr.txt")"

if [ "$rc" = "0" ]; then
  ok "a denied log metric leaves the script running"
else
  bad "a denied log metric ended the script (rc=$rc) — all fourteen policies would be skipped"
fi

case "$out" in
  *REACHED_POLICY_LOOP*) ok "execution continues to the policy loop" ;;
  *) bad "execution never reached the policy loop; got: $out" ;;
esac

case "$out" in
  *'DENIED=[ci_egress_denied,]'*) ok "the denied metric is recorded for the summary" ;;
  *) bad "the denied metric was not recorded; got: $out" ;;
esac

case "$err" in
  *ciRunnerApplyLogMetrics*) ok "the operator is told which role is missing" ;;
  *) bad "stderr does not name the ciRunnerApplyLogMetrics custom role; got: $err" ;;
esac

# Each arm must print ITS remediation and not the others'. Without this, a
# function that prints every hint for every error satisfies each arm's positive
# assertion while giving an operator a menu to guess from — which is the state
# this replaced.
case "$err" in
  *"could not READ it"*) bad "a plain denial also printed the ALREADY_EXISTS explanation" ;;
  *) ok "a denial does not print the ALREADY_EXISTS explanation" ;;
esac

# The underlying API error must survive, not be swallowed by our own message.
case "$err" in
  *GCLOUD_STDERR_SENTINEL_7f3a*) ok "the underlying API error is surfaced" ;;
  *) bad "the API error was swallowed; got: $err" ;;
esac

# ── already_exists: IAM wearing a different error code ───────────────────────
#
# The create path's IAM symptom. `describe` is silent on failure, so an account
# holding `create` but not `get` fails the probe, creates against an existing
# metric, and is refused ALREADY_EXISTS forever. An operator told that is "not
# a permission problem" goes hunting the log filter for a grant.
out="$(run_case already_exists)"; rc=$?
err="$(cat "$tmpd/stderr.txt")"

if [ "$rc" = "0" ]; then
  ok "an ALREADY_EXISTS metric leaves the script running"
else
  bad "an ALREADY_EXISTS metric ended the script (rc=$rc)"
fi

case "$err" in
  *"could not READ it"*) ok "ALREADY_EXISTS is explained as a missing read, not a create" ;;
  *) bad "ALREADY_EXISTS was not explained as an IAM read failure; got: $err" ;;
esac

case "$err" in
  *"NOT an IAM denial"*) bad "ALREADY_EXISTS was steered away from IAM — the one wrong answer here" ;;
  *) ok "ALREADY_EXISTS is not steered away from IAM" ;;
esac

# ── transient: the arm that must NOT send anyone to IAM ──────────────────────
out="$(run_case transient)"; rc=$?
err="$(cat "$tmpd/stderr.txt")"

if [ "$rc" = "0" ]; then
  ok "a transient API fault leaves the script running"
else
  bad "a transient API fault ended the script (rc=$rc)"
fi

case "$err" in
  *"NOT an IAM denial"*) ok "a non-permission error is not blamed on IAM" ;;
  *) bad "a transient error was not distinguished from a denial; got: $err" ;;
esac

# The specific waste this prevents: an operator auditing a role they already
# hold while a backend error clears itself on the next run.
case "$err" in
  *ciRunnerApplyLogMetrics*) bad "a transient error still told the operator to grant the role" ;;
  *) ok "a transient error does not name a role to grant" ;;
esac

# ── ok: the happy path must stay silent and record nothing ───────────────────
out="$(run_case ok)"; rc=$?

if [ "$rc" = "0" ]; then
  ok "a writable log metric succeeds"
else
  bad "the happy path failed (rc=$rc)"
fi

case "$out" in
  *'DENIED=[]'*) ok "nothing is recorded when the metric writes cleanly" ;;
  *) bad "the happy path recorded a denial; got: $out" ;;
esac

# ── the second contract: soft-failing must not become reporting success ──────
#
# Recording the denial is only half the fix. If nothing acts on the record, the
# run still exits 0 with every alert policy synced and one metric missing — the
# original bug with a friendlier log. The block below is what closes that, and
# it is lifted the same way the function is, so the two cannot drift.
BLOCK="$(sed -n '/^# A denied log metric with nothing deferred/,/^fi$/p' "$SRC")"
if [ -z "$BLOCK" ]; then
  echo "FAIL: the denied-metric exit block was not found in ensure-alert-policies.sh"
  exit 1
fi

blockrc() { # <log_metric_denied value> -> rc
  (
    set -euo pipefail
    # Read by the lifted block through `eval`, which shellcheck cannot follow.
    # shellcheck disable=SC2034
    PROJECT=testproject
    log_metric_denied="$1"
    eval "$BLOCK"
  ) >/dev/null 2>&1
}

if blockrc "ci_egress_denied"$'\n'; then
  bad "a denied metric with no deferred policy exited 0 — the run reports success while an alert is missing"
else
  ok "a denial with nothing deferred still fails the run"
fi

if blockrc ""; then
  ok "a clean run is not failed by the denial block"
else
  bad "the denial block failed a run that denied nothing"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
