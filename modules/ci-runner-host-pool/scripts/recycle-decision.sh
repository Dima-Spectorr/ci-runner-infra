#!/usr/bin/env bash
# ci-runner-host-pool — when a host on a STALE instance template may be retired,
# as a PURE function.
#
# WHY THIS FILE EXISTS
#
# `terraform apply` moves the definition of a host. It does not move a host.
# The MIG's update_policy is OPPORTUNISTIC on purpose — PROACTIVE would delete
# hosts to apply a new template, and an arbitrary victim here carries up to
# `slots_per_host` running jobs. So a new template sits there, and hosts adopt
# it only when something else happens to delete them.
#
# That "something else" was drain_decision(), which knows nothing about
# templates: it retires a host for being IDLE past the grace window. A pool with
# work never goes idle for fifteen minutes, so it can run the old startup script
# indefinitely. Measured on 2026-08-15: v5.7.0 — the release that stops a job
# inheriting the previous job's cloud credentials — was applied to the
# IntegrateIT pool, and five hosts created the previous day kept serving jobs
# from the old template afterwards. The apply reported success. It was true and
# it was not the question anybody was asking.
#
# THE RULE, and why it is not "delete stale hosts"
#
# A host may not be interrupted, so the retirement is two-phase — cordon, then
# retire — and the phases are ticks apart:
#
#   CORDON   deregister the host's IDLE agents. GitHub REFUSES to deregister an
#            agent that is executing a job (422), and that refusal is the
#            mid-job guard: the working slot survives, its job runs to
#            completion, and no new job can ever reach this host again because
#            every other slot is gone from the pool. Agents here are not
#            --ephemeral and their unit is Restart=no, so a deregistered slot
#            stays deregistered.
#   RETIRE   once the last job lands and busy reaches 0, hand the host to
#            drain_host() — deregister the remainder, verify no Runner.Worker
#            survives, delete.
#
# Nothing is killed. The host simply stops accepting work and leaves when it is
# empty.
#
# ROLLING, NOT ALL AT ONCE. Cordoning is not free: a cordoned host's idle slots
# leave the pool immediately, so cordoning every stale host at once removes the
# fleet's whole spare capacity in one tick and every queued job waits for a
# boot. `max_unavailable` bounds how many hosts may be mid-recycle at a time —
# and 0 disables the whole mechanism, which is the kill switch a rule that
# deletes machines has to have.
#
# The caller owns all I/O — GitHub, gcloud, the metadata server — so this rule
# is exercised by scripts/ci/recycle-decision.selftest.sh instead of only in
# production.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# recycle_decision <instance_status> <template_state> <busy_slots> \
#                  <registration_state> <age_seconds> <register_grace_seconds> \
#                  <in_flight> <max_unavailable> <already_cordoned>
#
#   instance_status     : GCE instanceStatus. Only RUNNING is recycled; every
#                         other state is drain_decision's business, and it
#                         deletes those unconditionally already.
#   template_state      : this host's instance template against the MIG's
#                         current one --
#                           current = the host is already what the MIG builds
#                           stale   = an apply has moved on without it
#                           unknown = could not be determined
#   busy_slots          : how many of this host's K agents are executing a job.
#   registration_state  : present | partial | absent | unknown, as
#                         drain_decision defines them.
#   age_seconds         : how long the controller has known this host.
#   register_grace_seconds : how long `absent` is allowed to mean "still
#                         booting".
#   in_flight           : hosts already mid-recycle (cordoned, not yet gone).
#   max_unavailable     : how many may be mid-recycle at once. 0 = disabled.
#   already_cordoned    : 1 if THIS host is one of the in_flight ones.
#
# Echoes "cordon:<reason>", "retire:<reason>" or "skip:<reason>". Always exits 0
# -- the verdict is the output, not the status, so a `set -e` caller cannot be
# tripped by a skip.
recycle_decision() {
  local status="${1:-}"
  local template="${2:-unknown}"
  local busy="${3:-0}"
  local reg="${4:-unknown}"
  local age="${5:-0}"
  local reg_grace="${6:-0}"
  local in_flight="${7:-0}"
  local max_unavail="${8:-0}"
  local cordoned="${9:-0}"

  # 0. Off. A mechanism that deletes machines on a schedule nobody triggered
  #    needs a switch that stops it without a rollback, and this is it.
  if [ "$max_unavail" -le 0 ]; then
    echo "skip:disabled"
    return 0
  fi

  # 1. Only a RUNNING host. A TERMINATED or SUSPENDED one is already
  #    drain_decision's unconditional delete; recycling it too would race that
  #    path for the same instance in the same tick.
  if [ "$status" != "RUNNING" ]; then
    echo "skip:not-running status=$status"
    return 0
  fi

  # 2. Indeterminate template fails SAFE, and this is the branch that matters
  #    most. `unknown` is what a gcloud hiccup, a quota error or a renamed field
  #    reads as — and treating that as "stale" would cordon EVERY host in the
  #    pool at once on a transient API failure. Recycling late costs one release
  #    cycle; recycling the whole fleet on a bad read costs the pool.
  if [ "$template" != "stale" ]; then
    echo "skip:template=$template"
    return 0
  fi

  # 3. Indeterminate registration fails safe for the same reason drain does: if
  #    GitHub could not be asked, `busy=0` is not evidence of an idle host, it
  #    is evidence of nothing. Cordoning on it would deregister working slots.
  if [ "$reg" = "unknown" ]; then
    echo "skip:registration-unknown"
    return 0
  fi

  # 4. A booting host reads absent and busy=0 — indistinguishable from an empty
  #    one ready to retire. Retiring it there is not a slow recycle, it is a
  #    churn loop: the MIG recreates from the current template, the replacement
  #    boots, reads absent, and is shot in turn. The pool never reaches usable
  #    capacity while reporting healthy recycling the whole time.
  #
  #    A host young enough to still be booting is also, by construction, a host
  #    the MIG built from a template it had recently — so there is nothing to
  #    gain by rushing it.
  if [ "$age" -lt "$reg_grace" ]; then
    echo "skip:booting age=${age}s<${reg_grace}s"
    return 0
  fi

  # 5. Budget. Checked AFTER the safety rules and BEFORE the action, and skipped
  #    entirely for a host already mid-recycle: it is already counted in
  #    in_flight, and refusing to finish what we started would leave a cordoned
  #    host — one with no idle slots and no way back — parked forever.
  if [ "$cordoned" != "1" ] && [ "$in_flight" -ge "$max_unavail" ]; then
    echo "skip:at-capacity in-flight=$in_flight>=max=$max_unavail"
    return 0
  fi

  # 6. Still working. Cordon it — deregister the idle slots so no new job can
  #    reach this host, and leave the busy ones alone; GitHub refuses those
  #    anyway, and that refusal is the guarantee that nothing running is
  #    interrupted. Re-issued every tick on purpose: it is idempotent, and a
  #    slot whose deregistration failed once must not be the reason a host takes
  #    another job.
  if [ "$busy" -gt 0 ]; then
    echo "cordon:stale-template busy=$busy"
    return 0
  fi

  # 7. Empty. Retire it.
  #
  #    Deliberately NOT subject to the idle grace window that drain_decision
  #    applies: that window exists to keep a host WARM for the next job, and
  #    keeping this one warm keeps the wrong startup script warm with it. Nor to
  #    the min_hosts floor — the autoscaler is ONLY_UP with min_replicas =
  #    min_hosts, so it restores the floor from the CURRENT template, which is
  #    the entire point. Draining at the floor here is not churn, it is the
  #    replacement.
  #
  #    The CALLER must still run the full drain sequence — deregister, verify no
  #    Runner.Worker survives, then delete. This verdict authorises that
  #    sequence; it does not authorise a bare delete.
  echo "retire:stale-template reg=$reg cordoned=$cordoned"
  return 0
}
