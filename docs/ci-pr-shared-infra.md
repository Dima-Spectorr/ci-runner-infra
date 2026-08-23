# One host per workflow run, one infrastructure stack on it — published contract

This is the contract consuming repositories adopt. The decision behind it, with
the measurements and the rejected alternatives, is
[`adr-pr-host-affinity.md`](adr-pr-host-affinity.md). The enforcement is
`RUNNER9`/`RUNNER10`/`RUNNER11` in `scripts/ci/check-runner-policy.sh`
([`ci-workflow-gates.md`](ci-workflow-gates.md)).

**Copy the file, not the snippets.**
[`examples/pr-shared-infra.yml`](examples/pr-shared-infra.yml) is the whole
contract as one workflow — anchor/owner, a Linux consumer, a Windows consumer
and a declared exemption. The fragments below are quoted from it to explain one
decision at a time; the file is the one that is *checked*.
`scripts/ci/check-shared-infra-example.sh` runs on every pull request to this
repository and asserts both that the gate reports it clean and that three
mutations of it are each reported — so an example that has drifted away from
the rules fails here rather than in the repository that copied it. A snippet in
prose has no such guard, and this document has already shipped an owner marker
in a spelling the gate does not read.

Adopt it **after** [`ci-lane-model.md`](ci-lane-model.md). The lane rule decides
how much CI a diff deserves; this decides where that CI runs. A repository that
pins jobs to a host before it has an aggregate required check has pinned the
wrong set of jobs.

---

## The three rules

1. **One pull request's self-hosted work runs on one host.** A pull request that
   also needs the Windows pool uses two: one Linux host, one Windows host.
2. **Infrastructure — database, broker, cache — is brought up once per pull
   request**, by one job, and shared by every test and every container in it.
3. **A Windows job reaches that stack over the VPC**, at the Linux host's
   address. There is no container runtime on a Windows host and this contract
   does not add one.

### The unit is a workflow run, and that is a precondition, not a detail

`needs:` and job outputs do not cross workflow runs. Two workflows triggered by
the same `pull_request` event cannot read each other's anchor, so they cannot
agree on a host without a lease store — and a lease store is the thing this
design exists to avoid ([`adr-pr-host-affinity.md`](adr-pr-host-affinity.md)
§2.2).

So the enforceable unit is **one workflow run**. "One host per pull request" is
true exactly when a repository's `pull_request` CI is one workflow, which the
lane model already pushes it toward. **Consolidate first.** A repository that
adopts this with three parallel `pull_request` workflows gets three hosts and
three stacks, and the contract will have made nothing better.

---

## 1. The anchor job

There is no API call and no lease. The first fleet job runs **unpinned**, and
whichever host it lands on becomes this workflow run's host. It reports that
host from its own environment, and every later job pins to it.

```yaml
  anchor:
    name: Host anchor
    needs: lane
    if: needs.lane.outputs.lane != 'none'
    runs-on: [self-hosted, linux, gcp, '<Repo>']   # deliberately unpinned
    timeout-minutes: 10
    outputs:
      # A JSON ARRAY, consumed with fromJSON — see "Why an array" below.
      runs-on: ${{ steps.anchor.outputs.runs-on }}
      host: ${{ steps.anchor.outputs.host }}
    steps:
      - id: anchor
        run: |
          set -euo pipefail
          # Set by the host at boot, alongside CI_SHARED_INFRA_*. Absent means
          # the host predates this contract — degrade, do not fail.
          if [ -z "${CI_HOST_LABEL:-}" ]; then
            echo 'runs-on=["self-hosted","linux","gcp","<Repo>"]' >> "$GITHUB_OUTPUT"
            echo "host=" >> "$GITHUB_OUTPUT"
            echo "::notice::host predates the affinity contract — running unpinned"
            exit 0
          fi
          # Hold the host against drain and recycle. `ci-pin-hold` is on PATH
          # in every slot. The TTL is a deadline measured from NOW, not from the
          # end of the run, so it must cover the whole run -- see "Sizing the
          # TTL" below. A lapsed hold degrades to today's behaviour.
          #
          # READ THE ANSWER. The helper is an admission decision, not a request:
          # it exits 0 either way and says `pinned=0` when another run already
          # holds this host. Publishing the label anyway pins every consumer to
          # a host somebody else owns, which is the contention this whole
          # mechanism exists to prevent.
          if [ "$(ci-pin-hold --run "$GITHUB_RUN_ID" --ttl "$CI_PIN_TTL" \
                    | sed -n 's/^pinned=//p')" != 1 ]; then
            echo 'runs-on=["self-hosted","linux","gcp","<Repo>"]' >> "$GITHUB_OUTPUT"
            echo "host=" >> "$GITHUB_OUTPUT"
            echo "::notice::another run holds this host — running unpinned"
            exit 0
          fi

          printf 'runs-on=["self-hosted","linux","gcp","<Repo>","%s"]\n' \
            "$CI_HOST_LABEL" >> "$GITHUB_OUTPUT"
          printf 'host=%s\n' "$CI_HOST_LABEL" >> "$GITHUB_OUTPUT"
```

