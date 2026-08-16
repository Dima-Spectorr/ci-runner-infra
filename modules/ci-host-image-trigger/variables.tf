variable "project_id" {
  type        = string
  description = "Project that runs the build AND holds the resulting image. Packer's build VM, the IAP tunnel it is reached over, and the created image all land here — `$PROJECT_ID` inside the build is this project, not the caller's."
}

variable "region" {
  type        = string
  description = "Region for the trigger. Cloud Build triggers are REGIONAL — a trigger created in one region is invisible to `gcloud builds triggers list` run against another, which reads as 'the trigger was never created'."
}

variable "github_owner" {
  type        = string
  description = "GitHub owner of the repository holding the image build. No default: an owner default in a generic module is a customer literal with a fallback."
}

variable "github_repo" {
  type        = string
  default     = "ci-runner-infra"
  description = "Repository holding `packer/` and the root `cloudbuild.yaml`. Defaults to this repository's name because that is where the image build lives; override it only for a fork. The project's GitHub connection must already cover THIS repository — not merely the consumer's own repo, which is the prerequisite most easily assumed satisfied."
}

variable "github_connection" {
  type        = string
  default     = null
  description = <<-EOT
    Name of an EXISTING 2nd-gen Cloud Build connection in this project and region, e.g. `<project>-github`. Null (the default) means the project links repositories the 1st-gen way, through the Cloud Build GitHub App, and the trigger is built with a `github {}` block.

    THE TWO GENERATIONS ARE DIFFERENT APIS, NOT A VERSION FLAG. A 1st-gen trigger names owner/repo directly and resolves them against a project-level GitHub App install; a 2nd-gen trigger names a `google_cloudbuildv2_repository` resource under a connection. Neither block works against the other's link, and the failure is not a validation error — it is a trigger that is created successfully and never fires, because the push it is watching for arrives on a link it cannot see.

    Which one a project has is a fact about the project, discovered rather than chosen (`gcloud builds connections list --project=<p> --region=<r>`, PER REGION — 2nd-gen connections are regional and a region-less list returns [] for a project that has several).

    Full resource names are accepted as well as bare names, so `google_cloudbuildv2_connection.x.id` can be passed straight through.
  EOT
}

variable "github_repository" {
  type        = string
  default     = null
  description = <<-EOT
    Full resource name of an EXISTING `google_cloudbuildv2_repository` under `github_connection` — `projects/p/locations/r/connections/c/repositories/x`. Only read when `github_connection` is set.

    Null (the default) registers the repository under the connection instead. Set this when it is already registered — by the project's apply-trigger root, or by hand — because registering the same remote twice under one connection is an ALREADY_EXISTS error, not a no-op. This module watches ci-runner-infra, which a project may well have registered already for something else, so pass `repository_id` from whichever root registered it first.
  EOT

  validation {
    condition     = var.github_repository == null || can(regex("^projects/[^/]+/locations/[^/]+/connections/[^/]+/repositories/[^/]+$", coalesce(var.github_repository, "x")))
    error_message = "github_repository must be a full resource name: projects/<project>/locations/<region>/connections/<connection>/repositories/<name>."
  }
}

variable "branch" {
  type        = string
  default     = "main"
  description = "The branch whose pushes rebuild the image, as a LITERAL name. The push filter's regex is derived from it."

  validation {
    condition     = !can(regex("[\\^$*+?()\\[\\]{}|\\\\]", var.branch))
    error_message = "branch takes a literal branch name (main), not a regex (^main$). The regex form is derived for the push filter."
  }
}

variable "name" {
  type        = string
  default     = null
  description = "Trigger name. Defaults to ci-host-image-<repo>. Set it when one project builds more than one image variant — a toolchain-only image and a cache-warmed one are two triggers with two families."

  validation {
    condition     = var.name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]$", coalesce(var.name, "x-x")))
    error_message = "name must start with a letter and contain only letters, digits and hyphens (Cloud Build trigger naming)."
  }
}

variable "service_account" {
  type        = string
  description = <<-EOT
    Email of the EXISTING account the build runs as. This module creates no identity, by design — see the header of main.tf.

    THE ONE SECURITY DECISION IN THIS MODULE, and it is NOT the same account shape as `ci-runner-apply-trigger` asks for. This build creates and deletes a GCE VM, reaches it over an IAP tunnel, and creates an image; it does not touch terraform state, IAM or secrets. The role list is in docs/applying-runner-infra.md. An image builder that also holds the apply account's roles is one build away from being able to change the fleet it builds for.
  EOT

  validation {
    # Rejects a RESOURCE NAME — `projects/p/serviceAccounts/x` — because the
    # resource name is built from this value and a doubled prefix fails at apply
    # with a message about a malformed path rather than about the input that
    # produced it. The default compute account is a legal, differently-shaped
    # service account and is accepted; see the same note in
    # ci-runner-apply-trigger.
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.service_account)) || can(regex("^[0-9]+-compute@developer\\.gserviceaccount\\.com$", var.service_account))
    error_message = "service_account must be a service account EMAIL — name@project.iam.gserviceaccount.com, or <number>-compute@developer.gserviceaccount.com for a project's default compute account — not a full projects/.../serviceAccounts/... resource name, which is built from it."
  }
}

variable "zone" {
  type        = string
  description = "Zone for Packer's temporary build VM (`_ZONE`). Required, no default: a zone literal in a generic module is a region literal with extra steps. Pick one in `region` — the VM has no external IP and is reached over IAP, and the firewall rule permitting that lives in the project's own network."
}

