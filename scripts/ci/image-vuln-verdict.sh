#!/usr/bin/env bash
# =============================================================================
# image-vuln-verdict.sh — which findings in a golden-image scan stop the build
#
# USAGE
#   scripts/ci/image-vuln-verdict.sh --report <grype.json>
#                                    [--fail-on critical|high|medium|low]
#                                    [--ignores <file>] [--today YYYY-MM-DD]
#                                    [--selftest]
#
# PURPOSE
#   The image build produces an SBOM and scans it. This decides what the scan
#   MEANS, as a pure function of the report — so the decision is testable in
#   this repository's CI, where no image is built, rather than only inside a
#   forty-minute Packer run that nobody watches.
#
#     VULN1  a finding at or above the floor WITH AN AVAILABLE FIX — blocking
#     VULN2  an ignore entry whose expiry has passed — blocking, and the
#            finding it was hiding is reported alongside it
#     VULN0  the report could not be read, or matched nothing at all —
#            reported as a failure, never as a clean image
#
# WHY ONLY FIXABLE FINDINGS BLOCK
#   The interesting question for an image build is "is this image worse than
#   the one it could have been", and an unfixed CVE in a base-image package is
#   not something the build can answer yes to. Blocking on it stops every image
#   in the fleet until somebody adds an ignore entry — and the entry they add
#   under that pressure is a permanent one, written at speed, for a CVE they
#   did not read. That is the mechanism by which a vulnerability gate becomes a
#   file of stale exceptions.
#
#   So a finding with `fix.state = fixed` is blocking: the build could have
#   picked up the fixed version and did not, which is actionable today by
#   rebuilding. Everything else is REPORTED in full — it is in the SBOM, it is
#   in the output, and it is not a red build somebody has to route around.
#
# WHY IGNORES EXPIRE
#   An ignore with no expiry is a decision that outlives the person who made
#   it and the reason they made it. Every entry carries a date; on the day it
#   passes, the gate goes red naming the entry rather than quietly continuing
#   to hide the finding. Re-affirming an ignore is then a pull request with a
#   new date, which is the review.
#
# WHY AN EMPTY MATCH SET IS A FAILURE
#   A whole-filesystem scan of an Ubuntu image matching zero vulnerabilities is
#   not a clean image; it is an empty SBOM, a scanner that did not run, or a
#   report written to a path nothing read. All three report identically to a
#   perfect result, and that vacuous pass is worse than no gate, because it is
#   believed.
#
# WHAT THIS DOES NOT DECIDE
#   Whether a CVE is exploitable on a CI host. That is the review, and the
#   ignore file with its dated reason is where the review is recorded.
#
# EXIT CODES
#   0 — no blocking findings
#   1 — blocking findings (VULN1 or VULN2)
#   2 — usage, or the report could not be read (VULN0)
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

REPORT=""; FAIL_ON="critical"; IGNORES=""; TODAY=""; SELFTEST=0

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" >&2; exit 2; }

# verdict <report> <fail-on> <ignores-or-empty> <today>
#
# Emits one record per line, tab-separated and positionally fixed:
#
#   #FINDING<TAB>id<TAB>severity<TAB>package<TAB>version<TAB>fix<TAB>state
#   #EXPIRED<TAB>id<TAB>expiry<TAB>reason
#   #COUNT<TAB>total<TAB>blocking<TAB>ignored<TAB>expired
#
# `state` is blocking | ignored | reported. No field may be empty: `read` with
# `IFS=$'\t'` still treats a tab as IFS WHITESPACE and collapses a run of them,
# so one empty column silently shifts every column after it — which is how a
# package with no fix version arrives as its own severity.
verdict() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys

report_path, fail_on, ignores_path, today = sys.argv[1:5]

