# CI check-process optimization catalog

Fleet-wide audit of 14 repositories with GitHub Actions CI, plus the shared
self-hosted runner pools this repository provisions. Every item below is a
*measured* gap, not a generic best practice: the evidence column names the repo
and the number it came from.

Scope of the audit: `.github/workflows/*.yml` and `.mergify.yml` in
`Apigee-Portal`, `Atlas`, `Borsh-Tablet-App`, `CarListPrice`, `DataRetrival`,
`IntegrateIT`, `Manar`, `Print-Server`, `SOAP-To-REST`, `Specaria-Platform`,
`Telnet-Emulation`, `ci-runner-infra`, `entity-platform`, `mot-face-blur`.

---

## 0. What the numbers actually say

| Measurement | Result |
|---|---|
| Non-code-only PRs (last 60 merged) | Apigee-Portal 3%, SOAP-To-REST 6%, DataRetrival 10%, Specaria-Platform 15% |
| Queue wait, median | 0 s in all four busy repos |
| Queue wait, worst observed | DataRetrival 5 817 s (97 min), SOAP-To-REST 2 528 s, Specaria-Platform 1 306 s |
| Jobs carrying `timeout-minutes` | 0 of ~34 in DataRetrival, 0 of ~112 in SOAP-To-REST, 1 of ~61 in Print-Server |
| Workflows carrying `concurrency` | DataRetrival 1/6, Specaria-Platform 5/10, Atlas 3/6, Print-Server 5/8 |
| Third-party actions pinned by commit SHA | 0 of ~375 uses, fleet-wide |
| Repos that skip CI on draft PRs | 1 of 14 (Apigee-Portal) |

Two conclusions follow, and they change the priority order:

1. **The pool is not chronically saturated — it is burst-saturated.** A median
   wait of zero with a 97-minute tail means the cost to fix is not "buy more
   hosts", it is "stop holding slots you are not using". Cancellation,
   timeouts, and draft-skipping attack the tail directly.
2. **Non-code PRs are a small share of PRs but a disproportionate share of
   wasted slot-seconds**, because today the skip decision is made *after* the
   runner is claimed (§2.1).

---

## 1. Trigger tier — never create the run at all

The cheapest job is one GitHub never schedules.

### 1.1 Draft vs ready pull requests — largest single saving

Only Apigee-Portal implements this. Its `ci.yml` is the reference:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
```

```yaml
    if: >-
      github.event_name != 'pull_request'
      || github.event.pull_request.draft == false
      || startsWith(github.head_ref, 'mergify/merge-queue/')
