#!/usr/bin/env bash
# ci-runner-host-pool — re-running a job whose Spot host was reclaimed.
#
# Like every *-decision.sh it is CONCATENATED into the
# controller's startup script (after host-ownership.sh, whose pool_slot_host it
# calls) and sourced by scripts/ci/preempt-decision.selftest.sh.
#
# WHY THIS EXISTS
#
# A Spot host (`spot = true`, termination action DELETE) can be reclaimed at
# any moment, and every job on it dies with it. GitHub reports such a job as
# `failure`: "The runner has received a shutdown signal" when the agent saw the
# 30-second notice, or "lost communication with the server" ten minutes later
# when it did not, usually with zero steps. Nothing retries it. The pull request
# goes red for a reason that has nothing to do with its code, and a person has
# to notice, read a log that may not exist, and press re-run. On a pool whose
# whole point is to be cheap and interruptible, that is a job lost silently.
#
# THE EVIDENCE, AND WHY ALL OF IT IS NEEDED
#
# Re-running a GENUINE failure is the expensive mistake: it hides a red build
# behind a second attempt and spends the job's whole duration again. So a job
# is re-run only when three independent things agree:
#
#   1. The job itself looks like a lost runner: concluded `failure` with NO
#      step that concluded `failure`. A test that failed has a failed step; a
#      runner that vanished has none (zero steps, or the running step cancelled
#      by the shutdown signal). Checked against a real one, 2026-10-10: a job
#      whose host was shut down mid-step concluded `failure` with that step
#      `cancelled`, the later steps `skipped`, and no step `failure`. The
#      controller's jq applies this; it is stated here because the two
#      functions below assume it.
#   2. Its runner_name is a slot of a host THIS pool's MIG could have created
#      (pool_slot_host), on a pool whose descriptor says spot = true.
#   3. That host is gone: no longer in the MIG's instance list, or listed but
#      cold-started after the job began — a MIG recreates a deleted managed
#      instance under the SAME NAME, so "absent" alone would miss most
#      preemptions. Both facts come from calls the tick already makes
#      (list-instances, and the instances list behind HOST_BORN); no
#      operations list is read.
#
# A HOST THAT IS STILL UP IS NOT EVIDENCE OF ANYTHING YET. A job killed by the
# shutdown signal is reported failed within seconds, while the instance is still
# listed RUNNING for its last half-minute. So "alive" is only a verdict once the
# job has been finished for `settle` seconds; before that it is `wait`. The
# controller's own scale-in cannot fake condition 3 inside that window: it
# deletes only hosts idle for the pool's drain grace.
#
# THE CAP, AND WHO ENFORCES IT
#
# Once per run attempt, and only while run_attempt is below the cap. GitHub is
# the durable record: the decision is taken against the run as GitHub reports
# it NOW (re-read before every POST), so a run somebody already re-ran, or the
# controller re-ran before a restart erased its ledger, is on a newer attempt
# and is left alone. The ledger only stops a second POST inside the window
# where GitHub has accepted the re-run but not yet moved the attempt number.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# preempt_host_verdict <base> <runner_name> <hosts_listed> <listed_status>
#                      <host_born> <job_started> <job_completed> <now> <settle>
#
#   base           the pool's MIG baseInstanceName ("" when it could not be read)
#   runner_name    the job's runner_name
#   hosts_listed   1 when this tick's list-instances call succeeded
#   listed_status  the host's instanceStatus in that list, "" when not listed
#   host_born      epoch of the host's current boot (HOST_BORN), "" if unread
#   job_started    epoch the job started
#   job_completed  epoch the job completed
#   now            epoch now
#   settle         seconds a finished job must age before "alive" is final
#
# Prints exactly one of:
#   foreign:<why>  not a host of this pool — this pool has nothing to say
#   lost:<why>     the machine that ran the job is gone
#   alive:<why>    the machine that ran the job is still up; a real failure
#   wait:<why>     cannot be told yet; ask again next tick
preempt_host_verdict() {
  local base="${1:-}" runner="${2:-}" listed="${3:-0}" status="${4:-}"
  local born="${5:-}" started="${6:-}" completed="${7:-}" now="${8:-}" settle="${9:-0}"
  local host

  # Without the base name nothing can be attributed, and that is a failed
  # describe, not a fact about the job.
  [ -n "$base" ] || { echo "wait:the MIG base name could not be read"; return 0; }
  host=$(pool_slot_host "$base" "$runner") || {
    echo "foreign:runner '$runner' is not a slot of a $base host"
    return 0
  }

  # An EMPTY listing and a FAILED listing look the same from here; only the
  # second may not be read as "the host is gone". Same fail-safe as the reaper.
  [ "$listed" = 1 ] || { echo "wait:the MIG instance list was not read this tick"; return 0; }

  if [ -z "$status" ]; then
    echo "lost:$host is no longer in the MIG"
    return 0
  fi

  case "$started" in "" | *[!0-9]*) echo "wait:the job has no readable start time"; return 0 ;; esac
  case "$born" in
    "" | *[!0-9]*)
      # Listed, but the boot time is unread: a host recreated under the same
      # name would read as the one that ran the job. Wait for the fact.
      echo "wait:$host boot time could not be read"
      return 0
      ;;
  esac
  if [ "$born" -gt "$started" ]; then
    echo "lost:$host cold-started after the job began (recreated under the same name)"
    return 0
  fi

  # Still the same machine. STOPPING/STOPPED/TERMINATED is a host on its way
  # out — possibly the reclaim itself — so it is not called alive yet.
  if [ "$status" != RUNNING ]; then
    echo "wait:$host is $status"
    return 0
  fi

  case "$completed" in "" | *[!0-9]*) echo "wait:the job has no readable completion time"; return 0 ;; esac
  case "$now" in "" | *[!0-9]*) echo "wait:no clock"; return 0 ;; esac
  if [ $((now - completed)) -lt "$settle" ]; then
    echo "wait:$host still RUNNING, but the job finished only $((now - completed))s ago"
    return 0
  fi
  echo "alive:$host is still up on the boot that ran the job"
}

