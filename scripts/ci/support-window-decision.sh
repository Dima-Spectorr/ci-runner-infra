#!/usr/bin/env bash
# ci-runner-infra — is a declared version still inside its support window, as a
# PURE function.
#
# WHY THIS FILE EXISTS
#
# Dependabot answers "is a newer version available?". Nothing in the fleet
# answers "is the version we are on still supported?", and those are different
# questions with different failure modes. The measured state of the fleet on
# 2026-08-16, none of which raised a single alert anywhere:
#
#   * Node 18 — end of life 2025-04-30, sixteen months past.
#   * Node 20 — end of life 2026-04-30, past as of this file.
#   * Node 22 — end of life 2027-04-30, so it looks fine; but its ACTIVE
#     support ended 2025-10-21. New applications were being started on it while
#     Node 24 was available and supported until 2026-10-20.
#
# The third line is the one that matters, and it is why this rule reads two
# fields rather than one. A version-behind check cannot see it (22 is not
# behind anything it tracks), and an end-of-life check cannot see it either (the
# EOL date is eight months out). What is wrong is that a NEW adoption chose a
# line with a shorter remaining runway than an available one — a decision that
# is free to reverse on the day it is made and expensive a year later.
#
# THE INVARIANT THAT MATTERS
#
# The dangerous direction is a false CLEAN. A missing feed, an unrecognised
# product or a cycle the upstream never published must read as UNKNOWN and be
# reported as such; it must never read as "supported". The upstream field that
# makes this concrete is `eol: false`, which means "no end-of-life date has
# been announced" and NOT "this version has no end of life" — every React major
# ever released carries `eol: false`, including the ones that have been dead for
# years. A parser that reads that as a boolean reports the whole fleet clean.
#
# The other direction — a false alarm — costs a line in an issue nobody had to
# act on. So where the two trade off, this rule reports rather than stays quiet,
# EXCEPT for the one case where quiet is the point: an existing, already-shipped
# application sitting on a maintenance-only line is a plan, not a defect, and
# is reported at the lowest severity so it does not drown the ones that are.
#
# Tenancy-agnostic — no customer literals, no repository knowledge, no network.
# Consumers adopt it through the contract in docs/dependency-freshness.md.

# --- date arithmetic, without `date` -----------------------------------------
#
# The rule takes dates and must compare them, but shelling out to `date -d`
# would make the verdict depend on GNU coreutils and on the clock of whatever
# host ran it. Both are inputs a self-test cannot pin, and an unpinnable input
# is how a time-dependent rule passes its tests forever and is wrong in
# production every April. `today` is therefore an ARGUMENT, and the conversion
# is pure integer arithmetic (Howard Hinnant's days-from-civil).

