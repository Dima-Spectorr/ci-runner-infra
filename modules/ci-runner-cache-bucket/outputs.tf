output "bucket_name" {
  value       = google_storage_bucket.cache.name
  description = "Pass this to each pool's `cache_snapshot_bucket`. Every pool in the project shares the bucket and is separated inside it by object prefix."
}

output "bucket_url" {
  value       = google_storage_bucket.cache.url
  description = "gs:// URL of the bucket, for operators inspecting snapshots by hand."
}

output "snapshot_max_age_days" {
  value       = var.snapshot_max_age_days
  description = "The age at which the bucket deletes a snapshot. A pool's own boot-time limit should be at or below this, so the host and the bucket agree on when a cache has expired."
}
