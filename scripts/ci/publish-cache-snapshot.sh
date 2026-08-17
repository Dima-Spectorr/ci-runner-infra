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
#       watching — instead of silently on every boot of every host. The publish
#       phase scans AGAIN, on what it actually received, because an artifact
#       crossing a job boundary is input.
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

# Which phases this invocation is. Building and publishing are independent: the
# workflow runs one of each, a local dry run is build-only, and running both at
# once is what makes the script usable by hand.
BUILDING=1; [ -z "${CACHE_ARCHIVE_IN:-}" ] || BUILDING=0
PUBLISHING=1
[ -z "${CACHE_ARCHIVE_OUT:-}" ] || PUBLISHING=0
[ -z "${CACHE_DRY_RUN:-}" ]     || PUBLISHING=0

[ "$BUILDING" = 1 ] || [ "$PUBLISHING" = 1 ] \
  || die "CACHE_ARCHIVE_IN with CACHE_ARCHIVE_OUT or CACHE_DRY_RUN asks this to neither build nor publish"

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
    *[!a-z0-9-]* | '' | -* | *- ) die "CACHE_POOL must be lowercase letters, digits and hyphens: $CACHE_POOL" ;;
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
  * ) die "refusing to publish from a '$GITHUB_EVENT_NAME' run — a snapshot may only be built by schedule, workflow_dispatch or push. Runs triggered by pull_request_target, workflow_run or issue_comment execute untrusted code while asserting the default branch." ;;
esac

command -v getcap >/dev/null 2>&1 \
  || die "getcap is not installed (libcap2-bin). A host refuses a snapshot it cannot scan for file capabilities, so building one that cannot be scanned here is building one nothing will accept."

STAGE=$(mktemp -d)
ARCHIVE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE" "$ARCHIVE_DIR"' EXIT
chmod 0700 "$STAGE" "$ARCHIVE_DIR"

# --- the scan --------------------------------------------------------------------
#
# The content patterns of the embedded-credential pass, each with the name its
# failure reports. ONE list, used both to find a hit and to explain it: a second
# copy would be a second thing that has to agree, which is the whole failure mode
# this script's duplicated-but-selftested rules exist to avoid.
CREDENTIAL_PATTERNS=(
  "registry-auth-token|_authToken"
  "url-embedded-basic-auth|://[^/@[:space:]\"]+:[^/@[:space:]\"]+@"
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
explain_credential_hit() { # <tree> <file>
  local root="$1" file="$2" entry label pat n scheme
  {
    printf 'the embedded-credential pass matched in %s\n' "$(safe_path "${file#"$root"/}")"
    printf '  file: %s bytes, %s line(s)\n' "$(wc -c <"$file")" "$(wc -l <"$file")"
    for entry in "${CREDENTIAL_PATTERNS[@]}"; do
      label="${entry%%|*}" pat="${entry#*|}"
      n=$(grep -c -E -e "$pat" "$file" 2>/dev/null) || n=0
      [ "$n" -gt 0 ] || continue
      printf '  %s: %s match(es), first on line %s\n' \
        "$label" "$n" "$(grep -n -m1 -E -e "$pat" "$file" 2>/dev/null | cut -d: -f1)"
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
        scheme=$(grep -oE -m1 "[A-Za-z][A-Za-z0-9+.-]{0,31}$pat" "$file" 2>/dev/null | head -n1 | cut -d: -f1) || true
        case "$scheme" in
          http | https | ftp | ftps | ssh | git | git+ssh | git+https | svn | svn+ssh \
          | mongodb | mongodb+srv | postgres | postgresql | mysql | mariadb | redis \
          | rediss | amqp | amqps | s3 | gs | ldap | ldaps | smtp | smtps | imap )
            printf '    scheme: %s\n' "$scheme" ;;
          * )
            printf '    scheme: not a recognised URL scheme — inspect that line locally\n' ;;
        esac
      fi
    done
    printf '  the matched text is deliberately not printed — reproduce the prepare command and inspect that line locally\n'
  } >&2
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
  local entry
  for entry in "${CREDENTIAL_PATTERNS[@]}"; do pass+=(-e "${entry#*|}"); done
  bad=$(grep -rlI -E "${pass[@]}" "$root" 2>/dev/null | head -n1) || true
  [ -z "$bad" ] || { explain_credential_hit "$root" "$bad"; die "the staged tree holds what looks like an embedded credential ($(safe_path "$bad")) — refusing to publish it"; }
}

