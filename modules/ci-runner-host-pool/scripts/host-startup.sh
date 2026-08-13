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

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a /var/log/ci-host.log; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }
die() { log "FATAL: $*"; exit 1; }

md() {
  curl -fsS -H "Metadata-Flavor: Google" \
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
HOSTNAME_SHORT=$(md "instance/name")

SLOTS=${SLOTS:-1}

[ -n "$OWNER" ] && [ -n "$REPO" ] || die "missing ci-github-owner/ci-github-repo metadata"
[ -d "$RUNNER_HOME" ] || die "golden image is missing $RUNNER_HOME — this host was booted from the wrong image, and booting a bare image here would reintroduce the per-job install cost this pool removes"

# --- GitHub App installation token -------------------------------------------
#
# Registration needs a short-lived token, so it is minted on the host from the
# App private key rather than baked anywhere. The key itself is read from Secret
# Manager at boot and never written to disk unencrypted for longer than the
# signing call.
gh_token() {
  local key jwt header payload now b64
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

  curl -fsS -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$INSTALL_ID/access_tokens" \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

registration_token() {
  local tok
  tok=$(gh_token) || return 1
  [ -n "$tok" ] || return 1
  curl -fsS -X POST \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER/$REPO/actions/runners/registration-token" \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# --- slots --------------------------------------------------------------------
#
# One agent per slot, each in its own directory with its own work folder, so K
# jobs on this host cannot collide in the workspace. They DO share the image's
# caches by design — that sharing is the speed-up — which is exactly why a pool
# serves one repository only (see README.md, isolation rules).

install_slot() {
  local idx="$1" token="$2"
  local dir="$SLOT_ROOT/$idx"
  local name="$HOSTNAME_SHORT-s$idx"

  mkdir -p "$dir"
  # Copy, not symlink: config.sh writes .runner/.credentials into the directory
  # it runs in, and K agents must not share one identity.
  cp -a "$RUNNER_HOME/." "$dir/"
  chown -R runner:runner "$dir"

  local group_arg=()
  [ -n "$RUNNER_GROUP" ] && group_arg=(--runnergroup "$RUNNER_GROUP")

  sudo -u runner "$dir/config.sh" \
    --unattended --replace \
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
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=runner
WorkingDirectory=$dir
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
}

main "$@"
