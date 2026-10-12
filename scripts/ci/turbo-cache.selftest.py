#!/usr/bin/env python3
"""Self-test for the host's Turborepo remote cache server.

Two properties, and only one of them is about speed.

THE SECURITY ONE: nothing a job sends may become something a later build reads.
A host runs pull-request code, and a build artifact is a tarball the next build
unpacks into its output tree and reports as its own result — so a PUT that
reached the store, or the local disk copy, or even the process's own memory
between requests, would let one pull request hand every later build in that
repository its output. The tests below drive real PUTs and then assert the store
was never called and the disk holds nothing.

THE CORRECTNESS ONE: the shapes turbo actually sends have to work, because every
way this server can be subtly wrong presents as "the cache is enabled and the
build is slow", which is exactly the failure that hid on IntegrateIT for weeks.
`status` must answer without a token or turbo disables the cache for the whole
run; a bad hash must not reach the object name; a miss must be a 404 and not a
500.

No network and no GCP identity: the store fetch is stubbed, so this runs on a
GitHub-hosted runner.
"""

import importlib.util
import io
import os
import pathlib
import shutil
import sys
import tempfile

DISK = tempfile.mkdtemp(prefix="turbo-selftest-")

os.environ["CI_TURBO_BUCKET"] = "example-ci-cache"
os.environ["CI_TURBO_PREFIX"] = "turbo/acme/widgets/"
os.environ["CI_TURBO_TOKEN"] = "host-token"
os.environ["CI_TURBO_DISK_DIR"] = DISK
os.environ["CI_TURBO_MAX_ARTIFACT_BYTES"] = "1024"

SERVER = (
    pathlib.Path(__file__).resolve().parents[2]
    / "modules"
    / "ci-runner-host-pool"
    / "scripts"
    / "turbo-cache-server.py"
)

spec = importlib.util.spec_from_file_location("turbo", SERVER)
turbo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(turbo)

# The store, stubbed at the connection. Every request it is asked for is
# recorded, so a test can assert not only what came back but that nothing was
# asked for at all — and every connection opened is counted, so a test can
# assert one keep-alive connection served many artifacts.
STORE = {"turbo/acme/widgets/deadbeef": b"ARTIFACT-BYTES"}
ASKED = []
OPENED = []  # every FakeConn ever created
# Per-object faults, keyed by object name:
#   "cut"       the body stops short of its Content-Length (http.client raises)
#   "short"     the body ends cleanly but short of its Content-Length
#   "chunked"   no Content-Length at all
#   "status:N"  the store answers HTTP N
FAULTS = {}
# The next request on a REUSED connection fails as a store-closed keep-alive does.
STALE_NEXT = []


class FakeResp:
    def __init__(self, status, body, length, cut=False):
        self.status = status
        self._body = io.BytesIO(body)
        self._length = length
        self._cut = cut
        self.will_close = False

    def getheader(self, name, default=None):
        if name.lower() == "content-length" and self._length is not None:
            return str(self._length)
        return default

    def read(self, n=None):
        chunk = self._body.read(n) if n else self._body.read()
        if not chunk and self._cut:
            raise turbo.http.client.IncompleteRead(b"", 10)
        return chunk


