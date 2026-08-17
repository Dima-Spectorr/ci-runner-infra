# ci-runner-network — per-project ingress plumbing for the CI runner pool.
#
# The runner VMs and controller have NO external IPs (org policy
# compute.vmExternalIpAccess=DENY). Outbound internet egress (to github.com /
# api.github.com / *.actions.githubusercontent.com and Google APIs) flows via the
# VPC peering to the estate's central landing-zone VPC and out through the
# centralised egress firewall — exactly as every other project VM in that
# estate. NO per-project Cloud Router or Cloud NAT is created; they are not
# needed for a peered landing-zone estate. (An estate without a central egress
# path would add its own Cloud NAT; this module deliberately stays out of that
# decision and only adds firewall rules.)
#
# This module is created ONCE per project. The VPC and subnet are assumed to
# already exist (most landing-zone app projects ship with one) and are passed
# in by self-link / name; this module only adds the firewall rules.
#
# Resources:
#   google_compute_firewall (iap)    — tcp:22 ingress from the IAP range only
#   google_compute_firewall (health) — health-check ranges -> tagged VMs
#   google_compute_firewall (egress) — explicit egress restricted to HTTPS + DNS
#
# EGRESS IS RECORDED, NOT JUST BOUNDED.
#   The allow rule below reaches 0.0.0.0/0 on 443 by necessity, and until now
#   nothing wrote down where it actually went. A warm host holds a GCP identity,
#   runs third-party code from every lockfile it installs, and had no record of
#   a single outbound destination — so "did anything leave this pool" was a
#   question with no evidence either way, in either direction.
#
#   There is no Cloud NAT here to log (this estate peers out through a central
#   firewall) and this module does not own the subnet, so it cannot turn on VPC
#   flow logs. What it does own is the rules, and firewall-rule logging records
#   the same 5-tuple: one `compute.googleapis.com/firewall` entry per connection,
#   carrying the destination address and port, the rule that decided, and the
#   disposition. That is the inventory. See var.firewall_logging.

locals {
  # `all` logs the allows too — the only setting that answers "where does this
  # pool connect out to". `denied` and `all` both log the deny.
  log_allowed = var.firewall_logging == "all"
  log_denied  = var.firewall_logging != "off"

  # INCLUDE_ALL_METADATA, deliberately, and it is the more expensive choice.
  # A destination IP on its own is not an answer: nobody reading an alert can
  # tell 140.82.121.4 from a rented VPS, and the whole point of the record is
  # that somebody can. The metadata is what carries the remote ASN, country and
  # — for an in-estate destination — the instance, which is what makes a
  # never-before-seen destination legible rather than merely new.
  firewall_log_metadata = "INCLUDE_ALL_METADATA"
}

