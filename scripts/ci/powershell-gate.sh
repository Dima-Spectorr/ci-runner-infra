#!/usr/bin/env bash
# Parse and lint every PowerShell file in this repository.
#
# WHY THIS EXISTS BEFORE THERE IS ANY POWERSHELL
#
# Two gates in `.github/workflows/ci.yml` sweep `find . -name '*.sh'`: `bash -n`
# and shellcheck. A Windows host is driven by a `.ps1` embedded in instance
# metadata, and neither gate can see one. So does the genericity sweep, which
# greps `--include='*.tf' --include='*.sh' --include='*.hcl'` — a customer,
# project or region literal in a Windows boot script would be committed and CI
# would report clean.
#
# The blind spot is closed here, in the pull request BEFORE the first `.ps1`
# lands, because the alternative is a window in which the fleet's newest code is
# the only code no gate reads. That window is how the vendored predecessor
# drifted, and it is how `v5.1.4` shipped a controller that died on its first
# tick while every gate stayed green.
#
# WHAT IT ASSERTS
#
#   1. Every `.ps1` parses, using PowerShell's own parser rather than a
#      lookalike. This is the `bash -n` analogue.
#   2. PSScriptAnalyzer reports no Error or Warning, at a PINNED version. A
#      PSGallery module is the same shape of dependency as a GitHub Action, and
#      this repository pins every action to a commit for the same reason: a
#      moved tag is arbitrary code. It runs only on a GitHub-hosted runner and
#      never touches a host.
#
# `--selftest` proves both detectors FIRE against planted fixtures before any
# pass below is believed. A parser gate that reads no files and a parser gate
# that finds no faults print the same thing otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Pinned deliberately. `-RequiredVersion` in the installer and here must name
# the same version, and neither may float.
ANALYZER_VERSION="1.25.0"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

# --- the two detectors -------------------------------------------------------
#
# Both take a path and return 0 clean / 1 faulted, printing what they found. The
# file path travels in the environment rather than inside the command string:
# interpolating it would make a path containing a quote into PowerShell source,
# which is the injection this repository's own outcome-attribution gate exists
# to prevent one layer up.

ps_parses() { # <file>
  # shellcheck disable=SC2016  # the PowerShell program must NOT be shell-expanded.
  PS_TARGET="$1" pwsh -NoProfile -NonInteractive -Command '
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $env:PS_TARGET, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
      $errors | ForEach-Object { Write-Output ("    {0}" -f $_.ToString()) }
      exit 1
    }
    exit 0
  '
}

