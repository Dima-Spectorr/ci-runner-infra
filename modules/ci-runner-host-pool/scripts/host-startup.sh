#!/usr/bin/env bash
# ci-runner-host-pool — host boot.
#
# This script is deliberately SHORT, and that is the point of the whole design.
# It installs nothing. Every expensive thing a job needs — the runner agent,
# the container runtime, language toolchains, and warm dependency caches — is
# already in the golden image (see packer/ci-host-image.pkr.hcl). All this
# script does is register `ci-slots` persistent agents and get out of the way.
#
# The pool it replaces did the opposite: it downloaded and configured a runner,
# then a job installed a toolchain, then the job downloaded its dependencies,
# and then the VM was destroyed so the next job could repeat all of it. That
# repetition is the CI wall time this pool exists to delete.
#
# Agents here are NOT --ephemeral. An ephemeral agent unregisters after one job,
# which is correct when the VM dies with it and wrong here: the host must stay
# hot and keep serving. Job isolation is provided by running each job in a
# container instead of by destroying the machine.

set -uo pipefail

RUNNER_HOME="/opt/actions-runner"
SLOT_ROOT="/opt/ci/slots"
LOG_TAG="ci-host"

# Each slot runs as its OWN Linux user, `ci-s<idx>`, with its OWN rootless
# Docker daemon. Slots used to share the `runner` account and the one system
# daemon, which meant a job could reach /var/run/docker.sock and from there
# enumerate the sibling slots' containers, exec into them, and read their
# GITHUB_TOKEN and workspace — and, because the host is warm, the next jobs'
# too. It also made $HOME shared, which raced pnpm's store install between
# concurrent slots (DataRetrival #2339). One user per slot fixes both (#10).
SLOT_USER_PREFIX="ci-s"
slot_user() { printf '%s%s' "$SLOT_USER_PREFIX" "$1"; }

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a /var/log/ci-host.log; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }
die() { log "FATAL: $*"; exit 1; }

# Bounded, like every call this host makes. A host boot that HANGS is worse than
# one that fails: it never registers an agent, never powers off, and bills at
# warm-host size until the controller's register-grace expires — and while it
# waits it counts as a host the pool already has, so the pool does not add the
# one that would have taken the queued job.
CURL_TIMEOUTS=(--connect-timeout 10 --max-time 30)

md() {
  curl "${CURL_TIMEOUTS[@]}" -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null
}

OWNER=$(md "instance/attributes/ci-github-owner")
REPO=$(md "instance/attributes/ci-github-repo")
APP_ID=$(md "instance/attributes/ci-app-id")
INSTALL_ID=$(md "instance/attributes/ci-app-installation-id")
KEY_SECRET=$(md "instance/attributes/ci-app-key-secret")
LABELS=$(md "instance/attributes/ci-runner-labels")
RUNNER_GROUP=$(md "instance/attributes/ci-runner-group")
SLOTS=$(md "instance/attributes/ci-slots")
POOL=$(md "instance/attributes/ci-pool")
JOB_SA=$(md "instance/attributes/ci-job-service-account")
BROKER_PORT=$(md "instance/attributes/ci-job-broker-port")
HOSTNAME_SHORT=$(md "instance/name")
# Registry hosts the job identity authenticates to. Comma-separated, set by the
# module; see write_slot_docker_config for why the list is explicit.
REGISTRY_HOSTS=$(md "instance/attributes/ci-registry-hosts")
# The regional Artifact Registry of the host's OWN region is always included:
# the overwhelmingly common case is a repository pulling a builder image it
# publishes alongside its runners, and requiring every estate to spell that out
# would make the failure it prevents the default.
INSTANCE_ZONE=$(md "instance/zone")        # projects/<n>/zones/<region>-<x>
INSTANCE_ZONE=${INSTANCE_ZONE##*/}
HOST_REGION=${INSTANCE_ZONE%-*}

BROKER_PORT=${BROKER_PORT:-8081}

SLOTS=${SLOTS:-1}

if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  die "missing ci-github-owner/ci-github-repo metadata"
fi
[ -d "$RUNNER_HOME" ] || die "golden image is missing $RUNNER_HOME — this host was booted from the wrong image, and booting a bare image here would reintroduce the per-job install cost this pool removes"

# --- GitHub App installation token -------------------------------------------
#
# Registration needs a short-lived token, so it is minted on the host from the
# App private key rather than baked anywhere. The key itself is read from Secret
# Manager at boot and never written to disk unencrypted for longer than the
# signing call.
gh_token() {
  local key jwt header payload now
  key=$(gcloud secrets versions access latest --secret="$KEY_SECRET" 2>/dev/null)
  [ -n "$key" ] || { log "could not read App key from secret $KEY_SECRET"; return 1; }

  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  # 9 minutes: GitHub rejects a JWT with more than 10 minutes of life, and a
  # little clock skew must fit inside the difference.
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64)

  local sig
  sig=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -sign <(printf '%s' "$key") | b64)
  jwt="$header.$payload.$sig"

  curl "${CURL_TIMEOUTS[@]}" -fsS -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$INSTALL_ID/access_tokens" \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

