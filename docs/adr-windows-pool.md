# Windows as a first-class pool

Status: **proposed** (design only; nothing here is implemented).
Supersedes: the "Windows" section of `docs/onboarding-a-repository.md`, which
records the current state rather than a decision.
Amended 2026-08-16: **§3A supersedes phase 2 of §3 in full** and rewrites parts of
§2, §4, §5, §6 and §7. Phase 2 as originally written cannot work — the mechanism
is refuted by Microsoft's documented firewall rule precedence. Read §3A before
acting on anything below that mentions "the fence".

## Why this is being written

Windows CI in this fleet is the architecture this repository was created to
retire, still running. It is an ephemeral one-VM-per-job pool from the retired
`ci-runner-pool` module, *vendored* into a consuming repository's own Terraform —
which is both failure modes at once: the per-job boot and install cost the warm
pool exists to delete, and the copy-that-drifts that the shared module exists to
delete. It has no warm cache, no controller-owned drain, no telemetry, and no
gate reads it.

It has already been paid for. On 2026-08-14 that pool's poller sat in
`activating (start)` for 2h55m on one unbounded socket, its timer reading
`NEXT n/a`, its MIG pinned at `targetSize 0`, with a Windows job queued the
whole time and no alert anywhere — because the demand metric kept its last
published value and a stale number is not an absent one. The gate that now
prevents that (`scripts/ci/bounded-calls.selftest.sh`) was written *because of*
that outage, and it cannot see a single line of the Windows pool: it reads
`modules/ci-runner-host-pool/scripts/*.sh`, and the Windows pool is neither in
this module nor written in bash. The fleet learned the lesson and the machine
that taught it was left outside the classroom.

So: Windows becomes a pool of **this** module, under the same controller, the
same drain and recycle rules, the same telemetry, the same gates. Not a second
module, not a fork, and not a build flag that turns the artifact into "the
Windows module".

## What already crosses the OS boundary unchanged

Most of it, and that is what makes this a pool rather than a project. The MIG,
the `ONLY_UP` autoscaler and its `single_instance_assignment`, the identity
split, the demand and outcome sweep with its label-superset matching, the
telemetry publisher, and every pure decision function — `drain_decision()`,
`orphan_decision()`, `recycle_decision()`, `watchdog_decision()` — are written
against GitHub's runner list and GCE's instance list and know nothing about what
a host boots. `orphan_decision()` in particular already tolerates one repository
served by two pools: it matches on the MIG's `base_instance_name` prefix, so a
Windows pool's registrations and a Linux pool's registrations in the same
repository's runner list do not reap each other. The controller VM stays
Debian/bash whatever its hosts run; it never executes anything on a host.

Four things do not cross:

1. the instance-template metadata key that carries the boot script
   (`startup-script` vs `windows-startup-script-ps1`);
2. `scripts/host-startup.sh`, which is Linux top to bottom;
3. `packer/ci-host-image.pkr.hcl`, which is single-OS by construction — an
   `ubuntu` source family, `apt`, the SSH communicator, and a download of
   `actions-runner-linux-x64`;
