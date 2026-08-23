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

# A slot's HOME is disposable. It is emptied and rebuilt from $SLOT_TEMPLATE
# before every job, after every job and at every agent start, so nothing a job
# leaves there is ever seen by the next one (#110). These two directories are
# what makes that possible.
#
# The template is the ONLY description of what a slot starts with: root-owned,
# never writable by a slot, and used both when a slot is first provisioned and
# on every reset, so "fresh" and "reset" cannot drift apart.
SLOT_TEMPLATE="/opt/ci/slot-template"
# Per-slot state that must SURVIVE the home being replaced: the rootless
# daemon's data root, which is moved out of the home for exactly that reason
# (see install_dockerd_unit), and the marker recording that the slot was left
# clean. Root-owned all the way down except the daemon's own subdirectory, so a
# slot cannot forge its own clean bill of health.
SLOT_STATE="/var/lib/ci-slot"

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

# For any text that came OUT of a scanned tree rather than out of this script.
#
# The cache scan refuses a tree and names the entry that tripped it, which is the
# right thing to do — a refusal that names the tree root and not the cause once
# cost a pool hours of running cold. But that entry's name is chosen by whoever
# wrote the cache, and a filename may contain a newline. Interpolated raw, one
# refusal becomes two log lines and the second can be shaped to look like any
# other line this script emits, including a success verdict.
#
# It cannot change a verdict — the refusal has already happened by the time the
# path is interpolated, and this text never reaches a shell. What it corrupts is
# the log an operator reads when deciding whether a pool went cold for a benign
# reason, which is the one moment that log has to be trustworthy. Length is
# bounded for the same reason: `-quit` yields one entry, but one entry's path can
# be as long as the tree is deep.
safe_for_log() {
  printf '%.300s' "$(printf '%s' "$1" | tr '\n\t' '  ' | tr -d '\000-\037')"
}

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
# The Turborepo remote cache this host SERVES to its slots. Empty bucket = the
# layer is off and every slot runs exactly as it did before these keys existed,
# which is what lets a host booted from an older template stay correct.
TURBO_BUCKET=$(md "instance/attributes/ci-turbo-bucket")
TURBO_PREFIX=$(md "instance/attributes/ci-turbo-prefix")
TURBO_PORT=$(md "instance/attributes/ci-turbo-port")
TURBO_DISK_BUDGET=$(md "instance/attributes/ci-turbo-disk-budget-bytes")
TURBO_MAX_ARTIFACT=$(md "instance/attributes/ci-turbo-max-artifact-bytes")
HOSTNAME_SHORT=$(md "instance/name")
# Registry hosts the job identity authenticates to. Comma-separated, set by the
# module; see write_docker_cred_helpers for why the list is explicit.
REGISTRY_HOSTS=$(md "instance/attributes/ci-registry-hosts")
# The regional Artifact Registry of the host's OWN region is always included:
# the overwhelmingly common case is a repository pulling a builder image it
# publishes alongside its runners, and requiring every estate to spell that out
# would make the failure it prevents the default.
INSTANCE_ZONE=$(md "instance/zone")        # projects/<n>/zones/<region>-<x>
INSTANCE_ZONE=${INSTANCE_ZONE##*/}
HOST_REGION=${INSTANCE_ZONE%-*}

# What the telemetry publisher concatenated above this file expects, under the
# names it expects. Spelled out here rather than passed in metadata where the
# host already knows the value: a second copy of the project id is a second
# thing that can disagree with the machine it is running on.
PROJECT=$(md "project/project-id")
# shellcheck disable=SC2034  # read by telemetry.sh, concatenated ABOVE this file
REGION=$HOST_REGION
# Empty when either half is, rather than the "/" that concatenating two empty
# reads would produce: the emitter below skips on an empty REPO_FULL, and "/" is
# not empty — it is a resource label that publishes and cannot be grouped by.
REPO_FULL=""
if [ -n "${OWNER:-}" ] && [ -n "${REPO:-}" ]; then REPO_FULL="$OWNER/$REPO"; fi
METRIC_PREFIX=$(md "instance/attributes/ci-metric-prefix")
# Tighter than the publisher's default 30. The controller's flush happens inside
# a tick nobody waits on; this one happens on the boot path, in front of the
# agent registering, and AFTER the hydrate's own budget has been accounted for —
# so its worst case is added to that budget rather than covered by it. Two calls
# at 10s is a bound worth stating out loud, not a boot silently doubled.
# shellcheck disable=SC2034  # read by telemetry.sh, concatenated ABOVE this file
TS_MAX_TIME=10

BROKER_PORT=${BROKER_PORT:-8081}

TURBO_PORT=${TURBO_PORT:-8082}
# Set by start_turbo_cache when the layer comes up, and read by install_slot to
# decide whether a slot is told about the cache at all. Declared here so the two
# are not ordered by accident: a slot must never be handed TURBO_API for a
# server that failed to start, because turbo would then spend a request per task
# on a connection refused instead of building.
TURBO_TOKEN=""
TURBO_DISK_BUDGET=${TURBO_DISK_BUDGET:-8589934592}
TURBO_MAX_ARTIFACT=${TURBO_MAX_ARTIFACT:-536870912}

SLOTS=${SLOTS:-1}

if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  die "missing ci-github-owner/ci-github-repo metadata"
fi

# --- host affinity label ------------------------------------------------------
#
# Every agent on this host also answers to `host-<instance-name>`, which is what
# lets a workflow run keep all of its jobs on the host its first job landed on
# (docs/adr-pr-host-affinity.md). GitHub sends a job to any runner whose label
# set is a SUPERSET of `runs-on`, so an extra label costs nothing to a workflow
# that does not name it, and is the only thing that will serve one that does.
#
# Appended here rather than set in metadata, because the module cannot know an
# instance name a MIG assigns at creation time.
#
# Fails closed. A host that could not read its own name would register agents
# indistinguishable from every other host's, and a pinned job would then queue
# against a label nothing answers until GitHub cancels it a day later. Every
# other value on this path comes from the same metadata server, so this is not a
# new dependency — only a new reason to insist it answered.
[ -n "${HOSTNAME_SHORT:-}" ] || die "could not read instance/name from metadata — without it this host cannot publish its affinity label, and a pinned job would queue against a label nothing answers"
HOST_LABEL="host-$HOSTNAME_SHORT"
LABELS="${LABELS:+$LABELS,}$HOST_LABEL"
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

  # THE JWT IS NOT AN ARGUMENT, and that is the same security property cache_fetch
  # spells out below: /proc/<pid>/cmdline is world-readable, the slot units are not
  # ordered against google-startup-scripts.service, and on a reboot of a WARM host
  # this runs while already-registered agents are executing job code. This token is
  # worth more than the instance token that motivated the pattern — it mints
  # installation tokens for the whole installation.
  #
  # `printf` is a shell builtin, so nothing execs with the JWT in ITS argv either,
  # and the config file is a process substitution: the fd belongs to root, it has
  # no name a slot user could open, and it is gone when curl exits.
  curl "${CURL_TIMEOUTS[@]}" -fsS -X POST \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$jwt") \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$INSTALL_ID/access_tokens" \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

registration_token() {
  local tok
  tok=$(gh_token) || return 1
  [ -n "$tok" ] || return 1
  # Out of argv for the same reason as the JWT above, and for one more: this token
  # joins an arbitrary machine to the pool, so a job that read it off /proc could
  # register a runner it controls and be handed other repositories' jobs.
  curl "${CURL_TIMEOUTS[@]}" -fsS -X POST \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$tok") \
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

# --- the Turborepo remote cache this host serves ------------------------------
#
# The repository configures nothing. A monorepo's build cache is the largest
# remaining win on this fleet (docs/ci-optimization-catalog.md, 4.4), and the one
# repository that built one by hand ran it COLD for weeks without noticing,
# because a hand-wired cache fails as a warning per artifact in a green run. So
# the host serves it and points every slot at it, the same way it serves job
# credentials: one thing to get right, in one place, reviewed with the module.
#
# READ-ONLY, and that is not a stage on the way to something else — see the
# header of turbo-cache-server.py. A host runs pull-request code; a cache that
# job code could write is one pull request handing the next build a tarball that
# is unpacked into its output tree and treated as its own result.
#
# Fails OPEN. Every failure here costs cache hits and nothing else, and a host
# that refused to register over a cache would turn a speed layer into an
# outage — the exact trade the snapshot layer already declines.
start_turbo_cache() {
  local src
  src=$(md "instance/attributes/ci-turbo-cache-py")
  [ -n "$src" ] || { log "turbo cache: server source missing from metadata"; return 1; }

  printf '%s' "$src" >/opt/ci/turbo-cache-server.py
  chmod 0755 /opt/ci/turbo-cache-server.py

  # A per-BOOT token, generated here and never persisted. It is not the security
  # boundary — the port is REJECTed on the primary interface and every slot on
  # this host may read the same artifacts anyway (see _authorized in the
  # server) — so its whole job is to make a workflow that points TURBO_API
  # somewhere else, or brings a token of its own, fail loudly instead of reading
  # this cache under a team name that means nothing here.
  # Held in a local until the server has ANSWERED, and only then published as
  # TURBO_TOKEN: install_slot reads that variable as "the cache is up", so
  # setting it here would point every slot at a server this function is about to
  # give up on.
  local tok
  tok=$(openssl rand -hex 16 2>/dev/null) || tok=""
  [ -n "$tok" ] || { log "turbo cache: could not generate a token"; return 1; }

  cat >/etc/systemd/system/ci-turbo-cache.service <<EOF
[Unit]
Description=Turborepo remote cache, read-only ($POOL)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Root, for the same reason the job broker is: this is the only thing on the
# host that may hold the host identity's token, which is what reads the store.
# Job code cannot reach that token — the slot namespaces REJECT the metadata
# server and /proc of a root process is invisible under hidepid=2.
User=root
Environment=CI_TURBO_BUCKET=$TURBO_BUCKET
Environment=CI_TURBO_PREFIX=$TURBO_PREFIX
Environment=CI_TURBO_TOKEN=$tok
Environment=CI_TURBO_DISK_BUDGET_BYTES=$TURBO_DISK_BUDGET
Environment=CI_TURBO_MAX_ARTIFACT_BYTES=$TURBO_MAX_ARTIFACT
# Every slot has its own network namespace and therefore its own loopback, so a
# server bound to 127.0.0.1 in the host namespace is reachable from none of
# them. It binds every address — including each slot's gateway — and
# setup_slot_networking REJECTs this port on the primary interface, exactly as
# it does for the broker.
Environment=CI_TURBO_HOST=0.0.0.0
Environment=CI_TURBO_PORT=$TURBO_PORT
ExecStart=/usr/bin/python3 /opt/ci/turbo-cache-server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ci-turbo-cache.service >>/var/log/ci-host.log 2>&1 || return 1

  # Prove it answers before a slot is told to trust it. `status` is the call
  # turbo makes first and the one that decides whether the client uses the cache
  # at all, so a server that listens but cannot answer it is a server that turns
  # itself off in every build while looking up here.
  local i
  for i in $(seq 1 15); do
    if curl "${CURL_TIMEOUTS[@]}" -fsS \
      "http://127.0.0.1:$TURBO_PORT/v8/artifacts/status" >/dev/null 2>&1; then
      TURBO_TOKEN="$tok"
      log "turbo remote cache serving gs://$TURBO_BUCKET/$TURBO_PREFIX on 127.0.0.1:$TURBO_PORT"
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
#
# --- and why it is now the whole slot, not two credential stores (#110) -------
#
# The first version of this removed ~/.config/gcloud and ~/.gsutil. That is a
# DENYLIST: it removes what it was told about and leaves everything else, and
# what it left is EXECUTED by the next job on the same slot — ~/.gitconfig's
# `core.hooksPath` fires on the next actions/checkout, ~/.bashrc and ~/.profile
# fire on the next `run:` step, ~/.local/bin shadows a real binary, and
# `.git/hooks/*` in a leftover workspace survives a `git clean -ffdx`. Naming those
# four would only make the denylist longer; the fifth is whatever nobody has
# thought of yet.
#
# So the home is REPLACED, not cleaned: every entry is deleted and $SLOT_TEMPLATE
# is copied back. What a job starts with becomes a property of a tree this
# script writes and no slot can reach, instead of a property of the list of
# paths someone remembered. The same argument retires _work's leftovers — the
# previous workspace and `_tool`, which is on PATH.
#
# That is only affordable because nothing a slot must KEEP lives in the home any
# more. The dependency caches are under $CACHE_SLOTS, the daemon's socket is in
# $XDG_RUNTIME_DIR, and the daemon's data root was moved to $SLOT_STATE/<idx>
# for precisely this reason (see install_dockerd_unit) — so a reset costs a copy
# of a few dotfiles, not a re-pull of every image the host has warmed.
install_job_hooks() {
  mkdir -p /opt/ci/job-hooks || return 1
  chown root:root /opt/ci/job-hooks || return 1
  # Root-owned and not slot-writable: these files are executed by every slot on
  # the host, so a slot that could rewrite one would be running code in every
  # OTHER slot's uid — and one of them now runs as root.
  chmod 0755 /opt/ci/job-hooks || return 1

  # Two shims, because the runner tells a hook nothing about which stage it is
  # in: ACTIONS_RUNNER_HOOK_JOB_STARTED and ..._COMPLETED are two variables
  # naming two paths, and neither script is passed an argument saying which one
  # it is. Two one-line files is the whole of the difference.
  local stage renew
  for stage in started completed; do
    renew=': the hold is renewed on job-started only, never here'
    if [ "$stage" = started ]; then
      # shellcheck disable=SC2016  # ${GITHUB_RUN_ID} must survive into the hook
      # file verbatim. Expansion is not recursive, so $renew going into the
      # unquoted heredoc below inserts this text without re-expanding it, and
      # the hook then reads the runner's own environment at job time. Expanding
      # it here would bake in the empty value this boot has.
      renew='sudo -n /opt/ci/job-hooks/pin-hold.sh renew --run "${GITHUB_RUN_ID:-}" >/dev/null 2>&1 || true'
    fi
    cat >"/opt/ci/job-hooks/job-$stage.sh" <<EOF
#!/usr/bin/env bash
# Installed by host-startup.sh. Runs as the slot user. See install_job_hooks().
set -uo pipefail
# -n: never prompt. There is no tty and nobody to answer it, so a sudoers file
# that stopped granting this must fail the job at once rather than hang it until
# the job's own timeout.
# The hold is renewed by the HOST, not by the workflow, and this is the only
# place that can do it: a consumer running inside a \`container:\` cannot reach
# /usr/local/bin/ci-pin-hold at all, and those are precisely the jobs whose runs
# last long enough for a TTL to matter. Never fatal — a hold that fails to
# extend expires, and the sweeper puts the slot back; failing a job over the
# fleet's own bookkeeping would be the worse outcome by far.
#
# STARTED only, and named. On \`completed\` a renewal extends the hold past the
# end of the last job of the run, for a full TTL, over a host nothing is using.
# \`--run\` is what keeps a job of some OTHER run from renewing this one's hold;
# the helper refuses when the ids differ.
$renew
exec sudo -n /opt/ci/job-hooks/slot-reset.sh $stage
EOF
    chown root:root "/opt/ci/job-hooks/job-$stage.sh" || return 1
    chmod 0755 "/opt/ci/job-hooks/job-$stage.sh" || return 1
  done

  # The reset itself, and it runs as ROOT. Not a preference: a job's containers
  # write into the slot's tree through a user namespace, so the files they leave
  # behind are owned by SUBORDINATE uids and the directories among them are not
  # writable by the slot user. `rm -rf` run as the slot user returns EACCES on
  # exactly the leftovers that matter most — and, under `set -uo pipefail` with
  # no `-e`, would have reported a partial wipe as a completed one.
  cat >/opt/ci/job-hooks/slot-reset.sh <<EOF
#!/usr/bin/env bash
# Installed by host-startup.sh. Runs as root. See install_job_hooks() for why.
set -uo pipefail

SLOT_ROOT="$SLOT_ROOT"
SLOT_STATE="$SLOT_STATE"
SLOT_TEMPLATE="$SLOT_TEMPLATE"
SLOT_USER_PREFIX="$SLOT_USER_PREFIX"
PIN_DIR="$PIN_DIR"

say() { logger -t ci-slot-reset -- "\$*" 2>/dev/null || true; echo "slot reset: \$*" >&2; }

stage="\${1:-}"
idx=""

# WHICH slot is being reset is decided here, and never by the caller when the
# caller is a slot. sudo sets SUDO_UID itself from the real invoking user and
# env_reset drops the caller's own copy, so a slot cannot name a DIFFERENT
# slot's index — it does not get to name one at all. The sudoers rule matches
# the two permitted argument forms literally, for the same reason.
if [ -n "\${SUDO_UID:-}" ]; then
  u=\$(getent passwd "\$SUDO_UID" | cut -d: -f1)
  case "\$u" in
    "\$SLOT_USER_PREFIX"[0-9]*) idx=\${u#"\$SLOT_USER_PREFIX"} ;;
    *) say "refusing: uid \$SUDO_UID (\$u) is not a slot user"; exit 1 ;;
  esac
else
  # No sudo in the picture: this is systemd's ExecStartPre, which has to supply
  # the index because there is no invoking user to read it from.
  idx="\${2:-}"
fi

case "\$stage:\$idx" in
  started:[0-9]*|completed:[0-9]*|boot:[0-9]*) ;;
  *) say "refusing: bad stage or index '\$stage'/'\$idx'"; exit 1 ;;
esac

u="\$SLOT_USER_PREFIX\$idx"
# The passwd entry, and then a shape check on what it returned. This deletes a
# directory tree as root, so the single input that decides WHICH tree comes from
# the account database rather than from a variable, and still has to look like a
# slot home when it gets here.
home=\$(getent passwd "\$u" | cut -d: -f6)
case "\$home" in
  /home/"\$SLOT_USER_PREFIX"[0-9]*) ;;
  *) say "refusing: home of \$u is '\$home', not a slot home"; exit 1 ;;
esac
[ -d "\$SLOT_TEMPLATE" ] || { say "refusing: \$SLOT_TEMPLATE is missing"; exit 1; }

marker="\$SLOT_STATE/\$idx/clean"

# THE BURN COUNT. Beside the marker, in the same root-owned directory and for
# the same reason: it is a claim about a slot that the slot must not be able to
# make about itself.
#
# What it counts is consecutive failures to reach a clean state — a job failed
# on arrival because the slot was not left clean, or a reset that could not earn
# the marker. Any reset that DOES earn the marker clears it, so the number is
# always "how many in a row, right now", never a lifetime total. That is the
# only shape the take-out-of-service rule can read: a slot that fails one job in
# fifty is a repository's problem, and a slot that has failed the last four is
# the fleet's.
burns="\$SLOT_STATE/\$idx/burns"

burn_count() {
  local n=""
  [ -f "\$burns" ] && read -r n <"\$burns" 2>/dev/null
  case "\$n" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "\$n" ;;
  esac
}

burn_add() {
  local n
  n=\$(burn_count)
  printf '%s\n' "\$((n + 1))" >"\$burns" 2>/dev/null ||
    say "slot \$idx: could not record that it burned a job"
}

# ONE reset at a time per slot, and this became a requirement rather than a
# nicety when the idle sweep arrived. Until then every caller was the slot's own
# agent, which is single-threaded across the job boundary: started, then the job,
# then completed. The sweep is a root timer that resets a slot NO agent is
# currently driving, so two roots can now be inside one tree — one renaming
# _work into the holding directory while the other is emptying it, both running
# rm -rf against paths the other is moving. The window is small and the outcome
# is not: a half-moved _work is a slot that fails every job until the host goes.
#
# The lock file is in the slot's own state directory, which is root-owned 0755
# and holds the clean marker for the same reason — a slot that could write here
# could forge the very claim this script exists to make.
#
# WAIT rather than skip, because both callers are legitimate and neither is
# repeatable at no cost: the sweep gives up its tick, and a started hook that
# skipped the reset would be the one outcome this script must never produce. The
# deadline is generous because the reset it is waiting on tears down containers
# under three \`timeout\`s of its own; a wait that expires means something is
# genuinely wedged, and then refusing is right — the marker is withheld either
# way, so the sweep tries again in thirty seconds.
exec 9>>"\$SLOT_STATE/\$idx/.reset.lock" ||
  { say "slot \$idx: could not open the reset lock"; exit 1; }
flock -w 300 9 ||
  { say "slot \$idx: another reset of this slot is still running — refusing to start a second one"; exit 1; }

# How much of _work goes. _actions and _temp are filled by the runner BEFORE the
# job-started hook is called — actions are downloaded in JobExtension and _temp
# carries the hook's own invocation — so removing them at that point breaks the
# job that is starting. Everything else under _work belongs to the last job: the
# checked-out workspace with its .git/hooks, and _tool, which is on PATH.
#
# At 'completed' and 'boot' nothing under _work belongs to a live job, so both
# exceptions are dropped and _actions and _temp go with the rest. Leaving _temp
# behind is not a tidiness question: google-github-actions/auth writes its
# credential file under RUNNER_TEMP, which IS _temp, so a _temp that outlives the
# job boundary is the exact leak #110 was opened for, one directory over from the
# home this hook already rebuilds.
keep_actions=0
keep_temp=0
[ "\$stage" = started ] && keep_actions=1
[ "\$stage" = started ] && keep_temp=1

# A job-started that cannot find the marker is a job about to run on a slot
# whose previous job never reached its completed hook — cancelled hard, agent
# killed, host lost power mid-job. That is the state that leaves the most
# behind, and it is also the one state in which _actions cannot be trusted. So
# the exception is dropped and the job is FAILED rather than run: one lost job
# that says why beats a job that silently executed a previous job's action code.
fail_after=0
if [ "\$stage" = started ] && [ ! -f "\$marker" ]; then
  say "slot \$idx was not left clean — its previous job never completed; wiping everything and failing this job"
  keep_actions=0
  # keep_temp is deliberately NOT cleared here. The runner writes this hook's own
  # invocation under _temp, so emptying it now would break the very job we are
  # about to fail deliberately. Its content goes at the completed reset that
  # follows, which is the reset that has to be trusted anyway.
  fail_after=1
  # A job is about to be failed on this slot. That is the event #278 exists to
  # count: it is invisible in every fleet series — the host goes on reporting
  # the slot as serving — and it is also the event that makes a broken slot
  # WIN work, because failing in six seconds returns it to the queue faster
  # than a healthy slot can claim one.
  burn_add
