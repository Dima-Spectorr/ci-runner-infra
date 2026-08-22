#!/usr/bin/env bash
# Every predicate below is invoked through its NAME, held in a variable, by
# assert() and mutate() -- which is the whole design: the same predicate has to
# run against the real file and against a mutated copy, and a caller that named
# it directly could not do both. shellcheck's reachability pass sees no direct
# call and reports the entire file as dead code.
# shellcheck disable=SC2317
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
PUBSH="$HERE/publish-cache-snapshot.sh"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }
[ -f "$HOST_SCRIPT" ] || { echo "FAIL: missing $HOST_SCRIPT"; exit 1; }
[ -f "$PUBSH" ] || { echo "FAIL: missing $PUBSH"; exit 1; }

# Code only: full-line comments stripped, so prose ABOUT an invariant can never
# satisfy the check FOR it. This does not strip `<# … #>` doc-comment bodies,
# which cuts the safe way here too — a docstring that spells out `gcloud storage`
# fails the negative assertion below rather than sneaking past it.
code() { # <file>
  grep -v '^[[:space:]]*#' "$1"
}

# grep -q, MINUS THE SIGPIPE. The rule is already written down three times in
# this directory -- apply-identity, apply-runner-pool and apply-trigger each
# carry it above their `matches` helper -- and this file was the one that did not
# follow it.
#
# `-q` exits on the first match, which closes the
# pipe under it; whatever is writing into that pipe -- `printf` here, `code`'s
# own `grep -v` there -- then dies of EPIPE, and `set -o pipefail` reports the
# WHOLE pipeline as failed. A predicate that FOUND its text returns false. It is
# non-deterministic by construction: it only fires when the match lands early
# enough that the writer has not already finished, so it depends on where in the
# file the text sits and on how much the pipe buffers. That is why five checks
# failed in CI (64 KiB pipe, GNU grep, ~2000-line input) while the same commit
# passed on a laptop. `-c` reads to end of input, so nothing upstream is ever cut
# off, and it still exits 1 when there is no match.
grepq() { grep -c "$@" >/dev/null; }

# --- predicates --------------------------------------------------------------

has_build_phase_guard() { # <file>
  code "$1" | grepq 'Get-BuildPhaseRefusal -Pool' || return 1
  # The call without the throw is the same as no call at all.
  code "$1" | grepq 'if ($refusal) { throw' || return 1
}

has_event_guard() { # <file>
  code "$1" | grepq 'if (-not (Test-SnapshotEventAllowed -EventName $env:GITHUB_EVENT_NAME))' || return 1
  code "$1" | grepq "refusing to build a snapshot from a" || return 1
}

has_job_object_reap() { # <file>
  code "$1" | grepq '\[CiJobObject\]::CreateKillOnClose()' || return 1
  code "$1" | grepq '\[CiJobObject\]::StartSuspendedInJob($job, $line, $WorkingDirectory)' || return 1
  # Kill and Close BOTH, and in the finally: closing alone reaps only when the
  # .NET finalizer gets round to the handle, which is not a point in time this
  # script can name.
  code "$1" | grepq '\[CiJobObject\]::Kill($job)' || return 1
  code "$1" | grepq '\[CiJobObject\]::Close($job)' || return 1
}

has_kill_on_close_flag() { # <file>
  # The flag's value and its use. A constant declared and never assigned to
  # LimitFlags creates a job object with no limits at all, which reaps nothing.
  code "$1" | grepq 'LimitKillOnJobClose = 0x2000' || return 1
  code "$1" | grepq 'info.BasicLimitInformation.LimitFlags = LimitKillOnJobClose' || return 1
  code "$1" | grepq 'ExtendedLimitInformation = 9' || return 1
}

has_bounded_prepare() { # <file>
  code "$1" | grepq '\[CiJobObject\]::Wait($handle, $TimeoutSeconds \* 1000)' || return 1
  # And the timeout is treated as a failure rather than logged: a half-populated
  # cache that publishes is worse than no snapshot.
  code "$1" | grepq 'if ($run.TimedOut)' || return 1
}

has_no_publish_surface() { # <file>
  # This job holds no credential, so it must hold no uploader either. Checked as
  # an absence because that is the only way to notice one being added.
  if code "$1" | grepq -E 'gcloud|gsutil|storage\.googleapis|Invoke-WebRequest|Invoke-RestMethod|curl\.exe'; then
    return 1
  fi
}

