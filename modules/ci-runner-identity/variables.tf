variable "project_id" {
  description = "Project that owns the service account and the secret."
  type        = string
}

variable "name" {
  description = "Pool name, used in display names and labels."
  type        = string
}

variable "account_id" {
  description = <<-EOT
    Service account id (the local part of the email). Keep this STABLE across
    pool generations: project IAM bindings elsewhere refer to the email, and
    changing it silently strips a working pipeline of its access.
  EOT
  type        = string
}

variable "app_key_secret_id" {
  description = <<-EOT
    Secret Manager secret id for the GitHub App private key. The secret is
    created empty; the PEM is added out of band with
    `gcloud secrets versions add`, so no key material passes through Terraform
    state or a plan output.
  EOT
  type        = string
}

variable "grant_compute_admin" {
  description = <<-EOT
    Grant roles/compute.instanceAdmin.v1 so the controller can delete hosts —
    the pool's only scale-in path. Set false only when a narrower custom role
    is bound to this account elsewhere; with neither, the pool scales out and
    never back down.
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Extra labels for the secret."
  type        = map(string)
  default     = {}
}
