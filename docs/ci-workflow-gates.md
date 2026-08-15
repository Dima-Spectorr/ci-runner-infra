# Workflow gates a consuming repository copies in

Two shell checks published from this repository, in the same shape and for the
same reason as `check-merge-queue-single-step.sh`: the rule is written once
where the fleet is defined, self-tested here, and copied into each consumer so
it runs in that consumer's own required check.

| Script | Asks |
|---|---|
| `scripts/ci/check-runner-policy.sh` | which pool a job may claim, and for how long |
| `scripts/ci/check-action-pins.sh` | is every third-party action an immutable commit |

Both parse the workflow with PyYAML rather than grepping it, both address every
finding by exact path, and both carry `--selftest` fixtures that must run
BEFORE the real check — a workflow gate that reads no workflow reports clean,
and that vacuous pass is worse than no gate because it is believed.

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
| `RUNNER7` | a REMOTE reusable workflow's jobs are not in this repository |

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
"hosted image" is the finite GitHub family — `ubuntu|windows|macos` plus
`latest` or a version, with an optional `-arm`/`-large` class suffix — not that
prefix: `ubuntu-pool-1` is an ordinary custom label on a fleet runner, and
reading it as hosted both skipped every isolation check on the job carrying it
and made it a legal destination for fork code.
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
bash scripts/ci/check-action-pins.sh [--selftest] [--allow=<owner>]... [<file>...]
```

| id | Rule |
|---|---|
| `PIN0` | the file does not load, or the gate cannot run |
| `PIN1` | a remote `uses:` names a 40-character commit SHA |
| `PIN2` | and carries the version beside it as a comment, on every line |
| `PIN3` | a `docker://` step image is pinned by `@sha256:` digest |

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

## Adopting them

1. Copy both scripts into the consumer's `scripts/ci/`.
2. Wire four steps into the job behind the aggregate required check, **fixtures
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
```

3. Put them on `ubuntu-latest`, not on the pool — they are zero-dependency
   guards (catalog §2.2), and a gate about pool safety should not need the pool
   to be healthy in order to run.
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

Both gates run in report mode over the ten locally-cloned consumers, against
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
