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

Specaria-Platform's `ci-success` job (`needs: [...]`, `if: always()`) is the
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

### 4.2 The golden image's warm cache is a stub

`packer/warm-cache/none.sh` in this repository is a no-op. Everything a repo
installs on every job — npm registry contents, Go module cache, Maven/Gradle
artifacts, base container layers — is a candidate for baking. This is the one
optimization that helps every repo without touching any repo's workflows.

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

---

## 7. Supply-chain tier

Zero of ~375 third-party action references are pinned to a commit SHA — all use
mutable tags (`@v4`, `@v7`). These actions run on self-hosted VMs that hold a
GCP identity. Pin by SHA and let Dependabot propose the bumps; this also removes
the surprise-breakage class of CI failure, which is itself wasted CI.

---

## 8. Governance tier — how this stays true

1. **Publish the lane model as a reusable workflow from this repository**,
   consumed by tag exactly as `modules/ci-runner-host-pool` already is. Repos
   get fixes without 14 hand-edits — the same argument this repo's README makes
   against vendoring the Terraform module.
2. **Add a drift gate** mirroring the existing `ci-runner-*` module drift check:
   fail if a consuming repo re-implements the classifier locally.
3. **Budget the always-on set.** A PR that adds a new unconditional required
   job should have to justify it, in the same shape as the existing
   `Resident instruction context within budget` gate.
4. **Measure per-lane runner-minutes.** `modules/ci-runner-host-pool/scripts/telemetry.sh`
   already reports from the hosts; emitting lane and repo turns the next round
   of this work into measurement instead of audit.
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
| 10 | Real warm cache in the golden image | 4.2 |
| 11 | Batch settings + scopes in every queue | 6 |
| 12 | Build-once/reuse, Docker layer cache, remote monorepo cache | 3.4, 4.3, 4.4 |
| 13 | SHA-pin actions | 7 |
| 14 | Fast/heavy runner classes and shared overflow capacity | 2.3, 2.4 |
