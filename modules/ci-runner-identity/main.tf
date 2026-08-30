# ci-runner-identity — the service account and App-key secret a pool runs on.
#
# Split out of ci-runner-host-pool on purpose.
#
# The pool module is replaced whenever the execution model changes; identity is
# NOT. If the SA and the secret lived inside the pool module, swapping the pool
# would destroy the service account every IAM grant in the project points at,
# and delete the secret whose VALUE was added out of band and exists in no
# state file, no repo and no backup. That turns a runner upgrade into a manual
# credential re-issue in every project.
#
# So identity is a separate module with a separate lifecycle: it survives pool
# replacement, and a pool is handed an email and a secret name it did not
# create.
#
# PERMISSIONS ARE THE JOB'S PERMISSIONS. Every grant below is reachable by any
# CI job that runs on a host using this SA. Nothing may be added here for
# convenience.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

resource "google_service_account" "runner" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = "CI runner pool (${var.name})"
  description  = "Identity for CI runner hosts and the pool controller. Anything this account can reach, a CI job can reach."

  lifecycle {
    # A Windows pool's whole safety argument is "the host account is worth
    # nothing, and the controller holds what matters". Collapsing the controller
    # onto the host account puts the App-key read and instance-admin straight
    # back on the machine that executes pull-request code — i.e. it undoes the
    # reduction below and finding #1958 with it, while every grant here still
    # reads as removed. Refused at plan time.
    precondition {
      condition     = var.host_os != "windows" || var.create_controller_service_account
      error_message = "host_os = \"windows\" requires create_controller_service_account = true — a Windows host account is deliberately stripped of the App-key read, and collapsing the controller onto it hands that read (and instance-admin) back to job code."
    }
  }
}

# The CONTROLLER's identity, separate from the hosts'.
#
# The controller is the only thing that deletes a host — that is the entire
# scale-in mechanism, since no autoscaler is allowed to pick a victim — and
# deletion needs roles/compute.instanceAdmin.v1. While one account served both
# roles, that grant sat on the account attached to every host VM, i.e. on
# machines whose whole purpose is to execute pull-request code. Job code that
# got out of the container fence could delete the pool it was running on,
# including the hosts carrying other repositories' jobs, or create new
# instances with the host identity attached. `ci-runner-host-pool`'s own
# `service_account_email` description already forbade exactly this.
#
# The controller runs no build input, so instance-admin is bounded there.
resource "google_service_account" "controller" {
  count = var.create_controller_service_account ? 1 : 0

  project = var.project_id
  # 30-character cap on an account id, and `-ctl` costs four. Truncate the same
  # way the job account does so a long pool name (ci-runner-host-dataretrival)
  # fails at neither plan time nor apply.
  account_id   = "${substr(var.account_id, 0, min(26, length(var.account_id)))}-ctl"
  display_name = "CI pool controller (${var.name})"
  description  = "Identity for the pool CONTROLLER only. Holds instance-admin so it can delete hosts; must never be attached to a host, which runs build input."
}

locals {
  controller_email = var.create_controller_service_account ? google_service_account.controller[0].email : google_service_account.runner.email

  # Every grant on the HOST account is reachable by any job that runs on a host,
  # and on Windows there is no fence that changes that (see `host_os`). So on
  # Windows the host account gets none of them: 1 on linux, 0 on windows, and
  # one name so the three resources below cannot drift apart.
  host_grants = var.host_os == "windows" ? 0 : 1

  # The id is `var.app_key_secret_id` either way — a secret_id is the name the
  # caller chose, not something the API assigns. Reading it back off the
  # resource when this module owns it is still what orders the grants after the
  # create; when it does not, there is nothing to order against and the grants
  # land on a secret some other root manages.
  app_key_secret_id = var.create_app_key_secret ? google_secret_manager_secret.app_key[0].secret_id : var.app_key_secret_id
}

resource "google_secret_manager_secret" "app_key" {
  count = var.create_app_key_secret ? 1 : 0

  project   = var.project_id
  secret_id = var.app_key_secret_id

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "ci-runner-host-pool"
    pool      = var.name
  })

  # The VALUE is added out of band and is never in Terraform state, a repo, or
  # a plan output. Terraform must not be able to destroy it as collateral.
  lifecycle {
    prevent_destroy = true
  }
}

# Only this pool's identities may read the App key. The host and controller
# grants are separate resources rather than one `for_each` keyed by email:
# for_each would re-key the host's existing binding from
# `google_secret_manager_secret_iam_member.runner_reads_key` to
# `…runner_reads_key["<email>"]` (and the same for every other grant), and a computed
# email cannot appear in a `moved` block, so every live pool would destroy and
# recreate working IAM on its next apply for no behavioural gain.
#
# `count`, not `for_each`, and that is the difference the paragraph above is
# about. Adding a count puts a STATIC `[0]` on the address, which a `moved`
# block can name (see the three at the end of this file), so an existing pool
# keeps its live binding and plans zero resource changes. A computed email as a
# for_each key cannot appear in a `moved` block, which is why that shape stays
# rejected.
resource "google_secret_manager_secret_iam_member" "runner_reads_key" {
  count = local.host_grants

  project   = var.project_id
  secret_id = local.app_key_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

# The controller reads the key to mint an installation token for the queue
# poll; a host reads it for its slots' registration tokens.
resource "google_secret_manager_secret_iam_member" "controller_reads_key" {
  count = var.create_controller_service_account ? 1 : 0

  project   = var.project_id
  secret_id = local.app_key_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.controller[0].email}"
}

