# ADR: one always-on utility host per shared root

Status: accepted (owner, 2026-10-30) · Tracking: #1635 · Blocked by: #249

## Context

Measured 2026-10-28..30 across the fleet: GitHub-hosted minutes are still spent, and
almost none of it is real build work. It is thousands of 1–2 minute gatekeeper jobs
(lane, review-to-issue, drift, policy) that run on `ubuntu-latest` **on purpose**:
putting them on a scale-to-zero pool label would wake an n2-standard-16 host for a
30-second script (see "the merge lane never wakes a pool").

| Repo / workflow | Runs | Hosted min |
|---|---|---|
| IntegrateIT `pr-check.yml` lane job | 734 | ~1,468 |
| entity-platform `review-findings-to-issues.yml` | 861 | 861 |
| IntegrateIT `merge-lane-events` / `merge-lane-review-relay` | 937 | 937 |
| IntegrateIT `ci-module-drift` | 176 | 176 |
| MOT-GCP-Billing, Borsh, General-IT, Manar, Atlas lane / reaper / policy jobs | — | ~100 |

Every hosted job bills at least one minute, so it is the count of jobs that matters,
not how long they run.

## Decision

1. **Scope: the MOT shared root (`mot-ci-runners`) only.** Specaria repos
   (SOAP-To-REST, Specaria-Platform, Apigee-Portal, CloudObservability) stay hosted. The
   owner judged that a second machine was close to break-even.
2. **New module `modules/ci-runner-utility-host`**: a zonal MIG with `target_size = 1`,
   no autoscaler, and no controller involvement. Standard GCE (never Spot), with
   `e2-standard-2` as the default. The boot disk is ≥ 200 GB because the host image is
   200 GB. It reuses the pool's `host-startup.sh` and `telemetry.sh`. It has no job
   service account and no cache bucket.
3. **One host, many repos.** `repos = map(object({ slots = number, labels = optional(list(string), []) }))`.
   Each slot is bound to one repo and registers a JIT runner with
   `[self-hosted, linux, gcp, <Repo>-util]`. App tokens are minted per slot and scoped
   to that one repository.
4. **The controller is unchanged.** `-util` labels never match a `-shared` pool, and the
   utility base name fails `pool_owns_host`. A root-guard rule keeps the two base names
   distinct.
5. **What moves:** short gatekeeper jobs only, by editing their `runs-on` to the literal
   `-util` label. Check names do not change.
6. **What stays hosted:**
   - `ci-module-drift`, by design (IntegrateIT#7705): it must run when the fleet is
     broken.
   - `merge-lane-events` and `merge-lane-review-relay`: they carry the merge App key
     with contents-write.
   - Anything triggered by `pull_request_target`, or that runs fork code. That
     includes IntegrateIT's `review-findings-to-issues`.
   - `branch-reaper-self`, because it receives `MERGE_APP_PRIVATE_KEY`.

## Required changes

- **PR A, `host-startup.sh`:**
  - Per-slot `SLOT_REPO` and `SLOT_LABELS` from the new metadata keys `ci-slot-repos`,
    `ci-slot-labels` and `ci-utility=true`.
  - `gh_token`, `mint_jit` and `delete_runner` take the repo as a parameter.
  - A binding file, `/var/lib/ci-slot-binding/<idx>`, wipes a slot whose repo changed.
  - A new `ci-cache-seed=off` knob.
  - A pool host, where the keys are absent, must behave exactly as today.
- **PR B:** the module itself, its docs and its tftests.
- **PR C:** `check-runner-policy.sh` RUNNER2 accepts the `-util` scope label.
- **Root PR:** `mot-ci-runners` adds `module "utility_host"` after a release.
- **Consumer PRs:** one repo at a time, IntegrateIT last.

## Security

Cross-repo co-tenancy is new: today one host serves one repo. The security review on
2026-10-30 found four blocking items. All are fixed in PR A and gated on
`ci-utility=true`.

- **B1, `/proc`:**
  - The pool sets `hidepid=0`, and reusable workflows put repo tokens in `curl` argv.
  - On the utility host: `hidepid=2`, `ProtectProc=invisible`, and `container:` /
    `services:` jobs are refused.
  - The token-in-argv cleanup itself is #1640.
- **B2, #249:** `FORWARD -s 10.99.0.0/16 -d 10.99.0.0/16 -j DROP` sits above the
  per-slot accepts.
- **B3, shared port band:** the utility host has none, because the cross-slot band
  accept would bypass B2.
- **B4, rebind leftovers:** a slot moving to another repo wipes its home, `_work`,
  Docker data root, cache slot and old JIT registration.

Also required:

- **Every opted-in repo has fork PR workflows disabled.** As of 2026-10-30 this holds
  for all 7 candidate repos. A gatekeeper job runs trusted code from the default
  branch, or from same-repo PRs only.
- **Jobs given the merge App key stay hosted.** This includes `branch-reaper-self`.

Hardening backlog: #1637 (`/dev/shm`), #1638 (no turbo cache bucket), #1639 (pin-hold).

Unchanged guarantees:

- Slot uids cannot reach the metadata server.
- The App private key is readable only by root.
- Tokens are per-repo.

## Cost

| Item | Per month |
|---|---|
| e2-standard-2, always on, plus the 200 GB pd-balanced disk | ~$50–60 |
| Hosted minutes moved off GitHub (≈70% of MOT-side minutes) | saves roughly $150–200 |

## Consequences

- A gatekeeper job can queue behind a busy slot at peak times. Size the slots per repo
  from measured concurrency.
- One host is a single point of failure for gatekeepers. That is acceptable because the
  bootstrap-critical gates (drift, the events relay) stay hosted. A dead host is
  replaced by the MIG's autohealing.