**Why an anchor and not a runner-list lookup.** Reading the runner list is
repository administration, and `administration` is not a job-level `permissions:`
key — `GITHUB_TOKEN` cannot be granted it at all. A design that depended on it
was not adoptable, only plausible. The anchor needs no token and no permission.
It also answers a question the API cannot: the host it names is demonstrably
**alive and busy right now**, because a job of yours is running on it.

**Why this closes the drain window.** The pin hold (§6) is written by the anchor
job itself, on the host, before any pinned job exists. A design that discovers
the host out-of-band leaves a gap between picking a host and running anything on
it, and a host can drain inside that gap.

**Why an array.** Appending an empty label to a literal list yields
`[self-hosted, linux, gcp, <Repo>, ""]`, and an empty label matches no runner —
turning a degraded run into a queue-until-cancelled hang. The anchor emits the
whole array so "unpinned" is a shorter array, not a blank element.

**Make the anchor do real work.** The anchor occupies a slot, so a repository
with shared infrastructure should make its **infra owner job the anchor** (§3)
rather than paying for a job that only echoes a variable.

**If the host disappears, your run is cancelled — deliberately.** A pin names
one machine, and a machine that is replaced comes back under a new name, so a
job pinned to a host that no longer exists is not slow, it is unservable:
nothing will ever carry that label again. Left alone it holds its concurrency
group until GitHub times it out a day later. The controller instead fails the
run within minutes of the host going away, with the reason in its log. **Re-run
it** — the next anchor picks a live host, and there is nothing to clean up.

This should be rare, because hosts are drained rather than yanked and the pin
hold blocks the drain for the length of your run. A run of these means hosts are
disappearing under live work — a recycle policy that is too aggressive, or
preemption — and the series `ci_pinned_runs_cancelled` is where that shows up.

## 2. Consuming the anchor

```yaml
  test:
    needs: [lane, anchor]
    if: needs.lane.outputs.lane != 'none'
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
```

Every fleet-reachable Linux job in a `pull_request` workflow does this, except
the anchor itself. `RUNNER9` checks it.

This is dynamic runner selection, which `RUNNER5` reports as UNDECIDED, so the
gate is run with `--allow-dynamic-runner` once this contract is adopted.
`RUNNER9` supplies the specificity that flag gives up: not merely an expression,
but one naming the anchor job's output.

### Do not put the fork guard in the anchor's `if:`

`if: github.event.pull_request.head.repo.fork == false` on the anchor looks
equivalent to routing and is not. A job that `needs:` a **skipped** job is
itself skipped, so guarding the anchor skips every consumer with it, and a fork
pull request gets no CI at all — the routing expression on `test` is never even
evaluated, because `test` never starts. Nothing goes red: a skipped required
check is not a failed one.

So the anchor **routes** rather than skipping, exactly as its consumers do, and
publishes a hosted array on a fork so the whole run degrades together:

```yaml
    runs-on: ${{ github.event.pull_request.head.repo.fork && 'ubuntu-latest' || fromJSON('["self-hosted","linux","gcp","<Repo>"]') }}
```

