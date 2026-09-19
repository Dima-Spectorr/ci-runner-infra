# The fleet audit

Whether every repository in the account is in the state the fleet intends —
asked once a day, from outside the repositories being asked about.

## Why this exists

This repository has about sixty CI gates. Every one of them checks **this
repository**. The four outages that cost the most were all on the other side of
that boundary:

| What broke | What it looked like |
|---|---|
| Eleven of thirteen pools pinned to an old module release | Applies green, MIGs stable, no host could ever upgrade itself |
| A merge lane configured but never armed | The job skipped — neither red nor green — and the repository merged nothing |
| A required check no workflow emits | GitHub said `blocked`, the lane logged `skip:missing-required`, nothing was red |
| Wedged queued runs filling the 50-run page | `ci_demand` read a clean zero and the pool sat at zero, healthy |

They share a shape, and it is not a bug in any one repository: **a repository in
the broken state looks exactly like a repository that is simply idle.** Nobody
outside it was looking. That is the whole argument for this.

## The manifest is the source of truth, not `gh repo list`

[`fleet/repos.tsv`](../fleet/repos.tsv) declares one row per repository:
`repo`, `tier`, `reason`.

Discovering the fleet instead of declaring it reproduces exactly the blindness
above. A new repository with no lane and no CI is indistinguishable from a
deliberate exemption, so a discovery-only audit has to treat it as fine — and
the repository nobody onboarded is precisely the one worth catching. So the
audit reports in **both** directions: a repository with no row
(`fail:not-in-manifest`), and a row with no repository
(`warn:in-manifest-but-not-visible`).

The `reason` column is not decoration. An exemption whose reason has gone stale
is the same defect as a missing gate, and the reason is what makes that
reviewable a year later.

### Tiers

| Tier | Meaning | Audited for |
|---|---|---|
| `pool` | Self-hosted runners in a GCP project, plus the full lane | Everything, including pool health and the queued-run page |
| `lane` | The merge lane and its guards on GitHub-hosted runners | Everything except pool health |
| `checks` | CI gates, deliberately no merge lane — changes land by direct push | That the checks are **still** there; a repository that lost them looks exactly like a quiet one |
| `dormant` | No CI at all | That it **still** has none — the day a workflow appears it has become a `lane` or `checks` repository, and nobody said so |
| `empty` | No default branch | That it still has none |
| `source` | This repository | Nothing pin-related — it calls its own workflows through the `-self` variants — but the **unreleased backlog**: how much merged work no consumer can reach yet, and how long the oldest of it has waited |

`dormant` and `checks` are the rows that earn the manifest. Each is exempt from
the lane for a reason, and each reason is a fact that can change without anyone
deciding to change it — a workflow appearing, or a workflow going away.

## Every unknown is a finding

The inverse of the branch reaper's rule, and for the inverse reason. **The
reaper destroys, so its unknowns keep. This one only reports, so an unknown
costs a line of output** — and buys the guarantee that "did not check" and
"found nothing" never render the same. An audit that quietly passes on a failed
API read is worse than no audit, because it is the same green a healthy fleet
produces.

So a pin that could not be read is `warn:lane-pin-unreadable`, not silence; a
ruleset that could not be compared is `warn:required-checks-uncomparable`, not a
pass; an unrecognised tier is `fail:unknown-tier`, not a default.

## `fail:` versus `warn:`

`fail:` is for state that **silently stops work** — a merge that can never
happen, a pool that can never upgrade. `warn:` is for state that degrades
something a human would still notice. The distinction is not severity in the
abstract; it is whether anything else in the system would ever tell you.

Only `fail:` turns the run red. A dry-run lane is a legitimate place to sit for
a while, and an audit that goes red for it is an audit people stop reading.


### An empty pool is only a failure once the boot grace has passed

These pools scale from zero, so between the first queued run and the first
registered host there is a window in which a healthy pool and a broken one look
identical: no runners, work waiting. Measured on this fleet that window is two
to four minutes.

So the pool rule does not fail on demand — it fails on demand **older than
`DEMAND_GRACE`** (15 minutes, deliberately generous; a pool that will not scale
stays that way for hours). Without it the audit reported `mot-claude` as having
no runners under demand while its MIG was already at `targetSize 2`, forty
seconds after somebody opened a pull request. A daily audit that reds on
whichever repository happens to have fresh work is one people stop reading, and
that is the failure mode this whole file was written against.

Demand whose age could not be read is `warn:demand-age-unknown`, not a pass.

