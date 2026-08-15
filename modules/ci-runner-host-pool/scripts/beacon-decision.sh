#!/usr/bin/env bash
# ci-runner-host-pool — the controller's WINDOWS LIVENESS rule, as a PURE
# function.
#
# WHY THIS FILE EXISTS
#
# Before the controller deletes a host, two gates must pass. The first is
# GitHub's: drain_host() deregisters every agent on the host, and GitHub REFUSES
# to remove an agent that is executing a job. That refusal is issued from
# outside the host, is unforgeable from inside it, and does not care what OS the
# host runs.
#
# The second gate exists because the first has a window — an agent can be
# deregistered while its worker is still winding down, and an agent can die
# leaving a worker behind. So the controller asks the host directly whether a
# worker process remains. On Linux it asks over `gcloud compute ssh
# --tunnel-through-iap` and reads `pgrep -fc Runner.Worker`. On Windows there is
# no sshd and no pgrep, so the host publishes the same count OUTBOUND into its
# own guest attributes and the controller reads it through the compute API it
# already calls:
#
#   ci/workers  = count of Runner.Worker.exe
#   ci/ts       = RFC3339 UTC time of that count
#   ci/boot     = RFC3339 UTC time of the boot script's first write
#
# The rule is separated from the I/O for the same reason drain-decision.sh and
# orphan-decision.sh are: the action it authorises is IRREVERSIBLE. A wrong
# `keep:` costs money. A wrong `delete:` costs somebody's merge-blocking job,
# and up to slots_per_host of them at once. So the predicate is tested off the
# box, on this repository's runners, before it is ever allowed near a machine.
#
# THE ONE INVARIANT
#
# In every degraded case the answer is `keep:`. A mechanism that breaks tells us
# nothing about the host, and "nothing" never authorises a deletion. There is
# exactly one row below that deletes without positive evidence of idleness, and
# it is confined to the case where positive evidence is IMPOSSIBLE because the
# host never became a runner at all.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# beacon_decision <read_status> <key_present> <workers> <ts_epoch> <now_epoch> \
#                 <publish_interval> <instance_age> <register_grace> \
#                 <registrations> <misses> <required_misses>
#
#   read_status     : exit status of the get-guest-attributes call. NON-ZERO IS
#                     NOT "no workers" — it is "we did not get an answer". This
#                     is the same distinction orphan_decision() draws between a
#                     failed list-instances and a pool genuinely at zero, and it
#                     is the single most important argument here.
#   key_present     : 1 if the read returned a value for ci/workers, 0 if the
#                     read SUCCEEDED and the key simply is not there.
#   workers         : the published count. Only meaningful when key_present=1.
#   ts_epoch        : ci/ts converted to epoch seconds by the caller. 0 means
#                     the caller could not parse it.
#   now_epoch       : the controller's clock.
#   publish_interval: seconds between the host's publishes. Staleness is 3x
#                     this, so one missed write and one slow tick are both
#                     survivable without a spurious keep.
#   instance_age    : seconds since the instance was created, per the MIG.
#   register_grace  : the same register_grace_seconds that stops the controller
#                     reading a booting host as a dead one.
#   registrations   : how many agents this host currently has in GitHub's list.
#   misses          : consecutive ticks this host has been seen beacon-less.
#   required_misses : how many such ticks are needed. The same
#                     orphan_confirm_ticks the reaper uses.
#
# Echoes "delete:<reason>" or "keep:<reason>". Always exits 0 — the verdict is
# the output, not the status, exactly like the other three rules.
beacon_decision() {
  local read_status="${1:-1}"
  local present="${2:-0}"
  local workers="${3:-}"
  local ts="${4:-0}"
  local now="${5:-0}"
  local interval="${6:-30}"
  local age="${7:-0}"
  local grace="${8:-0}"
  local regs="${9:-0}"
  local misses="${10:-0}"
  local need="${11:-2}"

  # 1. The mechanism itself failed: API error, timeout, permission, quota. Guest
  #    attributes are rate-limited to 10 queries per minute per instance, so a
  #    controller that read every host every tick would manufacture exactly this
  #    case at scale. Treating it as idleness would delete hosts because the
  #    fleet got busy, which is the worst possible correlation.
  if [ "$read_status" != "0" ]; then
    echo "keep:read-failed status=$read_status"
    return 0
  fi

  # 2. The read succeeded and there is no beacon. Everything in this branch is
  #    about telling "not yet" apart from "never".
  if [ "$present" != "1" ]; then
    # 2a. Still booting. A Windows host takes minutes to reach its first write,
    #     and the grace is the same floor the rest of the controller uses.
    if [ "$age" -lt "$grace" ]; then
      echo "keep:booting age=$age<$grace"
      return 0
    fi

    # 2b. GitHub says this host has agents, but the host publishes no beacon.
    #     Then the boot script DID run far enough to register, and the publisher
    #     is what is broken — so a worker can exist and we cannot see it. This
    #     row is the reason the rule takes the registration count at all: it is
    #     what keeps 2c confined to hosts that never became runners.
    if [ "$regs" -gt 0 ]; then
      echo "keep:registered-without-beacon regs=$regs age=$age"
      return 0
    fi

    # 2c. Old enough, no beacon, and no agent in GitHub's list. The boot script
    #     never got far enough to install a runner, so no worker can exist on
    #     this host — not "probably none", none. Without this row such a host is
    #     undeletable forever: a permanent, billing, invisible resident of a pool
    #     that reports the right number of hosts.
    #
    #     Confirmed across ticks anyway, because the inputs that got us here
    #     (a runner list, an instance list) are the same ones whose transient
    #     failure orphan_decision() already refuses to act on once.
    if [ "$misses" -lt "$need" ]; then
      echo "keep:unconfirmed misses=$misses<$need age=$age"
      return 0
    fi

    echo "delete:never-booted age=$age>=$grace misses=$misses>=$need"
    return 0
  fi

  # 3. A beacon exists. Anything malformed in it is a broken publisher, not an
  #    idle host. The count is validated before it is compared, because in bash
  #    an unquoted comparison against a non-numeric value is a syntax error at
  #    best and a wrong answer at worst — and the wrong answer here deletes a
  #    machine.
  if ! [[ "$workers" =~ ^[0-9]+$ ]]; then
    echo "keep:unparseable-workers value=$workers"
    return 0
  fi
  if ! [[ "$ts" =~ ^[0-9]+$ ]] || [ "$ts" -le 0 ]; then
    echo "keep:unparseable-timestamp value=$ts"
    return 0
  fi

  # 3a. A timestamp from the future cannot be aged, and it is the one value that
  #     would make a dead publisher look permanently fresh. Guest attributes are
  #     writable by any process on the VM including job code (Google documents
  #     this plainly), so a future ts is reachable by accident from clock skew
  #     and on purpose from a build. Either way the honest answer is that we
  #     cannot date this reading. One interval of slack absorbs ordinary skew.
  if [ "$ts" -gt "$((now + interval))" ]; then
    echo "keep:timestamp-in-future ts=$ts now=$now"
    return 0
  fi

  # 3b. Stale. The publisher died; the host may be perfectly busy, and we no
  #     longer know. Three intervals, so a single missed write does not stall a
  #     drain and a genuinely dead publisher is still caught within 90 seconds
  #     at the default rate.
  local max_age=$((interval * 3))
  local beacon_age=$((now - ts))
  if [ "$beacon_age" -gt "$max_age" ]; then
    echo "keep:stale-beacon age=${beacon_age}s>${max_age}s"
    return 0
  fi

  # 3c. A worker is alive.
  if [ "$workers" -gt 0 ]; then
    echo "keep:workers=$workers"
    return 0
  fi

  # 3d. The only affirmative case in the whole rule: the read worked, the beacon
  #     is present, it is fresh, and it says zero.
  echo "delete:idle workers=0 beacon_age=${beacon_age}s"
  return 0
}
