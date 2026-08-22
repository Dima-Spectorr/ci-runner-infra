#!/usr/bin/env bash
# Self-test for the Windows snapshot BUILD phase's structural invariants.
#
# Its companions are the Pester suite over the pure functions
# (build-cache-snapshot.Tests.ps1), which runs them on ubuntu-latest, and the
# parse/analyzer gate (powershell-gate.sh). What is left for this file is the
# half neither of those can reach: whether the pure functions are actually
# CALLED, whether the install is actually bounded, and whether the ORDER the
# safety argument depends on is the order in the file. A guard nobody invokes
# passes every unit test it has.
#
# WHAT WOULD BREAK SILENTLY
#
#   the split dissolves      Get-BuildPhaseRefusal is the whole two-job argument.
#                            Dropping the call — or the throw after it — leaves a
#                            green build that runs third-party install code in a
#                            job holding an OIDC token, and nothing about the
#                            artifact looks different afterwards.
#
#   the bound disappears     Replacing the timed WaitForExit with a bare one, or
#                            dropping the job object for taskkill, still produces
#                            a snapshot on every run that happens to behave. The
#                            run where the install spawns a service is the one
#                            that packs a tree still being written, and it is
#                            indistinguishable from a slow build.
#
#   the reap moves           The tree is read for hostile entries and packed on
#                            the assumption nothing is still writing it. That is
#                            only true because the job is terminated first. Moving
#                            the reap after the read reads clean, tests clean, and
#                            voids the claim.
#
#   a credential arrives     This file must never grow an upload. The moment it
#                            can reach a bucket, the two-job split it enforces
#                            three lines earlier is theatre.
#
# Every mutation breaks the script the way a later edit plausibly would and
# asserts the matching predicate goes false. A gate that only passes on correct
# input is not evidence.

# Every predicate matches the TEXT of build-cache-snapshot.ps1, in which `$job`,
# `$proc` and `$stage` are the literal characters that must be there. Expanding
# them here would compare against this test's own environment.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/build-cache-snapshot.ps1"
HOST_SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/windows-host-startup.ps1"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }
[ -f "$HOST_SCRIPT" ] || { echo "FAIL: missing $HOST_SCRIPT"; exit 1; }

# Code only: full-line comments stripped, so prose ABOUT an invariant can never
# satisfy the check FOR it. This does not strip `<# … #>` doc-comment bodies,
# which cuts the safe way here too — a docstring that spells out `gcloud storage`
# fails the negative assertion below rather than sneaking past it.
code() { # <file>
  grep -v '^[[:space:]]*#' "$1"
}

# --- predicates --------------------------------------------------------------

has_build_phase_guard() { # <file>
  code "$1" | grep -q 'Get-BuildPhaseRefusal -Pool' || return 1
  # The call without the throw is the same as no call at all.
  code "$1" | grep -q 'if ($refusal) { throw' || return 1
}

has_event_guard() { # <file>
  code "$1" | grep -q 'if (-not (Test-SnapshotEventAllowed -EventName $env:GITHUB_EVENT_NAME))' || return 1
  code "$1" | grep -q "refusing to build a snapshot from a" || return 1
}

has_job_object_reap() { # <file>
  code "$1" | grep -q '\[CiJobObject\]::CreateKillOnClose()' || return 1
  code "$1" | grep -q '\[CiJobObject\]::Assign($job, $proc.Handle)' || return 1
  # Kill and Close BOTH, and in the finally: closing alone reaps only when the
  # .NET finalizer gets round to the handle, which is not a point in time this
  # script can name.
  code "$1" | grep -q '\[CiJobObject\]::Kill($job)' || return 1
  code "$1" | grep -q '\[CiJobObject\]::Close($job)' || return 1
}

has_kill_on_close_flag() { # <file>
  # The flag's value and its use. A constant declared and never assigned to
  # LimitFlags creates a job object with no limits at all, which reaps nothing.
  code "$1" | grep -q 'LimitKillOnJobClose = 0x2000' || return 1
  code "$1" | grep -q 'info.BasicLimitInformation.LimitFlags = LimitKillOnJobClose' || return 1
  code "$1" | grep -q 'ExtendedLimitInformation = 9' || return 1
}

