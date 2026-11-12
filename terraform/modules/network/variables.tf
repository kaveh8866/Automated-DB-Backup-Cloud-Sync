variable "compartment_id" {
  description = "Compartment that owns the network resources."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to every resource display name."
  type        = string
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN."
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "Source CIDR allowed to reach TCP 22. The only inbound rule in this stack."
  type        = string
}

variable "vcn_dns_label" {
  description = "DNS label for the VCN (letters/digits, max 15)."
  type        = string
  default     = "cloudguarddb"
}

variable "subnet_dns_label" {
  description = "DNS label for the subnet (letters/digits, max 15)."
  type        = string
  default     = "backup"
}

variable "freeform_tags" {
  description = "Freeform tags applied to every resource."
  type        = map(string)
  default     = {}
}
