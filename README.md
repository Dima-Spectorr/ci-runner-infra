# ci-runner-infra

Shared Terraform module and golden-image definition for self-hosted GitHub
Actions CI across the fleet. **One module, one image, every repository.**

## Why this repo exists

The module this replaces (`ci-runner-pool`) was *vendored* — copied into each
repository's `infra/terraform/modules/`. Nine copies, nine independent edits,
and they disagreed on the safety-critical scale-in contract. A fix for the
autoscaler deleting a VM mid-job landed in one copy; a fix for a pool pinned at
maximum landed in another; several copies had neither. Nothing was wrong with
any single fix. Vendoring was wrong.

Consumers now reference this module by tag:

```hcl
module "ci" {
  source = "git::https://github.com/<org>/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.35.0"
  # ...
}
```

A drift gate in each consuming repository fails CI if a local
`infra/terraform/modules/ci-runner-*` directory reappears.

**Putting a new repository on the fleet:**
[`docs/onboarding-a-repository.md`](docs/onboarding-a-repository.md) — the whole
sequence, including the label rule whose failure mode is a pull request that
hangs rather than an error.

## What changed, and what it buys

| | old: one VM per job | new: warm container hosts |
|---|---|---|
| VM lifetime | one job | many jobs, hours |
| per-job boot | 60–120 s | 0 |
| per-job toolchain install | 1–5 min | 0 (baked) |
| per-job dependency download | 1–4 min | ~0 after the slot's first job (warm cache) |
| isolation | destroy the VM | run the job in a container |
| scale-out | autoscaler on job demand | same |
| scale-in | VM self-deletes after its job | controller drains idle hosts |
| scale to zero | yes | yes |
| autoscaler mode | `ON` + `scale_in_control`, or `ONLY_UP` | `ONLY_UP` only |

The two changes that matter are on the same line of the table: a host is reused
(so the boot and install cost is paid once instead of per job), and because a
host is reused it now carries up to `slots_per_host` jobs at a time — which is
why no autoscaler is allowed to pick one to delete.

## Architecture

```
GitHub  <--poll(outbound)--  controller (e2-micro, always on)
                                 |  publishes ci_demand + telemetry
                                 v
                            autoscaler (ONLY_UP)
                                 |  adds hosts only
                                 v
                            regional MIG of warm hosts
                            each: K persistent runner agents
                                  jobs execute in containers
                                 ^
                                 |  deregister -> verify -> delete
                            controller owns every deletion
```

No inbound webhook is permitted into these projects, so demand is polled. The
controller is the only always-on cost per pool.

### Scale-in, precisely

1. The controller polls GitHub for each host's agents and their busy state.
2. `drain_decision()` (`modules/ci-runner-host-pool/scripts/drain-decision.sh`)
   returns `drain:` or `keep:` from already-observed facts. It is a pure
   function with a self-test — the predecessor of this rule shipped inverted
   once, and an untestable rule is a rule that ships wrong.
3. On `drain:`, the controller **deregisters** the host's agents. GitHub
   *refuses* to remove an agent that is executing a job; that refusal is the
   mid-job guard, and it aborts the whole drain for that host.
4. It then verifies no `Runner.Worker` process remains, and only then deletes
   the instance from the MIG.

5. Registrations left behind by a host that died *outside* this path — an
   operator `delete-instances`, a MIG recreate, host maintenance, a controller
   restart mid-drain — are reclaimed by `orphan_decision()`
   (`scripts/orphan-decision.sh`, also pure and self-tested). It deletes a
   registration only when the agent is offline, not busy, named for an instance
   this MIG could have created, and has had no instance behind it for
   `orphan_confirm_ticks` consecutive ticks. That last condition is the guard
   against a failed `list-instances` — which returns an empty host list,
   indistinguishable from a pool at zero — deregistering a live fleet.

A `keep:` verdict is never an error. A host is kept when it is busy, when the
pool is at its floor, when GitHub could not be asked, or when it is idle but
still inside its warm window.

### Getting a new template onto a busy host

`terraform apply` moves the *definition* of a host. It does not move a host. The
MIG's `update_policy` is `OPPORTUNISTIC` on purpose — `PROACTIVE` would delete
hosts to apply a new template, and an arbitrary victim here carries up to
`slots_per_host` running jobs. So a new template sits there, and hosts adopt it
only when something else happens to delete them.

That "something else" was `drain_decision()`, which knows nothing about
templates: it retires a host for being **idle** past the warm window. A pool with
work never goes idle for fifteen minutes, so it can keep running the previous
startup script indefinitely. Measured on 2026-08-15: v5.7.0 was applied to the
IntegrateIT pool and five hosts created the day before kept serving jobs from the
old template afterwards. The apply reported success. That was true, and it was
not the question anyone was asking.

`recycle_decision()`
(`modules/ci-runner-host-pool/scripts/recycle-decision.sh`, pure and
self-tested like the other two) closes that gap, and it never interrupts a job.
It is two-phase, and the phases are ticks apart:

* **cordon** — deregister the stale host's **idle** agents. GitHub refuses to
  deregister an agent that is executing a job, and that refusal is the guard: the
  working slot survives and its job runs to completion, while every idle slot
  leaves the pool, so no *new* job can ever reach this host again. Agents here
  are not `--ephemeral` and their unit is `Restart=no`, so a deregistered slot
  stays deregistered.
* **retire** — once the last job lands and the host is empty, it goes through the
  ordinary drain sequence: deregister the remainder, verify no `Runner.Worker`
  survives, delete. The autoscaler is `ONLY_UP` with `min_replicas = min_hosts`,
  so it rebuilds the host from the **current** template. Retiring at the floor is
  not churn — it is the replacement.

Bounded by `recycle_max_unavailable`, which is how many hosts may be mid-recycle
at once. A cordoned host's idle slots leave the pool immediately, so cordoning
every stale host at once would remove the fleet's whole spare capacity in one
tick and leave every queued job waiting on a boot. **The default is `0`, which
disables the mechanism entirely** — every existing consumer of this module
predates the feature, and a rule that deletes machines on nobody's trigger needs
a switch that stops it without a rollback. Start at `1`.

Two series make it observable. `ci_hosts_stale_template` climbs when a template
lands and falls back to zero as hosts are replaced; **stuck** above zero is the
state that was invisible on 2026-08-15 — alert on sustained non-zero, not on the
spike, because the spike is a release working. `ci_recycle_verdicts` counts
`cordoned` and `retired` per tick: `cordoned` climbing while `retired` stays flat
means the recycle is working and the hosts are not leaving — jobs that never end.

