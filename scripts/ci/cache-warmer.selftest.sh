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
VARS="$ROOT/modules/ci-runner-cache-warmer/variables.tf"
TURBO="$ROOT/modules/ci-runner-cache-warmer/scripts/warm-turbo.sh"
SHARED="$ROOT/scripts/ci/publish-cache-snapshot.sh"
SHAREDSCAN="$ROOT/scripts/ci/scan-cache-credentials.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

for f in "$MAIN" "$VARS" "$TURBO"; do
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
#
#    The credential-scan library is the same reference and the same argument. The
#    publisher sources it from its own directory and refuses to run at all when
#    `scan_credentials_or_die` is undefined, so a library that stops being staged
#    beside it is a warm that publishes nothing — loudly, but only at trigger
#    time, on a schedule nobody is watching. Asserted here instead: read from the
#    repository root, written into the staged directory next to the publisher.
has_shared_publisher() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'file\("\$\{path\.module\}/\.\./\.\./scripts/ci/publish-cache-snapshot\.sh"\)' || return 1
  matches "$code" 'file\("\$\{path\.module\}/\.\./\.\./scripts/ci/scan-cache-credentials\.sh"\)'  || return 1
  matches "$code" 'gzip -d > \$\{local\.staged_dir\}/scan-cache-credentials\.sh'                  || return 1
}

if has_shared_publisher "$MAIN"; then ok; else
  bad "the warmer no longer runs the repository's own publish-cache-snapshot.sh — a second copy of the snapshot's archive layout and scan rules will drift from what a host accepts, and the first symptom is every host in the pool refusing a hydrate"
fi

if [ -f "$SHARED" ]; then ok; else
  bad "scripts/ci/publish-cache-snapshot.sh has moved; the warmer module reads it by relative path and terraform will fail at plan time with a message that says nothing about this"
fi

if [ -f "$SHAREDSCAN" ]; then ok; else
  bad "scripts/ci/scan-cache-credentials.sh has moved; the warmer module reads it by relative path too, and terraform will fail at plan time with a message that says nothing about this"
fi

