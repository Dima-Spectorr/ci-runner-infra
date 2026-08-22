# One pull request, one host — and one shared infrastructure stack on it

Status: **proposed** (design only; nothing here is implemented).
Scope: every repository on the fleet, both pools.
Related: [`ci-lane-model.md`](ci-lane-model.md) decides *how much* CI a diff
deserves; this decides *where* that CI runs and *what it shares*.
[`adr-windows-pool.md`](adr-windows-pool.md) §3A and §4 are the constraint this
document's third rule has to live inside.

## The three rules being adopted

1. **One pull request's self-hosted work runs on one host** — except a pull
   request that also needs the Windows pool, which uses two: one Linux host and
   one Windows host.
2. **Infrastructure a suite needs — a database, a broker, a cache — is brought
   up ONCE per pull request** and shared by every test and every container that
   pull request runs.
3. **A job on the Windows host can reach that shared infrastructure**, which
   lives on the Linux host.

They are one decision, not three. Rule 2 is only meaningful if rule 1 holds —
"once per pull request" has no referent while a pull request's jobs are
scattered across whichever hosts the pool happened to have idle. And rule 3 is
the price of rule 1's exception: the moment a pull request legitimately occupies
two hosts, the shared stack is on one of them and the other has to cross a
network boundary this fleet currently denies in both directions.

---

## Why this is being written

Three separate observations, one cause.

