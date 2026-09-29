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
# GitHub's `busy` flag has a window — an agent can die leaving a worker behind.
# On Windows the controller therefore also asks the host whether a worker
# process remains. There is no sshd and no pgrep, so the host publishes the
# count OUTBOUND into its own guest attributes and the controller reads it
# through the compute API it already calls. (Linux hosts used to be asked over
# `gcloud compute ssh --tunnel-through-iap`; that probe could not log in and
# was removed in #930 — a Linux host's idle proof is the roster alone.)
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
#                 <registrations> <misses> <required_misses> <policy_denied>
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
#   policy_denied   : 1 when read_status is non-zero BECAUSE the org policy
#                     constraints/compute.disableGuestAttributesAccess refused
#                     it. Not "the read failed" — "there is no beacon on this
#                     project and there never will be". The caller establishes
#                     this by matching the constraint id in gcloud's own stderr,
#                     text no job can write, so it is not a lever a host can
#                     pull on the controller.
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
  local policy_denied="${12:-0}"

  # 1. The mechanism itself failed: API error, timeout, permission, quota. Guest
  #    attributes are rate-limited to 10 queries per minute per instance, so a
  #    controller that read every host every tick would manufacture exactly this
  #    case at scale. Treating it as idleness would delete hosts because the
  #    fleet got busy, which is the worst possible correlation.
  #
  #    A POLICY REFUSAL IS NOT THAT FAILURE, AND READING IT AS ONE MADE 2c
  #    UNREACHABLE
  #
  #    Every reason above is transient and load-correlated. The org policy that
  #    turns guest attributes off is neither: it is a standing fact about the
  #    project, it refuses every read equally, and it will still refuse the next
  #    one. So the beacon does not exist, will never exist, and "we could not
  #    read it this time" is the wrong sentence about it.
  #
  #    Read as an ordinary failure it shadows the whole of rule 2 -- including
  #    2c, whose comment says in as many words what it is there to prevent: a
  #    permanent, billing, invisible resident of a pool that reports the right
  #    number of hosts. Measured in production 2026-09-05 on a Windows pool in a
  #    project that enforces the constraint: ci_guest_attributes_denied
  #    published on every tick for hours while a host that had denied its own
  #    boot and registered nothing sat RUNNING and undeletable -- drain_decision
  #    saying `drain:never-registered`, drain_host aborting on this rule every
  #    time, and ci_host_idle_seconds_max climbing past 21000 on a pool whose
  #    only host was dead. Six days old, and nothing in the fleet could take it.
  #
  #    Falling through does NOT weaken the gate. `present` is 0 whenever the
  #    read failed, so this lands in rule 2 and nowhere else: a host still
  #    booting keeps at 2a, a host GitHub knows has agents keeps at 2b, and only
  #    2c -- no beacon possible, no agent in GitHub's list, past the grace, and
  #    confirmed over ticks -- can delete. The affirmative `delete:idle` at 3d
  #    stays out of reach, because it needs a beacon this project cannot have.
  #
  #    The same misreading vetoed every drain and every recycle in the fleet
  #    through the pin-hold gate until 2026-08-24. This is the beacon half of
  #    that fix, and it was left behind because a veto that KEEPS a host looks
  #    safe from every angle except the one where the host is already dead.
  if [ "$read_status" != "0" ] && [ "$policy_denied" != "1" ]; then
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