registration_token() {
  local tok
  tok=$(gh_token) || return 1
  [ -n "$tok" ] || return 1
  curl "${CURL_TIMEOUTS[@]}" -fsS -X POST \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER/$REPO/actions/runners/registration-token" \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# --- metadata fence -----------------------------------------------------------
#
# Job code must not be able to reach the instance metadata server. It would
# otherwise mint an access token for THIS host's service account, which can read
# the GitHub App private key out of Secret Manager and delete instances — i.e.
# any workflow on a fork-able branch owns the fleet (the #1958 finding on the
# pool this replaces).
#
# Fenced per JOB UID, and there is now one per slot: `runner` (the legacy job
# account, still fenced so nothing that runs as it can reach metadata either)
# plus `ci-s1..ci-sN`. A rootless container's traffic leaves through
# slirp4netns as the slot user, so the OUTPUT owner rule covers a job's
# containers as well as the job itself; the DOCKER-USER rule stays as the guard
# for any rootful bridge traffic that still exists. Root is deliberately NOT
# fenced — this script and the controller's probes need metadata.
#
# Fails CLOSED: a host that cannot install the fence must not serve jobs.
fence_uid() { # <user>
  local md_ip="169.254.169.254" u="$1" proto

  iptables -w -C OUTPUT -d "$md_ip" -m owner --uid-owner "$u" -j REJECT 2>/dev/null \
    || iptables -w -I OUTPUT 1 -d "$md_ip" -m owner --uid-owner "$u" -j REJECT \
    || return 1

  # ...except DNS, which lives on the SAME address. 169.254.169.254 is both the
  # metadata server (HTTP, port 80) and the VPC resolver (port 53), and a
  # container gets it as its only nameserver: the daemon copies the host's
  # UPSTREAM resolver into the container, and on GCE that upstream is the
  # metadata address.
  #
  # A blanket REJECT therefore took name resolution away from every container a
  # job starts, while leaving it intact for the job itself — the job talks to
  # systemd-resolved on 127.0.0.53, a container cannot. The symptom is
  # `Temporary failure in name resolution` inside the container, which reads as
  # a broken upstream registry rather than as host policy.
  #
  # Port 53 is not a credential path: the metadata server serves tokens over
  # HTTP on port 80 only, and the REJECT above still covers it. Verified on a
  # live host — names resolve inside the container, the token endpoint times out.
  for proto in udp tcp; do
    iptables -w -C OUTPUT -d "$md_ip" -p "$proto" --dport 53 -m owner --uid-owner "$u" -j ACCEPT 2>/dev/null \
      || iptables -w -I OUTPUT 1 -d "$md_ip" -p "$proto" --dport 53 -m owner --uid-owner "$u" -j ACCEPT \
      || return 1
  done
}

fence_metadata() {
  local md_ip="169.254.169.254" i

  fence_uid runner || return 1
  for i in $(seq 1 "$SLOTS"); do
    fence_uid "$(slot_user "$i")" || return 1
  done

  # DOCKER-USER is created by dockerd and consulted before docker's own rules.
  # Create it only as a fallback so the rule still exists if dockerd is late.
  iptables -w -N DOCKER-USER 2>/dev/null || true
  iptables -w -C FORWARD -j DOCKER-USER 2>/dev/null \
    || iptables -w -I FORWARD 1 -j DOCKER-USER || return 1
  iptables -w -C DOCKER-USER -d "$md_ip" -j REJECT 2>/dev/null \
    || iptables -w -I DOCKER-USER 1 -d "$md_ip" -j REJECT \
    || return 1
}

# --- job credential broker ----------------------------------------------------
#
# The fence above removes the host identity from job code. Deploy workflows in
# this fleet legitimately need ADC (`gcloud builds submit`,
# `gcloud run services describe`), so the credential comes back from a WEAKER
# identity instead: the broker vends tokens for the job service account only.
# See scripts/job-metadata-broker.py.
#
# No job service account configured = no ADC for jobs, and that is a valid pool
# for a repository whose CI never touches GCP. It is never a silent downgrade to
# the host identity.
start_job_broker() {
  local src
  src=$(md "instance/attributes/ci-job-broker-py")
  [ -n "$src" ] || { log "job broker source missing from metadata"; return 1; }

  printf '%s' "$src" >/opt/ci/job-metadata-broker.py
  chmod 0755 /opt/ci/job-metadata-broker.py

  cat >/etc/systemd/system/ci-job-broker.service <<EOF
[Unit]
Description=CI job credential broker ($POOL)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Root, deliberately: the broker is the ONLY thing on this host that may talk to
# the real metadata server on job code's behalf, and it hands back a token for a
# different, weaker account.
User=root
Environment=CI_JOB_SERVICE_ACCOUNT=$JOB_SA
# Every slot has its OWN loopback now (it has its own network namespace), so a
# broker bound to 127.0.0.1 in the host namespace is unreachable from any of
# them. It binds all addresses instead — including each slot's gateway address —
# and setup_slot_networking REJECTs this port on the primary interface so
# nothing off this host can reach it.
Environment=CI_BROKER_HOST=0.0.0.0
Environment=CI_BROKER_PORT=$BROKER_PORT
ExecStart=/usr/bin/python3 /opt/ci/job-metadata-broker.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ci-job-broker.service >>/var/log/ci-host.log 2>&1 || return 1

  # Prove it before any agent registers: a broker that looks up but vends
  # nothing turns every deploy job into a confusing auth failure at step time.
  local i
  for i in $(seq 1 30); do
    # Bounded so a broker that ACCEPTS but never answers cannot turn a 30x2s
    # readiness probe into an unbounded wait.
    if curl "${CURL_TIMEOUTS[@]}" -fsS -H "Metadata-Flavor: Google" \
      "http://127.0.0.1:$BROKER_PORT/computeMetadata/v1/instance/service-accounts/default/token" \
      >/dev/null 2>&1; then
      log "job credential broker serving $JOB_SA on 127.0.0.1:$BROKER_PORT"
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- per-job credential reset -------------------------------------------------
#
# THE FAULT (IntegrateIT, every pr-check run for weeks): the Turbo remote cache
# was dead on every sampled run. `gcloud storage cp` failed with
#
#   Unable to retrieve Identity Pool subject token
#   {"source":"actions-run-service","statusCode":401,
#    "errorMessage":"token has invalid claims: token is expired"}
#
# `source: actions-run-service` is GitHub's OIDC endpoint, so gcloud was using an
# EXTERNAL_ACCOUNT credential — and the workflow that failed never authenticated
# at all. It was reading a credential a DIFFERENT job had left behind: deploy.yml,
# deploy-mcp-server.yml, cve-triage.yml and windows-agent.yml run on the same
# pool and pair google-github-actions/auth with setup-gcloud, whose
# `gcloud auth login --cred-file=...` writes the external account into the gcloud
# config as the ACTIVE account. A slot user is an ordinary Linux account created
# once per host boot, so its $HOME outlives every job the slot serves — and this
# pool sets no CLOUDSDK_CONFIG and, until now, no job hooks. The credential
# simply stayed. Later jobs then preferred it over the broker, because an
# explicitly configured active account beats ADC-via-metadata, and it failed only
# because its subject token had long since expired.
#
# So the cold cache is the symptom. The defect is that job-scoped credentials
# outlive the job, and the SECURITY half of it does not depend on the expiry: a
# deploy identity left in a shared home is reachable by whatever pull request
# lands on that slot next. Nothing about it is specific to IntegrateIT or to
# gcloud's failure mode, which is why it is fixed on the host rather than in a
# workflow.
#
# Both hooks, deliberately. JOB_COMPLETED alone leaves a live credential sitting
# on disk for however long the slot stays idle, and it does not run at all if the
# agent is killed mid-job — exactly the case that leaves the most behind.
# JOB_STARTED alone leaves the idle window open. Together, a job neither inherits
# nor bequeaths one.
install_job_hooks() {
  mkdir -p /opt/ci/job-hooks || return 1
  chown root:root /opt/ci/job-hooks || return 1
  # Root-owned and not slot-writable: this one file is executed by every slot on
  # the host, so a slot that could rewrite it would be running code in every
  # OTHER slot's uid. The hook itself runs as the slot user and removes only that
  # user's own files.
  chmod 0755 /opt/ci/job-hooks || return 1

  cat >/opt/ci/job-hooks/reset-credentials.sh <<EOF
#!/usr/bin/env bash
# Installed by host-startup.sh. Runs as the slot user, before every job starts
# and after every job ends. See install_job_hooks() for why.
set -uo pipefail

# The passwd entry, not \$HOME: this runs inside the agent's environment, and the
# directory being deleted should be decided by the host's account database rather
# than by a variable a job could have changed.
home=\$(getent passwd "\$(id -un)" | cut -d: -f6)
case "\$home" in
  /home/$SLOT_USER_PREFIX*) ;;
  *) echo "credential reset: refusing to clean '\$home' — not a slot home" >&2; exit 1 ;;
esac

# Only credential stores that NOTHING on this host owns. ~/.docker/config.json is
# deliberately absent: write_slot_docker_config puts the registry helper there,
# and removing it would fail every container job at "Initialize containers"
# instead of fixing anything.
rc=0
for d in "\$home/.config/gcloud" "\$home/.gsutil"; do
  rm -rf -- "\$d" || { echo "credential reset: could not remove \$d" >&2; rc=1; }
done
exit \$rc
EOF

  chown root:root /opt/ci/job-hooks/reset-credentials.sh || return 1
  chmod 0755 /opt/ci/job-hooks/reset-credentials.sh || return 1
}

