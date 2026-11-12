variable "compartment_id" {
  description = "Compartment that owns the bucket."
  type        = string
}

variable "namespace" {
  description = "Object Storage namespace that owns the bucket."
  type        = string
}

variable "bucket_name" {
  description = "Bucket name, unique inside the namespace."
  type        = string
}

variable "region" {
  description = "Region identifier used to build the S3-compatible endpoint."
  type        = string
}

variable "enable_versioning" {
  description = "Keep object versions so an overwrite or delete can be recovered."
  type        = bool
  default     = true
}

variable "archive_after_days" {
  description = "Transition archives to the Archive tier after N days; 0 disables the rule."
  type        = number
  default     = 30
}

variable "delete_after_days" {
  description = "Delete archives after N days; 0 disables the rule."
  type        = number
  default     = 0
}

variable "freeform_tags" {
  description = "Freeform tags applied to the bucket."
  type        = map(string)
  default     = {}
}