fi
# Cleared FIRST. Everything below can fail, and a marker left in place by a
# reset that did not finish is a lie the next job would believe.
rm -f -- "\$marker"

rc=0

# THE HOME, wholesale. -mindepth 1 so the home itself keeps its inode, its
# ownership and its mode: the shell dotfiles, the caches a tool decided to put
# there and anything a job planted are all just entries inside it.
find "\$home" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || { say "slot \$idx: could not empty \$home"; rc=1; }
cp -a "\$SLOT_TEMPLATE/." "\$home/" || { say "slot \$idx: could not restore \$home from \$SLOT_TEMPLATE"; rc=1; }
chown -R "\$u:\$u" "\$home" || { say "slot \$idx: could not chown \$home"; rc=1; }
chmod 0750 "\$home" || { say "slot \$idx: could not chmod \$home"; rc=1; }

# THE WORK FOLDER. Absent until the slot's first job, which is not a failure.
#
# The slot OWNS \$SLOT_ROOT/\$idx -- install_slot chowns the whole runner copy to
# it, because config.sh writes .runner and .credentials there -- so the slot can
# create, rename and replace names inside it, including _work itself. That makes
# every path below a name an untrusted account controls, and root is the one
# walking them. Two things follow, and this is the same namespace-ownership rule
# provision_slot_user states on \$SLOT_STATE/\$idx: root operates on a leaf inside
# a directory root owns, never inside one the slot owns.
#
# So _work is RENAMED into a root-owned holding directory for the duration and
# renamed back at the end. rename(2) is atomic and carries every open handle
# with it, so the runner keeps the workspace it already prepared; what it does
# not carry is the slot's ability to swap a name mid-loop. Without this the
# remove-then-recreate below is a root-owned TOCTOU: a second process of the
# same slot can plant a symlink at \$work between the rm and the install.
work="\$SLOT_ROOT/\$idx/_work"
held="\$SLOT_ROOT/.reset/\$idx/_work"
took=0
if [ -L "\$work" ]; then
  # Checked BEFORE anything follows it. -d is true through a symlink, so a slot
  # that replaced _work with a link to / would have had root walk and empty
  # whatever it pointed at. There is no reset to perform here, only a slot to
  # refuse: the marker is not written and the next job on it is failed.
  say "slot \$idx: \$work is a symlink -- refusing to reset through it"
  rc=1
elif [ -d "\$work" ]; then
  # A holding directory left behind by a reset that died mid-flight. It is under
  # a root-owned 0700 parent, so nothing in it came from a slot.
  rm -rf -- "\$held"
  if mv -T -- "\$work" "\$held"; then
    took=1
  else
    say "slot \$idx: could not take \$work for the reset"
    rc=1
  fi
fi
if [ "\$took" = 1 ]; then
  for e in "\$held"/* "\$held"/.[!.]* "\$held"/..?*; do
    # -e is FALSE for a dangling symlink, so -L is asked too: a link left pointing
    # at a path that no longer exists would otherwise survive every reset, still be
    # recorded clean, and break the next job when the runner prepares or enters that
    # name. The three globs together cover every entry -- plain, .name and ..name --
    # and an unmatched glob stays literal and is dropped by the same test.
    [ -e "\$e" ] || [ -L "\$e" ] || continue
    case "\${e##*/}" in
      _temp) [ "\$keep_temp" = 1 ] && continue ;;
      _actions) [ "\$keep_actions" = 1 ] && continue ;;
    esac
    # A directory is recreated EMPTY rather than left absent. At 'started' the
    # runner has ALREADY prepared the pipeline workspace — JobExtension creates
    # it while initializing the job, well before it appends this hook to the
    # pre-job steps — so a job whose first step is a plain 'run:' would chdir
    # into a path that had stopped existing. The CONTENT is what belongs to the
    # previous job; the directory itself belongs to this one, and _tool is on
    # PATH the same way.
    d=0
    [ -d "\$e" ] && d=1
    rm -rf -- "\$e" || { say "slot \$idx: could not remove \$e"; rc=1; }
    if [ "\$d" = 1 ] && [ "\$stage" = started ]; then
      install -d -o "\$u" -g "\$u" -m 0755 "\$e" || { say "slot \$idx: could not recreate \$e"; rc=1; }
    fi
  done
  # Handed back. The slot still owns the parent, so it could have created a NEW
  # _work at the vacated name while root worked in the holding directory; that
  # name is not ours to remove, so the reset is refused instead and the slot is
  # left without a marker. Fail closed: the next started reset wipes everything
  # and fails that job, which is the outcome this hook exists to produce.
  if [ -e "\$work" ] || [ -L "\$work" ]; then
    say "slot \$idx: something recreated \$work while it was being reset -- refusing to hand it back"
    rc=1
  elif mv -T -- "\$held" "\$work"; then
    chown "\$u:\$u" "\$work" || { say "slot \$idx: could not chown \$work"; rc=1; }
  else
    say "slot \$idx: could not return \$work to slot \$idx"
    rc=1
  fi
fi

# THE IMAGE STORE, tags only.
#
# #231 moved the store to $SLOT_STATE/<idx>/docker precisely so every image the
# host warmed SURVIVES a reset -- that is what keeps the reset cheap -- and #233
# is the surface that leaves open. A job can 'docker tag' or 'docker build -t' a
# name the next job on this slot then resolves LOCALLY: 'docker run <name>' never
# contacts a registry when a local image by that name exists, and neither does a
# 'FROM' in a later build. The next job runs the previous job's content under a
# name it believes it fetched.
#
# Removing the store would be a cold start per job and would defeat the warm
# layer, so what goes is narrower. A tag is KEPT when either is true:
#
#   the image carries a RepoDigest   it came from a registry, by digest. A job
#                                    cannot forge one: 'docker tag' and
#                                    'docker build' produce none, and only a
#                                    pull or a push writes one.
#   its id is in the boot manifest   $SLOT_STATE/<idx>/baked-images, written by
#                                    record_baked_images() from what 'docker
#                                    load' reported at boot. Root-owned, in the
#                                    same root-owned directory as the clean
#                                    marker, so a slot cannot add to it.
#
# Everything else is a name this host has no record of anyone fetching. A MISSING
# manifest reads as an empty one -- a pool that bakes no images has no
# /opt/ci-images and gets no file -- which is correct: with nothing baked, a
# registry digest is the only thing that vouches for a tag.
#
# The NAME goes, not the content: 'docker rmi --no-prune' on one reference of a
# multiply-referenced image untags it, and the layers stay in the store. A
# rebuild is still warm, and the digest-bearing images are untouched.
#
# A daemon that is not there is not a failure here. It already fails the next job
# at its first 'docker' line, and refusing the clean marker on top of that would
# turn a slot with no dockerd into a slot that also fails every job for a reason
# it does not name. A tag that will not go IS a failure: that slot is poisoned,
# and the marker is exactly the claim it must not get.
# A HELD slot is spared, and that is rule 2 of the shared-infra contract meeting
# rule 1. Under one host per pull request the run's later jobs land on THIS
# slot and reuse what the anchor built — and a stack built by \`docker compose
# build\` carries no RepoDigest and was not baked at boot, which is exactly the
# shape below removes. Pruning between two jobs of one run would delete the
# run's own images out from under it.
#
# Deferred, never waived: the sweeper's teardown at expiry runs this same reset
# with the hold already past its expiry, so the tags go then. Nothing a run
# built outlives the run.
prune=1
# The BOOT ID is part of the question, and leaving it out made the warm-reboot
# case silently wrong. The runner unit is already enabled, so on a reboot it
# runs this reset before the sweeper has had a chance to declare the old record
# orphaned. Judged on slot and wall clock alone, an unexpired record from the
# PREVIOUS boot spared the tags -- for containers that did not survive the
# guest. The next job then resolved locally tagged images the last run built,
# which is exactly the cross-job leak this reset exists to close.
if [ -f "\$PIN_DIR/host" ]; then
  h_slot=""; h_expiry=""; h_boot=""
  while IFS='=' read -r hk hv; do
    case "\$hk" in slot) h_slot="\$hv" ;; expiry) h_expiry="\$hv" ;; boot) h_boot="\$hv" ;; esac
  done <"\$PIN_DIR/host"
  case "\$h_slot:\$h_expiry" in
    [0-9]*:[0-9]*)
      if [ "\$h_slot" = "\$idx" ] && [ "\$h_expiry" -gt "\$(date +%s)" ] &&
        [ "\$h_boot" = "\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]; then
        prune=0
        say "slot \$idx is held by a live run -- keeping its local image tags until the hold expires"
      fi
      ;;
  esac
fi
if [ "\$stage" != started ] && [ "\$prune" = 1 ]; then
  sock="/run/\$u/docker.sock"
  baked="\$SLOT_STATE/\$idx/baked-images"
  if [ -S "\$sock" ]; then
    # THE CONTAINERS, and they go BEFORE the tags -- a running container holds a
    # reference to its image and the untag below would fail on it.
    #
    # A stack brought up the documented way, \`docker compose up -d\` in the
    # anchor job, does not stop when the job that started it ends: nothing in
    # the runner's lifecycle reaches into a detached rootless container. Before
    # #258 that was untidy. With a PERSISTENT port band it is a correctness bug
    # with two faces, and both are silent:
    #
    #   the ports stay bound   the next run assigned this slot brings up its own
    #                          stack on the same band ports and gets
    #                          address-in-use, in a job that changed nothing.
    #   the stack stays up     or -- worse -- the next run's jobs CONNECT, to a
    #                          database belonging to a pull request that ended,
    #                          and read or corrupt its data. A passwordless
    #                          Postgres is the example this contract documents.
    #
    # So the reclamation is host-side and boundary-driven, not a TTL: it happens
    # at 'completed' and at 'boot', which is every point at which no job of this
    # slot is running. A HELD slot is spared by the same \`prune\` gate that
    # spares its image tags -- the run's later jobs land here and reuse the
    # stack, which is rule 2 of the contract -- and the sweeper's teardown runs
    # this same reset once the hold has expired, so nothing a run brought up
    # outlives the run.
    #
    # \`docker rm -f -v\`, not \`compose down\`: root has no compose project name
    # here, and a job is free to have started containers without compose at all.
    # \`-v\` takes the anonymous volumes with them, which is where a database that
    # was never meant to persist put its data.
    cids=\$(timeout 30 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
             docker ps --all --quiet --no-trunc 2>/dev/null | sort -u)
    if [ -n "\$cids" ]; then
      # word-splitting is the point -- one id per argument.
      # shellcheck disable=SC2086
      if timeout 180 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
           docker rm --force --volumes -- \$cids >/dev/null 2>&1; then
        say "slot \$idx: removed \$(printf '%s\n' "\$cids" | grep -c .) container(s) left behind by the last job"
      else
        # Fail closed. A container this reset could not remove is still holding
        # its band ports, and the marker is exactly the claim it must not get:
        # the next job on this slot is failed rather than run into a port
        # collision, or into somebody else's database.
        say "slot \$idx: could not remove the containers left behind by the last job"
        rc=1
      fi
    fi
    # The networks and named volumes compose created alongside them. Unreferenced
    # by now, because the containers are gone; a named volume that survived would
    # carry the previous pull request's database into the next run's stack under
    # the same compose project name.
    timeout 60 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
      docker network prune --force >/dev/null 2>&1 ||
      { say "slot \$idx: could not prune the last job's networks"; rc=1; }
    # \`--all\` covers NAMED volumes and not merely anonymous ones, which is the
    # half that matters: \`docker compose\` names its volumes after the project,
    # so the next run under the same project name would inherit the last pull
    # request's database. The flag arrived in Docker 23 and this fleet's hosts
    # are newer -- but a host that is not would fail the flag, fail this reset,
    # and refuse the marker for every job it ever runs. So the older spelling
    # is tried before that is called a failure.
    timeout 60 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
      docker volume prune --force --all >/dev/null 2>&1 ||
      timeout 60 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
        docker volume prune --force >/dev/null 2>&1 ||
      { say "slot \$idx: could not prune the last job's volumes"; rc=1; }

    ids=\$(timeout 30 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
            docker image ls --all --quiet --no-trunc 2>/dev/null | sort -u)
    if [ -n "\$ids" ]; then
      # One inspect for the whole store rather than one per image: a slot that
      # has run a few builds holds dozens, and this runs between every pair of
      # jobs.
      #
      # word-splitting \$ids is the point -- one id per argument.
      # shellcheck disable=SC2086
      info=\$(timeout 60 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
              docker image inspect \
              --format '{{.Id}} {{len .RepoDigests}} {{range .RepoTags}}{{.}} {{end}}' \
              \$ids 2>/dev/null)
      while read -r id ndig tags; do
        [ -n "\$id" ] || continue
        [ "\$ndig" = 0 ] || continue
        grep -qxF -- "\$id" "\$baked" 2>/dev/null && continue
        for t in \$tags; do
          case "\$t" in '' | '<none>:<none>') continue ;; esac
          if timeout 30 sudo -u "\$u" DOCKER_HOST="unix://\$sock" \
               docker rmi --no-prune -- "\$t" >/dev/null 2>&1; then
            say "slot \$idx: dropped local image tag \$t -- no registry digest and not baked at boot"
          else
            say "slot \$idx: could not drop local image tag \$t"
            rc=1
          fi
        done
      done <<< "\$info"
    fi
  else
    say "slot \$idx: no docker socket at \$sock -- no container was reclaimed and no image tag was checked"
  fi
fi

# Written LAST and only on success, into a directory no slot can write. It is
# the assertion "this slot is in the state the template describes", and a reset
# that half-failed has not earned it. Not written at 'started', because the slot
# is about to be dirtied by the job that is starting.
if [ "\$rc" = 0 ] && [ "\$stage" != started ]; then
  : >"\$marker" || rc=1
fi

# THE COUNT, decided by the same rc the marker was. A reset that reached the
# template state is the only evidence that this slot can still be returned to
# it, so it is the only thing that clears the count — and a reset that could
# not is exactly the condemned-by-design case #277 leaves behind: a container
# that will not die, a tag that will not drop, a _work the slot recreated under
# us. 'started' is skipped in both directions: it never earns the marker, so
# clearing on it would erase the history at the start of every job, and the
# burn it may have just recorded above is already counted.
if [ "\$stage" != started ]; then
  if [ "\$rc" = 0 ]; then
    rm -f -- "\$burns"
  else
    burn_add
  fi
fi

[ "\$fail_after" = 1 ] && exit 1
exit "\$rc"
EOF
  # A here-document is expanded BEFORE cat ever runs, and this script runs under
  # `set -u`. One unescaped name in the body above -- in a comment line as
  # readily as in code -- aborts that expansion, and because the `>` redirect
  # has already truncated the target the failure leaves a ZERO-BYTE file with
  # the right owner and the right mode. Every slot unit then dies on
  # `ExecStartPre` with `Exec format error` (203/EXEC), on a host that went on
  # to announce itself ready. Measured 2026-08-23: eight of eleven hosts served
  # nothing for hours this way. So the write is not trusted, it is checked.
  [ -s /opt/ci/job-hooks/slot-reset.sh ] ||
    { log "slot-reset.sh came out empty -- a name in its here-document did not expand"; return 1; }
  bash -n /opt/ci/job-hooks/slot-reset.sh ||
    { log "slot-reset.sh is not parseable -- refusing to install it"; return 1; }
  chown root:root /opt/ci/job-hooks/slot-reset.sh || return 1
  chmod 0755 /opt/ci/job-hooks/slot-reset.sh || return 1

  # The credential-only hook this supersedes. Removed rather than left behind: a
  # warm host reboots into a newer copy of this script with the old file still
  # on its boot disk, and a stale reset that removes two directories is worse
  # than none at all — it looks like the reset is happening.
  rm -f /opt/ci/job-hooks/reset-credentials.sh

  install_slot_reset_sudoers || return 1
}

# What a slot may run as root, spelled out to the argument. sudoers matches a
# command line literally, so listing the two stages IS the allowlist: there is
# no permitted form that names another slot's index, and none that reaches the
# `boot` path systemd uses.
install_slot_reset_sudoers() {
  local f=/etc/sudoers.d/ci-slot-reset tmp i u
  tmp=$(mktemp) || return 1
  {
    echo "# Written by host-startup.sh. Lets each slot ask root to reset ITSELF"
    echo "# between jobs. The index comes from SUDO_UID, never from an argument."
    for i in $(seq 1 "$SLOTS"); do
      u=$(slot_user "$i")
      printf '%s ALL=(root) NOPASSWD: /opt/ci/job-hooks/slot-reset.sh started, /opt/ci/job-hooks/slot-reset.sh completed\n' "$u"
    done
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0440 "$tmp" || { rm -f "$tmp"; return 1; }

  # Validated BEFORE it is installed. A file in /etc/sudoers.d that does not
  # parse does not fail open on the one rule it was meant to add: sudo refuses
  # the whole ruleset, and every sudo on the host stops working — including the
  # one install_slot needs to register an agent at all.
  if ! visudo -cqf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    log "refusing to install $f: it does not pass visudo"
    return 1
  fi
  install -o root -g root -m 0440 "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# --- the pin hold -------------------------------------------------------------
#
# One workflow run keeps one host for as long as it needs it
# (adr-pr-host-affinity.md §3.1, ci-pr-shared-infra.md §6). The mechanism is a
# single root-owned record on the host naming the run that holds it and the
# moment the hold expires, republished into a guest attribute so the controller
# can see it without an SSH probe it has no place to make.
#
# The consumer-facing spelling is the one the contract publishes, and it is a
# flag form rather than a verb because a workflow author writes it by hand:
#
#   ci-pin-hold --run "$GITHUB_RUN_ID" --ttl "$CI_PIN_TTL" [--reserve-slot]
#
# `renew` and `status` are bare verbs because nothing outside this host calls
# them. Four properties are load-bearing, and each is a decision the ADR argues
# rather than an implementation detail:
#
#   ADMISSION, NOT REQUEST.  A reserve refuses when the host already carries a
#   hold for a DIFFERENT live run, and the refusal is exit 0 with `pinned=0` —
#   the loser continues unpinned, which this design already supports. If every
#   anchor that asked were granted, several runs starting together would take
#   every slot on one host and each would then wait out the others' TTLs on the
#   stack it was blocking: a deadlock built entirely out of successful steps.
#
#   MONOTONIC.  There is no verb that shortens or removes a hold. `renew`
#   extends by the TTL RECORDED IN THE HOLD, never by one the caller supplies,
#   and any slot on the host may call it — a co-tenant must be able to keep a
#   host alive and must not be able to release someone else's. Expiry is the
#   only way a hold ends, and the sweeper is the only thing that acts on it.
#
#   THE INDEX IS NEVER AN ARGUMENT.  Same rule slot-reset.sh states: which slot
#   is speaking comes from SUDO_UID, which sudo sets itself and env_reset
#   strips from the caller's environment.
#
#   A HOLD DOES NOT SURVIVE A REBOOT.  It records the boot it was written under.
#   Rootless containers do not outlive the guest, so a hold carried across a
#   warm reboot would pin a host to a stack that no longer exists and fail the
#   run slowly instead of quickly. A stale hold is released as orphaned.
PIN_DIR="$SLOT_STATE/.pin"
# 30 minutes by default and 2 hours at most. The default is long enough for the
# tail of an ordinary run and short enough that a run which died without ever
# reaching a completed hook does not hold a host through a lunch break; the
# clamp is what stops a job asking for a day, and it is also how long an
# abandoned hold can pin a host. A hold is renewed at the start of every job on
# a held host, so the TTL bounds the GAP between jobs, not the run.
PIN_DEFAULT_TTL=1800
PIN_MAX_TTL=7200

install_pin_hold() {
  mkdir -p "$PIN_DIR" || return 1
  chown root:root "$PIN_DIR" || return 1
  # 0755, not 0700: a job may READ the record — that is how a consumer learns
  # which run holds the host it is on — and no job may write it.
  chmod 0755 "$PIN_DIR" || return 1

  cat >/opt/ci/job-hooks/pin-hold.sh <<EOF
#!/usr/bin/env bash
# Installed by host-startup.sh. Runs as root. See install_pin_hold().
set -uo pipefail

SLOT_STATE="$SLOT_STATE"
SLOT_USER_PREFIX="$SLOT_USER_PREFIX"
PIN_DIR="$PIN_DIR"
PIN_DEFAULT_TTL=$PIN_DEFAULT_TTL
PIN_MAX_TTL=$PIN_MAX_TTL
SLOTS=$SLOTS
HOST_LABEL="$HOST_LABEL"

RECORD="\$PIN_DIR/host"
LOCK="\$PIN_DIR/.lock"

# Admission is a CHECK followed by a WRITE, and between the two it was not
# exclusive. Two anchors on two idle slots could each read "no live hold", each
# write, and each be told pinned=1 -- the atomic rename kept the file whole and
# lost one reservation entirely, leaving that run pinned to a host where its
# slot and its stack are protected by nothing. The rename was never the race.
#
# The sweeper takes the same lock, because "no live hold" and "the sweeper is
# halfway through releasing one" are different states that looked identical.
take_lock() { # <what>
  exec 9>>"\$LOCK" || { say "refusing \$1: cannot open \$LOCK"; return 1; }
  flock -w 15 9 || { say "refusing \$1: another caller holds the admission lock"; return 1; }
  return 0
}

say() { logger -t ci-pin-hold -- "\$*" 2>/dev/null || true; echo "pin hold: \$*" >&2; }

boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

# The guest attribute the controller reads. Best effort by design: the hold on
# disk is the truth this host acts on, and a metadata server that did not answer
# must not turn into a host that forgets it is holding a run. The controller's
# own reader is monotonic (§2.4), so a PUT that is late is merely late.
publish() {
  curl --silent --show-error --fail --connect-timeout 3 --max-time 10 \
    -X PUT --data "\$1" -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/ci/pin-hold" \
    >/dev/null 2>&1 || say "could not publish the hold to guest attributes (the record on disk still stands)"
}

# The contract publishes a DURATION -- 'CI_PIN_TTL: 90m' -- because that is what
# a workflow author writes next to a timeout-minutes they already own. Seconds
# are accepted bare so the host's own callers need no suffix.
parse_ttl() { # <text> -> seconds on stdout; non-zero on refusal
  local t="\$1" n unit
  case "\$t" in
    *[0-9]s) n="\${t%s}"; unit=1 ;;
    *[0-9]m) n="\${t%m}"; unit=60 ;;
    *[0-9]h) n="\${t%h}"; unit=3600 ;;
    *[0-9])  n="\$t";     unit=1 ;;
    *) return 1 ;;
  esac
  case "\$n" in '' | *[!0-9]*) return 1 ;; esac
  [ "\${#n}" -le 9 ] || return 1
  printf '%s' "\$((n * unit))"
}