```

Both halves are load-bearing and both are non-obvious:

- Without `ready_for_review` in `types:`, a draft that is later marked Ready
  never re-fires, and the guarded checks stay `SKIPPED` while the PR reports
  `mergeStateStatus=CLEAN` — green-looking and untested.
- Without the `mergify/merge-queue/` escape hatch, Mergify's speculative branch
  (which is itself a draft PR, not a `merge_group` event) skips every required
  check and **no PR in the repo can ever merge**.

Why this is the biggest item: the standing PR policy is that agents open PRs as
drafts by default and keep at most two non-draft per repo. So the fleet's normal
state is *most open PRs are drafts*, and in 13 of 14 repos every push to a draft
runs the full suite on the pool.

Recommended tiering, rather than all-or-nothing skipping:

| Tier | Runs on draft? | Contents |
|---|---|---|
| fast | yes | classifier, lint, typecheck, format, cheap static guards |
| heavy | no — on `ready_for_review` and later | unit suites, integration, image smoke, e2e, CodeQL, perf, Lighthouse |

A draft still gets fast feedback; the pool stops paying for suites nobody reads
until review.

**Prerequisite, not a footnote — the heavy tier's job names must not be the
required check names.** A job skipped on a draft records a real check-run with
conclusion `skipped` on the head sha, and that run outlives the draft phase: the
`ready_for_review` re-run adds a `success` run with the same name on the same
sha, and Mergify reads the `skipped` one. On DataRetrival #2338 that reported
`lint`, `typecheck`, `migrations` and `migration-harness` as failing with every
job green, and `@mergifyio refresh` did not clear it — only a new head sha did.

It only bites when `ready_for_review` is the last event on the sha, which is why
it hides: a pull request with one more commit after being marked ready is spared,
and the agent-authored one that was complete when opened is not. Adopt §3.1
first, or draft tiering converts a saved pool slot into a stuck queue. Full
write-up and the always-completing-shim fix: `docs/ci-lane-model.md`.

### 1.2 Workflow-level `paths-ignore` on satellite workflows

Only 3 of ~90 PR-triggered workflows have any path filter at the trigger
(`Atlas/lighthouse-ci.yml`, `IntegrateIT/windows-agent.yml`,
`Print-Server/govulncheck.yml`). A trigger-level filter means **no run object,
no queue entry, no runner** — strictly better than a job-level `if:`.

Trap: a filtered-out required check reports nothing at all and blocks the merge
queue forever. Trigger-level filters are only safe on workflows that are (a) not
required, or (b) behind the aggregate check of §3.1.

### 1.3 Duplicate `push` + `pull_request` triggers

22 workflows declare both. That is correct when `push` is limited to the default
branch (post-merge verification), which is the case in most of them — but audit
each: any `push:` without a `branches:` restriction double-runs every branch
push alongside the PR run.

### 1.4 Bot pull requests

Dependabot PRs currently take the full self-hosted suite. They need the
dependency-relevant subset (build + unit + audit) and can take `ubuntu-latest`.

### 1.5 Fork pull requests

Only `entity-platform` routes forks away from the self-hosted pool:

```yaml
runs-on: ${{ (github.event.pull_request.head.repo.fork && 'ubuntu-latest') || vars.CI_RUNNER_LABEL || 'ubuntu-latest' }}
```

Everywhere else, fork-authored code would execute on a GCP VM holding a service
identity. This is a security finding as much as an efficiency one, and it should
be a fleet invariant, not a per-repo choice.

---

## 2. Placement tier — do not spend a pool slot to decide not to work

### 2.1 Gate at job level, not inside the job

`Apigee-Portal/ci.yml` and `DataRetrival/ci.yml` run `dorny/paths-filter` as a
*step* inside a `runs-on: [self-hosted, …]` job, then guard the remaining steps
with `if: steps.gate.outputs.run == 'true'`. A docs-only PR therefore claims 13
pool slots in Apigee-Portal purely to decide to do nothing.

`Specaria-Platform/ci.yml` and `entity-platform/ci.yml` show the correct shape —
one classifier job, then `needs: changes` + `if: needs.changes.outputs.go == 'true'`
on each consumer. `entity-platform` additionally puts the classifier on
`ubuntu-latest`, which is the version to standardize on.

The reason the two repos gate in-job is real, and must be fixed first: a
job-level `if:` reports `skipped`, and a `skipped` required check dequeues a PR
in Mergify permanently. §3.1 removes that constraint.

### 2.2 Zero-dependency guards do not belong on the pool

In Apigee-Portal, `source-maps`, `sql-migrations`, `doc-claims`,
`context-budget`, `test-path-filters` and `workflow-shell` are pure Node-stdlib
or shell checks with no install and no build — and all six run on the
self-hosted pool, unfiltered, on every PR. Six pool slots per PR for work
`ubuntu-latest` does in seconds. The same pattern exists in SOAP-To-REST
(`env-alignment`, `soft-rules-enforce`, `hardening-audit`, `genericity`) and
Specaria-Platform (`gitleaks`, `generic-binary-check`).

### 2.3 Two runner classes, not one

Every pool is addressed by a single per-repo label
(`[self-hosted, linux, gcp, <Repo>]`). One label means a 30-second lint and a
10-minute integration suite compete for the same scarce hosts. Splitting the
pool into a small always-warm `fast` class and an autoscaled `heavy` class lets
short jobs bypass a burst entirely.

### 2.4 No cross-repo overflow capacity

Labels are per repo, so a saturated `DataRetrival` pool cannot borrow an idle
`Manar` host. That is the mechanism behind the 97-minute tail. A shared
overflow label that any repo may target as a fallback would absorb bursts
without raising steady-state host count.

**Not adoptable as written.** One repository per pool is a SECURITY boundary
here, not a capacity choice: hosts are warm and reused, so caches, checked-out
trees and any credential material a job leaves behind outlive it. A label two
repositories can both target puts one repository's job on a host the other just
used. An overflow pool is viable only if its hosts are EPHEMERAL — destroyed
after a single job — and take a repository-scoped identity at registration
rather than holding a shared one. Cost that before treating this row as a
recommendation; the 97-minute tail may be cheaper to fix with faster scale-out.

---

## 3. Structure tier — shape of the check graph

### 3.1 One aggregate required check per repo (prerequisite for everything else)

Specaria-Platform's `ci-success` job (`needs: [...]`, `if: ${{ !cancelled() }}`
— **not** `always()`, which reports a permanent red from every superseded run;
see the lane model's "A superseded run must not report") is the
pattern: individual jobs may skip freely, and the single job named in the branch
ruleset and in `.mergify.yml` always reports. DataRetrival independently reached
the same shape for `migration-harness` — its own comment records why:

> The `migration-harness` context ALWAYS completes … on a no-migration-change
> PR it reports success (heavy job skipped == pass) rather than `skipped`, which
> would otherwise dequeue the PR forever.

Generalize it. Without this, every other item in this document is blocked.

### 3.2 Collapse satellite workflows into jobs

Apigee-Portal runs 6 separate PR-triggered workflows beyond `ci.yml`
(`generic-binary-check`, `image-smoke`, `postgres-integration`,
`review-findings-to-issues`, `security-scan`, `unit-tests`, `web-tests`). Each is
its own checkout, its own toolchain setup, its own pool acquisition of the same
commit. As jobs inside one workflow they share the classifier, share `needs:`
ordering, and are cancellable as a unit.

Counter-case worth preserving: a workflow that must run when `ci.yml` is broken
(this repo's own rule — CI for the fleet must not depend on the fleet) stays
separate on purpose.

### 3.3 Detect/run/report split as the standard shape

DataRetrival's `migration-harness-changes` → `migration-harness-run` →
`migration-harness` triple is the reusable shape for any expensive conditional
gate. Promote it to the template rather than re-deriving it per repo.

### 3.4 Build once, reuse downstream

Typecheck, lint, unit tests and image build each re-install and re-build the
same tree. Publishing the built output once via `upload-artifact` and consuming
it downstream removes the repeated build, which is the dominant cost in
Apigee-Portal's 646-second average Unit Tests run.

### 3.5 Matrix discipline

`max-parallel` appears in only 2 of 14 repos. On a self-hosted pool an
unbounded matrix from one PR starves every other PR. `fail-fast` is set
inconsistently (5 uses in Apigee-Portal, 0 in SOAP-To-REST and CarListPrice) —
it should be `true` wherever a single failure already fails the gate.

---

## 4. Cost-per-job tier

### 4.1 Caching is close to absent

`actions/cache` uses: Atlas 0, Specaria-Platform 0, entity-platform 0,
Telnet-Emulation 0, Manar 0, mot-face-blur 0, Borsh-Tablet-App 0, CarListPrice 0.
Warm hosts hide this — until a host is cold or newly scaled out, at which point
every dependency downloads again inside the burst that caused the scale-out.
Caching matters *most* exactly when the pool is under pressure.

### 4.2 The golden image's warm cache is a stub (shipped as a boot-time layer)

`packer/warm-cache/none.sh` in this repository is a no-op. Everything a repo
installs on every job — npm registry contents, Go module cache, Maven/Gradle
artifacts, base container layers — is a candidate for baking. This is the one
optimization that helps every repo without touching any repo's workflows.

`packer/warm-cache/playwright.sh` is the first real one, and it is opt-in per
pool rather than fleet-wide: the browser image is the largest thing baked into
any image here and it helps only the repositories that run UI tests. It also
shows the shape a **container** cache has to take — `docker save` to
the root-owned `/opt/ci-images/`, loaded per slot at boot — because a plain
pre-pull lands in a daemon no slot uses. Note that it is deliberately outside
`/opt/ci-cache`, which reaches every slot as a writable copy: a cached *file* is
untrusted build input, but a cached *image* is executed in every slot on the
host. See [`docs/ui-testing-on-the-fleet.md`](ui-testing-on-the-fleet.md).

**Status (v5.12.0): half done, and the missing half was the larger one.** The gap
was never only that nothing warmed the tree — it was that nothing *used* it.
`/opt/ci-cache` existed from image `v3-12-0`, and no tool on any host had ever
been pointed at it: npm still wrote `~/.npm`, Go still wrote `~/go/pkg/mod`, and
both live in a slot `$HOME` that is private per slot and destroyed with the host.
Warming the tree first would have produced a measured saving of zero and read as
"caching does not help here".

v5.12.0 wires the tools to a cache (`host-startup.sh`, `cache_env()`), so it now
accumulates across jobs on a warm host. **Not to the shared tree**: `/opt/ci-cache`
became the root-owned read-only *master*, and each slot gets a private copy of it
under `/var/lib/ci-cache/<idx>`. A cache several slot users can write is a
code-execution channel between concurrent jobs — every package manager treats its
own cache as already-verified input — and the per-slot boundary the pool is built
on would be worth nothing with that channel through it. The cost of the copy is
disk: K slots hold K copies. See README.md's isolation rules for the full
argument.

What v5.12.0 did not do was survive the host: a scale-out or a recycle still
started cold, which is exactly when the pool is under the pressure that made
caching matter (§4.1). That is the snapshot layer, and it is deliberately *not*
a bake: one image serves every pool while cache content is per-repository, and a
baked cache freezes at build time. It hydrates the master, which is read-only and
therefore the one place a snapshot can land without reopening the channel above.

**Status (v5.22.0): shipped, and per-pool adoption is what is left.** A booting
host reads a pointer object under the pool's own prefix and unpacks the snapshot
into the master before the agent registers; a trusted scheduled run — never a
pull-request job — packs the next one and swaps the pointer under a generation
precondition. The bound the persistent snapshot removed is restored explicitly:
`cache_snapshot_max_age_hours` makes a stale snapshot get ignored rather than
trusted, the bucket carries a matching lifecycle rule, and the read grant is
conditioned on the pool's prefix so one pool cannot reach another's cache. The
hydrate fails open under `cache_hydrate_budget_seconds` — a cache problem starts
a host cold, it never stops it registering.

That fail-open is also why this section can no longer be read as "done": a pool
that never sets `cache_snapshot_bucket` behaves exactly as it did before, and so
does a pool whose publishing run quietly stopped. Both are silent by
construction, which is what `ci_cache_hydrate_verdict` and the `cachestale` /
`cachefail` policies exist to say out loud — see
[`docs/publishing-a-cache-snapshot.md`](publishing-a-cache-snapshot.md) for the
wiring and README.md for the verdicts. Until a pool opts in and
`ensure-alert-policies.sh` has run against its project, the saving here is still
zero, and nothing will page about it.

Note for whoever picks this up: `setup-*` actions re-downloading toolchains is
**not** part of this and must not be folded into it. The Actions tool cache has
no locking (actions/toolkit#804), so pointing concurrent slots at one is a
documented corruption, not an optimization. It needs a tree nothing writes
during a build.

### 4.3 Docker layer caching

Image-building jobs (`image-smoke` at 138 s average, `docker-build` in
Specaria-Platform) rebuild layers from scratch. Registry-backed
`--cache-from`/`--cache-to` against Artifact Registry is the fix.

### 4.4 Remote build cache for the monorepos

IntegrateIT (~277 packages) and Apigee-Portal would benefit more from a shared
Turborepo/Nx remote cache than from finer path filters: a remote cache dedupes
work *across PRs*, whereas a path filter only ever helps within one PR.

### 4.5 Checkout cost

35 `actions/checkout` invocations in Apigee-Portal, 18 of them with an explicit
`fetch-depth` — most of those are `fetch-depth: 0` because diff-based guards
need history. A full clone per job, times 13 jobs, on every PR. Fetching only
two commits (`fetch-depth: 2`, then `git diff --name-only HEAD^1 HEAD`) gives
the same diff at a fraction of the transfer, because on a `pull_request` event
HEAD is the merge commit GitHub built and HEAD^1 is its base.

Do **not** reach for `git fetch --depth=1 origin $BASE_SHA` plus a triple-dot
`git diff "$BASE_SHA"...HEAD`. Triple-dot asks git to compute a merge base, and
each shallow fetch lands as its own grafted root with no shared ancestry, so it
fails with `fatal: ... no merge base` — under `set -euo pipefail`, on every
pull request. `--depth` deepens an existing shallow history; it does not
reconnect two roots.

---

## 5. Reliability tier — red and hung checks are pure waste

### 5.1 Missing `timeout-minutes` is the highest-severity easy fix

Jobs with no timeout inherit GitHub's 360-minute default. On a self-hosted pool
a hung job holds a host for six hours; worse, Mergify's `checks_timeout` expires
first and the PR is *silently dequeued* rather than turning red. Apigee-Portal
documented exactly this in its `.mergify.yml` after PR #1429, and pinned the
ordering invariant:

> per-workspace timeout (20m) < job timeout-minutes (<=25m) < 40 min
> [`checks_timeout`]

Nine repos have effectively no job timeouts at all.

### 5.2 A permanently red gate

Apigee-Portal's `Postgres Integration` was non-success in 11 of its last 13
PR runs (252 s average, ~54 min of pool time in that window). A gate that is
almost always red consumes capacity and trains everyone to ignore it. Either
fix it or quarantine it to non-required until it is fixed — leaving it as-is is
the worst of the three options.

### 5.2a `grep -q` inside a `pipefail` pipeline — a gate that inverts itself

Every repo here writes shell gates, and the idiom they all reach for is

```bash
set -uo pipefail
awk '…' file | grep -q 'the thing that must be there'
```

which is wrong. `grep -q` exits the moment it matches; the writer upstream then
takes SIGPIPE and exits 141; `pipefail` propagates that as the pipeline's
status. **A successful match is therefore reported as a failure** — and only
sometimes, because it is a race with how much the writer had already buffered.
That is precisely the shape that passes on a laptop and fails on a runner
against a byte-identical file, so the first instinct is to hunt for a
difference between the two machines that does not exist. It cost a full
diagnosis cycle here on `host-startup.selftest.sh` before the assertion was made
to print the text it had matched against, at which point the text plainly
contained the string it claimed was missing.

The dangerous direction is the inverted check — `if grep -q <bad-pattern>; then
fail`. There the artefact turns a real regression into a silent `ok`, and
nothing ever prints. `identity-split.selftest.sh` check 1 was that shape.

Write the match against a string, never through a pipe into an early-exiting
reader:

```bash
matches() { # <text> <ere> — grep -c reads to EOF, so nothing upstream is signalled
  local n; n=$(printf '%s\n' "$1" | grep -cE -- "$2"); [ "${n:-0}" -gt 0 ]
}
matches "$(awk '…' file)" 'the thing that must be there'
```

The same applies to any early-exiting reader at the end of a pipeline under
`pipefail` — `head -n`, `grep -m`, `sed q`. When the value is what you want and
the status is ignored (`x=$(cmd | head -1)`), it is harmless; when the status is
the verdict, it is a bug.

Whenever a gate fails, print the input it judged, not only the verdict. A gate
that says only "not found" cannot be told apart from a gate that is broken.

### 5.3 Retry granularity

There is no flake-retry policy anywhere. When a flake occurs the whole workflow
is re-run, multiplying the cost of the flakiest suites. Retry at the test level.

---

## 6. Merge-queue tier

| Setting | Present in | Consequence where absent |
|---|---|---|
| `batch_size` | Apigee-Portal (5), DataRetrival (5) | speculative CI run per PR instead of per batch |
| `batch_max_failure_resolution_attempts` | nowhere | unbounded bisection when a batch fails, or — set too low — innocent pull requests dequeued with the culprit. **Mandatory wherever `batch_size` exceeds 1**, at `ceil(log2(max))` or above |
| `batch_max_wait_time` | DataRetrival (1 min) | lone PRs wait for companions that never come |
| `checks_timeout` | Apigee-Portal (40 min) | inherits an undeclared ~42-min vendor default; hangs surface as silent dequeues |
| `scopes` | IntegrateIT | batches mix unrelated areas, so a batch failure bisects across unrelated changes |
| priority lanes | none | a docs change queues behind a migration |

Additional queue-level items:

- **Lane-specific queues.** A non-code PR should enter a `docs` queue with
  `priority: high` and no batching — still serialized, so merge ordering holds,
  but never behind a heavy batch.
- **Single source of conditions.** Several configs duplicate the same check list
  in `queue_rules.merge_conditions` and in `pull_request_rules.conditions`.
  When the two drift, PRs stick with no visible error. Keep one list.
- **Per-lane suite reuse.** The queue's re-check after a base move is legitimate
  — it is how a semantic conflict between two independently-green PRs is caught
  — but most merges cannot change most PRs. A documentation merge costs one full
  suite per PR still in flight and provably cannot change an outcome.
  Content-address each lane over its declared inputs in the merge-result tree
  and reuse the recorded green result: `scripts/ci/suite-reuse-key.sh`, adopted
  through [`ci-suite-reuse.md`](ci-suite-reuse.md). Fails closed on every doubt,
  and no lane reuses across a CI-process change.

---

## 7. Supply-chain tier

Zero of ~375 third-party action references are pinned to a commit SHA — all use
mutable tags (`@v4`, `@v7`). These actions run on self-hosted VMs that hold a
GCP identity. Pin by SHA and let Dependabot propose the bumps; this also removes
the surprise-breakage class of CI failure, which is itself wasted CI.

**Shipped:** `scripts/ci/check-action-pins.sh` (v5.4.0) enforces it — PIN1 the
commit SHA, PIN2 the version comment beside it so Dependabot's bumps stay
reviewable, PIN3 `docker://` images by digest. Re-measured 2026-08-15 across the
ten locally-cloned consumers: **344 unpinned references, zero repositories
clean**. See `docs/ci-workflow-gates.md` for adoption, including the Dependabot
config without which pinning becomes permanent staleness.

