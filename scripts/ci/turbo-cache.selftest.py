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

# The store, stubbed. Every request it is asked for is recorded, so a test can
# assert not only what came back but that nothing was asked for at all.
STORE = {"turbo/acme/widgets/deadbeef": b"ARTIFACT-BYTES"}
ASKED = []
OPENED = []


def fake_urlopen(req, timeout=None):  # noqa: ARG001 - stdlib signature
    url = req.full_url if hasattr(req, "full_url") else str(req)
    OPENED.append(url)
    if "storage.googleapis.com" not in url:
        raise AssertionError("the server reached something other than the store: %s" % url)
    if req.get_method() != "GET":
        raise AssertionError("the server used %s against the store" % req.get_method())
    name = url.split("/o/")[1].split("?")[0]
    name = name.replace("%2F", "/")
    ASKED.append(name)
    if name not in STORE:
        raise turbo.urllib.error.HTTPError(url, 404, "Not Found", {}, None)

    class Resp:
        headers = {"Content-Length": str(len(STORE[name]))}

        def read(self, n=None):
            return STORE[name][:n] if n else STORE[name]

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    return Resp()


turbo.urllib.request.urlopen = fake_urlopen
turbo._host_token = lambda: "HOST-TOKEN"


class FakeHandler(turbo.Handler):
    """Drives the handlers without a socket."""

    def __init__(self, path, headers=None, body=b""):
        self.path = path
        base = {"Authorization": "Bearer host-token"}
        if headers is not None:
            base = headers
        if body:
            base = dict(base, **{"Content-Length": str(len(body))})
        self.headers = base
        self.status = None
        self.body = b""
        self.rfile = io.BytesIO(body)
        self.wfile = io.BytesIO()

    def send_response(self, code, *a):
        self.status = code

    def send_header(self, *a):
        pass

    def end_headers(self):
        pass

    def log_message(self, *a):
        pass

    def _json(self, code, payload):
        self.status = code
        self.body = turbo.json.dumps(payload).encode()

    def _bytes(self, data, head_only=False):
        self.status = 200
        self.body = b"" if head_only else data


def call(method, path, headers=None, body=b""):
    h = FakeHandler(path, headers, body)
    getattr(h, "do_" + method)()
    return h.status, h.body


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
opened_before = len(OPENED)
status, _ = call("PUT", "/v8/artifacts/cafebabe", body=b"POISONED-ARTIFACT")
check("an upload is accepted so turbo does not warn per artifact", status == 202)
check(
    "an upload reaches neither the store nor the disk",
    len(OPENED) == opened_before and not os.path.exists(os.path.join(DISK, "cafebabe")),
    "opened=%r" % OPENED[opened_before:],
)
status, _ = call("GET", "/v8/artifacts/cafebabe")
check("what a job uploaded is not readable by the next build", status == 404)

# 5. The body of a discarded upload is drained. Left unread it sits at the head
#    of the next request on a keep-alive connection, and turbo reports a
#    protocol error for an artifact it never sent.
h = FakeHandler("/v8/artifacts/cafebabe", body=b"x" * 4096)
h.do_PUT()
check("the discarded upload's body is consumed", h.rfile.read() == b"")

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

shutil.rmtree(DISK, ignore_errors=True)
sys.exit(1 if failures else 0)
