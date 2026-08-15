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

variable "network" {
  type        = string
  description = "Network for the build VM. Empty = infer from the subnetwork."
  default     = ""
}

variable "network_tags" {
  type        = list(string)
  description = <<-EOT
    Network tags the build VM carries. These MUST include the tag the project's
    IAP-SSH firewall rule targets — the build VM has no external IP (org policy
    compute.vmExternalIpAccess=DENY across this fleet), so Packer reaches it
    only through the IAP tunnel, and an untagged VM is simply unreachable.
  EOT
  default     = []
}

variable "image_storage_locations" {
  type        = list(string)
  description = <<-EOT
    Where the produced image is STORED. Empty lets GCE choose, and its choice is
    a multi-region ("eu") that `constraints/gcp.resourceLocations` rejects in
    these projects — the build then runs to completion and fails only at image
    creation, wasting the whole run. Pass the build region.
  EOT
  default     = []
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
  # GitHub hard-blocks deprecated agents: a stale one registers, prints
  # "Listening for Jobs", then dies with "Forbidden Runner version ... is
  # deprecated and cannot receive messages" — so the pool looks healthy while
  # every slot is offline. Bump this and rebuild the image; --disableupdate
  # means the host never self-heals.
  default     = "2.336.0"
}

variable "source_image_family" {
  type    = string
  default = "ubuntu-2404-lts-amd64"
}

