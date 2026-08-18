#!/usr/bin/env bash
# =============================================================================
# publish-cache-snapshot.sh — build one pool's dependency snapshot and publish it
#
# USAGE — two phases, in two jobs, and the split is the security argument
#   build   (no credential):  CACHE_PREPARE='npm ci --ignore-scripts' \
#                             CACHE_ARCHIVE_OUT=snap.tar.gz bash <this>
#   publish (the credential): CACHE_POOL=… CACHE_BUCKET=… \
#                             CACHE_ARCHIVE_IN=snap.tar.gz bash <this>
#
#   Run as one phase — everything unset but CACHE_PREPARE/CACHE_POOL/CACHE_BUCKET
#   — and it still works, for a local `CACHE_DRY_RUN=1` and for nothing else. See
#   docs/publishing-a-cache-snapshot.md, which ships the two-job workflow.
#
# WHY TWO JOBS
#   CACHE_PREPARE is `npm ci`, `mvn dependency:go-offline`, `pip download`. Every
#   one of those executes third-party code — lifecycle scripts, sdist builds,
#   Maven plugins — and a job holding the publisher credential exports
#   ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN to every process in it. One
#   compromised transitive dependency in that job mints its own OIDC token,
#   publishes a snapshot of its choosing, and every host in the pool unpacks it as
#   root. Scrubbing the environment does not fix it; not being in the room does.
#   So the phase that runs other people's code has `contents: read` and nothing
#   else, and the phase that holds the credential only receives an archive,
#   re-scans it, and uploads it.
#
# WHERE THIS RUNS
#   On a GitHub-hosted runner, in the workflow file named by the publisher
#   module's `publish_workflow_path`, on the repository's default ref —
#   authenticating as `ci-runner-cache-publisher` through Workload Identity
#   Federation. NEVER on a pool host: a host executes pull-request code, and a
#   host that could publish would let one job's leftovers become the starting
#   cache of every later host in the pool.
#
#   That boundary is enforced by IAM, not by this file. What this file adds is
#   the half IAM cannot see — WHAT goes into the archive:
#
#     * dependencies installed from the DEFAULT BRANCH into an empty tree. Never
#       an archive of a host's live cache: a slot's cache holds whatever job last
#       ran there (including a fork's pull request), and a host's master holds
#       only what the image baked plus what an earlier snapshot brought, so
#       archiving either either re-admits pull-request output or compounds an
#       earlier mistake.
#     * scanned with the SAME rules the host applies on arrival, so a snapshot
#       that a host would refuse fails here — loudly, once, in a run someone is
#       watching — instead of silently on every boot of every host. The packed
#       archive is then unpacked and scanned AGAIN, in every phase: an artifact
#       that crossed a job boundary is input, and so is one this process packed,
#       since only the second scan sees what the archive actually holds.
#
# WHAT IT WRITES
#   gs://<bucket>/cache/<pool>/<UTC>-<digest>.tar.gz   write-once, never replaced
#   gs://<bucket>/cache/<pool>/current                 one line: the object name
#
#   The snapshot name is qualified and never reused because the bucket measures
#   age PER GENERATION: an object refreshed in place is a generation aged zero
#   that never expires, which is the age bound configured and doing nothing. The
#   publisher's IAM grant carries create and not delete for the same reason, so
#   an attempt to reuse a name fails with a 403 rather than quietly succeeding.
#
#   The pointer is swapped with --if-generation-match, so two publishers racing
#   produce one winner and one loud failure, never a pointer naming a snapshot
#   that was not fully written.
#
# INPUTS (environment)
#   CACHE_PREPARE     required when building. The command that installs
#                     dependencies. Runs in the current directory with the cache
#                     variables exported. MUST be lifecycle-script-free —
#                     `--ignore-scripts`, `--no-deps`, `-o`/offline — because it
#                     runs third-party code; see WHY TWO JOBS.
#   CACHE_POOL        required when publishing. The pool name — the same value the
#                     pool and publisher modules were given. Decides the prefix.
#   CACHE_BUCKET      required when publishing. The bucket NAME, not a gs:// URL.
#   CACHE_ARCHIVE_OUT optional. Build, scan, pack to this path, upload nothing.
#   CACHE_ARCHIVE_IN  optional. Skip the install; verify and publish this archive.
#   CACHE_MAX_BYTES   optional. Refuse an archive larger than this. Default 4 GiB,
#                     matching the pools' own default bound: a larger snapshot is
#                     not a slow hydrate, it is one every host silently refuses.
#   CACHE_DRY_RUN     optional. Build and scan, upload nothing. For a first run.
#   CACHE_PREPARE_TIMEOUT
#                     optional, seconds. Default 3600. The prepare command runs
#                     in its own process group and the group is killed when it
#                     returns or when this expires — an install that daemonises
#                     must not outlive the scan that is supposed to bound it.
#   CACHE_SCAN_ALLOW_DIGESTS
#                     optional. Full sha256 digests, separated by commas or
#                     whitespace, of files the EMBEDDED-CREDENTIAL CONTENT pass
#                     may excuse — for a dependency that ships a PEM in its own
#                     test fixtures, which lands under a hash name no filename
#                     rule can see. It excuses a `private-key-header` hit and
#                     NOTHING else: a registry token or a URL password is never
#                     excusable, and the link, setuid, capability and
#                     credential-filename passes are what a host itself enforces,
#                     so an exception there would publish a snapshot every host
#                     rejects. Note the asymmetry — a host runs no content pass
#                     of its own, so an entry here is the LAST word on that file,
#                     which then lands unpacked as root on every host in the
#                     pool. Set it in BOTH jobs, as a literal in the workflow
#                     file. Every use is logged. The refusal prints the digest.
#   CACHE_SCAN_ALLOW_FILE
#                     optional. Path to a checked-in file holding the same
#                     digests, one per line, EACH followed by a `#` comment
#                     naming the package that ships it. Use this rather than the
#                     variable once there is more than a handful: one real
#                     monorepo's install lands 71 of them, and 71 hashes in a
#                     YAML scalar is a list nobody can review. Both may be set;
#                     the entries are unioned. Set it in BOTH jobs, for the same
#                     reason as the variable.
# =============================================================================
set -euo pipefail

# The tool directories a host will accept, by name. A host drops every top-level
# entry that is not on ITS list, so a name added here without being added there
# is shipped, downloaded and discarded — bytes against the size bound for
# nothing. Kept in the same order as the host's for diffing by eye.
CACHE_DIRS=(npm yarn pnpm-store go-mod pip uv m2 nuget composer)

die() { printf 'publish-cache-snapshot: %s\n' "$*" >&2; exit 1; }
log() { printf 'publish-cache-snapshot: %s\n' "$*"; }

# A path from the staged tree, made safe to print. The tree is populated by the
# prepare command — third-party install code — and a Linux filename may legally
# hold a newline or an escape sequence. Printed raw into an Actions log, one
# carrying `\n::add-mask::` or `\n::error::` writes workflow commands from the job
# that holds the publishing credential; more cheaply, a newline forges log lines
# and hides the rest of the refusal. Non-printables become `?`, which keeps the
# fact that something was there rather than quietly dropping it.
safe_path() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' '?'; }

CACHE_MAX_BYTES="${CACHE_MAX_BYTES:-4294967296}"
# An install that hangs on a registry must not hold the group open forever; the
# reap below cannot run until this returns. One hour, well under the workflow's
# own job timeout so the failure is this script's and names its own cause.
# Validated, because `timeout 0` means NO timeout: the one value that turns this
# bound off is also the one an operator reaches for to mean "don't wait".
CACHE_PREPARE_TIMEOUT="${CACHE_PREPARE_TIMEOUT:-3600}"
case "$CACHE_PREPARE_TIMEOUT" in
  '' | 0 | *[!0-9]* ) die "CACHE_PREPARE_TIMEOUT must be a positive whole number of seconds (0 disables the timeout entirely, which is the one thing it may not do): $(safe_path "$CACHE_PREPARE_TIMEOUT")" ;;
