#!/usr/bin/env bash
# ci-runner-host-pool — the controller's PIN HOLD rule, as a PURE function.
#
# WHY THIS FILE EXISTS
#
# A pull request between its fast tier and its heavy tier is a host that is idle
# and must not be taken away: the run's remaining jobs name that host by label,
# and a host that is gone is a label nothing answers. The same is true of a host
# whose shared database the run's other jobs are still talking to.
#
# So a host carries a PIN HOLD — a workflow run id and an expiry, written by the
# anchor job with `ci-pin-hold --run <id> --ttl <seconds>` and published into the
# host's own guest attributes. The controller reads it AFTER it has reached a
# verdict, and downgrades `cordon:`, `retire:` and `drain:` to a no-op while the
# hold is live. A veto, not an argument: recycle_decision() and drain_decision()
# keep their signatures, both removal paths funnel through the one gate, and the
# read costs a round trip only for a host the controller was about to remove.
#
# THE RULE IS NOT THE BEACON'S RULE — IT IS MONOTONIC
#
# Guest attributes are writable by any process on the VM, job code included, so
# a co-tenant — another pull request's job, on another slot of the same host —
# can PUT a syntactically valid but ALREADY EXPIRED value over the live one.
# beacon_gate()'s first-occurrence-wins rule does not help: it settles duplicate
# rows within one read, and cannot recover a value that was overwritten before
# the read happened. Left at that, the cheapest attack on this design would be
# to shorten somebody else's hold and have the controller delete the host, and
# the shared stack on it, for you — during a gap between that run's jobs, with
# no forged privilege at all.
#
# So the caller keeps the GREATEST EXPIRY IT HAS EVER SEEN for that host and
# passes it in, and the verdict is taken against that rather than against the
# value in front of us. A co-tenant can then only ever EXTEND a hold, never
# shorten one. Two things bound what extending can cost:
#
#   * the expiry is CLAMPED to <max_hold> on read, because job code can equally
#     write one ten years out; and
#   * a hold nobody renews lapses on its own, so the worst an abandoned or
#     forged hold buys is one host kept warm to the ceiling — the same cost as
#     a slow job, with the orphan rules unchanged above it.
#
# And a MALFORMED hold means keeping the host, not dropping it: a broken
# publisher must not read as consent to delete. That is the same invariant
# beacon_decision() carries, for the same reason — the action being authorised
# is irreversible, and "we did not get an answer" never authorises it.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# WHEN THE MECHANISM DOES NOT EXIST AT ALL, THE VETO PROTECTS NOTHING
#
# Rule 1 below reads a failed read as "we did not get an answer" and keeps the
# host. That is right for the failures it was written for — a timeout, a quota,
# the per-instance rate limit — because a hold may well be sitting there behind
# the failure. It is wrong for one failure, and that one failure is total:
#
#   ERROR: HTTPError 412: Constraint
#   constraints/compute.disableGuestAttributesAccess violated for project N.
#
# An org policy that disables guest-attribute ACCESS disables the WRITE as well
# as the read, so `ci-pin-hold` on a host cannot publish a hold, no hold can
# exist, and there is nothing behind the failure to protect. Left as a keep it
# is not a conservative default — it is a permanent, silent veto on every
# removal the controller will ever decide, for every host, on every tick.
#
# Measured on 2026-08-24 in a live fleet: the constraint is enforced org-wide,
# so both IntegrateIT pools reported `ci_pin_holds_honoured` equal to their own
# host count on all 91 points of a six-hour window, `ci_drain_verdicts` and
# `ci_recycle_verdicts` zero on every one of them, and nine hosts sat on a stale
# instance template for a day with `min_hosts` set to zero. Every series read
# healthy. The pool simply never shrank and never upgraded again.
#
# So the caller classifies its own error and says so, and this rule answers the
# only honest answer available: free. It is a NARROW gate on purpose — the
# caller must have matched the constraint by name. A bare 403 is NOT this case:
# that is the controller's own IAM, a hold can still have been written by job
# code, and the keep is correct there.

