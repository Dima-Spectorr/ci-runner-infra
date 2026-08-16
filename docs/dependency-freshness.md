# Support windows — the published contract

This is the contract consuming repositories adopt to find out that a version
they depend on has stopped being supported. The rule itself is
`scripts/ci/support-window-decision.sh`, asserted by
`scripts/ci/support-window-decision.selftest.sh` in this repository's CI; the
scanner that feeds it is `scripts/ci/scan-support-windows.sh`, asserted by
`scripts/ci/scan-support-windows.selftest.sh`. It is delivered as a reusable
workflow, consumed by tag exactly as `modules/ci-runner-host-pool` is.

The tag in the snippet below is the **floating major**, `@v5`, which is what
this repository's guides publish and what its pin gate asserts — an exact
`@vX.Y.Z` in a document is stale on the next release. It costs nothing here:
the workflow resolves `github.job_workflow_sha` at run time, so a consumer
still runs the scanner at the exact commit the tag pointed at when the job
started, rather than whatever is on the default branch.

---

## What it is, and what already exists

Dependabot answers **"is a newer version available?"**. Nothing in the fleet
answered **"is the version we are on still supported?"**, and those turn out to
be different questions with different silences.

The measured state of the fleet on 2026-08-16, none of which had produced an
alert anywhere:

| in use | end of life | active support ended | what anything reported |
|---|---|---|---|
| Node 18 | 2025-04-30 — sixteen months past | 2023-10-18 | nothing |
| Node 20 | 2026-04-30 — four months past | 2024-10-22 | nothing |
| Node 22 | 2027-04-30 — eight months away | **2025-10-21 — ten months past** | nothing |
| Node 22, baked into the golden image | as above | as above | nothing |

The third row is the one worth the gate. Node 22 looks fine on any check that
reads an end-of-life date, because that date is eight months out. What is
actually true is that it left active support ten months ago — and new
applications were being started on it while Node 24 was on the shelf, supported
for another year. No version-behind check can see that (22 is not "behind"
anything it tracks) and no end-of-life check can either.

So this gate reads **two** dates, not one, and it treats a version a pull
request *chose* differently from one it *inherited*.

## The invariant

The two failure directions are not symmetric, and neither is the rule:

- A **false alarm** costs a line in an issue nobody had to act on.
- A **false clean** is a report that says the fleet is fine. It is
  indistinguishable from a healthy fleet, it is what the fleet already had, and
  it is what this gate exists to end.

The concrete shape of the false clean is one field. Upstream publishes
`eol: false` to mean *"no end-of-life date has been announced"* — **not** *"this
version has no end of life"*. Every React major ever released carries
`eol: false`, including the ones that have been dead for years. Read as a
boolean, that field marks every framework which publishes no dates as
permanently supported, and the scan reports clean forever while appearing to
work. `_eol_state` and `_support_state` are two functions rather than one for
exactly this reason, and collapsing them is the most likely way to reintroduce
it.

So: **anything doubtful is UNDECIDED, never supported.** An unreachable feed, an
unrecognised product, a release line upstream never shipped, a `today` that will
not parse — each is reported as a finding, and the report says at the top that
it is incomplete.

## The verdicts

Six, ordered by what a reader should do about them rather than by severity of
the word.

| code | means | why it sits here |
|---|---|---|
| `SUP1` | **Unsupported.** Past end of support; no security fixes are being published. | The row to act on. Outranks everything, including a new adoption — "you are already running it" is stronger than "do not adopt it". |
| `SUP3` | **Newly adopted with a shorter runway** than a line already available. | Second, because it is the only finding whose fix is free. On the day of the pull request it is one character; after release it is a migration. |
| `SUP2` | **Inside the migration window.** Supported, with an end date close enough to plan for. | A lead time, not a countdown — see below. |
| `SUP4` | **Undecided.** No lifetime data. | Not a pass. See the invariant. |
| `SUP5` | **Maintenance only.** Out of active support, end of life still ahead. | Informational, and last. This is what a deliberate postponement looks like, and a gate that nags about it is a gate that gets muted. |
| `SUP0` | Supported. | Produces no row at all. |

### The window is a lead time, not a countdown

The default is **180 days**. A team told at 150 days can plan a migration; a
team told at seven days can only panic, and a team told on the day support ended
is already late. The number is deliberately measured in months rather than in
the days a release-note reader would notice.

### `SUP3` is gated twice, on purpose

An unqualified "you are not on the newest" would fire on nearly every repository
in the fleet, permanently, and is precisely the noise this design exists to
avoid. `SUP3` fires only when **both** hold:

1. the newly declared line is already out of active support, or expiring inside
   the window; **and**
2. a line with a longer runway exists.

Adopting a fully-supported line that merely is not the newest stays silent. On
2026-08-16 a new service on Node 24 is silent even though Node 26 exists —
because 26 had not yet become LTS, and recommending it would be recommending
something no team should put in production yet.

