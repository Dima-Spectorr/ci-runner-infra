# Golden CI host image, Windows.
#
# The sibling of ci-host-image.pkr.hcl and the same bargain: a host booting from
# it already has the runner agent, the toolchains and the service host the boot
# script needs, so a job starts working within seconds of being assigned instead
# of after an install sequence every job would otherwise repeat. On this platform
# that sequence is minutes, not seconds — which is why the retired one-VM-per-job
# Windows pool cost what it cost.
#
# A SECOND SOURCE, NOT A MODE ON THE FIRST ONE. Section 1 of
# docs/adr-windows-pool.md decides this: an Ubuntu source block cannot express a
# WinRM communicator, and a template with a `mode` variable that switches OS is
# the polymorphic artifact the one-generic-binary rule exists to refuse. The
# Linux template stays Linux-only and this one stays Windows-only.
#
# ONE IMAGE, EVERY POOL. There is no per-repository image and no build flag that
# makes this "the signing image". Everything a host knows about which repository
# it serves arrives as instance metadata at boot
# (modules/ci-runner-host-pool/main.tf), and a pool needing an extra SDK
# contributes it MACHINE-WIDE through `warm_cache_script`, which runs last and is
# the only layer a consumer supplies. Baking a repository, project, region or
# customer in here would turn one artifact into N artifacts that drift apart.
#
# WHAT THE BOOT SCRIPT REQUIRES OF THIS IMAGE
#
# Not a wish list. Every path below is a `$script:` constant in
# modules/ci-runner-host-pool/scripts/windows-host-startup.ps1, and that script
# REFUSES TO BOOT when one is missing rather than installing it:
#
#   C:\ci\bin\ci-service-shim.exe   the service host (Install-BeaconService,
#                                   Install-BrokerService both Deny-Boot without it)
#   C:\ci\bin\python\python.exe     the broker's interpreter, at a fixed path so
#                                   the broker's identity cannot depend on PATH
#   C:\ci\bin\actions-runner        the UNCONFIGURED agent, copied per slot
#   C:\ci\image-version.txt         an integer, compared against the pool's
#                                   `ci-image-min-version` by Test-ImageVersion
#
# The boot script creates C:\ci, C:\ci\bin and C:\ci\slots itself and locks them
# in phase 1, so this image does not ACL them. It bakes no cache tree either:
# unlike Linux, a Windows host has no host-wide warm cache and no per-slot copy
# of one to read it (issue #150).
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
    Network tags the build VM carries. These MUST include the tag an IAP
    firewall rule targets, and on THIS template that rule has to allow tcp:5986
    from the IAP forwarding range, not tcp:22 — the build VM has no external IP
    (org policy compute.vmExternalIpAccess=DENY across this fleet), Packer
    reaches it only through the IAP tunnel, and the tunnel carries WinRM here.
    A project whose IAP rule was written for the Linux image opens the wrong
    port, and the build fails as a WinRM timeout that names nothing.
  EOT
  default     = []
}

variable "image_storage_locations" {
  type        = list(string)
  description = <<-EOT
    Where the produced image is STORED. Empty lets GCE choose, and its choice is
    a multi-region that `constraints/gcp.resourceLocations` rejects in these
    projects — the build then runs to completion and fails only at image
    creation, wasting the whole run, which on this platform is the longer run of
    the two. Pass the build region.
  EOT
  default     = []
}

variable "image_family" {
  type        = string
  description = <<-EOT
    A family of its own, never the Linux one. A family points at its newest
    member, so sharing one would mean a pool tracking `ci-runner-host` could be
    handed a Windows image by nothing more than build order.
  EOT
  default     = "ci-runner-host-win"
}

variable "image_version" {
  type        = string
  description = "Version suffix, e.g. v1-0-0. Images are immutable; pools pin one."
}

variable "image_contract_version" {
  type        = string
  description = <<-EOT
    The integer written to C:\ci\image-version.txt, and a DIFFERENT thing from
    `image_version` above: that one names the artifact, this one states which
    contract the artifact satisfies. Test-ImageVersion in the boot script reads
    this file, refuses anything non-numeric, and compares it against the pool's
    `ci-image-min-version` metadata — so a host booted on an image predating a
    component the script now assumes fails at phase 0, by name, instead of
    hours later at the first service install.

    Bump it in the same pull request that adds a component the boot script may
    then assume; raising a pool's floor before an image carrying that number
    exists is how a fleet stops booting.
  EOT
  default     = "1"
}

