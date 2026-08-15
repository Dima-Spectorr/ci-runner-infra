#!/usr/bin/env bash
# Every network call in the delivered scripts must be time-bounded, and every
# `Type=oneshot` unit they install must carry a `TimeoutStartSec`.
#
# WHY THIS IS A GATE AND NOT A REVIEW NOTE
#
# The controller is a `Type=simple` unit running `while true; do tick; sleep
# POLL; done`, and the pollers this fleet's consumers install are `Type=oneshot`
# timer units. Both shapes turn ONE unbounded socket into a permanent stall:
#
#   * in the loop, a blocked call never returns, so no later tick ever runs —
#     and the process stays alive, so `Restart=always` never fires;
#   * in a oneshot, systemd will not start the next activation while the
#     previous one is still starting, so the timer reads `NEXT n/a` forever.
#
# In both cases the demand metric keeps its LAST PUBLISHED VALUE. Nothing is
# missing, so nothing alerts: the pool simply stops scaling out while jobs queue
# and stops draining while hosts idle, and every dashboard shows a number.
#
# This is a real incident, not a hypothesis. 2026-08-14, the IntegrateIT windows
# pool: `ci-controller-poll.service` in `activating (start)` for 2h55m, timer
# `NEXT n/a`, MIG pinned at targetSize 0, `windows-agent-build` queued the whole
# time, no alert anywhere. The reaper in the same module survived identical
# conditions purely because it had been written with `--max-time` and
# `TimeoutStartSec`; the poller had not. The difference was an author's habit,
# which is exactly the kind of difference a gate exists to remove.
#
# `--max-time` alone is not enough and is checked separately: it does not bound
# a stalled CONNECT, which falls back to the OS TCP timeout (minutes).
#
# POWERSHELL, FOR THE SAME REASON
#
# The incident above was a WINDOWS pool, and this gate could not read a line of
# Windows code. A Windows host is driven by a `.ps1`, whose web calls are
# `Invoke-RestMethod` and `Invoke-WebRequest` — both of which wait **forever** by
# default in PowerShell 6+, where `-TimeoutSec 0` and an unset `-TimeoutSec` mean
# "no timeout". That is the same unbounded socket in a different language, and it
# would produce the same stalled tick, the same last-published metric value and
# the same silent dashboard.
#
# A raw `System.Net.Http.HttpClient` is rejected outright rather than checked for
# a timeout. Its default is 100 seconds, which is a bound nobody in this
# repository chose, and whether a given instance's `Timeout` was assigned is not
# a property of the line that constructs it. The two cmdlets carry their bound
# on the call, where a gate can see it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/modules/ci-runner-host-pool/scripts"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

# Fold `\`-continuations so a curl spread over five lines is judged as the one
# command it is — checking line-by-line would report every wrapped invocation as
# unbounded, and the noise would get the gate disabled.
fold_lines() { sed -e :a -e '/\\$/{N;s/\\\n//;ta' -e '}' "$1"; }

# Commands, not comments: this file's own prose says `curl` a dozen times, and
# so does the module's. Strip full-line comments before judging.
curl_cmds()   { fold_lines "$1" | grep -vE '^[[:space:]]*#' | grep -E '(^|[^[:alnum:]_-])curl[[:space:]]'; }
oneshot_units() { fold_lines "$1" | grep -vE '^[[:space:]]*#' | grep -cE '^Type=oneshot$'; }

# A curl is bounded when it carries BOTH a total cap and a connect cap, in any
# of curl's spellings, including via an expanded array such as
# "${CURL_TIMEOUTS[@]}" — the fleet's convention.
is_bounded() { # <command text>
  local c="$1"
  [[ "$c" == *'CURL_TIMEOUTS[@]'* ]] && return 0
  [[ "$c" == *'--max-time'* || "$c" =~ (^|[[:space:]])-m[[:space:]] ]] || return 1
  [[ "$c" == *'--connect-timeout'* ]] || return 1
  return 0
}

# PowerShell continues a line with a trailing BACKTICK, not a backslash, so the
# folder above would judge a wrapped `Invoke-RestMethod` as several commands and
# miss the `-TimeoutSec` on its last line.
# shellcheck disable=SC2016  # `$ is sed's end-of-line anchor, not a shell expansion.
fold_ps_lines() { sed -e :a -e '/`$/{N;s/`\n//;ta' -e '}' "$1"; }

