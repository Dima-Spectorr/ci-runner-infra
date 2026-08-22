#!/usr/bin/env bash
# ci-runner-host-pool — how the controller reads ONE queued or running job once
# host affinity exists, as a PURE function.
#
# WHY THIS FILE EXISTS
#
# collect_demand() answers one question — "how many jobs is this pool supposed
# to be running?" — and publishes it as `ci_demand`, which IS the autoscaler's
# input. Host affinity (docs/adr-pr-host-affinity.md) breaks that question into
# three, and getting any of them wrong is expensive in a different direction:
#
#   * A job pinned to `host-<instance>` carries a label this pool's agents DO
#     register but the pool's own label list does not contain, so the existing
#     subset test drops it. Left alone, every pinned job in the fleet becomes
#     invisible: demand reads low, the pool scales in under work it is actually
#     doing, and the drain rule is the only thing left standing between a warm
#     host and the jobs pinned to it.
#
#   * Counted naively, it is worse the other way. A pinned job cannot use a new
#     host — only the one named in its label can serve it — so feeding it to an
#     autoscaler whose whole vocabulary is "add a host" buys a machine that will
#     sit empty while the job keeps waiting, and buys another next tick.
#
#   * And a job pinned to a host that no longer exists can never run at all.
#     Nothing retries it, nothing scales for it, and because of the rule above
#     nothing even counts it: it waits out GitHub's 24-hour cancellation. That
#     is the unrecoverable-without-an-operator shape the ADR exists to avoid,
#     arriving through the door the ADR opened.
#
# So the rule is separated from the I/O for the same reason drain-decision.sh
# and orphan-decision.sh are. Two of its verdicts are irreversible in one
# direction — `orphan` cancels somebody's workflow run — and a predicate that
# can cancel a run has to be testable off the box.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# pinned_job_decision <job_status> <job_labels_csv> <pool_labels_csv> \
#                     <base_instance_name> <live_hosts_csv> <age> <grace>
#
#   job_status      : "queued" | "in_progress" per the GitHub API.
#   job_labels_csv  : the job's `runs-on`, comma-separated.
#   pool_labels_csv : ci-runner-labels — what this pool's agents register
#                     BEFORE the per-host affinity label is appended at boot.
#   base_instance_name : the MIG's baseInstanceName. Bounds every verdict that
#                     acts to hosts THIS pool can create; see rule 5.
#   live_hosts_csv  : instance names the MIG reports NOW (not labels — the
#                     "host-" prefix is added here so one caller cannot pass
#                     labels while another passes names).
#   age             : seconds this job has been queued.
#   grace           : seconds a pinned job may wait for a host the MIG has not
#                     reported yet before it is called orphaned.
#
# Echoes one of:
#   ignore:<reason>  not this pool's job; do not count it, do not act on it
#   demand:<reason>  unpinned and ours — count it, and let it ask for a host
#   pinned:<reason>  ours and pinned to a live host — count it as work in
#                    flight, but NOT as a reason to scale out
#   wait:<reason>    ours, pinned, host not in the MIG's list yet — inside the
#                    grace window, so say nothing and look again next tick
#   orphan:<reason>  ours, pinned, and unservable — fail the run
#
# Always exits 0: the verdict is the output, not the status.
pinned_job_decision() {
  local status="${1:-}"
  local job_labels="${2:-}"
  local pool_labels="${3:-}"
  local base="${4:-}"
  local live="${5:-}"
  local age="${6:-0}"
  local grace="${7:-300}"

  # 1. A job with no labels is a GitHub-hosted job. Not ours, and not a fault.
  [ -n "$job_labels" ] || { echo "ignore:job has no labels"; return 0; }

  # 1b. THE LABELS ARE UNTRUSTED. `runs-on` is authored in the pull request, so
  #     on a fork PR it is attacker-controlled text, and both membership tests
  #     below are `case` patterns — where `*` and `?` are wildcards, not
  #     characters. A label of `*` would match this pool's list whatever it
  #     contains, and a pin of `ci-lin-*` would match a live host it does not
  #     name. Neither reaches across tenants (a run can only be cancelled from
  #     its own job's verdict) but both make the classifier lie, so anything
  #     carrying pattern syntax is not classified at all. A real label cannot
  #     contain these: GitHub restricts runner labels to plain text.
  #
  #     The backslash is built from its octal code rather than written as a
  #     character: shellcheck reads a backslash sitting just inside a closing
  #     single quote as a botched attempt to escape that quote (SC1003) and
  #     fails the build over it -- in the pattern list and in a printf of a
  #     lone backslash alike. '\0134' keeps the backslash away from the quote,
  #     so there is nothing to misread. A quoted expansion in a `case` pattern
  #     is matched literally, which is what is wanted here in any event.
  local _bs
  _bs=$(printf '%b' '\0134')
  case "$job_labels" in
    *'*'* | *'?'* | *'['* | *']'* | *"$_bs"*)
      echo "ignore:labels contain pattern syntax"; return 0 ;;
  esac

  # 2. Split the affinity label out of the rest. A runner answers to exactly one
  #    host label, so more than one in `runs-on` is unsatisfiable BY CONSTRUCTION
  #    — see rule 6, which is the only place a workflow's own mistake is called
  #    one rather than blamed on the fleet.
  #
  #    Splitting is `${x//,/ }` and never `local IFS=,` — the latter reads
  #    correctly and is a trap: `unset` on a local unshadows the caller's value
  #    rather than restoring the default, and this function is called from a
  #    loop inside the controller's tick.
  #    A `host-*` label that this pool ALREADY REGISTERS is not an affinity pin
  #    — it is an ordinary pool label that happens to share the prefix, and
  #    `runner_labels` accepted such a label long before affinity existed. Read
  #    as a pin it is catastrophic in a quiet way: `host-large` would parse as a
  #    pin to an instance named `large`, no live host would answer it, and the
  #    controller would cancel a perfectly schedulable run — while also dropping
  #    it from scale-out demand, so nothing would even be built for it. The
  #    pool's own list is the authority on which of its labels are its own.
  #
  #    `variables.tf` now also refuses a `host-`-prefixed `runner_labels` entry
  #    outright, so a NEW pool cannot create this collision at all. This arm is
  #    what keeps an EXISTING one from being cancelled on the way to fixing it.
  local pins="" rest="" l
  for l in ${job_labels//,/ }; do
    case ",$pool_labels," in
      *",$l,"*) rest="${rest:+$rest,}$l"; continue ;;
    esac
    case "$l" in
      host-*) pins="${pins:+$pins,}$l" ;;
      *)      rest="${rest:+$rest,}$l" ;;
    esac
  done

  # 3. The superset rule, minus the affinity label. GitHub sends a job to any
  #    runner whose labels are a SUPERSET of `runs-on`, and this pool's agents
  #    register the pool list plus one host label — so the pool serves this job
  #    exactly when everything except the pin is in the pool list.
  #
  #    Membership is the comma-fenced `case` the orphan reaper uses, not a
  #    substring test: without the fences, a pool carrying `linux` would answer
  #    yes to a job asking for `linux-arm64`.
  local r
  for r in ${rest//,/ }; do
    case ",$pool_labels," in
      *",$r,"*) ;;
      *) echo "ignore:label $r is not this pool's"; return 0 ;;
    esac
  done

  # 4. Unpinned and ours: ordinary demand, and the only kind that may buy a
  #    host. Anchors land here, which is what keeps scale-out working at all.
  [ -n "$pins" ] || { echo "demand:unpinned"; return 0; }

  # 5. BOUNDED TO THIS POOL BEFORE ANYTHING IRREVERSIBLE HAPPENS, and this is
  #    the guard that matters most in a repo served by two pools. A Linux
  #    controller looking at a job pinned to a Windows instance must not read
  #    "that host is not in my MIG" as "that host is gone" and cancel somebody's
  #    run over a host it does not own and cannot see. Same join key the orphan
  #    reaper uses: every instance a pool can create is "<base>-<suffix>".
  local pin_host="${pins#host-}"
  case "$pins" in
    *,*) ;;   # rule 6 handles it, and it must not be short-circuited here
    *)
      case "$pin_host" in
        "$base"-*) ;;
        *) echo "ignore:host $pin_host is not from this pool"; return 0 ;;
      esac
      ;;
  esac

  # 6. Two host labels. No runner carries two, so no runner is a superset of
  #    this `runs-on` and nothing will ever pick the job up — waiting for the
  #    grace window first would only delay a verdict that cannot change. This is
  #    a workflow bug, and saying so beats a 24-hour queue.
  case "$pins" in
    *,*) echo "orphan:pinned to more than one host ($pins)"; return 0 ;;
  esac

  # 7. In flight. Whatever the MIG currently reports, a running job HAS a host —
  #    a list that lags a boot or misses a tick is not evidence to cancel on.
  if [ "$status" != "queued" ]; then
    echo "pinned:in flight on $pin_host"
    return 0
  fi

  # 8. Pinned to a host that is up. Real work, and it counts as busy — but it is
  #    not scale-out demand, because a new host cannot serve it.
  case ",$live," in
    *",$pin_host,"*) echo "pinned:$pin_host is live"; return 0 ;;
  esac

  # 9. Not in the list, but not for long.
  #
  #    Non-numeric age or grace is treated as "wait", not as an arithmetic error
  #    — a malformed timestamp from the API is not grounds to cancel a run, and
  #    the alternative is a `[: integer expression expected` that takes the
  #    controller's tick down with it.
  case "$age$grace" in
    *[!0-9]*) echo "wait:$pin_host not listed yet (unreadable age/grace)"; return 0 ;;
  esac

  #    A host mid-boot, a MIG listing that
  #    blipped, a controller on its first tick with an empty host list: all
  #    three look exactly like a dead host for a moment. The grace window is
  #    what stops a transient from cancelling a healthy run.
  #    `-le`, not `-lt`: a tick that lands exactly on the deadline resolves in
  #    favour of the run. One more tick of waiting costs a tick; one wrongly
  #    cancelled run costs somebody a re-run and the fleet its credibility.
  if [ "$age" -le "$grace" ]; then
    echo "wait:$pin_host not listed yet (${age}s of ${grace}s)"
    return 0
  fi

  # 10. Long enough. The host is not coming back under this name — a MIG
  #     replacement returns with a new one — so nothing will ever serve this
  #     job. Fail it now; a re-run anchors somewhere alive.
  echo "orphan:$pin_host is gone (${age}s)"
}