4. the controller's **second drain gate** — `gcloud compute ssh <host>
   --tunnel-through-iap --command 'pgrep -fc "Runner.Worker"'`. A Windows GCE VM
   has no sshd, and there is no `pgrep`. This is the one that decides whether a
   host may be deleted, so it is the one this document spends the most time on.

And a fifth category, which is the interesting one: Linux isolation machinery
with **no Windows analogue at all** — the per-uid iptables metadata fence, the
per-slot network namespace, the per-slot rootless dockerd, systemd units,
`loginctl enable-linger`. For each of those the *reason* still applies and the
*mechanism* does not, and the section that matters is §4, where each one is
named and either replaced or explicitly refused.

---

## 1. The OS axis

### The shape: a pool has an OS, a module does not

`host_os` is a variable on `ci-runner-host-pool`, defaulting to `"linux"`, with
`validation` restricting it to `linux` or `windows`. A consumer that wants both
instantiates the module twice — one Linux pool, one Windows pool, each with its
own name, its own MIG, its own controller, its own labels. That is not a
workaround; it is the existing contract. A pool already serves one repository
with one label set, and the two pools must never answer the same labels or
GitHub will hand a Linux job to a Windows host. Two module blocks is how that is
already expressed for two repositories, and an OS is a weaker distinction than a
repository.

This is deliberately **not** a per-artifact flag. `check-generic-binary`'s rule —
one generic artifact, per-deployment differences arrive as configuration —
applies to the module and to the image, not to the pool: the Terraform module
source is byte-identical for both pools, and the *image* stays one image per OS
because an image cannot be polymorphic across kernels. What must never appear is
a second module directory, a `ci-runner-host-pool-windows`, or a Packer variable
that makes the Linux template build a Windows image. `packer/ci-host-image.pkr.hcl`
stays Linux-only and gains a sibling `packer/ci-host-image-win.pkr.hcl`, for the
same reason the Ubuntu source block cannot express a WinRM communicator: two
source blocks, not one source block with a mode.

The Windows image is repo-agnostic on exactly the terms the Linux one is. One
image serves every Windows pool in every project; everything a host knows about
who it serves arrives as instance metadata at boot. There is no per-repository
image and no build flag that makes it "the MSI-signing image" — a repository
that needs an extra SDK contributes it through the same optional warm-cache
provisioner the Linux image already has, which runs last and is the only layer a
consumer supplies.

### What `host_os` actually switches

In `main.tf`, exactly one thing: which metadata key carries the boot script.

```
metadata = merge(
  var.host_os == "windows"
    ? { "windows-startup-script-ps1" = local.windows_host_startup }
    : { "startup-script"             = local.host_startup },
  { "ci-host-os" = var.host_os, ... }
)
```

`ci-host-os` is set as its own metadata key and the boot script asserts it
against the OS it is actually running on. This exists because the failure mode
of getting the pair wrong is the worst-behaved one in the system: a Windows image
booted with `startup-script` set, or a Linux image booted with
`windows-startup-script-ps1` set, runs **no boot script at all**. The guest agent
simply does not find a key for its platform. The host comes up healthy, registers
zero agents, is drained by the controller at `register_grace_seconds` (drain rule
5, `reg=absent`), the autoscaler rebuilds it from the same template, and the pool
churns hosts at full price forever while every metric reads "hosts running". The
assertion cannot prevent the mispairing — a script that does not run cannot check
anything — so it is backed by a plan-time heuristic (below) and by a telemetry
tell: `ci_hosts_running` above zero with `ci_slots_total` at zero, sustained past
`register_grace_seconds`, is this and only this.

### Variables whose meaning changes, and variables that must be refused

**`slots_per_host`.** The docstring today says "each slot is a separate Linux user
with its own rootless Docker daemon". On Windows the first half survives verbatim
and the second half has no analogue: each slot is a separate **local Windows user
account** with its own profile, its own workspace and its own `TEMP`, and there is
no container runtime at all. The docstring must state both, because the
difference is not cosmetic — a reader who carries the Linux sentence across
concludes that jobs are container-isolated on Windows, and they are not.

Two consequences follow that a Windows consumer must decide on rather than
inherit. Concurrent Windows slots share one loopback and one port space, because
Windows has no per-user network namespace (§4); and a Windows build slot's memory
floor is set by MSBuild and its toolchains, not by a shell. The default of `4`
stays — changing a shared default silently re-sizes every Linux pool — but the
Windows guidance is `2`, and `1` for a pool whose jobs bind fixed ports. See
§4 for why that is not a bug to be fixed later.

**`extra_registry_hosts` — rejected outright on Windows.** It exists to name the
registries the *job identity* authenticates to, and it is consumed by
`write_slot_docker_config()` writing a `credHelpers` map into each slot's
`~/.docker/config.json`. There is no docker on a Windows host and nothing reads
the list. Accepting it would be the worst kind of no-op: a consumer configures a
private registry, Terraform applies clean, and the failure arrives later as an
unauthenticated pull inside a job — which is precisely the shape of the bug that
cost this fleet a tag, an apply and a host replacement when the same map was
written with a wildcard key that docker never consults. A non-empty list with
`host_os = "windows"` fails at plan.

**`network_tags`.** Its docstring today carries a safety contract: *"the
controller verifies a host is truly idle over IAP-SSH before deleting it, so a
host the IAP rule does not reach fails that check, the drain aborts, and the pool
never scales in"*. That contract is Linux-only from here on. A Windows pool's
liveness gate is outbound-only (§2), so a Windows host needs **no inbound path
from the controller whatsoever** — no IAP-SSH rule, no tag, no listener. This is
a reduction in attack surface and in configuration that can be got wrong, and it
is one of the arguments for the mechanism chosen in §2. The docstring must scope
its existing sentence to `host_os = "linux"` rather than leaving a reader of a
Windows pool hunting for a firewall rule that must not exist.

**`spot` — rejected outright on Windows,** and it should be rejected everywhere
next. The fleet-wide rule is standard GCE only for CI runners: Spot terminations
broke real CI jobs in production use, and cost control here is scale-to-zero plus
right-sizing, not preemption. Windows adds two more reasons — a preemption takes
K slots with it on a host whose boot is measured in minutes, and Windows Server
licensing is billed per vCPU-hour regardless of provisioning model, so the
saving is smaller than it looks. Refusing it on Windows is in scope for this
work. Removing it from the Linux path is a separate change and a separate PR,
because it is a breaking input change for every existing consumer.

### What a Windows pool must refuse to boot with

This repository's habit is that a host which cannot establish an invariant
**refuses to register** rather than serving jobs in a degraded state — `die`
rather than `log WARN`. The Windows pool inherits that habit and extends the
list. Plan time first, because a failure at plan costs a review comment and a
failure at boot costs a churning MIG:

| refused at plan | why |
|---|---|
| `image` naming the Linux image family while `host_os = "windows"` (and the reverse) | the copy-paste error: a consumer duplicates the Linux module block, sets `host_os`, and forgets the image. A string check on the family name is a heuristic, not a proof — but it catches the one mistake that actually happens, and its alternative is the silent churn loop above. |
| `extra_registry_hosts` non-empty | nothing reads it; see above |
| `spot = true` | see above |
| `register_grace_seconds < 1200` | the default of 600 is calibrated to a Linux boot plus K× `config.sh`. A Windows first boot plus K local-account creations plus K× `config.cmd --runasservice` does not fit in it, and the consequence of not fitting is the churn loop that `register_grace_seconds` exists to prevent — the controller reads a booting host as a dead one and drains it, sometimes between the verdict and the agents coming up. |
| `boot_disk_size_gb < 200` | Windows plus the build toolchains plus the warm cache plus K workspaces plus a pagefile. A host that fills its disk mid-job fails every slot at once and reports it as a repository problem. |

And at boot, each of these makes the host register **nothing**:

* `ci-host-os` metadata absent or not `windows`;
* the golden-image marker absent, or below the minimum image version the script
  requires — the same fail-closed shape as the Linux script's refusal to boot an
  image without `dockerd-rootless.sh`, and for the same reason: an older image
  silently returns every slot to a shared state the split exists to remove;
* any slot user not created, or its profile/workspace ACL not asserted;
* ~~the metadata fence not installed **or not proved from a slot user's own
  context** (§3)~~ — **superseded by §3A**: there is no fence. Read instead: the
  host identity not proved harmless from a slot user's own context — a host whose
  service account can still read the App key secret registers nothing;
* the job credential broker configured and not answering;
* the per-job credential reset hooks not installed;
* the liveness beacon not published at least once (§2).

---

## 2. The liveness gate

### What the gate is for

The controller deletes hosts. Before it does, two gates must pass. The first is
GitHub's: the controller deregisters every agent on the host, and GitHub
*refuses* to remove an agent that is executing a job. That refusal is the mid-job
guard, it is unforgeable from the host, and it does not care what OS the host
runs. The second gate exists because the first one has a window: an agent can
have been deregistered while its worker process is still winding down, and an
agent can have died leaving a worker behind. So the controller asks the host
directly whether a `Runner.Worker` process remains, and deletes only on "no".

On Linux it asks over `gcloud compute ssh --tunnel-through-iap`. On Windows
there is no sshd and no `pgrep`. Two replacements were considered.

### Option (i): OpenSSH Server in the Windows golden image

This is real and it is documented. Google supports SSH to Windows VMs
(`https://cloud.google.com/compute/docs/connect/windows-ssh`): set
`enable-windows-ssh=TRUE` in project or instance metadata, with guest agent
`20220527.00` or later and OpenSSH 8.6 or later on the VM. The research question
worth asking was whether the guest agent provisions keys the way it does on
Linux, and the answer is **no, not the same way**: OS Login is Linux-only ("OS
Login is only available for Linux VMs"), all Windows VMs use *metadata* to manage
SSH keys, and Google's own documentation says that for Windows "Compute Engine
doesn't store the public key on the VM" — the key path is driven by the agent per
connection rather than persisted into an `authorized_keys` file. Microsoft's
OpenSSH-for-Windows, meanwhile, reads administrator accounts' keys from
`%ProgramData%\ssh\administrators_authorized_keys`, not from a per-user file.

Four things make this the wrong gate here, and only the first is about effort:

* **It re-imports the failure it should be removing.** The gate would need the
  IAP-SSH firewall rule and the `network_tags` contract — and "the IAP firewall
  tag" is already the documented first thing to check when a pool never scales
  in. A new OS whose delete path fails closed on a firewall rule a consumer
  forgot is a new instance of the fleet's most common misconfiguration.
* **It logs in as an administrator on a machine running build input.** The
  Windows key path lands in the administrators' key file. The controller holds
  `roles/compute.instanceAdmin.v1`; the whole identity split in this module
  exists to keep that identity off machines that execute pull-request code, and
  an interactive admin session from the controller onto such a machine every
  drain is a step back across that line.
* **It is a synchronous call that can hang.** That is the exact failure class of
  the 2h55m outage — one call that neither returns nor fails, inside a loop, with
  the metric holding its last value. `gcloud compute ssh` to a Windows VM has more
  moving parts than to a Linux one (key push to instance metadata, agent pickup,
  tunnel, sshd), and each is a place to stall.
* **The load-bearing part is not documented.** Google documents IAP TCP
  forwarding for Windows *RDP*; nothing found documents
  `gcloud compute ssh --tunnel-through-iap` against a Windows VM. It is plausible
  by mechanism — IAP forwards TCP and does not care what is on the port — but
  "plausible by mechanism" is not what the fleet's delete gate should rest on.

### Option (ii), chosen: a host-published beacon over guest attributes

The host publishes what it knows about itself, outbound, and the controller reads
it through the same compute API it already uses for `list-instances`.

The mechanism is documented and small
(`https://cloud.google.com/compute/docs/metadata/manage-guest-attributes`):
`enable-guest-attributes=TRUE` in instance metadata; the VM writes with a `PUT`
to `http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/<ns>/<key>`
carrying `Metadata-Flavor: Google`; the controller reads with
`gcloud compute instances get-guest-attributes <host> --query-path=<ns>/<key>`,
needing `compute.instances.getGuestAttributes`, which the controller's existing
`roles/compute.instanceAdmin.v1` already covers. Values are capped at 256 KiB and
keys at 128 bytes, which is four orders of magnitude more than needed.

A privileged publisher service on the host writes one namespace, `ci`, every 30
seconds:

```
ci/workers  = <integer count of Runner.Worker.exe>
ci/ts       = <RFC3339 UTC timestamp of that count>
ci/boot     = <RFC3339 UTC timestamp of the boot script's first write>
```

`Runner.Worker.exe` is the right process name: the runner's listener spawns
`Runner.Worker` plus the platform executable extension, and on Windows that is
`.exe`. The count is `(Get-Process -Name 'Runner.Worker' -ErrorAction
SilentlyContinue | Measure-Object).Count` — a host-local question with a
host-local answer, which is the same question the Linux `pgrep -fc` asks.

`ci/boot` is written by the boot script before anything else, and it is what
makes the absent case decidable (below).

### The rule, as a pure function

The verdict is a pure function of already-observed facts, exactly like
`drain_decision()`, `orphan_decision()` and `recycle_decision()` — which means it
is unit-tested in `scripts/ci/`, on this repository's runners, before it is ever
allowed to delete a machine. `beacon_decision()` takes the read *outcome* (not
just the value), the values, the instance age and a confirmation count, and
returns `delete:` or `keep:`:

| observed | verdict | why |
|---|---|---|
| read failed (API error, timeout, permission) | `keep:` | the mechanism broke; a broken mechanism tells us nothing about the host |
| read succeeded, key **present**, `ts` within 3× the publish interval, `workers = 0` | `delete:` | the only affirmative case |
| read succeeded, key present, fresh, `workers > 0` | `keep:` | a job worker is alive |
| read succeeded, key present, `ts` **stale** | `keep:` | the publisher died. The host may be perfectly busy; we no longer know |
| read succeeded, key **absent**, instance younger than `register_grace_seconds` | `keep:` | still booting |
| read succeeded, key absent, instance older than `register_grace_seconds`, zero registrations in GitHub's list, confirmed on `orphan_confirm_ticks` consecutive ticks | `delete:` | the boot script never ran, so no runner was ever installed, so no worker can exist |

The last row is the only place a host is deleted without positive evidence, and
it is constrained to the case where positive evidence is impossible *because the
host never became a runner at all*. Three guards make it safe, and all three are
borrowed rather than invented: the distinction between a **failed read** and a
**successful read returning nothing** is the same distinction `orphan_decision()`
draws between a failed `list-instances` and a pool at zero; the confirmation
count is the same `orphan_confirm_ticks`; and the age floor is the same
`register_grace_seconds` that stops the controller reading a booting host as a
dead one. Without that row a host whose boot script failed before its first
beacon write would be undeletable forever — a permanent, billing, invisible
resident of a pool that reports the right number of hosts.

**In every degraded case the answer is "keep the host".** The mechanism failing
never authorises a deletion. The cost of a wrong `keep:` is money; the cost of a
wrong `delete:` is somebody's merge-blocking job, and up to `slots_per_host` of
them at once.

### Can job code forge the beacon?

This is the question the mechanism has to survive, and the documentation is
blunt about it: *"Any process running in the VM instance can write to the guest
attributes values including scripts and applications that don't have sudo or
administrator level privileges."* Guest attributes are **not** a privilege
boundary inside the VM.

They do not need to be, for three reasons that compose. **Amended by §3A: reason 1
is void — there is no fence — and reason 2 is narrower. Reason 3 carries this
alone, and it can.**

1. ~~**The write goes through the fence.**~~ **Void (§3A).** The guest-attributes `PUT` is an
   ordinary call to the metadata server on `169.254.169.254:80` — the same
   address and the same port the metadata fence blocks. There is no separate
   channel. On a host whose fence is intact, job code cannot write a guest
   attribute at all, and §3 makes proving the fence a boot precondition rather
   than an assertion.
2. **If the fence is broken, forgery is not the interesting attack.** A slot that
   can reach `169.254.169.254:80` mints an access token for the host service
   account, which reads the GitHub App private key out of Secret Manager. That is
   the fleet, and it is the exposure the fence has always existed to close. A
   beacon forged by an attacker who already owns the fleet adds nothing.
3. **Forging `workers = 0` cannot delete a host that is running a job**, because
   the beacon is the **second** gate. The first is GitHub refusing to deregister
   a busy agent, and that refusal is issued by GitHub, from outside the host, and
   is not forgeable from it. To reach the beacon check at all, every agent on the
   host must already have been deregistered — which GitHub will not do while one
   is executing. The worst a forged `workers = 0` achieves is deleting a host
   that is genuinely idle, i.e. exactly what the controller was about to do.

The reverse forgery — a job pinning `workers` permanently above zero to keep its
host alive — costs the pool one host's warm window and is caught by
`ci_host_idle_seconds_max` climbing without bound on a host GitHub reports idle.

### Quota, and why the controller does not poll every host every tick

Guest attributes are rate-limited to **10 queries per minute per VM instance** and
3 per second. The publisher writing every 30s is 2/min. If the controller read
every host's beacon on every 20s tick it would add 3/min per host, and a pool that
tightened `poll_interval_seconds` would silently cross the limit — at which point
reads start failing, `beacon_decision()` correctly says `keep:`, and the pool
stops scaling in for a reason no dashboard shows.

So the controller reads the beacon **only for a host it is about to delete** —
inside `drain_host()`, after deregistration, where the SSH call sits today — and
for a host whose staleness it is reporting. That is at most one read per host per
drain attempt, and it keeps the budget an order of magnitude clear. It is also
bounded like every other call this fleet makes: `gcloud` gets an explicit timeout,
and `scripts/ci/bounded-calls.selftest.sh` is the thing that will notice if a
future edit removes it.

### Telemetry

Two series, added to `metric_names` in the same change that publishes them, so
`scripts/ci/metric-contract.selftest.sh` can hold code and contract together:

* `ci_beacon_stale_hosts` — hosts whose last successful read was stale or absent
  past the register grace. Steady state is zero. Sustained non-zero means the
  pool has hosts it will never be able to delete, which is the Windows-shaped
  version of "`ci_orphan_registrations_reaped` should sit at zero".
* `ci_drain_verdicts{outcome="beacon_blocked"}` — an existing series gaining a
  value, so a drain aborted by the liveness gate is visible next to the drains
  aborted by GitHub's refusal, rather than being invisible in the difference
  between two other numbers.

### Should this replace the Linux SSH check?

Yes, eventually, and no, not here.

Every argument above holds on Linux. It would remove the IAP-SSH inbound
requirement from `network_tags` and with it the fleet's most common "pool never
scales in" cause; it would remove a synchronous, hang-capable call from the tick
loop; and it would delete an interactive path from the controller onto machines
running build input. The publisher is four lines of shell and a systemd timer.

It is a separate change because it is a **migration**, and this one is a
greenfield. Windows has no installed base: the first Windows host ever booted
publishes a beacon, and a controller that requires one is correct from the first
tick. Linux has seven pools of hosts that live for hours or days and were booted
from images that know nothing about beacons. A controller that started requiring
a beacon would find none, and its two possible behaviours are both bad — refuse
to delete anything (the fleet stops scaling in, at the floor, until every host is
replaced) or treat absent-as-idle (which deletes running jobs). The correct
migration is a dual-read window: the controller accepts either gate, hosts adopt
the publisher through an image bump and `recycle_max_unavailable`, and the SSH
path is removed only once `ci_beacon_stale_hosts` has been zero across the fleet
for long enough to mean it. That is a fleet-wide change to the rule that deletes
machines, and putting it inside a pull request whose stated intent is "add a
second host OS" is how a delivery ends up rolled back for a reason unrelated to
what it was for.

---

## 3. Windows host bring-up

This is the contract `windows-host-startup.ps1` must satisfy. It is written in
the same order the script must execute in, because in several places the order
*is* the safety property. Every phase either succeeds or the host registers
nothing.

The script installs nothing. Every expensive thing — the runner agent, the build
toolchains, the warm cache — is in the golden image, for the same reason it is on
Linux: a pool that installs at boot has re-invented the per-job cost it exists to
delete. The Windows equivalent of the Linux script's "am I on the right image"
refusal is a version marker file the Packer template writes and this script reads.

### Phase 0 — preflight, and the beacon before anything else

Read every metadata attribute the script needs, **first**, while the metadata
server is still reachable from this process. After the fence goes in (phase 2),
this script's own access to `169.254.169.254:80` is gone; that is not a
side-effect to be worked around but the design (§ "the fence" below).

Then: assert `ci-host-os = windows`; assert the image marker exists and is at or
above the floor; write `ci/boot` to the guest attributes and install the beacon
publisher service. The beacon comes before the slot users and long before any
agent, so there is no instant in this host's life at which a `Runner.Worker.exe`
could exist without a publisher able to see it. A failed first beacon write is
fatal: a host that cannot say whether it is busy is a host that can never be
safely deleted, and it is cheaper to lose it to the register-grace drain now than
to keep it forever later.

### Phase 1 — slot users, profiles, workspaces, TEMP

Each slot is a local account `ci-s<i>`. Created with a password from a CSPRNG,
used once to register the service in phase 5, never written to disk by this
script, never logged, never placed in metadata. Windows requires a password here
because a Windows service logon requires one — there is no `sudo -u` on this
platform — and the password is subsequently held by LSA as a service secret,
readable only by SYSTEM. That is a real difference from Linux, where no such
credential exists, and it is contained by making the password useless for
anything else: each slot account is granted `SeServiceLogonRight` and denied
`SeInteractiveLogonRight`, `SeNetworkLogonRight` and
`SeRemoteInteractiveLogonRight`. It is not in `Administrators` and not in
`Remote Desktop Users`.

`SeServiceLogonRight` is granted **explicitly**, by this script, before
`config.cmd` is called. GitHub's own tooling may grant it as part of
`--runasservice`; that is not established from primary documentation, and a
safety property that depends on a side-effect of somebody else's installer is not
a property.

*Reason survives, mechanism differs — the sibling-readable home.* On Linux the
script does `chmod 0750 /home/$u` and comments that an unenforced comment is not
an isolation boundary, because `useradd -m` under a permissive `HOME_MODE` leaves
a world-readable home. Windows creates `C:\Users\ci-s<i>` at first logon with an
ACL of the user, SYSTEM and Administrators — the default is already right. That
is not a reason to skip the step; it is a reason the step is cheap. The script
disables ACL inheritance on the profile root and on the workspace root, removes
any `Users` / `Authenticated Users` / `Everyone` ACE, and grants SYSTEM full,
Administrators full, `ci-s<i>` modify. And then it **proves** it in phase 6,
because "Windows does the right thing by default" is a claim about an image, and
the image changes.

Workspaces live at `C:\ci\slots\<i>`, with the same ACL, and the agent is
configured with `--work C:\ci\slots\<i>\_work`.

*Reason survives, mechanism differs — `/tmp`.* The Linux rule is that a workflow
step naming a fixed path under `/tmp` — and CI scripts name fixed paths there
constantly — creates it under whichever slot ran first, and every later slot gets
`Permission denied` on a file it believes is its own; the fix is `PrivateTmp=yes`
on the daemon with the agent joining the same namespace. Windows has no mount
namespace to give a service, so the mechanism is: a per-slot directory
`C:\ci\slots\<i>\temp` with the slot's ACL, and `TMP` and `TEMP` set in the
runner **service's** environment (the service key's `Environment` value, not the
machine-wide environment, which would give every slot the same one).