That still keeps fork code off a credentialed warm host, which is all `RUNNER4`
asks. A fork run then has no pin and no shared stack, so the anchor publishes
`addr` and `pg` **empty** — a blank value a consumer can test, rather than the
literal `null` a missing output produces — and a suite that needs the stack
either brings up its own throwaway service on that leg or does not run on
forks.

An `if:` guard is still right for a job **nothing needs**, such as the Windows
leg: there is no hosted substitute for what it tests, so skipping it is the
answer. A repository whose lane model makes that check required has to let a
skip satisfy it.

## 3. The infrastructure owner job

Exactly one job in the workflow brings the stack up, and it is the anchor.
`RUNNER10` fails a second owner.

**The owner job exits as soon as the stack is up, and it must.** A job's
outputs do not reach `needs.<job>.outputs.*` until the job *completes*, so an
owner that lingers is an owner whose consumers can never start. The slot it
leaves behind is reserved host-side instead — see "Why the slot is held
host-side" below.

```yaml
  anchor:
    name: Shared infra (anchor)
    needs: lane
    if: needs.lane.outputs.lane != 'none'
    # shared-infra-owner(anchor): brings up the compose stack in a run step
    #   ^ the marker RUNNER10 counts. The spelling is load-bearing and it names
    #     the job: a marker that named nothing would excuse whatever the file
    #     happened to contain, including a job added later.
    runs-on: [self-hosted, linux, gcp, '<Repo>']
    # The bring-up, and nothing else. This job has to END for its outputs to
    # reach the jobs that need them.
    timeout-minutes: 15
    outputs:
      runs-on: ${{ steps.up.outputs.runs-on }}
      addr: ${{ steps.up.outputs.addr }}
      pg: ${{ steps.up.outputs.pg }}
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
      - id: up
        run: |
          set -euo pipefail
          # The band is the slot's, set by the host at boot. A port outside it
          # resolves on this slot's own loopback and NOWHERE else — which fails
          # later, in the Windows job, as "connection refused" with nothing
          # nearby to read. So assert it here, where the message can be useful.
          : "${CI_SHARED_INFRA_ADDR:?host is too old for this contract — needs the port-band boot}"
          pg=$(( CI_SHARED_INFRA_PORT_MIN + 0 ))
          [ "$pg" -le "$CI_SHARED_INFRA_PORT_MAX" ] || { echo "band exhausted"; exit 1; }

          # Project name per pull request: two stacks for one pull request (two
          # workflows, or a re-run) are then two complete stacks rather than one
          # half-initialised shared one.
          export COMPOSE_PROJECT_NAME="pr-${{ github.event.pull_request.number }}"
          PG_PORT="$pg" docker compose -f ci/compose.yaml up -d --wait

          # Migrate and seed ONCE. This is the line the whole contract exists
          # for: it used to run in every job that needed a database.
          ./scripts/db-migrate.sh "postgres://ci@127.0.0.1:${pg}/app"

          # Pin the host AND reserve this slot for the rest of the run. The
          # slot part is what keeps the stack alive after this job ends; see
          # below for why the job cannot do that by staying alive itself.
          #
          # A refusal here is fatal for THIS job and not for the run: the stack
          # is already up on a slot nothing is protecting, so the honest thing
          # is to fail rather than publish an address that the next job to land
          # on this slot will wipe out from under its consumers.
          if [ "$(ci-pin-hold --run "$GITHUB_RUN_ID" --ttl "$CI_PIN_TTL" \
                    --reserve-slot | sed -n 's/^pinned=//p')" != 1 ]; then
            echo "::error::could not reserve this slot — another run holds this host"
            exit 1
          fi

          printf 'runs-on=["self-hosted","linux","gcp","<Repo>","%s"]\n' \
            "$CI_HOST_LABEL" >> "$GITHUB_OUTPUT"
          echo "addr=${CI_SHARED_INFRA_ADDR}" >> "$GITHUB_OUTPUT"
          echo "pg=${pg}"                     >> "$GITHUB_OUTPUT"
```

### Why the slot is held host-side

There is a real problem here, and one tempting fix for it that does not work.

