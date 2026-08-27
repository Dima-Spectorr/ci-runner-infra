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
| `dormant` | No CI at all | That it **still** has none — the day a workflow appears, it has become a `lane` repository whose merges nothing serves |
| `empty` | No default branch | That it still has none |
| `source` | This repository | Nothing pin-related: it calls its own workflows through the `-self` variants |

`dormant` is the row that earns the manifest. Its exemption is conditional on a
fact that can change without anyone deciding to change it.

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
actually uses.

## The split, and why the rule has a self-test

`scripts/ci/fleet-audit.sh` is the impure half: it talks to GitHub and holds no
rule. `scripts/ci/fleet-audit-decision.sh` is a pure function from facts to
findings and holds every judgement.

The split is not tidiness. `fleet-audit.yml` runs on a **schedule**, and a
schedule is dispatched from the default branch only — so the pull request that
changes the rule cannot exercise it, whatever CI says. The 61 cases in
`fleet-audit-decision.selftest.sh`, wired into `ci.yml`, are what stands in for
the run that cannot happen. Most of them assert that a specific broken state is
still **reported**, which is the opposite weighting to the reaper's self-test
and follows from the opposite consequence of being wrong.

## Operating it

Daily at 05:41 UTC, after the reaper, plus `workflow_dispatch`.

Two things the operator sets:

- **`MERGE_LANE_ENABLED`** must be `true`, and `MERGE_APP_ID` /
  `MERGE_APP_PRIVATE_KEY` must exist. Reading another repository needs the App
  token; the job is gated on the same variable the lane and the reaper use
  rather than a third one meaning the same thing.
- **`FLEET_AUDIT_ISSUE`** — the issue number the daily report is commented on.
  One long-lived issue, not a new one per run: a daily audit that files an issue
  a day trains people to close them unread, which is the same failure as not
  running it. Unset means the report lives only in the job log.

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