RANK = {"negligible": 0, "unknown": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
floor = RANK.get(fail_on.lower())
if floor is None:
    print("BADFLOOR", file=sys.stderr)
    sys.exit(3)

try:
    with open(report_path, encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as exc:                     # noqa: BLE001 - any read/parse failure is the same verdict
    print("UNREADABLE %s" % exc, file=sys.stderr)
    sys.exit(3)

matches = doc.get("matches")
if not isinstance(matches, list):
    print("NOMATCHESKEY", file=sys.stderr)
    sys.exit(3)

# id -> (expiry, reason). A malformed line is not skipped quietly: an ignore
# file the gate half-read would hide findings nobody agreed to hide.
ignores = {}
if ignores_path:
    try:
        with open(ignores_path, encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(None, 2)
                if len(parts) < 3:
                    print("BADIGNORE line %d: %s" % (lineno, line), file=sys.stderr)
                    sys.exit(3)
                ignores[parts[0]] = (parts[1], parts[2])
    except OSError as exc:
        print("UNREADABLE %s" % exc, file=sys.stderr)
        sys.exit(3)

def out(*fields):
    print("\t".join(str(f) if str(f) != "" else "-" for f in fields))

total = blocking = ignored = expired = 0
seen_expired = set()

for m in matches:
    vuln = m.get("vulnerability") or {}
    art = m.get("artifact") or {}
    vid = vuln.get("id") or "UNKNOWN"
    sev = (vuln.get("severity") or "unknown").lower()
    fix = vuln.get("fix") or {}
    fixed_in = ",".join(fix.get("versions") or []) or "-"
    fixable = fix.get("state") == "fixed"
    total += 1

    at_or_above = RANK.get(sev, 0) >= floor
    state = "reported"

    if at_or_above and fixable:
        if vid in ignores:
            expiry, reason = ignores[vid]
            # An expired ignore does not fall back to ignoring. It is its own
            # finding, and the thing it was hiding is reported beside it.
            if today > expiry:
                state = "blocking"
                blocking += 1
                if vid not in seen_expired:
                    seen_expired.add(vid)
                    expired += 1
                    out("#EXPIRED", vid, expiry, reason)
            else:
                state = "ignored"
                ignored += 1
        else:
            state = "blocking"
            blocking += 1

    out("#FINDING", vid, sev, art.get("name") or "-", art.get("version") or "-", fixed_in, state)

out("#COUNT", total, blocking, ignored, expired)
PY
}

run() {
  REPORT=""; FAIL_ON="critical"; IGNORES=""; TODAY=""; SELFTEST=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --report)  REPORT="$2";  shift 2 ;;
      --fail-on) FAIL_ON="$2"; shift 2 ;;
      --ignores) IGNORES="$2"; shift 2 ;;
      --today)   TODAY="$2";   shift 2 ;;
      --selftest) SELFTEST=1;  shift ;;
      *) echo "unknown argument: $1" >&2; usage ;;
    esac
  done

  [ "$SELFTEST" = "1" ] && { selftest; return; }

  command -v python3 >/dev/null 2>&1 || { echo "::error::[VULN0] python3 is required to read the report" >&2; return 2; }
  [ -n "$REPORT" ] || usage
  [ -n "$TODAY" ] || TODAY="$(date -u +%Y-%m-%d)"
  # The default lives here rather than in the caller so the build VM and this
  # repository's CI read the same file without either having to name it.
  if [ -z "$IGNORES" ] && [ -f "$REPO_ROOT/docs/image-vuln-ignores.txt" ]; then
    IGNORES="$REPO_ROOT/docs/image-vuln-ignores.txt"
  fi

  local records
  records="$(verdict "$REPORT" "$FAIL_ON" "$IGNORES" "$TODAY")"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::error::[VULN0] the scan report could not be read — treating as a failed scan, not as a clean image" >&2
    return 2
  fi

  local total blocking ignored expired
  # shellcheck disable=SC2034
  read -r _ total blocking ignored expired <<< "$(printf '%s\n' "$records" | grep '^#COUNT' | tr '\t' ' ')"

  if [ "${total:-0}" -eq 0 ]; then
    echo "::error::[VULN0] the scan matched nothing at all. A whole-filesystem scan of this image matching zero vulnerabilities is an empty SBOM or a scanner that did not run, not a clean image" >&2
    return 2
  fi

  echo "image scan: $total finding(s), floor=$FAIL_ON, $blocking blocking, $ignored ignored, $expired expired ignore(s)"

  local _ id sev pkg ver fix state expiry reason
  while IFS=$'\t' read -r _ id expiry reason; do
    echo "::error::[VULN2] the ignore for $id expired on $expiry — re-affirm it with a new date in a pull request, or fix the finding. Reason on file: $reason"
  done < <(printf '%s\n' "$records" | grep '^#EXPIRED' || true)

  while IFS=$'\t' read -r _ id sev pkg ver fix state; do
    case "$state" in
      blocking) echo "::error::[VULN1] $sev $id in $pkg $ver — fixed in $fix. The image could have picked this up and did not." ;;
      ignored)  echo "  ignored  $sev $id in $pkg $ver (fixed in $fix)" ;;
      *)        echo "  reported $sev $id in $pkg $ver (fix: $fix)" ;;
    esac
  done < <(printf '%s\n' "$records" | grep '^#FINDING' || true)

  [ "${blocking:-0}" -gt 0 ] && return 1
  return 0
}

