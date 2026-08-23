#!/usr/bin/env bash
# Self-test for the cache warmer, whose failures are all of the SILENT kind.
#
# The warmer is an unattended nightly job whose only observable is "the caches
# are warm". Every one of the invariants below breaks that quietly:
#
#   the shared script    the snapshot's archive layout and its scan rules are the
#                        host's contract, held in scripts/ci/publish-cache-snapshot.sh.
#                        A copy inside the module would drift from what hosts
#                        accept, and the first sign would be a hydrate that
#                        stopped working on every host at once.
#   two phases           the phase that runs third-party install code must not be
#                        the phase that uploads.
#   write-once           the grants must carry create and not delete, or the
#                        bucket's age bound stops meaning anything.
#   the pointer          exactly one object may be replaced. A prefix condition
#                        there hands back the delete authority the split removed.
#   the schedule         the trigger has no push filter, so a missing or
#                        unauthorised schedule is a warmer that never runs — and
#                        a cache nobody fills looks exactly like a cache nobody
#                        needs.
#
# Structural, like host-startup.selftest.sh: the checks match the TEXT of the
# module, and each is paired with a mutation that breaks it the way a later edit
# plausibly would. A gate that only passes on correct input is not evidence.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
MAIN="$ROOT/modules/ci-runner-cache-warmer/main.tf"
TURBO="$ROOT/modules/ci-runner-cache-warmer/scripts/warm-turbo.sh"
SHARED="$ROOT/scripts/ci/publish-cache-snapshot.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

for f in "$MAIN" "$TURBO"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

# Never `... | grep -q` under pipefail: grep exits on the first match, the writer
# takes SIGPIPE, and a successful match is reported as a failure. Same rule, and
# the same reason, as host-startup.selftest.sh.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# --- the invariants ------------------------------------------------------------

# 1. THE SHARED SCRIPT IS SHARED. `file()` reaching the repository root, and the
#    file actually being there. Two separate failures: the reference could be
#    replaced by a copy inside the module (drift), or the root file could be
#    moved (a plan that fails with a message about a missing file and nothing
#    about why a module wants one two directories up).
has_shared_publisher() { # <file>
  matches "$(code_of "$1")" 'file\("\$\{path\.module\}/\.\./\.\./scripts/ci/publish-cache-snapshot\.sh"\)'
}

if has_shared_publisher "$MAIN"; then ok; else
  bad "the warmer no longer runs the repository's own publish-cache-snapshot.sh — a second copy of the snapshot's archive layout and scan rules will drift from what a host accepts, and the first symptom is every host in the pool refusing a hydrate"
fi

if [ -f "$SHARED" ]; then ok; else
  bad "scripts/ci/publish-cache-snapshot.sh has moved; the warmer module reads it by relative path and terraform will fail at plan time with a message that says nothing about this"
fi

# 2. TWO PHASES. The archive is packed in one step and uploaded in another, and
#    the uploading step is not the one that ran the install.
has_two_phases() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'CACHE_ARCHIVE_OUT=' || return 1
  matches "$code" 'CACHE_ARCHIVE_IN=' || return 1
  # The install phase must NOT be handed the bucket: a phase that can upload is
  # a phase that is publishing, whatever the step is called.
  ! matches "$code" 'CACHE_ARCHIVE_OUT=[^\"]*\"[,]?[[:space:]]*$(:?)CACHE_BUCKET'
}

if has_two_phases "$MAIN"; then ok; else
  bad "the snapshot is no longer packed in one step and published in another — the step that runs third-party install code is the step holding the write grant"
fi

# 3. WRITE-ONCE. Both content prefixes are granted objectCreator, and the only
#    objectAdmin in the module is conditioned on ONE object with `==`.
has_write_once() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'role[[:space:]]*=[[:space:]]*"roles/storage\.objectCreator"' || return 1
  # objectAdmin appears once, and the condition next to it names one object.
  [ "$(printf '%s\n' "$code" | grep -cE 'roles/storage\.objectAdmin')" -eq 1 ] || return 1
  matches "$code" 'resource\.name == \\"\$\{local\.pointer_resource\}\\"' || return 1
  # And nothing anywhere is granted a role that carries delete over a prefix.
  ! matches "$code" 'objectAdmin[^=]*\n?.*startsWith'
}

if has_write_once "$MAIN"; then ok; else
  bad "the warmer's grants no longer make cache content write-once — an object replaced in place is a generation aged zero, so the bucket's age bound stops expiring anything and a poisoned entry is re-served forever"
fi

# 4. THE PREFIXES ARE THE ONES THE READERS READ. Spelled differently in the
#    warmer than in ci-runner-host-pool and the warm writes where no host looks,
#    which reports as a cache that is simply always cold.
has_matching_prefixes() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'cache_prefix = "cache/\$\{var\.pool_name\}/"' || return 1
  matches "$code" 'turbo_prefix = "turbo/\$\{var\.github_owner\}/\$\{var\.github_repo\}/"'
}

if has_matching_prefixes "$MAIN"; then ok; else
  bad "the warmer's object prefixes no longer match the ones ci-runner-host-pool grants its hosts read on; the warm would publish where nothing looks and every pool would report a permanently cold cache"
fi

