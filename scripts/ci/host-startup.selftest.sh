#!/usr/bin/env bash
# Self-test for the two host-boot invariants whose breakage is SILENT.
#
# Both were paid for once already on the pool this module replaces:
#
#   --disableupdate  GitHub forced an actions/runner self-update, leaving run.sh
#                    alive while the agent was OFFLINE and undispatchable. CI
#                    stalled 90 minutes with VMs RUNNING and zero usable runners
#                    (DataRetrival #2281). A warm host makes it worse: the
#                    self-update takes K slots down at once.
#
#   metadata fence   Job code could reach 169.254.169.254 and mint a token for
#                    the host service account — which reads the GitHub App
#                    private key from Secret Manager and can delete instances
#                    (#1958). Any workflow would own the fleet.
#
# Neither failure raises an error at boot: the host registers, serves jobs, and
# looks healthy. So they are pinned here instead.
#
# The checks are STRUCTURAL — the flag must be an argument to config.sh, not a
# word in a comment or a log line. Each mutation below breaks the script the way
# a later edit plausibly would and asserts this test notices; a gate that only
# passes on correct input is not evidence.

# Every predicate and mutation below matches the TEXT of host-startup.sh, in
# which `$u`, `$idx` and `$(slot_user …)` are the literal characters that must be
# there. Expanding them here would compare against this test's own environment
# and pass on any script at all — so the single quotes are the point.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/host-startup.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# Code only: full-line comments stripped, so prose about an invariant can never
# satisfy the check for the invariant.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `... | grep -q` under `set -o pipefail`. `grep -q` exits the moment it
# matches, the writer upstream takes SIGPIPE and exits 141, and pipefail then
# makes the PIPELINE fail — so a successful match is reported as a failure. It
# is a race with how much the writer had already buffered, which is why this
# passed on a laptop and failed on a runner against a byte-identical script.
# Every predicate below therefore matches against a string, not through a pipe.
# `grep -c` reads its input to the end, so nothing upstream is ever signalled.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

# --- the invariants, as pure predicates over a script's text -----------------

# --disableupdate must sit in config.sh's own argument list. The list is
# continued across lines with backslashes, so the run is joined first.
joined_code_of() { # <file> — continuation lines folded into one line each
  code_of "$1" | sed ':a;/\\$/{N;s/\\\n//;ba}'
}

has_disableupdate() { # <file>
  matches "$(joined_code_of "$1")" 'config\.sh([^|;&]|\\)*--disableupdate'
}

has_metadata_fence() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" '169\.254\.169\.254' || return 1
  matches "$code" '--uid-owner "\$u"' || return 1                     # fenced per uid
  matches "$code" '^[[:space:]]*fence_uid runner' || return 1         # the legacy job user
  matches "$code" 'DOCKER-USER' || return 1                           # and its containers
  # Every SLOT user too — a job now runs as ci-s<idx>, not as `runner`, so a
  # fence that only names `runner` fences nobody who executes build code.
  matches "$code" 'fence_uid "\$\(slot_user' || return 1
  # Fails closed: a host that cannot install the fence must not register agents.
  matches "$code" 'fence_metadata[[:space:]]*\|\|[[:space:]]*die'
}

# Per-slot container isolation (#10). Before this, every slot talked to the one
# rootful daemon, so a job could enumerate the sibling slots' containers, exec
# into them and read their GITHUB_TOKEN and workspace — and, the host being
# warm, later jobs' too. Three parts, all silent when broken: the agent must be
# pointed at ITS OWN socket, the shared daemon must be gone, and the slot must
# not run as an account another slot also runs as.
has_slot_isolation() { # <file>
  local code
  code=$(code_of "$1")
  # the agent's DOCKER_HOST is the slot's own socket, not the system one
  matches "$code" 'Environment=DOCKER_HOST=unix:///run/\$u/docker\.sock' || return 1
  # a daemon per slot, started before the agent that will use it
  matches "$code" 'ci-dockerd@' || return 1
  matches "$code" 'start_slot_dockerd "\$idx"[[:space:]]*\|\|[[:space:]]*return 1' || return 1
  # the shared rootful daemon is masked, not merely stopped — and the mask must
  # be fatal. Ignoring its failure leaves /var/run/docker.sock reachable on a
  # host that goes on to register agents, which is the #10 exposure intact.
  matches "$code" 'systemctl mask .*docker\.socket' || return 1
  matches "$code" 'systemctl mask[^|]*(\\\n)?[^|]*\|\|[^|]*die|die "could not mask the rootful Docker daemon' || return 1
  # the agent goes down with its daemon even when the daemon CRASHES (BindsTo);
  # Requires alone only propagates an explicit stop, so a dead daemon would
  # leave the agent taking jobs that fail at their first container step
  matches "$code" '^BindsTo=ci-dockerd@' || return 1
  # slot homes are 0750 and owned by the slot user, whatever login.defs says
  matches "$code" 'chmod 0750 "/home/\$u"' || return 1
  # and the agent runs as the slot's own user
  matches "$code" '^User=\$u$' || return 1
  matches "$code" 'sudo -u "\$u" .*"\$dir/config\.sh"'
}

