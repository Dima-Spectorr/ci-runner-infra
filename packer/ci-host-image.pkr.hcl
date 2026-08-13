# Golden CI host image.
#
# This image is the wall-time saving. A host booting from it already has the
# runner agent, the container runtime, the language toolchains and a pre-warmed
# dependency cache, so a job starts working within seconds of being assigned
# instead of after the boot + install + download sequence every job in this
# fleet currently repeats.
#
# ONE IMAGE, EVERY POOL. There is no per-repository image and no build flag
# that makes the image "the Print-Server image" or "the Apigee image". Anything
# a host needs to know about which repository it serves arrives as instance
# metadata at boot (see modules/ci-runner-host-pool/main.tf). Baking a repo,
# project, region or customer into this image would turn one artifact into N
# artifacts that drift apart — the exact failure that the vendored Terraform
# module produced across this fleet.
#
# Built by Cloud Build, never on a laptop.

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = ">= 1.1.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Project the image is built in and stored in."
}

variable "zone" {
  type        = string
  description = "Build zone."
}

variable "subnetwork" {
  type        = string
  description = "Subnetwork for the build VM."
}

variable "image_family" {
  type    = string
  default = "ci-runner-host"
}

variable "image_version" {
  type        = string
  description = "Version suffix, e.g. v3-0-0. Images are immutable; pools pin one."
}

variable "runner_version" {
  type        = string
  description = "GitHub Actions runner agent version to bake, without the leading v."
  default     = "2.319.1"
}

variable "source_image_family" {
  type    = string
  default = "ubuntu-2404-lts-amd64"
}

variable "warm_cache_script" {
  type        = string
  description = <<-EOT
    OPTIONAL path to a repo-supplied script that pre-populates dependency
    caches (module downloads, base images, package archives). It runs inside
    the build VM as root and must be idempotent and network-only — it may
    download, it must not embed credentials or customer data.

    Empty = build a toolchain-only image.
  EOT
  default     = ""
}

source "googlecompute" "host" {
  project_id          = var.project_id
  zone                = var.zone
  subnetwork          = var.subnetwork
  source_image_family = var.source_image_family
  ssh_username        = "packer"
  machine_type        = "n2-standard-8"
  disk_size           = 200
  disk_type           = "pd-balanced"

  image_name        = "${var.image_family}-${var.image_version}"
  image_family      = var.image_family
  image_description = "Warm CI host: runner agent + container runtime + toolchains + pre-warmed caches. Repo-agnostic; all identity arrives via instance metadata."

  image_labels = {
    component = "ci-runner-host-pool"
    managed   = "packer"
  }
}

build {
  name    = "ci-host"
  sources = ["source.googlecompute.host"]

  # 1. Base packages the host scripts assume exist.
  provisioner "shell" {
    inline = [
      "set -eux",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update -qq",
      "apt-get install -y -qq curl jq git openssl ca-certificates gnupg unzip rsync",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 2. Container runtime. Jobs run in containers, which is what replaces
  #    "destroy the VM" as the isolation boundary now that hosts are reused.
  provisioner "shell" {
    inline = [
      "set -eux",
      "install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "chmod a+r /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list",
      "apt-get update -qq",
      "apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "systemctl enable docker",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 3. The runner account and the agent itself.
  #
  #    Baked UNCONFIGURED: the tarball is extracted here, and each host copies
  #    it once per slot and runs config.sh at boot with a short-lived token. No
  #    credential, token or repository name is ever in the image.
  provisioner "shell" {
    inline = [
      "set -eux",
      "useradd -m -s /bin/bash runner || true",
      "usermod -aG docker runner",
      "mkdir -p /opt/actions-runner",
      "cd /opt/actions-runner",
      "curl -fsSL -o runner.tar.gz \"https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz\"",
      "tar xzf runner.tar.gz && rm runner.tar.gz",
      "./bin/installdependencies.sh",
      "chown -R runner:runner /opt/actions-runner",
      "mkdir -p /opt/ci/slots /opt/ci-cache && chown -R runner:runner /opt/ci /opt/ci-cache",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 4. Repo-supplied cache warming. Optional, and deliberately the LAST layer:
  #    everything above is identical for every consumer, so a change here does
  #    not invalidate the expensive layers.
  provisioner "shell" {
    # An empty list runs nothing, which is how "toolchain-only image" is
    # expressed without a second build definition.
    # Never an empty list: Packer validates this block at PREPARE time and
    # rejects "no scripts" outright, so "warm nothing" is a script that does
    # nothing rather than an absent one.
    scripts         = [var.warm_cache_script != "" ? var.warm_cache_script : "warm-cache/none.sh"]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 5. Leave no build identity behind. The build VM's SSH user, logs and
  #    machine-id must not be part of an artifact that N hosts boot from.
  provisioner "shell" {
    inline = [
      "set -eux",
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/* /home/packer/.ssh /root/.ssh /var/log/*.log",
      "truncate -s 0 /etc/machine-id",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }
}