# 2. TWO PHASES. The archive is packed in one step and uploaded in another, and
#    the uploading step is not the one that ran the install.
has_two_phases() { # <file>
  local code deps
  code=$(code_of "$1")
  matches "$code" 'CACHE_ARCHIVE_OUT=' || return 1
  matches "$code" 'CACHE_ARCHIVE_IN=' || return 1
  # The install phase must NOT be handed the bucket: a phase that can upload is
  # a phase that is publishing, whatever the step is called.
  #
  # SLICED, not matched with one regex. The first draft asked grep for a pattern
  # spanning the `CACHE_ARCHIVE_OUT=` line and a `CACHE_BUCKET=` line below it,
  # which grep cannot do — it reads a line at a time, so the assertion could
  # never fail and the mutation beside it passed for the wrong reason. awk
  # extracts the dependencies step and the question is asked of that text alone.
  deps=$(printf '%s\n' "$code" | awk '
    /id[[:space:]]*=[[:space:]]*"dependencies"/ { inside = 1 }
    inside && /id[[:space:]]*=[[:space:]]*"build"/ { inside = 0 }
    inside { print }
  ')
  [ -n "$deps" ] || return 1
  ! matches "$deps" 'CACHE_BUCKET'
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
  # Write-once, stated on the request. `ifGenerationMatch=0` is what makes an
  # already-published hash a 412 the loop counts as a skip rather than an
  # overwrite — which the grant refuses anyway, but a refusal read as a failure
  # is a nightly alert nobody can action.
  matches "$code" 'ifGenerationMatch=0' || return 1
  # And the upload must NOT go back through `gcloud storage cp`. That call lists
  # the destination, a list is authorised against the BUCKET, and every grant
  # this identity holds is conditioned on an object prefix — so it publishes
  # nothing at all. Measured: 0 of 291 artifacts, for months.
  ! matches "$code" 'gcloud storage cp' || return 1
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

# 8. THE WARM CONFIGURES ITSELF FROM THE REPOSITORY. Every input a consumer has
#    to fill in is an input a consumer can get wrong in a root nobody revisits,
#    about a repository that changes without telling Terraform — and wrong here
#    does not fail an apply, it fails inside a nightly build or, worse, succeeds
#    having installed nothing. The install must be decided from the lockfile the
#    repository already commits, and both commands must remain OPTIONAL.
has_self_configuring() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'pnpm-lock\.yaml' || return 1
  matches "$code" 'yarn\.lock' || return 1
  matches "$code" 'package-lock\.json' || return 1
  matches "$code" 'coalesce\(var\.prepare_command, local\.install_scriptfree\)' || return 1
  matches "$code" 'coalesce\(var\.build_command,'
}

if has_self_configuring "$MAIN"; then ok; else
  bad "the warm no longer works its install out from the repository's lockfile — every consuming root is back to stating a package manager that only has to be wrong once, in the one place where being wrong reports as a cache that is merely cold"
fi

# And the inputs stay optional. A default restored in variables.tf re-imposes a
# package manager on every consumer that leaves them unset, which is all of them.
block_of() { # <file> <variable-name>
  awk -v v="$2" 'index($0, "variable \"" v "\" {") == 1 { inside = 1 } inside { print } inside && $0 == "}" { exit }' "$1"
}

has_optional_commands() { # <file>
  local v blk
  for v in prepare_command build_command; do
    blk=$(block_of "$1" "$v")
    [ -n "$blk" ] || return 1
    matches "$blk" '^[[:space:]]*default[[:space:]]*=[[:space:]]*null[[:space:]]*$' || return 1
  done
}

if has_optional_commands "$VARS"; then ok; else
  bad "prepare_command or build_command has a default again — a consumer that states nothing now gets a package manager chosen by this module instead of one read from its own lockfile"
fi

# 9. THE BUILD IS TOLD WHERE TO WRITE, FROM THE SAME INPUT THE COLLECTOR READS.
#    Two knobs that must be kept equal is one knob that is eventually unequal,
#    and unequal here means turbo wrote its artifacts somewhere the publishing
#    step does not look: a green warm that publishes nothing at all.
has_cache_dir_bound() { # <file>
  local code
  code=$(code_of "$1")
  # NOT `matches "$code" -- '--cache-dir…'`: `matches` passes its second argument
  # to grep, so an intervening `--` makes the PATTERN `--`, which every file
  # matches. That is how the mutation below first passed. Escape the dashes into
  # the pattern instead.
  matches "$code" '\-\-cache-dir=\$\{local\.turbo_cache_dir_arg\}' || return 1
  # And the argument is Terraform-rendered from the same input, quoted, rather
  # than left for the shell.
  matches "$code" 'turbo_cache_dir_arg = "'"'"'\$\{replace\(var\.turbo_cache_dir' || return 1
  # THE REGRESSION THIS REPLACED, asserted as an absence. `--cache-dir="$WARM_
  # TURBO_DIR"` reads correctly and is wrong: every `$` in a step command is put
  # through `escape_dollars`, and the `script` field is handed to the shell
  # verbatim — Cloud Build does not unescape `$$` there the way it does in
  # `args`. So the build ran `--cache-dir="$$WARM_TURBO_DIR"`, turbo wrote to
  # `<pid>WARM_TURBO_DIR`, and the publishing step found nothing and exited 0.
  # Nothing went red; the prefix was simply always empty. Measured on the
  # executed build resource `5ea57da5` (2026-08-26).
  ! matches "$code" 'cache-dir=\\"\$WARM_TURBO_DIR' || return 1
  # The install ladder ends in `fi`, and the two halves are joined with a space:
  # without the `;` the step is `fi npx …`, a syntax error that kills the build
  # step before anything runs. Caught once by hand; asserted here so it is caught
  # the next time too.
  matches "$code" '"\$\{local\.install_full\};"' || return 1
  [ "$(printf '%s\n' "$code" | grep -cE 'WARM_TURBO_DIR=\$\{var\.turbo_cache_dir\}')" -eq 2 ]
}

if has_cache_dir_bound "$MAIN"; then ok; else
  bad "the build step and the publishing step no longer take the turbo cache directory from one input — turbo writes where the collector does not look, and the warm reports success having published nothing"
fi

# 10. THE SNAPSHOT'S INSTALL RUNS NO LIFECYCLE SCRIPTS. It is unpacked as root on
#     every host in the pool; the build step's install is a separate ladder and
#     is deliberately allowed to run them, which is exactly how this one loses
#     `--ignore-scripts` in a later edit that "makes them consistent".
has_scriptfree_snapshot() { # <file>
  matches "$(code_of "$1")" 'install_scriptfree = replace\(replace\(local\.install_ladder, "@FLAGS@", "--ignore-scripts"\)'
}

if has_scriptfree_snapshot "$MAIN"; then ok; else
  bad "the snapshot's install runs lifecycle scripts again — install-time scripts are the cheapest place to put code in someone else's build, and this archive is unpacked as root on every host in the pool"
fi

# 11. NOTHING IS ESCAPED ON ITS WAY INTO A STEP, AND THIS ASSERTION IS INVERTED
#     FROM WHAT IT USED TO SAY. Doubling every `$` is Cloud Build's escape for
#     the `args` field, and it was right while the scripts were pasted there —
#     unescaped, the API refused at FIRE time with "key in the template ... is
#     not a valid built-in substitution", which was a warmer that had never run
#     and a cache that had always been cold.
#
#     Every script now goes in `script` (assertion 12), and the substitution
#     pass does not read that field at all. Measured with a one-step build,
#     2026-08-26, both halves: `8f91196b` under loose substitution and
#     `f314e153` under STRICT saw `$PROBE_VAR` reach the shell intact and expand
#     to the step's env value, saw `$$PROBE_VAR` reach it as the PID, and
#     accepted `$_NO_SUCH_SUBSTITUTION_KEY` — the very text that is a fire-time
#     refusal in `args`.
#
#     So an escape here is corruption rather than protection, and it cost this
#     module its whole turbo half for months. The old form is asserted as an
#     ABSENCE, because it is exactly what a reader who knows the `args` rule
#     would put back.
has_no_dollar_escaping() { # <file>
  local code
  code=$(code_of "$1")
  ! matches "$code" 'escape_dollars' || return 1
  ! matches "$code" 'replace\([^)]*"\$",' || return 1
  matches "$code" 'stage_script = local\.stage_script_raw' || return 1
  matches "$code" 'prepare_command = coalesce\(var\.prepare_command' || return 1
  matches "$code" 'build_command = coalesce\(var\.build_command' || return 1
  # And nothing reaches a step as a raw file() read. That used to be how one
  # step could bypass the escaping while the local beside it kept it; with no
  # escaping left the reason is different and no weaker — a step must run the
  # STAGED file, whose digest it checks, not a second copy inlined by a route
  # that checks nothing.
  ! matches "$code" 'script[[:space:]]*=[[:space:]]*file\(' || return 1
  ! matches "$code" 'args[[:space:]]*=[[:space:]]*\["-c", file\('
}

if has_no_dollar_escaping "$MAIN"; then ok; else
  bad "a script or command is escaped on its way into a \`script\` field, or reaches a step by a route that bypasses staging — a doubled \`\$\` is not unescaped there and arrives as the build's PID, which is the defect that published nothing for months"
fi

# 12. EVERY STEP CARRIES ITS SCRIPT IN `script`, NEVER IN `args`. A step argument
#     is capped at 10,000 characters and the publishing script is an order of
#     magnitude past it, so `entrypoint = "bash"` + `args = ["-c", …]` is refused
#     — at FIRE time again, "build step 0 arg 1 too long (max: 10000)", on a
#     trigger that applied green. `script` has no such cap and honours the file's
#     own shebang; setting `entrypoint` beside it is an error in its own right.
carries_scripts_in_script_field() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'script = local\.stage_script' || return 1
  matches "$code" 'script = local\.run_publish' || return 1
  matches "$code" 'script = local\.run_turbo' || return 1
  ! matches "$code" 'args[[:space:]]*=[[:space:]]*\["-c"' || return 1
  ! matches "$code" 'entrypoint'
}

