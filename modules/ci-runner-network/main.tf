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

# --- the shared-infrastructure band -------------------------------------------
#
# Rule 3 of the fleet's shared-infrastructure contract: a job on the Windows
# host must be able to reach the database on the LINUX host of the same pull
# request (docs/adr-pr-host-affinity.md §3.3, docs/ci-pr-shared-infra.md).
#
# Nothing above permits it. There is no ingress rule letting one pool host reach
# another, and `deny-egress` at 65534 takes everything the allows do not name —
# so without these two rules the Windows job's connection to the stack is
# refused, and refused as a hang: the client waits until the job's timeout.
#
# The two rules are NOT symmetrical, because GCP's two directions do not offer
# the same controls. Ingress can name the tag that may be REACHED; egress can
# only name a destination RANGE. So the ingress rule is the half that bounds who
# may answer, and the egress rule only stops a slot dialling the band of a host
# outside the estate's own networks.
#
# The tags are the whole safety argument and they are described in the host
# pool's var.shared_infra_id. In short: `ci-shared-infra-src-<id>` is carried
# by both pools and is the SOURCE; `ci-shared-infra-stack-<id>` is carried by
# the Linux pool only and is the ingress TARGET.
#
# `-src-` is in that name to keep the two namespaces DISJOINT, and it is not
# cosmetic. Spelled `ci-shared-infra-<id>`, the source namespace CONTAINED the
# stack namespace: the pair keyed `stack-foo` got the source tag
# `ci-shared-infra-stack-foo`, which is character-for-character the stack tag of
# the pair keyed `foo`. Both keys pass validation, and the result is a rule for
# `foo` that targets `stack-foo`'s hosts -- the Windows one included, which
# `docs/adr-windows-pool.md` says can match no ingress rule -- and a rule for
# `stack-foo` that accepts `foo`'s Linux hosts as sources. Two repositories'
# bands joined, silently, by a naming choice. With a fixed role token after a
# fixed prefix the collision is not possible to spell: every source tag begins
# `ci-shared-infra-src-` and every stack tag `ci-shared-infra-stack-`. A Windows host matches no ingress
# rule anywhere, which is what keeps docs/adr-windows-pool.md's "no inbound
# path" true through a change that is entirely about inbound paths.
#
# A literal, un-scoped `ci-shared-infra` would have been fleet-wide: network
# tags match across every VM in the VPC that carries them, and two repositories
# whose pools share a network — the normal deployment, since the module takes
# the network as an input — would each match the other's rule. One repository's
# job could then open a socket on another repository's database.
#
# THE BOUNDARY THIS ENFORCES IS THE REPOSITORY, AND NOT THE RUN. Say so here,
# because the rule reads as though it were per-run and is not: a network tag is
# static VM metadata, so every host of one repository's pool carries the same
# source tag and every stack host the same target tag, for as long as the pool
# exists. Two pull requests of the SAME repository running concurrently on
# different hosts therefore match each other's rule, and either can reach the
# other's band — including, in the example the contract documents, a
# passwordless PostgreSQL.
#
# What that is and is not:
#
#   not a fork exposure   fork-authored code does not run on this fleet at all.
#                         RUNNER4 fails a pull_request job that reaches a warm
#                         host without a fork guard, and the pools are
#                         additionally set to refuse fork workflows. The code on
#                         both sides of this boundary is code with write access
#                         to the repository already.
#   still a real gap      a job that is merely BUGGY -- a fixed port, a stale
#                         connection string, a test that scans the band -- can
#                         reach a concurrent run's database and corrupt a result
#                         nobody will connect to this rule.
#
# Closing it needs authorization the network layer cannot express, because the
# run id is not a tag: host-side filtering that admits only the pair holding the
# same run, which is what the pin hold already records per host. Tracked in
# issue #265; until it lands, this rule is a repository-scoped boundary and is
# documented as one in docs/ci-pr-shared-infra.md.

locals {
  # Slot i owns 100 host ports at 35000 + i*100, and slots are numbered from
  # ONE (`seq 1 "$SLOTS"` in host-startup.sh), so the span starts at 35100 and
  # not at 35000. Asserted against the script by
  # scripts/ci/shared-infra-band.selftest.sh.
  shared_infra_band_base  = 35000
  shared_infra_band_width = 100

  # ONE ENTRY PER PAIR, and every derived value computed here rather than inline
  # in each resource. This module is created once per PROJECT while a pair
  # belongs to a REPOSITORY, so a project hosting two repositories' pools has
  # two pairs; the two rules below are the only resources in this module that
  # are per-pair, which is why they are the only ones keyed. Deriving the span
  # and the tags twice, once in each resource, is how an ingress rule and an
  # egress rule come to disagree — and that failure does not surface as a red
  # apply, it surfaces as a job that hangs until its timeout.
  shared_infra = {
    for k, v in var.shared_infra_pairs : k => {
      source_tag = "ci-shared-infra-src-${k}"
      stack_tag  = "ci-shared-infra-stack-${k}"
      band_span = format(
        "%d-%d",
        local.shared_infra_band_base + local.shared_infra_band_width,
        local.shared_infra_band_base + v.slots_per_host * local.shared_infra_band_width + local.shared_infra_band_width - 1,
      )
      destination_ranges = coalesce(v.destination_ranges, var.shared_infra_destination_ranges)
    }
  }
}

