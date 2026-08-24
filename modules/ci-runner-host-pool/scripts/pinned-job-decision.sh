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
#   * And the same thing happens to a job that was already RUNNING when its
#     host went away, except quieter: GitHub leaves the job `in_progress` with
#     nothing behind it, so the check run never reaches a conclusion at all.
#     Everything waiting on that status waits out somebody's timeout — a merge
#     queue reads "no status" as "still checking" and holds the entry for its
#     full window before dequeuing on a timeout that names no cause. See rule 7.
#
# So the rule is separated from the I/O for the same reason drain-decision.sh
# and orphan-decision.sh are. Two of its verdicts are irreversible in one
# direction — `orphan` cancels somebody's workflow run — and a predicate that
# can cancel a run has to be testable off the box.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# pin_split <pins|rest> <job_labels_csv> <pool_labels_csv>
#
# Rule 2 of pinned_job_decision, lifted out so there is exactly ONE piece of
# code in this fleet that decides which of a job's labels is an affinity pin.
# The controller needs that answer separately — to look up how long the pinned
# host has been missing before it asks for a verdict — and the alternative was a
# second copy of the rule in the caller, which is precisely the drift the demand
# sweep's comment warns about.
#
# Echoes the comma-joined subset asked for: `pins` (the `host-*` labels this
# pool does NOT itself register) or `rest` (everything else, including a
# `host-`-prefixed label the pool DOES register, which is an ordinary label and
# not a pin — see the caller's note on `host-large`).
#
# Folds both sides itself so it is safe to call before or after
# pinned_job_decision has folded them; folding is idempotent.
pin_split() {
  local want="${1:-}"
  local job_labels pool_labels
  job_labels=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
  pool_labels=$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')

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

  case "$want" in
    pins) printf '%s' "$pins" ;;
    *)    printf '%s' "$rest" ;;
  esac
}

# pin_host_of <job_labels_csv> <pool_labels_csv>
#
# The instance name a job is pinned to, for a caller that needs it BEFORE it has
# a verdict. Empty when the job carries no pin, and empty when it carries more
# than one — two pins are unsatisfiable by construction (rule 6) and there is no
# single host to ask about. Says nothing about whether the job is this pool's;
# that is rule 3's and rule 5's, and both still run.
#
# And empty for a name that is not a GCE instance name. This is the one helper
# whose output a caller turns into a FILESYSTEM PATH before any verdict exists,
# and its input is `runs-on` — text authored in the pull request. Rule 1b
# already refuses `case`-pattern syntax, but it lives inside the decision
# function, which by definition has not run yet when a caller asks this
# question, and it has no reason to care about `/` or `..` because it never
# builds a path. So the charset is enforced HERE, at the boundary that hands the
# name out, rather than trusted at each place that consumes it: a label of
# `host-../../something` yields no pin at all, which every caller already
# handles as "no absence clock" and reads as unknown.
#
# The rule is GCE's, not ours — an instance name is lowercase alphanumerics and
# hyphens — so a legitimate pin cannot fail it, and a name that fails it could
# not have named a live host in any event.
pin_host_of() {
  local pins
  pins=$(pin_split pins "${1:-}" "${2:-}")
  case "$pins" in
    "" | *,*) return 0 ;;
  esac
  local host="${pins#host-}"
  case "$host" in
    "" | *[!a-z0-9-]*) return 0 ;;
  esac
  printf '%s' "$host"
}

