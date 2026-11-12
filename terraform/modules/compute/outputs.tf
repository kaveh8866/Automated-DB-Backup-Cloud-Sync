output "instance_id" {
  description = "OCID of the compute instance."
  value       = oci_core_instance.this.id
}

output "public_ip" {
  description = "Public IPv4 address of the instance."
  value       = data.oci_core_vnic.primary.public_ip_address
}

output "private_ip" {
  description = "Private IPv4 address of the instance inside the VCN."
  value       = data.oci_core_vnic.primary.private_ip_address
}

output "availability_domain" {
  description = "Availability domain the instance landed in."
  value       = local.availability_domain
}

output "image_id" {
  description = "Image resolved (or supplied) for the instance."
  value       = local.resolved_image_id
}

output "is_flex_shape" {
  description = "Whether shape_config was applied (flex shapes only)."
  value       = local.is_flex_shape
}