variable "network" {
  type        = string
  description = "VPC network for the build VM (`_NETWORK`). Required and unset by default rather than defaulting to `default`, because the project that has a `default` network is not the project this is for: these builds run on a VPC whose IAP-SSH rule targets `network_tag`, and a build VM placed on the wrong network fails only after boot, as an SSH timeout that reads like a broken image."
}

variable "subnetwork" {
  type        = string
  default     = "default"
  description = "Subnetwork for the build VM (`_SUBNETWORK`). Matches the root cloudbuild.yaml's own default. Not a region literal — it is a subnetwork NAME, resolved within `zone`'s region."
}

variable "network_tag" {
  type        = string
  default     = "ci-runner"
  description = "Network tag put on the build VM (`_NETWORK_TAG`). MUST match the tag the project's IAP-SSH firewall rule targets, or the tunnel to the (external-IP-less) build VM never opens and Packer waits out its SSH timeout. Defaults to the tag `ci-runner-network` applies."
}

variable "image_family" {
  type        = string
  default     = "ci-runner-host"
  description = "Image family the build stamps (`_IMAGE_FAMILY`), and the prefix of every image name it produces. A cache-warmed image should use a DISTINCT family, so pools tracking the toolchain-only family do not silently inherit the extra gigabytes."
}

variable "image_storage_location" {
  type        = string
  description = <<-EOT
    Where the produced image is STORED (`_IMAGE_STORAGE_LOCATION`). Required, with no default, because there is no correct generic answer and the incorrect one is expensive: left empty, GCE picks a multi-region, `constraints/gcp.resourceLocations` rejects it, and it rejects it at IMAGE CREATION — after every provisioner has already run, an hour in.

    Normally the build region. A location, so it is an input and never a literal here.
  EOT

  validation {
    condition     = length(trimspace(var.image_storage_location)) > 0
    error_message = "image_storage_location must be non-empty — an empty value passes terraform, passes the trigger, and fails at the end of an hour-long build."
  }
}

variable "image_version" {
  type        = string
  default     = null
  description = <<-EOT
    Version suffix stamped into the image name, which is `<image_family>-<image_version>` (`_IMAGE_VERSION`).

    Null (the default, and the point of this module) passes the Cloud Build expansion `g$SHORT_SHA`, so every merge produces a unique, immutable image — `<image_family>-g<sha>` — and no two builds can ever race to create one name. Set it only to reproduce a historical naming scheme, e.g. `v3-12-0`.

    Dots are legal in neither a GCE image name nor this suffix: `v3.12.0` fails at image creation. Hyphens.
  EOT
}

variable "runner_version" {
  type        = string
  default     = null
  description = "GitHub Actions runner agent version to bake (`_RUNNER_VERSION`), without the leading v. Null (the default) sends no substitution and inherits the root cloudbuild.yaml's pin — which is the version this repo tests and bumps. Override only to build an image ahead of a merge."
}

variable "packer_version" {
  type        = string
  default     = null
  description = "Packer version the build downloads (`_PACKER_VERSION`). Null (the default) sends no substitution and inherits the root cloudbuild.yaml's pin. Same rule as runner_version: the config file is where these move."
}

variable "warm_cache_script" {
  type        = string
  default     = ""
  description = "Path, inside the repository, to a cache-warming script baked into the image (`_WARM_CACHE_SCRIPT`) — e.g. `warm-cache/playwright.sh`. Empty (the default) builds the toolchain-only image. A warmed image is substantially larger, so pair a non-empty value with a distinct `image_family`."
}

variable "cloudbuild_config" {
  type        = string
  default     = "cloudbuild.yaml"
  description = "Path, inside the repository, to the build config the trigger runs. The repository root's file by default — that IS the image build. A different file must set `options.logging: CLOUD_LOGGING_ONLY`, which Cloud Build requires of any build naming its own service account and refuses the submission without — and must also be named in `included_files`, whose default lists the root file. Changing one and not the other leaves a trigger that runs a config nothing it watches can change."

  validation {
    condition     = !startswith(var.cloudbuild_config, "/") && !strcontains(var.cloudbuild_config, "..")
    error_message = "cloudbuild_config is a path INSIDE the repository, relative to its root. A leading slash or a .. segment escapes the workspace."
  }
}

variable "included_files" {
  type        = list(string)
  default     = ["packer/**", "cloudbuild.yaml"]
  description = "Globs whose change rebuilds the image. Scoped tightly on purpose: this build takes about an hour, and firing it on every merge to a repository that is mostly documentation and shell would spend the day rebuilding an identical image. `scripts/**` is NOT included — nothing under it is copied into the image; the only reference to it in `packer/` is a comment. Widen it if that stops being true."
}

variable "ignored_files" {
  type        = list(string)
  default     = ["**/*.md"]
  description = "Globs that never rebuild the image even inside included_files. Documentation only, by default."
}

variable "extra_substitutions" {
  type        = map(string)
  default     = {}
  description = "Escape hatch for a substitution this module does not model — a new one added to the root cloudbuild.yaml before this module learns about it. Merged LAST, so it also overrides any value above. Prefer a named variable; this exists so a config-file change is not blocked on a module release."

  validation {
    condition     = alltrue([for k in keys(var.extra_substitutions) : startswith(k, "_")])
    error_message = "Every user-defined Cloud Build substitution must start with an underscore; the un-prefixed names are reserved for built-ins and the API rejects them."
  }
}

variable "disabled" {
  type        = bool
  default     = false
  description = "Create the trigger disabled. For onboarding a project whose network or IAP firewall is not ready — the trigger exists and is reviewable, and nothing runs."
}
