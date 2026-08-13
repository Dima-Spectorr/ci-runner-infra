#!/usr/bin/env python3
"""Self-test for the job credential broker's request routing.

The property under test is the one that makes the metadata fence worth having:
NO request shape may cause a HOST token to reach job code. A percent-encoded or
dot-segmented path that slips past the service-account branch and into the
proxy would be handed to the real metadata server, which decodes it — a full
bypass that looks like a routing detail.

No network: the upstream fetch and the impersonation call are stubbed, so this
runs on a GitHub-hosted runner with no GCP identity at all.
"""

import importlib.util
import io
import os
import pathlib
import sys

os.environ["CI_JOB_SERVICE_ACCOUNT"] = "job-sa@example.iam.gserviceaccount.com"

BROKER = (
    pathlib.Path(__file__).resolve().parents[2]
    / "modules"
    / "ci-runner-host-pool"
    / "scripts"
    / "job-metadata-broker.py"
)

spec = importlib.util.spec_from_file_location("broker", BROKER)
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)

# Stubs. `_md` standing in for the real metadata server returns a marker that a
# leak is immediately recognisable by.
UPSTREAM = {}


def fake_md(rel):
    UPSTREAM["last"] = rel
    if "service-accounts" in rel:
        return b"HOST-TOKEN-LEAKED"
    return b"upstream:" + rel.encode()


broker._md = fake_md
broker._job_token = lambda: ("JOB-TOKEN", 3300)


class FakeHandler(broker.Handler):
    """Drives do_GET without a socket."""

    def __init__(self, path, headers=None):
        self.path = path
        self.headers = headers if headers is not None else {"Metadata-Flavor": "Google"}
        self.status = None
        self.body = b""
        self.wfile = io.BytesIO()

    def send_response(self, code, *a):
        self.status = code

    def send_header(self, *a):
        pass

    def end_headers(self):
        pass

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/text"):
        self.status = code
        self.body = body.encode() if isinstance(body, str) else body


def get(path, headers=None):
    h = FakeHandler(path, headers)
    h.do_GET()
    return h.status, h.body


failures = []


def check(name, cond, detail=""):
    if cond:
        print("ok   - %s" % name)
    else:
        print("FAIL - %s %s" % (name, detail))
        failures.append(name)


# 1. The happy path: a job asks for a token and gets the JOB one.
status, body = get("/computeMetadata/v1/instance/service-accounts/default/token")
check("token endpoint serves the job token", status == 200 and b"JOB-TOKEN" in body, body)

# 2. The header google-auth always sends is required.
status, _ = get("/computeMetadata/v1/instance/service-accounts/default/token", headers={})
check("missing Metadata-Flavor is refused", status == 403)

# 3. Bypass shapes. Each of these previously routed to the proxy.
for name, path in [
    (
        "percent-encoded service-accounts",
        "/computeMetadata/v1/instance/%73ervice-accounts/default/token",
    ),
    (
        "dot-segment traversal",
        "/computeMetadata/v1/instance/attributes/../service-accounts/default/token",
    ),
    (
        "double-encoded",
        "/computeMetadata/v1/instance/%2573ervice-accounts/default/token",
    ),
]:
    status, body = get(path)
    check(
        "no host token via %s" % name,
        b"HOST-TOKEN-LEAKED" not in body,
        "status=%s body=%r" % (status, body),
    )

# 4. Non-identity metadata still proxies, or the credential libraries cannot
#    even construct credentials.
status, body = get("/computeMetadata/v1/project/project-id")
check("project-id proxies", status == 200 and body.startswith(b"upstream:"), body)

# 5. Another account may not be requested by name to dodge the override.
status, body = get(
    "/computeMetadata/v1/instance/service-accounts/"
    "967881749820-compute@developer.gserviceaccount.com/token"
)
check("foreign account is refused", status == 404, "status=%s" % status)

# 6. The shapes gcloud actually asks for while resolving ADC, in order. The
#    directory listing has a trailing slash that normalisation strips; serving it
#    a 403 is what "the metadata server is concealed" means, and it kills every
#    deploy step on a warm host before its first API call.
status, body = get("/computeMetadata/v1/instance/service-accounts/")
check(
    "service-account listing is served, not proxied",
    status == 200 and b"default" in body,
    "status=%s body=%r" % (status, body),
)

status, body = get("/computeMetadata/v1/instance/service-accounts/default/?recursive=true")
check(
    "recursive default account describes the job identity",
    status == 200 and b"job-sa@" in body and b"HOST-TOKEN-LEAKED" not in body,
    "status=%s body=%r" % (status, body),
)

status, body = get("/computeMetadata/v1/instance/service-accounts/default/email")
check("default email is the job account", status == 200 and b"job-sa@" in body, body)

sys.exit(1 if failures else 0)
