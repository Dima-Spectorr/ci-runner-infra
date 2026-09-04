# `ci-runner-network` — the firewall posture around a CI runner pool

Creates the **once-per-project** firewall rules the runner pool needs. The VPC
and the subnet are assumed to exist already and are passed in; this module
creates neither, and creates no Cloud Router and no Cloud NAT.

**There is no NAT here, deliberately.** The hosts and the controller have no
external address (`compute.vmExternalIpAccess = DENY`). Outbound traffic leaves
through the VPC peering to the estate's landing-zone network and its central
egress firewall, exactly as every other machine in these projects. An estate
without a central egress path would add its own NAT; this module stays out of
that decision.

Tenancy-agnostic — no customer literals.

## What it creates

| Rule | Direction | Purpose |
|---|---|---|
| `<prefix>-allow-iap-ssh` | ingress | `tcp:22` from `35.235.240.0/20` only. Operators reach machines with no external address this way — and so does the controller's idle probe, which is why a host outside this rule can never be scaled in. |
| `<prefix>-allow-iap-winrm` | ingress | `tcp:5986` from `35.235.240.0/20`, to `<prefix>-image-builder` and **no other tag**. The Windows golden image is built by a Packer VM with no external address that is reached over WinRM-on-TLS through the IAP tunnel; without this rule the build does not fail, it waits until the plugin times out. The tag is deliberately not the runner tag: 5986 belongs on a VM that lives for one build, not on hosts that run pull-request code for months. A rule whose target tag is on no instance permits nothing, so this costs no surface in a project that never builds a Windows image. |
| `<prefix>-allow-health` | ingress | MIG / load-balancer health-check ranges → tagged hosts. |
| `<prefix>-allow-egress` | egress | `tcp:443` + `tcp/udp:53`. GitHub, the package registries, Google APIs, DNS. **Logged** — this is the destination record. |
| `<prefix>-allow-egress-db` | egress | Common database ports, **RFC1918 destinations only**. Logged. |
| `<prefix>-deny-egress` | egress, priority 65534 | Everything else. The implied deny only applies while no allow rule exists; stating it keeps a later broad allow on the VPC from silently widening what pull-request code can reach. Logged, including at `firewall_logging = "denied"`. |

### The egress is recorded, not only bounded

The allow rule reaches `0.0.0.0/0` on 443 by necessity — GitHub, the package
registries and Google APIs publish large, rotating, per-region ranges, and
pinning them in a firewall rule breaks builds on every upstream rotation. The
port narrowing is real defence; the destination is not bounded and is not going
to be.

What was missing was any record of it. A warm host holds a GCP identity and runs
third-party code out of every lockfile it installs, and the pool could not
answer "where did this connect out to" in either direction — there was no
evidence of an exfiltration and no evidence against one.

`firewall_logging` (default `all`) turns the rules into that record: one
`compute.googleapis.com/firewall` entry per connection, carrying the destination
address and port, the rule that decided, and the disposition.

- **There is no Cloud NAT here to log.** This estate peers out through a central
  firewall; the module deliberately creates no NAT.
- **This module does not own the subnet**, so it cannot enable VPC flow logs.
  It owns the rules, and the rules record the same 5-tuple.
- **The health-check rule is never logged**, at any setting. Probes arrive every
  few seconds per host, forever, and would bury the egress record they were
  charged for.
- `INCLUDE_ALL_METADATA`, deliberately: a bare destination IP is not an answer.
  The metadata carries the remote ASN and country, which is what lets a reader
  tell GitHub from a rented VPS.

Set `firewall_logging = "denied"` for the cheap setting — but it is the cheap
one, not the safe one. It answers what the rules stopped, and the interesting
egress from a credentialed warm host is the egress that was allowed.

Read `gcloud logging read 'logName:"compute.googleapis.com%2Ffirewall"'` in the
pool's project.

### About the database rule

Integration tests that talk to a real database are why several of these
repositories run CI on their own machines at all. The allow rule above them is
narrowed to 443 and DNS, so without this rule the deny takes every database
connection — and takes it **silently**: what the author sees is a client that
hangs until the job times out, with the refusal in a firewall log nobody is
reading.

The port list is the common set (SQL Server, Oracle, MySQL/MariaDB, PostgreSQL,
Redis, Cassandra, MongoDB), not any one repository's port, so each new
integration suite does not rediscover the omission the same expensive way. The
ports are not what makes this safe — the **destination** is: RFC1918 only, so a
job may reach a database inside the estate's own networks (which being on this
subnet already implies) and cannot open a database connection to a rented host
on the internet.

Adding a port is routine. Widening `database_egress_ranges` needs an argument.
`database_egress_ports = []` creates no rule at all.

## Variables

Required: `project_id`, `network`.
Optional: `name_prefix`, `runner_network_tag`, `image_builder_network_tag`, `iap_source_range`,
`health_check_source_ranges`, `egress_destination_ranges`, `egress_tcp_ports`,
`egress_udp_ports`, `database_egress_ports`, `database_egress_ranges`,
`firewall_logging`.

## Outputs

`runner_network_tag` — pass it into `ci-runner-host-pool`'s `network_tags` so
these rules apply to the pool's machines.

`image_builder_network_tag` — pass it to the Windows image build as
`_IMAGE_BUILDER_NETWORK_TAG`. Never into a pool's `network_tags`: that would put
the one tag 5986 is open to onto every runner host, which is the whole thing
this separation exists to prevent, and `cloudbuild.yaml`'s guard refuses the
same mistake from the other side.

## Use it by tag, never vendored

```hcl
module "ci_runner_network" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-network?ref=v5.91.0"

  project_id         = var.project_id
  network            = var.network
  name_prefix        = var.pool_name
  runner_network_tag = "${var.pool_name}-host"
}
```

Nine repositories each carried a copy of this module before it moved here, and
the copies drifted. A shared tag makes a fix land once.