if carries_scripts_in_script_field "$MAIN"; then ok; else
  bad "a step passes its script through args or sets an entrypoint beside script — args are capped at 10,000 characters, the publishing script is far past that, and the API refuses the build at fire time on a trigger that applied cleanly"
fi

# 13. THE SCRIPTS ARE HANDED OVER ONCE, GZIPPED, AND THE APPLY REFUSES A CONFIG
#     THAT HAS GROWN BACK TOWARD 128 KiB. Past roughly that, Cloud Build accepts
#     the build, gives it an id, and then never schedules it — source fetched,
#     SETUPBUILD finished, every step QUEUED, no BUILD phase and no error, until
#     the queue TTL expires an hour later. Measured by bisection in one region: a
#     125 KB config reached BUILD in two seconds, a 140 KB config never reached
#     it at all. The first version of this module inlined the 91 KB publishing
#     script into TWO steps and shipped a 199 KB config, so every warm it fired
#     sat in that hole for as long as the module existed, reported nowhere.
#     Inlining a script into a step is how it comes back, which is why the read
#     is `base64gzip` and the guard is a precondition rather than a comment.
has_config_under_the_cliff() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'publish_gz = base64gzip\(file\(' || return 1
  matches "$code" 'turbo_gz   = base64gzip\(file\(' || return 1
  matches "$code" 'build_config_bytes = sum\(\[' || return 1
  # And a step that runs a STAGED script checks its digest first. /workspace is
  # also where the repository's install and build run, so a step that executes
  # what it finds there is a step the untrusted one in the middle could have
  # rewritten — the exact ordering the two-phase split exists to keep.
  matches "$code" 'publish_sha = filesha256\(' || return 1
  matches "$code" 'scan_sha    = filesha256\(' || return 1
  matches "$code" 'turbo_sha   = filesha256\(' || return 1
  # The library the publisher sources is checked in the same step as the
  # publisher: a snapshot scanned by a rewritten scanner is a snapshot nobody
  # scanned, and it is published either way.
  matches "$code" '\$\{local\.scan_sha\}  \$\{local\.staged_dir\}/scan-cache-credentials\.sh' || return 1
  [ "$(printf '%s\n' "$code" | grep -c 'sha256sum -c -')" -eq 2 ] || return 1
  matches "$code" 'condition     = local\.build_config_bytes < [0-9]+' || return 1
  # And the big script reaches the config exactly once. Twice is the 199 KB
  # config that never ran.
  [ "$(printf '%s\n' "$code" | grep -cF 'base64gzip(file("${path.module}/../../scripts/ci/publish-cache-snapshot.sh"))')" -eq 1 ]
}

