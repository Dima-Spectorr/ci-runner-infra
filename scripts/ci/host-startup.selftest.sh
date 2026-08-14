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
  matches "$code" 'sudo -u "\$u" "\$dir/config\.sh"'
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
  # and the boot probe reads back where the daemon actually landed
  matches "$code" 'readlink "/proc/\$dpid/ns/net"'
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
mutate "namespaced DNS exception dropped"    's|-d "$md_ip" -p "$proto" --dport 53 -j ACCEPT|-d "$md_ip" -p "$proto" --dport 9 -j ACCEPT|' has_port_isolation

printf 'host-startup self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
