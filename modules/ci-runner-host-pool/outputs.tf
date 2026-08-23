output "mig_name" {
  description = "Name of the regional MIG holding the hosts."
  value       = google_compute_region_instance_group_manager.hosts.name
}

output "mig_self_link" {
  description = "Self-link of the regional MIG."
  value       = google_compute_region_instance_group_manager.hosts.self_link
}

output "instance_group" {
  description = "Instance group self-link, for attaching external monitoring."
  value       = google_compute_region_instance_group_manager.hosts.instance_group
}

output "autoscaler_name" {
  description = "Name of the autoscaler. Verify with the compute REST API — the installed gcloud has no `compute autoscalers` subcommand."
  value       = google_compute_region_autoscaler.hosts.name
}

# `one()` and not `[0]`: with manage_controller = false there is no controller,
# and an index into an empty list fails the PLAN with an error about the output
# rather than about the pool. Null is the honest answer — this pool's controller
# is somewhere else.
#
# And the GROUP, not the instance. Since #308 the controller is a managed group of
# size 1, and the VM inside it is named `<group>-<suffix>` — a name that changes
# every time the group rebuilds it, which is the entire point. An output that
# named the instance would be a value every consumer had to re-read after each
# recovery, so the stable handle is the group.
output "controller_instance" {
  description = "Name of the managed group holding the always-on controller VM, or null when a shared controller serves this pool. The VM itself is <this>-<suffix>; list it with `gcloud compute instance-groups managed list-instances`."
  value       = one(google_compute_instance_group_manager.controller[*].name)
}

output "controller_zone" {
  description = "Zone of the controller's managed group, or null when a shared controller serves this pool."
  value       = one(google_compute_instance_group_manager.controller[*].zone)
}

# THE POOL, AS THE CONTROLLER'S TABLE WANTS IT.
#
# A consumer wiring four pools to one controller passes
# `pools = [for m in [module.lin_ci, module.win_ci, ...] : m.pool_descriptor]`
# and retypes nothing. That matters more than it looks: `mig` is the MIG's
# GENERATED name, not `var.name`, and a descriptor written by hand gets it wrong
# in a way that produces a controller which lists an empty instance group
# forever and reports a perfectly healthy empty pool.
#
# Keys the table gives a safe default are deliberately ABSENT rather than
# restated — `role`, `beacon_interval`, `pin_orphan_grace_seconds`. One default,
# in pool-table.sh, where the self-test can reach it.
output "pool_descriptor" {
  description = "This pool as one row of a controller's `ci-pools` table. Feed to modules/ci-runner-controller."
  value = {
    name                     = var.name
    mig                      = google_compute_region_instance_group_manager.hosts.name
    region                   = var.region
    slots                    = var.slots_per_host
    min_hosts                = var.min_hosts
    max_hosts                = var.max_hosts
    drain_grace_seconds      = var.drain_grace_seconds
    register_grace_seconds   = var.register_grace_seconds
    orphan_confirm_ticks     = var.orphan_confirm_ticks
    recycle_max_unavailable  = var.recycle_max_unavailable
    host_os                  = var.host_os
    mints_registration_token = var.controller_mints_registration_token
    runner_labels            = local.runner_labels

    # Carried even though the parser defaults it, unlike every other defaulted
    # column: `ci` is the safe default for a pool that says nothing, and it is
    # the WRONG answer for the pool this delivery exists to add. A merge-queue
    # pool that arrives labelled `ci` is sized from pull-request demand, which
    # is precisely the rationing the split removes.
    role = var.role
  }
}

output "runner_labels" {
  description = "Exact label set the agents register with. Workflows must match a subset of this."
  value       = local.runner_labels
}

output "job_concurrency" {
  description = "Maximum concurrent jobs this pool can serve: max_hosts * slots_per_host."
  value       = var.max_hosts * var.slots_per_host
}

