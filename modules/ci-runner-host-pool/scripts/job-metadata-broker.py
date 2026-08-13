#!/usr/bin/env python3
"""Job credential broker — Application Default Credentials for fenced job code.

WHY THIS EXISTS

Job code on a warm host is fenced off the instance metadata server
(host-startup.sh: fence_metadata). Without that fence any workflow could mint a
token for the HOST service account, which reads the GitHub App private key out
of Secret Manager and can delete instances — a workflow on a fork-able branch
would own the fleet.

But real workflows in this fleet deploy: `gcloud builds submit`,
`gcloud run services describe`. Those need ADC. A fence with no replacement
credential path does not make the fleet safer, it makes deploy workflows fail
and invites someone to remove the fence.

So the fence stays and the credential arrives from a DIFFERENT, weaker identity:
this broker runs as root (unfenced), reads the host token from the real metadata
server, exchanges it for a token of the JOB service account via IAM Credentials,
and serves it on loopback in the shape google-auth/gcloud expect. Jobs point at
it with GCE_METADATA_HOST and never see the host identity.

The security property: whatever a job can reach is exactly what the job service
account was granted. The host account's secret access and instance-delete rights
are not reachable through this broker, because it never vends a host token.

Non-service-account metadata paths are proxied through unchanged (project id,
zone, instance name): they are not secrets, and google-auth asks for them while
constructing credentials.

CONTAINERS: a container started by a job reaches the broker only if the workflow
forwards it (e.g. --network host, or passing GOOGLE_APPLICATION_CREDENTIALS
material in explicitly). This is deliberate — the DOCKER-USER reject rule stays.
"""

import json
import os
import posixpath
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MD_ROOT = "http://169.254.169.254/computeMetadata/v1/"
MD_HEADERS = {"Metadata-Flavor": "Google"}
SA_PREFIX = "/computeMetadata/v1/instance/service-accounts/"
# posixpath.normpath() below strips the trailing slash, so the directory listing
# gcloud asks for FIRST — GET /instance/service-accounts/ — arrives here without
# it and would miss the prefix test, fall through to the proxy, and be refused by
# the "no identity paths are proxied" guard. gcloud reports that 403 as
# "MetadataServerException: the metadata server is concealed" and every deploy
# step on a warm host dies before its first API call.
SA_ROOT = SA_PREFIX.rstrip("/")