# ── fixtures ─────────────────────────────────────────────────────────────────
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"

  match() {  # <id> <severity> <fix-state> <fixed-in> <pkg> <version>
    printf '{"vulnerability":{"id":"%s","severity":"%s","fix":{"state":"%s","versions":["%s"]}},"artifact":{"name":"%s","version":"%s"}}' \
      "$1" "$2" "$3" "$4" "$5" "$6"
  }
  report() { printf '{"matches":[%s]}\n' "$(printf '%s' "$1")"; }

  check() {  # <name> <want-rc> <must-contain-or-dash> <args...>
    local name="$1" want="$2" needle="$3"; shift 3
    local out rc
    out="$(run "$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ] || { [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -q -- "$needle"; }; then
      echo "FAIL $name (rc=$rc want=$want)"
      printf '%s\n' "$out" | sed 's/^/      /'
      status=1
    else
      echo "ok   $name"
    fi
  }

  # A fixable critical is the whole point: the build could have taken the fix.
  report "$(match CVE-1 critical fixed 1.2.3 libfoo 1.2.2)" > "$tmp/fixable.json"
  check "a fixable critical blocks the build" 1 "VULN1" --report "$tmp/fixable.json" --today 2026-01-01

  # The same critical with no fix does NOT block. Nothing the build can do
  # about it, and blocking is what turns the gate into a file of exceptions.
  report "$(match CVE-2 critical not-fixed - libfoo 1.2.2)" > "$tmp/unfixed.json"
  check "an unfixable critical is reported, not blocking" 0 "reported critical CVE-2" \
    --report "$tmp/unfixed.json" --today 2026-01-01

  # Below the floor, fixable, still not blocking — the floor is the knob.
  report "$(match CVE-3 medium fixed 2.0.0 libbar 1.0.0)" > "$tmp/medium.json"
  check "a fixable medium is below the default floor" 0 "reported medium CVE-3" \
    --report "$tmp/medium.json" --today 2026-01-01
  check "the floor is what moves it" 1 "VULN1" \
    --report "$tmp/medium.json" --fail-on medium --today 2026-01-01

  # A live ignore hides the finding from the verdict but not from the output.
  printf 'CVE-1 2026-12-31 reviewed 2026-01-02, not reachable from a CI host\n' > "$tmp/live.txt"
  check "a live ignore stops it blocking and still prints it" 0 "ignored  critical CVE-1" \
    --report "$tmp/fixable.json" --ignores "$tmp/live.txt" --today 2026-06-01

  # The day after the expiry it blocks again, and the ENTRY is the finding.
  printf 'CVE-1 2026-05-31 reviewed 2026-01-02, not reachable from a CI host\n' > "$tmp/dead.txt"
  check "an expired ignore blocks and names itself" 1 "VULN2" \
    --report "$tmp/fixable.json" --ignores "$tmp/dead.txt" --today 2026-06-01
  check "the expired entry does not hide what it was hiding" 1 "VULN1" \
    --report "$tmp/fixable.json" --ignores "$tmp/dead.txt" --today 2026-06-01

  # On the expiry date itself it is still live: an entry dated the 31st is good
  # through the 31st, which is what somebody writing the date means by it.
  check "an ignore is live on its expiry date" 0 "ignored  critical CVE-1" \
    --report "$tmp/fixable.json" --ignores "$tmp/dead.txt" --today 2026-05-31

  # An ignore for something that is not blocking anyway must not be counted as
  # used — otherwise the file grows entries nobody can ever retire.
  printf 'CVE-2 2026-12-31 an unfixed one, ignored for no reason\n' > "$tmp/moot.txt"
  check "an ignore on a non-blocking finding changes nothing" 0 "reported critical CVE-2" \
    --report "$tmp/unfixed.json" --ignores "$tmp/moot.txt" --today 2026-06-01

  # Zero matches is the vacuous pass this gate must never produce.
  printf '{"matches":[]}\n' > "$tmp/empty.json"
  check "an empty match set fails, it does not pass" 2 "VULN0" \
    --report "$tmp/empty.json" --today 2026-01-01

  # So is a report that is not there, and one that is not JSON.
  check "a missing report fails" 2 "VULN0" --report "$tmp/nope.json" --today 2026-01-01
  printf 'not json at all\n' > "$tmp/junk.json"
  check "an unparseable report fails" 2 "VULN0" --report "$tmp/junk.json" --today 2026-01-01
  printf '{"descriptor":{"name":"grype"}}\n' > "$tmp/nokey.json"
  check "a report with no matches key fails" 2 "VULN0" --report "$tmp/nokey.json" --today 2026-01-01

  # A malformed ignore line fails rather than being skipped: an ignore file the
  # gate half-read hides findings nobody agreed to hide.
  printf 'CVE-1 2026-12-31\n' > "$tmp/short.txt"
  check "an ignore line with no reason fails the gate" 2 "VULN0" \
    --report "$tmp/fixable.json" --ignores "$tmp/short.txt" --today 2026-01-01

  # Several findings at once, because the counts are what the build log shows.
  report "$(match CVE-1 critical fixed 1.2.3 libfoo 1.2.2),$(match CVE-2 high fixed 9 libbar 8),$(match CVE-3 low not-fixed - libbaz 1)" \
    > "$tmp/many.json"
  check "the counts are per finding, not per severity" 1 "3 finding(s)" \
    --report "$tmp/many.json" --today 2026-01-01

  # A finding whose fix carries no version must still be positional: an empty
  # column would shift `state` into `fix` and a blocking finding would print as
  # if it were merely reported.
  printf '{"matches":[{"vulnerability":{"id":"CVE-9","severity":"critical","fix":{"state":"fixed"}},"artifact":{"name":"libqux","version":"1"}}]}\n' \
    > "$tmp/nofixver.json"
  check "a fix with no version does not shift the columns" 1 "VULN1" \
    --report "$tmp/nofixver.json" --today 2026-01-01

  rm -rf "$tmp"
  [ "$status" -eq 0 ] && echo "image-vuln-verdict self-test: all fixtures pass"
  return "$status"
}

run "$@"