**The problem.** A slot is released the instant its job ends, and the next job
to land on it runs as the **same uid against the same rootless daemon** — free
to list, `exec` into, mutate or stop a stack that other jobs are still using.
The slot's between-jobs reset would destroy it outright, on purpose. Host
affinity does not help: it pins a *host*, and this is a *slot* problem.

**The fix that does not work.** The owner cannot reserve the slot by simply not
finishing. A job's outputs are published to `needs.<job>.outputs.*` only when
the job **completes**, and a dependent job does not start until everything in
its `needs:` list has completed. An owner that stays running to guard the stack
is an owner whose consumers are still queued, waiting for the endpoints it is
holding — while it waits for them. Every adopting workflow would deadlock on its
first run.

**What actually happens.** The reservation is not a job at all, and it is not
one mechanism either — it is a fast half and an exclusive half, because neither
alone is buildable.

`ci-pin-hold --reserve-slot` records that this slot belongs to this run. The
record is written by a root helper into a root-owned directory that jobs can
read and none can write, reached through a sudoers allowlist of exactly three
command lines (`--run *`, `renew --run *`, `status`) — and the helper takes no slot
argument at all: it derives the index from `SUDO_UID`, the way `slot-reset.sh`
already does, so a slot cannot name a neighbour's. What PR-authored code can ask
for is bounded rather than trusted: the run id is shape-checked, the TTL is
clamped to a ceiling the host owns, and no verb shortens or removes a hold —
expiry is the only end.

Two things then read that record. **`slot-reset.sh`**, which already runs as
root before and after every job, keeps wiping the workspace, home and
credentials exactly as it does today but leaves this slot's containers standing.
**The sweeper**, a 30-second host timer, stops the slot's agent so nothing
further is scheduled onto that uid or that daemon.

The stop is neither the hook's nor the controller's, for two different reasons.
The hook executes inside `ci-runner@<idx>.service`, so a hook that stopped its
own unit would have systemd SIGTERM the agent that is still reporting the job's
result — the reservation would work and the job would be lost. The controller's
only per-host shell runs after it has already decided to remove a host: a
healthy, current-template, busy host is never probed, and that is every host a
live hold is on. So the timer does it. Between the owner's exit and the next
sweep a job can still land on the slot; it gets a clean workspace and the stack
survives, which is why the reset half has to exist rather than being an
optimisation.

The release is host-side too, by the sweeper described below. The cost is
unchanged: one of `slots_per_host` is unavailable for the length of the run.

**A reboot ends your run rather than resuming it.** Rootless containers do not
survive the guest, and the slot's boot-time reset restores the agent before
anything could stop it. The hold records the boot it was written under, so a
stale one is released rather than honoured, and the run is failed promptly
instead of waiting for a stack that no longer exists. Re-run it; the next anchor
picks a live host.

**Teardown belongs to the host, not to a workflow.** A consuming job is a
different uid and cannot open a mode-0700 `/run/ci-s<i>`; an `if: always()`
teardown step there fails silently, which is worse than none. When the hold is
released — the controller sees the run finished, or the TTL lapses — the host
tears the stack down as the slot's own user, runs the reset the hook skipped,
and starts the agent again.

### What replaces `services:`

`services:` is per-job by construction: the agent creates the containers at
"Initialize containers" and destroys them when the job ends. There is no variant
of it that is shared. A repository adopting this contract declares its
infrastructure in `ci/compose.yaml` and brings it up in the owner job.

`services:` on a **Windows** pool label was already refused by `RUNNER8`, and for
a harder reason: the pool has no container runtime at all.

## 4. Consuming the stack

**From another Linux slot on the same host** — the sibling slot has its own
network namespace, so `127.0.0.1` is the wrong address there:

```yaml
  integration:
    needs: [anchor]
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    env:
      DATABASE_URL: postgres://ci@${{ needs.anchor.outputs.addr }}:${{ needs.anchor.outputs.pg }}/app
    steps:
      # Nothing to renew here: the host renews the hold before this job's first
      # step runs. See "Sizing the TTL".
      - run: ./gradlew integrationTest
```

### Sizing the TTL

