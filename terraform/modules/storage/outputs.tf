output "bucket_name" {
  description = "Name of the created bucket."
  value       = oci_objectstorage_bucket.this.name
}

output "namespace" {
  description = "Object Storage namespace that owns the bucket."
  value       = var.namespace
}

output "bucket_id" {
  description = "OCID-style identifier of the bucket (namespace/name)."
  value       = "${var.namespace}/${oci_objectstorage_bucket.this.name}"
}

output "s3_endpoint" {
  description = "S3-compatible endpoint for rclone/aws-cli against this bucket."
  value       = "https://${var.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "native_endpoint" {
  description = "Native OCI Object Storage endpoint (used by the OCI CLI/SDK)."
  value       = "https://objectstorage.${var.region}.oraclecloud.com"
}

output "access_type" {
  description = "Bucket access model — private by design."
  value       = oci_objectstorage_bucket.this.access_type
}

output "versioning" {
  description = "Versioning state of the bucket."
  value       = oci_objectstorage_bucket.this.versioning
}
