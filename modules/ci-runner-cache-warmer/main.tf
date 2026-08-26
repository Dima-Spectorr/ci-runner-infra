# ci-runner-cache-warmer — the fleet-side identity that FILLS the caches a pool
# reads, so no repository has to.
#
# WHAT PROBLEM THIS CLOSES
#
# Two caches make this fleet fast, and until now both were the repository's job
# to fill:
#
#   the dependency snapshot   published by a workflow in the repository, running
#                             as `ci-runner-cache-publisher` through Workload
#                             Identity Federation. Four moving parts per repo: a
#                             workflow file, a WIF binding naming that exact
#                             file, a publisher account, and a schedule.
#   the remote BUILD cache    filled by nothing at all. The host serves reads
#                             (ci-runner-host-pool, turbo-cache-server.py) and
#                             refuses writes on purpose, so without a writer the
#                             store stays empty and every read is a polite miss.
#
# Per-repository wiring is the failure mode this fleet has already paid for: the
# one repository that hand-wired a build cache ran it stone cold for weeks while
# every run stayed green, because a cache that answers nothing looks exactly like
# a build that is merely slow. A capability every consumer opts into by hand is a
# capability most of them have wrong.
#
# So the fleet fills both. This module is a Cloud Build trigger on a schedule
# that checks out the repository's DEFAULT BRANCH, installs its dependencies,
# runs its build, and publishes what that produced: the dependency snapshot to
# `cache/<pool>/`, and the turbo artifacts to `turbo/<owner>/<repo>/`. A
# repository adds nothing, and a repository that already publishes snapshots by
# workflow can delete that workflow (see the README's migration note).
#
# WHY THE WRITER IS HERE AND NOT ON A HOST
#
# A host executes pull-request code. An identity that both runs job code and
# publishes cache content would let one pull request hand build input to every
# later build in the repository — the cross-slot boundary re-opened across hosts
# and across time. That argument is written out in ci-runner-cache-publisher and
# it has not changed; what changes here is only WHERE the trusted writer runs.
# Cloud Build, on the default branch, on a schedule, is an identity no pull
# request can reach.
#
# WHAT IT MAY DO — four grants, and each one is narrower than the obvious one
#
#   1. create objects under `turbo/<owner>/<repo>/`   (objectCreator)
#   2. read objects under the same prefix             (objectViewer)
#   3. create objects under `cache/<pool>/`           (objectCreator)
#   4. replace exactly `cache/<pool>/current`         (objectAdmin, one object)
#
# objectCreator carries create and NOT delete, and in Cloud Storage overwriting
# a live object requires delete — so "written once, never overwritten" stops
# being a convention and becomes something IAM refuses. That matters because the
# bucket's age bound is measured per generation: an object refreshed in place is
# a generation aged zero that never expires, and a poisoned entry inside it
# would be re-served forever. Grant 4 is the single exception, conditioned on
# one object name rather than a prefix, because the pointer must be replaceable
# to point anywhere.
#
# WHAT THIS DOES NOT PROTECT AGAINST, STATED PLAINLY
#
# The install and build steps run the repository's own dependencies, and every
# step in a Cloud Build can reach the metadata server and mint this account's
# token. A malicious dependency in the DEFAULT BRANCH's lockfile could therefore
# publish cache content of its choosing. That is a smaller step than it sounds —
# code in the default branch's dependency tree already runs on every host in the
# pool — and it is bounded by the grants above: create-only, in two prefixes of
# one bucket, for one repository. What it is NOT bounded by is a scrubbed
# environment, so do not add grants here on the assumption that the build steps
# are trusted. They are the repository's code.
#
# That is also why the account that FIRES the schedule is a second, separate
# identity that runs nothing: firing a Cloud Build trigger cannot be scoped to
# one trigger, so the account allowed to fire this one is allowed to fire the
# project's apply trigger too. Give that to the warmer and the bound above stops
# being true.
#
# The workflow-based publisher splits this into two jobs precisely because a
# GitHub OIDC token is exportable by anything in the job; that split does not
# translate to Cloud Build, where the credential is the build's own identity.
#
# Resources:
#   google_service_account            — the warmer, and the account that fires it
#   google_cloudbuildv2_repository    — the repo link, when the project is gen2
#   google_cloudbuild_trigger         — the build, manual-only, fired by the job
#   google_cloud_scheduler_job        — the schedule
#   google_storage_bucket_iam_member  — the four grants above

