# One host per pull request, one infrastructure stack on it — published contract

This is the contract consuming repositories adopt. The decision behind it, with
the measurements and the rejected alternatives, is
[`adr-pr-host-affinity.md`](adr-pr-host-affinity.md). The enforcement is
`RUNNER9`/`RUNNER10`/`RUNNER11` in `scripts/ci/check-runner-policy.sh`
([`ci-workflow-gates.md`](ci-workflow-gates.md)).

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

---

## 1. The lease job

One per workflow, on `ubuntu-latest`. It must never occupy a pool slot: its
whole job is to decide which slot the rest of the workflow gets.

```yaml
  host:
    name: Host lease
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      # The runner list is repository administration, not contents.
      administration: read
    outputs:
      # A JSON ARRAY, consumed with fromJSON — see "Why an array" below.
      runs-on: ${{ steps.lease.outputs.runs-on }}
      host: ${{ steps.lease.outputs.host }}
    steps:
      - id: lease
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SCOPE: <Repo>            # this repository's pool scope label
          PR: ${{ github.event.pull_request.number || 0 }}
        run: |
          set -euo pipefail
          # `--paginate` matters: a fleet at max_hosts 3 fits on one page today
          # and the pick must not change meaning when it does not.
          hosts=$(gh api --paginate \
                    "repos/${GITHUB_REPOSITORY}/actions/runners" \
                    --jq '.runners[]
                          | select(.status == "online")
                          | select([.labels[].name] | index(env.SCOPE))
                          | select([.labels[].name] | index("linux"))
                          | [.labels[].name]
                          | map(select(startswith("host-")))[0]' \
                 | grep -v '^null$' | sort -u || true)
          n=$(printf '%s\n' "$hosts" | grep -c . || true)
          if [ "$n" -eq 0 ]; then
            # SUPPORTED, not an error. The pool scales to zero; emitting a label
            # for a host that is not there is how a pull request queues for 24
            # hours. Degrade to the unpinned label set and let the autoscaler
            # do its job.
            echo 'runs-on=["self-hosted","linux","gcp","<Repo>"]' >> "$GITHUB_OUTPUT"
            echo "host=" >> "$GITHUB_OUTPUT"
            echo "::notice::no online host — running unpinned, infra will be per-job"
            exit 0
          fi
          pick=$(printf '%s\n' "$hosts" | sed -n "$(( PR % n + 1 ))p")
          printf 'runs-on=["self-hosted","linux","gcp","<Repo>","%s"]\n' "$pick" >> "$GITHUB_OUTPUT"
          printf 'host=%s\n' "$pick" >> "$GITHUB_OUTPUT"
          echo "::notice::pinned to $pick ($n online)"
```

**Why the pull-request number and not a registry.** Several workflows fire on
one pull request and none of them can read another's outputs. A stateless
function of the pull-request number is what makes them agree without a lease
store, a lock, and a lock's failure modes. A host draining between two workflows
can move the pick; the ADR states that residual and why it is the cheaper side.

**Why an array.** Appending an empty label to a literal list yields
`[self-hosted, linux, gcp, <Repo>, ""]`, and an empty label matches no runner —
turning the scale-to-zero case back into the 24-hour hang the empty case exists
to avoid. The lease emits the whole array so "unpinned" is a shorter array, not
a blank element.

**`administration: read`, and nothing else.** `permissions:` is declared on the
job, so every other scope drops to none for it. If your organisation withholds
that scope from `GITHUB_TOKEN`, the API call 403s — treat that exactly as the
zero-hosts case and run unpinned. Do not reach for a PAT: a token that can read
the runner list of every repository, held in a repository that runs pull-request
code, is a worse trade than an unpinned pull request.

## 2. Consuming the lease

```yaml
  test:
    needs: [lane, host]
    if: needs.lane.outputs.lane != 'none'
    runs-on: ${{ fromJSON(needs.host.outputs.runs-on) }}
    timeout-minutes: 30
```

Every fleet-reachable Linux job in a `pull_request` workflow does this.
`RUNNER9` checks it.

This is dynamic runner selection, which `RUNNER5` reports as UNDECIDED, so the
gate is run with `--allow-dynamic-runner` once this contract is adopted.
`RUNNER9` supplies the specificity that flag gives up: not merely an expression,
but one naming the lease job's output.

## 3. The infrastructure owner job

Exactly one job in the repository's `pull_request` workflows brings the stack
up. `RUNNER10` fails a second one.

