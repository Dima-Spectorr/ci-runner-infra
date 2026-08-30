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

variable "create_app_key_secret" {
  description = <<-EOT
    Create the App-key secret named by `app_key_secret_id`, rather than pointing
    at one another root already owns.

    Leave true for a pool that is the first in its project. Set it false for a
    SECOND identity in a project whose key already exists, where creating one
    would mean a second empty secret — and, because the secret carries
    `prevent_destroy`, one Terraform can never take back.

    The case it exists for is a Windows pool. A Windows host account is stripped
    of the App-key read (`host_os`), and a Windows pool requires the CONTROLLER
    to mint registration tokens, so nothing the identity creates ever reads the
    key: the secret would be created empty, never given a version, never read,
    and never removable. False makes the identity point at the key the project's
    existing pool already has, which is also the key the shared controller
    already reads.

    Set it false and the grants this module writes land on a secret it does not
    manage. That is the intent — but nothing here can check the secret exists,
    so a typo in `app_key_secret_id` is a 404 at apply time on a plan that read
    clean, not a plan-time error.
  EOT
  type        = bool
  default     = true
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

variable "create_controller_service_account" {
  description = <<-EOT
    Create a separate `<account_id>-ctl` identity for the pool CONTROLLER, and
    put roles/compute.instanceAdmin.v1 on it instead of the host account.

    Leave true. Setting false collapses the controller back onto the host
    account, which puts instance-deletion rights on every machine that executes
    pull-request code: job code escaping the container fence could delete the
    pool it runs on, other repositories' hosts included. It exists only so a
    project mid-migration can apply the module before its root passes
    `controller_service_account_email` through to `ci-runner-host-pool` — not
    as a supported end state.
  EOT
  type        = bool
  default     = true
}

variable "host_os" {
  description = <<-EOT
    Operating system of the HOSTS this identity serves: "linux" or "windows".
    It selects how much the HOST account is allowed to hold, and nothing else —
    the controller account is identical either way.

    linux (the default, and unchanged from every pool that exists today): the
    host account reads the App key from Secret Manager to mint its own runner
    registration tokens, and writes metrics and logs. That is safe because a
    Linux host fences job code off the metadata server by iptables owner-match,
    so job code cannot mint a token for this account at all.

    windows: there is no such fence, and no mechanism to build one — Windows
    Firewall resolves an explicit block ahead of every conflicting allow,
    `-Service` carries no precedence, and the one documented override needs
    IPsec the metadata server does not speak. Job code therefore reaches the
    metadata server and can mint an access token for whatever this account is.
    So the account is reduced to nothing worth stealing: only
    `roles/iam.serviceAccountTokenCreator` on the job account, which
    ci-runner-host-pool grants and which the broker was going to vend to job
    code anyway. The registration token is minted by the CONTROLLER instead —
    set `controller_mints_registration_token` on the pool.

    Terraform cannot see what IAM a caller's account holds elsewhere, so this is
    a declaration, not an enforcement. The enforcement is the host's own boot
    probe, which asserts a 403 on the secret from the token it is given — that
    probe ships with the Windows host template and does not exist yet, so until
    it does, `host_os = "windows"` reduces the grants this module writes and
    proves nothing about grants written anywhere else.
  EOT
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.host_os)
    error_message = "host_os must be \"linux\" or \"windows\"."
  }
}

variable "labels" {
  description = "Extra labels for the secret."
  type        = map(string)
  default     = {}
}

variable "create_job_service_account" {
  description = <<-EOT
    Create the weak identity that JOB code runs as (`<account_id>-job`). Leave
    true unless the project already has one: without it, a pool has nothing safe
    to hand jobs, and the only way to make `gcloud` work in a workflow becomes
    removing the metadata fence.
  EOT
  type        = bool
  default     = true
}