# preempt_rerun_decision <run_status> <run_conclusion> <run_attempt>
#                        <candidate_attempt> <acted_attempt> <cap> <pinned>
#
#   run_status/run_conclusion/run_attempt   the run as GitHub reports it NOW
#   candidate_attempt                       the attempt whose job was lost
#   acted_attempt                           the attempt the controller already
#                                           re-ran ("" if none)
#   cap                                     re-run only while run_attempt < cap
#   pinned                                  1 when a lost job carried a host-*
#                                           pin label
#
# Prints exactly one of:
#   rerun-failed:<why>  POST .../rerun-failed-jobs (the passed jobs are kept)
#   rerun-full:<why>    POST .../rerun — the run is host-pinned
#   done:<why>          nothing to do, and nothing anybody needs to hear about
#   declined:<why>      a lost job that will NOT be re-run — say so
#   wait:<why>          the run could not be read; ask again next tick
preempt_rerun_decision() {
  local rstatus="${1:-}" concl="${2:-}" rattempt="${3:-}" cand="${4:-}"
  local acted="${5:-}" cap="${6:-3}" pinned="${7:-0}"

  [ -n "$rstatus" ] || { echo "wait:the run could not be read"; return 0; }
  case "$rattempt" in "" | *[!0-9]*) echo "wait:the run has no readable attempt"; return 0 ;; esac
  case "$cand" in "" | *[!0-9]*) echo "done:no attempt was recorded for the lost job"; return 0 ;; esac

  # Somebody — a person, the merge lane, this controller before a restart —
  # already re-ran it. GitHub's attempt number is the record that survives.
  if [ "$rattempt" != "$cand" ]; then
    echo "done:the run is on attempt $rattempt now, not $cand"
    return 0
  fi
  if [ "$acted" = "$rattempt" ]; then
    echo "done:attempt $rattempt was already re-run by this controller"
    return 0
  fi
  [ "$rstatus" = completed ] || { echo "done:the run is $rstatus"; return 0; }
  [ "$concl" = failure ] || { echo "done:the run concluded ${concl:-nothing}"; return 0; }

  case "$cap" in "" | *[!0-9]*) cap=3 ;; esac
  if [ "$rattempt" -ge "$cap" ]; then
    echo "declined:attempt $rattempt reached the cap of $cap — lost again, so look at the pool, not the code"
    return 0
  fi

  # A host-pinned run (ADR adr-pr-host-affinity.md): its jobs carry the
  # dead host's `host-*` label, and rerun-failed-jobs would queue them for a
  # machine that no longer exists. Only a full re-run re-pins the anchor.
  if [ "$pinned" = 1 ]; then
    echo "rerun-full:attempt $rattempt lost a host-pinned job; a full re-run re-pins it to a live host"
    return 0
  fi
  echo "rerun-failed:attempt $rattempt lost its host; re-running the failed jobs only"
}