# A slot whose daemon is up but cannot START a container is the failure this
# repository shipped for a day: `docker info` answered, the boot probe passed,
# and every job that touched a container died at its first build step. Both
# halves are asserted, because each one alone reproduces it.
has_container_runtime() { # <file>
  local code
  code=$(code_of "$1")
  # 1. DNS. The metadata address is ALSO the VPC resolver, and a container is
  #    handed it as its only nameserver, so a blanket per-uid REJECT takes name
  #    resolution away from every container a job starts. Port 53 must be let
  #    through; port 80, the token path, must not.
  matches "$code" 'dport 53 -m owner --uid-owner "\$u" -j ACCEPT' || return 1
  # 2. The user manager. runc asks systemd for a cgroup scope in user.slice; a
  #    slot that never logs in has no user manager to ask unless it lingers, and
  #    the daemon has to be pointed at that manager's bus.
  matches "$code" 'loginctl enable-linger "\$u"' || return 1
  matches "$code" 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$uid/bus' || return 1
  # 3. And the boot probe has to assert the capability rather than the daemon,
  #    or the next regression of either half ships exactly as this one did.
  matches "$code" 'slot_runtime_usable "\$idx" "\$u"[[:space:]]*\|\|[[:space:]]*return 1' || return 1
  matches "$code" '/run/user/\$uid/bus' || return 1
  # Resolution is proved from INSIDE the slot's network namespace, which is
  # where a job runs: the host's systemd-resolved stub does not exist there, so
  # a probe run in the host namespace answers a question nobody asked.
  matches "$code" 'ip netns exec "\$ns" getent ahostsv4'
}

# Slots share a host, so they share /tmp unless something separates them. A CI
# step that names a fixed path there — `/tmp/lockfile-fresh.json`, and there are
# many — creates it under whichever slot ran first, and every later slot gets
# EACCES on a file it believes is its own (SOAP-To-REST #2017). The daemon and
# its agent must land in the SAME private /tmp, or a bind mount of a path under
# it silently mounts an empty directory instead of the file the step wrote.
has_slot_tmp_isolation() { # <file>
  local code
  code=$(code_of "$1")
  matches "$code" '^PrivateTmp=yes$' || return 1
  # Two of them: the daemon's and the agent's. One alone is the broken half.
  [ "$(printf '%s\n' "$code" | grep -cE '^PrivateTmp=yes$')" -ge 2 ] || return 1
  matches "$code" '^JoinsNamespaceOf=ci-dockerd@\$idx\.service$'
}

# Each slot's daemon picks a host port for a service container out of
# /proc/sys/net/ipv4/ip_local_port_range, and RootlessKit binds that number in
# the ONE shared host netns. Every slot reading the same default range picks the
# same first free port, so two slots starting a service container together fail
# with "PortManager.AddPort(): listen tcp4 0.0.0.0:32768: bind: address already
# in use" (IntegrateIT #7749) — not a rare race, a near-certainty. The partition
# is silent when broken: the daemon starts fine and only jobs fail, later.
# Two attempts at slicing the ephemeral range per slot (v4.5.0, v4.5.1) both
# failed on a live host, for a reason no static check could have caught: docker's
# rootlesskit runs with --detach-netns, so the daemon stays in the HOST namespace
# and there is no per-slot ip_local_port_range to write. What is checked here is
# the replacement — a real namespace per slot — and the three ways it silently
# reverts to the shared-netns behaviour it exists to remove.
has_port_isolation() { # <file>
  local code
  code=$(code_of "$1")
  # a namespace per SLOT: an index-free name gives every slot the same one
  matches "$code" "slot_netns\(\) *{ *printf 'ci-s%s'" || return 1
  # the daemon joins it…
  matches "$code" '^NetworkNamespacePath=/run/netns/\$\(slot_netns "\$idx"\)$' || return 1
  # …and so does the agent, or "localhost:PORT" stops reaching its own services
  matches "$code" 'NetworkNamespacePath=/run/netns/\$\(slot_netns "\$idx"\)[[:space:]]*$' || return 1
  # egress for the namespace, or the slot has no network at all
  matches "$code" 'POSTROUTING -s 10\.99\.0\.0/16 -o "\$ifc" -j MASQUERADE' || return 1
  # the metadata fence restated for FORWARDed traffic — the per-uid OUTPUT rules
  # never see a namespaced packet — and the DNS exceptions must be INSERTED
  # ABOVE the blanket reject, i.e. appear AFTER it in the script
  matches "$code" 'FORWARD 1 -s 10\.99\.0\.0/16 -d "\$md_ip" -j REJECT' || return 1
  matches "$code" 'FORWARD 1 -s 10\.99\.0\.0/16 -d "\$md_ip" -p "\$proto" --dport 53 -j ACCEPT' || return 1
  local reject_ln accept_ln
  reject_ln=$(printf '%s\n' "$code" | grep -n 'FORWARD 1 -s 10\.99\.0\.0/16 -d "\$md_ip" -j REJECT' | head -1 | cut -d: -f1)
  accept_ln=$(printf '%s\n' "$code" | grep -n 'FORWARD 1 -s 10\.99\.0\.0/16 -d "\$md_ip" -p "\$proto" --dport 53 -j ACCEPT' | head -1 | cut -d: -f1)
  [ -n "$reject_ln" ] && [ -n "$accept_ln" ] && [ "$accept_ln" -gt "$reject_ln" ] || return 1
  # the per-slot veth rules must be APPENDED, never inserted: an insert lands
  # above that reject and hands job code the host's identity back
  matches "$code" '\-A FORWARD -i "\$veth" -j ACCEPT' || return 1
  ! matches "$code" '\-I FORWARD 1 -i "\$veth"' || return 1
  # the broker follows the slots out of loopback, and is closed on the VM's NIC
  matches "$code" '^Environment=CI_BROKER_HOST=0\.0\.0\.0$' || return 1
  matches "$code" 'INPUT 1 -i "\$ifc" -p tcp --dport "\$BROKER_PORT" -j REJECT' || return 1
  matches "$code" 'GCE_METADATA_HOST=%s:%s' || return 1
  # BOTH units must carry the resolver bind: joining a namespace does not bring
  # /etc/netns/<ns>/resolv.conf with it — that is `ip netns exec`'s doing, not
  # systemd's — and without it every service resolves against a 127.0.0.53 stub
  # that does not exist in the namespace (the v5.0.0 fault: registered agents
  # that never connected). Two occurrences: the daemon drop-in and the agent unit.
  [ "$(printf '%s\n' "$code" | grep -c '^BindReadOnlyPaths=/etc/netns/\$(slot_netns "\$idx")/resolv\.conf:/etc/resolv\.conf$')" -ge 2 ] || return 1
  # and the boot probe must check DNS the way a UNIT sees it, not the way
  # `ip netns exec` does — the latter passes on exactly the broken host
  matches "$code" 'nsenter --net="/run/netns/\$ns" getent ahostsv4' || return 1
  # and the boot probe reads back where the daemon actually landed
  matches "$code" 'readlink "/proc/\$dpid/ns/net"'
}

