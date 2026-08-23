#!/usr/bin/env python3
"""Turborepo remote cache — served by the host, so a repository configures nothing.

WHY THIS EXISTS

A remote build cache is the single largest win left for the monorepos on this
fleet (docs/ci-optimization-catalog.md, 4.4): it dedupes work ACROSS pull
requests, where a path filter only ever helps within one. IntegrateIT built one
by hand — `gcloud storage cp` inside its own workflow, against its own bucket,
with its own credentials — and that arrangement is exactly what failed silently
for weeks: the workflow authenticated nowhere, picked up a credential another
job had left in the shared home, and ran with a permanently cold cache while
every run looked green (README.md, and 4b in the catalog).

The lesson is not "fix that workflow". It is that a cache which every repository
wires up by hand is a cache every repository can wire up wrong, invisibly. So
the fleet serves it: the host runs this, points every slot at it through
TURBO_API/TURBO_TOKEN, and a repository adds NOTHING to its workflows. There is
no per-repo bucket, no per-repo credential, and nothing for a repository to
forget to renew.

WHAT IT IS NOT: A WRITE PATH FOR JOB CODE

This server is READ-ONLY against the shared store, and that is the whole
security argument rather than a limitation to be lifted later.

A host executes pull-request code. If a job could write into a cache that later
jobs read, then one pull request would hand build output to every later build in
that repository — the same channel the per-slot cache copy closes within a host
(host-pool README) and the snapshot bucket's read-only host grant closes across
hosts (cache-bucket README), re-opened one layer up and with a much better
delivery mechanism: a Turborepo artifact is a tarball that is unpacked straight
into the next build's output directories and then EXECUTED as that build's
result. A fork's first run would own every subsequent build.

So the write side belongs, as it does for the dependency snapshot, to an
identity that never runs pull-request code: the cache warmer builds the default
branch on a schedule and publishes the artifacts. This host reads what the
warmer wrote and nothing else.

A PUT from a job is therefore accepted and discarded — 202, body drained, stored
nowhere. Not refused: `turbo` reports an upload failure as a warning per
artifact, and a build that produces two hundred of them turns a working cache
into a log that reads like a broken one. That was the observable which hid the
IntegrateIT fault for weeks, and reproducing it here would be a poor trade for
strictness nothing acts on. What a job may believe about its own uploads costs
nothing; what a job may hand the next build is everything.

THE DISK CACHE IS A COPY OF THE STORE, NEVER OF A JOB

A host that has served one build already has the bytes. Reading them from GCS
again, for every slot, on every run, is the cross-region-hydrate cost this fleet
already refuses elsewhere. So a fetched artifact is kept on local disk, root
owned, and served from there next time.

It holds only what came OUT of the trusted store, keyed by the hash the store
served it under. Nothing a job PUT reaches it, so the local copy can never be
the difference between what one pull request built and what the next one runs.
"""

import errno
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MD_ROOT = "http://169.254.169.254/computeMetadata/v1/"
MD_HEADERS = {"Metadata-Flavor": "Google"}
GCS_ROOT = "https://storage.googleapis.com/storage/v1/b/"