# Sets R_RUN R_SLOT R_TTL R_EXPIRY R_RESERVE R_BOOT. Returns 1 when there is no
# usable record, and 2 when there is one but it belongs to an earlier boot.
#
# A record that does not parse is treated as ABSENT here and as PRESENT by the
# sweeper, and the asymmetry is deliberate: refusing to grant a new hold over
# something unreadable would wedge the host forever, while sweeping something
# unreadable away would be the one path by which a corrupted byte releases a
# live run's host.
read_record() {
  R_RUN=""; R_SLOT=""; R_TTL=""; R_EXPIRY=""; R_RESERVE=0; R_BOOT=""
  [ -f "\$RECORD" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case "\$k" in
      run) R_RUN="\$v" ;;
      slot) R_SLOT="\$v" ;;
      ttl) R_TTL="\$v" ;;
      expiry) R_EXPIRY="\$v" ;;
      reserve) R_RESERVE="\$v" ;;
      boot) R_BOOT="\$v" ;;
    esac
  done <"\$RECORD"
  case "\$R_RUN:\$R_SLOT:\$R_TTL:\$R_EXPIRY:\$R_RESERVE" in
    ?*:[0-9]*:[0-9]*:[0-9]*:[01]) ;;
    *) return 1 ;;
  esac
  [ "\$R_BOOT" = "\$(boot_id)" ] || return 2
  return 0
}

# The record is replaced by RENAME, never by writing over the live file. A
# reader that opened it between a truncate and a write would see a hold with no
# expiry, and read_record would call that absent — which is the one reading that
# releases a host somebody is using.
write_record() { # <run> <slot> <ttl> <expiry> <reserve>
  local tmp
  tmp=\$(mktemp "\$PIN_DIR/.host.XXXXXX") || return 1
  {
    printf 'run=%s\n' "\$1"
    printf 'slot=%s\n' "\$2"
    printf 'ttl=%s\n' "\$3"
    printf 'expiry=%s\n' "\$4"
    printf 'reserve=%s\n' "\$5"
    printf 'boot=%s\n' "\$(boot_id)"
  } >"\$tmp" || { rm -f "\$tmp"; return 1; }
  chmod 0644 "\$tmp" || { rm -f "\$tmp"; return 1; }
  mv -f -- "\$tmp" "\$RECORD" || { rm -f "\$tmp"; return 1; }
}

idx=""
if [ -n "\${SUDO_UID:-}" ]; then
  u=\$(getent passwd "\$SUDO_UID" | cut -d: -f1)
  case "\$u" in
    "\$SLOT_USER_PREFIX"[0-9]*) idx=\${u#"\$SLOT_USER_PREFIX"} ;;
    *) say "refusing: uid \$SUDO_UID (\$u) is not a slot user"; exit 1 ;;
  esac
fi

now=\$(date +%s)

case "\${1:-}" in
  --run)
    [ -n "\$idx" ] || { say "refusing: reserve must come from a slot"; exit 1; }
    run=""; ttl_text=""; reserve=0; slot_to_write=""; expiry_to_write=""
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        # \`shift 2 || break\` accepted a flag with no value and fell through
        # to the default TTL, or to an empty run id caught much later by the
        # shape check. A workflow that wrote \`--ttl\` and forgot the duration got
        # a hold it did not ask for, and no diagnostic saying so.
        --run) [ "\$#" -ge 2 ] || { say "refusing: --run needs a value"; exit 1; }; run="\$2"; shift 2 ;;
        --ttl) [ "\$#" -ge 2 ] || { say "refusing: --ttl needs a value"; exit 1; }; ttl_text="\$2"; shift 2 ;;
        --reserve-slot) reserve=1; shift ;;
        *) say "refusing: unknown argument '\$1'"; exit 1 ;;
      esac
    done

    # The run id lands in a file, a log line and a guest attribute. Shape-checked
    # rather than quoted-and-hoped: GITHUB_RUN_ID is a number today, and the
    # workflows that pass it are not this repository's to police.
    case "\$run" in
      '' | *[!A-Za-z0-9._-]*) say "refusing: '\$run' is not a usable run id"; exit 1 ;;
    esac
    [ "\${#run}" -le 64 ] || { say "refusing: run id is longer than 64 characters"; exit 1; }

    ttl=""
    if [ -n "\$ttl_text" ]; then
      ttl=\$(parse_ttl "\$ttl_text") || { say "refusing: '\$ttl_text' is not a duration"; exit 1; }
    fi
    [ -n "\$ttl" ] || ttl=\$PIN_DEFAULT_TTL
    [ "\$ttl" -ge 60 ] || ttl=60
    [ "\$ttl" -le "\$PIN_MAX_TTL" ] || ttl=\$PIN_MAX_TTL

    # A one-slot host cannot reserve: the reservation takes the slot out of
    # service, and taking the only slot out of service is a host that serves
    # nobody, including the run that asked. Refused rather than downgraded, so
    # the workflow learns it needs a pool with room instead of losing its stack
    # to the next job that lands.
    if [ "\$reserve" = 1 ] && [ "\$SLOTS" -lt 2 ]; then
      say "refusing --reserve-slot: this host has one slot, and reserving it would leave the run nowhere to run"
      exit 1
    fi

    take_lock "the hold" || exit 1
    read_record; rr=\$?
    if [ "\$rr" = 0 ] && [ "\$R_RUN" != "\$run" ] && [ "\$R_EXPIRY" -gt "\$now" ]; then
      # The admission decision, and the whole reason this is not a request.
      say "slot \$idx: run \$run may not reserve this host — run \$R_RUN holds it for another \$((R_EXPIRY - now))s"
      echo "pinned=0"
      exit 0
    fi

    # An EXPIRED RESERVATION is not a free host, and reading it as one leaked a
    # slot every time. The sweeper releases a reservation by tearing the stack
    # down, resetting the slot and starting its agent; between the expiry and
    # the next 30-second tick the record still describes a stopped agent over a
    # live stack. Overwriting it there discards the only thing that says any of
    # that has to happen, so the old stack survives, the old agent stays down,
    # and the new run reserves a different slot. Repeat and the host runs out.
    if [ "\$rr" = 0 ] && [ "\$R_RUN" != "\$run" ] && [ "\$R_RESERVE" = 1 ]; then
      say "slot \$idx: run \$run may not take this host yet — run \$R_RUN's reservation expired \$((now - R_EXPIRY))s ago and the sweeper has not released it"
      echo "pinned=0"
      exit 0
    fi

    slot_to_write=\$idx
    expiry_to_write=\$((now + ttl))
    if [ "\$rr" = 0 ] && [ "\$R_RUN" = "\$run" ]; then
      # A repeated claim by the SAME run may ADD a reservation -- the documented
      # flow is an anchor that pins, then an owner job that reserves -- and may
      # not do anything else. The record is world-readable by design, so a
      # co-tenant can read R_RUN and call with it; matching the run id is an
      # identity CLAIM and not proof of one. Keeping the reserved slot and the
      # later of the two expiries costs the real owner nothing, and leaves that
      # caller nothing to move: it cannot walk the reservation onto its own slot
      # and it cannot shorten a hold by asking for a smaller TTL.
      [ "\$R_RESERVE" = 1 ] && { reserve=1; slot_to_write=\$R_SLOT; }
      [ "\$R_EXPIRY" -gt "\$expiry_to_write" ] && expiry_to_write=\$R_EXPIRY
    fi

    write_record "\$run" "\$slot_to_write" "\$ttl" "\$expiry_to_write" "\$reserve" \
      || { say "could not write the hold"; exit 1; }
    publish "\$run \$expiry_to_write"
    say "slot \$slot_to_write: run \$run holds this host for another \$((expiry_to_write - now))s (reserve=\$reserve)"
    echo "pinned=1"
    echo "host_label=\$HOST_LABEL"
    echo "reserved=\$reserve"
    ;;

  renew)
    # The TTL comes from the record because the renewing job is not always the
    # job that reserved: a consumer inside a 'container:' cannot reach this
    # binary at all, so the renewal is made by the host's job-started hook,
    # which has no view of a workflow-level env:.
    #
    # \`--run\` is how that hook says WHICH run it is renewing for. Without it,
    # every job on the host renewed whatever hold it found: once the owning run
    # finished or was cancelled, an unrelated job landing on any slot pushed the
    # expiry forward again, and the stopped slot, the surviving stack and the
    # veto on this host's removal all outlived the run indefinitely. A TTL only
    # ends a hold if nothing keeps feeding it.
    shift
    renew_run=""
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --run) [ "\$#" -ge 2 ] || { say "refusing: --run needs a value"; exit 1; }; renew_run="\$2"; shift 2 ;;
        *) say "refusing: unknown argument '\$1'"; exit 1 ;;
      esac
    done
    # An absent or empty --run is not an identity claim, and renewing on one
    # renews whatever hold happens to be there — the very thing --run exists to
    # stop. Sudoers no longer permits the bare verb; this refuses it too, so
    # neither door depends on the other staying shut.
    [ -n "\$renew_run" ] || { say "refusing: renew needs --run <id>"; exit 1; }
    take_lock "the renewal" || exit 1
    read_record || { echo "pinned=0"; exit 0; }
    [ "\$R_EXPIRY" -gt "\$now" ] || { echo "pinned=0"; exit 0; }
    if [ "\$renew_run" != "\$R_RUN" ]; then
      say "not renewing: this job belongs to run \$renew_run and the hold is run \$R_RUN's"
      echo "pinned=0"
      echo "run=\$R_RUN"
      exit 0
    fi
    # Monotonic: only ever forward, and never past the clamp.
    new=\$((now + R_TTL))
    [ "\$new" -gt "\$R_EXPIRY" ] || new=\$R_EXPIRY
    write_record "\$R_RUN" "\$R_SLOT" "\$R_TTL" "\$new" "\$R_RESERVE" || exit 1
    publish "\$R_RUN \$new"
    echo "pinned=1"
    echo "run=\$R_RUN"
    ;;

  status)
    read_record || { echo "pinned=0"; exit 0; }
    echo "pinned=1"
    echo "run=\$R_RUN"
    echo "slot=\$R_SLOT"
    echo "reserved=\$R_RESERVE"
    echo "expires_in=\$((R_EXPIRY - now))"
    ;;

  *)
    say "refusing: expected --run <id> [--ttl <duration>] [--reserve-slot], or renew, or status"
    exit 1
    ;;
esac
exit 0
EOF
  chown root:root /opt/ci/job-hooks/pin-hold.sh || return 1
  chmod 0755 /opt/ci/job-hooks/pin-hold.sh || return 1

  # On PATH, because a workflow step should not have to know where this host
  # keeps its hooks. The shim is what the sudoers rules name.
  cat >/usr/local/bin/ci-pin-hold <<'EOF'
#!/usr/bin/env bash
# Installed by host-startup.sh. Runs as the slot user. See install_pin_hold().
set -uo pipefail
exec sudo -n /opt/ci/job-hooks/pin-hold.sh "$@"
EOF
  chown root:root /usr/local/bin/ci-pin-hold || return 1
  chmod 0755 /usr/local/bin/ci-pin-hold || return 1

  install_pin_hold_sudoers || return 1
  install_pin_sweep || return 1
}

install_pin_hold_sudoers() {
  local f=/etc/sudoers.d/ci-pin-hold tmp i u
  tmp=$(mktemp) || return 1
  {
    echo "# Written by host-startup.sh. Lets a slot take, extend and read the"
    echo "# host's pin hold. There is no verb here that shortens or removes one:"
    echo "# a co-tenant must be able to keep a host alive and must not be able to"
    echo "# release somebody else's run. Expiry is the only end, and the sweeper"
    echo "# is the only thing that acts on it."
    echo "#"
    echo "# The reserve form takes a wildcard because its arguments are a run id"
    echo "# and a duration nobody can enumerate here. What bounds it is the first"
    echo "# argument being pinned to --run, and pin-hold.sh validating every"
    echo "# field it then reads: sudo matches argv, so there is no shell for the"
    echo "# wildcard to reach, and no argument that names another slot."
    for i in $(seq 1 "$SLOTS"); do
      u=$(slot_user "$i")
      printf '%s ALL=(root) NOPASSWD: /opt/ci/job-hooks/pin-hold.sh --run *, /opt/ci/job-hooks/pin-hold.sh renew --run *, /opt/ci/job-hooks/pin-hold.sh status\n' "$u"
    done
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0440 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! visudo -cqf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    log "refusing to install $f: it does not pass visudo"
    return 1
  fi
  install -o root -g root -m 0440 "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# --- the sweeper --------------------------------------------------------------
#
# The one actor that can end a hold. The contract's first draft gave this to the
# controller, and it cannot have it: the controller's only per-host shell lives
# inside drain_host() and runs AFTER a removal verdict, so a host that is
# healthy, current-template and busy is never probed at all — which is every
# host a live hold is on. The job-completed hook cannot have it either, because
# it executes inside ci-runner@<idx>.service and stopping that unit would have
# systemd SIGTERM the agent while it is still reporting the job's result.
#
# So it is a timer on the host, and that also gets the other half for free: a
# hold ends by EXPIRING, and expiry is not an event anybody delivers.
install_pin_sweep() {
  cat >/opt/ci/job-hooks/pin-sweep.sh <<EOF
#!/usr/bin/env bash
# Installed by host-startup.sh. Runs as root on a timer. See install_pin_sweep().
set -uo pipefail

SLOT_STATE="$SLOT_STATE"
SLOT_USER_PREFIX="$SLOT_USER_PREFIX"
PIN_DIR="$PIN_DIR"

RECORD="\$PIN_DIR/host"
LOCK="\$PIN_DIR/.lock"

say() { logger -t ci-pin-sweep -- "\$*" 2>/dev/null || true; echo "pin sweep: \$*" >&2; }

publish() { # <payload>
  curl --silent --show-error --fail --connect-timeout 3 --max-time 10 \
    -X PUT --data "\$1" -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/ci/pin-hold" \
    >/dev/null 2>&1 || true
}

[ -f "\$RECORD" ] || exit 0

# The SAME lock ci-pin-hold takes to admit a run. Without it a sweep releasing
# an expired reservation and an anchor deciding the host is free ran against
# each other, and the anchor's write landed on a record the sweep then deleted.
# A tick that cannot get the lock does nothing and returns in 30 seconds.
exec 9>>"\$LOCK" || exit 0
flock -w 10 9 || { say "another caller holds the admission lock — this tick does nothing"; exit 0; }

run=""; slot=""; expiry=""; reserve=0; boot=""
while IFS='=' read -r k v; do
  case "\$k" in
    run) run="\$v" ;; slot) slot="\$v" ;; expiry) expiry="\$v" ;;
    reserve) reserve="\$v" ;; boot) boot="\$v" ;;
  esac
done <"\$RECORD"

# Unreadable is KEPT, and the host is left alone. The opposite reading — sweep
# what you cannot parse — makes a corrupted byte into a released host, under a
# run that is still using it.
case "\$run:\$slot:\$expiry:\$reserve" in
  ?*:[0-9]*:[0-9]*:[01]) ;;
  *) say "the hold record does not parse — leaving it, and this host, alone"; exit 0 ;;
esac

now=\$(date +%s)
u="\$SLOT_USER_PREFIX\$slot"
marker="\$SLOT_STATE/\$slot/clean"

# A hold from an earlier boot is ORPHANED, not honoured. Rootless containers do
# not survive the guest, so the stack it protects is already gone: keeping it
# would pin a live host to nothing and fail the run slowly instead of at once.
# There is nothing to tear down, so this is a release and not a teardown.
if [ "\$boot" != "\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]; then
  say "run \$run's hold was written before this boot — releasing it as orphaned; its containers did not survive the reboot"
  # PUBLISHED, not just logged. The instance keeps answering the same host-*
  # label across a reboot, so the controller's missing-host detector cannot see
  # that the promised stack is gone; left alone, the guest attribute goes on
  # vetoing this host's removal until the old expiry, while every job pinned to
  # it waits on a stack that no longer exists. Clearing the attribute is what
  # ends the veto, and it goes BEFORE the local record -- once that is deleted
  # nothing on this host knows which run to clear.
  publish ""
  rm -f -- "\$RECORD"
  systemctl start "ci-runner@\$slot.service" >/dev/null 2>&1 || true
  exit 0
fi

if [ "\$expiry" -gt "\$now" ]; then
  # Live. Republish, because a guest attribute is not durable across everything
  # that can reset one, and the controller reads the attribute rather than this
  # file.
  publish "\$run \$expiry"

  # And take a RESERVED slot out of service the moment it goes idle. The stack
  # belongs to this slot's rootless daemon and this slot's uid; a released slot
  # is handed to the next job under both, which would hand another run a live
  # database and a warm docker socket it never created.
  #
  # 'Idle' is the clean marker AND no worker process, and it needs both. The
  # marker is written by the completed hook BEFORE control returns to the
  # runner, and it stays on disk while the runner reports the result and while
  # it accepts and prepares the next job -- right up to that job's started hook.
  # A tick landing anywhere in either window saw a marker and stopped the unit
  # underneath a live job, through the very mechanism added to avoid stopping
  # one. Runner.Worker is the runner's own per-job process and exists for
  # exactly the span the marker cannot describe.
  #
  # This narrows the window; it does not close it. A job that arrives between
  # the pgrep and the stop is still lost, and closing that needs a signal from
  # the runner that it has no assignment, which the agent does not offer.
  #
  # Only when the hold asked for it. A pinned consumer that never brought a
  # stack up has nothing to protect, and stopping its agent would subtract a
  # slot from the pool for the length of a run that was not using it.
  if [ "\$reserve" = 1 ] && [ -f "\$marker" ] &&
    ! pgrep -u "\$u" -f 'Runner\.Worker' >/dev/null 2>&1 &&
    systemctl is-active --quiet "ci-runner@\$slot.service"; then
    if systemctl stop "ci-runner@\$slot.service" >/dev/null 2>&1; then
      say "slot \$slot reserved by run \$run and now idle — agent stopped so the run's stack is not handed to the next job"
    else
      say "slot \$slot: could not stop the agent holding run \$run's stack"
    fi
  fi
  exit 0
fi

# --- expired ------------------------------------------------------------------
say "run \$run's hold on slot \$slot expired \$((now - expiry))s ago"

# A hold that reserved nothing owns no stack and no slot: the slot's own
# job-completed reset already cleaned it, and it never left service. Releasing
# is the whole of the work.
if [ "\$reserve" != 1 ]; then
  rm -f -- "\$RECORD"
  publish ""
  say "released — the host is available to the next run"
  exit 0
fi

# Teardown, reset, agent back. FAIL CLOSED on each: a slot whose stack would not
# die, or whose reset did not finish, is a slot that must not take another job,
# so the agent is left DOWN rather than started over an unknown state. A host
# whose slots are down takes no work and stops vetoing its own removal, which is
# the only retirement this host has a channel to ask for.
say "tearing run \$run's stack down on slot \$slot"

rc=0

# THE AGENT GOES DOWN FIRST. The live branch above stops a reserved slot's agent
# when it sees the slot idle, and it can miss: the hold can expire before that
# ever happens, and the documented one-tick reservation window lets another job
# land on the slot in the meantime. Reaching teardown with the agent up means
# deleting the containers, home and workspace of a job that is running right
# now. Fail closed -- a slot whose agent will not stop is left exactly as it is,
# with the hold in place, and the next tick tries again.
if systemctl is-active --quiet "ci-runner@\$slot.service"; then
  if systemctl stop "ci-runner@\$slot.service" >/dev/null 2>&1; then
    say "slot \$slot: agent stopped before teardown"
  else
    say "slot \$slot: could not stop the agent — NOT tearing down; the hold stays for the next sweep"
    exit 0
  fi
fi

# The containers next. Nothing else here stops them: slot-reset.sh empties the
# home and _work, which is where the compose file was, not where the stack is.
sock="/run/\$u/docker.sock"
if [ -S "\$sock" ]; then
  # A FAILED enumeration is not an empty one. \`docker ps\` timing out or erroring
  # left ids empty with the failure dropped, so the removal was skipped, the
  # teardown was called a success, the hold was deleted and the agent came back
  # over a still-live stack -- handing the next job the previous run's daemon.
  if ! ids=\$(timeout 30 sudo -u "\$u" DOCKER_HOST="unix://\$sock" docker ps --all --quiet 2>/dev/null); then
    say "slot \$slot: could not list the run's containers — treating the teardown as failed"
    rc=1
    ids=""
  fi
  if [ -n "\$ids" ]; then
    # word-splitting \$ids is the point -- one id per argument.
    # shellcheck disable=SC2086
    timeout 120 sudo -u "\$u" DOCKER_HOST="unix://\$sock" docker rm --force --volumes \$ids >/dev/null 2>&1 \
      || { say "slot \$slot: could not remove the run's containers"; rc=1; }
  fi
else
  say "slot \$slot: no docker socket at \$sock — no container was stopped"
fi

# The record is still in place here, and deliberately: the reset reads it, sees
# an EXPIRED hold, and prunes the image tags it spared while the hold was live.
/opt/ci/job-hooks/slot-reset.sh completed "\$slot" >/dev/null 2>&1 \
  || { say "slot \$slot: the reset after the hold did not finish"; rc=1; }

# The record goes only when the slot is genuinely back. A hold left in place is
# swept again on the next tick, which is a retry; a hold removed over a slot
# that is still dirty is a slot handed back to the fleet on a clean bill of
# health nobody earned.
#
# THE AGENT START IS PART OF THAT, and it was not. Removing the record and then
# failing to start left no state for a later sweep to retry from, so the slot
# stayed down for the life of the host with nothing recording why. On a pool at
# min_hosts the controller keeps that host at the floor rather than replacing
# it, so the pool quietly runs one slot short. Keeping the record makes the next
# tick redo a teardown that is idempotent -- the containers are already gone --
# and try the start again.
if [ "\$rc" != 0 ]; then
  say "slot \$slot: teardown incomplete — the agent stays DOWN and the hold stays in place for the next sweep"
  exit 0
fi

if ! systemctl start "ci-runner@\$slot.service" >/dev/null 2>&1; then
  say "slot \$slot: torn down and reset, but the agent would not start — the hold stays in place so the next sweep retries"
  exit 0
fi

rm -f -- "\$RECORD"
publish ""
say "slot \$slot: torn down, reset and back in service"
exit 0
EOF
  chown root:root /opt/ci/job-hooks/pin-sweep.sh || return 1
  chmod 0755 /opt/ci/job-hooks/pin-sweep.sh || return 1

  cat >/etc/systemd/system/ci-pin-sweep.service <<'EOF'
[Unit]
Description=Expire this host's pin hold and return the held slot to service

[Service]
Type=oneshot
# A oneshot with no deadline blocks its own timer forever: systemd will not
# start the next activation while this one is still running, so a single sweep
# wedged in `docker compose down` or `systemctl start` stops every later sweep
# on this host -- and the held slot it was about to return never comes back.
# Generous rather than tight, because the sweep tears a stack down and starts an
# agent, and killing that halfway is only safe BECAUSE it is: the hold record
# outlives a failed teardown, so the next sweep retries from where this one
# stopped.
TimeoutStartSec=300
ExecStart=/opt/ci/job-hooks/pin-sweep.sh
EOF

  # Every 30 seconds, which is the window between a hold expiring and the slot
  # coming back. AccuracySec pins it: systemd coalesces timers by up to a minute
  # by default, and a sweep that drifts is a slot idle and unavailable for
  # longer than anything says it should be.
  cat >/etc/systemd/system/ci-pin-sweep.timer <<'EOF'
[Unit]
Description=Sweep this host's pin hold every 30 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >>/var/log/ci-host.log 2>&1 || return 1
  systemctl enable --now ci-pin-sweep.timer >>/var/log/ci-host.log 2>&1 || return 1
}