esac

# The content digests the embedded-credential pass may excuse.
#
# It exists because a hit there is not automatically a leak. A dependency's
# PAYLOAD can carry a PEM test fixture — `pnpm install` of one real monorepo
# lands a 4 KiB private key from a package's own tests — and in a
# content-addressed store it arrives under a hash name, so the credential-
# FILENAME pass cannot see it and the content pass refuses that snapshot on every
# run, forever. The two ways out that do not need this are deleting the pattern
# and widening it into uselessness, which is how a scan stops being a bound.
#
# Read from the consumer, not from a list in this repository: which fixture a
# consumer's dependency tree drags in is theirs to know, and the entry belongs in
# their workflow or in a file beside it, on a line next to a comment naming the
# package. It must be set in BOTH jobs — the publishing job re-scans what it
# received, and one excused only in the build job fails there instead.
#
# Validated strictly. A malformed entry that quietly matched nothing would read
# exactly like one that worked, and a SHORT one is the real hazard: treated as a
# prefix it would excuse everything beginning with those characters.
SCAN_ALLOW_DIGESTS=()

# One entry, from either source. `where` names the source in every refusal, so an
# operator staring at "non-hex entry" knows which of the two to go and edit.
SCAN_ALLOW_WHERE=()
scan_allow_add() { # <digest> <where>
  local d=$1 where=$2
  case "$d" in
    *[!0-9a-fA-F]* ) die "$where holds a non-hex entry: $(safe_path "$d")" ;;
  esac
  [ "${#d}" = 64 ] \
    || die "$where entries are full sha256 digests — 64 hex characters, not ${#d}"
  SCAN_ALLOW_DIGESTS+=("$(printf '%s' "$d" | tr 'A-F' 'a-f')")
  # Kept beside the digest so the excusal can say WHERE the exception came from
  # and, for the file form, what its line called the package. The log is the
  # only artifact a reviewer has after the runner is gone; one that names
  # neither is an audit trail back to a hash.
  SCAN_ALLOW_WHERE+=("$where")
}

# The same digests, from a file, because past a handful the variable stops being
# reviewable. A YAML scalar cannot carry a comment per line, and a bare list of
# 71 hashes is one nobody reads — which is how an allowlist becomes the hole it
# was meant to close. The file gives every digest a line of its own and a name
# beside it.
#
# The name is REQUIRED, not encouraged: a digest with no comment is refused. The
# rule everywhere else in this layer is that a fixture is excused by the package
# that ships it and never by the hash alone, and this is the one place that rule
# can actually be enforced rather than written down.
#
# Parsed here, at the top, BEFORE the prepare command runs. The build job's
# checkout is writable by the install it is about to run, so an allowlist read
# after third-party code executed would be one that code could have extended.
if [ -n "${CACHE_SCAN_ALLOW_FILE:-}" ]; then
  [ -f "$CACHE_SCAN_ALLOW_FILE" ] \
    || die "CACHE_SCAN_ALLOW_FILE names no readable file: $(safe_path "$CACHE_SCAN_ALLOW_FILE") — an allowlist that is not there excuses nothing and reads exactly like one that worked"
  scan_allow_lineno=0
  while IFS= read -r scan_allow_line || [ -n "$scan_allow_line" ]; do
    scan_allow_lineno=$((scan_allow_lineno + 1))
    # A whole-line comment or a blank line is structure, not an entry.
    #
    # Strip the leading whitespace and judge what is left, rather than trying to
    # spell "optional indentation then `#`" as a glob. `[ \t]*'#'*` reads like
    # that and is not: the bracket matches exactly ONE character and the `*`
    # matches anything, so every indented line holding a `#` anywhere — an
    # entry that an editor auto-indented, or one pasted out of the docs — was
    # skipped as a comment. Silently: the digest simply never loaded, and the
    # operator then watches the scan refuse a fixture they can see in the file.
    scan_allow_bare=${scan_allow_line#"${scan_allow_line%%[![:space:]]*}"}
    case "$scan_allow_bare" in
      '' | '#'* ) continue ;;
    esac
    scan_allow_digest=${scan_allow_line%%#*}
    # Nothing before the `#`, or no `#` at all: either way there is a digest
    # standing on its own authority.
    [ "$scan_allow_digest" != "$scan_allow_line" ] \
      || die "CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno excuses a digest with no comment naming the package that ships it — a hash on its own is one nobody can review: $(safe_path "$scan_allow_line")"
    # Trailing `#` with nothing after it is a comment marker, not a name.
    scan_allow_name=$(printf '%s' "${scan_allow_line#*#}" | tr -d '[:space:]')
    scan_allow_label=$(printf '%s' "${scan_allow_line#*#}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$scan_allow_name" ] \
      || die "CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno has an empty comment — name the package that ships the file"
    scan_allow_digest=$(printf '%s' "$scan_allow_digest" | tr -d '[:space:]')
    [ -n "$scan_allow_digest" ] \
      || die "CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno has a comment but no digest: $(safe_path "$scan_allow_line")"
    # The line's own words go into the audit trail. safe_path, because this is
    # a file on disk and the refusal it may end up in is printed by the job that
    # holds the publishing credential.
    scan_allow_where="CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno ($(safe_path "$scan_allow_label"))"
    scan_allow_add "$scan_allow_digest" "$scan_allow_where"
  done <"$CACHE_SCAN_ALLOW_FILE"
  scan_allow_count=${#SCAN_ALLOW_DIGESTS[@]}
  [ "$scan_allow_count" -gt 0 ] \
    || die "CACHE_SCAN_ALLOW_FILE is set but $(safe_path "$CACHE_SCAN_ALLOW_FILE") holds no digests — a file of nothing but comments is not an allowlist"
  command -v sha256sum >/dev/null 2>&1 \
    || die "CACHE_SCAN_ALLOW_FILE is set but sha256sum is not on PATH — the allowlist cannot be evaluated"
  log "the content scan may excuse $scan_allow_count digest(s) named in $(safe_path "$CACHE_SCAN_ALLOW_FILE")"
fi

if [ -n "${CACHE_SCAN_ALLOW_DIGESTS:-}" ]; then
  # read -ra rather than unquoted expansion: the latter globs, and a digest is
  # attacker-adjacent input that should never reach pathname expansion.
  # -d '' as well as IFS: plain `read` stops at the first NEWLINE whatever IFS
  # says, so a YAML block scalar holding three digests would parse one and drop
  # two — unvalidated, unreported, and reading exactly like a list that worked.
  IFS=$', \n\t' read -rd '' -a SCAN_ALLOW_RAW <<<"$CACHE_SCAN_ALLOW_DIGESTS" || true
  for d in ${SCAN_ALLOW_RAW[@]+"${SCAN_ALLOW_RAW[@]}"}; do
    [ -n "$d" ] || continue
    scan_allow_add "$d" CACHE_SCAN_ALLOW_DIGESTS
  done
  # A digest nobody can compute is a digest that excuses nothing, silently.
  command -v sha256sum >/dev/null 2>&1 \
    || die "CACHE_SCAN_ALLOW_DIGESTS is set but sha256sum is not on PATH — the allowlist cannot be evaluated"
fi

SCAN_ALLOW_MATCHED_WHERE=""
scan_digest_is_allowed() { # <sha256>
  local i=0 d
  SCAN_ALLOW_MATCHED_WHERE=""
  for d in ${SCAN_ALLOW_DIGESTS[@]+"${SCAN_ALLOW_DIGESTS[@]}"}; do
    if [ "$d" = "$1" ]; then
      SCAN_ALLOW_MATCHED_WHERE=${SCAN_ALLOW_WHERE[$i]}
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Which phases this invocation is. Building and publishing are independent: the
# workflow runs one of each, and a local dry run is build-only.
BUILDING=1; [ -z "${CACHE_ARCHIVE_IN:-}" ] || BUILDING=0
PUBLISHING=1
[ -z "${CACHE_ARCHIVE_OUT:-}" ] || PUBLISHING=0
[ -z "${CACHE_DRY_RUN:-}" ]     || PUBLISHING=0

[ "$BUILDING" = 1 ] || [ "$PUBLISHING" = 1 ] \
  || die "CACHE_ARCHIVE_IN with CACHE_ARCHIVE_OUT or CACHE_DRY_RUN asks this to neither build nor publish"

# NEVER BOTH IN ONE PROCESS. This is the two-job split, enforced rather than
# described — see WHY TWO JOBS in the header, which until now was an argument the
# code did not make.
#
# Building means running CACHE_PREPARE: arbitrary third-party install code, as
# this uid, in this process tree. Publishing means holding a credential that can
# write the object every host in the fleet boots from. Together they put the OIDC
# token inside the blast radius of a postinstall script, and they reopen the one
# gap the digest pin can only narrow: between the last `assert_archive_unchanged`
# and gcloud's own open of the file there are hundreds of milliseconds of Python
# start-up, and a process that escaped the reap (`setsid` leaves the group, and
# `kill -- -$pgid` cannot follow it) wins that race by polling. Splitting the
# phases removes the racer instead of shrinking the window.
#
# The cost is that this cannot be run end-to-end by hand, which is the point.
# CACHE_DRY_RUN=1 builds and scans; CACHE_ARCHIVE_OUT then CACHE_ARCHIVE_IN does
# the same thing the workflow does, in two invocations.
[ "$BUILDING" = 0 ] || [ "$PUBLISHING" = 0 ] \
  || die "refusing to build and publish in one process: the phase that runs CACHE_PREPARE must not be the phase that holds the credential. Use CACHE_DRY_RUN=1 to build and scan, or CACHE_ARCHIVE_OUT here and CACHE_ARCHIVE_IN in a separate run."

if [ "$BUILDING" = 1 ]; then
  : "${CACHE_PREPARE:?CACHE_PREPARE is required (the command that installs dependencies)}"
fi

if [ "$PUBLISHING" = 1 ]; then
  : "${CACHE_POOL:?CACHE_POOL is required (the pool name)}"
  : "${CACHE_BUCKET:?CACHE_BUCKET is required (the snapshot bucket name)}"

  # The same charset the pool and publisher modules validate, for the same reason
  # one step further down: this value becomes an object prefix, and a host refuses
  # a pointer naming anything outside its own prefix.
  case "$CACHE_POOL" in
    *[!a-z0-9-]* | '' | -* | *- ) die "CACHE_POOL must be lowercase letters, digits and hyphens: $(safe_path "$CACHE_POOL")" ;;
  esac
  case "$CACHE_BUCKET" in
    gs://* ) die "CACHE_BUCKET is a bucket NAME, not a gs:// URL" ;;
    *[!a-z0-9._-]* | '' | .* | -* | *. | *- | *..* ) die "CACHE_BUCKET is not a valid bucket name" ;;
  esac

  command -v gcloud >/dev/null 2>&1 || die "gcloud is not on PATH"
fi

# THE EVENT GUARD, AND IT IS NOT REDUNDANT WITH THE IAM BINDING.
#
# The binding pins repository, workflow file and ref. It cannot pin the EVENT,
# and `refs/heads/<default>` is what `pull_request_target`, `workflow_run` and
# `issue_comment` runs assert — while a `pull_request_target` run is the standard
# way to execute fork-authored code. If this workflow is ever edited to trigger
# on one of those, the binding still resolves and the credential is still handed
# out; this check is what turns that edit into a failed run instead of a poisoned
# snapshot. Note that a workflow CALLED as a reusable workflow reports its
# CALLER's event here, which is exactly the case the binding alone cannot see.
# Absent GITHUB_EVENT_NAME means "not on GitHub Actions", which is a local dry run
# and is allowed to proceed.
case "${GITHUB_EVENT_NAME:-}" in
  '' | schedule | workflow_dispatch | push ) : ;;
  * ) die "refusing to publish from a '$(safe_path "$GITHUB_EVENT_NAME")' run — a snapshot may only be built by schedule, workflow_dispatch or push. Runs triggered by pull_request_target, workflow_run or issue_comment execute untrusted code while asserting the default branch." ;;