# pinned_job_decision <job_status> <job_labels_csv> <pool_labels_csv> \
#                     <base_instance_name> <live_hosts_csv> <age> <grace> \
#                     [missing_for]
#
#   job_status      : "queued" | "in_progress" per the GitHub API.
#   job_labels_csv  : the job's `runs-on`, comma-separated.
#   pool_labels_csv : everything this pool's agents register BEFORE the per-host
#                     affinity label is appended at boot — ci-runner-labels PLUS
#                     the runner's own read-only labels (`self-hosted`, the OS,
#                     the architecture), which no `--labels` argument produces
#                     and no workflow can tell apart from ours. Passing the
#                     configured list alone reads every real workflow in this
#                     fleet as another pool's. Case is irrelevant; see rule 0.
#   base_instance_name : the MIG's baseInstanceName. Bounds every verdict that
#                     acts to hosts THIS pool can create; see rule 5.
#   live_hosts_csv  : instance names the MIG reports NOW (not labels — the
#                     "host-" prefix is added here so one caller cannot pass
#                     labels while another passes names).
#   age             : seconds this job has been queued.
#   grace           : seconds a pinned job may wait for a host the MIG has not
#                     reported yet before it is called orphaned.
#   missing_for     : seconds the pinned host has been CONTINUOUSLY absent from
#                     the MIG's list, or empty when the caller cannot say. This
#                     is a second, independent clock and both must run out
#                     before anything is cancelled; see rule 9.
#
# Echoes one of:
#   ignore:<reason>  not this pool's job; do not count it, do not act on it
#   demand:<reason>  unpinned and ours — count it, and let it ask for a host
#   pinned:<reason>  ours and pinned to a live host — count it as work in
#                    flight, but NOT as a reason to scale out
#   vanished:<reason> ours, RUNNING, and the host underneath it is gone — the
#                    job will never report a conclusion on its own; fail the run
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
  local missing="${8:-}"

  # 0. BOTH SIDES ARE FOLDED BEFORE ANYTHING IS COMPARED. GitHub dispatches a
  #    job case-insensitively — `linux`, `Linux` and `LINUX` are one label to
  #    it — while every membership test below is a `case` on a comma-fenced
  #    string, which is exact. Unfolded, a workflow saying `linux` against a
  #    pool whose agents register `Linux` falls out at rule 3 as "not this
  #    pool's", and a job pinned to a host this pool owns is then neither
  #    counted nor ever orphaned: it waits out GitHub's 24 hours in silence.
  #    That is not hypothetical — it is what every workflow in this fleet says.
  #    Folded here rather than at the caller so the function cannot be handed a
  #    set it will silently misread. Labels are ASCII by GitHub's own rule, so
  #    `tr` is the whole of it; instance names are lowercase by GCE's.
  job_labels=$(printf '%s' "$job_labels" | tr '[:upper:]' '[:lower:]')
  pool_labels=$(printf '%s' "$pool_labels" | tr '[:upper:]' '[:lower:]')

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
  local pins rest
  pins=$(pin_split pins "$job_labels" "$pool_labels")
  rest=$(pin_split rest "$job_labels" "$pool_labels")

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

  # 7. Pinned to a host that is up. Real work — queued behind that host's other
  #    jobs, or running on it — and it counts as busy, but it is not scale-out
  #    demand, because a new host cannot serve it.
  #
  #    THE LIVENESS TEST IS ASKED OF A RUNNING JOB TOO, and it did not use to
  #    be: this function used to answer "in flight" for anything non-queued and
  #    return, on the reasoning that a running job HAS a host and a lagging MIG
  #    list is not evidence to cancel on. The first half of that is only true
  #    while the host exists. When a slot dies holding a job — a host deleted
  #    under it, an agent that stopped answering, a slot poisoned mid-run — the
  #    job stays `in_progress` at GitHub with no runner behind it and reports
  #    NOTHING: not success, not failure, not cancelled. Measured on a consumer
  #    repository 2026-08-23, that is a check run stuck for GitHub's own 24-hour
  #    timeout, and everything downstream waits it out. A merge queue is the
  #    expensive case, because it does not read a missing status as a problem —
  #    it reads it as "still checking" and holds the entry until its own
  #    timeout, 150 minutes on that repository, before dequeuing on a timeout
  #    that names nothing.
  #
  #    So the fix for "the queue never got a status" is to make the JOB report.
  #    A run that is cancelled has a conclusion; a run whose host evaporated has
  #    none and never will. The second half of the old reasoning is still
  #    honoured, and honoured harder — see rule 9's two clocks.
  case ",$live," in
    *",$pin_host,"*)
      if [ "$status" = "queued" ]; then
        echo "pinned:$pin_host is live"
      else
        echo "pinned:in flight on $pin_host"
      fi
      return 0
      ;;
  esac

  # 8. Not in the list, but possibly not for long.
  #
  #    Non-numeric age, grace or missing_for is treated as "wait", not as an
  #    arithmetic error — a malformed timestamp from the API is not grounds to
  #    cancel a run, and the alternative is a `[: integer expression expected`
  #    that takes the controller's tick down with it. An EMPTY missing_for is
  #    different from a malformed one: it means the caller keeps no absence
  #    ledger, which is allowed, and rule 9 falls back to one clock.
  case "$age$grace" in
    *[!0-9]*) echo "wait:$pin_host not listed yet (unreadable age/grace)"; return 0 ;;
  esac
  if [ -n "$missing" ]; then
    case "$missing" in
      *[!0-9]*) echo "wait:$pin_host not listed yet (unreadable absence)"; return 0 ;;
    esac
  fi

  # 8b. A RUNNING JOB IS ONLY EVER CANCELLED ON THE ABSENCE CLOCK. Without a
  #     ledger there is exactly one clock, `age`, and for a running job it is
  #     the wrong one twice over: it is measured from creation rather than from
  #     anything about the host, and every long job trips it. Cancelling a
  #     queued job on that evidence costs a wait; cancelling a running one
  #     throws away work that is happening. So a caller that keeps no ledger
  #     gets the OLD behaviour for in-flight jobs — count it, say nothing — and
  #     the new verdict is available only to a caller that can answer "how long
  #     has that host been gone".
  if [ "$status" != "queued" ] && [ -z "$missing" ]; then
    echo "pinned:in flight on $pin_host (not listed, and no absence clock)"
    return 0
  fi

  # 9. TWO CLOCKS, AND BOTH MUST RUN OUT. A host mid-boot, a MIG listing that
  #    blipped, a controller on its first tick with an empty host list: all
  #    three look exactly like a dead host for a moment, and the grace window is
  #    what stops a transient from cancelling a healthy run.
  #
  #    `age` alone is not that window. It is measured from the job's creation,
  #    so a job that sat in a queue for twenty minutes and then lost its host
  #    has already spent the whole allowance before the host went anywhere: one
  #    blipped listing cancels it on the first tick, with no tolerance at all.
  #    That was survivable while only QUEUED jobs could be cancelled here —
  #    the cost is a re-run of something that had not started. It is not
  #    survivable now that a running job can be, so the caller may supply a
  #    second clock measuring the thing actually being claimed: how long the
  #    host has been continuously absent.
  #
  #    The effective clock is the SMALLER of the two, which is exactly "both
  #    have run out". A caller with no ledger passes nothing and gets today's
  #    behaviour unchanged — and, per rule 8b, gets no `vanished` verdict at
  #    all, because for a running job the ledger IS the evidence.
  #
  #    `-le`, not `-lt`: a tick that lands exactly on the deadline resolves in
  #    favour of the run. One more tick of waiting costs a tick; one wrongly
  #    cancelled run costs somebody a re-run and the fleet its credibility.
  local clock="$age"
  if [ -n "$missing" ] && [ "$missing" -lt "$clock" ]; then
    clock="$missing"
  fi
  if [ "$clock" -le "$grace" ]; then
    echo "wait:$pin_host not listed yet (${clock}s of ${grace}s)"
    return 0
  fi

  # 10. Long enough, on both clocks. The host is not coming back under this name
  #     — a MIG replacement returns with a new one — so nothing will ever serve
  #     this job, and nothing will ever conclude it either. Fail it now; a
  #     re-run anchors somewhere alive.
  #
  #     The two verdicts differ only in what they tell the operator, and the
  #     distinction is worth keeping: a QUEUED job that is cancelled cost the
  #     fleet nothing but a wait, while a RUNNING one that is cancelled had a
  #     host taken out from under live work. The second is a fleet fault every
  #     time. The first can be a job that simply outlived a legitimate scale-in.
  if [ "$status" = "queued" ]; then
    echo "orphan:$pin_host is gone (${clock}s)"
  else
    echo "vanished:$pin_host went away under a running job (${clock}s)"
  fi
}
