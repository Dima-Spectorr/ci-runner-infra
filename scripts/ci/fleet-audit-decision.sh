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

# _fleet_is_number — a fact that may be compared with `-ge`.
#
# `[ "$x" -ge "$y" ]` on a non-numeric operand exits 2, and 2 is falsey, so an
# unparseable fact silently takes the "not over the threshold" branch. Every
# numeric comparison in this file guards its operands with this first.
_fleet_is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

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
#   tier          pool | lane | checks | dormant | empty | source | (anything else)
#   has_lane      1 if .github/workflows/merge-lane.yml exists
#   has_guard     1 if the pr-guard caller exists
#   has_reaper    1 if the branch-reaper caller exists
#   lane_pin      the sha the lane caller pins, "" if unread
#   guard_pin     ditto for the guard
#   reaper_pin    ditto for the reaper
#   want_pin      the sha every caller should pin
#   enabled       value of MERGE_LANE_ENABLED
#   armed         value of MERGE_LANE_ARMED
#   vars_readable 0 if the variables API refused the token — see below
#   app_id        1 if the MERGE_APP_ID secret exists
#   app_key       1 if the MERGE_APP_PRIVATE_KEY secret exists
#   secrets_readable  0 if the secrets API refused the token
#
# READABILITY IS A SEPARATE FACT FROM THE VALUE, and it has to be, because the
# variables and secrets APIs answer a token that lacks the scope with a 403 and
# a token that is fine with an empty list — and `MERGE_LANE_ENABLED` being
# absent looks exactly the same from here. The first live run under the App
# token reported EVERY repository as `lane-not-enabled`, including the twelve
# where the lane merges pull requests daily, because the App had no
# `Variables: read`. An audit that confidently states the opposite of the truth
# is worse than one that says nothing: it is the failure this file was written
# to catch, committed by this file. Only an explicit `0` means unreadable; an
# absent fact is read as readable, so a caller that does not supply it keeps
# the old behaviour rather than silently warning on every repository.
#   checks_match  1 if the caller's required-checks equal the ruleset's
#   ruleset       1 if a ruleset protects the default branch
#   has_ci        1 if the repository has any workflow at all
#   runners       count of registered self-hosted runners
#   online        count of those that are online
#   corpses       queued runs OUTSIDE the demand window
#   demand        queued runs INSIDE it — what the controller scales on
#   settled       the subset of that demand older than the pool's boot grace
#   page          the size of the queued-run page the controller reads
#
# `source` tier only — the unreleased backlog (see the rule below):
#   tag_readable      1 when the floating major tag resolved, 0 when it did not
#   backlog           commits on the default branch newer than that tag which
#                     touch a released surface; "" when it could not be counted
#   backlog_hours     age in whole hours of the OLDEST of those commits; "" when
#                     it could not be determined
#   backlog_max_hours how long that oldest commit may sit before the delay has
#                     become an omission. "" takes the default below; `0` opts
#                     out, the same spelling every numeric knob in merge-lane.yml
#                     uses for "turn this off".
# ---------------------------------------------------------------------------

