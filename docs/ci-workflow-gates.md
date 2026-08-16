# Workflow gates a consuming repository copies in

Five shell checks published from this repository, in the same shape and for
the same reason as `check-merge-queue-single-step.sh`: the rule is written once
where the fleet is defined, self-tested here, and copied into each consumer so
it runs in that consumer's own required check.

| Script | Asks |
|---|---|
| `scripts/ci/check-runner-policy.sh` | which pool a job may claim, and for how long |
| `scripts/ci/check-action-pins.sh` | is every third-party action an immutable commit |
| `scripts/ci/check-workflow-shell.sh` | does the shell INSIDE the YAML survive `bash -n` and shellcheck |
| `scripts/ci/check-e2e-policy.sh` | does the browser suite report honestly, and fast |
| `scripts/ci/check-generic-literals.sh` | does a customer, region or owner literal reach something copy-pasteable |

All five address every finding by exact path, and all five carry `--selftest`
fixtures that must run BEFORE the real check — a workflow gate that reads no
workflow reports clean, and that vacuous pass is worse than no gate because it
is believed.

Three of them — the runner-policy, action-pin and workflow-shell gates — parse
the workflow with PyYAML rather than grepping it, because each one asks a
question about the document's *structure*. The literals gate also reads
`.yml`/`.yaml`, and deliberately does not parse them: its question is whether a
value appears anywhere in a file somebody will copy, which is a question about
text, and a parse would drop the comments that are just as copy-pasteable.

The e2e gate cannot parse its input at all: it is `playwright.config.ts`, which is TypeScript,
and a shell gate is not going to evaluate it. It reads that file lexically and
says so — see its "what it cannot decide" section — and treats anything it
cannot read as a FAILURE rather than a pass, because the two error directions
are not symmetric. A false failure costs one commit making a value literal; a
false pass is a gate that quietly stopped gating.

---

## `check-runner-policy.sh`

```
bash scripts/ci/check-runner-policy.sh [--selftest] [--scope=<label>]
                                       [--forks=allowed|blocked]
                                       [--max-timeout=<minutes>]
                                       [--allow-dynamic-runner] [<file>...]
```

With no `<file>` arguments it reads every `.yml`/`.yaml` directly under
`.github/workflows/`, and fails if it finds none.

| id | Rule |
|---|---|
| `RUNNER0` | the file does not load, or the gate cannot run |
| `RUNNER1` | a fleet-reachable `runs-on` also names a repository-scoping label |
| `RUNNER2` | with `--scope=<label>`, it is THAT label |
| `RUNNER3` | every job that runs steps declares `timeout-minutes` (see the note below) |
| `RUNNER4` | a fork-reachable workflow keeps fleet-reachable jobs behind a fork guard |
| `RUNNER5` | the runner is selected dynamically — reported as UNDECIDED, not passed |
| `RUNNER6` | and the declared timeout is below the default it replaces |
| `RUNNER7` | a REMOTE reusable workflow's jobs are not in this repository — UNDECIDED, declarable per callee |
| `RUNNER8` | a job on a **Windows** pool label declares `container:` or `services:`, which that pool cannot run |

### `self-hosted` is a label, not a requirement

GitHub routes a job to any runner whose label set is a **superset** of what
`runs-on` names, so `runs-on: Atlas` and `runs-on: [linux, gcp]` both reach this
fleet without the marker appearing anywhere. An earlier revision gated
RUNNER1/2/4 on seeing that literal, which made dropping one redundant label the
cheapest way past all three at once.

So the question is inverted. A job is fleet-reachable unless **every** label it
names is a GitHub-hosted image (`ubuntu-*`, `windows-*`, `macos-*`), and a
dynamically selected runner counts as reachable for the fork question — "not
proven self-hosted" is not the same as "hosted", and spending it as such is an
error in the passing direction.

### RUNNER1 is the security check

Every pool on this fleet answers to `self-hosted, <os>, gcp` plus one
repository label, and that label is the whole of the boundary `README.md`
describes: one repository per pool, because a warm host reuses caches, checked
out trees, and whatever credential material the previous job left behind. So
`runs-on: [self-hosted, Linux, gcp]` is not a job with a short label list — it
is a job any pool in the fleet may pick up. IntegrateIT's
`runner-version-check.yml` was written that way and ran that way weekly
(measured 2026-08-15). Nothing reported it: from GitHub's side it is a job that
found a runner.

