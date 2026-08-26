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

**Status (Windows, 2026-08-22): the layer now exists on both operating systems.**
Until issue #150 closed, everything above was Linux-only: a Windows host had no
master, no per-slot copy and no tool pointed anywhere, so a Windows pool paid the
per-job download on every job of every host and the saving in the table below was
literally zero there. `windows-host-startup.ps1` phase 7 is the counterpart --
`C:\ci-cache` sealed read-and-execute to the slot accounts, a real per-slot copy
under `C:\ci\cache\<idx>`, and the same nine tool directories under the same ten
environment variables. Three things differ and each is forced rather than chosen:
the copy is a genuine copy because NTFS hardlinks share one ACL across every link
and block cloning is ReFS-only; affordability is re-checked per slot against a
25 GB floor on the 200 GB boot disk, so the slots that fit are seeded and the
rest run cold; and the snapshot layer above is **not** wired to Windows yet, so a
Windows host still starts cold after a scale-out or a recycle. That last one is
the Windows half of "per-pool adoption is what is left", tracked separately.

Note for whoever picks this up: `setup-*` actions re-downloading toolchains is
**not** part of this and must not be folded into it. The Actions tool cache has
no locking (actions/toolkit#804), so pointing concurrent slots at one is a
documented corruption, not an optimization. It needs a tree nothing writes
during a build.

### 4.3 Docker layer caching

Image-building jobs (`image-smoke` at 138 s average, `docker-build` in
Specaria-Platform) rebuild layers from scratch. Registry-backed
`--cache-from`/`--cache-to` against Artifact Registry is the fix.

### 4.4 Remote build cache for the monorepos — shipped, both halves

IntegrateIT (~277 packages) and Apigee-Portal would benefit more from a shared
Turborepo/Nx remote cache than from finer path filters: a remote cache dedupes
work *across PRs*, whereas a path filter only ever helps within one PR.

It is now part of the pool rather than something a repository assembles. A host
serves `turbo-cache-server.py` against the project's cache bucket, under
`turbo/<owner>/<repo>/`, and hands every slot `TURBO_API`, `TURBO_TOKEN` and
`TURBO_TEAM` — so a workflow that never heard of this fleet gets hits, holds no
credential and has nothing to renew. `cache_snapshot_bucket` alone turns it on;
`turbo_cache_bucket` exists only to point it elsewhere or switch it off.

Being *inside* the pool is the fix, not a packaging choice. The hand-wired cache
§4.1 is about ran cold for weeks and reported the fault as five warnings inside
green runs. A per-repository cache is a per-repository way to be silently slow.

Job code cannot write, and that is permanent. An artifact is a tarball the next
build unpacks into its output tree and reports as its own result, so a writable
cache is one pull request handing every later build its output — uploads are
accepted and discarded rather than refused, because a refusal is one warning per
artifact and that noise is what hid the original fault.

What fills the store is `modules/ci-runner-cache-warmer`: one Cloud Build
trigger, fired nightly by Cloud Scheduler, that installs the default branch's
dependencies and runs its build, then publishes both results — the turbo
artifacts under `turbo/<owner>/<repo>/` and the dependency snapshot under
`cache/<pool>/`. It is the fleet's only identity allowed to write cache content,
it is attached to no VM, and its grants carry create without delete, so a
published object cannot be replaced in place. Because turbo's local
`<hash>.tar.zst` **is** the remote artifact byte for byte, publishing is a plain
object copy and the host-side server still has no write path at all.

That also retires the per-repository snapshot workflow: a repository that used
`ci-runner-cache-publisher` was wiring federation, a workflow file and a
schedule of its own to produce the same object this now produces for it. See
`modules/ci-runner-cache-warmer/README.md` for the migration.

Nx is not covered: its remote-cache protocol is not the one this server speaks.

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
`pipefail` — `head -n`, `grep -m`, `sed q`.

**An earlier revision of this section carved out an exception, and the exception
was wrong.** It said that when the value is what you want and the status is
ignored — `x=$(cmd | head -1)` — the artefact is harmless. The status is not
ignored. `x=$(…)` is a simple command whose exit status *is* the substitution's,
so where `set -e` is also in effect the assignment is what dies:

```bash
$ bash -c 'set -euo pipefail; x="$(yes | head -1)"; echo reached'; echo $?
141
```

That sentence is the one consumers copied. IntegrateIT's `pr-check` installs
Terraform and then asserts the version it got with
`got="$("$bindir/terraform" version | head -1)"`. Four of thirty consecutive
failed runs died there with exit 141 — *after* printing
`terraform_1.9.8_linux_amd64.zip: OK`, so the download and the checksum had both
succeeded — and two of those four were inside a merge-queue speculative check,
which dequeues the pull request and re-runs the whole batch.

Three things let the shape survive review:

- `set -e` and `pipefail` are usually established far from the offending line,
  and GitHub's `shell: bash` is `bash --noprofile --norc -eo pipefail {0}`, so a
  `run:` block can be in scope without the word `pipefail` appearing in it. The
  default shell, with no `shell:` key, is `bash -e {0}` — errexit, no pipefail.
  Whether the block is affected is decided by a key that is not there.
- `local x=$(cmd | head -1)` **is** safe: `local` is a builtin with its own exit
  status, which masks the substitution's. Identical text, opposite verdict, one
  keyword apart. (Masking a failure is its own defect, but not this one.)
- It is a buffering race, so it passes while the writer's output is small and
  starts failing when the tool gets chattier or the machine gets busier.

`scripts/ci/check-pipefail-readers.sh` (rules PFR1/PFR2) is the gate for this,
wired into `ci.yml` beside the other shell sweeps. No linter has the rule —
shellcheck does not model `pipefail` — and a plain grep for the idiom is mostly
false positives, so the gate is narrow on purpose: only where **both** options
are in effect, only bare assignments and bare pipeline statements, never a
`local`, never a pipeline the author already guarded with `||`, and never an
`if` condition. That last exemption is the important one: `set -e` is suspended
in a condition, `if … | grep -q …` is idiomatic across all fourteen repositories,
and a gate that lights up on hundreds of correct lines is a gate somebody
deletes — which costs more than the findings are worth.

Whenever a gate fails, print the input it judged, not only the verdict. A gate
that says only "not found" cannot be told apart from a gate that is broken.

### 5.3 Retry granularity

There is no flake-retry policy anywhere in the fleet. When a flake occurs the
whole workflow is re-run — every shard, every install, every gate — to re-run
the one test that wobbled.

The measurement, taken over the last thirty failed `pr-check` runs on the
largest consumer during the #74 delivery:

| Failing step | Runs |
|---|---|
| aggregate (reports the failure, is never the cause) | 30 |
| `Test (this shard)` | 16 |
| `Build + typecheck + lint (turbo)` | 9 |
| `Install Terraform (for the infra gate)` | 4 |
| Designer module-size | 1 |

**Two rows in that table point in opposite directions, and the second one is
why this section is not simply "turn retries on".**

The sixteen `Test (this shard)` failures are the waste this section names: one
shard wobbles and the whole workflow pays.

The four `Install Terraform` failures were **not flakes**. All four exited 141 —
the `pipefail` defect §5.2 above dissects, fixed in #206 and IntegrateIT #9888.
It is a buffering race, so a retry would have gone green on a fair share of
second attempts. A blanket retry policy would have hidden a real bug behind an
intermittent green, and an intermittent defect is one nobody fixes. **The gate
that would have concealed it is the one this section recommends** — which is the
whole reason the shape matters more than the feature.

So, four constraints, and a retry layer that drops any of them costs more than
the re-runs it saves:

- **Retry at the test level, inside the runner.** Not `retry-on-failure` on the
  job, not a re-run of the workflow. A framework-level retry re-runs the test;
  everything around it — checkout, install, build, the other shards — stays
  done.
- **Never retry a setup, install or gate step.** Those failures are
  environmental or they are defects, and both want to be loud. Scope the retry
  to the test-execution step and nothing else. The Terraform four are what this
  clause is written against.
- **A retried pass is a flake, not a green.** If attempt 2 is indistinguishable
  from attempt 1 in the report, the flake rate stops being observable and the
  suite rots quietly. Report it, count it, and put the count somewhere someone
  reads.
- **Cap it at one retry.** A test that needs two is not flaky, it is broken;
  that is a quarantine decision, not a retry setting.

**Where this lands is a consumer repository, not this one.** The runners do not
decide retry policy — the test runner's own configuration does. What belongs
here is the constraint above, so that a consumer copying this catalog copies the
trap along with the recommendation.

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

### 7.4 What the fleet actually RUNS ON — shipped

7.1 and 7.2 both look at what a pull request pulls in. Neither looks below it.
Every warm host in this fleet boots one golden image, and the only description
of that image was the template that built it — a list of what was *asked for*,
which stops being the same set the moment a transitive dependency moves, and
which says nothing about whether any of it is known-vulnerable.

That is not a hypothetical gap. `node_major` was pinned to 22 and sat ten months
past the end of its support window before anyone noticed, and that value is
written down in the template in plain text. Everything apt resolved underneath
it was not written down anywhere at all.

**Shipped:** the image build produces an SBOM of its own finished filesystem
(`syft`, pinned + checksum-verified), scans it (`grype`, likewise), and refuses
to create the image when the scan finds something **fixable, at or above
`_VULN_FAIL_ON`, in an installed distro package**. The SBOM is published to
`_SBOM_BUCKET` and also left on the image at `/opt/ci-image-sbom/`, so a host
that turns out to be affected by something disclosed later is answerable on the
box.

Four design choices, each against a specific way this kind of gate dies:

- **Only findings grype matched through the distro's own feed block.** For a
  `deb`, grype asks Ubuntu whether *this* package version is affected and Ubuntu
  answers knowing what it backported. For anything syft found by reading a
  binary — the `linux-kernel` cataloger, a Go module compiled into an executable
  — there is no distro opinion to ask for, so grype compares the upstream
  version against NVD/GHSA. Measured on this gate's first real run (build
  `f5510d02`, 2026-08-18): 22,161 findings, 273 blocking, **all 273 from binary
  catalogers** — 105 against `linux-kernel 6.17.0-1022-gcp` reported "fixed in
  5.16, 6.2, 6.7…", and 168 against `golang.org/x/crypto v0.23.0` vendored
  inside dockerd, containerd and snapd. The `deb` entries for those same kernels
  produced thousands of matches and **zero** blocking, because there Ubuntu's
  data reports the backport. Left as it was, the gate was red on every image
  forever for findings nobody here can fix. They are still counted and printed,
  on the summary line, as `off-distro`. The cost was named rather than hidden —
  a genuinely vulnerable vendored module in an image-installed binary no longer
  failed the build — and it is now bounded rather than open: the population is
  **enforced by identity**, not by count. The `(id, package)` pairs the image
  carries live in `docs/image-vuln-offdistro.txt` (seeded 2026-08-26 from build
  `1057f771`: 117 pairs behind 273 findings), and a pair not in that file is a
  red build with a pull request as the review. A count would have been useless
  here — it moves whenever the vulnerability database does — whereas a new pair
  is a new statement about this image. Attributing a vendored module to the
  distro binary that already patched it still needs a scanner that understands
  binary provenance; that is the remaining piece, and it is no longer the only
  thing standing between this gate and a silent regression. **A finding whose
  `artifact.type` the report does not state blocks**, exactly as a `deb` would:
  the test is "distro package *or* provenance unknown", so the day grype renames
  that field the gate goes red rather than quietly narrowing to nothing.
