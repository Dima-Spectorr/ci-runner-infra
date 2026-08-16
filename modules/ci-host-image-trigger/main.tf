# ci-host-image-trigger — the golden host image, rebuilt by a merge instead of
# by a person.
#
# Until this module the image came from a hand-typed `gcloud builds submit
# --config cloudbuild.yaml` with five substitutions, and every one of those five
# was a chance to rebuild an image subtly unlike the last one. The root
# cloudbuild.yaml's header still lists that command, because it stays the right
# way to build an image OUT OF BAND — a warm-cache variant, a bisect, a
# one-off. What it is not is a release mechanism: an artifact whose reproduction
# depends on somebody remembering `_IMAGE_STORAGE_LOCATION` is an artifact
# nobody can reproduce, and that particular omission fails at the END of an
# hour-long build, after every provisioner has already run.
#
# THIS MODULE INLINES NO BUILD STEPS, and that is the difference from
# `ci-runner-apply-trigger`, which does. The steps that build the image already
# live in this repository's root `cloudbuild.yaml`, next to the packer template
# they drive; the trigger names that file and nothing else. Copying them into
# terraform would put the build in two places and let them drift, and the one
# that drifts is always the copy nobody runs by hand.
#
# WHAT THIS MODULE DELIBERATELY DOES NOT DO: create a service account. Same
# argument as ci-runner-apply-trigger — a module that mints the identity its own
# builds run as is a module that decides its own privileges. `service_account`
# is an EXISTING account, it is the one security decision here, and the roles it
# needs are in docs/applying-runner-infra.md. They are not the apply account's
# roles: this build drives a GCE VM over an IAP tunnel and creates an image.
#
# WHAT A MERGE DOES AND DOES NOT DO TO A RUNNING FLEET: it produces a NEW image
# and moves nothing. Pools pin an exact image name, never the family, so no host
# reboots and no pool changes until somebody bumps `host_image` in a consumer
# root. That is the intended behaviour and not a gap — an image that arrived on
# every pool the moment it built would be an untested image on every pool.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

locals {
  # One literal branch in, the regex derived. The push filter takes a REGEX;
  # `^main$` typed as the branch is the plausible mistake and it is the quiet
  # kind. Same reasoning as ci-runner-apply-trigger, kept identical on purpose.
  branch_regex = "^${var.branch}$"

  trigger_name = coalesce(var.name, "ci-host-image-${lower(replace(var.github_repo, "_", "-"))}")

  # 2nd gen if the project has a connection, 1st gen otherwise. Not a preference
  # and not a migration: it is a read of what the project already has. A trigger
  # built against the generation the project does NOT use is created without
  # complaint and never fires — see the `github_connection` description.
  gen2 = var.github_connection != null

  # A bare name or a full resource id, both accepted, so a caller holding
  # `google_cloudbuildv2_connection.x.id` can pass it straight through.
  connection_id = local.gen2 ? (
    startswith(coalesce(var.github_connection, ""), "projects/")
    ? var.github_connection
    : "projects/${var.project_id}/locations/${var.region}/connections/${var.github_connection}"
  ) : null

  repository_id = local.gen2 ? coalesce(var.github_repository, try(google_cloudbuildv2_repository.repo[0].id, "")) : null

  # `g$SHORT_SHA`, not `$SHORT_SHA`. The image is named
  # `<image_family>-<image_version>` by the packer template, so the version
  # suffix could in principle be anything — but the version is also the only
  # part a human reads to tell two images apart, and a bare short sha starting
  # with a digit is indistinguishable from a truncated version string. The `g`
  # is git's own convention for "the following is an abbreviated object name"
  # (`git describe` prints `v1.2.3-4-gabc1234`), and it guarantees the suffix
  # begins with a letter — which matters if the family is ever overridden with
  # something that does not, since a GCE image name must start with a lowercase
  # letter. `packer/ci-host-image.pkr.hcl` puts no format constraint on
  # `image_version`, so nothing downstream would reject a bad one until the
  # image is created, at the end of the build.
  #
  # THE EXPANSION IS REAL, NOT LITERAL TEXT. Cloud Build resolves a substitution
  # referenced inside another substitution's value only when
  # `dynamicSubstitutions` is on — and for a build invoked by a trigger it "is
  # always set to true and does not need to be specified in your build config
  # file". This module only ever produces trigger-invoked builds, so the
  # condition holds by construction. It would NOT hold for the same value typed
  # into a manual `gcloud builds submit`, which is the version of this that
  # would silently create an image literally named `ci-runner-host-g$SHORT_SHA`.
  image_version = coalesce(var.image_version, "g$SHORT_SHA")

  # Always set: every one of these is either required by the root
  # cloudbuild.yaml's `guard` step or has a default in this module.
  base_substitutions = {
    _ZONE                   = var.zone
    _NETWORK                = var.network
    _SUBNETWORK             = var.subnetwork
    _NETWORK_TAG            = var.network_tag
    _IMAGE_FAMILY           = var.image_family
    _IMAGE_STORAGE_LOCATION = var.image_storage_location
    _IMAGE_VERSION          = local.image_version
    _WARM_CACHE_SCRIPT      = var.warm_cache_script
  }

  # Omitted rather than sent empty when the caller does not pin them. The root
  # cloudbuild.yaml carries real defaults for both (`_RUNNER_VERSION`,
  # `_PACKER_VERSION`), and sending "" would override a working default with a
  # value that breaks the build — a runner agent download of version `` and a
  # packer download of version ``, both 404, both an hour into nothing.
  optional_substitutions = merge(
    var.runner_version == null ? {} : { _RUNNER_VERSION = var.runner_version },
    var.packer_version == null ? {} : { _PACKER_VERSION = var.packer_version },
  )
}