# --- registry credentials for job containers ----------------------------------
#
# THE FAULT (Borsh-Tablet-App, first pool run): every job declaring
# `container: <region>-docker.pkg.dev/...` failed before its first step with
#
#   Error response from daemon: error from registry: Unauthenticated request.
#   Unauthenticated requests do not have permission
#   "artifactregistry.repositories.downloadArtifacts"
#
# The runner pulls the job container with the slot's own rootless docker, and
# that daemon has no credentials at all. On the retired one-VM-per-job runners
# the pull inherited the VM's identity, so this cost nothing to nobody and was
# invisible until the identities were split.
#
# Handing docker a static token would be the wrong shape: it expires in an hour
# while a host lives for days. A credential helper is asked on every pull, so
# what it returns is as fresh as the broker.
#
# It returns the JOB identity, not the host's — the same account the rest of the
# job gets. A registry the job account cannot read is a grant to add in the
# consuming repository's Terraform, where it is reviewable, and NOT a reason to
# reach for the host account, which can read the GitHub App private key.
install_registry_credential_helper() {
  cat >/usr/local/bin/docker-credential-cijob <<'HELPER'
#!/bin/sh
# Docker credential helper — vends a JOB-identity bearer token for Google
# container registries. `get` is the only verb docker uses for pulls; `store`
# and `erase` must exit cleanly or docker treats a plain `docker login` as a
# failure.
[ "$1" = "get" ] || exit 0
host=$(cat)
: "${GCE_METADATA_HOST:=127.0.0.1:${CI_BROKER_PORT:-8081}}"
token=$(curl --fail --silent --connect-timeout 3 --max-time 10 -H 'Metadata-Flavor: Google' \
  "http://${GCE_METADATA_HOST}/computeMetadata/v1/instance/service-accounts/default/token" \
  | sed -n 's/.*"access_token"[^"]*"\([^"]*\)".*/\1/p')
# No token — say so in docker's own vocabulary and let the pull go anonymous.
#
# The exact string matters: the docker CLI treats it as "this registry has no
# stored credentials" and falls back; anything else is a hard client error. A
# hard error here would mean a pool configured with NO job service account (the
# broker is not started at all in that case) could no longer pull even a PUBLIC
# image — trading one repository's private-registry failure for every
# repository's.
#
# The private-registry case still fails, but at the registry, with the message
# that names the missing permission — which is readable, and is what led here.
[ -n "$token" ] || {
  echo "docker-credential-cijob: no token from the job credential broker at ${GCE_METADATA_HOST}" >&2
  echo "credentials not found in native keychain"
  exit 1
}
printf '{"ServerURL":"%s","Username":"oauth2accesstoken","Secret":"%s"}\n' "$host" "$token"
HELPER
  chmod 0755 /usr/local/bin/docker-credential-cijob
}

# Per slot, because ~/.docker/config.json is read from the HOME of whoever runs
# the docker client, and every slot is its own user.
#
# EVERY KEY IS AN EXACT HOST. The first version of this wrote `"*.pkg.dev"`, on
# the assumption that docker matches credHelpers by pattern. It does not: the
# lookup is an exact map lookup on the registry hostname, so the wildcard entry
# is not an error, it is simply never consulted — and the pull goes out
# anonymous and fails exactly as it did with no config at all. That cost a
# second round trip through a tag, an apply and a host replacement to find, and
# the reason it was not obvious is that the helper itself tested fine by hand.
#
# The list is therefore built rather than written: the host's own region (the
# common case — a repository pulling a builder image it publishes next to its
# runners), the four Container Registry hosts, and whatever else the module was
# given. Only Google registries appear, so docker.io and ghcr.io keep pulling
# anonymously — which a `credsStore` (which DOES apply to every registry) would
# have broken by offering them a Google access token.
write_slot_docker_config() {
  local idx="$1" u hosts h first
  u=$(slot_user "$idx")

  hosts="gcr.io us.gcr.io eu.gcr.io asia.gcr.io"
  [ -n "$HOST_REGION" ] && hosts="$hosts ${HOST_REGION}-docker.pkg.dev"
  [ -n "$REGISTRY_HOSTS" ] && hosts="$hosts $(printf '%s' "$REGISTRY_HOSTS" | tr ',' ' ')"

  install -d -o "$u" -g "$u" -m 0700 "/home/$u/.docker"
  {
    printf '{\n  "credHelpers": {\n'
    first=1
    for h in $hosts; do
      [ -n "$h" ] || continue
      [ "$first" = 1 ] || printf ',\n'
      printf '    "%s": "cijob"' "$h"
      first=0
    done
    printf '\n  }\n}\n'
  } >"/home/$u/.docker/config.json"
  chown "$u:$u" "/home/$u/.docker/config.json"
  chmod 0600 "/home/$u/.docker/config.json"
}

# --- container MTU ------------------------------------------------------------
#
# THE FAULT (Borsh-Tablet-App, the run after the registry fix): a Gradle build
# failed with
#
#   Plugin [id: 'org.cyclonedx.bom', version: '3.3.0'] was not found
#
# and, one step earlier, `Client network socket disconnected before secure TLS
# connection was established`. Both are the same fault, and neither of them says
# what it is. The same URL fetched fine from the host and fine from the job's own
# container on a second attempt — which is the tell, because a blocked
# destination fails every time and this one failed by size.
#
# The VM's interfaces are MTU 1460 (the GCE default) and setup_slot_netns already
# matches the veth pair to it. The BRIDGE the daemon then creates inside that
# namespace does not inherit it: dockerd defaults to 1500, so a container emits
# 1500-byte frames onto a path whose next hop takes 1460. They are dropped, and
# because the drop happens mid-handshake what the client reports is a truncated
# TLS stream — never a size error. Small responses complete, large ones do not,
# so the same build fails in a different place each run.
#
# TWO KEYS, because `mtu` is not the one that matters here. Measured on a live
# host with docker 29.7.2: with `mtu` alone the default `docker0` bridge comes up
# at 1460 and a `docker network create` bridge still comes up at 1500 — and the
# network the runner creates for a `container:` job (`github_network_*`) is
# exactly the second kind, so the setting that looks like the fix changes nothing
# a job can observe. `default-network-opts` supplies the per-driver default that
# those networks inherit. `mtu` is kept for the default bridge, which a job that
# runs `docker run` without a network still lands on.
#
# Read from the primary interface, not written as 1460: an image or estate with
# jumbo frames or a tunnel would be given the wrong number by a literal, and the
# wrong number here fails exactly as invisibly as the default did.
write_slot_daemon_config() {
  local idx="$1" u mtu
  u=$(slot_user "$idx")
  mtu=$(primary_mtu)
  [ -n "$mtu" ] || return 1

  install -d -o "$u" -g "$u" -m 0700 "/home/$u/.config"
  install -d -o "$u" -g "$u" -m 0700 "/home/$u/.config/docker"
  printf '{\n  "mtu": %s,\n  "default-network-opts": {\n    "bridge": { "com.docker.network.driver.mtu": "%s" }\n  }\n}\n' \
    "$mtu" "$mtu" >"/home/$u/.config/docker/daemon.json"
  chown "$u:$u" "/home/$u/.config/docker/daemon.json"
  chmod 0600 "/home/$u/.config/docker/daemon.json"
}