resource "google_compute_firewall" "shared_infra_ingress" {
  # An empty map — the default — creates nothing, which is the gate: a project
  # that declared no pair gets exactly today's posture and no new rules.
  for_each = local.shared_infra

  project = var.project_id
  # `-in-`, for the reason `-src-` is in the tag above: `-allow-si-<key>` and
  # `-allow-si-eg-<key>` were nested namespaces, so the pair keyed `eg-foo`
  # claimed the same firewall name as `foo`'s egress rule. Firewall names are
  # unique per project, so a valid two-pair configuration failed at apply.
  name    = "${var.name_prefix}-allow-si-in-${each.key}"
  network = var.network

  direction   = "INGRESS"
  source_tags = [each.value.source_tag]
  target_tags = [each.value.stack_tag]

  # Same check as the egress rule's, and here rather than only there because
  # "the other name is the longer one" is a fact about two string literals that
  # a later edit can change without either resource noticing.
  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-allow-si-in-${each.key}") <= 63
      error_message = "name_prefix and the shared_infra_pairs key '${each.key}' together exceed GCP's 63-character resource-name limit for `${var.name_prefix}-allow-si-in-${each.key}`. Shorten one of them: otherwise the apply reaches the API and fails there, after the plan looked clean."
    }
  }

  allow {
    protocol = "tcp"
    ports    = [each.value.band_span]
  }

  # Which host reached which stack, on which port. This is a rule that opens a
  # path between two CI hosts, so the connections it permits are exactly the
  # ones an incident would ask about.
  dynamic "log_config" {
    for_each = local.log_allowed ? [1] : []
    content {
      metadata = local.firewall_log_metadata
    }
  }
}

resource "google_compute_firewall" "shared_infra_egress" {
  for_each = local.shared_infra

  project = var.project_id
  name    = "${var.name_prefix}-allow-si-eg-${each.key}"
  network = var.network

  direction          = "EGRESS"
  destination_ranges = each.value.destination_ranges
  target_tags        = [each.value.source_tag] # the SENDING VMs

  allow {
    protocol = "tcp"
    ports    = [each.value.band_span]
  }

  dynamic "log_config" {
    for_each = local.log_allowed ? [1] : []
    content {
      metadata = local.firewall_log_metadata
    }
  }

  # A PRECONDITION and not a `variable` validation, because the check needs two
  # variables at once and a validation condition could not reference a second
  # variable before Terraform 1.9. This repository supports 1.5, and the module
  # is loaded by every consumer whether or not it sets `shared_infra_pairs` — so
  # a cross-variable validation here would not merely reject a bad pair, it
  # would refuse to load, and every plan in every 1.5-1.8 consumer would fail on
  # a feature they never turned on.
  #
  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-allow-si-eg-${each.key}") <= 63
      error_message = "name_prefix and the shared_infra_pairs key '${each.key}' together exceed GCP's 63-character resource-name limit for `${var.name_prefix}-allow-si-eg-${each.key}`. Shorten one of them: otherwise the apply reaches the API and fails there, after the plan looked clean."
    }
  }
}

# The floor the allow above is an exception TO, and without it the allow was
# decorative on the side that needs it most.
#
# `egress_deny` is what normally makes an egress allow mean something: it denies
# everything at 65534 and the allows carve holes in it. But it targets
# `var.runner_network_tag`, and a WINDOWS pool does not carry that tag — the
# documented Windows configuration passes no network_tags at all, because its
# liveness gate is outbound and it needs no inbound path. So a Windows host
# carries the source tag and nothing else, matches no deny, and falls through
# to GCP's implied allow-egress. Band traffic to an address OUTSIDE
# destination_ranges was therefore permitted: not by this module's allow, but
# by the absence of anything refusing it. Both the per-pair override and
# shared_infra_destination_ranges were advisory on exactly the host the feature
# exists for.
#
# Scoped to the band and to the source tag, because that is the reach this PR
# grants and the reach it should be able to withdraw. It does NOT give a
# Windows pool the general egress floor a Linux pool has; that gap is real and
# older than this rule, and closing it means deciding what a Windows host is
# allowed to reach, which is not a decision to make inside a firewall rule for
# a database band.
#
# 65533 and not 1000: the allow above runs at the default 1000 and has to win
# for the ranges it names. A deny that outranked it would close the band
# outright, and the symptom -- a consumer hanging until the job's timeout --
# looks identical to the misconfiguration this rule is here to surface.
resource "google_compute_firewall" "shared_infra_egress_deny" {
  for_each = local.shared_infra

  project = var.project_id
  name    = "${var.name_prefix}-deny-si-eg-${each.key}"
  network = var.network

  direction          = "EGRESS"
  priority           = 65533
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [each.value.source_tag]

  deny {
    protocol = "tcp"
    ports    = [each.value.band_span]
  }

  # No name-length precondition of its own: `-deny-si-eg-` is a character
  # shorter than `-allow-si-eg-`, so the allow's check above is the binding one
  # and this name cannot be the first to overflow.

  dynamic "log_config" {
    for_each = local.log_denied ? [1] : []
    content {
      metadata = local.firewall_log_metadata
    }
  }
}