esac

command -v getcap >/dev/null 2>&1 \
  || die "getcap is not installed (libcap2-bin). A host refuses a snapshot it cannot scan for file capabilities, so building one that cannot be scanned here is building one nothing will accept."

STAGE=$(mktemp -d)
ARCHIVE_DIR=$(mktemp -d)
# Created only once the prepare command has returned, so it is named in the trap
# before it exists.
VERIFY=""
trap 'rm -rf "$STAGE" "$ARCHIVE_DIR" ${VERIFY:+"$VERIFY"}' EXIT
chmod 0700 "$STAGE" "$ARCHIVE_DIR"

# --- the scan --------------------------------------------------------------------
#
# The content patterns of the embedded-credential pass, each with the name its
# failure reports. ONE list, used both to find a hit and to explain it: a second
# copy would be a second thing that has to agree, which is the whole failure mode
# this script's duplicated-but-selftested rules exist to avoid.
#
# The URL schemes a `user:pass@` may follow. ONE definition, used to FIND the hit
# and to validate the scheme the refusal prints, for the same reason the pattern
# list itself is one list.
#
# The anchor is not cosmetic. Unanchored, `://[^/@ "]+:[^/@ "]+@` matches any 5
# bytes in that shape, and since the pass reads binary files too (it must — see
# the grep below) a dependency cache full of gzip and nupkg blobs trips it by
# chance: measured over 4 GiB of random bytes, about three times. Those hits are
# unexcusable by design and land on a hash-named compressed blob, so the operator
# has no move left except deleting the rule — which is how a scan stops being a
# bound. Requiring a real scheme costs the rule nothing, because embedded basic
# auth is BY DEFINITION preceded by one.
#
# The VCS branch is `(git|hg|bzr|svn)(\+(ssh|https?|file))?` and not a hand-listed
# few: pip and npm both accept VCS-pinned dependencies over plain http, so
# `git+https` being on the list while `git+http` was not was an oversight, not a
# policy. Widening it costs the false-positive rate nothing — every branch is
# still a literal scheme followed by `://`.
URL_SCHEME_ALT='https?|ftps?|sftp|ssh|(git|hg|bzr|svn)(\+(ssh|https?|file))?|mongodb(\+srv)?|postgres(ql)?|mysql|mariadb|rediss?|amqps?|s3|gs|ldaps?|smtps?|imap'