# pin_hold_decision <read_status> <key_present> <raw> <cached_run> \
#                   <cached_expiry> <now_epoch> <max_hold> [<reads_disabled>]
#
#   read_status  : exit status of the get-guest-attributes call. NON-ZERO IS NOT
#                  "no hold" — it is "we did not get an answer".
#   key_present  : 1 if the read returned a row for the hold key, 0 if the read
#                  SUCCEEDED and the key simply is not there.
#   raw          : the published value, verbatim: "<run> <expiry_epoch>". The
#                  helper writes an EMPTY value to release, so an empty raw with
#                  key_present=1 is a release, not a malformed hold.
#   cached_run   : the run id belonging to the greatest expiry seen so far.
#   cached_expiry: that expiry, epoch seconds. 0 or unparseable means nothing has
#                  been seen for this host.
#   now_epoch    : the controller's clock.
#   max_hold     : the ceiling any single hold may reach from now, in seconds.
#   reads_disabled : 1 only when the caller matched
#                  `constraints/compute.disableGuestAttributesAccess` in the
#                  error it got back — i.e. guest attributes are administratively
#                  off for this project, so no hold can have been published.
#                  Defaults to 0, which preserves every existing caller.
#
# Echoes "hold:run=<id> expiry=<epoch> <reason>" or "free:<reason>", and always
# exits 0 — the verdict is the output, not the status, like the other rules.
#
# On "hold:" the run and expiry are the MERGED pair the caller should remember:
# whichever of the published and cached holds reaches further. On a read that
# failed they are the cached pair, and the caller must leave its cache untouched
# — a failed read is not evidence about a hold either way.
pin_hold_decision() {
  local read_status="${1:-1}"
  local present="${2:-0}"
  local raw="${3:-}"
  local c_run="${4:-}"
  local c_exp="${5:-0}"
  local now="${6:-0}"
  local max_hold="${7:-7200}"
  local reads_disabled="${8:-0}"

  # A cache this process wrote can still be garbage: truncated by a reboot
  # mid-write, or left over from an older format. Sanitised here rather than at
  # the call site so the rule is total over its inputs, and so a corrupt file
  # can neither veto forever nor abort the tick on a numeric comparison.
  case "$c_exp" in '' | *[!0-9]*) c_exp=0 ;; esac
  case "$c_run" in *[!0-9]*) c_run="" ;; esac
  if [ "$c_exp" -le 0 ] || [ -z "$c_run" ]; then
    c_exp=0
    c_run=""
  fi
  case "$max_hold" in '' | *[!0-9]*) max_hold=7200 ;; esac
  case "$now" in '' | *[!0-9]*) now=0 ;; esac

  # 0. The mechanism does not exist here. Checked BEFORE rule 1 because it is a
  #    strictly more specific reading of the same failed read, and checked
  #    against the CALLER'S classification rather than a status code, because
  #    412 on its own is not the fact — the constraint name is. See the header
  #    for why this is the one failure that does not mean "we did not get an
  #    answer": the write is disabled by the same policy as the read, so there
  #    is no hold to be wrong about. Nothing is cached and nothing is consulted;
  #    a stale cache entry from before the policy landed must not outlive it.
  if [ "$reads_disabled" = "1" ]; then
    echo "free:guest-attributes-unavailable"
    return 0
  fi

  # 1. The mechanism failed: API error, timeout, permission, quota. Guest
  #    attributes are rate limited per instance, so a busy fleet is exactly when
  #    this happens — and reading it as "no hold" would delete pinned hosts
  #    because the fleet got busy, which is the worst possible correlation. The
  #    cache is not what grants permission to keep here; it only supplies the
  #    pair to report, and it is deliberately left unchanged by this branch.
  if [ "$read_status" != "0" ]; then
    echo "hold:run=$c_run expiry=$c_exp read-failed status=$read_status"
    return 0
  fi

  local p_run="" p_exp=0 clamped=""

  # 2. The read succeeded and the key carries a value. An EMPTY value is the
  #    helper's release and is not malformed — it publishes nothing, and the
  #    cache below decides what is left standing. Anything else that is not
  #    exactly "<digits> <digits>" is a broken publisher: hold, and keep it away
  #    from the cache so one bad write cannot become the remembered answer.
  if [ "$present" = "1" ] && [ -n "$raw" ]; then
    local f1="" f2="" extra=""
    case "$raw" in
      # A herestring reads one line. A value carrying a newline would have its
      # tail silently dropped, so "123 456<newline>anything" must not be able to
      # present itself as a well-formed hold.
      *"
"*)
        echo "hold:run=$c_run expiry=$c_exp malformed-hold"
        return 0
        ;;
    esac
    read -r f1 f2 extra <<<"$raw"
    case "${f1:-}" in '' | *[!0-9]*) f1="" ;; esac
    case "${f2:-}" in '' | *[!0-9]*) f2="" ;; esac
    if [ -z "$f1" ] || [ -z "$f2" ] || [ -n "$extra" ]; then
      echo "hold:run=$c_run expiry=$c_exp malformed-hold"
      return 0
    fi
    p_run="$f1"
    p_exp="$f2"

    # The clamp. Job code can write an expiry ten years out just as easily as a
    # correct one, and an unclamped value would make the host permanently
    # undeletable — a billing, invisible resident of a pool that reports the
    # right number of hosts. The ceiling is the same one the host helper
    # enforces on --ttl; see PIN_MAX_TTL in host-startup.sh.
    if [ "$p_exp" -gt "$((now + max_hold))" ]; then
      p_exp=$((now + max_hold))
      clamped=" clamped"
    fi
  fi

  # 3. The monotonic merge. The published hold wins only by reaching FURTHER; a
  #    value that reaches less far is either the same hold seen again or a
  #    co-tenant shortening someone else's, and neither may move the deadline
  #    backwards.
  local m_run m_exp src
  if [ "$p_exp" -gt "$c_exp" ]; then
    m_run="$p_run"
    m_exp="$p_exp"
    src="published"
  else
    m_run="$c_run"
    m_exp="$c_exp"
    src="cached"
  fi

  if [ "$m_exp" -le 0 ]; then
    echo "free:no-hold"
    return 0
  fi

  if [ "$m_exp" -gt "$now" ]; then
    echo "hold:run=$m_run expiry=$m_exp live $src$clamped remaining=$((m_exp - now))s"
    return 0
  fi

  # 4. The only case that authorises the removal to proceed: a hold existed, and
  #    it has lapsed. The caller drops its cache entry here, which is also what
  #    stops the next reading of this host inheriting a dead veto.
  echo "free:expired run=$m_run expiry=$m_exp now=$now"
  return 0
}