# Job containers are pulled by the SLOT's own rootless daemon, which has no
# credentials of its own. Without a credential helper every job declaring a
# container image from a private Artifact Registry dies at "Initialize
# containers" with "Unauthenticated request ... downloadArtifacts"
# (Borsh-Tablet-App, first pool run) — before a single step of the job runs.
has_registry_credentials() { # <file>
  local code
  code=$(code_of "$1")
  # a helper binary on PATH…
  matches "$code" '/usr/local/bin/docker-credential-cijob' || return 1
  # …that vends a BEARER token, i.e. asks the broker each time rather than
  # baking in one that expires an hour into a host's multi-day life
  matches "$code" 'oauth2accesstoken' || return 1
  matches "$code" 'service-accounts/default/token' || return 1
  # …mapped at Google registries only. credsStore would apply it to EVERY
  # registry, sending a Google access token to docker.io on the next public pull.
  matches "$code" 'credHelpers' || return 1
  matches "$code" '\$\{HOST_REGION\}-docker\.pkg\.dev' || return 1
  # …by EXACT hostname. docker resolves credHelpers as a map lookup on the
  # registry host, so a `*.pkg.dev` key is not an error — it is simply never
  # consulted, and the pull goes out anonymous exactly as with no config at all.
  ! matches "$code" '"\*\.pkg\.dev"|"\*\.gcr\.io"' || return 1
  ! matches "$code" '"credsStore"' || return 1
  # …and degrading to an ANONYMOUS pull when there is no token, in docker's own
  # vocabulary. A pool with no job service account starts no broker at all, and
  # a hard failure here would stop it pulling even a public image.
  matches "$code" 'credentials not found in native keychain' || return 1
  # installed before the slot users that reference it, and fatal — a host that
  # registers without it takes jobs it cannot start
  matches "$code" 'install_registry_credential_helper[[:space:]]*\\?$|install_registry_credential_helper[^|]*\|\|' || return 1
  matches "$code" 'die .could not install the registry credential helper' || return 1
  # and every slot actually gets the config naming it. It is written ONCE, into
  # the template every slot's home is built and rebuilt from (#110), rather than
  # into each home directly — a home written a second way is a home that drifts
  # from what a reset restores.
  matches "$code" 'write_docker_cred_helpers >"\$SLOT_TEMPLATE/\.docker/config\.json"'
}

