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
#   WARM_SERVED_DIR    where the build step's read-only cache server kept the
#                      artifacts it SERVED from the store        (optional)
#   WARM_DRY_RUN       1 = say what would be uploaded, upload nothing
#
# INCREMENTAL, AND WHY A SERVED HASH IS SKIPPED WITHOUT A REQUEST
#   The build step reads this same store before it builds (turbo-cache-server.py,
#   the host pool's own read-only server, bound to loopback), so a task whose
#   hash is already published is replayed rather than rebuilt — and turbo then
#   leaves that artifact in its local directory like any other. The server keeps
#   every artifact it served in WARM_SERVED_DIR, under the bare hash, so a hash
#   found there was READ FROM THIS PREFIX a few minutes ago and is skipped with
#   no request at all. The worst a forged file there can do is make this step
#   skip a hash: that is a miss for the next build, never content in the store.
#
# PARALLEL, BOUNDED
#   The existence check and the upload run PUBLISH_PARALLEL artifacts at a time.
#   One `gcloud storage objects describe` per artifact, in sequence, was ~1 s
#   each and 16 minutes for a 956-artifact warm (build 6e721cc4, 2026-10-10).
#   Bounded rather than unbounded because a cold warm offers thousands at once.
#
# NEVER A TRUNCATED ARTIFACT
#   Every upload is checked first: the zstd frame magic always, and a full
#   `zstd -t` decode when the image has zstd (the wrapper installs it best
#   effort). A cut-off `.tar.zst` is counted `refused`, never published —
#   write-once means a corrupt object would be served for the bucket's whole
#   age bound.
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

WARM_SERVED_DIR="${WARM_SERVED_DIR:-}"

# How many artifacts are checked and uploaded at once. A constant, not an
# input: it bounds this step's own sockets and memory, and nothing about a
# repository changes what it should be.
PUBLISH_PARALLEL=16

RESULTS=$(mktemp -d) || { log "the result directory could not be staged"; exit 2; }
trap 'rm -rf "$RESULTS"' EXIT

# Sets HTTP_CODE and err_detail; never returns non-zero, because every outcome
# including "no credential" is a per-artifact count the caller reports. <body>
# is per artifact: these run in parallel and must not share a buffer.
HTTP_CODE=""
err_detail=""
gcs_upload() { # <file> <percent-encoded object name> <body>
  local file="$1" name="$2" body="$3"
  err_detail=""
  HTTP_CODE=""
  if [ -z "$GCS_TOKEN" ]; then
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
    --data-binary "@$file" -o "$body" -w '%{http_code}' \
    "https://storage.googleapis.com/upload/storage/v1/b/${WARM_BUCKET}/o?uploadType=media&ifGenerationMatch=0&name=${name}" \
    2>/dev/null)
  case "$HTTP_CODE" in
    200 | 201 | 412) : ;;
    # The API's own message, trimmed to one line. It names the refused
    # permission on a 403, which is the single most useful thing this step can
    # say and the thing it could not say before.
    *) err_detail=$(tr '\n' ' ' <"$body" | cut -c1-200) ;;
  esac
  return 0
}

# The object's METADATA, by name — `storage.objects.get` against that one
# object, so the prefix condition on the grant matches. Same request
# `gcloud storage objects describe` made, without starting a Python interpreter
# per artifact. Prints 200 (there), 404 (not there) or anything else (unknown —
# the upload decides, and `ifGenerationMatch=0` keeps that safe).
gcs_exists() { # <percent-encoded object name> <body>
  [ -n "$GCS_TOKEN" ] || { printf 'none'; return 0; }
  curl -sS --proto '=https' --connect-timeout 10 --max-time 60 \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$GCS_TOKEN") \
    -o "$2" -w '%{http_code}' \
    "https://storage.googleapis.com/storage/v1/b/${WARM_BUCKET}/o/${1}?fields=name" \
    2>/dev/null || true
}

# A `.tar.zst` that was cut off — a build killed mid-write, a full disk — still
# has a hash-shaped name and a plausible size. Published, it is a write-once
# object every pull request would unpack into its output tree until the age
# bound expires it. The frame magic is checked always; a full decode when the
# image has zstd.
is_whole_zstd() { # <file>
  local magic
  magic=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "28b52ffd" ] || return 1
  if command -v zstd >/dev/null 2>&1; then
    zstd -tq -- "$1" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# One artifact, in a background subshell: the outcome is written as one word to