**"Newly declared" requires the base commit to be reachable.** The reusable
workflow checks out with `fetch-depth: 0` for this reason; a shallow clone makes
every declaration look inherited and silently removes the finding the report
leads with.

### What "the best available line" means

Not the newest. The newest is routinely a line that has shipped but has not yet
become LTS. The rule is: among lines that have **already** become LTS and are
still in active support, the one with the furthest end of life. Products that
publish no LTS dates at all fall back to the same question without that clause.

## Where the findings go

Two destinations, because two of these findings have different half-lives.

- **The standing state → one issue, upserted.** Not a new issue per run: a
  scheduled scan that files a fresh issue every night teaches everyone to filter
  the label, and a filtered label is the same as no scan at all. The issue is
  **closed automatically** when nothing actionable remains — an issue that only
  ever grows is a backlog, and nobody reads a backlog to learn today's state.
  Informational `SUP5` rows appear in the body but do not hold it open.
- **`SUP3` → a comment on the pull request making the choice.** An issue filed
  for it would be read weeks after the decision hardened.

### Why it is not a required check

Every finding here has a date attached, and none of those dates are moved by the
pull request being checked. A repository green yesterday and red this morning
because Node reached a milestone overnight would be a repository whose merge
queue is blocked by the calendar. The scan therefore always exits 0; findings
are the report, never the exit status.

## Adopting it

```yaml
# .github/workflows/support-windows.yml
name: Support windows

on:
  schedule:
    - cron: '17 6 * * 1'   # weekly; these dates move on release calendars, not on commits
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  # `run_id` rather than a constant on the non-pull-request half: a scheduled
  # run must never be cancelled by the next one, because the step it would be
  # interrupted in is the one that upserts the issue.
  group: support-windows-${{ github.head_ref || github.run_id }}
  cancel-in-progress: true

jobs:
  scan:
    uses: <org>/ci-runner-infra/.github/workflows/support-windows.yml@v5
    permissions:
      contents: read
      issues: write
      pull-requests: write
```

Inputs, all optional: `window-days` (default 180), `issue-label` (default
`support-window`), `comment-on-pull-request` (default true), and
`scanner-repository`, which only needs setting when the consuming repository is
in a different organisation from `ci-runner-infra`.

**It does not run on the warm pool.** The job clones a repository and reads
text; `ci-optimization-catalog.md` §2.2 is explicit that a zero-dependency guard
must not claim a pool slot, and a scan that costs a slot on every repository in
the fleet is the kind of cost that gets the whole thing switched off.

## What it reads

Every place a version is *chosen*, which is why the list is short and why each
entry is worth a finding:

| source | what it yields |
|---|---|
| `.nvmrc`, `.node-version`, `.python-version` | the runtime a developer gets |
| `go.mod` `go` directive | the language version the module targets |
| `.github/workflows/**` `node-version:` / `python-version:` / `go-version:` | the toolchain CI actually builds with |
| `Dockerfile` `FROM image:tag` | a runtime declaration wearing a hat |
| `package.json` dependencies | frameworks with a published support lifetime |
| `packer/*.pkr.hcl` | **the golden image's baked baseline and host OS** |

That last row is the one with the widest blast radius and the least visibility:
no application manifest mentions it, no Dependabot ecosystem covers it, and it
is inherited by every host in the fleet until someone edits a Packer variable.

### The golden image, and a repository that wants a newer major

The baked Node is a **host baseline**, not a toolchain choice — it exists so
that marketplace actions installing a `#!/usr/bin/env node` shim do not die with
exit 127. A repository that wants a different major already gets one:
`actions/setup-node` prepends its own toolchain to `PATH`, and the per-slot tool
cache in `host-startup.sh` is left to the setup actions deliberately. So a
repository asking for Node 26 needs no image change.

What the image *does* owe the fleet is a baseline that is still supported, and
nothing was watching that. Now `support-windows-self.yml` does, weekly, and on
any pull request that touches `packer/`.

## What it deliberately does not do

**A library with no published support lifetime is not a finding.** Support
lifetimes exist for runtimes, base images and major frameworks — 464 products
upstream at the time of writing. They do not exist for the several thousand
transitive libraries in a lockfile, and no amount of scanning invents them.
Emitting an undecided row for each would bury the four rows that matter under
two thousand that do not, and that report is muted within a week. The report
says so explicitly rather than implying a completeness it does not have.

Known gaps, each a version this scan does not read rather than one it reads
wrongly:

- A workflow matrix (`node-version: [18, 20]`) yields no declaration.
- A floating base-image tag (`FROM node:latest`) yields no cycle.
- Products whose upstream identifier differs from the image or package name
  need a row in `product_for_image` / `product_for_package`. The fleet's next
  language arrives as a row in those tables, not as an edit to the logic.