### 7.1 Dependabot answers the other question — shipped

Pinning plus Dependabot keeps a dependency *current*. Neither of them notices
when a version stops being *supported*, and the fleet was full of the
difference. Measured 2026-08-16, with no alert raised anywhere:

- **Node 18** — end of life 2025-04-30, sixteen months past.
- **Node 20** — end of life 2026-04-30, four months past.
- **Node 22** — end of life 2027-04-30, so every end-of-life check reads it as
  fine. Its ACTIVE support ended 2025-10-21, and new applications were being
  started on it while Node 24 was available and supported for another year.
- **The golden image itself** — `node_major` in `packer/ci-host-image.pkr.hcl`
  was that same Node 22, inherited by every host in the fleet, named in no
  application manifest and covered by no Dependabot ecosystem.

The third bullet is the one no existing tool can reach: 22 is not "behind"
anything a version check tracks, and its end-of-life date is eight months out.
What is wrong is the *runway* of a line chosen for something new.

**Shipped:** `scripts/ci/support-window-decision.sh` — SUP1 past end of support,
SUP3 a NEW declaration on a shorter runway than an available line, SUP2 inside
the migration window, SUP5 maintenance-only (informational), SUP4 undecided and
never a pass. Delivered as the reusable workflow
`.github/workflows/support-windows.yml`; it reports through an issue and a pull
request comment rather than a required check, because none of its dates are
moved by the pull request being checked. See `docs/dependency-freshness.md`,
including why `eol: false` upstream means "no date announced" and reading it as
a boolean reports the whole fleet clean.