# `_authToken` carries a left boundary for the same reason the URL rule carries
# an anchor, and it was found the same way — on a real tree. Bare, it also
# matches the TAIL of a longer identifier, and `googleapis` ships four doc
# comments reading `"authToken": "my_authToken"` in a 456 KB `.d.ts`. That hit
# is unexcusable by design and lands on a hash-named store object, so the
# operator's only move is deleting the rule that guards the one credential
# nothing may allowlist past. The forms an `_authToken` is actually written in
# all keep matching — `//registry.example.com/:_authToken=…` in an `.npmrc`,
# the same line indented, the same key in JSON, in `npm config` output, in a
# URL query string. What stops matching, in the text forms above, is the tail
# of a longer identifier, which is never the credential.
#
# A bracket expression is why EVERY grep that runs these patterns pins
# `LC_ALL=C`, and that is not tidiness: with GNU grep on glibc in a UTF-8
# locale `[^A-Za-z0-9]` matches a CHARACTER, so a byte that is not valid UTF-8
# in front of the token makes the whole rule miss. The boundary is free under
# the byte locale and a hole without it. Two of those greps decide whether a
# file is refused; the three in `explain_credential_hit` only decide what the
# refusal prints, and an unpinned one there means the gate refuses a file and
# then cannot say which rule caught it — on exactly the bytes this boundary was
# written for.
CREDENTIAL_PATTERNS=(
  "registry-auth-token|(^|[^A-Za-z0-9])_authToken"
  "url-embedded-basic-auth|(^|[^A-Za-z0-9+.-])($URL_SCHEME_ALT)://[^/@[:space:]\"]+:[^/@[:space:]\"]+@"
  "private-key-header|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)

# The same walks a host runs on arrival, in the same order and with the same
# rules. Deliberately duplicated rather than shared: the host's copy is embedded
# in a startup script that cannot source anything from this repository, and the
# two must agree, so the selftest asserts they hold the same rules.
#
# The host's `-links +1` clause is NOT here, and its absence is deliberate rather
# than forgotten. On a host, a multi-linked file in the cache is an alias to
# something outside it. In a staging tree it is routine and harmless: `pnpm
# install` hardlinks store content into the workspace's node_modules, raising
# nlink on files inside `pnpm-store`, and the archive is packed with
# --hard-dereference so every member is stored as its own content anyway. Keeping
# the clause here would make every pnpm publish fail on a condition that cannot
# reach a host — and the predictable response to that is deleting the check.
# What replaces it is `archive_is_flat`, which reads the bytes actually shipped.

# Says what the content pass actually caught. It needs saying because the pass
# finds a FILE, and in a dependency cache a file's name is a content hash —
# `.../pnpm-store/v3/files/72/93a11b…e02` names nothing anyone can act on, so the
# refusal reads identically whether it caught a leaked registry token or a
# package's test fixture. A fail-closed gate nobody can read is one that gets
# deleted the second time it fires.
#
# It prints WHERE and WHICH, never WHAT: the matched text is a candidate secret,
# and a CI log is readable by everyone who can see the run, so echoing it there
# would publish the very thing the gate exists to contain. Counts, line numbers
# and a URL scheme are not the secret; the value on that line is, and it stays in
# the file. Whoever investigates re-runs the install and looks locally.
# Which rules a file trips, space-separated. Two callers need this: the reporter
# below, and the allowlist, which excuses some labels and never others.
# EVERY label, never the first: a file is excusable only when every rule it trips
# is an excusable one, so a file holding a token AND a key header must
# come back with both or it becomes excusable. And a grep that ERRORS must not
# read as "did not match" — a dropped label is the direction that makes a file
# excusable, so an error refuses. (`die` inside a command substitution exits only
# that subshell, which yields an empty label string: no match, no excusal, and
# the caller refuses. Fail-closed either way.)
matched_labels() { # <file>
  local file="$1" entry rc out=""
  for entry in "${CREDENTIAL_PATTERNS[@]}"; do
    rc=0
    # LC_ALL=C, for the reason spelled out at the bulk grep in `scan_or_die`:
    # a bracket expression is character-wise in a UTF-8 locale, so an invalid
    # byte in front of a pattern makes it match nothing. Both greps or neither
    # — this one decides which labels a file trips, and a label dropped here is
    # a file that becomes excusable.
    LC_ALL=C grep -qa -E -e "${entry#*|}" "$file" 2>/dev/null || rc=$?
    [ "$rc" -le 1 ] \
      || die "the content scan could not test $(safe_path "$file") against ${entry%%|*} (grep exited $rc)"
    if [ "$rc" = 0 ]; then out="$out ${entry%%|*}"; fi
  done
  printf '%s' "${out# }"
}

# Whether a digest may excuse this file at all, asked before any digest is
# computed. Three rules match; two of them are excusable and one never is.
#
# `registry-auth-token` is absolute. An `_authToken` line in the cache is the
# attack this whole pass exists for, and no dependency ships one as a fixture,
# so there is nothing to trade off — an operator must not be able to allowlist
# their way past a live registry credential. Being absolute is what obliges the
# pattern to be exact rather than generous: a rule with no escape hatch turns
# every false positive into a demand to delete it, which is why the boundary on
# `_authToken` above is part of this decision and not a tidy-up.
#
# `url-embedded-basic-auth` used to be absolute too, and that was wrong in a way
# only the fleet's first real tree showed. A `user:password@` URL is what a
# package's README, its `.d.ts` and its URL-parser tests are FULL of: measured on
# one monorepo, 40 store objects trip it and every one is a published
# placeholder — `got`'s readme, `@types/node`'s `url.d.ts`, `zod`'s parser tests,
# `pg-pool`'s connection-string example. An unexcusable rule with a 40-file false
# -positive floor does not get respected; it gets deleted, and then nothing
# watches for the real thing. So it is excusable on the same terms as a PEM
# fixture: by digest, named, in a diff someone reviewed.
#
# The floor is per-label, and the two labels get different numbers because the
# thing that makes a digest safe is ENTROPY, not size, and only one of them has
# any. An allowlist entry is itself a published hash — it is checked into the
# repository — so the question for both is the same: given everything already
# known about the file, does its sha256 narrow the secret?
#
#   private-key-header, floor 0. The bytes under that header are key material.
#   Even a 230-byte ed25519 fixture has more entropy in it than an attacker can
#   walk, so its digest tells them nothing they can use. Excusable at any size,
#   which is what keeps `ssh2`'s smaller fixtures excusable at all.
#
#   url-embedded-basic-auth, floor 1024. Here the carrier is usually PUBLIC — a
#   README, a `.d.ts`, a parser test, all of them in a tarball on npm — so the
#   only unknown in the preimage is the credential itself. A 47-byte
#   `mongodb://user:pass@host` is worse still: the refusal already prints byte
#   count, line count, match line and scheme, which pins it to one field. Below
#   the floor the hash is an offline oracle with no rate limit, so the entry
#   that would excuse it is one nobody may write down.
SCAN_EXCUSABLE_MIN_BYTES=1024
# The floor for one label, or a refusal. The default arm is what makes this a
# whitelist rather than "anything but the token rule": a rule added to the scan
# later is unexcusable until someone gives it a number here, in a diff.
scan_label_min_bytes() { # <label>
  case "$1" in
    private-key-header ) printf '0' ;;
    url-embedded-basic-auth ) printf '%s' "$SCAN_EXCUSABLE_MIN_BYTES" ;;
    * ) return 1 ;;
  esac
}

# Whether a digest may excuse this file at all, asked before any digest is
# computed. EVERY label the file trips must be excusable at that file's size: a
# README documenting both a registry token and a connection string is a file no
# list may excuse, however innocent either half looks alone.
scan_hit_is_excusable() { # <file>
  local labels label floor size
  labels=$(matched_labels "$1")
  # No label means the grep failed inside a subshell, not that the file is
  # clean — this is only ever called on a file the scan already matched. The
  # call sites are all `if` conditions, which switches `set -e` off for this
  # whole body, so without this an errored grep would walk the empty loop and
  # fall through to a size test that any real file passes.
  [ -n "$labels" ] || return 1
  size=$(wc -c <"$1") || return 1
  for label in $labels; do
    floor=$(scan_label_min_bytes "$label") || return 1
    [ "$size" -ge "$floor" ] || return 1
  done
}

