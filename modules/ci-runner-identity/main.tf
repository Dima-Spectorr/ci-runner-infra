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
}

resource "google_secret_manager_secret" "app_key" {
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

# Only this pool's identity may read the App key.
resource "google_secret_manager_secret_iam_member" "runner_reads_key" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.app_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

# Publishing the demand metric is what makes the pool scale out at all, and
# publishing the telemetry series is what makes it observable.
resource "google_project_iam_member" "metrics" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_project_iam_member" "logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

# The controller deletes hosts; that is the entire scale-in mechanism, since no
# autoscaler is permitted to choose a victim.
#
# roles/compute.instanceAdmin.v1 is broader than "delete instances in one MIG"
# — GCP has no predefined role that narrow. Where it matters, replace this with
# a custom role limited to compute.instances.delete /
# compute.instanceGroupManagers.update and pass grant_compute_admin = false.
resource "google_project_iam_member" "compute" {
  count   = var.grant_compute_admin ? 1 : 0
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

# Deliberately NOT granted here: storage, artifact registry, deploy, or any
# data-plane role. A pipeline that needs one asks for it explicitly in the
# consuming stack, where the grant is visible in that repo's review.
