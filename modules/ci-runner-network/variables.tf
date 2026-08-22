# ci-runner-network — variables.
# Tenancy-agnostic: no customer literals. The customer overlay supplies values
# via .tfvars. Creates the once-per-project IAP + health-check firewall rules.
# Runner outbound egress goes via the VPC peering to the central landing-zone
# VPC and through the centralised firewall — no per-project Cloud NAT needed.

variable "project_id" {
  type        = string
  description = "GCP project ID where the firewall rules are created."
}

# No `region` variable: firewall rules are global, so the one the vendored copy
# carried was never read — it only pinned one estate's default region into a
# module several estates consume.

variable "name_prefix" {
  type        = string
  default     = "ci-runners"
  description = "Name prefix applied to the firewall resources."
}

variable "network" {
  type        = string
  description = "Self-link or name of the existing VPC network the runners attach to."
}

variable "runner_network_tag" {
  type        = string
  default     = "ci-runner"
  description = "Network tag the firewall rules target. Must match the tag the pool module puts on the instance template and controller VM."
}

variable "iap_source_range" {
  type        = string
  default     = "35.235.240.0/20"
  description = "Google IAP TCP-forwarding source range. SSH ingress is allowed only from here."
}

variable "health_check_source_ranges" {
  type        = list(string)
  default     = ["130.211.0.0/22", "35.191.0.0/16"]
  description = "Google load-balancer / MIG health-check source ranges."
}

variable "egress_destination_ranges" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = <<-EOT
    Destination CIDRs the runner VMs may reach on the allowed egress ports.
    The egress firewall rule restricts by port/protocol (HTTPS + DNS only);
    the destination stays 0.0.0.0/0 by default because CI runners reach
    GitHub, package registries and Google APIs through the central peering
    and their IPs are not fixed. An estate with a known egress target set
    (a fixed proxy/resolver) can narrow this for additional defence-in-depth.
  EOT
}

variable "egress_tcp_ports" {
  type        = list(string)
  default     = ["443", "53"]
  description = "TCP destination ports the runner VMs may egress to. 443 = HTTPS (GitHub, registries, Google APIs); 53 = DNS over TCP."
}

variable "database_egress_ports" {
  type = list(string)
  default = [
    "1433",  # Microsoft SQL Server
    "1521",  # Oracle
    "3306",  # MySQL / MariaDB
    "5432",  # PostgreSQL / Cloud SQL / AlloyDB
    "6379",  # Redis / Memorystore
    "9042",  # Cassandra
    "27017", # MongoDB
  ]
  description = <<-EOT
    Database ports a CI job may open to PRIVATE addresses. The common set rather
    than any one repository's port: a per-repo list means each new integration
    suite rediscovers the omission as a test that hangs until the job times out,
    against a deny recorded in a log nobody is reading. The safety here is
    database_egress_ranges, not this list. Set to [] to create no rule at all.
  EOT
}

variable "database_egress_ranges" {
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  description = <<-EOT
    Where those database ports may be reached. RFC1918 only, and this is the
    line that matters: a job may reach a database inside the estate's own
    networks — which being on this subnet already implies — and may not open a
    database connection to anything on the internet. Widening THIS needs an
    argument; adding a port above does not.
  EOT
}

variable "egress_udp_ports" {
  type        = list(string)
  default     = ["53"]
  description = "UDP destination ports the runner VMs may egress to. 53 = DNS resolution."
}

variable "firewall_logging" {
  type        = string
  default     = "all"
  description = <<-EOT
    Whether the runner firewall rules record the connections they act on.

      all     — both the allows and the deny. This is the only setting that
                produces a record of WHERE the pool connects out to.
      denied  — the deny rule only: what was refused, not what was reached.
      off     — no record at all.

    Default is `all`, because the destination inventory is the whole reason the
    variable exists and a pool that logs nothing cannot be asked the question
    later. It is a knob rather than a constant because the volume is real: one
    log entry per connection, on hosts that talk to a package registry
    thousands of times per job.

    `denied` is the cheap setting, not the safe one. It answers "what did the
    rules stop", which is the smaller half — the interesting egress from a warm
    host holding a GCP identity is the egress that was ALLOWED, because the
    rules allow 443 to 0.0.0.0/0.
  EOT

  validation {
    condition     = contains(["all", "denied", "off"], var.firewall_logging)
    error_message = "firewall_logging must be one of: all, denied, off."
  }
}

variable "shared_infra_id" {
  description = <<-EOT
    Identifier of the shared-infrastructure pool PAIR these rules serve — the
    same value given to both of the repository's `ci-runner-host-pool`
    instances, which is what puts the paired tags on their hosts.

    Empty (the default) creates no band rules at all. A project whose pools set
    no `shared_infra_id` gets exactly today's posture.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.shared_infra_id == "" || can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.shared_infra_id))
    error_message = "shared_infra_id must be a valid GCP network-tag component: lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "shared_infra_slots_per_host" {
  description = <<-EOT
    `slots_per_host` of the LINUX pool in the pair. It is the only input the
    band span needs: slot i owns 100 host ports at 35000 + i*100, and slots are
    numbered from ONE, so the span is 35100 .. 35000 + slots*100 + 99.

    It is stated here rather than read from the pool module because this module
    is created once per project and does not depend on the pools — but it must
    AGREE with them, and `scripts/ci/shared-infra-band.selftest.sh` asserts that
    this arithmetic and `host-startup.sh`'s produce the same numbers. A
    firewall span and a DNAT span that disagree do not fail loudly: the
    connection hangs until the job's timeout.
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.shared_infra_slots_per_host >= 1 && var.shared_infra_slots_per_host <= 90 && floor(var.shared_infra_slots_per_host) == var.shared_infra_slots_per_host
    error_message = "shared_infra_slots_per_host must be a whole number between 1 and 90 — above 90 the band would run past port 44099 and into the ephemeral range."
  }
}

variable "shared_infra_destination_ranges" {
  description = <<-EOT
    Destination ranges for the band's EGRESS allow. GCP egress rules cannot be
    scoped by destination TAG — only by range — so this is the one asymmetry in
    the pair of rules: ingress names the tag that may be reached, egress can
    only name where the sender may send.

    Default is RFC1918, which is what the `egress_database` rule already
    concedes for the same reason. Narrow it to the pool subnet's CIDR where the
    subnet is known; the ingress rule is the half that actually bounds who may
    answer.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

  validation {
    condition     = length(var.shared_infra_destination_ranges) > 0
    error_message = "shared_infra_destination_ranges must not be empty: an empty list is not a closed rule, it is an apply error, and the intent it looks like (no band egress) is spelled shared_infra_id = \"\"."
  }
}
