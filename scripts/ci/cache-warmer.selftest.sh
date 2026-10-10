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
DERIVE="$ROOT/modules/ci-runner-cache-warmer/scripts/derive-turbo-tasks.cjs"
ALERT="$ROOT/modules/ci-runner-cache-warmer/alert.tf"
SHARED="$ROOT/scripts/ci/publish-cache-snapshot.sh"
SHAREDSCAN="$ROOT/scripts/ci/scan-cache-credentials.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

for f in "$MAIN" "$VARS" "$TURBO" "$DERIVE" "$ALERT"; do
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
  # Three staged-script runs: the publisher (with its library), the uploader,
  # and the task derivation the build step runs before anything else.
  matches "$code" 'derive_sha  = filesha256\(' || return 1
  matches "$code" '\$\{local\.derive_sha\}  \$\{local\.staged_dir\}/derive-turbo-tasks\.cjs. \| sha256sum -c - >/dev/null \|\| exit 1' || return 1
  # Four: the read-only cache server the build step starts is staged too, and
  # it runs in the step that also runs the repository's build.
  matches "$code" 'server_sha  = filesha256\(' || return 1
  matches "$code" '\$\{local\.server_sha\}  \$\{local\.staged_dir\}/turbo-cache-server\.py. \| sha256sum -c - >/dev/null \|\| exit 1' || return 1
  [ "$(printf '%s\n' "$code" | grep -c 'sha256sum -c -')" -eq 4 ] || return 1
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

# 16. THE DEFAULT BUILD RUNS THE TASKS IT IS TOLD TO, AND ONLY TASK NAMES GET
#     INTO THE COMMAND. A pull-request job that runs `typecheck` or `lint` reads
#     the same pool as `build`. With `build` hard-coded, those tasks were never
#     published and ran cold on every PR (IntegrateIT #25161). The names are
#     joined into a shell command line, so the variable's validation is what
#     keeps a `;` or `$(` out of it.
runs_declared_tasks() { # <main.tf>
  matches "$(code_of "$1")" 'turbo run \$\{local\.turbo_task_args\} \-\-continue=dependencies-successful \-\-cache-dir=' || return 1
  matches "$(code_of "$1")" 'turbo_task_args = local\.derive_tasks \? "\$WARM_TASKS" : join\(" ", var\.turbo_tasks == null \? \[\] : var\.turbo_tasks\)' || return 1
  ! matches "$(code_of "$1")" 'turbo run build \-\-cache-dir='
}

validates_task_names() { # <variables.tf>
  local blk
  blk=$(block_of "$1" turbo_tasks)
  [ -n "$blk" ] || return 1
  matches "$blk" '^[[:space:]]*default[[:space:]]*=[[:space:]]*null[[:space:]]*$' || return 1
  matches "$blk" 'var\.turbo_tasks == null \? true : \(length\(var\.turbo_tasks\) > 0 && alltrue' || return 1
  # The allowed set, verbatim. Widening it is a deliberate edit to this line too.
  printf '%s\n' "$blk" | grep -cF -- '"^[A-Za-z0-9][A-Za-z0-9:#@._/-]{0,127}$"' >/dev/null
}

if runs_declared_tasks "$MAIN"; then ok; else
  bad "the default build no longer runs var.turbo_tasks — a task a pull-request job reads from the pool is never warmed, and that job runs cold on every PR with nothing red"
fi

if validates_task_names "$VARS"; then ok; else
  bad "turbo_tasks lost its default or its name validation — the names are joined into the build step's shell command, so an unvalidated entry is a second command"
fi

