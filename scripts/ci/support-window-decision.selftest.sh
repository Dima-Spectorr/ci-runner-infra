#!/usr/bin/env bash
# The support-window rule, tested against the fleet state that motivated it.
#
# Every version fixture below is REAL — the cycles, the end-of-life dates and
# the active-support dates are the ones endoflife.date published on 2026-08-16,
# transcribed rather than invented. A rule about dates tested against invented
# dates asserts only that its arithmetic is self-consistent.
#
# `today` is an argument to the rule, so the same fixture is asserted from
# several vantage points. That is not a trick to reach a branch: the whole
# defect this rule addresses is that a repository's verdict changes on a date
# nobody is watching, and a self-test whose "today" is the clock of whoever ran
# it passes every day until the one day it matters.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./support-window-decision.sh
source "$HERE/support-window-decision.sh"

PASS=0
FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; PASS=$((PASS + 1))
  else printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# endoflife.date/api/nodejs.json, read 2026-08-16.
N18_EOL=2025-04-30; N18_SUP=2023-10-18
N20_EOL=2026-04-30; N20_SUP=2024-10-22
N22_EOL=2027-04-30; N22_SUP=2025-10-21
N24_EOL=2028-04-30; N24_SUP=2026-10-20
N25_EOL=2026-06-01; N25_SUP=2026-04-01
# 26 appears only ever as the BEST line, and the rule consults nothing but a
# best line's end of life — so there is deliberately no `N26_SUP` beside it.
N26_EOL=2029-04-30

TODAY=2026-08-16
W=180

# --- the incident ------------------------------------------------------------
# Three Node versions were in use across the fleet on the day this was written
# and not one of them had produced an alert. The three verdicts differ, and a
# tool that gave them the same verdict would be either useless or unreadable.

check "Node 18 — sixteen months past end of life" \
  "SUP1:unsupported-since-2025-04-30" \
  "$(support_verdict "$TODAY" "$W" 18 "$N18_EOL" "$N18_SUP" 26 "$N26_EOL" existing)"

# The one a version-behind checker cannot see either: 20 is not "behind" in any
# sense Dependabot reports, it simply died four months ago.
check "Node 20 — end of life passed this April, silently" \
  "SUP1:unsupported-since-2026-04-30" \
  "$(support_verdict "$TODAY" "$W" 20 "$N20_EOL" "$N20_SUP" 26 "$N26_EOL" existing)"

# Node 22 is the case this rule exists for, and it has TWO answers depending on
# one thing no version check knows: whether the declaration is new.
#
# On an application already shipped on 22, this is a postponement. The EOL is
# 257 days out, security fixes are still flowing, and nagging about it every
# CI run is how a report gets filtered into a folder nobody opens.
check "Node 22 on an existing app — informational, not a finding" \
  "SUP5:maintenance-only-since-2025-10-21" \
  "$(support_verdict "$TODAY" "$W" 22 "$N22_EOL" "$N22_SUP" 24 "$N24_EOL" existing)"

# The same version, chosen TODAY for a new application, is a different thing:
# 24 was on the shelf, supported for another year, and free to pick. Reversing
# this decision costs nothing on the day of the pull request.
check "Node 22 newly adopted while 24 was available — the finding nothing else raises" \
  "SUP3:new-on-maintenance-22-choose-24" \
  "$(support_verdict "$TODAY" "$W" 22 "$N22_EOL" "$N22_SUP" 24 "$N24_EOL" new)"

# --- what must stay QUIET ----------------------------------------------------
# The failure mode of this whole design is a report so noisy it is ignored, and
# the fastest way there is to flag "not the newest" as a defect.

check "Node 24 is fully supported — silent" \
  "SUP0:supported" \
  "$(support_verdict "$TODAY" "$W" 24 "$N24_EOL" "$N24_SUP" 26 "$N26_EOL" existing)"

# 26 exists and has a longer runway. Adopting 24 anyway is a legitimate choice
# — an LTS with active support for another year — and SUP3 must NOT fire on it.
# If it did, every repository in the fleet would carry a finding permanently.
check "a NEW app on 24 while 26 exists — still silent, 24 is supported" \
  "SUP0:supported" \
  "$(support_verdict "$TODAY" "$W" 24 "$N24_EOL" "$N24_SUP" 26 "$N26_EOL" new)"

# Odd-numbered lines are never LTS and die fast; 25's end of life was 2026-06-01.
check "Node 25 — a non-LTS line, already past end of life" \
  "SUP1:unsupported-since-2026-06-01" \
  "$(support_verdict "$TODAY" "$W" 25 "$N25_EOL" "$N25_SUP" 26 "$N26_EOL" existing)"

# --- the migration window is a lead time, not a countdown --------------------
# Node 20 seen from 2025-12-01: 150 days of life left. A team told at 150 days
# can plan; a team told at 7 days can only panic.
check "Node 20 seen from five months out — inside the window" \
  "SUP2:expiring-2026-04-30-in-150d" \
  "$(support_verdict 2025-12-01 "$W" 20 "$N20_EOL" "$N20_SUP" 24 "$N24_EOL" existing)"