# --- the idle slot sweep ------------------------------------------------------
#
# A slot with no clean marker is a slot whose last job never reached its
# completed hook: cancelled hard, agent killed, host lost power mid-job. The
# started hook refuses to RUN such a slot, and that refusal is right and stays —
# it is the one state in which _actions cannot be trusted, so a job that ran
# there would be executing a previous job's action code.
#
# What was wrong is that the cleaning waited for a victim. Nothing about a
# cancelled job's leftovers requires a job to be standing on the slot while they
# are removed, and the price of waiting was measured: under a fail-fast matrix
# one red shard cancels its siblings, every cancelled sibling condemns its slot,
# and every condemned slot then bills the next job that lands on it. At
# IntegrateIT on 2026-08-23 that reached twelve of twenty-four slots, and a
# condemned slot burns a job in about six seconds -- faster than a healthy slot
# can claim one, so it preferentially WINS queued work.
#
# So the same reset runs here instead, at the one moment that costs nothing: the
# slot is dirty AND no job is on it. The stage is 'completed', which is the
# existing path for exactly this state -- no live job, so both the _actions and
# _temp exceptions are dropped and the marker is written on success.
#
# Three sources feed it and only the first is a defect: a job cancelled by
# fail-fast, a job that deleted its own workspace so the runner could not launch
# the completed hook at all, and the periodic audits that withdraw a marker on
# purpose when a slot's prune inputs stop holding.
install_slot_sweep() {
  cat >/opt/ci/job-hooks/slot-sweep.sh <<EOF
#!/usr/bin/env bash
# Installed by host-startup.sh. Runs as root on a timer. See install_slot_sweep().
set -uo pipefail

SLOT_STATE="$SLOT_STATE"
SLOT_USER_PREFIX="$SLOT_USER_PREFIX"
SLOTS=$SLOTS

# How long a slot must have been dirty AND idle before this touches it. Two
# ticks, deliberately: one observation is a sample of two facts read a moment
# apart, and the whole risk here is acting on a slot a job is arriving at. A
# job in flight holds a worker process for its entire length, so the pair below
# cannot BOTH be true under one -- but a pgrep that failed to see a process it
# should have seen would be indistinguishable from an idle slot, and requiring
# the state to persist turns that from a wrong action into a skipped tick.
GRACE=60

# How many consecutive failures to reach a clean state condemn a slot. Counted
# by slot-reset.sh into \$SLOT_STATE/<idx>/burns; see the burn count there for
# what does and does not clear it.
#
# Small on purpose. The cost of being wrong in one direction is a slot idle for
# a few minutes on a host that has other slots; in the other it is a slot that
# burns every job it is handed at six seconds a job, winning the race for
# queued work against its healthy neighbours because losing is faster than
# working. Three is two more chances than the evidence in #278 suggests any of
# them ever used.
CONDEMN_MAX=3

say() { logger -t ci-slot-sweep -- "\$*" 2>/dev/null || true; echo "slot sweep: \$*" >&2; }

for idx in \$(seq 1 "\$SLOTS"); do
  u="\$SLOT_USER_PREFIX\$idx"
  dir="\$SLOT_STATE/\$idx"
  marker="\$dir/clean"
  since="\$dir/dirty-since"

  id "\$u" >/dev/null 2>&1 || continue
  [ -d "\$dir" ] || continue

  # Clean is the ordinary case and the cheap one, and it clears the clock: a
  # slot that went dirty, served a job and came back must not carry a
  # measurement taken before all of that toward its next dirty spell.
  if [ -f "\$marker" ]; then
    rm -f -- "\$since"
    continue
  fi

  # A live job. The marker is absent for the whole length of one -- the started
  # hook clears it and the completed hook writes it back -- so this is the
  # ordinary reading of a dirty slot and not an exception.
  if pgrep -u "\$u" -f 'Runner\.Worker' >/dev/null 2>&1; then
    rm -f -- "\$since"
    continue
  fi

  # A slot mid-transition is somebody else's. 'activating' is the boot reset
  # running as the agent unit's ExecStartPre, which is this same script under
  # another name; is-active --quiet answers only for 'active', so the state is
  # read as a word rather than as a yes/no.
  state=\$(systemctl is-active "ci-runner@\$idx.service" 2>/dev/null)
  case "\$state" in
    activating | deactivating | reloading) continue ;;
  esac

  now=\$(date +%s)
  seen=""
  [ -f "\$since" ] && read -r seen <"\$since"
  case "\$seen" in
    [0-9]*) ;;
    *) seen="\$now"; printf '%s\n' "\$now" >"\$since" || say "slot \$idx: could not record when it went dirty" ;;
  esac
  [ \$((now - seen)) -ge "\$GRACE" ] || continue

  # THE AGENT GOES DOWN FIRST, and that is what makes the reset below safe
  # rather than merely likely to be safe. With the unit stopped no job can be
  # assigned to this slot at all, so the tree is not being replaced under one
  # that arrived while the checks above were running.
  #
  # It does not close the window entirely, and the same limit is already
  # recorded on the reserved-slot stop in the pin sweep: a job that arrives
  # between the pgrep and the stop is killed by the stop. That is one job, on a
  # slot that has been dirty and idle for a minute, against a slot that
  # otherwise fails every job it is ever handed. What must not happen is the
  # reset running UNDER a live job, so the worker is asked for a second time
  # once the stop has returned.
  was_active=0
  [ "\$state" = active ] && was_active=1
  if [ "\$was_active" = 1 ] &&
    ! systemctl stop "ci-runner@\$idx.service" >/dev/null 2>&1; then
    say "slot \$idx: is dirty and idle but its agent would not stop — leaving it for the next sweep"
    continue
  fi
  if pgrep -u "\$u" -f 'Runner\.Worker' >/dev/null 2>&1; then
    say "slot \$idx: a job is still on it after the agent was stopped — refusing to reset underneath one"
    [ "\$was_active" = 1 ] &&
      { systemctl start "ci-runner@\$idx.service" >/dev/null 2>&1 ||
        say "slot \$idx: and it did not come back up — the next sweep retries"; }
    continue
  fi

  reset_ok=0
  if /opt/ci/job-hooks/slot-reset.sh completed "\$idx" >/dev/null 2>&1; then
    reset_ok=1
    rm -f -- "\$since"
    say "slot \$idx: was left dirty by a job that never completed — reset with no job on it; the next job takes the ordinary path"
  else
    # The marker is withheld by the reset itself, which is the correct outcome
    # and not a second failure to handle here: the slot stays dirty, the started
    # hook goes on refusing it, and this sweep tries again in thirty seconds.
    # The clock is deliberately NOT cleared, so the retry is immediate.
    say "slot \$idx: dirty and idle, but the reset did not finish — it stays dirty and the next sweep retries"
  fi

  # CONDEMNATION. Everything above retries forever, and forever is the bug: a
  # slot whose reset can never finish stays dirty, so the started hook goes on
  # failing every job it is handed, and it is handed a lot of them because
  # failing takes six seconds. Past CONDEMN_MAX the slot stops being offered
  # work at all — its agent is simply not started again below.
  #
  # A slot serving nothing is strictly better than a slot serving six-second
  # failures, and it is also the state the rest of the fleet can already SEE: a
  # stopped agent leaves the repository's runner list, the controller's
  # host_facts() reads the host as short of slots, and that gap is published as
  # ci_slots_missing. No new call, no new attribute, and it covers the two
  # neighbouring shapes as well — a host that registered nothing (#130) and a
  # host whose slot units never started (#268).
  #
  # Not disabled, not deleted: the next tick tries the reset again, so a slot
  # whose obstruction clears — a wedged container finally reaped, a disk that
  # came back — recovers on its own.
  burns=""
  [ -f "\$dir/burns" ] && read -r burns <"\$dir/burns" 2>/dev/null
  case "\$burns" in '' | *[!0-9]*) burns=0 ;; esac

  if [ "\$reset_ok" = 0 ] && [ "\$burns" -ge "\$CONDEMN_MAX" ]; then
    if [ ! -f "\$dir/condemned" ]; then
      : >"\$dir/condemned" 2>/dev/null || say "slot \$idx: could not record that it is condemned"
      say "slot \$idx: \$burns consecutive failures to reach a clean state — taking it out of service rather than letting it keep winning jobs it will burn"
    fi
    continue
  fi

  if [ "\$reset_ok" = 1 ] && [ -f "\$dir/condemned" ]; then
    rm -f -- "\$dir/condemned"
    say "slot \$idx: clean again after being condemned — putting it back into service"
    was_active=1
  fi

  # Back into the pool either way. A slot left down by a failed reset would be
  # capacity lost to the bookkeeping rather than to the fault, and the marker is
  # what keeps a job from running on it — not the agent being absent.
  if [ "\$was_active" = 1 ] &&
    ! systemctl start "ci-runner@\$idx.service" >/dev/null 2>&1; then
    say "slot \$idx: reset, but its agent would not start again — the next sweep retries"
  fi
done

exit 0
EOF
  # Checked, not trusted, and for the reason install_job_hooks records: an
  # unescaped name in the body above aborts the expansion AFTER the redirect has
  # truncated the file, leaving a zero-byte script with the right owner and mode
  # that systemd reports as 203/EXEC.
  [ -s /opt/ci/job-hooks/slot-sweep.sh ] ||
    { log "slot-sweep.sh came out empty -- a name in its here-document did not expand"; return 1; }
  bash -n /opt/ci/job-hooks/slot-sweep.sh ||
    { log "slot-sweep.sh is not parseable -- refusing to install it"; return 1; }
  chown root:root /opt/ci/job-hooks/slot-sweep.sh || return 1
  chmod 0755 /opt/ci/job-hooks/slot-sweep.sh || return 1

  cat >/etc/systemd/system/ci-slot-sweep.service <<'EOF'
[Unit]
Description=Reset this host's dirty slots while no job is on them

[Service]
Type=oneshot
# A oneshot with no deadline blocks its own timer forever, and this one calls a
# reset that tears down containers under three timeouts of its own, once per
# slot. Generous enough that a busy host finishes, bounded so a single wedged
# docker call cannot stop every later sweep on this host -- which would leave
# the dirty slots this exists to clear dirty for the life of the host.
TimeoutStartSec=900
ExecStart=/opt/ci/job-hooks/slot-sweep.sh
EOF

  # Every 30 seconds, matching the pin sweep. With GRACE at two ticks a slot
  # left dirty is back in ordinary service inside about a minute and a half,
  # against never.
  cat >/etc/systemd/system/ci-slot-sweep.timer <<'EOF'
[Unit]
Description=Sweep this host's dirty idle slots every 30 seconds

[Timer]
OnBootSec=45
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >>/var/log/ci-host.log 2>&1 || return 1
  systemctl enable --now ci-slot-sweep.timer >>/var/log/ci-host.log 2>&1 || return 1
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