The gate needs no per-repo configuration to judge that, deliberately — a gate
every consumer must configure is a gate several consumers configure wrongly. A
label counts as a SCOPE label when it is not one of the platform labels every
pool carries:

```
self-hosted linux windows macos x64 arm64 arm gcp aws azure on-prem
```

matched case-insensitively, because GitHub treats runner labels that way and
`Linux` vs `linux` must not read as a scope. `--scope=<label>` adds the
stronger form for a consumer that wants it: not merely SOME scope, but its own.

### What RUNNER3 does and does not bound

`timeout-minutes` starts when the job starts. It does **not** bound the wait for
a runner — a self-hosted job that never finds one is cancelled by GitHub after
24 hours no matter what this key says. So RUNNER3 is about the job that starts
and hangs: on a warm host that is a slot held for six hours, and where the merge
queue's `checks_timeout` expires first the pull request is silently DEQUEUED
rather than turning red, which reads as a pull request that simply stopped
moving.

A job pointed at a label no runner carries is a different defect with a
different fix — the pool, or the `runs-on`. RUNNER1 and the onboarding doc's
label rule are what catch that.

### RUNNER8 is scoped to the label, not to the key

A Windows pool on this fleet has no container runtime at all; job isolation
there is one local Windows account per slot (`docs/adr-windows-pool.md` §4). So
`container:` and `services:` cannot run on it, and the way they fail is why this
is a gate rather than a lesson: a `services:` block fails at "Initialize
containers" before a single step runs, with an error about docker on a host that
has no docker, which every reader takes for a broken host — while the workflow
itself looks entirely ordinary, because on `windows-latest` and on the Linux
pool it is.

The rule therefore reads the **label**. `container:` on the Linux pool is how
that pool is meant to be used, and a hosted `windows-2022` image is not this
fleet and does run containers; only a fleet-reachable job naming the `windows`
platform label is refused, case-insensitively, and a matrix is judged per leg.
`scripts/ci/check-runner-policy.selftest.sh` mutates the gate seven ways and
asserts its fixture suite FAILS for each — a detector that has not been seen to
fire is not a detector.

### `--forks` is declared, not guessed

Fork code on a warm, credentialed, reused host is the attack the isolation
rules exist for. But a repository whose forking is off cannot be reached that
way at all, and a gate that fails such a repository on every pull request
teaches its readers to disable the gate. So the posture is declared once, in
the consuming workflow where it is reviewable. `--forks=allowed` is the default
and the strict reading; `--forks=blocked` is for a repository that has turned
forking off, and is a claim its author is making in a diff.

A guard counts by **direction, not mention**. The first version of this check
asked whether `head.repo.fork` appeared in the job's `if:` or `runs-on`, which
is a topic rather than a guard: `if: …head.repo.fork == true` names the fork and
routes fork-authored code *exclusively* onto the warm pool — the precise attack
RUNNER4 exists to stop, passing the check meant to stop it.

Recognised as excluding a fork:

```yaml
if: github.event.pull_request.head.repo.fork == false     # or != true, or !…fork
if: github.event.pull_request.head.repo.full_name == github.repository
runs-on: ${{ github.event.pull_request.head.repo.fork && 'ubuntu-latest' || vars.CI_RUNNER_LABEL }}
```

The `runs-on` form counts only because its **fork-true branch names a hosted
image**; written the other way round the same idiom hands forks the pool. And
"hosted image" is the finite GitHub family, not that prefix: `ubuntu-pool-1` is
an ordinary custom label on a fleet runner, and reading it as hosted both
skipped every isolation check on the job carrying it and made it a legal
destination for fork code.

"Finite" then has to mean the versions GitHub actually ships, because `latest`
or any number accepted `ubuntu-2204`, `windows-11` and `macos-14.0` — three
ordinary self-hosted naming conventions, none of them a hosted image. Each OS
carries its own version shape:

| OS | Accepted | Optional class suffix |
|---|---|---|
| `ubuntu-` | `latest`, an LTS `NN.04` | `-arm`, `-arm64`, `-large`, `-xlarge` |
| `windows-` | `latest`, a year `20NN`, `11-arm` | same |
| `macos-` | `latest`, a bare major `NN` | same |