# 5. THE SCHEDULE EXISTS AND IS ALLOWED TO FIRE. A scheduler job without the
#    permission to run a trigger applies cleanly and 403s on every fire, in a
#    log the cache's readers never see.
has_working_schedule() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'google_cloud_scheduler_job' || return 1
  matches "$code" 'roles/cloudbuild\.builds\.editor' || return 1
  matches "$code" 'roles/iam\.serviceAccountUser' || return 1
  # And it must fire the branch as a literal: triggers.run refuses a regex.
  matches "$code" 'branchName = var\.branch'
}

if has_working_schedule "$MAIN"; then ok; else
  bad "the warm is no longer scheduled, or the account that fires it cannot: either way the caches are never filled, which is indistinguishable from a fleet that does not need them"
fi

# 6. THE UPLOADER REFUSES WHAT THE SERVER WOULD NOT SERVE. A published object the
#    host-side server rejects is storage paid for and never read.
has_uploader_bounds() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" '\*\[!A-Za-z0-9_-\]\*' || return 1
  matches "$code" 'WARM_MAX_BYTES' || return 1
  matches "$code" -- '--no-clobber' || return 1
  # A prefix that does not end in a slash writes next to the tree, not into it.
  matches "$code" 'does not end in'
}

if has_uploader_bounds "$TURBO"; then ok; else
  bad "the artifact uploader no longer refuses what the host-side server would refuse to serve — an over-sized artifact, a name that is not a hash, or a prefix missing its trailing slash all publish objects that answer no read"
fi

# 7. THE ACCOUNT THAT FIRES IS NOT THE ACCOUNT THAT BUILDS. `cloudbuild.builds
#    .create` has no per-trigger binding: whoever may fire the warm may fire
#    every trigger in the project, and in these projects that includes the one
#    that runs terraform. The warmer's build runs the repository's own
#    dependency code, so collapsing the two accounts — the obvious
#    simplification, and the one a later edit will reach for — turns a
#    compromised lockfile into an apply.
has_separate_firer() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'resource "google_service_account" "firer"' || return 1
  matches "$code" 'role[[:space:]]*=[[:space:]]*"roles/cloudbuild\.builds\.editor"' || return 1
  # Every use of the firing identity goes through the one local, and that local
  # must not fall back to the warmer.
  ! matches "$code" 'scheduler_email[[:space:]]*=.*google_service_account\.warmer'
}

if has_separate_firer "$MAIN"; then ok; else
  bad "the account that fires the warm is the account that runs it — firing a trigger cannot be scoped to one trigger, so a dependency in the default branch could start any build in the project, including the terraform apply"
fi

# --- mutations -----------------------------------------------------------------

mutate() { # <description> <file> <sed-program> <predicate>
  local desc="$1" file="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
  # A sed that ERRORS writes an empty file, which differs from the original and
  # fails every predicate — so a broken mutation program reads as a mutation
  # caught. `\{` inside a BRE is an interval, not a literal brace, and every
  # anchor here is terraform interpolation; the first draft of this file had
  # four such mutations passing without ever running.
  if ! sed "$prog" "$file" >"$tmp"; then
    bad "mutation program is not valid sed: $desc"
  elif cmp -s "$file" "$tmp"; then
    bad "mutation did not apply (stale anchor): $desc"
  elif "$pred" "$tmp"; then
    bad "mutation not detected: $desc"
  else
    ok
  fi
  rm -f "$tmp"
}

mutate "the publisher copied into the module" "$MAIN" \
  's@file("\${path\.module}/\.\./\.\./scripts/ci/publish-cache-snapshot\.sh")@file("${path.module}/scripts/publish-cache-snapshot.sh")@' \
  has_shared_publisher

mutate "install and upload in one phase" "$MAIN" \
  's@"CACHE_ARCHIVE_OUT=/workspace/ci-cache-snapshot.tar.gz",@@' \
  has_two_phases

mutate "the pointer grant widened to a prefix" "$MAIN" \
  's@resource\.name == \\"\${local\.pointer_resource}\\"@resource.name.startsWith(\\"${local.bucket_resource}\\")@' \
  has_write_once

mutate "creator swapped for an admin" "$MAIN" \
  's@roles/storage\.objectCreator@roles/storage.objectAdmin@' \
  has_write_once

mutate "the snapshot prefix drifts from the host's" "$MAIN" \
  's@cache_prefix = "cache/\${var\.pool_name}/"@cache_prefix = "snapshots/${var.pool_name}/"@' \
  has_matching_prefixes

mutate "the build prefix drifts from the host's" "$MAIN" \
  's@turbo_prefix = "turbo/\${var\.github_owner}/\${var\.github_repo}/"@turbo_prefix = "turbo/${var.pool_name}/"@' \
  has_matching_prefixes

mutate "the scheduler may no longer fire the trigger" "$MAIN" \
  's@roles/cloudbuild\.builds\.editor@roles/cloudbuild.builds.viewer@' \
  has_working_schedule

mutate "the schedule fires a branch pattern" "$MAIN" \
  's@branchName = var\.branch@branchName = "^${var.branch}$"@' \
  has_working_schedule

mutate "the warmer fires its own schedule" "$MAIN" \
  's@try(google_service_account\.firer\[0\]\.email, "")@google_service_account.warmer.email@' \
  has_separate_firer

mutate "the uploader stops checking the hash shape" "$TURBO" \
  's@\*\[!A-Za-z0-9_-\]\* | ""@"") ;; #@' \
  has_uploader_bounds

mutate "the uploader overwrites what is already published" "$TURBO" \
  's@ --no-clobber@@' \
  has_uploader_bounds

printf 'cache-warmer selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