check "Node 18 seen from January 2025 — 119 days left" \
  "SUP2:expiring-2025-04-30-in-119d" \
  "$(support_verdict 2025-01-01 "$W" 18 "$N18_EOL" "$N18_SUP" 22 "$N22_EOL" existing)"

# The boundary, both sides. Node 22's EOL is exactly 180 days after 2026-11-01.
check "exactly at the window edge is inside it" \
  "SUP2:expiring-2027-04-30-in-180d" \
  "$(support_verdict 2026-11-01 "$W" 22 "$N22_EOL" "$N22_SUP" 24 "$N24_EOL" existing)"

# One day earlier is 181 days out — outside the window, so the softer
# maintenance verdict is what remains. The ladder must not skip a rung.
check "one day outside the window falls through to maintenance-only" \
  "SUP5:maintenance-only-since-2025-10-21" \
  "$(support_verdict 2026-10-31 "$W" 22 "$N22_EOL" "$N22_SUP" 24 "$N24_EOL" existing)"

# --- `eol: false` means "no date announced", never "no end of life" ----------
#
# This is the parse that decides whether the whole report is trustworthy. React
# publishes NO end-of-life dates: every cycle it has ever shipped carries
# `eol: false`, including 15, which nobody would call supported. A rule that
# reads that field as a boolean reports every React application in the fleet as
# clean, forever, and looks like it is working.
check "React 18 — no EOL date published, but active support ended" \
  "SUP1:support-ended-2024-12-05" \
  "$(support_verdict "$TODAY" "$W" 18 false 2024-12-05 19 false existing)"

check "React 19 — no EOL date, support still active: supported" \
  "SUP0:supported" \
  "$(support_verdict "$TODAY" "$W" 19 false true 19 false existing)"

# `support: false` is the mirror sentinel: ended, no date. The reason line must
# not read "support-ended-false".
check "support ended with no date renders as a reason, not as a sentinel" \
  "SUP1:support-ended" \
  "$(support_verdict "$TODAY" "$W" 15 false false 19 false existing)"

check "eol: true is 'ended, date unknown' — unsupported, not a date" \
  "SUP1:unsupported" \
  "$(support_verdict "$TODAY" "$W" 3 true false 5 2030-01-01 existing)"

# A product with no EOL dates at all cannot produce a SUP3: there is no runway
# to compare, so "choose the other one" would be an unfounded instruction.
check "no dates anywhere — a new adoption is not second-guessed" \
  "SUP0:supported" \
  "$(support_verdict "$TODAY" "$W" 18 false true 19 false new)"

# --- absence is UNKNOWN, and unknown is not clean ----------------------------
# The feed is a third party. When it is down, unreachable, or has never heard of
# the product, the one answer that must be unreachable is "supported".

check "a cycle the feed does not carry is undecided, never a pass" \
  "SUP4:no-lifetime-data-for-17" \
  "$(support_verdict "$TODAY" "$W" 17 "" "" 24 "$N24_EOL" existing)"

check "an unreachable feed is undecided, never a pass" \
  "SUP4:no-lifetime-data-for-22" \
  "$(support_verdict "$TODAY" "$W" 22 unknown unknown "" "" existing)"

# An unreadable clock makes every comparison meaningless. The rule refuses to
# answer rather than answering from a date it could not parse.
check "an unparseable 'today' decides nothing" \
  "SUP4:unreadable-today-not-a-date" \
  "$(support_verdict not-a-date "$W" 22 "$N22_EOL" "$N22_SUP" 24 "$N24_EOL" existing)"

# A new adoption with no alternative found — the caller could not read the
# product's other cycles. No comparison is possible, so no SUP3.
check "no alternative known: a new adoption falls back to the plain verdicts" \
  "SUP5:maintenance-only-since-2025-10-21" \
  "$(support_verdict "$TODAY" "$W" 22 "$N22_EOL" "$N22_SUP" "" "" new)"

# --- date arithmetic ---------------------------------------------------------
# `08` and `09` are not valid octal. A month that silently fails to parse
# compares against zero, which reads as "long expired" for every August date —
# a whole-fleet false alarm arriving on a calendar boundary.
check "August parses as 8, not as bad octal" 20681 "$(iso_to_days 2026-08-16)"
check "September parses as 9" 20708 "$(iso_to_days 2026-09-12)"
check "the epoch is day zero" 0 "$(iso_to_days 1970-01-01)"
check "a leap day is a real day" 21243 "$(iso_to_days 2028-02-29)"

iso_to_days 2026-13-01 >/dev/null 2>&1 && r=accepted || r=rejected
check "an impossible month is rejected, not wrapped" rejected "$r"
iso_to_days true >/dev/null 2>&1 && r=accepted || r=rejected
check "the 'true' sentinel is not a date" rejected "$r"

# --- the rule never fails its caller ----------------------------------------
# A scan reads dozens of declarations. If an odd verdict could exit non-zero,
# the first unrecognised product would end the scan and the report would be
# short, green and wrong.
( set -e; support_verdict "$TODAY" "$W" 17 "" "" "" "" existing >/dev/null ) && r=ok || r=exited
check "an undecided verdict does not exit non-zero under set -e" ok "$r"

printf 'support-window-decision selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