- **Only fixable findings block.** A gate that fails on something nobody can act
  on acquires an `|| true` within a month. Unfixable findings are still reported.
- **Every exception expires.** `docs/image-vuln-ignores.txt` entries carry a
  date; the day after it the gate goes red and names the entry. The failure mode
  of a vulnerability gate is not missing something — it is becoming a file of
  exceptions added under deadline and never revisited.
- **The decision is a separate, unit-tested script.** `image-vuln-verdict.sh`
  runs against fixtures in this repository's CI. The alternative is a policy
  observable only inside a forty-minute image build that no consumer's CI runs —
  which is how the `inline_shebang` defect in 7.2's neighbourhood survived.

The vulnerability database is fetched as its own **retried** step before the
scan, not left to grype's implicit auto-update. `grype.anchore.io` returned a
bare EOF on two of the first three real image builds; implicitly, that surfaces
as a WARN and then, two seconds later, `failed to load vulnerability db:
database does not exist` — a build lost 25 minutes in, to a network blip. Five
attempts with a growing backoff, then a hard failure, and `grype db status`
after them to prove the file is actually on disk.

Two separate reasons for that shape. The retries are for the blip: it is a
transient EOF, and a 25-minute build should not die on one. The explicit
`db status` is for the other end — `grype db update` exits 0 when it decides no
update is needed, which on a cold cache whose listing fetch failed is
indistinguishable from success. Today the scan that follows would error out
(`database does not exist`), so the build fails loudly; but that is grype's
current behaviour, not a contract, and the failure mode it protects against is
a scan that reports zero findings for want of data. "Found nothing" and "a
clean image" are the same line of output, so the build proves the database is
there rather than inferring it from a scan that did not complain.