## The unreleased backlog (the `source` tier)

Consumers pin `?ref=v5`, so a change merged to main reaches nobody until
`VERSION` moves and `publish-tag.yml` advances that tag behind it. The number
moves either in the change itself or in a later `chore(release)` pull request —
both happen — and nothing anywhere bounded how long the second case could take.
Of 120 released-surface merges measured on this repository, 119 were published
inside 53 hours; one sat for nine and a half days with every gate green, and was
only noticed because somebody went looking. **The delay was never the defect;
nobody noticing was.**

So once a day the audit compares the floating `v5` tag to the default branch,
counts the commits ahead of it that touch a released surface (`modules/`,
`scripts/`), and reports on the **oldest** one. `docs/`, `fleet/`, `.github/`
and `packer/` are exempt: the first three are read from the default branch, and
`packer/` is built by a push-to-branch Cloud Build trigger, so none of them wait
on a tag.

| Finding | What it means | What an operator does |
|---|---|---|
| `ok:compliant tier=source backlog=0` | The tag is at the tip, or everything ahead of it is exempt | Nothing |
| `ok:compliant tier=source backlog=N oldest=Hh max=Mh` | Work is waiting and the oldest is **under** the ceiling | Nothing — this is the normal state between releases, printed so a batch can be watched growing rather than met on the day it crosses |
| `fail:unreleased-backlog commits=N oldest=Hh max=Mh` | The oldest merged change has been unreachable for longer than the ceiling | Open a `chore(release)` pull request; it sweeps up everything waiting |
| `fail:release-tag-unreadable` | The ref consumers pin did not resolve, or resolved to something that is not a commit | Check `publish-tag.yml`'s last run and the `v5` ref. **This is a failure, never an empty backlog** — the audit cannot bound what it cannot measure |
| `warn:unreleased-backlog-unknown` | The tag resolved but the comparison did not | Usually a refused or truncated API read; re-run |
| `warn:unreleased-backlog-age-unknown commits=N` | Something *is* waiting, and its age could not be established | A commit read that failed, a clock in the future, an unparseable date, or more than `BACKLOG_SCAN_MAX` commits of backlog. The count is real; the age is not known, and is deliberately not guessed |

The last row is the one to read carefully. An age the walk could not establish
is **never** rendered as a young one, and a walk it could not finish is never
rendered as an empty backlog — because every one of those states produces the
same zero as a genuinely clean repository, which is the exact shape of the
omission this watchdog exists to catch. `backlog_facts()` has its own self-test,
`scripts/ci/fleet-audit-collector.selftest.sh`, for that reason and no other.

### `UNRELEASED_BACKLOG_MAX_HOURS`

The ceiling, in hours, as a repository variable. **Unset leaves the watchdog
armed** at the rule's own default of 72 hours — chosen from the measured
distribution above, comfortably past the 53-hour tail and comfortably under the
227-hour outlier. Unlike `MERGE_LANE_ENABLED`, an empty value is not an off
switch here; a watchdog that disarms itself when nobody configures it is a
watchdog that is off everywhere.

**`0` turns it off**, and says so — `ok:compliant tier=source
backlog-watchdog=off`, not silence. Off means off: the opt-out is checked
**before** the tag is resolved, so `0` also silences `fail:release-tag-unreadable`.
That is deliberate rather than an oversight. The tag is read only in order to
measure the backlog, so an operator who has switched the measurement off should
not keep receiving failures about its inputs — and the tag itself is still
watched by `publish-tag.yml`, which creates it, and by `release-tag.yml`, which
asserts it names `VERSION`. Neither of those is affected by this variable.

## Running it

```bash
bash scripts/ci/fleet-audit.sh
```

One repository, which is how you check a fix without spending the fleet's rate
limit:

```bash
bash scripts/ci/fleet-audit.sh IntegrateIT
```

Exit status is `0` when nothing failed, `1` on any `fail:` finding, `2` when the
audit could not run at all. `FLEET_OWNER`, `FLEET_MANIFEST`, `DEMAND_MAX_AGE`
and `QUEUED_PAGE` are all overridable; the defaults match what the controller
actually uses. So are `BACKLOG_MAX_HOURS`, `RELEASED_SURFACE`, `BACKLOG_SCAN_MAX`
and `FLOATING_TAG` — the last of these exists so the backlog code can be
exercised by hand against a tag known to be behind main:

```bash
FLOATING_TAG=v5.99.1 bash scripts/ci/fleet-audit.sh ci-runner-infra
```