That is weaker than the Linux fix and the difference must be stated rather than
discovered: it redirects the *conventional* temp path, and nothing stops a step
from writing to a literal `C:\temp\build`. What the ACLs do is convert that
collision from a silent cross-slot read into an `Access is denied`. A job author
who hardcodes an absolute path outside `%TEMP%` gets a failure; on the old
one-VM-per-job Windows pool they got away with it. That is a real behavioural
change for the repository being migrated and belongs in its onboarding notes, not
in a surprise.

### Phase 2 — the metadata fence

> **SUPERSEDED IN FULL BY §3A (2026-08-16).** The mechanism below cannot work:
> Windows Firewall gives explicit block rules precedence over any conflicting
> allow rule and supports no administrator-assigned ordering, so the three
> `-Service` allow rules do not sit "above" the block — they lose to it, and the
> rule set blocks the guest agent, the beacon and the broker. A second,
> independent refutation is visible in the phase ordering here: phase 5 mints a
> registration token, which needs a GCP access token, which needs the metadata
> server — and the boot script is not one of the three exempt services, so phase 5
> could not run either. The threat statement in the first paragraph is still
> correct and still governs; everything after it is retained only so the argument
> can be read against §3A's refutation.

*The reason is unchanged and is the most important sentence in this document.*
Job code that reaches `169.254.169.254:80` mints an access token for the host
service account, which reads the GitHub App private key from Secret Manager and
can create instances with the host identity attached. Any workflow on a fork-able
branch would own the fleet. This is not theoretical; it is the finding the Linux
fence was built for.

*The mechanism has no analogue, and the obvious translation is a silent no-op.*
The Linux fence is `iptables -m owner --uid-owner`, per slot uid. The apparent
Windows equivalent is `New-NetFirewallRule -LocalUser <SDDL>`. It is not
equivalent. Microsoft's parameter documentation describes `-LocalUser` /
`-RemoteUser` as matching packets "authenticated as coming from or going to" a
principal, classifies them under the *security* filter object
(`Get-NetFirewallSecurityFilter`) rather than the address/port filters, and its
worked example pairs them with `-Authentication Required` and the note that "both
memberships must be confirmed by authentication using a separate connection
security rule". Windows Filtering Platform cannot bind a SID to a packet without
an authenticated connection, and there is no IPsec to the GCE metadata server —
nor any documented way to have one. A `-LocalUser` outbound rule to
`169.254.169.254:80` would be accepted by the cmdlet, appear in the rule list,
and filter nothing. **A fence that installs cleanly and enforces nothing is worse
than no fence**, because it survives review.