# Whether the REFUSAL may print this file's digest — a strictly narrower question
# than whether a list may excuse it, and the diff that fused the two was wrong.
# Excusing costs an operator a reviewed line naming the package; printing costs
# nothing and reaches everyone who can read the run. So the log offers a digest
# only where the file's own bytes are the secret, which is the private-key case
# and only it. For a URL credential the operator computes the digest off the log
# with CACHE_DRY_RUN=1 — the same route a fixture has always had.
SCAN_PRINTABLE_LABELS='private-key-header'
scan_hit_digest_is_printable() { # <file>
  local labels label
  labels=$(matched_labels "$1")
  [ -n "$labels" ] || return 1
  for label in $labels; do
    case " $SCAN_PRINTABLE_LABELS " in
      *" $label "* ) ;;
      * ) return 1 ;;
    esac
  done
  # Size still matters here for the reason it always did: this rule matches a
  # HEADER, and a 60-byte header in front of a short string is not key material.
  [ "$(wc -c <"$1")" -ge "$SCAN_EXCUSABLE_MIN_BYTES" ]
}

explain_credential_hit() { # <tree> <file>
  local root="$1" file="$2" entry label pat n scheme
  {
    printf 'the embedded-credential pass matched in %s\n' "$(safe_path "${file#"$root"/}")"
    printf '  file: %s bytes, %s line(s)\n' "$(wc -c <"$file")" "$(wc -l <"$file")"
    for entry in "${CREDENTIAL_PATTERNS[@]}"; do
      label="${entry%%|*}" pat="${entry#*|}"
      n=$(LC_ALL=C grep -ca -E -e "$pat" "$file" 2>/dev/null) || n=0
      [ "$n" -gt 0 ] || continue
      printf '  %s: %s match(es), first on line %s\n' \
        "$label" "$n" "$(LC_ALL=C grep -na -m1 -E -e "$pat" "$file" 2>/dev/null | cut -d: -f1)"
      # The one extra fact worth having: the scheme in front of a `user:pass@`
      # tells a real registry credential (`https`) apart from a fixture
      # connection string (`mongodb`, `postgres`, `git+ssh`).
      #
      # Printed ONLY when it is one of these, and that allow-list is the whole
      # safety argument. What sits before `://` is not reliably a scheme word —
      # cache content is raw blobs and concatenated fields, so the maximal run of
      # `[A-Za-z0-9+.-]` there can be an adjacent token or part of the credential
      # itself. Echoing whatever was found would leak exactly the bytes this
      # function exists not to print. Anything unrecognised says so and stops.
      if [ "$label" = url-embedded-basic-auth ]; then
        scheme=$(LC_ALL=C grep -oEa -m1 -e "$pat" "$file" 2>/dev/null | head -n1 \
          | sed -E 's@^[^A-Za-z]*@@; s@://.*@@') || true
        if printf '%s' "$scheme" | grep -qE "^($URL_SCHEME_ALT)$"; then
          printf '    scheme: %s\n' "$scheme"
        else
          printf '    scheme: not a recognised URL scheme — inspect that line locally\n'
        fi
      fi
    done
    printf '  the matched text is deliberately not printed — reproduce the prepare command and inspect that line locally\n'
    # The digest an allowlist entry keys on, so a refusal that turns out to be a
    # package fixture can be excused without anyone having to reproduce the
    # install just to compute it.
    #
    # Three answers, in narrowing order, and the middle one is the point:
    # whether a list MAY excuse this file and whether this log may print its
    # digest are different questions with different answers, and the version of
    # this script that asked one function for both handed out an oracle.
    #
    # One-wayness is not what withholds a digest. Everything above already
    # narrows the preimage hard — exact byte count, line count, match line, URL
    # scheme — and where the rest of the file is a package's published README the
    # only unknown left is the credential. An unsalted sha256 of a nearly-known
    # plaintext is an offline oracle with no rate limit, so printing it here
    # would hand out the very thing this pass just contained.
    if ! command -v sha256sum >/dev/null 2>&1; then
      printf '  no digest is printed: this machine has no sha256sum, so an allowlist entry for this file has to be computed somewhere that does\n'
    elif scan_hit_digest_is_printable "$file"; then
      printf '  sha256: %s\n' "$(sha256sum <"$file" | cut -d' ' -f1)"
      printf '  if this is a dependency fixture and not a leak, put that digest on CACHE_SCAN_ALLOW_DIGESTS -- or, past a handful, in the file CACHE_SCAN_ALLOW_FILE names -- in BOTH jobs\n'
    elif scan_hit_is_excusable "$file"; then
      printf '  a named digest CAN excuse this file, but the log does not print it. A digest is offered only where the secret IS the file -- enough key material that a hash of it is no use to anyone. This file is not that: either its rule matches a header in front of a short string, or the rest of its bytes are a package README anyone can read. Either way the byte count, line count and match line above already narrow the preimage, so compute the digest yourself with CACHE_DRY_RUN=1 and put it in the file CACHE_SCAN_ALLOW_FILE names, in BOTH jobs\n'
    else
      printf '  no digest is printed for this file, and no list will excuse it at this size. A registry token is never excusable; a URL credential is, but only in a file of at least %s bytes, because below that its hash is an oracle for its own contents. Fix the cause instead -- a prepare command that authenticates, or a dependency that has no business being in the tree\n' "$SCAN_EXCUSABLE_MIN_BYTES"
    fi
  } >&2
}

# The process group a pid belongs to, or nothing. Two spellings because the
# answer decides whether a reap is aimed at a real group or at nothing, and a
# check that quietly fails to run is worse than no check: procps takes
# `-o pgid=`, and the ps in Git Bash — where this file's behavioural tests run —
# rejects `-o` outright but prints a PGID column.
pgid_of() { # <pid>
  local out
  out=$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ') || out=""
  case "$out" in '' | *[!0-9]* ) : ;; * ) printf '%s' "$out"; return 0 ;; esac
  out=$(ps 2>/dev/null | awk -v p="$1" \
    'NR==1{for(i=1;i<=NF;i++){if($i=="PID")c1=i;if($i=="PGID")c2=i};next}
     c1&&c2&&$c1==p{print $c2;exit}') || out=""
  case "$out" in '' | *[!0-9]* ) return 1 ;; * ) printf '%s' "$out"; return 0 ;; esac
}

# Why the archive did not unpack, said accurately. `head` closing the pipe and a
# corrupt archive both surface as the same tar failure, and blaming corruption
# for a tree that merely compresses well sends the operator looking for a
# hardware fault. The bound stays 8x the compressed size because that is the
# bound the HOST applies on arrival: a snapshot past it is one every host would
# silently refuse, so catching it here is the point rather than a side effect.
unpack_failed() {
  local expanded
  # Bounded like the main path. An error handler that decompresses without a
  # limit turns a gzip bomb into its own amplifier: the run that refused the
  # archive would then be the run that filled the disk explaining why.
  expanded=$( (gzip -dc "$ARCHIVE" || true) | head -c "$((size * 8 + 1))" | wc -c ) || expanded=0
  if [ "$expanded" -gt "$((size * 8))" ]; then
    die "the archive expands past the $((size * 8)) byte bound (8x its compressed size, which is the same bound every pool host applies on arrival) — this snapshot would be refused by every host, so it is refused here"
  fi
  die "the archive did not unpack — refusing to publish an archive this run cannot inspect"
}