has_bounded_prepare() { # <file>
  code "$1" | grep -q 'WaitForExit($TimeoutSeconds \* 1000)' || return 1
  # And the timeout is treated as a failure rather than logged: a half-populated
  # cache that publishes is worse than no snapshot.
  code "$1" | grep -q 'if ($run.TimedOut)' || return 1
}

has_no_publish_surface() { # <file>
  # This job holds no credential, so it must hold no uploader either. Checked as
  # an absence because that is the only way to notice one being added.
  if code "$1" | grep -Eq 'gcloud|gsutil|storage\.googleapis|Invoke-WebRequest|Invoke-RestMethod|curl\.exe'; then
    return 1
  fi
}

has_reap_before_read() { # <file>
  local run_line read_line
  run_line=$(grep -n '\$run = Invoke-PrepareInJob' "$1" | head -1 | cut -d: -f1)
  read_line=$(grep -n '\$entries = @(Get-ChildItem -LiteralPath \$stage' "$1" | head -1 | cut -d: -f1)
  [ -n "$run_line" ] && [ -n "$read_line" ] || return 1
  [ "$run_line" -lt "$read_line" ] || return 1
}

has_hostile_scan_before_pack() { # <file>
  local scan_line pack_line
  scan_line=$(grep -n 'Get-StagedTreeRefusal -Entries \$entries' "$1" | head -1 | cut -d: -f1)
  pack_line=$(grep -n '& \$tar -czf' "$1" | head -1 | cut -d: -f1)
  [ -n "$scan_line" ] && [ -n "$pack_line" ] || return 1
  [ "$scan_line" -lt "$pack_line" ] || return 1
  code "$1" | grep -q 'if ($hostile) { throw' || return 1
}

has_empty_tree_refusal() { # <file>
  # An empty archive is a valid archive, and it would replace every host's warm
  # master with nothing. The failure mode that looks exactly like success.
  code "$1" | grep -q 'if ($files.Count -eq 0)' || return 1
}

has_archive_rooted_at_the_tool_names() { # <file>
  # -C the stage, then the names. Without -C the members carry a path prefix and
  # the host — which unpacks expecting exactly these top-level names — hydrates
  # nothing while every step reports success.
  code "$1" | grep -q '& $tar -czf $out -C $stage @script:CacheDirs' || return 1
}

has_stage_cleanup() { # <file>
  code "$1" | grep -q 'Remove-Item -LiteralPath $stage -Recurse -Force' || return 1
}

has_inert_dot_source() { # <file>
  code "$1" | grep -q "if (\$MyInvocation.InvocationName -ne '.')" || return 1
  # Nothing at column 0 may change the caller's state or compile a type: the
  # Pester suite dot-sources this file on Linux, where kernel32 does not exist.
  if code "$1" | grep -Eq '^(Set-StrictMode|\$ErrorActionPreference|Add-Type)'; then
    return 1
  fi
}

has_matching_cache_dir_lists() { # <file>
  # Two copies of one fact: a name here the host does not know is downloaded and
  # discarded, and a name there that is not here is never warmed. Compared as
  # whole lines so the ORDER has to match too, which is what keeps them diffable
  # by eye.
  local mine theirs
  mine=$(grep -m1 '^\$script:CacheDirs = ' "$1")
  theirs=$(grep -m1 '^\$script:CacheDirs = ' "$HOST_SCRIPT")
  [ -n "$mine" ] && [ "$mine" = "$theirs" ]
}

# --- static assertions -------------------------------------------------------

echo "build-cache-snapshot self-test:"

assert() { # <description> <predicate>
  if "$2" "$SCRIPT"; then ok; else bad "$1"; fi
}

assert "the two-job split is refused in code, not just documented" has_build_phase_guard
assert "untrusted-event runs are refused before the install"       has_event_guard
assert "the install runs inside a kill-on-close job object"        has_job_object_reap
assert "the job object is created with the kill-on-close limit"    has_kill_on_close_flag
assert "the install is bounded and a timeout is fatal"             has_bounded_prepare
assert "this phase can reach no bucket"                            has_no_publish_surface
assert "the job is reaped before the tree is read"                 has_reap_before_read
assert "the tree is scanned for reparse points before packing"     has_hostile_scan_before_pack
assert "an empty staged tree is refused"                           has_empty_tree_refusal
assert "the archive's members are the bare tool directories"       has_archive_rooted_at_the_tool_names
assert "the staging tree is removed on every path"                 has_stage_cleanup
assert "the file is dot-sourceable with no side effects"           has_inert_dot_source
assert "the tool list matches the host's, name for name and in order" has_matching_cache_dir_lists