locals {
  # Both prefixes are written the same way in three modules — here, the host
  # pool's read grants, and the publisher's write grants. Spelled differently
  # anywhere and the failure is silent: the warmer writes where no host looks,
  # and every host logs a cache that has not been published yet.
  cache_prefix = "cache/${var.pool_name}/"
  turbo_prefix = "turbo/${var.github_owner}/${var.github_repo}/"

  bucket_resource  = "projects/_/buckets/${var.cache_bucket}/objects/"
  pointer_resource = "${local.bucket_resource}${local.cache_prefix}current"

  trigger_name = coalesce(var.name, "ci-cache-warmer-${lower(replace(var.github_repo, "_", "-"))}")

  # 2nd gen if the project has a connection, 1st gen otherwise — a read of what
  # the project already has, not a preference. The two are separate APIs and a
  # trigger built against the generation the project does NOT use is created
  # without complaint and never fires. Same determination as
  # ci-runner-apply-trigger, deliberately spelled the same way.
  gen2 = var.github_connection != null

  connection_id = local.gen2 ? (
    startswith(coalesce(var.github_connection, ""), "projects/")
    ? var.github_connection
    : "projects/${var.project_id}/locations/${var.region}/connections/${var.github_connection}"
  ) : null

  repository_id = local.gen2 ? coalesce(var.github_repository, try(google_cloudbuildv2_repository.repo[0].id, "")) : null

  # The publishing script the snapshot half runs. It is READ FROM THE REPOSITORY
  # ROOT rather than copied into this module, and that is on purpose: it is the
  # same file the workflow-based publisher runs, it encodes the archive layout
  # and the scan rules a host applies on arrival, and a second copy would drift
  # from the host's expectations without anything failing until a hydrate
  # silently stops working. scripts/ci/cache-warmer.selftest.sh asserts the path
  # still resolves, because a module vendored without its repository root would
  # otherwise fail at plan time with a message about a missing file and nothing
  # about why this module wants one two directories up.
  #
  # NOTHING IS ESCAPED ON ITS WAY INTO A STEP, AND THAT IS MEASURED. Every `$`
  # used to go in DOUBLED, which was right for the field this module no longer
  # uses. Cloud Build reads `$X` and `${X}` in a build config as a SUBSTITUTION
  # before the container sees them, and a shell script pasted whole into `args`
  # is dense with both: the trigger accepted it happily and the API refused at
  # FIRE time, in a nightly build nobody watches, with
  #
  #   invalid value for 'build.substitutions': key in the template
  #   "CACHE_EXPAND_FLOOR_BYTES" is not a valid built-in substitution
  #
  # `$$` was the escape for that, and it stopped being needed one release later
  # when every script moved into `script` (see below) — but it stayed, and it
  # cost this module its whole turbo half: `--cache-dir="$$WARM_TURBO_DIR"`
  # reached bash as the PID followed by a literal, for months, silently.
  #
  # THE SUBSTITUTION PASS DOES NOT TOUCH A `script` FIELD AT ALL. Measured with a
  # one-step build against this fleet's own trigger, 2026-08-26, both halves:
  #
  #   `8f91196b`   loose    `$PROBE_VAR` reached the shell as `$PROBE_VAR` and
  #                         expanded to the step's env value; `$$PROBE_VAR`
  #                         reached it as `$$PROBE_VAR`, i.e. the PID.
  #   `f314e153`   STRICT   identical — and `$_NO_SUCH_SUBSTITUTION_KEY` was
  #                         accepted too, where the same text in `args` is the
  #                         fire-time refusal quoted above. The pass never reads
  #                         the field, so there is no key for it to reject.
  #
  # So a script is handed over exactly as written, an escape is a corruption
  # rather than a protection, and a caller's `$HOME` or `$(git rev-parse HEAD)`
  # now means what it says. Anything moved back into `args` — do not — would
  # need the doubling again, and would hit the 10,000-character cap first.
  #
  # NOT `substitution_option = "ALLOW_LOOSE"` either, which is what this error's
  # first search result suggests and what the loose probe above deliberately
  # used: it makes unmatched keys resolve to the EMPTY STRING instead of
  # failing, so a build starts and runs a script whose every variable reference
  # has been erased. This is one of the few places where the loud failure is the
  # good outcome.
  # AND EVERY STEP CARRIES ITS SCRIPT IN `script`, NEVER IN `args`. A build step
  # argument is capped at 10,000 characters and the API refuses the whole build
  # at FIRE time — again, not at apply time — with
  #
  #   invalid build: invalid .steps field: build step 0 arg 1 too long
  #   (max: 10000)
  #
  # The publishing script alone is an order of magnitude past that, so
  # `entrypoint = "bash"` + `args = ["-c", script]` cannot carry it and no amount
  # of escaping changes that. `script` has no such cap, and it honours the file's
  # own `#!/usr/bin/env bash`, so both scripts run under the interpreter they were
  # written for. Setting `entrypoint` beside `script` is an error — that is why
  # these steps have none.

  # AND THE WHOLE BUILD STAYS UNDER ~128 KiB, WHICH IS THE THIRD REFUSAL AND THE
  # ONLY ONE THAT NEVER SAYS ANYTHING AT ALL.
  #
  # A build message past roughly 128 KiB is accepted by the API, given a build id,
  # and then simply never scheduled. It fetches its source, finishes SETUPBUILD,
  # and stops: no BUILD phase, every step `QUEUED`, no log line, no error, until
  # the queue TTL expires an hour later. Measured live, by bisection, in one
  # region of this fleet: a 125 KB config reached BUILD in two seconds, a 140 KB
  # config never reached it at all, and neither the machine type, the custom
  # service account, the step images nor regional capacity made any difference.
  # The first version of this module inlined the 91 KB publishing script into TWO
  # steps and shipped a 199 KB config, so every warm it fired sat in that hole.
  #
  # So the scripts are handed over ONCE, gzipped, and unpacked into /workspace —
  # the one directory Cloud Build carries between steps. That takes the config from
  # 199 KB to about 55 KB and it removes the escaping problem above for the three
  # scripts as a side effect: base64 has no `$` in its alphabet, so there is
  # nothing left in them for Cloud Build to read as a substitution. The four steps
  # that follow are three lines each.
  #
  # `length()` counts bytes, and the precondition on the trigger below fails the
  # APPLY if the total ever climbs back toward the cliff. That is the point of it:
  # this limit's natural failure mode is a nightly build nobody watches, and the
  # publishing script grows.
  staged_dir = "/workspace/.ci-warmer"

  publish_gz = base64gzip(file("${path.module}/../../scripts/ci/publish-cache-snapshot.sh"))
  scan_gz    = base64gzip(file("${path.module}/../../scripts/ci/scan-cache-credentials.sh"))
  turbo_gz   = base64gzip(file("${path.module}/scripts/warm-turbo.sh"))

  # THE CREDENTIAL-SCAN LIBRARY IS STAGED AS A SIBLING, NOT CONCATENATED.
  #
  # `publish-cache-snapshot.sh` sources `$HERE/scan-cache-credentials.sh` unless
  # `scan_credentials_or_die` is already defined, and refuses to publish at all if
  # the function is missing by the time anything scans. When the publisher was
  # pasted into a step as text there was no disk to source from and the library's
  # text had to be prepended, with `SCAN_INLINE_LIBRARY=1` to suppress its
  # standalone `usage:` check. Staged as a real file it needs neither: `$HERE`
  # resolves to the directory below and the warm loads the library by exactly the
  # route the workflow does, which is one fewer way for the two to diverge.
  #
  # Quoted heredoc delimiters, so the shell expands nothing in a blob it is only
  # decoding, and `chmod +x` so each script is executed through its OWN shebang
  # rather than whatever interpreter the step image happens to call it with.
  stage_script_raw = <<-EOT
    #!/bin/sh
    set -eu
    mkdir -p ${local.staged_dir}
    base64 -d <<'PUBLISH_GZ_EOF' | gzip -d > ${local.staged_dir}/publish-cache-snapshot.sh
    ${local.publish_gz}
    PUBLISH_GZ_EOF
    base64 -d <<'SCAN_GZ_EOF' | gzip -d > ${local.staged_dir}/scan-cache-credentials.sh
    ${local.scan_gz}
    SCAN_GZ_EOF
    base64 -d <<'TURBO_GZ_EOF' | gzip -d > ${local.staged_dir}/warm-turbo.sh
    ${local.turbo_gz}
    TURBO_GZ_EOF
    chmod +x ${local.staged_dir}/publish-cache-snapshot.sh ${local.staged_dir}/scan-cache-credentials.sh ${local.staged_dir}/warm-turbo.sh
    ${local.stage_scan_allow}
  EOT

  stage_script = local.stage_script_raw

  # AND EVERY STEP CHECKS THE DIGEST BEFORE IT RUNS WHAT IT FOUND THERE.
  #
  # /workspace is the only directory that survives between steps, and it is also
  # the directory the repository's own install and build run in. Staging the
  # scripts there and executing them by path would mean the publishing step runs
  # a file the untrusted step in the middle was free to rewrite — which is
  # precisely the ordering property the two-phase split above is for. It costs
  # one line to keep: the digest comes from the module, out of the same `file()`
  # read that produced the blob, so a tampered staged script fails the step
  # loudly instead of being published from.
  #
  # This does not widen or narrow what a compromised dependency can ultimately
  # do — it can mint this account's token from its own step either way, as the
  # header says. It keeps the step boundary meaning what it says it means.
  # The scan library is checked with the publisher and not on its own, because
  # the publisher is the only thing that loads it: a step that verified it and
  # then ran nothing would prove nothing, and one that ran the publisher without
  # verifying it would publish a tree scanned by whatever the build step left in
  # that file.
  publish_sha = filesha256("${path.module}/../../scripts/ci/publish-cache-snapshot.sh")
  scan_sha    = filesha256("${path.module}/../../scripts/ci/scan-cache-credentials.sh")
  turbo_sha   = filesha256("${path.module}/scripts/warm-turbo.sh")

  # AND getcap HAS TO BE IN THE IMAGE, WHICH IN A NODE IMAGE IT IS NOT.
  #
  # The publisher refuses to build a snapshot it cannot scan for file
  # capabilities, because a host refuses to unpack one: `getcap` missing is a
  # refusal on both sides, deliberately, and not a skip. `node:22` — the default
  # build image, and the image the snapshot phase runs in — ships without
  # libcap2-bin, so the warm died on that check having installed the whole
  # dependency tree first. The workflow this module replaces installed it in a
  # `run:` line (docs/publishing-a-cache-snapshot.md); nothing was carrying that
  # over here.
  #
  # Best-effort, and the failure mode is what makes it safe to be: if the install
  # does not work the publisher's own check fires one line later with the message
  # that named the package. Both package managers are tried because the images
  # are inputs — a repository may set `build_image` to an Alpine variant, where
  # the manager is `apk`. There the binary is in `libcap-getcap`, NOT in
  # `libcap`: current Alpine ships /usr/sbin/getcap from that subpackage alone
  # (pkgs.alpinelinux.org, checked 2026-08-24), and `libcap` on its own installs
  # the shared library and no scanner. Older Alpine did carry it in `libcap`, so
  # that is the fallback rather than the first try. No `$` anywhere in here, so
  # it needs no substitution escaping; adding one means escaping it.
  ensure_getcap = "if ! command -v getcap >/dev/null 2>&1; then\n  if command -v apt-get >/dev/null 2>&1; then\n    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends libcap2-bin >/dev/null 2>&1 || true\n  elif command -v apk >/dev/null 2>&1; then\n    apk add --no-cache libcap-getcap >/dev/null 2>&1 || apk add --no-cache libcap >/dev/null 2>&1 || true\n  fi\nfi\n"

  # AND THE CREDENTIAL SCAN NEEDS THE REPOSITORY'S ALLOWLIST, FOR THE SAME REASON
  # THE getcap INSTALL DOES: the workflow this module replaces passed
  # CACHE_SCAN_ALLOW_FILE in BOTH of its jobs, and nothing was carrying it over.
  #
  # The scan refuses a staged tree holding what looks like an embedded
  # credential, and dependency trees legitimately contain such files — a test
  # fixture that is a PEM, a package README quoting `https://user:pass@host`.
  # Refusing them is right; the way past is a named, commented digest, never a
  # widened rule. `url-embedded-basic-auth` in particular is excusable ONLY from
  # the allowlist FILE, where a comment says which package ships it, and never
  # from the bare-hex CACHE_SCAN_ALLOW_DIGESTS. So the file is the only route,
  # and a warmer that cannot pass one cannot warm such a repository at all.
  #
  # Resolved at warm time against the checkout rather than asserted in a plan.
  # The path is a convention with a default, so the ordinary repository
  # configures nothing; a repository with no such file excuses nothing, which is
  # the correct starting state. But an operator who NAMED a path and mistyped it
  # must not get that same silence — an allowlist that is not there reads exactly
  # like one that worked — so a non-default path that is missing fails, and it
  # fails in the STAGING step, before the install rather than after it.
  #
  # `null` means the convention and is the default; a named path is a claim the
  # operator made and is therefore required to exist; `""` turns the lookup off.
  #
  # CAPTURED BEFORE ANY REPOSITORY CODE RUNS, AND READ FROM THE CAPTURE AFTERWARDS.
  # The publish phase re-scans the archive it is handed rather than trusting the
  # phase that produced it — an artifact that crossed a step boundary is input —
  # and an allowlist re-read from the live checkout would walk straight through
  # that: the build step runs the repository's lifecycle scripts and can write to
  # /workspace, so it could rewrite BOTH the archive and the file saying which
  # digests are excusable, and have the credentialed phase accept the result.
  # Copying it in `stage-scripts`, which runs before the install, closes that
  # ordering: the file both phases read is the reviewed one.
  #
  # It is a shape, not a boundary, and the module is honest about which: the
  # copy still lives in /workspace, and Cloud Build cannot scope a step's
  # identity, so a build step that wanted to publish forged content can already
  # mint the token and do it directly (see the README). What this removes is the
  # ordering gap and the whole accidental class — a build that rewrites
  # `.github/` for its own reasons and silently widens the scan.
  scan_allow_default  = ".github/cache-scan-allow.txt"
  scan_allow_rel      = var.cache_scan_allow_file == null ? local.scan_allow_default : var.cache_scan_allow_file
  scan_allow_path     = local.scan_allow_rel == "" ? "" : "/workspace/${local.scan_allow_rel}"
  scan_allow_staged   = "${local.staged_dir}/cache-scan-allow.txt"
  scan_allow_required = var.cache_scan_allow_file != null && var.cache_scan_allow_file != ""

  # Goes into the staging script, which reaches the shell verbatim, so a `$` here
  # would mean what it says; there is none, and `sha256sum` is printed as its own
  # command rather than substituted because a value read at warm time is the
  # honest thing to print.
  stage_scan_allow = local.scan_allow_path == "" ? "" : join("", [
    "if [ -f '${local.scan_allow_path}' ]; then\n",
    "  cp '${local.scan_allow_path}' '${local.scan_allow_staged}'\n",
    "  echo '[warm] credential-scan allowlist captured before any repository code ran: ${local.scan_allow_rel}'\n",
    "  sha256sum '${local.scan_allow_staged}'\n",
    "else\n",
    local.scan_allow_required
    ? "  echo '[warm] cache_scan_allow_file names ${local.scan_allow_rel}, which is not in the checkout - refusing, because an allowlist that is not there excuses nothing and reads exactly like one that worked' >&2\n  exit 1\n"
    : "  echo '[warm] no credential-scan allowlist at ${local.scan_allow_rel}; the scan will excuse nothing'\n",
    "fi",
  ])

  # And the publisher reads the CAPTURE, never the checkout. The path is
  # validated, along with the quote that would end the string it is pasted
  # into — a `$` in it is now harmless, but a `'` still is not.
  ensure_scan_allow = local.scan_allow_path == "" ? "" : join("", [
    "if [ -f '${local.scan_allow_staged}' ]; then\n",
    "  CACHE_SCAN_ALLOW_FILE='${local.scan_allow_staged}'\n",
    "  export CACHE_SCAN_ALLOW_FILE\n",
    "fi\n",
  ])

  run_publish = "#!/bin/sh\nset -eu\necho '${local.publish_sha}  ${local.staged_dir}/publish-cache-snapshot.sh\n${local.scan_sha}  ${local.staged_dir}/scan-cache-credentials.sh' | sha256sum -c -\n${local.ensure_getcap}${local.ensure_scan_allow}exec ${local.staged_dir}/publish-cache-snapshot.sh\n"
  run_turbo   = "#!/bin/sh\nset -eu\necho '${local.turbo_sha}  ${local.staged_dir}/warm-turbo.sh' | sha256sum -c -\nexec ${local.staged_dir}/warm-turbo.sh\n"

  # HOW THE REPOSITORY IS INSTALLED AND BUILT — WORKED OUT AT WARM TIME, FROM THE
  # REPOSITORY, RATHER THAN STATED BY WHOEVER WIRES THE WARMER UP.
  #
  # These defaults are the difference between a capability every consumer opts
  # into by hand and one that is simply on. An input like `prepare_command` looks
  # harmless — it is one line of tfvars — but it is one line that must be RIGHT,
  # in a root nobody revisits, about a repository whose package manager changes
  # without telling Terraform. Wrong, it does not fail the apply: the install
  # fails inside a nightly build, or worse succeeds and builds nothing, and both
  # read from the outside as a cache that is merely cold.
  #
  # So the ladder below asks the repository. A lockfile is the one statement
  # about package managers every repository already makes, keeps current, and
  # commits — the same fact the repository's own CI reads.
  #
  # ONE LINE, deliberately: the prepare half crosses into the build as a Cloud
  # Build environment entry (`CACHE_PREPARE=…`), and an entry carrying newlines is
  # a thing to find out about in a nightly log. `join(" ", …)` is what keeps the
  # ladder readable here and a single line there.
  install_ladder = join(" ", [
    "if [ -f pnpm-lock.yaml ]; then corepack enable >/dev/null 2>&1 || true; pnpm install --frozen-lockfile @FLAGS@;",
    # Berry and classic disagree on both flags, and which one a repository is on
    # is not knowable from the lockfile name. Berry first, classic as the fallback.
    "elif [ -f yarn.lock ]; then corepack enable >/dev/null 2>&1 || true; yarn install --immutable @YARN@ || yarn install --frozen-lockfile @FLAGS@;",
    "elif [ -f package-lock.json ]; then npm ci @FLAGS@;",
    "elif [ -f package.json ]; then npm install --no-audit --no-fund @FLAGS@;",
    "else echo '[warm] no lockfile and no package.json at the repository root; nothing to install'; fi",
  ])

  # THE SNAPSHOT'S INSTALL RUNS NO LIFECYCLE SCRIPTS. It is unpacked as root on
  # every host in the pool, and install-time scripts are the cheapest place to
  # put code in someone else's build.
  install_scriptfree = replace(replace(local.install_ladder, "@FLAGS@", "--ignore-scripts"), "@YARN@", "--mode=skip-build")

  # THE BUILD'S INSTALL DOES run them, and that is not an inconsistency. This step
  # exists to run the repository's build — arbitrary code from the default branch,
  # by definition — so refusing its lifecycle scripts buys nothing and stops most
  # workspaces from building at all, which was the single most common reason a
  # consumer had to override anything here.
  #
  # It re-installs rather than inheriting the step above because the publishing
  # script stages the package stores under `mktemp -d`, and only `/workspace`
  # survives between Cloud Build steps. With npm that is invisible; pnpm's
  # `node_modules` is a tree of links INTO that store, so the build would open a
  # workspace whose every dependency dangles, fail, and leave the turbo prefix
  # empty — silently. One extra install a night is the cheaper side of that.
  install_full = replace(replace(local.install_ladder, "@FLAGS@", ""), "@YARN@", "")

  # Handed over as written. This used to be escaped along with everything else,
  # which meant a `prepare_command` holding `$HOME` or `$(git rev-parse HEAD)` —
  # neither an unreasonable thing to write — silently became the PID and a
  # literal. See the measurement above.
  prepare_command = coalesce(var.prepare_command, local.install_scriptfree)

  # `--cache-dir` is passed from the same variable the publishing step reads, so
  # the two cannot drift. The old default relied on turbo's own default matching
  # whatever `--cache-dir` the repository's CI happened to pass; when it did not,
  # the warm published an empty directory and reported success.
  #
  # RENDERED BY TERRAFORM, NOT EXPANDED BY THE SHELL, and that is the whole point
  # of this line. It used to read `--cache-dir="$WARM_TURBO_DIR"`, taking the
  # value from the env below — and every `$` in a step command was doubled on its
  # way out, so what Cloud Build actually ran was:
  #
  #   npx --no-install turbo run build --cache-dir="$$WARM_TURBO_DIR"
  #
  # Read off the EXECUTED build resource, not the trigger template
  # (`5ea57da5`, 2026-08-26), so substitution resolution had
  # already happened and the `$$` survived it: the `$$` escape is unescaped in
  # `args`, and the `script` field is handed to the shell verbatim. In bash
  # `"$$WARM_TURBO_DIR"` is the PID followed by a literal, so turbo wrote its
  # cache to `/workspace/<pid>WARM_TURBO_DIR`, the publishing step looked at
  # `node_modules/.cache/turbo`, found no directory, and exited 0 — which it is
  # right to do, because a repository with no turbo pipeline lands there too.
  #
  # So every warm since the turbo half shipped published ZERO artifacts and
  # reported success. The symptom is an empty `turbo/<owner>/<repo>/` prefix and
  # a host-side cache that never hits; nothing anywhere goes red.
  #
  # Interpolating the value here emits a command with no `$` in it at all, so
  # the escaping cannot reach it and the fix does not depend on what Cloud Build
  # does with `$$` in a `script`. The single-source property is unchanged — this
  # is the same `var.turbo_cache_dir` the publishing step's env carries — and
  # the self-test now asserts the RENDERED command, which is the thing that was
  # never checked.
  #
  # The interpolation stays even though an override may now spell a shell
  # variable: the DEFAULT should not depend on the env block below being wired,
  # and a command with no `$` in it cannot be got wrong by a later change to how
  # this module writes a step.
  #
  # The `;` is load-bearing and is asserted by the self-test: the ladder ends in
  # `fi`, and `fi npx …` is a syntax error the whole build step dies on before
  # anything runs — a green apply, a red nightly build, an empty cache.
  build_command = coalesce(var.build_command, join(" ", [
    "${local.install_full};",
    "npx --no-install turbo run build --cache-dir=${local.turbo_cache_dir_arg}",
  ]))

  # Single-quoted so a directory with a space or a glob character in it is one
  # argument and not three. `'` itself is closed, escaped and reopened rather
  # than rejected: the value reaches a shell command line, and the failure of
  # getting that wrong is a build step that dies on a syntax error at fire time.
  turbo_cache_dir_arg = "'${replace(var.turbo_cache_dir, "'", "'\\''")}'"

  build_step_script = "#!/usr/bin/env bash\n${local.build_command} || echo '[warm] build failed; publishing what it produced'\n"

  # Every byte this module hands Cloud Build, which is what the cliff above is
  # measured against. The env entries and the trigger's own fields add a little on
  # top, hence a budget well under the observed 128 KiB rather than at it.
  build_config_bytes = sum([
    length(local.stage_script),
    length(local.run_publish),
    length(local.build_step_script),
    length(local.run_turbo),
    length(local.run_publish),
  ])

  # WHO FIRES THE TRIGGER IS A DIFFERENT IDENTITY FROM WHO RUNS THE BUILD, and
  # this is not symmetry for its own sake. `cloudbuild.builds.create` — the
  # permission a scheduler needs to fire anything — has no resource-level
  # binding for a single trigger: the narrowest grant that fires THIS build also
  # fires every other trigger in the project, and in these projects that
  # includes ci-runner-apply-trigger, which runs terraform as an account with
  # real authority. Held by the warmer, that permission would be reachable by
  # the repository's own dependency tree (see WHAT THIS DOES NOT PROTECT
  # AGAINST), and the honest bound above — create-only, two prefixes, one bucket
  # — would simply not be true.
  scheduler_email = coalesce(var.scheduler_service_account, try(google_service_account.firer[0].email, ""))
}