variable "runner_version" {
  type        = string
  description = "GitHub Actions runner agent version to bake, without the leading v."
  # Deliberately the same default as the Linux template, and for the same
  # reason: GitHub hard-blocks deprecated agents, so a stale one registers,
  # prints "Listening for Jobs" and then dies with "Forbidden Runner version ...
  # is deprecated" — the pool looks healthy while every slot is offline. It
  # matters more here: --disableupdate means the host never self-heals, and a
  # Windows host takes K slots down at once rather than one short-lived VM.
  default = "2.336.0"
}

variable "source_image_family" {
  type        = string
  description = <<-EOT
    Windows Server WITH Desktop Experience, not Server Core. `windows-2022` is
    the Desktop family in `windows-cloud`; `windows-2022-core` is the Core one.
    Chosen deliberately: CI job code on this fleet is written against
    GitHub-hosted `windows-latest`, which is a Desktop Experience image, and the
    installers and test runners that assume a GUI subsystem is present fail on
    Core in ways that read as repository faults. The Core image is smaller; the
    difference is disk, and disk is the cheapest thing in this system.
  EOT
  default     = "windows-2022"
}

variable "source_image_project_id" {
  type        = string
  description = <<-EOT
    Where the source family lives. Named explicitly rather than left to the
    plugin's default, which searches the BUILD project first — and a project
    that happens to hold an image family of the same name would silently become
    the base of every Windows host in the fleet.
  EOT
  default     = "windows-cloud"
}

variable "winrm_username" {
  type        = string
  description = <<-EOT
    The account Packer authenticates as. It is created by the GCE guest agent
    during the build and exists only for the length of it; the account and its
    profile are removed by the last provisioner, because an artifact N hosts
    boot from must not carry the build identity.

    No password anywhere in this file. The googlecompute plugin generates one
    per build (`winrm_password` left unset), hands GCE an RSA public key and
    decrypts what comes back, and registers the value with Packer's secret
    filter so it does not reach the log.
  EOT
  default     = "packer_user"
}

variable "powershell_version" {
  type        = string
  description = <<-EOT
    PowerShell 7, and it is a HOST BASELINE rather than a toolchain choice: the
    Actions runner's default shell on Windows is `pwsh`, so on a host without it
    every `run:` step in every workflow fails before it executes a line. Windows
    PowerShell 5.1 is in the box and is what the boot script and the services
    run under; it is not `pwsh` and does not satisfy a workflow that asked for
    one.

    Even-numbered releases are the LTS line (7.4, 7.6), which is why this tracks
    7.6 rather than the newest number available.
  EOT
  default     = "7.6.5"
}

variable "python_version" {
  type        = string
  description = <<-EOT
    The interpreter the job credential broker runs under, installed at
    C:\ci\bin\python and deliberately NOT on PATH — the boot script fixes that
    path so the broker's identity cannot change because a later image layer
    installed a different python. Repositories that need python for a job use
    actions/setup-python, which brings its own.

    scripts/job-metadata-broker.py is standard library only, so the full
    installer is more than it needs; it is used anyway because the embeddable
    distribution ships a restricted `sys.path` and no certificate store, and the
    broker speaks TLS to Google's IAM endpoint.
  EOT
  default     = "3.14.7"
}

variable "git_version" {
  type        = string
  description = <<-EOT
    git, because actions/checkout is git: without it the FIRST step of nearly
    every workflow fails, which is the Windows form of the exit-127 baseline gap
    the Linux template's assertions exist to catch.
  EOT
  default     = "2.55.0.4"
}

