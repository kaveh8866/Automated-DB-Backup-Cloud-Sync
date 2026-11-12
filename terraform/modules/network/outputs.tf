output "vcn_id" {
  description = "OCID of the created VCN."
  value       = oci_core_vcn.this.id
}

output "subnet_id" {
  description = "OCID of the public subnet."
  value       = oci_core_subnet.public.id
}

output "security_list_id" {
  description = "OCID of the security list holding the SSH-only ingress rule."
  value       = oci_core_security_list.public.id
}

output "internet_gateway_id" {
  description = "OCID of the internet gateway."
  value       = oci_core_internet_gateway.this.id
}

output "route_table_id" {
  description = "OCID of the public route table."
  value       = oci_core_route_table.public.id
}

output "ingress_ports" {
  description = "Ports actually opened to the internet by this module."
  value       = [for rule in local.ingress_rules : rule.port]
}
