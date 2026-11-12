variable "compartment_id" {
  description = "Compartment that owns the instance."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID; availability domains are tenancy-scoped."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to instance and VNIC display names."
  type        = string
}

variable "subnet_id" {
  description = "Subnet the primary VNIC attaches to."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain name; null means the first AD in the region."
  type        = string
  default     = null
}

variable "instance_shape" {
  description = "Compute shape (default VM.Standard.A1.Flex, Always Free eligible)."
  type        = string
}

variable "instance_ocpus" {
  description = "OCPUs for flex shapes."
  type        = number
}

variable "instance_memory_gbs" {
  description = "Memory in GB for flex shapes."
  type        = number
}

variable "boot_volume_size_gbs" {
  description = "Boot volume size in GB."
  type        = number
}

variable "ssh_public_key" {
  description = "SSH public key content injected through instance metadata."
  type        = string
}

variable "user_data" {
  description = "Base64-encoded cloud-init payload."
  type        = string
}

variable "hostname_label" {
  description = "DNS label for the primary VNIC."
  type        = string
}

variable "image_id" {
  description = "Explicit image OCID; null resolves the latest matching Ubuntu image for the shape."
  type        = string
  default     = null
}

variable "image_operating_system" {
  description = "Operating system used when image_id is null."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "image_os_version" {
  description = "OS version used when image_id is null."
  type        = string
  default     = "24.04"
}

variable "freeform_tags" {
  description = "Freeform tags applied to every resource."
  type        = map(string)
  default     = {}
}
