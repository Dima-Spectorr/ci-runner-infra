#!/usr/bin/env bash
# Self-test for the per-slot dependency cache.
#
# Two unrelated reasons this file exists, and both are load-bearing.
#
# FIRST: every performance failure mode here is SILENT. A job with a
# misconfigured cache still passes; it just re-downloads everything, and the only
# symptom is a wall-time number nobody watches per-job. That is exactly how
# `packer/warm-cache/none.sh` stayed a stub for five minor versions while the
# image described itself as carrying "pre-warmed caches".
#
# SECOND, and the reason most of the assertions below are about permissions
# rather than about speed: the first version of this layer was a single shared
# group-writable tree, and it was rejected in review as a cross-slot code
# execution channel. Every cache directory is a place its own tool treats as
# already-verified input — `npx` runs straight out of the npm cache, Maven skips
# checksums for an artifact already in the local repository — so a tree two slots
# can both write is a way for one slot to hand another slot code to run, as that
# slot's user, with that slot's token. The fix was to give each slot its own copy
# and make the shared master read-only. Nothing about that is visible in a job's
# output either, which is why it is asserted here.
#
# The failure modes, all asserted below:
#
#   wrong variable    Point pnpm at a store with the spelling it stopped reading
#                     in v11 and it does not warn — it stores nothing where you
#                     asked and reports success.
#   shared writable   The rejected design. A `chgrp ci` / `2775` / `UMask=0002`
#                     anywhere in this script means it came back.
#   foreign ownership A seeded file must end up owned by the slot that uses it.
#                     Root-owned is not merely untidy: `fs.protected_hardlinks`
#                     forbids a non-owner from hardlinking a file it cannot
#                     write, so pnpm and uv — whose whole performance model is
#                     hardlinking out of the store — silently fall back to
#                     copying, and the cache buys nothing.
#   unsafe sharing    GOCACHE (golang/go#43645) and RUNNER_TOOL_CACHE
#                     (actions/toolkit#804) are documented as NOT safe for
#                     concurrent writers.
#   root operates in a job-writable directory
#                     The escalation, stated correctly — an earlier revision of
#                     this file stated it wrongly and asserted the wrong fix.
#                     GNU chown walks with FTS_PHYSICAL as soon as -R is given
#                     (coreutils src/chown.c), so the RECURSIVE form has never
#                     dereferenced and -h adds nothing to it. The form that DOES
#                     dereference is the plain `chown u:g path`. This script runs
#                     as root on EVERY boot over trees that survive a reset, so
#                     the invariant asserted below is structural rather than a
#                     flag: every directory in which root creates, renames or
#                     chowns an entry must be root-owned, leaving no name for a
#                     slot to substitute between the test and the call.
#   torn seed         A half-copied cache directory visible at the path a tool
#                     reads is a truncated entry served as a real one.
#   fails closed      A cache problem must never stop a host registering. A slow
#                     host is worth more than a missing one, because the pool
#                     answers a missing host by queueing jobs.
#
# The checks are STRUCTURAL, and the mutations below break the script the way a
# later edit plausibly would: a gate that only passes on correct input is not
# evidence.

# The predicates match the TEXT of host-startup.sh, in which `$CACHE_MASTER`,
# `$c` and `$idx` are the literal characters that must be present. Expanding them
# here would compare against this test's own environment and pass on any script.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/host-startup.sh"
PACKER="$HERE/../../packer/ci-host-image.pkr.hcl"
POOLTF="$HERE/../../modules/ci-runner-host-pool/main.tf"
POOLVARS="$HERE/../../modules/ci-runner-host-pool/variables.tf"
PUBTF="$HERE/../../modules/ci-runner-cache-publisher/main.tf"
PUBVARS="$HERE/../../modules/ci-runner-cache-publisher/variables.tf"
BUCKETTF="$HERE/../../modules/ci-runner-cache-bucket/main.tf"
TELEM="$HERE/../../modules/ci-runner-host-pool/scripts/telemetry.sh"
PUBSH="$HERE/publish-cache-snapshot.sh"
# The embedded-credential CONTENT pass, extracted so the Windows builder can run
# the same patterns. It is asserted as ONE body of code with the publisher below:
# a rule that moved from one file to the other must not be able to look like a
# rule that was deleted, and a rule deleted from both must not be able to look
# like a rule that moved.
SCANSH="$HERE/scan-cache-credentials.sh"
PUBDOC="$HERE/../../docs/publishing-a-cache-snapshot.md"

PASS=0
FAIL=0

SKIP=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
# Counted and printed, never silent: a skip that does not appear in the summary
# is a check that stopped running without anyone deciding it should.
skip() { SKIP=$((SKIP + 1)); printf 'SKIP: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }
[ -f "$PACKER" ] || { echo "FAIL: missing $PACKER"; exit 1; }
[ -f "$POOLTF" ] || { echo "FAIL: missing $POOLTF"; exit 1; }
[ -f "$POOLVARS" ] || { echo "FAIL: missing $POOLVARS"; exit 1; }
[ -f "$PUBTF" ] || { echo "FAIL: missing $PUBTF"; exit 1; }
[ -f "$PUBVARS" ] || { echo "FAIL: missing $PUBVARS"; exit 1; }
[ -f "$BUCKETTF" ] || { echo "FAIL: missing $BUCKETTF"; exit 1; }
[ -f "$TELEM" ] || { echo "FAIL: missing $TELEM"; exit 1; }
[ -f "$PUBSH" ] || { echo "FAIL: missing $PUBSH"; exit 1; }
[ -f "$SCANSH" ] || { echo "FAIL: missing $SCANSH"; exit 1; }
[ -f "$PUBDOC" ] || { echo "FAIL: missing $PUBDOC"; exit 1; }

# Code only: full-line comments stripped, so the prose explaining an invariant
# can never be what satisfies the check for it. This matters more here than
# anywhere else in the repository, because the comments in this section NAME
# every variable and every mechanism that must not be present — `GOCACHE`,
# `RUNNER_TOOL_CACHE`, `cp -al`, `2775` and `UMask` all appear as documented
# rejections, so a check reading raw text would see them and pass.
#
# Takes one file or several. Several is what lets a predicate assert over a pair
# of files that were once one file: `-h` so no `==>` header can ever satisfy a
# pattern, and the concatenation order is the caller's, never glob order.
code_of() { grep -hvE '^[[:space:]]*#' "$@"; }

# Never `... | grep -q` under `set -o pipefail`: grep exits on the match, the
# writer takes SIGPIPE and exits 141, and pipefail reports a SUCCESSFUL match as
# a failure — as a race with how much the writer had buffered, so it passes on a
# laptop and fails on a runner against a byte-identical file.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# --- the invariants -----------------------------------------------------------

# Every cache variable is the one the tool's own documentation names, and every
# one of them points at THIS SLOT's cache (`$c`) rather than at the shared
# master. A wrong name is not an error at any layer: the tool falls back to its
# default under $HOME, which works, is private, and dies with the host.
has_cache_env() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" '^Environment=npm_config_cache=\$c/npm$'              || return 1
  matches "$code" '^Environment=YARN_CACHE_FOLDER=\$c/yarn$'            || return 1
  # BOTH pnpm spellings: v11 reads pnpm_config_store_dir and silently ignores
  # the npm_config_ form, and repositories pin their own pnpm.
  matches "$code" '^Environment=pnpm_config_store_dir=\$c/pnpm-store$'  || return 1
  matches "$code" '^Environment=npm_config_store_dir=\$c/pnpm-store$'   || return 1
  matches "$code" '^Environment=GOMODCACHE=\$c/go-mod$'                 || return 1
  matches "$code" '^Environment=PIP_CACHE_DIR=\$c/pip$'                 || return 1
  matches "$code" '^Environment=UV_CACHE_DIR=\$c/uv$'                   || return 1
  matches "$code" '^Environment=MAVEN_ARGS=-Dmaven\.repo\.local=\$c/m2$' || return 1
  matches "$code" '^Environment=NUGET_PACKAGES=\$c/nuget$'              || return 1
  matches "$code" '^Environment=COMPOSER_CACHE_DIR=\$c/composer$'       || return 1
  # Emitting the block is not enough — it has to reach the unit, per slot.
  matches "$code" 'CACHE_ENV=\$\(cache_env "\$idx"\)'                   || return 1
  matches "$code" '^\$CACHE_ENV$'                                       || return 1
}

# The rejected design must not come back. Each of these is individually
# sufficient to rebuild the shared writable tree: a group that spans slots, a
# setgid group-writable mode on the cache, or a group-write umask on the agent.
# The master's own root directory is repaired at boot; nothing inside it is.
#
# This is the one place in the cache path where the host FIXES something instead
# of refusing it, so the whole value of the change is in its scope. Every check
# below is about that scope, because a repair that grew a `-R` would silently
# convert the hostility scan from a gate into a laundering step: the setuid
# binary gets its bits stripped, the scan then finds nothing, and the tree is
# copied into every slot with the gate reporting clean.
has_master_root_heal() { # <file>
  local code heal
  code=$(code_of "$1")
  matches "$code" '^heal_cache_master_root\(\)' || return 1
  # Before the scan, or it never runs: the scan is what returns the refusal.
  matches "$code" 'heal_cache_master_root$'     || return 1
  matches "$code" '^lock_shared_cache\(\)'      || return 1

  # The body, in isolation — a `-R` elsewhere in this script is legitimate and
  # must not be what satisfies or fails this.
  heal=$(printf '%s\n' "$code" | sed -n '/^heal_cache_master_root()/,/^}/p')
  # Recursive in ANY spelling. `chmod -R` here is the whole failure mode.
  ! matches "$heal" 'chmod[[:space:]]+(-[[:alnum:]]*R|--recursive)' || return 1
  ! matches "$heal" 'chown[[:space:]]+(-[[:alnum:]]*R|--recursive)' || return 1
  # It repairs the master and only the master. A staged snapshot is untrusted
  # content and gets no repairs; taking a tree argument is how that would start.
  ! matches "$heal" 'CACHE_STAGE'                                   || return 1
  ! matches "$heal" '\$\{?1'                                        || return 1
  # An explicit mode, because clearing setgid is the point and `go-w` — which is
  # what was already running and not doing it — leaves the bit set.
  matches "$heal" 'chmod[[:space:]]+0755'                           || return 1
  ! matches "$heal" 'chmod[[:space:]]+[^0]*go-w'                    || return 1
  # A symlink is refused by the scan, not followed by the repair. chmod has no
  # --no-dereference, so without this the repair walks off the tree.
  matches "$heal" '\[ -L "\$CACHE_MASTER" \]'                       || return 1
  return 0
}

has_no_shared_writable_tree() { # <file>
  local code
  code=$(code_of "$1")
  ! matches "$code" 'chgrp[[:space:]]+-R[[:space:]]+ci'  || return 1
  ! matches "$code" 'chmod[[:space:]]+2775'              || return 1
  ! matches "$code" '^UMask=0002$'                       || return 1
  # A supplementary group shared by every slot user. It grants nothing today,
  # which is exactly why it must not exist: it is one chgrp away from being the
  # rejected design again, and the next reader has no way to tell it was inert.
  ! matches "$code" 'usermod[[:space:]]+-aG[[:space:]]+ci[[:space:]]' || return 1
  # `cp -al` is the hardlink seed that shares inodes between slots. It is safe
  # only while the files stay root-owned and unwritable — which is precisely the
  # state that locks pnpm and uv out of them under fs.protected_hardlinks. Both
  # halves cannot be true at once, so the mechanism is banned outright.
  ! matches "$code" 'cp[[:space:]]+-al'                  || return 1
}

# The master is shared, so nothing but root may write it; each slot's copy is
# private, so it must be owned by that slot. Both halves, or the design is a
# shared tree wearing per-slot paths.
has_ownership_split() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'chown[[:space:]]+-Rh[[:space:]]+root:root[[:space:]]+"\$CACHE_MASTER"' || return 1
  matches "$code" 'chmod[[:space:]]+-R[[:space:]]+go-w,go\+rX[[:space:]]+"\$CACHE_MASTER"' || return 1
  # The seeded copy is chowned to the slot RECURSIVELY. Not cosmetic: a
  # root-owned file the slot can only read cannot be hardlinked by that slot
  # (fs.protected_hardlinks) and cannot be chmod'd by it either, so pnpm, uv and
  # every chmod-then-write installer degrade or fail.
  matches "$code" 'chown[[:space:]]+-R[[:space:]]+"\$u:\$u"'                              || return 1
  # Copied, never referenced: --no-preserve=ownership leaves no root-owned file
  # in a tree the slot writes to even for the moment before the chown.
  matches "$code" 'cp[[:space:]]+-a[[:space:]]+--no-preserve=ownership'                   || return 1
  # One slot must not be able to read another's cached content. The 0700 is on
  # the TOOL directory, created with its owner and mode in one call.
  matches "$code" 'install -d -o "\$u" -g "\$u" -m 0700 "\$dst/\$d"'                      || return 1
}

# A cache the owning tool cannot write to, and that every other slot can read.
#
# Both halves come from the same fact: `cp -a` PRESERVES mode and `chown -R`
# changes only the owner, so a copy of the sealed master arrives with the seal's
# modes. Seal it `a-w` and the slot's own directories land 0555 — EACCES on the
# first write, from the copy that exists to make writes unnecessary. And the
# `install -d … -m 0700` that is supposed to keep one slot out of another's cache
# is guarded by `[ -d "$dst/$d" ] ||`, which a successful seed makes true — so on
# the warm path it never runs and the mode stays the master's world-traversable
# one. An invariant that holds only on the cold path is not an invariant, which
# is why the assertions below are about the UNCONDITIONAL forms.
has_usable_private_slot_cache() { # <file>
  local code
  code=$(code_of "$1")
  # THE isolation control, and the one the earlier revisions got wrong twice: a
  # mode on a directory the slot does not own and cannot chmod. `chmod 0700` on
  # $dst/<tool> is not it — the slot owns that one, so `chmod 0777` on its own
  # cache directory reopens the channel for every later job on every other slot.
  matches "$code" 'chmod 0710 "\$dst"'                          || return 1
  ! matches "$code" 'chmod 0755 "\$dst"$'                       || return 1
  # The seal keeps the owner bit, because the copy inherits it.
  ! matches "$code" 'chmod -R a-w'                              || return 1
  # The staging tree is chmod'd while root still owns it. After the chown it is a
  # root-privileged chmod inside a directory an untrusted uid can write, and
  # `chmod` without -R dereferences.
  # …and published at its final mode rather than widened and narrowed after the
  # rename, which would leave a window in which another slot can keep a dirfd.
  #
  # This one is about ORDER, so it compares line numbers instead of matching
  # text: both chmods have to come before the chown. A herestring rather than a
  # pipe, because this file runs under pipefail and awk's early `exit` would
  # SIGPIPE the producer.
  local n_find n_pub n_chown
  n_find=$(awk '/-type d -exec chmod u[+]rwx/{print NR; exit}'          <<<"$code")
  n_pub=$(awk '/chmod 0700 "\$dst\/\.seed-\$d"/{print NR; exit}'        <<<"$code")
  n_chown=$(awk '/chown -R "\$u:\$u" "\$dst\/\.seed-\$d"/{print NR; exit}' <<<"$code")
  [ -n "$n_find" ] && [ -n "$n_pub" ] && [ -n "$n_chown" ]      || return 1
  [ "$n_find" -lt "$n_chown" ] && [ "$n_pub" -lt "$n_chown" ]   || return 1
  # …and the copy has its directory write bit restored anyway, so a master
  # sealed by an older image still yields a usable cache. On the staging name,
  # before the rename: that name has never been visible to the slot.
  matches "$code" 'find "\$dst/\.seed-\$d" -type d -exec chmod u\+rwx' || return 1
  # Anchored at the start of the line ON PURPOSE. A `[ -d … ] ||` or any other
  # guard in front of it puts the 0700 back on a branch the warm path skips,
  # and this is the check that says the confidentiality bound is unconditional.
  matches "$code" '^[[:space:]]*chmod 0700 "\$dst/\$d"'         || return 1
}

# THE escalation, and the reason it is stated as a namespace rule and not as a
# flag: `chown -R` has never dereferenced (coreutils gives -R FTS_PHYSICAL), so
# -h on it proves nothing. The call that dereferences is the plain non-recursive
# `chown u:g path`, and no flag saves it if a slot can swap `path` for a symlink
# between the test and the call. So: root's work area must be root-owned, and no
# non-recursive chown may be aimed at a path under it.
has_root_owned_namespace() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'chown root:"\$u" "\$dst"'                    || return 1
  matches "$code" 'chown root:root "\$CACHE_SLOTS"'             || return 1
  # The bug this replaced, in both the shapes it had. Note the missing closing
  # quote: `chown "$u:$u" "$dst"` and `chown "$u:$u" "$dst/$d"` are the same
  # defect — a non-recursive, dereferencing chown aimed at a name the slot can
  # substitute — so the ban has to cover the whole subtree, not one path.
  ! matches "$code" 'chown "\$u:\$u" "\$dst'                    || return 1
  ! matches "$code" 'chmod 0700 "\$dst"$'                       || return 1
}

# Refuse the master outright if it holds anything the seal (`chmod -R go+rX`
# WIDENS permissions) or the copy (`cp -a` preserves xattrs and modes) would
# propagate to every slot.
has_hostile_entry_refusal() { # <file>
  local code
  code=$(code_of "$1")
  # shellcheck disable=SC1003  # the trailing `\\` is an ERE for the literal
  # line-continuation backslash the scan is wrapped with, not a quote escape.
  matches "$code" 'find "\$root" \\'                                || return 1
  matches "$code" '\-type l -o -type b -o -type c -o -type p -o -type s' || return 1
  matches "$code" '\-o -perm /6000 \\\)'                            || return 1
  matches "$code" 'getcap -r "\$root"'                              || return 1
  # HARDLINKS ARE COUNTED, NOT FORBIDDEN. `-links +1` alone cannot tell an
  # internal store (pnpm hardlinks its content-addressed files; `cp -al` does
  # too) from a link reaching outside the tree, and only the second widens
  # anything under `chmod -R go+rX`. Comparing in-tree name count with link
  # count answers the actual question, so the blunt predicate must be GONE —
  # leaving it in place alongside would restore the over-block on its own.
  ! matches "$code" '\-type f -a -links \+1'                        || return 1
  matches "$code" 'find "\$root" -type f -links \+1 -printf' || return 1
  matches "$code" 'c\[\$2\]\+\+ } END { for \(i in c\) if \(c\[i\] < n\[i\]\)' || return 1
  # The counting pass prints integers only. A path may contain a newline, which
  # would split one record into two and corrupt every count that follows it.
  ! matches "$code" "links \+1 -printf '%n %i %p" || return 1
  # A credential in a content-addressed cache is not cache content.
  matches "$code" "name '\.npmrc'"                                  || return 1
  # ...but the pass is bounded to the top of the tree, and the bound is what
  # makes the name list safe to widen. Unbounded it reads inside extracted
  # package payloads, where a `.npmrc` or a `.pem` is a dependency's own test
  # fixture — one such package would take every host on every pool cold.
  matches "$code" '\-maxdepth 3 -type f'                            || return 1
  matches "$code" "name '\*\.pem'"                                  || return 1
  matches "$code" "name 'id_rsa'"                                   || return 1
  matches "$code" "name '\.pgpass'"                                 || return 1
  # NOT -xdev on the scan. chmod has no --one-file-system, so the walk descends
  # into a bind mount whatever the scan does; a scan that skipped one would hide
  # exactly the entries the walk then re-owns and widens.
  ! matches "$code" 'find "\$root" -xdev'                           || return 1
  # The scan takes the tree as an argument and defaults to the master. This is
  # what lets ONE scanner cover both the master and a freshly unpacked snapshot;
  # a scanner hard-wired to the master would leave the snapshot — the only route
  # into this tree that no reviewed build step stands in front of — unscanned.
  matches "$code" 'local bad ino root="\$\{1:-\$CACHE_MASTER\}"'    || return 1
}

# THE SCANNED TREE IS UNTRUSTED, SO ITS FILENAMES ARE UNTRUSTED TEXT.
#
# Every refusal names the entry that tripped it — that is deliberate, and a
# refusal that named only the tree root once cost a pool hours of running cold.
# But a filename may contain a newline, and interpolated raw it turns one
# refusal into two log lines, the second of which can be shaped to read like a
# success verdict from this same script. It cannot change what the host DOES;
# it corrupts the record an operator reads when deciding why a pool went cold.
has_sanitized_refusal_logging() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'safe_for_log\(\) \{'                             || return 1
  # Control characters removed, not merely escaped, and the result bounded —
  # `-quit` yields one entry, but one entry's path can be as long as the tree.
  matches "$code" "tr '\\\\n\\\\t' '  '"                            || return 1
  matches "$code" "tr -d '\\\\000-\\\\037'"                         || return 1
  matches "$code" "printf '%\.300s'"                                || return 1
  # Every site that interpolates scan output goes through it. Asserting the
  # helper exists proves nothing if a refusal still reaches the log raw, and
  # these four are all of them.
  matches "$code" 'link, node or setuid entry \(\$\(safe_for_log "\$bad"\)\)'  || return 1
  matches "$code" 'hardlink to a file outside the tree \(\$\(safe_for_log "\$bad"\)\)' || return 1
  matches "$code" 'a file capability \(\$\(safe_for_log "\$bad"\)\)'           || return 1
  matches "$code" 'looks like a credential file \(\$\(safe_for_log "\$bad"\)\)' || return 1
  ! matches "$code" 'entry \(\$bad\)'                               || return 1
  ! matches "$code" 'credential file \(\$bad\)'                     || return 1
}

# A tool must never see a half-copied cache directory at the path it reads.
has_atomic_seed() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'cp -a --no-preserve=ownership "\$src" "\$dst/\.seed-\$d"' || return 1
  matches "$code" 'mv -T "\$dst/\.seed-\$d" "\$dst/\$d"'                     || return 1
}

# Documented as unsafe for concurrent writers by their own maintainers, and
# excluded even though each slot now has its own copy: GOCACHE is unsafe between
# the parallel builds INSIDE one job too, and the setup-* actions prune the tool
# cache as though they own it.
has_no_unsafe_sharing() { # <file>
  local code
  code=$(code_of "$1")
  ! matches "$code" 'GOCACHE'              || return 1
  ! matches "$code" 'RUNNER_TOOL_CACHE'    || return 1
  ! matches "$code" 'AGENT_TOOLSDIRECTORY' || return 1
  ! matches "$code" 'GRADLE_RO_DEP_CACHE'  || return 1
  # -modcacherw makes Go's extracted modules writable. go.sum authenticates the
  # module ZIP at download; the build compiles from the extracted tree and never
  # re-hashes it, which is why `go mod verify` is a separate command. Read-only
  # is that tree's only protection, and a per-slot cache does not need it lifted.
  ! matches "$code" 'modcacherw'           || return 1
}

# The cache is the only layer in this script allowed to fail open. A host with no
# cache is slow; a host that will not register is absent, and the pool answers an
# absent host by queueing jobs.
has_fail_open() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'provision_shared_cache \|\| true'   || return 1
  ! matches "$code" 'provision_shared_cache.*\|\| die' || return 1
  # The gate is the completion MARKER, not the directory. seed_slot_cache creates
  # the directory on its first line and the marker on its last, so gating on the
  # directory would emit all ten variables for a run that failed half way —
  # pointing tools at paths that may not exist or may not be writable, which is a
  # hard per-job failure rather than the cache miss this layer promises. The
  # marker lives in the root-owned work area, so a slot cannot forge it.
  matches "$code" '\[ -f "\$c/\.ready" \] \|\| return 0' || return 1
  matches "$code" 'rm -f "\$dst/\.ready"'                || return 1
  matches "$code" ': >"\$dst/\.ready"'                   || return 1
}

# The other half of the marker contract, and the reason this predicate sits next
# to has_fail_open: `.ready` under a RETIRED slot index is a marker nothing
# rewrites. Reduce slots_per_host and `/var/lib/ci-cache/<idx>` above the new
# count keeps its whole tree and its marker; raise the count again and the
# seeding loop meets a directory that already claims to be complete. The sweep
# runs BEFORE the seeding loop, or it deletes what it has just seeded.
has_retired_slot_prune() { # <file>
  local code
  code=$(code_of "$1")
  # Bounded by what is on disk — the previous slot count is recorded nowhere on
  # this host, so a `seq` over a guessed range cannot be right.
  matches "$code" '^  for d in "\$CACHE_SLOTS"/\*; do'  || return 1
  # Digits only, and only above the live count. Everything else in $CACHE_SLOTS
  # was not put there by this function and is not this function's to remove —
  # this is an `rm -rf` in a directory root also writes its own state into.
  matches "$code" 'case "\$idx" in .*\[!0-9\]\*\) continue ;; esac' || return 1
  matches "$code" '\[ "\$idx" -gt "\$SLOTS" \] \|\| continue' || return 1
  # if/else, not `rm && log || log`: the second form runs the failure branch
  # when the LOG fails, and the log is the only record this sweep leaves.
  matches "$code" '^    if rm -rf "\$d"; then'                || return 1
  matches "$code" 'log "slot \$idx: retired \(this host now has \$SLOTS\)' || return 1
  matches "$code" 'log "slot \$idx: retired, but its cache copy could not be removed"' || return 1
  # …and it fails open like everything else here: a slot that cannot be removed
  # is logged, never fatal.
  ! matches "$code" 'rm -rf "\$d".*\|\| die'                 || return 1
  local prune_at seed_at
  prune_at=$(printf '%s\n' "$code" | grep -nE '^  for d in "\$CACHE_SLOTS"/\*; do' | head -n1 | cut -d: -f1)
  # The seeding CALL, not the `for i in $(seq 1 "$SLOTS")` header — that header
  # appears four times in this script and the first one is a thousand lines
  # above the cache layer, so an ordering check anchored on it compares the
  # sweep against an unrelated loop and fails whatever the sweep does.
  seed_at=$(printf '%s\n' "$code" | grep -nE '^    seed_slot_cache "\$i" \|\| log' | head -n1 | cut -d: -f1)
  [ -n "$prune_at" ] && [ -n "$seed_at" ] && [ "$prune_at" -lt "$seed_at" ] || return 1
}