ps_lints_clean() { # <file>
  # shellcheck disable=SC2016  # the PowerShell program must NOT be shell-expanded.
  PS_TARGET="$1" PS_ANALYZER_VERSION="$ANALYZER_VERSION" \
  pwsh -NoProfile -NonInteractive -Command '
    Import-Module PSScriptAnalyzer -RequiredVersion $env:PS_ANALYZER_VERSION -ErrorAction Stop
    $found = Invoke-ScriptAnalyzer -Path $env:PS_TARGET -Severity Error,Warning
    if ($found) {
      $found | ForEach-Object {
        Write-Output ("    {0}:{1} {2} — {3}" -f `
          (Split-Path -Leaf $_.ScriptPath), $_.Line, $_.RuleName, $_.Message)
      }
      exit 1
    }
    exit 0
  '
}

analyzer_available() {
  # shellcheck disable=SC2016  # the PowerShell program must NOT be shell-expanded.
  PS_ANALYZER_VERSION="$ANALYZER_VERSION" \
  pwsh -NoProfile -NonInteractive -Command '
    $m = Get-Module -ListAvailable -Name PSScriptAnalyzer |
           Where-Object { $_.Version.ToString() -eq $env:PS_ANALYZER_VERSION }
    if ($m) { exit 0 } else { exit 1 }
  ' >/dev/null 2>&1
}

# --- 0. is there a PowerShell at all -----------------------------------------
#
# A missing `pwsh` fails rather than skips. "Skipped" and "passed" are reported
# identically by a green check, and this gate is the only thing reading the
# Windows half of the fleet.

echo "powershell gate:"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "  FAIL  pwsh is not installed — the PowerShell gate cannot run, and a"
  echo "        gate that cannot run must not report success."
  exit 1
fi
# shellcheck disable=SC2016  # $PSVersionTable is PowerShell's variable, not this shell's.
ok "pwsh $(pwsh -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)"

# --- 1. selftest: prove the detectors fire -----------------------------------

if [ "${1:-}" = "--selftest" ]; then
  FIX=$(mktemp -d)
  trap 'rm -rf "$FIX"' EXIT

  # An unterminated block. Chosen over a misspelled cmdlet on purpose: a
  # misspelling parses fine and would prove nothing about the parser.
  cat >"$FIX/broken.ps1" <<'BROKEN'
function Get-Thing {
  if ($true) {
    Write-Output 'x'
}
BROKEN

  cat >"$FIX/clean.ps1" <<'CLEAN'
function Get-Thing {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string] $Name)
  Write-Output $Name
}
CLEAN

  # PSAvoidUsingInvokeExpression is a Warning, and Warning is in the severity
  # set this gate enforces. If the analyzer ever stops reporting it, this fixture
  # says so rather than the whole lint step quietly becoming decorative.
  cat >"$FIX/smelly.ps1" <<'SMELLY'
function Invoke-Thing {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string] $Command)
  Invoke-Expression $Command
}
SMELLY

  if ps_parses "$FIX/broken.ps1" >/dev/null 2>&1; then
    bad "parser accepted an unterminated block — every parse pass below is vacuous"
  else
    ok "parser flags a syntax error"
  fi

  if ps_parses "$FIX/clean.ps1" >/dev/null 2>&1; then
    ok "parser accepts a clean script"
  else
    bad "parser rejects a clean script — it would be turned off, not fixed"
  fi

  if analyzer_available; then
    if ps_lints_clean "$FIX/smelly.ps1" >/dev/null 2>&1; then
      bad "analyzer accepted Invoke-Expression — the lint step is decorative"
    else
      ok "analyzer flags a Warning-severity finding"
    fi

    if ps_lints_clean "$FIX/clean.ps1" >/dev/null 2>&1; then
      ok "analyzer accepts a clean script"
    else
      bad "analyzer rejects a clean script — it would be turned off, not fixed"
    fi
  else
    bad "PSScriptAnalyzer $ANALYZER_VERSION is not installed — half this gate is absent"
  fi

  if [ "$fail" -eq 0 ]; then
    echo "  detectors fire."
  else
    echo "  POWERSHELL GATE UNVERIFIABLE (detectors are broken)."
  fi
  exit "$fail"
fi

# --- 2. the real files -------------------------------------------------------
#
# Tracked files only, and via git rather than `find`: `find` also walks nested
# checkouts that happen to live under the tree, and a sibling worktree's content
# is not this repository's to fail on. The same correction the docs-pins gate
# already carries.

mapfile -t files < <(cd "$ROOT" && git ls-files -z -- '*.ps1' | tr '\0' '\n' | sort)

# Zero is the honest answer until the Windows boot script lands, and this gate
# deliberately ships one pull request earlier than that. It prints the count
# rather than staying silent, because "scanned nothing" and "found nothing" must
# never look the same in the log.
if [ "${#files[@]}" -eq 0 ]; then
  ok "no .ps1 tracked yet — 0 file(s) scanned"
  echo "  powershell gate ready."
  exit 0
fi

if ! analyzer_available; then
  bad "PSScriptAnalyzer $ANALYZER_VERSION is not installed — the lint half cannot run"
  echo "  POWERSHELL GATE UNVERIFIABLE."
  exit 1
fi

for rel in "${files[@]}"; do
  f="$ROOT/$rel"
  out=$(ps_parses "$f" 2>&1) || { bad "$rel: does not parse"; echo "$out"; continue; }
  out=$(ps_lints_clean "$f" 2>&1) || { bad "$rel: analyzer findings"; echo "$out"; continue; }
  ok "$rel"
done

if [ "$fail" -eq 0 ]; then
  echo "  ${#files[@]} PowerShell file(s) parse and lint clean."
else
  echo "  POWERSHELL FAULTS PRESENT."
fi
exit "$fail"