has_reap_before_read() { # <file>
  local run_line read_line
  run_line=$(grep -n -m1 '\$run = Invoke-PrepareInJob' "$1" | cut -d: -f1)
  read_line=$(grep -n -m1 '\$entries = @(Get-Item -LiteralPath \$stage' "$1" | cut -d: -f1)
  [ -n "$run_line" ] && [ -n "$read_line" ] || return 1
  [ "$run_line" -lt "$read_line" ] || return 1
}

has_hostile_scan_before_pack() { # <file>
  local scan_line pack_line
  scan_line=$(grep -n -m1 'Get-StagedTreeRefusal -Entries \$entries' "$1" | cut -d: -f1)
  pack_line=$(grep -n -m1 '& \$tar -czf' "$1" | cut -d: -f1)
  [ -n "$scan_line" ] && [ -n "$pack_line" ] || return 1
  [ "$scan_line" -lt "$pack_line" ] || return 1
  code "$1" | grepq '^        if ($hostile) {' || return 1
  code "$1" | grepq 'throw "refusing to pack: $hostile"' || return 1
}

has_root_in_hostile_scan() { # <file>
  # Get-ChildItem returns the descendants of whatever $stage RESOLVES to and
  # never the starting item, so a prepare command that replaces $stage with a
  # junction produces a tree that scans clean while tar packs from elsewhere.
  # The root is the one entry the scan cannot afford to omit.
  code "$1" | grepq '@(Get-Item -LiteralPath $stage -Force' || return 1
}

has_hostile_stage_left_alone() { # <file>
  # Windows PowerShell 5.1's Remove-Item -Recurse DESCENDS a directory junction.
  # Deleting a tree that was just proved to contain one deletes the junction's
  # TARGET -- as the cleanup for refusing it.
  #
  # And the cleanup runs on the FAILURE paths too, which never reach the
  # pack-time scan: a prepare command that timed out or exited non-zero is the
  # likeliest one to have left a junction behind. So the scan lives in the
  # cleanup, and the ONE recursive delete in this file is downstream of it.
  local code delete_line scan_line
  code=$(code "$1")
  printf '%s' "$code" | grepq 'Remove-StageSafely -Path $stage' || return 1
  # exactly one recursive delete of the stage, and it is inside that function
  [ "$(printf '%s\n' "$code" | grep -c 'Remove-Item -LiteralPath $Path -Recurse')" = 1 ] || return 1
  [ "$(printf '%s\n' "$code" | grep -c 'Remove-Item -LiteralPath $stage -Recurse')" = 0 ] || return 1
  scan_line=$(grep -n -m1 'Get-StagedTreeRefusal -Entries $entries' "$1" | cut -d: -f1)
  delete_line=$(grep -n -m1 'Remove-Item -LiteralPath $Path -Recurse' "$1" | cut -d: -f1)
  [ -n "$scan_line" ] && [ -n "$delete_line" ] || return 1
  [ "$scan_line" -lt "$delete_line" ] || return 1
  # a tree that could not be READ is not a tree that came back clean
  printf '%s' "$code" | grepq 'rootErrors.Count -gt 0 -or $treeErrors.Count -gt 0' || return 1
}

has_drain_after_kill() { # <file>
  local kill_line drain_line read_line
  kill_line=$(grep -n -m1 '\[CiJobObject\]::Kill(\$job)' "$1" | cut -d: -f1)
  drain_line=$(grep -n -m1 'Wait-JobObjectDrained -Job \$job' "$1" | cut -d: -f1)
  read_line=$(grep -n -m1 '\$entries = @(Get-Item -LiteralPath \$stage' "$1" | cut -d: -f1)
  [ -n "$kill_line" ] && [ -n "$drain_line" ] && [ -n "$read_line" ] || return 1
  # terminate, THEN wait for the members to actually go, THEN read the tree.
  [ "$kill_line" -lt "$drain_line" ] || return 1
  [ "$drain_line" -lt "$read_line" ] || return 1
  # …and a job that will not drain fails the build rather than logging.
  code "$1" | grepq 'ActiveProcesses' || return 1
}