# The registry credential-helper map, written to stdout so the one caller can
# put it wherever it needs it. It goes into $SLOT_TEMPLATE/.docker/config.json
# and from there into every slot's home, because docker reads ~/.docker from the
# HOME of whoever runs the client and every slot is its own user — but the
# CONTENT is identical for every slot on the host, so there is one copy to be
# right rather than K.
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
write_docker_cred_helpers() {
  local hosts h first

  hosts="gcr.io us.gcr.io eu.gcr.io asia.gcr.io"
  [ -n "$HOST_REGION" ] && hosts="$hosts ${HOST_REGION}-docker.pkg.dev"
  [ -n "$REGISTRY_HOSTS" ] && hosts="$hosts $(printf '%s' "$REGISTRY_HOSTS" | tr ',' ' ')"

  printf '{\n  "credHelpers": {\n'
  first=1
  for h in $hosts; do
    [ -n "$h" ] || continue
    [ "$first" = 1 ] || printf ',\n'
    printf '    "%s": "cijob"' "$h"
    first=0
  done
  printf '\n  }\n}\n'
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
# ...and both of those files now live in the TEMPLATE rather than being written
# into each home directly, because the home is emptied between jobs (#110). The
# template is what a slot is built from at boot and rebuilt from on every reset,
# so anything a slot must have is here or it does not survive the first job.
seed_slot_template() {
  local mtu
  mtu=$(primary_mtu)
  [ -n "$mtu" ] || return 1

  # Rebuilt from scratch on every boot rather than updated in place. This tree
  # is on the boot disk of a host that reboots warm, so an entry left behind by
  # an OLDER version of this script would otherwise be copied into every slot's
  # home, on every reset, for the life of the host.
  rm -rf "$SLOT_TEMPLATE" || return 1
  install -d -o root -g root -m 0755 "$SLOT_TEMPLATE" || return 1

  # What `useradd -m` would have copied, so a slot's shell behaves the way the
  # image says it should. Taken from the image rather than written here — the
  # distro owns these files and a second inline copy is a second thing to keep
  # in step. ~/.bashrc and ~/.profile are two of the four plant sites #110
  # names, which is exactly why their content now comes from a root-owned tree
  # instead of from whatever the last job left.
  [ ! -d /etc/skel ] || cp -a /etc/skel/. "$SLOT_TEMPLATE/" || return 1

  install -d -o root -g root -m 0700 "$SLOT_TEMPLATE/.docker" || return 1
  write_docker_cred_helpers >"$SLOT_TEMPLATE/.docker/config.json" || return 1
  chmod 0600 "$SLOT_TEMPLATE/.docker/config.json" || return 1

  install -d -o root -g root -m 0700 "$SLOT_TEMPLATE/.config" || return 1
  install -d -o root -g root -m 0700 "$SLOT_TEMPLATE/.config/docker" || return 1
  printf '{\n  "mtu": %s,\n  "default-network-opts": {\n    "bridge": { "com.docker.network.driver.mtu": "%s" }\n  }\n}\n' \
    "$mtu" "$mtu" >"$SLOT_TEMPLATE/.config/docker/daemon.json" || return 1
  chmod 0600 "$SLOT_TEMPLATE/.config/docker/daemon.json" || return 1
}

# --- the dependency cache -----------------------------------------------------
#
# The golden image creates /opt/ci-cache, but until this layer existed nothing on
# the host ever told a package manager the directory was there. The image's own
# description promised "pre-warmed caches" while `packer/warm-cache/none.sh`
# warmed nothing and no job could have used the result anyway: npm still wrote
# ~/.npm, Go still wrote ~/go/pkg/mod, and both live in a slot HOME that is
# private per slot and destroyed with the host. So every job on every host
# re-downloaded the same dependency set, which is precisely the per-job cost this
# pool exists to delete (docs/ci-optimization-catalog.md §4.2, priority 10).
#
# THE SHAPE OF THIS, AND WHY IT IS NOT ONE SHARED DIRECTORY.
#
# The obvious design — one tree, group `ci`, group-writable, every slot pointed at
# it — is the one the image was already built for, and it is not defensible. Every
# directory below is a place its own tool treats as ALREADY-VERIFIED input:
# `npx` executes straight out of the npm cache, Maven skips checksum verification
# for an artifact already in the local repository, pip does not re-hash a cached
# wheel, NuGet verifies signatures on restore from the feed and not on a package
# already extracted. So a writable shared tree is not a cache — it is a channel by
# which one slot hands another slot code to run, as that slot's user, with that
# slot's token. pnpm and uv make it worse rather than better: they HARDLINK from
# the store into the workspace, so the two slots hold the same inode and a check
# one slot performs can be invalidated by the other after it passed.
#
# That channel would cross the boundary the rest of this script exists to build —
# separate uid, separate netns, separate container daemon per slot — and would
# route around all of it. "One pool serves one repository" does not rescue it: a
# fork's pull-request job and a main-branch deploy job holding the release
# credential are the same repository and run CONCURRENTLY on one host.
#
# So the tree is split in two:
#
#   * $CACHE_MASTER (/opt/ci-cache) is the shared, root-owned, READ-ONLY master.
#     It is what the image warms and what a future snapshot layer hydrates. No
#     slot can write anywhere in it.
#   * $CACHE_SLOTS/<idx> is one writable cache per slot, COPIED from the master
#     and owned outright by that slot.
#
# A real copy, and not the hardlink copy (`cp -al`) that this obviously wants to
# be. Hardlink seeding gets the security property for free — a shared root-owned
# 0444 inode cannot be written by a slot that owns only the directory entry — and
# it costs directory entries instead of bytes, so it was the first design here.
# It does not work, for a reason worth writing down so nobody re-derives it:
#
#   `fs.protected_hardlinks=1` is the Ubuntu default, and it forbids an
#   unprivileged process from creating a hardlink to a file it does not own
#   unless it has BOTH read and write access to it. pnpm and uv exist to hardlink
#   content out of their store into the workspace. A root-owned 0444 seeded file
#   is readable and not writable, so every one of those links fails with EPERM —
#   the tools are locked out of precisely the content the seeding exists to give
#   them. Turning the sysctl off to make it work would remove a protection this
#   multi-tenant host wants more than it wants the disk saving.
#
# So each slot gets its own bytes. Every tool then sees exactly what it sees on an
# ordinary single-user machine — its own cache, owned by the user running it, with
# no permission special case anywhere — which is also why this needs no per-tool
# verification of what tolerates a foreign-owned entry. The price is disk: K slots
# hold K copies, and the master is now warmed from a snapshot rather than only by
# what the image baked, so `boot_disk_size_gb` has to carry K+1 of them.
CACHE_MASTER="/opt/ci-cache"
CACHE_SLOTS="/var/lib/ci-cache"

# Where a downloaded snapshot is unpacked and inspected before any of it is
# allowed into the master. Under /opt and NOT under $CACHE_MASTER: the master is
# scanned as a whole, and a staging tree inside it would be scanned along with
# it — so a snapshot that failed inspection would still have made the master
# hostile, and the boot would refuse to seed from a cache that was fine until the
# rejected content was unpacked into it.
CACHE_STAGE="/opt/.ci-cache-incoming"

# One subdirectory per tool, named for the tool rather than for the language, so
# a tree lifted off a host is self-describing.
CACHE_DIRS=(npm yarn pnpm-store go-mod pip uv m2 nuget composer)

# How far a snapshot is allowed to expand, and why it has a floor.
#
# Eight times the compressed size is the ratio, and the ratio is not arbitrary:
# the archive, the tree it unpacks to and the tree already in the master all sit
# on this disk at once, and a dependency cache compresses about threefold.
#
# But tar's default blocking factor is 20 512-byte records, so no archive is
# shorter than 10240 bytes however little it holds, and the nine directories
# above already cost 4608 bytes of headers before one file goes in. Scaled all
# the way down, the bound lands BELOW what a valid, nearly-empty archive weighs:
# a tree that gzips to 400 bytes gets a 3200-byte bound and `head` cuts the stream
# mid-archive. What happens next is worse than a wrong refusal. Measured on GNU
# tar 1.35: cut the stream at a member boundary and the rest of tar's 10240-byte
# record reads as zeros, two zero blocks are how an archive says it ended, and tar
# extracts the PREFIX and exits 0 — no warning, no non-zero status. A nine-
# directory tree cut at 2256 bytes yields four of the nine and a clean exit. So a
# too-small bound does not reliably refuse the snapshot; it silently hydrates part
# of one and reports success. The floor keeps the ratio governing everything that
# matters — a real snapshot is tens of megabytes — while no archive is ever cut
# for being short. 64 KiB is six times tar's minimum and far below any tree with a
# dependency in it.
#
# The floor is not the whole answer, only the part that keeps small archives out
# of the truncating case at all. Because tar's status cannot be trusted to report
# a cut, the unpack below is preceded by a COUNT: see hydrate_shared_cache_bounded.
#
# The publisher applies the identical bound (`scripts/ci/publish-cache-snapshot.sh`)
# so that what it accepts and what a host accepts are the same set. The two
# copies must not drift, and the self-test asserts both.
CACHE_EXPAND_FLOOR_BYTES=65536
cache_expand_bound() { # <compressed bytes>
  local bound=$(($1 * 8))
  [ "$bound" -ge "$CACHE_EXPAND_FLOOR_BYTES" ] || bound=$CACHE_EXPAND_FLOOR_BYTES
  printf '%s' "$bound"
}

# THE RULE THIS WHOLE SECTION IS BUILT ON: root never operates on a path inside a
# directory an untrusted uid controls.
#
# That is the accurate form of a rule which is usually stated wrongly, including
# in an earlier revision of this file. The folklore version — "`chown -R` follows
# symlinks, so add -h" — is backwards on both halves. GNU chown walks with
# FTS_PHYSICAL as soon as -R is given (coreutils src/chown.c), so the RECURSIVE
# form has never dereferenced and -h adds nothing to it. The form that DOES
# dereference is the plain, non-recursive one: `chown u:g some/path` where
# `some/path` is a symlink re-owns the referent. So the dangerous call is the
# innocuous-looking single chown, not the scary-looking recursive one — and no
# flag makes it safe if the attacker can swap the name out from under it between
# the check and the call.
#
# The structural fix is therefore ownership of the NAMESPACE, not flags on the
# call. Every directory in which this script creates, renames or chowns an entry
# is root-owned; a slot user owns only the leaves it needs to write:
#
#   $CACHE_MASTER (/opt/ci-cache)   root, read-only, shared, never slot-writable
#   $CACHE_SLOTS  (/var/lib/ci-cache)        root 0755 — traversal only
#   $CACHE_SLOTS/<idx>                       root 0755 — root's work area
#   $CACHE_SLOTS/<idx>/<tool>                slot 0700 — the writable cache
#
# A slot can do anything it likes inside its own <tool> directories and cannot
# create, delete or replace a name in the directory above them. Every root
# operation below therefore happens in a namespace no slot can race.

# Refuse the master outright if it holds anything a root-run recursive walk, or a
# later `cp -a`, must not propagate. This is not defensive decoration: the script
# is the instance's startup-script, it runs on EVERY boot over a /opt/ci-cache
# that lives on the boot disk and survives a reset, and images before v5.12.0 ship
# that tree group-writable — so its contents are, historically, attacker-writable
# input.
#
# Deliberately NOT -xdev. Skipping other filesystems would let a bind mount under
# the cache hide entries from the scan while `chown -R`/`chmod -R` below still
# descend into it and re-own it. chmod has no --one-file-system at all, so the
# scan and the walk cannot be given matching scopes; scanning everything the walk
# will touch is the half that can actually be made true.
#
# Takes the tree to scan, defaulting to the master. It is called on TWO trees and
# that is the point of the argument: once on a freshly unpacked snapshot, before
# a byte of it reaches the master, and once on the master itself at lock time. The
# second is not redundant — the master also carries whatever the image baked and
# whatever survived the last boot, and the tree a snapshot lands in is exactly the
# tree this refuses to distribute.
#
# In `strict` mode each walk is also bounded by whatever is left of the hydrate's
# deadline, and running out is a refusal. A scan is three full tree walks, and a
# snapshot of many millions of tiny files passes both the compressed-size and the
# unpacked-size bounds while costing minutes of `getcap -r` — the delay the whole
# budget exists to prevent, reached by going around it rather than through it. The
# master's own scan is not bounded: it is the tree this host already has, and
# refusing it for being slow would cost every slot its cache for no gain.
cache_scan() { # <seconds-or-0> <cmd...>
  local limit="$1"; shift
  if [ "$limit" -gt 0 ]; then timeout "$limit" "$@"; else "$@"; fi
}

cache_master_is_hostile() { # [<tree>] [strict]
  local bad ino root="${1:-$CACHE_MASTER}" limit=0
  if [ "${2:-}" = "strict" ]; then
    limit=$(( ${CACHE_DEADLINE:-0} - $(date +%s) ))
    [ "$limit" -gt 0 ] || limit=1
  fi
  # Symlinks and setuid/setgid bits are the obvious two. The rest are here
  # because `chmod -R go+rX` WIDENS permissions and `cp -a` preserves: an
  # unreadable /etc/shadow does not stay unreadable if something links it in
  # here, and device, fifo and socket nodes have no business in a dependency
  # cache. The hardlink case is NOT in this predicate — see the pass below.
  # `-printf '%y %M %p'` and not `-print`, because the refusal has to say WHICH
  # of those predicates matched. Six predicates share one message, and the one
  # that actually fired here was `-perm /6000` on the tree ROOT — an image that
  # shipped /opt/ci-cache as `drwxrwsr-x runner:ci` rather than root-owned 0755.
  # `refusing /opt/ci-cache: it holds a link, node or setuid entry
  # (/opt/ci-cache)` names the path twice and the cause not at all, so the whole
  # pool ran cold while the log said something that read like a content problem.
  # The type letter and the mode string cost nothing and answer it outright:
  # `d drwxrwsr-x /opt/ci-cache`.
  #
  # GNU find, which is what the image ships and what packer's copy of this scan
  # already assumes; this script runs on the Linux pool only.
  bad=$(cache_scan "$limit" find "$root" \
    \( -type l -o -type b -o -type c -o -type p -o -type s -o -perm /6000 \) \
    -printf '%y %M %p\n' -quit 2>/dev/null) || {
    log "refusing $root: it could not be scanned inside the remaining budget"
    return 0
  }
  if [ -n "$bad" ]; then
    log "refusing $root: it holds a link, node or setuid entry ($(safe_for_log "$bad"))"
    return 0
  fi
  # HARDLINKS, COUNTED RATHER THAN FORBIDDEN.
  #
  # The danger is a hardlink whose OTHER name is outside the tree: `chmod -R
  # go+rX` widens the inode in place, so linking in something unreadable
  # publishes it. A link count above one is not that danger, though, and the
  # old `-links +1` predicate could not tell the two apart. A content-addressed
  # store that hardlinks internally — pnpm's does exactly this — and any warm
  # script that populated the master with `cp -al` both tripped it, and the
  # refusal is silent in job output: the pool just runs cold, which nobody
  # watches per job. Over-blocking a security check into permanent uselessness
  # is a worse outcome than the check not existing.
  #
  # The exact question is answerable and cheap. Count how many of an inode's
  # names live inside the tree and compare with its link count: equal means
  # every name is in here and `chmod` reaches all of them, fewer means at least
  # one name is somewhere this tree does not own. Measured on a live host, a
  # full walk of 61k files costs 0.2s, so this is not worth an early exit.
  #
  # The counting pass prints NO paths — only two integers per name — because a
  # path may contain a newline and would split one record into two, corrupting
  # the counts. The offending path is looked up afterwards, by inode, and only
  # on the refusal path.
  ino=$(cache_scan "$limit" find "$root" -type f -links +1 -printf '%n %i\n' 2>/dev/null \
    | awk '{ n[$2] = $1; c[$2]++ } END { for (i in c) if (c[i] < n[i]) { print i; exit } }') || {
    log "refusing $root: it could not be scanned for hardlinks inside the remaining budget"
    return 0
  }
  if [ -n "$ino" ]; then
    bad=$(cache_scan "$limit" find "$root" -inum "$ino" -printf '%y %M %p\n' -quit 2>/dev/null) \
      || bad="inode $ino"
    log "refusing $root: it holds a hardlink to a file outside the tree ($(safe_for_log "$bad"))"
    return 0
  fi
  # File capabilities are invisible to -perm, and `cp -a` copies xattrs, so a
  # cap_setuid binary in the master would land in every slot's cache with its
  # capability intact. getcap is in libcap2-bin and present on the image; if it
  # ever is not, that is a gap to see in the log rather than to skip silently.
  if command -v getcap >/dev/null 2>&1; then
    # No pipe into head: this script runs under `set -o pipefail`, and head
    # closing the pipe early can SIGPIPE getcap.
    bad=$(cache_scan "$limit" getcap -r "$root" 2>/dev/null) || {
      log "refusing $root: it could not be scanned for file capabilities inside the remaining budget"
      return 0
    }
    if [ -n "$bad" ]; then
      log "refusing $root: it holds a file capability ($(safe_for_log "$bad"))"
      return 0
    fi
  elif [ "${2:-}" = "strict" ]; then
    # For the baked master a missing getcap is a gap worth seeing in the log: that
    # tree was produced by a reviewed image build, so the scan is a second opinion.
    # For a snapshot it is the ONLY opinion — nothing reviewed stands in front of
    # it — and a check that can be skipped rather than failed is not a bound. So
    # the caller that hands this untrusted content says `strict`, and an
    # unscannable tree is a refused tree.
    log "refusing $root: getcap is not installed, so it cannot be scanned for file capabilities"
    return 0
  else
    log "getcap not installed — $root not scanned for file capabilities"
  fi
  # A dependency cache holds content addressed by hash, never credentials. If a
  # consumer's warm script left one behind, `chmod -R go+rX` would publish it to
  # every uid on the host and `cp -a` would then hand a copy to every slot. Refuse
  # rather than distribute it.
  #
  # BOUNDED TO THE TOP OF THE TREE, and the bound is what lets the name list be
  # honest. Unbounded, this pass reads inside extracted package payloads, where
  # a `.npmrc` or a `.pem` is a dependency's own test fixture rather than a leak
  # — Yarn Classic extracts tarballs into its cache, so one package shipping one
  # such file takes every host on every pool cold, and the symptom is a slow
  # pool that nobody watches per job. A check that fires on correct content gets
  # deleted, and then the real leak has nothing standing in front of it.
  #
  # Depth matches the threat. What this defends against is a warm script that
  # dropped a credential where it works from: the cache root or a tool's own
  # directory. That is depth 1 to 3. Nothing at that depth is package payload —
  # measured on a live host, the whole tree above depth 3 is twelve entries and
  # every one of them is a tool directory — so at this depth a match is a leak
  # and refusing the whole master is the proportionate answer. Deeper than that,
  # a match is somebody else's fixture and refusing the master is not.
  bad=$(cache_scan "$limit" find "$root" -maxdepth 3 -type f \( \
      -name '.npmrc' -o -name '.yarnrc' -o -name '.yarnrc.yml' -o -name '.netrc' \
      -o -name '.pypirc' -o -name '.git-credentials' -o -name 'auth.json' \
      -o -name 'settings.xml' -o -iname 'nuget.config' -o -name 'credentials' \
      -o -name '.dockercfg' -o -name '.pgpass' -o -name 'pip.conf' -o -name '.env' \
      -o -name 'gradle.properties' -o -name 'application_default_credentials.json' \
      -o -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ecdsa' -o -name 'id_ed25519' \
      -o -name '*.pem' \
    \) -print -quit 2>/dev/null) || {
    log "refusing $root: it could not be scanned for credential files inside the remaining budget"
    return 0
  }
  if [ -n "$bad" ]; then
    log "refusing $root: it holds what looks like a credential file ($(safe_for_log "$bad"))"
    return 0
  fi
  return 1
}

# --- the snapshot the image did not bake ----------------------------------------
#
# The baked master is as old as the image. A pool that scales out under load —
# which is the only time it scales out — hands every new host a cache from
# whenever the image was cut, and the queue that caused the scale-out is served
# by the coldest hosts in the fleet. The snapshot closes that gap: a small,
# regularly published tarball of the same tree, unpacked over the baked one at
# boot.
#
# FOUR PROPERTIES, AND EACH IS LOAD-BEARING.
#
# 1. READ ONLY, ALWAYS. This host never writes to the bucket, and its service
#    account is granted `roles/storage.objectViewer` conditioned on this pool's
#    prefix — no create, no delete, no other pool. A host executes job code, so a
#    host that could publish would let whatever one job left in a cache become
#    the starting cache of every later host in the pool: the cross-slot channel
#    the per-slot copy closes, re-opened across hosts and across time. The
#    publisher is a separate identity that never runs pull-request code.
#
# 2. BOUNDED, THEN ABANDONED. Everything here runs against one deadline. A slow
#    or missing snapshot costs the FIRST job on this host a cold cache; a host
#    that waits on it costs the pool a host, and the pool answers a missing host
#    by queueing jobs. So the budget is small and every failure returns.
#
# 3. AGED OUT HERE TOO. The bucket deletes snapshots at its own age bound, and
#    this refuses one older than its own limit. Two bounds because they fail
#    differently: the bucket's holds if this script is broken, this one holds if
#    the lifecycle rule is edited away in the console — and lifecycle deletion is
#    asynchronous, so the bucket's bound alone is soft by up to a day.
#
# 4. INSPECTED BEFORE IT IS TRUSTED. What arrives is untrusted build input that
#    did not pass through the image build's gate, so it passes through the same
#    scan at boot, in a staging tree, before anything reaches the master. The
#    scan is cache_master_is_hostile() and this is the reason it takes an
#    argument.

# Fetch one object from this pool's prefix. Storage JSON API rather than
# `gcloud storage`: it is one curl against a documented URL with the instance's
# own token, with no dependency on which gcloud is on the image and no config
# directory to leave behind.
cache_fetch() { # <object-suffix> <dest> <seconds> [<query>] [<max-bytes>]
  # Only `/` needs encoding. Every name reaching here is either this script's own
  # literal or has been matched against a whitelist that permits nothing else
  # outside [A-Za-z0-9._-], which is why a general percent-encoder is not needed
  # and its absence is not a gap.
  local enc
  enc=$(printf '%s%s' "$CACHE_PREFIX" "$1" | sed 's|/|%2F|g')
  [ "$3" -gt 0 ] || return 1
  # THE TOKEN IS NOT AN ARGUMENT, AND THAT IS A SECURITY PROPERTY, NOT A STYLE.
  # `-H "Authorization: Bearer $CACHE_TOKEN"` would put the instance's own
  # cloud-platform token in this process's argv, and /proc/<pid>/cmdline is
  # world-readable: a job step running as a slot user reads it with `cat`. That
  # token is the HOST identity — it impersonates the job account and reads the
  # GitHub App key out of Secret Manager — and the per-uid REJECT to the metadata
  # server exists precisely so job code cannot obtain it. Handing it over in argv
  # would route around that rule. Startup and the slot agents are not ordered
  # against each other, so on a reboot of a warm host this runs while jobs run.
  #
  # So it goes over a pipe: curl reads its config from a file descriptor, and
  # /proc/<pid>/fd of a root process is root-only. `printf` is a shell builtin, so
  # the subshell never execs anything that could carry the token in ITS argv
  # either. No temp file, so nothing to leave behind or to race.
  #
  # --max-filesize bounds the response before it lands on disk. Without it the
  # only bound on a response is the deadline, and /opt is what fills.
  #
  # `Accept-Encoding: gzip` is not an optimisation. An object stored with
  # `Content-Encoding: gzip` is decompressively transcoded by the service unless
  # the client says it accepts gzip, and a transcoded response arrives chunked
  # with no Content-Length — which is the one case --max-filesize cannot bound in
  # advance. Asking for gzip means the bytes arrive exactly as stored, so the
  # size the metadata reported is the size that lands.
  curl --connect-timeout 5 --max-time "$3" -fsS \
    --max-filesize "${5:-65536}" \
    -K <(printf 'header = "Authorization: Bearer %s"\nheader = "Accept-Encoding: gzip"\n' "$CACHE_TOKEN") \
    -o "$2" \
    "https://storage.googleapis.com/storage/v1/b/$CACHE_BUCKET/o/$enc${4:-?alt=media}" \
    2>/dev/null
}

# The token outlives no more of this script than it has to. hydrate_shared_cache
# has a dozen early returns and each one would need its own `unset`, so the
# clearing happens here, once, on every path out — including the ones a later
# edit adds.
# WHY THE VERDICT IS PUBLISHED HERE AND NOT AT THE RETURN THAT DECIDED IT.
#
# The body has a dozen early returns, and the layer fails open, so all but one
# of them log a line and return 0. That is the whole diagnostic problem: from
# outside, a pool whose snapshot expired, a pool whose bucket was never
# configured and a pool whose every host times out on the download are the same
# observable — jobs that are slower than they were, and nothing red anywhere.
#
# So each return states its verdict in a variable and this wrapper publishes it,
# once, on every path out — including the ones a later edit adds. The same
# argument as the `unset` below, for the same reason: a rule that has to be
# repeated at every return is a rule that will be missed at the next one.
hydrate_shared_cache() {
  local rc=0
  CACHE_VERDICT=""
  CACHE_STARTED=$(date +%s)
  hydrate_shared_cache_bounded || rc=$?
  publish_cache_telemetry
  unset CACHE_TOKEN CACHE_DEADLINE CACHE_VERDICT CACHE_STARTED \
        CACHE_SNAP_AGE_HOURS CACHE_SNAP_BYTES CACHE_DIRS_MOVED
  return "$rc"
}

# One point per series, one flush, and never a reason to fail the boot. A host
# that cannot publish still registers: the metric exists to explain a slow pool,
# and refusing to serve jobs because the explanation did not send would be the
# monitoring deciding the availability.
publish_cache_telemetry() {
  # All four, not just the two the URL needs: POOL and REPO_FULL are the resource
  # labels, and an empty one produces a request the API rejects whole — one
  # missing metadata read would drop every series in this flush and log a 400
  # nobody reads, rather than skipping cleanly.
  [ -n "${METRIC_PREFIX:-}" ] && [ -n "${PROJECT:-}" ] \
    && [ -n "${POOL:-}" ] && [ -n "${REPO_FULL:-}" ] || return 0

  # An empty verdict means the function returned through a path that states
  # none, which is a bug in this file rather than a state of the cache. Named
  # rather than dropped, because a verdict that silently stops being published
  # looks exactly like a pool that stopped hydrating.
  queue_series "ci_cache_hydrate_verdict" 1 \
    "\"verdict\":\"$(ts_label_value "${CACHE_VERDICT:-unset}")\""
  queue_series "ci_cache_hydrate_seconds" "$(( $(date +%s) - CACHE_STARTED ))"
  # Age, size and count are only published when a snapshot was actually read.
  # A zero on a pool with no bucket configured would sit in the same series as a
  # zero on a pool whose snapshot is fresh, and an alert cannot tell those apart.
  [ -n "${CACHE_SNAP_AGE_HOURS:-}" ] \
    && queue_series "ci_cache_snapshot_age_hours" "$CACHE_SNAP_AGE_HOURS"
  [ -n "${CACHE_SNAP_BYTES:-}" ] \
    && queue_series "ci_cache_snapshot_bytes" "$CACHE_SNAP_BYTES"
  [ -n "${CACHE_DIRS_MOVED:-}" ] \
    && queue_series "ci_cache_dirs_hydrated" "$CACHE_DIRS_MOVED"

  flush_series || log "cache telemetry did not publish — the hydrate itself was unaffected"
  return 0
}

hydrate_shared_cache_bounded() {
  local bucket_rc=0
  CACHE_BUCKET=$(md "instance/attributes/ci-cache-bucket") || bucket_rc=$?
  if [ -z "${CACHE_BUCKET:-}" ]; then
    # `md` returns an empty string for BOTH "the attribute is not set" and "the
    # metadata server did not answer", and those are opposite facts: the first is
    # the correct steady state of a pool that never wanted this layer, and the
    # alert on hydrate failures excludes it for exactly that reason. Reported the
    # same way, a metadata read that failed at boot would file itself into the
    # silenced bucket — a pool with a bucket configured, hydrating nothing,
    # reporting the verdict that means "nothing to do".
    #
    # The exit code already carries the distinction, with no second call. `md`
    # returns curl's status, and `-f` gives 22 for an HTTP 404 — the attribute
    # is genuinely not set — where a DNS failure, a refused connection or a
    # timeout give 6, 7 and 28. A second probe cannot do better and is wrong in
    # the common case: one transient failure followed by a probe that succeeds a
    # moment later — which is what "transient" means — still reported
    # not-configured. It also cost up to 30 seconds of boot before `deadline` was
    # computed, so the hydrate's own budget did not cover it.
    #
    # The sustained case this was written for is mostly unreachable anyway: a
    # metadata server already dead at boot makes this script `die` a thousand
    # lines above, and `flush_series` mints its token from the same server, so a
    # correct no-metadata-server verdict cannot be delivered regardless.
    # 0 as well as 22: an attribute that exists and is empty is a pool that did
    # not configure this layer, exactly like one with no attribute at all. Only a
    # code that says the REQUEST failed may claim the server is unreachable.
    if [ "$bucket_rc" = 22 ] || [ "$bucket_rc" = 0 ]; then
      CACHE_VERDICT="not-configured"
      log "no snapshot bucket configured — this host runs on the cache its image baked"
    else
      CACHE_VERDICT="no-metadata-server"
      log "metadata server unreachable — cannot tell whether a snapshot bucket is configured"
    fi
    return 0
  fi
  CACHE_PREFIX=$(md "instance/attributes/ci-cache-prefix")
  # The prefix is what the read grant is conditioned on, so an empty one is not a
  # harmless default: it would send every request outside the condition, and the
  # 403s would read as "the snapshot is missing" in the log rather than as a
  # misconfigured pool.
  case "$CACHE_PREFIX" in
    */) : ;;
    *) CACHE_VERDICT="bad-prefix"; log "cache prefix '${CACHE_PREFIX:-}' is not a directory prefix — skipping hydrate"; return 0 ;;
  esac

  local budget max_age_hours max_bytes
  budget=$(md "instance/attributes/ci-cache-budget-seconds")
  max_age_hours=$(md "instance/attributes/ci-cache-max-age-hours")
  max_bytes=$(md "instance/attributes/ci-cache-max-bytes")
  # Defaults live in Terraform, which validates them. These exist for the host
  # that boots from an older template, where the key is simply absent.
  case "$budget" in ''|*[!0-9]*) budget=60 ;; esac
  case "$max_age_hours" in ''|*[!0-9]*) max_age_hours=168 ;; esac
  case "$max_bytes" in ''|*[!0-9]*) max_bytes=4294967296 ;; esac
  # The same ranges Terraform validates, applied again here, because metadata is
  # not only written by Terraform: anyone who can set an instance's metadata can
  # set `ci-cache-budget-seconds` to a number that holds registration open for as
  # long as they like. A shape check alone accepts that number.
  [ "$budget" -ge 10 ] || budget=10
  [ "$budget" -le 300 ] || budget=300
  [ "$max_age_hours" -ge 1 ] || max_age_hours=1
  [ "$max_age_hours" -le 720 ] || max_age_hours=720
  [ "$max_bytes" -ge 1048576 ] || max_bytes=1048576
  [ "$max_bytes" -le 34359738368 ] || max_bytes=34359738368

  local started deadline
  started=$(date +%s)
  deadline=$((started + budget))
  # A global, because the inspection is bounded by the same deadline and it runs
  # inside a function shared with the master's own lock. Cleared by the wrapper.
  CACHE_DEADLINE=$deadline

  CACHE_TOKEN=$(md "instance/service-accounts/default/token" \
    | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "${CACHE_TOKEN:-}" ]; then
    CACHE_VERDICT="no-token"
    log "no instance token — skipping cache hydrate"
    return 0
  fi

  local tmp
  tmp=$(mktemp -d /opt/.ci-cache-dl.XXXXXX) || { CACHE_VERDICT="no-scratch"; return 0; }
  # Root-owned 0700 from creation. Nothing else on this host may read, still less
  # substitute, a name inside the directory root is about to unpack an archive
  # into — the rule the whole cache section is built on.
  chmod 0700 "$tmp" || { CACHE_VERDICT="no-scratch"; rm -rf "$tmp"; return 0; }

  # The pointer names the current snapshot. It is a separate, tiny object because
  # the snapshots themselves must never be overwritten: the bucket measures age
  # per generation and an overwrite starts a new one at zero, so a snapshot key
  # rewritten in place would never reach the age bound and never expire.
  if ! cache_fetch "current" "$tmp/current" "$((deadline - $(date +%s)))"; then
    CACHE_VERDICT="no-snapshot"
    log "no cache snapshot published for this pool yet — running on the baked cache"
    rm -rf "$tmp"
    return 0
  fi

  local snap
  snap=$(head -n 1 "$tmp/current" | tr -d '\r\n')
  # A whitelist, not a sanitiser. The pointer is written by the trusted publisher,
  # but it is still the one input here that names a path, and this is what keeps
  # it from naming anything but a snapshot in this pool's own prefix: no `/`, so
  # no traversal and no other pool; no `..`; nothing outside a character set that
  # needs no encoding.
  case "$snap" in
    *[!A-Za-z0-9._-]* | '' | .* )
      # The rejected name is NOT echoed. It is the one fully attacker-controlled
      # string here, it has not been validated at the point this line runs, and
      # this log goes to a file an operator reads in a terminal.
      CACHE_VERDICT="bad-pointer"
    log "the cache pointer does not name a snapshot in this pool's prefix (${#snap} bytes) — ignoring it"
      rm -rf "$tmp"
      return 0
      ;;
  esac

  # Size and creation time from the service, not from the name. A timestamp
  # encoded in the object name is written by whoever wrote the object;
  # `timeCreated` is the service's own record of the generation, and the age
  # bound is worth having only if it reads the one that cannot be backdated.
  if ! cache_fetch "$snap" "$tmp/meta" "$((deadline - $(date +%s)))" "?fields=timeCreated,size,generation"; then
    CACHE_VERDICT="unreadable"
    log "cache snapshot $snap is named by the pointer but could not be read — running on the baked cache"
    rm -rf "$tmp"
    return 0
  fi

  local created size age gen
  created=$(sed -n 's/.*"timeCreated"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/meta")
  size=$(sed -n 's/.*"size"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$tmp/meta")
  # The generation, so that what is measured is what is downloaded. Age, size and
  # free space are asserted here and the bytes arrive later; without pinning, the
  # object could be replaced in between and every one of those bounds would have
  # been checked against a generation that no longer exists. "Snapshots are
  # written once" is the publisher's convention — it is not a control this host
  # can enforce, so this host does not rely on it.
  gen=$(sed -n 's/.*"generation"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$tmp/meta")
  created=$(date -u -d "$created" +%s 2>/dev/null) || created=""
  if [ -z "$created" ] || [ -z "$size" ] || [ -z "$gen" ]; then
    CACHE_VERDICT="no-metadata"
    log "cache snapshot $snap has no readable size, generation or creation time — refusing it"
    rm -rf "$tmp"
    return 0
  fi
  age=$(( (started - created) / 3600 ))
  # Recorded before the bounds below rather than after them: the age and size of
  # a snapshot a host REFUSED are the two numbers that say why, and an alert on
  # "the snapshot is too old" cannot be written from points only fresh snapshots
  # publish.
  CACHE_SNAP_AGE_HOURS=$age
  CACHE_SNAP_BYTES=$size
  if [ "$age" -ge "$max_age_hours" ]; then
    CACHE_VERDICT="too-old"
    log "cache snapshot $snap is ${age}h old, past the ${max_age_hours}h bound — starting cold instead"
    rm -rf "$tmp"
    return 0
  fi
  if [ "$size" -gt "$max_bytes" ]; then
    CACHE_VERDICT="too-big"
    log "cache snapshot $snap is $size bytes, past the $max_bytes bound — refusing it"
    rm -rf "$tmp"
    return 0
  fi
  # Reserve exactly what the unpack below is allowed to write — see
  # cache_expand_bound. Filling the boot disk to warm a cache would cost this
  # host every job it was about to run, which is a far worse trade than starting
  # cold; reserving LESS than the unpack bound would let that happen anyway.
  local free_kb bound
  bound=$(cache_expand_bound "$size")
  free_kb=$(df -Pk /opt | awk 'NR==2 {print $4}')
  if [ -z "${free_kb:-}" ] || [ "$((free_kb * 1024))" -lt "$bound" ]; then
    CACHE_VERDICT="no-space"
    log "not enough free space on /opt for a $size byte snapshot — starting cold instead"
    rm -rf "$tmp"
    return 0
  fi

  if ! cache_fetch "$snap" "$tmp/snap.tar.gz" "$((deadline - $(date +%s)))" \
      "?alt=media&generation=$gen" "$size"; then
    CACHE_VERDICT="download-timeout"
    log "cache snapshot $snap did not download inside the ${budget}s budget — starting cold instead"
    rm -rf "$tmp"
    return 0
  fi

  rm -rf "$CACHE_STAGE"
  if ! mkdir -p "$CACHE_STAGE" || ! chmod 0700 "$CACHE_STAGE"; then
    CACHE_VERDICT="no-scratch"
    rm -rf "$tmp"
    return 0
  fi
  # --no-same-owner and --no-same-permissions: what is in the archive decides
  # nothing about ownership or mode. Everything lands root-owned under root's
  # umask, and the master's own lock re-applies the modes afterwards regardless.
  # --no-xattrs --no-acls --no-selinux for the same reason one layer down, and
  # this one is load-bearing rather than tidy: a `security.capability` xattr is
  # invisible to the mode bits, survives the `chown -Rh root:root` the master lock
  # applies, is published by `chmod -R go+rX` and is copied into every slot by
  # `cp -a`. GNU tar does not restore xattrs unless asked, so the flags change
  # nothing today — they are here so that a tar that decides otherwise, or an
  # image that ships a different tar, does not silently change what a snapshot can
  # carry. The scan below refuses capabilities as well; two layers, because the
  # scan needs a tool on the image and this does not. (`--no-selinux` is not
  # here: it is GNU-only, these images carry no SELinux, and an unknown option
  # would make tar fail on every boot — a hydrate that never works, logged as a
  # budget overrun.)
  #
  # WHAT MUST NEVER BE ADDED TO THIS LINE: `-P`/`--absolute-names`, and
  # `--keep-directory-symlink`. The staging tree is what confines an adversarial
  # archive, and it is tar's DEFAULTS that confine it — a leading `/` and a
  # leading `../` are stripped, and a directory member landing on a symlink
  # replaces it instead of following it. Each of those flags turns one of those
  # defaults off, and the scan afterwards only sees what stayed inside the tree.
  #
  # `timeout` because tar is where a large or adversarial archive spends its time,
  # and the budget has to bind the slowest step or it binds nothing. The clamp is
  # not cosmetic: a budget already spent gives a negative number, and `timeout -3`
  # is a parse error, which fails open by accident instead of on purpose.
  #
  # The decompression runs through `head -c` because `max_bytes` bounds the
  # COMPRESSED archive and gzip expands by more than a thousandfold on the right
  # input: a 4 MiB tarball can fill the boot disk, and the free-space check ahead
  # of it reserved cache_expand_bound "$size", not eight times whatever it holds.
  # Same $bound as that check, deliberately: unpacking past what was reserved is
  # the failure the reservation exists to prevent.
  #
  # But `head` closing the pipe is not, by itself, a refusal. tar exits 0 on a
  # stream cut at a member boundary — the record's zero padding reads as an
  # end-of-archive marker (see cache_expand_bound) — so a bound enforced only by
  # `head` can leave this host with a PARTIAL cache it believes is whole, and the
  # scan below would then pass on a subset of what the snapshot carries. The bound
  # is therefore decided by COUNTING the decompressed bytes first, and tar's
  # status is only the second opinion. One extra decompression pass, bounded by
  # the same number and inside the same budget.
  #
  # The counting pass's own status is kept, in a file, because it is upstream in
  # a pipe inside a command substitution and `|| true` used to eat it. `timeout`
  # exits 124 when the hydrate deadline expires mid-decompression, and a 124
  # read as success turns an UNMEASURED archive into a count that is
  # comfortably within bounds — after which the extraction below gets a fresh
  # one-second floor and tar accepts a prefix ending at a member boundary. That
  # is the partial hydrate this count exists to prevent, reached through the
  # count. A 141 is the normal over-bound case and never gets here: the byte
  # count decides that one first, above.
  local left=$((deadline - $(date +%s)))
  [ "$left" -gt 0 ] || left=1
  local expanded count_rc
  expanded=$( { timeout "$left" gzip -dc "$tmp/snap.tar.gz" 2>/dev/null; echo "$?" >"$tmp/count.rc"; } \
    | head -c "$((bound + 1))" | wc -c ) || expanded=$((bound + 1))
  count_rc=$(tr -dc 0-9 <"$tmp/count.rc" 2>/dev/null) || count_rc=''
  if [ "$expanded" -gt "$bound" ]; then
    CACHE_VERDICT="too-big-expanded"
    log "cache snapshot $snap expands past the $bound byte bound — refusing it rather than unpacking part of it"
    rm -rf "$tmp" "$CACHE_STAGE"
    return 0
  fi
  if [ "${count_rc:-}" != 0 ]; then
    case "${count_rc:-}" in
      124 | 137 )
        CACHE_VERDICT="unpack-timeout"
        log "cache snapshot $snap could not be measured inside the ${budget}s budget — starting cold rather than unpacking an archive nothing bounded"
        ;;
      * )
        CACHE_VERDICT="unreadable"
        log "cache snapshot $snap could not be decompressed to measure it (exit ${count_rc:-unknown}) — starting cold instead"
        ;;
    esac
    rm -rf "$tmp" "$CACHE_STAGE"
    return 0
  fi
  left=$((deadline - $(date +%s)))
  [ "$left" -gt 0 ] || left=1
  if ! timeout "$left" gzip -dc "$tmp/snap.tar.gz" 2>/dev/null \
      | head -c "$bound" \
      | tar -x -C "$CACHE_STAGE" \
          --no-same-owner --no-same-permissions --no-xattrs --no-acls \
          2>/dev/null; then
    CACHE_VERDICT="unpack-timeout"
    log "cache snapshot $snap did not unpack inside the ${budget}s budget — starting cold instead"
    rm -rf "$tmp" "$CACHE_STAGE"
    return 0
  fi
  rm -rf "$tmp"

  # The same scan the image build runs and the master lock runs, on content that
  # passed through neither. A snapshot is the one way into this tree that no
  # reviewed build step stands in front of.
  if cache_master_is_hostile "$CACHE_STAGE" strict; then
    CACHE_VERDICT="scan-refused"
    log "cache snapshot $snap rejected by the same scan the image build runs — starting cold instead"
    rm -rf "$CACHE_STAGE"
    return 0
  fi

  # Only the tool directories this host knows about, by name. A snapshot cannot
  # introduce a new top-level entry into the master: anything the archive holds
  # that is not one of these is dropped with the staging tree, so a name added to
  # the publisher has to be added here — and reviewed — before it can arrive.
  #
  # A directory is REPLACED rather than merged. The snapshot is produced from this
  # same image, so it is a superset of what was baked; a merge would be slower,
  # would not be atomic, and would leave entries from an expired snapshot alive in
  # the master indefinitely, which is the age bound quietly failing.
  # Unconditionally, and before the loop rather than inside it: a boot that died
  # between the aside-move and the replacement leaves one of these behind, and a
  # sweep that only runs for directories the NEXT snapshot happens to ship would
  # leave it there indefinitely — a full duplicate cache tree that lock_shared_cache
  # then publishes read-only to every uid on the host.
  local stale
  for stale in "$CACHE_MASTER"/.*.previous; do
    [ -e "$stale" ] && rm -rf "$stale"
  done

  local d took=0 n=0
  for d in "${CACHE_DIRS[@]}"; do
    [ -d "$CACHE_STAGE/$d" ] || continue
    # The baked directory is moved ASIDE, not deleted, and only dropped once its
    # replacement is in place. Deleting first is one failed rename away from a
    # host with neither copy — the snapshot path is allowed to leave the cache as
    # cold as it found it, never colder.
    if [ -d "$CACHE_MASTER/$d" ] \
       && ! mv -T "$CACHE_MASTER/$d" "$CACHE_MASTER/.$d.previous" 2>/dev/null; then
      continue
    fi
    # A rename, not a copy: same filesystem, so it costs nothing and cannot half
    # finish. Nothing reads the master until seed_slot_cache runs later in this
    # same script, so there is no reader to tear.
    if mv -T "$CACHE_STAGE/$d" "$CACHE_MASTER/$d" 2>/dev/null; then
      n=$((n + 1))
    else
      mv -T "$CACHE_MASTER/.$d.previous" "$CACHE_MASTER/$d" 2>/dev/null || true
    fi
    rm -rf "$CACHE_MASTER/.$d.previous"
  done
  rm -rf "$CACHE_STAGE"

  took=$(( $(date +%s) - started ))
  CACHE_VERDICT="hydrated"
  CACHE_DIRS_MOVED=$n
  log "cache hydrated from $snap: $n tool cache(s), $size bytes, ${age}h old, ${took}s of a ${budget}s budget"
}