The list goes stale in the safe direction on purpose: an image GitHub adds
later reads as self-hosted until the line is updated, which costs one reported
job. The other direction costs the boundary.

Anything not recognised is unguarded — an unrecognised-but-correct guard costs
one reported job and a reviewer's minute, where an unrecognised inversion costs
the boundary.

And the condition is read as a Boolean tree, not searched. `always() ||
…head.repo.fork == false` contains the exclusion and runs for forks anyway,
because the other alternative does not care. So for `||` **every** alternative
has to exclude, for `&&` **one** conjunct excluding is enough, and what is left
after that split is a leaf matched against the shapes above.

### Reachability crosses a local `uses:` call

A `pull_request` workflow calling `./.github/workflows/build.yml` runs that
callee's jobs in the caller's pull-request context. But the callee declares only
`workflow_call`, so read alone it looks fork-unreachable and its self-hosted
jobs are never asked for a guard — while the caller has no `runs-on` to judge.
Both files clean, fork code on a warm host. Reachability is therefore computed
across the whole file set before anything is judged, and transitively.

A **remote** callee is a different answer: that document is not in this
repository, so the RUNNER3 exemption a `uses:` job gets was handing the bound to
jobs nobody read. That is RUNNER7.

RUNNER7 refused every such call outright, and that was one step too far. Every
repository on this fleet calls the reusable workflows in **this** repository —
one copy, so a fix lands once instead of in nine drifting forks — and an
unconditional refusal made the only way past it the vendoring the
`No vendored CI runner module` job exists to prevent. Undecidable is not
forbidden, so it is declarable, in a comment beside the call:

```yaml
jobs:
  apply:
    # remote-reusable-allowed(Dima-Spectorr/ci-runner-infra/.github/workflows/apply-runner-pool.yml, #8160): the callee is reviewed in its own repository; it runs github-hosted with an explicit timeout
    uses: Dima-Spectorr/ci-runner-infra/.github/workflows/apply-runner-pool.yml@v5
```

The marker **names its callee**, so pointing the `uses:` at a different workflow
or a different owner re-arms the check; the ref is deliberately excluded, since
a pin bump does not change what this gate can read and whether the ref may float
at all is `check-action-pins.sh`'s question. The issue number is not decoration:
it is where the reading of the callee is recorded, so the acceptance has an
owner and a place to be revisited, and a marker without one — or without a
reason after the colon — is a waiver wearing a declaration's shape and does not
count. It must be a real comment; the same text inside a `run:` string is not a
declaration.

What it asserts is narrow, and worth stating plainly so nobody reads it as more:
a human read the callee and accepted its jobs' runner scope and timeouts. It
does not verify them — nothing in this repository's copy of the gate can, which
is the whole finding.

This is a marker rather than a CLI flag like RUNNER5's `--allow-dynamic-runner`
on purpose: a flag excuses every remote call in the repository at once, includes
one a later unrelated change adds, and lives in the CI invocation where the
reviewer of the call never sees it.

A guard on the **calling job** is a guard on everything that job reaches, so an
edge carries its caller and a guarded caller contributes none. Without that, the
callee was asked for a condition its own file has no pull-request context for,
and the only way to satisfy the gate was to duplicate the caller's `if:`. A
callee reached by **any** unguarded edge is still reachable — the guard has to
hold on every path, not on one of them.

Reachability is a set membership, so both sides of every edge are canonicalised
to one absolute spelling. They were not: the caller was keyed by whatever string
the invocation passed — `.github/workflows/ci.yml` in the documented
`<file>...` mode — while the `./…` call target was resolved to an absolute path.
The two never compared equal, so on the invocation the usage line documents the
whole computation produced nothing and every callee read as unreachable. The
fixture missed it by only ever passing absolute paths; there is now one that
passes relative ones.

### What it cannot decide

`runs-on: ${{ vars.CI_RUNNER_LABEL }}` and `runs-on: {group: warm}` resolve
against repository configuration this gate cannot see. Both are RUNNER5 —
reported as undecidable rather than passed, because an expression is the one
spelling that can quietly name any pool in the fleet.

