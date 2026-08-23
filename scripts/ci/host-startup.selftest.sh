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

counts() { # <text> <ere> <n>
  local n
  n=$(printf '%s' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -eq "$3" ]
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
  matches "$code" '"\\\$held"/\.\[!\.\]\* "\\\$held"/\.\.\?\*' || return 1
  # root never walks a name the slot can swap. _work is renamed into a root-owned
  # 0700 holding directory for the duration and renamed back at the end, and a
  # _work that is already a symlink is refused rather than followed.
  matches "$code" 'held="\\\$SLOT_ROOT/\.reset/\\\$idx/_work"' || return 1
  matches "$code" 'if \[ -L "\\\$work" \]' || return 1
  matches "$code" 'mv -T -- "\\\$work" "\\\$held"' || return 1
  matches "$code" 'mv -T -- "\\\$held" "\\\$work"' || return 1
  matches "$code" 'install -d -o root -g root -m 0700 "\$SLOT_ROOT/\.reset/\$idx"' || return 1
  # and the boot reset in provision_slot_user does not run under an agent that a
  # warm reboot already brought up — that unit ran its own boot reset
  matches "$code" 'systemctl is-active --quiet "ci-runner@\$idx\.service"' || return 1
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

# A name the previous job left in the slot's image store is the one warm thing
# the next job EXECUTES while believing it fetched it: `docker run x` contacts no
# registry when a local `x` exists, and neither does a `FROM x` in a later build.
# #231 moved the store out of the home so it survives a reset — that is what
# makes the reset cheap, and it is also what leaves this open (#233).
#
# None of it is visible in a passing build: the poisoned job succeeds.
has_local_tag_prune() { # <file>
  local code
  code=$(code_of "$1")

  # 1. At the resets that END a job, never at the one that starts it — at
  #    `started` the runner has already loaded the image the job is about to use.
  matches "$code" 'if \[ "\\\$stage" != started \] && \[ "\\\$prune" = 1 \]; then' || return 1

  # 2. A REGISTRY DIGEST is what buys a tag its life, and a job cannot write one:
  #    `docker tag` and `docker build -t` produce none; only a pull or a push does.
  matches "$code" 'RepoDigests' || return 1
  matches "$code" '\[ "\\\$ndig" = 0 \] \|\| continue' || return 1

  # 3. …or the boot manifest, matched by image ID and NEVER by name. Match the
  #    name and a job blesses its own image by retagging it onto a baked one.
  matches "$code" 'baked="\\\$SLOT_STATE/\\\$idx/baked-images"' || return 1
  matches "$code" 'grep -qxF -- "\\\$id" "\\\$baked"' || return 1

  # 4. The NAME goes, not the content. `--no-prune` on one reference of a
  #    multiply-referenced image untags it and leaves the layers in the store, so
  #    a rebuild is still warm — deleting the content instead would be the cold
  #    start per job that the whole warm layer exists to end.
  matches "$code" 'docker rmi --no-prune -- "\\\$t"' || return 1
  ! matches "$code" 'docker image prune' || return 1

  # 5. The manifest it reads is written by root at boot from what `docker load`
  #    actually reported, by ID — a name there would be forgeable by the same
  #    retag as above.
  matches "$code" "docker image inspect --format '\{\{\.Id\}\}' -- \"\\\$ref\"" || return 1
  matches "$code" 'chown root:root "\$manifest_tmp"' || return 1
  # …and installed with ONE rename, so a reset that lands mid-boot reads either
  #    the previous complete list or the new complete list. A manifest appended
  #    to in place would have a window in which the entries not yet written look
  #    exactly like an image nobody baked — and get untagged.
  matches "$code" 'mv -T -- "\$manifest_tmp" "\$manifest"' || return 1

  # 6. A daemon that is not there only logs: it already fails the next job at its
  #    first docker line, and refusing the marker on top of that turns a slot with
  #    no dockerd into a slot that also fails every job for a reason it never
  #    names. A tag that will NOT go is the opposite — that slot is poisoned, and
  #    the clean marker is exactly the claim it must not get.
  matches "$code" 'no docker socket at' || return 1
  matches "$code" 'could not drop local image tag' || return 1
}

# A stack the anchor brought up with `docker compose up -d` does not stop when
# the job that started it ends -- nothing in the runner's lifecycle reaches into
# a detached rootless container. Before the port band that was untidy; with a
# PERSISTENT band it is a correctness bug wearing two faces, both silent. The
# ports stay bound, so the next run assigned this slot gets address-in-use in a
# job that changed nothing; or the stack stays up and the next run CONNECTS to a
# finished pull request's database -- passwordless, in the example the contract
# documents.
has_container_reclaim() { # <file>
  local code
  code=$(code_of "$1")

  # 1. Every container, running or not, and by boundary rather than by TTL: the
  #    resets that END a job are exactly the points at which no job of this slot
  #    is running. A HELD slot is spared by the same gate that spares its image
  #    tags, because the run's later jobs land here and reuse the stack.
  matches "$code" 'docker ps --all --quiet --no-trunc' || return 1
  matches "$code" 'docker rm --force --volumes -- \\\$cids' || return 1

  # 2. BEFORE the tags. A running container holds a reference to its image and
  #    the untag would fail on it.
  local before after
  before=$(printf '%s\n' "$code" | grep -n 'docker ps --all --quiet' | head -1 | cut -d: -f1)
  after=$(printf '%s\n' "$code" | grep -n 'docker image ls --all --quiet' | head -1 | cut -d: -f1)
  [ -n "$before" ] && [ -n "$after" ] && [ "$before" -lt "$after" ] || return 1

  # 3. The volumes go with them, named ones included -- `docker compose` names
  #    its volumes after the project, so a survivor is the previous pull
  #    request's database handed to the next run under the same name. The older
  #    spelling is tried before the missing flag is called a failure, or a host
  #    on Docker 22 would refuse the marker for every job it ever runs.
  matches "$code" 'docker volume prune --force --all' || return 1
  matches "$code" 'docker volume prune --force >' || return 1
  matches "$code" 'docker network prune --force' || return 1

  # 4. Fail closed. A container this reset could not remove still holds the
  #    band's ports, and the clean marker is exactly the claim it must not get.
  matches "$code" 'could not remove the containers left behind' || return 1
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

# A slot must be TOLD what fraction of the host it is. `nproc` inside a slot
# reports the whole machine — slots are separated by user, network namespace and
# dockerd, and deliberately not by CPU — so a workflow that sizes its worker
# pool from `nproc` sizes it for a host it shares with K-1 siblings. Measured on
# the IntegrateIT pool 2026-08-22: 4 slots on 16 vCPU, each test job budgeting
# for 16, roughly 3x oversubscribed. Nothing errors. The job just runs slowly
# and its per-test timeouts start expiring, which reads as a flaky suite and
# gets "fixed" by a re-run — so the variables are pinned here.
has_slot_share() { # <file>
  local code
  code=$(code_of "$1")
  # the share is DERIVED from the host and the slot count, not a literal
  matches "$code" 'Environment=CI_SLOT_VCPUS=\$\(\( cpus / SLOTS' || return 1
  matches "$code" 'Environment=CI_SLOT_MEM_MB=' || return 1
  # and the host's own totals, so a job that wants to reason about the machine
  # can, without guessing which of the two `nproc` means
  matches "$code" 'Environment=CI_HOST_VCPUS=' || return 1
  matches "$code" 'Environment=CI_HOST_SLOTS=' || return 1
  # never zero: integer division on a host with fewer vCPU than slots would
  # otherwise hand a job a worker budget of 0
  matches "$code" 'cpus / SLOTS > 0 \? cpus / SLOTS : 1' || return 1
  # computed unconditionally — unlike CACHE_ENV, which is empty for an unseeded
  # slot. A slot always has a share.
  matches "$code" 'local SHARE_ENV; SHARE_ENV=\$\(share_env\)' || return 1
  # and actually reaching the unit, which is the only part the job can observe
  matches "$code" '^\$SHARE_ENV$'
}


# The shared-infrastructure port band (adr-pr-host-affinity.md §3.2). Four parts,
# and every one of them is silent when broken: a slot that publishes a database
# nobody can reach fails as "the Windows job cannot connect", which reads as a
# firewall problem, a DNS problem, or a flaky test -- anything but the missing
# rule that caused it.
has_shared_infra_band() { # <file>
  local code
  code=$(code_of "$1")
  # the band is derived from $SLOTS, not from a hardcoded slot count
  matches "$code" '^slot_band_min\(\)' || return 1
  matches "$code" '^slot_band_max\(\)' || return 1
  matches "$code" 'slot_band_max "\$SLOTS"' || return 1
  # a 1:1 DNAT per slot, matched on the host ADDRESS. An `-i` match here would
  # exclude a sibling slot, whose packets arrive on cis<N> -- the main consumer.
  matches "$code" 'PREROUTING -d "\$addr" -p tcp --dport "\$bmin:\$bmax"' || return 1
  matches "$code" 'DNAT --to-destination "\$nsip"' || return 1
  # the forward allow is scoped to what the DNAT produced, not to an interface
  # pair, so it survives #249 removing the broad per-veth accepts
  matches "$code" 'ctstate DNAT --ctorigdst "\$baddr"' || return 1
  matches "$code" 'ctorigdstport "\$bspan_min:\$bspan_max"' || return 1
  # ...and scoped to TCP, like the DNAT it mirrors. `--ctorigdstport` carries no
  # protocol of its own, so without this the accept was wider than the rule that
  # produces the traffic it exists for.
  matches "$code" 'FORWARD -p tcp -m conntrack --ctstate DNAT' || return 1
  # The band is reserved out of the ephemeral range. It sits above 32768, so
  # without this a host socket can be handed a band port and hold it, and the
  # slot that publishes there fails to bind -- on a different port every boot.
  # Merged with what is already reserved, never stamped over it.
  matches "$code" 'sysctl -qw "net.ipv4.ip_local_reserved_ports=' || return 1
  matches "$code" '\$\{reserved:\+\$reserved,\}\$want' || return 1
  matches "$code" '< /proc/sys/net/ipv4/ip_local_reserved_ports' || return 1
  # and the slot is told its own band, or a job cannot know where to publish
  matches "$code" '^Environment=CI_SHARED_INFRA_ADDR=' || return 1
  matches "$code" '^Environment=CI_SHARED_INFRA_PORT_MIN=' || return 1
  matches "$code" '^Environment=CI_SHARED_INFRA_PORT_MAX=' || return 1
}

# The arithmetic itself, EVALUATED rather than matched. A text predicate cannot
# tell 35000+idx*100 from 35000+idx*10, and the second one overlaps every band
# with the next -- two slots publishing the same port, which is the collision
# the whole design exists to make impossible.
band_arithmetic_disjoint() { # <file>
  local defs i j amin amax bmin bmax
  defs=$(sed -n '/^CI_BAND_BASE=/,/^slot_band_max()/p' "$1")
  ( eval "$defs"
    for i in 1 2 3 4 5 6 7 8; do
      amin=$(slot_band_min "$i"); amax=$(slot_band_max "$i")
      # a band is 100 wide and starts where the formula says
      [ "$amin" -eq $((35000 + i * 100)) ] || exit 1
      [ $((amax - amin)) -eq 99 ]          || exit 1
      for j in 1 2 3 4 5 6 7 8; do
        [ "$i" -lt "$j" ] || continue
        bmin=$(slot_band_min "$j"); bmax=$(slot_band_max "$j")
        # disjoint, in both directions
        { [ "$amax" -lt "$bmin" ] || [ "$bmax" -lt "$amin" ]; } || exit 1
      done
    done )
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

if has_local_tag_prune "$SCRIPT"; then
  ok
else
  bad "a job can leave an image name behind for the next, unrelated job on the same slot to run as if it had fetched it — the store survives the reset by design (#231) and nothing drops the tags no registry digest and no boot manifest vouches for (#233)"
fi

if has_container_reclaim "$SCRIPT"; then
  ok
else
  bad "a stack the last run left detached keeps this slot's band ports bound and its database reachable — the next run assigned this slot either cannot start its own services or connects to a finished pull request's, and neither says so"
fi

if has_shared_infra_band "$SCRIPT"; then
  ok
else
  bad "the shared-infrastructure port band is not published: a slot's stack is unreachable from a sibling slot and from the Windows host, which is the whole of rule 3 (adr-pr-host-affinity.md §3.2)"
fi

if band_arithmetic_disjoint "$SCRIPT"; then
  ok
else
  bad "the per-slot port bands are not 100 wide and disjoint — two slots can be handed the same host port, which is the collision the slot netns exists to prevent"
fi

# --- the pin hold ------------------------------------------------------------
#
# One workflow run keeps one host (adr-pr-host-affinity.md §3.1), and every
# failure of that mechanism is SILENT in the way this file exists to catch: a
# hold that is never taken gives a pull request two hosts and a database the
# second one cannot reach, and a hold that is never released leaves a host
# serving nobody until the controller retires it hours later. Neither reports an
# error at boot; both look like a slow fleet.
#
# The properties below are the ones a later edit is most likely to undo while
# leaving the script reading as correct.
has_pin_hold() { # <file>
  local code
  code=$(code_of "$1")

  # installed, and FATAL. A host that registered agents without this takes work
  # it cannot be pinned to, which is the failure with no error message.
  matches "$code" 'install_pin_hold \|\| die' || return 1

  # MONOTONIC. There is no verb that shortens or removes a hold: a co-tenant
  # slot must be able to keep the host alive and must not be able to hand
  # somebody else's run away mid-run. Expiry is the only end there is.
  matches "$code" 'expected --run <id> \[--ttl <duration>\] \[--reserve-slot\], or renew, or status' || return 1
  ! matches "$code" 'pin-hold\.sh release' || return 1
  # …and renew extends by the TTL RECORDED IN THE HOLD, never one the caller
  # supplies, so "renew" cannot be spelled as "expire in one second".
  matches "$code" 'new=\\\$\(\(now \+ R_TTL\)\)' || return 1
  matches "$code" '\[ "\\\$new" -gt "\\\$R_EXPIRY" \] \|\| new=\\\$R_EXPIRY' || return 1

  # ADMISSION, not request. A second run asking for a host that is already held
  # is REFUSED and continues unpinned. Granting both is how several runs
  # starting together take every slot on one host and then wait out each
  # other TTLs — a deadlock assembled entirely out of successful steps.
  matches "$code" 'may not reserve this host' || return 1
  # and the refusal is exit 0 with pinned=0, because an anchor that cannot pin
  # still has a run to do
  matches "$code" 'echo "pinned=0"' || return 1

  # WHICH slot is speaking is never an argument, exactly as in slot-reset.sh
  matches "$code" 'refusing: reserve must come from a slot' || return 1
  matches "$code" 'is not a slot user' || return 1
  # and the run id reaches a file, a log line and a guest attribute, so it is
  # shape-checked rather than quoted and hoped for
  matches "$code" 'is not a usable run id' || return 1
  # the TTL is clamped: a job does not get to hold a host for a day
  matches "$code" '\[ "\\\$ttl" -le "\\\$PIN_MAX_TTL" \] \|\| ttl=\\\$PIN_MAX_TTL' || return 1

  # the record is root-owned and readable, never slot-writable — a slot that
  # could write it could pin the host to a run of its choosing, or unpin one
  matches "$code" 'chown root:root "\$PIN_DIR"' || return 1
  matches "$code" 'chmod 0755 "\$PIN_DIR"' || return 1
  # …and replaced by rename, never written over in place: a reader that saw a
  # truncated record would read it as NO hold, which is the one reading that
  # releases a host somebody is using
  matches "$code" 'mv -f -- "\\\$tmp" "\\\$RECORD"' || return 1
  # an unreadable record is KEPT and the host left alone, for the same reason
  matches "$code" 'the hold record does not parse' || return 1

  # sudoers grants the three verbs and nothing else, and is validated before it
  # is installed
  matches "$code" 'NOPASSWD: /opt/ci/job-hooks/pin-hold\.sh --run \*, /opt/ci/job-hooks/pin-hold\.sh renew --run \*, /opt/ci/job-hooks/pin-hold\.sh status' || return 1
  # …and the BARE verb is not in it. `renew` with no id renews whatever hold is
  # on the host, so leaving it permitted hands every job on the box the ability
  # to feed a stranger's hold — with the ownership check right there, unreached.
  ! matches "$code" 'pin-hold\.sh renew,' || return 1
  matches "$code" 'refusing: renew needs --run <id>' || return 1
  matches "$code" 'visudo -cqf "\$tmp"' || return 1

  # THE HOST RENEWS, NOT THE WORKFLOW. A consumer job running inside a
  # `container:` cannot reach /usr/local/bin/ci-pin-hold at all, and those are
  # the runs long enough for a TTL to matter — so the renewal is in the job hook
  # every job goes through, and it is never fatal.
  matches "$code" "sudo -n /opt/ci/job-hooks/pin-hold.sh renew --run .\\\$\{GITHUB_RUN_ID:-\}." || return 1
  # …on job-STARTED only. A renewal in the completed hook pushes the expiry a
  # full TTL past the last job of the run, over a host nothing is using.
  matches "$code" 'if \[ "\$stage" = started \]; then' || return 1
  matches "$code" 'renewed on job-started only' || return 1
  # …and it names the run, so a job of some OTHER run cannot feed this hold. It
  # was every job renewing every hold: after the owner finished or was
  # cancelled, an unrelated job on any slot pushed the expiry forward again and
  # the stopped slot, the surviving stack and the removal veto never ended.
  matches "$code" 'renew_run" != "\\\$R_RUN"' || return 1

  # THE SWEEPER STOPS THE AGENT BEFORE IT TEARS ANYTHING DOWN, and fails closed
  # if it cannot. The live branch's stop can miss -- the hold can expire before
  # the slot ever goes idle -- and reaching teardown with the agent up deletes
  # the containers, home and workspace of a job running right now.
  matches "$code" 'agent stopped before teardown' || return 1
  matches "$code" 'could not stop the agent — NOT tearing down' || return 1

  # A FAILED ENUMERATION IS NOT AN EMPTY ONE. `docker ps` timing out left ids
  # empty with the failure dropped, so removal was skipped, teardown was called
  # a success, the hold was deleted and the agent came back over a live stack.
  matches "$code" 'could not list the run.s containers' || return 1

  # THE RECORD OUTLIVES A FAILED START. Removing it and then failing to start
  # left no state to retry from and the slot stayed down for the life of the
  # host, with the controller keeping that host at the floor rather than
  # replacing it.
  matches "$code" 'the agent would not start — the hold stays in place' || return 1

  # IDLE NEEDS TWO WITNESSES. The clean marker is on disk from the completed
  # hook until the NEXT job's started hook, so a tick in either window stopped
  # the unit under a live job -- through the mechanism added to avoid that.
  matches "$code" 'pgrep -u "\\\$u" -f .Runner\\.Worker.' || return 1

  # A PREVIOUS-BOOT HOLD IS PUBLISHED AS RELEASED, not only logged. The instance
  # answers the same host-* label across a reboot, so nothing else can tell the
  # controller the promised stack is gone.
  counts "$code" '^ *publish ""$' 3 || return 1

  # A HELD slot keeps its local image tags. The run's later jobs land on this
  # slot and reuse what the anchor built, and a compose-built image carries no
  # RepoDigest and was not baked at boot — precisely what the prune removes.
  matches "$code" 'held by a live run' || return 1
  matches "$code" 'if \[ "\\\$stage" != started \] && \[ "\\\$prune" = 1 \]' || return 1

  # ADMISSION IS SERIALISED. Check-then-write was not exclusive: two anchors on
  # two idle slots could both read "free", both write, and both be told
  # pinned=1, with the second rename silently discarding the first reservation.
  # The atomic rename was never the race. The sweeper takes the same lock, so
  # "free" and "being released right now" stop looking identical.
  matches "$code" 'flock -w 15 9' || return 1
  matches "$code" 'take_lock "the hold" \|\| exit 1' || return 1
  matches "$code" 'take_lock "the renewal" \|\| exit 1' || return 1
  matches "$code" 'flock -w 10 9 \|\| \{ say "another caller holds the admission lock' || return 1

  # AN EXPIRED RESERVATION IS NOT A FREE HOST. Between the expiry and the next
  # 30-second tick the record still describes a stopped agent over a live stack,
  # and overwriting it there is how a slot leaks: the old stack survives, the
  # old agent stays down, and the new run reserves a different slot.
  matches "$code" 'the sweeper has not released it' || return 1

  # A REPEATED CLAIM BY THE SAME RUN may add a reservation and may do nothing
  # else. The record is world-readable, so matching R_RUN is an identity claim
  # and not proof of one; keeping the reserved slot and the later expiry leaves
  # a co-tenant nothing to move and no way to shorten a hold.
  matches "$code" 'slot_to_write=\\\$R_SLOT' || return 1
  matches "$code" '\[ "\\\$R_EXPIRY" -gt "\\\$expiry_to_write" \] && expiry_to_write=\\\$R_EXPIRY' || return 1

  # A FLAG THAT NEEDS A VALUE GETS ONE. `shift 2 || break` accepted `--ttl` with
  # nothing after it and fell through to the default.
  matches "$code" 'refusing: --ttl needs a value' || return 1
  matches "$code" 'refusing: --run needs a value' || return 1

  # THE BOOT ID IS PART OF THE PRUNE DECISION. On a warm reboot the runner unit
  # runs this reset before the sweeper can call the old record orphaned, and an
  # unexpired record from the PREVIOUS boot spared image tags for containers
  # that did not survive the guest.
  matches "$code" 'h_boot" = "\\\$\(cat /proc/sys/kernel/random/boot_id' || return 1

  # A DURATION, because that is what the contract publishes (`CI_PIN_TTL: 90m`)
  # and what a workflow author writes beside a timeout-minutes they already own.
  matches "$code" 'is not a duration' || return 1
  matches "$code" '\*\[0-9\]m\) n="\\\${t%m}"; unit=60 ;;' || return 1

  # A ONE-SLOT HOST CANNOT RESERVE. The reservation takes the slot out of
  # service, and taking the only slot out of service is a host that serves
  # nobody — including the run that asked. Refused, not silently downgraded.
  matches "$code" 'refusing --reserve-slot: this host has one slot' || return 1

  # A HOLD DOES NOT SURVIVE A REBOOT. Rootless containers do not outlive the
  # guest, so a hold carried across one pins a live host to a stack that is
  # already gone, and fails the run slowly instead of at once.
  matches "$code" "printf 'boot=%s" || return 1
  matches "$code" 'releasing it as orphaned' || return 1

  # THE SWEEPER IS THE ONLY THING THAT ENDS A HOLD, and it runs on a timer
  # because expiry is not an event anybody delivers.
  matches "$code" '^OnUnitActiveSec=30$' || return 1
  matches "$code" '^AccuracySec=5$' || return 1
  matches "$code" 'systemctl enable --now ci-pin-sweep\.timer' || return 1

  # It takes a held slot out of service once its job ends — not the completed
  # hook, which runs inside the agent unit and would SIGTERM itself mid-report,
  # and not the controller, which never opens a shell on a host that is healthy
  # and busy. Gated on the clean marker, which is what makes "idle" a fact
  # rather than a guess: a slot running a job has no marker.
  matches "$code" '\[ "\\\$reserve" = 1 \] && \[ -f "\\\$marker" \] &&' || return 1
  matches "$code" 'systemctl is-active --quiet "ci-runner@\\\$slot\.service"; then' || return 1
  matches "$code" 'systemctl stop "ci-runner@\\\$slot\.service"' || return 1

  # …and at expiry it tears the run's stack down, resets, and only THEN clears
  # the record and starts the agent. FAIL CLOSED: a teardown that did not finish
  # leaves the agent DOWN and the hold in place for the next sweep, because a
  # slot handed back on a clean bill of health nobody earned is worse than a
  # slot that is missing.
  matches "$code" 'docker rm --force' || return 1
  matches "$code" '/opt/ci/job-hooks/slot-reset\.sh completed "\\\$slot"' || return 1
  matches "$code" 'if \[ "\\\$rc" != 0 \]; then' || return 1
  matches "$code" 'rm -f -- "\\\$RECORD"' || return 1
  matches "$code" 'the agent stays DOWN' || return 1
  matches "$code" 'systemctl start "ci-runner@\\\$slot\.service"' || return 1
}

# #250 shipped the PER-RESET half of #233: a tag survives a reset only with a
# registry digest or an id in the boot manifest. This is the periodic half. The
# manifest is written once, at boot, and a host that runs for days between
# reboots is otherwise trusting a fact established then and never revisited.
has_baked_image_audit() { # <file>
  local code
  code=$(code_of "$1")

  # Installed, armed, and NOT fatal. It is a detector over a control that already
  # runs at every job boundary, so a host that could not install it still has the
  # protection — refusing to serve over that would cost more than it buys.
  matches "$code" 'install_baked_image_audit \|\|$' || return 1
  ! matches "$code" 'install_baked_image_audit \|\| die' || return 1
  matches "$code" 'systemctl enable --now ci-baked-image-audit\.timer' || return 1
  matches "$code" '^OnUnitActiveSec=900$' || return 1

  # PERIODIC, and that is the whole point: nothing delivers "the store changed
  # under the manifest" as an event. The first run waits, because the boot-time
  # `docker load` only moves a manifest into place when it finishes.
  matches "$code" '^OnBootSec=300$' || return 1
  # A oneshot with no deadline blocks its own timer forever.
  matches "$code" '^TimeoutStartSec=180$' || return 1

  # THE FOUR FINDINGS. An id the store no longer has; the manifest's own
  # ownership; the root-owned namespace above it; and the daemon's data root.
  # `say`, not just the sentence: a finding computed and never emitted reads
  # exactly like a clean host, and it is one deleted word away at all times.
  matches "$code" 'say "slot \\\$idx: the manifest names \\\$id, which the store no longer has' || return 1
  matches "$code" 'not root:root:644' || return 1
  matches "$code" 'not root:root:755' || return 1
  matches "$code" 'not \\\$u:\\\$u:700' || return 1

  # `stat` follows a symlink, so the link test comes FIRST or a slot-planted
  # link to a root-owned path reads as compliant.
  matches "$code" '\[ -L "\\\$manifest" \]' || return 1
  matches "$code" '\[ -L "\\\$droot" \]' || return 1

  # The failure policy is the reset's. A poisoning withdraws the marker; a
  # daemon that is merely absent logs and takes nothing.
  # Spelled with the `if`: the reset hook removes a marker too, so the bare
  # `rm` matches whether or not the audit still withdraws anything.
  matches "$code" 'if rm -f -- "\\\$marker"; then' || return 1
  matches "$code" 'clean marker withdrawn' || return 1
  matches "$code" 'no docker socket at \\\$sock -- the manifest.s ids were not checked' || return 1

  # Never `grep -q` on a pipeline whose status is the answer: -q exits on the
  # first match, the in-process writer dies of EPIPE, and pipefail reports a
  # pipeline that FOUND its id as one that did not.
  matches "$code" 'grep -cxF -- "\\\$id" >/dev/null' || return 1

  # A MISSING manifest is not a finding — most pools bake nothing, and the prune
  # reads an absent file as an empty one.
  matches "$code" 'elif \[ -f "\\\$manifest" \]' || return 1
}

# The scripts this boot script WRITES are never run by anything here, so a
# syntax error in any of them survives every text predicate above and first
# appears on a live host as a slot that will not pin — or, worse, a sweeper that
# exits before it can hand one back. So they are extracted and parsed.
#
# `\$` in the heredoc is a runtime `$`; unescaping it is what turns the emitted
# text back into the file the host actually gets.
generated_scripts_parse() { # <file>
  local name body tmp rc=0
  for name in pin-hold pin-sweep baked-image-audit; do
    body=$(awk -v n="$name" '
      $0 == "  cat >/opt/ci/job-hooks/" n ".sh <<EOF" { on = 1; next }
      on && $0 == "EOF" { exit }
      on { print }
    ' "$1" | sed 's/\\\$/$/g')
    # An empty extraction means the anchor moved, and an empty file parses
    # clean — which would report a missing check as a passing one.
    [ -n "$body" ] || { rc=1; continue; }
    tmp=$(mktemp)
    printf '%s\n' "$body" >"$tmp"
    bash -n "$tmp" >/dev/null 2>&1 || rc=1
    rm -f "$tmp"
  done
  [ "$rc" = 0 ]
}

if has_pin_hold "$SCRIPT"; then
  ok
else
  bad "a workflow run cannot keep the host it landed on, or cannot give it back — an unpinnable host hands one pull request two of them and a database the second cannot reach, and a hold nobody ends leaves a host serving nobody until the controller retires it (adr-pr-host-affinity.md §3.1)"
fi

if has_baked_image_audit "$SCRIPT"; then
  ok
else
  bad "nothing re-checks the baked-image manifest after boot — on a host that runs for days the prune in #250 is deciding which image tags may survive a reset from a claim made once, at boot, over a store that has changed since (issue #251)"
fi

if generated_scripts_parse "$SCRIPT"; then
  ok
else
  bad "one of the pin-hold scripts this boot script writes does not parse — every text check above still passes, and the failure first appears as a host that silently will not pin"
fi

# --- the remote build cache, whose every failure is silent --------------------
#
# This layer has no loud failure mode at all. A slot pointed at a dead server, a
# slot pointed at its own loopback where nothing listens, a server reachable
# from off the host, a token published before the server answered — each of them
# produces builds that run, pass, and are slower than they should be, which is
# how the one hand-wired build cache in this fleet stayed cold for weeks under
# green runs.
#
# Four properties, and one of them is a security property rather than a speed
# one: the port must be REJECTed on the primary interface, because the server
# reads one repository's build artifacts out of a bucket nothing off this host
# is entitled to read.
has_turbo_cache() { # <file>
  local code joined
  code=$(code_of "$1")
  joined=$(joined_code_of "$1")

  # 1. The slot is told about the cache only when the server ANSWERED. The
  #    token is published inside the readiness loop for exactly this reason, and
  #    install_slot's guard is what turns "the server did not come up" into "no
  #    cache" rather than a connection refused per task.
  matches "$code" 'TURBO_TOKEN="\$tok"' || return 1
  matches "$code" 'if \[ -n "\$TURBO_TOKEN" \]; then' || return 1
  matches "$code" '/v8/artifacts/status' || return 1

  # 2. The slot's own loopback is not where the server is. Every slot has its
  #    own network namespace, so TURBO_API must name the slot's GATEWAY — the
  #    same wrinkle that makes the credential broker unreachable on 127.0.0.1.
  matches "$joined" 'Environment=TURBO_API=http://%s:%s' || return 1
  matches "$joined" 'TURBO_API=.*slot_gw_ip' || return 1

  # 3. The variables reach the unit. Computed and never interpolated is a whole
  #    layer that silently does nothing.
  matches "$code" '^\$TURBO_ENV$' || return 1

  # 4. Nothing off this host reaches it.
  matches "$joined" 'INPUT 1 -i "\$ifc" -p tcp --dport "\$TURBO_PORT" -j REJECT' || return 1

  # 5. It never takes the host down. A build cache that refuses to register
  #    agents has turned a speed layer into an outage.
  ! matches "$joined" 'start_turbo_cache \|\| die'
}

if has_turbo_cache "$SCRIPT"; then
  ok
else
  bad "the remote build cache is mis-wired — a slot pointed at a dead or unreachable server, a cache the network can reach, or a boot that dies over it; every one of those presents as builds that pass and are slow, which is the failure this layer exists to end"
fi

# --- mutation cases: prove the checks above can actually fail -----------------
if has_slot_share "$SCRIPT"; then
  ok
else
  bad "a slot does not publish its share of the host, so a job sizing itself from nproc sizes for the whole machine and oversubscribes it K-fold - slow jobs and expiring per-test timeouts that a re-run appears to fix"
fi

mutate() { # <description> <sed-program> <predicate> — predicate must go false
  local desc="$1" prog="$2" pred="$3" tmp
  tmp=$(mktemp)
  sed "$prog" "$SCRIPT" >"$tmp"
  if cmp -s "$SCRIPT" "$tmp"; then
    # The sed program matched nothing, so the predicate was handed the REAL file
    # and passing proves nothing. Left undetected this reads as a live mutation
    # for as long as the anchor stays stale.
    bad "mutation did not apply (stale anchor): $desc"
  elif "$pred" "$tmp"; then
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
mutate "double-dot names never enumerated" 's@ "\\\$held"/\.\.?\*@@'                                                has_slot_reset
mutate "root walks a name the slot can swap" 's@mv -T -- "\\\$work" "\\\$held"@true@'                              has_slot_reset
mutate "a symlinked work folder followed" 's@if \[ -L "\\\$work" \]@if false@'                                            has_slot_reset
mutate "the workspace never handed back" 's@mv -T -- "\\\$held" "\\\$work"@true@'                                    has_slot_reset
mutate "holding directory left slot-writable" 's@install -d -o root -g root -m 0700 "\$SLOT_ROOT/.reset/\$idx"@install -d -o "\$u" -g "\$u" -m 0700 "\$SLOT_ROOT/.reset/\$idx"@' has_slot_reset
mutate "boot reset runs under a live agent" 's|systemctl is-active --quiet "ci-runner@\$idx.service"|false|'                                  has_slot_reset
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

mutate "prune moved onto the starting job"   's|if \[ "\\$stage" != started \] && \[ "\\$prune" = 1 \]; then|if [ "\\$stage" = started ]; then|' has_local_tag_prune
mutate "digest-bearing images untagged too"  's|\[ "\\$ndig" = 0 \] \|\| continue|[ "\\$ndig" -ge 0 ] \|\| continue|'    has_local_tag_prune
mutate "boot manifest no longer consulted"   's|grep -qxF -- "\\$id" "\\$baked"|grep -qxF -- "zzz" "\\$baked"|'          has_local_tag_prune
mutate "manifest keyed by name, not id"      's|--format .{{[.]Id}}. -- "$ref"|--format NAME -- "$ref"|'         has_local_tag_prune
mutate "manifest written in place"           's|mv -T -- "\$manifest_tmp" "\$manifest"|cp -- "$manifest_tmp" "$manifest"|'  has_local_tag_prune
mutate "manifest left slot-writable"         's|chown root:root "\$manifest_tmp"|chown "$u":"$u" "$manifest_tmp"|'          has_local_tag_prune
mutate "layers deleted with the tag"         's|docker rmi --no-prune -- "\\$t"|docker image prune -af|'                  has_local_tag_prune
mutate "the band's forward allow drops -p tcp"  's|FORWARD -p tcp -m conntrack|FORWARD -m conntrack|g'                       has_shared_infra_band
mutate "the band is no longer reserved"        '/ip_local_reserved_ports=/d'                                                  has_shared_infra_band
mutate "the reservation overwrites the list"   's|ports=[$][{]reserved:+[$]reserved,[}][$]want|ports=$want|'                  has_shared_infra_band
mutate "containers left for the next run"    's|docker ps --all --quiet --no-trunc|docker ps --quiet --filter name=zzz|'      has_container_reclaim
mutate "named volumes survive the reset"     's|docker volume prune --force --all|docker volume prune --force|'               has_container_reclaim
mutate "a stuck container no longer fails"   's|could not remove the containers left behind|removed nothing behind|'          has_container_reclaim
mutate "a stuck tag no longer fails the slot" 's|could not drop local image tag|dropped nothing for|'                     has_local_tag_prune

mutate "App JWT back in curl argv"        's@-K <(printf.*\$jwt")@-H "Authorization: Bearer $jwt"@'          has_secrets_out_of_argv
mutate "registration token back in curl argv" 's@-K <(printf.*\$tok")@-H "Authorization: Bearer $tok"@'          has_secrets_out_of_argv
mutate "env prefix dropped from config.sh" '/^  ACTIONS_RUNNER_INPUT_TOKEN=/d'                                    has_secrets_out_of_argv
mutate "sudo stops preserving the variable" 's@--preserve-env=ACTIONS_RUNNER_INPUT_TOKEN @@'                      has_secrets_out_of_argv
mutate "--token added back alongside it"   's@--url "https://github.com/$OWNER@--token "$token" --url "https://github.com/$OWNER@' has_secrets_out_of_argv
mutate "silent env drop no longer fatal"   '/sudo will not pass an environment variable/s@; return 1; }@; }@'     has_secrets_out_of_argv
mutate "only one slot unit hides /proc"    '0,/^ProtectProc=invisible/s@^ProtectProc=invisible@#&@'               has_secrets_out_of_argv
mutate "hidepid weakened to 1"             's@hidepid=2@hidepid=1@'                                               has_secrets_out_of_argv
mutate "host /proc left readable"          '/^  harden_proc$/d'                                                   has_secrets_out_of_argv

mutate "share never computed"        's@^  local SHARE_ENV; SHARE_ENV=\$(share_env)$@@'          has_slot_share
mutate "share never reaches the unit" 's@^\$SHARE_ENV$@@'                                        has_slot_share
mutate "slot handed the whole host"   's@cpus / SLOTS > 0 ? cpus / SLOTS : 1@cpus@'               has_slot_share
mutate "share hardcoded"              's@Environment=CI_SLOT_VCPUS=\$(( cpus / SLOTS@Environment=CI_SLOT_VCPUS=$(( 16 / SLOTS@' has_slot_share
mutate "memory share dropped"         '/^Environment=CI_SLOT_MEM_MB=/d'                           has_slot_share
mutate "host totals dropped"          '/^Environment=CI_HOST_VCPUS=/d'                            has_slot_share
mutate "slot count dropped"           '/^Environment=CI_HOST_SLOTS=/d'                            has_slot_share

mutate "band DNAT dropped"            '/PREROUTING -d "\$addr" -p tcp --dport/,+3d'          has_shared_infra_band
mutate "DNAT matched on the interface" 's@PREROUTING -d "\$addr" -p tcp@PREROUTING -i "$ifc" -p tcp@g' has_shared_infra_band
mutate "forward allow scoped to a veth" 's@ctstate DNAT --ctorigdst "\$baddr"@ctstate NEW -i "$veth"@g' has_shared_infra_band
mutate "span hardcoded to four slots"  's@slot_band_max "\$SLOTS"@slot_band_max 4@'               has_shared_infra_band
mutate "slot never told its band"      '/^Environment=CI_SHARED_INFRA_PORT_MIN=/d'                 has_shared_infra_band
mutate "bands overlap"                 's@CI_BAND_WIDTH=100@CI_BAND_WIDTH=10@'                     band_arithmetic_disjoint
mutate "band width off by one"         's@+ CI_BAND_WIDTH - 1 ))@+ CI_BAND_WIDTH ))@'              band_arithmetic_disjoint

mutate "hold install no longer fatal"       's@install_pin_hold || die.*@install_pin_hold || true@'                        has_pin_hold
mutate "renew takes a TTL from the caller"  's@new=\\\$((now + R_TTL))@new=\\\$((now + 60))@'                              has_pin_hold
mutate "renew allowed to move backwards"    's@\[ "\\\$new" -gt "\\\$R_EXPIRY" \] || new=\\\$R_EXPIRY@:@'                  has_pin_hold
mutate "every asker granted the host"       's@may not reserve this host@would like this host@'                            has_pin_hold
mutate "reserve accepts a slotless caller"  's@refusing: reserve must come from a slot@no slot, no problem@'               has_pin_hold
mutate "the run id no longer shape-checked" 's@is not a usable run id@is fine by us@'                                      has_pin_hold
mutate "the TTL clamp removed"              's@\[ "\\\$ttl" -le "\\\$PIN_MAX_TTL" \] || ttl=\\\$PIN_MAX_TTL@:@'            has_pin_hold
mutate "the record left slot-writable"      's@chmod 0755 "\$PIN_DIR"@chmod 0777 "$PIN_DIR"@'                              has_pin_hold
mutate "the record written in place"        's@mv -f -- "\\\$tmp" "\\\$RECORD"@cp -f -- "\\\$tmp" "\\\$RECORD"@'           has_pin_hold
mutate "an unparseable record swept away"   's@the hold record does not parse@unreadable, removing@'                       has_pin_hold
mutate "sudoers widened to any verb"        's@pin-hold.sh --run \*, /opt/ci/job-hooks/pin-hold.sh renew --run \*, /opt/ci/job-hooks/pin-hold.sh status@pin-hold.sh *@' has_pin_hold
mutate "the bare renew verb comes back"     's@pin-hold.sh renew --run \*@pin-hold.sh renew, /opt/ci/job-hooks/pin-hold.sh renew --run *@'      has_pin_hold
mutate "renew accepts an empty run"         's@refusing: renew needs --run <id>@carry on then@'                                 has_pin_hold
mutate "the host stops renewing the hold"   's@sudo -n /opt/ci/job-hooks/pin-hold.sh renew --run@: renew --run@'           has_pin_hold
mutate "any run may renew any hold"         's@renew_run" != "\\\$R_RUN"@renew_run" = "" @'                                    has_pin_hold
mutate "the completed hook renews too"      's@if \[ "\$stage" = started \]; then@if true; then@'                              has_pin_hold
mutate "admission is not serialised"        's@take_lock "the hold" || exit 1@:@'                                             has_pin_hold
mutate "the sweeper ignores the lock"       's@flock -w 10 9 ||@true ||@'                                              has_pin_hold
mutate "an expired reservation is free"     's@the sweeper has not released it@go right ahead@'                               has_pin_hold
mutate "a repeat claim moves the slot"      's@slot_to_write=\\\$R_SLOT@slot_to_write=\\\$idx@'                                has_pin_hold
mutate "a repeat claim may shorten a hold"  's@\[ "\\\$R_EXPIRY" -gt "\\\$expiry_to_write" \] \&\& expiry_to_write=\\\$R_EXPIRY@:@' has_pin_hold
mutate "--ttl accepts no value again"       's@refusing: --ttl needs a value@a default will do@'                               has_pin_hold
mutate "the prune forgets the boot"         's@\[ "\\\$h_boot" = "\\\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" \]@true@' has_pin_hold
mutate "teardown before the agent stops"    's@agent stopped before teardown@here we go@'                                     has_pin_hold
mutate "a failed docker ps reads as empty"  's@could not list the run.s containers@nothing to see@'                           has_pin_hold
mutate "the record dies with a failed start" 's@the agent would not start — the hold stays in place@the agent would not start@' has_pin_hold
mutate "the marker alone proves idle"       's@! pgrep -u "\\\$u" -f .Runner\\.Worker. >/dev/null 2>&1 \&\&@@'                has_pin_hold
mutate "an orphaned hold is only logged"    's@^  publish ""$@  true@'                                                        has_pin_hold
mutate "a held slot pruned between jobs"    's@if \[ "\\\$stage" != started \] && \[ "\\\$prune" = 1 \]@if [ "\\\$stage" != started ]@' has_pin_hold
mutate "the sweeper runs once at boot"      's@^OnUnitActiveSec=30$@@'                                                     has_pin_hold
mutate "the sweep left to systemd to time"  's@^AccuracySec=5$@@'                                                          has_pin_hold
mutate "the timer installed but not armed"  's@systemctl enable --now ci-pin-sweep.timer@systemctl enable ci-pin-sweep.timer@' has_pin_hold
mutate "a busy slot stopped mid-job"        's@&& \[ -f "\\\$marker" \] &&@\&\&@'                       has_pin_hold
mutate "the held slot never taken out"      's|systemctl stop "ci-runner@\\\$slot.service"|true|'                          has_pin_hold
mutate "the stack survives expiry"          's@docker rm --force@docker ps --filter@'                                      has_pin_hold
mutate "no reset after the hold"            's@/opt/ci/job-hooks/slot-reset.sh completed "\\\$slot"@true@'                  has_pin_hold

mutate "audit installed but not armed"       's@systemctl enable --now ci-baked-image-audit.timer@systemctl enable ci-baked-image-audit.timer@' has_baked_image_audit
mutate "audit runs once and never again"     's@^OnUnitActiveSec=900$@@'                                              has_baked_image_audit
mutate "audit races the boot image load"     's@^OnBootSec=300$@OnBootSec=1@'                                         has_baked_image_audit
mutate "audit oneshot without a deadline"    's@^TimeoutStartSec=180$@@'                                              has_baked_image_audit
mutate "audit failure made fatal"            's@^  install_baked_image_audit ||$@  install_baked_image_audit || die@' has_baked_image_audit
mutate "dead manifest id no longer reported" 's@say "slot \\\$idx: the manifest names@: "slot \$idx: the manifest names@' has_baked_image_audit
mutate "manifest mode no longer checked"     's@not root:root:644@is fine@'                                           has_baked_image_audit
mutate "state directory no longer checked"   's@not root:root:755@is fine@g'                                          has_baked_image_audit
mutate "image store owner no longer checked" 's@not \\\$u:\\\$u:700@is fine@'                                         has_baked_image_audit
mutate "symlinked manifest reads as a file"  's@if \[ -L "\\\$manifest" \]@if false@'                                 has_baked_image_audit
mutate "symlinked image store accepted"      's@if \[ -L "\\\$droot" \]@if false@'                                    has_baked_image_audit
mutate "poisoned slot keeps its marker"      's@^    if rm -f -- "\\\$marker"; then$@    if true; then@'              has_baked_image_audit
mutate "absent daemon stops being logged"    's@no docker socket at \\\$sock -- the manifest.s ids@no docker socket at \$sock -- nothing@' has_baked_image_audit
mutate "id lookup back to grep -q"           's@grep -cxF -- "\\\$id" >/dev/null@grep -qxF -- "\$id"@'                has_baked_image_audit
mutate "a missing manifest made a finding"   's@elif \[ -f "\\\$manifest" \]@elif true@'                              has_baked_image_audit
mutate "the hold cleared even on failure"   's@^if \[ "\\\$rc" != 0 \]; then$@if false; then@'                               has_pin_hold
mutate "a failed teardown back in service"  's@the agent stays DOWN@the agent is restarted anyway@'                        has_pin_hold

mutate "cache token published before it answered" 's@^  local tok$@  local tok; TURBO_TOKEN=x@; s@^      TURBO_TOKEN="\$tok"$@@'  has_turbo_cache
mutate "slot told about a dead cache"     's@if \[ -n "\$TURBO_TOKEN" \]; then@if true; then@'                          has_turbo_cache
mutate "cache addressed on the slot loopback" 's@Environment=TURBO_API=http://%s:%s@Environment=TURBO_API=http://127.0.0.1:%s@' has_turbo_cache
mutate "cache variables never reach the unit" 's@^\$TURBO_ENV$@@'                                                       has_turbo_cache
mutate "cache exposed to the network"     '/--dport "\$TURBO_PORT" -j REJECT/,+1d'                                      has_turbo_cache
mutate "readiness probe dropped"          's@/v8/artifacts/status@/@'                                                   has_turbo_cache
mutate "a cold cache takes the host down" 's@start_turbo_cache || log@start_turbo_cache || die@'                        has_turbo_cache

mutate "the TTL suffix silently ignored"    's@is not a duration@is close enough@'                                  has_pin_hold
mutate "minutes read as seconds"            's@unit=60 ;;@unit=1 ;;@'                                              has_pin_hold
mutate "a one-slot host allowed to reserve" 's@refusing --reserve-slot: this host has one slot@reserving the only slot on@' has_pin_hold
mutate "the hold forgets which boot"        's@boot=%s@host=%s@'                                              has_pin_hold
mutate "a hold honoured across a reboot"    's@releasing it as orphaned@keeping it@'                                 has_pin_hold
mutate "a plain pin takes its slot away"    's@\[ "\\\$reserve" = 1 \] && \[ -f@[ -f@'                                     has_pin_hold

# --- no comment in an UNQUOTED heredoc may spell a live backtick --------------
#
# Everything this script installs is written by heredocs, and most of them are
# unquoted because they interpolate a Terraform value. In one of those a
# backtick is not punctuation, it is a command substitution: a comment reading
# `docker ps` timing out RUNS docker ps while the file is being written -- at
# boot, as root. The habit that produces it is ordinary markdown, two commits
# have now shipped it, and a reviewer's eye slides straight over a comment.
#
# The rule is mechanical, so the check is too: inside an unquoted heredoc every
# backtick is escaped. A quoted heredoc is exempt, nothing in it expands. This
# found eleven live ones the day it was written.
_live=$(awk -v SQ="'" '
  BEGIN { inhd = 0; BT = sprintf("%c", 96); BS = sprintf("%c", 92) }
  inhd == 0 {
    p = index($0, "<<")
    if (p > 0) {
      rest = substr($0, p + 2)
      sub(/^-/, "", rest)
      sub(/^[ 	]+/, "", rest)
      q = 0
      if (substr(rest, 1, 1) == SQ) { q = 1; rest = substr(rest, 2) }
      if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
        delim = substr(rest, 1, RLENGTH)
        inhd = 1
      }
    }
    next
  }
  { line = $0; sub(/^[ 	]+/, "", line); sub(/[ 	]+$/, "", line) }
  line == delim { inhd = 0; next }
  q == 0 {
    for (i = 1; i <= length($0); i++) {
      if (substr($0, i, 1) == BT && substr($0, i - 1, 1) != BS) { print FNR; next }
    }
  }
' "$SCRIPT")
if [ -z "$_live" ]; then
  ok
else
  bad "a backtick inside an unquoted heredoc is a command substitution the boot would run, not prose -- line(s): ${_live//$'\n'/ }"
fi

printf 'host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