has_suspended_start() { # <file>
  # The window between "the process is running" and "the process is in the job"
  # is the window in which cmd.exe spawns the package manager OUTSIDE the job:
  # unbounded by the deadline, unreached by kill-on-close, still writing into
  # the tree while it is packed. CREATE_SUSPENDED closes it by construction.
  local code create_line assign_line resume_line
  code=$(code "$1")
  printf '%s' "$code" | grepq 'CreateSuspended = 0x00000004' || return 1
  printf '%s' "$code" | grepq 'StartSuspendedInJob' || return 1
  # ...and Start-Process is gone: it has no suspended start to offer. The C#
  # block comments explain why, and code() strips only #-comments, so the //
  # ones go here.
  ! printf '%s\n' "$code" | grep -v '^[[:space:]]*//' | grepq 'Start-Process' || return 1
  create_line=$(grep -n -m1 'CreateSuspended, IntPtr.Zero, workingDirectory' "$1" | cut -d: -f1)
  assign_line=$(grep -n -m1 'AssignProcessToJobObject(job, pi.Process)' "$1" | cut -d: -f1)
  resume_line=$(grep -n -m1 'ResumeThread(pi.Thread)' "$1" | cut -d: -f1)
  [ -n "$create_line" ] && [ -n "$assign_line" ] && [ -n "$resume_line" ] || return 1
  [ "$create_line" -lt "$assign_line" ] || return 1
  [ "$assign_line" -lt "$resume_line" ] || return 1
  # a process that could not be assigned never runs at all
  printf '%s' "$code" | grepq 'TerminateProcess(pi.Process, 1)' || return 1
}

has_inherited_std_handles() { # <file>
  # A zeroed STARTUPINFO with bInheritHandles=FALSE leaves the child with no
  # usable standard handles, so every byte the prepare command writes is
  # discarded: a prepare step that fails, fails silently, and the workflow log
  # shows nothing but an exit code. STARTF_USESTDHANDLES is what makes the three
  # fields be read, and it is ignored unless handles are inherited too -- so
  # both halves are pinned, and so is the order (the fields are filled before
  # the call that reads them).
  local code create_line flags_line
  code=$(code "$1")
  printf '%s' "$code" | grepq 'UseStdHandles = 0x00000100' || return 1
  printf '%s' "$code" | grepq 'si.Flags = UseStdHandles;' || return 1
  printf '%s' "$code" | grepq 'si.StdOutput = Usable(GetStdHandle(StdOutputHandle));' || return 1
  printf '%s' "$code" | grepq 'si.StdError = Usable(GetStdHandle(StdErrorHandle));' || return 1
  printf '%s' "$code" | grepq 'CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, true,' || return 1
  # INVALID_HANDLE_VALUE is passed on as zero, not as -1: a child handed -1 can
  # still try to write to it, while zero reads as "no such stream".
  printf '%s' "$code" | grepq 'handle == InvalidHandle ? IntPtr.Zero : handle' || return 1
  flags_line=$(grep -n -m1 'si.Flags = UseStdHandles;' "$1" | cut -d: -f1)
  create_line=$(grep -n -m1 'CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, true,' "$1" | cut -d: -f1)
  [ -n "$flags_line" ] && [ -n "$create_line" ] || return 1
  [ "$flags_line" -lt "$create_line" ] || return 1
}