A fork guard used to silence RUNNER5 too, on the reasoning that the fleet's
routing idiom *is* the decision RUNNER5 asks about. It is not: it decides where
fork code goes and says nothing about which pool the other branch names, so fork
isolation was standing in for pool scoping. The guard now settles RUNNER4 only,
and a consumer whose pool genuinely comes from a repository variable its admins
scope declares `--allow-dynamic-runner` in its own workflow — a claim in a diff,
the same shape as `--forks=blocked`.

### RUNNER6 — and the bound has to bind

`timeout-minutes: 360` satisfies RUNNER3 and preserves in full the failure
RUNNER3 exists to prevent: 360 **is** GitHub's default, so the job holds a warm
slot for six hours exactly as an undeclared one does. Key presence was the wrong
question. The ceiling is 360 by default and `--max-timeout=<n>` lowers it for a
consumer whose merge queue expires sooner — a job outliving `checks_timeout` is
dequeued silently rather than turning red.

`timeout-minutes: ${{ vars.JOB_TIMEOUT }}` is the same finding in a different
spelling: the key is present, the value may be 360, and this gate cannot read
the variable. Reported, not passed — the rule RUNNER5 already follows.

### What it decides that looks undecidable

`runs-on: ${{ fromJSON(matrix.<key>.<field>) }}` is an expression whose label
lists are **literals in the same file** — apigee-portal's `unit-tests.yml`
writes each leg's pool as `'["self-hosted", "linux", "gcp", "Apigee-Portal"]'`.
Nothing there is undecidable, and abstaining would be the gate declining to
read a boundary written down in front of it. So the legs are resolved.

Each leg is judged **separately**, as `<job>~leg<n>`. Unioning them would let a
scoped leg supply the label an unscoped leg sharing the job is missing — the
gate would then report clean on a leg the whole fleet can claim, which is the
exact failure it exists to catch.

Resolution is refused, back to RUNNER5, the moment it stops being a literal
lookup: an `include:`/`exclude:` that can add or override legs, a value that is
itself an expression, or anything that is not parseable JSON. Replicating
GitHub's matrix expansion here would be a second implementation of it, and a
wrong one reports on legs that do not exist while missing the ones that do.

### Why it parses

`runs-on: self-hosted` is a string where `runs-on: [self-hosted]` is a list;
`timeout-minutes` appears at both job and STEP level and only the job one bounds
the slot; a `uses:` job accepts no timeout at all. Each of those reads as
satisfied to a line reader — every mistake in the direction that reports clean.

---

## `check-action-pins.sh`

```
bash scripts/ci/check-action-pins.sh [--selftest] [--allow=<owner>]...
                                    [--allow-dynamic-image] [<file>...]
```

| id | Rule |
|---|---|
| `PIN0` | the file does not load, or the gate cannot run |
| `PIN1` | a remote `uses:` names a 40-character commit SHA |
| `PIN2` | and carries the version beside it as a comment, on every line |
| `PIN3` | a container image is pinned by `@sha256:` digest — a `docker://` step, a job `container:`, or a `services.*.image` |
| `PIN4` | an image chosen by expression is reported, not passed |

`@v4` is a tag, and a tag is a pointer its owner may move at any time. The
audit in `ci-optimization-catalog.md` §7 measured zero of ~375 third-party
references pinned across fourteen repositories — and on this fleet those actions
execute on warm VMs holding a service identity, beside other jobs' caches and
trees. One moved tag on one popular action is arbitrary code on every pool,
with no pull request in any consumer to review it. The duller reason pays every
week: a moved tag is also the surprise-breakage class of CI failure, a green
pipeline going red with no change in the repository. Pinning converts that into
a Dependabot pull request.

PIN2 is not decoration. `actions/checkout@11bd719…` tells a reviewer nothing
about what it is or whether it is current, so a SHA-only pin buys immutability
by giving up reviewability, and the usual next step is that nobody upgrades it
for two years. `@<sha> # v4.2.2` is exactly what Dependabot writes and rewrites
on every bump, so requiring it costs nothing. It is asserted against the RAW
LINE, because a comment is not part of the loaded document.

An abbreviated SHA is rejected: it looks pinned and is not — GitHub resolves it
against whatever the repository holds at resolution time, which is the
mutability the gate removes.