# 17. BY DEFAULT THE WARM RUNS THE REPOSITORY'S OWN DECLARED TASKS. A list a
#     root keeps goes stale the day the repository adds a task, and `["build"]`
#     left typecheck and lint cold on every PR (IntegrateIT #25161). Each
#     property below is one a later edit plausibly drops:
#       derivation is the default, and only when neither override is set;
#       the build step runs it BEFORE the build and fails loudly on nothing;
#       the default exclusions are test* and e2e* (service-dependent tasks);
#       the script leaves out persistent and cache:false tasks, refuses names
#       outside the shell-safe set, and never falls back to a guess.
derives_tasks_by_default() { # <main.tf>
  local code
  code=$(code_of "$1")
  matches "$code" 'derive_tasks    = var\.build_command == null && var\.turbo_tasks == null' || return 1
  # The step must RUN the measured script, not an inline copy without the derive.
  matches "$code" '^[[:space:]]*script[[:space:]]*= local\.build_step_script$' || return 1
  # `\\n`: main.tf holds a literal backslash-n (HCL's newline escape). A bare
  # `\n` in an ERE is not that, and matched nothing.
  matches "$code" 'build_step_script = "#!/usr/bin/env bash\\n\$\{local\.derive_step\}\$\{local\.serve_step\}\$\{local\.build_command\}' || return 1
  matches "$code" 'WARM_TASKS=\$\(node \$\{local\.staged_dir\}/derive-turbo-tasks\.cjs turbo\.json \$\{join\(" ", \[for g in var\.turbo_tasks_exclude : "'"'"'\$\{g\}'"'"'"\]\)\}\) \|\| \{ .*exit 1; \}' || return 1
  matches "$code" "gzip -d > \\$\{local\.staged_dir\}/derive-turbo-tasks\.cjs"
}

excludes_by_default() { # <variables.tf>
  local blk
  blk=$(block_of "$1" turbo_tasks_exclude)
  [ -n "$blk" ] || return 1
  matches "$blk" '^[[:space:]]*default[[:space:]]*=[[:space:]]*\["test\*", "e2e\*", "deploy\*", "release\*", "publish\*", "\*migrate\*", "clean\*"\]' || return 1
  # Validated to a glob character set with no quote in it: each entry is pasted
  # between single quotes on the build step's command line.
  printf '%s\n' "$blk" | grep -cF -- '"^[A-Za-z0-9*?][A-Za-z0-9*?:#@._/-]{0,127}$"' >/dev/null
}

derivation_is_safe() { # <derive-turbo-tasks.cjs>
  local code
  code=$(grep -vE '^[[:space:]]*//' "$1")
  matches "$code" 'if \(info\.persistent\) why = "persistent";' || return 1
  matches "$code" 'else if \(!info\.cached\) why = "cache: false";' || return 1
  matches "$code" 'if \(d\.cache !== false\) cur\.cached = true;' || return 1
  matches "$code" 'if \(d\.persistent === true\) cur\.persistent = true;' || return 1
  printf '%s\n' "$code" | grep -cF -- 'const SAFE = /^[A-Za-z0-9][A-Za-z0-9:#@._\/-]{0,127}$/;' >/dev/null || return 1
  matches "$code" 'else if \(!SAFE\.test\(name\)\) why = "not a safe task name";' || return 1
  matches "$code" 'typeof declared !== "object" \|\| Array\.isArray\(declared\)' || return 1
  matches "$code" 'say\("tasks derived from "' || return 1
  matches "$code" 'say\("excluded: "' || return 1
  matches "$code" 'process\.exit\(5\);' || return 1
  ! matches "$code" '"build"'
}

if derives_tasks_by_default "$MAIN"; then ok; else
  bad "the default build no longer derives its tasks from turbo.json before building — a task the repository adds is never warmed"
fi
if excludes_by_default "$VARS"; then ok; else
  bad "turbo_tasks_exclude lost its test*/e2e* default or its glob validation — a service-dependent test task fails every warm, or a quote reaches the command line"
fi
if derivation_is_safe "$DERIVE"; then ok; else
  bad "derive-turbo-tasks.cjs no longer leaves out persistent / cache:false tasks, checks names, logs both lists, or refuses an empty result — a watcher hangs the warm, or a guess hides a broken config"
fi

