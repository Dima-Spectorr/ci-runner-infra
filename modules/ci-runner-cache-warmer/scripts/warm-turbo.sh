#!/usr/bin/env bash
# =============================================================================
# warm-turbo.sh — publish a default-branch build's Turborepo artifacts
#
# WHERE THIS RUNS
#   As the last step of the cache warmer's Cloud Build, after a step has run the
#   repository's build on the DEFAULT BRANCH. Never on a pool host: a host
#   executes pull-request code, and a build artifact is a tarball the next build
#   unpacks into its output tree and reports as its own result. The host-side
#   server is read-only for exactly that reason, and this is the other half —
#   the one identity in the arrangement that is allowed to write, because it is
#   the one that never runs a pull request.
#
# WHAT IT UPLOADS, AND WHY THERE IS NO UPLOAD PROTOCOL HERE
#   `turbo` writes each finished task to its local cache directory as
#   `<hash>.tar.zst`, and the artifact a remote cache serves for `<hash>` is
#   that same file, byte for byte. So there is nothing to translate: the object
#   name is the hash and the object body is the file. That is deliberate — a
#   writer that spoke the v8 HTTP API would need a server with a write path,
#   and the whole security argument for the host-side server is that it has
#   none and never will.
#
# WRITE-ONCE, AND WHY AN ALREADY-PUBLISHED HASH IS A SUCCESS
#   A turbo hash is the digest of a task's inputs, so re-running the same build
#   produces the same names. The warmer's grant carries create and NOT delete,
#   which means an upload over a live object fails with a 403 — and on a
#   schedule most hashes are already there. So an object that exists is skipped
#   before it is offered, and a 403 on the race between the check and the write
#   is still a success: whatever is in the bucket under that name was written by
#   this same identity from this same branch.
#
#   This is the same rule the dependency snapshot follows and for the same
#   reason: the bucket's age bound is measured per generation, so an object
#   refreshed in place is a generation aged zero that never expires.
#
# ENV
#   WARM_BUCKET        bucket holding the build cache            (required)
#   WARM_TURBO_PREFIX  object prefix, `turbo/<owner>/<repo>/`    (required)
#   WARM_TURBO_DIR     turbo's local cache directory             (required)
#   WARM_MAX_BYTES     refuse to publish an artifact over this   (default 512Mi)
#   WARM_DRY_RUN       1 = say what would be uploaded, upload nothing
#
# EXIT
#   0 even when it published nothing. A warmer that fails the build because a
#   build had no cacheable tasks would page someone over a working system; what
#   an operator needs is the count, which is logged and is what the alert reads.
# =============================================================================
set -uo pipefail

log() { printf '[warm-turbo] %s\n' "$*" >&2; }

: "${WARM_BUCKET:?WARM_BUCKET is required}"
: "${WARM_TURBO_PREFIX:?WARM_TURBO_PREFIX is required}"
: "${WARM_TURBO_DIR:?WARM_TURBO_DIR is required}"
WARM_MAX_BYTES="${WARM_MAX_BYTES:-536870912}"
WARM_DRY_RUN="${WARM_DRY_RUN:-0}"

# A prefix that does not end in `/` is a prefix that writes NEXT TO the tree it
# was meant to write into — `turbo/acme/widgetsdeadbeef` rather than
# `turbo/acme/widgets/deadbeef`. The host's IAM condition is a startsWith on the
# trailing-slash form, so the object would also be unreadable: published,
# charged for, and invisible. Refused here rather than discovered as a cache
# that never warms.
case "$WARM_TURBO_PREFIX" in
  */) : ;;
  *) log "WARM_TURBO_PREFIX '$WARM_TURBO_PREFIX' does not end in '/' — refusing"; exit 2 ;;
esac

if [ ! -d "$WARM_TURBO_DIR" ]; then
  # Not a failure. A repository that does not use turbo, or a build where every
  # task was already replayed from a cache this warmer filled on an earlier run,
  # both land here.
  log "no turbo cache directory at $WARM_TURBO_DIR — nothing to publish"
  exit 0
fi

published=0
skipped=0
refused=0
failed=0

# `find` rather than a glob: a monorepo's cache directory routinely holds more
# entries than a command line can carry, and the failure mode of the glob is an
# "argument list too long" that aborts the publish after an arbitrary prefix of
# it. -maxdepth 1 because only the top level holds artifacts; turbo keeps its
# own bookkeeping in subdirectories.
while IFS= read -r artifact; do
  [ -n "$artifact" ] || continue
  base=$(basename "$artifact")
  hash=${base%.tar.zst}

  # The hash reaches an object name, so it is checked against the same charset
  # the host-side server accepts before it is used to build one. A file the
  # server would refuse to serve must not be published: it would be a paid-for
  # object that answers no read.
  case "$hash" in
    *[!A-Za-z0-9_-]* | "")
      log "refusing '$base': not an artifact hash"
      refused=$((refused + 1))
      continue
      ;;
  esac

  size=$(stat -c %s "$artifact" 2>/dev/null || echo 0)
  if [ "$size" -gt "$WARM_MAX_BYTES" ]; then
    # The host-side server treats anything over its bound as a miss, so
    # publishing this would cost storage and never serve a read.
    log "refusing '$hash': ${size}B is over the ${WARM_MAX_BYTES}B artifact bound"
    refused=$((refused + 1))
    continue
  fi

  object="gs://${WARM_BUCKET}/${WARM_TURBO_PREFIX}${hash}"

  if gcloud storage objects describe "$object" >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$WARM_DRY_RUN" = "1" ]; then
    log "would publish $hash (${size}B)"
    published=$((published + 1))
    continue
  fi

  # --no-clobber is the same write-once rule the grant enforces, stated on the
  # call so the common case — a hash already published by yesterday's run,
  # racing today's — is a no-op rather than an error someone has to read.
  if gcloud storage cp --no-clobber "$artifact" "$object" >/dev/null 2>&1; then
    published=$((published + 1))
  elif gcloud storage objects describe "$object" >/dev/null 2>&1; then
    # Lost the race, and the winner wrote the same bytes under a content hash.
    skipped=$((skipped + 1))
  else
    log "could not publish $hash"
    failed=$((failed + 1))
  fi
done <<EOF
$(find "$WARM_TURBO_DIR" -maxdepth 1 -type f -name '*.tar.zst' 2>/dev/null)
EOF

log "published=$published already-present=$skipped refused=$refused failed=$failed"

# A failed upload is not a failed warm. The next scheduled run republishes it,
# and every build in between simply misses on that one task — which is what it
# would have done anyway. Failing here would turn a partial warm into a red
# build somebody has to triage.
exit 0