PIN2 compares two counts — raw lines naming the reference, raw lines carrying a
version comment — and **zero of the first is a finding, not agreement**. A
folded or quoted scalar spells the same value in a way a line-oriented match
does not see, and `0 > 0` reported a check that could not run as a check that
passed. That is the vacuous pass this whole design is arranged against, found in
its own strictest rule.

A gate that reads only `uses:` reads only the references arriving by that key,
and the two most privileged references in a workflow arrive by another. A job
`container:` **is** the job — every step runs inside that image with the job's
token mounted — and a `services.*.image` sits on the job's network for the job's
whole life. Both are read, and both answer to PIN3, so `postgres:16` as a
service is the same finding as `docker://postgres:16` as a step.

An image chosen by an expression is neither: this gate has no repository
variables, so calling `container: ${{ vars.CI_BUILDER_IMAGE }}` pinned and
calling it unpinned are both answers to a question that was never asked. PIN4
reports it as undecided — the same rule RUNNER5 follows for a dynamic
`runs-on` — and `--allow-dynamic-image` is the consumer's declaration that the
value comes from an admin-scoped variable, visible in the consuming workflow
rather than defaulted here.

A `uses:` beginning `./` is this repository's own tree at this repository's own
commit, already immutable, and is exempt — but only the **wrapper** is. That
manifest's own `uses: third/party@main` runs inside the calling job, on the
calling job's runner, with the calling job's token, so the exemption is paid for
by opening the file. Discovery walks `.github/actions/**`; a local action may
live anywhere, so `./tools/custom-action` was exempt here and unreachable there
— invisible to both halves at once. Each `./…` reference is now resolved and
read where it is USED, and a cycle of mutually-calling wrappers terminates on a
seen-set rather than recursing.

`--allow=<owner>` exempts an owner a consumer has decided to trust by tag; it
exists so adoption is never all-or-nothing, and each use is a visible argument
in the consuming workflow rather than a silent default here.

---

## `check-workflow-shell.sh`

```
bash scripts/ci/check-workflow-shell.sh [--selftest] [--root=<dir>]
                                        [--exclude=SC****]... [<file>...]
```

With no `<file>` arguments it reads every `.yml`/`.yaml` under
`.github/workflows/` **and** every `action.yml`/`action.yaml` under
`.github/actions/`, and fails if it finds none.

| id | Rule |
|---|---|
| `WFS0` | the gate could not read a document, could not find shellcheck, or extracted nothing |
| `WFS1` | every `run:` block parses under `bash -n` |
| `WFS2` | shellcheck has nothing to say about it |

A `run:` block is shell that happens to live in a `.yml`. The `shell` job here
shellchecks every `*.sh` in the tree and read none of them — and the pull
request that added `.github/actions/playwright-ui/action.yml` had real
shellcheck findings in its `.sh` files sitting beside unread `run:` blocks. The
tool catches what this project cares about; a whole class of shell was simply
out of its reach.

That class is the one with the widest blast radius, which is why it is a gate
rather than a habit: this repository publishes actions that run in CONSUMERS'
repositories, on their warm hosts, holding their job identity. A quoting bug
there surfaces in a pull request whose owner did not write the line.

### Line fidelity is what makes a finding actionable

Each block is written to a temporary file padded with blank lines so that line
*N* of the temp file is line *N* of the YAML, shellcheck runs `-f gcc`, and the
path is rewritten back to the real file. A folded or plain scalar cannot be
mapped character-for-character, so those get an explicit note instead of a
confident wrong line — the gate says what it does not know rather than guessing.

`${{ … }}` expressions are replaced character-for-character before checking, so
line and column survive while the shell parser stops choking on a template.

### The exemptions, each asserted by a fixture

A non-bash `shell:`; a Windows `runs-on` without an explicit `shell: bash`
(this fleet runs Windows pools, where the default is PowerShell); and the
default exclusions `SC1090,SC1091,SC2154,SC2148`, extendable with `--exclude=`.

SC2154 in particular is not laziness. Inside a `run:` block an unassigned
variable is the normal case — `$GITHUB_OUTPUT`, `$GITHUB_ENV`, every job-level
`env:` — and leaving it on buries every real finding under noise, which is the
failure mode where a gate is technically green and actually unread.

### Missing shellcheck is `WFS0`, never a pass