variable "node_major" {
  type        = string
  description = <<-EOT
    Major version of the SYSTEM node installed on PATH. This is not a build
    toolchain — repositories still pin their own via actions/setup-node. It
    exists because a large share of marketplace actions install a shell shim
    with `#!/usr/bin/env node` (pnpm/action-setup's `pnpm`,
    hashicorp/setup-terraform's `terraform` wrapper) and then invoke it from a
    `run:` step. The runner's own bundled node is deliberately NOT on PATH, so
    on a host without a system node every one of those shims dies with
    "/usr/bin/env: 'node': No such file or directory" and exit 127.
  EOT
  default     = "22"
}

variable "warm_cache_script" {
  type        = string
  description = <<-EOT
    OPTIONAL path to a repo-supplied script that pre-populates dependency
    caches (module downloads, base images, package archives). It runs inside
    the build VM as root and must be idempotent and network-only — it may
    download, it must not embed credentials or customer data.

    Warm a FILESYSTEM cache, not a docker image cache: each slot runs its own
    rootless daemon with its own data root under the slot user's home, so
    images pulled here into the build VM's root-owned /var/lib/docker are
    invisible to every one of them. Pre-pulling would cost build minutes and
    disk for nothing.

    A container image therefore has to be baked as a FILE, which is the one
    form every slot can read: `docker save` it into /opt/ci-images/ and
    host-startup.sh's load_baked_images() loads it into each slot's daemon at
    boot. That directory is root-owned and read-only to slots, deliberately —
    it is not part of /opt/ci-cache, which reaches every slot as a writable
    per-slot copy, because its contents are executed rather than read. `warm-cache/playwright.sh` is that pattern, for pools that run
    browser tests.

    Empty = build a toolchain-only image.
  EOT
  default     = ""
}

source "googlecompute" "host" {
  project_id          = var.project_id
  zone                = var.zone
  network             = var.network != "" ? var.network : null
  subnetwork          = var.subnetwork
  tags                = var.network_tags
  source_image_family = var.source_image_family

  # OS Login is enforced by org policy (compute.requireOsLogin), which makes
  # metadata SSH keys inert — a metadata-key build would hang until it timed
  # out. With this, Packer authenticates as the builder's own service account
  # and the provisioners' `sudo` needs that identity to hold osAdminLogin.
  use_os_login = true

  # Required by the plugin even under OS Login, which then replaces it with the
  # POSIX account name of the builder's service account.
  ssh_username = "packer"

  machine_type        = "n2-standard-8"
  disk_size           = 200
  disk_type           = "pd-balanced"

  # No external IP, ever. `compute.vmExternalIpAccess` is DENY org-wide here, so
  # a build VM that asks for one is rejected at create time — the build fails
  # before a single provisioner runs. Egress still works: these VPCs peer to the
  # landing-zone VPC and leave through the central firewall, which is how the
  # runner hosts themselves reach GitHub without a Cloud NAT.
  omit_external_ip = true

  # Consequences of the line above: connect to the internal address, and get to
  # it through the IAP tunnel, because the builder is not inside the VPC.
  use_internal_ip = true
  use_iap         = true

  image_name        = "${var.image_family}-${var.image_version}"
  image_family      = var.image_family
  image_storage_locations = var.image_storage_locations
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
  #
  #    python3-pip and python3-venv are here for the same reason node and
  #    PowerShell are below: a GitHub-hosted image has them, so workflows install
  #    their python tooling with a bare `python3 -m pip install --user …` (CI
  #    security scanners in particular — semgrep, checkov). Ubuntu ships python3
  #    WITHOUT the pip module, so on a host that only has the interpreter that
  #    line fails with "No module named pip" and the whole job stops.
  #
  #    python3-yaml is explicit for the opposite reason: it is ALREADY present,
  #    but only because cloud-init depends on it. The merge-queue gate the
  #    consuming repositories run (`scripts/ci/check-merge-queue-single-step.sh`)
  #    needs it and deliberately installs nothing, so naming it here is what
  #    stops a base-image change from turning a required check red fleet-wide.
  provisioner "shell" {
    inline = [
      "set -eux",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update -qq",
      "apt-get install -y -qq curl jq git openssl ca-certificates gnupg unzip rsync python3-pip python3-venv python3-yaml",
      # PEP 668: Ubuntu 24.04 marks its system python EXTERNALLY-MANAGED, so
      # even with pip installed, `python3 -m pip install …` aborts with "This
      # environment is externally managed" — a DIFFERENT failure from the
      # missing-module one above, and the one DataRetrival's lint job hit on the
      # v3-8-0 image. A GitHub-hosted image does not carry that marker, and the
      # workflows in this fleet are written against that behaviour.
      #
      # A host is a disposable CI worker rebuilt from this image, not a machine
      # whose system python has to survive a job, so the risk PEP 668 protects
      # against does not apply here. Configured rather than deleting the marker
      # so the reason stays visible on the box.
      "printf '[global]\\nbreak-system-packages = true\\n' > /etc/pip.conf",
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
      # Rootless prerequisites. Each slot runs its OWN daemon as its own user
      # (see host-startup.sh): newuidmap/newgidmap from uidmap give it a user
      # namespace, slirp4netns gives it networking, fuse-overlayfs gives it a
      # usable storage driver without root.
      "apt-get install -y -qq uidmap slirp4netns fuse-overlayfs dbus-user-session docker-ce-rootless-extras",
      # Ubuntu 24.04 restricts unprivileged user namespaces by AppArmor profile;
      # with the restriction on, rootlesskit dies at start with "Operation not
      # permitted" and every slot's daemon is down. Unprivileged low ports are
      # allowed because service containers routinely publish 80/443 in CI.
      "printf 'kernel.apparmor_restrict_unprivileged_userns=0\\nnet.ipv4.ip_unprivileged_port_start=0\\n' > /etc/sysctl.d/99-ci-rootless.conf",
      # The SHARED daemon is disabled here and masked at boot. A job that can
      # reach /var/run/docker.sock owns every other slot on the host — the
      # exposure per-slot daemons exist to remove (#10). The CLI, buildx and
      # compose plugins stay: they talk to whatever DOCKER_HOST points at.
      "systemctl disable docker.service docker.socket || true",
      # Shared warm cache: readable and writable through the `ci` group, which
      # every slot user joins at boot. Slot HOMES are not shared — that sharing
      # is what raced pnpm's store between concurrent slots.
      "groupadd -f ci",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 3. System node.
  #
  #    GitHub-hosted images ship node on PATH, so marketplace actions assume it
  #    and install `#!/usr/bin/env node` shims that a `run:` step then calls.
  #    The runner agent bundles its own node under externals/, but that copy is
  #    intentionally not on PATH — actions run against it via the agent, shims
  #    do not. Without this layer:
  #      pnpm/action-setup      -> "exec: node: not found",           exit 127
  #      hashicorp/setup-terraform (terraform_wrapper: true)
  #                             -> "/usr/bin/env: 'node': No such file", 127
  #    Observed 2026-08-13 on DataRetrival (typecheck, lint) and
  #    Telnet-Emulation (terraform fmt) the first time those repos ran on warm
  #    hosts. This is a HOST BASELINE, not a toolchain choice: repositories
  #    still select their build node with actions/setup-node, which prepends
  #    its own to PATH.
  provisioner "shell" {
    inline = [
      "set -eux",
      "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg",
      "chmod a+r /etc/apt/keyrings/nodesource.gpg",
      "echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${var.node_major}.x nodistro main\" > /etc/apt/sources.list.d/nodesource.list",
      "apt-get update -qq",
      "apt-get install -y -qq nodejs",
      # corepack is what makes `pnpm`/`yarn` resolvable when a repo does not run
      # a setup action at all; harmless when it does.
      "corepack enable || true",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 4. PowerShell.
  #
  #    Also part of the GitHub-hosted baseline, and equally assumed: a workflow
  #    may declare `shell: pwsh`, and a test suite may drive a .ps1 script
  #    directly. Apigee-Portal's `Unit tests (packages)` failed 2026-08-13 with
  #    "No PowerShell interpreter found (tried pwsh, powershell.exe,
  #    powershell)" — and by design it does NOT skip when the interpreter is
  #    missing, because the script under test guards an auto-approved
  #    production apply.
  provisioner "shell" {
    inline = [
      "set -eux",
      "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg",
      "chmod a+r /etc/apt/keyrings/microsoft.gpg",
      "echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/$(. /etc/os-release && echo $VERSION_ID)/prod $(. /etc/os-release && echo $VERSION_CODENAME) main\" > /etc/apt/sources.list.d/microsoft-prod.list",
      "apt-get update -qq",
      "apt-get install -y -qq powershell",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 5. The runner account and the agent itself.
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
      "mkdir -p /opt/ci/slots && chown -R runner:runner /opt/ci",
      # /opt/ci-cache is the READ-ONLY master cache, root-owned and writable by
      # nobody. It is never a slot's working cache: each slot gets its own copy
      # under /var/lib/ci-cache/<idx> at boot, because a tree several slot users
      # can write is a channel by which one job hands another job code to run —
      # `npx` executes out of the npm cache, Maven skips checksums for an
      # artifact already in the local repository, pip does not re-hash a cached
      # wheel. See host-startup.sh's "the dependency cache" section.
      "mkdir -p /opt/ci-cache && chown -R root:root /opt/ci-cache",
      "chmod 0755 /opt/ci-cache",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 6. Repo-supplied cache warming. Optional, and deliberately the LAST layer:
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

  # 6b. Seal the master cache AFTER warming.
  #
  #     A consumer's warm script is arbitrary repo-supplied code running as root,
  #     so what it leaves behind is not assumed: the tree is re-owned to root and
  #     stripped of every write bit here, which is the state host-startup.sh
  #     expects to find and copies from. Root ignores the missing write bit, so a
  #     later warming layer still works; a slot user has read and traverse only.
  #
  #     The scan below is a real gate, and it is written the long way on purpose.
  #     The obvious one-liner — `! find ... | grep -q .` — CANNOT fail a build:
  #     `set -e` is defined to ignore the status of any command whose value is
  #     inverted with `!`, and without `pipefail` a find that errors passes too.
  #     So it would read as a guard, log as a guard, and ship the image anyway.
  #     Capturing the output and testing it is what makes the build actually stop.
  #
  #     What it looks for is everything the two lines after it would PROPAGATE:
  #     `chmod -R go+rX` widens permissions, so a hardlink to a file outside the
  #     tree gets that file made world-readable in place; `cp -a` on the host
  #     preserves xattrs, so a file capability would be handed to every slot. See
  #     host-startup.sh's cache_master_is_hostile(), which repeats this at boot
  #     because an image is not the only way content reaches this tree.
  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      "bad=$(find /opt/ci-cache \\( -type l -o -type b -o -type c -o -type p -o -type s -o -perm /6000 -o \\( -type f -a -links +1 \\) \\) -print -quit)",
      "[ -z \"$bad\" ] || { echo \"warm cache holds a link, node or setuid entry: $bad\" >&2; exit 1; }",
      # No pipe into head: under pipefail, head closing the pipe early can SIGPIPE
      # getcap and abort the build over a cache that was perfectly fine.
      "command -v getcap >/dev/null || { echo 'getcap missing: cannot scan the warm cache for file capabilities' >&2; exit 1; }",
      "bad=$(getcap -r /opt/ci-cache 2>/dev/null)",
      "[ -z \"$bad\" ] || { echo \"warm cache holds a file capability: $bad\" >&2; exit 1; }",
      "chown -Rh root:root /opt/ci-cache",
      # go-w, not a-w. The tree is root-owned, so the OWNER write bit protects
      # nothing (root ignores it) — but the host copies this tree per slot with
      # `cp -a`, which preserves mode, so stripping it would bake a cache no slot
      # can write into. go+rX gives back traversal and read without making a data
      # file executable (X is directory-or-already-executable).
      "chmod -R go-w,go+rX /opt/ci-cache",

      # Baked image archives live in /opt/ci-images, NOT under /opt/ci-cache,
      # and the separation is the control rather than a tidiness choice.
      #
      # Every archive there is `docker load`ed into every slot's daemon at
      # boot, so it is EXECUTED, not read — while /opt/ci-cache is untrusted
      # build input by design (README: "a warm cache is untrusted build
      # input"), reaches every slot as a per-slot WRITABLE copy, and is the
      # tree a snapshot hydrates into. Making the archives root-owned INSIDE
      # that tree is not enough: a copy carries them into a directory the slot
      # owns, and write+execute on a non-sticky parent lets a job rename the
      # whole directory away and put its own — with a matching SHA256SUMS — in
      # its place, supplying both halves of the check. Ownership of an entry
      # never protects it from the permissions of the directory holding it.
      #
      # So the archives sit in their own root-owned tree that is never copied
      # per slot. Nothing at runtime writes here; they are produced at bake
      # time, by the warm script, as root.
      "if [ -d /opt/ci-images ]; then chown -R root:root /opt/ci-images && chmod 0755 /opt/ci-images && find /opt/ci-images -type f -exec chmod 0644 {} + ; fi",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 7. Assert the host baseline, as the runner user and with the runner's PATH.
  #
  #    A missing baseline tool does not fail an image build — it fails every job
  #    on every host that boots the image, hours later, as an opaque exit 127.
  #    That is exactly how the node gap reached five repositories at once. Each
  #    entry below is a binary some marketplace action or workflow step invokes
  #    from a `run:` shell, so losing one is a fleet outage; catch it here.
  provisioner "shell" {
    inline = [
      "set -eux",
      "for b in node npm pwsh python3 git jq curl unzip rsync openssl docker; do sudo -u runner -i command -v $b >/dev/null || { echo \"MISSING from runner PATH: $b\"; exit 1; }; done",
      "sudo -u runner -i node --version",
      # pip is a MODULE, not a binary on PATH — `command -v pip3` can succeed on
      # a host where `python3 -m pip` (what workflows actually write) does not.
      "sudo -u runner -i python3 -m pip --version",
      # PyYAML arrives with cloud-init even when nothing names it, so a host can
      # pass every other assertion here and still fail the merge-queue gate in
      # fourteen repositories. Imported, not apt-queried: what matters is that
      # the interpreter a job runs can load it.
      "sudo -u runner -i python3 -c 'import yaml'",
      # `pip --version` succeeds on an EXTERNALLY-MANAGED host — only an INSTALL
      # path proves the PEP 668 block is lifted. Asserted by driving pip down
      # that path and rejecting only the PEP 668 refusal: --no-index means the
      # package is never resolved, so this needs no PyPI egress and installs
      # nothing into the image. Any other failure (including "no matching
      # distribution", which is the expected outcome) is fine.
      "sudo -u runner -i python3 -m pip install --user --dry-run --no-index ci-host-pep668-probe 2>&1 | tee /tmp/pep668 || true",
      "if grep -qi 'externally managed' /tmp/pep668; then echo 'PEP 668 still blocks pip install'; exit 1; fi; rm -f /tmp/pep668",
      # The shim shape that actually broke: resolved through env, as a script's
      # interpreter is, not as a login-shell builtin.
      "printf '#!/usr/bin/env node\\nconsole.log(\"shim ok\")\\n' > /tmp/shim && chmod +x /tmp/shim && sudo -u runner /tmp/shim && rm -f /tmp/shim",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 7b. Prove a rootless daemon actually STARTS on this image.
  #
  #     Presence of dockerd-rootless.sh proves nothing: the failure mode here is
  #     that the binary is installed and the daemon still dies at start because a
  #     kernel knob (AppArmor's unprivileged-userns restriction), a setuid helper
  #     (newuidmap) or a subuid range is missing. That failure surfaces hours
  #     later as every slot on every host having no container runtime at all —
  #     i.e. a fleet outage, delivered by an image build that reported success.
  #     So start one here, as an unprivileged user, and ask it a question.
  provisioner "shell" {
    inline = [
      "set -eux",
      "for b in /usr/bin/dockerd-rootless.sh /usr/bin/newuidmap /usr/bin/newgidmap /usr/bin/slirp4netns /usr/bin/fuse-overlayfs; do [ -x $b ] || { echo \"MISSING: $b\"; exit 1; }; done",
      # The sysctl file is written for the hosts; apply it here too, otherwise
      # this probe tests a kernel configured differently from the one it ships.
      "sysctl --system >/dev/null",
      "useradd -m ci-rootless-probe || true",
      "grep -q '^ci-rootless-probe:' /etc/subuid || echo 'ci-rootless-probe:900000:65536' >> /etc/subuid",
      "grep -q '^ci-rootless-probe:' /etc/subgid || echo 'ci-rootless-probe:900000:65536' >> /etc/subgid",
      "install -d -o ci-rootless-probe -g ci-rootless-probe -m 0700 /run/ci-rootless-probe",
      "setsid sudo -u ci-rootless-probe env HOME=/home/ci-rootless-probe XDG_RUNTIME_DIR=/run/ci-rootless-probe PATH=/usr/bin:/usr/sbin:/bin:/sbin /usr/bin/dockerd-rootless.sh > /tmp/rootless.log 2>&1 < /dev/null &",
      "ok=0; for i in $(seq 1 30); do if sudo -u ci-rootless-probe env DOCKER_HOST=unix:///run/ci-rootless-probe/docker.sock docker info >/dev/null 2>&1; then ok=1; break; fi; sleep 2; done",
      "if [ \"$ok\" != 1 ]; then echo 'rootless dockerd did not come up on this image:'; cat /tmp/rootless.log; exit 1; fi",
      "pkill -u ci-rootless-probe || true; sleep 2; userdel -r ci-rootless-probe || true; rm -rf /run/ci-rootless-probe /tmp/rootless.log",
      "sed -i '/^ci-rootless-probe:/d' /etc/subuid /etc/subgid",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # 8. Leave no build identity behind. The build VM's SSH user, logs and
  #    machine-id must not be part of an artifact that N hosts boot from.
  provisioner "shell" {
    inline = [
      "set -eux",
      "apt-get clean",
      # Every home, not /home/packer: under OS Login the build user is named
      # after the builder's service account, so a hardcoded name would leave the
      # build identity's authorized_keys inside an image N hosts boot from.
      "rm -rf /var/lib/apt/lists/* /home/*/.ssh /root/.ssh /var/log/*.log",
      "truncate -s 0 /etc/machine-id",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }
}
