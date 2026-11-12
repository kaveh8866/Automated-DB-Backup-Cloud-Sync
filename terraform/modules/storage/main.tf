# OCI Object Storage module — private bucket for the backup archives.
#
# PORTABILITY / S3 COMPATIBILITY
#   The bucket is consumed through OCI's S3-compatible endpoint
#   (…compat.objectstorage.<region>.oraclecloud.com), which means the runner,
#   rclone and the AWS CLI all work unchanged. Swapping providers therefore
#   means swapping *this module*, not the backup pipeline:
#
#   | OCI (here)                        | AWS                                        | GCP                                                |
#   | --------------------------------- | ------------------------------------------ | -------------------------------------------------- |
#   | oci_objectstorage_bucket          | aws_s3_bucket                              | google_storage_bucket (or the S3/XML interop API)  |
#   | access_type = "NoPublicAccess"    | Block Public Access + bucket policy        | uniform bucket-level access, no allUsers binding   |
#   | versioning = "Enabled"            | versioning { enabled = true }              | versioning { enabled = true }                      |
#   | oci_objectstorage_object_lifecycle_policy | aws_s3_bucket_lifecycle_configuration | google_storage_bucket_lifecycle_rule            |
#   | namespace + bucket name           | bucket name (globally unique)              | globally unique bucket name                        |
#
#   Endpoints, for the rclone remote (see configs/rclone/rclone.conf.example):
#     OCI  https://<namespace>.compat.objectstorage.<region>.oraclecloud.com
#     AWS  https://s3.<region>.amazonaws.com                 (provider = AWS)
#     GCS  https://storage.googleapis.com                    (provider = Google, or S3 interop)
#   R2/MinIO follow the same pattern: change `provider` and `endpoint`, keep the
#   rest of the config — and keep BACKUP_SYNC_MODE=rclone.
#
# ACCESS: NoPublicAccess. Archives contain a full database dump; the only
# principal that may read them is one holding an IAM policy on this bucket.
# A pre-authenticated request or a signed URL is the supported way to hand a
# single archive to a human — never a public bucket.

resource "oci_objectstorage_bucket" "this" {
  compartment_id = var.compartment_id
  namespace      = var.namespace
  name           = var.bucket_name

  # Private by construction: no anonymous read, ever.
  access_type   = "NoPublicAccess"
  storage_tier  = "Standard"
  versioning    = var.enable_versioning ? "Enabled" : "Suspended"
  freeform_tags = var.freeform_tags

  # Archives are written by the runner and read only during a restore; object
  # events are not needed for either path.
  object_events_enabled = false
}

# Lifecycle rules. Both are optional and off when their day count is 0:
#   * archive tier after N days  -> cheaper storage for backups nobody reads
#   * delete after N days        -> hard cap on cost when the operator wants one
# The runner's own retention (BACKUP_RETENTION_DAYS / BACKUP_KEEP_MINIMUM) is
# the primary policy; these rules are the backstop for objects whose local
# bookkeeping was lost.
resource "oci_objectstorage_object_lifecycle_policy" "this" {
  namespace = var.namespace
  bucket    = oci_objectstorage_bucket.this.name

  dynamic "rules" {
    for_each = var.archive_after_days > 0 ? [1] : []

    content {
      name        = "archive-old-backups"
      action      = "ARCHIVE"
      time_amount = var.archive_after_days
      time_unit   = "DAYS"
      is_enabled  = true
      target      = "objects"
    }
  }

  dynamic "rules" {
    for_each = var.delete_after_days > 0 ? [1] : []

    content {
      name        = "delete-expired-backups"
      action      = "DELETE"
      time_amount = var.delete_after_days
      time_unit   = "DAYS"
      is_enabled  = true
      target      = "objects"
    }
  }
}