**Nothing you can write shortens a hold, including your own release.** The
controller remembers the greatest expiry it has ever seen for a host and judges
against that, so the value in front of it can only ever push the deadline
further out. That is not tidiness: guest attributes are writable by every
process on the VM, so without it the cheapest attack on this design would be to
publish a valid-but-expired hold over a neighbour's live one and have the
controller delete the host, and the shared stack on it, for you. The practical
consequence for a normal run is small and worth knowing: after your teardown the
host may stay up until the hold would have lapsed anyway. Size the TTL for the
gap between your jobs, not for the length of the run.

Two bounds sit on top of that. The controller **clamps** any hold to the same
ceiling the host helper clamps `--ttl` to, so a hold written ten years out buys
nothing; and a **malformed** hold keeps the host rather than freeing it, because
a broken publisher must not read as consent to delete.

**The hold expires on wall-clock time from when it was written, and the release
path tears the stack down when it lapses.** A run that outlives its hold loses
its database mid-test -- the failure this contract exists to prevent, arriving
through the door the contract opened. Two rules keep that from happening, and
both are needed:

**The host renews the hold when a pinned job starts.** Re-writing a hold for
the same run id moves the expiry forward, so the TTL only ever has to cover *one
job plus the gap before the next*, not the whole run.

Renewal is **not** a step the workflow writes. It was, in an earlier draft, and
that draft was wrong twice over. A job with a `container:` — the normal shape
for a consumer of a containerised stack, and the shape this contract's own
examples encourage — runs its steps *inside* the container, where the
host-installed `ci-pin-hold` does not exist: the renewal step would fail
`command not found`, or, written defensively, would silently succeed while
renewing nothing, and the stack would then be torn down under a run that had
done everything asked of it. And there is no gate that could catch either: a
step's *presence* is checkable, but the phase-5 gates read workflow YAML, and
whether `ci-pin-hold` resolves inside an arbitrary image is not a property of
the YAML.

So renewal belongs where the binary is: `ACTIONS_RUNNER_HOOK_JOB_STARTED`, on
the host, outside any container, before the job's first step. The hook already
runs on every job on these hosts. It renews when the job carries a `host-*`
label naming this host and a hold for that run exists; otherwise it does
nothing. It renews with **the TTL the anchor recorded in the hold**, not with
`CI_PIN_TTL`: a hook runs outside the job's step environment and cannot rely on
seeing a workflow-level `env:`, and a hold that renewed itself with a defaulted
duration would silently stop honouring the number the workflow chose. That
makes renewal automatic for every pinned consumer, including the containerised
ones, unforgettable rather than merely documented, and removes the gate that
could not have worked.

Renewal never fails a job. A hold that cannot extend expires, and the sweeper
puts the slot back — the better of the two outcomes, and the reason the hook
swallows the helper's exit status.

**The TTL must still exceed the longest single hop.** Renewal does not help
across a hop nothing renews: a Windows consumer runs on a *different* host and
cannot renew the Linux host's hold at all. So set the TTL from one number the
workflow already owns -- the largest `timeout-minutes` among the jobs that may
run between two renewals -- plus queueing headroom, and declare it once:

```yaml
env:
  CI_PIN_TTL: 90m    # >= the longest job between renewals, plus queue time
```

A run whose long tail is entirely Windows renews nothing on the Linux host, and
its TTL must cover that whole tail. If that number is uncomfortably large, the
fix is a renewal hop -- a trivial pinned job between the Windows stages -- not a
bigger ceiling: the ceiling is also how long an abandoned hold pins a host.

**From the Windows host** — identical, which is the point:

```yaml
  package:
    needs: [anchor]
    runs-on: [self-hosted, windows, gcp, '<Repo>']
    timeout-minutes: 45
    env:
      DATABASE_URL: postgres://ci@${{ needs.anchor.outputs.addr }}:${{ needs.anchor.outputs.pg }}/app
```

`localhost` and `127.0.0.1` in a Windows fleet job are refused by `RUNNER11`.
Not style: the Linux snippet is correct on Linux and there is nothing listening
on the Windows host's loopback, so the copy-paste fails as a connection timeout
inside a 45-minute packaging job.

