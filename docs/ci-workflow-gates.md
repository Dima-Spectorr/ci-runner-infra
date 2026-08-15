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
                                       [--forks=allowed|blocked] [<file>...]
```

With no `<file>` arguments it reads every `.yml`/`.yaml` directly under
`.github/workflows/`, and fails if it finds none.

| id | Rule |
|---|---|
| `RUNNER0` | the file does not load, or the gate cannot run |
| `RUNNER1` | a `runs-on` naming `self-hosted` also names a repository-scoping label |
| `RUNNER2` | with `--scope=<label>`, it is THAT label |
| `RUNNER3` | every job that runs steps declares `timeout-minutes` |
| `RUNNER4` | a fork-reachable workflow keeps self-hosted jobs behind a fork guard |
| `RUNNER5` | the runner is selected dynamically — reported as UNDECIDED, not passed |

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

### `--forks` is declared, not guessed

Fork code on a warm, credentialed, reused host is the attack the isolation
rules exist for. But a repository whose forking is off cannot be reached that
way at all, and a gate that fails such a repository on every pull request
teaches its readers to disable the gate. So the posture is declared once, in
the consuming workflow where it is reviewable. `--forks=allowed` is the default
and the strict reading; `--forks=blocked` is for a repository that has turned
forking off, and is a claim its author is making in a diff.

A guard counts when `head.repo.fork` or `head_repository` decides the job —
in `if:` (which skips it) or in `runs-on` (which re-routes it):

```yaml
runs-on: ${{ github.event.pull_request.head.repo.fork && 'ubuntu-latest' || vars.CI_RUNNER_LABEL }}
```

That idiom is an expression, and it is clean rather than RUNNER5: the
expression IS the routing decision RUNNER5 exists to ask about. An **unguarded**
expression is still reported.

### What it cannot decide

`runs-on: ${{ vars.CI_RUNNER_LABEL }}` and `runs-on: {group: warm}` resolve
against repository configuration this gate cannot see. Both are RUNNER5 —
reported as undecidable rather than passed, because an expression is the one
spelling that can quietly name any pool in the fleet.

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
| `PIN2` | and carries the version beside it as a comment |
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

A `uses:` beginning `./` is this repository's own tree at this repository's own
commit, already immutable, and is exempt. `--allow=<owner>` exempts an owner a
consumer has decided to trust by tag; it exists so adoption is never
all-or-nothing, and each use is a visible argument in the consuming workflow
rather than a silent default here.

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

Both gates run in report mode over the ten locally-cloned consumers:

| Repo | runner policy | action pins |
|---|---|---|
| Atlas | clean | 24 × PIN1 |
| Borsh-Tablet-App | 6 × RUNNER5 | 15 × PIN1 |
| DataRetrival | 9 × RUNNER3 | 25 × PIN1 |
| IntegrateIT | 1 × RUNNER1, 3 × RUNNER3 | 41 × PIN1 |
| Print-Server | 22 × RUNNER3 | 36 × PIN1 |
| Soap-to-Rest | 19 × RUNNER3 | 40 × PIN1 |
| Specaria-Platform | 1 × RUNNER3 | 49 × PIN1 |
| Telnet-Emulation | 13 × RUNNER3 | 25 × PIN1 |
| apigee-portal | 20 × RUNNER3 | 58 × PIN1 |
| entity-platform | 16 × RUNNER3, 3 × RUNNER5 | 31 × PIN1 |

Two readings matter. PIN1 is universal — 344 unpinned references and not one
repository clean, which is why this is a published gate rather than fourteen
hand-edits. RUNNER1 is rare: exactly one job in the fleet is self-hosted
without a scope label, which is the point — the finding a gate exists for is
the one nobody would have found by reading.

Run in report mode before enforcing:

```bash
bash scripts/ci/check-runner-policy.sh --forks=blocked .github/workflows/*.yml
```
