output "service_account_email" {
  value       = google_service_account.publisher.email
  description = "The publisher's identity. Pass to `google-github-actions/auth` as `service_account` in the scheduled publish workflow on the default branch."
}

output "cache_prefix" {
  value       = local.cache_prefix
  description = "The object prefix this publisher may write and the pool reads. Both sides derive it from the pool name; this output exists so a workflow can be handed it rather than re-spell it."
}

output "pointer_object" {
  value       = "${local.cache_prefix}current"
  description = "The one object the publisher may replace. Swap it with a generation precondition; everything else under the prefix is write-once."
}