**The Windows job is the only reason a pull request holds two hosts.** A
repository with no Windows pool has one host per workflow run, full stop.

**More than one Windows job costs more than one Windows host.** `slots_per_host`
is 1 on that pool, so two unpinned Windows jobs land on two machines. Pinning
them to one host — by having a Windows anchor of their own — serializes them
instead. The pool exists for a single packaging build, so neither answer is
wrong and the contract does not choose for you: `RUNNER9` covers Linux jobs and
does not require a Windows anchor. Decide explicitly and say so in the workflow.

### Sharing a stack safely

One Postgres serving six suites can race in ways six private ones cannot, and
the failure reads as flake. The contract is a schema or a database per suite
inside the one server — created by the suite, dropped by it. No gate can check
this; it is the obligation that comes with the saving.

## 5. What the host provides

Set by the boot script in every Linux slot's environment:

| variable | meaning |
|---|---|
| `CI_HOST_LABEL` | this host's affinity label, `host-<instance-name>` — what the anchor publishes |
| `CI_SHARED_INFRA_ADDR` | the host's primary VPC address — what siblings and the Windows host connect to |
| `CI_SHARED_INFRA_PORT_MIN` | first host port DNAT'd into this slot |
| `CI_SHARED_INFRA_PORT_MAX` | last one; the band is 100 ports and disjoint per slot |

And one command, on `PATH` in every slot:

| command | meaning |
|---|---|
| `ci-pin-hold --run <id> --ttl <duration>` | write (or renew) this host's pin hold as a guest attribute; the controller reads it before acting on a drain, cordon or retire verdict, and vetoes the removal while the hold is live. The TTL runs from now — see "Sizing the TTL". Called by the anchor, and thereafter by the host's job-started hook (`renew --run <id>`, on **started** only, and refused when the id is not the one the record names): a workflow never needs to call it to renew, and a job inside a `container:` could not. **Prints `pinned=1` or `pinned=0` and exits 0 either way** — it is an admission decision, so read the answer and continue unpinned on a refusal |
| `ci-pin-hold … --reserve-slot` | additionally reserve **this slot** for the run. Runs as root through a three-line sudoers allowlist, because the record it writes decides whether a slot is wiped and PR-authored code is what calls it. `slot-reset.sh` then spares this slot's containers while still wiping its workspace, and the host-side sweeper stops the slot's agent so nothing else lands on its uid or its daemon. **Refuses** when the host already holds a reservation for a different run — first anchor wins, and the loser continues unpinned — and on a single-slot host, where reserving the only slot would serve nobody. Released, torn down and restored host-side when the run ends or the TTL lapses. A second run is refused until that release has actually happened, not merely become due |

A host that does not set them is older than this contract. The anchor degrades
to unpinned on a missing `CI_HOST_LABEL`; the owner job fails on a missing
`CI_SHARED_INFRA_ADDR` (`:?` above) rather than defaulting to `127.0.0.1`, which
works in the owner job and fails everywhere else.

Ports outside the band are **not** DNAT'd and are not a bug — the band is what
the pool's firewall rule permits between hosts, and a wider one would be a wider
rule.

### What the firewall rule does not separate

The rule is scoped to the **repository**, not to the run, and the difference is
worth stating because the band otherwise reads as private to your pull request.

A network tag is static metadata on a VM. Every host in your repository's pool
carries the same source tag and every stack host the same target tag, for as
long as the pool exists — there is no run id in a tag. So two pull requests of
the *same repository* running at the same time on different hosts each match the
other's rule, and either could open a socket on the other's band. In the example
this document uses, that is a passwordless PostgreSQL.

What this is not: an opening for fork-authored code. Forks do not run on this
fleet — the pools refuse fork workflows and `check-runner-policy.sh` fails a
`pull_request` job that reaches a warm host without a fork guard. Both sides of
this boundary are code that already has write access to the repository.