# --- mutations ---------------------------------------------------------------
#
# Each one edits a copy, re-runs the matching predicate, and requires it to go
# FALSE. A predicate that survives its own mutation is matching something other
# than what it claims to.

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mutate() { # <description> <sed-program> <predicate>
  local copy="$TMP/mutated.ps1"
  sed "$2" "$SCRIPT" > "$copy"
  if ! cmp -s "$SCRIPT" "$copy"; then
    if "$3" "$copy"; then bad "mutation not caught: $1"; else ok; fi
  else
    bad "mutation did not apply (the predicate is untested): $1"
  fi
}

mutate "the build-phase refusal computed and ignored" \
  's|^    if ($refusal) { throw.*$|    if ($false) { throw "x" }|' \
  has_build_phase_guard

mutate "the event guard dropped" \
  's|^    if (-not (Test-SnapshotEventAllowed.*$|    if ($false) {|' \
  has_event_guard

mutate "the process assigned to no job object" \
  's|^        \[CiJobObject\]::Assign($job, $proc.Handle)$|        $null = $job|' \
  has_job_object_reap

mutate "the job closed without being terminated first" \
  's|^        \[CiJobObject\]::Kill($job)$|        $null = $job|' \
  has_job_object_reap

mutate "a job object created with no limits at all" \
  's|info.BasicLimitInformation.LimitFlags = LimitKillOnJobClose|info.BasicLimitInformation.LimitFlags = 0|' \
  has_kill_on_close_flag

mutate "the deadline replaced by an unbounded wait" \
  's|WaitForExit($TimeoutSeconds \* 1000)|WaitForExit()|' \
  has_bounded_prepare

mutate "a timeout logged instead of failing the build" \
  's|^        if ($run.TimedOut) {$|        if ($false) {|' \
  has_bounded_prepare

mutate "an upload added to the build job" \
  's|^        Write-BuildLog "packing $out"$|        Invoke-RestMethod -Method Put -InFile $out -Uri $dest|' \
  has_no_publish_surface

mutate "the tree read before the job is reaped" \
  's|^        $entries = @(Get-ChildItem -LiteralPath $stage.*$|        $entries = @()\n        $run = Invoke-PrepareInJob -Command x -TimeoutSeconds 1 -WorkingDirectory .|' \
  has_reap_before_read

mutate "the reparse-point verdict computed and ignored" \
  's|^        if ($hostile) { throw.*$|        $null = $hostile|' \
  has_hostile_scan_before_pack

mutate "an empty tree packed and published" \
  's|^        if ($files.Count -eq 0) {$|        if ($false) {|' \
  has_empty_tree_refusal

mutate "the archive rooted at the staging path instead of the tool names" \
  's|& $tar -czf $out -C $stage @script:CacheDirs|\& $tar -czf $out $stage|' \
  has_archive_rooted_at_the_tool_names

mutate "the staging tree left on disk" \
  's|^        Remove-Item -LiteralPath $stage -Recurse -Force.*$|        $null = $stage|' \
  has_stage_cleanup

mutate "the entry-point guard removed, so dot-sourcing runs main" \
  "s|^if (\$MyInvocation.InvocationName -ne '.') {$|if (\$true) {|" \
  has_inert_dot_source

mutate "strict mode set at script scope, where a dot-source inherits it" \
  '1i Set-StrictMode -Version Latest' \
  has_inert_dot_source

mutate "the type compiled at import, on a machine with no kernel32" \
  '1i Add-Type -TypeDefinition "public class X {}"' \
  has_inert_dot_source

mutate "a tool directory the host will never unpack" \
  "s|^\$script:CacheDirs = .*$|\$script:CacheDirs = @('npm', 'cargo')|" \
  has_matching_cache_dir_lists

# --- verdict -----------------------------------------------------------------

echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  echo "  BUILD-PHASE INVARIANTS BROKEN."
  exit 1
fi
echo "  build-phase invariants hold."
exit 0