if has_config_under_the_cliff "$MAIN"; then ok; else
  bad "a script is inlined into the build config again, or the size guard is gone — past ~128 KiB Cloud Build never schedules the build at all, and says nothing about it anywhere"
fi

# 14. THE STEP THAT BUILDS THE SNAPSHOT HAS getcap. The publisher refuses to
#     build a snapshot it cannot scan for file capabilities, and a host refuses
#     to unpack one — on both sides a missing `getcap` is a refusal, not a skip.
#     `node:22` is the default build image and ships without libcap2-bin, so the
#     warm installed the entire dependency tree and then died on that check,
#     every night. The workflow this module replaced installed the package in a
#     `run:` line; the module has to carry that over itself, for both package
#     managers, since the image is an input.
ensures_getcap_before_publishing() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'command -v getcap' || return 1
  matches "$code" 'libcap2-bin' || return 1
  # On Alpine the scanner is in `libcap-getcap`; `libcap` alone is the shared
  # library and no getcap, so installing it would satisfy apk and still leave
  # the publisher refusing. It stays as the fallback for older Alpine only.
  matches "$code" 'apk add --no-cache libcap-getcap' || return 1
  # In the wrapper that runs the publisher, and therefore in BOTH steps that run
  # it — not bolted onto one of them.
  matches "$code" '\$\{local\.ensure_getcap\}.*exec \$\{local\.staged_dir\}/publish-cache-snapshot\.sh'
}

if ensures_getcap_before_publishing "$MAIN"; then ok; else
  bad "the publishing wrapper no longer ensures getcap is installed — node:22 has no libcap2-bin, so the warm installs the whole dependency tree and then refuses to build the snapshot it was fired to build"
fi