# Every "group" permission in this script means "nobody but this slot" only
# while each slot's primary group is its own single-member group. Asserted in
# the script, not assumed in a comment.
has_primary_group_assert() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" '\[ "\$\(id -gn "\$u"\)" = "\$u" \]' || return 1
}

# The image build's own gate on the master, which is a different file and a
# different failure mode: it must ABORT the build, and the obvious way to write
# it does not.
#
# `! find ... | grep -q .` reads as a guard and cannot fail one. POSIX and bash
# both define `set -e` to ignore the status of a command whose value is inverted
# with `!`, and without `pipefail` a find that errors also passes — so the image
# ships with whatever the scan was supposed to catch. This is asserted here
# rather than in the Packer file because nothing else in CI runs a build.
has_packer_gate_that_aborts() { # <file>
  local code
  code=$(code_of "$1")
  [ -f "$1" ] || return 1
  matches "$code" 'set -euxo pipefail'          || return 1
  matches "$code" 'exit 1'                      || return 1
  # The shape that cannot fail, in either spelling.
  ! matches "$code" '"! find /opt/ci-cache'     || return 1
  ! matches "$code" 'find /opt/ci-cache.*grep -q' || return 1
  # The image must not ship the tree writable by a group of slot users.
  ! matches "$code" 'chgrp -R ci /opt/ci-cache' || return 1
  ! matches "$code" 'chmod 2775 /opt/ci-cache'  || return 1
  matches "$code" 'chown -Rh root:root /opt/ci-cache' || return 1
  # …nor a tree no slot can write into. The host copies it per slot with `cp -a`,
  # which preserves mode, so `a-w` here bakes 0555 directories into every slot's
  # private cache. The owner bit protects nothing on a root-owned tree anyway.
  ! matches "$code" 'chmod -R a-w'                    || return 1
  matches "$code" 'chmod -R go-w,go\+rX /opt/ci-cache' || return 1
  # Third copy of the same scan, and it must say which predicate fired too. The
  # image gate is the one place that can still refuse a hostile tree BEFORE any
  # host boots from it, so its refusal is read by whoever is unblocking a build.
  matches "$code" "\-printf '%y %M %p" || return 1
  # THE TWO COPIES MUST NOT DRIFT. This gate and host-startup.sh scan the same
  # tree for the same reasons, and a fix applied to one of them is a fix the
  # fleet only half has — the image would keep failing builds over a pnpm store
  # that every booted host now accepts, or worse, accept one every host refuses.
  ! matches "$code" '\-type f -a -links \+1'                                || return 1
  matches "$code" 'c\[\$2\]\+\+ } END { for \(i in c\) if \(c\[i\] < n\[i\]\)' || return 1
  # CACHE_PREPARE is consumer-supplied, so an entry's name is untrusted text
  # here exactly as it is at boot.
  matches "$code" 'clean\(\) \{'                                            || return 1
  matches "$code" 'clean \\"\$bad\\"'                                       || return 1
}

# --- the snapshot hydrate -------------------------------------------------------

# A host READS the snapshot bucket and never writes it, and reads only its own
# pool's prefix. This is the whole security argument for the snapshot layer, and
# it lives in an IAM grant nobody looks at again after it is written — so it is
# asserted here instead.
has_read_only_cache_grant() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'role[[:space:]]+= "roles/storage\.objectViewer"' || return 1
  # objectUser and objectAdmin both carry storage.objects.create and .delete. A
  # host that can create an object in this bucket can publish what the next host
  # boots from, which is one job handing code to every future job in the pool.
  ! matches "$code" 'roles/storage\.objectUser'    || return 1
  ! matches "$code" 'roles/storage\.objectAdmin'   || return 1
  ! matches "$code" 'roles/storage\.objectCreator' || return 1
  ! matches "$code" 'roles/storage\.admin'         || return 1
  # Conditioned on the prefix, or eight pools in one bucket are one pool.
  matches "$code" 'expression[[:space:]]+= "resource\.name\.startsWith' || return 1
  matches "$code" '\$\{local\.cache_prefix\}'                          || return 1
  # ONE expression for the prefix, shared by the condition and the host. Written
  # twice they drift, and the drift is silent: every read lands outside the grant
  # and 403s, which the host logs as "no snapshot published yet".
  matches "$code" '^  cache_prefix = "cache/\$\{var\.name\}/"' || return 1
  matches "$code" '"ci-cache-prefix"' || return 1
}

# The hydrate is bounded and every step inside it returns rather than aborting
# the boot. A host that waits on a snapshot is a host the pool does not have, and
# the pool answers a missing host by queueing jobs.
has_bounded_hydrate() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'deadline=\$\(\(started \+ budget\)\)'      || return 1
  # Every network call carries the remaining budget, and a call handed a budget
  # already spent does not run at all.
  matches "$code" 'curl --connect-timeout 5 --max-time "\$3"' || return 1
  matches "$code" '\[ "\$3" -gt 0 \] \|\| return 1'           || return 1
  # tar is where a large archive spends its time, so it is bounded too — with the
  # clamp, because `timeout -3` is a parse error rather than a timeout.
  matches "$code" 'timeout "\$left"'                          || return 1
  matches "$code" '\[ "\$left" -gt 0 \] \|\| left=1'          || return 1
  # Fails open at the call site and inside: no `die`, and no `return 1` path that
  # the caller could mistake for a reason to stop.
  matches "$code" 'hydrate_shared_cache \|\| true'            || return 1
  ! matches "$code" 'hydrate_shared_cache.*\|\| die'          || return 1
}