### 7.2 What the pinned code may DO — shipped

Pinning decides what arrives on a pool. It says nothing about what that code is
allowed to do once it runs, and the default answer is the worst one available:
omit `permissions:` and a job does not get nothing, it gets the **repository
default** — a value in a web console, invisible in the pull request, and
`read-write` for every repository created before GitHub changed it. On this
fleet the resulting `GITHUB_TOKEN` is readable by every step in the job,
including the install scripts of every transitive dependency it downloads, on a
warm host holding a GCP identity beside other jobs' caches and trees.

**Shipped:** `scripts/ci/check-workflow-permissions.sh` — PERM1 the set is
stated (in the job or the workflow above it) rather than inherited, PERM2 a
write sits on the job that needs it rather than on every job in the file
(`write-all` never does; a one-job file is exempt, because there is nothing to
move), PERM3 no `secrets: inherit` to a remote reusable workflow, PERM4
undecided and never a pass. Run against this repository on its first pass it
found two workflow-level writes — both single-job, both correct — which is the
measurement that produced the one-job exemption rather than an allowlist entry.
See `docs/ci-workflow-gates.md`.

### 7.3 Where the pool connects out to — shipped

The supply chain does not end at what a lockfile installs; it ends at what the
installed code then talks to. A warm host holds a GCP identity, runs
third-party code out of every lockfile, and reaches `0.0.0.0/0` on 443 by
necessity — the registries publish large rotating ranges and pinning them in a
firewall rule breaks builds on every upstream rotation. Until now nothing wrote
down a single destination, so "did anything leave this pool" had no evidence
either way. An exfiltration and a clean pool looked identical.