# Publishing the demand metric is what makes the pool scale out at all, and
# publishing the telemetry series is what makes it observable. The controller
# publishes demand, each host publishes its own series, so both need this.
#
# A Windows host publishes no series of its own — its liveness signal is the
# guest-attribute beacon, an unauthenticated PUT needing no IAM — so the host
# half is dropped there, and with it a pull request's ability to forge the
# demand metric the autoscaler reads. The CONTROLLER's grant below is untouched.
resource "google_project_iam_member" "metrics" {
  count = local.host_grants

  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_project_iam_member" "controller_metrics" {
  count = var.create_controller_service_account ? 1 : 0

  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.controller[0].email}"
}

resource "google_project_iam_member" "logs" {
  count = local.host_grants

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_project_iam_member" "controller_logs" {
  count = var.create_controller_service_account ? 1 : 0

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.controller[0].email}"
}

# The controller deletes hosts; that is the entire scale-in mechanism, since no
# autoscaler is permitted to choose a victim.
#
# This lands on the CONTROLLER account, never the hosts' — see the comment on
# google_service_account.controller. When the split is disabled the two
# collapse and the grant is back on the host account, which is why disabling it
# is documented as a migration step and not a supported end state.
#
# roles/compute.instanceAdmin.v1 is broader than "delete instances in one MIG"
# — GCP has no predefined role that narrow. Where it matters, replace this with
# a custom role limited to compute.instances.delete /
# compute.instanceGroupManagers.update and pass grant_compute_admin = false.
resource "google_project_iam_member" "compute" {
  count   = var.grant_compute_admin ? 1 : 0
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${local.controller_email}"
}

# The drain checks for live Runner.Worker processes over
# `gcloud compute ssh --tunnel-through-iap` (controller-startup.sh) before it
# deletes a host. That call needs iap.tunnelInstances.accessViaIAP, which
# roles/compute.instanceAdmin.v1 does NOT include — so without this grant the
# SSH fails, its failure is suppressed, the worker list comes back empty, and
# the controller deletes the host having verified nothing. The pools that
# predate the identity split carried the permission on the old runner account
# and lost it when the controller moved to its own.
resource "google_project_iam_member" "controller_iap_tunnel" {
  count   = var.grant_compute_admin ? 1 : 0
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${local.controller_email}"
}

# Deliberately NOT granted here: storage, artifact registry, deploy, or any
# data-plane role. A pipeline that needs one asks for it explicitly in the
# consuming stack, where the grant is visible in that repo's review.

# --- job identity ---------------------------------------------------------------
#
# The account above is the HOST's, and job code never gets it: hosts fence job
# code off the metadata server precisely because that account reads the App key.
# What a job's `gcloud` sees instead is this account, vended over loopback by the
# host's credential broker.
#
# It starts with NO grants at all. Every permission a workflow needs — push an
# image, submit a build, describe a service — is granted to THIS account in the
# consuming stack, where a reviewer sees exactly what CI can do.
resource "google_service_account" "job" {
  count = var.create_job_service_account ? 1 : 0

  project = var.project_id
  # GCP caps an account id at 30 characters, and `-job` costs four of them, so
  # a pool whose runner account is already long (ci-runner-host-dataretrival)
  # would otherwise fail validation at plan time and block the whole pool.
  account_id   = "${substr(var.account_id, 0, min(26, length(var.account_id)))}-job"
  display_name = "CI job identity (${var.name})"
  description  = "Identity handed to CI JOB code by the host credential broker. Deliberately weaker than the host account: it cannot read the GitHub App key or delete hosts."
}

# --- state moves ----------------------------------------------------------------
#
# The three host grants above became conditional, which adds an index to their
# addresses. Terraform reads `X` and `X[0]` as two different objects, so without
# these it would plan a DESTROY and a CREATE of working IAM on the next apply of
# every pool that exists — a window in which a live host cannot read the App key
# and cannot register, from a change meant to leave Linux alone. With them a
# Linux pool plans zero resource changes: one no-op move each, `host_grants`
# still 1. Deleting them later re-opens that window for anyone who has not
# applied since.
moved {
  from = google_secret_manager_secret_iam_member.runner_reads_key
  to   = google_secret_manager_secret_iam_member.runner_reads_key[0]
}

moved {
  from = google_project_iam_member.metrics
  to   = google_project_iam_member.metrics[0]
}

moved {
  from = google_project_iam_member.logs
  to   = google_project_iam_member.logs[0]
}

# And the App-key secret, for the same reason and with a sharper edge: it
# carries `prevent_destroy`, so a pool that has applied before would not merely
# see a destroy-and-create planned for it — it would see an apply that REFUSES,
# naming a lifecycle rule, on a change that was meant to leave it alone.
moved {
  from = google_secret_manager_secret.app_key
  to   = google_secret_manager_secret.app_key[0]
}
