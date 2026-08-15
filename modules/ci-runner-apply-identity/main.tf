# ci-runner-apply-identity — the identity an UNATTENDED terraform apply runs as.
#
# `apply-runner-pool.yml` needs an identity, and the obvious ones are both wrong.
#
# Not the RUNTIME account: a runtime SA is bound to what the application may
# touch. Handing it authority to rebuild the compute the application runs on
# inverts that relationship, and gives a data-plane credential a control-plane
# blast radius.
#
# Not a full infra-admin account either, which is the interesting half.
#
# THE CONSTRAINT THAT SHAPES THIS MODULE: this identity is assumable by a
# GitHub Actions run. Everything it can do, a workflow file can do. The runner
# root creates service accounts and project IAM bindings, so an identity able to
# apply that root END TO END would hold `resourcemanager.projectIamAdmin` —
# which is "can grant itself owner". Reachable from CI, in a fleet whose pull
# requests auto-merge on green, that is a path from "opened a pull request" to
# project owner, and no amount of care in the workflow closes it.
#
# So this account is deliberately INCOMPLETE. It can rebuild compute — instance
# templates, the managed instance group, the autoscaler — and it cannot create a
# service account or change an IAM policy. That is not a reduced version of the
# job; it is the whole job, because of how the modules are split:
#
#   ci-runner-identity   changes almost never. It EXISTS to survive pool
#                        replacement, which is the reason it is a separate
#                        module at all.
#   ci-runner-host-pool  is what every release changes, and it is compute.
#
# A release therefore plans clean on identity and rebuilds the pool, which is
# exactly what this account can do.
#
# WHEN AN IDENTITY CHANGE DOES SHIP, THIS ACCOUNT FAILS. That is the design, not
# a gap. The apply stops with a permission error, red, naming the resource — and
# a human runs that one apply. The alternative is an account that never needs a
# human and can also grant itself anything; a loud failure on the rare case is
# cheaper than a silent capability on every case.
#
# Read access is granted broadly enough to REFRESH those resources, because
# terraform refreshes everything in state before it plans anything. An account
# that cannot read the service accounts cannot plan the pool either, and would
# fail on every run rather than only the ones that change identity.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

resource "google_service_account" "apply" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = "CI runner pool apply (${var.name})"
  description  = "Identity for the unattended terraform apply of the runner pool. Deliberately cannot create service accounts or change IAM policy: it is assumable from GitHub Actions, so anything it can do, a workflow file can do."
}

# --- what it may CHANGE ---------------------------------------------------------
#
# Compute, and nothing else.
#
# roles/compute.admin is broader than "manage one managed instance group" — GCP
# ships no predefined role that narrow, and the pool legitimately needs instance
# templates, the group, the autoscaler and the instances themselves. It is
# bounded in the direction that matters: compute.admin cannot grant IAM, cannot
# create identities, and cannot read a secret's value.
resource "google_project_iam_member" "compute" {
  project = var.project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.apply.email}"
}

# Attaching a service account to an instance template is itself a permission,
# and without it every apply fails at the template — the one resource every
# release changes.
#
# Scoped to the pool's OWN accounts, not granted project-wide: actAs on the
# project would let this identity attach ANY service account in the project to
# an instance it creates, which is the standard escalation from compute.admin to
# whatever the most privileged account in the project can do. The list is an
# input precisely so that a reviewer sees which identities are in reach.
resource "google_service_account_iam_member" "act_as" {
  for_each = toset(var.impersonable_service_accounts)

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.apply.email}"
}

# --- what it may only READ ------------------------------------------------------
#
# Terraform refreshes every resource in state before planning any of them, so
# "cannot change identity" still requires "can read identity". These four roles
# are read-only by construction; none carries a set/create/delete permission.

# google_service_account.* — refresh, plus getIamPolicy for the bindings on them.
resource "google_project_iam_member" "read_service_accounts" {
  project = var.project_id
  role    = "roles/iam.serviceAccountViewer"
  member  = "serviceAccount:${google_service_account.apply.email}"
}

# google_project_iam_member.* — refresh calls projects.getIamPolicy. Read-only:
# securityReviewer is the role for auditing policy, and cannot set it.
resource "google_project_iam_member" "read_iam_policy" {
  project = var.project_id
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${google_service_account.apply.email}"
}

# google_secret_manager_secret.* and its IAM. Metadata only —
# secretmanager.viewer does NOT include versions.access, so the App private key
# stays unreadable by the account that rebuilds the pool around it.
resource "google_project_iam_member" "read_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.apply.email}"
}

# --- terraform state ------------------------------------------------------------
#
# Bucket-scoped, never project-wide storage admin: the state bucket usually
# lives beside buckets holding build artifacts and caches, and a project-wide
# grant would hand CI write access to all of them to store one .tfstate.
resource "google_storage_bucket_iam_member" "state" {
  bucket = var.state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.apply.email}"
}

# --- who may assume it ----------------------------------------------------------
#
# THE principalSet IS THE SECURITY BOUNDARY, and it is the line most likely to
# be widened by someone in a hurry.
#
# A provider that maps only `attribute.repository` binds to the repository as a
# whole — every branch, every workflow file, including one pushed to a branch by
# anyone who can push. Branch protection does not help: the workflow that
# assumes this identity is the attacker's own file, running on their own branch,
# and it never goes near main.
#
# So the default binds `attribute.ref` to a single ref, and the module REFUSES a
# repository-wide binding rather than accepting it as a default. Adding
# `attribute.ref: assertion.ref` to a provider's mapping is additive — existing
# principalSets keep resolving — so "the provider does not map ref" is a
# one-command fix, not a reason to widen this.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${var.workload_identity_pool}/attribute.ref/${var.allowed_ref}"
}