# A slot user's $HOME outlives every job the slot serves, so anything a job
# leaves there is inherited by the next, unrelated job — a credential to reuse,
# or a hook, a dotfile or a shadowing binary to EXECUTE.
#
# It started as a credential story: a deploy workflow left ~/.config/gcloud
# behind and later jobs failed with "Unable to retrieve Identity Pool subject
# token ... token is expired", because the OIDC subject token had died hours
# earlier. The visible cost was a permanently cold Turbo cache (229 misses, 0
# hits, ~11 minutes per shard). The real cost was that a deploy identity was
# reachable by whatever pull request landed on that slot next, and only expiry
# stopped it being usable.
#
# Removing those two credential stores fixed one path and left the class (#110).
# What this pins now is the shape that closes the class: the home is REPLACED
# from a root-owned template rather than cleaned of known-bad paths, so
# `.gitconfig` core.hooksPath, `.bashrc`, `.local/bin` and a leftover
# workspace's `.git/hooks` all go without anyone having had to name them.
has_slot_reset() { # <file>
  local code
  code=$(code_of "$1")

  # both ends of the job, on the AGENT unit
  matches "$code" '^Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ci/job-hooks/job-started\.sh$' || return 1
  matches "$code" '^Environment=ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/ci/job-hooks/job-completed\.sh$' || return 1
  # …and unconditionally, not folded into the JOB_SA branch that gates BROKER_ENV:
  # a pool with no job identity is where an inherited credential is worst.
  ! matches "$code" 'if \[ -n "\$JOB_SA" \].*ACTIONS_RUNNER_HOOK' || return 1
  # plus the third reset, which is the one the two hooks cannot cover: an agent
  # killed mid-job never ran its completed hook, and a warm host reboots over
  # the previous boot's leftovers. `+` is what runs it as root despite User=.
  matches "$code" '^ExecStartPre=\+/opt/ci/job-hooks/slot-reset\.sh boot \$idx$' || return 1

  # the files exist, root-owned and not writable by the slots that execute them —
  # one set shared by every uid on the host, and one of them runs as root
  matches "$code" 'chown root:root "/opt/ci/job-hooks/job-\$stage\.sh"' || return 1
  matches "$code" 'chmod 0755 "/opt/ci/job-hooks/job-\$stage\.sh"' || return 1
  matches "$code" 'chown root:root /opt/ci/job-hooks/slot-reset\.sh' || return 1
  matches "$code" 'chmod 0755 /opt/ci/job-hooks/slot-reset\.sh' || return 1
  # installed before any agent registers, and fatal: an agent whose JOB_STARTED
  # hook points at a missing file takes work and fails all of it
  matches "$code" 'install_job_hooks \|\| die' || return 1
  # and the template it restores from is built before the slot users that need it
  matches "$code" 'seed_slot_template \|\| die' || return 1

  # REPLACEMENT, not cleaning. The home is emptied and the template copied back;
  # a predicate that only looked for an `rm` would have passed on the denylist
  # this replaces, so both halves are pinned.
  matches "$code" 'find "\\\$home" -mindepth 1 -maxdepth 1 -exec rm -rf' || return 1
  matches "$code" 'cp -a "\\\$SLOT_TEMPLATE/\." "\\\$home/"' || return 1
  # …and the previous job's workspace and tool cache go with it
  matches "$code" 'work="\\\$SLOT_ROOT/\\\$idx/_work"' || return 1
  # …while _temp and _actions stay at job start ONLY: the runner fills both
  # BEFORE the started hook runs, so wiping them there breaks the starting job.
  # At completed and boot they go with the rest, because _temp is where
  # RUNNER_TEMP lands and a credential written there must not outlive its job.
  matches "$code" '_temp\) \[ "\\\$keep_temp" = 1 \] && continue ;;' || return 1
  matches "$code" '\[ "\\\$stage" = started \] && keep_actions=1' || return 1
  matches "$code" '\[ "\\\$stage" = started \] && keep_temp=1' || return 1
  # a dangling symlink is invisible to -e, so -L is asked too, and the glob set
  # reaches ..name as well as .name — either one left behind is an entry that
  # survives every reset while the slot is still recorded clean
  matches "$code" '\[ -e "\\\$e" \] \|\| \[ -L "\\\$e" \] \|\| continue' || return 1
  matches "$code" '"\\\$work"/\.\[!\.\]\* "\\\$work"/\.\.\?\*' || return 1
  # and the workspace the runner already prepared for the STARTING job is
  # emptied, not unlinked — a plain `run:` step chdirs into it
  matches "$code" 'install -d -o "\\\$u" -g "\\\$u" -m 0755 "\\\$e"' || return 1

  # WHO gets reset is never the caller's choice when the caller is a slot: sudo
  # sets SUDO_UID from the real invoking user, so slot 2 cannot name slot 3.
  matches "$code" 'if \[ -n "\\\$\{SUDO_UID:-\}" \]' || return 1
  matches "$code" 'NOPASSWD: /opt/ci/job-hooks/slot-reset\.sh started, /opt/ci/job-hooks/slot-reset\.sh completed' || return 1
  # sudoers is validated before it is installed — a file there that does not
  # parse does not fail open on one rule, it stops every sudo on the host
  matches "$code" 'visudo -cqf "\$tmp"' || return 1

  # the tree being deleted as root comes from the account database, not from a
  # $HOME a job could have rewritten, and still has to look like a slot home
  matches "$code" 'home=\\\$\(getent passwd "\\\$u"' || return 1
  matches "$code" 'not a slot home' || return 1

  # a slot cannot forge its own clean bill of health: the marker lives in a
  # root-owned directory, and only the daemon's data root below it is slot-owned
  matches "$code" 'marker="\\\$SLOT_STATE/\\\$idx/clean"' || return 1
  matches "$code" 'install -d -o root -g root -m 0755 "\$SLOT_STATE/\$idx"' || return 1
  matches "$code" 'install -d -o "\$u" -g "\$u" -m 0700 "\$SLOT_STATE/\$idx/docker"' || return 1
  # …and a slot whose previous job never completed does not get to run the next
  # one: that is the single state in which _actions cannot be trusted either
  matches "$code" 'fail_after=1' || return 1

  # the daemon's data root is OUT of the home, which is what makes the home
  # disposable at all — leave it in and a reset deletes the store of a daemon
  # that is still holding it open
  matches "$code" 'ExecStart=/usr/bin/dockerd-rootless\.sh --data-root=/var/lib/ci-slot/%i/docker' || return 1

  # and the denylist this replaces is gone, not merely lengthened
  ! matches "$code" 'for d in "\\\$home/\.config/gcloud"' || return 1
}

# The container bridge must be born on the host's MTU.
#
# The veth pair is already matched to it; the bridge dockerd creates inside the
# namespace is not, and defaults to 1500 against a 1460 path. What that produces
# is not a size error but a truncated TLS stream — "socket disconnected before
# secure TLS connection was established", or a dependency that "was not found" —
# on large responses only, so the same build fails somewhere new each run.
has_container_mtu() { # <file>
  local code
  code=$(code_of "$1")
  # set on the DAEMON, so it becomes the default for the per-job
  # `github_network_*` bridge the runner creates and this script never sees
  matches "$code" 'daemon\.json' || return 1
  matches "$code" '"mtu"' || return 1
  # …and the per-driver default, which is the one the per-job network reads.
  # `mtu` alone leaves a `docker network create` bridge at 1500 — measured, on a
  # host, with docker 29.7.2 — and that is precisely the network the runner makes
  # for a `container:` job, so the obvious key alone fixes nothing observable.
  matches "$code" 'default-network-opts' || return 1
  matches "$code" 'com\.docker\.network\.driver\.mtu' || return 1
  # from the primary interface, not a literal: a literal is wrong on any estate
  # with jumbo frames or a tunnel, and wrong here is invisible
  matches "$code" 'mtu=\$\(primary_mtu\)' || return 1
  ! matches "$code" '"mtu": *1460' || return 1
  # written before the daemon starts — `mtu` is read at start, so a later write
  # leaves the running daemon and its existing networks on the old value — and
  # into the template, because the home it lands in is replaced between jobs
  matches "$code" '>"\$SLOT_TEMPLATE/\.config/docker/daemon\.json"'
}