### What is in the golden image, and whether it may ship

Every warm host in this fleet boots one artifact, and until now the only account
of its contents was `packer/ci-host-image.pkr.hcl` — which lists what was *asked
for*, not what apt resolved, and says nothing at all about whether any of it is
known-vulnerable. That gap has a measured cost already at one level up:
`node_major` sat ten months past its support window because nothing was in a
position to check it.

So the build now scans itself, in this order and for a reason:

1. **An SBOM of the finished filesystem** (`syft`, pinned and checksum-verified),
   after the cleanup step, so it describes what ships rather than what the build
   was holding. It is published to `_SBOM_BUCKET` **and** left on the image at
   `/opt/ci-image-sbom/sbom.spdx.json` — when something is disclosed next month,
   the question "is it in the image that pool is pinned to" has to be answerable
   from the running host, long after the build workspace is gone.
2. **A scan of that SBOM** (`grype`, likewise pinned).
3. **A verdict** — `scripts/ci/image-vuln-verdict.sh`, which is where the policy
   lives and is unit-tested against fixtures in this repo's own CI, because a
   rule only observable inside a forty-minute image build that nobody's CI runs
   is a rule nobody can change with confidence.

The verdict blocks only on findings **with an available fix**, at or above
`_VULN_FAIL_ON` (default `critical`), **in an installed distro package** (`deb`,
`rpm`, `apk` — or an artifact whose type the report does not state, which fails
closed and blocks). Failing on something nobody can act on is how a gate earns
an `|| true` within a month, and for anything `syft` found by reading a binary —
the kernel image, a Go module compiled into `dockerd` — `grype` has no distro
security data to consult, so it compares upstream version numbers and reports
every backported fix as missing. The first real run of this gate produced 273
blocking findings, and every one of the 273 was a match of exactly that kind.
They are still counted and named, as `off-distro`. Exceptions go in
`docs/image-vuln-ignores.txt` and **carry an expiry date**: the day after it, the
gate goes red and names the entry, which forces the decision again rather than
letting the list grow quietly. A report that cannot be read, or that matched
nothing at all, is a **failure** — never a clean image.

It runs **before** the image is created, so a blocking finding means no image
exists, rather than an image that exists and is documented as unusable. The
report is downloaded to the build workspace *before* the failing check, because
an aborted build is exactly the one whose report somebody needs.

**Windows is not covered.** `packer/ci-host-image-win.pkr.hcl` builds a very
different filesystem, and syft's catalogers would find almost nothing to
enumerate on it — an SBOM listing four packages would read as "the Windows image
is clean" while describing nothing. Saying so here is the honest state; giving
that image a real answer is separate work, not a line in this one.

## Isolation rules (not optional)

* **One repository per pool.** Warm hosts share caches between jobs; that
  sharing is the speed-up. Two repositories on one pool would let one
  repository's build read the other's caches, credentials and workspace
  remnants.
* **Fork pull requests never run on a warm host.** Untrusted code plus a warm,
  credentialed, reused machine is the whole attack. Route them to
  GitHub-hosted runners.
* **Never mount the Docker socket into a job container.** It is a
  host-root escape and it defeats the container boundary that replaced
  "destroy the VM".
* **The host service account is a job's service account.** Anything it can
  reach, a build can reach. Grant only: read the App key secret, write metrics,
  write logs.
* **The controller has its own identity, and it is not the hosts'.** Scale-in
  is the controller deleting hosts, which needs
  `roles/compute.instanceAdmin.v1`; on a shared account that role rides every
  host VM, so job code out of the container fence could delete the pool it runs
  on — other repositories' in-flight jobs included — or create instances with
  the host identity attached. `ci-runner-identity` creates `<account_id>-ctl`
  and puts the grant there; `ci-runner-host-pool` REQUIRES
  `controller_service_account_email` and rejects a value equal to
  `service_account_email`. It used to default to "reuse the host account", and
  every consumer took that default, so it is no longer a default at all.