JOB_SA = os.environ.get("CI_JOB_SERVICE_ACCOUNT", "").strip()
BIND_HOST = os.environ.get("CI_BROKER_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("CI_BROKER_PORT", "8081"))
SCOPE = "https://www.googleapis.com/auth/cloud-platform"

_lock = threading.Lock()
_cached = {"token": None, "expires_at": 0.0}


def _md(path):
    req = urllib.request.Request(MD_ROOT + path, headers=MD_HEADERS)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.read()


def _host_token():
    raw = _md("instance/service-accounts/default/token")
    return json.loads(raw)["access_token"]


def _job_token():
    """Token for the JOB service account. Cached until shortly before expiry."""
    now = time.time()
    with _lock:
        if _cached["token"] and now < _cached["expires_at"]:
            return _cached["token"], int(_cached["expires_at"] - now)

    url = (
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/"
        + urllib.parse.quote(JOB_SA)
        + ":generateAccessToken"
    )
    body = json.dumps({"scope": [SCOPE], "lifetime": "3600s"}).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": "Bearer " + _host_token(),
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        out = json.loads(resp.read())

    # Re-mint 5 minutes early: a token that expires mid-step fails the step, and
    # a job step can run for minutes after it read the token.
    ttl = 3600 - 300
    with _lock:
        _cached["token"] = out["accessToken"]
        _cached["expires_at"] = time.time() + ttl
    return out["accessToken"], ttl


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        sys.stderr.write("[ci-job-broker] " + (fmt % args) + "\n")

    def _send(self, code, body, ctype="application/text"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # google-auth verifies this header to believe it is on GCE.
        self.send_header("Metadata-Flavor", "Google")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - stdlib signature
        # google-auth pings the root to decide "am I on GCE"; gcloud sends the
        # Metadata-Flavor header on every request, and so must anything else.
        if self.headers.get("Metadata-Flavor") != "Google":
            self._send(403, "Metadata-Flavor: Google header required\n")
            return

        split = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(split.query)

        # Percent-decode and normalise BEFORE matching. Skipping either step is a
        # full bypass of this broker: `/instance/%73ervice-accounts/default/token`
        # or `/instance/x/../service-accounts/default/token` would miss the
        # service-account branch, fall through to the proxy, and be decoded by the
        # real metadata server — handing job code a HOST token.
        path = posixpath.normpath(urllib.parse.unquote(split.path))
        if not path.startswith("/"):
            path = "/" + path

        try:
            if path == SA_ROOT:
                self._service_account("", query)
                return
            if path.startswith(SA_PREFIX):
                self._service_account(path[len(SA_PREFIX):], query)
                return
            if path in ("/", "/computeMetadata/v1/", "/computeMetadata/v1"):
                self._send(200, "computeMetadata/\n")
                return
            # Anything else is non-secret instance/project data. Proxy it: the
            # broker's job is to replace the IDENTITY, not to reimplement the
            # metadata server.
            if not path.startswith("/computeMetadata/v1/"):
                self._send(404, "not a metadata path\n")
                return
            rel = path[len("/computeMetadata/v1/"):]
            # Belt and braces after normalisation: nothing that mentions an
            # identity is ever proxied, whatever shape it arrived in.
            if "service-accounts" in rel:
                self._send(403, "identity paths are served by the broker only\n")
                return
            self._send(200, _md(rel + ("?" + split.query if split.query else "")))
        except urllib.error.HTTPError as exc:
            self._send(exc.code, "upstream: %s\n" % exc.reason)
        except Exception as exc:  # noqa: BLE001 - broker must not die on one request
            self._send(500, "broker error: %s\n" % exc)

    def _service_account(self, rest, query):
        # rest is e.g. "" | "default/" | "default/token" | "default/email"
        parts = [p for p in rest.split("/") if p]
        if not parts:
            self._send(200, "default/\n")
            return

        account = parts[0]
        # The job identity is the ONLY identity this host exposes. An explicit
        # request for another account is refused rather than quietly upgraded.
        if account not in ("default", JOB_SA):
            self._send(404, "no such service account on this host\n")
            return

        leaf = parts[1] if len(parts) > 1 else ""

        if leaf == "token":
            token, ttl = _job_token()
            self._send(
                200,
                json.dumps(
                    {"access_token": token, "expires_in": ttl, "token_type": "Bearer"}
                ),
                "application/json",
            )
            return
        if leaf == "email":
            self._send(200, JOB_SA)
            return
        if leaf == "scopes":
            self._send(200, SCOPE + "\n")
            return
        if leaf == "identity":
            # ID tokens would have to be minted for the job SA too; nothing in
            # this fleet uses them from a runner yet, and guessing an audience
            # is worse than a clear 404.
            self._send(404, "identity tokens are not served by the job broker\n")
            return
        if leaf == "":
            if query.get("recursive", ["false"])[0].lower() == "true":
                self._send(
                    200,
                    json.dumps(
                        {"aliases": ["default"], "email": JOB_SA, "scopes": [SCOPE]}
                    ),
                    "application/json",
                )
            else:
                self._send(200, "aliases\nemail\nscopes\ntoken\n")
            return

        self._send(404, "unsupported service-account attribute\n")


def main():
    if not JOB_SA:
        sys.stderr.write(
            "[ci-job-broker] CI_JOB_SERVICE_ACCOUNT is empty — refusing to start. "
            "A broker with no job identity would vend nothing while looking healthy.\n"
        )
        return 2
    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    sys.stderr.write(
        "[ci-job-broker] serving %s on %s:%d\n" % (JOB_SA, BIND_HOST, BIND_PORT)
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