# a file named for the hash, because a subshell's counters die with it.
publish_one() { # <artifact> <hash> <size>
  local artifact="$1" hash="$2" size="$3" body code
  body="$RESULTS/$hash.body"

  code=$(gcs_exists "${ENC_PREFIX}${hash}" "$body")
  if [ "$code" = "200" ]; then
    echo skipped >"$RESULTS/$hash"
    return 0
  fi

  if ! is_whole_zstd "$artifact"; then
    log "refusing '$hash': not a complete zstd frame — a truncated artifact is never published"
    echo refused >"$RESULTS/$hash"
    return 0
  fi

  if [ "$WARM_DRY_RUN" = "1" ]; then
    log "would publish $hash (${size}B)"
    echo published >"$RESULTS/$hash"
    return 0
  fi

  gcs_upload "$artifact" "${ENC_PREFIX}${hash}" "$body"
  case "$HTTP_CODE" in
    200 | 201) echo published >"$RESULTS/$hash" ;;
    # `ifGenerationMatch=0` refused it: something wrote that name between the
    # check above and this request — an overlapping warm. Whatever is there was
    # written by this same identity from this same branch, under a name that is
    # a digest of the task's inputs, so it is the same artifact.
    412) echo skipped >"$RESULTS/$hash" ;;
    *)
      # The reason, not just the count. This step reported `failed=291` with no
      # other output for months of nightly runs, and the cause — one refused
      # permission, the same one for all 291 — was not recoverable from the log.
      log "could not publish $hash: HTTP ${HTTP_CODE:-none}${err_detail:+ — $err_detail}"
      echo failed >"$RESULTS/$hash"
      ;;
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

refused=0
served=0
running=0

# `find` rather than a glob: a monorepo's cache directory routinely holds more
# entries than a command line can carry. -maxdepth 1 because only the top level
# holds artifacts; turbo keeps its own bookkeeping in subdirectories.
#
# STREAMED through process substitution, not a pipe: a pipe would run the loop in
# a subshell and `wait` below would have no children to wait for.
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

  # Served from this prefix by the build step's read-only server: already there.
  if [ -n "$WARM_SERVED_DIR" ] && [ -f "$WARM_SERVED_DIR/$hash" ]; then
    served=$((served + 1))
    continue
  fi

  size=$(stat -c %s "$artifact" 2>/dev/null || echo 0)
  if [ "$size" -gt "$WARM_MAX_BYTES" ]; then
    # The host-side server treats anything over its bound as a miss, so
    # publishing this would cost storage and never serve a read.
    log "refusing '$hash': ${size}B is over the ${WARM_MAX_BYTES}B artifact bound"
    refused=$((refused + 1))
    continue
  fi

  # Minted (or re-used) HERE, in the parent, so every child inherits the same
  # token as a shell variable — never as an argument.
  gcs_token || GCS_TOKEN=""

  # The bound. `wait -n` returns as soon as any one child finishes.
  if [ "$running" -ge "$PUBLISH_PARALLEL" ]; then
    wait -n
    running=$((running - 1))
  fi
  publish_one "$artifact" "$hash" "$size" &
  running=$((running + 1))
done < <(find "$WARM_TURBO_DIR" -maxdepth 1 -type f -name '*.tar.zst' 2>/dev/null)
wait

count_of() { find "$RESULTS" -maxdepth 1 -type f ! -name '*.body' -exec cat {} + 2>/dev/null | grep -cx "$1"; }
published=$(count_of published)
skipped=$(count_of skipped)
failed=$(count_of failed)
refused=$((refused + $(count_of refused)))

log "published=$published already-present=$((skipped + served)) served-by-the-store=$served refused=$refused failed=$failed"

# A failed upload is not a failed warm. The next scheduled run republishes it,
# and every build in between simply misses on that one task — which is what it
# would have done anyway. Failing here would turn a partial warm into a red
# build somebody has to triage.
exit 0