ps_web_cmds() { fold_ps_lines "$1" | grep -vE '^[[:space:]]*#' | grep -Ei '(^|[^[:alnum:]_-])Invoke-(RestMethod|WebRequest)([^[:alnum:]_-]|$)'; }
ps_httpclients() { fold_ps_lines "$1" | grep -vE '^[[:space:]]*#' | grep -cEi 'Net\.Http\.HttpClient'; }

# `-TimeoutSec 0` is spelled out as unbounded because it IS: PowerShell documents
# 0 as "indefinite". A gate that accepted the flag's presence rather than its
# value would pass the one spelling that reproduces the incident exactly.
is_bounded_ps() { # <command text>
  local c="$1"
  [[ "$c" =~ -TimeoutSec[[:space:]]+0([^0-9]|$) ]] && return 1
  [[ "$c" == *'-TimeoutSec'* ]] || return 1
  return 0
}

echo "bounded-calls self-test:"

# --- 0. selftest: a detector that sees nothing also reports PASS -------------
#
# Prove both detectors fire against planted fixtures before believing any pass
# below. Without this the gate's green means "found no problems" and "read no
# files" identically.
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

cat >"$FIX/bad.sh" <<'BADEOF'
#!/usr/bin/env bash
# curl mentioned in a comment must not be judged
md() {
  curl -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/x"
}
BADEOF

cat >"$FIX/partial.sh" <<'PARTEOF'
#!/usr/bin/env bash
resp=$(curl -fsS --max-time 30 "https://api.github.com/x")
PARTEOF

cat >"$FIX/good.sh" <<'GOODEOF'
#!/usr/bin/env bash
CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)
md() {
  curl "${CURL_TIMEOUTS[@]}" -fsS "http://metadata.google.internal/x"
}
resp=$(curl --connect-timeout 10 --max-time 30 -fsS "https://api.github.com/x")
GOODEOF

probe_unbounded() { # <file> -> count of unbounded curls
  local n=0 c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    is_bounded "$c" || n=$((n + 1))
  done < <(curl_cmds "$1")
  echo "$n"
}

# if/else rather than `A && ok || bad`: in that idiom the `||` branch also runs
# when `ok` itself fails, so a broken reporter would be reported as a broken
# detector. shellcheck SC2015 flags it, and this gate must pass its own repo's
# lint.
expect_eq() { # <actual> <expected> <ok-msg> <bad-msg>
  if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$4"; fi
}

expect_eq "$(probe_unbounded "$FIX/bad.sh")" 1 \
  "detector flags an unbounded curl" \
  "detector did NOT flag an unbounded curl — every pass below is vacuous"

expect_eq "$(probe_unbounded "$FIX/partial.sh")" 1 \
  "detector flags --max-time without --connect-timeout" \
  "detector accepts --max-time alone — a stalled CONNECT stays unbounded"

expect_eq "$(probe_unbounded "$FIX/good.sh")" 0 \
  "detector accepts bounded curls (array and explicit flags)" \
  "detector rejects a correctly bounded curl — it would be turned off, not fixed"

cat >"$FIX/unit-bad.sh" <<'UBEOF'
cat >/etc/systemd/system/x.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/opt/x.sh
EOF
UBEOF

cat >"$FIX/unit-good.sh" <<'UGEOF'
cat >/etc/systemd/system/x.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/opt/x.sh
TimeoutStartSec=300
EOF
UGEOF

units_missing_timeout() { # <file> -> 0/1
  local units timeouts
  units=$(oneshot_units "$1")
  timeouts=$(grep -cE '^TimeoutStartSec=' "$1")
  if [ "$units" -gt "$timeouts" ]; then echo 1; else echo 0; fi
}

expect_eq "$(units_missing_timeout "$FIX/unit-bad.sh")" 1 \
  "detector flags a oneshot unit with no TimeoutStartSec" \
  "detector did NOT flag an unbounded oneshot unit"

expect_eq "$(units_missing_timeout "$FIX/unit-good.sh")" 0 \
  "detector accepts a oneshot unit carrying TimeoutStartSec" \
  "detector rejects a correctly bounded oneshot unit"

# --- 0b. the PowerShell detectors -------------------------------------------