# A baked container image is the one cached thing that is EXECUTED rather than
# read: every archive is `docker load`ed into every slot's daemon at boot, so
# whoever can write one runs their image in every slot on the host, for the rest
# of its life, with no further access needed.
#
# Two properties keep that shut, and neither is visible in a passing build —
# an image whose archives are writable builds exactly like one whose archives
# are not, so nothing but this test stands between the two.
has_baked_image_load() { # <file>
  local code joined
  code=$(code_of "$1")
  joined=$(joined_code_of "$1")

  # 1. The archives come from the root-owned tree, never from the shared cache.
  #    /opt/ci-cache is copied into a writable per-slot tree BY DESIGN (slots
  #    must update their own) and is documented as untrusted build input. Owning
  #    the files inside it would not help: write+execute on a non-sticky parent
  #    is enough to rename the whole directory aside and substitute another,
  #    checksums and all.
  matches "$code" 'dir="/opt/ci-images"' || return 1
  ! matches "$code" 'dir="/opt/ci-cache' || return 1

  # 2. The checksum line is selected by an EXACT filename field, not by looking
  #    for the name anywhere in the file. A substring match lets a planted
  #    `x.tar` borrow the entry belonging to the legitimate `x.tar.gz`:
  #    sha256sum -c then verifies that OTHER file, reports success, and the
  #    planted one is loaded unverified. Character 67 is where sha256sum's name
  #    field begins.
  matches "$code" 'substr\(\$0,67\)==f' || return 1
  ! matches "$code" 'grep -qF " \$base"' || return 1
  #    …and only a line whose first field is a hex digest counts, so GNU's
  #    backslash-escaped forms shift the name and fall out rather than matching.
  matches "$code" 'substr\(\$0,1,64\)' || return 1

  # 3. Fail closed. An archive with no entry of its own, or with more than one,
  #    is not loaded at all — every archive this fleet bakes gets exactly one.
  matches "$code" '\$nmatch" -ne 1' || return 1
  matches "$joined" 'sha256sum -c --status' || return 1

  # 4. Backgrounded, but still waited for. main() collects the PIDs and waits
  #    before returning: google-startup-scripts.service is a oneshot whose
  #    default KillMode=control-group SIGKILLs whatever is left in the cgroup
  #    when the script exits, which would kill these loads partway through and
  #    leave a half-loaded image behind.
  matches "$code" 'IMAGE_LOAD_PIDS' || return 1
  matches "$code" 'wait \$\{IMAGE_LOAD_PIDS\}' || return 1

  # 5. The load is recorded as USEFUL, not merely successful. The runner pulls
  #    the job's `container:` image unconditionally, and that pull recognises
  #    these layers only under the containerd image store, which preserves
  #    registry blob digests across save/load. Under the legacy graphdriver
  #    store every step here still succeeds and the job re-downloads the image
  #    anyway — the archive becomes ~900MB of image that buys nothing, and the
  #    only symptom is that UI jobs are slow. Nothing pins the store (docker-ce
  #    is installed unversioned), so the slot logs the one it actually got.
  matches "$code" 'io.containerd.snapshotter.v1' || return 1
  matches "$joined" 'docker info --format' || return 1
}

# The helper carries the trap it was written to avoid, so it is tested first.
# A match on the FIRST line of a large input is the worst case: with `grep -q`
# the writer is still pushing bytes when grep exits on the match, takes SIGPIPE,
# and pipefail reports the successful match as a failure.
if matches "$(seq 1 20000)" '^1$' && ! matches "$(seq 1 20000)" '^abc$'; then
  ok
else
  bad "matches() is unreliable on a large input — the pipefail/SIGPIPE trap is back, and every predicate below is now untrustworthy"
fi

# Nothing that mints a token may be an ARGUMENT (#107). /proc/<pid>/cmdline is
# world-readable, the slot units are not ordered against the startup script, and
# on a reboot of a WARM host the script runs while agents from the previous boot
# are executing job code — so a job can poll for the App JWT (which mints
# installation tokens for the whole installation) and the registration token
# (which joins an arbitrary machine to the pool) while they are being used.
#
# Silent when broken in both directions: the argv form works perfectly, and the
# hardening below is invisible until someone goes looking for it.
has_secrets_out_of_argv() { # <file>
  local code joined
  code=$(code_of "$1")
  joined=$(joined_code_of "$1")

  # The blanket rule, stated as the absence it is: no Authorization header on
  # any command line in this script, whatever the token.
  ! matches "$code" '-H "Authorization: Bearer' || return 1

  # curl reads it from a config file on a fd this shell owns instead. `printf`
  # is a builtin, so the value is never in any process's argv on the way there.
  matches "$code" 'header = "Authorization: Bearer %s"' || return 1
  matches "$code" '\-K <\(printf.*"\$jwt"\)' || return 1
  matches "$code" '\-K <\(printf.*"\$tok"\)' || return 1

  # config.sh is not curl. actions/runner takes every `configure` argument as
  # ACTIONS_RUNNER_INPUT_<NAME> and clears it from its own environment block, so
  # the token lands in /proc/<pid>/environ — owner-only — instead.
  ! matches "$joined" 'config\.sh([^|;&]|\\)*--token' || return 1
  matches "$code" '^  ACTIONS_RUNNER_INPUT_TOKEN="\$token"' || return 1
  # The NAME in argv, the VALUE in the environment. `sudo VAR=value` would have
  # put the token straight back into sudo's own cmdline.
  matches "$code" 'sudo -u "\$u" --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN' || return 1
  # And fails closed: sudo's env_reset dropping the variable is silent, so a
  # host that cannot carry it must not register rather than fall back to argv.
  matches "$joined" 'sudo_passes_env "\$u".*return 1' || return 1

  # Belt, so the next call site cannot reintroduce the class: both slot units
  # (they share a mount namespace, so one-sided is a coin toss) plus the host
  # /proc, which is what stops a `--pid=host` container from seeing around them.
  [ "$(printf '%s\n' "$code" | grep -cE '^ProtectProc=invisible')" -eq 2 ] || return 1
  matches "$code" 'remount,nosuid,nodev,noexec,hidepid=2 /proc' || return 1
  matches "$code" '^  harden_proc$'
}