variable "warm_cache_script" {
  type        = string
  description = <<-EOT
    OPTIONAL path to a repo-supplied PowerShell script that installs ADDITIONAL
    MACHINE-WIDE TOOLCHAIN as the last build layer. It runs inside the build VM,
    elevated, and must be idempotent and network-only — it may download, it must
    not embed credentials or customer data. Whatever it installs must be
    machine-wide to have any effect, because the slot accounts a job runs as do
    not exist yet at image-build time.

    IT IS NOT A CACHE LAYER, DESPITE THE NAME IT SHARES WITH THE LINUX ONE.
    There is no host-wide warm cache on a Windows host and nothing here can
    create one: windows-host-startup.ps1 states outright that "CacheRoot is the
    slot's OWN workspace root. There is no host-wide warm cache directory on
    this image", and it has no counterpart to the Linux boot script's
    CACHE_MASTER=/opt/ci-cache -> CACHE_SLOTS=/var/lib/ci-cache per-slot copy.
    A tree baked here would be read by nothing, copied per slot by nothing, and
    put on a job's PATH or into an npm/NuGet config by nothing. The name is kept
    so the two templates take the same variable; the gap is tracked in issue
    #150 and this description changes when that closes, not before.

    There is no container half of this contract either: section 4 of the ADR
    states that a Windows pool runs no job containers, so the Linux template's
    /opt/ci-images tree has no counterpart here.

    Empty = build a toolchain-only image.
  EOT
  default     = ""
}

locals {
  # Git for Windows spells its version twice and differently: the release is
  # tagged `v2.55.0.windows.4` and the installer inside it is
  # `Git-2.55.0.4-64-bit.exe`. Derived from one variable rather than declared as
  # two, because two would eventually disagree and the disagreement would be a
  # 404 forty minutes into a build.
  git_parts   = split(".", var.git_version)
  git_tag     = "v${local.git_parts[0]}.${local.git_parts[1]}.${local.git_parts[2]}.windows.${local.git_parts[3]}"
  git_setup   = "Git-${var.git_version}-64-bit.exe"
  warm_script = var.warm_cache_script != "" ? var.warm_cache_script : "warm-cache/none.ps1"
}

source "googlecompute" "host" {
  project_id              = var.project_id
  zone                    = var.zone
  network                 = var.network != "" ? var.network : null
  subnetwork              = var.subnetwork
  tags                    = var.network_tags
  source_image_family     = var.source_image_family
  source_image_project_id = [var.source_image_project_id]

  # WinRM, not SSH, and no OS Login. compute.requireOsLogin governs SSH; a
  # Windows guest authenticates the WinRM session against a local account the
  # GCE guest agent creates from the `windows-keys` exchange the plugin drives,
  # so the org policy neither helps nor hinders here. The account is deleted by
  # the cleanup provisioner.
  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_use_ssl  = true
  # The listener presents the certificate GCE generated for this VM, which no
  # public CA signed and which the builder has no way to pin. The channel is a
  # localhost-terminated IAP tunnel to a VM with no external IP, and the
  # credential crossing it is a per-build password that dies with the instance.
  winrm_insecure = true

  # WinRM is not listening on a stock GCE Windows image until something starts
  # it, and `startup_script_file` is documented as unsupported on Windows — a
  # Windows script can only arrive as metadata. sysprep-specialize runs before
  # first logon, which is early enough that Packer's first connection attempt
  # finds a listener.
  #
  # The firewall line is not redundant with quickconfig: quickconfig opens the
  # HTTP listener's port, and this template connects over 5986.
  metadata = {
    sysprep-specialize-script-cmd = join(" & ", [
      "winrm quickconfig -quiet",
      "winrm set winrm/config/service/auth @{Basic=\"true\"}",
      "netsh advfirewall firewall add rule name=\"WinRM-HTTPS-packer\" dir=in action=allow protocol=TCP localport=5986",
    ])
  }

  machine_type = "n2-standard-8"
  # 200 GB, matching the floor section 1 of the ADR puts on a Windows pool host:
  # Windows, plus the toolchains, plus K per-slot caches, plus K workspaces, plus a
  # pagefile. A host that fills its disk mid-job fails every slot at once and
  # reports it as a repository problem.
  disk_size = 200
  disk_type = "pd-balanced"

  # No external IP, ever. `compute.vmExternalIpAccess` is DENY org-wide here, so
  # a build VM that asks for one is rejected at create time — the build fails
  # before a single provisioner runs. Egress still works: these VPCs peer to the
  # landing-zone VPC and leave through the central firewall.
  omit_external_ip = true

  # Consequences of the line above: connect to the internal address, and get to
  # it through the IAP tunnel, because the builder is not inside the VPC. The
  # plugin tunnels whichever port the communicator uses, and already knows a
  # WinRM listener takes longer to come up than sshd does.
  use_internal_ip = true
  use_iap         = true

  image_name              = "${var.image_family}-${var.image_version}"
  image_family            = var.image_family
  image_storage_locations = var.image_storage_locations
  image_description       = "Warm Windows CI host: runner agent + service shim + toolchains. Repo-agnostic; identity arrives at boot via instance metadata."

  image_labels = {
    component = "ci-runner-host-pool"
    managed   = "packer"
    os        = "windows"
  }
}