# 15. AND IT PASSES THE REPOSITORY'S CREDENTIAL-SCAN ALLOWLIST, the other thing
#     the replaced workflow did in BOTH of its jobs and the module did not carry
#     over. Dependency trees legitimately hold files the scan refuses — a
#     package's PEM test fixture, a README quoting `https://user:pass@host` — and
#     `url-embedded-basic-auth` is excusable ONLY from the allowlist file, never
#     from the bare-hex env variable. Without a way to pass one, such a
#     repository cannot be warmed at all.
passes_scan_allowlist() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'CACHE_SCAN_ALLOW_FILE' || return 1
  # Resolved against the checkout, so the ordinary repository configures
  # nothing — and the default is a convention, not a required input.
  matches "$code" 'scan_allow_default *= *"\.github/cache-scan-allow\.txt"' || return 1
  matches "$code" 'if \[ -f' || return 1
  # A path the operator NAMED and mistyped must fail the step, not go quiet:
  # an allowlist that is not there excuses nothing and reads exactly like one
  # that worked.
  matches "$code" 'scan_allow_required' || return 1
  matches "$code" 'exit 1' || return 1
  # Captured in the staging step, which runs before the install — and the
  # publisher reads the CAPTURE, never the live checkout. The build step runs the
  # repository's lifecycle scripts and can write to /workspace, so an allowlist
  # re-read there could be rewritten alongside the archive it excuses, and the
  # credentialed phase would re-scan forged content against a forged allowlist.
  matches "$code" '\$\{local\.stage_scan_allow\}' || return 1
  matches "$code" "cp '\\\$\{local\.scan_allow_path\}' '\\\$\{local\.scan_allow_staged\}'" || return 1
  matches "$code" "CACHE_SCAN_ALLOW_FILE='\\\$\{local\.scan_allow_staged\}'" || return 1
  # In the wrapper, and therefore in BOTH steps that run the publisher.
  matches "$code" '\$\{local\.ensure_scan_allow\}.*exec \$\{local\.staged_dir\}/publish-cache-snapshot\.sh'
}

if passes_scan_allowlist "$MAIN"; then ok; else
  bad "the publishing wrapper no longer passes the repository's credential-scan allowlist — a repository whose dependency tree holds a PEM fixture or a URL with basic auth cannot be warmed, and the only route past that class is the allowlist FILE"
fi

# 16. AND THAT PATH IS CHECKED AT PLAN TIME, because it is pasted into a shell
#     string in a step that can reach the metadata server and mint the warmer's
#     write token. A quote ends that string; a `$` is read by Cloud Build as a
#     substitution key and refuses the build outright.
validates_scan_allow_path() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" 'variable "cache_scan_allow_file"' || return 1
  matches "$code" 'validation' || return 1
  matches "$code" "regexall" || return 1
  matches "$code" 'startswith'
}

if validates_scan_allow_path "$VARS"; then ok; else
  bad "cache_scan_allow_file is no longer validated — it is pasted into a single-quoted shell string in the step that holds the warmer's write credential"
fi

# 17. EVERY INSTALL RUNG SURVIVES ONE NETWORK RESET. The warm fires unattended at
#     04:00 and the next fire is a day away, so a transfer reset costs a full day
#     of stale host caches with nothing red to point at — measured on build
#     `2ee657b0` (2026-09-01), which died in `dependencies` when corepack's
#     download of `pnpm-9.15.0.tgz` was reset mid-transfer.
#
#     Asserted on the RENDERED rungs, not on the presence of the word "retry":
#     the ladder is a single line built by interpolation, and the shape that
#     matters is `{ cmd; } || { …; sleep …; cmd; }` — a retry written as a shell
#     function would need `"$@"`, whose `$` this module's own escaping rule turns
#     into the build's PID. So the absence of `"$@"` is part of the check.
retries_each_install() { # <file>
  local code rendered
  code=$(code_of "$1")
  matches "$code" 'install_attempts = \{' || return 1
  matches "$code" 'install_retried = \{' || return 1
  # The wrapper: grouped, one retry, a pause between the two attempts.
  rendered=$(printf '%s\n' "$code" | grep -F 'manager => "{ ${cmd}; } ||') || return 1
  matches "$rendered" 'sleep 15; \$\{cmd\}; \}' || return 1
  # No rung may reach the shell through `"$@"` - that `$` becomes the build PID.
  ! matches "$rendered" '"\$@"' || return 1
  # And the ladder must actually USE the wrapped rungs. A chain that still names
  # the bare command is a retry that exists in the file and nowhere else.
  # `matches` is grep -E, so the shell's `||` has to be escaped out of alternation.
  ! matches "$code" 'then corepack enable >/dev/null 2>&1 \|\| true; pnpm install' || return 1
  [ "$(printf '%s\n' "$code" | grep -cF 'local.install_retried[')" -eq 4 ]
}