scan_or_die() { # <tree>
  local root="$1" bad
  bad=$(find "$root" \
    \( -type l -o -type b -o -type c -o -type p -o -type s -o -perm /6000 \) \
    -print -quit 2>/dev/null) || die "the staged tree could not be scanned"
  [ -z "$bad" ] || die "the staged tree holds a link, node or setuid entry ($(safe_path "$bad")) — a host would refuse this snapshot"

  bad=$(getcap -r "$root" 2>/dev/null) || die "the staged tree could not be scanned for file capabilities"
  [ -z "$bad" ] || die "the staged tree holds a file capability ($(safe_path "$bad")) — a host would refuse this snapshot"

  # A dependency cache holds content addressed by hash, never credentials. The
  # prepare command usually authenticates to a registry, and this is where the
  # token it wrote gets caught before it is published to every host in the pool.
  bad=$(find "$root" -type f \( \
      -name '.npmrc' -o -name '.yarnrc' -o -name '.yarnrc.yml' -o -name '.netrc' \
      -o -name '.pypirc' -o -name '.git-credentials' -o -name 'auth.json' \
      -o -name 'settings.xml' -o -iname 'nuget.config' -o -name 'credentials' \
      -o -name 'gha-creds-*.json' -o -name '*.pem' -o -name 'id_rsa*' \
      -o -name 'gradle.properties' -o -name '.dockercfg' \
    \) -print -quit 2>/dev/null) || die "the staged tree could not be scanned for credential files"
  [ -z "$bad" ] || die "the staged tree holds what looks like a credential file ($(safe_path "$bad")) — refusing to publish it"

  # A filename list only catches a credential a tool wrote to its own config. It
  # does not see one INSIDE cache content — npm's _cacache index entries keep
  # per-entry request metadata, pip's and uv's HTTP caches keep the request URL,
  # and a registry URL with embedded basic auth is a credential in a file whose
  # name is a hash. CREDENTIAL_PATTERNS holds the high-confidence ones; broader
  # ones (a bare `authorization:`, `"private_key"`) match package test fixtures
  # often enough that adding them would train someone to delete the check. This
  # pass is a floor, not a guarantee — the guarantee is not authenticating in the
  # prepare command at all.
  local -a pass=()
  local entry digest excused=0 seen=0 hits rc=0
  for entry in "${CREDENTIAL_PATTERNS[@]}"; do pass+=(-e "${entry#*|}"); done
  # Listed to a file, and the exit status is checked. grep says 0 for "found",
  # 1 for "nothing", >=2 for "I broke" — and a >=2 that goes unread reads exactly
  # like a clean pass. On a multi-GB tree walked to the end (see below) that is
  # not theoretical: an unreadable path or a killed walk would otherwise publish.
  #
  # `mktemp`, never a fixed name under $ARCHIVE_DIR. The prepare command runs as
  # this uid BEFORE the scan and is handed $STAGE, so it knows the temp root: a
  # predictable name lets it pre-create `content-hits` as a symlink to /dev/null
  # (grep writes nowhere, rc=0, the loop reads nothing) or as a directory (the
  # redirection fails with status 1, indistinguishable from "no hits"). Either
  # one turns the only pass that sees an embedded credential into a no-op, and in
  # the single-phase mode there is no second scan to catch it. O_EXCL on an
  # unguessable name is what closes that.
  hits=$(mktemp "$ARCHIVE_DIR/hits.XXXXXX") || die "the content scan could not create its hit list"
  # `-Z` and `read -d ''`: NUL-separated, because a Linux filename may legally
  # hold a NEWLINE and this list is parsed. With a newline-terminated list, a
  # file named `<excused-fixture>\n` splits into two records — the excused
  # fixture's own path, then an empty line the loop skips — so the file whose
  # name carried the newline is never opened, never digested, and is packed.
  # The allowlist is what makes that fatal: the first record is excused rather
  # than refused, so the pass ends green. NUL is the one byte a path cannot
  # contain, which is why it is the only safe separator here.
  #
  # `-a` and NOT `-I`. `-I` skips a file grep classifies as binary, and grep
  # classifies on the first NUL byte it reads — so the prepare command, which is
  # untrusted third-party install code by this script's own threat model, opts
  # any file out of this pass by writing one leading NUL in front of the
  # credential. It defeats both jobs identically, because the publish job's
  # re-scan of the unpacked archive calls this same function. What `-a` costs is
  # a full read of the tree AND chance matches inside the compressed blobs it now
  # reads — measured at roughly one per gibibyte for a rule as loose as
  # `://x:y@`, on a 4 GiB cache, against files whose names are content hashes and
  # which cannot be excused. That is the reason every pattern above is anchored
  # to something a random byte stream does not produce; it is not a detail of the
  # patterns, it is the condition on which reading binaries is affordable.
  # `LC_ALL=C` for the same reason `-a` is here: the pass reads bytes, not text.
  # In a UTF-8 locale a bracket expression matches one CHARACTER, so a byte in
  # 0x80-0xFF that is not valid UTF-8 is not a character and `[^A-Za-z0-9]`
  # matches nothing in front of it — which turns `\xff_authToken=<token>` into a
  # clean file. That is the leading-NUL trick above with one byte changed, and
  # against the one label no allowlist may excuse. Measured on ubuntu-latest,
  # whose image sets LANG=C.UTF-8: without this, that string is not found.
  LC_ALL=C grep -rlaZ -E "${pass[@]}" "$root" >"$hits" 2>/dev/null || rc=$?
  [ "$rc" -le 1 ] || die "the staged tree could not be scanned for embedded credentials (grep exited $rc)"
  # EVERY hit, not just the first. With an allowlist in play, stopping at the
  # first match would let an excused file stand in front of an unexcused one and
  # take the whole pass green.
  while IFS= read -r -d '' bad; do
    [ -n "$bad" ] || continue
    seen=$((seen + 1))
    if [ "${#SCAN_ALLOW_DIGESTS[@]}" -gt 0 ]; then
      # Asked BEFORE the digest is computed, so a file no list may excuse never
      # gets one — a registry token is refused here whatever is on the list.
      if scan_hit_is_excusable "$bad"; then
        digest=$(sha256sum <"$bad" | cut -d' ' -f1) \
          || die "the content scan could not digest $(safe_path "${bad#"$root"/}")"
        if scan_digest_is_allowed "$digest"; then
          # Logged, never silent. An exception nobody sees is one nobody revisits
          # when the package that needed it is gone.
          log "the content scan excused $(safe_path "${bad#"$root"/}") — sha256 $digest, excused by $SCAN_ALLOW_MATCHED_WHERE"
          excused=$((excused + 1))
          continue
        fi
      fi
    fi
    explain_credential_hit "$root" "$bad"
    die "the staged tree holds what looks like an embedded credential ($(safe_path "${bad#"$root"/}")) — refusing to publish it"
  done <"$hits"
  # grep said it found something and the loop saw nothing: the list was truncated
  # or never reached, and the difference between that and a clean tree is the
  # whole pass. Refuse rather than reason about which.
  [ "$rc" != 0 ] || [ "$seen" -gt 0 ] \
    || die "the content scan found matches it could not then read — refusing to publish"
  [ "$excused" = 0 ] || log "the content scan excused $excused file(s) by digest"
}

# What the host will actually receive. Every member must be a plain file or a
# directory: a symlink or hardlink member arrives on the host as a link in its
# staging tree, which its own scan refuses, and a setuid mode is refused twice.
# Reading the archive rather than the tree is what makes this check independent
# of whatever produced it — which is the point in the publish phase, where the
# tree is gone and the archive came from another job.
archive_is_flat() { # <archive>
  # mktemp for the same reason the hit list uses it: a fixed name under
  # $ARCHIVE_DIR is one the prepare command can pre-create as a symlink to
  # /dev/null, and a listing that is written nowhere makes this check pass on
  # every archive.
  local bad list
  list=$(mktemp "$ARCHIVE_DIR/listing.XXXXXX") || die "the archive could not be listed"
  # Listed to a file rather than piped into awk: under `pipefail` an awk that
  # stops at the first offending member takes the writer down with SIGPIPE, and a
  # FOUND violation would then be reported as "could not be listed".
  tar -tvzf "$1" >"$list" || die "the archive could not be listed"
  bad=$(awk '$1 !~ /^[-d]/ || $1 ~ /[sS]/ { print; exit }' "$list")
  [ -z "$bad" ] || die "the archive holds a member that is not a plain file or directory, or is setuid ($(safe_path "$bad")) — a host would refuse it"
}

# The archive is deliberately NOT created here. Creating it before the prepare
# command runs put an attacker-writable file in a directory that command can
# simply list: `mktemp` randomises a name against GUESSING, not against `ls`, and
# `chmod 0700` is no barrier to the same uid. Each branch below creates it at the
# point it packs. This is one of three parts and the weakest: what actually
# bounds a process the install left behind is reaping its process group before
# anything is scanned, and what catches a write that happened anyway is the
# digest pinned across every later use of the file.
ARCHIVE=""

if [ "$BUILDING" = 1 ]; then
  for d in "${CACHE_DIRS[@]}"; do mkdir -p "$STAGE/$d"; done

  # --- install ------------------------------------------------------------------
  #
  # Every variable a host sets for a slot, pointed at the staging tree instead, so
  # what the prepare command populates is laid out exactly as the host expects to
  # unpack it. Both pnpm spellings, because pnpm 11 reads pnpm_config_store_dir and
  # silently ignores the npm_config_ form it honoured before — silently, meaning a
  # single-spelling guess looks like it worked and stores nothing where we asked.
  export npm_config_cache="$STAGE/npm"
  export YARN_CACHE_FOLDER="$STAGE/yarn"
  export pnpm_config_store_dir="$STAGE/pnpm-store"
  export npm_config_store_dir="$STAGE/pnpm-store"
  export GOMODCACHE="$STAGE/go-mod"
  export PIP_CACHE_DIR="$STAGE/pip"
  export UV_CACHE_DIR="$STAGE/uv"
  export MAVEN_ARGS="-Dmaven.repo.local=$STAGE/m2"
  export NUGET_PACKAGES="$STAGE/nuget"
  export COMPOSER_CACHE_DIR="$STAGE/composer"

  # Not logged with its value: a prepare command for a private registry routinely
  # carries a token in its arguments, repository VARIABLES are not masked, and
  # this log is readable by anyone who can read the repository.
  log "installing dependencies into a clean tree"
  # `sh -euc` and not an array: the caller supplies a command line, usually with
  # its own flags, and this runs on the default branch of a repository whose
  # workflows already run arbitrary commands. Splitting it here would be a false
  # safety. `-e` because a prepare joined with `;` instead of `&&` would otherwise
  # publish a half-populated cache with a zero exit.
  #
  # In its OWN PROCESS GROUP, under a timeout, and reaped before anything is
  # scanned. `sh -euc` returning does not mean the install stopped: a lifecycle
  # script that daemonises keeps running as this uid, with the staged tree and
  # the temp root in reach, and every "the scan bounds it" argument in this file
  # is written against a process that by then no longer exists. Removing the
  # writer is the control; the digest pin further down is only the detector.
  #
  # `set -m` is what gives the job a group of its own — without it the child
  # shares this script's group and `kill -- -$pid` would either fail or kill the
  # run. That it worked is verified rather than assumed, because a reap aimed at
  # the wrong group is a control that silently does nothing.
  #
  # `sh -euc` and not an array: the caller supplies a command line, usually with
  # its own flags, and this runs on the default branch of a repository whose
  # workflows already run arbitrary commands. Splitting it here would be a false
  # safety. `-e` because a prepare joined with `;` instead of `&&` would otherwise
  # publish a half-populated cache with a zero exit.
  set -m
  timeout -k 30 "$CACHE_PREPARE_TIMEOUT" sh -euc "$CACHE_PREPARE" &
  prep_pgid=$!
  set +m
  # `ps` alone decides, both whether there is a child to judge and what group it
  # is in. The earlier shape guarded this with `kill -0`, which is a different
  # source: bash's kill BUILTIN answers from its own job table and calls a job it
  # has already reaped live. On Linux every prepare that finishes quickly — which
  # is all of them in this file's behavioural tests — took that branch with `ps`
  # having nothing left to report, and the run died on a scheduling accident
  # rather than on a fault.
  #
  # So: no group reported means no child left to bound, and there is nothing to
  # refuse. A group reported that is not the child's own is the real fault — the
  # reap would be aimed at this script's group — and that is what dies.
  #
  # The refusal names the two values it compared. A gate that says only "the
  # group is wrong" is one nobody can act on from a CI job page once the runner
  # is gone: "ps could not answer" and "the child landed in this script's group"
  # have different fixes and read identically without them.
  prep_seen=$(pgid_of "$prep_pgid" || true)
  [ -z "$prep_seen" ] || [ "$prep_seen" = "$prep_pgid" ] \
    || die "the prepare command did not get a process group of its own, so nothing it leaves running could be reaped — refusing to build a snapshot this run cannot bound (child pid $prep_pgid, its group '$prep_seen', this script's group $(pgid_of $$ || true))"
  prep_rc=0
  wait "$prep_pgid" || prep_rc=$?
  # TERM, a moment, then KILL. Both are best-effort against an already-empty
  # group, which is the normal case and not an error.
  kill -TERM -- "-$prep_pgid" 2>/dev/null || true
  sleep 1
  kill -KILL -- "-$prep_pgid" 2>/dev/null || true
  case "$prep_rc" in
    0 ) : ;;
    124 | 137 ) die "the prepare command ran past CACHE_PREPARE_TIMEOUT (${CACHE_PREPARE_TIMEOUT}s) and was killed — an install that cannot finish must not become a half-populated snapshot" ;;
    * ) die "the prepare command failed — publishing an archive of a failed install would ship a cache that is worse than none" ;;
  esac

  scan_or_die "$STAGE"

  # --- pack ---------------------------------------------------------------------
  #
  # --owner/--group/--numeric-owner: the archive is unpacked by root into a
  # root-owned tree, and a uid from the build machine leaking into it is a file the
  # host's own ownership rules did not decide. --sort=name makes the bytes a
  # function of the content rather than of readdir order, which is what makes a
  # rebuild that changed nothing produce the same digest. --hard-dereference stores
  # a multi-linked file as its own content instead of as a link member, so nothing
  # the host extracts has nlink > 1 — the condition its own scan refuses.
  log "packing"
  # `.tar.gz` suffix: the name is what gzip's output is read back as by `tar -tvzf`.
  ARCHIVE=$(mktemp "$ARCHIVE_DIR/snap.XXXXXX.tar.gz") || die "the archive file could not be created"
  tar -c -C "$STAGE" --owner=0 --group=0 --numeric-owner --sort=name --hard-dereference \
    -- "${CACHE_DIRS[@]}" | gzip -n -6 >"$ARCHIVE"
