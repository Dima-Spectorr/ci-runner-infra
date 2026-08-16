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

output "controller_instance" {
  description = "Name of the always-on controller VM (poller, drainer, metric publisher)."
  value       = google_compute_instance.controller.name
}

output "controller_zone" {
  description = "Zone of the controller VM."
  value       = google_compute_instance.controller.zone
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
      "ci_hosts_running",
      "ci_hosts_max",
      "ci_hosts_draining",
      "ci_slots_total",
      "ci_slots_busy",
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