# --- the real script must satisfy both ---------------------------------------
if has_disableupdate "$SCRIPT"; then
  ok
else
  bad "config.sh is not passed --disableupdate — a forced self-update will take every slot on the host OFFLINE (#2281)"
  # Show the joined invocation the predicate actually saw. The first occurrence
  # of this failure was green locally and red in CI on a byte-identical script,
  # and with only the verdict printed there was nothing to tell a genuine
  # regression apart from an artefact of how the text was assembled. Print the
  # evidence, so the next occurrence is read rather than guessed at.
  printf '  saw: %s\n' "$(joined_code_of "$SCRIPT" \
    | grep -n 'config\.sh' \
    | sed -e 's/\r/<CR>/g' -e '6,$d')"
fi

if has_metadata_fence "$SCRIPT"; then
  ok
else
  bad "job code is not fenced off 169.254.169.254 for every job uid (runner + each slot) and DOCKER-USER, or the fence does not fail closed (#1958)"
fi

if has_slot_isolation "$SCRIPT"; then
  ok
else
  bad "slots do not get their own user and their own container daemon — a job can reach the sibling slots' containers, tokens and workspaces (#10)"
fi

if has_slot_tmp_isolation "$SCRIPT"; then
  ok
else
  bad "slots share /tmp, or the agent does not share its daemon's — a fixed path there is owned by whichever slot ran first and every other slot gets EACCES on it (SOAP-To-REST #2017)"
fi

if has_port_isolation "$SCRIPT"; then
  ok
else
  bad "slots share the host network namespace — two slots publishing a service container's port take the same number and one dies with 'address already in use' (IntegrateIT #7749), or the namespace has no egress / no metadata fence / no broker"
fi

if has_container_runtime "$SCRIPT"; then
  ok
else
  bad "a slot can run a daemon but not a container — DNS is fenced off, or the slot has no user manager for runc's scope, or the boot probe still only asks whether the daemon is up"
fi

if has_registry_credentials "$SCRIPT"; then
  ok
else
  bad "job containers are pulled without credentials — every job whose image comes from a private registry fails at 'Initialize containers' with 'Unauthenticated request ... downloadArtifacts', or the helper is wired at every registry rather than Google's alone"
fi

if has_slot_reset "$SCRIPT"; then
  ok
else
  bad "a job inherits whatever the previous job left in the same slot — the home is not rebuilt from the template between jobs, so a leftover ~/.gitconfig hooksPath, ~/.bashrc, ~/.local/bin entry or workspace .git/hooks is executed by the next, unrelated job, and a deploy credential is left active for whatever pull request lands there next (#110)"
fi

if has_container_mtu "$SCRIPT"; then
  ok
else
  bad "job containers get dockerd's default 1500-byte MTU on a 1460-byte path — large TLS responses are black-holed and surface as a truncated handshake or a dependency that 'was not found', in a different place each run (Borsh-Tablet-App, first green pool run)"
fi

if has_secrets_out_of_argv "$SCRIPT"; then
  ok
else
  bad "a token that mints other tokens is passed as an argument, or the argv of one uid is still readable by another — a job running on a warm host can read the App JWT or the registration token out of /proc while the startup script uses them (#107)"
fi

if has_baked_image_load "$SCRIPT"; then
  ok
else
  bad "a job can choose the container image every OTHER slot on this host runs — the baked archives are loaded into every slot's daemon at boot, so an archive a slot can write (or a checksum line it can borrow from a neighbouring filename) is arbitrary code in every job that lands here afterwards"
fi

# --- mutation cases: prove the checks above can actually fail -----------------
mutate() { # <description> <sed-program> <predicate> — predicate must go false
  local desc="$1" prog="$2" pred="$3" tmp
  tmp=$(mktemp)
  sed "$prog" "$SCRIPT" >"$tmp"
  if "$pred" "$tmp"; then
    bad "mutation not detected: $desc"
  else
    ok
  fi
  rm -f "$tmp"
}

