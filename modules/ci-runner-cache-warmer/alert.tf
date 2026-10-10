# THE WARMER OWNS ITS OWN ALARM, IN ITS OWN PROJECT.
#
# A warm that fails is a cold pool, and a cold pool raises nothing: every
# pull-request job is merely slower. Measured 2026-10-10 on one consumer: the
# nightly warm had ended in ERROR on at least eight consecutive nights while the hosts'
# own `ci_cache_snapshot_age_hours` climbed to 169 h. The fleet's stale-cache
# policy (scripts/ci/ensure-alert-policies.sh) exists, but it is installed by
# the apply trigger of the POOL's project, which is not this module's project
# and had never installed the fleet set at all. An alarm that lives somewhere
# else than the thing it watches is an alarm that can be missing without
# anything showing it, so this one is created beside the trigger, by the same
# apply, against the same project.
#
# THE SIGNAL IS THE BUILD'S OWN LAST LINE, not a controller reading the builds
# list. Cloud Build writes `DONE` (success) or `ERROR` (failure) as the MAIN
# step's final log line of every build it runs, on the monitored resource
# `build` labelled with the trigger id. A controller-side check was rejected
# for two measured reasons: the controller's project can differ from this one,
# and `gcloud builds list --limit=50` covers about three hours of a busy
# project, so a nightly build falls off the page before anything reads it.
#
# TWO CONDITIONS, AND ONLY THE SECOND IS THE GUARANTEE.
#   failed  any non-`DONE` outcome in the last hour. Fast, and specific: it
#           names the failure while the log is fresh.
#   stale   no `DONE` within `alert_stale_after_hours`. This is the one that
#           cannot be satisfied by a warm that is broken in a way nobody
#           predicted: a build refused at fire time writes NO log line, a
#           scheduler that stopped firing writes nothing, and what a timed-out
#           build logs is deliberately not assumed. Absence of success catches
#           all of them.
# A metric-ABSENCE condition was not used for `stale`: its window is capped
# well below a nightly cadence. A PromQL range is not.

locals {
  # Log-based metric ids allow `-`; their PromQL names do not, and Cloud
  # Monitoring maps every other character to `_`.
  outcome_metric_name = "${local.trigger_name}-outcome"
  outcome_promql      = "logging_googleapis_com:user_${replace(local.outcome_metric_name, "/[^A-Za-z0-9_]/", "_")}"
  outcome_selector    = "monitored_resource=\"build\""
}

resource "google_logging_metric" "warm_outcome" {
  project     = var.project_id
  name        = local.outcome_metric_name
  description = "Final outcome of each ${local.trigger_name} build (DONE, ERROR, or whatever else Cloud Build writes as the MAIN step's last line). Feeds the warmer's own alert policy."

  # `textPayload` is matched to an explicit set so an ordinary step line can
  # never be counted as an outcome. Anything other than DONE in the set is a
  # failure by the policy's reading.
  filter = join(" AND ", [
    "resource.type=\"build\"",
    "resource.labels.build_trigger_id=\"${google_cloudbuild_trigger.warm.trigger_id}\"",
    "labels.build_step=\"MAIN\"",
    "textPayload=(\"DONE\" OR \"ERROR\" OR \"TIMEOUT\")",
  ])

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "outcome"
      value_type  = "STRING"
      description = "The build's final MAIN line: DONE on success."
    }
  }

  label_extractors = {
    outcome = "EXTRACT(textPayload)"
  }
}

resource "google_monitoring_alert_policy" "warm" {
  project      = var.project_id
  display_name = "CI cache warmer / ${local.trigger_name} failing or stale"
  combiner     = "OR"
  # A disabled warmer is not expected to succeed; an enabled one always is.
  enabled               = !var.disabled
  notification_channels = var.alert_notification_channels
  severity              = "ERROR"

  lifecycle {
    # A variable validation cannot read var.project_id on Terraform 1.5.
    precondition {
      condition     = alltrue([for c in var.alert_notification_channels : split("/", c)[1] == var.project_id])
      error_message = "Every alert_notification_channels entry must be a channel in project_id (${var.project_id})."
    }
  }

  conditions {
    display_name = "a warm ended in a non-DONE outcome in the last hour"
    condition_prometheus_query_language {
      query               = "sum(increase(${local.outcome_promql}{${local.outcome_selector},outcome!=\"DONE\"}[1h])) > 0"
      duration            = "0s"
      evaluation_interval = "300s"
    }
  }

  conditions {
    display_name = "no successful warm in ${var.alert_stale_after_hours}h"
    condition_prometheus_query_language {
      # `or vector(0)`: with no DONE at all there is no series to compare, and
      # an empty comparison is silence — the exact failure this exists for.
      query               = "(sum(increase(${local.outcome_promql}{${local.outcome_selector},outcome=\"DONE\"}[${var.alert_stale_after_hours}h])) or vector(0)) < 1"
      duration            = "0s"
      evaluation_interval = "900s"
    }
  }

  alert_strategy {
    auto_close = "604800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "CI cache warmer ${local.trigger_name} is failing or has not succeeded in ${var.alert_stale_after_hours}h"
    content   = <<-EOT
      The Cloud Build trigger `${local.trigger_name}` (project `${var.project_id}`) warms the
      `${var.pool_name}` pool's caches. Until it succeeds again every pull-request job on that
      pool runs cold, and nothing else turns red.

      Read the last builds:

          gcloud builds list --project=${var.project_id} --region=${var.region} --filter='buildTriggerId="${google_cloudbuild_trigger.warm.trigger_id}"' --limit=5

      Or in Logs Explorer: `${google_logging_metric.warm_outcome.filter}`

      No build at all within the window means the scheduler did not fire or the build was refused
      before it ran (a refused build writes no log). A credential-scan refusal names the file and,
      where printing it is safe, the allowlist line to add.
    EOT
  }
}