`--allow-missing-shellcheck` exists only so a developer's local self-test can
declare the gap out loud; CI never passes it. A gate that reports clean because
its tool was absent is the exact vacuous pass this file opens with.

### Why not actionlint

actionlint does this natively and validates the workflow schema too, and it is
the right answer for a repository that only needs to check itself. This one
publishes its gates: fourteen repositories adopt them **by tag**, as shell they
source, next to `lane-decision.sh` and `check-action-pins.sh` — which already
parse workflow YAML for exactly this reason. A Go binary downloaded per
consumer is a second supply chain to pin, in a fleet where an unpinned
third-party artefact is the thing `check-action-pins.sh` exists to forbid. The
schema half of actionlint remains worth having and is not this gate.

---

## `check-e2e-policy.sh`

```
bash scripts/ci/check-e2e-policy.sh [--selftest] [--root=<dir>]
                                    [--job-timeout=<minutes>]
                                    [--image-codename=<noble>]
                                    [<playwright.config file>...]
```

With no file arguments it finds every `playwright.config.*` within three levels
of `--root` (default `.`), skipping `node_modules`.

### Why this one is a gate and not a README

Every other check in this repository catches something that eventually turns a
run red. This one catches things that never do. That is the entire argument for
it:

| Mis-configuration | What CI reports | What actually happened |
|---|---|---|
| `test.only` committed | green, and fast | the suite ran one test |
| no `globalTimeout` | *nothing* | the hung job outlived the queue's `checks_timeout` and the pull request was **dequeued**, not failed |
| `trace: 'on'` | green | every passing test was recorded; the suite takes roughly twice as long for evidence nobody opens |
| `container:` tag ≠ `@playwright/test` | green | the job downloaded ~2 GB of image the host already held baked, and ran one release's browsers under another release's client |
| `reuseExistingServer: true` on CI | green | the suite tested a server the previous job left running |
| unbounded `workers` | green | one repository's suite took the whole host and *other* repositories timed out |

The dequeue row is not hypothetical for this fleet: it is the same failure the
per-workspace < job `timeout-minutes` < `checks_timeout` ordering already exists
to prevent, arriving through a config file no existing gate reads.

### The checks

| id | Asks | Why it is not tidiness |
|---|---|---|
| E2E0 | a suite or an E2E job exists, but no config governs it | the vacuous pass, named — "no config" is only legitimate when there is also no suite |
| E2E1 | `forbidOnly` is set and not `false` | a committed `test.only` otherwise passes the suite by shrinking it |
| E2E2 | `workers` is an explicit **literal** | the default is the host's core count, and a host runs several agent slots; a value that does not resolve *is* the default, behind a line that looks considered |
| E2E3 | `expect` < test < `globalTimeout` < job `timeout-minutes` | each rung that is not below the next never binds; the top one missing is the silent dequeue |
| E2E4 | trace/video/screenshot are failure-conditional | `'on'` records passing tests, which is pure runtime |
| E2E5 | the reporter is machine-readable, and `blob` when sharding | an html-only report cannot be read by a gate or merged across shards, so a sharded run has N partial verdicts and no single one |
| E2E6 | `reuseExistingServer` is off under CI | a warm host is the point of this fleet and exactly why a reused server is a stale one |
| E2E7 | the job runs in `mcr.microsoft.com/playwright:v<x>-noble` — that codename, `--image-codename=` to override — and does not `playwright install` inside it | ~2 GB per job that every host on the pool already holds as a baked archive; `-jammy` runs and passes, it just downloads first |
| E2E8 | that container's release equals the pinned `@playwright/test` | the one that decides whether any of the speed work survives a dependency bump |
| E2E9 | no `waitForTimeout` / `sleep` in specs | the single largest source of both flake and wasted runtime |

E2E7 and E2E8 only look at workflows that actually invoke the suite — a
`playwright test` or an `e2e` script. Matching the *words* caught the workflow
running this gate, whose own step is named "e2e policy", and then demanded that
gate job run in a browser container.

E2E3 only compares against the job when `--job-timeout=<minutes>` is passed: the
job's ceiling is not knowable from the config alone, and inventing a default
would make the check agree with itself.

### Where it sits next to `check-playwright-pin.sh`