has_hardlink_flattening() { # <file>
  # The publish job builds its own archives with `--hard-dereference` and
  # `archive_is_flat` rejects a hard-link member. That rule is not re-derived for
  # Windows -- the publish job applies it to whatever arrives -- so a Windows
  # archive carrying one is a run that succeeds, uploads, and is then refused
  # deterministically at the far end. bsdtar has no --hard-dereference to pass,
  # so the tree is what gets flattened.
  code "$1" | grepq 'Resolve-StagedHardLink -Files $files' || return 1
  # -1 IS ITS OWN ANSWER. A link count that could not be read is not a file shown
  # to be flat, and a predicate that lets `-lt 0` fall through to `-le 1` would
  # pack exactly the members this pass exists to remove.
  code "$1" | grepq 'if ($links -lt 0) {' || return 1
  code "$1" | grepq 'return -1;' || return 1
  # THE SCRATCH NAME IS NOT A NAME THE TREE MAY ALREADY HOLD. The cache is
  # written by third-party install code, so a package shipping `foo` beside
  # `foo.ci-flatten` had the second one overwritten and then unlinked -- a real
  # cache file deleted by the pass that exists to make the archive packable.
  # A fresh GUID plus a copy that refuses to overwrite turns that into an error.
  code "$1" | grepq "'.ci-flatten-' + \[guid\]::NewGuid()" || return 1
  code "$1" | grepq 'Copy($f.FullName, $candidate, $false)' || return 1
  ! code "$1" | grepq 'Copy($f.FullName, $spare, $true)' || return 1
  # BEFORE TAR, because tar is what records the link.
  local flat pack
  flat=$(code "$1" | grep -n 'Resolve-StagedHardLink -Files $files' | cut -d: -f1 | sed -n 1p)
  pack=$(code "$1" | grep -n 'tar -czf $out -C $stage' | cut -d: -f1 | sed -n 1p)
  [ -n "$flat" ] && [ -n "$pack" ] || return 1
  [ "$flat" -lt "$pack" ]
}
has_unquiesced_stage_kept() { # <file>
  # Remove-StageSafely is safe because the tree is QUIET: it scans for reparse
  # points and then recursively deletes what scanned clean. A job object that
  # never drained is the statement that the tree is not quiet -- a surviving
  # process can plant a junction between the scan and the delete, and 5.1's
  # Remove-Item follows it. No ordering closes that window, so the delete has to
  # be given up rather than re-ordered.
  code "$1" | grepq '$script:StageNotQuiesced = $true' || return 1
  code "$1" | grepq 'if ($script:StageNotQuiesced) {' || return 1
  # And the flag is read BEFORE the recursive delete, or it is a record of
  # something that already happened.
  local flag del
  flag=$(code "$1" | grep -n 'if ($script:StageNotQuiesced) {' | cut -d: -f1 | sed -n 1p)
  del=$(code "$1" | grep -n 'Remove-Item -LiteralPath $Path -Recurse' | cut -d: -f1 | sed -n 1p)
  [ -n "$flag" ] && [ -n "$del" ] || return 1
  [ "$flag" -lt "$del" ] || return 1
  # AND THE KILL IS INSIDE THAT TRY. TerminateJobObject can report failure and
  # the wrapper raises when it does; thrown from IN FRONT of the try, that
  # skipped the flag entirely -- so the one path where the members were never
  # even asked to stop was the one path that left the stage looking quiesced.
  # Adjacency is the check: the kill and the drain wait are the same try block.
  local after
  after=$(code "$1" | grep -A1 -F '[CiJobObject]::Kill($job)' | sed -n 2p)
  printf '%s\n' "$after" | grepq 'Wait-JobObjectDrained -Job $job' || return 1
}
has_credential_name_scan() { # <file>
  # WHY THIS PASS EXISTS ON THIS SIDE AT ALL. The publish job scans the tree
  # again and refuses far more thoroughly -- but between the two jobs the
  # archive is an `upload-artifact`, and an artifact is downloadable by anyone
  # who can read the repository from the moment it is stored. A refusal in the
  # publish job happens after that and cannot take it back. So the name half of
  # the scan has to run on the side that produced the tree.
  code "$1" | grepq 'Get-CredentialFileRefusal -Entries $entries' || return 1
  # Computed and ignored is the same as not computed: both the guard that reads
  # the verdict and the throw that acts on it, or a scan whose answer goes
  # nowhere passes this predicate while packing the credential.
  code "$1" | grepq 'if ($credential) {' || return 1
  code "$1" | grepq 'throw "refusing to pack: $credential"' || return 1
  # ORDER: before the archive is written, or it is a refusal of a file that has
  # already been packed.
  local cred pack
  cred=$(code "$1" | grep -n 'Get-CredentialFileRefusal -Entries $entries' | cut -d: -f1 | sed -n 1p)
  pack=$(code "$1" | grep -n 'tar -czf $out -C $stage' | cut -d: -f1 | sed -n 1p)
  [ -n "$cred" ] && [ -n "$pack" ] || return 1
  [ "$cred" -lt "$pack" ]
}
has_agreeing_credential_names() { # <file>
  # Two copies of one security rule. The shell side spells it as `find -name`
  # predicates because that is what it has; this side spells it as PowerShell
  # wildcards because git-bash's find is not reachable from the build job. What
  # makes the duplicate safe is that neither may move without the other: a name
  # dropped here is a credential the artifact carries out of the build job, and
  # a name dropped there is one the bucket accepts.
  #
  # Compared as SETS, sorted, because the two files order their lists to read
  # well in their own syntax and pinning the order would be pinning formatting.
  # `-iname` and `-name` collapse to the same entry deliberately: NTFS matching
  # is case-insensitive, so the one entry the shell has to spell `-iname` is
  # already what PowerShell's `-like` does to every entry.
  local mine theirs
  mine=$(sed -n '/^\$script:CredentialFileNames = @(/,/^)/p' "$1" |
    grep -oE "'[^']+'" | tr -d "'" | sort)
  theirs=$(sed -n '/-name/p' "$PUBSH" |
    grep -oE -- "-i?name '[^']+'" | grep -oE "'[^']+'" | tr -d "'" | sort -u)
  [ -n "$mine" ] && [ -n "$theirs" ] || return 1
  [ "$mine" = "$theirs" ]
}
has_packed_file_count() { # <file>
  # tar packs the named cache directories. Counting every file under the staging
  # root instead lets one stray marker stand in for a warm cache, and publishes
  # an archive of empty directories that every host unpacks over its master.
  code "$1" | grepq 'script:CacheDirs -contains $_.FullName.Substring($prefix.Length)' || return 1
}