What it still is: a job with a hardcoded port, a stale connection string, or a
test that scans the band can reach a *concurrent run's* database and corrupt a
result, and nothing in the failure will point at this rule. Two habits avoid it
entirely, and they are the same two the rest of this document asks for anyway —
take your addresses from `CI_SHARED_INFRA_ADDR` and the band variables rather
than hardcoding a port, and name your compose project after the run so a stray
connection fails loudly instead of landing somewhere plausible.

Closing it properly needs authorization the network layer cannot express, and is
tracked in issue #265 as host-side filtering keyed on the run the pin hold
already records.

## 6. What the pool does for you

You do not configure any of this; it is stated so the behaviour is not a
surprise.

- **The anchor job writes a pin hold on its host**, naming the workflow run and
  an expiry. The controller will not drain *or cordon-for-recycle* a host under
  an unexpired hold, so the host that answered the anchor is still there when the
  pinned jobs arrive.
- **A pinned job does not ask the autoscaler for a new host.** It cannot use
  one — only the named host can serve it. The controller recognises the affinity
  label, keeps the pinned job out of scale-out demand, and still counts its host
  as busy. Genuine scale-out demand still comes from anchors, which are
  unpinned.
- **If the host disappears anyway, your run fails instead of hanging.** The pin
  hold covers drain and recycle; it does not cover a crash or a manual delete,
  and a MIG replacement comes back under a different name and therefore a
  different label. A pinned job whose host no longer exists can never be
  served — and because it is excluded from scale-out demand, nothing will even
  try. The controller detects that case and fails the run within a bounded
  window rather than leaving it to GitHub's 24-hour queue timeout. Re-run the
  workflow: the next anchor picks a live host.

## 7. Adoption order

1. The aggregate required check and the lane model — [`ci-lane-model.md`](ci-lane-model.md).
2. **Consolidate `pull_request` CI into one workflow.** Without this, everything
   below is per-workflow and the pull request still holds several hosts.
3. The anchor job, with every other fleet Linux job consuming it. Merge this
   alone and confirm the pull request still runs when the pool is cold.
4. Move `services:` into `ci/compose.yaml` and make the anchor the owner.
5. Point the Windows job at the outputs.
6. Turn the gate on: add `--allow-dynamic-runner --shared-infra` to the
   `check-runner-policy.sh` invocation.

Step 6 last, deliberately. The rules are opt-in by flag so that a repository
mid-adoption is not a repository with a red gate teaching its readers to
disable it.

## 8. What a consuming repository must not do

- **Do not vendor the anchor job's logic and then edit it.** Nine divergent
  copies of the pool module is the mistake this repository exists to undo.
- **Do not pin the anchor.** It is the job that discovers the host; pinning it
  to a host that may not exist is the deadlock this design removes.
- **Do not use a PAT to read the runner list.** The anchor makes the API
  unnecessary; a fleet-wide token in a repository that runs pull-request code is
  a worse trade than any scheduling gain.
- **Do not tear the stack down from a consuming job.** See §3 — it cannot reach
  the daemon it targets. The host does it.
- **Do not keep the owner job running to guard the stack.** Its outputs are
  unreadable until it finishes and its consumers cannot start, so it would wait
  for them while they wait for it. The reservation is host-side precisely
  because the workflow layer cannot express it.
- **Do not expect the reservation to be instant.** For a tick after the owner
  exits, another job may land on the reserved slot. It cannot corrupt your
  workspace — the reset still runs — but it shares your daemon while it lasts.
  A stack must not hold anything a concurrent pull request should not see; the
  port band already says the same thing for the network side.
- **Do not adopt this on a one-slot pool.** The owner would reserve the only
  agent and its consumers, all pinned to that host, would never start. The
  reservation refuses and fails the run rather than deadlocking, but the fix is
  `slots_per_host >= 2` on the pool. Your consumers then get `slots_per_host - 1`
  concurrent slots, not `slots_per_host`.
- **Do not publish outside your slot's band.** It works in the job that does it
  and in no other job, which is the worst place for a failure to appear.
- **Do not write `localhost` in a Windows fleet job.** See `RUNNER11`.
- **Do not add a second `services:` job or a second owner marker "just for this
  one suite".** That is the per-job database this contract removed, re-entering
  under a smaller name.
