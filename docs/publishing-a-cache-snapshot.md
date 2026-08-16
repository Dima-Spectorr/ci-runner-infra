# Publishing a cache snapshot

A pool's hosts **read** a snapshot on boot and never write one. This is the other
half: the scheduled run that builds it.

Read `modules/ci-runner-cache-publisher/README.md` first for *who* may publish
and why it cannot be a host. This document is *what* to run.

## What you need already

- `ci-runner-cache-bucket` applied once in the project;
- the pool pointed at it (`cache_snapshot_bucket`);
- `ci-runner-cache-publisher` applied for this pool, and its
  `publish_workflow_path` naming the workflow file below. The binding pins the
  **file name** — a workflow at a different path gets a token GCP will not
  exchange.

## The workflow

Copy this into the path you gave `publish_workflow_path` (default
`.github/workflows/publish-cache-snapshot.yml`). It runs on a **GitHub-hosted**
runner, not on the fleet: the fleet's hosts are the consumers of what it
produces, and running it there would put the publishing credential on a machine
that executes pull-request code.

**It is two jobs, and that is not tidiness.** `CACHE_PREPARE` runs third-party
code — npm lifecycle scripts, sdist builds, Maven plugins — and a job that has
`id-token: write` exports `ACTIONS_ID_TOKEN_REQUEST_URL` and `_TOKEN` to every
process in it. One compromised transitive dependency in a job holding the
publishing credential mints its own token, publishes a snapshot of its choosing,
and every host in the pool unpacks it as root. So the job that installs holds
`contents: read` and nothing else; the job that publishes only downloads the
archive, re-scans it and uploads it. Do not merge them back.

```yaml
name: publish-cache-snapshot

on:
  schedule:
    - cron: '17 3 * * *'
  workflow_dispatch:

# Nothing at the top level. Each job takes exactly what it needs, and the split
# is void if `id-token: write` is granted here.
permissions: {}

concurrency:
  group: publish-cache-snapshot
  cancel-in-progress: false

# Do NOT add `workflow_call`. The identity binding pins this file's path, so a
# caller passing an input that reaches CACHE_PREPARE would satisfy both the
# binding and the script's event guard. This file takes no inputs.

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read           # and nothing else — this job runs the install
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0

      # The scripts live in the fleet repository. Pin the COMMIT, not the tag:
      # this repository's release process floats `v5` forward, and a tag that
      # moves changes the script that later runs beside the credential. Resolve
      # once with:
      #   git ls-remote https://github.com/Dima-Spectorr/ci-runner-infra refs/tags/v5.20.0^{}
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          repository: Dima-Spectorr/ci-runner-infra
          ref: <commit sha of v5.20.0>   # v5.20.0
          path: .ci-runner-infra

      - run: sudo apt-get update && sudo apt-get install -y libcap2-bin

      - name: Build the snapshot
        env:
          CACHE_PREPARE: npm ci --ignore-scripts
          CACHE_ARCHIVE_OUT: ${{ runner.temp }}/snap.tar.gz
        run: bash .ci-runner-infra/scripts/ci/publish-cache-snapshot.sh

      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: cache-snapshot
          path: ${{ runner.temp }}/snap.tar.gz
          retention-days: 1

  publish:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write          # the credential lives here, and no install does
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          repository: Dima-Spectorr/ci-runner-infra
          ref: <commit sha of v5.20.0>   # v5.20.0
          path: .ci-runner-infra

      - run: sudo apt-get update && sudo apt-get install -y libcap2-bin

      - uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0
        with:
          name: cache-snapshot
          path: ${{ runner.temp }}

      - uses: google-github-actions/auth@c200f3691d83b41bf9bbd8638997a462592937ed # v2.1.9
        with:
          workload_identity_provider: ${{ vars.CACHE_WIF_PROVIDER }}
          service_account: ${{ vars.CACHE_PUBLISHER_SA }}

      - uses: google-github-actions/setup-gcloud@e427ad8a34f8676edf47cf7d7925499adf3eb74f # v2.2.1

      - name: Publish the snapshot
        env:
          CACHE_POOL: ${{ vars.CACHE_POOL }}
          CACHE_BUCKET: ${{ vars.CACHE_BUCKET }}
          CACHE_ARCHIVE_IN: ${{ runner.temp }}/snap.tar.gz
        run: bash .ci-runner-infra/scripts/ci/publish-cache-snapshot.sh
```

