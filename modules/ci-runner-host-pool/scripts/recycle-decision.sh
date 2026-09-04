#!/usr/bin/env bash
# ci-runner-host-pool — when a host that cannot be repaired in place may be
# retired, as a PURE function. Two conditions qualify: an instance template the
# apply has moved past, and registered capacity the host has lost and cannot get
# back. Both are answered with the same bounded cordon-then-retire sequence.
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
#                  <in_flight> <max_unavailable> <already_cordoned> \
#                  <partial_for_seconds>
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
#   partial_for_seconds : how long this host has read `partial` WITHOUT
#                         INTERRUPTION. 0 when it is not partial now, and 0 for
#                         a caller that does not track it -- which keeps this
#                         parameter's absence meaning "no capacity-lost recycle
#                         ever", the same way max_unavailable=0 does. Compared
#                         against max(register_grace, 960s); the floor is the
#                         slot sweep's own worst case, derived at rule 2.
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
  local partial_for="${10:-0}"

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

  # 2. WHY this host would be recycled. There are two reasons, and a host that
  #    has neither is left alone.
  #
  #    `stale-template` is the original: an apply moved the definition and this
  #    host did not move with it. Indeterminate template fails SAFE, and this is
  #    the branch that matters most — `unknown` is what a gcloud hiccup, a quota
  #    error or a renamed field reads as, and treating it as "stale" would
  #    cordon EVERY host in the pool at once on a transient API failure.
  #    Recycling late costs one release cycle; recycling the whole fleet on a
  #    bad read costs the pool.
  #
  #    `capacity-lost` is the second, and it is about capacity rather than code.
  #    drain_host() deregisters a host's agents one at a time and aborts the
  #    moment GitHub refuses one for executing a job — the 422 mid-job guard.
  #    That refusal protects the running job; it does not put back the agents
  #    already removed. Agents here are not --ephemeral and their unit is
  #    Restart=no, so a deregistered slot stays deregistered: the host goes on
  #    advertising slots that no longer exist, and cannot register them again
  #    without config.sh and a fresh token. The worker-gate arms of the same
  #    function are worse — they abort AFTER the whole loop, so every slot is
  #    gone.
  #
  #    Measured on the Telnet pool 2026-09-04: one slot of four lost at
  #    13:11:46Z to a drain aborted by a job that arrived in the same tick,
  #    still missing 55 minutes later, and recovered only because the host
  #    happened to go idle again and be drained for an unrelated reason. Nothing
  #    was going to repair it: drain_decision's idle-past-grace rule was the
  #    only path left, and on a pool sitting at its min_hosts floor — or one
  #    that never goes idle for the grace window — that path never fires.
  #
  #    HYSTERESIS, because `partial` is also a normal transient — and the window
  #    is NOT simply reg_grace. ci-slot-sweep stops a dirty slot's agent while it
  #    resets the workspace and starts it again, ordinarily inside about ninety
  #    seconds. Ordinarily is not the bound. Its unit carries TimeoutStartSec=900
  #    on a 30-second timer, deliberately generous so that one wedged docker call
  #    cannot stop every later sweep on the host — so a slot that is coming back
  #    can legitimately be missing for roughly 930 seconds, and the host reads
  #    `partial` for every one of them.
  #
  #    A recycle rule that fires inside that window RACES THE HOST'S OWN REPAIR
  #    and wins: the slot would have returned, and instead the pool cordons the
  #    host's remaining idle slots and deletes it. So the window is the larger of
  #    reg_grace — the same window that decides `absent` means dead, because it
  #    answers the same question — and the sweep's own worst case plus its timer
  #    interval. The floor is what keeps a pool that has lowered reg_grace for
  #    faster scale-in from quietly buying host churn with it.
  local window="$reg_grace"
  [ "$window" -lt 960 ] && window=960

  local reason=""
  if [ "$template" = "stale" ]; then
    reason="stale-template"
  elif [ "$reg" = "partial" ] && [ "$partial_for" -ge "$window" ]; then
    reason="capacity-lost"
  fi

  #    The two no-reason outcomes are reported apart, because they are not the
  #    same non-event. A host that is merely on a current template is the answer
  #    for every healthy host on every tick. A host reading `partial` INSIDE the
  #    hysteresis window is the mechanism watching something: either a sweep
  #    that is about to hand the slot back, or the first ticks of capacity that
  #    is gone for good. Collapsing the second into the first would publish the
  #    interesting case under the label of the boring one.
  if [ -z "$reason" ]; then
    if [ "$reg" = "partial" ]; then
      echo "skip:partial-grace partial_for=${partial_for}s<${window}s template=$template"
    else
      echo "skip:template=$template reg=$reg"
    fi
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
    echo "cordon:$reason busy=$busy"
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
  #    Both reasons want the same thing here. A stale host kept warm keeps the
  #    wrong startup script warm; a capacity-lost host kept warm keeps slots that
  #    do not exist in the pool's arithmetic, which is worse than being one host
  #    short — a job routes to capacity that cannot run it.
  #
  #    The CALLER must still run the full drain sequence — deregister, verify no
  #    Runner.Worker survives, then delete. This verdict authorises that
  #    sequence; it does not authorise a bare delete.
  echo "retire:$reason reg=$reg cordoned=$cordoned"
  return 0
}