# Repair the master's own root directory, and nothing inside it.
#
# Images before v3-13-0 shipped /opt/ci-cache as `drwxrwsr-x runner:ci` — mode
# 2775 — and `-perm /6000` in the scan above matches a setgid DIRECTORY, so every
# host in the pool refused its own master and every job ran cold. The tree was
# EMPTY; the refusal was about the container, not the contents. `chmod -R go-w`
# below cannot undo it twice over: `go-w` does not clear the setgid bit, and it
# runs only after the scan has already returned a refusal.
#
# So the one entry the IMAGE created is normalised here, before the scan, and it
# is the only thing normalised. Everything under it is content; the scan is what
# judges content; a hostile entry INSIDE the tree is still a refusal. Sanitising
# those would turn the gate into a laundering step — the scan exists precisely so
# that a setuid binary or a hardlink to /etc/shadow is refused rather than
# quietly de-fanged and then copied into every slot.
#
# The staged snapshot tree never gets this. That one is untrusted by
# construction and is scanned `strict`; a repair there would be repairing
# something a job could have written.
heal_cache_master_root() {
  local before after
  # A symlink is not a directory to repair, and both chown -h's target and
  # chmod's would be resolved through it — chmod has no --no-dereference at all.
  # Leave it untouched and let the scan refuse it by -type l, which is the whole
  # reason that predicate is there.
  if [ -L "$CACHE_MASTER" ]; then
    return 0
  fi
  if [ ! -d "$CACHE_MASTER" ]; then
    return 0
  fi
  before=$(stat -c '%a %U:%G' "$CACHE_MASTER" 2>/dev/null) || return 0
  # 0755 root:root is what packer bakes (`chown -Rh root:root` + `chmod -R
  # go-w,go+rX` on a 0775 tree). Matching it exactly means a healthy host does
  # nothing and says nothing.
  if [ "$before" = "755 root:root" ]; then
    return 0
  fi
  chown -h root:root "$CACHE_MASTER" 2>/dev/null || true
  # An explicit mode, not `go-w`: clearing setgid is the entire point, and
  # `chmod -R go-w` is exactly the call that was already running and not doing it.
  chmod 0755 "$CACHE_MASTER" 2>/dev/null || true
  after=$(stat -c '%a %U:%G' "$CACHE_MASTER" 2>/dev/null) || after="unreadable"
  if [ "$after" = "755 root:root" ]; then
    log "normalised $CACHE_MASTER: $before -> $after"
  else
    # Not a refusal on its own — the scan runs next and decides. But an operator
    # reading a later refusal needs to know this was tried and did not take.
    log "could not normalise $CACHE_MASTER: still $after (was $before)"
  fi
}

# Make the master read-only to everything but root.
lock_shared_cache() {
  # Before the scan, not after: the scan is what refuses a setgid root, so a
  # repair that runs afterwards never runs at all.
  heal_cache_master_root
  if cache_master_is_hostile; then
    log "jobs will run without a seeded cache"
    return 1
  fi
  # -R is what makes this walk physical; -h is belt-and-braces for the
  # non-recursive case and costs nothing. See the rule at the top of the section.
  # Status checked, not discarded. `go-w` leaves the OWNER write bit in place, so
  # "root owns every entry" is now the whole of what makes the master unwritable
  # by a slot — and images before module v5.12.0 ship this tree group-writable, so
  # a slot-owned file in it is a reachable starting state rather than a
  # hypothetical. A half-failed chown would leave exactly that file writable by
  # the uid that owns it. Fail open, per this section's contract: no seeded cache
  # is slow, a distributed one is a cross-slot channel.
  if ! chown -Rh root:root "$CACHE_MASTER" 2>/dev/null; then
    log "could not take ownership of $CACHE_MASTER — refusing to seed from it"
    return 1
  fi
  # go-w,go+rX and NOT a-w,a+rX. The master is root-owned, so the owner write bit
  # protects nothing here — root ignores it — but `cp -a` PRESERVES mode, so
  # stripping it would hand every slot a copy of its own cache with no write bit
  # on any directory: owner-`ci-sN`, mode 0555, EACCES on the first write. The
  # bits that matter are group's and other's, and those are what this removes.
  # +rX restores traversal and read for the slots, X being
  # directory-or-already-executable so a data file does not become executable.
  if ! chmod -R go-w,go+rX "$CACHE_MASTER" 2>/dev/null; then
    log "could not seal $CACHE_MASTER read-only — refusing to seed from it"
    return 1
  fi
}

# Give slot $1 its own writable cache, seeded from the master.
seed_slot_cache() {
  local idx="$1" u d src dst
  u=$(slot_user "$idx")
  dst="$CACHE_SLOTS/$idx"

  # ROOT-owned and slot-GROUP, mode 0710. Two separate properties, both
  # load-bearing, and it is worth being explicit about which does what.
  #
  # Root OWNS it because everything below creates, renames and chowns names in
  # $dst, and a slot that owned $dst could swap any of those names for a symlink
  # between root's test and root's call.
  #
  # 0710 with the slot's group is what actually isolates one slot's cache from
  # the others, and this is NOT belt-and-braces for the 0700 further down. That
  # 0700 is on a directory the slot OWNS, and an owner may always chmod its own
  # directory: one job on slot 1 running `chmod 0777` on its own cache directory
  # would, with $dst world-traversable, hand every later job on every other slot
  # write access to it — and a poisoned npm cache is executed by the next `npx`
  # on slot 1 with slot 1's token. The bound has to sit on a directory the slot
  # cannot chmod, so it sits here. The group is the slot's own single-member
  # primary group, whose singleness provision_slot_user asserts before this runs;
  # no r bit, because a tool opens its cache by absolute path and never needs to
  # list the directory above it.
  mkdir -p "$dst" || return 1
  chown root:"$u" "$dst" || return 1
  chmod 0710 "$dst" || return 1

  # Cleared first and written last, so it means "every directory below is present
  # and owned by this slot" rather than "seeding was attempted". It lives in the
  # root-owned $dst, so a slot cannot forge it to be handed variables pointing at
  # directories it cannot write.
  rm -f "$dst/.ready"

  for d in "${CACHE_DIRS[@]}"; do
    src="$CACHE_MASTER/$d"
    # Already seeded on an earlier boot: leave it exactly as the slot left it.
    # Re-seeding would delete a warm cache to replace it with a colder one. The
    # entry cannot have been substituted — $dst is root-owned — so this is the
    # slot's own cache, poisoned only by its own earlier jobs, which is the
    # bound the README states and the host's lifetime ends.
    [ -d "$dst/$d" ] && continue
    if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
      # Into a temporary name and then renamed, because the env var below names
      # the final path: a tool that started while a half-copied tree sat there
      # would read a truncated entry as a real one. rename is atomic, so the
      # directory either is not there (cache miss, correct) or is complete. The
      # staging name is in the root-owned $dst for the same reason as everything
      # else here — in a slot-owned directory it could be pre-created as a
      # symlink and `cp` would follow it, writing as root wherever it pointed.
      #
      # --no-preserve=ownership: the master is root-owned and this copy is the
      # slot's own. Combined with the chown below it leaves no root-owned file in
      # a tree the slot writes to, which is what keeps the tools' normal
      # single-user assumptions true.
      rm -rf "$dst/.seed-$d"
      if cp -a --no-preserve=ownership "$src" "$dst/.seed-$d" 2>/dev/null; then
        # A copy of a sealed tree arrives with the seal's modes, so the owner
        # write bit is restored on DIRECTORIES here — a cache the tool cannot add
        # an entry to is not a cache, it is an EACCES.
        #
        # BEFORE the chown, not after, and that ordering is the whole safety
        # argument. `chmod` without -R dereferences, and `-exec … {} +` batches,
        # so there is a real window between find's lstat and the chmod call. While
        # the tree is still root-owned no other uid can create a name in it, so
        # there is nothing to substitute during that window; one chown later it
        # would be a root-privileged operation inside a uid-controlled namespace,
        # which is the thing the rule at the top of this section forbids.
        #
        # Files are deliberately left alone. Go writes its module cache 0444 on
        # purpose and owning it does not change that; every cache here is
        # content-addressed and replaced by rename, which needs write on the
        # parent directory and now has it.
        find "$dst/.seed-$d" -type d -exec chmod u+rwx {} + 2>/dev/null || true
        # Published at its final mode rather than widened-then-narrowed: a
        # directory permission is checked at open(), so a slot that won the window
        # between `mv -T` and a later chmod would keep a dirfd onto another slot's
        # cache for the life of the host.
        chmod 0700 "$dst/.seed-$d" 2>/dev/null || true
        chown -R "$u:$u" "$dst/.seed-$d" 2>/dev/null || true
        mv -T "$dst/.seed-$d" "$dst/$d" 2>/dev/null || rm -rf "$dst/.seed-$d"
      else
        rm -rf "$dst/.seed-$d"
      fi
    fi
    # Either the master had nothing to give or the copy failed. Both are a cold
    # cache, which is slow and correct; the directory still has to exist and be
    # writable or the tool pointed at it fails instead of missing.
    #
    # `install -d` rather than mkdir+chown: one call that creates the directory
    # with the right owner and mode, so there is no window in which it exists
    # owned by root, and no separate chown to be aimed at a substituted name.
    [ -d "$dst/$d" ] || install -d -o "$u" -g "$u" -m 0700 "$dst/$d" || return 1
    # Unconditional, because `install -d -m 0700` above sets the mode only on the
    # branch where it runs and a successful seed skips it, leaving the copy
    # carrying the master's world-traversable directory mode.
    #
    # This is defence in depth and NOT the isolation control — the slot owns this
    # directory and can chmod it back to 0777 whenever it likes. The bound that
    # holds against a slot that wants to be reached is the 0710 on $dst, which
    # only root can change. This line closes the accidental case, not the
    # deliberate one.
    chmod 0700 "$dst/$d" || return 1
  done

  : >"$dst/.ready" || return 1
}

