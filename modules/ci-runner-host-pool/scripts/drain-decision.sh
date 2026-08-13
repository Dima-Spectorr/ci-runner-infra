#!/usr/bin/env bash
# ci-runner-host-pool — the controller's drain decision, as a PURE function.
#
# WHY THIS FILE EXISTS
#
# A warm container host carries K concurrent jobs, not one. That single fact
# invalidates the scale-in model every pool in this fleet grew up with:
#
#   * one-VM-per-job could tolerate a MIG scale-in picking an arbitrary victim,
#     because the blast radius was one job and GitHub re-queues it. With K jobs
#     on a host the blast radius is K, and it is no longer tolerable.
#   * one-VM-per-job could delegate scale-down to the VM self-deleting after
#     its single job. A host that serves many jobs has no such moment.
#
# So the autoscaler is pinned to ONLY_UP (it may add hosts, never choose a
# victim) and the CONTROLLER owns every deletion. This file is the judgement
# half of that: given already-observed facts about one host, decide whether it
# may be drained. The caller owns all I/O — GitHub, gcloud, the metadata server
# — so this rule can be exercised by scripts/ci/drain-decision.selftest.sh
# instead of only in production.
#
# The one-VM-per-job predecessor of this rule (IntegrateIT reap-decision.sh)
# shipped INVERTED once: an online-but-idle runner was read as "still working"
# and therefore never reaped, which pinned a MIG at max_runners. A rule that
# cannot be tested is a rule that ships wrong.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# drain_decision <instance_status> <busy_slots> <idle_seconds> <grace_seconds> \
#                <pool_size> <min_hosts> <registration_state> \
#                [age_seconds] [register_grace_seconds]
#
#   instance_status     : GCE instanceStatus (RUNNING, TERMINATED, ...).
#   busy_slots          : how many of this host's K runner agents are executing
#                         a job right now, per the GitHub API.
#   idle_seconds        : how long busy_slots has been 0. Meaningless when
#                         busy_slots > 0; pass 0 there.
#   grace_seconds       : how long a host may sit at 0 busy slots before it is
#                         drain-eligible. THIS is the pool's drain latency --
#                         not a job TTL. Keeping it comfortably above a typical
#                         gap between pushes is what makes the host still warm
#                         for the next run.
#   pool_size           : RUNNING hosts in the MIG right now.
#   min_hosts           : the configured floor (warm floor, or 0).
#   registration_state  : the host's agents as GitHub sees them --
#                           present  = K agents registered and reachable
#                           partial  = some agents registered, some missing
#                           absent   = no agents registered at all
#                           unknown  = could not be determined (API/token failure)
#   age_seconds         : how long the controller has known this host. A host
#                         boots, installs nothing (golden image) but still has
#                         to fetch a registration token and config K agents, so
#                         it reads absent for MINUTES while being perfectly
#                         healthy. Default 0 keeps old callers honest: with no
#                         age they get the pre-boot-grace behaviour.
#   register_grace_seconds : how long absent is allowed to mean "still booting".
#
# Echoes "drain:<reason>" or "keep:<reason>". Always exits 0 -- the verdict is
# the output, not the status, so a `set -e` caller cannot be tripped by a keep.
drain_decision() {
  local status="${1:-}"
  local busy="${2:-0}"
  local idle="${3:-0}"
  local grace="${4:-600}"
  local pool="${5:-0}"
  local floor="${6:-0}"
  local reg="${7:-unknown}"
  local age="${8:-0}"
  local reg_grace="${9:-0}"

  # 1. A host in a terminal power state can hold no job. Delete unconditionally.
  #    This is the path that reclaims a host that crashed or was stopped out of
  #    band; it has no compute permission to remove itself from the MIG.
  case "$status" in
    STOPPING | TERMINATED | SUSPENDED | STOPPED)
      echo "drain:terminal-state=$status"
      return 0
      ;;
  esac

  # 2. Indeterminate registration fails SAFE. If GitHub could not be asked we
  #    cannot prove the host is idle, and draining a working host costs K jobs
  #    while sparing an idle one costs one host for one more cycle.
  if [ "$reg" = "unknown" ]; then
    echo "keep:registration-unknown"
    return 0
  fi

  # 3. Any busy slot protects the whole host, without an upper bound. A
  #    genuinely long job is never interrupted, however long it runs.
  #
  #    Unbounded protection is reserved for OBSERVED busy slots precisely
  #    because anything unbounded that a DEAD host can enter recreates the
  #    immortal-VM bug. A host whose agents have vanished from GitHub
  #    (reg=absent) reports busy=0 and is therefore drainable below.
  if [ "$busy" -gt 0 ]; then
    echo "keep:busy-slots=$busy"
    return 0
  fi

  # 4. Never drain below the floor. The autoscaler would immediately recreate
  #    whatever we delete at the floor, so draining there is pure churn -- and
  #    a warm floor exists precisely so the next job finds a hot host.
  if [ "$pool" -le "$floor" ]; then
    echo "keep:at-floor pool=$pool<=min=$floor"
    return 0
  fi

  # 5. A host with NO agents registered never joined the pool (failed boot,
  #    bad token, image regression). It cannot receive work and it cannot
  #    self-heal, so it is drained rather than kept for the idle grace window --
  #    waiting only bills for a host that will never be useful.
  #
  #    But "absent" is ALSO what a perfectly healthy host reads while it is
  #    still booting: it fetches a registration token and runs config.sh K
  #    times before the first agent appears. Draining on that read is not a
  #    slow scale-in, it is a churn loop that never lets the pool reach usable
  #    capacity -- and it is fatal, not merely wasteful, at the moment the
  #    agents come up between the verdict and the delete: the host takes jobs
  #    and is then deleted under them. Observed on the DataRetrival pool
  #    2026-08-13T19:00-19:06Z: six hosts created and shot as never-registered
  #    in six minutes, one of them (wz1f) one second after it picked up a job,
  #    which died with "The runner has received a shutdown signal".
  #
  #    So absent only means dead once the host has had time to register.
  if [ "$reg" = "absent" ]; then
    if [ "$age" -lt "$reg_grace" ]; then
      echo "keep:booting age=${age}s<${reg_grace}s reg=absent"
      return 0
    fi
    echo "drain:never-registered age=${age}s>=${reg_grace}s"
    return 0
  fi

  # 6. Idle, but not yet past the grace window: keep it WARM. This is the
  #    branch that delivers "no boot time between CI runs" -- the host stays up
  #    across a push, its review round, and a merge-queue retry.
  if [ "$idle" -lt "$grace" ]; then
    echo "keep:warm idle=${idle}s<${grace}s"
    return 0
  fi

  # 7. Idle past the grace window and above the floor. Drain it.
  #    `partial` registration lands here too: some agents are missing, the rest
  #    hold no job, so the host is degraded capacity we are paying for.
  #
  #    The CALLER must now make the host ineligible before deleting it:
  #    deregister each agent via the GitHub API (which REFUSES to remove an
  #    agent that is executing a job -- the mid-job guard), verify no
  #    Runner.Worker remains, and only then delete the instance. This verdict
  #    authorises that sequence; it does not authorise a bare delete.
  echo "drain:idle-past-grace idle=${idle}s>=${grace}s reg=$reg pool=$pool>min=$floor"
  return 0
}