`CACHE_PREPARE` is the only line most repositories change. It is whatever
installs this repository's dependencies, and it **must not run lifecycle
scripts** — `npm ci --ignore-scripts`, `mvn -B -o dependency:go-offline`,
`go mod download`, `pip download --no-build-isolation -r requirements.txt`, or
several joined with `&&`. Bare `npm ci` runs `postinstall` from every transitive
dependency and `pip download` builds sdists; the job split is what keeps that
from reaching the credential, but there is no reason to run it at all. It runs
with every cache variable pointed at an empty staging tree, so what it downloads
is what gets published.

**Do not put a registry token in `CACHE_PREPARE`.** Repository *variables* are
not masked in logs, and a credential that the install writes into the cache is a
credential published to every host in the pool. The script scans for both, and
that scan is a floor, not a guarantee.

## The five rules the script enforces so you do not have to

1. **Built from the default branch into an empty tree.** Never an archive of a
   host's live cache. A slot's cache holds whatever job last ran there, including
   a fork's pull request; a host's master holds only the image's content plus an
   earlier snapshot's. Archiving either re-admits untrusted output or compounds
   an earlier mistake.
2. **Scanned with the host's own rules before upload** — links, device nodes,
   setuid, file capabilities, credential files, and a content pass for embedded
   registry tokens and private keys. A snapshot that a host would refuse fails
   here instead: once, loudly, in a run someone is watching, rather than silently
   on every boot of every host.
3. **Scanned again in the publishing job, on what it received.** The archive
   crosses a job boundary, and the job that built it is the one that ran
   third-party code — so the job holding the credential unpacks it, with the
   host's own decompression bound, and re-runs every check before uploading a
   byte. It also refuses any archive member that is not a plain file or a
   directory.
4. **Write-once names.** `<UTC>-<digest>.tar.gz`, never reused. The bucket
   measures age per generation, so an object refreshed in place is a generation
   aged zero that never expires — the age bound configured and doing nothing. The
   IAM grant carries no `storage.objects.delete`, so a reused name fails.
5. **The pointer swaps last, with a generation precondition.** A host reading
   mid-publish gets the previous snapshot, which is stale at worst. Two
   publishers racing produce one winner and one loud failure.

The script also refuses to run at all from a `pull_request_target`,
`workflow_run` or `issue_comment` event. Those assert the **default branch**
while running fork-authored code, so the identity binding alone would still hand
out the credential — this is the check that turns such an edit into a failed run.

## First run

Run the build phase alone: `CACHE_PREPARE=… CACHE_DRY_RUN=1 bash
scripts/ci/publish-cache-snapshot.sh`. It installs, scans and packs, prints the
size, and uploads nothing — no credential is involved, so it runs on a laptop. The size is the number that matters: a snapshot past the pools'
`cache_snapshot_max_bytes` (4 GiB by default, compressed) is refused by every
host, which reads in their logs as *"no snapshot published"* rather than as an
error.

## Verifying it worked

```bash
gcloud storage cat gs://<bucket>/cache/<pool>/current
```

Then boot a host and read `/var/log/ci-runner-startup.log`: a successful hydrate
logs the snapshot name, how many tool caches it moved in, its size, its age, and
how much of the budget it spent. Every failure inside that budget is one line and
a cold first job — the layer fails open, so a broken publish costs cache hits and
never a host that does not come up.