# --- slots --------------------------------------------------------------------
#
# One agent per slot, each as its own USER, in its own directory, with its own
# work folder and its own container daemon, so K jobs on this host collide in
# nothing they can observe. They DO share the image's read-only caches by design
# — that sharing is the speed-up — which is exactly why a pool serves one
# repository only (see README.md, isolation rules).

# The Linux account and the subordinate uid/gid range its rootless daemon needs.
# Without a subuid/subgid range `dockerd-rootless.sh` cannot create a user
# namespace and refuses to start, which is the whole isolation.
provision_slot_user() {
  local idx="$1" u base
  u=$(slot_user "$idx")

  if ! id "$u" >/dev/null 2>&1; then
    # --user-group, not the distro default: ci-dockerd@.service runs as
    # User=ci-s%i Group=ci-s%i, and on an image whose /etc/login.defs sets
    # USERGROUPS_ENAB no the slot would land in the shared `users` group and the
    # unit would fail on an unknown group.
    useradd -m --user-group -s /bin/bash "$u" || return 1
  fi
  # Group `ci` is how a slot reaches the shared warm cache without reaching the
  # other slots' homes (which stay 0750 and owned by their own user).
  getent group ci >/dev/null || groupadd ci
  usermod -aG ci "$u" || return 1
  # Enforce the mode rather than inherit it. HOME_MODE / UMASK in login.defs
  # decides what `useradd -m` creates, and a 0755 home is exactly the sibling
  # readability this split exists to remove — an unenforced comment is not an
  # isolation boundary.
  getent group "$u" >/dev/null || return 1
  chown "$u:$u" "/home/$u" || return 1
  chmod 0750 "/home/$u" || return 1

  # useradd normally allocates these; allocate explicitly when it did not, well
  # clear of its default 100000 base so the two schemes cannot overlap.
  base=$((500000 + idx * 65536))
  grep -q "^$u:" /etc/subuid || printf '%s:%d:65536\n' "$u" "$base" >>/etc/subuid
  grep -q "^$u:" /etc/subgid || printf '%s:%d:65536\n' "$u" "$base" >>/etc/subgid

  # The slot never logs in, so without lingering it has no user systemd manager
  # and no user D-Bus. runc — the thing that actually creates a container — asks
  # systemd for a scope with `Slice=user.slice`; with no user manager to ask it
  # falls through to the SYSTEM manager, which refuses an unprivileged caller
  # with "Interactive authentication required". Image builds keep working
  # (buildkit needs no scope) and starting a container does not, which is how
  # this survived a boot probe that only asked the daemon whether it was up.
  loginctl enable-linger "$u" || return 1

  # Credentials for the slot's own rootless daemon. Written here rather than in
  # install_slot because it belongs to the USER, and a slot user that exists
  # without it pulls anonymously — which fails at "Initialize containers",
  # before any step of the job runs.
  write_slot_docker_config "$idx" || return 1

  # …and the daemon's own config, which must exist before ci-dockerd@$idx starts:
  # `mtu` is read at daemon start, so writing it later leaves the running daemon
  # — and every network it has already created — on the wrong one.
  write_slot_daemon_config "$idx" || return 1
}

# --- per-slot network namespace ----------------------------------------------
#
# THE FAULT (IntegrateIT #7749, four shards failing together on consecutive runs):
#   Error response from daemon: failed to set up container networking: driver
#   failed programming external connectivity ... error while calling RootlessKit
#   PortManager.AddPort(): listen tcp4 0.0.0.0:32768: bind: address already in use
#
# A service container with an unspecified host port (`ports: - 5432`, which is
# what actions/runner emits for every `services:` block) makes the daemon pick a
# host port from /proc/sys/net/ipv4/ip_local_port_range, and RootlessKit then
# binds THAT NUMBER so the job can reach it on localhost. Every slot's daemon
# reads the same range and picks the same first free port — 32768 — so the
# collision is near-deterministic rather than a race that is rarely lost.
#
# It cannot be fixed by giving each slot a slice of the range, which is what
# v4.5.x tried twice and what a host proved wrong both times:
#   * docker's rootlesskit is started with `--detach-netns`, so the DAEMON stays
#     in the HOST network namespace and only containers get the detached one.
#     There is no per-slot netns whose ip_local_port_range could differ.
#   * /proc inside the slot is the host's procfs, propagated (`master:`), so the
#     sysctl a shim reads and writes is the HOST's — the write is refused
#     (EACCES) and a successful one would have repartitioned the whole host.
#   * Bind-mounting a doctored file over /proc/sys/net/ipv4/ip_local_port_range
#     DOES change what the daemon reads, and breaks every container on the host:
#     a partially-covered procfs is no longer "fully visible", so runc's own
#     `mount proc` fails with EPERM ("error mounting \"proc\" to rootfs").
#   * The value is not read once at daemon start either, so staging the host
#     sysctl around each start does nothing. Measured on a live host.
#
# So the slots get a real network namespace each, and the collision stops being
# possible rather than being made unlikely: port 32768 in slot 1's netns and
# port 32768 in slot 2's netns are different sockets. It also fixes the case a
# range partition never could — two slots publishing the same FIXED host port,
# which any workflow with `ports: - 5432:5432` does.
#
# Each namespace is a /30 veth to the host, NAT'd out of the primary interface.
# The job reaches its service containers on localhost, exactly as before, because
# the agent runs in the same namespace as its daemon.
slot_netns()  { printf 'ci-s%s' "$1"; }          # namespace name
slot_veth()   { printf 'cis%s' "$1"; }           # host-side interface (<=15 chars)
slot_gw_ip()  { printf '10.99.%s.1' "$1"; }      # host end of the /30
slot_ns_ip()  { printf '10.99.%s.2' "$1"; }      # slot end of the /30