# A layer that fails open is a layer that reports nothing when it fails, unless
# something makes it report. That is the whole content of this check: an expired
# snapshot, a bucket that was never configured and a fleet-wide download timeout
# produce the same observable — jobs slower than they were — so the verdict is
# the only thing that separates them, and a verdict is only useful if EVERY exit
# has one.
has_observable_hydrate() { # <file>
  local code
  code=$(code_of "$1")

  # Structural, not a count: every `return` inside the bounded body must be
  # preceded by its own CACHE_VERDICT assignment, which is a property a new exit
  # added next year either has or does not. A count would pass on an edit that
  # added an exit and reused the verdict above it — the exact edit that produces
  # a host reporting `too-old` for a failure that had nothing to do with age.
  local unlabelled
  unlabelled=$(awk '
    /^hydrate_shared_cache_bounded\(\) \{/ { inbody = 1 }
    inbody && /^\}$/                       { inbody = 0 }
    !inbody                                { next }
    /CACHE_VERDICT=/                       { pending = 1 }
    /(^|[;[:space:]])return([[:space:]]|$)/ {
      if (!pending) { print NR }
      pending = 0
    }
  ' <<<"$code" | grep -c . )
  [ "${unlabelled:-1}" = "0" ] || return 1

  # And the publish is in the wrapper, on every path out, rather than at the
  # return that decided the verdict — the same argument the `unset` already makes
  # in this file: a rule repeated at every return is a rule missed at the next.
  matches "$code" 'hydrate_shared_cache_bounded \|\| rc=\$\?' || return 1
  matches "$code" '^  publish_cache_telemetry$'               || return 1
  # "The attribute is not set" and "the metadata server did not answer" are
  # opposite facts and `md` returns an empty string for both, so the exit code
  # is what separates them: curl -f gives 22 for a 404, and 6/7/28 for DNS,
  # refused and timed out. This is an OBSERVABILITY invariant, which is why it
  # is asserted here: `not-configured` is the verdict that means "nothing to
  # do", so a broken metadata server reported under it is a fleet-wide outage
  # that no alert can see. Reading the code also costs nothing, where the second
  # probe it replaced cost up to 30 seconds of boot before `deadline` existed.
  matches "$code" 'CACHE_BUCKET=\$\(md "instance/attributes/ci-cache-bucket"\) \|\| bucket_rc=\$\?' || return 1
  matches "$code" '^    if \[ "\$bucket_rc" = 22 \] \|\| \[ "\$bucket_rc" = 0 \]; then' || return 1
  # No second metadata call may decide it, and rc 0 with an empty value is a
  # pool that did not configure this layer, not an unreachable server.
  ! matches "$code" 'md "instance/id"'                        || return 1
  # Nothing may return between the two.
  local between
  between=$(awk '/hydrate_shared_cache_bounded \|\| rc=\$\?/ { seen = 1; next }
                 seen && /publish_cache_telemetry/           { exit }
                 seen && /return/                            { print }' <<<"$code" | grep -c .)
  [ "${between:-1}" = "0" ] || return 1
  # The verdict is cleared with the rest of the per-boot state, or a host that
  # re-runs the hydrate reports the previous run's answer.
  matches "$code" 'unset .*CACHE_VERDICT'                     || return 1

  # Age and size are recorded BEFORE the bounds that reject on them. Recorded
  # after, the only snapshots that ever publish an age are the ones young enough
  # to be accepted, and "the snapshot is too old" becomes unalertable.
  local order
  order=$(awk '/CACHE_SNAP_AGE_HOURS=/ { print "age"; exit }
               /CACHE_VERDICT="too-old"/ { print "bound"; exit }' <<<"$code")
  [ "$order" = "age" ] || return 1

  # Label goes through the allowlist, not into the JSON raw.
  matches "$code" 'ts_label_value "\$\{CACHE_VERDICT:-unset\}"' || return 1
  # And a telemetry failure changes nothing about the hydrate. The layer already
  # fails open; an observability call that could fail a boot would make watching
  # the cache riskier than not having it.
  matches "$code" 'flush_series \|\| log'                       || return 1
  ! matches "$code" 'publish_cache_telemetry \|\| die'          || return 1
}

# The same rule as has_token_out_of_argv, applied to the file that now runs
# beside the hydrate. This predicate is the whole reason the publisher was worth
# a second look: on the controller VM there are no untrusted users and argv is
# nobody's channel, so the pattern was fine there for as long as it lived there.
#
# Stated as properties of the POST call read as a unit, not as a list of exact
# strings that happen to be in the file. The strings were the defect: `! matches
# '-H "Authorization: Bearer $token'` bans one spelling, so `-H "authorization:
# bearer $token"`, `--header "Authorization: Bearer $token"` and a `$tok` renamed
# a line earlier all read as clean, and the required `-K <(printf` could sit in a
# different function entirely while the call beside it still carried the header.
# So: extract the call, and assert on THAT.
has_publisher_token_out_of_argv() { # <telemetry.sh>
  local code call
  code=$(code_of "$1")
  # The call, from `http=$(curl` to the line that closes it. Same awk-range
  # technique has_host_telemetry_wiring uses on the join block.
  call=$(awk '/http=\$\(curl/ { in_call = 1 }
              in_call             { print }
              in_call && /-d "\$body"\)/ { exit }' <<<"$code")
  [ -n "$call" ] || return 1
  # The token reaches curl through a config file on a pipe, which never becomes
  # a process argument…
  matches "$call" '\-K <\(printf .header = "Authorization: Bearer %s' || return 1
  # …and no header option anywhere in this file carries a bearer token, in any
  # spelling curl accepts and whatever the variable holding it is called.
  ! matches "$code" '(-H|--header)[[:space:]]+"[Aa]uthorization: *[Bb]earer' || return 1
  # The response body goes to a private file. Anything else — a fixed name, a
  # path built from a variable this predicate cannot follow — is a root `curl -o`
  # aimed at a name a job user may have pre-planted a symlink at.
  matches "$call" '\-o "\$out"'                               || return 1
  matches "$code" 'out=\$\(mktemp\)'                          || return 1
  # And it is removed on BOTH exits. The failure path is the one that gets
  # forgotten, and it is also the only one that reads the file back into a log.
  local removals
  removals=$(printf '%s\n' "$code" | grep -cE '^[[:space:]]*\[ "\$out" = /dev/null \] \|\| rm -f "\$out"')
  [ "${removals:-0}" -ge 2 ]                                  || return 1
}

# The publisher only exists on the host because it was concatenated there. This
# is the line that puts it in front of the host's script the way it is already in
# front of the controller's.
has_host_telemetry_wiring() { # <main.tf>
  local code
  code=$(code_of "$1")
  matches "$code" 'host_startup = join' || return 1
  local block
  block=$(awk '/host_startup = join/, /\]\)/' <<<"$code")
  matches "$block" 'scripts/telemetry\.sh'     || return 1
  matches "$block" 'scripts/host-startup\.sh'  || return 1
  # Order matters: the host script calls queue_series at the top level of a
  # function defined below it, so telemetry.sh must be the earlier member.
  local first
  first=$(awk '/telemetry\.sh/ { print "telemetry"; exit }
               /host-startup\.sh/ { print "host"; exit }' <<<"$block")
  [ "$first" = "telemetry" ] || return 1
}

# Everything a snapshot brings is inspected before a byte of it reaches the
# master, and it is inspected by the SAME scan the image build runs. A snapshot
# is the one route into this tree with no reviewed build step in front of it.
has_snapshot_inspection() { # <file>
  local code
  code=$(code_of "$1")
  # Staged outside the master. Inside it, a rejected snapshot would already have
  # made the master hostile by the time the scan said so.
  matches "$code" '^CACHE_STAGE="/opt/\.ci-cache-incoming"'      || return 1
  matches "$code" 'tar -x -C "\$CACHE_STAGE"'                    || return 1
  matches "$code" '\-\-no-same-owner --no-same-permissions --no-xattrs --no-acls' || return 1
  # And nothing that turns off the tar defaults the staging tree relies on.
  ! matches "$code" 'tar .*(--absolute-names|--keep-directory-symlink| -P )' || return 1
  # The inspection is inside the deadline too: three tree walks over a snapshot of
  # many millions of tiny files is the delay the budget exists to prevent, reached
  # by going around it.
  matches "$code" 'CACHE_DEADLINE=\$deadline'                    || return 1
  matches "$code" 'cache_scan "\$limit" find "\$root"'           || return 1
  # The refusal has to name the PREDICATE, not just the path. Six of them share
  # one message, and the first time it fired in production it named the tree root
  # twice and the cause not at all — a setgid directory the image had shipped,
  # which read like a content problem and cost hours. `%y %M` is the whole fix.
  matches "$code" "\-printf '%y %M %p" || return 1
  matches "$code" 'cache_scan "\$limit" getcap -r "\$root"'      || return 1
  # `strict`, because for a snapshot the scan is the only opinion there is: an
  # unscannable tree has to be a refused tree, not a logged one.
  matches "$code" 'cache_master_is_hostile "\$CACHE_STAGE" strict' || return 1
  matches "$code" 'elif \[ "\$\{2:-\}" = "strict" \]'            || return 1
  # max_bytes bounds the COMPRESSED archive and gzip expands by more than a
  # thousandfold on the right input, so the decompressed stream is bounded too.
  matches "$code" 'head -c "\$bound"'                            || return 1
  # ...and the bound has a FLOOR, because tar writes nothing shorter than 20
  # 512-byte records however little it holds. Scaled all the way down, 8x lands
  # below that and `head` cuts a valid archive in half. The floor is asserted as a
  # number: an arithmetic tidy-up that removes it brings the same defect back
  # looking like a simplification.
  matches "$code" '^CACHE_EXPAND_FLOOR_BYTES=65536$'             || return 1
  matches "$code" '\[ "\$bound" -ge "\$CACHE_EXPAND_FLOOR_BYTES" \] \|\| bound=\$CACHE_EXPAND_FLOOR_BYTES' || return 1
  # And the bound is decided by COUNTING, before the unpack. `head` closing the
  # pipe is not a refusal: tar exits 0 on a stream cut at a member boundary, so a
  # bound enforced only by tar's status leaves this host with part of a snapshot
  # it believes is whole — and the scan then passes on a subset of what arrived.
  matches "$code" 'expanded=\$\( \{ timeout "\$left" gzip -dc "\$tmp/snap.tar.gz" 2>/dev/null; echo "\$\?" >"\$tmp/count.rc"; \} [\]' || return 1
  # ...and the counting pass's OWN status is kept, in a file, because `|| true`
  # used to eat it. `timeout` leaves 124 when the hydrate deadline expires
  # mid-decompression, and a 124 read as success turns an UNMEASURED archive
  # into a count comfortably within bounds — after which the extraction gets a
  # fresh one-second floor and tar accepts a prefix ending at a member boundary.
  matches "$code" '^  count_rc=\$\(tr -dc 0-9 <"\$tmp/count.rc" 2>/dev/null\)' || return 1
  matches "$code" '^  if \[ "\$\{count_rc:-\}" != 0 \]; then$' || return 1
  matches "$code" '^      124 \| 137 \)$' || return 1
  ! matches "$code" 'gzip -dc "\$tmp/snap.tar.gz" 2>/dev/null \|\| true' || return 1
  matches "$code" '\| head -c "\$\(\(bound \+ 1\)\)" \| wc -c \) \|\| expanded=\$\(\(bound \+ 1\)\)' || return 1
  matches "$code" '^  if \[ "\$expanded" -gt "\$bound" \]; then$' || return 1
  matches "$code" 'CACHE_VERDICT="too-big-expanded"'             || return 1
  # The count runs BEFORE the unpack, or it is not a bound at all — it is a
  # postmortem on a tree already written.
  local count_at unpack_at
  count_at=$(printf '%s\n' "$code" | grep -nE '^  if \[ "\$expanded" -gt "\$bound" \]' | head -n1 | cut -d: -f1)
  unpack_at=$(printf '%s\n' "$code" | grep -nE '\| head -c "\$bound" [\]' | head -n1 | cut -d: -f1)
  [ -n "$count_at" ] && [ -n "$unpack_at" ] && [ "$count_at" -lt "$unpack_at" ] || return 1
  # The free-space check reserves EXACTLY what the unpack may write. Reserving
  # the unfloored product while unpacking to the floored bound is how a host
  # fills its own boot disk warming a cache.
  matches "$code" '^  bound=\$\(cache_expand_bound "\$size"\)$'  || return 1
  matches "$code" '\[ "\$\(\(free_kb \* 1024\)\)" -lt "\$bound" \]' || return 1
  # Nothing computes the bound by hand any more. One arithmetic site, or the two
  # copies of it drift and the host refuses what the publisher accepted.
  ! matches "$code" 'head -c "\$\(\(size \* 8\)\)"'              || return 1
  # A whitelist on the way in: only the tool directories this host already knows
  # about move, so a snapshot cannot introduce a new top-level name.
  matches "$code" 'for d in "\$\{CACHE_DIRS\[@\]\}"; do'         || return 1
  matches "$code" 'mv -T "\$CACHE_STAGE/\$d" "\$CACHE_MASTER/\$d"' || return 1
  # And a whitelist on the pointer, the one input here that names a path.
  matches "$code" '\*\[!A-Za-z0-9\._-\]\* \| .. \| \.\* \)'      || return 1
  # The hydrate runs BEFORE the master is scanned and locked, or unscanned
  # content lands in a tree already declared safe and is seeded to every slot.
  matches "$code" 'hydrate_shared_cache \|\| true'               || return 1
  # Which of the two comes FIRST, not merely that both are present. A here-string
  # rather than a pipe: awk exits at the first match, and under `pipefail` a
  # writer that takes SIGPIPE would turn a correct answer into a failure.
  local first
  first=$(awk '/^  (hydrate|provision)_shared_cache \|\| true$/ {print $1; exit}' <<<"$code")
  [ "$first" = "hydrate_shared_cache" ] || return 1
}

# The age bound is read from the service, not from the object's name. A snapshot
# whose name carries a timestamp is a snapshot whose age is asserted by whoever
# wrote it; `timeCreated` is the service's own record of that generation.
has_service_attested_age() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" '\?fields=timeCreated,size,generation'      || return 1
  matches "$code" '"timeCreated"'                             || return 1
  # And what was measured is what is downloaded. Without the generation pinned,
  # age, size and free space are all asserted against a generation that need not
  # be the one that arrives.
  matches "$code" '\?alt=media&generation=\$gen'              || return 1
  matches "$code" 'age=\$\(\( \(started - created\) / 3600 \)\)' || return 1
  matches "$code" '\[ "\$age" -ge "\$max_age_hours" \]'       || return 1
  # A size bound and a free-space bound, because filling the boot disk to warm a
  # cache costs this host every job it was about to run.
  matches "$code" '\[ "\$size" -gt "\$max_bytes" \]'          || return 1
  matches "$code" 'df -Pk /opt'                               || return 1
}

# The instance token never becomes a process argument. /proc/<pid>/cmdline is
# world-readable, the slot agents are not ordered against the startup script, and
# that token is the HOST identity — it impersonates the job account and reads the
# GitHub App key. The per-uid REJECT to the metadata server is the rule this would
# route around.
has_token_out_of_argv() { # <file>
  local code
  code=$(code_of "$1")
  # Scoped to the cache token. The registration call and the App JWT above it put
  # their own secrets in argv on the same channel; those predate this layer and
  # are tracked separately, and widening this check to them would fail today for a
  # reason that has nothing to do with the snapshot.
  ! matches "$code" '\-H "Authorization: Bearer \$CACHE_TOKEN' || return 1
  matches "$code" '\-K <\(printf .header = "Authorization: Bearer' || return 1
  # Cleared on every path out of the hydrate, which is why the hydrate is a
  # wrapper around the body rather than one function with a dozen early returns.
  matches "$code" 'unset CACHE_TOKEN'                          || return 1
  # A response is bounded before it lands on disk, not only by the deadline.
  matches "$code" '\-\-max-filesize "\$\{5:-65536\}"'          || return 1
  matches "$code" 'cache_fetch "\$snap" "\$tmp/snap\.tar\.gz"' || return 1
}

# The bounds a host applies are the bounds Terraform validated, applied again on
# the host: metadata is not written only by Terraform, and a shape check accepts
# any number at all.
has_clamped_metadata_bounds() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" '\[ "\$budget" -le 300 \] \|\| budget=300'   || return 1
  matches "$code" '\[ "\$max_age_hours" -le 720 \]'            || return 1
  matches "$code" '\[ "\$max_bytes" -ge 1048576 \]'            || return 1
}

# The pool name is the string the cache prefix is built from, and that prefix is
# interpolated into a CEL literal on the read grant. A quote in it rewrites the
# condition.
has_constrained_pool_name() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'regex\("\^\[a-z\]\(\[-a-z0-9\]\{0,61\}\[a-z0-9\]\)\?\$", var\.name\)' || return 1
  # Both halves of the same door: the bucket name is interpolated into that same
  # CEL literal, and validating one and not the other closes neither.
  matches "$code" 'regex\(.*, var\.cache_snapshot_bucket\)'   || return 1
}

# The write side. A host may not publish; this is the identity that may, and
# every assertion here is about it staying unable to do the two things that would
# undo the layer: overwrite a snapshot, or be assumed by a pull-request run.
has_write_once_publisher() { # <file>
  local code
  code=$(code_of "$1")
  # Create WITHOUT delete under the prefix. Overwriting a live object in Cloud
  # Storage needs storage.objects.delete, so objectCreator is what turns "written
  # once" from a convention the publisher is trusted with into a 403. objectUser
  # and a prefix-scoped objectAdmin both carry delete and would hand it back.
  matches "$code" 'role[[:space:]]+= "roles/storage\.objectCreator"' || return 1
  ! matches "$code" 'roles/storage\.objectUser' || return 1
  ! matches "$code" 'roles/storage\.admin'      || return 1
  # objectAdmin exists exactly once, on the pointer, and its condition names ONE
  # object with `==`. A startsWith there would give delete over every snapshot.
  [ "$(printf '%s\n' "$code" | grep -cE 'roles/storage\.objectAdmin')" -eq 1 ] || return 1
  matches "$code" 'expression  = "resource\.name == \\"\$\{local\.pointer_resource\}\\""' || return 1
  matches "$code" '^  pointer_resource = .*\$\{local\.cache_prefix\}current"$'            || return 1
  # Both prefix grants conditioned, and on the prefix the pool derives from the
  # same expression. An unconditioned write grant is every pool's cache.
  [ "$(printf '%s\n' "$code" | grep -cE 'expression  = "resource\.name\.startsWith')" -eq 2 ] || return 1
  matches "$code" '^  cache_prefix = "cache/\$\{var\.name\}/"' || return 1
  # Assumable by ONE workflow file, in ONE repository, on ONE ref — all three in
  # a single claim. Neither weaker axis alone is enough: attribute.repository
  # admits every branch and every workflow file in it, and attribute.ref admits
  # every OTHER repository federated by the same pool (one issuer serves all of
  # github.com) as well as the pull_request_target and workflow_run events, whose
  # tokens assert the DEFAULT BRANCH while running fork-authored code.
  matches "$code" 'principalSet://iam\.googleapis\.com/\$\{var\.workload_identity_pool\}/attribute\.job_workflow_ref/\$\{var\.repository\}/\$\{var\.publish_workflow_path\}@\$\{var\.allowed_ref\}' || return 1
  ! matches "$code" 'attribute\.repository/'   || return 1
  ! matches "$code" 'attribute\.ref/'          || return 1
  # No key material. A downloadable key is a credential that outlives the run and
  # cannot be bound to a ref at all.
  ! matches "$code" 'google_service_account_key' || return 1
}

# The ref is the boundary, so the variable that names it is validated rather than
# documented. A tag is movable by anyone who can push one; a pull-request ref is
# unreviewed code by definition.
has_ref_bound_publisher() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'regex\("\^refs/heads/' || return 1
  matches "$code" 'default     = "refs/heads/main"' || return 1
  # The two parts that make the ref mean anything. `repository` has no default,
  # because a module that guessed it would bind to somebody else's repository;
  # and both are interpolated into a principalSet whose parts are separated by
  # `/` and `@`, so neither may carry a separator.
  matches "$code" 'variable "repository"' || return 1
  matches "$code" 'regex\(.*, var\.repository\)' || return 1
  matches "$code" 'default     = "\.github/workflows/' || return 1
  matches "$code" 'regex\("\^\\\\\.github/workflows/.*, var\.publish_workflow_path\)' || return 1
  # The same two CEL-literal inputs the pool validates, validated here too.
  matches "$code" 'regex\("\^\[a-z\]\(\[-a-z0-9\]\{0,61\}\[a-z0-9\]\)\?\$", var\.name\)' || return 1
  matches "$code" 'regex\(.*, var\.cache_snapshot_bucket\)' || return 1
}

# The bucket module states who may write only by NOT granting it. An
# authoritative empty binding — the shape that would say "and no one else" — is
# not shipped, because setIamPolicy has historically rejected a memberless
# binding and an unverified control is not worth an apply every consumer would
# have to fix. What IS checkable here is that the bucket module grants no write
# at all: a grant appearing in this file is unconditioned by construction, since
# the per-pool grants live in the pool and publisher modules.
has_no_write_grant_on_the_bucket() { # <file>
  local code
  code=$(code_of "$1")
  ! matches "$code" 'roles/storage\.objectAdmin'   || return 1
  ! matches "$code" 'roles/storage\.objectCreator' || return 1
  ! matches "$code" 'roles/storage\.objectUser'    || return 1
  ! matches "$code" 'roles/storage\.admin'         || return 1
  # And the two settings that would route around a prefix condition entirely.
  matches "$code" '^  uniform_bucket_level_access = true$' || return 1
  matches "$code" '^  public_access_prevention = "enforced"$' || return 1
}

# The publishing script is the only writer into the trusted path, so what it
# refuses matters as much as what it does.
#
# It reads TWO files as one body of code: the file under test, and whichever of
# the pair it is not. $PAIR_OTHER is what supplies the second — set by
# `mutate_pubsh` and `mutate_scansh`, so a mutation of either half is judged
# against the whole. Without it every assertion that names a rule now living in
# the other file would fail on every mutation of this one, and the suite would
# report ~90 failures that say nothing about the mutation.
PAIR_OTHER=""
has_trusted_snapshot_build() { # <file>
  local code reporter labeller confirmer line rest form arg label
  code=$(code_of "$1" ${PAIR_OTHER:+"$PAIR_OTHER"})
  # Built into a fresh staging tree, never from a host's cache. /opt/ci-cache is
  # the master's path and must not appear at all: an archive of it would put a
  # previous snapshot's content — or a slot's — back through the front door.
  ! matches "$code" '/opt/ci-cache' || return 1
  matches "$code" 'STAGE=\$\(mktemp -d\)' || return 1
  matches "$code" 'export npm_config_cache="\$STAGE/npm"' || return 1
  # Both pnpm spellings, the same reason the host emits both.
  matches "$code" 'export pnpm_config_store_dir=' || return 1
  matches "$code" 'export npm_config_store_dir='  || return 1
  # The event guard. The IAM binding pins repository, workflow and ref and cannot
  # pin the EVENT — and pull_request_target/workflow_run runs assert the default
  # ref while executing fork code, so without this an edit to the trigger is a
  # poisoned snapshot rather than a failed run.
  matches "$code" 'GITHUB_EVENT_NAME' || return 1
  matches "$code" "'' \| schedule \| workflow_dispatch \| push" || return 1
  # The two names the publish phase is aimed at are validated BEFORE anything is
  # packed, and they are validated the way the modules validate them — first
  # character included. A pool name opening with a digit cannot exist, and the
  # 403 it earns at the upload is the same 403 a missing binding, a wrong pool
  # and an expired federation all give: fails closed either way, and the whole
  # tree is packed first.
  matches "$code" '^    \*\[!a-z0-9-\]\* \| .. \| \*- \) die "CACHE_POOL' || return 1
  matches "$code" '^    \[!a-z\]\* \) die "CACHE_POOL must start with a lowercase letter' || return 1
  matches "$code" '^  \[ "\$\{#CACHE_POOL\}" -le 63 \]' || return 1
  matches "$code" '^    gs://\* \) die "CACHE_BUCKET is a bucket NAME' || return 1
  matches "$code" '^    \*\[!a-z0-9\._-\]\* \| .. \| \.\* \| -\* \| \*\. \| \*- \| \*\.\.\* \) die "CACHE_BUCKET' || return 1
  matches "$code" '^  \[ "\$\{#CACHE_BUCKET\}" -ge 3 \]' || return 1
  matches "$code" '^  \[ "\$\{#CACHE_BUCKET\}" -le 63 \]' || return 1
  # The host's walks, with the host's rules — plus a content pass, because a
  # filename list cannot see a token inside a cache entry whose name is a hash.
  matches "$code" '\-perm /6000' || return 1
  matches "$code" 'getcap -r' || return 1
  matches "$code" "\-name '\.git-credentials'" || return 1
  # Pinned whole and anchored, because every way this rule has gone wrong was a
  # small edit to it: the left class, the right assignment, the boundary itself.
  matches "$code" '^  "registry-auth-token\|\(\^\|\[\^A-Za-z0-9\.\\\$\]\)_authToken\(\[\[:space:\]\\"'"'"'\]\*\[=:\]\|\[\\"'"'"'\]\[\[:space:\]\]\+\[\\"'"'"'\]\)"$' || return 1
  # Every grep running these patterns reads BYTES, so every one pins the byte
  # locale. A bracket expression is character-wise in a UTF-8 locale — which
  # ubuntu-latest sets — so one invalid byte in front of the pattern makes the
  # rule miss entirely. Pinned on each grep rather than exported once, because
  # an export is a line someone moves. Two are asserted here because they decide
  # refusal; the reporter's three are pinned by the closed allow-list below.
  matches "$code" '^    LC_ALL=C grep -qa -E -e "\$\{entry#\*\|\}" "\$file"' || return 1
  # The refusal has to be readable. The pass finds a FILE, and in a dependency
  # cache that file's name is a content hash, so without this the log says only
  # that something matched somewhere — indistinguishable from a false positive.
  matches "$code" 'explain_credential_hit "\$root" "\$bad"' || return 1
  # ...and readable without printing what it caught. What sits before `://` in a
  # cache blob is not reliably a scheme word, so an unfiltered echo of it is the
  # leak this function exists to avoid; only an allow-listed scheme is printed.
  matches "$code" 'not a recognised URL scheme' || return 1
  # Every path in a refusal came from third-party install code, and a filename
  # may hold a newline. Raw, one carrying `\n::add-mask::` writes workflow
  # commands from the job that holds the publishing credential.
  matches "$code" 'safe_path\(\) \{ printf' || return 1
  matches "$code" 'safe_path "\$bad"' || return 1
  # The digest allowlist. It excuses the CONTENT pass and nothing else, and each
  # of these is what keeps it an exception rather than an off switch: a full
  # 64-character sha256 (a prefix would excuse everything sharing it), a hex-only
  # entry, a line in the log every time one is used, and a walk over EVERY hit —
  # stopping at the first would let an excused file stand in front of a real one.
  matches "$code" '\[ "\$\{#d\}" = 64 \]' || return 1
  matches "$code" '\*\[!0-9a-fA-F\]\*' || return 1
  matches "$code" 'die "\$where holds a non-hex entry' || return 1
  # Both sources — the variable and the file — go through ONE validator. Two
  # copies is how the file grows a shorter rule than the variable it replaced,
  # on the path an operator actually uses once the list is long.
  [ "$(printf '%s\n' "$code" | grep -c 'scan_allow_add ')" = 2 ] || return 1
  # The file's own rule: a digest with no comment naming its package is refused.
  # This is the one place the "excused by NAME, never by hash alone" convention
  # can be enforced instead of written down, and 71 unlabelled hashes is exactly
  # the list that gets rubber-stamped.
  matches "$code" 'excuses a digest with no comment naming the package' || return 1
  matches "$code" 'has an empty comment' || return 1
  # The guards themselves, not only the sentences they die with. A `[ ... ]`
  # replaced by `true` leaves the message in place, so a suite that reads only
  # the message reports a script that no longer checks anything as intact.
  matches "$code" '\[ "\$scan_allow_digest" != "\$scan_allow_line" \]' || return 1
  matches "$code" '\[ -n "\$scan_allow_name" \]' || return 1
  matches "$code" '\[ -f "\$CACHE_SCAN_ALLOW_FILE" \]' || return 1
  matches "$code" '\[ "\$scan_allow_count" -gt 0 \]' || return 1
  # Leading whitespace is stripped and the REMAINDER judged. Spelled as a glob
  # — `[ \t]*'#'*` — the bracket matches exactly one character and the star
  # matches anything, so every indented line containing a `#` anywhere is eaten
  # as a comment and its digest never loads. Silently, which is the part that
  # matters: the operator sees the scan refuse a fixture that is in the file.
  matches "$code" 'scan_allow_bare=\$\{scan_allow_line#"\$\{scan_allow_line%%\[!\[:space:\]\]\*\}"\}' || return 1
  ! matches "$code" "\\[\\\$' \\\\t'\\]\\*'#'\\*" || return 1
  # The arms themselves. Stripping the indentation is only half of it; the other
  # half is that what remains is judged as a WHOLE line, so `*"#"*` reintroduces
  # the bug with the strip still in place.
  matches "$code" "^      '' \\| '#'\\* \\) continue ;;\$" || return 1
  # The excusal names its SOURCE, and for the file its line and what that line
  # called the package. The log is the only artifact left once the runner is
  # gone; one that says only "is on CACHE_SCAN_ALLOW_DIGESTS" is an audit trail
  # back to a hash, on the layer that just excused a private-key header.
  matches "$code" 'excused by \$SCAN_ALLOW_MATCHED_WHERE' || return 1
  matches "$code" 'SCAN_ALLOW_MATCHED_WHERE=\$\{SCAN_ALLOW_WHERE\[\$i\]\}' || return 1
  matches "$code" 'safe_path "\$scan_allow_label"' || return 1
  # A file that is not there, or holds nothing but comments, reads exactly like
  # one that worked — the failure is a publish that refuses on every run.
  matches "$code" 'CACHE_SCAN_ALLOW_FILE names no readable file' || return 1
  matches "$code" 'holds no digests' || return 1
  # ...and it is read BEFORE the prepare command runs. The build job's checkout
  # is writable by the install it is about to run, so an allowlist parsed after
  # third-party code executed is one that code could have extended — it would
  # excuse its own planted file and the run would look like a clean publish.
  #
  # Since the extraction it takes two assertions instead of one, because the
  # allowlist now lives in the other file and runs when that file is SOURCED.
  # Both halves are checked, and each is checked WITHIN one file's own lines: the
  # two are concatenated in whichever order puts the mutated one first, so a line
  # number compared across the seam would mean nothing.
  #
  # Half one: the source happens before the prepare command is launched.
  local src_at prep_at
  src_at=$(printf '%s\n' "$code" | grep -n '^  \. "\$HERE/scan-cache-credentials\.sh"$' | head -1 | cut -d: -f1)
  prep_at=$(printf '%s\n' "$code" | grep -n 'timeout -k 30 "\$CACHE_PREPARE_TIMEOUT"' | head -1 | cut -d: -f1)
  [ -n "$src_at" ] && [ -n "$prep_at" ] && [ "$src_at" -lt "$prep_at" ] || return 1
  # Half two: sourcing is what parses it. Both parses sit at TOP LEVEL — column
  # zero, not inside a function — so they run at source time. Moved into
  # `scan_credentials_or_die` they would instead run after the prepare command,
  # which is the ordering this pair of checks exists to refuse.
  matches "$code" '^if \[ -n "\$\{CACHE_SCAN_ALLOW_FILE:-\}" \]; then$'    || return 1
  matches "$code" '^if \[ -n "\$\{CACHE_SCAN_ALLOW_DIGESTS:-\}" \]; then$' || return 1
  # Half three: a library that did not load is a hard refusal, not a publish with
  # one pass missing. The source is CONDITIONAL — the cache-warmer inlines the
  # library instead, because its Cloud Build step runs `bash -c "<text>"` and has
  # no scripts/ci to source from — so "the function is defined" is the thing that
  # has to be asserted, separately from "the source ran".
  matches "$code" 'declare -F scan_credentials_or_die >/dev/null 2>&1 \\$' || return 1
  matches "$code" 'the embedded-credential content scan is not loaded' || return 1
  matches "$code" 'scan_credentials_or_die "\$root"' || return 1
  matches "$code" '\[ "\$d" = "\$1" \]' || return 1
  matches "$code" 'sha256sum is not on PATH' || return 1
  matches "$code" 'log "the content scan excused \$\(safe_path' || return 1
  ! matches "$code" '\$\{pass\[@\]\}.*\| head' || return 1
  # ...and a registry token is refused with the allowlist set, before a digest is
  # even computed. That shape no dependency ships, so an entry that could excuse
  # one would be an operator's route past a live credential rather than past a
  # false positive. The other two rules are excusable, on DIFFERENT terms, and
  # the two numbers are the whole argument: a PEM's bytes are key material, so
  # its hash gives an attacker nothing and it is excusable at any size; a
  # `user:password@` URL sits in a package's published README or `.d.ts`, so
  # everything except the credential is already public and a hash of a short one
  # is an offline oracle for the rest.
  matches "$code" 'SCAN_EXCUSABLE_MIN_BYTES=1024' || return 1
  matches "$code" '^    private-key-header \) printf .0. ;;$' || return 1
  matches "$code" "^    url-embedded-basic-auth \\) printf '%s' \"\\\$SCAN_EXCUSABLE_MIN_BYTES\" ;;\$" || return 1
  # The default arm is what makes the floor table a whitelist: a rule added to
  # the scan later has no number here and so is unexcusable until someone writes
  # one. Anchored to the whole line, because `* ) return 1 ;;` unanchored is also
  # a substring of `*[!0-9]* ) return 1 ;;` elsewhere in the script -- the loose
  # form went on passing with this arm deleted.
  matches "$code" '^    \* \) return 1 ;;$' || return 1
  # EVERY label, at THIS file's size. A file tripping two rules is excusable only
  # if both are: a README documenting a registry token and a connection string is
  # not half-excusable.
  matches "$code" 'for label in \$labels; do' || return 1
  matches "$code" 'floor=\$\(scan_label_min_bytes "\$label"\) \|\| return 1' || return 1
  matches "$code" '\[ "\$size" -ge "\$floor" \] \|\| return 1' || return 1
  matches "$code" '\[ -n "\$labels" \] \|\| return 1' || return 1
  # Excusing and PRINTING are different questions, and the version that asked one
  # function for both printed a digest for the class whose carrier bytes are
  # public. The narrower one governs the log: private-key only, and still ≥1024
  # because this rule matches a header, not the key.
  matches "$code" "SCAN_PRINTABLE_LABELS='private-key-header'" || return 1
  # Anchored to the walk's own indentation. Unanchored, the one-line case in
  # scan_excusal_source_is_allowed contains this text too, and satisfies the
  # assertion while the walk above it is inverted — which is exactly what it
  # did until CI caught it.
  matches "$code" '^      \*" \$label "\* \) ;;$' || return 1
  matches "$code" '^      \* \) return 1 ;;$' || return 1
  matches "$code" '\[ "\$\(wc -c <"\$1"\)" -ge "\$SCAN_EXCUSABLE_MIN_BYTES" \]' || return 1
  # One predicate per question, each asked at exactly the sites that own it. The
  # scan decides with the excusability one; the reporter offers a digest only
  # under the printable one, and falls back to the excusability one to tell the
  # operator a list would work if they computed the hash off the log.
  matches "$code" 'if scan_hit_is_excusable "\$bad"; then' || return 1
  matches "$code" 'elif scan_hit_digest_is_printable "\$file"; then' || return 1
  matches "$code" 'elif scan_hit_is_excusable "\$file"; then' || return 1
  [ "$(printf '%s\n' "$code" | grep -c 'scan_hit_is_excusable')" = 3 ] || return 1
  [ "$(printf '%s\n' "$code" | grep -c 'scan_hit_digest_is_printable')" = 2 ] || return 1
  # Neither predicate may hand over the file's bytes. They are called from inside
  # the reporter, whose own body is walked below for exactly this — but that walk
  # sees only the call, not what the callee does with what it reads.
  #
  # An ALLOW-list of the forms that may touch "$1", for the same reason the
  # reporter's walk is one: a ban-list of the commands that leak is not closed.
  # Banning printf/echo/cat still leaves `die "$(<"$1")"`, `die "$(grep . "$1")"`
  # and `read -r x <"$1"; die "$x"`, all three of which put the content on stderr
  # — `die` is allowed because it prints a sanitised PATH, and nothing about
  # `die` forces its argument to be one.
  local -a reads_arg=(
    'matched_labels "$1"'
    'wc -c <"$1"'
    # The confirmation stage reads the file too, and it is on the same walk for
    # the same reason: it answers yes or no about the bytes and must never put
    # them anywhere. Only two forms may touch its argument — the read that feeds
    # awk, and the sanitised PATH in its own error.
    'LC_ALL=C tr -d '"'"'\000'"'"' <"$1"'
    'safe_path "$1"'
  )
  for form in scan_hit_is_excusable scan_hit_digest_is_printable scan_file_holds_pem_block; do
    labeller=$(printf '%s\n' "$code" | sed -n "/^$form() {/,/^}\$/p")
    matches "$labeller" "^$form\(\) \{" || return 1
    while IFS= read -r line; do
      rest="$line"
      for arg in "${reads_arg[@]}"; do rest="${rest//"$arg"/}"; done
      case "$rest" in *'"$1"'* ) return 1 ;; esac
    done < <(printf '%s\n' "$labeller" | grep -F '"$1"')
  done
  # Printable must be a SUBSET of excusable, and structurally so. A label added
  # to SCAN_PRINTABLE_LABELS with no row in the floor table would print a digest
  # for a file no list can excuse — this round's defect, back through a different
  # door — so every printable label is required to resolve to a floor.
  for label in $(printf '%s\n' "$code" | sed -n "s/^SCAN_PRINTABLE_LABELS='\(.*\)'\$/\1/p"); do
    matches "$code" "^    $label \) printf" || return 1
  done
  # One call site, in the content pass. Wired into the filename, link, setuid or
  # capability pass it would excuse something a HOST refuses, and the archive
  # would be published for every host to reject.
  [ "$(printf '%s\n' "$code" | grep -c 'scan_digest_is_allowed')" = 2 ] || return 1
  # A digest is not enough on its own for the URL class: it has to have come from
  # the file, where the entry names the package. Asserted at the call site AND in
  # the table, because a table with an empty string in it silently allows
  # everything and reads as if the rule were still there.
  matches "$code" 'scan_digest_is_allowed "\$digest" && scan_excusal_source_is_allowed "\$labels"' || return 1
  matches "$code" "SCAN_FILE_ONLY_LABELS='url-embedded-basic-auth'" || return 1
  matches "$code" '"CACHE_SCAN_ALLOW_FILE"\* \) ;;' || return 1
  # The prefilter's second question. The pattern stays the cheap one — asserted
  # unchanged above — and the confirmation is what keeps 22 churning source files
  # out of the allowlist. Guarded on the label being the ONLY one, so a file that
  # also trips the token rule cannot ride out on an unconfirmed header.
  matches "$code" '\[ "\$labels" = private-key-header \] && ! scan_file_holds_pem_block "\$bad"' || return 1
  matches "$code" 'scan_file_holds_pem_block\(\) \{' || return 1
  confirmer=$(printf '%s\n' "$code" | sed -n '/^scan_file_holds_pem_block() {/,/^}$/p')
  # A body line is REQUIRED between the two markers — that is the whole rule, and
  # a version that confirmed on BEGIN plus END alone would still flag every
  # secret-detector source that names both.
  matches "$confirmer" 'if \(body > 0\) found = 1' || return 1
  # An encrypted OpenSSL key carries `Proc-Type:`/`DEK-Info:` and a blank line
  # before its body. Drop either arm and a real encrypted key reads as
  # unconfirmed and is published.
  matches "$confirmer" 'inblock && /\^\[\[:space:\]\]\*\[A-Za-z\]\[A-Za-z0-9-\]\*:/' || return 1
  matches "$confirmer" 'inblock && /\^\[\[:space:\]\]\*\$/' || return 1
  # Indentation does not stop a key being a key. A PEM in a YAML block scalar
  # arrives indented and YAML gives it back unindented, so anchoring the body at
  # column zero made every one of those read as unconfirmed — and unconfirmed is
  # the direction that publishes.
  matches "$confirmer" 'inblock && /\^\[\[:space:\]\]\*\[A-Za-z0-9\+\\/=\]\+\[\[:space:\]\]\*\$/' || return 1
  ! matches "$confirmer" '/\^\[A-Za-z0-9\+\\/=\]' || return 1
  # NULs stripped, byte locale, and an errored awk refuses. Same three rules the
  # passes that refuse already run under; a confirmation stage that fails open is
  # a hole in the one direction that matters.
  matches "$confirmer" "LC_ALL=C tr -d '\\\\000' <\"\\\$1\" \| LC_ALL=C awk" || return 1
  # The reader's status read SEPARATELY from the parser's. Under pipefail a `tr`
  # that could not open the file and an awk that found no key both leave 1, and
  # those are opposite verdicts — the second is a clean file, the first is a file
  # that changed under the scan between the grep and the confirmation.
  matches "$confirmer" '^  if LC_ALL=C tr -d' || return 1
  matches "$confirmer" 'pipes="\$\{PIPESTATUS\[\*\]\}"' || return 1
  matches "$confirmer" '^  reader=\$\{pipes%% \*\}' || return 1
  matches "$confirmer" '^  parser=\$\{pipes##\* \}' || return 1
  matches "$confirmer" '\[ "\$reader" = 0 \]' || return 1
  matches "$confirmer" '\[ "\$parser" -le 1 \]' || return 1
  matches "$confirmer" '\[ "\$parser" = 0 \]' || return 1
  ! matches "$confirmer" '\[ "\$rc" -le 1 \]' || return 1
  # No early exit. `exit` mid-stream SIGPIPEs the `tr` in front of it and, under
  # pipefail, turns a confirmed key into a scan error — which this file's own
  # drain rule exists to prevent.
  ! matches "$confirmer" 'inblock.*\{ *exit' || return 1
  matches "$confirmer" 'END \{ exit\(found \? 0 : 1\) \}' || return 1
  # grep says >=2 for "I broke", and a >=2 that goes unread reads exactly like a
  # clean pass — on the one layer that sees an embedded credential.
  matches "$code" 'die "the staged tree could not be scanned for embedded credentials' || return 1
  # Nothing in the reporter may hand over the file's CONTENT — it may only report
  # ABOUT it. An ALLOW-list of the forms that may touch "$file", not a ban on the
  # commands that leak: `head -c` banned still leaves `head -n`, `$(<"$file")`,
  # `sed -n 1p`, awk, cut, dd, base64 and read. The set below is closed, so a new
  # way to print the bytes fails here whatever it is called. One occurrence per
  # line, so a leak cannot ride along on the end of an allowed one.
  reporter=$(printf '%s\n' "$code" | sed -n '/^explain_credential_hit() {/,/^}$/p')
  local -a reads_about=(
    'wc -c <"$file"'
    'wc -l <"$file"'
    # Carrying `LC_ALL=C` makes this list pin the locale too: drop the prefix
    # and the form stops matching, `"$file"` survives the strip, and the
    # assertion fails. The reporter reads the same bytes under the same rules
    # as the passes that refuse, or it reports on a different file than the one
    # that was caught.
    'LC_ALL=C grep -ca -E -e "$pat" "$file"'
    'LC_ALL=C grep -na -m1 -E -e "$pat" "$file"'
    'LC_ALL=C grep -oEa -m1 -e "$pat" "$file"'
    'matched_labels "$file"'
    # Asks about the file (which rules it tripped, how big it is) and answers
    # yes or no. It is on this list for the same reason `matched_labels` is:
    # both read the bytes and neither hands them to the log.
    'scan_hit_is_excusable "$file"'
    'scan_hit_digest_is_printable "$file"'
    'sha256sum <"$file"'
  )
  while IFS= read -r line; do
    rest="$line"
    for form in "${reads_about[@]}"; do rest="${rest//"$form"/}"; done
    case "$rest" in *'"$file"'* ) return 1 ;; esac
  done < <(printf '%s\n' "$reporter" | grep -F '"$file"')
  # The labeller behind the digest gate collects EVERY rule a file trips. An
  # early exit there returns a shorter list, and a shorter list is what makes a
  # file equal `private-key-header` and so excusable.
  labeller=$(printf '%s\n' "$code" | sed -n '/^matched_labels() {/,/^}$/p')
  ! matches "$labeller" '(^|[;&| ])(break|return|exit)([ ;&|]|$)' || return 1
  matches "$labeller" '\[ "\$rc" -le 1 \]' || return 1
  # The hit list is created with mktemp, so the prepare command — which runs as
  # this uid, before the scan, knowing the temp root — cannot pre-create it as a
  # symlink to /dev/null or as a directory and take the whole pass green. The
  # directory it is created IN is $SCAN_TMPDIR, which the publisher points at its
  # own 0700 archive directory — the second assertion, because a library default
  # of `.` would put the list inside whatever tree the caller happened to be in.
  matches "$code" 'hits=\$\(mktemp "\$SCAN_TMPDIR/hits\.XXXXXX"\)' || return 1
  matches "$code" '^SCAN_TMPDIR="\$ARCHIVE_DIR"$' || return 1
  matches "$code" 'SCAN_TMPDIR="\$\(mktemp -d\)"' || return 1
  matches "$code" 'die "the content scan found matches it could not then read' || return 1
  matches "$code" 'done <"\$hits"' || return 1
  # NUL-separated, both ends. A newline is a legal filename byte, so a
  # newline-separated hit list lets one planted name split into an excused
  # record plus an empty one and never be opened. Asserted as a PAIR: either
  # half alone silently drops every hit after the first.
  matches "$code" 'grep -rlaZ -E' || return 1
  matches "$code" "while IFS= read -r -d '' bad; do" || return 1
  # `-a`, never `-I`. `-I` skips a file grep calls binary, and grep decides that
  # on the first NUL byte -- so one leading NUL written by the install turns this
  # pass off for that file, in BOTH jobs, because both call the same function.
  #
  # Pinned by CONSTRUCTION, not by banning one spelling of the mistake. A guard
  # written as `! matches 'grep -rl[a-zA-Z]*I'` reads like it covers this and does
  # not: `grep -rIlZ` and `grep -rlZ --binary-files=without-match` both walk past
  # it and both publish the NUL exploit. So: the flag group is asserted exactly,
  # and the two opt-outs are banned anywhere in the file, since neither has a
  # legitimate use in a script whose only content pass must read every byte.
  matches "$code" '^  LC_ALL=C grep -rlaZ -E "\$\{pass\[@\]\}" "\$root" >"\$hits"' || return 1
  # Scoped to a grep's own short-option cluster, in any position: `-rIlZ` and
  # `-rlIZ` are the same flag and neither may appear. Not a bare `-I` search --
  # `kill -KILL` would trip that, and a guard that has to be loosened later gets
  # loosened past the thing it guards.
  ! matches "$code" 'grep( -[a-zA-Z]+)* -[a-zA-Z]*I' || return 1
  ! matches "$code" 'grep .*[-]-binary-files=' || return 1
  # Every other file this script writes into $ARCHIVE_DIR gets the same
  # treatment as the hit list, for the same reason: a fixed name there is one
  # the prepare command can pre-create as a symlink.
  matches "$code" 'list=\$\(mktemp "\$ARCHIVE_DIR/listing\.XXXXXX"\)' || return 1
  matches "$code" 'pointer_body=\$\(mktemp "\$ARCHIVE_DIR/current\.XXXXXX"\)' || return 1
  ! matches "$code" '"\$ARCHIVE_DIR/(listing|snap\.tar\.gz|current)"' || return 1
  # The archive is not created until the branch that packs it. An unguessable
  # name is no defence for THIS file: mktemp randomises against guessing, and the
  # prepare command can simply list the directory. What matters is that the file
  # does not exist at all while untrusted code is still running.
  matches "$code" '^ARCHIVE=""$' || return 1
  # `read` stops at the first newline whatever IFS says.
  matches "$code" "read -rd '' -a SCAN_ALLOW_RAW" || return 1
  # The host refuses a multi-linked file, so nothing may be packed as a link
  # member; a staging tree legitimately has them (pnpm), which is why the bound
  # is on the archive rather than on the tree.
  matches "$code" '\-\-hard-dereference' || return 1
  matches "$code" 'archive_is_flat "\$ARCHIVE"' || return 1
  # ...and the listing it writes is bounded. Unbounded, an archive with an
  # enormous member count puts a multi-gigabyte file on the publish runner before
  # a line of it is read. Bounded but TRIMMED would be worse than either: the
  # offending member could be in the part that was cut, so the check would pass
  # on exactly the archive it was written to catch. Over the bound is a refusal.
  matches "$code" 'cap=\$\(cache_expand_bound "\$\(stat -c %s "\$1"\)"\)' || return 1
  matches "$code" 'tar -tvzf "\$1" \| head -c "\$\(\(cap \+ 1\)\)" >"\$list"' || return 1
  # BOTH statuses, and the limiter's is the one that was dropped. It is the last
  # stage, so nothing SIGPIPEs it: every failure it reports is a failure to
  # WRITE the listing, ENOSPC first among them, and a listing that stopped early
  # measures comfortably under the cap. The flatness scan then passes on a
  # PREFIX, and a setuid member past the cut is never looked at.
  matches "$code" 'list_pipes="\$\{PIPESTATUS\[\*\]\}"' || return 1
  matches "$code" '^  tar_rc=\$\{list_pipes%% \*\}' || return 1
  matches "$code" '\[ "\$\{list_pipes##\* \}" = 0 \]' || return 1
  ! matches "$code" 'tar_rc=\$\{PIPESTATUS\[0\]\}' || return 1
  matches "$code" '\[ "\$written" -le "\$cap" \]' || return 1
  # And the BYTE COUNT decides which refusal is printed, not tar's status. `head`
  # closing the pipe kills tar with SIGPIPE, so reading the status alone reports
  # every over-long listing as a corrupt archive and sends the operator looking
  # for a hardware fault — the same misdiagnosis unpack_failed exists to avoid.
  local flat trunc_at rc_at
  flat=$(printf '%s\n' "$code" | sed -n '/^archive_is_flat() {/,/^}$/p')
  trunc_at=$(printf '%s\n' "$flat" | grep -nE '\[ "\$written" -le "\$cap" \]' | head -n1 | cut -d: -f1)
  rc_at=$(printf '%s\n' "$flat" | grep -nE '\[ "\$tar_rc" = 0 \]' | head -n1 | cut -d: -f1)
  [ -n "$trunc_at" ] && [ -n "$rc_at" ] && [ "$trunc_at" -lt "$rc_at" ] || return 1
  # The prepare command's own failure must be one: `sh -c` without -e publishes a
  # half-populated cache with a zero exit. Asserted on the shell that actually
  # runs it — the wrapper that records the process group execs into this one, so
  # a `-e` dropped HERE is the one that matters, and the wrapper carrying `-euc`
  # would otherwise satisfy a laxer pattern.
  matches "$code" 'exec sh -euc "\$cmd"' || return 1
  matches "$code" '^      cmd=\$CACHE_PREPARE_CMD$' || return 1
  # The publishing phase re-scans what it received. The archive crossed a job
  # boundary, and the job that scanned it first is the one that ran other
  # people's code.
  # The bytes that get shipped are the bytes that get scanned. Unconditional and
  # at the top level: gated on the phase, a single-phase run has exactly one scan
  # and anything substituted after it reaches the bucket. Into a tree of its own,
  # because $STAGE is what the install populated.
  # The URL rule is anchored to a real scheme. Unanchored, `://x:y@` is five
  # bytes of shape that random data produces about once a gibibyte -- and since
  # the pass reads binaries, those land on hash-named compressed blobs that
  # cannot be excused and cannot be inspected. A gate that refuses good snapshots
  # is a gate someone removes, so the false-positive rate is a property of the
  # rule, not a nuisance. ONE list drives both finding the hit and validating the
  # scheme the refusal prints; two would drift.
  matches "$code" "^URL_SCHEME_ALT='" || return 1
  # The VCS schemes as a family, not a hand-picked few: pip and npm both take a
  # VCS-pinned dependency over plain http, so a list with `git+https` and without
  # `git+http` reads like policy and is an oversight.
  matches "$code" '\(git\|hg\|bzr\|svn\)\(\\\+\(ssh\|https\?\|file\)\)\?' || return 1
  matches "$code" 'url-embedded-basic-auth\|\(\^\|\[\^A-Za-z0-9\+\.-\]\)\(\$URL_SCHEME_ALT\)://' || return 1
  # `grep -c … >/dev/null` and never `grep -qE`: the writer is an in-process
  # `printf` of a shell variable, and the status of this pipeline IS whether the
  # scheme is recognised. `-q` exits on the first match, the `printf` dies of
  # EPIPE, and pipefail then reports a scheme that WAS recognised as one that was
  # not — printing the raw hit the allow-list exists to keep out of the log. See
  # PFR3 in check-pipefail-readers.sh.
  matches "$code" 'grep -cE "\^\(\$URL_SCHEME_ALT\)\$" >/dev/null' || return 1

  matches "$code" '^VERIFY=\$\(mktemp -d\)' || return 1
  matches "$code" '^scan_or_die "\$VERIFY"$' || return 1
  # The publisher's copy of the scan says which predicate fired too — it is the
  # same six sharing the same sentence, and an operator reading "holds a link,
  # node or setuid entry" about a DIRECTORY has been sent the wrong way once.
  matches "$code" "\-printf '%y %M %p" || return 1
  matches "$code" '\-C "\$VERIFY" --no-same-owner' || return 1
  # The SAME bound a host applies, computed by the same function, floored by the
  # same number. The point of bounding here at all is that an archive past the
  # bound is one every host would silently refuse; a publisher whose bound has
  # drifted from the fleet's is checking nothing anyone will act on. The floor
  # exists because tar writes nothing shorter than 10240 bytes, so 8x of a tiny
  # tree cuts a perfectly valid archive.
  matches "$code" '^verify_bound=\$\(cache_expand_bound "\$size"\)$' || return 1
  matches "$code" 'head -c "\$verify_bound"' || return 1
  matches "$code" '^CACHE_EXPAND_FLOOR_BYTES=65536$' || return 1
  matches "$code" '\[ "\$bound" -ge "\$CACHE_EXPAND_FLOOR_BYTES" \] \|\| bound=\$CACHE_EXPAND_FLOOR_BYTES' || return 1
  # The bound is enforced by COUNTING, before the unpack, because tar exits 0 on a
  # stream cut at a member boundary: the verification tree would then hold a
  # prefix, the credential scan would pass on the prefix, and the whole archive
  # would be published. The count is itself bounded — an expansion check that
  # decompresses without a limit is the gzip bomb's amplifier.
  matches "$code" '^assert_expands_within_bound\(\) \{ # <bound>$' || return 1
  matches "$code" 'expanded=\$\( \(gzip -dc "\$ARCHIVE" \|\| true\) \| head -c "\$\(\(\$1 \+ 1\)\)" \| wc -c \) \|\| expanded=\$\(\(\$1 \+ 1\)\)' || return 1
  matches "$code" '\[ "\$expanded" -le "\$1" \]' || return 1
  matches "$code" '^assert_expands_within_bound "\$verify_bound"$' || return 1
  # ...and the refusal quotes both halves of the bound — an operator who reads
  # only "past the 3152 byte bound" cannot tell a gzip bomb from a fixture that
  # packed to 394 bytes.
  matches "$code" 'floored at \$CACHE_EXPAND_FLOOR_BYTES' || return 1
  ! matches "$code" 'size \* 8' || return 1
  # Counting before unpacking, not after. Below the unpack it is a postmortem on
  # a tree the scan has already been handed.
  local assert_at verify_at
  assert_at=$(printf '%s\n' "$code" | grep -nE '^assert_expands_within_bound "\$verify_bound"$' | head -n1 | cut -d: -f1)
  verify_at=$(printf '%s\n' "$code" | grep -nE 'head -c "\$verify_bound"' | head -n1 | cut -d: -f1)
  [ -n "$assert_at" ] && [ -n "$verify_at" ] && [ "$assert_at" -lt "$verify_at" ] || return 1
  # A tar that says nothing is not a tar that succeeded, so its status can no
  # longer be the thing that decides the bound.
  ! matches "$code" 'unpack_failed' || return 1

  # The install runs in a process group of its own, bounded, and the group is
  # reaped BEFORE anything is scanned. `sh -euc` returning does not mean the
  # install stopped -- a lifecycle script that daemonises keeps running as this
  # uid with the staged tree in reach, and every "the scan bounds it" argument in
  # that file is written against a process that by then no longer exists.
  # Asserted as a set: `set -m` is what creates the group, the pgid check is what
  # proves it, the two kills are what use it. Any one alone is decoration.
  matches "$code" '^  set -m$' || return 1
  matches "$code" '^  CACHE_PREPARE_PGID_FILE="\$prep_pgid_file" CACHE_PREPARE_CMD="\$CACHE_PREPARE"' || return 1
  matches "$code" '^    timeout -k 30 "\$CACHE_PREPARE_TIMEOUT" sh -euc .$' || return 1
  # The child records its own group; the parent does not interrogate a pid that
  # may already be reaped. Asking `ps` from here could not answer in the one case
  # the assertion exists for — a prepare that finished before `ps` saw it reports
  # nothing, "nothing" has to pass, and a reaped child is also the shape most
  # likely to have left a daemon in the group. A file the child wrote is there
  # whether or not the process is.
  matches "$code" 'tr -dc 0-9 >"\$CACHE_PREPARE_PGID_FILE"' || return 1
  matches "$code" 'cut -d" " -f5 /proc/self/stat' || return 1
  matches "$code" 'prep_seen=\$\(tr -dc 0-9 <"\$prep_pgid_file"\)' || return 1
  ! matches "$code" 'prep_seen=\$\(pgid_of "\$prep_pgid"' || return 1
  # `kill -0` is not a source for this either: bash's kill builtin reports a job
  # it has already reaped as live, so pairing it with a `ps` lookup made every
  # fast prepare on Linux look like a wrong group.
  ! matches "$code" 'kill -0 "\$prep_pgid"' || return 1
  # An unrecorded group and a wrong group are separate refusals. Collapsed into
  # `[ -z "$prep_seen" ] || [ ... ]` — which is what this replaced — an empty
  # value PASSES, and empty is now the interesting case rather than the benign
  # one, so that shape must not come back.
  matches "$code" '^  \[ -n "\$prep_seen" \]' || return 1
  matches "$code" '^  \[ "\$prep_seen" = "\$prep_pgid" \]' || return 1
  ! matches "$code" '\[ -z "\$prep_seen" \] \|\|' || return 1
  # Read AFTER the wait, or empty means "not yet" and the ambiguity is back.
  local pgid_at wait_at
  pgid_at=$(printf '%s\n' "$code" | grep -nE 'prep_seen=\$\(tr -dc 0-9' | head -n1 | cut -d: -f1)
  wait_at=$(printf '%s\n' "$code" | grep -nE '^  wait "\$prep_pgid"' | head -n1 | cut -d: -f1)
  [ -n "$pgid_at" ] && [ -n "$wait_at" ] && [ "$wait_at" -lt "$pgid_at" ] || return 1
  # The path is out of the environment before the prepare command is exec'd. Not
  # a wall — same uid, and `ls` finds an mktemp name — but the obvious forgery
  # should not be handed over in a variable.
  matches "$code" 'unset CACHE_PREPARE_PGID_FILE CACHE_PREPARE_CMD' || return 1
  # The refusal names the two values it compared. Without them the message is
  # the same string whether nothing was recorded or the wrong group was.
  matches "$code" 'child pid \$prep_pgid, its group .\$prep_seen' || return 1
  matches "$code" 'kill -TERM -- "-\$prep_pgid"' || return 1
  matches "$code" 'kill -KILL -- "-\$prep_pgid"' || return 1
  # ...and BEFORE the scan, which is the whole claim. A reap that runs after the
  # staged tree has been read bounds nothing: the write it was supposed to
  # prevent has already happened and already been scanned past. Order is the
  # property here, so order is what gets asserted -- the presence of the kills
  # says nothing on its own.
  local reap_at scan_at refuse_at
  reap_at=$(printf '%s\n' "$code" | grep -nE 'kill -KILL -- "-\$prep_pgid"' | head -n1 | cut -d: -f1)
  scan_at=$(printf '%s\n' "$code" | grep -nE '^  scan_or_die "\$STAGE"$' | head -n1 | cut -d: -f1)
  [ -n "$reap_at" ] && [ -n "$scan_at" ] && [ "$reap_at" -lt "$scan_at" ] || return 1
  # ...and before the REFUSALS too, which is the harder half. `$prep_pgid` is
  # this shell's own child, so the group to kill is known here whatever the
  # recorder managed to write — and every reason the record can be missing is a
  # reason to want the group reaped MORE: both probes failed, the write was
  # interrupted, or same-uid prepare code truncated the file precisely so this
  # run would give up before the kill. Dying on the record ahead of the kill
  # left daemonized descendants running on the one path that exists to report
  # the group could not be verified.
  refuse_at=$(printf '%s\n' "$code" | grep -nE '^  \[ -n "\$prep_seen" \]' | head -n1 | cut -d: -f1)
  [ -n "$refuse_at" ] && [ "$reap_at" -lt "$refuse_at" ] || return 1

  # The bytes scanned are the bytes shipped. The verify pass reads a tree
  # unpacked FROM the archive, while `cp` and `gcloud storage cp` re-open the
  # archive itself -- so without a digest pinned across that gap, everything that
  # was verified was verified about bytes that could since have been replaced.
  # Both call sites, or the pin only covers the half that has one.
  # ...and the credentialed phase never runs the install at all, which is what
  # makes the pin a detector rather than the only thing standing between an
  # escapee and the upload. `setsid` leaves the process group and `kill -- -$pgid`
  # cannot follow it, so in a process that both builds and publishes there is
  # always a racer for the gap between the last check and gcloud's own open.
  # Removing the racer is the fix; shrinking the window is not.
  matches "$code" '^\[ "\$BUILDING" = 0 \] \|\| \[ "\$PUBLISHING" = 0 \]' || return 1

  matches "$code" '^ARCHIVE_SHA=\$\(sha256sum <"\$ARCHIVE" \| cut' || return 1
  # BEFORE the size and layout verdicts, not after. `stat` and `tar -tvzf` each
  # re-open the archive; rendered before the pin exists, their answers describe
  # bytes nothing can later prove were the ones shipped -- and archive_is_flat is
  # the ONLY pass that sees setuid and hardlink members, because the verify
  # extraction drops modes and xattrs before its own scan can look.
  local pin_at size_at flat_at
  pin_at=$(printf '%s\n' "$code" | grep -nE '^ARCHIVE_SHA=' | head -n1 | cut -d: -f1)
  size_at=$(printf '%s\n' "$code" | grep -nE '^size=\$\(stat' | head -n1 | cut -d: -f1)
  flat_at=$(printf '%s\n' "$code" | grep -nE '^archive_is_flat "\$ARCHIVE"' | head -n1 | cut -d: -f1)
  [ -n "$pin_at" ] && [ -n "$size_at" ] && [ -n "$flat_at" ] || return 1
  [ "$pin_at" -lt "$size_at" ] && [ "$pin_at" -lt "$flat_at" ] || return 1
  matches "$code" '^assert_archive_unchanged "the size and member-layout verdicts were trusted"' || return 1
  matches "$code" '^assert_archive_unchanged\(\) \{' || return 1
  matches "$code" '^  assert_archive_unchanged "the artifact was written"' || return 1
  matches "$code" '^assert_archive_unchanged "the upload"' || return 1

  # Every refusal that interpolates a path runs it through safe_path, including
  # the one whose value is a workflow literal today. An unsanitised path in a
  # die is an Actions workflow-command injection the day someone derives that
  # value from job output, and "not attacker-controlled yet" is not a property
  # the next edit preserves.
  matches "$code" '^  \[ -f "\$CACHE_ARCHIVE_IN" \] \|\| die .*\$\(safe_path "\$CACHE_ARCHIVE_IN"\)' || return 1
  ! matches "$code" 'die "[^"]*: \$CACHE_ARCHIVE_IN"' || return 1

  # mkdir -p takes the ambient umask where mktemp -d gave 0700.
  matches "$code" 'mkdir -p "\$STAGE"; chmod 0700 "\$STAGE"' || return 1
  # ...and the name it uploads under is derived from that pinned digest rather
  # than from a fresh read, which would name the file after bytes nothing checked.
  matches "$code" '^digest=\$\{ARCHIVE_SHA:0:16\}$' || return 1
  ! matches "$code" 'sha256sum "\$ARCHIVE"' || return 1
  # A missing getcap is a refusal, not a skip: on a snapshot the scan is the only
  # opinion, and a check that can be skipped rather than failed is not a bound.
  # Anchored, and the refusal with it: `if command -v getcap; then` still holds
  # the same words while turning the requirement into a skip.
  matches "$code" '^command -v getcap' || return 1
  matches "$code" '^  \|\| die "getcap is not installed' || return 1
  # Write-once, and the two bounds that keep it that way.
  matches "$code" 'SNAP="\$\(date -u \+%Y%m%dT%H%M%SZ\)-\$\{digest\}\.tar\.gz"' || return 1
  matches "$code" 'uploadType=resumable&name=\$\{ENC_SNAP\}&ifGenerationMatch=0' || return 1
  matches "$code" 'uploadType=media&name=\$\{ENC_POINTER\}&ifGenerationMatch=\$\{gen\}' || return 1
  # ...and the upload names the object rather than letting a tool work it out.
  # `gcloud storage cp` lists the destination to decide whether it is a directory,
  # a list is authorised against the BUCKET, and every one of the publisher's
  # grants is conditioned on an object prefix -- so a `cp` here is a 403 after the
  # pack, or a fourth IAM binding that can list every other pool's snapshots.
  ! matches "$code" 'gcloud storage cp' || return 1
  # The token reaches curl over a pipe, never in argv.
  matches "$code" '\-K <\(printf .header = "Authorization: Bearer' || return 1
  ! matches "$code" '\-H "Authorization: Bearer' || return 1
  # The session URI is the one URL here that arrived from the network, and it
  # then receives requests carrying that token. It is checked against the
  # endpoint this run addressed, and the scheme is pinned, so a `Location:`
  # naming somewhere else cannot be handed the credential.
  matches "$code" 'refusing to send the credential to it' || return 1
  matches "$code" "curl -sS --proto '=https'" || return 1
  # Success is the STATUS CODE, never curl's exit status: `-f` calls a 308
  # Resume Incomplete a success, and the pointer would then name an object that
  # was never finalised -- a fleet-wide silent cold start.
  matches "$code" '200 \| 201 \) uploaded=1; break ;;' || return 1
  matches "$code" 'has not finalised the object' || return 1
  # ...and the resume probe declares a zero-length body. Without it curl sends no
  # Content-Length, the frontend answers 411 rather than 308, no `Range:` comes
  # back, and the resume path is present but can never resume.
  matches "$code" "\-H 'Content-Length: 0' -H \"Content-Range: bytes \\*/" || return 1
  # The archive's digest travels with the upload, so a transfer corrupted in
  # flight is refused by the service instead of stored and then pointed at.
  matches "$code" 'openssl dgst -md5 -binary "\$ARCHIVE"' || return 1
  matches "$code" 'md5Hash' || return 1
  # ...and the pin is re-asserted on a retry, which re-reads the file.
  matches "$code" 'assert_archive_unchanged "the upload retry"' || return 1
  # The pointer's generation: no `-f` and `|| true`, because under `set -euo
  # pipefail` a bare failing assignment TERMINATES THE SHELL -- the first
  # publish into a fresh prefix would die silently between the upload and the
  # swap. And the parse is anchored, because `metageneration` ends in
  # `generation` too, and digit-validated before it reaches a URL.
  matches "$code" "sed -n 's/\\^generation:" || return 1
  matches "$code" 'head -n 1\) \|\| true' || return 1
  matches "$code" '\*\[!0-9\]\* \) gen=0 ;;' || return 1
  # Size, because a snapshot past the pools' bound is refused by every host and
  # reads in their logs as "nothing published" rather than as an error.
  matches "$code" 'CACHE_MAX_BYTES' || return 1
  # And the split itself: a build-only run must stop before the first gcloud call.
  # Everything above describes what a good snapshot is; this is the line that says
  # the phase that ran other people's code does not get to upload one.
  matches "$code" '^if \[ "\$PUBLISHING" = 0 \]; then' || return 1
}