build {
  name    = "ci-host-win"
  sources = ["source.googlecompute.host"]

  # 1. The in-box prerequisites this image is BUILT with, asserted before
  #    anything is installed on top of them.
  #
  #    csc.exe is the whole reason the service shim can be a reviewed source
  #    file instead of a vendored binary; if a future base image drops the .NET
  #    Framework compiler, the honest outcome is a build that stops here rather
  #    than one that silently ships without a shim and takes the fleet down at
  #    the next boot.
  #
  #    The port-exclusion probe is the same idea for the boot script's
  #    `Lock-LoopbackPort`: it reserves the closed-metadata port with
  #    `netsh int ipv4 add excludedportrange`, and a base image where that call
  #    is unavailable is one where every host Deny-Boots. Probed and undone.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "New-Item -ItemType Directory -Force -Path 'C:\\ci','C:\\ci\\bin' | Out-Null",
      "$csc = \"$env:WINDIR\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe\"",
      "if (-not (Test-Path -LiteralPath $csc)) { throw \"no in-box C# compiler at $csc\" }",
      "& netsh int ipv4 add excludedportrange protocol=tcp startport=1 numberofports=1 | Out-Null",
      "if ($LASTEXITCODE -ne 0) { throw 'netsh cannot reserve a loopback port on this base image' }",
      "& netsh int ipv4 delete excludedportrange protocol=tcp startport=1 numberofports=1 | Out-Null",
    ]
  }

  # 2. PowerShell 7. The Actions runner's default shell on Windows is `pwsh`, so
  #    this is not a convenience: without it every `run:` step on every host
  #    fails with a missing interpreter, which is this platform's version of the
  #    exit-127 outage the Linux template's node layer exists to prevent.
  #
  #    $ProgressPreference is not cosmetic. Invoke-WebRequest under Windows
  #    PowerShell renders a progress bar per read, which turns a 100 MB download
  #    into a multi-minute one on a VM with plenty of bandwidth.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'",
      "$v = '${var.powershell_version}'",
      "$msi = \"$env:TEMP\\PowerShell-$v-win-x64.msi\"",
      # Bounded, like every call a host in this fleet makes: an unbounded fetch
      # in a build is an image build that hangs until Cloud Build's own timeout.
      "Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri \"https://github.com/PowerShell/PowerShell/releases/download/v$v/PowerShell-$v-win-x64.msi\" -OutFile $msi",
      "$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @('/i', $msi, '/quiet', '/norestart', 'ADD_PATH=1')",
      "if ($p.ExitCode -ne 0) { throw \"PowerShell 7 install failed with $($p.ExitCode)\" }",
      "Remove-Item -LiteralPath $msi -Force",
    ]
  }

  # 3. git. actions/checkout IS git, so a host without it fails the first step of
  #    nearly every workflow. The installer's own silent switches, not a package
  #    manager: adding one would put a second update channel on every host in the
  #    fleet for a single package.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'",
      "$exe = \"$env:TEMP\\${local.git_setup}\"",
      "Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri 'https://github.com/git-for-windows/git/releases/download/${local.git_tag}/${local.git_setup}' -OutFile $exe",
      "$p = Start-Process $exe -Wait -PassThru -ArgumentList @('/VERYSILENT','/NORESTART','/NOCANCEL','/SP-','/SUPPRESSMSGBOXES','/COMPONENTS=gitlfs')",
      "if ($p.ExitCode -ne 0) { throw \"git install failed with $($p.ExitCode)\" }",
      "Remove-Item -LiteralPath $exe -Force",
    ]
  }

  # 4. The broker's interpreter, at the path the boot script fixes.
  #
  #    InstallAllUsers with an explicit TargetDir and PrependPath=0: this
  #    interpreter is infrastructure, not a toolchain. On PATH it would become
  #    whatever a job's `python` resolves to, and the boot script's comment on
  #    $script:PythonExe says why that must not be possible — the broker runs as
  #    LocalSystem and its interpreter must not be selectable by a later image
  #    layer or by a job.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'",
      "$v = '${var.python_version}'",
      "$exe = \"$env:TEMP\\python-$v-amd64.exe\"",
      "Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri \"https://www.python.org/ftp/python/$v/python-$v-amd64.exe\" -OutFile $exe",
      "$p = Start-Process $exe -Wait -PassThru -ArgumentList @('/quiet','InstallAllUsers=1','PrependPath=0','Include_launcher=0','Include_test=0','TargetDir=C:\\ci\\bin\\python')",
      "if ($p.ExitCode -ne 0) { throw \"python install failed with $($p.ExitCode)\" }",
      "Remove-Item -LiteralPath $exe -Force",
      "& 'C:\\ci\\bin\\python\\python.exe' -c \"import ssl, urllib.request, http.server; print('broker interpreter ok')\"",
      "if ($LASTEXITCODE -ne 0) { throw 'the broker interpreter cannot import what the broker imports' }",
    ]
  }

  # 5. The runner agent, baked UNCONFIGURED.
  #
  #    The zip is expanded here and the boot script COPIES it per slot before
  #    running config.cmd with a short-lived, controller-minted token: config.cmd
  #    writes `.runner` and `.credentials` into the directory it runs in, and K
  #    agents must not share one identity. No credential, token or repository
  #    name is ever in this image.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'",
      "$v = '${var.runner_version}'",
      "$zip = \"$env:TEMP\\actions-runner.zip\"",
      "Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri \"https://github.com/actions/runner/releases/download/v$v/actions-runner-win-x64-$v.zip\" -OutFile $zip",
      "New-Item -ItemType Directory -Force -Path 'C:\\ci\\bin\\actions-runner' | Out-Null",
      "Expand-Archive -LiteralPath $zip -DestinationPath 'C:\\ci\\bin\\actions-runner' -Force",
      "Remove-Item -LiteralPath $zip -Force",
      "foreach ($f in @('config.cmd','run.cmd')) { if (-not (Test-Path -LiteralPath \"C:\\ci\\bin\\actions-runner\\$f\")) { throw \"the runner archive did not contain $f\" } }",
    ]
  }

  # 6. The service host shim.
  #
  #    Compiled here, from packer/windows/ci-service-shim.cs, with the compiler
  #    that is already in the box. The alternative is a third-party executable
  #    fetched at build time and run as LocalSystem by every host in the fleet —
  #    the file in this repository is what review actually sees, and that is the
  #    whole argument. See the header of the .cs for why a shim is needed at all
  #    and why it is a lifecycle convenience rather than a safety boundary.
  provisioner "file" {
    source      = "windows/ci-service-shim.cs"
    destination = "C:/Windows/Temp/ci-service-shim.cs"
  }

  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$csc = \"$env:WINDIR\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe\"",
      "& $csc /nologo /target:exe /platform:x64 /optimize+ /warnaserror+ /out:C:\\ci\\bin\\ci-service-shim.exe /reference:System.ServiceProcess.dll /reference:System.Xml.dll C:\\Windows\\Temp\\ci-service-shim.cs",
      "if ($LASTEXITCODE -ne 0) { throw 'the service shim did not compile' }",
      "Remove-Item -LiteralPath 'C:\\Windows\\Temp\\ci-service-shim.cs' -Force",
    ]
  }

  # 7. Repo-supplied extra toolchain. Optional, and deliberately the LAST
  #    installing layer: everything above is identical for every consumer, so a
  #    change here does not invalidate the expensive layers.
  #
  #    Machine-wide or nothing — see the `warm_cache_script` description. This
  #    image bakes no cache tree, because a Windows host has nothing that would
  #    read one (issue #150); baking one anyway would be dead weight that reads
  #    like a working feature, which is the more expensive of the two mistakes.
  provisioner "powershell" {
    # Never an empty list: Packer validates this at PREPARE time and rejects a
    # provisioner with no script, so "warm nothing" is a script that does
    # nothing rather than an absent one. See warm-cache/none.ps1.
    scripts           = [local.warm_script]
    elevated_user     = build.User
    elevated_password = build.Password
  }

  # 8. The image version marker.
  #
  #    Written WITHOUT a byte-order mark, and that is the whole risk in this
  #    block. Test-ImageVersion trims the file and then requires `^[0-9]+$`; a
  #    BOM is not whitespace, .NET's Trim() does not remove it, and the match
  #    fails — so a BOM here is every Windows host in the fleet refusing to boot
  #    with "golden image version '' is below the required 1". Set-Content's
  #    -Encoding UTF8 means with-BOM on Windows PowerShell, which is what runs
  #    this, so the encoding is named explicitly instead.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$v = '${var.image_contract_version}'",
      "if ($v -notmatch '^[0-9]+$') { throw \"image_contract_version '$v' is not an integer, and the boot script refuses anything else\" }",
      "[System.IO.File]::WriteAllText('C:\\ci\\image-version.txt', $v, (New-Object System.Text.UTF8Encoding($false)))",
    ]
  }

  # 9. Assert the host baseline.
  #
  #    A missing baseline does not fail an image build — it fails every job on
  #    every host that boots the image, hours later, as an opaque error somebody
  #    reads as a repository fault. The Linux template learned this when a
  #    missing system node reached five repositories at once. Each assertion
  #    below is something a workflow step or the boot script invokes directly.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      # A fresh process, not this one: PATH changes made by the installers above
      # are in the machine environment, and the session that ran them does not
      # see them. Asserting in this session would prove nothing about the
      # session a job gets.
      "$machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine')",
      "$env:Path = $machinePath",
      "foreach ($b in @('pwsh.exe','git.exe')) { if (-not (Get-Command $b -ErrorAction SilentlyContinue)) { throw \"MISSING from the machine PATH: $b\" } }",
      "& pwsh -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'",
      "if ($LASTEXITCODE -ne 0) { throw 'pwsh is on PATH but will not run' }",
      "& git --version",
      "if ($LASTEXITCODE -ne 0) { throw 'git is on PATH but will not run' }",
      "foreach ($p in @('C:\\ci\\bin\\ci-service-shim.exe','C:\\ci\\bin\\python\\python.exe','C:\\ci\\bin\\actions-runner\\config.cmd','C:\\ci\\image-version.txt')) { if (-not (Test-Path -LiteralPath $p)) { throw \"the boot script requires $p and this image does not have it\" } }",
      "$marker = (Get-Content -Raw -LiteralPath 'C:\\ci\\image-version.txt').Trim()",
      "if ($marker -notmatch '^[0-9]+$') { throw \"the image marker reads '$marker', which Test-ImageVersion refuses\" }",
    ]
  }

  # 9b. Prove the shim actually RUNS a service on this image.
  #
  #     The Windows counterpart of the Linux template's rootless-daemon probe,
  #     and it exists for the identical reason: presence proves nothing. The
  #     failure mode is a shim that compiled, installed, and then never reaches
  #     SERVICE_RUNNING because the SCM killed it at start — which surfaces hours
  #     later as every host in the fleet failing phase 0 at Install-BeaconService
  #     with a beacon that is "Stopped, not Running". An image build that
  #     reported success would have delivered a fleet outage.
  #
  #     The definition below is deliberately the same SHAPE the boot script
  #     writes (Get-BeaconServiceConfig): a powershell.exe child, Automatic, a
  #     restart action, a roll-by-size log. Installing it twice is not padding —
  #     the boot script calls `install` on every boot and Windows hosts reboot
  #     for updates, so a shim that refuses the second call is a host that never
  #     comes back from a patch.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$xml = @'",
      "<service>",
      "  <id>ci-shim-probe</id>",
      "  <name>ci-shim-probe</name>",
      "  <description>Image-build probe. Removed before capture.</description>",
      "  <executable>powershell.exe</executable>",
      "  <arguments>-NoProfile -NonInteractive -Command \"while ($true) { Start-Sleep -Seconds 5 }\"</arguments>",
      "  <env name=\"CI_SHIM_PROBE\" value=\"1\"/>",
      "  <startmode>Automatic</startmode>",
      "  <onfailure action=\"restart\" delay=\"10 sec\"/>",
      "  <resetfailure>1 hour</resetfailure>",
      "  <log mode=\"roll-by-size\"><sizeThreshold>10240</sizeThreshold><keepFiles>2</keepFiles></log>",
      "</service>",
      "'@",
      "$cfg = 'C:\\Windows\\Temp\\ci-shim-probe.xml'",
      "[System.IO.File]::WriteAllText($cfg, $xml, (New-Object System.Text.UTF8Encoding($true)))",
      "& 'C:\\ci\\bin\\ci-service-shim.exe' install $cfg",
      "if ($LASTEXITCODE -ne 0) { throw \"the shim refused to install a service (exit $LASTEXITCODE)\" }",
      "& 'C:\\ci\\bin\\ci-service-shim.exe' install $cfg",
      "if ($LASTEXITCODE -ne 0) { throw 'the shim is not idempotent, so a reboot would strand the host' }",
      "Start-Service -Name 'ci-shim-probe'",
      "$svc = Get-Service -Name 'ci-shim-probe'",
      "if ($svc.Status -ne 'Running') { throw \"the shim service is '$($svc.Status)', not Running\" }",
      "Stop-Service -Name 'ci-shim-probe' -Force",
      "& sc.exe delete ci-shim-probe | Out-Null",
      "Remove-Item -LiteralPath $cfg -Force",
      "Remove-Item -LiteralPath 'C:\\Windows\\Temp\\ci-shim-probe.out.log' -Force -ErrorAction SilentlyContinue",
    ]
  }

  # 10. Leave no build identity behind. The WinRM account, its profile and the
  #     build's logs must not be part of an artifact N hosts boot from — the same
  #     rule as the Linux template's `rm -rf /home/*/.ssh`, and here it removes a
  #     LOCAL ADMINISTRATOR whose password the plugin generated, which would
  #     otherwise be a standing account on every host in the fleet.
  #
  #     Not generalised with GCESysprep, deliberately and with the trade stated:
  #     sysprep shuts the guest down from inside, which drops the WinRM session
  #     Packer is still holding, and the failure mode of getting that wrong is a
  #     build that reports an error after forty minutes of work. Hosts from this
  #     image therefore share a computer name until the guest agent renames them
  #     from instance metadata at first boot. Nothing in this pool identifies a
  #     host by computer name — the agent name comes from `instance/name` and the
  #     beacon from guest attributes — so the cost is cosmetic, and it is written
  #     here rather than discovered.
  provisioner "powershell" {
    elevated_user     = build.User
    elevated_password = build.Password
    inline = [
      "$ErrorActionPreference = 'Continue'",
      "$u = '${var.winrm_username}'",
      "Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like \"*\\$u\" } | Remove-CimInstance -ErrorAction SilentlyContinue",
      "Remove-LocalUser -Name $u -ErrorAction SilentlyContinue",
      "Remove-Item -Path \"$env:TEMP\\*\" -Recurse -Force -ErrorAction SilentlyContinue",
      "Remove-Item -Path 'C:\\Windows\\Temp\\*' -Recurse -Force -ErrorAction SilentlyContinue",
      "wevtutil el | ForEach-Object { wevtutil cl \"$_\" 2>$null }",
      # Proved in the build log rather than assumed, and proved from INSIDE this
      # script on purpose: the account this session authenticated as has just
      # been deleted, so anything Packer does over WinRM after this line is on
      # borrowed time — nothing else may be added below this provisioner.
      "if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) { Write-Error \"the build account $u survived cleanup\"; exit 1 }",
      "exit 0",
    ]
  }
}