# iso_to_days — echoes days since 1970-01-01 for a YYYY-MM-DD string; returns 1
#               and echoes nothing for anything else, including the upstream's
#               `true`/`false`/empty sentinels.
iso_to_days() {
  local iso="$1" y m d era yoe doy doe mp

  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac

  # 10# forces base ten: `08` and `09` are invalid octal, and a month that
  # silently fails to parse is a comparison against zero.
  y=$((10#${iso:0:4}))
  m=$((10#${iso:5:2}))
  d=$((10#${iso:8:2}))
  if [ "$m" -lt 1 ] || [ "$m" -gt 12 ] || [ "$d" -lt 1 ] || [ "$d" -gt 31 ]; then
    return 1
  fi

  if [ "$m" -le 2 ]; then y=$((y - 1)); fi
  era=$(((y >= 0 ? y : y - 399) / 400))
  yoe=$((y - era * 400))
  mp=$((m > 2 ? m - 3 : m + 9))
  doy=$(((153 * mp + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $((era * 146097 + doe - 719468))
}

# --- the upstream's two sentinels, which do not mean the same thing ----------
#
# `eol` and `support` are the same shape and invert each other's booleans:
#
#   eol:     "2026-04-30" a date | true  = already ended, no date
#                                | false = NO DATE ANNOUNCED (not "never")
#   support: "2025-10-21" a date | true  = still actively supported
#                                | false = active support ended, no date
#
# So they get one resolver each. Collapsing them into a shared helper is the
# single most likely way to reintroduce the false clean described above.

# _eol_state <raw> <today_days> — echoes "past", "future:<days-remaining>" or "unknown".
_eol_state() {
  local raw="$1" today="$2" when
  case "$raw" in
    true) echo past; return 0 ;;
    ""|false|null|unknown) echo unknown; return 0 ;;
  esac
  when="$(iso_to_days "$raw")" || { echo unknown; return 0; }
  if [ "$when" -le "$today" ]; then echo past; else echo "future:$((when - today))"; fi
}

# _support_state <raw> <today_days> — echoes "past", "future:<days-remaining>",
#                                     "active" or "unknown".
_support_state() {
  local raw="$1" today="$2" when
  case "$raw" in
    true) echo active; return 0 ;;
    false) echo past; return 0 ;;
    ""|null|unknown) echo unknown; return 0 ;;
  esac
  when="$(iso_to_days "$raw")" || { echo unknown; return 0; }
  if [ "$when" -le "$today" ]; then echo past; else echo "future:$((when - today))"; fi
}

# support_verdict — the rule.
#
#   support_verdict <today> <window_days> <cycle> <eol_raw> <support_raw> \
#                   <best_cycle> <best_eol_raw> <adoption>
#
# `today` and every date argument are YYYY-MM-DD. `best_cycle`/`best_eol_raw`
# describe the longest-runway release line the caller found for the same
# product, empty when it found none. `adoption` is `new` when THIS pull request
# introduces the declaration, anything else otherwise.
#
# Echoes "<code>:<reason>" and exits 0 — the verdict is the OUTPUT, never the
# exit status, so a `set -e` caller cannot be tripped by a verdict it did not
# expect, and a scan of forty declarations cannot be halted by the first one.
#
#   SUP1 unsupported            — running past the end of support. Act now.
#   SUP3 shorter-window-adopted — a NEW declaration took a line with less
#                                 runway than one already available. Act before
#                                 it merges; free today, expensive later.
#   SUP2 expiring               — inside the migration window. Plan it.
#   SUP5 maintenance-only       — out of active support, EOL still ahead.
#                                 Informational; this is what a deliberate
#                                 postponement looks like and it must not nag.
#   SUP4 unknown                — no lifetime data. NOT a pass.
#   SUP0 supported              — inside the window on both fields.
support_verdict() {
  local today_iso="$1" window="$2" cycle="$3" eol_raw="$4" support_raw="$5"
  local best_cycle="$6" best_eol_raw="$7" adoption="$8"
  local today eol sup best_eol

  today="$(iso_to_days "$today_iso")" || {
    # An unreadable clock is not an excuse to report a clean tree. Every
    # declaration becomes undecided, loudly, and the caller reports it.
    echo "SUP4:unreadable-today-$today_iso"
    return 0
  }

  eol="$(_eol_state "$eol_raw" "$today")"
  sup="$(_support_state "$support_raw" "$today")"

  # No data at all for this cycle — the product is unrecognised, the feed was
  # unreachable, or upstream never published this line. Undecided, never clean.
  if [ "$eol" = unknown ] && [ "$sup" = unknown ]; then
    echo "SUP4:no-lifetime-data-for-$cycle"
    return 0
  fi

  # 1. Past the announced end of life. The loudest verdict, and it outranks
  #    everything including a new adoption: "do not adopt" is weaker advice than
  #    "you are already running it".
  if [ "$eol" = past ]; then
    # `eol: true` is "ended, date not published" — the reason line must not
    # render that sentinel as though it were the date it is missing.
    if [ "$eol_raw" = true ]; then echo "SUP1:unsupported"; else echo "SUP1:unsupported-since-${eol_raw}"; fi
    return 0
  fi

  # 2. No EOL date was ever announced, and active support has ended. This is the
  #    React shape: upstream supports exactly one major and announces no dates,
  #    so `support` is the only field that ever moves. Treating the missing EOL
  #    as "fine" here is precisely the false clean this rule exists to prevent.
  if [ "$eol" = unknown ] && [ "$sup" = past ]; then
    if [ "$support_raw" = false ]; then echo "SUP1:support-ended"; else echo "SUP1:support-ended-${support_raw}"; fi
    return 0
  fi

  # 3. A NEW declaration that picked a shorter runway than was on the shelf.
  #    Gated twice, because an unqualified "you are not on the newest" is the
  #    noise this whole design exists to avoid: it fires only when the chosen
  #    line is ALREADY out of active support or expiring inside the window, AND
  #    a line with a longer runway exists. Adopting a fully-supported line that
  #    happens not to be the newest is a legitimate choice and stays silent.
  if [ "$adoption" = new ] && [ -n "$best_cycle" ] && [ "$best_cycle" != "$cycle" ]; then
    local eol_days=-1 best_days=-1
    case "$eol" in future:*) eol_days="${eol#future:}" ;; esac
    best_eol="$(_eol_state "$best_eol_raw" "$today")"
    case "$best_eol" in future:*) best_days="${best_eol#future:}" ;; esac

    if [ "$best_days" -gt "$eol_days" ]; then
      case "$sup" in
        past)
          echo "SUP3:new-on-maintenance-${cycle}-choose-${best_cycle}"
          return 0
          ;;
      esac
      if [ "$eol_days" -ge 0 ] && [ "$eol_days" -le "$window" ]; then
        echo "SUP3:new-on-expiring-${cycle}-choose-${best_cycle}"
        return 0
      fi
    fi
  fi

  # 4. Inside the migration window. The window is a LEAD TIME, not a countdown:
  #    a team that starts migrating on the day support ends is already late, so
  #    the default is measured in months rather than the days a release-note
  #    reader would notice.
  case "$eol" in
    future:*)
      if [ "${eol#future:}" -le "$window" ]; then
        echo "SUP2:expiring-${eol_raw}-in-${eol#future:}d"
        return 0
      fi
      ;;
  esac

  # 5. Out of active support with the end of life still ahead. Security fixes
  #    only. Reported at the bottom of the issue, never as a finding to act on.
  if [ "$sup" = past ]; then
    if [ "$support_raw" = false ]; then echo "SUP5:maintenance-only"; else echo "SUP5:maintenance-only-since-${support_raw}"; fi
    return 0
  fi

  echo "SUP0:supported"
}