```yaml
  infra:
    name: Shared infra
    needs: host
    runs-on: ${{ fromJSON(needs.host.outputs.runs-on) }}
    timeout-minutes: 15
    outputs:
      addr: ${{ steps.up.outputs.addr }}
      pg: ${{ steps.up.outputs.pg }}
    steps:
      - uses: actions/checkout@v4
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

          # Project name per pull request: two stacks for one pull request (the
          # re-pick case) are then two complete stacks rather than one
          # half-initialised shared one.
          export COMPOSE_PROJECT_NAME="pr-${{ github.event.pull_request.number }}"
          PG_PORT="$pg" docker compose -f ci/compose.yaml up -d --wait

          # Migrate and seed ONCE. This is the line the whole contract exists
          # for: it used to run in every job that needed a database.
          ./scripts/db-migrate.sh "postgres://ci@127.0.0.1:${pg}/app"

          echo "addr=${CI_SHARED_INFRA_ADDR}" >> "$GITHUB_OUTPUT"
          echo "pg=${pg}"                     >> "$GITHUB_OUTPUT"
```

Teardown belongs in an `if: always()` step of the last consuming job, or in a
final job that `needs:` them all — not in the owner job, which finishes first.
A stack left running is not a leak the host cannot survive (the recycle rules
reclaim the slot) but it holds the band until it does.

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
    needs: [host, infra]
    runs-on: ${{ fromJSON(needs.host.outputs.runs-on) }}
    timeout-minutes: 30
    env:
      DATABASE_URL: postgres://ci@${{ needs.infra.outputs.addr }}:${{ needs.infra.outputs.pg }}/app
```

**From the Windows host** — identical, which is the point:

```yaml
  package:
    needs: [host, infra]
    runs-on: [self-hosted, windows, gcp, <Repo>]
    timeout-minutes: 45
    env:
      DATABASE_URL: postgres://ci@${{ needs.infra.outputs.addr }}:${{ needs.infra.outputs.pg }}/app
```

`localhost` and `127.0.0.1` in a Windows fleet job are refused by `RUNNER11`.
Not style: the Linux snippet is correct on Linux and there is nothing listening
on the Windows host's loopback, so the copy-paste fails as a connection timeout
inside a 45-minute packaging job.

**The Windows job is the only reason a pull request holds two hosts.** A
repository with no Windows pool has one host per pull request, full stop.

### Sharing a stack safely

One Postgres serving six suites can race in ways six private ones cannot, and
the failure reads as flake. The contract is a schema or a database per suite
inside the one server — created by the suite, dropped by it. No gate can check
this; it is the obligation that comes with the saving.

## 5. What the host provides

Set by the boot script in every Linux slot's environment:

| variable | meaning |
|---|---|
| `CI_SHARED_INFRA_ADDR` | the host's primary VPC address — what siblings and the Windows host connect to |
| `CI_SHARED_INFRA_PORT_MIN` | first host port DNAT'd into this slot |
| `CI_SHARED_INFRA_PORT_MAX` | last one; the band is 100 ports and disjoint per slot |

A host that does not set them is older than this contract. Fail on the absence
(`:?` above) rather than defaulting to `127.0.0.1`, which works in the owner job
and fails everywhere else.

Ports outside the band are **not** DNAT'd and are not a bug — the band is what
the pool's firewall rule permits between hosts, and a wider one would be a wider
rule.

## 6. Adoption order

1. The aggregate required check and the lane model — [`ci-lane-model.md`](ci-lane-model.md).
2. The lease job, with every fleet Linux job consuming it. Merge this alone and
   confirm the pull request still runs when the pool is cold.
3. Move `services:` into `ci/compose.yaml` and one owner job.
4. Point the Windows job at the outputs.
5. Turn the gate on: add `--allow-dynamic-runner --pr-affinity` to the
   `check-runner-policy.sh` invocation.

Step 5 last, deliberately. The rules are opt-in by flag so that a repository
mid-adoption is not a repository with a red gate teaching its readers to
disable it.

## 7. What a consuming repository must not do

- **Do not vendor the lease job's logic and then edit it.** Nine divergent
  copies of the pool module is the mistake this repository exists to undo.
- **Do not treat an empty lease as an error.** Scale-to-zero is normal. Unpinned
  is a supported, slower mode; a failed lease job is a blocked pull request.
- **Do not use a PAT to read the runner list.** Unpinned beats a fleet-wide
  token in a repository that runs pull-request code.
- **Do not publish outside your slot's band.** It works in the job that does it
  and in no other job, which is the worst place for a failure to appear.
- **Do not write `localhost` in a Windows fleet job.** See `RUNNER11`.
- **Do not add a second `services:` job "just for this one suite".** That is the
  per-job database this contract removed, re-entering under a smaller name.
