# shellcheck shell=bash
# fleet-audit — whether ONE repository is in the state the fleet intends, as a
# PURE function over facts somebody else collected.
#
# WHY THIS EXISTS
#
# Every other gate in this repository checks this repository. None of them can
# see across the repository boundary, and the outages that cost the most here
# were all on the other side of it:
#
#   * eleven of thirteen pools pinned off, so no host could ever upgrade itself
#   * a merge lane configured but never armed, whose job skips in silence
#   * a required check no workflow emits, which blocks every merge forever and
#     renders as nothing at all — GitHub says `blocked`, the lane logs
#     `skip:missing-required`, and nothing anywhere is red
#   * wedged queued runs filling the 50-run page, so demand reads a clean zero
#
# What those share is not a bug in any one repository. It is that a repository
# in the broken state looks EXACTLY like a repository that is simply idle, and
# nobody was asking the fleet-wide question. This file is that question.
#
# WHY EVERY UNKNOWN IS A FINDING, NOT A PASS
#
# The inverse of the reaper's rule, and for the inverse reason. The reaper
# destroys, so its unknowns keep. This one only REPORTS, so an unknown costs a
# line of output and buys the guarantee that "did not check" and "found nothing"
# never render the same — the invariant the whole audit exists to restore. An
# audit that quietly passes on a failed API read is worse than no audit, because
# it is the same green a healthy fleet produces.
#
# Tenancy-agnostic: no customer literals, no project ids, no repository names.
# Every threshold and every expected value is an input.

# _fleet_say — record one finding.
#
# Assigns to `found` in the caller. Bash scopes locals dynamically, so this sets
# `fleet_verdict`'s own variable rather than creating a global — which is what
# lets the "printed nothing" case below be a bug rather than a clean result.
_fleet_say() {
  found=1
  echo "$1"
}

