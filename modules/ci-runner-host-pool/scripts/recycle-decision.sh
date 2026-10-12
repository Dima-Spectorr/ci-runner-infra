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
#            mid-job guard: the working slot survives and its job runs to
#            completion. Agents here are not --ephemeral and their unit is
#            Restart=no, so a deregistered slot stays deregistered.
#   RETIRE   once the last job lands and busy reaches 0, hand the host to
#            drain_host() — deregister the remainder, verify no Runner.Worker
#            survives, delete.
#
# Nothing is killed. The host simply stops accepting work and leaves when it is
# empty.
#
# THE HELD SLOT IS NOT "OTHER", AND THIS COMMENT USED TO SAY IT WAS (#948).
#
# It read "no new job can ever reach this host again because every other slot is
# gone from the pool". "every OTHER slot" was load-bearing and wrong. The slot
# GitHub refused to deregister is still REGISTERED — the 422 protects the job on
# it, it does not take the agent out of the scheduler — so the moment that job
# lands the slot is an ordinary, eligible, long-polling runner again.
#
# On an idle pool that is invisible: the next tick reads busy=0 and retires. On
# a SATURATED one it is a livelock, and a self-reinforcing one, because the
# cordon removed this host's other slots from a pool that already has a backlog:
# fewer slots against the same queue means the survivors — including the held
# one — are busy a larger fraction of the time, which makes an idle observation
# LESS likely, which keeps the cordon from completing. Rule 5 below then exempts
# an already-cordoned host from the budget, so with max_unavailable=1 one stuck
# host pins every other host in its pool on the stale template too. Measured on
# 2026-09-19: the held slot took new work 31 minutes after being cordoned, and
# again at 63 minutes, while 18 runs sat queued.
#
# The tick interval bounds nothing here. `cordon_host` calls the exposure "up to
# one poll interval", but that is a SAMPLING RATE against a Poisson arrival
# process, not a deadline — every sample can miss, and for an hour they all did.
#
# THE RULE BELOW IS UNCHANGED, AND DELIBERATELY SO. Both directions that would
# have changed it are dead ends: GitHub's repository-scope runner API has no
# pause/disable/quiesce primitive at all, and a deadline that escalates to a
# DELETE is answered 422 while one that escalates to a kill drops a running job —
# the one thing this whole two-phase design exists to prevent. The fix is in the
# I/O layer instead: on cordon the controller sets `ci-cordon=1` on the instance,
# and the host's own slot loop stops re-registering each slot once its job ends.
# A slot holds one single-use registration at a time, so one that is not
# re-registered is not a scheduling target, and it leaves the repository's
# runner list — so `busy` reaches 0 within one JOB duration rather
# than whenever a sample happens to land. Same rule, an input that now converges.
# Behind `recycle_cordon_stops_agents`, default false.
#
# WHAT THE CORDON PROVIDES, STATED WITHOUT THE OVERCLAIM: no job is ever
# interrupted, and a slot once removed from the pool never comes back. It does
# NOT provide "no new job can ever reach this host again" on its own — only the
# host-side half makes that true, and only on a pool whose hosts are new enough
# to have the slot loop that reads the flag. So the measurement added in #951 stays:
# cordon_host() publishes ci_recycle_verdicts{outcome=cordon-no-progress} for a
# cordon that has removed nothing since it started. With the flag off, or on a
# pool still running older hosts, that series is the livelock being visible
# rather than silent. Do not re-add the stronger claim unconditionally.
#
# ROLLING, NOT ALL AT ONCE. Cordoning is not free: a cordoned host's idle slots
# leave the pool immediately, so cordoning every stale host at once removes the
# fleet's whole spare capacity in one tick and every queued job waits for a
# boot. `max_unavailable` bounds how many hosts may be mid-recycle at a time —
# and 0 disables the whole mechanism, which is the kill switch a rule that
# deletes machines has to have.
#
# MAKE BEFORE BREAK — THE REPLACEMENT IS BOUGHT BEFORE THE HOST IS CORDONED.
#
# Rolling bounded the loss; it did not remove it. Measured on a 20-host pool
# with max_unavailable=4, 2026-10-11 03:20Z: four hosts cordoned with 2-3 jobs
# each (one for 26+ minutes) while pull-request runs queued. The pool sat at
# max_hosts, so the autoscaler could not add anything, and every idle slot the
# cordons removed was simply gone — a two-hour rollout run four hosts short.
#
# So a busy host that qualifies is first RESERVED, not cordoned. A reservation
# changes nothing on the host: it keeps every slot and keeps taking work. What
# it changes is the pool's arithmetic. recycle_surge_demand() below counts a
# host in the recycle set as ONE host carrying its own running jobs and nothing
# more, so the demand the autoscaler reads asks for its replacement at once;
# and the autoscaler's ceiling is max_hosts + recycle_max_unavailable, so a pool
# already at max_hosts has room to buy it. Only once the reservation is older
# than register_grace — the module's own bound on "a new host has booted and
# registered" — is the old host cordoned. The replacement is serving before the
# old host's idle slots leave, so the pool's capacity never dips below where it
# started. The surge ends by itself: the retire deletes the old host, which
# lowers the MIG's target, and with nothing left in the recycle set the demand
# is capped at max_hosts again.
#
# The caller owns all I/O — GitHub, gcloud, the metadata server — so this rule
# is exercised by scripts/ci/recycle-decision.selftest.sh instead of only in
# production.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# recycle_decision <instance_status> <template_state> <busy_slots> \
#                  <registration_state> <age_seconds> <register_grace_seconds> \
#                  <in_flight> <max_unavailable> <already_cordoned> \
#                  <partial_for_seconds> <reserved_for_seconds>
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
#   in_flight           : hosts already mid-recycle (reserved or cordoned, not
#                         yet gone).
#   max_unavailable     : how many may be mid-recycle at once. 0 = disabled.
#                         Also the surge: the autoscaler may run this many
#                         hosts above max_hosts while they are replaced.
#   already_cordoned    : 1 if THIS host is cordoned.
#   partial_for_seconds : how long this host has read `partial` WITHOUT
#                         INTERRUPTION. 0 when it is not partial now, and 0 for
#                         a caller that does not track it -- which keeps this
#                         parameter's absence meaning "no capacity-lost recycle
#                         ever", the same way max_unavailable=0 does. Compared
#                         against max(register_grace, 960s); the floor is the
#                         slot loop's bounded reset, derived at rule 2.
#   reserved_for_seconds: how long THIS host has held a reservation — its
#                         replacement requested, its slots still serving. -1
#                         (the default) when it holds none. A reserved host is
#                         one of the in_flight ones, like a cordoned one.
#
# Echoes "reserve:<reason>", "cordon:<reason>", "retire:<reason>" or
# "skip:<reason>". Always exits 0
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
  local reserved_for="${11:--1}"
  case "$reserved_for" in -1) ;; '' | *[!0-9]*) reserved_for=-1 ;; esac

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
  #    is NOT simply reg_grace. Every slot registers for ONE job, and its slot
  #    loop resets it before registering it again, so EVERY slot is missing
  #    from the roster between every two jobs — ordinarily for about ninety
  #    seconds. Ordinarily is not the bound. The loop runs that reset under
  #    `timeout 900` and retries a failed one after 30 seconds, deliberately
  #    generous so that one wedged docker call is survived rather than taking
  #    the slot out of service — so a slot that is coming back can legitimately
  #    be missing for roughly 930 seconds, and the host reads `partial` for
  #    every one of them.
  #
  #    A recycle rule that fires inside that window RACES THE HOST'S OWN REPAIR
  #    and wins: the slot would have returned, and instead the pool cordons the
  #    host's remaining idle slots and deletes it. So the window is the larger of
  #    reg_grace — the same window that decides `absent` means dead, because it
  #    answers the same question — and the loop's bounded reset plus its retry
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
  #    hysteresis window is the mechanism watching something: either a reset
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
  #    host — one with no idle slots and no way back — parked forever. A
  #    reserved host is exempt for the same reason: its replacement is already
  #    bought, and dropping it here would leave the surge paid for and the old
  #    host never cordoned.
  if [ "$cordoned" != "1" ] && [ "$reserved_for" -lt 0 ] &&
    [ "$in_flight" -ge "$max_unavail" ]; then
    echo "skip:at-capacity in-flight=$in_flight>=max=$max_unavail"
    return 0
  fi

  # 6. Still working, so make before break.
  #
  #    Not reserved yet, or reserved for less than register_grace: RESERVE. The
  #    host keeps every slot and keeps serving; the caller records the
  #    reservation and the surge demand buys the replacement. register_grace is
  #    the bound, not a new number, because it is already this module's answer
  #    to "how long may a new host take to boot and register" — the same window
  #    that decides `absent` means dead. A replacement that has not arrived by
  #    then (a quota refusal, a zone out of capacity) is not waited on forever:
  #    the cordon proceeds and the pool is one host short for one job length,
  #    which is exactly what every recycle cost before this change.
  #
  #    Then CORDON — deregister the idle slots so no new job can reach this
  #    host, and leave the busy ones alone; GitHub refuses those anyway, and
  #    that refusal is the guarantee that nothing running is interrupted.
  #    Re-issued every tick on purpose: it is idempotent, and a slot whose
  #    deregistration failed once must not be the reason a host takes another
  #    job. A host already cordoned stays cordoned whatever its reservation
  #    says: a cordon is never walked back into a reservation, because its
  #    deregistered slots do not come back.
  if [ "$busy" -gt 0 ]; then
    if [ "$cordoned" != "1" ] && [ "$reserved_for" -lt "$reg_grace" ]; then
      echo "reserve:$reason busy=$busy reserved_for=${reserved_for}s<${reg_grace}s"
      return 0
    fi
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