provision_shared_cache() {
  # Fails OPEN, unlike almost everything else in this script. A host with no
  # usable cache is a SLOW host; a host that refuses to register over a cache
  # problem is a missing host, and the pool responds to missing hosts by queueing
  # jobs. Speed is worth less than capacity, so every failure here is logged and
  # survived.
  if [ ! -d "$CACHE_MASTER" ]; then
    log "no $CACHE_MASTER on this image — jobs will run without a seeded cache (needs image v3-12-0 or later)"
    return 1
  fi
  lock_shared_cache || return 1

  mkdir -p "$CACHE_SLOTS" || { log "could not create $CACHE_SLOTS — jobs will run without a seeded cache"; return 1; }
  # Root-owned traversal only. Each slot's directory one level down is root-owned
  # 0710 with that slot's group, so a slot reaching this far still cannot enter
  # any directory but its own — and cannot widen the one that stops it.
  chown root:root "$CACHE_SLOTS" 2>/dev/null || true
  chmod 0755 "$CACHE_SLOTS" 2>/dev/null || true

  # Retired indices go before the live ones are seeded. `slots_per_host` can be
  # reduced, and `/var/lib/ci-cache/<idx>` for an index above the new count keeps
  # its tree and — worse — its `.ready` marker, which says "every tool directory
  # below is present and owned by this slot". Nothing reads it while the index is
  # retired, so this is hygiene rather than a live bug; but the marker stops being
  # true the moment the count goes back up and the seeding loop finds a directory
  # that already claims to be ready. It is also a full duplicate cache tree per
  # retired slot, on the disk the hydrate reserves space on.
  #
  # Bounded by what is THERE, not by a guess at the old count: the previous value
  # of `ci-slots` is not recorded anywhere on this host, so the sweep reads the
  # directory. Only names that are entirely digits are considered, and only ones
  # above $SLOTS are removed — anything else in $CACHE_SLOTS was not put there by
  # this function and is not this function's to delete.
  local d idx
  for d in "$CACHE_SLOTS"/*; do
    [ -d "$d" ] || continue
    idx=${d##*/}
    case "$idx" in ''|*[!0-9]*) continue ;; esac
    [ "$idx" -gt "$SLOTS" ] || continue
    # if/else and not `&& … || …`: the second form runs the failure branch when
    # the LOG fails, which would report a removal that succeeded as one that did
    # not — and the log is the only record this sweep leaves.
    if rm -rf "$d"; then
      log "slot $idx: retired (this host now has $SLOTS), its cache copy removed"
    else
      log "slot $idx: retired, but its cache copy could not be removed"
    fi
  done

  local i
  for i in $(seq 1 "$SLOTS"); do
    seed_slot_cache "$i" || log "slot $i: could not seed its cache — it will run cold"
  done
  log "dependency cache seeded for $SLOTS slot(s) from $CACHE_MASTER (${#CACHE_DIRS[@]} tool caches, read-only master)"
}

# The systemd `Environment=` lines that point slot $1's build tools at its own
# cache.
#
# Every entry below is the variable the tool's own documentation names, and the
# list is deliberately shorter than "every cache a CI host has". Two are EXCLUDED
# on purpose, and each exclusion is a bug avoided rather than an oversight:
#
#   * GOCACHE (Go's BUILD cache) — golang/go#43645: concurrent builds sharing one
#     GOCACHE is not safe. GOMODCACHE, the downloaded-module cache, is a
#     different directory and is the one worth sharing, so only that is set.
#   * RUNNER_TOOL_CACHE / AGENT_TOOLSDIRECTORY — the tool-cache library has no
#     locking (actions/toolkit#804: two jobs extracting a JDK into one directory
#     fail with "cannot remove ...: Directory not empty"). Per-slot seeding would
#     in principle fix that, but the setup-* actions treat the tool cache as a
#     place they OWN and prune, and a pruned hardlink tree is a slow rebuild for
#     every slot rather than a shared saving. It stays per-slot and untouched.
#
# GOFLAGS=-modcacherw is deliberately NOT set. Go writes its module cache
# read-only by design so that a build cannot edit a dependency after go.sum
# verified the zip it came from — the extracted tree is never re-hashed, which is
# why `go mod verify` exists as a separate command. In a tree shared by several
# uids that read-only mode was the only thing standing between a hostile
# co-tenant and an in-place edit of a module another slot compiles. Per-slot
# caches make Go's own default both safe and sufficient, so the default stays.
share_env() {
  # What this slot's FAIR SHARE of the host is, published so a job can size
  # itself to the machine it is actually on.
  #
  # `nproc` inside a slot reports the whole host — 16 on an n2-standard-16 —
  # because slots are separated by user, network namespace and dockerd, and not
  # by CPU. That is deliberate: a hard CPUQuota would stop a lone job from using
  # an otherwise idle host, and this pool exists to make jobs fast. The cost is
  # that every tool which sizes a worker pool from `nproc` believes it owns the
  # machine, and K of them believe it at the same time.
  #
  # Measured on the IntegrateIT pool, 2026-08-22: 4 slots on 16 vCPU, each test
  # job budgeting 2 packages x 6 workers because its workflow reasoned from
  # `nproc` and a comment that still said "one CI job per VM". Up to 48 test
  # workers on 16 vCPU, plus four Postgres service containers — 3x
  # oversubscribed, which is the shape that produces timeouts a re-run "fixes".
  #
  # So the host states the share and the job obeys it. Contention between slots
  # stays on the kernel's fair scheduler, where a slot that is alone still gets
  # everything; what changes is that a slot which is NOT alone no longer plans
  # as though it were.
  local cpus mem_kb
  cpus=$(nproc)
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  cat <<EOF
Environment=CI_SLOT_VCPUS=$(( cpus / SLOTS > 0 ? cpus / SLOTS : 1 ))
Environment=CI_SLOT_MEM_MB=$(( mem_kb / 1024 / SLOTS ))
Environment=CI_HOST_VCPUS=$cpus
Environment=CI_HOST_SLOTS=$SLOTS
EOF
}

cache_env() {
  local idx="$1" c="$CACHE_SLOTS/$1"
  # The marker, not the directory. $c is created by the FIRST line of
  # seed_slot_cache and the marker by its last, so testing the directory would
  # emit all ten variables for a seeding run that failed half way — pointing a
  # tool at a directory that is absent, or present with the wrong owner, which is
  # a hard per-job failure rather than the cache miss this layer promises.
  [ -f "$c/.ready" ] || return 0
  cat <<EOF
# npm reads any config key from a matching npm_config_* variable.
Environment=npm_config_cache=$c/npm
Environment=YARN_CACHE_FOLDER=$c/yarn
# BOTH spellings, because the supported one changed: pnpm 11 reads
# pnpm_config_store_dir and silently IGNORES the npm_config_ form it honoured
# before — silently, meaning a single-spelling guess looks like it worked and
# quietly stores nothing where we asked. Repositories pin their own pnpm, so
# this host cannot assume which side of that change it is serving. The store also
# has to sit on the same filesystem as the workspace or pnpm degrades from
# hardlinking to copying without saying so; /var/lib and the slot work trees are
# both on the boot disk, which is also why this is not an overlay mount.
Environment=pnpm_config_store_dir=$c/pnpm-store
Environment=npm_config_store_dir=$c/pnpm-store
Environment=GOMODCACHE=$c/go-mod
Environment=PIP_CACHE_DIR=$c/pip
Environment=UV_CACHE_DIR=$c/uv
# Maven has no environment variable for the local repository; the system property
# is the supported route, and MAVEN_ARGS is how you deliver one from the
# environment (Maven 3.9.0 and later). A repository that sets its own MAVEN_ARGS
# overrides this, which is the correct precedence.
Environment=MAVEN_ARGS=-Dmaven.repo.local=$c/m2
Environment=NUGET_PACKAGES=$c/nuget
Environment=COMPOSER_CACHE_DIR=$c/composer
EOF
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
  # No shared supplementary group. A slot user belongs to nothing but its own
  # single-member group: the dependency cache is delivered as a per-slot COPY
  # (see "the dependency cache" above) rather than as one tree several uids can
  # write, so there is nothing left for a group like `ci` to grant — and a group
  # that grants nothing is just a boundary waiting to be widened by accident.
  # Enforce the mode rather than inherit it. HOME_MODE / UMASK in login.defs
  # decides what `useradd -m` creates, and a 0755 home is exactly the sibling
  # readability this split exists to remove — an unenforced comment is not an
  # isolation boundary.
  getent group "$u" >/dev/null || return 1
  # The primary group must be this slot's OWN single-member group, asserted and
  # not assumed. Everything above only creates the account when it is absent, so
  # an image that ships a pre-made ci-sN — or a future path that creates one
  # differently — could hand this slot a primary group it SHARES with the other
  # slots, and then every "group" permission in this script means "all slots"
  # instead of "nobody but me". That reading applies to the slot's own home and
  # to its agent credentials, so it is a silent collapse of the whole per-slot
  # boundary. Fail the slot rather than run it with the boundary gone.
  [ "$(id -gn "$u")" = "$u" ] || {
    log "slot $idx: primary group of $u is not $u — refusing to provision it"
    return 1
  }
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

  # Root-owned per-slot state, and the single leaf inside it the slot may write:
  # its daemon's data root. Root owns the directory ABOVE that leaf, so a slot
  # cannot create, rename or replace a name there — the same namespace-ownership
  # rule the cache tree follows, and here it is what stops a slot from forging
  # the `clean` marker that decides whether its next job is allowed to run.
  install -d -o root -g root -m 0755 "$SLOT_STATE" || return 1
  install -d -o root -g root -m 0755 "$SLOT_STATE/$idx" || return 1
  # Where slot-reset.sh holds _work while it empties it. Root-owned and 0700 on
  # both levels, because the whole point is a directory the slot cannot create a
  # name in while root is walking one.
  install -d -o root -g root -m 0700 "$SLOT_ROOT/.reset" || return 1
  install -d -o root -g root -m 0700 "$SLOT_ROOT/.reset/$idx" || return 1
  install -d -o "$u" -g "$u" -m 0700 "$SLOT_STATE/$idx/docker" || return 1

  # The home's CONTENT — the registry credential helpers and the daemon's mtu
  # config among it — comes from $SLOT_TEMPLATE, laid down by the same code that
  # will lay it down again between every pair of jobs. Writing it here a second
  # way is exactly how "a fresh slot" and "a reset slot" drift apart, and a drift
  # in this direction is silent: the first job on a host would see a file no
  # later job on that host ever sees again.
  #
  # Fails the slot: a home that is not in the state the template describes is a
  # home nobody can describe, and the next thing to happen to it is an agent
  # being registered against it.
  #
  # NOT under a live agent. On a WARM reboot the ci-runner@ units are already
  # enabled and start independently of google-startup-scripts.service -- the same
  # hazard gh_token spells out -- so an agent can be registered and executing a
  # job by the time this line is reached, and a boot reset would empty that live
  # job's home, _actions, _temp and workspace and then record the slot clean.
  # Skipping is not a compromise: the unit carries its own
  # ExecStartPre=+slot-reset.sh boot, so a slot whose agent is up has ALREADY
  # been reset by the path that owns that decision, and doing it a second time
  # from here can only destroy work.
  if systemctl is-active --quiet "ci-runner@$idx.service"; then
    log "slot $idx: its agent is already running (warm reboot) — its unit's own boot reset stands; not resetting under a possibly live job"
    return 0
  fi
  /opt/ci/job-hooks/slot-reset.sh boot "$idx" || return 1
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
primary_addr() { ip -o -4 addr show dev "$(primary_if)" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# The shared-infrastructure port band. Slot <idx> owns 100 host ports and no
# other slot owns any of them, so two slots publishing the "same" service never
# collide -- the collision setup_slot_netns exists for, restated at the level a
# sibling slot and a Windows host can both address.
#
# Derived from $SLOTS, never from a hardcoded four. Slot indices here start at
# ONE (seq 1 "$SLOTS"), so the lowest band is 35100 and the whole span is
# `slot_band_min 1` .. `slot_band_max $SLOTS`. The span is computed from these
# two functions rather than restated as a formula: a firewall range and a DNAT
# range that disagree fail as "the connection hangs", which is unreadable.
CI_BAND_BASE=35000
CI_BAND_WIDTH=100
slot_band_min() { printf '%s' "$(( CI_BAND_BASE + $1 * CI_BAND_WIDTH ))"; }
slot_band_max() { printf '%s' "$(( CI_BAND_BASE + $1 * CI_BAND_WIDTH + CI_BAND_WIDTH - 1 ))"; }

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

  # THE BAND IS RESERVED FROM THE EPHEMERAL RANGE, and this is not tidiness.
  # `ip_local_port_range` starts at 32768 on every stock kernel, so the whole
  # band sits inside it: any outbound socket the host opens -- the runner
  # agent's long poll to GitHub, a registry pull, the ops agent -- can be handed
  # 35142 by the kernel and hold it. The next slot to publish a service on that
  # port then fails to bind, in a job that did nothing wrong, on a host that
  # looks healthy, and the failure moves to a different port on every boot.
  #
  # `ip_local_reserved_ports` is the kernel's answer: a port listed there is
  # never handed out as ephemeral, while an explicit bind() to it still works --
  # exactly the split this needs, since a band port is only ever bound
  # deliberately. Set for the whole band at once, from the same two constants
  # the DNAT and the firewall rule use.
  #
  # Merged with whatever is already reserved rather than overwritten: the value
  # is one host-wide list, and stamping our band over someone else's reservation
  # would hand THEM the intermittent bind failure.
  #
  # A failure here is logged and not fatal. The band still works; it is the rare
  # collision that comes back, and refusing to bring the host up over it would
  # trade an occasional flake for a pool that does not start.
  local band_lo band_hi reserved want
  band_lo=$(slot_band_min 1); band_hi=$(slot_band_max "$SLOTS")
  want="$band_lo-$band_hi"
  reserved=$(tr -d ' ' < /proc/sys/net/ipv4/ip_local_reserved_ports 2>/dev/null)
  case ",$reserved," in
    *",$want,"*) : ;;
    *)
      sysctl -qw "net.ipv4.ip_local_reserved_ports=${reserved:+$reserved,}$want" ||
        log "could not reserve $want from the ephemeral port range -- a host socket may take a band port and a slot's service will then fail to bind"
      ;;
  esac

  # The band's forward allow, scoped to what the DNAT actually produced.
  #
  # A sibling slot's packet to the host address is DNATed in PREROUTING and then
  # traverses FORWARD from its own cis<N> to the owner's veth. Today the broad
  # per-veth accepts in setup_slot_netns already permit that, but those accepts
  # are what #249 removes, and this path must survive their removal -- so the
  # band states its own case rather than living on someone else's rule.
  #
  # Original-destination matching is the point: --ctorigdst/--ctorigdstport
  # admit precisely the traffic that entered through a band DNAT, and nothing a
  # slot addressed to a sibling's 10.99.<n>.2 directly.
  #
  # `-p tcp` because the DNAT that produces this traffic is `-p tcp`, and
  # `--ctorigdstport` alone does not imply a protocol -- it matches the port
  # field of whatever the conntrack entry holds. Without it the accept was wider
  # than the rule it mirrors, admitting forwarded UDP to a band port that no
  # DNAT on this host could have created. When #249 lands, its
  # reject goes BELOW these two and its acceptance criterion becomes "a sibling
  # reaches the band, and reaches nothing else".
  #
  # APPENDED, never inserted, for the same reason the per-veth accepts are: an
  # insert would land above the metadata REJECT below and hand a slot the host's
  # identity back.
  local baddr bspan_min bspan_max
  baddr=$(primary_addr)
  bspan_min=$(slot_band_min 1); bspan_max=$(slot_band_max "$SLOTS")
  if [ -n "$baddr" ]; then
    iptables -w -C FORWARD -p tcp -m conntrack --ctstate DNAT --ctorigdst "$baddr" \
      --ctorigdstport "$bspan_min:$bspan_max" -j ACCEPT 2>/dev/null \
      || iptables -w -A FORWARD -p tcp -m conntrack --ctstate DNAT --ctorigdst "$baddr" \
        --ctorigdstport "$bspan_min:$bspan_max" -j ACCEPT || return 1
    iptables -w -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
      || iptables -w -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  else
    log "no primary address -- shared-infrastructure band not forwarded"
  fi

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

  # The turbo cache listens on every slot gateway for the same reason, and so
  # also on the VM's own address. It vends no credential, but it does serve one
  # repository's build artifacts out of a bucket nothing off this host is
  # entitled to read — and it is added here, next to the broker's rule, so the
  # question "what does this host expose?" has one answer in one place.
  #
  # Unconditional on the port even when the layer is off: nothing listens then,
  # and a REJECT for a closed port costs nothing, whereas making the rule
  # conditional makes a host that later enables the layer depend on a reboot
  # ordering to be safe.
  iptables -w -C INPUT -i "$ifc" -p tcp --dport "$TURBO_PORT" -j REJECT 2>/dev/null \
    || iptables -w -I INPUT 1 -i "$ifc" -p tcp --dport "$TURBO_PORT" -j REJECT \
    || return 1
}