else
  # safe_path even though this one is a workflow literal today: it is the only
  # refusal that interpolates a path, and the day someone derives it from job
  # output is the day the exception becomes the injection.
  [ -f "$CACHE_ARCHIVE_IN" ] || die "CACHE_ARCHIVE_IN does not name a file: $(safe_path "$CACHE_ARCHIVE_IN")"
  ARCHIVE=$(mktemp "$ARCHIVE_DIR/snap.XXXXXX.tar.gz") || die "the archive file could not be created"
  cp -- "$CACHE_ARCHIVE_IN" "$ARCHIVE"
fi

# FIRST, before anything reads the archive for a verdict. The identity of the
# bytes, taken once and re-checked at every later use.
#
# Every check below re-opens this file: `stat` for the size, `tar -tvzf` for the
# member layout, `gzip -dc` for the scan, and finally `cp` and `gcloud storage cp`
# for the bytes that ship. A verdict rendered before the pin exists is a verdict
# about bytes nothing can later prove were these — the size bound would then be
# computed from a stale length (and quoted in the expansion message, which is how
# that reads as a factual claim about the wrong file), and the flatness check,
# which is the ONLY pass that sees setuid and hardlink members, would have looked
# at a different archive than the one uploaded.
#
# Detector, not control: what is supposed to leave nothing able to write here is
# the reap above, plus the refusal to hold the credential in a process that ran
# CACHE_PREPARE at all. If this ever fires, one of those failed, and the run
# refuses rather than publishing.
#
# From stdin, so a filename is never an operand: GNU sha256sum escapes a name
# holding a newline or a backslash and prefixes the line with one.
ARCHIVE_SHA=$(sha256sum <"$ARCHIVE" | cut -d' ' -f1) \
  || die "the archive could not be digested"