# 18. THE WARMER OWNS ITS ALARM, AND THE ALARM CANNOT BE SILENT. Measured
#     2026-10-10: a consumer's warm ended in ERROR on at least eight nights in a
#     row and nobody was told, because the only stale-cache policy lived in the
#     pool's project and had never been installed there. The properties that make
#     the module's own policy real, each a plausible later edit:
#       the metric counts THIS trigger's builds, from the MAIN outcome line;
#       the stale condition reads absence of DONE (the guarantee — a refused build
#       logs nothing), and keeps `or vector(0)`, without which "no DONE at all"
#       is an empty comparison and therefore silence;
#       the failure condition counts anything that is not DONE;
#       the policy notifies the declared channels, and the channels are required;
#       it has ONE condition with both branches joined by `or` — the API refuses
#       (400) a second prometheus_query_language condition on a policy.
owns_its_alarm() { # <alert.tf>
  local code
  code=$(code_of "$1")
  matches "$code" 'resource "google_logging_metric" "warm_outcome"' || return 1
  matches "$code" 'resource\.labels\.build_trigger_id=\\"\$\{google_cloudbuild_trigger\.warm\.trigger_id\}\\"' || return 1
  matches "$code" 'labels\.build_step=\\"MAIN\\"' || return 1
  matches "$code" 'outcome[[:space:]]*=[[:space:]]*"EXTRACT\(textPayload\)"' || return 1
  matches "$code" 'outcome!=\\"DONE\\"\}\[1h\]\)\) > 0' || return 1
  matches "$code" 'outcome=\\"DONE\\"\}\[\$\{var\.alert_stale_after_hours\}h\]\)\) or vector\(0\)\) < 1' || return 1
  matches "$code" 'notification_channels[[:space:]]*=[[:space:]]*var\.alert_notification_channels' || return 1
  matches "$code" '\[1h\]\)\) > 0\) or \(\(sum\(increase' || return 1
  [ "$(grep -c '^  conditions {$' <<<"$code")" -eq 1 ] || return 1
}

requires_alert_channels() { # <variables.tf>
  local blk
  blk=$(block_of "$1" alert_notification_channels)
  [ -n "$blk" ] || return 1
  ! matches "$blk" '^[[:space:]]*default[[:space:]]*=' || return 1
  matches "$blk" 'length\(var\.alert_notification_channels\) > 0 && alltrue' || return 1
  blk=$(block_of "$1" alert_stale_after_hours)
  matches "$blk" '^[[:space:]]*default[[:space:]]*=[[:space:]]*36[[:space:]]*$'
}

if owns_its_alarm "$ALERT"; then ok; else
  bad "the warmer's own alert policy lost a property that makes it fire — a failing or never-run warm is a cold pool and nothing else turns red"
fi

if requires_alert_channels "$VARS"; then ok; else
  bad "alert_notification_channels is no longer required and non-empty (or the stale default moved) — an alert nobody receives repeats the incident"
fi

# 20. THE BUILD READS THE POOL BEFORE IT BUILDS. Measured on build 6e721cc4: 0
#     of 956 tasks cached, every one rebuilt and re-published, nightly. The build
#     step now starts the HOST POOL's own read-only server — the same file, not a
#     copy, so a warm trusts exactly what a pull request trusts — on loopback,
#     digest-checked, before the build command; and the publisher is told which
#     hashes it served so it never asks the bucket about them.
HOSTSERVER="$ROOT/modules/ci-runner-host-pool/scripts/turbo-cache-server.py"
reads_the_pool_before_building() { # <main.tf>
  local code
  code=$(code_of "$1")
  matches "$code" 'server_gz = base64gzip\(file\("\$\{path\.module\}/\.\./ci-runner-host-pool/scripts/turbo-cache-server\.py"\)\)' || return 1
  matches "$code" '\$\{local\.server_sha\}  \$\{local\.staged_dir\}/turbo-cache-server\.py. \| sha256sum -c - >/dev/null \|\| exit 1' || return 1
  # Loopback only: the server holds a token that can read the whole prefix.
  matches "$code" 'CI_TURBO_HOST=127\.0\.0\.1 ' || return 1
  ! matches "$code" 'CI_TURBO_HOST=0\.0\.0\.0' || return 1
  matches "$code" 'export TURBO_API=http://127\.0\.0\.1:' || return 1
  matches "$code" 'build_step_script = .*\$\{local\.serve_step\}\$\{local\.build_command\}' || return 1
  matches "$code" '"WARM_SERVED_DIR=\$\{local\.served_dir\}"'
}