# Idempotent: a re-run of this script (or a slot restart) must find the
# namespace it already made rather than tear a running slot's networking down.
setup_slot_netns() { # <idx>
  local idx="$1" ns veth gw nsip mtu addr bmin bmax
  ns=$(slot_netns "$idx"); veth=$(slot_veth "$idx")
  gw=$(slot_gw_ip "$idx"); nsip=$(slot_ns_ip "$idx"); mtu=$(primary_mtu)
  addr=$(primary_addr); bmin=$(slot_band_min "$idx"); bmax=$(slot_band_max "$idx")

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

  # The band's DNAT: anything addressed to THIS HOST on slot <idx>'s 100 ports
  # is rewritten to the slot's namespace address.
  #
  # Matched on destination ADDRESS, not on `-i <primary_if>`. The main consumer
  # of this path is a sibling slot on the same host, whose packets arrive on
  # cis<N> and never on the primary interface; an input-interface match would
  # silently exclude the traffic the rule exists for, handing the Windows case a
  # working path and the same-host case a connection refused. Matching the
  # host's own address admits both and still declines anything not addressed
  # here.
  #
  # A host with no primary address is not a host that can serve a band, but it
  # is also not a reason to fail the slot: everything else about the slot works,
  # and a job that needs the band asserts CI_SHARED_INFRA_ADDR itself.
  if [ -n "$addr" ]; then
    iptables -w -t nat -C PREROUTING -d "$addr" -p tcp --dport "$bmin:$bmax" \
      -j DNAT --to-destination "$nsip" 2>/dev/null \
      || iptables -w -t nat -A PREROUTING -d "$addr" -p tcp --dport "$bmin:$bmax" \
        -j DNAT --to-destination "$nsip" || return 1
  else
    log "slot $idx: no primary address -- shared-infrastructure band not published"
  fi
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
# Hide every other uid's processes from this slot. Set here as well as on the
# agent because the two SHARE a mount namespace (JoinsNamespaceOf), and /proc is
# a property of that namespace rather than of either unit: setting it on one
# side only would leave which view wins depending on which started first.
#
# Ignored with a warning by systemd older than 247, which is why it is not the
# argument for anything — it is the belt over the tokens already being out of
# argv, not a substitute for it.
ProtectProc=invisible
# The data root is OUTSIDE the slot's home, which is what lets the home be
# emptied between jobs (#110) — and also what keeps a reset cheap: every image
# this host has warmed lives here and survives one.
#
# Passed explicitly rather than left to $XDG_DATA_HOME. dockerd-rootless.sh
# forwards its arguments to the daemon and sets no data root of its own, so
# without this dockerd falls back to $HOME/.local/share/docker — inside the tree
# the reset deletes, while the daemon still holds it open.
ExecStart=/usr/bin/dockerd-rootless.sh --data-root=/var/lib/ci-slot/%i/docker
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

# Load any container image archives the IMAGE baked into /opt/ci-images into
# this slot's rootless daemon.
#
# NOT the dependency cache. /opt/ci-cache is copied into a writable per-slot tree
# by design and documented as untrusted build input; what is read here is
# `docker load`ed into every slot
# on the host, so a job able to write it would be choosing the image every other
# slot runs. The two trees are siblings for that reason, and this one is
# root-owned.
#
# This exists because a pre-pulled image is per-DAEMON, and every slot runs its
# own rootless daemon with its own data root under the slot user's home. An
# image pulled at bake time lands in the build VM's root-owned /var/lib/docker
# and is invisible to all K of them — so the only way to bake a container image
# is to bake a FILE (docker save) and load it per slot, which is what this does.
#
# Deliberately generic: the host has no idea what is in the archives, and no
# tool is named here. A pool that wants an image warm supplies a warm-cache
# script that writes /opt/ci-images/*.tar[.gz]; a pool that does not gets no
# directory at all and pays nothing.
#
# /opt/ci-images is NOT under /opt/ci-cache, and that is the security boundary
# rather than a filing choice. The dependency cache is copied per slot so each
# can update its own, and everything in it is untrusted build input by design.
# These
# archives are not input: they are loaded into every slot's daemon at boot, so
# whoever can write one is running their image in every slot on the host for
# the rest of its life. Root-owned tree, root-owned parent, no group write.
#
# Backgrounded and never fatal, for two reasons. A multi-gigabyte load takes
# minutes, and blocking on it would keep the whole pool from registering while
# a job queue builds. And a corrupt or half-written archive must degrade to "the
# job pulls the image itself", which is merely slow — the alternative is a host
# that refuses to register over a CACHE, which is the same class of fault as
# making boot depend on a registry (see slot_runtime_usable).
#
# One load per SLOT, not one per host: the slot daemons have separate data
# roots, so there is nothing for them to share and each pays the cost in full.
# Measured single-threaded on a 4-vCPU host: ~53s to checksum and load a 942MB
# archive. K slots run that concurrently against one disk, so the last one
# finishes appreciably later than the first — that is accepted, not overlooked.
# It is affordable only because nothing waits on it: slots register and take
# jobs while these run in the background, and the first UI job to land before
# its slot finished loading just pulls the image itself.
# The identity of what boot put in this slot's image store, for #233.
#
# `docker load` is the only moment the host knows an image arrived from a source
# the host chose. Everything after it -- every tag in that store -- is a name a
# JOB may have created, and `docker run <name>` never contacts a registry when a
# local image by that name exists. So the ids loaded here are recorded, and the
# reset prunes any tag that is neither in this list nor carrying a registry
# digest of its own.
#
# The ids and not the names. A job can `docker tag` a baked NAME onto its own
# image, and a manifest of names would then bless exactly the substitution this
# is here to catch. An id is the content.
#
# Never fatal. A manifest that cannot be written leaves the prune trusting
# registry digests alone, which costs a re-pull of the baked images on the next
# job and breaks nothing.
record_baked_images() { # <idx> <slot user> <manifest path> <docker load output>
  local idx="$1" u="$2" f="$3" out="$4" ref id
  # Both forms docker prints: a tagged image gives `Loaded image: repo:tag`, an
  # untagged one gives `Loaded image ID: sha256:...`.
  printf '%s\n' "$out" |
    sed -n -e 's/^Loaded image ID: //p' -e 's/^Loaded image: //p' |
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      id=$(sudo -u "$u" DOCKER_HOST="unix:///run/$u/docker.sock" \
             docker image inspect --format '{{.Id}}' -- "$ref" 2>/dev/null) || continue
      [ -n "$id" ] || continue
      printf '%s\n' "$id" >>"$f" ||
        log "slot $idx: could not record $ref in the baked-image manifest"
    done
}


load_baked_images() {
  local idx="$1" u; u=$(slot_user "$idx")
  local dir="/opt/ci-images"

  [ -d "$dir" ] || return 0
  # Nothing to do is the common case — most pools bake no images at all.
  local archives; archives=$(find "$dir" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' \) 2>/dev/null)
  [ -n "$archives" ] || return 0

  (
    local a base manifest manifest_tmp
    # Built beside its destination and moved into place ONCE, at the end. A warm
    # reboot re-runs this while agents may already be executing jobs, and a
    # manifest that is empty for the minutes a multi-gigabyte load takes is a
    # manifest the reset would read as "nothing here was baked". Truncating in
    # place would open exactly that window; a rename does not.
    manifest="$SLOT_STATE/$idx/baked-images"
    manifest_tmp="$manifest.$$"
    : >"$manifest_tmp"
    chown root:root "$manifest_tmp"
    chmod 0644 "$manifest_tmp"
    printf '%s\n' "$archives" | while IFS= read -r a; do
      [ -n "$a" ] || continue
      base=$(basename "$a")

      # Verify against the digest recorded at bake time, when the archive was
      # last known-good. Defence in depth, not the primary control — the tree
      # is root-owned and unwritable by slots — but it is the half that still
      # holds if that ownership is ever widened, and it turns a truncated
      # archive into a clean skip.
      #
      # The line is selected by an EXACT filename field, not by searching for
      # the name anywhere in the file. `grep -F " $base"` would match the line
      # belonging to a DIFFERENT archive whose name merely contains this one —
      # `x.tar` matching the entry for `x.tar.gz` — and then `sha256sum -c`
      # would happily verify that other, legitimate file and report success,
      # loading the unchecked one. Character 67 is where sha256sum's name
      # field starts (64 hex digits + two separators).
      #
      # Fail closed: an archive with no line of its own, or with more than one,
      # is not loaded. Every archive this fleet bakes gets exactly one line, so
      # anything else is a tree nobody should be executing.
      local sums="$dir/SHA256SUMS" nmatch=0
      if [ -f "$sums" ]; then
        nmatch=$(awk -v f="$base" 'substr($0,1,64) ~ /^[0-9a-f]+$/ && substr($0,67)==f' "$sums" | wc -l)
      fi
      if [ "$nmatch" -ne 1 ]; then
        log "slot $idx: $base has no single checksum entry — NOT loading it; jobs will pull that image themselves"
        continue
      fi
      if ! ( cd "$dir" && awk -v f="$base" 'substr($0,1,64) ~ /^[0-9a-f]+$/ && substr($0,67)==f' SHA256SUMS \
               | sha256sum -c --status - ); then
        log "slot $idx: $base failed its checksum — NOT loading it; jobs will pull that image themselves"
        continue
      fi

      # `docker load` reads gzip transparently, so a warm script may save either
      # form; gzip trades boot CPU for image size and is the better default.
      #
      # `timeout` so a wedged load cannot hold this script open indefinitely —
      # main() waits for these before exiting, and an unbounded wait would keep
      # google-startup-scripts.service active forever.
      #
      # Generous on purpose. Nothing is waiting on this: the slots have already
      # registered and the host is taking jobs while these run, so the only
      # thing the ceiling bounds is how long a oneshot unit stays active. A
      # browser archive is multiple gigabytes and every slot loads its own copy
      # concurrently, so a tight ceiling would kill legitimate slow loads and
      # cost every job on the host the download this exists to avoid — trading
      # the whole feature for a tidier boot.
      #
      # shellcheck disable=SC2024  # the redirect is the shell's, and this shell
      # is root: a GCE startup script runs as root, which is also why every
      # other write to this log in this file is spelled the same way. `sudo`
      # here drops privilege for the daemon socket, it does not raise it.
      #
      # The output is CAPTURED rather than redirected, because it is the only
      # place the identity of what was just loaded appears. `docker load` names
      # each image it wrote (`Loaded image:` / `Loaded image ID:`), and that list
      # is what the per-slot boot manifest is built from -- see #233 and the tag
      # prune in slot-reset.sh. It still reaches the log, one line later.
      if out=$(timeout 1800 sudo -u "$u" DOCKER_HOST="unix:///run/$u/docker.sock" \
                 docker load -i "$a" 2>&1); then
        printf '%s\n' "$out" >>/var/log/ci-host.log
        log "slot $idx: loaded baked image archive $base"
        record_baked_images "$idx" "$u" "$manifest_tmp" "$out"
        # Whether loading it SAVED anything is a separate question from whether
        # it loaded. The runner pulls the job's `container:` image
        # unconditionally, and that pull only recognises these layers under the
        # containerd image store, which preserves registry blob digests across a
        # save/load round trip. Under the legacy graphdriver store every step
        # here still succeeds and the job re-downloads the image anyway.
        # The bake asserts the store on the BUILD VM; this records the one that
        # actually did the load, so a divergence is a line in this log rather
        # than an unexplained slowdown discovered months later.
        store=$(sudo -u "$u" DOCKER_HOST="unix:///run/$u/docker.sock" \
                  docker info --format '{{.DriverStatus}}' 2>/dev/null || true)
        case "$store" in
          *io.containerd.snapshotter.v1*)
            log "slot $idx: containerd image store — the job's own pull will be a no-op" ;;
          *)
            log "slot $idx: WARNING: image store is not containerd (${store:-unknown}) — the baked archive will NOT save the job's download" ;;
        esac
      else
        log "slot $idx: could not load $base — jobs will pull that image themselves"
      fi
    done
    # Even when every archive failed. An EMPTY manifest is the honest statement
    # "this host baked nothing into this slot", and the prune treats it that way;
    # leaving the PREVIOUS boot's manifest in place would keep blessing image ids
    # this boot never loaded.
    mv -T -- "$manifest_tmp" "$manifest" ||
      log "slot $idx: could not install the baked-image manifest — the tag prune will trust registry digests only"
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

# Can sudo carry a variable from THIS environment into the child's, without the
# value ever being an argument? That is how the registration token reaches
# config.sh (see install_slot), so the answer decides whether a slot may be
# registered at all.
#
# It is probed rather than assumed because it is not this script's policy to
# read: sudo's env_reset drops everything not explicitly preserved, and
# --preserve-env=NAME is honoured only where sudoers grants SETENV — which it
# implies for an entry whose command is ALL, as root's is on every image this
# pool uses. If that ever stops being true the variable is dropped SILENTLY and
# the runner asks for a token it will never get, which surfaces as an
# unexplained "config.sh failed". Probed once: the policy is a property of the
# invoking user, root, and does not vary by slot.
#
# 0 = not probed, 1 = works, 2 = does not.
SUDO_ENV_PROBE=0
sudo_passes_env() { # <user>
  if [ "$SUDO_ENV_PROBE" -eq 0 ]; then
    if CI_SUDO_ENV_PROBE=ok sudo -u "$1" --preserve-env=CI_SUDO_ENV_PROBE \
         sh -c '[ "${CI_SUDO_ENV_PROBE:-}" = ok ]' 2>/dev/null; then
      SUDO_ENV_PROBE=1
    else
      SUDO_ENV_PROBE=2
    fi
  fi
  [ "$SUDO_ENV_PROBE" -eq 1 ]
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

  # Empty when this slot has no seeded cache, which leaves every tool on its own
  # default under the slot's home — slower, and correct.
  local CACHE_ENV; CACHE_ENV=$(cache_env "$idx")

  # What makes the remote build cache seamless: the repository sets nothing, and
  # a workflow that never heard of this fleet gets cache hits because `turbo`
  # reads these three variables out of its environment.
  #
  # TURBO_API is this slot's GATEWAY address, not 127.0.0.1 — the slot has its
  # own loopback and nothing listens on it, the same wrinkle the broker has.
  #
  # TURBO_TEAM is required by the client even when the server ignores it: turbo
  # refuses to use a remote cache without a team, and it must be a `team_`-
  # prefixed slug or the CLI rejects it. The value names the pool, so a cache
  # line in a build log says which pool served it.
  #
  # Empty when the server did not come up, deliberately: a slot pointed at a
  # dead cache spends a connection refused per task, which is slower than having
  # no cache and much harder to read in a log.
  local TURBO_ENV=""
  if [ -n "$TURBO_TOKEN" ]; then
    TURBO_ENV=$(printf 'Environment=TURBO_API=http://%s:%s\nEnvironment=TURBO_TOKEN=%s\nEnvironment=TURBO_TEAM=team_%s' \
      "$(slot_gw_ip "$idx")" "$TURBO_PORT" "$TURBO_TOKEN" "$POOL")
  fi

  # Unconditional, unlike CACHE_ENV: every slot has a share whether or not it
  # has a seeded cache, and a job that cannot read one falls back to `nproc` —
  # which is the over-subscription this exists to end.
  local SHARE_ENV; SHARE_ENV=$(share_env)

  mkdir -p "$dir"
  # Copy, not symlink: config.sh writes .runner/.credentials into the directory
  # it runs in, and K agents must not share one identity.
  cp -a "$RUNNER_HOME/." "$dir/"
  chown -R "$u:$u" "$dir"
  chmod 0750 "$dir"

  local group_arg=()
  [ -n "$RUNNER_GROUP" ] && group_arg=(--runnergroup "$RUNNER_GROUP")

  # Fails CLOSED, and before the copy is registered rather than after: a host
  # where sudo will not carry the token through the environment has no way left
  # to hand it to config.sh that does not publish it in argv. See the call below.
  sudo_passes_env "$u" \
    || { log "slot $idx: sudo will not pass an environment variable through, and the only other way to hand config.sh its registration token is world-readable argv"; return 1; }

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
  # THE REGISTRATION TOKEN IS NOT AN ARGUMENT either, and this is the call the
  # exposure was really about: config.sh is a long-lived .NET process, not a
  # sub-second curl, and it runs while the slots that are already up serve jobs.
  #
  # actions/runner accepts every `configure` argument as ACTIONS_RUNNER_INPUT_<NAME>
  # and deletes the variable from its own environment block before it configures
  # anything (Runner.Listener CommandSettings), so the value sits in
  # /proc/<pid>/environ — readable only by the owning uid — and not in
  # /proc/<pid>/cmdline, which anyone on the host can read. `token` is on the
  # runner's own secret-arg list, so its trace output is masked too.
  #
  # --preserve-env=NAME puts the NAME in argv and leaves the VALUE in the
  # environment, which is the entire point; `sudo ACTIONS_RUNNER_INPUT_TOKEN=...`
  # would have put the token straight back into sudo's own cmdline.
  #
  # Fails CLOSED: a host where sudo will not carry the variable has no way left to
  # register that does not publish the token, so it does not register.
  ACTIONS_RUNNER_INPUT_TOKEN="$token" \
  sudo -u "$u" --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN "$dir/config.sh" \
    --unattended --replace --disableupdate \
    --url "https://github.com/$OWNER/$REPO" \
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
$CACHE_ENV
$TURBO_ENV
$SHARE_ENV
# The label a job pins the rest of its workflow run to. Read by the anchor job,
# which publishes it as the runs-on list for every later job in the run. A slot
# that does not know it degrades to unpinned scheduling rather than failing,
# which is why the anchor tests for it -- but on this host it is always set,
# because the boot dies above without it.
Environment=CI_HOST_LABEL=$HOST_LABEL
# The shared-infrastructure band this slot may publish on, and the address a
# sibling slot or a Windows host reaches it at. A service published inside the
# band is reachable from both; one published outside it resolves on this slot's
# own localhost and nowhere else, which fails as "the Windows job cannot
# connect" rather than as anything readable -- so the owner job asserts the
# range before it publishes.
Environment=CI_SHARED_INFRA_ADDR=$(primary_addr)
Environment=CI_SHARED_INFRA_PORT_MIN=$(slot_band_min "$idx")
Environment=CI_SHARED_INFRA_PORT_MAX=$(slot_band_max "$idx")
# Reset this slot before every job and after every job: the home is emptied and
# rebuilt from $SLOT_TEMPLATE, and the previous job's workspace and tool cache go
# with it. Set unconditionally, and NOT alongside BROKER_ENV: a pool with no job
# service account is where an inherited credential is most dangerous, since
# nothing there is supposed to have Google credentials at all. A failing hook
# fails the job, which is the intended trade — a job that could not be given a
# clean slot must not run in a previous job's leftovers.
Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ci/job-hooks/job-started.sh
Environment=ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/ci/job-hooks/job-completed.sh
# The one that matters: this is the unit job code runs under, and everything a
# job spawns inherits this mount namespace, so a step cannot read root's argv --
# nor a sibling slot's — out of /proc. See the daemon unit for why both carry it.
ProtectProc=invisible
# The third reset, and the one the two hooks cannot cover: an agent KILLED
# mid-job never runs its completed hook, and a host that reboots warm starts its
# agents over a disk the previous boot's jobs wrote. '+' runs this as root in
# spite of User= above, which is the entire point — see install_job_hooks.
ExecStartPre=+/opt/ci/job-hooks/slot-reset.sh boot $idx
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

  # Checked, because the caller counts a failure here and the host's readiness
  # line is computed from that count. An unchecked `enable --now` reports four
  # slots serving on a host whose four units all failed to start.
  if ! systemctl enable --now "ci-runner@$idx.service" >>/var/log/ci-host.log 2>&1 ||
     ! systemctl is-active --quiet "ci-runner@$idx.service"; then
    log "slot $idx: ci-runner@$idx.service did not start; slot will not serve"
    systemctl status "ci-runner@$idx.service" --no-pager -l >>/var/log/ci-host.log 2>&1 || true
    return 1
  fi
  log "slot $idx registered as $name"
}

# ProtectProc= covers the slot units, and a container is the hole it leaves: a
# job can ask its own daemon for `--pid=host`, and a fresh procfs mount inside
# that namespace would show the whole host again. The kernel refuses such a mount
# unless it is at least as restrictive as the one already visible, so setting
# hidepid on the host /proc is what makes the unit-level setting hold everywhere
# below it.
#
# hidepid=2, not 1: 1 hides the contents of another uid's /proc/<pid> but still
# lists the pid, and the argv of a boot-time process is exactly what must not be
# enumerable. No gid= escape hatch — a group that can see everything is the
# thing being removed.
#
# Fails OPEN, deliberately, and it is the only hardening here that does. The
# security property is that the tokens are not in argv at all; this makes the
# whole CLASS unreadable so a future call site cannot reintroduce it. A kernel
# or a mount policy that will not take the option is a reason to log loudly, not
# a reason to take a pool offline over a defence in depth.
harden_proc() {
  if mount -o remount,nosuid,nodev,noexec,hidepid=2 /proc 2>/dev/null; then
    log "/proc remounted hidepid=2 — one uid cannot read another's argv"
  else
    log "WARNING: could not remount /proc with hidepid=2; argv stays world-readable on this host, so every future call site must keep its own secrets out of it"
  fi
}

main() {
  mkdir -p "$SLOT_ROOT"
  id runner >/dev/null 2>&1 || die "golden image is missing the 'runner' user"
  [ -x /usr/bin/dockerd-rootless.sh ] || die "golden image has no rootless docker (dockerd-rootless.sh) — a host without it can only give every slot the same daemon, which is the exposure #10 removed"

  # First, and before any slot exists: the window this closes is the one where
  # THIS script holds a GitHub App JWT while agents from a previous boot are
  # already serving jobs.
  harden_proc

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

  # Before the slot users, because provisioning one now BUILDS its home from the
  # template — the very same way a reset rebuilds it between jobs.
  seed_slot_template || die "could not build the pristine slot home template — refusing to register agents"
  # Before the slot users for that same reason, and before the units that name
  # it. Fails CLOSED twice over: provision_slot_user calls slot-reset.sh, and an
  # agent whose ACTIONS_RUNNER_HOOK_JOB_STARTED points at a file that is not
  # there refuses to run any job at all — so a host that registered without this
  # would take work and fail every bit of it.
  install_job_hooks || die "could not install the per-job slot reset — refusing to register agents"

  # After the hooks, because job-started.sh renews a hold through it, and before
  # any agent exists, because a host that took a job without this is a host that
  # cannot be pinned — and an unpinnable host silently gives a pull request two
  # of them, which is the whole failure this fleet is being changed to prevent.
  install_pin_hold || die "could not install the pin hold — refusing to register agents"

  local i
  for i in $(seq 1 "$SLOTS"); do
    provision_slot_user "$i" || die "could not provision the user for slot $i"
  done
  # Before provision_shared_cache, and the order is the security argument rather
  # than a preference: everything a snapshot brings has to be in the master while
  # the master is still being scanned and locked. Hydrating afterwards would land
  # unscanned content in a tree already declared read-only and safe, and the seed
  # would hand a copy of it to every slot. Fails OPEN, like everything else here.
  hydrate_shared_cache || true
  # After the slot users, because each slot's cache is chowned to its user, and
  # before install_slot, because that reads whether a slot has a cache to decide
  # whether to point the agent at it. Fails OPEN: the return value is deliberately
  # ignored.
  provision_shared_cache || true

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

  # After the fence and the namespaces, because the server binds the slot
  # gateways those created and the REJECT that hides it from the network is
  # installed there; before install_slot, because that reads TURBO_TOKEN to
  # decide whether a slot is told the cache exists.
  #
  # Fails OPEN, unlike the broker: a missing credential fails a deploy job
  # outright, whereas a missing build cache only costs the time the fleet was
  # already spending before this layer existed.
  if [ -n "$TURBO_BUCKET" ] && [ -n "$TURBO_PREFIX" ]; then
    start_turbo_cache || log "turbo remote cache did not come up — slots will build without it"
  else
    log "no ci-turbo-bucket set — this pool serves no remote build cache"
  fi

  local token
  token=$(registration_token) || die "could not obtain a registration token"
  [ -n "$token" ] || die "registration token was empty"

  local failures=0
  for i in $(seq 1 "$SLOTS"); do
    install_slot "$i" "$token" || failures=$((failures + 1))
  done

  systemctl daemon-reload

  # After the agents, because it stops and starts their units by name, and after
  # the daemon-reload that makes those units known.
  #
  # Fails OPEN, and this is the one place in main() where that is the safer
  # reading rather than the lazier one. Everything above it fails CLOSED because
  # without it a host would serve jobs it should not: unfenced, unreset, or with
  # no credentials. Without the sweep a host serves jobs exactly as it did
  # before this existed -- it loses the recovery, not the isolation -- and
  # refusing to register over a missing timer would turn a repairable host into
  # a fleet outage of the kind the sweep is here to end.
  install_slot_sweep ||
    log "the idle slot sweep did not install — a slot left dirty by a cancelled job will stay dirty until this host is recycled"

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
