# Running Playwright UI tests on the fleet

Browser tests run in the **official Playwright container**, on a pool whose
image has that container **baked in** so the job does not download it.

Two things have to line up, and one gate holds them together:

| | decided by | where |
|---|---|---|
| which image the pool **bakes** | `warm_cache_script` | this repo, `packer/warm-cache/playwright.sh` |
| which image a job **runs** | the job's `container:` | the consuming repository's workflow |
| which Playwright the **suite** installs | `@playwright/test` | the consuming repository's `package.json` |

All three name one release. Playwright looks for an exact browser revision and
reports `Executable doesn't exist` when they disagree — so the composite action
below checks the suite against the container and fails with that sentence
instead of a per-spec launch error.

## Why the browsers are not on the host

The host image carries no browser, and deliberately. Baking browsers onto the
host would pin **every repository on the fleet** to one Playwright release, and
repositories upgrade on their own schedule. The container moves that pin into
the repository that owns it.

What the host bakes instead is the container itself, as a file.

## Why baking is a file and not a pull

Each slot runs its own rootless Docker daemon with its own data root under the
slot user's home. An image pulled at build time lands in the build VM's
root-owned `/var/lib/docker` and is invisible to every one of them — the
`warm_cache_script` contract says exactly this.

So `packer/warm-cache/playwright.sh` pulls the image and `docker save`s it,
gzipped, into `/opt/ci-cache/images/`. That directory is the one tree slots
share. At boot, `load_baked_images()` in `host-startup.sh` loads every archive
it finds there into each slot's daemon.

That load is **backgrounded and never fatal**. It takes minutes, and blocking a
pool's registration on a cache would turn a slow disk into a fleet that will not
take jobs. A failed load costs a download, not a job.

`load_baked_images()` names no tool: it loads whatever archives it finds. A pool
that bakes nothing has an empty directory and pays nothing.

## Putting a pool on browser tests

This is **opt-in per pool**, not a fleet default — a browser image is the
largest thing baked into any image here, and it helps only the repositories that
run UI tests.

In the pool's Packer build:

```hcl
warm_cache_script = "warm-cache/playwright.sh"
```

Then rebuild the image and move the pool to the new `image_version`. Budget
roughly 2 GB of image for the archive, and a few gigabytes per slot once each
slot has loaded it.

## Putting a repository's suite on the fleet

In the consuming repository:

```yaml
jobs:
  ui:
    # A fork must not reach this pool. The warm host is credentialed, reused
    # between jobs, and — for UI tests specifically — carries a browser image
    # cache shared by every slot on it. RUNNER4.
    #
    # The guard is an `if:` and not the expression `runs-on` form, even though
    # RUNNER4 accepts both: an expression `runs-on` is what RUNNER5 refuses to
    # read, so the other spelling satisfies one gate by tripping another.
    if: github.event.pull_request.head.repo.fork == false

    # The repository-scoped label is not optional — every pool answers to
    # `self-hosted, linux, gcp`, so a job naming only those can be picked up by
    # another repository's warm host. RUNNER1.
    runs-on: [self-hosted, linux, gcp, <RepoLabel>]
    timeout-minutes: 30
    container:
      image: mcr.microsoft.com/playwright:v1.62.1-noble
      # Not tuning. Chromium's default 64MB /dev/shm inside a container is not
      # enough for a real page, and the crash it produces looks like a flaky
      # suite rather than a misconfigured container.
      options: --shm-size=1gb
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
      - uses: <org>/ci-runner-infra/.github/actions/playwright-ui@v5.8.0
        with:
          playwright-version: "1.62.1"
```

### `--shm-size`, not `--ipc=host`

Playwright's own documentation suggests `--ipc=host`, and on a laptop or a
single-purpose CI box it is the right answer. It is the wrong answer here.

A fleet host runs K slots for K different jobs. `--ipc=host` puts the container
in the host's IPC namespace, so every slot's containers share one namespace and
one `/dev/shm` — which is exactly where Chromium keeps rendered page buffers.
That means one job's page content is reachable from another job's container, and
any one job can exhaust `/dev/shm` for every other slot on the host.

`--shm-size=1gb` solves the same crash — a 64MB `/dev/shm` is the actual cause —
with a private filesystem and no shared namespace.

### Traces are recordings, and artifacts are readable

A Playwright trace is a complete recording of the run: DOM snapshots,
screenshots, and every network request **including headers and bodies**. Nothing
in Playwright redacts them, and `::add-mask::` does not apply to file contents
inside an artifact. If the suite authenticates, the `Authorization` and `Cookie`
headers are in the trace; if a response carried personal data, so is that.

An uploaded artifact is downloadable by anyone with read access to the
repository — everyone, if the repository is public. Before turning this on
against an environment holding real data:

- scrub credentials in a fixture (`page.route`, stripping `authorization` and
  `cookie`), and use synthetic test data rather than real records;
- keep the retention short — this action defaults to 1 day;
- or set `upload-artifacts: false` and reproduce failures locally instead.

The fork guard makes this job **skip** on a fork pull request, so it must not be
a required check by name. A skipped required check never reports, and the pull
request sits in the queue until it is dequeued rather than turning red. Put it
behind the aggregate check described in [ci-lane-model.md](ci-lane-model.md),
which is the piece that reports a verdict for the lane whether or not every job
in it ran.

### Why a composite action and not a reusable workflow

A reusable workflow would have to take `runs-on` as an input, because this
repository cannot name another repository's pool. An expression `runs-on` is
precisely what `check-runner-policy.sh` refuses to read (RUNNER5), and RUNNER7
records that a **remote** reusable workflow's jobs are not visible in the
calling repository either.

The pool boundary and the job timeout would then be checked by nobody: not here,
where the labels are unknown, and not there, where the job does not appear.
Shipping the steps instead of the job keeps `runs-on`, `timeout-minutes` and
`container:` in the consumer's own workflow, in a diff, where that repository's
own gate reads them as literals.

## Upgrading the pinned release

1. Bump `PLAYWRIGHT_VERSION` in `packer/warm-cache/playwright.sh`.
2. Update the examples in this file and in the action, so
   `check-playwright-pin.sh` passes — it fails the build when any
   `mcr.microsoft.com/playwright:v…` reference in the repo disagrees with the
   baked pin.
3. Rebuild the image, move the pool, then bump `@playwright/test` and the
   `container:` tag in each consuming repository.

Steps 2 and 3 are separate on purpose: a consumer that upgrades before the pool
does still passes, it just downloads its container until the pool catches up.

## What the pin gate does not check

It cannot know the pin is *correct* — only that the repository tells one story
about it. A wrong-but-consistent version fails at image build, where
`docker pull` rejects the tag, which is the cheap place to find out.