if retries_each_install "$MAIN"; then ok; else
  bad "an install rung no longer survives a single network reset — the warm runs unattended at 04:00 against a shared egress IP, so one reset mid-download costs a day of stale host caches and nothing goes red"
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

mutate "the getcap install dropped from the publishing wrapper" "$MAIN" \
  's@\${local\.ensure_getcap}\${local\.ensure_scan_allow}@${local.ensure_scan_allow}@' \
  ensures_getcap_before_publishing

mutate "only the Debian package manager handled" "$MAIN" \
  's@apk add --no-cache libcap-getcap@true@' \
  ensures_getcap_before_publishing

mutate "Alpine given the library instead of the scanner" "$MAIN" \
  's@apk add --no-cache libcap-getcap >/dev/null 2>&1 || @@' \
  ensures_getcap_before_publishing

mutate "the allowlist dropped from the publishing wrapper" "$MAIN" \
  's@\${local\.ensure_scan_allow}exec@exec@' \
  passes_scan_allowlist

mutate "the allowlist read back from the live checkout" "$MAIN" \
  "s@CACHE_SCAN_ALLOW_FILE='\\\${local\.scan_allow_staged}'@CACHE_SCAN_ALLOW_FILE='\${local.scan_allow_path}'@" \
  passes_scan_allowlist

mutate "the allowlist no longer captured before the install" "$MAIN" \
  's@^ *\${local\.stage_scan_allow}$@@' \
  passes_scan_allowlist

mutate "a missing named allowlist made silent instead of fatal" "$MAIN" \
  's@exit 1@true@' \
  passes_scan_allowlist

mutate "the allowlist path taken on trust" "$VARS" \
  's@^ *validation {@  lifecycle_stub {@' \
  validates_scan_allow_path

mutate "the conventional allowlist path renamed out from under the repositories" "$MAIN" \
  's@\.github/cache-scan-allow\.txt@.github/scan-allow.txt@' \
  passes_scan_allowlist

mutate "the publisher copied into the module" "$MAIN" \
  's@file("\${path\.module}/\.\./\.\./scripts/ci/publish-cache-snapshot\.sh")@file("${path.module}/scripts/publish-cache-snapshot.sh")@' \
  has_shared_publisher

mutate "the credential-scan library stops being staged" "$MAIN" \
  's@^  scan_gz    = base64gzip(file("\${path\.module}/\.\./\.\./scripts/ci/scan-cache-credentials\.sh"))$@@' \
  has_shared_publisher

mutate "the library is read but never written beside the publisher" "$MAIN" \
  's@gzip -d > \${local\.staged_dir}/scan-cache-credentials\.sh@gzip -d > /tmp/scan-cache-credentials.sh@' \
  has_shared_publisher

mutate "install and upload in one phase" "$MAIN" \
  's@"CACHE_ARCHIVE_OUT=/workspace/ci-cache-snapshot.tar.gz",@@' \
  has_two_phases

# The mutation above removes the split; this one keeps it and hands the install
# step the credential anyway, which is the shape a later "just publish it here,
# it is one less step" edit actually takes. It is the only mutation that
# exercises the slice, and the reason the check was rewritten to use one.
mutate "the install step is handed the bucket" "$MAIN" \
  's@"CACHE_ARCHIVE_OUT=/workspace/ci-cache-snapshot.tar.gz",@&\n        "CACHE_BUCKET=${var.cache_bucket}",@' \
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
  's@&ifGenerationMatch=0@@' \
  has_uploader_bounds

mutate "the upload goes back through gcloud storage cp" "$TURBO" \
  's@gcloud storage objects describe@gcloud storage cp@' \
  has_uploader_bounds

mutate "a package manager assumed instead of detected" "$MAIN" \
  's@if \[ -f pnpm-lock\.yaml \]@if [ -f package-lock.json ]@' \
  has_self_configuring

mutate "the prepare command made a required input again" "$MAIN" \
  's@coalesce(var\.prepare_command, local\.install_scriptfree)@var.prepare_command@' \
  has_self_configuring

mutate "a default put back on the command inputs" "$VARS" \
  's@^  default     = null$@  default     = "npm ci --ignore-scripts"@' \
  has_optional_commands

