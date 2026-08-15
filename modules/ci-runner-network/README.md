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
| `<prefix>-allow-health` | ingress | MIG / load-balancer health-check ranges → tagged hosts. |
| `<prefix>-allow-egress` | egress | `tcp:443` + `tcp/udp:53`. GitHub, the package registries, Google APIs, DNS. |
| `<prefix>-allow-egress-db` | egress | Common database ports, **RFC1918 destinations only**. |
| `<prefix>-deny-egress` | egress, priority 65534 | Everything else. The implied deny only applies while no allow rule exists; stating it keeps a later broad allow on the VPC from silently widening what pull-request code can reach. |

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
Optional: `name_prefix`, `runner_network_tag`, `iap_source_range`,
`health_check_source_ranges`, `egress_destination_ranges`, `egress_tcp_ports`,
`egress_udp_ports`, `database_egress_ports`, `database_egress_ranges`.

## Outputs

`runner_network_tag` — pass it into `ci-runner-host-pool`'s `network_tags` so
these rules apply to the pool's machines.

## Use it by tag, never vendored

```hcl
module "ci_runner_network" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-network?ref=v5.7.0"

  project_id         = var.project_id
  network            = var.network
  name_prefix        = var.pool_name
  runner_network_tag = "${var.pool_name}-host"
}
```

Nine repositories each carried a copy of this module before it moved here, and
the copies drifted. A shared tag makes a fix land once.