if [ -f "$HOSTSERVER" ] && reads_the_pool_before_building "$MAIN"; then ok; else
  bad "the warm no longer reads the pool through the host's own read-only server before it builds — every task is rebuilt and re-published on every run, or the server is a drifting copy, unchecked, or reachable off the loopback"
fi

# 21. A SNAPSHOT REFUSAL NO LONGER LOSES THE TURBO WARM, AND STILL TURNS RED.
#     `dependencies` may fail so the build and publish-turbo still run; that is
#     only safe while all of these hold together: the archive both phases name is
#     one path, stage-scripts deletes whatever the checkout put there, the
#     install phase writes it only after its scan, publish-snapshot is NOT
#     allowed to fail and dies on a missing archive. Then the build is ERROR, the
#     outcome metric counts a non-DONE, and the alert fires as it did before.
step_block() { # <text> <step id>
  printf '%s\n' "$1" | awk -v want="$2" '
    /^[[:space:]]*step[[:space:]]*\{/ { inside = 0 }
    $0 ~ ("id[[:space:]]*=[[:space:]]*\"" want "\"") { inside = 1 }
    inside { print }
  '
}

snapshot_failure_still_red() { # <main.tf>
  local code deps pub stage
  code=$(code_of "$1")
  deps=$(step_block "$code" dependencies)
  pub=$(step_block "$code" publish-snapshot)
  stage=$(step_block "$code" stage-scripts)
  [ -n "$deps" ] && [ -n "$pub" ] && [ -n "$stage" ] || return 1
  matches "$deps" 'allow_failure[[:space:]]*=[[:space:]]*true' || return 1
  ! matches "$pub" 'allow_failure' || return 1
  ! matches "$stage" 'allow_failure' || return 1
  matches "$deps" '"CACHE_ARCHIVE_OUT=\$\{local\.snapshot_archive\}"' || return 1
  matches "$pub" '"CACHE_ARCHIVE_IN=\$\{local\.snapshot_archive\}"' || return 1
  matches "$code" 'rm -f \$\{local\.snapshot_archive\}' || return 1
  matches "$code" 'rm -rf \$\{local\.served_dir\}'
}

publisher_refuses_a_missing_archive() { # <publish-cache-snapshot.sh>
  local code scan_at cp_at
  code=$(code_of "$1")
  matches "$code" '\[ -f "\$CACHE_ARCHIVE_IN" \] \|\| die' || return 1
  scan_at=$(grep -n 'scan_or_die "\$VERIFY"' "$1" | tail -1 | cut -d: -f1)
  cp_at=$(grep -n 'cp -- "\$ARCHIVE" "\$CACHE_ARCHIVE_OUT"' "$1" | head -1 | cut -d: -f1)
  [ -n "$scan_at" ] && [ -n "$cp_at" ] && [ "$cp_at" -gt "$scan_at" ]
}

if snapshot_failure_still_red "$MAIN" && publisher_refuses_a_missing_archive "$SHARED"; then ok; else
  bad "the dependencies step may fail but the build no longer ends red — a refused snapshot would be a DONE warm and the alert would never fire"
fi

# 22. THE PUBLISHER, RUN. Fake curl, gcloud and zstd on PATH: a served hash
#     costs no request, a hash already in the bucket is not uploaded, a file that
#     is not a whole zstd frame is refused, and uploads run in parallel within
#     the bound — the 16-minute one-at-a-time loop was build 6e721cc4.
publishes_incrementally() { # <warm-turbo.sh>
  local t rc peak
  t=$(mktemp -d)
  mkdir -p "$t/bin" "$t/turbo" "$t/served" "$t/state/inflight"
  cat >"$t/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url="${*: -1}"; out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && : >"$out"
echo "$url" >>"$FAKE_STATE/calls"
case "$url" in
  */upload/*)
    # Held until the bound is full, every upload has started, or starts have
    # stalled for half a second — so the peak measures the script's bound, not
    # how fast this machine forks.
    echo x >>"$FAKE_STATE/started"
    : >"$FAKE_STATE/inflight/$BASHPID"
    last=-1; still=0
    while :; do
      n=$(find "$FAKE_STATE/inflight" -type f | wc -l)
      s=$(wc -l <"$FAKE_STATE/started")
      echo "$n" >>"$FAKE_STATE/peaks"
      if [ "$n" -ge 16 ] || [ "$s" -ge "$FAKE_TOTAL" ]; then break; fi
      if [ "$s" = "$last" ]; then still=$((still + 1)); [ "$still" -ge 5 ] && break
      else still=0; last=$s; fi
      sleep 0.1
    done
    sleep 0.5
    find "$FAKE_STATE/inflight" -type f | wc -l >>"$FAKE_STATE/peaks"
    rm -f "$FAKE_STATE/inflight/$BASHPID"
    echo "$url" >>"$FAKE_STATE/uploads"
    printf 200 ;;
  *present*) printf 200 ;;
  *) printf 404 ;;
esac
FAKE
  printf '#!/bin/sh\necho faketoken\n' >"$t/bin/gcloud"
  printf '#!/bin/sh\nfor f; do :; done\n! grep -q CORRUPT "$f"\n' >"$t/bin/zstd"
  chmod +x "$t/bin/curl" "$t/bin/gcloud" "$t/bin/zstd"
  art() { { printf '\050\265\057\375'; printf '%s' "$2"; } >"$t/turbo/$1.tar.zst"; }
  art served1 ok; : >"$t/served/served1"
  art present1 ok
  art corrupt1 CORRUPT
  printf 'nozstd' >"$t/turbo/badmagic1.tar.zst"
  # 18: just past the bound of 16, so an unbounded loop shows a peak over it.
  for i in $(seq -w 1 18); do art "up$i" ok; done
  PATH="$t/bin:$PATH" FAKE_STATE="$t/state" FAKE_TOTAL=18 WARM_BUCKET=b WARM_TURBO_PREFIX=turbo/o/r/ \
    WARM_TURBO_DIR="$t/turbo" WARM_SERVED_DIR="$t/served" bash "$1" >/dev/null 2>&1
  rc=0
  [ "$(wc -l <"$t/state/uploads" 2>/dev/null || echo 0)" -eq 18 ] || rc=1
  ! grep -q served1 "$t/state/calls" 2>/dev/null || rc=1
  ! grep -qE 'present1|corrupt1|badmagic1' "$t/state/uploads" 2>/dev/null || rc=1
  peak=$(sort -n "$t/state/peaks" 2>/dev/null | tail -1)
  [ "${peak:-0}" -gt 1 ] && [ "${peak:-0}" -le 16 ] || rc=1
  rm -rf "$t"
  return "$rc"
}

if publishes_incrementally "$TURBO"; then ok; else
  bad "warm-turbo.sh, run against fake curl/gcloud/zstd, re-asked about a served hash, re-uploaded a present one, published a truncated artifact, or uploaded one at a time / unbounded"
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
  's@"CACHE_ARCHIVE_OUT=\${local\.snapshot_archive}",@@' \
  has_two_phases

# The mutation above removes the split; this one keeps it and hands the install
# step the credential anyway, which is the shape a later "just publish it here,
# it is one less step" edit actually takes. It is the only mutation that
# exercises the slice, and the reason the check was rewritten to use one.
mutate "the install step is handed the bucket" "$MAIN" \
  's@"CACHE_ARCHIVE_OUT=\${local\.snapshot_archive}",@&\n        "CACHE_BUCKET=${var.cache_bucket}",@' \
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
  's@gcs_upload "\$artifact"@gcloud storage cp "$artifact"@' \
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
  's@ | sha256sum -c -\\n\${local\.ensure_zstd}exec \${local\.staged_dir}/warm-turbo\.sh@\\n${local.ensure_zstd}exec ${local.staged_dir}/warm-turbo.sh@' \
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

mutate "the default build hard-codes build again" "$MAIN" \
  's@turbo run ${local\.turbo_task_args} --continue=dependencies-successful --cache-dir=@turbo run build --cache-dir=@' \
  runs_declared_tasks

mutate "the task-name validation widened to anything" "$VARS" \
  's@\^\[A-Za-z0-9\]\[A-Za-z0-9:#\@._/-\]{0,127}\$@.*@' \
  validates_task_names

mutate "the task list run without --continue" "$MAIN" \
  's@ --continue=dependencies-successful --cache-dir=@ --cache-dir=@' \
  runs_declared_tasks

# A bare --continue means `always`: a lint or typecheck whose ^build failed still
# runs, and a false pass is cached under the right hash for every PR to replay.
mutate "the task list run with a bare --continue" "$MAIN" \
  's@ --continue=dependencies-successful --cache-dir=@ --continue --cache-dir=@' \
  runs_declared_tasks

mutate "the build step inlines its own script and skips the derive" "$MAIN" \
  's@script = local\.build_step_script$@script = local.build_command@' \
  derives_tasks_by_default

mutate "side-effecting tasks warmed by default" "$VARS" \
  's@, "deploy\*", "release\*", "publish\*", "\*migrate\*", "clean\*"\]@]@' \
  excludes_by_default

mutate "derivation runs even when a list is given" "$MAIN" \
  's@derive_tasks    = var\.build_command == null && var\.turbo_tasks == null@derive_tasks    = var.build_command == null@' \
  derives_tasks_by_default

mutate "the derive step never reaches the build script" "$MAIN" \
  's@\\n${local\.derive_step}${local\.serve_step}@\\n${local.serve_step}@' \
  derives_tasks_by_default

mutate "an empty derivation builds anyway" "$MAIN" \
  's@failing the build so the warmer alert fires. >&2; exit 1; }@failing the build so the warmer alert fires'"'"' >\&2; }@' \
  derives_tasks_by_default

mutate "the exclude globs dropped from the derivation" "$MAIN" \
  's@derive-turbo-tasks\.cjs turbo\.json ${join(" ", \[for g in var\.turbo_tasks_exclude : "'"'"'${g}'"'"'"\])}@derive-turbo-tasks.cjs turbo.json@' \
  derives_tasks_by_default

mutate "test tasks warmed by default" "$VARS" \
  's@default     = \["test\*", "e2e\*", @default     = [@' \
  excludes_by_default

mutate "a quote allowed into an exclude glob" "$VARS" \
  's@\^\[A-Za-z0-9\*?\]\[A-Za-z0-9\*?:#\@._/-\]{0,127}\$@.*@' \
  excludes_by_default

mutate "a persistent task warmed" "$DERIVE" \
  's@  if (info\.persistent) why = "persistent";@  if (false) why = "persistent";@' \
  derivation_is_safe

mutate "a cache:false task warmed" "$DERIVE" \
  's@  else if (!info\.cached) why = "cache: false";@@' \
  derivation_is_safe

mutate "an unsafe task name passed to the shell" "$DERIVE" \
  's@  else if (!SAFE\.test(name)) why = "not a safe task name";@@' \
  derivation_is_safe

mutate "nothing derived falls back to build" "$DERIVE" \
  's@  process\.exit(5);@  process.stdout.write("build\n"); process.exit(0);@' \
  derivation_is_safe
mutate "the outcome metric counts every trigger's builds" "$ALERT" \
  's|    "resource\.labels\.build_trigger_id=.*||' \
  owns_its_alarm

mutate "the stale condition loses vector(0) and goes silent with no DONE at all" "$ALERT" \
  's| or vector(0))|)|' \
  owns_its_alarm

mutate "the failure condition counts only ERROR" "$ALERT" \
  's|outcome!=\\"DONE\\"|outcome=\\"ERROR\\"|' \
  owns_its_alarm

mutate "the policy notifies nobody" "$ALERT" \
  's|notification_channels = var\.alert_notification_channels|notification_channels = []|' \
  owns_its_alarm

mutate "the two branches joined with and" "$ALERT" \
  's|> 0) or ((sum|> 0) and ((sum|' \
  owns_its_alarm

mutate "a second condition the API refuses" "$ALERT" \
  's|^  conditions {$|  conditions {\n  }\n  conditions {|' \
  owns_its_alarm

mutate "the alert channels given an empty default" "$VARS" \
  's|^  type        = list(string)$|&\n  default     = []|' \
  requires_alert_channels

mutate "the empty channel list accepted" "$VARS" \
  's|length(var\.alert_notification_channels) > 0 \&\& alltrue|alltrue|' \
  requires_alert_channels

mutate "the read-only server bound to every interface" "$MAIN" \
  's@CI_TURBO_HOST=127\.0\.0\.1@CI_TURBO_HOST=0.0.0.0@' \
  reads_the_pool_before_building

mutate "the build no longer reads the pool first" "$MAIN" \
  's@\${local\.serve_step}\${local\.build_command}@${local.build_command}@' \
  reads_the_pool_before_building

mutate "the publisher not told what was served" "$MAIN" \
  's@^ *"WARM_SERVED_DIR=\${local\.served_dir}",$@@' \
  reads_the_pool_before_building

mutate "the server started without checking its digest" "$MAIN" \
  's@"echo .\${local\.server_sha}  \${local\.staged_dir}/turbo-cache-server\.py. | sha256sum -c - >/dev/null || exit 1\\n",@@' \
  reads_the_pool_before_building

mutate "the server copied into the module" "$MAIN" \
  's@\.\./ci-runner-host-pool/scripts/turbo-cache-server\.py"))@scripts/turbo-cache-server.py"))@' \
  reads_the_pool_before_building

mutate "the snapshot publish allowed to fail too" "$MAIN" \
  's@id     = "publish-snapshot"@&\n      allow_failure = true@' \
  snapshot_failure_still_red

mutate "a stale archive from the checkout no longer removed" "$MAIN" \
  's@rm -f \${local\.snapshot_archive}@true@' \
  snapshot_failure_still_red

mutate "a served directory from the checkout no longer emptied" "$MAIN" \
  's@rm -rf \${local\.served_dir}@true@' \
  snapshot_failure_still_red

mutate "the two phases name different archives" "$MAIN" \
  's@"CACHE_ARCHIVE_IN=\${local\.snapshot_archive}"@"CACHE_ARCHIVE_IN=/workspace/other.tar.gz"@' \
  snapshot_failure_still_red

mutate "the publisher accepts a missing archive" "$SHARED" \
  's@\[ -f "\$CACHE_ARCHIVE_IN" \] || die@true || die@' \
  publisher_refuses_a_missing_archive

mutate "a served hash checked against the bucket anyway" "$TURBO" \
  's@\[ -f "\$WARM_SERVED_DIR/\$hash" \]@false@' \
  publishes_incrementally

mutate "the uploads run one at a time again" "$TURBO" \
  's@^PUBLISH_PARALLEL=16$@PUBLISH_PARALLEL=1@' \
  publishes_incrementally

mutate "the concurrency bound removed" "$TURBO" \
  's@^    wait -n$@    :@' \
  publishes_incrementally

mutate "a truncated artifact published" "$TURBO" \
  's@\[ "\$magic" = "28b52ffd" \] || return 1@:@' \
  publishes_incrementally

printf 'cache-warmer selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