On a healthy repository the derived tag sits at the tip, so without an override
every path past the first comparison is dead on the only repository it ever runs
against.

## The split, and why the rule has a self-test

`scripts/ci/fleet-audit.sh` is the impure half: it talks to GitHub and holds no
rule. `scripts/ci/fleet-audit-decision.sh` is a pure function from facts to
findings and holds every judgement.

The split is not tidiness. `fleet-audit.yml` runs on a **schedule**, and a
schedule is dispatched from the default branch only — so the pull request that
changes the rule cannot exercise it, whatever CI says. The cases in
`fleet-audit-decision.selftest.sh`, wired into `ci.yml`, are what stands in for
the run that cannot happen. Most of them assert that a specific broken state is
still **reported**, which is the opposite weighting to the reaper's self-test
and follows from the opposite consequence of being wrong.

**One function on the impure side is tested too**, and it is the exception that
explains the rule: `backlog_facts()` does not copy a value out of a response, it
*concludes* one from several — and it can conclude "nothing is waiting" for four
different reasons, three of which actually mean "I could not tell".
`fleet-audit-collector.selftest.sh` sources `fleet-audit.sh` with
`FLEET_AUDIT_LIB=1`, which stops the file before its run section, replaces `api`
with a fixture, and asserts the **exact** fact string each response must
produce. Three of those cases exist because the code once failed them in review,
and an assertion on exit status would have passed against all three.

## Operating it

Daily at 05:41 UTC, after the reaper, plus `workflow_dispatch`.

Three things the operator can set, two of them required:

- **`MERGE_LANE_ENABLED`** must be `true`, and `MERGE_APP_ID` /
  `MERGE_APP_PRIVATE_KEY` must exist. Reading another repository needs the App
  token; the job is gated on the same variable the lane and the reaper use
  rather than a third one meaning the same thing.
- **`FLEET_AUDIT_ISSUE`** — the issue number the daily report is commented on.
  One long-lived issue, not a new one per run: a daily audit that files an issue
  a day trains people to close them unread, which is the same failure as not
  running it. Unset means the report lives only in the job log.
- **`UNRELEASED_BACKLOG_MAX_HOURS`** — optional. Unset leaves the backlog
  watchdog armed at 72 hours; `0` turns it off. See the section above for why
  an empty value is not an off switch and why `0` also silences the
  unreadable-tag finding.

The token is minted **owner-wide** (`owner:` on `create-github-app-token`). The
default installation token is scoped to the repository the workflow runs in,
which is the one repository the audit does not need to read.

### The App needs `Variables: read`, `Secrets: read` and `Administration: read`

All three read-only, and the secrets one reads only the **names** — the Actions
secrets API never returns a value to anyone. Without the first two the audit
cannot tell you whether a lane is armed; without the third it cannot see a
single self-hosted runner, so the whole pool-health half of the report is
inert.

It matters more than it sounds, because of how those two endpoints refuse: a
token without the scope gets a `403` whose body is as empty as the answer for a
repository that genuinely has no variables. The first live run under the App
token, on 2026-08-27, reported **every repository in the fleet** as
`lane-not-enabled` — including the twelve where the lane merges pull requests
daily. The audit now captures the refusal as its own fact and reports
`warn:lane-arming-unreadable` / `warn:lane-secrets-unreadable` instead of
asserting the opposite of the truth, which is the failure this whole file
exists to catch and was, briefly, committing itself.

The runners endpoint sprang the same trap in the quieter direction: `.runners`
is `null` on a refusal body, `null | length` is `0`, and the corrected run
reported Apigee-Portal, IntegrateIT and Borsh-Tablet-App — 37 registered
runners between them — as having none under demand. It is type-checked now and
reports `warn:runner-count-unknown`. Two endpoints, two directions, one lesson:
**a count parsed out of an error body is not a count.**

A permission added to an App is a *request* until the installation owner
accepts it, and until then the App behaves exactly as though it had never been
added — so grant it on the App, then accept it on the installation, then
dispatch the audit and check the warnings are gone.

### The account listing has two scopes, and the report says which

`gh repo list` needs a user token. The scheduled run authenticates as the App,
whose installation token cannot enumerate an account — it can only list its own
installation, which equals the account only when the App is installed on all
repositories. When the audit falls back to that it prints
`warn:repo-list-scope-narrowed`, because a repository nobody onboarded is
exactly the one the App is least likely to be installed on. The difference
between "no unmanaged repositories exist" and "none that I could see" is the
whole point of the check.