mutate "flag removed"              's/ --disableupdate//'                         has_disableupdate
mutate "flag only in a comment"    's/ --disableupdate/ \\\n  # --disableupdate/' has_disableupdate
mutate "flag only in a log line"   's/--unattended --replace --disableupdate/--unattended --replace/; s/^log()/log "--disableupdate"\nlog()/' has_disableupdate
mutate "fence address dropped"     's/169\.254\.169\.254/127.0.0.1/g'             has_metadata_fence
mutate "containers unfenced"       's/DOCKER-USER/OUTPUT/g'                       has_metadata_fence
mutate "fence no longer fatal"     's/fence_metadata || die/fence_metadata || log/' has_metadata_fence
mutate "slot users unfenced"       's/fence_uid "\$(slot_user/fence_uid "runner" #(slot_user/'  has_metadata_fence
mutate "agent back on the shared daemon" 's|^Environment=DOCKER_HOST=unix:///run/\$u/docker.sock$|Environment=DOCKER_HOST=unix:///var/run/docker.sock|' has_slot_isolation
mutate "shared daemon left running" 's/systemctl mask --now docker.service docker.socket/systemctl stop docker.service/' has_slot_isolation
mutate "slots share one account"   's/^User=\$u$/User=runner/'                     has_slot_isolation
mutate "agent starts without its daemon" 's/start_slot_dockerd "\$idx" || return 1/start_slot_dockerd "$idx" || true/' has_slot_isolation
mutate "mask failure ignored"      's/|| die "could not mask the rootful Docker daemon.*/|| true/'  has_slot_isolation
mutate "agent survives a crashed daemon" 's/^BindsTo=ci-dockerd@/#BindsTo=ci-dockerd@/'             has_slot_isolation
mutate "slot homes left world-readable"  's/chmod 0750 "\/home\/\$u"/chmod 0755 "\/home\/$u"/'      has_slot_isolation
mutate "DNS fenced with the token path"  's/dport 53 -m owner/dport 80 -m owner/'                    has_container_runtime
mutate "slot no longer lingers"          's/loginctl enable-linger/# loginctl enable-linger/'          has_container_runtime
mutate "daemon left on the system bus"   's|DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$uid/bus|DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket|' has_container_runtime
mutate "probe back to daemon-only"       's/slot_runtime_usable "\$idx" "\$u" || return 1/: /'         has_container_runtime
mutate "DNS probe runs outside the netns" 's/ip netns exec "\$ns" getent ahostsv4/getent ahostsv4/'      has_container_runtime
mutate "slots share /tmp again"          's/^PrivateTmp=yes$/PrivateTmp=no/'                           has_slot_tmp_isolation
mutate "only the daemon gets a private /tmp" 's/^JoinsNamespaceOf=ci-dockerd@\$idx\.service$/#&/'      has_slot_tmp_isolation

mutate "one namespace for every slot"        "s|printf 'ci-s%s'|printf 'ci-shared'|"                                         has_port_isolation
mutate "daemon left in the host namespace"   's|^NetworkNamespacePath=/run/netns/\$(slot_netns "\$idx")$||'                     has_port_isolation
mutate "slot namespace loses its egress NAT" 's|POSTROUTING -s 10.99.0.0/16 -o "$ifc" -j MASQUERADE|POSTROUTING -s 127.0.0.0/8 -o "$ifc" -j MASQUERADE|' has_port_isolation
mutate "veth rule inserted above the fence"  's|-A FORWARD -i "$veth" -j ACCEPT|-I FORWARD 1 -i "$veth" -j ACCEPT|'             has_port_isolation
mutate "broker left on host loopback only"   's|^Environment=CI_BROKER_HOST=0.0.0.0$|Environment=CI_BROKER_HOST=127.0.0.1|'     has_port_isolation
mutate "broker port left open on the NIC"    's|INPUT 1 -i "$ifc" -p tcp --dport "$BROKER_PORT" -j REJECT|INPUT 1 -i "$ifc" -p tcp --dport 9 -j ACCEPT|' has_port_isolation
mutate "boot probe stops checking the netns" 's|readlink "/proc/$dpid/ns/net"|readlink "/proc/self/ns/net"|'                    has_port_isolation
mutate "resolver bind dropped from a unit"   '0,\|^BindReadOnlyPaths=/etc/netns/$(slot_netns "$idx")/resolv.conf:/etc/resolv.conf$|s|||' has_port_isolation
mutate "unit-view DNS probe removed"         's|nsenter --net="/run/netns/$ns" getent ahostsv4|ip netns exec "$ns" getent ahostsv4|'      has_port_isolation
mutate "namespaced DNS exception dropped"    's|-d "$md_ip" -p "$proto" --dport 53 -j ACCEPT|-d "$md_ip" -p "$proto" --dport 9 -j ACCEPT|' has_port_isolation

mutate "registry helper removed"          's|/usr/local/bin/docker-credential-cijob|/usr/local/bin/true|g'          has_registry_credentials
mutate "no-token path made fatal"         's|credentials not found in native keychain|no credentials|'                      has_registry_credentials
mutate "helper widened to every registry" 's|"credHelpers"|"credsStore": "cijob", "x"|'                            has_registry_credentials
mutate "back to a wildcard key"           's|\${HOST_REGION}-docker.pkg.dev|"*.pkg.dev"|'                          has_registry_credentials
mutate "helper install not fatal"         's|\|\| die .could not install the registry credential helper.*|\|\| true|' has_registry_credentials
mutate "template left without the config" 's@write_docker_cred_helpers >"\$SLOT_TEMPLATE/\.docker/config\.json"@true >"$SLOT_TEMPLATE/.docker/config.json"@' has_registry_credentials