# guest_attributes_namespace_absent <stderr-text> <namespace> -> 0 when the
# read failed ONLY because the namespace itself does not exist on the instance,
# 1 for every other outcome.
#
# Here rather than in its own file because both gates that need it -- the
# beacon's and the pin hold's -- run on every controller, this file is
# concatenated ahead of pin-hold-decision.sh on every one of them, and the
# end-to-end drain harness already loads it.
#
# WHY A 404 CAN BE A SUCCESSFUL READ (#1384)
#
# Both gates read the whole `<namespace>/` in one call. Asked for a namespace
# nothing has EVER written into, the compute API does not answer with an empty
# list -- it answers 404. Verbatim from a live pool host on 2026-09-29:
#
#   ERROR: (gcloud.compute.instances.get-guest-attributes) HTTPError 404: The
#   resource 'ci/' of type 'Guest Attribute' was not found.
#
# A host built from a template that predates the publisher has no `ci/`
# namespace at all. Read as "we did not get an answer", that made every pin
# hold on those hosts `hold:... read-failed`, vetoed every drain AND every
# recycle -- and since the recycle is the only thing that would have replaced
# the host with one that publishes, it did so permanently. Three pools sat idle
# and full for hours with `ci_pin_holds_honoured` equal to their host count. A
# namespace that does not exist holds no key, so there is no hold and no beacon
# behind this failure: it is the same fact as a read that succeeded and
# returned no rows, and the callers treat it exactly so.
#
# NARROW ON PURPOSE. Only the guest-attribute resource type, and only the
# namespace the caller asked for. The neighbouring 404s are NOT this:
#
#   * a missing INSTANCE -- "The resource 'projects/p/zones/z/instances/h' was
#     not found" -- names no guest attribute and stays a read failure; and
#   * a missing KEY, or some other namespace, names a different resource and
#     stays a read failure.
#
# The text can only come from gcloud on the controller -- the resource name in
# it is the query path the CONTROLLER sent, not anything a job wrote -- so this
# is not a lever job code can pull to talk the controller out of a veto.
# Line-wrapped and CRLF output is normalised, and `LC_ALL=C` for the reason
# guest_attributes_denied gives. An empty namespace, or one carrying anything
# but [A-Za-z0-9_-], is refused outright: an empty one would match the bare
# `'/'` resource, and the rule should never have to reason about a quote or a
# slash inside the name it is matching. Pure: no I/O, no globals.
guest_attributes_namespace_absent() {
  local text="${1:-}" ns="${2:-}"
  [ -n "$ns" ] || return 1
  case "$ns" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  text=$(printf '%s' "$text" | LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C tr -s ' ')
  case "$text" in
    *"HTTPError 404: The resource '$ns/' of type 'Guest Attribute' was not found"*) return 0 ;;
    *) return 1 ;;
  esac
}

# event_throttle_decision <previous "class epoch"> <class> <now> <interval>
#   -> "emit" or "quiet"
#
# WHY THE GATES' EVENTS ARE RATE-LIMITED. A veto, or a read that keeps failing,
# is re-decided on EVERY tick for EVERY host it affects. Sent as an event each
# time, a healthy two-hour pin hold alone is hundreds of entries per host, and a
# fleet-wide 429 or API outage is one per host per tick -- all competing for
# flush_events' 500-entry batch with the drain and cordon events that matter.
#
# So an event is sent when the CLASS of the answer changes (a hold that goes
# from `live published` to `read-failed` is news; the same hold seen again is
# not), and otherwise once per <interval> as a heartbeat, so a state that never
# changes -- which is exactly the #1384 failure -- is still visible in the log
# for as long as it lasts.
#
# The class is the caller's, and must not carry anything that moves every tick
# (an expiry, a remaining-seconds count), or every tick is a change. Anything
# the caller cannot vouch for -- no record, a malformed one, a clock that went
# backwards -- emits: a duplicate line is cheap, a silent state is what this
# replaced. Pure: no I/O, no globals.
event_throttle_decision() {
  local prev="${1:-}" class="${2:-}" now="${3:-}" interval="${4:-600}"
  local p_class p_at
  case "$now" in '' | *[!0-9]*) echo emit; return 0 ;; esac
  case "$interval" in '' | *[!0-9]*) interval=600 ;; esac
  p_class=${prev%% *}
  p_at=${prev#* }
  if [ -z "$prev" ] || [ "$p_at" = "$prev" ]; then echo emit; return 0; fi
  case "$p_at" in '' | *[!0-9]*) echo emit; return 0 ;; esac
  if [ "$p_class" != "$class" ]; then echo emit; return 0; fi
  if [ "$p_at" -gt "$now" ] || [ "$now" -ge "$((p_at + interval))" ]; then
    echo emit
    return 0
  fi
  echo quiet
}

# pin_hold_class <pin_hold_decision verdict> -> "<class> <severity>"
#
# The veto event's class and severity. A LIVE hold is the mechanism working --
# a pull request between tiers keeping its host -- and is INFO. Everything else
# that vetoes is a hold the controller could not verify, and is WARNING: the
# read failed, the host had no zone to read from, or the publisher wrote
# garbage. Only the reason word is used, never the run or expiry, for the
# reason event_throttle_decision gives. Pure.
pin_hold_class() {
  case "${1:-}" in
    *" live published"*) echo "live-published INFO" ;;
    *" live cached"*) echo "live-cached INFO" ;;
    *" read-failed"*) echo "read-failed WARNING" ;;
    *" no-zone"*) echo "no-zone WARNING" ;;
    *" malformed-hold"*) echo "malformed-hold WARNING" ;;
    *) echo "other WARNING" ;;
  esac
}