resource "google_service_account" "warmer" {
  project = var.project_id
  # 30 characters is the cap; `-warm` costs five, so the base is VALIDATED to 25
  # rather than truncated to it. Truncation is the silent failure: two pools
  # whose ids differ only after the 25th character would resolve to one account
  # holding both prefixes' grants.
  account_id   = "${var.account_id}-warm"
  display_name = "CI cache warmer (${var.pool_name})"
  description  = "Builds ${var.github_owner}/${var.github_repo}@${var.branch} on a schedule and publishes the dependency snapshot and the Turborepo artifacts the ${var.pool_name} pool reads. Must NEVER be attached to a host, which executes pull-request code."
}

# It holds nothing but the right to fire the trigger and to act as the warmer,
# and it runs no code at all — nothing in this build ever presents it.
resource "google_service_account" "firer" {
  count = var.scheduler_service_account == null ? 1 : 0

  project      = var.project_id
  account_id   = "${var.account_id}-fire"
  display_name = "CI cache warmer scheduler (${var.pool_name})"
  description  = "Fires ${local.trigger_name} on a schedule and nothing else. Separate from the warmer because firing a trigger cannot be scoped to one trigger, and the warmer runs the repository's own dependency code."
}

# --- what it may write --------------------------------------------------------

resource "google_storage_bucket_iam_member" "warmer_creates_turbo_artifacts" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-repositorys-build-cache"
    description = "Create objects under ${local.turbo_prefix} only. Create and not delete: a turbo hash names the digest of its inputs, so a name is only ever written once and an attempt to replace one is a 403 rather than a generation aged zero that outlives the bucket's age bound."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.turbo_prefix}\")"
  }
}