# How long finished work may sit on the default branch unpublished before this
# stops being a batch and starts being an omission.
#
# DERIVED, NOT CHOSEN. Measured over the 120 first-parent merges on this
# repository's default branch that touched `modules/` or `scripts/` and were not
# themselves a `chore(release)`, timed to the next `chore(release)` merge:
#
#   0h: 84   1h: 13   2h: 7   3h: 6   4h: 2   8h: 2
#   30h: 1   31h: 1   52h: 2   53h: 1
#   227h: 1   <- a9644d7, "a truncated runner listing … deleted it" (#765)
#
# 119 of 120 were swept up inside 53 hours. The single outlier, a9644d7, sat for
# nine and a half days — a controller fix that deleted working hosts, merged and
# reaching nobody — and nothing anywhere said so.
#
# WHAT THIS DOES AND DOES NOT CATCH. It would NOT have caught the commit #960
# was filed about: `afc9bf3` (#957) was published about two hours after it
# merged and never came close to any threshold worth setting. That is the point
# rather than a gap. #960 found a real hole by looking at a case that happened
# to fall through it, and the hole is that NOTHING bounds the wait — not that
# any particular commit waited too long. So this is a bound on the batch, and
# a9644d7 is what an unbounded batch actually costs.
#
# 72 hours is above every healthy observation with room to spare and far below
# the one real failure, so it fires on the shape that went wrong and is silent
# on the shape that is working as intended. It is a ceiling, NOT a target: a
# backlog under it is a perfectly healthy state and is reported as compliant.
#
# The default lives HERE and nowhere else on purpose. fleet-audit.sh passes the
# operator's override through unchanged and supplies no default of its own; two
# copies of a number like this drift, and the copy that drifts is the one that
# silently stops matching what the rule actually enforces.
FLEET_BACKLOG_MAX_HOURS_DEFAULT=72
fleet_verdict() {
  local facts="${1:-}"
  local tier="" has_lane="" has_guard="" has_reaper=""
  local lane_pin="" guard_pin="" reaper_pin="" want_pin=""
  local enabled="" armed="" app_id="" app_key=""
  local vars_readable="" secrets_readable=""
  local checks_match="" ruleset="" has_ci=""
  local runners="" online="" corpses="" demand="" settled="" page=""
  local tag_readable="" backlog="" backlog_hours="" backlog_max_hours=""
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
      vars_readable) vars_readable="$value" ;;
      app_id) app_id="$value" ;;
      app_key) app_key="$value" ;;
      secrets_readable) secrets_readable="$value" ;;
      checks_match) checks_match="$value" ;;
      ruleset) ruleset="$value" ;;
      has_ci) has_ci="$value" ;;
      runners) runners="$value" ;;
      online) online="$value" ;;
      corpses) corpses="$value" ;;
      demand) demand="$value" ;;
      settled) settled="$value" ;;
      page) page="$value" ;;
      tag_readable) tag_readable="$value" ;;
      backlog) backlog="$value" ;;
      backlog_hours) backlog_hours="$value" ;;
      backlog_max_hours) backlog_max_hours="$value" ;;
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
      # repository would sit there running checks that gate no merge. Whether it
      # becomes `lane` or `checks` is a human call: it turns on whether changes
      # arrive by pull request at all.
      [ "$has_ci" = "1" ] && _fleet_say "fail:dormant-repo-has-ci reclassify=lane-or-checks"
      [ "$has_ci" = "" ] && _fleet_say "warn:ci-unknown could-not-list-workflows"
      [ "$found" = "0" ] && echo "ok:compliant tier=dormant"
      return 0
      ;;
    checks)
      # The mirror image of `dormant`, and it exists for the same reason. This
      # repository has CI and deliberately no merge lane: its changes land by
      # direct push, so there is no pull request for a lane to gate. The fact
      # its exemption rests on is that the checks are actually there — take the
      # workflow away and the repository is running nothing, which reads exactly
      # like a healthy quiet one.
      [ "$has_ci" = "0" ] && _fleet_say "fail:checks-repo-has-no-ci reclassify=dormant"
      [ "$has_ci" = "" ] && _fleet_say "warn:ci-unknown could-not-list-workflows"
      [ "$found" = "0" ] && echo "ok:compliant tier=checks"
      return 0
      ;;
    source)
      # This repository calls its own workflows through the `-self` variants, so
      # it has no pin to itself and pin rules would report a false stale.
      #
      # WHAT IT IS AUDITED FOR INSTEAD: THE UNRELEASED BACKLOG.
      #
      # Nothing else in the fleet can ask this question. Every consumer pins
      # `?ref=vX.Y.Z` or `?ref=v5`, so a change to a released surface reaches
      # nobody until the floating major tag moves past it — and the tag moves
      # only when a `chore(release)` pull request bumps `VERSION`.
      #
      # THE DELAY IS DELIBERATE AND IS NOT WHAT IS BEING CHECKED. `VERSION` is
      # deliberately NOT bumped in the pull request that makes the change:
      # measured over the last 25 first-parent merges, five of the last eight
      # released-surface merges moved no version, because two pull requests in
      # flight at once both pick the same next number and the loser reddens the
      # default branch for every open pull request. Batching is the fix for
      # that, and a per-pull-request bump gate would reinstate it.
      #
      # What went missing is the OTHER end of the batch. A batch nobody sweeps
      # up is indistinguishable from a batch on its way — the same shape as
      # every other finding in this file, and the reason #960 was filed. So the
      # rule is not "did this commit bump" but "has the OLDEST thing waiting
      # been waiting too long".
      #
      # WHY THIS IS NOT A PULL-REQUEST CHECK, AND WHY IT IS NOT RED ON `main`.
      # The condition becomes true through the passage of time, not through a
      # push, so no push-triggered check can fire on it; this audit already runs
      # daily from a schedule, which is the trigger the condition needs. And a
      # scheduled workflow is not a pull request's check, so a `fail:` here
      # turns THIS run red and posts to the audit issue without reddening the
      # default branch — deliberate, because a red default branch blocks and
      # confuses every open pull request, and because release-tag.yml already
      # records what a check that is red on every successful release costs: it
      # trains everyone to ignore the one signal that says a tag sits at the
      # wrong commit.
      if [ "$backlog_max_hours" = "0" ]; then
        # The opt-out, spelled the way every numeric knob in merge-lane.yml
        # spells it. Reported rather than silent: a watchdog somebody turned off
        # and a watchdog that finds nothing must not render the same, which is
        # the invariant this whole file exists for.
        #
        # DELIBERATELY BEFORE THE TAG CHECK, so `0` silences the unreadable-tag
        # finding too. The tag is only read in order to bound the backlog, so an
        # operator who has said they do not want the backlog bounded is not left
        # with a daily failure about the input to a measurement nobody is
        # taking. The tag itself is not unwatched: publish-tag.yml asserts the
        # floating tag on every push, and release-tag.yml on every tag.
        echo "ok:compliant tier=source backlog-watchdog=off"
        return 0
      fi
      local max="${backlog_max_hours:-$FLEET_BACKLOG_MAX_HOURS_DEFAULT}"

      if [ "$tag_readable" = "0" ]; then
        # A `fail:`, not the `warn:` this file gives every other unknown — and
        # the difference is what the unknown is ABOUT. Every other unknown here
        # is a fact about somebody else's repository that the audit merely
        # failed to fetch. This one is the floating tag every consumer in the
        # fleet pins: unreadable means either the ref is gone or it resolves to
        # something no release produced, and both of those are the outage, not a
        # failure to observe it. publish-tag.yml takes exactly this stance about
        # an unreadable version: fail the release rather than move the tag
        # blind. Read as "no tag, so nothing is unreleased" it would be silent
        # forever, which is the one answer that must never be possible here.
        _fleet_say "fail:release-tag-unreadable cannot-bound-the-unreleased-backlog"
      elif ! _fleet_is_number "$backlog"; then
        # Absent AND malformed, together. A non-numeric count reaching `[ -ge ]`
        # makes the test exit 2, which reads as "not over the threshold" — a
        # quiet pass produced by a broken fact, the exact failure mode this file
        # refuses everywhere else.
        _fleet_say "warn:unreleased-backlog-unknown could-not-compare-default-branch-to-tag"
      elif [ "$backlog" = "0" ]; then
        : # Nothing waiting. The healthy end state, reported as compliant below.
      elif ! _fleet_is_number "$backlog_hours" || ! _fleet_is_number "$max"; then
        # The count is known and the age (or the ceiling to judge it against) is
        # not, so the one thing the rule actually judges is missing. A backlog
        # whose age cannot be read is never read as young.
        _fleet_say "warn:unreleased-backlog-age-unknown commits=$backlog oldest=${backlog_hours:-<unset>} max=${max:-<unset>}"
      elif [ "$backlog_hours" -ge "$max" ]; then
        _fleet_say "fail:unreleased-backlog commits=$backlog oldest=${backlog_hours}h max=${max}h open-a-chore-release-pull-request"
      fi

      if [ "$found" = "0" ]; then
        # A non-empty backlog under the ceiling is HEALTHY, and says so with its
        # numbers attached. Printing them on the compliant line is what lets a
        # reader watch a batch grow toward the ceiling instead of finding out
        # only on the day it crosses.
        if [ -n "$backlog" ] && [ "$backlog" != "0" ]; then
          echo "ok:compliant tier=source backlog=$backlog oldest=${backlog_hours}h max=${max}h"
        else
          echo "ok:compliant tier=source backlog=0"
        fi
      fi
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
    if [ "$vars_readable" = "0" ]; then
      # Not "not enabled" — "not known". See the note at the top of the file.
      _fleet_say "warn:lane-arming-unreadable token-lacks-variables-read"
    elif [ "$enabled" != "true" ]; then
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
    if [ "$secrets_readable" = "0" ]; then
      _fleet_say "warn:lane-secrets-unreadable token-lacks-secrets-read"
    elif [ "$enabled" = "true" ]; then
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
        # And demand alone is still not enough. These pools scale FROM zero, so
        # between the first queued run and the first registered host there is a
        # boot window in which an empty pool and a broken pool look identical.
        # Reported without it, the audit failed a repository whose pull request
        # was forty seconds old while its MIG was already at targetSize 2.
        if [ -z "$settled" ]; then
          _fleet_say "warn:demand-age-unknown queued=$demand"
        elif [ "$settled" != "0" ]; then
          _fleet_say "fail:no-runners-under-demand queued=$settled"
        fi
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