# The interface the default route leaves by, and its MTU. Both are read rather
# than assumed: interface naming differs between images (ens4/eth0) and a veth
# with the wrong MTU black-holes large TLS records instead of failing cleanly.
primary_if()  { ip -o route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
primary_mtu() { cat "/sys/class/net/$(primary_if)/mtu" 2>/dev/null || echo 1460; }

# Host-side plumbing shared by every slot namespace: forwarding, NAT, and the
# metadata policy for namespaced traffic.
#
# The per-uid OUTPUT fence in fence_metadata() no longer sees a slot's packets —
# they arrive on a veth and are FORWARDED, not originated locally — so the same
# policy is restated here for the 10.99.0.0/16 supernet: DNS to 169.254.169.254
# is allowed (it is also the VPC resolver, and a container's only nameserver),
# everything else to that address is rejected. Fails CLOSED with the fence.
setup_slot_networking() {
  local ifc md_ip="169.254.169.254"
  ifc=$(primary_if)
  [ -n "$ifc" ] || { log "no default route — cannot NAT slot namespaces"; return 1; }

  sysctl -qw net.ipv4.ip_forward=1 || return 1

  iptables -w -t nat -C POSTROUTING -s 10.99.0.0/16 -o "$ifc" -j MASQUERADE 2>/dev/null \
    || iptables -w -t nat -A POSTROUTING -s 10.99.0.0/16 -o "$ifc" -j MASQUERADE \
    || return 1

  # ORDER IS THE POLICY. Every insert goes to position 1, so the LAST insert is
  # the FIRST rule matched: the blanket REJECT is installed first and the two DNS
  # exceptions are pushed in above it. Installing them the other way round leaves
  # the REJECT on top, which takes name resolution away from every slot — the
  # same fault fence_uid() documents, one chain over.
  iptables -w -C FORWARD -s 10.99.0.0/16 -d "$md_ip" -j REJECT 2>/dev/null \
    || iptables -w -I FORWARD 1 -s 10.99.0.0/16 -d "$md_ip" -j REJECT \
    || return 1
  local proto
  for proto in udp tcp; do
    iptables -w -C FORWARD -s 10.99.0.0/16 -d "$md_ip" -p "$proto" --dport 53 -j ACCEPT 2>/dev/null \
      || iptables -w -I FORWARD 1 -s 10.99.0.0/16 -d "$md_ip" -p "$proto" --dport 53 -j ACCEPT \
      || return 1
  done

  # The broker listens on every slot's gateway address (see start_job_broker),
  # which means it also listens on the VM's own address. Nothing outside this
  # host may reach it — it vends tokens.
  iptables -w -C INPUT -i "$ifc" -p tcp --dport "$BROKER_PORT" -j REJECT 2>/dev/null \
    || iptables -w -I INPUT 1 -i "$ifc" -p tcp --dport "$BROKER_PORT" -j REJECT \
    || return 1
}

# Idempotent: a re-run of this script (or a slot restart) must find the
# namespace it already made rather than tear a running slot's networking down.
setup_slot_netns() { # <idx>
  local idx="$1" ns veth gw nsip mtu
  ns=$(slot_netns "$idx"); veth=$(slot_veth "$idx")
  gw=$(slot_gw_ip "$idx"); nsip=$(slot_ns_ip "$idx"); mtu=$(primary_mtu)

  ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns" || ip netns add "$ns" || return 1
  ip link show "$veth" >/dev/null 2>&1 \
    || ip link add "$veth" type veth peer name eth0 netns "$ns" || return 1

  ip addr replace "$gw/30" dev "$veth" || return 1
  ip link set "$veth" up mtu "$mtu" || return 1

  ip netns exec "$ns" ip link set lo up || return 1
  ip netns exec "$ns" ip link set eth0 up mtu "$mtu" || return 1
  ip netns exec "$ns" ip addr replace "$nsip/30" dev eth0 || return 1
  ip netns exec "$ns" ip route replace default via "$gw" || return 1

  # The namespace has no systemd-resolved, so the host's 127.0.0.53 stub is
  # meaningless in it: point it straight at the VPC resolver, which is the
  # address the metadata policy above allows port 53 to. Without this, name
  # resolution fails inside the slot and every checkout does too.
  mkdir -p "/etc/netns/$ns"
  {
    printf 'nameserver 169.254.169.254\n'
    sed -n 's/^search /search /p' /etc/resolv.conf
    printf 'options timeout:2 attempts:3\n'
  } >"/etc/netns/$ns/resolv.conf"

  # APPENDED, never inserted: an insert would land above the metadata REJECT that
  # setup_slot_networking put at the top of this chain and hand every slot the
  # host's identity back.
  iptables -w -C FORWARD -i "$veth" -j ACCEPT 2>/dev/null \
    || iptables -w -A FORWARD -i "$veth" -j ACCEPT || return 1
  iptables -w -C FORWARD -o "$veth" -j ACCEPT 2>/dev/null \
    || iptables -w -A FORWARD -o "$veth" -j ACCEPT || return 1
}

# One rootless dockerd per slot, as a system template unit rather than a user
# unit: a user unit needs a logind session (or lingering) to exist at boot, and
# `RuntimeDirectory=` gives the daemon the XDG_RUNTIME_DIR it wants without one.
install_dockerd_unit() {
  cat >/etc/systemd/system/ci-dockerd@.service <<'EOF'
[Unit]
Description=Rootless Docker daemon for CI slot %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ci-s%i
Group=ci-s%i
# /run/ci-s%i, owned by the slot user and mode 0700: this is where the daemon's
# socket lives, and the mode is what stops a sibling slot from connecting to it.
RuntimeDirectory=ci-s%i
RuntimeDirectoryMode=0700
Environment=HOME=/home/ci-s%i
Environment=XDG_RUNTIME_DIR=/run/ci-s%i
Environment=PATH=/usr/bin:/usr/sbin:/bin:/sbin
# A private /tmp, shared with this slot's runner agent and with nobody else.
# Slots are separate users on one host, and `/tmp` is the one directory they
# all still wrote to: a workflow step that names a fixed path there — and CI
# scripts name fixed paths there constantly — creates it under whichever slot
# ran first, and every later slot gets EACCES on a file it believes it owns.
# The failure reads as a repository bug ("Permission denied" on the repo's own
# scratch file) and moves between repositories with whichever slot got there
# first, so it is worth fixing on the host rather than in every workflow.
PrivateTmp=yes
ExecStart=/usr/bin/dockerd-rootless.sh
# Rootless dockerd needs its own cgroup subtree to set any resource limit;
# without delegation it still runs, but every limit a job asks for is ignored.
Delegate=yes
Restart=always
RestartSec=5
# A job container must not outlive the daemon's stop by holding systemd open.
KillMode=mixed
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
}

# `docker info` answering means the DAEMON is up. It does not mean a job can
# start a container: both faults this function checks left `docker info`
# perfectly healthy and surfaced one layer up, as a failing build step.
#
# Deliberately does not start a container. That needs an image, so it would make
# every host boot depend on a registry — turning a registry hiccup into a fleet
# that refuses to register. These are the two host-side preconditions instead,
# and both are free.
slot_runtime_usable() { # <idx> <user>
  local idx="$1" u="$2" uid
  uid=$(id -u "$u") || return 1

  # The user manager, so runc can create its scope.
  if [ ! -S "/run/user/$uid/bus" ]; then
    log "slot $idx: no user D-Bus at /run/user/$uid/bus — no container could create its cgroup scope"
    return 1
  fi

  # DNS as it will be seen by the job: from INSIDE the slot's namespace, where
  # the host's systemd-resolved stub does not exist and the only nameserver is
  # the VPC resolver the FORWARD policy allows port 53 to. Resolving as root in
  # the host namespace proves nothing about either.
  local ns; ns=$(slot_netns "$idx")
  if ! ip netns exec "$ns" getent ahostsv4 metadata.google.internal >/dev/null 2>&1; then
    log "slot $idx: cannot resolve inside $ns — the metadata policy is blocking port 53, or /etc/netns/$ns/resolv.conf is wrong"
    return 1
  fi

  # …and again the way the UNITS see it. `ip netns exec` bind-mounts
  # /etc/netns/$ns/resolv.conf over /etc/resolv.conf; systemd does not, so the
  # probe above passes on a host where every service is resolving against a
  # 127.0.0.53 stub that is unreachable in this namespace. nsenter joins the
  # namespace WITHOUT that convenience, which is exactly the units' view.
  if ! nsenter --net="/run/netns/$ns" getent ahostsv4 metadata.google.internal >/dev/null 2>&1; then
    log "slot $idx: services in $ns cannot resolve — the resolv.conf bind is missing from the unit drop-ins"
    return 1
  fi

  # The fence itself, proved from where job code runs rather than asserted: the
  # token endpoint must NOT answer in the slot's namespace. A slot that can read
  # it owns the fleet (#1958), so this is fatal, not a warning.
  if ip netns exec "$ns" curl -fsS --connect-timeout 5 -m 5 -H "Metadata-Flavor: Google" \
    "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token" >/dev/null 2>&1; then
    log "slot $idx: the REAL metadata server answers inside $ns — refusing to serve jobs"
    return 1
  fi

  # …and the broker, which is the credential job code is supposed to get, must
  # answer on this slot's gateway address. Loopback is the namespace's OWN
  # loopback now, so 127.0.0.1 would reach nothing.
  if [ -n "$JOB_SA" ] && ! ip netns exec "$ns" curl -fsS --connect-timeout 5 -m 5 -H "Metadata-Flavor: Google" \
    "http://$(slot_gw_ip "$idx"):$BROKER_PORT/computeMetadata/v1/instance/service-accounts/default/token" >/dev/null 2>&1; then
    log "slot $idx: the job credential broker is unreachable from $ns at $(slot_gw_ip "$idx"):$BROKER_PORT"
    return 1
  fi
}

start_slot_dockerd() {
  local idx="$1" u i uid
  u=$(slot_user "$idx")
  uid=$(id -u "$u") || return 1

  # Written per slot with the RESOLVED uid rather than with the %U specifier:
  # the value is a path that has to exist, and a wrong-but-plausible one here
  # fails the way the fault above failed — at a job's first container, not at
  # boot. `dockerd-rootless.sh` passes this through to runc.
  mkdir -p "/etc/systemd/system/ci-dockerd@$idx.service.d"
  cat >"/etc/systemd/system/ci-dockerd@$idx.service.d/10-user-bus.conf" <<EOF
[Service]
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus
EOF

  # The slot's own network namespace, created before the daemon that joins it.
  # This is what makes two slots' published ports independent; see
  # setup_slot_netns for why a shared netns could not be partitioned instead.
  setup_slot_netns "$idx" || { log "slot $idx: could not create network namespace"; return 1; }
  # BindReadOnlyPaths is NOT optional decoration. `/etc/netns/<ns>/resolv.conf`
  # is an `ip netns exec` convention — that tool bind-mounts it over
  # /etc/resolv.conf itself. systemd's NetworkNamespacePath= only joins the
  # namespace, so without this line the unit keeps reading the HOST's
  # /etc/resolv.conf, which names the systemd-resolved stub at 127.0.0.53 —
  # a loopback address that means nothing inside another namespace. Shipped
  # that way in v5.0.0: every slot registered and then sat in
  # "Runner connect error: Resource temporarily unavailable" (a DNS TRY_AGAIN
  # dressed as a socket error), while an `ip netns exec … curl` from the same
  # host resolved fine and made the fault look like anything but DNS.
  cat >"/etc/systemd/system/ci-dockerd@$idx.service.d/20-netns.conf" <<EOF
[Service]
NetworkNamespacePath=/run/netns/$(slot_netns "$idx")
BindReadOnlyPaths=/etc/netns/$(slot_netns "$idx")/resolv.conf:/etc/resolv.conf
EOF
  systemctl daemon-reload

  systemctl enable --now "ci-dockerd@$idx.service" >>/var/log/ci-host.log 2>&1 || return 1

  # Prove the daemon answers before the agent registers. A slot whose daemon is
  # down still takes jobs and fails each one at the first `docker` line, which
  # reads as a flaky repository rather than a broken host.
  for i in $(seq 1 30); do
    if sudo -u "$u" DOCKER_HOST="unix:///run/$u/docker.sock" docker info >/dev/null 2>&1; then
      slot_runtime_usable "$idx" "$u" || return 1
      # Read back where the daemon ACTUALLY landed rather than trusting the
      # drop-in. A daemon that silently stayed in the host namespace looks
      # perfectly healthy here and fails later, at some job's service container,
      # as "address already in use" — the exact fault this namespace removes.
      local dpid dns hostns
      dpid=$(pgrep -u "$u" -x dockerd | head -1)
      dns=$(readlink "/proc/$dpid/ns/net" 2>/dev/null)
      hostns=$(readlink /proc/1/ns/net 2>/dev/null)
      if [ -n "$dns" ] && [ "$dns" != "$hostns" ]; then
        log "slot $idx: daemon in network namespace $(slot_netns "$idx") ($dns)"
      else
        log "slot $idx: daemon is in the HOST network namespace — published ports will collide with a sibling slot"
        return 1
      fi
      log "slot $idx: rootless docker ready for $u"
      return 0
    fi
    sleep 2
  done
  log "slot $idx: rootless docker did not come up"
  return 1
}

# Load any container image archives the IMAGE baked into the shared cache into
# this slot's rootless daemon.
#
# This exists because a pre-pulled image is per-DAEMON, and every slot runs its
# own rootless daemon with its own data root under the slot user's home. An
# image pulled at bake time lands in the build VM's root-owned /var/lib/docker
# and is invisible to all K of them — so the only way to bake a container image
# is to bake a FILE (docker save) and load it per slot, which is what this does.
#
# Deliberately generic: the host has no idea what is in the archives, and no
# tool is named here. A pool that wants an image warm supplies a warm-cache
# script that writes /opt/ci-cache/images/*.tar[.gz]; a pool that does not gets
# an empty directory and pays nothing.
#
# Backgrounded and never fatal, for two reasons. A multi-gigabyte load takes
# minutes, and blocking on it would keep the whole pool from registering while
# a job queue builds. And a corrupt or half-written archive must degrade to "the
# job pulls the image itself", which is merely slow — the alternative is a host
# that refuses to register over a CACHE, which is the same class of fault as
# making boot depend on a registry (see slot_runtime_usable).
load_baked_images() {
  local idx="$1" u; u=$(slot_user "$idx")
  local dir="/opt/ci-cache/images"

  [ -d "$dir" ] || return 0
  # Nothing to do is the common case — most pools bake no images at all.
  local archives; archives=$(find "$dir" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' \) 2>/dev/null)
  [ -n "$archives" ] || return 0

  (
    local a base
    printf '%s\n' "$archives" | while IFS= read -r a; do
      [ -n "$a" ] || continue
      base=$(basename "$a")

      # Verify against the digest recorded at bake time, when the archive was
      # last known-good. This is defence in depth, not the primary control —
      # `images/` is root-owned and read-only to slots — but it is the half
      # that still holds if that ownership is ever widened by a later change,
      # and it turns a truncated archive into a clean skip.
      #
      # A missing SHA256SUMS is not a failure: an image baked before this
      # existed simply has nothing to check against.
      if [ -f "$dir/SHA256SUMS" ] && grep -qF " $base" "$dir/SHA256SUMS"; then
        if ! ( cd "$dir" && grep -F " $base" SHA256SUMS | sha256sum -c --status - ); then
          log "slot $idx: $base failed its checksum — NOT loading it; jobs will pull that image themselves"
          continue
        fi
      fi

      # `docker load` reads gzip transparently, so a warm script may save either
      # form; gzip trades boot CPU for image size and is the better default.
      #
      # `timeout` so a wedged load cannot hold this script open indefinitely —
      # main() waits for these before exiting, and an unbounded wait would keep
      # google-startup-scripts.service active forever.
      #
      # shellcheck disable=SC2024  # the redirect is the shell's, and this shell
      # is root: a GCE startup script runs as root, which is also why every
      # other write to this log in this file is spelled the same way. `sudo`
      # here drops privilege for the daemon socket, it does not raise it.
      if timeout 1800 sudo -u "$u" DOCKER_HOST="unix:///run/$u/docker.sock" \
           docker load -i "$a" >>/var/log/ci-host.log 2>&1; then
        log "slot $idx: loaded baked image archive $base"
      else
        log "slot $idx: could not load $base — jobs will pull that image themselves"
      fi
    done
  ) &
  # Remembered so main() can wait for it. A GCE startup script runs under
  # google-startup-scripts.service, a Type=oneshot unit, and systemd's default
  # KillMode=control-group SIGKILLs whatever is still in the cgroup once the
  # main process exits. Without this wait a multi-gigabyte load is killed
  # mid-stream, silently — no success line, no error, and a warm-cache feature
  # that does nothing while looking correct in review.
  IMAGE_LOAD_PIDS="${IMAGE_LOAD_PIDS:-} $!"
}

# Waited at the very END of the run, never at the call site: by then every slot
# has already registered, so the cost is that this script stays alive a few more
# minutes, not that the pool is late to take jobs.
wait_for_image_loads() {
  [ -n "${IMAGE_LOAD_PIDS:-}" ] || return 0
  log "waiting for baked image loads to finish before exiting"
  # shellcheck disable=SC2086  # deliberate word splitting: a PID list.
  wait ${IMAGE_LOAD_PIDS} 2>/dev/null || true
  log "baked image loads finished"
}

install_slot() {
  local idx="$1" token="$2"
  local dir="$SLOT_ROOT/$idx"
  local name="$HOSTNAME_SHORT-s$idx"
  local u; u=$(slot_user "$idx")

  start_slot_dockerd "$idx" || return 1

  # After the daemon is proven up, before the agent registers. Backgrounded, so
  # the slot takes jobs while the cache warms behind it.
  load_baked_images "$idx"

  # google-auth, gcloud and the Go/Java clients all resolve the metadata server
  # through these. Per SLOT, not per host: the address that reaches the broker
  # from inside a namespace is that namespace's gateway, and 127.0.0.1 is now
  # the slot's own loopback, where nothing listens.
  local BROKER_ENV=""
  if [ -n "$JOB_SA" ]; then
    BROKER_ENV=$(printf 'Environment=GCE_METADATA_HOST=%s:%s\nEnvironment=GCE_METADATA_IP=%s:%s\nEnvironment=GCE_METADATA_ROOT=%s:%s' \
      "$(slot_gw_ip "$idx")" "$BROKER_PORT" "$(slot_gw_ip "$idx")" "$BROKER_PORT" "$(slot_gw_ip "$idx")" "$BROKER_PORT")
  fi

  mkdir -p "$dir"
  # Copy, not symlink: config.sh writes .runner/.credentials into the directory
  # it runs in, and K agents must not share one identity.
  cp -a "$RUNNER_HOME/." "$dir/"
  chown -R "$u:$u" "$dir"
  chmod 0750 "$dir"

  local group_arg=()
  [ -n "$RUNNER_GROUP" ] && group_arg=(--runnergroup "$RUNNER_GROUP")

  # SC2024: the redirect is opened by THIS shell, which is root (startup-script
  # runs as root); sudo only drops privilege for config.sh itself. Writing the
  # log as root is intended — a job must not be able to rewrite the boot log.
  # shellcheck disable=SC2024
  # --disableupdate: GitHub otherwise forces an actions/runner self-update, which
  # leaves run.sh alive while the agent is OFFLINE and undispatchable. On the
  # pool this replaces that stalled CI for 90 minutes with VMs RUNNING and zero
  # usable runners (DataRetrival #2281). It matters MORE here, not less: a warm
  # host lives for hours, so a self-update takes K slots down at once instead of
  # one short-lived VM. The image pins the agent version; upgrades ship by
  # rebuilding the image, which is reviewable.
  sudo -u "$u" "$dir/config.sh" \
    --unattended --replace --disableupdate \
    --url "https://github.com/$OWNER/$REPO" \
    --token "$token" \
    --name "$name" \
    --labels "$LABELS" \
    --work "$dir/_work" \
    "${group_arg[@]}" >>/var/log/ci-host.log 2>&1 || {
      log "slot $idx: config.sh failed"
      return 1
    }

  cat >"/etc/systemd/system/ci-runner@$idx.service" <<EOF
[Unit]
Description=GitHub Actions runner slot $idx ($POOL)
After=network-online.target ci-dockerd@$idx.service
Wants=network-online.target
# The agent is useless without its daemon, and must go down with it rather than
# accept jobs that will fail at their first container step. BindsTo, not just
# Requires: Requires only propagates an explicit stop, so a daemon that CRASHES
# and exhausts its restarts would leave the agent online and still taking jobs.
BindsTo=ci-dockerd@$idx.service
Requires=ci-dockerd@$idx.service
# Share the daemon's private /tmp rather than getting a second, separate one.
JoinsNamespaceOf=ci-dockerd@$idx.service

[Service]
Type=simple
User=$u
WorkingDirectory=$dir
# This slot's OWN daemon. It is the only one it can reach: the sockets of the
# other slots sit in 0700 directories owned by their own users, and the rootful
# daemon is masked on this host.
Environment=DOCKER_HOST=unix:///run/$u/docker.sock
# The slot's private /tmp, and specifically the SAME one the daemon sees. A
# PrivateTmp=yes of its own would isolate the agent from its siblings but
# also from its own daemon, so "docker run -v /tmp/x:/x" would mount an empty
# directory instead of the file the step just wrote — a silent wrong answer,
# which is worse than the collision being fixed here. JoinsNamespaceOf makes
# the two share one namespace (declared in [Unit] above); the BindsTo there is
# what keeps them in step, since a daemon that restarts gets a new namespace
# and takes the agent down with it rather than leaving it on a stale one.
PrivateTmp=yes
# The SAME network namespace as its daemon, which is what keeps "service on
# localhost:PORT" true for the job: actions/runner publishes service containers
# on the daemon's host ports, and those are this namespace's ports now.
NetworkNamespacePath=/run/netns/$(slot_netns "$idx")
# Joining the namespace does not carry its resolver — see the daemon drop-in.
BindReadOnlyPaths=/etc/netns/$(slot_netns "$idx")/resolv.conf:/etc/resolv.conf
$BROKER_ENV
# Wipe this slot's leftover cloud credential store before every job and after
# every job. Set unconditionally, and NOT alongside BROKER_ENV: a pool with no
# job service account is where an inherited credential is most dangerous, since
# nothing there is supposed to have Google credentials at all. A failing hook
# fails the job, which is the intended trade — a job that could not be given a
# clean credential state must not run with a previous job's identity.
Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ci/job-hooks/reset-credentials.sh
Environment=ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/ci/job-hooks/reset-credentials.sh
ExecStart=$dir/run.sh
# The controller drains a host by DEREGISTERING its agents through the GitHub
# API, which GitHub refuses while an agent is executing a job. Restart=no here
# means a stopped agent stays stopped and the host really does go quiet.
Restart=no
KillSignal=SIGTERM
# Long enough for a job to finish once it has been asked to stop. A CI job that
# exceeds this was going to be killed by GitHub's own timeout anyway.
TimeoutStopSec=3600

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable --now "ci-runner@$idx.service" >>/var/log/ci-host.log 2>&1
  log "slot $idx registered as $name"
}

main() {
  mkdir -p "$SLOT_ROOT"
  id runner >/dev/null 2>&1 || die "golden image is missing the 'runner' user"
  [ -x /usr/bin/dockerd-rootless.sh ] || die "golden image has no rootless docker (dockerd-rootless.sh) — a host without it can only give every slot the same daemon, which is the exposure #10 removed"

  # The shared rootful daemon is the thing being removed: while its socket
  # exists, any slot that can reach it is back to full control of every other
  # slot's containers. Masked, not stopped — a package or a job must not be able
  # to start it again by touching the socket unit.
  # Fails CLOSED. A host that could not mask the rootful daemon must not
  # register: with /var/run/docker.sock reachable, every slot is back to full
  # control of every other slot's containers (#10), which is the whole exposure
  # this model removes. A masked-but-already-dead unit still exits 0, so this is
  # not a race with the image's own state.
  systemctl mask --now docker.service docker.socket >>/var/log/ci-host.log 2>&1 \
    || die "could not mask the rootful Docker daemon — refusing to register agents"
  # Belt and braces — but on REACHABILITY, not on the file. A masked unit can
  # leave the socket inode behind, and a host that refuses to boot over a dead
  # file would be a self-inflicted fleet outage. What must be true is that
  # nothing answers on it.
  if [ -S /var/run/docker.sock ] && docker -H unix:///var/run/docker.sock info >/dev/null 2>&1; then
    die "the rootful Docker daemon still answers on /var/run/docker.sock after masking — refusing to register agents"
  fi

  # Before the slot users, because provisioning one writes the config.json that
  # names this helper.
  install_registry_credential_helper \
    || die 'could not install the registry credential helper — every job running in a container from a private registry would fail its pull'

  local i
  for i in $(seq 1 "$SLOTS"); do
    provision_slot_user "$i" || die "could not provision the user for slot $i"
  done
  install_dockerd_unit
  # The template must be on disk AND known to systemd before the first
  # `systemctl enable --now ci-dockerd@1`, or that call fails on a unit systemd
  # has not read yet.
  systemctl daemon-reload

  # Before any agent exists, so no job can ever race the fence.
  fence_metadata || die "could not fence job code off the metadata server — refusing to register agents"
  # The same fence for namespaced traffic, plus the NAT that gives a slot egress
  # at all. Also fails CLOSED: without it a slot either has no network or has an
  # unfenced route to the metadata server.
  setup_slot_networking || die "could not set up slot networking — refusing to register agents"

  # Also before any agent exists: an agent registered without the broker would
  # pick up a deploy job that then fails on missing credentials.
  if [ -n "$JOB_SA" ]; then
    start_job_broker || die "job service account $JOB_SA is configured but its credential broker did not come up"
  else
    log "no ci-job-service-account set — jobs on this host get no Google credentials"
  fi

  # Before the units that reference it exist, and fails CLOSED: an agent whose
  # ACTIONS_RUNNER_HOOK_JOB_STARTED points at a missing file refuses to run any
  # job, so a host that registered without the hook installed would take work and
  # fail all of it.
  install_job_hooks || die "could not install the per-job credential reset hook — refusing to register agents"

  local token
  token=$(registration_token) || die "could not obtain a registration token"
  [ -n "$token" ] || die "registration token was empty"

  local failures=0
  for i in $(seq 1 "$SLOTS"); do
    install_slot "$i" "$token" || failures=$((failures + 1))
  done

  systemctl daemon-reload

  if [ "$failures" -ge "$SLOTS" ]; then
    # Zero registered agents = a host GitHub will never send work to. It cannot
    # fix itself, so it announces the fact and lets the controller drain it
    # (drain rule 5, reg=absent) instead of idling at full price forever.
    log "no slot registered — host is useless and will be drained by the controller"
    exit 1
  fi

  log "host ready: $((SLOTS - failures))/$SLOTS slots serving $OWNER/$REPO (pool=$POOL)"

  # AFTER the host is announced ready, so a slow image load delays nothing that
  # matters: the agents are registered and already taking work by this point.
  wait_for_image_loads
}

main "$@"
