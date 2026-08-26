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
#   before it is offered, and the write itself carries `ifGenerationMatch=0`, so
#   losing the race between the check and the write is a 412 rather than a 403 —
#   still a success: whatever is under that name was written by this same
#   identity from this same branch, under a name that is a digest of its inputs.
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

# The prefix reaches a URL below, so it is held to a charset with no `%` and no
# `..` before anything is encoded from it. The hash half is already validated
# per artifact; this is the half an operator supplies.
case "$WARM_TURBO_PREFIX" in
  *[!A-Za-z0-9._/-]* | *..*)
    log "WARM_TURBO_PREFIX '$WARM_TURBO_PREFIX' is not an object prefix — refusing"; exit 2 ;;
esac
# `/` is the only character in the validated charset that needs encoding in an
# object name, and it must be encoded: an unescaped one in the `name` parameter
# is read as a path separator in the API's own URL rather than as part of the
# object's name.
ENC_PREFIX=${WARM_TURBO_PREFIX//\//%2F}

# THE STORAGE JSON API RATHER THAN `gcloud storage cp`, AND THAT IS THE WHOLE
# FIX. `cp` LISTS the destination to work out whether the name it was given is
# an object or a directory, and a list is authorised against the BUCKET — so
# `resource.name` is the bucket, which never starts with an object path. Every
# grant this identity holds is conditioned on an object prefix, so the list is
# refused and the upload never happens. Measured, not reasoned: the first warm
# whose build actually produced artifacts published 0 of 291 and reported
# `failed=291`, and the same call in the dependency-snapshot publisher had
# already been rewritten this way for the same reason (`publish-cache-snapshot.sh`).
#
# Naming the object explicitly removes the question: the request needs
# `storage.objects.create` and nothing else. A list grant on a bucket that holds
# every pool's cache is not the alternative — it is a wider grant handed out to
# work around a client-side convenience.
GCS_TOKEN=""
GCS_TOKEN_AT=0
gcs_token() {
  local now
  now=$(date +%s)
  # Re-minted well inside the hour an access token lives: a monorepo's cache can
  # hold thousands of artifacts, and a publish loop that outlives its token
  # fails every upload after the expiry with a 401 that looks like a broken
  # grant. Cheap — this is a local metadata-server call.
  if [ -z "$GCS_TOKEN" ] || [ "$((now - GCS_TOKEN_AT))" -ge 1800 ]; then
    GCS_TOKEN=$(gcloud auth print-access-token 2>/dev/null) || return 1
    GCS_TOKEN_AT=$now
  fi
  [ -n "$GCS_TOKEN" ]
}

BODY=$(mktemp) || { log "the response buffer could not be staged"; exit 2; }
trap 'rm -f "$BODY"' EXIT

# Sets HTTP_CODE and err_detail; never returns non-zero, because every outcome
# including "no credential" is a per-artifact count the caller reports.
HTTP_CODE=""
err_detail=""
gcs_upload() { # <file> <percent-encoded object name>
  local file="$1" name="$2"
  err_detail=""
  HTTP_CODE=""
  if ! gcs_token; then
    err_detail="this step authenticated to nothing"
    return 0
  fi
  # THE TOKEN IS NOT AN ARGUMENT. `-H "Authorization: Bearer $TOKEN"` would put a
  # credential that may create objects in the bucket every host in the pool
  # trusts into this process's argv, and /proc/<pid>/cmdline is world-readable.
  # curl reads the header from a file descriptor instead, and `printf` is a
  # builtin, so nothing is exec'd with the token in ITS argv either.
  # `--proto '=https'` pins the scheme so a redirect cannot make curl send the
  # bearer token in clear text.
  HTTP_CODE=$(curl -sS --proto '=https' --connect-timeout 10 --max-time 1800 \
    --speed-limit 1024 --speed-time 120 \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$GCS_TOKEN") \
    -X POST -H 'Content-Type: application/octet-stream' \
    --data-binary "@$file" -o "$BODY" -w '%{http_code}' \
    "https://storage.googleapis.com/upload/storage/v1/b/${WARM_BUCKET}/o?uploadType=media&ifGenerationMatch=0&name=${name}" \
    2>/dev/null)
  case "$HTTP_CODE" in
    200 | 201 | 412) : ;;
    # The API's own message, trimmed to one line. It names the refused
    # permission on a 403, which is the single most useful thing this step can
    # say and the thing it could not say before.
    *) err_detail=$(tr '\n' ' ' <"$BODY" | cut -c1-200) ;;
  esac
  return 0
}

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
#
# STREAMED through process substitution, not a here-document. A here-doc fed by
# `$(find ...)` collects every path into one shell string first, which is the
# same "hold the whole list in memory at once" the glob was rejected for, only
# without the hard limit that would announce it. Process substitution also keeps
# the loop in THIS shell — a pipe would run it in a subshell and every counter
# below would be discarded at the end, reporting `published=0` on a run that
# published everything.
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

  # `objects describe` names the object, so it is authorised as
  # `storage.objects.get` against THAT object and the prefix condition on the
  # grant matches. This is the one gcloud storage call in the loop that a
  # prefix-scoped identity can make; see the upload below for the one it cannot.
  if gcloud storage objects describe "$object" >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$WARM_DRY_RUN" = "1" ]; then
    log "would publish $hash (${size}B)"
    published=$((published + 1))
    continue
  fi

  gcs_upload "$artifact" "${ENC_PREFIX}${hash}"
  case "$HTTP_CODE" in
    200 | 201)
      published=$((published + 1))
      ;;
    412)
      # `ifGenerationMatch=0` refused it: something wrote that name between the
      # describe above and this request. Whatever is there was written by this
      # same identity from this same branch, under a name that is a digest of
      # the task's inputs, so it is the same artifact. Lost the race, not failed.
      skipped=$((skipped + 1))
      ;;
    *)
      # The reason, not just the count. This step reported `failed=291` with no
      # other output for months of nightly runs, and the cause — one refused
      # permission, the same one for all 291 — was not recoverable from the log.
      log "could not publish $hash: HTTP ${HTTP_CODE:-none}${err_detail:+ — $err_detail}"
      failed=$((failed + 1))
      ;;
  esac
done < <(find "$WARM_TURBO_DIR" -maxdepth 1 -type f -name '*.tar.zst' 2>/dev/null)

log "published=$published already-present=$skipped refused=$refused failed=$failed"

# A failed upload is not a failed warm. The next scheduled run republishes it,
# and every build in between simply misses on that one task — which is what it
# would have done anyway. Failing here would turn a partial warm into a red
# build somebody has to triage.
exit 0