# ---------------------------------------------------------------------------
# fleet_verdict — every finding for one repository.
#
#   fleet_verdict "key=value;key=value;..."
#
# Prints zero or more finding lines and returns 0. A compliant repository prints
# exactly `ok:compliant`, so an empty line is always a bug in the caller rather
# than a clean result.
#
# Findings are `fail:` when the state silently stops work — a merge that can
# never happen, a pool that can never upgrade — and `warn:` when it degrades
# something a human would still notice. The distinction is not severity in the
# abstract; it is whether anything else in the system would ever tell you.
#
# Facts, all optional, all defaulting to unknown:
#   tier          pool | lane | dormant | empty | source | (anything else)
#   has_lane      1 if .github/workflows/merge-lane.yml exists
#   has_guard     1 if the pr-guard caller exists
#   has_reaper    1 if the branch-reaper caller exists
#   lane_pin      the sha the lane caller pins, "" if unread
#   guard_pin     ditto for the guard
#   reaper_pin    ditto for the reaper
#   want_pin      the sha every caller should pin
#   enabled       value of MERGE_LANE_ENABLED
#   armed         value of MERGE_LANE_ARMED
#   app_id        1 if the MERGE_APP_ID secret exists
#   app_key       1 if the MERGE_APP_PRIVATE_KEY secret exists
#   checks_match  1 if the caller's required-checks equal the ruleset's
#   ruleset       1 if a ruleset protects the default branch
#   has_ci        1 if the repository has any workflow at all
#   runners       count of registered self-hosted runners
#   online        count of those that are online
#   corpses       queued runs OUTSIDE the demand window
#   demand        queued runs INSIDE it — what the controller scales on
#   page          the size of the queued-run page the controller reads
# ---------------------------------------------------------------------------
fleet_verdict() {
  local facts="${1:-}"
  local tier="" has_lane="" has_guard="" has_reaper=""
  local lane_pin="" guard_pin="" reaper_pin="" want_pin=""
  local enabled="" armed="" app_id="" app_key=""
  local checks_match="" ruleset="" has_ci=""
  local runners="" online="" corpses="" demand="" page=""
  local found=0

  # `IFS` is scoped to the `read` rather than to the function: a function-local
  # IFS has to be unset to restore it, and unsetting a local exposes the global
  # of the same name instead of the value the caller had.
  local -a pairs=()
  IFS=';' read -r -a pairs <<< "$facts"

  local pair key value
  for pair in "${pairs[@]}"; do
    [ -z "$pair" ] && continue
    key="${pair%%=*}"
    value="${pair#*=}"
    case "$key" in
      tier) tier="$value" ;;
      has_lane) has_lane="$value" ;;
      has_guard) has_guard="$value" ;;
      has_reaper) has_reaper="$value" ;;
      lane_pin) lane_pin="$value" ;;
      guard_pin) guard_pin="$value" ;;
      reaper_pin) reaper_pin="$value" ;;
      want_pin) want_pin="$value" ;;
      enabled) enabled="$value" ;;
      armed) armed="$value" ;;
      app_id) app_id="$value" ;;
      app_key) app_key="$value" ;;
      checks_match) checks_match="$value" ;;
      ruleset) ruleset="$value" ;;
      has_ci) has_ci="$value" ;;
      runners) runners="$value" ;;
      online) online="$value" ;;
      corpses) corpses="$value" ;;
      demand) demand="$value" ;;
      page) page="$value" ;;
    esac
  done

  # --- tiers that are audited for staying what they are ----------------------
  #
  # Checked first and returned from, because every rule below asks about a lane
  # these tiers are not supposed to have. Running them anyway would report a
  # dormant repository as un-onboarded once per audit, forever, which is how an
  # audit teaches people to stop reading it.
  case "$tier" in
    empty)
      # A repository with no default branch grew one the moment somebody pushed.
      [ "$has_ci" = "1" ] && _fleet_say "fail:empty-repo-has-ci reclassify=lane"
      [ "$found" = "0" ] && echo "ok:compliant tier=empty"
      return 0
      ;;
    dormant)
      # THE ROW THAT EARNS THE MANIFEST. A dormant repository is exempt from the
      # lane because it has no CI for a lane to gate on. Add one workflow and
      # that reason is void — but nothing anywhere would have said so, and the
      # repository would sit there running checks that gate no merge.
      [ "$has_ci" = "1" ] && _fleet_say "fail:dormant-repo-has-ci reclassify=lane"
      [ "$has_ci" = "" ] && _fleet_say "warn:ci-unknown could-not-list-workflows"
      [ "$found" = "0" ] && echo "ok:compliant tier=dormant"
      return 0
      ;;
    source)
      # This repository calls its own workflows through the `-self` variants, so
      # it has no pin to itself and pin rules would report a false stale.
      [ "$found" = "0" ] && echo "ok:compliant tier=source"
      return 0
      ;;
    pool|lane) : ;;
    *)
      # An unrecognised tier is an operator typo, and reading it as `lane` would
      # invent findings while reading it as `dormant` would suppress real ones.
      echo "fail:unknown-tier tier=${tier:-<empty>}"
      return 0
      ;;
  esac

  # --- onboarding ------------------------------------------------------------
  #
  # The lane is checked before its configuration: a repository with no caller
  # has nothing for the arming rules to be true or false about, and reporting
  # "not armed" alongside "not onboarded" reads as two problems.
  if [ "$has_lane" != "1" ]; then
    _fleet_say "fail:no-merge-lane tier=$tier"
  else
    [ "$has_guard" != "1" ] && _fleet_say "warn:no-pr-guard"
    [ "$has_reaper" != "1" ] && _fleet_say "warn:no-branch-reaper"

    # --- pins ----------------------------------------------------------------
    #
    # Each caller is reported separately. They drift apart in practice, because
    # a release that touches only one of them gets bumped only where somebody
    # noticed — measured 2026-08-27, the lane sat at v5.73.0 in ten repositories
    # while the guard and the reaper beside it were still on v5.71.0.
    if [ -z "$want_pin" ]; then
      _fleet_say "warn:expected-pin-unknown"
    else
      local name pin present
      for name in lane guard reaper; do
        case "$name" in
          lane) pin="$lane_pin"; present="$has_lane" ;;
          guard) pin="$guard_pin"; present="$has_guard" ;;
          reaper) pin="$reaper_pin"; present="$has_reaper" ;;
        esac
        # An absent caller is already reported above, and has no pin to judge.
        [ "$present" != "1" ] && continue
        if [ -z "$pin" ]; then
          # A caller that EXISTS and whose pin could not be read is the exact
          # shape this audit exists to refuse: reading it as "not stale" makes a
          # repository whose file failed to download indistinguishable from one
          # that is up to date.
          _fleet_say "warn:${name}-pin-unreadable"
        elif [ "$pin" != "$want_pin" ]; then
          _fleet_say "fail:${name}-pin-stale pin=${pin:0:8} want=${want_pin:0:8}"
        fi
      done
    fi

    # --- arming --------------------------------------------------------------
    #
    # `MERGE_LANE_ENABLED` gates the job itself, so an unset variable is a lane
    # that skips on every CI completion. Skipped renders as neither red nor
    # green; the repository merges nothing and looks untouched.
    if [ "$enabled" != "true" ]; then
      _fleet_say "fail:lane-not-enabled enabled=${enabled:-<unset>}"
    elif [ "$armed" != "true" ]; then
      # Enabled but not armed is the deliberate dry-run state, and it is a
      # legitimate place to sit for a while — so a warning, not a failure.
      _fleet_say "warn:lane-dry-run armed=${armed:-<unset>}"
    fi

    # The token the lane mints comes from these two. Present-but-enabled is the
    # ordinary state; enabled-without-them is a lane that goes red on every run
    # with an authentication error, which reads like a broken lane rather than
    # an unfinished setup.
    if [ "$enabled" = "true" ]; then
      [ "$app_id" != "1" ] && _fleet_say "fail:missing-app-id-secret"
      [ "$app_key" != "1" ] && _fleet_say "fail:missing-app-key-secret"
    fi

    # --- the phantom required check ------------------------------------------
    #
    # The lane does not read the ruleset. Its `required-checks` input is a
    # literal list, so the two are separate edits and a disagreement is silent
    # in BOTH directions: a name only in the ruleset blocks a merge the lane
    # thinks is ready, and a name only in the lane list holds a merge GitHub
    # would have allowed. A name in neither place that no workflow emits is the
    # worst of the three — a permanent, invisible block.
    if [ "$armed" = "true" ]; then
      if [ -z "$checks_match" ]; then
        _fleet_say "warn:required-checks-uncomparable"
      elif [ "$checks_match" != "1" ]; then
        _fleet_say "fail:required-checks-disagree lane-list-vs-ruleset"
      fi
      [ "$ruleset" = "0" ] && _fleet_say "warn:no-ruleset-on-default-branch"
    fi
  fi

  # --- pool health -----------------------------------------------------------
  #
  # Only for `pool`. A `lane` repository has no runners by design, and reporting
  # zero online for it would be a finding on every audit of a healthy repo.
  if [ "$tier" = "pool" ]; then
    if [ -z "$runners" ] || [ -z "$online" ]; then
      _fleet_say "warn:runner-count-unknown"
    elif [ "$runners" = "0" ]; then
      # ZERO REGISTERED RUNNERS IS THE HEALTHY IDLE STATE OF THESE POOLS.
      #
      # They scale to zero; the only always-on cost is the controller. The
      # first draft reported zero as a failure and lit up four healthy
      # repositories on its first live run — the exact noise that teaches
      # people to stop reading an audit, in the audit written because nobody
      # was reading anything.
      #
      # What makes zero a failure is something WAITING for it. Demand inside
      # the controller's own window and no runner to serve it is a pool that
      # is not scaling out, which is the outage this file was written after.
      if [ -z "$demand" ]; then
        _fleet_say "warn:demand-unknown cannot-judge-empty-pool"
      elif [ "$demand" != "0" ]; then
        _fleet_say "fail:no-runners-under-demand queued=$demand"
      fi
    elif [ "$online" = "0" ]; then
      # Distinguished from an empty pool deliberately, and unconditional on
      # demand: hosts that registered and then went unreachable are a fault
      # whether or not anything is queued right now, and they are also what
      # the controller will not replace on its own.
      _fleet_say "fail:all-runners-offline registered=$runners"
    fi

    # Corpses are counted against the page the controller actually reads, not
    # against a fixed number, because the harm is proportional: the page holds
    # `page` runs, corpses never leave it, and at `page` corpses every real
    # queued run is pushed off — before the demand budget, so it never registers
    # in `ci_demand_runs_skipped`. Half a page is where that becomes plausible
    # rather than theoretical.
    if [ -n "$corpses" ] && [ -n "$page" ] && [ "$page" -gt 0 ] 2>/dev/null; then
      if [ "$corpses" -ge "$page" ] 2>/dev/null; then
        _fleet_say "fail:queued-page-full corpses=$corpses page=$page"
      elif [ $((corpses * 2)) -ge "$page" ] 2>/dev/null; then
        _fleet_say "warn:queued-page-filling corpses=$corpses page=$page"
      fi
    fi
  fi

  [ "$found" = "0" ] && echo "ok:compliant tier=$tier"
  return 0
}
