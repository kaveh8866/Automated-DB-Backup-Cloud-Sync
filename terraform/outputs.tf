# Connection details for the provisioned backup host and its bucket.
#
# The public IP is the hand-off to Stage 3 (deploy the compose stack over SSH).
# The bucket name and S3 endpoint are the values rclone needs for
# BACKUP_SYNC_MODE=rclone — see configs/rclone/rclone.conf.example.

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------

output "instance_public_ip" {
  description = "Public IPv4 address of the backup host."
  value       = module.compute.public_ip
}

output "instance_private_ip" {
  description = "Private IPv4 address inside the VCN."
  value       = module.compute.private_ip
}

output "instance_id" {
  description = "OCID of the compute instance."
  value       = module.compute.instance_id
}

output "instance_shape" {
  description = "Shape actually requested, with its OCPU and memory envelope."
  value = {
    shape  = var.instance_shape
    ocpus  = var.instance_ocpus
    memory = var.instance_memory_gbs
    flex   = module.compute.is_flex_shape
  }
}

output "availability_domain" {
  description = "Availability domain the instance landed in."
  value       = module.compute.availability_domain
}

output "image_id" {
  description = "Image resolved (or supplied) for the instance."
  value       = module.compute.image_id
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

output "vcn_id" {
  description = "OCID of the created VCN."
  value       = module.network.vcn_id
}

output "subnet_id" {
  description = "OCID of the public subnet."
  value       = module.network.subnet_id
}

output "security_list_id" {
  description = "OCID of the security list (SSH 22 only; no rule for 5432)."
  value       = module.network.security_list_id
}

# -----------------------------------------------------------------------------
# Object Storage
# -----------------------------------------------------------------------------

output "bucket_name" {
  description = "Name of the Object Storage bucket holding the backup archives."
  value       = module.storage.bucket_name
}

output "bucket_namespace" {
  description = "Object Storage namespace that owns the bucket."
  value       = module.storage.namespace
}

output "bucket_endpoint" {
  description = "S3-compatible endpoint for rclone/aws-cli (S3 API, not the native OCI API)."
  value       = module.storage.s3_endpoint
}

output "bucket_uri" {
  description = "Canonical OCI URI of the bucket, useful with the OCI CLI."
  value       = "oci://${module.storage.namespace}/${module.storage.bucket_name}"
}

output "bucket_lifecycle" {
  description = "Lifecycle policy applied to archives (0 days = rule disabled)."
  value = {
    versioning_enabled = var.enable_bucket_versioning
    archive_after_days = var.bucket_archive_after_days
    delete_after_days  = var.bucket_delete_after_days
    access             = "NoPublicAccess"
  }
}

# -----------------------------------------------------------------------------
# Hand-off
# -----------------------------------------------------------------------------

output "connection_endpoints" {
  description = "Ready-to-use endpoints for the backup host."
  value = {
    ssh = "ssh ubuntu@${module.compute.public_ip}"
    # PostgreSQL is never published to the internet; reach it through a tunnel.
    postgres_tunnel = "ssh -L 5432:localhost:5432 ubuntu@${module.compute.public_ip}"
    # Verify the bucket is reachable with the same rclone binary the runner uses.
    rclone_check = "rclone --config ./rclone.conf lsd oci-backups:"
  }
}

output "deploy_next_step" {
  description = "Reminder of how the stack is deployed — IaC provisions the host, compose runs the pipeline."
  value       = "ssh ubuntu@${module.compute.public_ip} 'git clone https://github.com/kaveh8866/Automated-DB-Backup-Cloud-Sync.git && cd Automated-DB-Backup-Cloud-Sync && cp .env.example .env && docker compose --env-file .env -f docker/docker-compose.yml up -d --build'"
}