output "metric_names" {
  description = "Fully-qualified custom metrics this pool publishes, for dashboards and alert policies."
  value = {
    for m in [
      "ci_demand",
      "ci_demand_queued",
      # Queued jobs this pool STOPPED answering for because they had been queued
      # past DEMAND_MAX_AGE. GitHub never takes a run out of `queued` on its own,
      # so a run held by an unapproved environment, blocked on a `concurrency`
      # group, or abandoned on a dead branch would otherwise hold a host warm
      # forever and peg ci_demand_wait_seconds at its own age — saturating the
      # one gauge that would have shown the real queue underneath it. Published
      # rather than silently subtracted: a demand figure that dropped with no
      # visible reason is the same invisibility arriving from the other side. A
      # steady non-zero count is a repository leaving runs stuck, not a fleet
      # fault; a sudden one alongside a rising ci_demand is worth reading twice.
      "ci_demand_expired",
      # Jobs this pool must run that are PINNED to one named host, kept out of
      # ci_demand on purpose: the autoscaler reads ci_demand, and buying a host
      # cannot help a job only one existing host can serve. Read the two
      # together — ci_demand near zero while this is high is a pool that looks
      # idle and is not, and it is the shape a stuck pinned run makes.
      "ci_demand_pinned",
      # Runs failed because the host they were pinned to no longer exists. Rare
      # by construction and never routine: a sustained non-zero rate means hosts
      # are being replaced underneath live runs — recycling too aggressively, or
      # preemption — not that the cancel logic is working hard.
      "ci_pinned_runs_cancelled",
      # Jobs found RUNNING on a host that had gone. Per JOB and before any
      # de-duplication, unlike the per-RUN series above, and it survives a
      # refused cancel — which is the case where the number matters most.
      #
      # It is the only series in this list that reports a job which was
      # producing NO SIGNAL AT ALL. A slot that dies holding a job leaves the
      # check run `in_progress` at GitHub with nothing behind it: no success, no
      # failure, no cancellation, until GitHub's own 24-hour timeout. Everything
      # downstream then waits out ITS timeout instead — a merge queue reads a
      # missing status as "still checking" and holds the entry for its full
      # window before dequeuing on a timeout that names no cause.
      #
      # So a non-zero here is never "the controller is tidying up". It is live
      # work that lost its machine, and sustained non-zero is a slot-health
      # problem being reported by the only layer positioned to notice.
      "ci_pinned_jobs_host_vanished",
      # Removals this pool decided on and then declined to carry out because the
      # host held a live pin hold. Scale-in deliberately deferred, not an error:
      # read alongside ci_demand_pinned, the two together are "the pool is
      # holding hosts for runs in flight". Sustained non-zero with no pinned
      # demand is the opposite — a hold that is not lapsing, which is the shape
      # an abandoned or forged one makes, and the reason the controller clamps
      # every hold to PIN_HOLD_MAX.
      "ci_pin_holds_honoured",
      "ci_hosts_running",
      "ci_hosts_max",
      "ci_hosts_draining",
      "ci_slots_total",
      "ci_slots_busy",
      # Slots that ANSWER, and the gap between that and the slots the pool was
      # built with. ci_slots_total is arithmetic — hosts × slots — so it reads
      # identically whether every agent is registered or none is. These two are
      # the only series that distinguish the two, and they are counted only over
      # RUNNING hosts past their registration grace, so ordinary scale-out does
      # not move them.
      #
      # Alert on sustained non-zero ci_slots_missing. It is one number for three
      # failures that all present as "the pool looks fine and jobs queue": a
      # host that registered nothing at all, a host whose slot units died before
      # the agent started, and a slot the host's own sweep condemned and took
      # out of service after it failed to reach a clean state CONDEMN_MAX times.
      # A blind tick contributes to neither, so this cannot be moved by the API
      # being unreadable.
      "ci_slots_registered",
      "ci_slots_missing",
      "ci_host_idle_seconds_max",
      "ci_queue_wait_seconds_max",
      # How long the oldest job already EXECUTING has been executing. Pairs with
      # ci_queue_wait_seconds_max, which only covers the wait before a job
      # starts. A slot whose runner agent dies mid-job keeps GitHub believing
      # the job is in flight — and the orphan reaper backs off precisely when
      # GitHub reports a runner busy — so the wedge is invisible until the job's
      # own `timeout-minutes` cancels it and fails a required check. Threshold
      # this per repository against its own longest legitimate job; there is no
      # fleet-wide right number. It rides the demand sweep, so it inherits the
      # demand sweep's bound: when ci_demand_runs_skipped is non-zero this is a
      # LOWER bound, and an alert on it can miss a wedge on exactly the busy
      # pool where the sweep ran out of budget. Alert on the pair.
      "ci_job_running_seconds_max",
      # `ci_job_startup_seconds` was declared here and never implemented — no
      # code path has ever published it. Removed rather than stubbed: a declared
      # series nothing writes produces an alert policy that cannot fire, which is
      # read as "healthy". Time-to-first-job is already observable as
      # ci_queue_wait_seconds_max; total wall time is a property of the workflow
      # run, not of the pool, and belongs in the run report.
      "ci_mig_target_size",
      "ci_drain_verdicts",
      # The SECOND delete gate — the one that asks the host itself whether a job
      # worker is still alive after every agent was deregistered. Read grouped
      # BY its `outcome` label; the three are not interchangeable. `held` is the
      # gate working. `undetermined` is the gate BLIND — the host's OS or its
      # liveness facts could not be read, so the controller kept a host it could
      # not ask about. Sustained non-zero `undetermined` is scale-in suspended
      # while every host reads healthy, and it is the one to alert on.
      "ci_worker_gate_verdicts",
      # How many hosts per tick carried no `ci-host-os` at all and were resolved
      # from the controller's own — the transitional arm in drain_host(). Every
      # host predates the key on the day this ships, so this starts at the drain
      # rate and must decay to zero as the pool recycles. Zero for a full recycle
      # window is the signal that the arm can be deleted; still non-zero long
      # after a rollout is a pool whose hosts are not being replaced.
      "ci_worker_gate_os_fallback",
      # Published since the reaper landed but never listed here, so no dashboard
      # or alert built from this contract could see it.
      "ci_orphan_registrations_reaped",
      # The only series that answers "did the apply reach machines". A pin
      # lands, the template changes, this climbs to the pool size and falls back
      # to zero as hosts are replaced. STUCK above zero is the state that was
      # invisible on 2026-08-15: v5.7.0 applied, five hosts still serving jobs
      # from the previous template, every other series green. Alert on sustained
      # non-zero, not on the spike — the spike is a release working.
      "ci_hosts_stale_template",
      # Per-tick deltas, like ci_drain_verdicts: align with a sum over the
      # window. `cordoned` climbing while `retired` stays flat means the recycle
      # is working and the hosts are not leaving — jobs that never end.
      "ci_recycle_verdicts",
      "ci_poller_heartbeat",
      # Pools the controller's own table refused at boot. A rejected pool has no
      # series of its own — it is simply never ticked — so there is nothing to
      # go absent and nothing to alert on except this. Its autoscaler is
      # ONLY_UP, which means it holds whatever size it last reached, forever,
      # while every other pool on the same controller reads healthy. Alert on
      # any non-zero value.
      "ci_pool_table_rejected",
      # Non-zero means scale-in is SUSPENDED — the controller cannot read the
      # runner list, so no host can be proven idle. Alert on a sustained run
      # (> 3 ticks), never on a single blip: one blind tick is normal API noise.
      "ci_runner_list_blind_ticks",
      # Tick duration. A tick approaching the watchdog threshold is a controller
      # about to be restarted mid-tick forever — and because every series is
      # queued during the tick and flushed at its end, the only other symptom is
      # ALL of them going absent at once, which reads identically to a project
      # that has no pool. Alert well below the threshold, not at it.
      "ci_tick_seconds",
      # Runs the demand sweep ran out of budget for. > 0 means ci_demand is a
      # lower bound, so an apparently under-scaled pool may simply not have been
      # counted.
      "ci_demand_runs_skipped",
      # --- the merge queue's own ceiling --------------------------------------
      # Published ONLY by a pool whose role is `merge-queue`, and absent on every
      # CI pool — a CI pool's work comes from people pushing commits, which no
      # configuration file bounds. Absence here is therefore normal and carries
      # meaning; do not alert on it.
      #
      # The pair to read together is ci_queue_capacity_wanted_hosts against
      # ci_queue_capacity_hosts. Equal is healthy. `wanted` above `capacity` is
      # the reported bottleneck in its diagnosable form: Mergify is configured
      # to run more speculative checks at once than this pool is allowed to grow
      # for, so the surplus checks WAIT — pending, never failed, on a pull
      # request whose own CI is already green. Alert on the comparison, which
      # needs no per-repository threshold, rather than on either number.
      "ci_queue_capacity_hosts",
      "ci_queue_capacity_wanted_hosts",
      # The inputs the ceiling was derived from, published so the derivation can
      # be checked from a dashboard instead of by reading a controller log.
      # ci_queue_parallel_checks is the summed `max_parallel_checks` of the
      # repository's queues; ci_queue_jobs_per_check is the observed high-water
      # number of this pool's jobs in one run. Their product over the pool's
      # slots is ci_queue_capacity_wanted_hosts.
      "ci_queue_parallel_checks",
      "ci_queue_jobs_per_check",
      # Read from the configuration, reported, and deliberately NOT multiplied
      # into the ceiling: in `parallel` mode Mergify validates a batch as ONE
      # speculative pull request, so a wider batch clears more of the backlog
      # per check run rather than needing more runners. It is published because
      # the opposite intuition is the natural one.
      "ci_queue_batch_size",
      # Jobs the ceiling removed from the published demand this tick. Expected
      # to be flat zero: real demand is measured from jobs Mergify has already
      # launched, and Mergify launches at most what its own config allows. A
      # non-zero value is a fault to go and read — a mislabelled workflow
      # reaching the queue pool, or a queue narrowed while runs were in flight.
      "ci_queue_demand_clamped",
      # How stale the configuration behind the ceiling is. The capacity rule
      # FAILS OPEN, so a controller that has lost access to the repository's
      # `.mergify.yml` keeps enforcing the last ceiling it derived and looks
      # entirely healthy — this is the only series that would say otherwise.
      # `-1` means it has never been read at all. Alert above a small multiple
      # of the sweep interval.
      "ci_queue_config_age_seconds",
      # --- work, as opposed to pool ------------------------------------------
      # Every series above describes the POOL. These two describe what it RAN,
      # labelled by workflow, which is the only way the fleet-wide questions
      # ("where do the runner seconds go", "which workflow is red") are
      # answerable without reading run logs per repository by hand.
      #
      # Both are per-tick DELTAS on a GAUGE, like ci_drain_verdicts: align with
      # a sum over the window, never with a mean. Both are ABSENT when nothing
      # finished — there is no workflow name to label a zero with — so read them
      # next to ci_poller_heartbeat, which separates an idle pool from a dead
      # controller.
      "ci_jobs_completed",
      "ci_job_seconds",
      # > 0 means completed runs went unread this tick and their outcomes are
      # deferred, not lost. Sustained non-zero means OUTCOME_BUDGET is too small
      # for this repository's throughput and the other two are lagging.
      "ci_outcome_runs_skipped",
      # --- the merge queue, as opposed to the pool ----------------------------
      # Open pull requests that are GREEN and can never enter the merge queue,
      # grouped by the entry condition they fail (`draft`, `base`,
      # `draft-and-base`). It is a REPOSITORY fact published under every pool's
      # label, so read it with max() across pools and never sum() — four pools
      # on one controller each publish the same count.
      #
      # It is here, in a capacity contract, because the two "CI is making no
      # progress" reports this fleet received in one week were both this and
      # neither was a pool: Mergify reports an unmet entry condition as NEUTRAL,
      # which renders as a grey dot beside forty green ticks. Nothing else in
      # this list can go non-zero for it.
      "ci_prs_green_and_unqueued",
      # > 0 means the parking sweep did not examine every candidate, so the
      # count above is a lower bound. Published every tick, 0 included: it is
      # what makes a zero above readable as "nothing is parked" rather than "the
      # sweep never got there".
      "ci_parked_prs_skipped",
      # > 0 means the sweep was REFUSED, not delayed: the installation lacks
      # `checks: read` and no later sweep will do better. Separate from the
      # counter above because the two carry opposite advice — wait, versus grant
      # a permission — and because a denied sweep leaves every other series here
      # publishing the same unbroken zero a healthy repository publishes.
      "ci_parked_sweep_denied",
      # --- the merge queue that ADMITTED the pull request and stopped ---------
      # The complement of the four series above: those describe a pull request
      # the queue will never take, these describe one it took and then left
      # stationary. Same repository-fact caveat — published under every pool's
      # label, read with max() and never sum().
      #
      # Nudges the controller actually posted this tick, labelled by `kind`
      # (`refresh` = the queue holds the entry and has not looked at it since
      # the last check went green; `queue` = there is no live entry, because it
      # was dequeued on a fleet failure or never entered). A per-tick DELTA on a
      # gauge: align with a sum, never a mean. Sustained non-zero is not the
      # fleet working, it is the queue needing a chaperone — read it as a defect
      # rate, and read it beside the failure rate of the merge-queue draft runs.
      "ci_queue_nudges",
      # Pull requests that met every stall condition and were NOT nudged,
      # because the head sha had already spent its attempts. This is the series
      # that says a human is needed: the automation has given up and the pull
      # request is still sitting there. Alert on it.
      "ci_queue_stalls_unresolved",
      # How many heads hit that ceiling. Separate from the count above because
      # this one is cumulative evidence that the infra/diff line is drawn wrong
      # — a healthy fleet exhausts nobody — while the count above is one
      # pull request needing help right now.
      "ci_queue_stall_attempts_exhausted",
      # > 0 means the stall sweep did not examine every candidate this tick, so
      # every count above is a lower bound rather than a fact. Published every
      # tick, 0 included, for the same reason ci_parked_prs_skipped is.
      "ci_queue_stall_prs_skipped",
      # > 0 means REFUSED, not delayed. Reading the state needs `checks: read`
      # and `pull_requests: read`; POSTING the nudge needs `pull_requests:
      # write`, which is the permission a repository is most likely to be
      # missing, and without it this layer is silently a no-op that publishes
      # the same zeros a healthy repository publishes.
      "ci_queue_stall_sweep_denied",
      # --- the cache hydrate --------------------------------------------------
      # Published by the HOST, not the controller, and once per boot rather than
      # per tick: the hydrate finishes before the runner agent registers, so the
      # controller never sees the machine it would be reporting on.
      #
      # This block exists because the layer fails open by design. A pool whose
      # snapshot expired, a pool whose bucket was never configured and a pool
      # whose every host times out on the download all present as the same
      # observable — jobs slower than they were, and nothing red anywhere. Read
      # ci_cache_hydrate_verdict grouped BY its `verdict` label; the raw value is
      # always 1 and means nothing on its own. `hydrated` is the only good one.
      "ci_cache_hydrate_verdict",
      # What the hydrate spent, whatever it decided. Approaching
      # cache_hydrate_budget_seconds means hosts are paying the full budget and
      # then registering cold — the worst of both.
      "ci_cache_hydrate_seconds",
      # Age and size of the snapshot the host READ ABOUT, recorded before the
      # bounds that may reject it — so a `too-old` verdict comes with the number
      # that produced it. Absent when there was no snapshot to describe, which is
      # why the stale-snapshot alert is written on this and not on the verdict.
      "ci_cache_snapshot_age_hours",
      "ci_cache_snapshot_bytes",
      # Tool caches actually moved in. Zero WITH a `hydrated` verdict is a
      # snapshot built from an empty tree — a publish that succeeded at packing
      # nothing.
      "ci_cache_dirs_hydrated",
    ] : m => "${var.metric_prefix}/${m}"
  }
}