assert_archive_unchanged() { # <what happens next>
  local now
  now=$(sha256sum <"$ARCHIVE" | cut -d' ' -f1) || die "the archive could not be re-digested before $1"
  [ "$now" = "$ARCHIVE_SHA" ] \
    || die "the archive changed between the scan and $1 — something is still writing in this run's temp directory, and nothing that was checked applies to these bytes"
}

size=$(stat -c %s "$ARCHIVE")
if [ "$size" -gt "$CACHE_MAX_BYTES" ]; then
  die "the archive is $size bytes, past the $CACHE_MAX_BYTES bound — every host would refuse it, which reads in their logs as 'no snapshot published'. Raise the pools' cache_snapshot_max_bytes first, then this."
fi

archive_is_flat "$ARCHIVE"
assert_archive_unchanged "the size and member-layout verdicts were trusted"

# The staged tree has served its purpose once the archive is packed and checked,
# and holding it costs a second full copy of the cache on a runner whose disk is
# smaller than two of them. It is also one fewer thing left writable.
# chmod, because `mkdir -p` takes the ambient umask (0755 on a hosted runner)
# where `mktemp -d` gave 0700. The directory stays empty, but it should not be a
# world-readable one.
if [ "$BUILDING" = 1 ]; then rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 0700 "$STAGE"; fi

# UNCONDITIONAL, in both phases: what gets scanned has to be the bytes that get
# shipped, not a tree those bytes were supposed to have come from. An artifact
# that crossed a job boundary is plainly input — but so is one packed a few lines
# up, so neither phase gets to skip it.
#
# On its own this does not close the write window, and it should not be read as
# doing so. Four things together close it: the credentialed phase never runs
# CACHE_PREPARE at all, so in that process there is no writer to race; the
# install's process group is reaped before the first scan; this pass proves the
# packed bytes are clean; and ARCHIVE_SHA proves the bytes uploaded are these.
#
# WHAT THIS PASS DOES NOT COVER: modes. The extraction below deliberately drops
# permissions, xattrs and ACLs, so by the time `-perm /6000` and `getcap` run
# over $VERIFY there is no setuid bit and no `security.capability` left to find.
# Those two rules are load-bearing only in `archive_is_flat`, which reads the
# archive's own member list — which is why it now runs inside the digest pin.
# What this pass is for is links and CONTENT.
#
# Into a tree of its own, created only now: $STAGE is what the prepare command
# populated, so unpacking over it would scan a union of the two.
#
# Bounded the way the host bounds it: gzip expands by more than a thousandfold on
# the right input, so the compressed bound alone bounds nothing. `head` closing
# the pipe truncates the stream and tar fails, which is the wanted answer.
VERIFY=$(mktemp -d) || die "the archive could not be unpacked for verification"
chmod 0700 "$VERIFY"
gzip -dc "$ARCHIVE" | head -c "$((size * 8))" \
  | tar -x -C "$VERIFY" --no-same-owner --no-same-permissions --no-xattrs --no-acls \
  || unpack_failed
scan_or_die "$VERIFY"

# The name is the object's identity forever: the bucket expires it by age and
# nothing ever replaces it. Timestamp first so a listing sorts chronologically,
# digest second so two runs of the same content are visibly the same content.
# Both halves stay inside the charset a host accepts in a pointer.
digest=${ARCHIVE_SHA:0:16}
SNAP="$(date -u +%Y%m%dT%H%M%SZ)-${digest}.tar.gz"
log "built $SNAP ($size bytes)"

if [ -n "${CACHE_ARCHIVE_OUT:-}" ]; then
  assert_archive_unchanged "the artifact was written"
  cp -- "$ARCHIVE" "$CACHE_ARCHIVE_OUT"
  log "wrote $CACHE_ARCHIVE_OUT — nothing uploaded, this phase holds no credential"
fi

if [ "$PUBLISHING" = 0 ]; then
  log "nothing uploaded"
  exit 0
fi

# --- publish --------------------------------------------------------------------
#
# --if-generation-match=0 means "only if this object does not exist". The IAM
# grant already refuses an overwrite, so this is the second of two bounds: it
# turns a name collision into a precondition failure naming the object, rather
# than a 403 that reads like a broken credential.
PREFIX="cache/${CACHE_POOL}"
assert_archive_unchanged "the upload"
log "uploading gs://${CACHE_BUCKET}/${PREFIX}/${SNAP}"
gcloud storage cp --if-generation-match=0 \
  "$ARCHIVE" "gs://${CACHE_BUCKET}/${PREFIX}/${SNAP}" \
  || die "the snapshot did not upload — nothing was published, and the pointer still names the previous snapshot"

# THE POINTER IS SWAPPED LAST, and only after the snapshot is fully uploaded.
# The order is the atomicity: a host that reads the pointer mid-publish gets the
# previous snapshot, which is stale at worst. The reverse order gives it a name
# that half exists.
POINTER="gs://${CACHE_BUCKET}/${PREFIX}/current"
gen=$(gcloud storage objects describe "$POINTER" --format='value(generation)' 2>/dev/null || true)
[ -n "$gen" ] || gen=0

# mktemp: the pointer's body is the one file in this directory whose CONTENT is
# what every host resolves a snapshot by, so a fixed name the prepare command
# could pre-create as a symlink is the shortest path from a compromised install
# to a pointer naming an object of its choosing.
pointer_body=$(mktemp "$ARCHIVE_DIR/current.XXXXXX") || die "the pointer could not be staged"
printf '%s\n' "$SNAP" >"$pointer_body"
gcloud storage cp --if-generation-match="$gen" \
  "$pointer_body" "$POINTER" \
  || die "the pointer was not swapped (generation $gen): another publisher won the race, the pointer changed while this run was packing, or this identity cannot read it — check that the snapshot itself uploaded. The snapshot IS uploaded and will expire with the bucket's age bound; re-run to publish it."

log "published $SNAP — hosts booting from now hydrate from it"