# The two sides derive the same list from nothing — the host's copy is embedded
# in a startup script that cannot source this repository. A name on one list and
# not the other is bytes shipped and dropped, or a directory published and never
# accepted, and neither side would say so.
has_agreeing_cache_dirs() { # <publish-script>
  local a b
  a=$(grep -m1 -E '^CACHE_DIRS=\(' "$1")
  b=$(grep -m1 -E '^CACHE_DIRS=\(' "$SCRIPT")
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# The workflow template consumers copy. It is documentation, and it is also the
# thing that actually runs beside the credential, so it gets checked like code.
# The split is the whole control: `CACHE_PREPARE` runs third-party code, and a
# job with `id-token: write` hands that code the credential through
# ACTIONS_ID_TOKEN_REQUEST_TOKEN no matter what the script does afterwards.
# Every block for one job key in the doc, each ending where the job ends: the
# next key at the same indent, or the closing fence.
#
# The doc carries more than one `build:` -- the reference workflow's and the
# Windows pool's -- and the claim below is about ALL of them, so the range
# cannot simply run from `build:` to `publish:`: a `,` range in sed restarts,
# so a `build:` with no `publish:` after it printed to END OF FILE, and the
# predicate read every `id-token` in the document as being inside a build job.
# Closing on the fence alone is not enough either -- both jobs of the reference
# workflow live in ONE fenced block, so `build:` would swallow `publish:` and
# with it the credential the whole split exists to keep out of the build job.
yaml_job_block() { # <file> <key> [occurrence, default 1]
  awk -v key="  $2:" -v want="${3:-1}" '
    $0 == key { n++; if (n == want) { inb = 1; print } next }
    inb && ($0 == "```" || $0 ~ /^  [A-Za-z_][A-Za-z0-9_-]*:[ 	]*$/) { inb = 0; next }
    inb { print }
  ' "$1"
}

has_split_publishing_workflow() { # <doc>
  local build publish winbuild doc
  doc=$(cat "$1")
  # The job blocks, by their own boundaries rather than by line count.
  # The FIRST `build:` and the SECOND are both build jobs -- the reference
  # workflow's and the Windows pool's -- and the claim below is about BOTH. The
  # Windows one runs CACHE_PREPARE too, so every reason the Linux build job may
  # hold no credential applies to it unchanged; a split that holds on one
  # platform and not the other is not a split.
  build=$(yaml_job_block "$1" build 1)
  winbuild=$(yaml_job_block "$1" build 2)
  publish=$(yaml_job_block "$1" publish)
  [ -n "$build" ] && [ -n "$publish" ] && [ -n "$winbuild" ] || return 1

  matches "$build" 'CACHE_PREPARE'      || return 1
  ! matches "$build" 'id-token'         || return 1
  ! matches "$build" 'google-github-actions/auth' || return 1

  matches "$winbuild" 'CACHE_PREPARE'   || return 1
  ! matches "$winbuild" 'id-token'      || return 1
  ! matches "$winbuild" 'google-github-actions/auth' || return 1
  matches "$winbuild" 'persist-credentials: false'   || return 1
  # It hands the archive on rather than uploading it: an OUT, never an IN, and
  # never a bucket. The Windows job is the one that runs third-party install
  # code, so it is the one that must not be able to reach the bucket at all.
  matches "$winbuild" 'CACHE_ARCHIVE_OUT' || return 1
  ! matches "$winbuild" 'CACHE_BUCKET'  || return 1

  matches "$publish" 'id-token: write'  || return 1
  matches "$publish" 'CACHE_ARCHIVE_IN' || return 1
  ! matches "$publish" 'CACHE_PREPARE'  || return 1
  matches "$publish" 'needs: build'     || return 1

  # A top-level `id-token: write` would grant it to both jobs and void the split
  # without touching either one.
  matches "$(sed -n '1,/^jobs:$/p' "$1")" '^permissions: \{\}$' || return 1

  # Every action pinned by commit, this repository's own rule: the auth action
  # mints the publisher token, and a moved tag on it is root code on every host.
  ! matches "$doc" 'uses: [^ ]*@v[0-9]' || return 1
  matches "$doc" 'uses: google-github-actions/auth@[0-9a-f]{40} # v' || return 1

  # A `workflow_call` here would let a caller pass an input that reaches
  # CACHE_PREPARE while satisfying both the binding and the event guard.
  ! matches "$doc" 'workflow_call:' || return 1

  # No checkout leaves the job's GITHUB_TOKEN in `.git/config`. Counted rather
  # than matched once, because the one that matters is the BUILD job's — that
  # workspace is where CACHE_PREPARE runs third-party install code, and the
  # premise of the whole split is that this job holds nothing worth stealing.
  # Every checkout in this file gets it, so every checkout must carry the flag.
  local checkouts persists
  checkouts=$(printf '%s\n' "$doc" | grep -cE '^ *- uses: actions/checkout@')
  persists=$(printf '%s\n' "$doc" | grep -cE '^ *persist-credentials: false$')
  [ "${checkouts:-0}" -gt 0 ] && [ "$persists" = "$checkouts" ] || return 1
  matches "$build" 'persist-credentials: false' || return 1
}

# --- the real script ------------------------------------------------------------

run() { # <name> <fn> <file>
  if "$2" "$3"; then ok; else bad "$1"; fi
}

run 'cache variables point every tool at the slot cache' has_cache_env             "$SCRIPT"
run 'no shared group-writable cache tree'                has_no_shared_writable_tree "$SCRIPT"
run 'master read-only, slot copy slot-owned'             has_ownership_split       "$SCRIPT"
run 'root only ever works in a root-owned directory'     has_root_owned_namespace  "$SCRIPT"
run 'the seeded cache is writable by it and private to it' has_usable_private_slot_cache "$SCRIPT"
run 'refuses a master holding a link, node or credential' has_hostile_entry_refusal "$SCRIPT"
run 'a refusal cannot forge a log line'                  has_sanitized_refusal_logging "$SCRIPT"
run 'the master root is repaired, its contents never'    has_master_root_heal      "$SCRIPT"
run 'the image build aborts on a hostile warm cache'     has_packer_gate_that_aborts "$PACKER"
run 'the seed is published atomically'                   has_atomic_seed           "$SCRIPT"
run 'no concurrency-unsafe cache is shared'              has_no_unsafe_sharing     "$SCRIPT"
run 'a cache failure never blocks registration'          has_fail_open             "$SCRIPT"
run 'a retired slot cache is removed before seeding'     has_retired_slot_prune    "$SCRIPT"
run 'slot primary group is asserted'                     has_primary_group_assert  "$SCRIPT"
run 'the host may read its own cache prefix and nothing else' has_read_only_cache_grant "$POOLTF"
run 'the hydrate is bounded and fails open'              has_bounded_hydrate       "$SCRIPT"
run 'a snapshot is inspected before it reaches the master' has_snapshot_inspection "$SCRIPT"
run 'snapshot age comes from the service, not the name'  has_service_attested_age  "$SCRIPT"
run 'the instance token never becomes a process argument' has_token_out_of_argv   "$SCRIPT"
run 'metadata-supplied bounds are clamped on the host'   has_clamped_metadata_bounds "$SCRIPT"
run 'the pool name cannot rewrite the IAM condition'     has_constrained_pool_name "$POOLVARS"
run 'the publisher may create but never overwrite a snapshot' has_write_once_publisher "$PUBTF"
run 'only the default ref may become the publisher'      has_ref_bound_publisher   "$PUBVARS"
run 'the bucket module grants no write of its own'       has_no_write_grant_on_the_bucket "$BUCKETTF"
PAIR_OTHER="$SCANSH"
run 'a snapshot is built clean, scanned and written once' has_trusted_snapshot_build "$PUBSH"
PAIR_OTHER=""
run 'both sides agree on which tool caches travel'       has_agreeing_cache_dirs   "$PUBSH"
run 'the install never runs beside the publishing credential' has_split_publishing_workflow "$PUBDOC"
run 'every hydrate exit says which one it was'           has_observable_hydrate    "$SCRIPT"
run 'the host carries the telemetry publisher'           has_host_telemetry_wiring "$POOLTF"
run 'the publisher keeps its token out of argv too'      has_publisher_token_out_of_argv "$TELEM"

# --- the mutations --------------------------------------------------------------
#
# Each one is an edit a later change could plausibly make, and each must be
# caught. A predicate that cannot fail is not a check.

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A mutation that never applied is the failure mode this whole file exists to
# prevent, one level up: the predicate then rejects an unmutated script (or an
# empty one, if sed died) and the run reports a pass over a check that was never
# exercised. So the expression must succeed AND must change something, and both
# are asserted before the predicate is allowed to have an opinion.
mutate_file() { # <source> <name> <fn> <sed-expr>
  local f="$TMP/m.sh"
  if ! sed -E "$4" "$1" >"$f"; then
    bad "mutation expression failed: $2"
    return
  fi
  if cmp -s "$f" "$1"; then
    bad "mutation matched nothing: $2"
    return
  fi
  if "$3" "$f"; then bad "mutation not caught: $2"; else ok; fi
}

mutate() { # <name> <fn> <sed-expr>
  mutate_file "$SCRIPT" "$1" "$2" "$3"
}

# The publisher/credential-scan pair. Each wrapper mutates ONE file and names the
# other as the predicate's second input, so the pair reads as the single body of
# code it was before the extraction. Reset afterwards rather than left set: a
# stale $PAIR_OTHER would silently hand an unrelated predicate a second file.
mutate_pubsh() { # <name> <fn> <sed-expr>
  PAIR_OTHER="$SCANSH"; mutate_file "$PUBSH" "$1" "$2" "$3"; PAIR_OTHER=""
}
mutate_scansh() { # <name> <fn> <sed-expr>
  PAIR_OTHER="$PUBSH"; mutate_file "$SCANSH" "$1" "$2" "$3"; PAIR_OTHER=""
}

mutate 'pnpm store loses the v11 spelling' has_cache_env \
  's|^Environment=pnpm_config_store_dir=.*$||'
mutate 'npm cache points at the shared master' has_cache_env \
  's|^Environment=npm_config_cache=\$c/npm$|Environment=npm_config_cache=$CACHE_MASTER/npm|'
mutate 'the env block stops reaching the unit' has_cache_env \
  's|^\$CACHE_ENV$||'
mutate 'cache_env stops being per-slot' has_cache_env \
  's|CACHE_ENV=\$\(cache_env "\$idx"\)|CACHE_ENV=$(cache_env)|'

# The repair, mutated four ways — each one an edit that reads like a small
# improvement and turns the hostility scan into a laundering step.
mutate 'the root repair goes recursive' has_master_root_heal \
  's@  chmod 0755 "\$CACHE_MASTER"@  chmod -R 0755 "$CACHE_MASTER"@'
mutate 'the root repair takes ownership recursively' has_master_root_heal \
  's@  chown -h root:root "\$CACHE_MASTER"@  chown -Rh root:root "$CACHE_MASTER"@'
mutate 'the root repair goes back to go-w, which leaves setgid set' has_master_root_heal \
  's@  chmod 0755 "\$CACHE_MASTER"@  chmod go-w "$CACHE_MASTER"@'
mutate 'the root repair follows a symlink off the tree' has_master_root_heal \
  's@  if \[ -L "\$CACHE_MASTER" \]; then@  if false; then@'
# And the ordering: a repair after the scan is a repair that never runs.
mutate 'the repair moves after the scan that refuses' has_master_root_heal \
  's@^  heal_cache_master_root$@@'

mutate 'the shared group-writable tree returns' has_no_shared_writable_tree \
  's|chmod -R go-w,go\+rX "\$CACHE_MASTER"|chmod 2775 "$CACHE_MASTER"|'
mutate 'a group-write umask returns to the agent' has_no_shared_writable_tree \
  's|^\$BROKER_ENV$|UMask=0002\n$BROKER_ENV|'
mutate 'seeding goes back to sharing inodes' has_no_shared_writable_tree \
  's|cp -a --no-preserve=ownership|cp -al|'
mutate 'a shared supplementary group comes back' has_no_shared_writable_tree \
  's|^(\s*)useradd -m --user-group|\1usermod -aG ci "$u"\n\1useradd -m --user-group|'

mutate 'the master is left writable' has_ownership_split \
  's|chmod -R go-w,go\+rX "\$CACHE_MASTER"|true "$CACHE_MASTER"|'
mutate 'the seeded copy keeps root ownership' has_ownership_split \
  's|chown -R "\$u:\$u"|chown -R root:root|'
mutate 'one slot can read another slot cache' has_ownership_split \
  's@-m 0700 "\$dst/\$d"@-m 0755 "$dst/$d"@'

# The escalation the reviewer found: root's work area handed to the slot, which
# puts every mkdir, mv and chown below into a namespace the slot can race.
mutate 'the slot owns root work area again' has_root_owned_namespace \
  's@^  chown root:"\$u" "\$dst"@  chown "$u:$u" "$dst"@'
mutate 'the tool directory chown comes back' has_root_owned_namespace \
  's@install -d -o "\$u" -g "\$u" -m 0700 "\$dst/\$d"@mkdir -p "$dst/$d" \&\& chown "$u:$u" "$dst/$d"@'
mutate 'the slot parent is left unowned' has_root_owned_namespace \
  's@^  chown root:root "\$CACHE_SLOTS".*$@@'

# The shapes of "the isolation is asserted but not implemented". The first is the
# one that survived two review passes: every comment, the README and a predicate
# all said 0700 meant one slot could not read another's cache, while the only
# directory carrying that 0700 was one the slot owned and could chmod at will.
mutate 'the slot work area is world-traversable again' has_usable_private_slot_cache \
  's@^  chmod 0710 "\$dst"@  chmod 0755 "$dst"@'
mutate 'the staging chmod moves after the chown' has_usable_private_slot_cache \
  's@^\s*find "\$dst/\.seed-\$d" -type d -exec chmod u\+rwx.*$@@; s@^(\s*)(chown -R "\$u:\$u" "\$dst/\.seed-\$d".*)$@\1\2\n\1find "$dst/.seed-$d" -type d -exec chmod u+rwx {} + 2>/dev/null || true@'
mutate 'the seed is published wide and narrowed later' has_usable_private_slot_cache \
  's@^(\s*)chmod 0700 "\$dst/\.seed-\$d".*$@@'
mutate 'the seal strips the owner write bit again' has_usable_private_slot_cache \
  's@chmod -R go-w,go\+rX@chmod -R a-w,a+rX@'
mutate 'the seeded directories are left unwritable' has_usable_private_slot_cache \
  's@^(\s*)find "\$dst/\.seed-\$d" -type d -exec chmod u\+rwx.*$@@'
mutate 'the 0700 goes back on the cold path only' has_usable_private_slot_cache \
  's@^(\s*)chmod 0700 "\$dst/\$d"@\1[ -d "$dst/$d" ] || chmod 0700 "$dst/$d"@'

mutate 'the hostile-entry scan is dropped' has_hostile_entry_refusal \
  's@^  bad=\$\(cache_scan "\$limit" find "\$root" \\$@  bad=@'
mutate 'the scan stops looking for smuggled hardlinks' has_hostile_entry_refusal \
  's@^  ino=\$\(cache_scan "\$limit" find "\$root" -type f -links \+1 -printf@  ino=$(: @'
# The counting comparison IS the check. Flip it to `<=` and every inode reports
# as reaching outside; flip it to `>` and none ever does. The second is the one
# that matters, because it is silent.
mutate 'the hardlink comparison can never fire' has_hostile_entry_refusal \
  's@if \(c\[i\] < n\[i\]\)@if (c[i] > n[i])@'
# The blunt predicate coming BACK is a regression too — it re-blocks every
# legitimate internal store, which is what took pools cold before.
mutate 'the blunt hardlink predicate returns' has_hostile_entry_refusal \
  's@-type l -o -type b@-type f -a -links +1 -o -type l -o -type b@'
mutate 'file capabilities stop being scanned' has_hostile_entry_refusal \
  's@getcap -r "\$root"@true "$root"@'
mutate 'the scan is hard-wired back to the master' has_hostile_entry_refusal \
  's@^  local bad ino root="\$\{1:-\$CACHE_MASTER\}" limit=0$@  local bad@'
mutate 'credentials stop being scanned' has_hostile_entry_refusal \
  "s@name '\\.npmrc'@name '.nothing'@"
# Unbounded, the credential pass reads inside extracted package payloads and one
# dependency's test fixture takes the whole fleet cold. The bound is not tidiness.
mutate 'the credential pass loses its depth bound' has_hostile_entry_refusal \
  's@-maxdepth 3 -type f@-type f@'
mutate 'the widened credential names are dropped' has_hostile_entry_refusal \
  "s@-o -name '\\*\\.pem' @@"

mutate 'refusals interpolate the raw path again' has_sanitized_refusal_logging \
  's@\$\(safe_for_log "\$bad"\)@$bad@g'
mutate 'the sanitizer stops stripping control characters' has_sanitized_refusal_logging \
  "s@tr -d '\\\\000-\\\\037'@cat@"
mutate 'the sanitizer stops bounding length' has_sanitized_refusal_logging \
  "s@printf '%\\.300s'@printf '%s'@"
mutate 'the scan skips other filesystems again' has_hostile_entry_refusal \
  's@^  bad=\$\(cache_scan "\$limit" find "\$root" \\$@  bad=$(cache_scan "$limit" find "$root" -xdev \\@'

mutate 'a torn seed becomes visible' has_atomic_seed \
  's|"\$dst/\.seed-\$d"|"$dst/$d"|g'

mutate 'GOCACHE is shared'          has_no_unsafe_sharing 's|^Environment=GOMODCACHE=.*$|Environment=GOCACHE=$c/go-build|'
mutate 'the tool cache is shared'   has_no_unsafe_sharing 's|^Environment=UV_CACHE_DIR=.*$|Environment=RUNNER_TOOL_CACHE=$c/tools|'
mutate '-modcacherw comes back'     has_no_unsafe_sharing 's|^Environment=GOMODCACHE=(.*)$|Environment=GOMODCACHE=\1\nEnvironment=GOFLAGS=-modcacherw|'

mutate 'a cache failure blocks registration' has_fail_open \
  's|provision_shared_cache \|\| true|provision_shared_cache \|\| die "no cache"|'
mutate 'cache_env trusts the directory, not the marker' has_fail_open \
  's@\[ -f "\$c/\.ready" \] \|\| return 0@[ -d "$c" ] || return 0@'
mutate 'the ready marker is never written' has_fail_open \
  's@^  : >"\$dst/\.ready".*$@  true@'
mutate 'a stale ready marker survives a reseed' has_fail_open \
  's@^  rm -f "\$dst/\.ready"$@@'

# The retired-slot sweep, in the four shapes that read as correct. The ordering
# the predicate pins is not mutated here because sed cannot move a loop past
# another one, but it is the defect that matters most: a sweep placed AFTER the
# seeding loop deletes what the run has just built, and looks identical in a
# diff. The last mutation below is its cheap cousin — a sweep aimed at a name
# that never matches, which reads as present and does nothing.
mutate 'the retired slot sweep is dropped' has_retired_slot_prune \
  's@^  for d in "\$CACHE_SLOTS"/\*; do$@  for d in; do@'
mutate 'the sweep deletes the live slots too' has_retired_slot_prune \
  's@^    \[ "\$idx" -gt "\$SLOTS" \] \|\| continue$@@'
mutate 'the sweep stops checking the name is a slot index' has_retired_slot_prune \
  's@^    case "\$idx" in .*esac$@@'
mutate 'a failed removal is reported as a success' has_retired_slot_prune \
  's@^    if rm -rf "\$d"; then$@    if rm -rf "$d" || true; then@'
mutate 'the sweep is aimed at a name that never exists' has_retired_slot_prune \
  's@^  for d in "\$CACHE_SLOTS"/\*; do$@  for d in "$CACHE_SLOTS"/.none; do@'

# The metadata rc classification: every one of these turns a transient metadata
# failure into "not-configured", which is the verdict that means "nothing to do"
# and therefore the one nothing alerts on.
mutate 'the metadata exit code is thrown away' has_observable_hydrate \
  's@^  CACHE_BUCKET=\$\(md "instance/attributes/ci-cache-bucket"\) \|\| bucket_rc=\$\?$@  CACHE_BUCKET=$(md "instance/attributes/ci-cache-bucket") || true@'
mutate 'any metadata failure means not-configured' has_observable_hydrate \
  's@^    if \[ "\$bucket_rc" = 22 \] \|\| \[ "\$bucket_rc" = 0 \]; then$@    if true; then@'
mutate 'the second metadata probe comes back' has_observable_hydrate \
  's@^    if \[ "\$bucket_rc" = 22 \] \|\| \[ "\$bucket_rc" = 0 \]; then$@    if [ -n "$(md "instance/id")" ]; then@'

mutate 'the primary-group assertion is dropped' has_primary_group_assert \
  's|\[ "\$\(id -gn "\$u"\)" = "\$u" \]|true|'

# The Packer gate, mutated in its own file. The first of these is the exact
# revision the reviewer rejected: a guard that reads correctly and cannot fail.
mutate_file "$PACKER" 'the image gate becomes an inverted pipeline' has_packer_gate_that_aborts \
  's@^      "bad=\$\(find /opt/ci-cache.*$@      "! find /opt/ci-cache \\\\( -type l \\\\) -print -quit | grep -q .",@'
mutate_file "$PACKER" 'the image gate loses pipefail' has_packer_gate_that_aborts \
  's@set -euxo pipefail@set -eux@'
mutate_file "$PACKER" 'the image ships the cache group-writable' has_packer_gate_that_aborts \
  's@^      "chown -Rh root:root /opt/ci-cache",$@      "chgrp -R ci /opt/ci-cache",@'
mutate_file "$PACKER" 'the image bakes a cache no slot can write' has_packer_gate_that_aborts \
  's@chmod -R go-w,go\+rX /opt/ci-cache@chmod -R a-w,a+rX /opt/ci-cache@'
# `..n` and not `.n`: inside the HCL string the newline is written `\\n`.
mutate_file "$PACKER" 'the image gate refusal names the path but not the reason' has_packer_gate_that_aborts \
  "s@-printf '%y %M %p..n' -quit@-print -quit@"

# The snapshot layer. The first two are the exact edits that would turn a host
# into a publisher, which is the whole thing this design exists to prevent.
mutate_file "$POOLTF" 'the host grant becomes writable' has_read_only_cache_grant \
  's@roles/storage\.objectViewer@roles/storage.objectUser@'
mutate_file "$POOLTF" 'the grant stops being conditioned on the prefix' has_read_only_cache_grant \
  's@^    expression  = "resource\.name\.startsWith.*$@    expression  = "true"@'
mutate_file "$POOLTF" 'the prefix is written twice instead of once' has_read_only_cache_grant \
  's@^  cache_prefix = "cache/\$\{var\.name\}/"$@  cache_prefix = "cache/${var.github_repo}/"@'

mutate 'the hydrate stops being bounded' has_bounded_hydrate \
  's@timeout "\$left" gzip@gzip@'
mutate 'a spent budget becomes a parse error' has_bounded_hydrate \
  's@^  \[ "\$left" -gt 0 \] \|\| left=1$@  true@'
mutate 'a cache fetch ignores the remaining budget' has_bounded_hydrate \
  's@^  \[ "\$3" -gt 0 \] \|\| return 1$@  true@'
mutate 'a slow snapshot blocks registration' has_bounded_hydrate \
  's@hydrate_shared_cache \|\| true@hydrate_shared_cache \|\| die "no snapshot"@'

mutate 'a snapshot reaches the master unscanned' has_snapshot_inspection \
  's@^  if cache_master_is_hostile "\$CACHE_STAGE" strict; then@  if false; then@'
mutate 'a snapshot is unpacked straight into the master' has_snapshot_inspection \
  's@^CACHE_STAGE="/opt/\.ci-cache-incoming"$@CACHE_STAGE="/opt/ci-cache/.incoming"@'
mutate 'the archive decides its own ownership and modes' has_snapshot_inspection \
  's@ --no-same-owner --no-same-permissions@@'
mutate 'the archive may carry a capability in an xattr' has_snapshot_inspection \
  's@ --no-xattrs --no-acls@@'
mutate 'tar is allowed out of the staging tree' has_snapshot_inspection \
  's@\| tar -x -C "\$CACHE_STAGE"@| tar -x -P -C "$CACHE_STAGE"@'
mutate 'the snapshot inspection escapes the deadline' has_snapshot_inspection \
  's@cache_scan "\$limit" getcap@getcap@'
mutate 'the refusal names the path but not the reason' has_snapshot_inspection \
  "s@-printf '%y %M %p.n' -quit@-print -quit@"
mutate 'the snapshot scan stops being strict' has_snapshot_inspection \
  's@cache_master_is_hostile "\$CACHE_STAGE" strict@cache_master_is_hostile "$CACHE_STAGE"@'
mutate 'an unscannable snapshot is logged rather than refused' has_snapshot_inspection \
  's@^  elif \[ "\$\{2:-\}" = "strict" \]; then$@  elif false; then@'
mutate 'the decompressed stream stops being bounded' has_snapshot_inspection \
  's@\| head -c "\$bound"@| cat@'
# The floor. Without it a valid archive of a small tree is cut by `head` -- and
# tar does not object, because the cut lands at a member boundary and the record's
# zero padding reads as an end-of-archive marker. The host hydrates four of nine
# directories and calls it a hit. That is issue #191 exactly.
mutate 'the expansion bound loses its floor on the host' has_snapshot_inspection \
  's@^  \[ "\$bound" -ge "\$CACHE_EXPAND_FLOOR_BYTES" \] \|\| bound=\$CACHE_EXPAND_FLOOR_BYTES$@  :@'
mutate 'the host floors the bound at nothing' has_snapshot_inspection \
  's@^CACHE_EXPAND_FLOOR_BYTES=65536$@CACHE_EXPAND_FLOOR_BYTES=0@'
# Reserve less than the unpack may write and the host fills its own boot disk
# warming a cache -- the one outcome the reservation exists to prevent.
mutate 'the free-space check reserves the unfloored product' has_snapshot_inspection \
  's@^  if \[ -z "\$\{free_kb:-\}" \] \|\| \[ "\$\(\(free_kb \* 1024\)\)" -lt "\$bound" \]; then$@  if [ -z "${free_kb:-}" ] || [ "$((free_kb * 1024))" -lt "$((size * 8))" ]; then@'
# The count is what makes the bound a bound; tar's silence is not agreement.
mutate 'the host stops counting what it decompressed' has_snapshot_inspection \
  's@^  if \[ "\$expanded" -gt "\$bound" \]; then$@  if false; then@'
mutate 'the count is removed from the hydrate altogether' has_snapshot_inspection \
  '/^  local expanded count_rc$/,/^  fi$/d'
mutate 'a partial hydrate stops having a verdict of its own' has_snapshot_inspection \
  's@CACHE_VERDICT="too-big-expanded"@CACHE_VERDICT="unpack-timeout"@'
mutate 'the count itself becomes unbounded' has_snapshot_inspection \
  's@\| head -c "\$\(\(bound \+ 1\)\)" \| wc -c \)@| wc -c )@'
# A 124 read as success is an UNMEASURED archive presented as a small one: the
# extraction below then gets a fresh one-second floor, and tar takes a prefix
# ending at a member boundary without complaint. That is the partial hydrate
# this count exists to prevent, reached through the count.
mutate 'the counting pass swallows its own exit code again' has_snapshot_inspection \
  's@; echo "\$\?" >"\$tmp/count\.rc"; \}@ || true; }@'
mutate 'a timed-out measurement is read as a small archive' has_snapshot_inspection \
  's@^  if \[ "\$\{count_rc:-\}" != 0 \]; then$@  if false; then@'
mutate 'a timeout and a corrupt stream stop being told apart' has_snapshot_inspection \
  's@^      124 \| 137 \)$@      zzz )@'
mutate 'the recorded status is never read back' has_snapshot_inspection \
  's@^  count_rc=\$\(tr -dc 0-9 <"\$tmp/count\.rc" 2>/dev/null\) \|\| count_rc=..$@  count_rc=0@'
mutate 'the pointer stops being whitelisted' has_snapshot_inspection \
  's@^    \*\[!A-Za-z0-9\._-\]\* \| .. \| \.\* \)$@    nothing-at-all )@'
mutate 'the hydrate runs after the master is locked' has_snapshot_inspection \
  's@^  hydrate_shared_cache \|\| true$@@; s@^  provision_shared_cache \|\| true$@  provision_shared_cache \|\| true\n  hydrate_shared_cache \|\| true@'

mutate 'snapshot age comes from the object name again' has_service_attested_age \
  's@\?fields=timeCreated,size@?fields=size@'
mutate 'the host-side age bound is dropped' has_service_attested_age \
  's@\[ "\$age" -ge "\$max_age_hours" \]@[ "$age" -lt 0 ]@'
mutate 'a snapshot may fill the boot disk' has_service_attested_age \
  's@^  free_kb=\$\(df -Pk /opt.*$@  free_kb=999999999999@'
mutate 'the generation stops being pinned to what was measured' has_service_attested_age \
  's@\?alt=media&generation=\$gen@?alt=media@'

mutate 'the token goes back into the curl arguments' has_token_out_of_argv \
  's@^    -K <\(printf .*$@    -H "Authorization: Bearer $CACHE_TOKEN" \\@'
mutate 'the token outlives the hydrate' has_token_out_of_argv \
  's@^  unset CACHE_TOKEN @  unset @'
mutate 'a response is bounded only by the deadline' has_token_out_of_argv \
  's@--max-filesize "\$\{5:-65536\}"@--silent@'

mutate 'the host stops clamping a metadata-supplied budget' has_clamped_metadata_bounds \
  's@^  \[ "\$budget" -le 300 \] \|\| budget=300$@  true@'
mutate 'the age bound may be set past the bucket rule' has_clamped_metadata_bounds \
  's@^  \[ "\$max_age_hours" -le 720 \].*$@  true@'

mutate_file "$POOLVARS" 'the pool name stops being constrained' has_constrained_pool_name \
  's@\^\[a-z\]\(\[-a-z0-9\]\{0,61\}\[a-z0-9\]\)\?\$@.*@'
mutate_file "$POOLVARS" 'the bucket name stops being constrained' has_constrained_pool_name \
  's@can\(regex\("\^\[a-z0-9\].*", var\.cache_snapshot_bucket\)\)@true@'

# The write side. The first two are the edits that turn the publisher back into
# something a pull request can be.
mutate_file "$PUBTF" 'the publisher may overwrite a snapshot' has_write_once_publisher \
  's@role   = "roles/storage\.objectCreator"@role   = "roles/storage.objectUser"@'
mutate_file "$PUBTF" 'the pointer grant widens to the whole prefix' has_write_once_publisher \
  's@== \\"\$\{local\.pointer_resource\}@.startsWith(\\"${local.prefix_resource}@'
# `|` rather than `@` as the delimiter here: the principalSet itself contains an
# `@`, between the workflow path and the ref.
mutate_file "$PUBTF" 'the whole repository may become the publisher' has_write_once_publisher \
  's|attribute\.job_workflow_ref/\$\{var\.repository\}/\$\{var\.publish_workflow_path\}@\$\{var\.allowed_ref\}|attribute.repository/${var.repository}|'
mutate_file "$PUBTF" 'the binding drops back to a bare ref' has_write_once_publisher \
  's|attribute\.job_workflow_ref/\$\{var\.repository\}/\$\{var\.publish_workflow_path\}@|attribute.ref/|'
mutate_file "$PUBTF" 'the workflow file stops being pinned' has_write_once_publisher \
  's|/\$\{var\.publish_workflow_path\}||'
mutate_file "$PUBTF" 'a create grant stops being conditioned on the prefix' has_write_once_publisher \
  's@expression  = "resource\.name\.startsWith\(\\"\$\{local\.prefix_resource\}\\"\)"@expression  = "true"@'
mutate_file "$PUBTF" 'the publisher gets a downloadable key' has_write_once_publisher \
  's@^resource "google_service_account_iam_member"@resource "google_service_account_key" "k" \{ service_account_id = google_service_account.publisher.name \}\nresource "google_service_account_iam_member"@'

mutate_file "$PUBVARS" 'a tag may hold the write grant' has_ref_bound_publisher \
  's@\^refs/heads/@^refs/@'
mutate_file "$PUBVARS" 'the default ref becomes a pull-request ref' has_ref_bound_publisher \
  's@default     = "refs/heads/main"@default     = "refs/pull/1/merge"@'
mutate_file "$PUBVARS" 'the repository stops being validated' has_ref_bound_publisher \
  's@, var\.repository\)@, var.name)@'
mutate_file "$PUBVARS" 'the workflow path may point anywhere' has_ref_bound_publisher \
  's@\^\\\\\.github/workflows/@^@'

mutate_file "$BUCKETTF" 'a bucket-wide write grant is added as a stopgap' has_no_write_grant_on_the_bucket \
  's@^resource "google_storage_bucket" "cache" \{@resource "google_storage_bucket_iam_member" "stopgap" \{ role = "roles/storage.objectAdmin" \}\nresource "google_storage_bucket" "cache" \{@'
mutate_file "$BUCKETTF" 'ACLs come back and route around the prefix conditions' has_no_write_grant_on_the_bucket \
  's@^  uniform_bucket_level_access = true$@  uniform_bucket_level_access = false@'

# The publishing script. Each of these is an edit that leaves a working script —
# it still builds something and still uploads it — and changes what "trusted"
# means. None of them would fail a run.
mutate_pubsh 'the publisher refusal names the path but not the reason' has_trusted_snapshot_build \
  "s@-printf '%y %M %p.n' -quit@-print -quit@"
mutate_pubsh 'the snapshot is packed from a host cache instead' has_trusted_snapshot_build \
  's@^STAGE=\$\(mktemp -d\)$@STAGE=/opt/ci-cache@'
mutate_pubsh 'pnpm loses the v11 spelling on the publishing side' has_trusted_snapshot_build \
  's@^ *export pnpm_config_store_dir=.*$@@'
mutate_pubsh 'the event guard opens to every event' has_trusted_snapshot_build \
  "s@^  '' \| schedule \| workflow_dispatch \| push \) : ;;\$@  * ) : ;;@"
mutate_pubsh 'a missing getcap becomes a skipped scan' has_trusted_snapshot_build \
  's@^command -v getcap.*$@if command -v getcap >/dev/null 2>\&1; then :; fi@'
mutate_pubsh 'setuid entries stop being scanned for' has_trusted_snapshot_build \
  's@-o -perm /6000 @@'
mutate_pubsh 'a hardlink may be packed as a link member' has_trusted_snapshot_build \
  's@ --hard-dereference@@'
mutate_pubsh 'the shipped bytes stop being inspected' has_trusted_snapshot_build \
  's@^archive_is_flat "\$ARCHIVE"$@@'
mutate_scansh 'the embedded-credential pass is dropped' has_trusted_snapshot_build \
  's@^  "registry-auth-token\|.*_authToken.*$@@'
# Widening it back is not the same failure as dropping it, and it is the quieter
# one: the scan still fires, the suite still passes its own token cases, and what
# breaks is a real tree months later, on a rule that cannot be allowlisted past.
# Three ways to widen, because this rule has been widened wrongly twice: back to
# a bare substring, back to a word with no assignment after it, and back to a
# left class that lets `._authToken =` through. Each of the last two is a real
# package — googleapis and neo4j-driver — and each would take the publish job
# permanently red with no allowlist entry able to clear it.
mutate_scansh 'the token rule matches the tail of a longer word again' has_trusted_snapshot_build \
  's@^  "registry-auth-token\|.*_authToken.*$@  "registry-auth-token|_authToken"@'
mutate_scansh 'the token rule stops requiring an assignment' has_trusted_snapshot_build \
  's@_authToken\(\[\[:space:\].*\)"$@_authToken"@'
mutate_scansh 'the token rule matches a property access again' has_trusted_snapshot_build \
  's@\[\^A-Za-z0-9\.\\\$\]@[^A-Za-z0-9]@'
# Dropping either locale pin re-opens the boundary as a hole rather than closing
# it. Two mutations, not one: the two greps answer different questions — which
# labels a file trips, and which files are looked at at all — and a suite that
# only pins one of them accepts a script where they disagree.
mutate_scansh 'the per-file credential grep loses its byte locale' has_trusted_snapshot_build \
  's@^    LC_ALL=C grep -qa -E -e @    grep -qa -E -e @'
mutate_scansh 'the tree-wide credential grep loses its byte locale' has_trusted_snapshot_build \
  's@^  LC_ALL=C grep -rlaZ -E @  grep -rlaZ -E @'
# The reporter's greps decide nothing, so dropping their pin is not a bypass —
# it is a file the gate refuses and then cannot name a rule for, which reads as
# a false positive and gets the rule deleted. Caught by the closed allow-list of
# forms allowed to touch "$file", which now carries the prefix.
mutate_scansh 'the credential reporter loses its byte locale' has_trusted_snapshot_build \
  's@^      n=\$\(LC_ALL=C grep -ca @      n=$(grep -ca @'
# A refusal that names only a content-addressed hash file cannot be told from a
# false positive without reproducing the whole install, and the predictable
# response to a gate nobody can read is deleting it.
mutate_scansh 'the credential refusal stops saying what it caught' has_trusted_snapshot_build \
  's@^    explain_credential_hit "\$root" "\$bad"$@@'
# The allowlist is the one place this script excuses a scan hit, so each of its
# bounds gets a mutation. Every one of these leaves a script that still builds,
# still scans and still publishes.
mutate_scansh 'an allowlist entry may be a digest PREFIX' has_trusted_snapshot_build \
  's@^  \[ "\$\{#d\}" = 64 \] \\$@  true \\@'
# The file's rules. Each mutation leaves a script that still parses a list and
# still publishes — the loss is only that nobody can tell what was excused.
mutate_scansh 'a digest in the file needs no package name beside it' has_trusted_snapshot_build \
  's@^    \[ "\$scan_allow_digest" != "\$scan_allow_line" \] \\$@    true \\@'
mutate_scansh 'a bare `#` counts as naming the package' has_trusted_snapshot_build \
  's@^    \[ -n "\$scan_allow_name" \] \\$@    true \\@'
mutate_scansh 'an allowlist file that is not there excuses nothing, quietly' has_trusted_snapshot_build \
  's@^  \[ -f "\$CACHE_SCAN_ALLOW_FILE" \] \\$@  true \\@'
mutate_scansh 'a file of nothing but comments passes for an allowlist' has_trusted_snapshot_build \
  's@^  \[ "\$scan_allow_count" -gt 0 \] \\$@  true \\@'
mutate_scansh 'an indented entry is eaten as a comment' has_trusted_snapshot_build \
  's@^      .. \| .#.\* \) continue ;;$@      "" | *"#"* ) continue ;;@'
mutate_scansh 'the excusal no longer says where the exception came from' has_trusted_snapshot_build \
  's@, excused by \$SCAN_ALLOW_MATCHED_WHERE"@ is on CACHE_SCAN_ALLOW_DIGESTS"@'
mutate_scansh 'the file skips its own validator' has_trusted_snapshot_build \
  's@^    scan_allow_add "\$scan_allow_digest" "\$scan_allow_where"$@    SCAN_ALLOW_DIGESTS+=("$scan_allow_digest"); SCAN_ALLOW_WHERE+=("$scan_allow_where")@'
mutate_scansh 'an excused file is excused silently' has_trusted_snapshot_build \
  's@^          log "the content scan excused @          : "@'
mutate_scansh 'the content pass stops at the first hit again' has_trusted_snapshot_build \
  's@^  done <"\$hits"$@  done < <(head -n1 "$hits")@'
# The prepare command runs first, as this uid, and is told where the temp root
# is. A fixed name for the hit list is a symlink to /dev/null away from turning
# the only pass that sees an embedded credential into a no-op.
mutate_scansh 'the hit list gets a name the install can guess' has_trusted_snapshot_build \
  's@^  hits=\$\(mktemp "\$SCAN_TMPDIR/hits\.XXXXXX"\).*$@  hits="$SCAN_TMPDIR/content-hits"@'
mutate_scansh 'a hit list that vanished reads as a clean tree' has_trusted_snapshot_build \
  's@^    || die "the content scan found matches it could not then read.*$@    || true@'
# A newline is a legal filename byte. Either half of the NUL pair reverted puts
# the parser back where a planted name can split one record into two.
mutate_scansh 'the hit list goes back to newline-separated' has_trusted_snapshot_build \
  's@grep -rlaZ -E@grep -rla -E@'
# One NUL byte is all `-I` needs to classify a file as binary and skip it, which
# turns the only pass that reads file CONTENT into a no-op for that file.
mutate_scansh 'a leading NUL byte opts a file out of the content pass' has_trusted_snapshot_build \
  's@grep -rlaZ -E@grep -rlIZ -E@'
mutate_scansh 'the hit-list reader goes back to reading lines' has_trusted_snapshot_build \
  "s@while IFS= read -r -d '' bad; do@while IFS= read -r bad; do@"
# The same guessable-name argument, for the three other files this script writes
# into the directory the prepare command can find.
mutate_pubsh 'the archive listing gets a name the install can guess' has_trusted_snapshot_build \
  's@^  list=\$\(mktemp "\$ARCHIVE_DIR/listing\.XXXXXX"\).*$@  list="$ARCHIVE_DIR/listing"@'
# Back to creating the archive before the install runs: the file is then there,
# listable, and writable by anything the prepare command left behind.
mutate_pubsh 'the archive exists before the install does' has_trusted_snapshot_build \
  's@^ARCHIVE=""$@ARCHIVE=$(mktemp "$ARCHIVE_DIR/snap.XXXXXX.tar.gz")@'
mutate_pubsh 'the pointer body gets a name the install can guess' has_trusted_snapshot_build \
  's@^pointer_body=\$\(mktemp "\$ARCHIVE_DIR/current\.XXXXXX"\).*$@pointer_body="$ARCHIVE_DIR/current"@'
# A shorter label list is what makes a file equal `private-key-header`, so an
# early exit from the labeller is an excusal for a file holding a real token.
mutate_scansh 'the labeller stops at the first rule it matches' has_trusted_snapshot_build \
  's@out="\$out \$\{entry%%\|\*\}"; fi@out="$out ${entry%%|*}"; break; fi@'
mutate_scansh 'a grep error in the labeller reads as no match' has_trusted_snapshot_build \
  's@^    \[ "\$rc" -le 1 \] \\$@    true \\@'
# The digest is an oracle for anything whose preimage is small, and one of these
# rules matches a HEADER while another matches a 40-byte connection string — the
# size floor is what keeps both out of the log and off the allowlist.
mutate_scansh 'a tiny credential file becomes excusable and gets its digest printed' has_trusted_snapshot_build \
  's@^SCAN_EXCUSABLE_MIN_BYTES=1024$@SCAN_EXCUSABLE_MIN_BYTES=0@'
mutate_scansh 'the allowlist drops everything after the first newline' has_trusted_snapshot_build \
  "s@read -rd '' -a SCAN_ALLOW_RAW@read -ra SCAN_ALLOW_RAW@"
# The off switch. One legitimate entry would excuse every content hit there is,
# and the run would still look exactly like a successful publish.
mutate_scansh 'the allowlist matches every digest' has_trusted_snapshot_build \
  's@^    if \[ "\$d" = "\$1" \]; then$@    if true; then@'
mutate_scansh 'a digest matches as a prefix at compare time' has_trusted_snapshot_build \
  's@^    if \[ "\$d" = "\$1" \]; then$@    if case "$1" in "$d"*) true ;; *) false ;; esac; then@'
mutate_scansh 'an allowlist entry need not be hex' has_trusted_snapshot_build \
  's@\*\[!0-9a-fA-F\]\*@*[!-~]*@'
mutate_scansh 'an allowlist that cannot be evaluated is ignored' has_trusted_snapshot_build \
  's@^    || die "CACHE_SCAN_ALLOW_DIGESTS is set but sha256sum.*$@    || true@'
# The rule that keeps a registry token unexcusable. Without it a digest excuses
# an `_authToken` line, and the refusal prints the sha256 of a nearly-known
# plaintext into a public log while it is at it.
mutate_scansh 'every credential shape becomes excusable by digest' has_trusted_snapshot_build \
  's@^      if scan_hit_is_excusable "\$bad"; then$@      if true; then@'
mutate_scansh 'the refusal prints a digest for every rule' has_trusted_snapshot_build \
  's@^    elif scan_hit_digest_is_printable "\$file"; then$@    elif true; then@'
# The two questions fused back into one. This is the shape the first attempt at
# this change had, and it prints a sha256 for a file that is a published README
# with one credential substituted into it.
mutate_scansh 'the log prints a digest for anything a list could excuse' has_trusted_snapshot_build \
  's@^    elif scan_hit_digest_is_printable "\$file"; then$@    elif scan_hit_is_excusable "$file"; then@'
mutate_scansh 'the URL class becomes printable too' has_trusted_snapshot_build \
  "s@^SCAN_PRINTABLE_LABELS='private-key-header'\$@SCAN_PRINTABLE_LABELS='private-key-header url-embedded-basic-auth'@"
# The whitelist walk in the printable set. Inverted, the ONE rule that must never
# be printed is the only one that is.
mutate_scansh 'the printable set is read as a blocklist' has_trusted_snapshot_build \
  's@^      \*" \$label "\* \) ;;$@      *" $label "* ) return 1 ;;@'
mutate_scansh 'a label nobody listed is printable by default' has_trusted_snapshot_build \
  's@^      \* \) return 1 ;;$@      * ) ;;@'
# The floor table. A label with no number must be unexcusable, not free.
mutate_scansh 'a label nobody gave a floor is excusable by default' has_trusted_snapshot_build \
  's@^    \* \) return 1 ;;$@    * ) printf 0 ;;@'
mutate_scansh 'the URL class loses its floor' has_trusted_snapshot_build \
  "s@^    url-embedded-basic-auth \\) printf '%s' \"\\\$SCAN_EXCUSABLE_MIN_BYTES\" ;;\$@    url-embedded-basic-auth ) printf '0' ;;@"
# Where a digest was written. The variable enforces nothing but hex, so dropping
# the source check hands the class most likely to be a live credential back to a
# route no reviewer can read.
mutate_scansh 'any route may excuse a URL credential again' has_trusted_snapshot_build \
  's@ && scan_excusal_source_is_allowed "\$labels"@@'
mutate_scansh 'the file-only table is emptied' has_trusted_snapshot_build \
  "s@^SCAN_FILE_ONLY_LABELS='url-embedded-basic-auth'\$@SCAN_FILE_ONLY_LABELS=''@"
mutate_scansh 'the variable counts as the file' has_trusted_snapshot_build \
  's@^      "CACHE_SCAN_ALLOW_FILE"\* \) ;;$@      "CACHE_SCAN_ALLOW"* ) ;;@'
# The confirmation stage. Each of these is a way the 22 churning source files
# come back, or a way a real key stops being confirmed and walks out.
mutate_scansh 'the key header is refused unconfirmed again' has_trusted_snapshot_build \
  's@^    if \[ "\$labels" = private-key-header \] && ! scan_file_holds_pem_block "\$bad"; then$@    if false; then@'
mutate_scansh 'a header with no body counts as a key' has_trusted_snapshot_build \
  's@^      if \(body > 0\) found = 1$@      found = 1@'
mutate_scansh 'an encrypted key loses its header lines' has_trusted_snapshot_build \
  's@^    inblock && /\^\[\[:space:\]\]\*\[A-Za-z\]\[A-Za-z0-9-\]\*:/ \{ next \}$@    inblock \&\& /^ZZZNEVER:/ { next }@'
mutate_scansh 'an encrypted key loses its blank line' has_trusted_snapshot_build \
  's@^    inblock && /\^\[\[:space:\]\]\*\$/ \{ next \}$@    inblock \&\& /^ZZZNEVER$/ { next }@'
# The indented shapes. An anchored body expression is what shipped, so both the
# header rule and the body rule get a mutation that puts the anchor back.
mutate_scansh 'the body must start in column zero again' has_trusted_snapshot_build \
  's@^    inblock && /\^\[\[:space:\]\]\*\[A-Za-z0-9\+\\/=\]\+\[\[:space:\]\]\*\$/ \{ body\+\+; next \}$@    inblock \&\& /^[A-Za-z0-9+\\/=]+[[:space:]]*$/ { body++; next }@'
mutate_scansh 'an indented header line stops being a header line' has_trusted_snapshot_build \
  's@^    inblock && /\^\[\[:space:\]\]\*\[A-Za-z\]\[A-Za-z0-9-\]\*:/ \{ next \}$@    inblock \&\& /^[A-Za-z][A-Za-z0-9-]*:/ { next }@'
mutate_scansh 'the confirmation reads bytes as text' has_trusted_snapshot_build \
  's@\| LC_ALL=C awk@\| awk@'
# The reader and the parser share an exit status again — the shape where an
# unopenable file reads as a file with no key in it.
mutate_scansh 'a broken confirmation reads as no key' has_trusted_snapshot_build \
  's@^  \[ "\$parser" -le 1 \] \\$@  [ "$parser" -le 99 ] \\@'
mutate_scansh 'an unreadable file reads as a file without a key' has_trusted_snapshot_build \
  's@^  \[ "\$reader" = 0 \] \\$@  [ "$reader" -le 99 ] \\@'
mutate_scansh 'the reader and the parser collapse into one status' has_trusted_snapshot_build \
  's@^  reader=\$\{pipes%% \*\}$@  reader=${pipes##* }@'
# PIPESTATUS survives exactly one command. Read it anywhere but in the branch
# body — an assignment counts — and the array is the assignment's, not the
# pipeline's, so `reader` becomes 0 for every file including the unreadable one.
mutate_scansh 'the statuses are read after the pipeline is gone' has_trusted_snapshot_build \
  's@^    pipes="\$\{PIPESTATUS\[\*\]\}"$@    pipes="0 0"@'
mutate_scansh 'the size test drops out of the excusability walk' has_trusted_snapshot_build \
  's@^    \[ "\$size" -ge "\$floor" \] \|\| return 1$@    true@'
mutate_scansh 'an unrecognised label stops refusing the whole file' has_trusted_snapshot_build \
  's@^    floor=\$\(scan_label_min_bytes "\$label"\) \|\| return 1$@    floor=$(scan_label_min_bytes "$label") || floor=0@'
# A labeller that came back empty means its grep died in a subshell, on a file
# the scan has already matched. Reading that as "no rule tripped" walks straight
# into the whitelist loop with nothing to reject.
mutate_scansh 'a labeller that failed reads as a file with nothing to excuse' has_trusted_snapshot_build \
  's@^  \[ -n "\$labels" \] \|\| return 1$@  [ -n "$labels" ] || return 0@'
mutate_scansh 'a broken content grep reads as a clean pass' has_trusted_snapshot_build \
  's@^  \[ "\$rc" -le 1 \] \|\| die .*$@@'
# The rule the whole reporter exists for: report ABOUT the file, never hand over
# what is in it.
mutate_scansh 'the refusal prints the head of what it caught' has_trusted_snapshot_build \
  's@^    printf .  the matched text is deliberately not printed.*$@&\n    printf "  head: %s\\n" "$(head -c 200 "$file")"@'
mutate_scansh 'the refusal echoes whatever sat in front of the ://' has_trusted_snapshot_build \
  's@^          printf .    scheme: not a recognised URL scheme.*$@          printf "    scheme: %s\\n" "$scheme"@'
mutate_pubsh 'a filename from the staged tree is printed raw' has_trusted_snapshot_build \
  's@\$\(safe_path "\$bad"\)@$bad@g'
mutate_pubsh 'a half-populated install publishes with a zero exit' has_trusted_snapshot_build \
  's@exec sh -euc "\$cmd"@exec sh -c "$cmd"@'
# Both respellings of the -I mistake. Each one publishes a NUL-prefixed token,
# and each one used to walk past the guard that claimed to forbid it.
mutate_scansh 'the binary skip comes back spelled -rIlZ' has_trusted_snapshot_build \
  's@grep -rlaZ -E@grep -rIlZ -E@'
mutate_scansh 'the binary skip comes back as --binary-files' has_trusted_snapshot_build \
  's@grep -rlaZ -E@grep -rlZ --binary-files=without-match -E@'
mutate_scansh 'the URL rule loses its scheme anchor' has_trusted_snapshot_build \
  's@\(\^\|\[\^A-Za-z0-9\+\.-\]\)\(\$URL_SCHEME_ALT\)://@://@'
mutate_pubsh 'one process may both run the install and hold the credential' has_trusted_snapshot_build \
  '/^\[ "\$BUILDING" = 0 \] \|\| \[ "\$PUBLISHING" = 0 \]/,+1d'
mutate_pubsh 'the size and layout verdicts precede the digest pin' has_trusted_snapshot_build \
  '/^ARCHIVE_SHA=/,+1d; s@^archive_is_flat "\$ARCHIVE"$@archive_is_flat "$ARCHIVE"\nARCHIVE_SHA=$(sha256sum <"$ARCHIVE" | cut -d" " -f1) \\\n  || die "the archive could not be digested"@'
mutate_scansh 'the VCS schemes go back to a hand-picked few' has_trusted_snapshot_build \
  's@[(]git[|]hg[|]bzr[|]svn[)][(][\][+][(]ssh[|]https[?][|]file[)][)][?]@git@'
mutate_pubsh 'the group the reap is aimed at goes unchecked' has_trusted_snapshot_build \
  '/^  prep_seen=\$\(tr -dc 0-9/,+4d'
# The shape this replaced. `[ -z "$prep_seen" ] ||` had to be there while the
# value came from `ps`, because a finished child reports nothing — and that is
# exactly why the check never fired on the case it was written for.
mutate_pubsh 'an unrecorded process group passes again' has_trusted_snapshot_build \
  's@^  \[ -n "\$prep_seen" \] \\$@  [ -z "$prep_seen" ] || \\@'
mutate_pubsh 'the group comes back from ps instead of from the child' has_trusted_snapshot_build \
  's@^  prep_seen=\$\(tr -dc 0-9 <"\$prep_pgid_file"\) \|\| prep_seen=""$@  prep_seen=$(pgid_of "$prep_pgid" || true)@'
mutate_pubsh 'the child stops recording the group it ran in' has_trusted_snapshot_build \
  's@^        \| tr -dc 0-9 >"\$CACHE_PREPARE_PGID_FILE" \|\| true$@        | cat >/dev/null || true@'
mutate_pubsh 'the /proc fallback goes away, so a host without ps refuses every run' has_trusted_snapshot_build \
  's@ \|\| cut -d" " -f5 /proc/self/stat@@'
# Read before the wait and "empty" means "not yet" again — the file is there but
# the child has not reached its first line, and the run dies on a scheduling
# accident, which is the fault the ps version had.
mutate_pubsh 'the recorded group is read before the install finishes' has_trusted_snapshot_build \
  '/^  prep_seen=\$\(tr -dc 0-9/d; s@^  prep_rc=0$@  prep_seen=$(tr -dc 0-9 <"$prep_pgid_file") || prep_seen=""\n  prep_rc=0@'
mutate_pubsh 'the pgid file path is left in the prepare command environment' has_trusted_snapshot_build \
  's@^      unset CACHE_PREPARE_PGID_FILE CACHE_PREPARE_CMD$@      :@'
mutate_pubsh 'the install keeps the run process group' has_trusted_snapshot_build \
  's@^  set -m$@  :@'
mutate_pubsh 'nothing is reaped once the install returns' has_trusted_snapshot_build \
  's@^  kill -TERM -- "-\$prep_pgid" 2>/dev/null \|\| true$@  :@'
mutate_pubsh 'the group is reaped only after the tree is scanned' has_trusted_snapshot_build \
  '/^  kill -(TERM|KILL) -- "-\$prep_pgid"/d; s@^  scan_or_die "\$STAGE"$@  scan_or_die "$STAGE"\n  kill -KILL -- "-$prep_pgid" 2>/dev/null || true@'
mutate_pubsh 'the uploaded bytes are never re-checked' has_trusted_snapshot_build \
  's@^assert_archive_unchanged "the upload"$@true@'
mutate_pubsh 'the CACHE_ARCHIVE_IN refusal echoes the path unfiltered' has_trusted_snapshot_build \
  's@\$\(safe_path "\$CACHE_ARCHIVE_IN"\)@$CACHE_ARCHIVE_IN@'
mutate_pubsh 'the recreated stage keeps the ambient umask' has_trusted_snapshot_build \
  's@mkdir -p "\$STAGE"; chmod 0700 "\$STAGE"@mkdir -p "$STAGE"@'
mutate_pubsh 'the written artifact is never re-checked' has_trusted_snapshot_build \
  's@^  assert_archive_unchanged "the artifact was written"$@  :@'
mutate_pubsh 'the snapshot is named after a fresh read of the file' has_trusted_snapshot_build \
  's@^digest=\$\{ARCHIVE_SHA:0:16\}$@digest=$(sha256sum "$ARCHIVE" | cut -c1-16)@'
mutate_pubsh 'the packed bytes are never scanned again' has_trusted_snapshot_build \
  's@^scan_or_die "\$VERIFY"$@true@'
# Gated on the phase again: the two-job flow still re-scans, and a single-phase
# run goes back to one scan with a writable window behind it.
mutate_pubsh 'the re-scan happens only in the publishing phase' has_trusted_snapshot_build \
  's@^scan_or_die "\$VERIFY"$@[ "$BUILDING" = 0 ] \&\& scan_or_die "$VERIFY"@'
mutate_pubsh 'the decompression stops being bounded' has_trusted_snapshot_build \
  's@ \| head -c "\$verify_bound" \\@ \\@'
# The count, which is the only part of the bound tar cannot fool. Without it a cut
# stream that happens to end on a member boundary extracts a PREFIX and exits 0 --
# the scan then passes on a subset of the bytes about to be published.
mutate_pubsh 'the expansion bound goes back to trusting tar' has_trusted_snapshot_build \
  's@^assert_expands_within_bound "\$verify_bound"$@:@'
mutate_pubsh 'the count is compared the wrong way round' has_trusted_snapshot_build \
  's@^  \[ "\$expanded" -le "\$1" \] \\@  [ "$expanded" -gt "$1" ] \\@'
mutate_pubsh 'the expansion count is taken after the unpack' has_trusted_snapshot_build \
  's@^assert_expands_within_bound "\$verify_bound"$@:@; s@^scan_or_die "\$VERIFY"$@assert_expands_within_bound "$verify_bound"\nscan_or_die "$VERIFY"@'
mutate_pubsh 'the expansion count itself becomes unbounded' has_trusted_snapshot_build \
  's@ \| head -c "\$\(\(\$1 \+ 1\)\)" \| wc -c \)@ | wc -c )@'
# The publisher's copy of the floor. Drifting from the fleet's is the same defect
# in the other direction: the gate exists to refuse here what a host would refuse
# on arrival, and two different bounds refuse two different sets.
mutate_pubsh 'the expansion bound loses its floor in the publisher' has_trusted_snapshot_build \
  's@^  \[ "\$bound" -ge "\$CACHE_EXPAND_FLOOR_BYTES" \] \|\| bound=\$CACHE_EXPAND_FLOOR_BYTES$@  :@'
mutate_pubsh 'the publisher floors the bound at nothing' has_trusted_snapshot_build \
  's@^CACHE_EXPAND_FLOOR_BYTES=65536$@CACHE_EXPAND_FLOOR_BYTES=0@'
mutate_pubsh 'the two bounds are computed by hand again' has_trusted_snapshot_build \
  's@^verify_bound=\$\(cache_expand_bound "\$size"\)$@verify_bound=$((size * 8))@'
# The listing. Unbounded it is a self-DoS; bounded but TRIMMED it is worse than
# unbounded, because the member it was written to catch can be in the part that
# was cut and the check passes.
mutate_pubsh 'the archive listing goes back to unbounded' has_trusted_snapshot_build \
  's@^  if tar -tvzf "\$1" \| head -c "\$\(\(cap \+ 1\)\)" >"\$list"; then$@  if tar -tvzf "$1" >"$list"; then@'
mutate_pubsh 'a truncated listing is inspected instead of refused' has_trusted_snapshot_build \
  's@^  \[ "\$written" -le "\$cap" \] \\$@  [ "$written" -ge 0 ] \\@'
# Order: tar's status read first reports every over-long listing as a corrupt
# archive, because `head` closing the pipe kills tar with SIGPIPE.
mutate_pubsh 'tar exit status decides before the byte count does' has_trusted_snapshot_build \
  '/^  \[ "\$tar_rc" = 0 \]/d; s@^  written=\$\(wc -c <"\$list"\).*$@  [ "$tar_rc" = 0 ] || die "the archive could not be listed"\n&@'
# The limiter is the last stage, so its only failures are failures to WRITE the
# listing. Dropped, an ENOSPC truncation measures under the cap and the flatness
# scan passes on a prefix.
mutate_pubsh 'the listing limiter goes back to having no status' has_trusted_snapshot_build \
  '/list_pipes##\* \}" = 0 \]/,+1d'
mutate_pubsh 'only the producer of the listing is checked' has_trusted_snapshot_build \
  's@^  tar_rc=\$\{list_pipes%% \*\}$@  tar_rc=${PIPESTATUS[0]}@'
mutate_pubsh 'the two listing statuses collapse into one' has_trusted_snapshot_build \
  's@^  tar_rc=\$\{list_pipes%% \*\}$@  tar_rc=${list_pipes##* }@'
# The reap must precede the REFUSALS, not just the scan. An unrecorded group is
# the shape most likely to have left a daemon behind, and it was the one shape
# that died before the kill.
mutate_pubsh 'the run gives up on an unrecorded group before reaping it' has_trusted_snapshot_build \
  '/^  kill -(TERM|KILL) -- "-\$prep_pgid"/d; /^  sleep 1$/d; s@^  case "\$prep_rc" in$@  kill -TERM -- "-$prep_pgid" 2>/dev/null || true\n  sleep 1\n  kill -KILL -- "-$prep_pgid" 2>/dev/null || true\n  case "$prep_rc" in@'
# The names the publish run is aimed at, checked before the tree is packed. Each
# of these is a value that cannot name anything the modules can create, so the
# only question is whether the operator learns that here or from a 403 that
# four different faults share.
mutate_pubsh 'a pool name may open with a digit' has_trusted_snapshot_build \
  '/^    \[!a-z\]\* \) die "CACHE_POOL must start/d'
mutate_pubsh 'the pool name loses its length bound' has_trusted_snapshot_build \
  '/^  \[ "\$\{#CACHE_POOL\}" -le 63 \]/,+1d'
mutate_pubsh 'the bucket name loses its length bound' has_trusted_snapshot_build \
  '/^  \[ "\$\{#CACHE_BUCKET\}" -ge 3 \]/,+1d'
mutate_pubsh 'the bucket name may be longer than a bucket name' has_trusted_snapshot_build \
  '/^  \[ "\$\{#CACHE_BUCKET\}" -le 63 \]/,+1d'
mutate_pubsh 'the pool name stops being validated at all' has_trusted_snapshot_build \
  '/^  case "\$CACHE_POOL" in$/,+3d'
mutate_pubsh 'the bucket name stops being validated at all' has_trusted_snapshot_build \
  '/^  case "\$CACHE_BUCKET" in$/,+3d'
# The verification unpack is the publisher reading back what it is about to ship,
# and it reads it back under the same refusals a host would apply.
mutate_pubsh 'the verification unpack lets the archive pick its owner' has_trusted_snapshot_build \
  's@-C "\$VERIFY" --no-same-owner @-C "$VERIFY" @'
mutate_pubsh 'credential files stop being scanned for' has_trusted_snapshot_build \
  "s@-o -name '\.git-credentials' @@"
mutate_pubsh 'the snapshot name becomes reusable' has_trusted_snapshot_build \
  's@^SNAP="\$\(date -u \+%Y%m%dT%H%M%SZ\)-\$\{digest\}\.tar\.gz"$@SNAP="latest.tar.gz"@'
mutate_pubsh 'the upload may overwrite an existing snapshot' has_trusted_snapshot_build \
  's@&ifGenerationMatch=0"@"@'
mutate_pubsh 'the pointer swap loses its precondition' has_trusted_snapshot_build \
  's@&ifGenerationMatch=\$\{gen\}"@"@'
mutate_pubsh 'the upload goes back to a tool that lists the bucket' has_trusted_snapshot_build \
  's@^log "uploading @gcloud storage cp "$ARCHIVE" "$dest" || true\nlog "uploading @'
mutate_pubsh 'the access token moves into argv' has_trusted_snapshot_build \
  's@-K <\(printf .header = "Authorization: Bearer %s.\\n. "\$GCS_TOKEN"\)@-H "Authorization: Bearer $GCS_TOKEN"@'
# The session URI arrives in a response header and is then handed the credential.
mutate_pubsh 'the session URI is trusted because it arrived over TLS' has_trusted_snapshot_build \
  's@^  \* \) die "the upload session URI is not.*$@  * ) : ;;@'
mutate_pubsh 'curl stops pinning the scheme' has_trusted_snapshot_build \
  "s@curl -sS --proto '=https' @curl -sS @"
# A 308 is not a finalised object, and curl's exit status cannot tell them apart.
mutate_pubsh 'a resume-incomplete counts as a finished upload' has_trusted_snapshot_build \
  's@200 \| 201 \) uploaded=1@200 | 201 | 308 ) uploaded=1@g'
mutate_pubsh 'the resume probe sends no Content-Length' has_trusted_snapshot_build \
  "s@-H 'Content-Length: 0' @@"
mutate_pubsh 'a session holding every byte is called finalised' has_trusted_snapshot_build \
  's@^      \|\| die "the upload session holds all.*$@      || { uploaded=1; break; }@'
# Integrity across the wire, and the pin re-asserted on the read a retry makes.
mutate_pubsh 'the upload declares no digest' has_trusted_snapshot_build \
  's@--data "\{.*md5Hash.*\}"@--data "{}"@'
mutate_pubsh 'a retry re-reads the archive without re-checking it' has_trusted_snapshot_build \
  's@^    assert_archive_unchanged "the upload retry"$@    :@'
# The generation read, and the two things that keep it from killing the shell or
# reaching a URL as something other than digits.
mutate_pubsh 'a missing pointer kills the shell instead of reading as 0' has_trusted_snapshot_build \
  's@ \| head -n 1\) \|\| true$@ | head -n 1)@'
mutate_pubsh 'the generation parse matches metageneration too' has_trusted_snapshot_build \
  "s@s/\\^generation:@s/.*generation:@"
mutate_pubsh 'whatever came back reaches the URL unvalidated' has_trusted_snapshot_build \
  's@^  .. \| .\[!0-9\]. \) gen=0 ;;$@  zzz ) gen=0 ;;@'
mutate_pubsh 'the size bound is dropped' has_trusted_snapshot_build \
  's@CACHE_MAX_BYTES@CACHE_SIZE_HINT@g'
mutate_pubsh 'the build phase falls through into the upload' has_trusted_snapshot_build \
  's@^if \[ "\$PUBLISHING" = 0 \]; then$@if false; then@'
mutate_file "$PUBSH" 'a directory is published that no host accepts' has_agreeing_cache_dirs \
  's@^CACHE_DIRS=\(npm @CACHE_DIRS=(npm cargo @'

# The workflow template. Each of these leaves a workflow that runs and publishes
# a snapshot, and each hands the credential to something that should not have it.
mutate_file "$PUBDOC" 'the two jobs are merged back into one' has_split_publishing_workflow \
  's@^      id-token: write.*$@@'
mutate_file "$PUBDOC" 'the install job gains the credential' has_split_publishing_workflow \
  's@^      contents: read  .*$@      contents: read\n      id-token: write@'
# The SECOND build job, on its own. The first version of this predicate ran its
# range from `build:` to `publish:`, so the Windows block -- which has no
# `publish:` after it -- was never inside the text being judged at all: a
# credential could be granted to a documented install job and the split's own
# test would pass. The two blocks are the same claim, so both are mutated.
mutate_file "$PUBDOC" 'the Windows install job gains the credential' has_split_publishing_workflow \
  's@^    runs-on: windows-latest$@    runs-on: windows-latest\n    permissions:\n      id-token: write@'
mutate_file "$PUBDOC" 'the token is granted workflow-wide instead' has_split_publishing_workflow \
  's@^permissions: \{\}$@permissions:\n  id-token: write@'
mutate_file "$PUBDOC" 'the publishing job stops waiting for the build' has_split_publishing_workflow \
  's@^    needs: build$@@'
# `|` as the delimiter: a pinned `uses:` contains an `@`.
mutate_file "$PUBDOC" 'the auth action goes back to a movable tag' has_split_publishing_workflow \
  's|google-github-actions/auth@[0-9a-f]{40} # v2\.[0-9]+\.[0-9]+|google-github-actions/auth@v2|'
mutate_file "$PUBDOC" 'the template becomes callable with inputs' has_split_publishing_workflow \
  's@^  workflow_dispatch:$@  workflow_dispatch:\n  workflow_call:@'
# The token back in a workspace, in the two shapes it comes back in: every
# checkout reverted at once, and — the one a reviewer would actually miss — a
# single checkout left on the defaults while the others still carry the flag.
# The second is why the assertion counts instead of matching once.
mutate_file "$PUBDOC" 'every checkout goes back to the defaults' has_split_publishing_workflow \
  's@^          persist-credentials: false$@@'
mutate_file "$PUBDOC" 'the build job alone keeps the token in its workspace' has_split_publishing_workflow \
  '0,/^          persist-credentials: false$/{/^          persist-credentials: false$/d}'
# The Windows build job, read as a build job. Each of these leaves the Linux
# pair untouched and would have passed unnoticed while the platform that runs
# the install held the credential.
mutate_file "$PUBDOC" 'the Windows build job gains the credential' has_split_publishing_workflow \
  's@^      contents: read           .*$@      contents: read\n      id-token: write@'
# NOT `/^  build:$/,/^  publish:$/!`, which is what this said first and which
# matched nothing: a sed range re-opens at EVERY match of its opening address, so
# the second `build:` -- the Windows one -- starts a range that finds no further
# `publish:` and therefore runs to end of file. The negation then excluded the
# very line the mutation was aimed at, and `mutate_file` reported "matched
# nothing". The Windows path is spelled with a backslash and the Linux one with a
# slash, so that is what tells them apart here.
mutate_file "$PUBDOC" 'the Windows build job publishes directly' has_split_publishing_workflow \
  's@^          CACHE_ARCHIVE_OUT: .*\\snap\.tar\.gz$@          CACHE_BUCKET: some-bucket@'

# The verdict plumbing. Every one of these leaves a hydrate that still works —
# hosts boot, jobs run — and takes away the only thing that would have said the
# cache stopped arriving.
mutate 'an exit stops naming itself' has_observable_hydrate \
  's@^    CACHE_VERDICT="too-old"$@@'
mutate 'the wrapper stops publishing the verdict' has_observable_hydrate \
  's@^  publish_cache_telemetry$@@'
mutate 'the verdict survives into the next hydrate' has_observable_hydrate \
  's@CACHE_VERDICT CACHE_STARTED@CACHE_STARTED@'
mutate 'only accepted snapshots report their age' has_observable_hydrate \
  's@^  CACHE_SNAP_AGE_HOURS=\$age$@@'
mutate 'the verdict label goes into the JSON unfiltered' has_observable_hydrate \
  's@\$\(ts_label_value "\$\{CACHE_VERDICT:-unset\}"\)@${CACHE_VERDICT}@'
mutate 'a failed publish becomes a failed hydrate' has_observable_hydrate \
  's@^  flush_series \|\| log .*$@  flush_series@'

mutate_file "$TELEM" 'the publishing token goes back into argv' has_publisher_token_out_of_argv \
  's@-K <\(printf .header = "Authorization: Bearer %s..n. "\$token"\)@-H "Authorization: Bearer $token"@'
mutate_file "$TELEM" 'the response goes back to a fixed name in shared /tmp' has_publisher_token_out_of_argv \
  's@-o "\$out"@-o /tmp/ts-response.json@'
# The three the old string-matching version let through: a header in a spelling
# nobody banned, a response path this predicate cannot follow, and a failure exit
# that leaves the body on disk — the one exit that has already logged from it.
mutate_file "$TELEM" 'the token header comes back spelled --header' has_publisher_token_out_of_argv \
  's@-K <\(printf .header = "Authorization: Bearer %s..n. "\$token"\)@--header "authorization: bearer $token"@'
mutate_file "$TELEM" 'the response goes to a path the file builds itself' has_publisher_token_out_of_argv \
  's@-o "\$out"@-o "${TMPDIR:-/tmp}/ts-$$.json"@'
mutate_file "$TELEM" 'the failure exit leaves the response body on disk' has_publisher_token_out_of_argv \
  's@^    \[ "\$out" = /dev/null \] \|\| rm -f "\$out"$@@'

mutate_file "$POOLTF" 'the host loses the telemetry publisher' has_host_telemetry_wiring \
  's@^    file\("\$\{path\.module\}/scripts/telemetry\.sh"\),$@@'
mutate_file "$POOLTF" 'the host script goes back to standing alone' has_host_telemetry_wiring \
  's@^  host_startup = join\(".{2}", \[$@  host_startup = file("${path.module}/scripts/host-startup.sh") # [@'

# --- the behavioural tests ------------------------------------------------------
#
# Everything above reads the script as TEXT. That is the right shape for "this
# rule must still be here", and it is structurally incapable of catching a rule
# that is present and wrong — which is how a hit list parsed by newline survived
# a full static suite: no assertion over source can express "the record
# separator must not be a legal filename byte".
#
# So these three RUN the real script, in dry-run, with a prepare command that
# plants the tree. The first is the control: without it a harness that silently
# stopped exercising the pass would make the other two pass by doing nothing.
#
# getcap is stubbed because it is not what is under test and it is absent on
# most laptops; everything else is the real script.
behave_setup() {
  BEH="$TMP/beh"
  rm -rf "$BEH"; mkdir -p "$BEH/stub"
  printf '#!/bin/sh\nexit 0\n' >"$BEH/stub/getcap"
  chmod +x "$BEH/stub/getcap"
}

# Runs the build phase against a prepare script. Echoes its output; returns its
# status. The prepare command's cwd is the caller's, and the stage is one
# dirname above $npm_config_cache — the same handle a real dependency has.
behave_run() { # <prepare-body> [allow-digests] [allow-file]
  local prep="$BEH/prepare.sh" rc=0 out
  # GITHUB_EVENT_NAME is pinned, not inherited. This suite runs on a PR, where
  # the ambient value is `pull_request` — a trigger the script refuses outright,
  # before it reaches a single control these tests are about. Inheriting it made
  # all eight behavioural tests fail in CI for one reason that had nothing to do
  # with any of them, while passing on a laptop where the variable is unset.
  # `schedule` is the trigger a real snapshot is built by, so this exercises the
  # gate's accept path rather than stepping around it.
  printf '%s' "$1" >"$prep"
  out=$(PATH="$BEH/stub:$PATH" \
        GITHUB_EVENT_NAME=schedule \
        CACHE_PREPARE="bash '$prep'" \
        CACHE_DRY_RUN=1 \
        CACHE_ARCHIVE_OUT="$BEH/out.tar.gz" \
        CACHE_SCAN_ALLOW_DIGESTS="${2:-}" \
        CACHE_SCAN_ALLOW_FILE="${3:-}" \
        bash "$PUBSH" 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

behave_setup

# The PEM fixture the allowlist is for: a legitimate one, stored under a
# hash-shaped name the way a pnpm store holds it, so no filename rule sees it.
# 1024 bytes of body so it is the same shape as the real thing.
BEH_PEM_BODY=$(printf -- '-----BEGIN PRIVATE KEY-----\n'; head -c 1200 /dev/zero | tr '\0' 'A' | fold -w 64; printf -- '\n-----END PRIVATE KEY-----\n')
BEH_PEM_SHA=$(printf '%s\n' "$BEH_PEM_BODY" | sha256sum | cut -d' ' -f1)

# CONTROL. An unexcused registry token must be refused — if this does not fail,
# the two tests below prove nothing.
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/npm/_cacache/content-v2/sha512/aa"
printf "%s\n" "//registry.example.com/:_authToken=deadbeef" \
  >"$stage/npm/_cacache/content-v2/sha512/aa/blob"
' >"$TMP/beh.control.log" 2>&1; then
  bad "behaviour: an embedded registry token was published"
else
  if matches "$(cat "$TMP/beh.control.log")" 'embedded credential'; then
    ok
  else
    bad "behaviour: the run failed, but not on the content pass"
  fi
fi

# The other side of that control, and the reason the token rule carries a left
# boundary. `googleapis` ships four doc comments of exactly this shape in one
# 456 KB `.d.ts`, and `registry-auth-token` is the one label no allowlist may
# excuse — so a bare `_authToken` pattern refuses that file permanently and the
# only move left is deleting the rule. This publishes, with no allowlist at all.
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/npm/_cacache/content-v2/sha512/ee"
printf "%s\n" "         *       //   \"authToken\": \"my_authToken\"," \
  >"$stage/npm/_cacache/content-v2/sha512/ee/blob"
' >"$TMP/beh.docword.log" 2>&1; then
  ok
else
  bad "behaviour: a doc comment naming my_authToken was refused as a registry token"
fi

# The second false positive this rule was widened wrongly into, and the reason
# it now requires an ASSIGNMENT. `neo4j-driver` names a private field exactly
# `_authToken` and ships it in eight files including a 570 KB minified bundle;
# no word boundary can help, because the identifier IS the string. What tells
# the two apart is that a field is read or bound, never given a value in place.
# All three shapes below are in the real package. This publishes, with no
# allowlist at all.
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/npm/_cacache/content-v2/sha512/dd"
printf "%s\n" "  this._authToken = _authToken;" \
              "    return this._authToken;" \
              "  function authTokenManager(_authToken) {" \
  >"$stage/npm/_cacache/content-v2/sha512/dd/blob"
' >"$TMP/beh.field.log" 2>&1; then
  ok
else
  bad "behaviour: a private field named _authToken was refused as a registry token"
fi

# ...and the assignment requirement is not a hole: every shape a tool actually
# writes the credential in still refuses. A commented-out line counts -- `;` is
# an ini comment, and a token in a comment is a token on disk. The whitespace
# and single-quote cases are here because `[[:space:]"']*` is the whole novelty
# of this rule, and an untested class member is one a later edit deletes for
# free. The yarn v1 pair is the one form with no operator at all: key and value
# are separated by juxtaposition, which the `.yarnrc` FILENAME rule catches by
# name and this rule has to catch inside a hash-named blob.
toki=0
for tokline in \
  '//registry.example.com/:_authToken=npm_REAL' \
  '_authToken=npm_REAL' \
  '  _authToken=npm_REAL' \
  ';_authToken=npm_REAL' \
  '_authToken = npm_REAL' \
  '_authToken	=	npm_REAL' \
  "_authToken' : 'npm_REAL" \
  'npm_config__authToken=npm_REAL' \
  '"//registry.yarnpkg.com/:_authToken" "npm_REAL"' \
  '"//registry.example.com/:_authToken": "npm_REAL"' \
  '//npm.pkg.github.com/:_authToken=${NPM_TOKEN}'
do
  toki=$((toki + 1))
  # The line goes over on disk rather than through the prepare body: it carries
  # quotes and a `${...}`, and interpolating it into the body would have the
  # outer shell expand exactly the shape being tested.
  printf '%s\n' "$tokline" >"$TMP/tok.txt"
  # Per-iteration log name: a single one is overwritten by the next case, so the
  # log left behind after a failure belongs to whichever case ran last.
  toklog="$TMP/beh.tok.$toki.log"
  if behave_run "$(printf 'set -eu\nstage=$(dirname "$npm_config_cache")\nd="$stage/npm/_cacache/content-v2/sha512/cc"\nmkdir -p "$d"\ncp %s "$d/blob"\n' "'$TMP/tok.txt'")" \
       >"$toklog" 2>&1; then
    bad "behaviour: a registry token published, written as: $tokline"
  else
    if matches "$(cat "$toklog")" 'embedded credential'; then
      ok
    else
      bad "behaviour: that token run failed, but not on the content pass: $tokline"
    fi
  fi
done

# The other half of that boundary, and the reason the greps pin LC_ALL=C. This
# is the leading-NUL opt-out with one byte changed: in a UTF-8 locale `\xff` is
# not a character, so `[^A-Za-z0-9]` matches nothing in front of the token and a
# live credential reads as a clean file. The prepare command is untrusted, so
# writing that byte is within reach of the same code the `-a` flag exists for.
# Run under a UTF-8 locale on purpose — under `C` this passes either way, which
# is exactly how the hole stayed invisible.
if LANG=C.UTF-8 LC_ALL=C.UTF-8 behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/npm/_cacache/content-v2/sha512/ff"
printf "\377//registry.example.com/:_authToken=STOLEN\n" \
  >"$stage/npm/_cacache/content-v2/sha512/ff/blob"
' >"$TMP/beh.hibyte.log" 2>&1; then
  bad "behaviour: a registry token behind one high-bit byte was published"
else
  if matches "$(cat "$TMP/beh.hibyte.log")" 'embedded credential'; then
    ok
  else
    bad "behaviour: the high-bit token run failed, but not on the content pass"
  fi
fi

# The allowlist does what it claims: the PEM fixture alone publishes.
if printf '%s\n' "$BEH_PEM_BODY" >"$TMP/pem" && behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/aa"
cat '"'$TMP/pem'"' >"$stage/pnpm-store/files/aa/deadbeef"
' "$BEH_PEM_SHA" >"$TMP/beh.excuse.log" 2>&1; then
  if matches "$(cat "$TMP/beh.excuse.log")" 'excused'; then
    ok
  else
    bad "behaviour: the fixture published, but no excusal was logged"
  fi
else
  bad "behaviour: an allowlisted PEM fixture was still refused"
fi

# The same excusal, from a file. This is the form a real consumer uses — the
# monorepo that drove this change lands 71 private-key-header hits, and a
# variable cannot carry a package name beside each one.
BEH_STAGE_PEM='
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/aa"
cat '"'$TMP/pem'"' >"$stage/pnpm-store/files/aa/deadbeef"
'
printf '# ssh2@1.17.0 test/fixtures — a published test key, in the tarball on npm\n%s  # the fixture\n' \
  "$BEH_PEM_SHA" >"$TMP/allow.txt"
if behave_run "$BEH_STAGE_PEM" '' "$TMP/allow.txt" >"$TMP/beh.allowfile.log" 2>&1; then
  # ...and the excusal names its source, its line, and what that line called the
  # package. A log saying only "excused" is the audit trail this whole change
  # exists to avoid.
  if matches "$(cat "$TMP/beh.allowfile.log")" 'excused by CACHE_SCAN_ALLOW_FILE line 2 \(the fixture\)'; then
    ok
  else
    bad "behaviour: the fixture published from a file, but the excusal did not name where it came from"
  fi
else
  bad "behaviour: a PEM fixture allowlisted in a file was still refused"
fi

# An INDENTED entry. This is the one the first version got wrong: the
# comment-skip glob ate every indented line holding a `#`, so an entry an editor
# auto-indented never loaded and the scan refused a fixture visibly in the file.
printf '# ssh2@1.17.0 test/fixtures\n    %s  # the fixture, indented\n' \
  "$BEH_PEM_SHA" >"$TMP/allow-indent.txt"
if behave_run "$BEH_STAGE_PEM" '' "$TMP/allow-indent.txt" >"$TMP/beh.allowindent.log" 2>&1; then
  if matches "$(cat "$TMP/beh.allowindent.log")" 'excused'; then
    ok
  else
    bad "behaviour: the indented entry published, but no excusal was logged"
  fi
else
  bad "behaviour: an indented allowlist entry was dropped"
fi

# A digest standing on its own authority. This is the whole point of the file
# over the variable, so the run must die on the LIST rather than reach the scan
# and quietly excuse it.
printf '%s\n' "$BEH_PEM_SHA" >"$TMP/allow-bare.txt"
if behave_run "$BEH_STAGE_PEM" '' "$TMP/allow-bare.txt" >"$TMP/beh.allowbare.log" 2>&1; then
  bad "behaviour: an unnamed digest excused a file"
else
  if matches "$(cat "$TMP/beh.allowbare.log")" 'no comment naming the package'; then
    ok
  else
    bad "behaviour: the unnamed digest was rejected, but not for being unnamed"
  fi
fi

# An allowlist that is not there. Tolerated, it would excuse nothing and the
# publish would refuse on every run — a misconfiguration that looks like a leak.
if behave_run "$BEH_STAGE_PEM" '' "$TMP/allow-missing.txt" >"$TMP/beh.allowgone.log" 2>&1; then
  bad "behaviour: a missing allowlist file was ignored"
else
  if matches "$(cat "$TMP/beh.allowgone.log")" 'names no readable file'; then
    ok
  else
    bad "behaviour: the missing allowlist failed the run, but not on the file"
  fi
fi

# A `user:password@` URL in a package's own documentation. This is the class the
# fleet's first real tree brought: 40 store objects, every one a published
# placeholder, and before this it could not be excused at any size. The file is
# padded past the floor because a README is, and because the floor is what keeps
# the printed digest from being an oracle for a short connection string.
BEH_URL_BODY=$(printf 'Connect with `postgres://user:password@localhost:5432/db`.\n'; head -c 1400 /dev/zero | tr '\0' 'x' | fold -w 70)
BEH_URL_SHA=$(printf '%s\n' "$BEH_URL_BODY" | sha256sum | cut -d' ' -f1)
BEH_STAGE_URL='
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/bb"
cat '"'$TMP/url'"' >"$stage/pnpm-store/files/bb/cafebabe"
'
printf '# pg-pool@3.13.0 README.md — the connection-string example\n%s  # pg-pool README\n' \
  "$BEH_URL_SHA" >"$TMP/allow-url.txt"
if printf '%s\n' "$BEH_URL_BODY" >"$TMP/url" \
  && behave_run "$BEH_STAGE_URL" '' "$TMP/allow-url.txt" >"$TMP/beh.allowurl.log" 2>&1; then
  if matches "$(cat "$TMP/beh.allowurl.log")" 'excused by CACHE_SCAN_ALLOW_FILE line 2 \(pg-pool README\)'; then
    ok
  else
    bad "behaviour: the documented URL published, but the excusal did not name where it came from"
  fi
else
  bad "behaviour: an allowlisted URL-credential fixture was still refused"
fi

# The same file, unexcused. A list COULD excuse it, and the report has to say so
# — but it must not hand over the digest, because the rest of those bytes is a
# README anyone can read and the hash would narrow the part that is not.
if behave_run "$BEH_STAGE_URL" >"$TMP/beh.urlnodigest.log" 2>&1; then
  bad "behaviour: an unexcused URL credential published"
else
  if matches "$(cat "$TMP/beh.urlnodigest.log")" 'a named digest CAN excuse this file, but the log does not print it' \
    && ! matches "$(cat "$TMP/beh.urlnodigest.log")" "sha256: $BEH_URL_SHA"; then
    ok
  else
    bad "behaviour: the URL fixture was refused, but the report either withheld the route or printed the digest"
  fi
fi

# The other side of the per-label table, and the reason it is a table at all: a
# small PEM stays excusable. `ssh2` ships ed25519 and ECDSA fixtures in the
# 200-500 byte range, and a flat floor would have made every one of them
# unexcusable overnight -- a publish wedged with no way out, on a fleet whose
# allowlist already named them. The bytes under the header are key material, so
# the digest is no use to anyone whatever the file's size.
BEH_SPEM_BODY=$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n'; head -c 160 /dev/zero | tr '\0' 'B' | fold -w 64; printf -- '\n-----END OPENSSH PRIVATE KEY-----\n')
BEH_SPEM_SHA=$(printf '%s\n' "$BEH_SPEM_BODY" | sha256sum | cut -d' ' -f1)
BEH_STAGE_SPEM='
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/ff"
cat '"'$TMP/spem'"' >"$stage/pnpm-store/files/ff/5ma11pem"
'
printf '# ssh2@1.17.0 test/fixtures — a small published key, well under 1024 bytes\n%s  # ssh2 ed25519 fixture\n' \
  "$BEH_SPEM_SHA" >"$TMP/allow-spem.txt"
if printf '%s\n' "$BEH_SPEM_BODY" >"$TMP/spem" \
  && behave_run "$BEH_STAGE_SPEM" '' "$TMP/allow-spem.txt" >"$TMP/beh.allowspem.log" 2>&1; then
  if matches "$(cat "$TMP/beh.allowspem.log")" 'excused by CACHE_SCAN_ALLOW_FILE line 2 \(ssh2 ed25519 fixture\)'; then
    ok
  else
    bad "behaviour: the small PEM published, but the excusal did not name where it came from"
  fi
else
  bad "behaviour: a small allowlisted PEM fixture was refused -- the private-key floor is not 0"
fi

# ...and unexcused it is refused without its digest, because at that size the
# rule has matched a header in front of a short string rather than a key.
if behave_run "$BEH_STAGE_SPEM" >"$TMP/beh.spemnodigest.log" 2>&1; then
  bad "behaviour: an unexcused small PEM published"
else
  if matches "$(cat "$TMP/beh.spemnodigest.log")" 'a named digest CAN excuse this file, but the log does not print it' \
    && ! matches "$(cat "$TMP/beh.spemnodigest.log")" "sha256: $BEH_SPEM_SHA"; then
    ok
  else
    bad "behaviour: the small PEM was refused, but the report either withheld the route or printed the digest"
  fi
fi

# A source file that MENTIONS the header and holds no key. This is 22 of the 71
# files the rule matched on the fleet's first real tree -- `jose`'s importer,
# `oracledb`'s util, `googleapis`' generated `.d.ts`, `gtoken`'s README -- and
# every one of them would otherwise need a digest that changes on the next
# dependency bump, in a job that runs unattended at 03:17. This publishes, with
# no allowlist at all. Both the BEGIN and the END string are here, because a
# secret detector's own source carries both and confirming on BEGIN alone would
# leave that file churning.
#
# Padded with INCOMPRESSIBLE bytes, and that is not decoration. This is the only
# new case that has to reach the packing stage, and the archive bound there is
# `8x the compressed size` — measured, a staging tree whose only content is
# repetitive padding compresses to ~345 bytes, which puts the bound at ~2760
# while the nine cache directories alone need 4608 bytes of tar headers. The
# case then fails on the bound and never reports on the confirmation stage at
# all. That floor is a real defect and it has its own issue (#191); random
# padding routes around it here rather than quietly depending on it.
BEH_MENTION_BODY=$(printf '%s\n' \
  'const PEM_START = "-----BEGIN PRIVATE KEY-----";' \
  'if (text.startsWith(PEM_START)) { return parsePrivateKey(text); }' \
  'const PEM_END = "-----END PRIVATE KEY-----";'; \
  head -c 20000 /dev/urandom | base64 | fold -w 70)
printf '%s\n' "$BEH_MENTION_BODY" >"$TMP/mention"
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/1a"
cat '"'$TMP/mention'"' >"$stage/pnpm-store/files/1a/mentiononly"
' >"$TMP/beh.pemmention.log" 2>&1; then
  if matches "$(cat "$TMP/beh.pemmention.log")" 'names a PEM header but holds no key block'; then
    ok
  else
    bad "behaviour: the header-mentioning source published, but the confirmation stage was not what let it through"
  fi
else
  bad "behaviour: a source file naming a PEM header was refused as a key"
fi

# ...and confirmation is not a way past anything else. The same mention, in a
# file that also carries a registry token: the key rule is unconfirmed, the token
# rule is not, and the token rule is the one no list may excuse.
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/1b"
printf "%s\n" \
  "const PEM_START = \"-----BEGIN PRIVATE KEY-----\";" \
  "//registry.example.com/:_authToken=deadbeefcafe" \
  >"$stage/pnpm-store/files/1b/mentionplus"
' >"$TMP/beh.pemmix.log" 2>&1; then
  bad "behaviour: an unconfirmed PEM header carried a registry token past the scan"
else
  if matches "$(cat "$TMP/beh.pemmix.log")" 'embedded credential'; then
    ok
  else
    bad "behaviour: the mixed file failed the run, but not on the content pass"
  fi
fi

# #183: the URL-credential class may be excused, but only from the file. The
# variable enforces nothing but hex -- forty characters in a workflow env block
# with nothing saying what they excuse -- and this is the class most likely to be
# a live credential if an operator misclassifies one. Same digest, same fixture,
# same run that passes through the file above: from the variable it refuses.
if printf '%s\n' "$BEH_URL_BODY" >"$TMP/url" \
  && behave_run "$BEH_STAGE_URL" "$BEH_URL_SHA" >"$TMP/beh.urlvar.log" 2>&1; then
  bad "behaviour: a bare CACHE_SCAN_ALLOW_DIGESTS entry excused a URL credential"
else
  if matches "$(cat "$TMP/beh.urlvar.log")" 'will not excuse a url-embedded-basic-auth hit from CACHE_SCAN_ALLOW_DIGESTS'; then
    ok
  else
    bad "behaviour: the URL credential was refused, but not for coming from the variable"
  fi
fi

# ...and the narrowing is exactly one label wide. A PEM fixture is still
# excusable from the variable, because its bytes ARE the secret and a reviewer
# reading a hash of it learns nothing either way.
if printf '%s\n' "$BEH_SPEM_BODY" >"$TMP/spem" \
  && behave_run "$BEH_STAGE_SPEM" "$BEH_SPEM_SHA" >"$TMP/beh.spemvar.log" 2>&1; then
  if matches "$(cat "$TMP/beh.spemvar.log")" 'excused by CACHE_SCAN_ALLOW_DIGESTS'; then
    ok
  else
    bad "behaviour: the PEM fixture published from the variable, but no excusal was logged"
  fi
else
  bad "behaviour: restricting the URL class to the file also took the PEM class with it"
fi

# Two rules in one file, one of them the unexcusable one, and the file's digest
# on the list. Under the old `= private-key-header` equality this was impossible
# to get wrong; with two excusable labels the conjunction is the only thing
# stopping a README that documents a registry token AND a connection string from
# being excused for the half that is innocent.
BEH_MIX_BODY=$(printf 'Set `//registry.example.com/:_authToken=deadbeefcafe`, then\n'; \
  printf 'connect with `postgres://user:password@localhost:5432/db`.\n'; \
  head -c 1400 /dev/zero | tr '\0' 'z' | fold -w 70)
BEH_MIX_SHA=$(printf '%s\n' "$BEH_MIX_BODY" | sha256sum | cut -d' ' -f1)
printf '# looks like a doc, trips two rules, one of them unexcusable\n%s  # the mixed file\n' \
  "$BEH_MIX_SHA" >"$TMP/allow-mix.txt"
if printf '%s\n' "$BEH_MIX_BODY" >"$TMP/mix" && behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/ee"
cat '"'$TMP/mix'"' >"$stage/pnpm-store/files/ee/0ddba11"
' '' "$TMP/allow-mix.txt" >"$TMP/beh.allowmix.log" 2>&1; then
  bad "behaviour: a file tripping the unexcusable rule was excused for its other half"
else
  if matches "$(cat "$TMP/beh.allowmix.log")" 'no list will excuse it' \
    && ! matches "$(cat "$TMP/beh.allowmix.log")" "sha256: $BEH_MIX_SHA"; then
    ok
  else
    bad "behaviour: the mixed-label file was refused, but not as unexcusable"
  fi
fi

# The same file, one byte under the floor. Its digest is an oracle for its own
# content, so no list may excuse it and the refusal must not print one.
BEH_URL_SMALL='mongodb://user:pass@db.example.com/x'
BEH_URL_SMALL_SHA=$(printf '%s\n' "$BEH_URL_SMALL" | sha256sum | cut -d' ' -f1)
printf '# a short connection string — must not be excusable\n%s  # too small to excuse\n' \
  "$BEH_URL_SMALL_SHA" >"$TMP/allow-url-small.txt"
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/cc"
printf "%s\n" '"'$BEH_URL_SMALL'"' >"$stage/pnpm-store/files/cc/beefbeef"
' '' "$TMP/allow-url-small.txt" >"$TMP/beh.allowurlsmall.log" 2>&1; then
  bad "behaviour: a short URL credential was excused by digest"
else
  if matches "$(cat "$TMP/beh.allowurlsmall.log")" 'no list will excuse it' \
    && ! matches "$(cat "$TMP/beh.allowurlsmall.log")" "sha256: $BEH_URL_SMALL_SHA"; then
    ok
  else
    bad "behaviour: the short URL credential was refused, but the report offered its digest anyway"
  fi
fi

# A registry token, large, with its own digest on the list. The one shape no
# list may ever excuse — if this publishes, the allowlist is a route past a live
# credential rather than past a false positive.
BEH_TOK_BODY=$(printf '//registry.example.com/:_authToken=deadbeefcafe\n'; head -c 1400 /dev/zero | tr '\0' 'y' | fold -w 70)
BEH_TOK_SHA=$(printf '%s\n' "$BEH_TOK_BODY" | sha256sum | cut -d' ' -f1)
printf '# not a fixture — a live token, and the list must not care\n%s  # the token\n' \
  "$BEH_TOK_SHA" >"$TMP/allow-tok.txt"
if printf '%s\n' "$BEH_TOK_BODY" >"$TMP/tok" && behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/dd"
cat '"'$TMP/tok'"' >"$stage/pnpm-store/files/dd/f00df00d"
' '' "$TMP/allow-tok.txt" >"$TMP/beh.allowtok.log" 2>&1; then
  bad "behaviour: an allowlisted registry token was published"
else
  if matches "$(cat "$TMP/beh.allowtok.log")" 'no list will excuse it'; then
    ok
  else
    bad "behaviour: the allowlisted token was refused, but not for being unexcusable"
  fi
fi

# THE ONE THE STATIC SUITE CANNOT SEE. A sibling whose name is the excused
# fixture's name plus a NEWLINE, holding a live token. With a newline-separated
# hit list grep emits the excused path, then the same path again as the prefix of
# this one, then an empty record the loop skips — two excusals, zero refusals,
# and this file is packed. Needs a filesystem that allows a newline in a name,
# which NTFS does not; skipped loudly there rather than passing.
#
# The probe is in two steps on purpose. One `2>/dev/null` around both swallows
# "$TMP is not writable" as well, and that reads as a skip -- a harness that has
# stopped being able to run anything at all reporting the same thing as a
# platform that merely cannot spell the filename.
if ! (cd "$TMP" && mkdir -p nlprobe && : >"nlprobe/plain"); then
  bad "behaviour: the newline probe could not write to \$TMP at all"
elif ! (cd "$TMP" && : >"nlprobe/a
b") 2>/dev/null; then
  skip "behaviour: this filesystem cannot hold a newline in a filename"
else
  if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/aa"
cat '"'$TMP/pem'"' >"$stage/pnpm-store/files/aa/deadbeef"
printf "%s\n" "//registry.example.com/:_authToken=deadbeef" \
  >"$stage/pnpm-store/files/aa/deadbeef
"
' "$BEH_PEM_SHA" >"$TMP/beh.newline.log" 2>&1; then
    bad "behaviour: a newline in a filename split the hit list and published a token"
  else
    if matches "$(cat "$TMP/beh.newline.log")" 'embedded credential'; then
      ok
    else
      bad "behaviour: the newline run failed, but not on the content pass"
    fi
  fi
fi

# THE OTHER ONE THE STATIC SUITE CANNOT SEE. `grep -I` decides a file is binary
# from its first NUL byte and skips it, so a single leading NUL in front of the
# credential opts that file out of the only pass that reads content -- in both
# jobs, since both call the same function. No name is planted here and no
# allowlist is set: the file is a plain registry token behind one NUL.
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/npm/_cacache/content-v2/sha512/bb"
printf "\000//registry.example.com/:_authToken=deadbeef\n" \
  >"$stage/npm/_cacache/content-v2/sha512/bb/blob"
' >"$TMP/beh.nul.log" 2>&1; then
  bad "behaviour: a leading NUL byte hid a registry token from the content pass"
else
  if matches "$(cat "$TMP/beh.nul.log")" 'embedded credential'; then
    ok
  else
    bad "behaviour: the NUL run failed, but not on the content pass"
  fi
fi

# The URL rule must still catch a real embedded credential once anchored...
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/npm/_cacache/content-v2/sha512/dd"
printf "registry=https://bob:hunter2@npm.example.com/\n" \
  >"$stage/npm/_cacache/content-v2/sha512/dd/blob"
' >"$TMP/beh.url.log" 2>&1; then
  bad "behaviour: an embedded https basic-auth credential was published"
else
  if matches "$(cat "$TMP/beh.url.log")" 'url-embedded-basic-auth'; then
    ok
  else
    bad "behaviour: the URL run failed, but not on the URL rule"
  fi
fi

# ...and must NOT fire on the same shape without a scheme in front of it. This is
# what a compressed blob produces by chance, roughly once a gibibyte, on a
# hash-named file nobody can excuse -- a refusal here is a gate that gets deleted.
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/npm/_cacache/content-v2/sha512/ee"
printf "\253\017Qz://k9:m2@\301\064\n" \
  >"$stage/npm/_cacache/content-v2/sha512/ee/blob"
' >"$TMP/beh.fp.log" 2>&1; then
  ok
else
  if matches "$(cat "$TMP/beh.fp.log")" 'url-embedded-basic-auth'; then
    bad "behaviour: random bytes shaped like ://x:y@ refused a clean snapshot"
  else
    bad "behaviour: the false-positive run failed for some other reason"
  fi
fi

# The smallest tree anyone could stage, and it must PUBLISH.
#
# Nothing here trips a scan: one file of repeated 'q'. What it exercises is the
# expansion bound's floor. Tar writes 20 512-byte records minimum and the nine
# cache directories cost 4608 bytes of headers before a file goes in, so a tree
# this compressible packs to a few hundred bytes — and eight times a few hundred
# bytes is LESS than the archive itself. Unfloored, `head` cuts the stream, tar
# reports an unexpected EOF, and the run refuses a perfectly good snapshot while
# announcing that it expanded too far.
#
# That is issue #191, and it was found the hard way: the case that caught it was
# an unrelated one whose fixture happened to compress well, and it went red
# intermittently — the archive carries a timestamped name, so its gzipped size
# wobbles across the threshold between runs. Deliberately compressible here, so
# the case is about the floor and not about whatever a fixture happens to weigh.
if behave_run '
set -eu
stage=$(dirname "$npm_config_cache")
mkdir -p "$stage/pnpm-store/files/aa"
head -c 64 /dev/zero | tr "\0" "q" >"$stage/pnpm-store/files/aa/tiny"
' >"$TMP/beh.tiny.log" 2>&1; then
  ok
else
  if matches "$(cat "$TMP/beh.tiny.log")" 'expands past the'; then
    bad "behaviour: a tree too small to fill tar's minimum archive was refused for expanding past the bound"
  else
    bad "behaviour: the smallest possible staged tree did not publish"
  fi
fi

# A writer the install leaves behind must not reach the published bytes. This is
# the shape of the attack the reap and the digest pin exist for: the prepare
# command forks a child, `sh -euc` returns clean, and the child then rewrites the
# packed archive with bytes carrying a token.
#
# TWO launchers, because they test different controls. `nohup ... &` stays in the
# prepare command's process group, so `kill -- -$pgid` reaches it -- that probe
# tests the REAP. `setsid` leaves the group, so the reap structurally cannot
# follow it -- that probe tests the DIGEST PIN, which is the only thing left.
#
# The child records that it actually SAW an archive. Without that marker the test
# passes whether or not the pin exists, because a child that was reaped before
# the archive was ever created has attacked nothing; that is exactly how the
# first version of this test reported a pass it had not earned. No marker is a
# skip, loudly, not an ok.
cat >"$BEH/attacker.sh" <<'ATTACKER'
#!/bin/sh
# $1 = the temp root to hunt in, $2 = the marker to touch on first sighting.
end=$(( $(date +%s) + 10 ))
while [ "$(date +%s)" -lt "$end" ]; do
  for f in "$1"/*/snap.*.tar.gz; do
    [ -f "$f" ] || continue
    : >"$2"
    printf '//registry.example.com/:_authToken=STOLEN\n' >"$f" 2>/dev/null || true
  done
  sleep 0.2
done
ATTACKER

daemon_probe() { # <what it tests> <launcher>
  local what="$1" launcher="$2" saw="$BEH/attacker.saw" log="$TMP/beh.$2.log"
  if ! command -v "$launcher" >/dev/null 2>&1; then
    skip "behaviour: no $launcher here, so this case cannot be launched ($what)"
    return
  fi
  rm -f "$saw" "$saw.launched" "$BEH/out.tar.gz"
  local body
  # The LAUNCHER records the launch, not the child. A working reap kills the
  # child inside the microseconds before it runs its first line, which from the
  # child's side is indistinguishable from a launch that failed — so a marker
  # written by the child would report the control working as "probe broken".
  body=$(printf '%s\n' \
    'set -eu' \
    'stage=$(dirname "$npm_config_cache")' \
    'mkdir -p "$stage/npm/_cacache/content-v2/sha512/cc"' \
    'printf "harmless\n" >"$stage/npm/_cacache/content-v2/sha512/cc/blob"' \
    "$launcher sh '$BEH/attacker.sh' \"\$(dirname \"\$stage\")\" '$saw' >/dev/null 2>&1 &" \
    ": >'$saw.launched'")
  if behave_run "$body" >"$log" 2>&1; then
    if grep -qa 'STOLEN' "$BEH/out.tar.gz" 2>/dev/null; then
      bad "behaviour: a writer left behind by the install replaced the published bytes ($what)"
    elif [ ! -f "$saw.launched" ]; then
      skip "behaviour: the install never reached the launch, so this proves nothing ($what)"
    else
      # A writer was launched and the published bytes are clean. Whether it was
      # reaped before it ever saw an archive, or saw one and lost the race to
      # the digest pin, the property under test held.
      ok
    fi
  else
    # `could not be listed` belongs here for the same reason the other three do.
    # The escapee overwrites the packed archive with a line of plain text, so
    # whichever inspection reaches those bytes first is the one that refuses:
    # the digest pin if the swap landed after the scan, `tar -tvzf` if it landed
    # before the listing, the scan itself if it landed before that. All four are
    # the run declining to publish a tampered archive, which is the property
    # under test; pinning the probe to one of them made it fail whenever the
    # race resolved a different way, and CI resolved it that way twice running.
    if matches "$(cat "$log")" 'changed between the scan and|embedded credential|did not unpack|could not be listed'; then
      ok
    else
      bad "behaviour: the run failed, but not on a control that names why ($what)"
    fi
  fi
  # Let the child expire before the next test, or its glob catches that run's
  # archive too and the results stop belonging to the test that produced them.
  sleep 11
}

daemon_probe 'the reap, on a child still in the group' 'nohup'
daemon_probe 'the digest pin, on a child that left the group' 'setsid'

# A behavioural failure says which control did not fire, and nothing about why
# the run got there — the script's own output went to a log file nobody prints.
# On a laptop you go read it; in CI the runner is gone by the time you look, so
# a red behavioural test would otherwise be undiagnosable from the job page.
if [ "$FAIL" -ne 0 ]; then
  for l in "$TMP"/beh.*.log; do
    [ -f "$l" ] || continue
    printf '\n--- %s (last 20 lines) ---\n' "$(basename "$l")"
    tail -20 "$l"
  done
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
# A skip is a real result on a laptop and not one in CI: the behavioural tests
# are the only instrument for this class of bug, and a green run that quietly
# exercised none of them is the failure mode they exist to prevent.
if [ -n "${CI:-}" ] && [ "$SKIP" -ne 0 ]; then
  printf 'FAIL: %d test(s) skipped, and CI is set\n' "$SKIP"
  exit 1
fi
[ "$FAIL" -eq 0 ]