cat >"$FIX/bad.ps1" <<'PSBADEOF'
# Invoke-RestMethod mentioned in a comment must not be judged
function Get-Md {
  $r = Invoke-RestMethod -Headers @{ 'Metadata-Flavor' = 'Google' } `
    -Uri 'http://metadata.google.internal/x'
  return $r
}
PSBADEOF

cat >"$FIX/zero.ps1" <<'PSZEROEOF'
$r = Invoke-WebRequest -Uri 'https://api.github.com/x' -TimeoutSec 0
PSZEROEOF

cat >"$FIX/good.ps1" <<'PSGOODEOF'
function Get-Md {
  $r = Invoke-RestMethod -Headers @{ 'Metadata-Flavor' = 'Google' } `
    -Uri 'http://metadata.google.internal/x' `
    -TimeoutSec 10
  return $r
}
$w = Invoke-WebRequest -Uri 'https://api.github.com/x' -TimeoutSec 30
PSGOODEOF

cat >"$FIX/client.ps1" <<'PSCLIENTEOF'
$c = [System.Net.Http.HttpClient]::new()
PSCLIENTEOF

probe_unbounded_ps() { # <file> -> count of unbounded PowerShell web calls
  local n=0 c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    is_bounded_ps "$c" || n=$((n + 1))
  done < <(ps_web_cmds "$1")
  echo "$n"
}

expect_eq "$(probe_unbounded_ps "$FIX/bad.ps1")" 1 \
  "detector flags an Invoke-RestMethod with no -TimeoutSec" \
  "detector did NOT flag an unbounded PowerShell web call — the Windows half of this gate is vacuous"

expect_eq "$(probe_unbounded_ps "$FIX/zero.ps1")" 1 \
  "detector flags -TimeoutSec 0, which PowerShell documents as indefinite" \
  "detector accepts -TimeoutSec 0 — the one spelling that reproduces the incident"

expect_eq "$(probe_unbounded_ps "$FIX/good.ps1")" 0 \
  "detector accepts bounded PowerShell web calls across a backtick continuation" \
  "detector rejects a correctly bounded PowerShell call — it would be turned off, not fixed"

expect_eq "$(ps_httpclients "$FIX/client.ps1")" 1 \
  "detector flags a raw HttpClient, whose 100s default is nobody's decision" \
  "detector did NOT flag a raw HttpClient"

expect_eq "$(ps_httpclients "$FIX/good.ps1")" 0 \
  "detector leaves cmdlet-only PowerShell alone" \
  "detector flags a file with no HttpClient in it"

[ "$fail" -eq 0 ] || { echo "  bounded calls UNVERIFIABLE (detectors are broken)."; exit 1; }

# --- 1. the real scripts -----------------------------------------------------
#
# Assert the inputs exist first: a grep over a moved file finds nothing, and
# "nothing unbounded" is what a pass looks like.
shopt -s nullglob
files=("$SCRIPTS"/*.sh)
if [ "${#files[@]}" -eq 0 ]; then
  bad "no scripts found under ${SCRIPTS#"$ROOT/"} — this gate would pass vacuously"
  echo "  bounded calls UNVERIFIABLE."
  exit 1
fi
ok "scanning ${#files[@]} script(s) under ${SCRIPTS#"$ROOT/"}"

for f in "${files[@]}"; do
  rel="${f#"$ROOT/"}"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if ! is_bounded "$c"; then
      bad "$rel: unbounded curl — $(printf '%.90s' "$(echo "$c" | tr -s ' ')")"
    fi
  done < <(curl_cmds "$f")

  u=$(oneshot_units "$f")
  t=$(grep -cE '^TimeoutStartSec=' "$f")
  if [ "$u" -gt "$t" ]; then
    bad "$rel: $u Type=oneshot unit(s) but only $t TimeoutStartSec — a hung activation blocks its own timer forever"
  fi
done

# The Windows half. Zero files is the honest count until the Windows boot script
# lands, and unlike the sweep above that is not a vacuous pass to guard against:
# this gate ships one pull request ahead of the code it is for, on purpose, so
# that no window exists in which an unbounded Windows call could enter unseen.
psfiles=("$SCRIPTS"/*.ps1)
ok "scanning ${#psfiles[@]} PowerShell script(s) under ${SCRIPTS#"$ROOT/"}"

for f in "${psfiles[@]}"; do
  rel="${f#"$ROOT/"}"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if ! is_bounded_ps "$c"; then
      bad "$rel: unbounded PowerShell web call — $(printf '%.90s' "$(echo "$c" | tr -s ' ')")"
    fi
  done < <(ps_web_cmds "$f")

  h=$(ps_httpclients "$f")
  if [ "$h" -gt 0 ]; then
    bad "$rel: $h raw HttpClient construction(s) — use Invoke-RestMethod/-WebRequest with -TimeoutSec, whose bound a gate can read"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "  every delivered call is bounded."
else
  echo "  UNBOUNDED CALLS PRESENT — one hung socket can freeze demand and stop the pool."
fi
exit "$fail"
