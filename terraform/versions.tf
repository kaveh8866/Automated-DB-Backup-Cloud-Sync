# Automated DB Backup & Cloud Sync — OCI environment (Stage 2)
#
# Root module. Provisions the host that runs the Stage 1 compose stack, plus the
# Object Storage bucket that receives the backup archives. Everything
# cloud-specific is confined to this directory and its three modules; docker/,
# scripts/ and configs/ never change.
#
# PORTABILITY (AWS / GCP): every resource below has a 1:1 equivalent — see the
# mapping tables at the top of modules/network/main.tf, modules/compute/main.tf
# and modules/storage/main.tf. Variable names are deliberately provider-neutral
# wherever the concept is shared (region, vcn_cidr/subnet_cidr, ssh_public_key,
# instance_shape, bucket_name).

terraform {
  # OpenTofu 1.6+ and Terraform 1.6+ both satisfy this configuration.
  required_version = ">= 1.6.0"

  required_providers {
    oci = {
      source = "oracle/oci"
      # 6.x is the current major line; allow newer majors only after testing.
      version = ">= 6.20.0, < 8.0.0"
    }
  }

  # State is local for Stage 2: one operator, one environment.
  # Move to an encrypted remote backend before any shared use — state holds
  # resource identifiers and is never committed (see ../.gitignore).
  #
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "automated-db-backup-cloud-sync/oci.tfstate"
  #   region = "eu-frankfurt-1"
  # }
}

provider "oci" {
  region = var.region

  # API-key authentication. Every value comes from variables (or from
  # ~/.oci/config when left null) — never from a file in this repository.
  tenancy_ocid        = var.tenancy_ocid
  user_ocid           = var.user_ocid
  fingerprint         = var.fingerprint
  private_key_path    = var.private_key_path
  config_file_profile = var.config_file_profile
}

# The Object Storage namespace is tenancy-scoped and required to address a
# bucket. Resolving it here keeps the bucket module provider-neutral.
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}