# Read, so the warmer can tell an artifact it has already published from one it
# has not and skip the upload. Viewer carries no create and no delete, so this
# widens nothing the grant above did not already decide.
resource "google_storage_bucket_iam_member" "warmer_reads_turbo_artifacts" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-repositorys-build-cache"
    description = "Read objects under ${local.turbo_prefix} only."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.turbo_prefix}\")"
  }
}

# The snapshot half. Identical in shape and in reasoning to
# ci-runner-cache-publisher's grants, because it is the same write against the
# same prefix by a different identity — see that module's header for why the
# authority to create and the authority to replace the pointer are two
# resources rather than one objectAdmin.
resource "google_storage_bucket_iam_member" "warmer_creates_snapshots" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-pools-cache-prefix"
    description = "Create objects under ${local.cache_prefix} only. No other pool's snapshots, and nothing outside the cache tree."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.cache_prefix}\")"
  }
}

resource "google_storage_bucket_iam_member" "warmer_reads_snapshots" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-pools-cache-prefix"
    description = "Read objects under ${local.cache_prefix} only — the pointer's current generation, before swapping it."
    expression  = "resource.name.startsWith(\"${local.bucket_resource}${local.cache_prefix}\")"
  }
}

# `==` and not `startsWith`, and the difference is the whole point: a prefix
# condition here would hand back the delete authority the split above spent two
# resources removing.
resource "google_storage_bucket_iam_member" "warmer_replaces_pointer" {
  bucket = var.cache_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.warmer.email}"

  condition {
    title       = "only-this-pools-current-pointer"
    description = "Replace ${local.cache_prefix}current only. The pointer holds no cache content; the snapshots it names are write-once."
    expression  = "resource.name == \"${local.pointer_resource}\""
  }
}

