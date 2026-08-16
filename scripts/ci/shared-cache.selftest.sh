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
PUBSH="$HERE/publish-cache-snapshot.sh"
PUBDOC="$HERE/../../docs/publishing-a-cache-snapshot.md"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }
[ -f "$PACKER" ] || { echo "FAIL: missing $PACKER"; exit 1; }
[ -f "$POOLTF" ] || { echo "FAIL: missing $POOLTF"; exit 1; }
[ -f "$POOLVARS" ] || { echo "FAIL: missing $POOLVARS"; exit 1; }
[ -f "$PUBTF" ] || { echo "FAIL: missing $PUBTF"; exit 1; }
[ -f "$PUBVARS" ] || { echo "FAIL: missing $PUBVARS"; exit 1; }
[ -f "$BUCKETTF" ] || { echo "FAIL: missing $BUCKETTF"; exit 1; }
[ -f "$PUBSH" ] || { echo "FAIL: missing $PUBSH"; exit 1; }
[ -f "$PUBDOC" ] || { echo "FAIL: missing $PUBDOC"; exit 1; }

# Code only: full-line comments stripped, so the prose explaining an invariant
# can never be what satisfies the check for it. This matters more here than
# anywhere else in the repository, because the comments in this section NAME
# every variable and every mechanism that must not be present — `GOCACHE`,
# `RUNNER_TOOL_CACHE`, `cp -al`, `2775` and `UMask` all appear as documented
# rejections, so a check reading raw text would see them and pass.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

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
  matches "$code" '\-perm /6000 -o \\\( -type f -a -links \+1 \\\)' || return 1
  matches "$code" 'getcap -r "\$root"'                              || return 1
  # A credential in a content-addressed cache is not cache content.
  matches "$code" "name '\.npmrc'"                                  || return 1
  # NOT -xdev on the scan. chmod has no --one-file-system, so the walk descends
  # into a bind mount whatever the scan does; a scan that skipped one would hide
  # exactly the entries the walk then re-owns and widens.
  ! matches "$code" 'find "\$root" -xdev'                           || return 1
  # The scan takes the tree as an argument and defaults to the master. This is
  # what lets ONE scanner cover both the master and a freshly unpacked snapshot;
  # a scanner hard-wired to the master would leave the snapshot — the only route
  # into this tree that no reviewed build step stands in front of — unscanned.
  matches "$code" 'local bad root="\$\{1:-\$CACHE_MASTER\}"'        || return 1
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
  matches "$code" 'cache_scan "\$limit" getcap -r "\$root"'      || return 1
  # `strict`, because for a snapshot the scan is the only opinion there is: an
  # unscannable tree has to be a refused tree, not a logged one.
  matches "$code" 'cache_master_is_hostile "\$CACHE_STAGE" strict' || return 1
  matches "$code" 'elif \[ "\$\{2:-\}" = "strict" \]'            || return 1
  # max_bytes bounds the COMPRESSED archive and gzip expands by more than a
  # thousandfold on the right input, so the decompressed stream is bounded too.
  matches "$code" 'head -c "\$\(\(size \* 8\)\)"'                || return 1
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
has_trusted_snapshot_build() { # <file>
  local code
  code=$(code_of "$1")
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
  # The host's walks, with the host's rules — plus a content pass, because a
  # filename list cannot see a token inside a cache entry whose name is a hash.
  matches "$code" '\-perm /6000' || return 1
  matches "$code" 'getcap -r' || return 1
  matches "$code" "\-name '\.git-credentials'" || return 1
  matches "$code" '_authToken' || return 1
  # The host refuses a multi-linked file, so nothing may be packed as a link
  # member; a staging tree legitimately has them (pnpm), which is why the bound
  # is on the archive rather than on the tree.
  matches "$code" '\-\-hard-dereference' || return 1
  matches "$code" 'archive_is_flat "\$ARCHIVE"' || return 1
  # The prepare command's own failure must be one: `sh -c` without -e publishes a
  # half-populated cache with a zero exit.
  matches "$code" 'sh -euc "\$CACHE_PREPARE"' || return 1
  # The publishing phase re-scans what it received. The archive crossed a job
  # boundary, and the job that scanned it first is the one that ran other
  # people's code.
  matches "$code" 'if \[ "\$BUILDING" = 0 \]' || return 1
  matches "$code" 'head -c "\$\(\(size \* 8\)\)"' || return 1
  # A missing getcap is a refusal, not a skip: on a snapshot the scan is the only
  # opinion, and a check that can be skipped rather than failed is not a bound.
  # Anchored, and the refusal with it: `if command -v getcap; then` still holds
  # the same words while turning the requirement into a skip.
  matches "$code" '^command -v getcap' || return 1
  matches "$code" '^  \|\| die "getcap is not installed' || return 1
  # Write-once, and the two bounds that keep it that way.
  matches "$code" 'SNAP="\$\(date -u \+%Y%m%dT%H%M%SZ\)-\$\{digest\}\.tar\.gz"' || return 1
  matches "$code" 'gcloud storage cp --if-generation-match=0' || return 1
  matches "$code" 'gcloud storage cp --if-generation-match="\$gen"' || return 1
  # Size, because a snapshot past the pools' bound is refused by every host and
  # reads in their logs as "nothing published" rather than as an error.
  matches "$code" 'CACHE_MAX_BYTES' || return 1
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
has_split_publishing_workflow() { # <doc>
  local build publish doc
  doc=$(cat "$1")
  # The two job blocks, by their own boundaries rather than by line count.
  build=$(sed -n '/^  build:$/,/^  publish:$/p' "$1")
  publish=$(sed -n '/^  publish:$/,/^```$/p' "$1")
  [ -n "$build" ] && [ -n "$publish" ] || return 1

  matches "$build" 'CACHE_PREPARE'      || return 1
  ! matches "$build" 'id-token'         || return 1
  ! matches "$build" 'google-github-actions/auth' || return 1

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
run 'the image build aborts on a hostile warm cache'     has_packer_gate_that_aborts "$PACKER"
run 'the seed is published atomically'                   has_atomic_seed           "$SCRIPT"
run 'no concurrency-unsafe cache is shared'              has_no_unsafe_sharing     "$SCRIPT"
run 'a cache failure never blocks registration'          has_fail_open             "$SCRIPT"
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
run 'a snapshot is built clean, scanned and written once' has_trusted_snapshot_build "$PUBSH"
run 'both sides agree on which tool caches travel'       has_agreeing_cache_dirs   "$PUBSH"
run 'the install never runs beside the publishing credential' has_split_publishing_workflow "$PUBDOC"

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

mutate 'pnpm store loses the v11 spelling' has_cache_env \
  's|^Environment=pnpm_config_store_dir=.*$||'
mutate 'npm cache points at the shared master' has_cache_env \
  's|^Environment=npm_config_cache=\$c/npm$|Environment=npm_config_cache=$CACHE_MASTER/npm|'
mutate 'the env block stops reaching the unit' has_cache_env \
  's|^\$CACHE_ENV$||'
mutate 'cache_env stops being per-slot' has_cache_env \
  's|CACHE_ENV=\$\(cache_env "\$idx"\)|CACHE_ENV=$(cache_env)|'

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
  's@-perm /6000 -o \\\( -type f -a -links \+1 \\\)@-perm /6000@'
mutate 'file capabilities stop being scanned' has_hostile_entry_refusal \
  's@getcap -r "\$root"@true "$root"@'
mutate 'the scan is hard-wired back to the master' has_hostile_entry_refusal \
  's@^  local bad root="\$\{1:-\$CACHE_MASTER\}" limit=0$@  local bad@'
mutate 'credentials stop being scanned' has_hostile_entry_refusal \
  "s@name '\\.npmrc'@name '.nothing'@"
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
mutate 'the snapshot scan stops being strict' has_snapshot_inspection \
  's@cache_master_is_hostile "\$CACHE_STAGE" strict@cache_master_is_hostile "$CACHE_STAGE"@'
mutate 'an unscannable snapshot is logged rather than refused' has_snapshot_inspection \
  's@^  elif \[ "\$\{2:-\}" = "strict" \]; then$@  elif false; then@'
mutate 'the decompressed stream stops being bounded' has_snapshot_inspection \
  's@\| head -c "\$\(\(size \* 8\)\)"@| cat@'
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
  's@^  unset CACHE_TOKEN CACHE_DEADLINE$@  :@'
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
mutate_file "$PUBSH" 'the snapshot is packed from a host cache instead' has_trusted_snapshot_build \
  's@^STAGE=\$\(mktemp -d\)$@STAGE=/opt/ci-cache@'
mutate_file "$PUBSH" 'pnpm loses the v11 spelling on the publishing side' has_trusted_snapshot_build \
  's@^ *export pnpm_config_store_dir=.*$@@'
mutate_file "$PUBSH" 'the event guard opens to every event' has_trusted_snapshot_build \
  "s@^  '' \| schedule \| workflow_dispatch \| push \) : ;;\$@  * ) : ;;@"
mutate_file "$PUBSH" 'a missing getcap becomes a skipped scan' has_trusted_snapshot_build \
  's@^command -v getcap.*$@if command -v getcap >/dev/null 2>\&1; then :; fi@'
mutate_file "$PUBSH" 'setuid entries stop being scanned for' has_trusted_snapshot_build \
  's@-o -perm /6000 @@'
mutate_file "$PUBSH" 'a hardlink may be packed as a link member' has_trusted_snapshot_build \
  's@ --hard-dereference@@'
mutate_file "$PUBSH" 'the shipped bytes stop being inspected' has_trusted_snapshot_build \
  's@^archive_is_flat "\$ARCHIVE"$@@'
mutate_file "$PUBSH" 'the embedded-credential pass is dropped' has_trusted_snapshot_build \
  "s@-e '_authToken' \\\\@\\\\@"
mutate_file "$PUBSH" 'a half-populated install publishes with a zero exit' has_trusted_snapshot_build \
  's@sh -euc "\$CACHE_PREPARE"@sh -c "$CACHE_PREPARE"@'
mutate_file "$PUBSH" 'the publishing job trusts the artifact it was handed' has_trusted_snapshot_build \
  's@^if \[ "\$BUILDING" = 0 \]; then$@if false; then@'
mutate_file "$PUBSH" 'the decompression stops being bounded' has_trusted_snapshot_build \
  's@ \| head -c "\$\(\(size \* 8\)\)" \\@ \\@'
mutate_file "$PUBSH" 'credential files stop being scanned for' has_trusted_snapshot_build \
  "s@-o -name '\.git-credentials' @@"
mutate_file "$PUBSH" 'the snapshot name becomes reusable' has_trusted_snapshot_build \
  's@^SNAP="\$\(date -u \+%Y%m%dT%H%M%SZ\)-\$\{digest\}\.tar\.gz"$@SNAP="latest.tar.gz"@'
mutate_file "$PUBSH" 'the upload may overwrite an existing snapshot' has_trusted_snapshot_build \
  's@gcloud storage cp --if-generation-match=0 @gcloud storage cp @'
mutate_file "$PUBSH" 'the pointer swap loses its precondition' has_trusted_snapshot_build \
  's@gcloud storage cp --if-generation-match="\$gen" @gcloud storage cp @'
mutate_file "$PUBSH" 'the size bound is dropped' has_trusted_snapshot_build \
  's@CACHE_MAX_BYTES@CACHE_SIZE_HINT@g'
mutate_file "$PUBSH" 'a directory is published that no host accepts' has_agreeing_cache_dirs \
  's@^CACHE_DIRS=\(npm @CACHE_DIRS=(npm cargo @'

# The workflow template. Each of these leaves a workflow that runs and publishes
# a snapshot, and each hands the credential to something that should not have it.
mutate_file "$PUBDOC" 'the two jobs are merged back into one' has_split_publishing_workflow \
  's@^      id-token: write.*$@@'
mutate_file "$PUBDOC" 'the install job gains the credential' has_split_publishing_workflow \
  's@^      contents: read  .*$@      contents: read\n      id-token: write@'
mutate_file "$PUBDOC" 'the token is granted workflow-wide instead' has_split_publishing_workflow \
  's@^permissions: \{\}$@permissions:\n  id-token: write@'
mutate_file "$PUBDOC" 'the publishing job stops waiting for the build' has_split_publishing_workflow \
  's@^    needs: build$@@'
# `|` as the delimiter: a pinned `uses:` contains an `@`.
mutate_file "$PUBDOC" 'the auth action goes back to a movable tag' has_split_publishing_workflow \
  's|google-github-actions/auth@[0-9a-f]{40} # v2\.1\.9|google-github-actions/auth@v2|'
mutate_file "$PUBDOC" 'the template becomes callable with inputs' has_split_publishing_workflow \
  's@^  workflow_dispatch:$@  workflow_dispatch:\n  workflow_call:@'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