Two halves, and the second is what makes the first worth paying for.

**Recording.** `modules/ci-runner-network` logs its rules
(`firewall_logging`, default `all`, `INCLUDE_ALL_METADATA`) — one entry per
connection with the destination, port, deciding rule and disposition. Not Cloud
NAT logs (this estate peers out through a central firewall, there is no NAT
here) and not VPC flow logs (the module does not own the subnet). It owns the
rules, and the rules carry the same 5-tuple. The health-check rule is never
logged at any setting: probes every few seconds per host forever would bury the
record they were charged for.

**Reading.** Refusals are alertable and are now an alert
(`ci_egress_denied`, a log-based metric, and the *egress refused* policy) —
before it, a blocked egress presented as a test client hanging until the job
timed out. Allowed destinations are the interesting half and are *not*
alertable: Cloud Monitoring knows *more*, not *new*, and the connection that
matters is one packet. So `scripts/ci/egress-destinations.sh` diffs the window
against a baseline committed under `docs/egress-baselines/`, keyed by owning
ASN rather than address so a CDN rotation is one destination and a rented VPS
is a different key on its first packet. A new destination is a pull request
adding a line. A tool that updated its own baseline would agree with whatever
happened last night, including the thing it exists to catch.

---

## 8. Governance tier — how this stays true