mutate "the build no longer told where to write" "$MAIN" \
  's@ --cache-dir=\${local\.turbo_cache_dir_arg}@@' \
  has_cache_dir_bound

# The exact shape that shipped broken for months. It is the natural thing to
# write — the env variable is right there on the step — so it is mutated back in
# rather than merely described above.
mutate "the cache directory left to the shell to expand" "$MAIN" \
  's@--cache-dir=\${local\.turbo_cache_dir_arg}@--cache-dir=\\"$WARM_TURBO_DIR\\"@' \
  has_cache_dir_bound

mutate "the two halves of the build command run together" "$MAIN" \
  's@"\${local\.install_full};",@local.install_full,@' \
  has_cache_dir_bound

mutate "the collector reads a directory of its own" "$MAIN" \
  's@"WARM_TURBO_DIR=\${var\.turbo_cache_dir}",@"WARM_TURBO_DIR=node_modules/.cache/turbo",@' \
  has_cache_dir_bound

mutate "the two installs made consistent, in the wrong direction" "$MAIN" \
  's|"@FLAGS@", "--ignore-scripts"|"@FLAGS@", ""|' \
  has_scriptfree_snapshot

# The escape put back the way a reader who knows the `args` rule would put it —
# which is how it outlived the field it was written for in the first place.
mutate "the build command escaped again" "$MAIN" \
  's@build_command = coalesce(var\.build_command@build_command = replace(coalesce(var.build_command@' \
  has_no_dollar_escaping

mutate "one step given the raw file() again" "$MAIN" \
  's@script = local\.run_turbo@script = file("${path.module}/scripts/warm-turbo.sh")@' \
  has_no_dollar_escaping

mutate "a script handed back to bash -c" "$MAIN" \
  's@script = local\.run_publish@entrypoint = "bash"\n      args       = ["-c", local.run_publish]@' \
  carries_scripts_in_script_field

mutate "an entrypoint set beside a script" "$MAIN" \
  's@script = local\.run_turbo@entrypoint = "bash"\n      script     = local.run_turbo@' \
  carries_scripts_in_script_field

# The 199 KB config, put back one step at a time — which is exactly how it was
# written the first time, by someone reasoning that a step should carry the
# script it runs.
mutate "the publishing script inlined into its step again" "$MAIN" \
  's@script = local\.run_publish@script = base64gzip(file("${path.module}/../../scripts/ci/publish-cache-snapshot.sh"))@' \
  has_config_under_the_cliff

mutate "a staged script run without checking its digest" "$MAIN" \
  's@\\nexec \${local\.staged_dir}/warm-turbo\.sh@\\nexec ${local.staged_dir}/warm-turbo.sh@;s@sha256sum -c -\\nexec \${local\.staged_dir}/warm-turbo\.sh@exec ${local.staged_dir}/warm-turbo.sh@' \
  has_config_under_the_cliff

mutate "the scanner staged but left unchecked" "$MAIN" \
  's@\\n\${local\.scan_sha}  \${local\.staged_dir}/scan-cache-credentials\.sh@@' \
  has_config_under_the_cliff

mutate "the size guard removed" "$MAIN" \
  's@condition     = local\.build_config_bytes < 110000@condition     = true@' \
  has_config_under_the_cliff

mutate "the staging script escaped again" "$MAIN" \
  's@stage_script = local\.stage_script_raw@stage_script = replace(local.stage_script_raw, "$", "$$")@' \
  has_no_dollar_escaping

# The retry defined and then not reached — the shape a refactor produces when it
# rewrites one rung of the chain and leaves the rest, and the one an assertion on
# the word "retry" alone would pass.
mutate "one rung left calling the bare install" "$MAIN" \
  's|\${local\.install_retried\["pnpm"\]}|pnpm install --frozen-lockfile @FLAGS@|' \
  retries_each_install

# A retry with no pause is not a retry against a reset connection; it is two
# failures a millisecond apart.
mutate "the pause between the two attempts removed" "$MAIN" \
  's|sleep 15; ||' \
  retries_each_install

# The natural way to write this — and the way that renders `"$$@"`, the build's
# PID followed by a literal `@`, because every `$` in a step command is doubled.
mutate "the retry written through a shell function" "$MAIN" \
  's|sleep 15; ${cmd}; }|sleep 15; \\"$@\\"; }|' \
  retries_each_install

printf 'cache-warmer selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
