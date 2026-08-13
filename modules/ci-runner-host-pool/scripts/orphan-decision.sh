#!/usr/bin/env bash
# ci-runner-host-pool — the controller's ORPHAN-REGISTRATION rule, as a PURE
# function.
#
# WHY THIS FILE EXISTS
#
# drain_host() deregisters a host's K agents before deleting the instance, so
# the controller's OWN scale-in leaves no registration behind. Every other way a
# host can disappear does:
#
#   * `instance-groups managed delete-instances` run by an operator (how the
#     whole fleet was recycled onto a new golden image on 2026-08-13);
#   * a MIG recreate/rolling update, or an instance lost to host maintenance;
#   * the controller crashing between the deregister loop and the delete, or
#     being replaced by a new controller mid-drain.
#
# Nothing reclaimed those, so the registrations accreted: 69 offline agents
# across six repos on 2026-08-13, up to 24 in one repo. They are not cosmetic.
# GitHub caps self-hosted runners per repo, `gh api .../actions/runners` is the
# controller's own view of the pool (collect_runners reads ONE page of 100), and
# a job whose labels match only dead agents queues against capacity that does
# not exist.
#
# The rule is separated from the I/O for the same reason drain-decision.sh is:
# the deletion it authorises is irreversible for a LIVE host — deregistering an
# agent that is serving jobs silently removes that slot from the pool until the
# host is rebuilt — so the predicate has to be testable off the box.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# orphan_decision <runner_name> <runner_status> <runner_busy> <base_instance_name> \
#                 <live_hosts_csv> <misses> <required_misses>
#
#   runner_name         : the GitHub agent's name. host-startup.sh names slots
#                         "<instance>-s<N>"; that naming IS the join key back to
#                         GCE, and a name that does not match it is NOT ours.
#   runner_status       : "online" | "offline" per the GitHub API.
#   runner_busy         : 1 if GitHub says the agent is executing a job.
#   base_instance_name  : the MIG's baseInstanceName. Every instance this pool
#                         can create is "<base>-<suffix>", so it bounds the
#                         reaper to this pool's own agents even when a repo is
#                         served by several pools (linux + windows) or still
#                         carries a retired pool's registrations.
#   live_hosts_csv      : comma-separated instance names the MIG reports NOW.
#   misses              : how many consecutive ticks this name has already been
#                         seen offline-and-hostless.
#   required_misses     : how many such ticks are needed before reaping.
#
# Echoes "reap:<reason>" or "keep:<reason>". Always exits 0 — the verdict is the
# output, not the status.
orphan_decision() {
  local name="${1:-}"
  local status="${2:-}"
  local busy="${3:-0}"
  local base="${4:-}"
  local live="${5:-}"
  local misses="${6:-0}"
  local need="${7:-2}"

  # 1. Not one of ours. A repo's runner list also holds the windows pool, other
  #    products' pools, and whatever a retired pool left behind. Reaping by
  #    "looks offline" instead of "is mine" would delete another pool's agents.
  #    An empty base is checked FIRST: it would otherwise degrade the prefix
  #    test to "-*" and make the reaper unbounded.
  if [ -z "$base" ]; then
    echo "keep:no-base-instance-name"
    return 0
  fi
  case "$name" in
    "$base"-*) ;;
    *)
      echo "keep:not-this-pool name=$name base=$base"
      return 0
      ;;
  esac

  local host="${name%-s*}"
  if [ "$host" = "$name" ]; then
    echo "keep:not-a-slot-name name=$name"
    return 0
  fi

  # 2. A busy or online agent is a live host, whatever the MIG list said. This
  #    is the guard against reaping a pool that gcloud momentarily under-reports
  #    — deregistering an agent mid-job kills that job.
  if [ "$busy" != "0" ]; then
    echo "keep:busy name=$name"
    return 0
  fi
  if [ "$status" != "offline" ]; then
    echo "keep:status=$status"
    return 0
  fi

  # 3. The host still exists. Then this is a booting slot, a restarting agent,
  #    or a partially-registered host — all of which drain_decision owns. The
  #    reaper only ever touches registrations with NO instance behind them.
  case ",$live," in
    *",$host,"*)
      echo "keep:host-alive host=$host"
      return 0
      ;;
  esac

  # 4. Confirm across ticks. `collect_hosts` failing returns an EMPTY host list,
  #    which is indistinguishable from a pool genuinely at zero — and at zero,
  #    reaping is exactly right. Requiring N consecutive misses means a single
  #    failed gcloud call cannot deregister a live fleet, while a truly dead
  #    host is still reclaimed within N ticks.
  if [ "$misses" -lt "$need" ]; then
    echo "keep:unconfirmed misses=$misses<$need host=$host"
    return 0
  fi

  echo "reap:no-instance host=$host misses=$misses>=$need"
  return 0
}