# A build that names its own service account writes its logs nowhere by default
# and Cloud Build refuses it at submit time. The bucket-free spelling is
# CLOUD_LOGGING_ONLY on the build (below); this grant is what lets the account
# actually write them.
resource "google_project_iam_member" "warmer_writes_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.warmer.email}"
}

# --- where the source comes from ----------------------------------------------

# Registered here rather than required as an input, because a connection is
# authorized once for a whole GitHub account and its repositories are then
# registered one at a time. Skipped when the caller names an existing link:
# registering the same remote twice under one connection is an ALREADY_EXISTS
# error rather than a no-op, and this module and ci-runner-apply-trigger will
# routinely be pointed at the same repository.
resource "google_cloudbuildv2_repository" "repo" {
  count = local.gen2 && var.github_repository == null ? 1 : 0

  project           = var.project_id
  location          = var.region
  name              = lower(replace("${var.github_owner}-${var.github_repo}-warm", "/[^a-zA-Z0-9-]/", "-"))
  parent_connection = local.connection_id
  remote_uri        = "https://github.com/${var.github_owner}/${var.github_repo}.git"
}

# --- the build ----------------------------------------------------------------

# MANUAL, and fired only by the scheduler below. Not a push trigger: warming is
# not a per-commit job. A busy repository would run one of these per merge, each
# one a full install and a full build, to publish artifacts the next one
# recomputes — and the snapshot half would write a new write-once object every
# time, which the bucket's age bound cannot clean up any faster than they arrive.
resource "google_cloudbuild_trigger" "warm" {
  project     = var.project_id
  location    = var.region
  name        = local.trigger_name
  description = "Build ${var.github_owner}/${var.github_repo}@${var.branch} on a schedule and publish the dependency snapshot and Turborepo artifacts for the ${var.pool_name} pool."
  disabled    = var.disabled

  dynamic "source_to_build" {
    for_each = local.gen2 ? [1] : []
    content {
      repository = local.repository_id
      ref        = "refs/heads/${var.branch}"
      repo_type  = "GITHUB"
    }
  }

  dynamic "source_to_build" {
    for_each = local.gen2 ? [] : [1]
    content {
      uri       = "https://github.com/${var.github_owner}/${var.github_repo}.git"
      ref       = "refs/heads/${var.branch}"
      repo_type = "GITHUB"
    }
  }

  service_account = google_service_account.warmer.id

  build {
    timeout = var.build_timeout

    options {
      logging      = "CLOUD_LOGGING_ONLY"
      machine_type = var.machine_type
    }

    # 0. THE SCRIPTS, UNPACKED INTO /workspace.
    #
    #    Handed over once and gzipped rather than pasted into each step that runs
    #    them: two inline copies of a 91 KB script is a 199 KB build message, and
    #    a build message past ~128 KiB is accepted and then never scheduled, in
    #    silence. See the note beside `staged_dir` for the measurement.
    #
    #    It runs in the gcloud image because that one is Debian and certainly has
    #    `base64` and `gzip`; it carries no credential and touches nothing but
    #    /workspace.
    step {
      id     = "stage-scripts"
      name   = var.gcloud_image
      script = local.stage_script
    }

    # 1. DEPENDENCIES, AND THE SNAPSHOT PACKED BUT NOT PUBLISHED.
    #
    #    This is the publishing script's BUILD phase, and running it here rather
    #    than reimplementing an install is the whole reason the script is shared:
    #    it exports the cache variables the prepare command must honour, stages
    #    exactly the tool directories a host will accept, and applies the same
    #    scan rules the host applies on arrival — so a snapshot a host would
    #    refuse fails here, loudly, once, instead of silently on every boot.
    #
    #    The prepare also leaves the workspace installed, which is what the build
    #    step below needs. Cloud Build carries /workspace between steps; nothing
    #    else survives.
    #
    #    No credential is needed to pack, and the step that runs third-party
    #    install code is deliberately not the step that uploads. That is the same
    #    two-job split the workflow-based publisher documents, mapped onto two
    #    steps — weaker here, because every step in a build can still reach the
    #    metadata server, but the ordering costs nothing and the day Cloud Build
    #    can scope a step's identity this is already the right shape.
    step {
      id     = "dependencies"
      name   = var.build_image
      script = local.run_publish
      env = [
        "CACHE_PREPARE=${local.prepare_command}",
        "CACHE_ARCHIVE_OUT=/workspace/ci-cache-snapshot.tar.gz",
        "CACHE_MAX_BYTES=${var.snapshot_max_bytes}",
      ]
    }

    # 2. THE BUILD, whose only purpose here is the artifacts it leaves behind.
    #    It is allowed to fail: a default branch that is briefly broken should
    #    not also stop the dependency snapshot from being published, and the
    #    turbo step below simply finds fewer artifacts. The exit code is logged
    #    by Cloud Build either way, so a permanently broken default branch is
    #    still visible.
    #
    #    WARM_TURBO_DIR is the same value the publishing step reads, and the
    #    default build command passes it to turbo as `--cache-dir`: where the
    #    artifacts are written and where they are looked for are one input, not
    #    two that have to be kept equal by whoever wires this up. TURBO_CACHE_DIR
    #    carries the same value to a build_command a repository overrode, which
    #    turbo honours without a flag.
    step {
      id     = "build"
      name   = var.build_image
      script = "#!/usr/bin/env bash\n${local.build_command} || echo '[warm] build failed; publishing what it produced'\n"
      env = [
        "TURBO_TELEMETRY_DISABLED=1",
        "CI=true",
        "WARM_TURBO_DIR=${var.turbo_cache_dir}",
        "TURBO_CACHE_DIR=${var.turbo_cache_dir}",
      ]
    }

    # 3. THE TURBO ARTIFACTS.
    step {
      id     = "publish-turbo"
      name   = var.gcloud_image
      script = local.run_turbo
      env = [
        "WARM_BUCKET=${var.cache_bucket}",
        "WARM_TURBO_PREFIX=${local.turbo_prefix}",
        "WARM_TURBO_DIR=${var.turbo_cache_dir}",
        "WARM_MAX_BYTES=${var.max_artifact_bytes}",
      ]
    }

    # 4. THE DEPENDENCY SNAPSHOT, published — the same script again, in its
    #    PUBLISH phase, which re-scans the archive it is handed rather than
    #    trusting the phase that produced it. An artifact that crossed a step
    #    boundary is input.
    step {
      id     = "publish-snapshot"
      name   = var.gcloud_image
      script = local.run_publish
      env = [
        "CACHE_ARCHIVE_IN=/workspace/ci-cache-snapshot.tar.gz",
        "CACHE_POOL=${var.pool_name}",
        "CACHE_BUCKET=${var.cache_bucket}",
        "CACHE_MAX_BYTES=${var.snapshot_max_bytes}",
      ]
    }
  }

  lifecycle {
    # THE CLIFF, TURNED INTO A PLAN FAILURE. Past roughly 128 KiB Cloud Build
    # accepts the build, hands back an id, and never schedules it: no BUILD
    # phase, no log, no error, for the whole queue TTL. Nothing downstream of an
    # apply can notice that — a warmer in that state is indistinguishable from a
    # cache that is merely cold, which is the exact failure this module exists to
    # end. So it is caught here, where somebody is reading the output.
    precondition {
      condition     = local.build_config_bytes < 110000
      error_message = "the warmer's build config is ${local.build_config_bytes} bytes of inline script, and Cloud Build silently never schedules a build past roughly 128 KiB — it fetches source, finishes SETUPBUILD, and sits with every step QUEUED until the queue TTL expires, with no error anywhere. Hand the new script over gzipped through the staging step instead of inlining it, the way publish-cache-snapshot.sh and warm-turbo.sh already are."
    }

    precondition {
      # A gen2 project must resolve to a repository link, and an unresolved one
      # is an empty string rather than an error — which applies cleanly and
      # produces a trigger with no source that fails at fire time, hours later,
      # in a log nobody is reading.
      condition     = !local.gen2 || local.repository_id != ""
      error_message = "the warmer for '${var.pool_name}' is configured for a 2nd-generation connection but no repository link resolved: pass github_repository, or let this module register one by leaving it null."
    }
  }
}