1. **Publish the lane model as a reusable workflow from this repository**,
   consumed by tag exactly as `modules/ci-runner-host-pool` already is. Repos
   get fixes without 14 hand-edits — the same argument this repo's README makes
   against vendoring the Terraform module.
2. **Add a drift gate** mirroring the existing `ci-runner-*` module drift check:
   fail if a consuming repo re-implements the classifier locally.
2a. **Gate the pool boundary itself, not only the lane.** Item 2 above and §5.1
   are both statements about a workflow file that nothing read.
   `scripts/ci/check-runner-policy.sh` (v5.4.0) now does: RUNNER1 a self-hosted
   `runs-on` carries a repository-scoping label, RUNNER3 every job declares
   `timeout-minutes`, RUNNER4 fork code stays off a warm host, RUNNER5 a
   dynamically selected runner is reported UNDECIDED rather than passed. The
   finding that justifies it is the one no reader had found: exactly ONE job in
   the fleet is self-hosted with no scope label, so it may be scheduled onto any
   repository's warm host — which is the isolation rule in `README.md` failing
   silently, because from GitHub's side it is a job that found a runner.
3. **Budget the always-on set.** A PR that adds a new unconditional required
   job should have to justify it, in the same shape as the existing
   `Resident instruction context within budget` gate.