# What the host will actually receive. Every member must be a plain file or a
# directory: a symlink or hardlink member arrives on the host as a link in its
# staging tree, which its own scan refuses, and a setuid mode is refused twice.
# Reading the archive rather than the tree is what makes this check independent
# of whatever produced it — which is the point in the publish phase, where the
# tree is gone and the archive came from another job.
archive_is_flat() { # <archive>
  local bad list="$ARCHIVE_DIR/listing"
  # Listed to a file rather than piped into awk: under `pipefail` an awk that
  # stops at the first offending member takes the writer down with SIGPIPE, and a
  # FOUND violation would then be reported as "could not be listed".
  tar -tvzf "$1" >"$list" || die "the archive could not be listed"
  bad=$(awk '$1 !~ /^[-d]/ || $1 ~ /[sS]/ { print; exit }' "$list")
  [ -z "$bad" ] || die "the archive holds a member that is not a plain file or directory, or is setuid ($(safe_path "$bad")) — a host would refuse it"
}

ARCHIVE="$ARCHIVE_DIR/snap.tar.gz"

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
  sh -euc "$CACHE_PREPARE" || die "the prepare command failed — publishing an archive of a failed install would ship a cache that is worse than none"

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
  tar -c -C "$STAGE" --owner=0 --group=0 --numeric-owner --sort=name --hard-dereference \
    -- "${CACHE_DIRS[@]}" | gzip -n -6 >"$ARCHIVE"
else
  [ -f "$CACHE_ARCHIVE_IN" ] || die "CACHE_ARCHIVE_IN does not name a file: $CACHE_ARCHIVE_IN"
  cp -- "$CACHE_ARCHIVE_IN" "$ARCHIVE"
fi

size=$(stat -c %s "$ARCHIVE")
if [ "$size" -gt "$CACHE_MAX_BYTES" ]; then
  die "the archive is $size bytes, past the $CACHE_MAX_BYTES bound — every host would refuse it, which reads in their logs as 'no snapshot published'. Raise the pools' cache_snapshot_max_bytes first, then this."
fi

archive_is_flat "$ARCHIVE"

if [ "$BUILDING" = 0 ]; then
  # An artifact that crossed a job boundary is input, and the job that scanned it
  # the first time is the one that ran third-party code. Bounded the way the host
  # bounds it: gzip expands by more than a thousandfold on the right input, so the
  # compressed bound alone bounds nothing. `head` closing the pipe truncates the
  # stream and tar fails, which is the wanted answer.
  gzip -dc "$ARCHIVE" | head -c "$((size * 8))" \
    | tar -x -C "$STAGE" --no-same-owner --no-same-permissions --no-xattrs --no-acls \
    || die "the archive did not unpack — refusing to publish an archive this run cannot inspect"
  scan_or_die "$STAGE"
fi

# The name is the object's identity forever: the bucket expires it by age and
# nothing ever replaces it. Timestamp first so a listing sorts chronologically,
# digest second so two runs of the same content are visibly the same content.
# Both halves stay inside the charset a host accepts in a pointer.
digest=$(sha256sum "$ARCHIVE" | cut -c1-16)
SNAP="$(date -u +%Y%m%dT%H%M%SZ)-${digest}.tar.gz"
log "built $SNAP ($size bytes)"

if [ -n "${CACHE_ARCHIVE_OUT:-}" ]; then
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

printf '%s\n' "$SNAP" >"$ARCHIVE_DIR/current"
gcloud storage cp --if-generation-match="$gen" \
  "$ARCHIVE_DIR/current" "$POINTER" \
  || die "the pointer was not swapped (generation $gen): another publisher won the race, the pointer changed while this run was packing, or this identity cannot read it — check that the snapshot itself uploaded. The snapshot IS uploaded and will expire with the bucket's age bound; re-run to publish it."

log "published $SNAP — hosts booting from now hydrate from it"
