# The baked tool cache

A pool host ships with a Node.js runtime already unpacked in the layout the
`actions/setup-node` action looks in, so a job that pins one of the baked
versions skips the download entirely.

This page says what is baked, how a pool operator changes it, what a consuming
repository has to pin to get the benefit, what happens when it pins something
else, and — the part that matters most — **what this repository cannot detect**.

## Why it exists

Measured on a real run, `Telnet-Emulation` run `35440557902`, 2026-09-19:

| | |
|---|---|
| jobs in the run | 11 |
| total job wall time | 637s |
| spent in `Set up Node.js` | 215s |
| share of the run spent downloading a runtime | **34%** |

Every one of those 11 jobs downloaded the same ~60 MB tarball from
`github.com`, on a host that had already downloaded it for the previous job.
Nothing in this repository intercepts that: `actions/setup-node` resolves
against the runner's tool cache, and the runner's default tool cache lives
under `_work`, which `slot-reset.sh` wipes at the start of **every** job
because it is on `PATH` and is executed.

That wipe is not the bug — it is the isolation rule this fleet is built on. The
fix is therefore not to stop wiping, but to hand each slot a **fresh copy** of a
root-owned master outside `_work`.

## What is baked

The single declaration is the `tool_cache_node_versions` variable in
`packer/ci-host-image.pkr.hcl`. Nothing else in this repository restates a
version number — `host-startup.sh` reads the `MANIFEST` the image build wrote,
and this page is checked against the variable by
`scripts/ci/shared-cache.selftest.sh`.

<!-- baked-tool-cache:begin -->
```
node 24.21.0
```
<!-- baked-tool-cache:end -->

### `node_major` is a different thing

`node_major` in the same packer template is the **system** Node on `PATH`,
installed from NodeSource for tooling that runs outside a job's `setup-node`
step. It is a MAJOR (`24`). `tool_cache_node_versions` is a set of **exact**
versions (`24.21.0`) with their published SHA-256, and it is what the setup
action resolves against. Changing one does not change the other, and conflating
them is the mistake the variable's own description exists to prevent.

## How a pool operator changes it

1. Pick the exact version. Take its SHA-256 for
   `node-v<version>-linux-x64.tar.gz` from
   `https://nodejs.org/dist/v<version>/SHASUMS256.txt`.
2. Edit the `default` map in `packer/ci-host-image.pkr.hcl`. It is a map, so
   more than one version may be baked at once — each costs about 110 MB of
   image and about that much of local copy per job start.
3. Update the fenced block on this page to match. CI fails if the two disagree.
4. Check the support window: `scripts/ci/scan-support-windows.sh` reads these
   versions weekly, exactly as it reads `node_major`, and a version outside its
   upstream support window is reported.
5. Merge. The image is rebuilt by the fleet's own `ci-runner-host-image`
   Cloud Build trigger — **there is no manual image build**. Hosts pick it up
   as they recycle.

There is no Terraform variable for this and deliberately so: it is a property
of the **image**, not of a pool, and a pool that could override it would be a
pool whose hosts disagree about what they carry.

## What a consuming repository must pin

```yaml
- uses: actions/setup-node@<sha>
  with:
    node-version: 24.21.0   # runtime-pin: matches the baked tool cache
```

An **exact** version. `node-version: 24` or `node-version: lts/*` asks the
action to resolve a version at job time, and the version it resolves is
whatever is newest upstream that day — which is, by construction, not a version
any image was baked with.

## What happens when it pins something else

It downloads, exactly as it did before this existed. Nothing fails, nothing
warns, and the job is as fast as it used to be and no faster.

### This is the part that is NOT detectable here

This repository cannot see a consuming repository's workflow file and cannot
make its `setup-node` call fail. A pin that drifts away from the baked set is
therefore **silent on the consumer side, permanently**, and no gate added here
will change that. What has been made detectable is drift on **this** side:

| Drift | Detected? | By what |
|---|---|---|
| this page and the packer variable disagree | yes, red | `scripts/ci/shared-cache.selftest.sh` |
| a baked version leaves its upstream support window | yes, reported | `scripts/ci/scan-support-windows.sh` |
| the image baked a version but not its `x64.complete` marker | yes, at boot | `host-startup.sh` logs it per host |
| the master is hostile, missing or empty | yes, at boot | `host-startup.sh` logs it, host still registers |
| a consuming repository pins a version that is not baked | **no** | nothing — it just downloads |

The last row is the honest cost of the design. The alternative — a required
check in every consuming repository asserting its pin — was not built, because
16 repositories would then be unable to upgrade Node until this one had shipped
an image, which trades a silent slowdown for a fleet-wide block.

## How it reaches a job

1. **Bake.** Packer downloads each version, verifies its SHA-256, unpacks it to
   `/opt/ci-toolcache/node/<version>/x64`, creates the sibling marker file
   `x64.complete` — the file the toolkit's `tc.find('node', <version>, 'x64')`
   actually tests for — and appends a `MANIFEST` line. A version without the
   marker is invisible to the setup action, which is why the bake verifies the
   binary reports the version that was asked for before writing the line.
2. **Boot.** `host-startup.sh` scans the master for anything a root-run walk
   must not propagate, seals it root-owned and read-only, logs each baked
   version, and writes the verdict marker every later re-seed reads.
3. **Seed.** `/opt/ci/job-hooks/seed-tool-cache.sh <slot>` copies the master to
   `/var/lib/ci-cache/<slot>/tool-cache` — staged under a temporary name and
   published with an atomic `mv -T`, with the ready marker written last — and
   the slot's systemd unit gets `RUNNER_TOOL_CACHE` pointing at it.
4. **Re-seed.** The same script runs again from `slot-reset.sh started` before
   every job, so the tree is **replaced**, not kept.

## The two objections this design had to answer

**"The setup-\* actions prune the tool cache as though they own it."** They do.
Now a prune costs exactly one job: the next job starts against a fresh copy.
The worst case degrades to the download that happened on every job before this
existed, which is why re-seeding on reset — not only at boot — is load-bearing
rather than tidiness.

**"`RUNNER_TOOL_CACHE` is documented as unsafe to share (actions/toolkit#804)."**
That is a *concurrent-writer* failure: two jobs writing one tool cache at the
same moment. This path is scoped to one slot, and a slot runs one job at a
time — the identical argument that already makes the per-slot npm, pnpm, Maven
and uv caches safe. What remains forbidden, and is still asserted by
`scripts/ci/shared-cache.selftest.sh`, is a **shared, group-writable** tool
cache: `chgrp ci`, mode `2775`, `UMask=0002`, `cp -al` seeding and a shared
`GOCACHE` are all still refused. The rule got narrower on purpose, not quieter.

## Where the code is

| | |
|---|---|
| the one declaration | `packer/ci-host-image.pkr.hcl`, `tool_cache_node_versions` |
| the bake | same file, provisioner step 5b |
| scan, seal, seed | `modules/ci-runner-host-pool/scripts/host-startup.sh` |
| the per-job re-seed | generated `/opt/ci/job-hooks/seed-tool-cache.sh` |
| the gates | `scripts/ci/shared-cache.selftest.sh`, `scripts/ci/scan-support-windows.sh` |