# --- the schedule -------------------------------------------------------------

# The only thing that ever fires this trigger. A warmer nobody runs is the cold
# cache this module exists to end, so the schedule is not optional and has no
# "null means never" spelling.
resource "google_cloud_scheduler_job" "warm" {
  project     = var.project_id
  region      = var.region
  name        = "${local.trigger_name}-scheduled"
  description = "Run ${local.trigger_name}. The warmer has no push trigger — this is the only thing that fires it."
  schedule    = var.schedule
  time_zone   = var.schedule_time_zone

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/triggers/${google_cloudbuild_trigger.warm.trigger_id}:run"

    # The branch the trigger already names. `:run` takes a plain branch name and
    # refuses a regex, which is why this module takes the branch as a literal
    # and derives everything else from it.
    body = base64encode(jsonencode({
      source = {
        branchName = var.branch
      }
    }))

    headers = {
      "Content-Type" = "application/json"
    }

    # Cloud Scheduler mints this token through a per-project service agent, so a
    # cross-project account fails at fire time with an error naming the agent
    # rather than the account.
    oauth_token {
      service_account_email = local.scheduler_email
    }
  }

  # A warm that is still running when the next one fires is a warm that is
  # taking longer than its period, not one that needs a second copy competing
  # for the same write-once object names.
  retry_config {
    retry_count = 0
  }

  lifecycle {
    precondition {
      # Same check, same wording, same reason as ci-runner-apply-trigger's: the
      # token is minted by a per-project service agent, so a cross-project
      # account applies cleanly and fails at fire time naming the agent.
      condition     = endswith(local.scheduler_email, "@${var.project_id}.iam.gserviceaccount.com") || can(regex("^[0-9]+-compute@developer\\.gserviceaccount\\.com$", local.scheduler_email))
      error_message = "the warmer's scheduler account must live in ${var.project_id}: Cloud Scheduler mints its token through a per-project service agent, so a cross-project account fails at fire time with an error naming the service agent, not the account."
    }
  }
}

# Firing a trigger is an API call like any other, and the account making it needs
# to be allowed to make it. Left out, the schedule applies cleanly and every fire
# is a 403 in the scheduler's log — a warmer that has never run, reported
# nowhere the cache's readers can see.
#
# It is granted to the FIRER and never to the warmer: the permission cannot be
# scoped to one trigger, so whoever holds it can run every trigger in the
# project — including the one that applies terraform.
resource "google_project_iam_member" "scheduler_runs_the_trigger" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${local.scheduler_email}"
}

# The build runs AS the warmer, so whoever fires it must be allowed to act as
# the warmer. One account, named — not a project-level serviceAccountUser, which
# would be "may act as every account in the project" and is the usual way this
# grant is written.
resource "google_service_account_iam_member" "scheduler_acts_as_warmer" {
  service_account_id = google_service_account.warmer.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.scheduler_email}"
}