mutate "reset only after the job"         's@^Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=.*$@@'                   has_slot_reset
mutate "reset only before the job"        's@^Environment=ACTIONS_RUNNER_HOOK_JOB_COMPLETED=.*$@@'                 has_slot_reset
mutate "boot reset dropped"               's@^ExecStartPre=+/opt/ci/job-hooks/slot-reset.sh boot \$idx$@@'         has_slot_reset
mutate "hook install no longer fatal"     's@install_job_hooks || die.*@install_job_hooks || true@'                has_slot_reset
mutate "template build no longer fatal"   's@seed_slot_template || die.*@seed_slot_template || true@'              has_slot_reset
mutate "reset script left slot-writable"  's@chmod 0755 /opt/ci/job-hooks/slot-reset.sh@chmod 0777 /opt/ci/job-hooks/slot-reset.sh@' has_slot_reset
mutate "home cleaned, never replaced"     's@^cp -a "\\\$SLOT_TEMPLATE/\." "\\\$home/".*@:@'                       has_slot_reset
mutate "home never emptied"               's@^find "\\\$home" -mindepth 1.*@:@'                                    has_slot_reset
mutate "home taken from the environment"  's@^home=\\\$(getent passwd.*@home="\$HOME"@'                           has_slot_reset
mutate "slot names its own index"         's@if \[ -n "\\\${SUDO_UID:-}" \]@if [ -n "\${CI_SLOT:-}" ]@'           has_slot_reset
mutate "sudoers widened to any argument"  's@ started, /opt/ci/job-hooks/slot-reset.sh completed@@'                has_slot_reset
mutate "sudoers installed unvalidated"    's@visudo -cqf "\$tmp"@true@'                                            has_slot_reset
mutate "marker left forgeable by the slot" 's@install -d -o root -g root -m 0755 "\$SLOT_STATE/\$idx"@install -d -o "\$u" -g "\$u" -m 0755 "\$SLOT_STATE/\$idx"@' has_slot_reset
mutate "dirty slot allowed to run anyway" 's@^  fail_after=1$@  fail_after=0@'                                     has_slot_reset
mutate "work folder left alone"           's@work="\\\$SLOT_ROOT/\\\$idx/_work"@work="\$SLOT_ROOT/\$idx/_none"@'  has_slot_reset
mutate "starting job loses its actions"   's@keep_actions=1@keep_actions=0@'                                     has_slot_reset
mutate "prepared workspace unlinked"      's@install -d -o "\\\$u" -g "\\\$u" -m 0755 "\\\$e"@true@'                     has_slot_reset
mutate "credentials kept across the boundary" 's@_temp) \[ "\\\$keep_temp" = 1 \] && continue ;;@_temp) continue ;;@'  has_slot_reset
mutate "_temp wiped under the starting job" 's@\[ "\\\$stage" = started \] && keep_temp=1@keep_temp=0@'                    has_slot_reset
mutate "dangling symlink survives the reset" 's@\[ -e "\\\$e" \] || \[ -L "\\\$e" \] || continue@[ -e "\\\$e" ] || continue@' has_slot_reset
mutate "double-dot names never enumerated" 's@ "\\\$work"/\.\.?\*@@'                                                has_slot_reset
mutate "data root back inside the home"   's@ --data-root=/var/lib/ci-slot/%i/docker@@'                            has_slot_reset

mutate "daemon MTU config removed"        's|daemon\.json|daemon.txt|g'                                          has_container_mtu
mutate "MTU key dropped"                  's|"mtu"|"debug"|'                                                       has_container_mtu
mutate "per-driver default dropped"       's|default-network-opts|default-address-pools|'                          has_container_mtu
mutate "driver MTU option dropped"        's|com\.docker\.network\.driver\.mtu|com.docker.network.driver.name|'    has_container_mtu
mutate "MTU hardcoded"                    's|mtu=\$(primary_mtu)|mtu=1460|'                                        has_container_mtu
mutate "template left on the default MTU" 's@>"\$SLOT_TEMPLATE/\.config/docker/daemon\.json"@>/dev/null@'          has_container_mtu

mutate "archives back in the shared cache"   's|/opt/ci-images|/opt/ci-cache/images|g'                              has_baked_image_load
mutate "checksum match back to a substring"  's|substr(\$0,67)==f|index($0,f)|g'                                    has_baked_image_load
mutate "hex-digest guard dropped"            's|substr(\$0,1,64)|substr($0,1,0)|g'                                  has_baked_image_load
mutate "unchecked archives loaded again"     's|"\$nmatch" -ne 1|"$nmatch" -ge 0|'                                  has_baked_image_load
mutate "digest no longer verified"           's|sha256sum -c --status|cat|'                                         has_baked_image_load
mutate "loads left to the cgroup killer"     's|wait \${IMAGE_LOAD_PIDS}|:|'                                        has_baked_image_load
mutate "image store no longer reported"      's|io.containerd.snapshotter.v1|containerd|g'                          has_baked_image_load

mutate "App JWT back in curl argv"        's@-K <(printf.*\$jwt")@-H "Authorization: Bearer $jwt"@'          has_secrets_out_of_argv
mutate "registration token back in curl argv" 's@-K <(printf.*\$tok")@-H "Authorization: Bearer $tok"@'          has_secrets_out_of_argv
mutate "env prefix dropped from config.sh" '/^  ACTIONS_RUNNER_INPUT_TOKEN=/d'                                    has_secrets_out_of_argv
mutate "sudo stops preserving the variable" 's@--preserve-env=ACTIONS_RUNNER_INPUT_TOKEN @@'                      has_secrets_out_of_argv
mutate "--token added back alongside it"   's@--url "https://github.com/$OWNER@--token "$token" --url "https://github.com/$OWNER@' has_secrets_out_of_argv
mutate "silent env drop no longer fatal"   '/sudo will not pass an environment variable/s@; return 1; }@; }@'     has_secrets_out_of_argv
mutate "only one slot unit hides /proc"    '0,/^ProtectProc=invisible/s@^ProtectProc=invisible@#&@'               has_secrets_out_of_argv
mutate "hidepid weakened to 1"             's@hidepid=2@hidepid=1@'                                               has_secrets_out_of_argv
mutate "host /proc left readable"          '/^  harden_proc$/d'                                                   has_secrets_out_of_argv

printf 'host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