* **Each slot is its own Linux user with its own rootless Docker daemon.** Slots
  used to share the `runner` account and the one system daemon, so a job that
  reached `/var/run/docker.sock` — which every job could, because that socket is
  how an agent creates service containers at all — could enumerate the sibling
  slots' containers, `exec` into them, and read their `GITHUB_TOKEN`, their
  workspace and whatever the credential broker minted for them; and because the
  host is warm, later jobs' too. The metadata fence never contained this: it
  blocks the metadata server, not the daemon. Now slot `i` runs as `ci-s<i>`,
  its daemon runs as that user with its socket in a 0700 `/run/ci-s<i>`, and the
  rootful daemon is masked on the host, so there is no shared socket left to
  reach (#10). The same split ends the shared `$HOME` that raced pnpm's store
  install between concurrent slots. **This requires image `v3-11-0` or later** —
  an older image has no `dockerd-rootless.sh`, and a host that boots one refuses
  to register rather than quietly putting every slot back on one daemon.
* **On a Windows pool, the isolation model is one local Windows account per
  slot — and there is no container under it.** Everything above about slot
  users, rootless daemons and the per-uid metadata fence is Linux. Windows has
  no container runtime on these hosts at all (the pool exists for a
  WiX/`signtool` packaging build, which needs the host's Win32 surface and is
  precisely what a Windows container breaks), and no working per-process egress
  filter either — an explicit block outranks every conflicting allow, and the
  one documented override needs IPsec the metadata server does not speak. So a
  Windows slot gets a private account, profile, workspace and TEMP, and the
  machine's system state below that — installed SDKs, the registry,
  `C:\ProgramData`, the certificate stores — is shared and persists across jobs.
  The boundary moves into IAM instead: the Windows host account is stripped to
  `roles/iam.serviceAccountTokenCreator` on the job account and **nothing** else
  — no Secret Manager, no metrics, no logs — because job code on a Windows host
  can mint a token for whatever that account is, and the host's boot probe
  proves it by asserting a 403 on both. Two consequences: `container:` and
  `services:` cannot run on a Windows pool and are refused by
  `scripts/ci/check-runner-policy.sh` (`RUNNER8`); and the first two rules in
  this list are not defence in depth there, they are the entire defence. Full
  residual: `docs/adr-windows-pool.md` §3A.
* **The Windows dependency cache is a real per-slot copy, and the three cheaper
  layouts are all unsafe here.** The split is the same shape as the Linux one —
  `C:\ci-cache` is the master, baked by the image, sealed to SYSTEM and
  Administrators with read-and-execute for the slot accounts and writable by
  none of them; `C:\ci\cache\<idx>\<tool>` is one private cache per slot and
  tool, copied from the master at boot by phase 7 of `windows-host-startup.ps1`,
  and it is what the slot's package managers are pointed at. What differs is the
  copy, and it is not a matter of taste:

  * A **junction** is one tree wearing K names. A read-only master means every
    package manager fails its first write; a writable one is the cross-slot
    channel with extra steps.
  * **NTFS hardlinks** — the Linux fallback of last resort — cannot work at all.
    A file's security descriptor lives on its MFT record, not on the directory
    entry, so *every hardlink to a file shares one ACL*. A slot's "own" copy
    would carry the master's ACL, could not be granted write for one slot alone,
    and granting it would grant it to all. On Linux this trade-off is a sysctl
    (`fs.protected_hardlinks`); on Windows there is nothing to trade.
  * **Block cloning** is a ReFS feature. The module provisions one 200 GB NTFS
    boot disk and no second volume.

  So each slot gets a real copy, and because K copies of a warmed tree is a real
  cost on a 200 GB disk, affordability is checked **per slot inside the loop**:
  the slots that fit are seeded and the rest run cold. Running out of disk
  halfway through the last copy is strictly worse than a cold cache — it leaves
  a partial tree that reads as a complete one, and it fails the *other* slots'
  jobs, which a cold cache never does.

  **Phase 7 is the one phase that fails open.** Every other phase ends in
  `Deny-Boot`. A host with no cache is slow; a host that refuses to register is
  missing, and the pool answers a missing host by queueing jobs. An image with
  no `C:\ci-cache` is therefore a supported image and needs no contract bump.

  **A Windows host hydrates from the snapshot, on the same terms as a Linux
  one.** Before the master is scanned and sealed, phase 7 fetches this pool's
  current snapshot and unpacks it over `C:\ci-cache` — same bucket, same
  `cache/<pool>/` prefix, same read-only grant, same age/size/free-space bounds,
  same one-budget-and-abandon rule, and the same verdict strings. Publishing is
  the same separate identity; a Windows pool publishes with a `windows-latest`
  job running `scripts/ci/build-cache-snapshot.ps1`
  (`docs/publishing-a-cache-snapshot.md`). Ordering is the design: the hydrate
  runs *before* `Protect-CacheMaster`, because what it writes is untrusted build
  input and the scan-and-seal is the gate that has to judge it, not something it
  arrives behind.

  Two Windows-specific pieces have no Linux counterpart. The staging and
  download trees are dropped through a reparse-point scan rather than
  `Remove-Item -Recurse`, because Windows PowerShell 5.1 — which is what runs
  the boot script — *follows a directory junction* on a recursive delete and
  removes what it points at (PowerShell/PowerShell#621, fixed in 6.0, never
  backported). And the master's own root is checked for hostility before
  anything is moved onto it, since the recursive scan that covers the rest of
  the tree runs afterwards, inside the seal.

  **What the Windows side does not yet have is the telemetry.** The boot script
  has no metric client at all, so the hydrate verdict is written to the boot log
  and nowhere else: a Windows pool that has silently stopped hydrating looks
  exactly like one that was never given a bucket. Tracked, not papered over.

  **The parent directories are SYSTEM's, not the slot's**, for the reason the
  Linux side states about `/var/lib/ci-cache/<idx>`: root never creates,
  renames or re-ACLs a name inside a directory an untrusted account controls.
  The layering is `C:\ci-cache` and `C:\ci\cache` and `C:\ci\cache\<idx>` all
  SYSTEM-and-Administrators, with the slot's `Modify` grant only on the
  `<tool>` leaves. The `.ready` marker sits one level *above* where a naive
  port would put it, in `<idx>`, precisely so a slot cannot forge it — phase 5
  reads that marker to decide whether to point ten environment variables at the
  tree. A slot has no ACE on `C:\ci\cache` or on its own `<idx>` and still opens
  `<idx>\npm` fine, because traversal is governed by `SeChangeNotifyPrivilege`
  ("bypass traverse checking"), which is granted to Everyone by default: a path
  is reachable when its **last** component grants access. That is already what
  makes `C:\ci\slots\<idx>` work, so it is the established pattern here rather
  than a new bet.

  **A warm cache is untrusted build input on Windows too.** `warm_cache_script`
  is arbitrary repo-supplied code running elevated in the build VM, and the tree
  it leaves behind is both ACL-walked and copied K times. The Linux scan refuses
  five things; three of them have no Windows spelling. Of the two that do, the
  **reparse point** is refused at build time and again at boot; the out-of-tree
  **NTFS hardlink** is not refused at all, and the seal rewrites the shared
  security descriptor at the file's other name -- a known gap, tracked as #238,
  because a link count needs a per-file `fsutil` call or a P/Invoke. `icacls`
  with `(OI)(CI)` follows a junction, so a junction aimed at `C:\Windows` is a
  read-and-execute grant applied *there* — and an ACL applied to the wrong tree
  is not undone by the next boot. `robocopy` follows one too, turning a cache
  seed into a per-slot copy of whatever it names. The root itself is scanned
  first, because a master that *is* a junction is the case where everything
  below it already belongs to another tree.
* **A job never inherits anything the previous job left in the slot.** The slot
  user is a normal Linux account, so its `$HOME` outlives every job the slot
  serves — and `setup-gcloud` persists whatever `google-github-actions/auth`
  produced as gcloud's *active* account. Nothing cleared it, so a deploy workflow
  left a deploy-capable identity in a home that the next pull-request job on that
  slot read as its own. Found because it also broke the thing nobody was
  watching: IntegrateIT's `pr-check` authenticates nowhere and expects the
  broker's ADC, picked up the stale external account instead, and ran with a
  permanently cold Turbo remote cache — a `token is expired` warning per cache
  call on every single run.

  A credential store is only the most visible thing a home carries, though: a
  `~/.gitconfig` naming a `core.hooksPath`, a line appended to `~/.bashrc`, a
  shadowing binary dropped in `~/.local/bin` and a previous workspace's
  `.git/hooks` are all *executed* by the next, unrelated job, and naming them one
  by one is a denylist that is wrong the moment a tool picks a new path. So the
  home is **replaced**, not cleaned: every pool runs a root-owned reset
  (`ACTIONS_RUNNER_HOOK_JOB_STARTED`, `..._COMPLETED`, and an `ExecStartPre` that
  covers an agent killed mid-job or a warm reboot) that empties the home and
  rebuilds it from a root-owned template, and takes the previous job's workspace
  and tool cache with it. Installed on every pool, including pools with no job
  service account, where an inherited credential is worst. A slot that cannot be
  shown to have been left clean fails its next job rather than running it.

  The one thing the reset deliberately keeps is the daemon's image store — that
  is where the warm layer lives, and deleting it would be a cold start per job.
  So what a job leaves there is pruned by *name* instead: at the end of every
  job, a local tag that carries no registry digest and whose image id is not in
  the boot-time baked manifest is untagged, with the layers left in place, so a
  rebuild is still warm. Without that, a job can tag or build any name it likes
  and the next job on that slot runs it while believing it fetched it — a local
  image by that name is resolved without ever contacting a registry, both by
  `docker run` and by a `FROM` in a later build (#233).
* **The remote BUILD cache is served by the host, so no repository wires one
  up.** A dependency cache saves downloading; a build cache saves building, and
  it dedupes across pull requests where a path filter only helps within one. The
  host runs a Turborepo remote cache against the project's cache bucket, under
  `turbo/<owner>/<repo>/`, and hands every slot `TURBO_API`, `TURBO_TOKEN` and
  `TURBO_TEAM` — a repository adds nothing to its workflows and holds no
  credential. That is the correction to the fault above rather than a separate
  feature: IntegrateIT's hand-built cache is what ran cold for weeks behind five
  warnings a run, and the fix that matters is that there is no longer anything
  per-repository to get wrong.

  **It is read-only to job code, permanently.** A turbo artifact is a tarball
  the next build unpacks into its output tree and reports as its own result, so
  a job that could publish one would hand every later build in that repository
  its output — the cross-slot channel the per-slot cache copy closes, and the
  cross-host one the snapshot bucket's read-only grant closes, re-opened with a
  better delivery mechanism. A host's grant is `roles/storage.objectViewer`
  conditioned on the repository's prefix; an upload from a job is accepted and
  discarded, because `turbo` reports a refused upload as a warning per artifact
  and a log full of those is the exact noise that hid the original fault. What
  fills the store is the default branch, published by an identity that never
  runs pull-request code.

  The whole layer fails open — a server that will not start, an unreadable
  bucket or an oversized artifact is a cache miss and a task that builds
  normally — and its port is `REJECT`ed on the primary interface, like the
  credential broker's, because it serves one repository's build output out of a
  bucket nothing off the host may read.
* **The metadata fence stops at port 80, and that is deliberate.**
  `169.254.169.254` is two services on one address: the metadata server over
  HTTP on port 80, and the VPC resolver on port 53. A container is handed that
  address as its only nameserver, so a blanket per-uid `REJECT` fences the token
  endpoint *and* takes name resolution away from every container a job starts —
  reported inside the container as `Temporary failure in name resolution`, which
  reads as a broken upstream registry rather than as host policy. Port 53 is let
  through per slot uid; port 80 is not, and the token endpoint still times out
  from inside a job's containers.
* **Each slot lingers.** A slot user never logs in, so it has no user systemd
  manager and no user D-Bus. `runc` asks systemd for a cgroup scope in
  `user.slice`; with no user manager to ask, it falls through to the system
  manager, which refuses an unprivileged caller with *Interactive authentication
  required*. Image builds keep working — buildkit needs no scope — and starting
  a container does not. `loginctl enable-linger` plus a per-slot
  `DBUS_SESSION_BUS_ADDRESS` is what makes the two agree.
* **The boot probe asserts the capability, not the daemon.** Both faults above
  left `docker info` answering, so a probe that only asked the daemon whether it
  was up passed on hosts where no job could run a container. It now also
  requires the slot's user bus to exist and the slot user to resolve a name. It
  deliberately does not start a container: that would need an image, and would
  turn a registry outage into a fleet that refuses to register.
* **`/tmp` is per slot, and the slot's daemon shares it.** Slots are separate
  users on one host, so a workflow step naming a fixed path under `/tmp` —
  and CI scripts name fixed paths there constantly — creates it under whichever
  slot ran first, and every later slot gets `Permission denied` on a file it
  believes is its own. It reads as a bug in the repository rather than as host
  policy, and it moves between repositories with whichever slot got there
  first. Each slot's dockerd runs with `PrivateTmp=yes` and its runner agent
  joins that same namespace, so `docker run -v /tmp/x:/x` still mounts the file
  the step just wrote instead of an empty directory.
* **A slot is told its share of the host, because it cannot measure it.** Slots
  are separated by user, network namespace and container daemon — and
  deliberately **not** by CPU. There is no `CPUQuota`, no `cpuset`, no
  `MemoryMax` on the agent unit, so `nproc` inside a slot reports the whole
  machine: 16 on an `n2-standard-16`, whether that slot is alone on the host or
  one of four. That is the right default. A hard quota would stop a lone job from
  using an otherwise idle host, and the pool exists to make jobs fast; the
  kernel's fair scheduler already divides a *contended* host sensibly.

  What it breaks is the very common workflow line `--max-workers=$(nproc)`. Every
  slot sizes its worker pool for the whole machine, and K of them do it at once.
  Measured on the IntegrateIT pool, 2026-08-22: 4 slots on 16 vCPU, each test job
  budgeting 2 packages x 6 workers from a comment that still said "one CI job per
  VM" — up to 48 workers on 16 vCPU plus four database service containers, about
  3x oversubscribed. Nothing errors. The jobs are slow and their per-test
  timeouts start expiring, which reads as a flaky suite and gets "fixed" by a
  re-run that oversubscribes the host again.

  So the unit carries four variables, computed at boot from the host it is
  actually on:

  | variable | value |
  |---|---|
  | `CI_SLOT_VCPUS` | host vCPU / `slots_per_host`, floored at 1 |
  | `CI_SLOT_MEM_MB` | host memory / `slots_per_host` |
  | `CI_HOST_VCPUS` | the host's own vCPU count |
  | `CI_HOST_SLOTS` | `slots_per_host` |

  A workflow sizes from `CI_SLOT_VCPUS` and falls back to `nproc` when it is
  unset — which is exactly the over-subscription above, so the fallback is a
  compatibility path and not a resting place. Both host totals are published too,
  so a job that genuinely wants to reason about the machine does not have to
  guess which of the two numbers `nproc` gave it.

  This is advice, not enforcement: a job that ignores the variable still gets the
  whole host if the host is idle, and still competes fairly if it is not. Pinning
  it as a quota is a separate decision, and would cost the idle-host case.

* **The dependency cache is shared read-only and written per slot.** The tree
  splits in two. `/opt/ci-cache` — **from image `v3-12-0` on** — is the master:
  root-owned, stripped of group and other write, shared by all slots and writable
  by none of them. `v3-12-0` itself shipped that directory `drwxrwsr-x runner:ci`,
  which the host's own hostility scan refuses (a setgid bit, on the tree root),
  so every host on it ran cold. The host now normalises the master's root
  directory — that one entry, non-recursively — before it scans, so a fleet on an
  old image repairs itself at boot. Nothing *inside* the tree is ever repaired:
  a hostile entry there is still a refusal, because a scan that sanitises what it
  finds is not a gate. `/var/lib/ci-cache/<idx>/<tool>` is one private cache per slot
  and tool, owned by that slot user, copied from the master at boot, and it is
  what the slot's package managers are actually pointed at.

  **What separates one slot's cache from another's is `/var/lib/ci-cache/<idx>`,
  not the cache directory itself.** That parent is `root:ci-s<idx>` mode `0710`:
  root owns it, the slot's own single-member group is the only other principal
  that may traverse it, and nothing can list it. The tool directory inside it is
  `0700` too, but that mode is defence in depth and cannot be the bound — the
  slot *owns* it, and an owner may always `chmod 0777` its own directory. A job
  that did so on a world-traversable parent would leave its cache writable by
  every later job on every other slot, and a poisoned npm cache is executed by
  the next `npx` that reads it, as that slot's user, with that slot's token. The
  control has to sit on a directory the job cannot change, so it does.

  The master's seal takes `go-w` and deliberately **not** `a-w`. On a root-owned
  tree the owner write bit protects nothing — root ignores it — but `cp -a`
  preserves mode, so stripping it hands every slot a copy of its own cache with
  no write bit on any directory: `EACCES` on the first install, from the copy
  whose entire purpose is to make that install unnecessary.

  **The directory *above* those is root's, not the slot's**, and that is a
  security boundary rather than tidiness. Root creates, renames and chowns names
  in `/var/lib/ci-cache/<idx>` on every boot; if the slot owned it, the slot
  could swap any of those names for a symlink between root's test and root's
  call and have root re-own the target. The usual statement of this hazard —
  "`chown -R` follows symlinks, add `-h`" — is backwards on both halves: GNU
  chown walks physically as soon as `-R` is given, and the form that *does*
  dereference is the plain `chown u:g path`. No flag fixes that if the path can
  be substituted, so the invariant here is about who owns the namespace, not
  about which flags the call carries.

  **One shared writable tree was the obvious design and it is not defensible.**
  Every directory in a dependency cache is a place its own tool treats as
  already-verified input: `npx` executes straight out of the npm cache, Maven
  skips checksum verification for an artifact already in the local repository,
  pip does not re-hash a cached wheel, NuGet verifies signatures on restore from
  the feed and not on a package it has already extracted. So a tree several slot
  users can write is not a cache — it is a channel by which one job hands another
  job code to run, as that slot's user and with that slot's token, routing around
  the separate uid, netns and container daemon the rest of this page describes.
  "A pool serves one repository" does not rescue it: a fork's pull-request job
  and a `main` deploy job holding the release credential are the same repository
  and run *concurrently* on one host.

  **The copy is a real copy, not a hardlink**, which costs disk in exchange for
  ordinary single-user semantics — K slots hold K copies, so `slots_per_host`
  multiplies the cache's footprint and `boot_disk_size_gb` has to carry it.
  Hardlink seeding (`cp -al`) looks strictly better and is not: `fs.protected_hardlinks=1`
  lets an unprivileged process link a file only if it owns it or can *write* it,
  so the root-owned read-only inodes that make sharing safe are exactly the ones
  a slot may not link — and pnpm and uv hardlink out of their stores into the
  workspace as their normal mode of operation. pnpm degrades to a silent full
  copy, uv can fail outright. Each slot owning its own copy removes the question.

  **Which caches are wired is a shorter list than it looks.** Nine are:
  npm, Yarn, pnpm's store, Go's *module* cache, pip, uv, Maven, NuGet, Composer.
  Three are deliberately left alone. `GOCACHE`, Go's build cache, is not safe for
  concurrent builds (golang/go#43645) and is a different directory from
  `GOMODCACHE`. The Actions tool cache (`RUNNER_TOOL_CACHE`) has no locking at
  all (actions/toolkit#804), and the `setup-*` actions treat it as a directory
  they own and prune, so seeding it would buy a rebuild rather than a saving.
  Gradle's `GRADLE_RO_DEP_CACHE` requires that nothing writes to it while builds
  read it, which a slot's own live cache is not.

  Go gets no `GOFLAGS=-modcacherw`. Go writes its module cache read-only by
  design, because `go.sum` authenticates the module *zip* at download and the
  build then compiles from the extracted tree without re-hashing it — that
  read-only mode is the extracted tree's only protection, and per-slot caches
  make Go's own default both safe and sufficient.

  **A seeded cache does not behave like one the job downloaded itself, and the
  difference shows up as `EACCES`.** A slot's copy arrives with the seal's modes:
  every FILE read-only, every DIRECTORY writable, all of it owned by the slot.
  Adding, replacing and removing entries all work — those need write on the
  parent directory, and it has it — but *rewriting a cached file in place* does
  not, and a job that does it gets a permission error on content it can plainly
  see it owns. `go clean -modcache` and `uv cache clean` are the reported cases.
  This is the correct trade rather than an oversight: `go.sum` authenticates the
  module *zip* at download and the build never re-hashes the extracted tree, so
  read-only files are the only thing standing between one job's write and the
  next job's compile. The workaround is one line before the command, and it
  always succeeds because the slot owns every file in the tree:

  ```bash
  chmod -R u+w "$GOMODCACHE" && go clean -modcache
  ```

  Do it in the job that needs it, not fleet-wide: the mode is per-slot and the
  host rebuilds it on the next boot either way.

  **A `container:` job gets no cache reuse.** These are systemd `Environment=`
  lines on the agent unit, and the runner passes only the workflow's own
  `container.env` (plus `HOME` and proxy vars) to `docker create` — nothing
  sweeps the worker's process environment into a job container. So a container
  job downloads its dependencies as before. It is not broken by this, just not
  helped: no variable reaches it pointing at a path it cannot write.

  **None of this can stop a host registering.** The cache layer fails open, alone
  among the boot steps here: a pool answers a *missing* host by queueing jobs and
  a *slow* host by being slow, so a cache fault is allowed to cost wall time and
  never capacity. On an image with no `/opt/ci-cache` the host emits no cache
  variables at all rather than variables pointing at a directory that is not
  there — the latter is a hard per-job failure, i.e. a missing speed-up turned
  into a broken pool.
* **A warm cache is untrusted build input.** A poisoned cache entry survives to
  the next job, which the old destroy-per-job model made impossible. Three
  bounds keep that survival finite. A pool serves one repository, so an entry can
  only reach jobs from the repository that produced it. The writable cache is per
  slot, so it reaches *later jobs on that slot* and never a job running beside it
  — that is the bound the rejected shared tree did not have. And it lives on the
  host's own disk: `/var/lib/ci-cache` is built at boot, survives a reboot, and
  dies when the instance is deleted, so a poisoned entry cannot outlive a
  recycle.

  Read the second bound precisely: agents are **not** `--ephemeral`, so "later
  jobs on that slot" includes a `main` deploy job holding the release credential
  running after a fork's pull-request job. That is not new — a slot's `~/.npm`,
  `~/go/pkg/mod` and `~/.m2` already persisted across jobs in its `$HOME` — and
  it is not what this layer changed. What this layer refused to do is widen it
  from *later* to *concurrent*, which is what one shared writable tree would have
  meant. Narrowing it further is an ephemeral-agent decision, not a cache one.

  The snapshot layer is that future layer, and it replaces the third bound with
  the explicit one: `cache_snapshot_max_age_hours`.
* **A host hydrates its cache from a snapshot, and never publishes one.** Set
  `cache_snapshot_bucket` and a booting host fetches this pool's current snapshot
  out of a shared `ci-runner-cache-bucket` and unpacks it over the baked master,
  so a scale-out under load does not hand every new host a cache as old as the
  image. The pool's host account gets `roles/storage.objectViewer` conditioned on
  `cache/<pool>/` — read only, this pool only.

  **Read only is the design, not a starting point.** A host executes job code, so
  a host that could publish a snapshot would let whatever one job left in a cache
  become the starting cache of every later host in the pool: the cross-slot
  channel the per-slot copy closes, re-opened across hosts and across time. A
  fork pull request would need to run once. Publishing belongs to a separate
  identity, `ci-runner-cache-publisher`: no key, attached to no VM, held only by
  a run of one named workflow file, in one named repository, on the default ref —
  all three in one claim, because a pool is shared across repositories and a
  `pull_request_target` run asserts the default branch while running fork code. It
  may create objects
  under its pool's prefix and may not overwrite them — no `storage.objects.delete`
  means "snapshots are written once" is enforced by IAM rather than trusted — and
  may replace exactly one object, the pointer. What it runs is
  `scripts/ci/publish-cache-snapshot.sh`, from a scheduled workflow in the
  consuming repository (`docs/publishing-a-cache-snapshot.md`): dependencies
  installed from the default branch into an empty tree, scanned with the host's
  own rules, packed and uploaded under a name never reused. A pool whose
  repository has not added that workflow finds nothing and runs on the baked
  cache.

  What arrives is inspected before any of it is trusted: it is unpacked into a
  staging tree outside the master, scanned by the same check the image build runs
  (links, device nodes, setuid, file capabilities, credential files), bounded by
  age, size and free disk, and then only the tool directories this host already
  knows about are moved in — a snapshot cannot introduce a new top-level name.
  The whole sequence runs against one budget (`cache_hydrate_budget_seconds`,
  60s) and every failure inside it returns, because the layer fails open like the
  rest of the cache path: a slow snapshot costs the first job a cold cache, a
  host waiting on one costs the pool a host.

## Telemetry

Every pool publishes the same series under `custom.googleapis.com/github/`, on
a `generic_node` resource labelled `repo` and `pool`, through one publisher
(`scripts/telemetry.sh`). One fleet dashboard covers every repository with no
per-repo dashboard code.

**The pool.** `ci_demand` (queued **and** in-progress — counting queued alone
collapses to zero the moment work starts), `ci_demand_queued`,
`ci_hosts_running`, `ci_hosts_max`, `ci_hosts_draining`, `ci_slots_total`,
`ci_slots_busy`, `ci_host_idle_seconds_max`, `ci_queue_wait_seconds_max`,
`ci_job_running_seconds_max`, `ci_mig_target_size`, `ci_drain_verdicts{outcome}`,
`ci_orphan_registrations_reaped`, `ci_hosts_stale_template`,
`ci_recycle_verdicts{outcome}`, `ci_poller_heartbeat`.

**The controller's own health.** `ci_tick_seconds`,
`ci_runner_list_blind_ticks`, `ci_demand_runs_skipped`,
`ci_outcome_runs_skipped`.

**The work, not the pool.** `ci_jobs_completed{workflow,outcome}` and
`ci_job_seconds{workflow}` — per-tick deltas on a gauge, so sum them over a
window rather than averaging, and read them next to `ci_poller_heartbeat`
because both are absent (not zero) when nothing finished.

**The cache hydrate.** `ci_cache_hydrate_verdict{verdict}`,
`ci_cache_hydrate_seconds`, `ci_cache_snapshot_age_hours`,
`ci_cache_snapshot_bytes`, `ci_cache_dirs_hydrated`. These are the one group the
**host** publishes rather than the controller, and once per boot rather than
once per tick — and, today, only a **Linux** host: the Windows boot script
hydrates on the same terms but has no metric client, so its verdict reaches the
boot log and no series. Read these as covering the Linux pools only, and do not
alert on their absence for a Windows one.
The reason they are host-published: the hydrate finishes before the runner agent registers, so the
controller never sees the machine it would be reporting on. Both accounts
already hold `roles/monitoring.metricWriter`, so this costs no new grant on a
machine that runs pull-request code.

They exist because the cache layer fails open on purpose. An expired snapshot, a
bucket that was never configured, and a pool whose every host times out on the
download are the same observable — jobs slower than they were, and nothing red
anywhere. Group `ci_cache_hydrate_verdict` **by its label**; the value is always
1 and means nothing alone. `hydrated` is the only good verdict, `not-configured`
is the correct steady state for a pool with no bucket (a host that could not
*read* its configuration says `no-metadata-server`, which is a different fact
and is alerted on), and everything else
(`no-snapshot`, `bad-pointer`, `too-old`, `too-big`, `too-big-expanded`,
`no-space`, `download-timeout`, `unpack-timeout`, `scan-refused`, …) names which exit was
taken. Age and size are recorded **before** the bounds that may reject the
snapshot, so a `too-old` verdict arrives with the number that produced it.

The full list is `metric_names` on the pool module; `scripts/ci/metric-contract.selftest.sh`
fails if the code and that output ever disagree, in either direction — reading
both startup scripts, because the pool publishes from two.

`ci_orphan_registrations_reaped` should sit at zero at steady state: a pool that
keeps reaping is losing hosts without going through the drain path.

`ci_queue_wait_seconds_max` and `ci_job_running_seconds_max` are the two halves
of a job's wall clock — how long it waited for a runner, and how long it has
held one. The second is what makes a wedged slot visible: when a runner agent
stops taking steps mid-job, GitHub still reports the job in flight and the
orphan reaper deliberately backs off from a busy runner, so nothing else in the
system can see it until the job's own `timeout-minutes` cancels it and fails a
required check. Threshold it per repository — there is no fleet-wide number that
is right for both a lint job and an integration suite — and alert on it together
with `ci_demand_runs_skipped`, because it rides the same sweep and is a lower
bound whenever that sweep ran out of budget.

`ci_poller_heartbeat` is published on every tick including a failed one:
"no data" there means the controller is down, which no other series can
distinguish from "the pool is idle".

`scripts/ci/ensure-alert-policies.sh --project <id> --email <addr>` brings one
project's policies up to the fleet's, idempotently. Two of the nine watch the
cache: *snapshot going stale* (`--cache-stale-hours`, 48 by default — set it
below the pool's `cache_snapshot_max_age_hours`, or the first notice anyone gets
is every host starting cold) and *hydrate failing on a configured pool*, which
excludes `not-configured` so it cannot page a pool that never wanted the layer.
Both are evaluated over a wide alignment window with no `duration`, unlike the
controller policies: their series appear once per boot, and asking a sporadic
series to hold a condition for ten minutes silences exactly the pool with few
boots and every one of them broken.

The ninth watches the egress record. `modules/ci-runner-network` logs the runner
firewall rules, so a refused outbound connection is now an entry rather than a
test client hanging until the job times out; a log-based metric counts those and
*egress refused* pages on a sustained run. The refusals are the alertable half.
The **allowed** destinations are the interesting half and no threshold can
express them — "somewhere new" is not "more" — so they are a diff instead:

```
scripts/ci/egress-destinations.sh --project <id> --fail-on-new
```

reads the window, keys each destination by the owning network rather than the
address (`as:36459|US|443` — a CDN rotation is one destination, a rented VPS is
a different ASN on the first packet) and reports anything absent from the
project's committed baseline under `docs/egress-baselines/`. A new destination
is then a pull request adding a line, reviewed by somebody who knows whether the
pool should be talking to it. `--update-baseline` seeds a pool's first one, and
seeding it is an act of review rather than a formality.

## Layout

```
modules/ci-runner-network/       the per-project firewall posture (no NAT),
                                 and the log of where the pool connects out to
modules/ci-runner-cache-bucket/  where a pool's cache lives between hosts
modules/ci-runner-apply-trigger/ the unattended apply, as the project's OWN Cloud Build
modules/ci-host-image-trigger/   the golden image, rebuilt by a merge instead of by hand
modules/ci-runner-host-pool/     the module consumers reference
  scripts/drain-decision.sh      pure scale-in rule (unit-tested)
  scripts/orphan-decision.sh     pure registration-reap rule (unit-tested)
  scripts/recycle-decision.sh    pure stale-template recycle rule (unit-tested)
  scripts/host-startup.sh        registers K agents; installs nothing
  scripts/controller-startup.sh  poll, publish, drain
  scripts/telemetry.sh           the single metric publisher
packer/ci-host-image.pkr.hcl     the golden image; repo-agnostic
scripts/ci/image-vuln-verdict.sh what the image may ship with (unit-tested)
docs/image-vuln-ignores.txt      the dated exceptions to that
scripts/ci/lane-decision.sh      pure CI-lane rule (unit-tested)
scripts/ci/                      self-tests
docs/onboarding-a-repository.md  how to put a NEW repo on the fleet
scripts/ci/check-merge-queue-single-step.sh
                                 the merge-queue rule consumers copy in
scripts/ci/check-runner-policy.sh
                                 which pool a job may claim, and for how long
scripts/ci/check-action-pins.sh  every third-party action pinned to a commit
scripts/ci/check-workflow-permissions.sh
                                 what a job may do to the repo, stated not inherited
scripts/ci/check-e2e-policy.sh   does a consumer's browser suite report honestly, and fast
scripts/ci/egress-destinations.sh
                                 where the pool connected out to, diffed against
                                 a reviewed baseline
docs/egress-baselines/           that baseline, one file per project
docs/ci-workflow-gates.md        those gates: rules, flags, how to adopt
docs/ci-lane-model.md            the lane contract consumers adopt
docs/ci-pr-shared-infra.md       one host per workflow run, one infra stack
docs/adr-pr-host-affinity.md     the decision behind that contract
docs/ci-merge-queue-baseline.md  one CI run per PR: the queue config + gate
docs/ci-optimization-catalog.md  the fleet audit behind that contract
packer/warm-cache/                optional baked caches, chosen per pool
.github/actions/playwright-ui/   the steps a repo's browser suite runs
docs/ui-testing-on-the-fleet.md  running Playwright UI tests on the fleet
```

## The CI lane model

This repository also publishes *how much CI a pull request deserves*, for the
same reason it publishes the pool: the rule had been re-derived in four
repositories with four different path lists, and two of them evaluate it inside
a `runs-on: [self-hosted, ...]` job — so a documentation-only pull request
claims a pool slot in order to decide it has nothing to do.

`scripts/ci/lane-decision.sh` is that rule as a pure function, asserted by
`scripts/ci/lane-decision.selftest.sh` on every change here. Three lanes:
`none` (no self-hosted job at all), `partial` (affected areas), `full` (diffs
whose blast radius is not visible in the diff — lockfiles, Dockerfiles,
workflows, infrastructure, migrations).

Consumers adopt it by tag, never by copying — see
[`docs/ci-lane-model.md`](docs/ci-lane-model.md) for the four adoption
requirements and the order they must be done in. The audit that produced it,
with per-repository measurements, is in
[`docs/ci-optimization-catalog.md`](docs/ci-optimization-catalog.md).

## One host per workflow run, and one infrastructure stack on it

Status: **accepted, landing phase by phase**. The decision is
[`docs/adr-pr-host-affinity.md`](docs/adr-pr-host-affinity.md); the contract
consumers adopt is
[`docs/ci-pr-shared-infra.md`](docs/ci-pr-shared-infra.md), whose delivery table
is the record of what is live. No consuming repository changes until phase 7,
and a repository adopting the shared stack needs `slots_per_host >= 2`.

The lane model bounds how much CI a pull request deserves. Nothing bounds
*where* it lands, and issue #205 measured what that costs: 12 concurrent slots
against ~25 jobs for one Apigee-Portal pull request, with three to four pull
requests in flight — queue waits of 291 s and, worse, unrelated required checks
displaced from 139 s to 406 s because nothing associates a job with the pull
request that asked for it.

Three rules follow from fixing that, and they are one decision:

* **A workflow run's self-hosted work runs on one host.** An affinity label
  (`host-<instance-name>`, registered at boot by both pools) plus an **anchor
  job**: the run's first fleet job goes out unpinned, and publishes the host it
  landed on for everything downstream to pin to. No API call, no token, no lease
  store — and the host is demonstrably alive, because a job of yours is on it.
  A host older than the contract is a **supported answer** that degrades to
  today's unpinned behaviour, because a label naming a host that is not there is
  a pull request that queues for 24 hours. The unit is a workflow *run* because
  job outputs do not cross runs; "one host per pull request" is what a
  repository gets once its `pull_request` CI is one workflow, which is the first
  step of adoption.
* **Infrastructure is brought up once per pull request**, by one job, and
  shared. `services:` is per-job by construction and is what this replaces.
* **A Windows job reaches that stack over the VPC.** Slots have separate network
  namespaces, so a sibling slot's `127.0.0.1` is not the owner's; the stack is
  published into a per-slot host port band, DNAT'd to the host address, and
  reached at that address by siblings and by the Windows host alike. The Windows
  pool still gets **no container runtime** — that decision
  ([`docs/adr-windows-pool.md`](docs/adr-windows-pool.md) §4) was reconsidered
  here and re-affirmed. Reachability, not a runtime.

`RUNNER9`/`RUNNER10`/`RUNNER11` in `check-runner-policy.sh` will assert the
three, opt-in by flag until adoption completes — a gate that fails every
repository the day it merges is a gate disabled in every repository the day
after.

## One CI run per pull request, or one per batch

The lane model decides how much CI a pull request deserves; it does not decide
how many times that CI runs. Mergify validates a queued pull request on a
throwaway `mergify/merge-queue/<sha>` branch — firing every `pull_request`
workflow a **second** time, on the fleet — unless the queue is serial,
unbatched, retry-free and single-step, and the fleet was in that state on
2026-08-14 (one repository's config was rejected outright and its queue was
failing closed).

That is **Tier 0**, and it is right for a repository whose pull requests wait
on CI. A repository whose pull requests wait on the *queue* — merge cadence
slower than one CI run — moves to **Tier 1**, where the second run is paid once
per batch rather than once per pull request. The two tiers differ by two
numbers in the gate, `MPC_MAX` and `BATCH_MAX`, and by nothing else.

**They are not the same kind of number.** Queue throughput is
`batch_size × max_parallel_checks`, but the runner bill is
`max_parallel_checks` alone: each parallel check is another concurrent CI run
drawn from the shared fleet, while each extra pull request in a batch rides a
run that is already happening. Wanting more throughput is an argument for
`batch_size`. It is never an argument for the width.

`scripts/ci/check-merge-queue-single-step.sh` is that rule, self-tested here —
including the Tier 1 detectors, which the fixtures exercise by raising the
ceilings for their own duration, so a repository that moves tiers inherits
proven checks rather than shipping untested ones. It is copied into each
consuming repository under the same name.
[`docs/ci-merge-queue-baseline.md`](docs/ci-merge-queue-baseline.md) has the
reference `.mergify.yml` for both tiers, the five properties, the measurement
that justifies a tier move, and where the gate must sit for a
`.mergify.yml`-only change to reach it.

## Releasing a version

`VERSION` holds the tag this repository currently publishes. Bump it **in the
same pull request as the change being released**. CI asserts that every module
pin printed in the documentation names the version in `VERSION`
(`scripts/ci/docs-pins.selftest.sh`) — the README quickstart had otherwise sat
three minor versions behind the fleet, in the one line a new consumer is most
likely to paste verbatim.

**The tag is created for you.** On every push to main, `publish-tag.yml` reads
`VERSION` and creates that annotated tag at the merge commit if it does not
already exist, then advances the floating major tag (`v5`) to it. Tagging was a
human step until v5.7.0 and it lapsed: tags stopped at v5.3.2 while `VERSION`
said v5.7.0, so v5.4.0, v5.5.0 and v5.6.0 merged, passed every gate, updated
every documented pin — and could not be pinned by anyone. Nothing went red,
because every gate that could have seen it compares the docs to `VERSION`, and
`VERSION` was right the whole time.

A published exact tag is never moved: it is what a consumer pinned. Only the
major tag floats, and it floats **forward only**. `publish-tag.yml` reads the
`VERSION` at the commit `v5` currently resolves to and refuses to move the tag to
anything older — a revert, a bad cherry-pick or a merge restoring an older
`VERSION` would otherwise walk the floating tag backwards, and that is a
fleet-wide downgrade that arrives at every consumer on its next apply with no
pull request anywhere and nothing red. An unreadable current version fails the
release rather than moving the tag blind; the next push to main retries it.

**The move is attempted only when it would change something.** A push that does
not bump `VERSION` finds the floating tag already at the object the exact tag
names, says so, and writes nothing — that call is the only one in the workflow
needing write access to a tag ref, and on 2026-08-15 six consecutive runs went
red on a `403` from it, five of them for a write that could not have changed
anything, over releases that had already been published correctly. A move that
*is* needed is attempted three times with the API's own response in the log, and
the tag is read back afterwards: a write that reports success and does not land
looks exactly like a published release until a consumer applies it. The workflow
is idempotent by construction and can be re-run by hand from the Actions tab
(`workflow_dispatch`), so recovering a release never means pushing a commit to
main for a non-release reason — and it refuses to run on any other ref, because
it tags the commit it runs on and a tag published at an unmerged commit can
never be taken back.

Consumers choose how they adopt:

| pin | adopts | costs |
|---|---|---|
| `?ref=v5.7.0` | when the repository opens and merges a bump | one pull request per release, per repository |
| `?ref=v5` | at its next `terraform apply` | nothing, and no review of what changed |

Either way a release does not repin anybody, and **nothing applies Terraform** —
a merged bump changes what the next apply will build, not what is running.

## Genericity

No customer, repository, project or region literal appears anywhere in this
repo. One image and one module serve every consumer; everything a host needs to
know about who it serves arrives as instance metadata at boot. A build flag
that made the image "the X image" would recreate, in the artifact, the drift
that vendoring created in the module.
