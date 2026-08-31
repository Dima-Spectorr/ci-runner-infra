#!/usr/bin/env bash
# The rule that decides whether a project is still receiving runner
# infrastructure, separated from the call that fetches the evidence so it can be
# tested against the broken states rather than only against the healthy one.
#
# That separation is not stylistic here. The whole point of this check is to
# catch a state that looks green, so a check that has only ever been exercised
# on a healthy project proves nothing at all — it is the same class of thing it
# was written to prevent. The self-test drives every arm below, including the
# refusal that produced no log and no build steps.
#
# apply_verdict <found> <status> <age-seconds>
#
#   found  1 if a ci-runner-apply-* build was found at all, 0 if the listing
#          succeeded and contained none. NOT the same as a failed listing —
#          the caller handles a refused API call before it gets here, because
#          a refusal leaves every number below stale rather than false.
#   status the newest such build's status, verbatim from Cloud Build.
#   age    seconds since that build was created, or a negative number when the
#          create time could not be parsed.
#
# Prints exactly one verdict:
#
#   missing            — the listing worked and there is no apply build in it.
#                        A trigger that stopped firing leaves no failed build
#                        behind, so this arm is the only thing that sees it.
#   failed:<status>    — the newest apply build did not succeed.
#   inflight:<status>  — it is still running. Deliberately NOT ok: reporting a
#                        green that has not happened yet is how a check ends up
#                        confirming the state it was meant to question.
#   ok                 — the newest apply build succeeded. Says nothing about
#                        HOW LONG AGO; the caller alerts on the age separately,
#                        because a project whose last successful apply was in
#                        June is green by this rule and broken in fact.
apply_verdict() {
  local found="${1:-}" status="${2:-}" age="${3:-}"

  # Anything that is not exactly 1 is treated as "not found". A caller that
  # hands over an empty string because a pipeline failed midway must not have
  # that read as a healthy pool, and this is the branch it lands in.
  [ "$found" = "1" ] || { printf 'missing'; return 0; }

  # A found build with no status is not a status this rule can pass. Same
  # reasoning as above: the ambiguous input takes the arm that raises something.
  [ -n "$status" ] || { printf 'failed:unknown'; return 0; }

  case "$status" in
    SUCCESS)
      printf 'ok'
      ;;
    WORKING | QUEUED | PENDING)
      printf 'inflight:%s' "$status"
      ;;
    *)
      # Everything else, by name rather than by list. FAILURE, TIMEOUT,
      # CANCELLED, EXPIRED, INTERNAL_ERROR and STATUS_UNKNOWN are all "this
      # apply did not land", and a status Cloud Build adds tomorrow that this
      # file has never heard of belongs on this arm too — an unrecognised
      # status must not fall through to ok.
      printf 'failed:%s' "$status"
      ;;
  esac

  # `age` is unused by the verdict on purpose and accepted anyway, so the
  # caller passes the whole record and the signature does not change when the
  # staleness threshold moves. Staleness is a THRESHOLD, which belongs in the
  # alert policy where each project can pick its own, not in a rule compiled
  # into every controller in the fleet.
  : "$age"
  return 0
}