The two are halves of one pin, and neither can do the other's job.
`check-playwright-pin.sh` runs **here** and holds every
`mcr.microsoft.com/playwright:` reference this repository publishes — the
warm-cache bake, the composite action, the docs — to one release. It says
outright that it cannot check the consumer's `container:` line, because that
line lives in the consumer's repository next to the `@playwright/test` it must
match.

E2E7 and E2E8 are that half, and they run **there**. Between them: the fleet
tells one story about which image it bakes, and each repository is held to
running the image it actually declares a dependency on. Drift on either side is
a green check and a slow one — the fleet bakes an archive nobody loads, or the
job downloads two gigabytes that were already on the disk under it.

[`ui-testing-on-the-fleet.md`](ui-testing-on-the-fleet.md) is the consumer-facing
guide to the container, the pool label and the `--shm-size` it needs.

---

## `check-generic-literals.sh`

```
bash scripts/ci/check-generic-literals.sh [--selftest] [--self=<owner/repo>]
                                          [--root=<dir>] [<file>...]
```

With no `<file>` arguments it reads every tracked `*.tf`, `*.tfvars`, `*.hcl`,
`*.sh`, `*.yml`, `*.yaml`, `*.md` and `*.mdx`, and fails if it finds none.

| id | Rule |
|---|---|
| `LIT0` | the gate found nothing to read, was handed a file it cannot read, or its reader exited non-zero or warned |
| `LIT1` | no customer/region/owner literal in an executable tree (`.tf`, `.tfvars`, `.hcl`, `.sh`, `.yml`, `.yaml`) |
| `LIT2` | no such literal inside a Markdown fenced code block |

This replaces an inline `grep` in `ci.yml` that covered `*.tf`, `*.sh` and
`*.hcl` and stopped. Documentation and workflow YAML — the two file classes it
never read — are where a region or an org name gets written down without anyone
treating it as code. `docs/onboarding-a-repository.md` exists to be pasted into
fourteen other repositories, so a literal reaching it propagates *by design*,
and a region literal in a workflow `env:` decides what CI actually does.

### Prose is exempt, a code fence is not

This is the whole design, and a naive widening gets it backwards.

A literal in **prose** is evidence. An incident id names an incident; naming
the peered landing zone tells a reader inside it what they are looking at.
Failing those makes the gate an obstacle to writing down why a rule exists —
and a gate that punishes the incident record is a gate whose incident records
stop being written.

A literal inside a ``` fence is a **thing somebody will paste**. That is the
direction damage travels, and the distinction is mechanically decidable, which
is the only reason it can be a gate at all.

Measured before the rule was written: a naive widening produced eleven findings
on this tree — every fenced one was this module's own address, every prose one
was incident evidence.

### The owner is derived, not written down

The predecessor hardcoded the GitHub owner **in its own pattern, in a public
repository**. This one takes the slug from `GITHUB_REPOSITORY`, falling back to
`git remote get-url origin` and overridable with `--self=`, and strips it from
a line before matching. So this module's own address disappears — the
quickstart needs it to be copy-pasteable — while any other repository under the
same owner keeps that owner and fails. The rule self-adjusts in a fork or a
consumer, and the literal is gone from the source.

The self-exclusion list is exactly one path, this script, and the self-test
asserts that it is exactly one: a denylist that skips a list of files is not a
denylist.

### A placeholder is not a literal

The first real finding of the widening was a false one. `cloudbuild.yaml`
documents its own invocation with `gs://<bucket-in-an-allowed-location>/source`
— a placeholder written down precisely so nobody hardcodes theirs, which is the
opposite of the defect. The banned thing is a bucket somebody owns, so the
pattern asks for a bucket-name character after the scheme; `gs://$VAR` and
`gs://<…>` are a caller's value by construction. A fixture holds that open.

The `<org>` / `<Repo>` / `<40-char-commit-sha>` placeholders the docs use need
no allowlist at all — none of them can match a pattern made of concrete values,
so the placeholder shape stays legible for free.

---

## Adopting them

1. Copy the scripts into the consumer's `scripts/ci/` — the three workflow
   gates always, and `check-e2e-policy.sh` if the repository has (or is about to
   have) a browser suite.
2. Wire the steps into the job behind the aggregate required check, **fixtures
   first**:

```yaml
      - name: runner policy self-test
        run: bash scripts/ci/check-runner-policy.sh --selftest
      - name: runner policy
        run: bash scripts/ci/check-runner-policy.sh --scope=<Repo> --forks=blocked
      - name: action pins self-test
        run: bash scripts/ci/check-action-pins.sh --selftest
      - name: action pins
        run: bash scripts/ci/check-action-pins.sh
      - name: workflow shell self-test
        run: bash scripts/ci/check-workflow-shell.sh --selftest
      - name: workflow shell
        run: bash scripts/ci/check-workflow-shell.sh
      - name: e2e policy self-test
        run: bash scripts/ci/check-e2e-policy.sh --selftest
      - name: e2e policy
        run: bash scripts/ci/check-e2e-policy.sh --job-timeout=25
```

   `check-generic-literals.sh` is deliberately not on that list. Its pattern
   encodes THIS module's customer, region and owner shapes, so a consumer that
   legitimately *is* one customer would fail it on every line and learn
   nothing. It is adopted only by a repository that is itself meant to be
   portable.

3. Put them on `ubuntu-latest`, not on the pool — they are near-zero-dependency
   guards (catalog §2.2), and a gate about pool safety should not need the pool
   to be healthy in order to run. `ubuntu-latest` also ships shellcheck and
   PyYAML preinstalled, which is what keeps `check-workflow-shell.sh` from
   spending its first step installing the tool it fails closed without.
4. Add Dependabot for the `github-actions` ecosystem in the same pull request,
   so PIN1 does not turn pinning into permanent staleness:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: "/"
    schedule: { interval: weekly }
```

### Fleet state at adoption time (measured 2026-08-15)

The runner-policy and action-pin gates ran in report mode over the ten
locally-cloned consumers, against
each repository's **default branch** (`origin/main`, or `origin/master` for
DataRetrival and Soap-to-Rest) rather than whatever the local working copy
held. That distinction is not pedantry: an earlier revision of this table was
measured against working copies carrying feature branches and uncommitted
edits, and it reported findings for repositories that did not have them —
apigee-portal in particular, credited with 20 × RUNNER3 against a default
branch that already bounds every job.

| Repo | files | runner policy | action pins |
|---|---|---|---|
| Atlas | 7 | clean | 26 × PIN1 |
| Borsh-Tablet-App | 2 | 7 × RUNNER5 | 17 × PIN1 |
| DataRetrival | 9 | clean | 39 × PIN1 |
| IntegrateIT | 11 | 1 × RUNNER1, 3 × RUNNER3 | 41 × PIN1 |
| Print-Server | 14 | 18 × RUNNER3 | 41 × PIN1 |
| Soap-to-Rest | 15 | clean | 52 × PIN1 |
| Specaria-Platform | 12 | clean | 55 × PIN1 |
| Telnet-Emulation | 5 | 13 × RUNNER3 | 28 × PIN1 |
| apigee-portal | 15 | clean | 93 × PIN1 |
| entity-platform | 3 | 16 × RUNNER3, 7 × RUNNER5 | 31 × PIN1 |

Three readings matter.

PIN1 is universal — **423 unpinned references and not one repository clean**,
which is why this is a published gate rather than ten hand-edits.

RUNNER1 is rare: exactly one job in the fleet is self-hosted without a scope
label. That is the point. The finding a gate exists for is the one nobody would
have found by reading, and a check that fires everywhere is measuring a
convention rather than a hazard.

RUNNER5 is not a finding about the gate, it is a finding about the repository.
Borsh-Tablet-App's seven and entity-platform's seven are jobs whose pool is
chosen by repository configuration: each reads `${{ vars.CI_RUNNER_LABEL }}`
behind a fork guard and falls back to `'ubuntu-latest'` when the variable is
unset, so the routing is correct — but correct-by-configuration is exactly what
a gate reading the file cannot confirm.

entity-platform's four extra appeared when the fork guard stopped silencing
RUNNER5 (see above) — they were always dynamic, the guard was answering for
them. Neither repository is expected to stay red: a consumer that has decided its variable is
admin-scoped says so with `--allow-dynamic-runner`, which is a line in a diff
someone approves rather than a gate quietly agreeing with itself.

Run in report mode before enforcing:

```bash
bash scripts/ci/check-runner-policy.sh --forks=blocked .github/workflows/*.yml
```