has_local_staging_root() { # <file>
  # An empty GITHUB_EVENT_NAME is accepted as a local build, and tested as one.
  # RUNNER_TEMP exists only on Actions, so a Join-Path against it alone would
  # make that allowance a lie.
  code "$1" | grepq 'System.IO.Path\]::GetTempPath()' || return 1
}

has_empty_tree_refusal() { # <file>
  # An empty archive is a valid archive, and it would replace every host's warm
  # master with nothing. The failure mode that looks exactly like success.
  code "$1" | grepq 'if ($files.Count -eq 0)' || return 1
}

has_archive_rooted_at_the_tool_names() { # <file>
  # -C the stage, then the names. Without -C the members carry a path prefix and
  # the host — which unpacks expecting exactly these top-level names — hydrates
  # nothing while every step reports success.
  code "$1" | grepq '& $tar -czf $out -C $stage $script:CacheDirs' || return 1
}

has_stage_cleanup() { # <file>
  # In the finally, so a throw between staging and packing does not leave the
  # tree behind -- and THROUGH Remove-StageSafely, which is the only delete that
  # first proves the tree is free of reparse points. A direct Remove-Item here
  # would still clean up; it would just do it by following whatever a prepare
  # command pointed at.
  code "$1" | grepq 'Remove-StageSafely -Path $stage' || return 1
  code "$1" | grepq 'Remove-Item -LiteralPath $stage' && return 1
  return 0
}