The floor starts at `critical`, not `high`, deliberately: the steady-state
finding count for a full Ubuntu userspace plus docker, node and PowerShell is
not yet known, and a gate that is red on its first run for reasons nobody
intends to act on is a gate somebody removes. The reports this now publishes are
what will justify lowering it.

**Not covered:** the Windows image. syft has almost nothing to catalog on that
filesystem, and an SBOM listing four packages would read as a clean result while
describing nothing.

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
   token expiring.

   Removing the two credential stores by name was the first fix and it was a
   denylist: the same home also carries a `~/.gitconfig` that can name a
   `core.hooksPath`, a `~/.bashrc` every subsequent shell sources, a `~/.local/bin`
   on `PATH`, and — one level up, in `_work` — the previous job's checkout with
   its own `.git/hooks` and a `_tool` directory the runner puts on `PATH`. Those
   are *executed*, not read, and the list is wrong the moment a tool picks a new
   path. `install_job_hooks()` therefore **replaces** the home rather than
   cleaning it: `ACTIONS_RUNNER_HOOK_JOB_STARTED` and `..._COMPLETED` both run a
   root-owned `slot-reset.sh` that empties `$HOME` and rebuilds it from a
   root-owned template, and removes the previous job's workspace and tool cache.
   Both ends, because the completed hook alone leaves a live credential on disk
   while the slot idles; and a third reset as `ExecStartPre=+` on the agent unit,
   because neither hook runs when an agent is killed mid-job or the host reboots
   warm. It is installed on every pool, including pools with no job service
   account, where an inherited credential is worst because nothing there should
   hold Google credentials at all.

   **The writers go before the files do.** Replacement is the second half of the
   reset, not the first: `slot-reset.sh` removes the containers the last job left
   detached and then terminates every remaining process of the slot — `SIGTERM`,
   then `SIGKILL` — before it empties anything, and writes the clean marker only
   once both have succeeded. In the other order every individual step is still
   correct and the composition is not: a container bind-mounting the home, or a
   server a step backgrounded, has a window between the template restore and its
   own removal in which to write `.bashrc`, `.gitconfig` or a credential back,
   and the marker then certifies a slot a writer outlived. Three things are
   spared by name, because each of them would turn a cleanup into an outage: the
   hook's own ancestry (the agent that called it), the slot's rootless dockerd
   and everything under its user manager (the next job needs that socket), and —
   when the caller is a root timer rather than the agent — the agent's own
   process tree. A writer that will not die withholds the marker exactly as an
   unremovable container does, and a slot **held** by a live run is spared
   wholesale until the hold expires.

   Three things make wholesale replacement affordable, and each is why the reset
   is cheap rather than a cold start. The warm caches live under `/opt/ci-cache`,
   not in the home. The rootless daemon's data root is passed explicitly as
   `--data-root=/var/lib/ci-slot/<idx>/docker`, so every image the host has warmed
   survives a reset — without it dockerd defaults to `$HOME/.local/share/docker`,
   inside the tree being deleted. And `_actions`/`_temp` are kept at
   `started` only, because the runner fills them *before* it calls that hook.
   `started` only is the whole of it: `_temp` is `RUNNER_TEMP`, which is where
   `google-github-actions/auth` writes its credential file, so a `_temp` kept at
   `completed` would leave that file for the next job on the slot — the same leak
   one directory over from the home the reset rebuilds.

   The reset runs as root through a `sudoers.d` rule that names the two permitted
   argument forms literally; which slot is reset comes from `SUDO_UID`, never from
   an argument, so a slot can only reset itself. Root is not a convenience: a
   job's rootless containers write through a user namespace, so the directories
   they leave are owned by subordinate uids and `rm -rf` as the slot user returns
   `EACCES` on exactly the leftovers that matter. A `clean` marker in a
   root-owned directory closes the last gap — a job that starts on a slot whose
   predecessor never reached its completed hook is failed loudly rather than run
   over an untrusted `_actions` tree.

   Root does not walk a name the slot can swap. The slot owns
   `/opt/ci/slots/<idx>` — `config.sh` writes `.runner` and `.credentials`
   there — so `_work` is renamed into a root-owned 0700 holding directory for
   the duration of the reset and renamed back at the end. `rename(2)` is atomic
   and carries the runner's open handles with it, so the workspace it already
   prepared survives; what it does not carry is the slot's ability to plant a
   symlink at a name between root's `rm -rf` and its `install -d`. A `_work`
   that is already a symlink is refused rather than followed, and a `_work` the
   slot recreated while root worked in the holding directory is refused rather
   than removed — both leave the marker unwritten, which fails the next job.

   The `boot` reset in `provision_slot_user` is skipped when that slot's agent
   is already running. On a warm reboot the `ci-runner@` units start
   independently of `google-startup-scripts.service`, so an agent can be
   executing a job while the startup script is still walking the slots, and a
   reset there would empty a live job and then record the slot clean. Skipping
   loses nothing: the unit carries its own `ExecStartPre=+slot-reset.sh boot`,
   so a slot whose agent is up has already been reset by the path that owns
   that decision.

   **A dirty slot is recovered by a timer, not by the next job.** The marker is
   the right gate and it had the wrong exit: the `started` hook was the only
   thing that ever wrote one back, so a slot whose job never reached its
   completed hook stayed condemned. Every job routed there afterwards was failed
   in about six seconds — *faster than a healthy slot can claim work*, so the
   broken slot preferentially won the queue and re-running the workflow spread
   the outage rather than clearing it. IntegrateIT lost twelve of twenty-four
   slots to it on 2026-08-23, from an ordinary `fail-fast` cancellation.
   `install_slot_sweep()` therefore runs `slot-sweep.sh` on a 30-second timer:
   any slot with no marker, no `Runner.Worker`, and a settled systemd state for
   two consecutive ticks has its agent stopped, is re-checked for a worker,
   is reset through the same `slot-reset.sh` the hooks call, and comes back.
   Recovery stops costing a job. Two witnesses and two ticks are both load-
   bearing — the marker is absent for the whole length of a *live* job, so
   "dirty" alone describes a running job exactly as well as an abandoned one —
   and the reset now takes a per-slot `flock`, because the sweep made root a
   second concurrent caller of a script that had only ever been called serially
   by the runner.

   **And a slot the timer cannot recover leaves the pool rather than eating
   it.** Retrying forever is right for a transient obstruction and wrong for a
   permanent one: while the sweep retries, the slot is still registered, still
   offered work, and still failing it in six seconds — which is precisely how
   twelve broken slots out-competed twelve healthy ones for the same queue.
   `slot-reset.sh` therefore counts consecutive failures to reach a clean state
   into `$SLOT_STATE/<idx>/burns` — root-owned, beside the marker, because the
   subject of the measurement is the slot — and clears it the moment the slot
   comes back clean. Past `CONDEMN_MAX=3` the sweep stops starting that slot's
   agent. Not disabled and not deleted: the reset is still attempted every tick,
   and a slot whose obstruction clears is put straight back into service.

   The fleet can already see this without a new API call or a new guest
   attribute. A stopped agent leaves the repository's runner list, and
   `host_facts()` has always counted how many of a host's slots answer; that
   count is now published as `ci_slots_registered`, and the gap against the
   slots the pool was built with as **`ci_slots_missing`** — the series to alert
   on. `ci_slots_total` is arithmetic, hosts × slots, so it reads identically
   whether every agent registered or none did, which is why three separate
   outages all presented as "the pool looks fine and jobs queue": a host that
   registered nothing (#130), a host whose slot units died before the agent
   started (#268), and a condemned slot (#278). The sum counts only RUNNING
   hosts past their registration grace, so ordinary scale-out does not move it,
   and a tick that could not read the runner list contributes to neither side —
   an unreadable API cannot fake an outage.

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
| 10 | Real warm cache — snapshot layer shipped v5.22.0; Windows per-slot layer shipped 2026-08-22; per-pool adoption and a Windows snapshot to land | 4.2 |
| 11 | Batch settings + scopes in every queue | 6 |
| 12 | Build-once/reuse, Docker layer cache, remote monorepo cache | 3.4, 4.3, 4.4 |
| 13 | SHA-pin actions — gate shipped v5.4.0, 344 findings to land | 7 |
| 14 | Fast/heavy runner classes and shared overflow capacity | 2.3, 2.4 |
| 15 | Per-lane suite reuse across base moves — rule shipped, adoption to land | 6 |