class FakeConn:
    def __init__(self):
        self.closed = False
        self.used = 0
        OPENED.append(self)

    def request(self, method, url, headers=None):
        if self.closed:
            raise AssertionError("a closed connection was lent again")
        if method != "GET":
            raise AssertionError("the server used %s against the store" % method)
        if not url.startswith(turbo.STORE_PATH):
            raise AssertionError("the server reached something other than the store: %s" % url)
        if (headers or {}).get("Authorization") != "Bearer HOST-TOKEN":
            raise AssertionError("a store request without the host token: %r" % headers)
        self.used += 1
        if self.used > 1 and STALE_NEXT:
            STALE_NEXT.pop()
            raise turbo.http.client.RemoteDisconnected("closed by peer")
        self._url = url

    def getresponse(self):
        name = self._url.split("/o/")[1].split("?")[0].replace("%2F", "/")
        ASKED.append(name)
        fault = FAULTS.get(name, "")
        if fault.startswith("status:"):
            return FakeResp(int(fault[7:]), b"error", 5)
        if name not in STORE:
            return FakeResp(404, b"Not Found", 9)
        data = STORE[name]
        if fault == "cut":
            return FakeResp(200, data[: len(data) // 2], len(data), cut=True)
        if fault == "short":
            return FakeResp(200, data[: len(data) // 2], len(data))
        if fault == "chunked":
            return FakeResp(200, data, None)
        return FakeResp(200, data, len(data))

    def close(self):
        self.closed = True


turbo._new_store_connection = FakeConn
turbo._host_token = lambda: "HOST-TOKEN"
# Small enough that every artifact below crosses several chunks, so the
# streaming loops are exercised rather than satisfied by one read.
turbo.CHUNK = 4


class FakeHandler(turbo.Handler):
    """Drives the real handlers, file serving included, without a socket."""

    def __init__(self, path, headers=None, body=b""):
        self.path = path
        base = {"Authorization": "Bearer host-token"}
        if headers is not None:
            base = headers
        if body:
            base = dict(base, **{"Content-Length": str(len(body))})
        self.headers = base
        self.status = None
        self.sent = {}
        self.rfile = io.BytesIO(body)
        self.wfile = io.BytesIO()
        self.close_connection = False

    def send_response(self, code, *a):
        self.status = code

    def send_header(self, name, value):
        self.sent[name] = value

    def end_headers(self):
        pass

    def log_message(self, *a):
        pass

    @property
    def body(self):
        return self.wfile.getvalue()


def call(method, path, headers=None, body=b""):
    h = FakeHandler(path, headers, body)
    getattr(h, "do_" + method)()
    return h.status, h.body


def leftovers():
    return [n for n in os.listdir(DISK) if n.endswith(".tmp")]


failures = []


def check(name, cond, detail=""):
    if cond:
        print("ok   - %s" % name)
    else:
        print("FAIL - %s %s" % (name, detail))
        failures.append(name)


# 1. status, and it answers WITHOUT a token. A 401 here is not a strict server,
#    it is a server that turns the cache off for the whole run — the client asks
#    this once and believes the answer.
status, body = call("GET", "/v8/artifacts/status", headers={})
check(
    "status is enabled and needs no token",
    status == 200 and b"enabled" in body,
    "status=%s body=%r" % (status, body),
)

# 2. A hit, and then the same hit again without touching the store: the second
#    slot to need an artifact is the case the local copy exists for.
status, body = call("GET", "/v8/artifacts/deadbeef")
check("a stored artifact is served", status == 200 and body == b"ARTIFACT-BYTES", body)
before = len(ASKED)
status, body = call("GET", "/v8/artifacts/deadbeef")
check(
    "the second read comes off local disk, not the store",
    status == 200 and body == b"ARTIFACT-BYTES" and len(ASKED) == before,
    "asked=%r" % ASKED,
)

# 3. A miss is a 404, cheaply. Turbo builds the task; a 500 here would be
#    reported as a cache error and disable the cache for the rest of the run.
status, _ = call("GET", "/v8/artifacts/0123456789abcdef")
check("an artifact the warmer has not published is a 404", status == 404)

# 4. THE ONE THAT MATTERS. A job uploads; nothing reaches the store, nothing
#    reaches the disk, and a later read of that hash is still a miss.
opened_before, asked_before = len(OPENED), len(ASKED)
status, _ = call("PUT", "/v8/artifacts/cafebabe", body=b"POISONED-ARTIFACT")
check("an upload is accepted so turbo does not warn per artifact", status == 202)
check(
    "an upload reaches neither the store nor the disk",
    len(OPENED) == opened_before
    and len(ASKED) == asked_before
    and not os.path.exists(os.path.join(DISK, "cafebabe")),
    "asked=%r" % ASKED[asked_before:],
)
status, _ = call("GET", "/v8/artifacts/cafebabe")
check("what a job uploaded is not readable by the next build", status == 404)

# 5. The body of a discarded upload is drained. Left unread it sits at the head
#    of the next request on a keep-alive connection, and turbo reports a
#    protocol error for an artifact it never sent.
h = FakeHandler("/v8/artifacts/cafebabe", body=b"x" * 4096)
h.do_PUT()
check("the discarded upload's body is consumed", h.rfile.read() == b"")

# 5b. A CHUNKED upload carries no Content-Length, so there is no framed body to
#     drain and the only safe answer is to stop reusing the connection. Reading
#     the raw chunk framing as if it were the body is what would leave the
#     connection one frame out of step — a protocol error reported against
#     whatever request came next.
h = FakeHandler(
    "/v8/artifacts/cafebabe",
    headers={"Authorization": "Bearer host-token", "Transfer-Encoding": "chunked"},
    body=b"1000\r\n" + b"x" * 4096 + b"\r\n0\r\n\r\n",
)
h.close_connection = False
h.do_PUT()
check(
    "a chunked upload is answered and the connection is not reused",
    h.status == 202 and h.close_connection,
    "status=%s close=%r" % (h.status, h.close_connection),
)

# 6. Hash shapes. The hash is the only thing that reaches an object name and a
#    file path, so a traversal must be refused before either.
for name, path in [
    ("dot-segment", "/v8/artifacts/../../etc/passwd"),
    ("percent-encoded slash", "/v8/artifacts/a%2F..%2Fb"),
    ("empty hash", "/v8/artifacts/"),
]:
    asked_before = len(ASKED)
    status, _ = call("GET", path)
    check(
        "refused before it reaches the store: %s" % name,
        status in (400, 404) and len(ASKED) == asked_before,
        "status=%s asked=%r" % (status, ASKED[asked_before:]),
    )

# 7. Every read is confined to this repository's prefix — the same boundary the
#    IAM condition states, asserted here so a bug in this file cannot rely on
#    the grant to catch it.
check(
    "every object asked for is under the configured prefix",
    all(n.startswith("turbo/acme/widgets/") for n in ASKED),
    "asked=%r" % ASKED,
)

# 8. A token from some other cache reads nothing. Not the boundary — the port is
#    REJECTed off-host — but the difference between a clear failure and a
#    workflow silently reading a cache it did not mean to.
status, _ = call("GET", "/v8/artifacts/deadbeef", headers={"Authorization": "Bearer someone-elses"})
check("an unknown token is refused", status == 401)

# 9. The size bound holds even when the store lies about Content-Length: a
#    chunked response has none at all, and the bytes still must not land.
STORE["turbo/acme/widgets/huge"] = b"z" * 5000
status, _ = call("GET", "/v8/artifacts/huge")
check(
    "an artifact over the bound is a miss, and is not kept",
    status == 404 and not os.path.exists(os.path.join(DISK, "huge")),
)

# 10. Telemetry is answered. Turbo treats a non-2xx from this endpoint as a
#     cache error, which is a red herring in a log that is otherwise fine.
status, _ = call("POST", "/v8/artifacts/events", body=b"[]")
check("cache events are answered", status == 200)

# 11. ONE keep-alive connection serves many artifacts. A new TLS connection per
#     artifact is a handshake for each of the hundreds one build replays.
for i in range(5):
    STORE["turbo/acme/widgets/pool%d" % i] = b"P%d" % i * 10
opened_before = len(OPENED)
results = [call("GET", "/v8/artifacts/pool%d" % i) for i in range(5)]
check(
    "sequential store fetches reuse one pooled connection",
    all(s == 200 for s, _ in results) and len(OPENED) - opened_before <= 1,
    "opened=%d" % (len(OPENED) - opened_before),
)

# 12. The served response carries the artifact's true length and its whole body,
#     streamed in chunks (CHUNK is 4 bytes here); HEAD carries the length alone.
STORE["turbo/acme/widgets/multi"] = bytes(range(256)) * 3
h = FakeHandler("/v8/artifacts/multi")
h.do_GET()
check(
    "a multi-chunk artifact is served whole under its exact Content-Length",
    h.status == 200
    and h.body == STORE["turbo/acme/widgets/multi"]
    and h.sent.get("Content-Length") == str(len(STORE["turbo/acme/widgets/multi"])),
    "status=%s len=%d sent=%r" % (h.status, len(h.body), h.sent),
)
h = FakeHandler("/v8/artifacts/multi")
h.do_HEAD()
check(
    "HEAD answers the length with no body",
    h.status == 200 and h.body == b"" and h.sent.get("Content-Length") == "768",
    "sent=%r body=%r" % (h.sent, h.body[:16]),
)

# 13. A body the store cuts off mid-stream is a MISS, never a smaller artifact:
#     nothing is kept, no temporary file is left, and the connection that
#     carried it is closed rather than lent to the next request.
for fault in ("cut", "short"):
    name = "turbo/acme/widgets/" + fault
    STORE[name] = b"y" * 200
    FAULTS[name] = fault
    opened_before = len(OPENED)
    status, body = call("GET", "/v8/artifacts/" + fault)
    conn = OPENED[-1]
    check(
        "a %s body is a miss, is not kept, and its connection is dropped" % fault,
        status == 404
        and not os.path.exists(os.path.join(DISK, fault))
        and not leftovers()
        and conn.closed
        and conn not in turbo._pool._idle,
        "status=%s tmp=%r closed=%r" % (status, leftovers(), conn.closed),
    )

# 14. No Content-Length at all: complete bodies are kept, oversize ones are not.
STORE["turbo/acme/widgets/chunk1"] = b"c" * 100
FAULTS["turbo/acme/widgets/chunk1"] = "chunked"
status, body = call("GET", "/v8/artifacts/chunk1")
check("a complete chunked response is served", status == 200 and body == b"c" * 100)
STORE["turbo/acme/widgets/chunk2"] = b"c" * 5000
FAULTS["turbo/acme/widgets/chunk2"] = "chunked"
status, _ = call("GET", "/v8/artifacts/chunk2")
check(
    "a chunked response over the bound is a miss and leaves nothing",
    status == 404 and not os.path.exists(os.path.join(DISK, "chunk2")) and not leftovers(),
)

# 15. A pooled connection the store already closed is retried once on a fresh
#     one: a stale keep-alive must not turn a stored artifact into a miss.
STORE["turbo/acme/widgets/stale"] = b"S" * 40
STORE["turbo/acme/widgets/warm15"] = b"w"
call("GET", "/v8/artifacts/warm15")  # a store fetch: leaves an idle, used connection
STALE_NEXT.append(True)
status, body = call("GET", "/v8/artifacts/stale")
check(
    "a stale pooled connection is replaced, not reported as a miss",
    status == 200 and body == b"S" * 40 and not STALE_NEXT,
    "status=%s stale-left=%r" % (status, STALE_NEXT),
)

# 16. A store error other than 403/404 is a miss, not a 500 turbo would treat as
#     a broken cache.
STORE["turbo/acme/widgets/err"] = b"e"
FAULTS["turbo/acme/widgets/err"] = "status:503"
status, _ = call("GET", "/v8/artifacts/err")
check("a store 503 is a miss", status == 404)

# 17. Every connection kept idle is one whose last response was read to its end:
#     none is closed, and the pool never holds more than its bound.
check(
    "the pool holds only open connections, within its bound",
    all(not c.closed for c in turbo._pool._idle) and len(turbo._pool._idle) <= 16,
)

shutil.rmtree(DISK, ignore_errors=True)
sys.exit(1 if failures else 0)