# Registered here rather than required as an input, for the same reason as in
# ci-runner-apply-trigger: a connection is authorized once for a whole GitHub
# account and its repositories are then registered one at a time, so requiring
# the registration as a prerequisite would put a manual step back into the path
# the connection was supposed to remove.
#
# Skipped when the caller names an existing one. Registering the same remote
# twice under one connection is an ALREADY_EXISTS error rather than a no-op —
# and that collision is LIKELIER here than anywhere else in this repo, because
# the repository this trigger watches is ci-runner-infra itself: a project that
# already registered it for some other purpose, or two projects' roots sharing
# one connection, hit it on the second apply. Pass `repository_id` from the
# first root's outputs.
resource "google_cloudbuildv2_repository" "repo" {
  count = local.gen2 && var.github_repository == null ? 1 : 0

  project  = var.project_id
  location = var.region
  # Every character GitHub allows in a repository name that a Google resource id
  # does not — `_` and `.` are both common and both rejected.
  name              = lower(replace("${var.github_owner}-${var.github_repo}", "/[^a-zA-Z0-9-]/", "-"))
  parent_connection = local.connection_id
  remote_uri        = "https://github.com/${var.github_owner}/${var.github_repo}.git"
}

resource "google_cloudbuild_trigger" "image" {
  project     = var.project_id
  location    = var.region
  name        = local.trigger_name
  description = "Rebuild the golden CI host image (${var.image_family}) from ${var.github_repo}'s root cloudbuild.yaml on push to ${var.branch}. Produces a new image; repins nothing — pools pin an exact name."
  disabled    = var.disabled

  # Exactly one of these exists per trigger — `dynamic` with a 0/1 iterator is
  # the terraform spelling of "this block, conditionally", and both are written
  # that way so neither reads as the special case.
  dynamic "github" {
    for_each = local.gen2 ? [] : [1]
    content {
      owner = var.github_owner
      name  = var.github_repo
      push {
        branch = local.branch_regex
      }
    }
  }

  dynamic "repository_event_config" {
    for_each = local.gen2 ? [1] : []
    content {
      repository = local.repository_id
      push {
        branch = local.branch_regex
      }
    }
  }

  # Scoped, and the scope is small on purpose. This build takes roughly an hour
  # and produces a multi-gigabyte image; firing it on every merge to a
  # documentation-and-shell repository would spend most of a day building images
  # identical to the one before. `scripts/**` is deliberately NOT here: nothing
  # under it is copied into the image — the only mention of it anywhere in
  # `packer/` is a comment.
  included_files = var.included_files
  ignored_files  = var.ignored_files

  # The account this runs as — an input, never created here. See the header, and
  # the role list in docs/applying-runner-infra.md.
  service_account = "projects/${var.project_id}/serviceAccounts/${var.service_account}"

  # The build is the repository's own file, not steps inlined here. Which also
  # means THERE IS NO BUILD TIMEOUT KNOB in this module and cannot be one:
  # terraform expresses a build timeout inside the `build {}` block, and a
  # `filename` trigger has no `build {}` block. The timeout is `timeout: 3600s`
  # at the bottom of that file, where the steps it bounds are — one place, and
  # a module knob here could only ever contradict it.
  filename = var.cloudbuild_config

  # NOTE ON `logging: CLOUD_LOGGING_ONLY`: it is mandatory for a build that
  # names its own service account — Cloud Build refuses the submission
  # otherwise, rather than running it and dropping the logs. It is not set here
  # because it cannot be: with `filename`, the options belong to the config
  # file, and the root cloudbuild.yaml already sets it. A consumer pointing
  # `cloudbuild_config` at some other file must ensure that file sets it too,
  # or the first push fails at submit time with "build.service_account requires
  # ... logging".

  substitutions = merge(local.base_substitutions, local.optional_substitutions, var.extra_substitutions)
}