4. **Measure where the seconds go — shipped in v5.5.0.** Every series the pool
   published described the *pool*: hosts, slots, queue depth. None described the
   *work*, so "which workflow spends the runner seconds, and which one spends
   them failing" was answerable only by reading run logs by hand, per
   repository — which is why it had only ever been answered for the loudest one.
   The controller now publishes `ci_jobs_completed{workflow,outcome}` and
   `ci_job_seconds{workflow}` for every job it actually ran.

   Three properties are worth knowing before reading them:

   * **The unit is a job on this pool, not a job in the repo.** The same
     superset rule that bounds demand bounds cost, so a repository's
     GitHub-hosted jobs never appear in a self-hosted pool's attribution.
     Otherwise the numbers would recommend warming a cache for work that never
     touches a warm host.
   * **Outcomes are read from the completed-runs list, not from the demand
     sweep.** The demand sweep holds a full job payload already, so counting
     there looks free — but it only ever fetches runs that are queued or in
     progress, and a run leaves both lists the instant its last job finishes.
     It can see every job except the ones that finished last, and the job that
     finishes last is very often the one that failed. A red rate built that way
     is biased exactly where it is read.
   * **The label is a workflow, not a lane.** The lane verdict (§ below,
     `scripts/ci/lane-decision.sh`) is computed inside the workflow; the
     controller never sees it. Attributing seconds to `full` / `partial` /
     `none` needs the workflow to report its own verdict, which is item 1 of
     this section, not this one. Workflow-level attribution is what is
     available without a cross-boundary contract, and it already answers where
     to spend next.
4a. **See a wedged slot — shipped in v5.6.0.** `timeout-minutes` (item 2 above)
   bounds what a stuck job costs; it does not make one visible, and the two are
   easy to confuse. When a runner agent stops taking steps mid-job, GitHub still
   reports the job in flight, and the orphan reaper deliberately backs off from
   a runner GitHub calls busy — so the wedge is invisible until the timeout
   cancels the job, fails a required check, and blocks the PR. Observed
   2026-08-15 on DataRetrival #2404: eighteen steps in 35 seconds, step nineteen
   never dispatched, fifteen minutes of nothing, every sibling job green, and
   the only visible symptom a `migrations` gate failing closed on a
   `cancelled` upstream.

   `ci_job_running_seconds_max` closes that gap using job payloads the demand
   sweep already pays for: the age of the oldest job this pool has actually
   started. It is a max rather than a count over a threshold because "too long"
   is per repository — a fleet-wide constant either misses the wedge on a repo
   with a half-hour integration suite or cries wolf on one whose longest job is
   a lint. Threshold it per repo, against that repo's own longest legitimate
   job. `ci_jobs_completed{outcome="cancelled"}` is the same event after the
   fact, and a rising cancel rate with no queue-cancel activity to explain it
   points here.