# IAP SSH — operators reach the no-external-IP VMs only through
# `gcloud compute ssh --tunnel-through-iap`. No broad 0.0.0.0/0:22.
resource "google_compute_firewall" "iap_ssh" {
  project = var.project_id
  name    = "${var.name_prefix}-allow-iap-ssh"
  network = var.network

  direction     = "INGRESS"
  source_ranges = [var.iap_source_range]
  target_tags   = [var.runner_network_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Who reached a warm host, and when. Low volume by nature — a human opening a
  # tunnel — and the one ingress worth a record.
  dynamic "log_config" {
    for_each = local.log_allowed ? [1] : []
    content {
      metadata = local.firewall_log_metadata
    }
  }
}

# MIG / load-balancer health-check probes (intra-VPC, Google ranges only).
resource "google_compute_firewall" "health_check" {
  project = var.project_id
  name    = "${var.name_prefix}-allow-health"
  network = var.network

  direction     = "INGRESS"
  source_ranges = var.health_check_source_ranges
  target_tags   = [var.runner_network_tag]

  allow {
    protocol = "tcp"
  }

  # Deliberately never logged, at any setting. Health probes arrive every few
  # seconds per host from Google's own ranges, forever, and they would be the
  # overwhelming majority of every entry in the log — burying the egress record
  # this change exists to produce, and charging for the privilege.
}

# Explicit, least-privilege egress-allow for the tagged runner/controller VMs.
# CI runners only make outbound calls — to GitHub, package registries and
# Google APIs (HTTPS/443) plus DNS resolution (53). They never need arbitrary
# ports or protocols outbound, so the rule is restricted to TCP 443 + TCP/UDP
# 53 rather than allow-all. Stating it explicitly also makes the egress posture
# auditable and survives a project that has tightened the implied rules.
#
# The destination stays 0.0.0.0/0 (the var default): a CI runner must reach
# GitHub, the package registries and Google APIs, whose published IP ranges
# are large, change frequently, and differ per region — pinning them in the
# firewall rule would be brittle and would silently break builds on every
# upstream IP-range rotation. The meaningful controls delivered here are the
# protocol/port narrowing (443 + 53 only — the original GCP-0035 finding was
# *all protocols*) and the explicit lower-priority deny-all below. In a peered
# landing-zone estate the real destination-level egress control is the central
# egress firewall the peering routes through. An estate with a fixed egress
# target set can still narrow var.egress_destination_ranges.
#
# The destination is unbounded, so it is RECORDED instead. Until this rule
# carried a log_config, "where does this pool connect out to" had no answer at
# all — which is a worse position than the wide rule, because it also means an
# exfiltration and a clean pool look identical from the outside.
#
# trivy:ignore:AVD-GCP-0035 — egress destination is intentionally 0.0.0.0/0;
# see the rationale above. Ports are restricted; destination control is the
# central firewall, and the destinations are now logged (var.firewall_logging).
# Re-review if the runner egress model changes.
resource "google_compute_firewall" "egress" {
  project = var.project_id
  name    = "${var.name_prefix}-allow-egress"
  network = var.network

  direction          = "EGRESS"
  destination_ranges = var.egress_destination_ranges
  target_tags        = [var.runner_network_tag]

  # HTTPS to GitHub / registries / Google APIs, and DNS over TCP.
  allow {
    protocol = "tcp"
    ports    = var.egress_tcp_ports
  }

  # DNS resolution.
  allow {
    protocol = "udp"
    ports    = var.egress_udp_ports
  }

  # THE record. This is the rule that reaches 0.0.0.0/0, so this is the rule
  # whose log says where the pool actually goes.
  dynamic "log_config" {
    for_each = local.log_allowed ? [1] : []
    content {
      metadata = local.firewall_log_metadata
    }
  }
}

# Database access, to PRIVATE ADDRESSES ONLY.
#
# Integration tests that talk to a real database are the reason several of these
# repositories run CI on their own machines at all, and the allow rule above is
# narrowed to 443 and DNS — so without this rule the deny below takes every
# database connection, and it takes it silently. What the author sees is a test
# client that hangs until the job's timeout, with the actual refusal recorded in
# a firewall log nobody is reading. That failure has now been paid for once; the
# rule exists so it is not paid for again per repository.
#
# The port list is the COMMON set, not any one repository's port. A per-repo list
# means each new integration suite rediscovers the omission the same expensive
# way, and the ports are not what makes this safe.
#
# What makes it safe is the DESTINATION: RFC1918 only. A job may reach a database
# inside the estate's own networks — which being on this subnet already implies —
# and may not open a database connection to anything on the internet, so this
# cannot become an exfiltration path to a rented Postgres. Adding a port here is
# routine; widening database_egress_ranges is the change that needs an argument.
#
# Set database_egress_ports = [] in a project whose runners must reach no
# database at all.
resource "google_compute_firewall" "egress_database" {
  count = length(var.database_egress_ports) > 0 ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-allow-egress-db"
  network = var.network

  direction          = "EGRESS"
  destination_ranges = var.database_egress_ranges
  target_tags        = [var.runner_network_tag]

  allow {
    protocol = "tcp"
    ports    = var.database_egress_ports
  }

  # Which database a CI job opened, from which host. RFC1918 destinations, so
  # the volume is a job's own connections rather than a registry's.
  dynamic "log_config" {
    for_each = local.log_allowed ? [1] : []
    content {
      metadata = local.firewall_log_metadata
    }
  }
}

# Deny everything else outbound from the runner VMs. The implied default-deny
# only applies in the absence of an allow rule; an explicit lower-priority deny
# documents the closed posture and blocks any future broad allow on the VPC.
resource "google_compute_firewall" "egress_deny" {
  project = var.project_id
  name    = "${var.name_prefix}-deny-egress"
  network = var.network

  direction          = "EGRESS"
  priority           = 65534
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [var.runner_network_tag]

  deny {
    protocol = "all"
  }

  # Logged at `denied` as well as `all`. The comment on the database rule above
  # describes a refusal "recorded in a firewall log nobody is reading" — it was
  # worse than that: with no log_config the refusal was recorded nowhere, and
  # the only symptom of a blocked egress was a test client hanging until the
  # job's timeout. This is what turns that into a searchable entry naming the
  # address and port the job could not reach.
  dynamic "log_config" {
    for_each = local.log_denied ? [1] : []
    content {
      metadata = local.firewall_log_metadata
    }
  }
}