has_inert_dot_source() { # <file>
  code "$1" | grepq "if (\$MyInvocation.InvocationName -ne '.')" || return 1
  # Nothing at column 0 may change the caller's state or compile a type: the
  # Pester suite dot-sources this file on Linux, where kernel32 does not exist.
  if code "$1" | grepq -E '^(Set-StrictMode|\$ErrorActionPreference|Add-Type)'; then
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
assert "the staging root itself is scanned, not only its descendants" has_root_in_hostile_scan
assert "a tree with a reparse point is left, not recursively deleted"  has_hostile_stage_left_alone
assert "the job is drained before the tree is read"                    has_drain_after_kill
assert "the prepare command is in the job before it can run"           has_suspended_start
assert "the prepare command's output reaches the workflow log"         has_inherited_std_handles
assert "hard links are broken before the archive is written"          has_hardlink_flattening
assert "a stage that never drained is left on disk, not deleted"      has_unquiesced_stage_kept
assert "a credential file is refused before the archive is written"    has_credential_name_scan
assert "the refused filenames are the same ones the publish job refuses" has_agreeing_credential_names
assert "the emptiness check counts only what tar packs"                has_packed_file_count
assert "there is a staging root off Actions too"                       has_local_staging_root

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

mutate "the prepare command started outside the job" \
  's|^        $started = \[CiJobObject\]::StartSuspendedInJob(.*$|        $null = $job|' \
  has_job_object_reap

mutate "the job closed without being terminated first" \
  's|^            \[CiJobObject\]::Kill($job)$|            $null = $job|' \
  has_job_object_reap

mutate "a job object created with no limits at all" \
  's|info.BasicLimitInformation.LimitFlags = LimitKillOnJobClose|info.BasicLimitInformation.LimitFlags = 0|' \
  has_kill_on_close_flag

mutate "the deadline replaced by an unbounded wait" \
  's|Wait($handle, $TimeoutSeconds \* 1000)|Wait($handle, -1)|' \
  has_bounded_prepare

mutate "a timeout logged instead of failing the build" \
  's|^        if ($run.TimedOut) {$|        if ($false) {|' \
  has_bounded_prepare

mutate "an upload added to the build job" \
  's|^        Write-BuildLog "packing $out"$|        Invoke-RestMethod -Method Put -InFile $out -Uri $dest|' \
  has_no_publish_surface

mutate "the tree read before the job is reaped" \
  's|^        $entries = @(Get-Item -LiteralPath $stage.*$|        $entries = @()\n        $run = Invoke-PrepareInJob -Command x -TimeoutSeconds 1 -WorkingDirectory .|' \
  has_reap_before_read

mutate "the reparse-point verdict computed and ignored" \
  's|^        if ($hostile) {$|        if ($false) {|' \
  has_hostile_scan_before_pack

mutate "only the staged tree's descendants scanned" \
  's|@(Get-Item -LiteralPath $stage -Force -ErrorAction Stop) +|@() +|' \
  has_root_in_hostile_scan

mutate "a hostile tree recursively deleted anyway" \
  's|^        Remove-StageSafely -Path $stage$|        Remove-Item -LiteralPath $stage -Recurse -Force|' \
  has_hostile_stage_left_alone

mutate "an unreadable tree deleted as if it were clean" \
  's|^    if ($rootErrors.Count -gt 0 -or $treeErrors.Count -gt 0) {$|    if ($false) {|' \
  has_hostile_stage_left_alone

mutate "the job terminated but never drained" \
  's|^ *Wait-JobObjectDrained -Job $job -TimeoutSeconds 60$|            $null = $job|' \
  has_drain_after_kill

mutate "the prepare command started running before it is assigned" \
  's|CreateSuspended, IntPtr.Zero, workingDirectory|0, IntPtr.Zero, workingDirectory|' \
  has_suspended_start

mutate "resumed before it is in the job" \
  's|^            if (!AssignProcessToJobObject(job, pi.Process))$|            if (ResumeThread(pi.Thread) == 0 \&\& !AssignProcessToJobObject(job, pi.Process))|' \
  has_suspended_start

mutate "the prepare command started with no standard handles" \
  's|CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, true,|CreateProcess(null, line, IntPtr.Zero, IntPtr.Zero, false,|' \
  has_inherited_std_handles

mutate "the handle fields filled but never read" \
  's|^        si.Flags = UseStdHandles;$|        si.Flags = 0;|' \
  has_inherited_std_handles

mutate "an invalid handle inherited as -1" \
  's|handle == InvalidHandle ? IntPtr.Zero : handle|handle|' \
  has_inherited_std_handles

mutate "the hard-link flattening dropped from the pack path" \
  's@^        $flattened = Resolve-StagedHardLink -Files $files$@        $flattened = 0@' \
  has_hardlink_flattening
mutate "an unreadable link count treated as a flat file" \
  's@^        if ($links -lt 0) {$@        if ($false) {@' \
  has_hardlink_flattening
mutate "the flattening scratch file overwriting a cache file of that name" \
  's@\[System.IO.File\]::Copy($f.FullName, $candidate, $false)@[System.IO.File]::Copy($f.FullName, $candidate, $true)@' \
  has_hardlink_flattening
mutate "the kill moved back in front of the try that records a stage still being written" \
  '/^            \[CiJobObject\]::Kill($job)$/d; s@^        try {$@        [CiJobObject]::Kill($job)\n        try {@' \
  has_unquiesced_stage_kept
mutate "the failed drain never recorded" \
  's@$script:StageNotQuiesced = $true@$null = $job@' \
  has_unquiesced_stage_kept
mutate "the cleanup run over a tree that never drained" \
  's@^    if ($script:StageNotQuiesced) {$@    if ($false) {@' \
  has_unquiesced_stage_kept
mutate "the credential filename scan computed and ignored" \
  's@^        if ($credential) {$@        if ($false) {@' \
  has_credential_name_scan
mutate "the credential scan dropped from the pack path" \
  's@^        $credential = Get-CredentialFileRefusal -Entries $entries$@@' \
  has_credential_name_scan
mutate "one credential filename quietly dropped from this side" \
  "s@'.netrc', @@" \
  has_agreeing_credential_names
mutate "every staged file counted, not only the packed ones" \
  's|($script:CacheDirs -contains $_.FullName.Substring($prefix.Length).Split(.\\.)\[0\])|$true|' \
  has_packed_file_count

mutate "no staging root off Actions" \
  's|\[System.IO.Path\]::GetTempPath()|$env:RUNNER_TEMP|' \
  has_local_staging_root

mutate "an empty tree packed and published" \
  's|^        if ($files.Count -eq 0) {$|        if ($false) {|' \
  has_empty_tree_refusal

mutate "the archive rooted at the staging path instead of the tool names" \
  's|& $tar -czf $out -C $stage $script:CacheDirs|\& $tar -czf $out $stage|' \
  has_archive_rooted_at_the_tool_names

mutate "the staging tree left on disk" \
  's|^        Remove-StageSafely -Path $stage$|        $null = $stage|' \
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