4b. **Stop a job inheriting the last job's credentials — shipped in v5.7.0.** A
   slot user is an ordinary Linux account created once per host boot, so its
   `$HOME` outlives every job the slot serves. Nothing cleared it, and no pool
   set `CLOUDSDK_CONFIG`, so `setup-gcloud` — which runs
   `gcloud auth login --cred-file=…` and makes the workload-identity account
   gcloud's *active* account — left that credential in place for whatever job
   landed on the slot next.

   IntegrateIT paid for this continuously. `deploy.yml`,
   `deploy-mcp-server.yml`, `cve-triage.yml` and `windows-agent.yml` all run on
   the same pool as `pr-check.yml`, which authenticates nowhere and expects ADC
   from the host broker. Instead its `gcloud storage` calls picked up the
   leftover external account and failed with `Unable to retrieve Identity Pool
   subject token … token is expired`. Every sampled run showed exactly five such
   warnings — one cache publish, four shard pulls — so the Turbo remote cache
   was cold on **every** run: shard 1 logged 229 `:build:` misses and 0 hits and
   spent 10m54s of a 17m16s step rebuilding dependencies before its first test.

   Worth separating the two costs, because only one of them is about speed. The
   cache was dead, which is minutes per shard per run. The other is that a
   deploy-capable identity sat in a shared home reachable by an arbitrary pull
   request, and the only thing that stopped it being usable was the OIDC subject
   token expiring. `install_job_hooks()` wires
   `ACTIONS_RUNNER_HOOK_JOB_STARTED` and `..._COMPLETED` to a root-owned script
   that removes the slot's `~/.config/gcloud` and `~/.gsutil` — both ends,
   because the completed hook alone leaves a live credential on disk while the
   slot idles and never runs at all when an agent is killed mid-job. It is
   installed on every pool, including pools with no job service account, where
   an inherited credential is worst because nothing there should hold Google
   credentials at all.

   The symmetric caution: a workflow that *relied* on a previous job's login now
   fails. Nothing in this fleet does — every workflow that needs GCP either runs
   `google-github-actions/auth` itself or uses the broker's ADC — but a repo
   that authenticated once in a setup job and shelled out to `gcloud` in a later
   job on the same pool would have been depending on the bug.
5. **Ship it as the new-project baseline** via the `scaffold` skill and
   `setup-github`, so a new repo starts with lanes rather than acquiring them
   at repo #15.

---

## Priority order

Ranked by saved pool-seconds per unit of work, with dependencies respected.

| # | Item | § |
|---|---|---|
| 1 | Aggregate required check per repo — unblocks everything else | 3.1 |
| 2 | `timeout-minutes` on every job; pin `checks_timeout` in every queue | 5.1, 6 |
| 3 | Draft/ready tiering in the 13 repos that lack it | 1.1 |
| 4 | `concurrency` + `cancel-in-progress` on every PR workflow | audit table |
| 5 | Move gating out of the job; classifier on `ubuntu-latest` | 2.1 |
| 6 | Move zero-dependency guards off the pool | 2.2 |
| 7 | Fix or quarantine the permanently-red gate | 5.2 |
| 8 | Non-code lane, in workflows and in a `docs` queue | 1.2, 6 |
| 9 | Fork PRs off the self-hosted pool (security) | 1.5 |
| 10 | Real warm cache — snapshot layer shipped v5.22.0, per-pool adoption to land | 4.2 |
| 11 | Batch settings + scopes in every queue | 6 |
| 12 | Build-once/reuse, Docker layer cache, remote monorepo cache | 3.4, 4.3, 4.4 |
| 13 | SHA-pin actions — gate shipped v5.4.0, 344 findings to land | 7 |
| 14 | Fast/heavy runner classes and shared overflow capacity | 2.3, 2.4 |
| 15 | Per-lane suite reuse across base moves — rule shipped, adoption to land | 6 |