# recycle_surge_demand <demand_jobs> <recycling_hosts> <recycling_busy> \
#                      <max_hosts> <jobs_per_host> [<min_hosts>]
#
# The demand the autoscaler should read, in JOBS, given the hosts mid-recycle.
# Pure, like recycle_decision, and for the same reason.
#
#   demand_jobs     : queued + in-progress jobs this pool can serve.
#   recycling_hosts : RUNNING hosts in the recycle set this tick - reserved or
#                     cordoned, not retired.
#   recycling_busy  : the jobs those hosts are executing, summed.
#   max_hosts       : the pool's ceiling in normal operation.
#   jobs_per_host   : the autoscaler's single_instance_assignment - how many
#                     jobs it buys one host for (slots minus headroom, >= 1).
#   min_hosts       : the warm floor (default 0).
#
# The autoscaler sizes the pool to ceil(demand / jobs_per_host). A host in the
# recycle set is worth exactly ONE host to that arithmetic - it carries its own
# running jobs and, once cordoned, takes nothing new - so its jobs come out of
# the shared demand and it goes back in as one host's worth:
#
#   shared    = min(demand - recycling_busy, max_hosts * jobs_per_host)
#   shared    = max(shared, min_hosts * jobs_per_host)   while recycling only
#   published = shared + recycling_hosts * jobs_per_host
#
# ceil(published / jobs_per_host) is then recycling_hosts PLUS the hosts the
# rest of the work needs: the replacements are bought while the old hosts still
# stand. The warm floor joins the shared part only while something recycles, so
# recycling the last warm host buys its replacement first instead of letting
# the pool touch zero; with nothing recycling the autoscaler's own min_replicas
# already holds that floor and the demand is left alone. The cap is on the
# SHARED part only, so hosts outside the recycle set never exceed max_hosts and
# the whole pool never exceeds max_hosts + recycling_hosts - which the
# autoscaler's max_replicas (max_hosts + recycle_max_unavailable) bounds a
# second time. With nothing recycling this is min(demand, max_hosts *
# jobs_per_host): the controller now enforces max_hosts itself, because
# max_replicas carries the surge headroom and is no longer it.
#
# Malformed recycle input degrades to the plain capped demand - never to a
# number that buys hosts nobody asked for. Echoes one non-negative integer.
recycle_surge_demand() {
  local demand="${1:-0}" hosts="${2:-0}" busy="${3:-0}" maxh="${4:-0}" per="${5:-1}"
  local minh="${6:-0}"
  case "$demand" in '' | *[!0-9]*) demand=0 ;; esac
  case "$maxh" in '' | *[!0-9]*) maxh=0 ;; esac
  case "$minh" in '' | *[!0-9]*) minh=0 ;; esac
  case "$per" in '' | *[!0-9]*) per=1 ;; esac
  [ "$per" -ge 1 ] || per=1
  case "$hosts$busy" in *[!0-9]*) hosts=0; busy=0 ;; esac
  [ "$minh" -le "$maxh" ] || minh=$maxh

  local shared=$((demand - busy))
  [ "$shared" -lt 0 ] && shared=0
  local cap=$((maxh * per))
  [ "$shared" -gt "$cap" ] && shared=$cap
  if [ "$hosts" -gt 0 ] && [ "$shared" -lt $((minh * per)) ]; then
    shared=$((minh * per))
  fi
  echo $((shared + hosts * per))
}

# recycle_surge_floor <published_jobs> <jobs_per_host> <min_hosts>
#
# The fewest RUNNING hosts an idle drain may leave while a recycle is live:
# ceil(published / jobs_per_host), never below min_hosts. This is the pool size
# the autoscaler is being told to hold, so draining an idle host below it is
# pure churn - the autoscaler reads the same surge on the next tick and buys
# the host straight back. It is what keeps a replacement bought for a reserved
# host alive until the host it replaces is gone. Echoes one integer.
recycle_surge_floor() {
  local pub="${1:-0}" per="${2:-1}" minh="${3:-0}"
  case "$pub" in '' | *[!0-9]*) pub=0 ;; esac
  case "$minh" in '' | *[!0-9]*) minh=0 ;; esac
  case "$per" in '' | *[!0-9]*) per=1 ;; esac
  [ "$per" -ge 1 ] || per=1
  local want=$(((pub + per - 1) / per))
  [ "$want" -lt "$minh" ] && want=$minh
  echo "$want"
}