BUCKET = os.environ.get("CI_TURBO_BUCKET", "").strip()
# Trailing slash included by the caller. The prefix is what confines this host
# to its own repository's artifacts, and it is also what the IAM condition on
# the host's read grant names — two statements of the same boundary, one of
# which is enforced by the storage service even if this file is wrong.
PREFIX = os.environ.get("CI_TURBO_PREFIX", "").strip()
BIND_HOST = os.environ.get("CI_TURBO_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("CI_TURBO_PORT", "8082"))
TOKEN = os.environ.get("CI_TURBO_TOKEN", "").strip()
DISK_DIR = os.environ.get("CI_TURBO_DISK_DIR", "/var/lib/ci-turbo-cache")
DISK_BUDGET = int(os.environ.get("CI_TURBO_DISK_BUDGET_BYTES", str(8 * 1024**3)))
MAX_ARTIFACT = int(os.environ.get("CI_TURBO_MAX_ARTIFACT_BYTES", str(512 * 1024**2)))

# A Turborepo artifact is named by the hash of its inputs, and that name is the
# only thing this server ever puts into a URL or a file path. Anything outside
# this alphabet is refused before it is used, so neither `..` nor a slash nor a
# percent-encoded one can reach the object name or the disk path.
HASH_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

_token_lock = threading.Lock()
_token = {"value": None, "expires_at": 0.0}
_disk_lock = threading.Lock()


def _host_token():
    """The HOST identity's access token, held only inside this root process.

    Job code cannot obtain it: the slot namespaces REJECT the metadata server
    (host-startup.sh, setup_slot_networking), and this token never leaves this
    process — it is not in argv, and /proc of a root process is unreadable to a
    slot under hidepid=2.
    """
    now = time.time()
    with _token_lock:
        if _token["value"] and now < _token["expires_at"]:
            return _token["value"]

    req = urllib.request.Request(
        MD_ROOT + "instance/service-accounts/default/token", headers=MD_HEADERS
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        out = json.loads(resp.read())

    # Re-mint five minutes early, for the same reason the job broker does: a
    # token that expires between the check and the call fails a fetch that had
    # no other reason to fail, and a cache miss is indistinguishable from one.
    ttl = max(int(out.get("expires_in", 3600)) - 300, 60)
    with _token_lock:
        _token["value"] = out["access_token"]
        _token["expires_at"] = time.time() + ttl
    return out["access_token"]


def _object_name(hash_):
    return PREFIX + hash_


def _disk_path(hash_):
    return os.path.join(DISK_DIR, hash_)


def _read_disk(hash_):
    try:
        with open(_disk_path(hash_), "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    # Touch on read: eviction below is by last use, and a hot artifact that was
    # written once at the start of the day must not be the first thing dropped.
    try:
        os.utime(_disk_path(hash_), None)
    except OSError:
        pass
    return data


def _write_disk(hash_, data):
    """Best effort, and silent on failure: this is a cache of a cache.

    Written to a temporary name in the same directory and renamed, because two
    slots can miss on the same hash at the same moment and a partially written
    file served to the second one is a corrupt artifact unpacked into a build.
    """
    tmp = _disk_path(hash_) + ".%d.tmp" % os.getpid()
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, _disk_path(hash_))
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return
    _evict_if_over_budget()


def _evict_if_over_budget():
    """Keep the local copy under its budget, oldest use first.

    The budget exists because this directory shares the boot disk with every
    slot's workspace and every image layer. A cache that fills that disk does
    not slow a build down, it fails every job on the host at once — which is a
    worse outcome than the cold reads this directory exists to avoid.
    """
    with _disk_lock:
        try:
            entries = []
            total = 0
            with os.scandir(DISK_DIR) as it:
                for entry in it:
                    try:
                        st = entry.stat()
                    except OSError:
                        continue
                    entries.append((st.st_atime, st.st_size, entry.path))
                    total += st.st_size
            if total <= DISK_BUDGET:
                return
            # Down to 80% rather than to exactly the budget: evicting one file
            # per write would run this scan on every miss for the rest of the
            # host's life.
            target = int(DISK_BUDGET * 0.8)
            for _, size, path in sorted(entries):
                if total <= target:
                    break
                try:
                    os.unlink(path)
                    total -= size
                except OSError:
                    pass
        except OSError:
            pass


def _fetch(hash_):
    """The artifact bytes, from disk if this host has them, else from the store.

    Returns None for a miss. A miss is the normal case for a build the warmer
    has not run yet and must be cheap and quiet; an ERROR is also returned as a
    miss, because a cache that fails a build when its backing store is
    unreachable is worse than no cache at all.
    """
    data = _read_disk(hash_)
    if data is not None:
        return data

    url = (
        GCS_ROOT
        + urllib.parse.quote(BUCKET, safe="")
        + "/o/"
        + urllib.parse.quote(_object_name(hash_), safe="")
        + "?alt=media"
    )
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": "Bearer " + _host_token(),
            # Not an optimisation: an object stored with Content-Encoding gzip
            # is transcoded on the way out unless the client says it takes gzip,
            # and a transcoded response arrives with no Content-Length. The
            # bytes turbo hashed are the bytes as stored.
            "Accept-Encoding": "gzip",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            declared = resp.headers.get("Content-Length")
            if declared is not None and int(declared) > MAX_ARTIFACT:
                return None
            # Bounded regardless of what the header claimed: read one byte past
            # the cap and refuse if it arrives, so a chunked response cannot put
            # an unbounded object into this process's memory.
            data = resp.read(MAX_ARTIFACT + 1)
            if len(data) > MAX_ARTIFACT:
                return None
    except urllib.error.HTTPError as exc:
        if exc.code not in (403, 404):
            sys.stderr.write("[ci-turbo-cache] fetch %s: HTTP %d\n" % (hash_, exc.code))
        return None
    except Exception as exc:  # noqa: BLE001 - a miss, never a failed build
        sys.stderr.write("[ci-turbo-cache] fetch %s: %s\n" % (hash_, exc))
        return None

    _write_disk(hash_, data)
    return data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        sys.stderr.write("[ci-turbo-cache] " + (fmt % args) + "\n")

    # --- plumbing -------------------------------------------------------------

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _bytes(self, data, head_only=False):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if not head_only:
            self.wfile.write(data)

    def _authorized(self):
        """The token is a misconfiguration check, not the boundary.

        The boundary is the network: this port is bound on the slot gateways and
        REJECTed on the host's primary interface, so the only clients are slots
        on this host and every one of them gets the same read-only view of the
        same repository's artifacts. There is nothing here for one slot to keep
        from another.

        What the check does buy is a clear answer when a workflow points TURBO_API
        at this host with a token of its own from some other cache — which would
        otherwise silently read this repository's artifacts under a team name
        that means nothing here.
        """
        if not TOKEN:
            return True
        got = self.headers.get("Authorization", "")
        return got.startswith("Bearer ") and got[7:].strip() == TOKEN

    def _hash_from(self, path):
        # /v8/artifacts/<hash>
        tail = path[len("/v8/artifacts/"):]
        tail = tail.split("?")[0]
        return tail if HASH_RE.match(tail) else None

    # --- the Turborepo remote cache API --------------------------------------

    def do_GET(self):  # noqa: N802 - stdlib signature
        self._get(head_only=False)

    def do_HEAD(self):  # noqa: N802 - stdlib signature
        self._get(head_only=True)

    def _get(self, head_only):
        path = urllib.parse.urlsplit(self.path).path

        # Asked before anything else by every turbo version, and the answer is
        # what turns the feature on in the client. An unauthenticated 200 here
        # is deliberate: it discloses nothing and a 401 makes turbo disable the
        # cache for the whole run, which is the failure this server exists to
        # end.
        if path in ("/v8/artifacts/status", "/v2/artifacts/status"):
            self._json(200, {"status": "enabled"})
            return

        if not self._authorized():
            self._json(401, {"error": "unknown cache token"})
            return

        if path.startswith("/v8/artifacts/"):
            hash_ = self._hash_from(path)
            if hash_ is None:
                self._json(400, {"error": "bad artifact hash"})
                return
            data = _fetch(hash_)
            if data is None:
                self._json(404, {"error": "artifact not found"})
                return
            self._bytes(data, head_only=head_only)
            return

        self._json(404, {"error": "not a turbo cache path"})

    def do_PUT(self):  # noqa: N802 - stdlib signature
        """Accepted, drained, discarded. See the header for why it is not a 4xx.

        The body is read to the end even though nothing keeps it: with
        HTTP/1.1 keep-alive, replying without consuming the request leaves the
        unread bytes at the head of the next request on that connection, and
        turbo then reports a protocol error for an artifact it never uploaded.
        """
        self._drain()
        self._json(202, {"urls": []})

    def _drain(self):
        """Consume the request body, or give up on the connection instead.

        A framed body is read and dropped. A CHUNKED one is not decoded here —
        this server never wants a byte of it, and half-implementing chunked
        decoding to throw the result away is how a keep-alive connection ends up
        one frame out of step, which surfaces as a protocol error on the NEXT
        request and gets blamed on whatever artifact that was. Closing the
        connection costs one handshake and leaves nothing mis-framed.
        """
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            self.close_connection = True
            return
        try:
            remaining = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            return
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 1024 * 1024))
            if not chunk:
                break
            remaining -= len(chunk)

    def do_POST(self):  # noqa: N802 - stdlib signature
        path = urllib.parse.urlsplit(self.path).path
        self._drain()
        # Turbo posts cache hit/miss telemetry here and treats a non-2xx as a
        # cache error. There is no telemetry sink in this fleet — the host's own
        # metrics carry what an operator needs — so it is answered and dropped.
        if path in ("/v8/artifacts/events", "/v2/artifacts/events"):
            self._json(200, {})
            return
        self._json(404, {"error": "not a turbo cache path"})


def main():
    if not BUCKET or not PREFIX:
        sys.stderr.write(
            "[ci-turbo-cache] CI_TURBO_BUCKET/CI_TURBO_PREFIX are empty — refusing to "
            "start. A cache server with no store answers every read with a miss "
            "while looking healthy, which is the failure this replaces.\n"
        )
        return 2

    try:
        os.makedirs(DISK_DIR, exist_ok=True)
        # Root only. The bytes here are unpacked into a build's output tree, so a
        # directory a slot could write is a slot writing the next build's result.
        os.chmod(DISK_DIR, 0o700)
    except OSError as exc:
        if exc.errno != errno.EEXIST:
            sys.stderr.write("[ci-turbo-cache] cannot use %s: %s\n" % (DISK_DIR, exc))
            return 2

    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    sys.stderr.write(
        "[ci-turbo-cache] serving gs://%s/%s read-only on %s:%d\n"
        % (BUCKET, PREFIX, BIND_HOST, BIND_PORT)
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