So the fence inverts. On Linux, root needs metadata, so the block is per-uid and
root is exempt. On Windows, the block is **host-wide** and the exemptions are
enumerated by *service*, because `-Service` (and `-Program`, and `-Package`) match
on process identity through the application/service filter and require no IPsec:

* one **block** rule: outbound, remote address `169.254.169.254`, protocol TCP,
  remote port **80**, all profiles, applies to every process on the machine;
* **allow** rules above it, each scoped `-Service` to exactly one Windows service:
  `GCEAgent` (the guest agent talks to the metadata server continuously and
  breaking it breaks the instance), `ci-job-broker`, `ci-beacon`.

Two properties follow, and both are better than the Linux original. Nothing
running as an ordinary user *or as SYSTEM* can reach the metadata server — only
those three service identities can, and a service SID is assigned by the Service
Control Manager, which a non-administrator slot account cannot ask for. And the
exemption list is short, enumerable and reviewable, rather than being "everything
except the uids we remembered to name".

*Port 80 only, and that is deliberate — the same rule, restated.*
`169.254.169.254` is two services on one address: the metadata server over HTTP on
80, and the VPC resolver on 53. GCE Windows guests use the metadata server as
their DNS server. A blanket block by address would take name resolution away from
the whole machine, and it would report itself as a broken upstream — an unresolvable
`github.com` on a host whose firewall looks fine. Port 53 is untouched; port 80 is
blocked; the token endpoint is unreachable and names still resolve. This is the
Linux comment's argument word for word, and it needs restating in the PowerShell
because the next person to "simplify" this rule will simplify it the same way.

*It is proved, not asserted.* Phase 6 runs a bounded HTTP request to the token
endpoint **as a slot user** and requires it to fail. This is what makes the
residual uncertainty about `-Service` outbound scoping safe: if the exemption
model does not behave as documented, the fence either blocks the broker (caught in
phase 6, host refuses to register) or fails to block the slot (caught in phase 6,
host refuses to register). It cannot ship silently working-in-appearance, which is
the failure mode `-LocalUser` would have had.

### Phase 3 — the job credential broker

`scripts/job-metadata-broker.py` is portable — Python standard library, no
platform calls — and travels as metadata exactly as it does today, so one image
keeps serving every pool while the broker stays versioned with the module and
covered by `scripts/ci/job-broker.selftest.py`. What does not travel is the
systemd unit.

It runs as a Windows service named `ci-job-broker`. ~~because the fence exemption
is scoped to a service SID and a scheduled task does not have one~~ — **§3A: that
reason is void; the remaining ones are lifecycle, not safety** (SCM start/stop and
restart policy, a per-service environment block, and one uniform way to ask
whether it is running). Windows has no
in-box way to run an arbitrary interpreter as a service, so the golden image bakes
a small generic service host — a service shim that starts one configured child
process and stops it on `SERVICE_CONTROL_STOP` — compiled at image build from the
in-box .NET Framework compiler. It is repo-agnostic, has no configuration beyond
the command line it is given, and is used by both services. This is the one piece
of genuinely new machinery in the Windows path and it is called out here so it is
reviewed as such rather than discovered in a diff.

The binding is simpler than Linux, and the reason is worth recording because it
looks like a regression: the broker binds `127.0.0.1:<ci-job-broker-port>`. On
Linux it binds `0.0.0.0` and the script then adds an `INPUT` REJECT on the primary
interface, purely because each slot has its own network namespace and therefore
its own loopback, so a broker on the host's `127.0.0.1` would be unreachable from
every slot. Windows has no per-slot namespace (§4), so every slot shares one
loopback, the broker is reachable at `127.0.0.1`, and nothing off the host can
reach a loopback socket. The Linux complexity is a consequence of the Linux
isolation, and importing it here would add an exposure — a listening socket on the
VM's address — in exchange for nothing.

`GCE_METADATA_HOST`, `GCE_METADATA_IP` and `GCE_METADATA_ROOT` are set in each
runner service's environment, which is what makes `gcloud`, `google-auth` and the
Go and Java clients find the broker instead of the fenced-off real thing. As on
Linux, an empty `ci-job-service-account` means the broker is not started and jobs
get no Google credentials at all — a valid pool, never a silent downgrade to the
host identity.

### Phase 4 — the per-job credential reset hooks

`ACTIONS_RUNNER_HOOK_JOB_STARTED` and `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` are
supported on Windows; the runner selects an interpreter from the hook file's
extension, so the variables and the both-ends discipline carry over unchanged and
only the script body is different.

The reason is unchanged and is not gcloud-specific: a slot account's profile
outlives every job the slot serves, and an action that persists a credential
leaves it for whatever pull request lands on that slot next. On Windows the
leftover lives in `%APPDATA%\gcloud` (and `%APPDATA%\gsutil`), not
`~/.config/gcloud`. Both hooks, for the reason the Linux comment gives: completion
alone leaves a live credential on disk for the whole idle window and does not run
at all if the agent is killed mid-job, which is the case that leaves the most
behind.

Two Linux details that must survive the port because they are the security half:

* The hook resolves the profile directory from the **account database** (the
  SID's `ProfileImagePath`), never from `$env:USERPROFILE`, and refuses to delete
  anything that is not under a `ci-s*` profile root. The Linux version reads
  `getent passwd` for exactly this reason: the directory being deleted must be
  decided by the host, not by a variable a job could have changed.
* The hook file is ACL'd SYSTEM/Administrators-full, slot-users-read-and-execute.
  One file is executed by every slot on the host, so a slot that could rewrite it
  would be running code in every other slot's identity. This is the Windows
  spelling of `chown root:root` plus `0755`, and it is not optional.

A failing hook fails the job. That is the intended trade, unchanged: a job that
could not be given a clean credential state must not run with the previous job's
identity.

### Phase 5 — agent registration as a service running as the slot user

Per slot: copy the baked, unconfigured agent from the image into
`C:\ci\slots\<i>` (copy, not link — `config.cmd` writes `.runner` and
`.credentials` into the directory it runs in, and K agents must not share one
identity), then

```
config.cmd --unattended --replace --disableupdate `
  --url https://github.com/<owner>/<repo> --token <registration token> `
  --name <instance>-s<i> --labels <ci-runner-labels> `
  --work C:\ci\slots\<i>\_work `
  --runasservice --windowslogonaccount ".\ci-s<i>" --windowslogonpassword <pw>
```

`--disableupdate` transfers verbatim and matters *more* here. GitHub otherwise
forces a runner self-update that leaves the process alive while the agent is
offline and undispatchable — 90 minutes of stalled CI on the pool this replaces —
and on a warm host that takes K slots down at once instead of one short-lived VM.
The image pins the agent version; upgrades ship by rebuilding the image, which is
reviewable.

`config.cmd --runasservice` itself must run elevated (it creates a service and
touches an account right), so it does **not** run as the slot user, which means it
writes `.runner` and `.credentials` owned by the elevated identity. On Linux
`chown -R "$u:$u" "$dir"` handles the equivalent; on Windows the ACL must be
re-applied *after* `config.cmd` and re-proved, or the agent cannot read its own
credentials — or, worse, a sibling can.

*Reason survives, mechanism differs — `Restart=no`.* The Linux unit sets
`Restart=no`, and the README's recycle contract depends on it: agents are not
`--ephemeral`, so a deregistered slot must **stay** deregistered, which is what
lets a cordoned host lose its idle slots permanently while its working slot
finishes. A Windows service installed by `config.cmd` carries the SCM's recovery
actions. A cleanly exiting agent is not a "failure" and should not trigger them,
but the guarantee this design needs is not "should not" — so the script sets the
service's recovery actions to take no action (`sc.exe failure <svc> reset= 0
actions= ""`) explicitly. A slot that restarts itself after a cordon re-enters the
pool, takes a job, and the host that was supposed to be retiring never retires.

Per-slot service environment (`Environment` on the service key, not machine-wide):
the three `GCE_METADATA_*` values, `TMP`/`TEMP`, and both
`ACTIONS_RUNNER_HOOK_JOB_*` — the last two set unconditionally, including on a
pool with no job service account, because that is where an inherited credential is
most dangerous.

**Not established, and must be verified on a live host before this phase ships:**
GitHub does not document running the runner service as a non-administrator local
account. The interactive prompt's default is `NT AUTHORITY\NETWORK SERVICE`, the
flags to override it exist and are widely used, and community reports describe
permission friction with low-privilege accounts that reads as "the account cannot
reach the runner's own working directory" — which is exactly what the explicit
workspace ACL in phase 1 is for. The one-user-per-slot model is the decision this
design is built on; what is open is only how much ACL and privilege plumbing it
takes, and phase 6 is what stops a half-working version from registering.

### Phase 6 — the fail-closed boot probe

> **The check list below is superseded by "What phase 6 must prove instead" in
> §3A.** The principle survives verbatim; the first bullet is now false by design
> and is replaced by a negative-capability assertion on the token the endpoint
> yields.

The Linux probe's principle is the one to carry: **assert the capability, not the
daemon**. Both faults it was written for left `docker info` answering on hosts
where no job could run a container. Every check below runs *as a slot user*,
because the question is what job code can do, and every one is fatal.

* The real metadata token endpoint does **not** answer. A slot that can read it
  owns the fleet.
* The broker **does** answer, when a job service account is configured. A slot
  that registers without it turns every deploy step into a confusing auth
  failure.
* The slot **cannot** enumerate a sibling slot's profile or workspace — assert
  `Access is denied`, do not assert the ACL string. An ACL is a description; a
  denied read is the property.
* The slot **can** create and delete a file under the shared warm cache. This is
  the exact `v3-11-0` fault in Windows dress: a cache warmed by a privileged
  build identity that slots can read and none can update, where a package manager
  refreshing a partially warmed tree fails and reports it as a flaky upstream.
* Name resolution works.
* The beacon has published at least once and its timestamp is fresh.

Deliberately **not** in the probe: starting a container (there are none) and
running a build (it would need the network and a repository, turning an upstream
hiccup into a fleet that refuses to register). The Linux script's reasoning for
what it leaves out applies unchanged.

---

## 3A. Amendment, 2026-08-16 — the fence has no Windows mechanism

**This section supersedes phase 2 of §3 in full.** Phase 2 does not describe a
control that can exist. What follows is the refutation, the re-derivation of what
the fence was actually for, the candidates, and the decision.

### The finding

Phase 2 specifies one host-wide outbound **block** rule to `169.254.169.254`
TCP/80 and, "above it", three `-Service`-scoped **allow** rules for `GCEAgent`,
`ci-beacon` and `ci-job-broker`. Windows Firewall does not resolve that
combination the way phase 2 assumes. Microsoft Learn, *Windows Firewall Rules*,
"Rule precedence for inbound and outbound rules"
(`https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules`):

> 2. Explicit block rules take precedence over any conflicting allow rules.
> 3. More specific rules take precedence over less specific rules, except if
>    there are explicit block rules as mentioned in 2.

and, in the same section:

> Outbound rules follow the same precedence behaviors.
>
> Windows Firewall doesn't support weighted, administrator-assigned rule
> ordering.

There is no "above it". `-Service` is a match condition and nothing more —
`New-NetFirewallRule`'s own reference
(`https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule`)
defines it as *"the short name of a Windows Server 2012 service to which the
firewall rule applies"*, with no precedence semantics attached. Specificity does
not help either, because clause 3 exempts itself in the presence of a block.

The one documented way an allow defeats a block is `-OverrideBlockRules`, and its
own reference closes the door:

> Indicates that matching network traffic that would otherwise be blocked are
> allowed. The network traffic must be authenticated by using a separate IPsec
> rule. […] If this parameter is specified, then the *Authentication* parameter
> cannot be set to NotRequired.

The outbound wording relaxes one precondition and not the load-bearing one — *"No
accounts are required in the RemoteMachine or RemoteUser parameter for an outbound
bypass rule"* removes the **account** requirement, not the **authentication**
requirement. An IPsec connection security rule to the GCE metadata server would
need the metadata server to be an IKE peer. No primary source describes one, and
Google documents the metadata server as a plain HTTP endpoint reached with a
`Metadata-Flavor: Google` header. Treat it as unavailable.

So the phase-2 rule set, installed exactly as written, blocks `GCEAgent`, the
beacon and the broker along with the slot accounts. The instance loses its guest
agent, the liveness gate of §2 stops publishing, and jobs lose ADC.

**The shape of this mistake is the one phase 2 itself warned about, one level up.**
Phase 2 rejected `-LocalUser` with the sentence *"a fence that installs cleanly
and enforces nothing is worse than no fence, because it survives review"*. The
replacement has the mirror flaw: it installs cleanly and enforces **everything**.
Phase 6 would have caught it — the broker readiness check fails, the host refuses
to register — which is the fail-closed design working as intended, and is also the
point at which the correct conclusion becomes "we built the wrong mechanism"
rather than "we mis-set a parameter". Discovering that after PRs 3–6 have shipped
is the cost this amendment exists to avoid.

### What the fence was actually for, and the two things phase 2 conflated

The threat statement in phase 2 is still the most important sentence in this
document, but it is two claims welded together, and they have different answers:

**(a) Job code minting an access token for the host service account.** This is the
fleet. Today the host account holds `roles/secretmanager.secretAccessor` on the
GitHub App private key (`modules/ci-runner-identity/main.tf`,
`google_secret_manager_secret_iam_member.runner_reads_key`), because
`host-startup.sh` mints its own registration tokens: `gh_token()` runs
`gcloud secrets versions access latest --secret="$KEY_SECRET"`, signs a JWT, and
exchanges it for an installation token. Anything holding a host token holds the
App key, and therefore holds every repository the App is installed on. It also
holds `roles/monitoring.metricWriter` and `roles/logging.logWriter`
project-wide — enough to write the demand series the autoscaler reads.

**(b) Job code reading instance metadata attributes generally.** This is not the
fleet, and today it is not even a secret. The attributes this module sets are
`ci-github-owner`, `ci-github-repo`, `ci-app-id`, `ci-app-installation-id`,
`ci-app-key-secret` (the *name* of a secret, not its value), `ci-runner-labels`,
`ci-runner-group`, `ci-slots`, `ci-pool`, `ci-job-service-account`,
`ci-job-broker-port`, `ci-job-broker-py`. A job that reads all of them learns
which repository it is serving, which it already knows. Google is explicit that
this class of read needs no privilege at all: *"Your compute instances
automatically access this metadata through the metadata server API without
needing additional authorization"*
(`https://docs.cloud.google.com/compute/docs/metadata/querying-metadata`).

The Linux fence closes (a) and (b) together because iptables owner-matching is
cheap and there was no reason to separate them. On Windows there is no mechanism
that closes either one, so the separation stops being academic: **(a) must be
closed by removing the value, and (b) must be accepted and designed around.** The
consequence of (b) being accepted is a rule, not a shrug: **no credential of any
kind may be placed in instance metadata on a Windows pool**, and §3A's chosen
option has to satisfy that while still getting a registration token to the host.

### Candidates

| mechanism | status | why |
|---|---|---|
| block + `-Service` allow exemptions (phase 2 as written) | **rejected** | refuted above. Explicit block beats any allow; no administrator-assigned ordering; `-OverrideBlockRules` needs IPsec the metadata server does not speak |
| `-LocalUser` per-slot rules | **rejected** (unchanged from phase 2) | `-LocalUser` matches only packets *"authenticated as coming from or going to a principal"*; there is no authenticated channel to the metadata server |
| **block** rule scoped `-Service` to the runner services, so job code inherits the match | **workaround, unprovable — treated as unavailable** | this is the only candidate that respects precedence: a block that simply does not match the exempt traffic, needing no allow at all. It rests on job processes carrying the runner service's SID and WFP examining it. **No primary source found** for either. Microsoft's own troubleshooting material describes the opposite cases — a service that impersonates binds in the *user's* context and WFP sees the user SID, and worker-thread I/O loses the service correlation (`https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/wfascimprov/msft-netfirewallrulefilterbyservice`; the archived forum note at `https://learn.microsoft.com/en-us/archive/msdn-technet-forums/f2bf0f58-6332-44ec-81c9-61e2b42097dd`). It is also **unprovable by the phase-6 boot probe**, which does not run as a descendant of the runner service; proving it would require the assertion to move into `ACTIONS_RUNNER_HOOK_JOB_STARTED`, i.e. into every job. A boundary this repository cannot state a source for and cannot prove at boot is not a boundary |
| profile-wide `Set-NetFirewallProfile -DefaultOutboundAction Block` plus an allow-list | **supported and documented, rejected on feasibility** | Microsoft names it and scopes it correctly: *"Changing the outbound rules to blocked can be considered for certain highly secure environments"*, requiring *"an inventory of all apps […] Administrators need to create new rules specific to each app that needs network connectivity"*. A CI host's job code is by definition an un-enumerable set of programs reaching an un-enumerable set of registries. The allow-list that makes CI work is `*`, at which point the default action buys nothing |
| host-wide block with **no** exemptions | **supported and documented, rejected on cost** | this is the only firewall configuration that is both documented and effective, and it costs all three consumers at once: the guest agent (Google does not document a supported GCE Windows instance whose guest agent cannot reach the metadata server), the §2 beacon (guest attributes are written by `PUT` to the same endpoint on the same port), and job ADC (the broker mints via the real metadata server). Losing the beacon loses the delete gate, which loses scale-in, which is most of what this work is for |
| deliver the registration token via **guest attributes** | **rejected — the channel does not exist in that direction** | Google is explicit: *"Users or service accounts outside of the VM cannot write to guest attributes metadata values"* (`https://docs.cloud.google.com/compute/docs/metadata/manage-guest-attributes`). Guest attributes are guest→outside only. The same page also says *"Any process running in the VM instance can write to the guest attributes values including scripts and applications that don't have sudo or administrator level privileges"* and *"Don't include sensitive information such as […] private keys or passwords in your guest attributes"* — so even if the direction worked, it would be the wrong place |
| deliver the registration token via **instance metadata**, written per-instance by the controller | **supported and documented, chosen — with a bounded exposure stated below** | `compute.instances.setMetadata` on a running instance is within the controller's existing `roles/compute.instanceAdmin.v1`; the guest reads it, and `wait-for-change` is a documented way to block until it appears (`https://docs.cloud.google.com/compute/docs/metadata/querying-metadata`). It is readable by job code — see the residual-risk paragraph. GitHub bounds it independently: *"The token expires after one hour"* (`https://docs.github.com/en/rest/actions/self-hosted-runners`) |
| **remove the value behind the endpoint** — a Windows pool host identity with nothing worth stealing | **supported and documented, chosen** | detailed below |
| `--ephemeral` / `generate-jitconfig` runners, removing the registration token entirely | **rejected here** | JIT config is documented, but the recycle contract in §3 phase 5 and the README depend on agents *not* being ephemeral: a deregistered slot must stay deregistered so a cordoned host can retire. Changing that is a fleet-wide change to how hosts drain, not a Windows detail |
| source-port, interface or route tricks to make the block rule miss the exempt traffic | **rejected** | a non-administrator can bind the same source port; Windows does not reserve low ports to administrators. No primary source treats any of these as an access-control boundary |
| WFP callout driver, AppContainer-launched job processes, Windows containers | **rejected** | the first is a kernel driver this fleet would own forever; the second is not something the GitHub runner can be told to do and no primary source describes it; the third is refused in §4 for the reason the pool exists at all |

### Decision

**A Windows pool gets no egress fence.** Phase 2 is deleted rather than replaced,
and its safety property is relocated into IAM, where Windows has a boundary that
is real.

1. **The Windows pool's host service account holds `roles/iam.serviceAccountTokenCreator`
   on the job service account and nothing else.** No `secretmanager.secretAccessor`,
   no `monitoring.metricWriter`, no `logging.logWriter`. TokenCreator is not an
   escalation: the broker's entire purpose is to vend exactly that token to job
   code, so a job that mints one directly has obtained what it was going to be
   given. Everything else is removed because a Windows host cannot defend it.
2. **The registration token is minted by the controller, not by the host.** The
   controller already reads the App key (`controller_reads_key`) and already mints
   installation tokens for the queue poll, so this moves a call rather than adding
   a capability. It writes the repository registration token to a per-instance
   metadata key, and **deletes that key** once the host's agents appear in
   GitHub's runner list. The host reads it with `wait-for-change`.
3. **Nothing else on a Windows host needs GCP permissions.** The beacon's guest-attribute
   `PUT` is an unauthenticated call to the metadata server and needs no IAM. The
   warm cache and the toolchains are baked by Packer, not pulled at boot. The
   broker needs its impersonation call and that is item 1.
4. **On Linux nothing changes.** The Linux fence works, is proved on a live host,
   and the Linux host account keeps its Secret Manager grant and mints its own
   registration tokens as it does today. This is a Windows-pool identity, selected
   by `host_os`, not a fleet-wide re-plumbing.

*Why not keep a credential in a SYSTEM-ACL'd file instead.* NTFS ACLs are the one
enforcement boundary on this platform that does behave as documented — a
non-administrator slot account genuinely cannot read a file granted only to SYSTEM
and Administrators, and phase 1 and phase 4 already lean on exactly that. It does
not help here. The credential the host needs is the App private key, and putting
the App private key on a CI host in any form is a strictly worse posture than
today's *"read it from Secret Manager, hold it for the length of one signing
call"* — it converts a revocable, audited, short-lived read into a durable secret
on a machine that executes pull-request code, defended by an ACL that one
privilege-escalation bug undoes. A long-lived service-account key file is the same
trade with an extra credential type nobody wants. The ACL is the right tool for
the hook scripts and the slot profiles; it is the wrong tool for the key that owns
the fleet.

### Residual risk, honestly

**Job code on a Windows host can reach the metadata server, and there is no
mechanism in this design that stops it.** Concretely: a job can mint an access
token for the host service account and impersonate the job service account —
which the broker was going to hand it anyway, so this costs nothing beyond making
the broker cosmetic on Windows. It can read every instance attribute, and every
**project**-level metadata attribute, which is the one that is not this module's
to control: project-wide SSH keys and any custom project metadata the consuming
estate has set are visible to any Windows CI job, and an estate that keeps
anything sensitive in project metadata must be told so in onboarding. It can read
the host's Google-signed identity token, so any service that trusts the host
service account's OIDC identity trusts a pull request. It can write and forge
guest attributes, including the beacon. And during the window between the
controller writing the registration token and the controller deleting the key —
or, failing that, the token's one-hour expiry — it can read a repository
registration token and register a runner with labels of its choosing, which is a
job-interception attack against that one repository. What it can **not** do is
read the GitHub App private key, write the demand metric the autoscaler reads, or
touch any repository other than the one its own pool serves. That is the whole of
the reduction, and it is the reduction that matters: the #1958 finding was "any
workflow on a fork-able branch owns the fleet", and after this change the worst
case is "a workflow can interfere with the repository it is already running for".
The two rules §4 already calls load-bearing — **one repository per pool** and
**fork pull requests never run on a warm host** — are now the only isolation
boundary a Windows pool has, and they must be enforced, not documented.

**What §2's beacon argument loses.** The subsection "Can job code forge the
beacon?" gives three reasons the beacon need not be a privilege boundary. Reason 1
("the write goes through the fence") is void — delete it. Reason 2 becomes
narrower and still holds: an attacker who can forge a beacon can also mint a host
token, and after this change that token is worth the job service account, which
the broker vends regardless. Reason 3 is untouched and is now carrying the weight
alone, which it can: GitHub refuses to deregister an agent that is executing a
job, that refusal is issued from outside the host, and the beacon is only ever
consulted *after* every agent on the host has already been deregistered. A forged
`workers = 0` deletes a host that is idle, which is what was about to happen.

### What phase 6 must prove instead

The probe's principle is unchanged and is the reason it survives: **assert the
capability, not the daemon.** But "a slot user cannot reach the token endpoint" is
no longer a property this design has, so asserting it would fail every boot. It is
replaced by the assertion that the token the endpoint yields is worthless. Run as a
slot user, every one fatal:

* The token endpoint **does** answer, and the token it returns **cannot** read the
  secret named by `ci-app-key-secret` — assert a `403` from
  `secretmanager.versions.access`. This is the phase-2 threat statement turned
  into a live negative-capability check, and it is strictly better evidence than
  the old probe: it tests the thing that actually matters (what the credential can
  do) rather than a proxy for it (whether a socket opens).
* That same token **cannot** write a time series — assert a `403` from
  `monitoring.timeSeries.create`. The demand metric is what scales the pool.
* No instance attribute contains a credential: assert that the
  registration-token key is **absent** by the time the probe runs. This is the
  check that keeps the "no credential in metadata" rule from decaying into a
  comment, and it is also how the controller's delete-the-key step gets a witness.
* The broker answers, and the identity in the token it vends is
  `ci-job-service-account` and not the host account. Both halves, because a broker
  that silently fell back to the host identity is the failure this whole design
  exists to prevent.
* Sibling profile and workspace reads are denied; the warm cache is writable; names
  resolve; the beacon has published once and is fresh. Unchanged.

A Windows pool whose host identity was not reduced fails the first two checks and
refuses to register. That is deliberate: the misconfiguration cannot be caught at
plan time (Terraform cannot see the IAM a caller's service account happens to
hold), so it is caught at boot, by the host, in the identity it is worried about.

---

## 4. What Windows does not get

Stated here, in the design, because the alternative is that a job author
discovers it as a broken workflow and reads it as a fleet fault.

**Containers.** No container runtime, no per-slot daemon, no registry credential
helper. This is the constraint that starts the whole design: the reason this pool
exists at all is a WiX/`signtool` MSI build, and Windows containers cannot run
it — the tooling needs the host's Win32 surface, and putting it in a container is
what would break the one job the pool is for. *Consequence for a job author:*
`container:` and `services:` in a workflow job cannot run on a Windows pool. A
`services:` block fails at "Initialize containers" before any step runs — an
error about docker on a host with no docker, which reads as a broken host. This
should be a gate, not a lesson: `scripts/ci/check-runner-policy.sh` gains a rule
that a job whose `runs-on` names a Windows pool label and which declares
`container:` or `services:` fails in the consuming repository's own CI, where the
author can see it.

**The isolation the container boundary provided.** On Linux the sentence "job
isolation is provided by running each job in a container instead of by destroying
the machine" is load-bearing: a job gets a clean root filesystem. On Windows a job
gets a clean *workspace* and a private profile, on a machine whose system state —
installed SDKs, the registry, `C:\ProgramData`, the certificate stores, anything a
job writes with the privileges it has — persists across jobs and is shared between
slots. This is materially weaker than the Linux pool, and it is weaker than the
ephemeral one-VM-per-job Windows pool being replaced, which destroyed the machine.
That is the price of warmth and it is the trade being made deliberately. Two
existing rules become load-bearing rather than merely correct: **one repository
per pool**, and **fork pull requests never run on a warm host**. On a Windows pool
they are the isolation boundary, not a defence in depth behind one.

**Per-slot network namespaces, and therefore per-slot ports.** Windows has no
`ip netns`. Two concurrent slots share one loopback and one port space, so two
jobs that bind the same fixed port collide, and the second reports "address
already in use" — which reads as a flaky test. On Linux this exact fault
(`0.0.0.0:32768: bind: address already in use`, four shards failing together) is
what forced namespaces after two failed attempts to partition the port range, and
there is no equivalent to reach for here. *Consequence for a job author:* bind
port 0 and read back the assigned port, or take a port from an environment
variable. *Consequence for the pool operator:* a repository whose Windows jobs
cannot do that runs `slots_per_host = 1` and still keeps the entire warm-boot and
warm-cache saving, which is the bulk of what this change is for.

**Egress filtering of any kind, including the metadata fence.** ~~The fence is
host-wide with a service allow-list (§3), not per-slot.~~ **Superseded by §3A:**
there is no fence at all. Windows has no documented mechanism that lets an allow
rule survive a host-wide block, and no documented per-principal outbound filter
that works without IPsec. A Windows CI job can reach `169.254.169.254:80` and mint
a token for the host service account. The boundary is moved into IAM — that
account is reduced until the token is worth only what the broker was going to hand
the job anyway — and the full residual, including what a job *can* still read, is
stated in §3A. *Consequence for the pool operator:* on a Windows pool, **one
repository per pool** and **no fork pull requests on a warm host** are not defence
in depth. They are the defence.

**Spot.** Refused (§1).

**arm64.** The Windows image is amd64 only. The Linux fleet's portability
ambitions do not extend to a Windows build host, and pretending otherwise would
put a variable in the Packer template that nothing sets.

---

## 5. Testability

This repository's culture is that a rule which cannot be tested is a rule that
ships wrong — `drain_decision()` shipped inverted once — and that a test which
*reads* the code is not a test: `v5.1.4` passed every gate in `ci.yml` while
every controller in the fleet died on the first tick, because all of those gates
read the controller's text and none of them ran it. PowerShell cannot be
`bash -n`'d or shellchecked, so the question is what the equivalents are.

**The safety-critical half is not PowerShell.** `beacon_decision()` — the rule
that decides whether a machine may be deleted — lives on the controller, in bash,
as a pure function with a self-test, exactly like the three that precede it. That
is deliberate: the part of this design whose wrong verdict destroys somebody's job
is written in the language this repository already knows how to prove things
about, and runs where the existing self-tests run.

**The PowerShell gets four gates**, all on `ubuntu-latest`, because this
repository must never need the fleet to be healthy in order to fix the fleet:

1. **Parse.** `pwsh` is present on GitHub-hosted Ubuntu images and installable
   where it is not.
   `[System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)`
   over every `.ps1`, failing on any error. This is the exact `bash -n` analogue
   and it runs the real parser rather than a lookalike.
2. **Lint.** PSScriptAnalyzer, pinned to a version, `-Severity Error,Warning`.
   The pinning is not ceremony — this repository pins every third-party action to
   a commit because a moved tag is arbitrary code on every pool in the fleet. A
   PSGallery module is the same shape of dependency, mitigated by the fact that it
   runs only on a GitHub-hosted runner and never touches a host.
3. **Structural self-test**, `scripts/ci/windows-host-startup.selftest.sh`, in
   **bash**, mutation-based, modelled directly on
   `scripts/ci/host-startup.selftest.sh`. It asserts the invariants whose
   breakage is silent, and — this is the part that makes it evidence rather than
   decoration — it breaks the script the way a later edit plausibly would and
   asserts that it notices. The invariants (**amended by §3A**: the four
   fence-shaped mutations are deleted and four identity-shaped ones replace them,
   because there is no fence to mutate): ~~the fence is installed before any agent
   is registered; the fence blocks port 80 and does not touch port 53; the fence's
   allow rules are `-Service`-scoped and the exemption list is exactly the three
   named services~~ — the script contains **no** `New-NetFirewallRule` at all, so
   a future edit cannot reintroduce a fence that reviews as working; the boot probe
   asserts a **403** from the secret and time-series calls rather than a failed
   connection, so an edit that reverts it to "the endpoint is unreachable" is
   caught; the probe asserts the registration-token metadata key is absent; the
   script never writes a credential to instance metadata or to guest attributes;
   `--disableupdate` is an argument to `config.cmd` and not a word in a comment;
   service recovery actions are cleared; the hook path is set unconditionally
   rather than only when a job service account exists; the beacon is started
   before the first agent; the boot probe runs as a slot user and every check is
   fatal.
4. **Pester**, run by `pwsh` on `ubuntu-latest`, over the script's *pure*
   functions — slot naming, the ACL descriptor construction, the beacon payload
   format, the metadata-attribute parsing. This requires the script to be
   dot-sourceable without side effects, i.e. `if ($MyInvocation.InvocationName -ne
   '.') { Main }` at the bottom. That structure is a requirement of this design,
   not a style preference: it is the only way any Windows code in this repository
   gets *run* by a gate rather than read by one.

**Gates that exist today and cannot see PowerShell.** These are additions to
existing files, and one of them should land before a single `.ps1` does:

* **The genericity sweep** greps `--include='*.tf' --include='*.sh'
  --include='*.hcl'`. A `.ps1` is invisible to it, so a customer, project or
  region literal could be committed into the Windows boot script and CI would
  report clean. This is a one-line change and it must land **first**, in the same
  pull request that adds the parse gate, before there is anything for it to miss.
* **`bash -n` and shellcheck** sweep `find . -name '*.sh'`. Gate 1 and gate 2
  above are their `.ps1` counterparts; the point of naming them together is that
  a reviewer looking for "is this file linted" should find one answer, not two
  half-answers.
* **`scripts/ci/bounded-calls.selftest.sh`** must learn `.ps1`. This is the gate
  written because a Windows pool stalled for 2h55m on an unbounded call, and it
  currently cannot read Windows code. `Invoke-RestMethod` and `Invoke-WebRequest`
  need `-TimeoutSec`, and a bare .NET `HttpClient` defaults to 100 seconds, which
  is not a bound anyone chose. Every web call and every `gcloud` invocation in the
  Windows path carries an explicit timeout, and this gate is what keeps that true
  when it stops being anyone's habit.
* **`scripts/ci/metric-contract.selftest.sh`** covers the two new series, in the
  same pull request that publishes them — the contract's whole purpose is that
  code and `metric_names` cannot drift in either direction.
* **`scripts/ci/check-runner-policy.sh`** gains the Windows container rule (§4).
* **`packer validate`** on both templates. CI does not run it today; a Windows
  template with a WinRM communicator is the first Packer source in this repository
  that a reviewer cannot check by eye against a working one.

---

## 6. Delivery

~~Nine~~ **Ten** pull requests (§3A inserts 4b and shifts the versions after it).
Each is independently mergeable, each leaves the fleet
working, and a Linux consumer is unaffected at every step — the module's
behaviour with `host_os` unset is byte-identical to today until PR 8, which is
the only one that changes a code path an existing pool executes.

`VERSION` on main is `v5.9.0`, so this sequence starts at `v5.10.0`. The numbers
below are the order these merge in, not a reservation: this repository has
several sessions open at once, and a version claimed by a branch that merges
first simply moves the rest along. `docs-pins` is what keeps that honest — a
pull request whose `VERSION` and documented pins disagree fails before it can
publish a tag nobody can resolve.

| # | version | intent | files | ~LOC | the gate that proves it |
|---|---|---|---|---|---|
| 1 | v5.10.0 | **The gates learn to see PowerShell.** Genericity sweep includes `*.ps1`; parse + PSScriptAnalyzer steps; `bounded-calls` reads `.ps1`. Lands before any `.ps1` exists, so no window exists in which a literal or an unbounded call could enter unseen. | `.github/workflows/ci.yml`, `scripts/ci/bounded-calls.selftest.sh`, a fixture `.ps1` | ~130 | `bounded-calls` self-test gains fixtures proving it FAILS on an unbounded `Invoke-RestMethod` and passes on a bounded one — a detector that has not been seen to fire is not a detector |
| 2 | v5.11.0 | **`beacon_decision()` as a pure rule**, plus its self-test. Nothing calls it. | `modules/ci-runner-host-pool/scripts/beacon-decision.sh`, `scripts/ci/beacon-decision.selftest.sh`, `ci.yml`, `README.md` | ~260 | the self-test, covering every row of the table in §2 including read-failed-vs-read-empty and the confirm-tick floor |
| 3 | v5.12.0 | **Windows boot script, part 1**: preflight, image assertion, beacon publisher, slot accounts, ACLs, per-slot TEMP. Unreferenced by Terraform. | `modules/.../scripts/windows-host-startup.ps1` (new), `scripts/ci/windows-host-startup.selftest.sh` (new), Pester tests, `ci.yml` | ~380 | parse + analyzer + the structural mutations + Pester on the pure functions |
| 4 | v5.13.0 | **Windows boot script, part 2** — **rescoped by §3A**: ~~the metadata fence and its proof~~, the broker service, the reset hooks. The fence half is deleted, not deferred; the PR shrinks to roughly half. | same script, same self-test | ~~~340~~ ~190 | ~~mutations asserting port-80-only, the exact `-Service` exemption list, fence-before-agents~~; mutations asserting the script contains no `New-NetFirewallRule`, writes no credential to metadata or guest attributes, and sets the hooks unconditionally |
| **4b** | **v5.14.0** | **NEW, required by §3A: the reduced Windows host identity and controller-minted registration token.** A Windows pool's host account gets `serviceAccountTokenCreator` on the job account and nothing else; the controller mints the repository registration token, writes it to a per-instance metadata key, and deletes the key once the host's agents appear. The boot script waits for it with `wait-for-change` instead of reading Secret Manager. **This is the PR that carries the security property phase 2 was supposed to carry, and it is a mandatory security review.** | `modules/ci-runner-identity/{main,variables,outputs}.tf`, `modules/ci-runner-host-pool/{main,variables}.tf`, `scripts/controller-startup.sh`, `modules/.../scripts/windows-host-startup.ps1`, `scripts/ci/controller-scope.selftest.sh` | ~340 | a controller self-test that **runs** the mint-write-delete sequence against a fake compute API and asserts the key is deleted; a Terraform self-test asserting a Linux pool's identity and its Secret Manager grant are byte-identical to today |
| 5 | v5.15.0 | **Windows boot script, part 3**: agent registration as a service, recovery actions cleared, the boot probe — **whose assertions are the §3A list, not the §3 list**. | same script, same self-test | ~320 | mutations asserting `--disableupdate`, cleared recovery actions, probe-as-slot-user, probe-is-fatal, and that the probe asserts a **403** rather than an unreachable endpoint |
| 6 | v5.16.0 | **The Windows golden image.** Second Packer source, WinRM communicator, the service-host shim, the warm-cache ACL, the image version marker. Repo-agnostic. **§3A note:** the shim's justification was *"the fence exemption is scoped to a service SID and a scheduled task does not have one"*. That reason is gone. It stays for lifecycle reasons — SCM start/stop, recovery policy, a service environment block — and must be reviewed as a convenience, not as a safety boundary. | `packer/ci-host-image-win.pkr.hcl`, `packer/warm-cache/none.ps1`, `ci.yml` | ~330 | `packer validate` on both templates (new step); the template's own in-build assertions, which are the Windows counterpart of the Linux "assert the host baseline" and "prove a rootless daemon starts" provisioners |
| 7 | v5.17.0 | **The OS axis in Terraform.** `host_os`, the metadata-key selection, `ci-host-os`, every plan-time refusal from §1, the changed docstrings. A Windows pool becomes declarable. **§3A adds one refusal:** `host_os = "windows"` fails at plan unless the pool declares controller-minted registration (the input added by PR 4b). Terraform cannot see what IAM a passed-in service account holds, so this is the only plan-time guard available and the real one is the boot probe. | `variables.tf`, `main.tf`, `scripts/ci/host-os-guard.selftest.sh` (new), `ci.yml` | ~320 | a self-test asserting that with `host_os` unset the rendered metadata key set is unchanged, and that each refusal in §1 and §3A is reachable — a precondition nothing can trip is not a precondition |
| 8 | v5.18.0 | **The controller's Windows delete gate.** `drain_host()`'s second gate branches on `ci-host-os`: unchanged SSH text on linux, `beacon_decision()` on windows. New telemetry. | `scripts/controller-startup.sh`, `main.tf`, `outputs.tf`, `scripts/ci/metric-contract.selftest.sh`, `scripts/ci/controller-scope.selftest.sh` | ~260 | `controller-scope` self-test, which **runs** the function under both values rather than reading it — this is the one PR that can break a Linux pool, and reading the diff is exactly what failed to catch `v5.1.4` |
| 9 | v5.19.0 | **Docs and the workflow gate.** `onboarding-a-repository.md` "Windows" rewritten from "the fleet is Linux only" to the adoption sequence; README isolation rules gain the Windows paragraph; `check-runner-policy.sh` rejects `container:`/`services:` on a Windows pool label. **§3A adds two obligations:** onboarding must state in the operator's own words that a Windows job can read the project's metadata and mint the host identity, so an estate keeping anything sensitive in project metadata knows before it opts in; and the "one repository per pool / no fork PRs on a warm host" rules must be written as Windows *requirements*, not recommendations. | `docs/onboarding-a-repository.md`, `README.md`, `scripts/ci/check-runner-policy.sh` | ~280 | the runner-policy gate's own `--selftest` fixtures, then this repository's own workflows; `docs-pins` self-test for the version in the new quickstart |

PRs 3–5 grow one file across three merges. That is deliberate rather than
regrettable: the alternative is one 900-line pull request, which the repository's
own rule splits, and each of the three has an intent a reviewer can hold — the
accounts and their boundaries, the fence and the credentials, the agents and the
probe. None of them is reachable from Terraform until PR 7, so a half-built script
on `main` is inert.

**§3A: what changes in this order, and whether a Windows pool may exist before it
lands.** Nine PRs become ten. PRs 1, 2, 3 and 8 are untouched — the gates, the
pure decision rule, the boot script's accounts-and-ACLs half, and the controller's
delete gate never depended on the fence. PR 4 loses its larger half and becomes
broker-and-hooks. PR 4b is new and is the only PR in this sequence that carries a
security property; it is a Terraform-and-controller change, not PowerShell, and it
is a mandatory `security-reviewer` gate. PR 5's probe assertions are replaced. PR
6 keeps its shim on a different justification. PR 7 gains one plan-time refusal
and moves the real check to boot. PR 9 grows. Everything from 4b onward shifts one
version.

**A Windows pool must not exist before PR 4b.** The question is not close. With
phase 2 deleted and nothing in its place, the first Windows host to run a
pull-request job hands that pull request a host token that reads the GitHub App
private key — which is the #1958 finding, verbatim, on a new OS. There is a small
mercy in the arithmetic: the same reduction that closes the hole is what makes
registration work at all, because a host account without Secret Manager cannot
mint its own registration token, so the safe configuration and the working
configuration are the same configuration. That is why PR 7's refusal is worth
having even though it can only check a declaration: the unsafe pool is the one
that happens to work today, so it has to be refused deliberately rather than left
to fail.

The first Windows pool is stood up after PR 7 with `min_hosts = 0` and
`slots_per_host = 1`, alongside the existing ephemeral pool rather than in place of
it, on its own labels. It is cut over only once it has served the MSI build, and
the old vendored pool is deleted in the consuming repository — which is a change
in that repository, not here, and is the last step rather than the first.

---

## 7. Decided

Four calls were put to the architect on 2026-08-15 and answered. They are
recorded here rather than in a pull request description because they are the
reason the numbers below are what they are, and the next person to raise "why
doesn't the Windows pool keep a warm host?" deserves the answer without an
archaeology dig.

**The first Windows pool scales to zero, always, with no warm schedule.**
Not `min_hosts = 0` plus a working-hours window, which is what this design
originally assumed — plain zero. Windows Server is licensed per vCPU-hour on top
of the machine, and a warm window pays that licence for every hour of the working
day whether or not anyone pushes. The cost of the choice is real and should be
named: the first Windows job after a quiet spell pays a full Windows boot, which
is slower than Linux, and `ci_queue_wait_seconds_max` on a Windows pool will show
it. The saving that remains is the one that mattered anyway — the *toolchain
install* and the *warm cache*, which a reused host keeps and a per-job VM never
had. `warm_schedules` remains available and unset; a pool that finds the morning
boot intolerable turns it on without a module change.

**`slots_per_host = 1` on Windows.** Windows has no per-slot network namespace
(§4), so two concurrent slots share one loopback and one port space, and two jobs
that both bind a fixed port collide with no host-side fix — reported as a flaky
build, never as host policy. One slot keeps every part of the warm-host saving
and none of that risk. Two remains expressible; it is not the default and it is
not where the first pool starts.

**Desktop Experience, not Core.** The pool exists for a WiX/`signtool` packaging
build, and that class of tooling is precisely the class that assumes shell
components Core does not ship. The trade is a larger image and a slower boot,
which the previous decision has already made the pool insensitive to — a pool
that scales to zero pays the boot either way, and paying thirty more seconds of
it is cheaper than discovering an installer that fails only on Core.

**Spot is refused on a Windows pool at plan time.** `spot = true` is already
wrong for CI on any OS — a preempted host takes its running jobs with it — and
the module still accepts it. Making it a *Windows* refusal now is the narrow,
non-breaking half: no existing pool sets it, so nothing breaks, and the Windows
path never grows the habit. Removing it fleet-wide changes an input every
consumer's root already names, so it is a breaking-input change of its own and
is deliberately not folded into this work.

**What is still open.** ~~Two things~~ — **one, as of §3A.** The first,
*that `-Service`-scoped outbound firewall rules are honoured against the metadata
address as documented*, is **closed, and the answer is no**: they are not, they
cannot be, and no allow rule defeats a block on this platform. See §3A. It was
never contained by the boot probe in the way this paragraph claimed — the probe
would have caught the over-block, but only after the mechanism was built, which is
a slower and more expensive way to learn it than reading the precedence rules
first. That is the lesson worth keeping from this amendment: a mechanism this
design leans on gets its primary source read *before* it earns a PR number, not
after.

What remains open is that the runner service runs as a **non-administrator** local
account with the workspace ACLs of phase 1 (PR 5). GitHub does not document that
configuration; the flags exist and are widely used, and the reported friction is
precisely about directory permissions. A half-working implementation refuses to
register the host rather than serving jobs from a broken boundary.

## 8. Risks, and the economics behind the decisions above

**Cost is the one that can invalidate the premise.** Windows Server on GCE is
licensed per vCPU-hour on top of the machine. A warm pool's saving is boot and
install time; its cost is that the host is billed while it waits. On Linux the
`drain_grace_seconds` default of 900 is comfortably worth it. On Windows the same
900 seconds of idle costs meaningfully more, and a `min_hosts` above zero costs a
licensed 16-vCPU machine around the clock. That is why §7 settles on plain zero:
the part of a warm host's saving that survives scale-to-zero is the part that was
worth having, because the toolchain install and the warm cache are minutes and
the boot is under two. `machine_type` stays a per-pool input with no Windows
default of its own — the Linux default of a 16-vCPU machine is sized for four
concurrent slots, and a one-slot Windows pool should name something smaller in its
own root rather than inherit a number chosen for a different shape.

The residual risk of that choice is not cost, it is **queue wait**. A pool at zero
with `slots_per_host = 1` serves its second concurrent job only after a second
host boots, so a repository that pushes two Windows jobs at once sees the boot
twice over. `ci_queue_wait_seconds_max` on the Windows pool is the series that
says whether that is tolerable, and it is the evidence that would justify either a
warm schedule or a second slot. Neither needs a module change.

~~**The two live-host unknowns**~~ **The one remaining live-host unknown** is
restated in §7 and is not repeated here; it ends in a host that refuses to
register rather than one that serves jobs from a broken boundary. The other —
whether a `-Service`-scoped outbound rule can fence the metadata server — was
answered on paper and is now §3A.

**The security posture of a Windows pool is materially weaker than a Linux pool's,
and that is now a decision rather than a gap** (§3A). A Linux host fences job code
off the metadata server and proves it on a live host. A Windows host cannot, so
the host identity is stripped until the token is worth only the job service
account the broker vends anyway. The cost is that a Windows CI job can read the
project's metadata, mint the host identity, and forge its own beacon. The
mitigation is not technical: it is **one repository per pool** and **no fork pull
requests on a warm host**, and a Windows pool that violates either has no
isolation left.

**The Linux SSH gate stays** (§2). It is a known, named, deferred piece of debt
with a migration shape already written down, not an oversight — and it is the
reason `ci_beacon_stale_hosts` matters more than it looks: it is the evidence that
will or will not justify that migration.