**The pool is the binding constraint and the arithmetic is not close.** Issue
[#205](https://github.com/Dima-Spectorr/ci-runner-infra/issues/205) measured it:
`max_hosts 3` × `slots_per_host 4` = 12 concurrent slots, against ~25 jobs for a
single Apigee-Portal pull request with three to four pull requests routinely in
flight. Measured queue waits of 50 s, 98 s, 180 s and 291 s, and — the part that
matters here — *displacement*: `TypeScript type-check` finished at 139 s on one
head and at 310 s and 406 s on two others, because unrelated pull requests were
eating the slots. A pull request's cost today is unbounded in the one dimension
the pool cannot grow.

**Every job that needs a database builds its own.** GitHub's `services:` are
per-job by construction: the agent creates them at "Initialize containers" and
destroys them when the job ends. A pull request with six jobs that each need
Postgres starts Postgres six times, migrates it six times, and seeds it six
times — on six slots that may be on three different hosts. Nothing about that is
a bug in any one workflow. It is what the primitive does.

**And the Windows pool cannot use that primitive at all.** `container:` and
`services:` fail at "Initialize containers" on a Windows host, which has no
container runtime by design — the pool exists for a WiX/`signtool` packaging
build that needs the host's real Win32 surface, and a Windows container is
precisely what breaks it (`adr-windows-pool.md` §4). `check-runner-policy.sh`
`RUNNER8` refuses the declaration so it fails in the consuming repository's own
CI rather than on the pool. That is the right refusal and it leaves a hole: a
Windows job that needs a database has, today, no supported way to get one.

---

## 1. What "one host" has to mean, given the isolation model

This is the part that cannot be decided by preference, because the host is not a
flat machine. `host-startup.sh` gives every slot its own uid, its own network
namespace, and its own rootless Docker daemon on a socket in a 0700
`/run/ci-s<i>`. The namespaces are `10.99.<idx>.2/30` on a veth to a
`10.99.<idx>.1` host end, NAT'd out of the primary interface.

So "one host" admits two readings, and they cost differently:

| reading | a pull request gets | shared infra reachable by |
|---|---|---|
| one **slot** | 1 concurrent job | that job only |
| one **host** | up to `slots_per_host` concurrent jobs | every slot on the host, *if* a path exists |

**One slot is rejected.** It makes rule 2 trivial — one daemon, one Docker
network, `localhost` everywhere — and it collapses a 25-job Apigee-Portal pull
request into a single serialized job. Measured against #205's own numbers that
trades a 291 s queue wait for a wall-clock several times worse, and it destroys
the per-check granularity the merge queue reads. The cure would be worse than
the disease it is prescribed for.

**One host is adopted.** A pull request occupies at most `slots_per_host` slots,
which is a *bound* where today there is none — that is the whole win against
#205 — and it keeps intra-pull-request parallelism at four-wide.

It also fixes the thing #205 describes and does not name: displacement is
unbounded because nothing associates a job with its pull request. Pinning makes
the association explicit, and the pool's contention moves from "every job
against every other job" to "at most three pull requests against each other",
which is a queue an operator can reason about.

### The consequence rule 2 has to absorb

Two slots on one host do **not** share a Docker daemon, a network namespace, or
a `localhost`. A stack brought up in slot 1 is invisible to slot 2 at
`127.0.0.1`, and that is deliberate: the slot fence exists because a shared
daemon socket let one job enumerate a sibling's containers, `exec` into them,
and read its `GITHUB_TOKEN` (README, "Each slot is its own Linux user with its
own rootless Docker daemon").

So sharing across slots needs a *sanctioned* path, and §3 builds exactly one.
What it must not do is rely on the path that already exists by accident — see
"Residual risk" below.

---

## 2. Pinning a pull request to a host

### 2.1 Hosts get an affinity label

Today every agent on a pool registers the same label set, read from
`instance/attributes/ci-runner-labels` — a template attribute, identical across
the MIG. There is nothing in a `runs-on` that can name one host.

Each agent additionally registers `host-<instance-name>`, composed at boot from
`instance/name` rather than from Terraform, because a MIG generates the name and
Terraform does not know it. Both boot scripts do it — `host-startup.sh` before
`--labels "$LABELS"`, `windows-host-startup.ps1` before its `--labels` argument.

This is additive. A `runs-on` that names only the pool labels keeps matching
every host, because GitHub routes to any runner whose label set is a superset of
what the job asks for. Nothing that exists today changes behaviour.

### 2.2 A lease job resolves the label

One job per workflow, on `ubuntu-latest` (the same reasoning as the lane
classifier: a job whose purpose is to decide whether a self-hosted slot is
warranted must never occupy one), lists the repository's runners, keeps those
that are `online` and carry the pool's scope label and `linux`, sorts them by
name, and picks index `pr_number % count`.

**Deterministic from the pull-request number, and not a claim in a registry.**
Several workflows fire on one pull request and they cannot see each other's
outputs; a stateless function of the pull request number is the only thing that
makes them agree without inventing a lease store, a lock, and a lock's failure
modes. The cost is stated plainly in §5.

**Zero online hosts is a supported answer, and it is `""`.** The pool scales to
zero. A lease job that fails, or that emits a label naming a host that is not
there, converts scale-to-zero into a pull request whose jobs queue until
GitHub's 24-hour cancellation. So an empty runner list yields an empty affinity
label, downstream `runs-on` degrades to exactly today's unpinned label set, the
autoscaler sees demand and scales out, and the pull request runs — unpinned, and
therefore with per-job infrastructure. **The contract degrades; it does not
deadlock.** This is the single most important property in this document, because
it is the one whose absence is unrecoverable without an operator.

### 2.3 Downstream jobs consume it

```yaml
  test:
    needs: [lane, host]
    if: needs.lane.outputs.lane != 'none'
    runs-on: ${{ fromJSON(needs.host.outputs.runs-on) }}
    timeout-minutes: 30
```

`fromJSON` of a whole array, not a label appended to a literal list: an empty
affinity label appended to a list produces `[self-hosted, linux, gcp, Repo, ""]`,
and an empty-string label matches no runner at all. The lease job emits the
complete array — pinned or unpinned — so the empty case is expressed by the
array being shorter rather than by a label being blank.

### 2.4 The controller must not drain a pinned host

`drain_decision()` drains a host that has been idle for its grace period. A
pull request between its fast tier and its heavy tier is a host that is idle and
must not be drained: the pull request's remaining jobs name that host by label,
and a drained host is a label nothing answers — the 24-hour hang again, arriving
through the back door after §2.2 closed the front one.

A host therefore carries a **pin hold**: a marker, written by any job that ran
under an affinity label, naming the pull request and an expiry. `drain_decision()`
treats an unexpired hold as not-idle. The hold is a pure input to a pure
function, which is how every other decision in this module is tested.

The expiry is what makes the hold safe to write from job context: the worst a
forged or abandoned hold can do is keep one host warm until it lapses, which is
the same cost as a slow job, and the recycle and orphan rules are unchanged
above it.

---

## 3. One shared stack per pull request, reachable from both hosts

### 3.1 The owner job brings it up; nobody else does

Exactly one job in a pull request owns the stack. It is a fleet Linux job, it
brings the stack up on its own slot's rootless daemon with a compose project
name derived from the pull-request number, it migrates and seeds it once, it
publishes the endpoints as job outputs, and every other job — Linux or Windows —
consumes those outputs.

`services:` is the shape being replaced. A `services:` block is per-job by
definition and there is no version of it that is shared, so a repository that
has adopted this contract declares infrastructure in exactly one place. That is
what `RUNNER10` (§4) asserts.

### 3.2 The port band, and the DNAT that makes it reachable

A slot's published port lands in the slot's network namespace. From outside the
host — and from a sibling slot — it does not exist. Two things are added:

**A per-slot port band.** Slot `idx` owns host ports `35000 + idx*100` through
`35000 + idx*100 + 99`. Disjoint by construction, so two slots publishing the
"same" service never collide — the collision that
[`setup_slot_netns`](../modules/ci-runner-host-pool/scripts/host-startup.sh)
was written for in the first place.

**A 1:1 DNAT per band**, installed at boot beside the existing MASQUERADE:

```
-t nat -A PREROUTING -i <primary_if> -p tcp --dport <band> -j DNAT --to 10.99.<idx>.2
```

The `FORWARD` chain already accepts `-o cis<idx>`, so nothing in the forwarding
policy loosens. What is new is one PREROUTING entry per slot, bounded to 100
ports, and nothing else on the host becomes reachable.

The slot learns its own band and the host's address the same way it learns its
cache paths — environment, set by the boot script:

```
CI_SHARED_INFRA_ADDR       the host's primary VPC address
CI_SHARED_INFRA_PORT_MIN   35000 + idx*100
CI_SHARED_INFRA_PORT_MAX   35000 + idx*100 + 99
```

A job that publishes outside its band gets a port that resolves on the slot's
own `localhost` and nowhere else — which fails as "the Windows job cannot
connect" rather than as anything readable, so the owner job asserts the range
before it publishes.

### 3.3 The firewall, which is currently closed in both directions

`ci-runner-network` today grants ingress for IAP SSH (22) and health checks, and
egress for 443, 53, and `database_egress_ports` to RFC1918. There is **no**
ingress rule permitting one pool host to reach another, and the explicit
`deny-egress` at priority 65534 takes everything the allows do not name.

So rule 3 needs one rule, not a posture change:

```
INGRESS, source_tags = [runner_network_tag], target_tags = [runner_network_tag],
tcp: 35000-35399   (slots_per_host bands)
```

Source *tags*, not ranges: the source set is exactly the pool's own VMs, which
is the narrowest statement of "a host in this pool" available, and it does not
have to be re-derived when a subnet is resized.

The Windows side's egress is already permitted **if** the band falls inside
`database_egress_ports`, and it does not — that list is real database ports.
Rather than widen a variable whose meaning is "a database somewhere in the
estate", the band gets its own egress allow with the same tag-to-tag scoping.
Two narrow rules that state what they are beat one wide rule that has to be
explained.

### 3.4 The Windows job reads an address, never `localhost`

There is no container runtime and no shared stack on the Windows host. A Windows
job connects to `${{ needs.infra.outputs.addr }}:${{ needs.infra.outputs.pg }}`.

`localhost` on a Windows fleet job is the copy-paste failure this contract
manufactures — the Linux snippet is correct on Linux and silently wrong here —
so `RUNNER11` (§4) refuses it rather than leaving it to a reviewer.

---

## 4. The gate

Three rules join `check-runner-policy.sh`, which every consuming repository
already runs, so adoption needs no new wiring.

| id | Rule |
|---|---|
| `RUNNER9` | a fleet-reachable **Linux** job in a `pull_request` workflow resolves its `runs-on` from the affinity lease, or carries a declared exemption |
| `RUNNER10` | at most **one** job across a repository's `pull_request` workflows declares `services:` — infrastructure is brought up once |
| `RUNNER11` | a **Windows** fleet job does not name `localhost`/`127.0.0.1` on a shared-infrastructure port — there is nothing listening there |

`RUNNER9` has to tolerate `RUNNER5`. Resolving `runs-on` from a job output *is*
dynamic runner selection, which `RUNNER5` reports as UNDECIDED unless
`--allow-dynamic-runner` is passed. A repository that has adopted this contract
passes it, and `RUNNER9` then supplies the specificity `RUNNER5` gave up: not
merely "an expression", but an expression naming the lease job's output.

Exemptions are **declared, not inferred**, in the workflow where a reviewer sees
them — the same posture as `--forks=blocked` and `remote-reusable-allowed`. A
release job that must not share a host with a pull request's test stack is a
legitimate exemption; "this one was awkward" is not, and the marker carries the
reason so the difference is legible.

---

## 5. Residual risk, honestly

**A re-pick splits a pull request across two hosts.** The lease is a function of
the pull-request number and the *current* online host list. A host that drains,
or one that scales out, between two workflows changes the divisor and can move
the pick. The pull request then holds two hosts and brings the stack up twice.
This is a performance regression, not a correctness one — the compose project
name is per pull request, so the second stack is a second complete stack rather
than a half-initialised shared one — and the alternative is a lease registry
whose own failure modes are worse than the fault it removes. It is worth
revisiting only with a measurement of how often it fires.

**Slots on one host can already reach each other, and this document must not be
read as granting that.** `setup_slot_netns` appends `FORWARD -i cis<idx> ACCEPT`
and `FORWARD -o cis<idx> ACCEPT`, so a packet from `10.99.2.2` to `10.99.1.2` is
forwarded today. The daemon sockets are 0700 and unaffected, so this is
network-level reach and not container control — but it is reach that nothing
decided to grant, and it is not the mechanism §3.2 uses. §3.2 goes through a
named port band on the host address precisely so that the sanctioned path is the
one workflows are written against, and so that closing the accidental one later
breaks nothing. **Filed separately; not fixed here.**

**A shared stack is a shared mutable object.** Six jobs against one Postgres can
race in ways six private Postgres instances cannot, and the failure looks like
flake. The contract is that suites sharing a stack are schema- or
database-per-suite inside it; that is a per-repository obligation this document
states and no gate can check.

**The port band is reachable by every host in the pool, not only by the pull
request's Windows host.** Tag-to-tag scoping is the narrowest control the
firewall offers; distinguishing "this pull request's Windows host" from "another
pull request's Linux host" is not expressible there. The pool already serves one
repository (README, "Isolation rules"), so the exposure is bounded by that rule
and not by this one — which is another way of saying the one-repository-per-pool
rule is load-bearing here in the same way `adr-windows-pool.md` §3A says it is
load-bearing there.

**A pull request is now bounded to `slots_per_host` concurrent slots.** For a
pull request that today briefly gets eight slots because the fleet was quiet,
this is slower. That is the trade being made deliberately: #205's evidence is
that the unbounded case is what produces the 291 s waits and the displaced
required checks, and a predictable four is worth more than an occasional eight.

---

## 6. Delivery

Each phase is independently landable and independently useful. Nothing before
phase 5 changes any consuming repository's behaviour.

| # | Phase | Touches | Ships without |
|---|---|---|---|
| 1 | This ADR and the published contract | `docs/` | — |
| 2 | Affinity label registered at boot, both pools | `host-startup.sh`, `windows-host-startup.ps1`, self-tests | any workflow using it |
| 3 | Port band, per-slot DNAT, `CI_SHARED_INFRA_*` env | `host-startup.sh`, self-tests | any firewall change |
| 4 | Ingress/egress band rules; drain pin hold | `ci-runner-network`, `drain-decision.sh`, self-tests | any workflow using it |
| 5 | `RUNNER9`/`RUNNER10`/`RUNNER11` + fixtures | `check-runner-policy.sh`, `docs/ci-workflow-gates.md` | adoption (rules are opt-in by flag) |
| 6 | Reference lease job and owner job | `docs/ci-pr-shared-infra.md`, this repo's own workflows | — |
| 7 | Per-repository adoption | consuming repositories, one pull request each | — |

Phase 5 lands the rules behind a flag for the same reason `--forks` is a flag: a
gate that fails every repository on the day it merges is a gate that gets
disabled in every repository on the day after.

---

## 7. Decided

- One pull request occupies one Linux host, and one Windows host only if it
  needs one. Not one slot.
- Pinning is an affinity label plus a stateless lease derived from the pull
  request number, and an empty lease is a **supported answer** that degrades to
  today's behaviour.
- The controller will not drain a host holding an unexpired pin hold.
- Shared infrastructure is owned by exactly one job, published into a per-slot
  port band, DNAT'd to the host address, and reached by everyone else — sibling
  slots and the Windows host alike — at that address.
- The Windows pool gets no container runtime. This was reconsidered as part of
  this decision and re-affirmed: `adr-windows-pool.md` §4's reasoning is
  unchanged, and rule 3 is satisfied by reachability, not by a runtime.
- The firewall gains two narrow tag-to-tag rules for the band, and no widening
  of `database_egress_ports`.
- The gate rules are opt-in by flag until phase 7 completes.
