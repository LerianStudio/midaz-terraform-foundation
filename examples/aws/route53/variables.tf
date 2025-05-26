variable "name" {
  description = "Base name for resources"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "private_domain_name" {
  description = "Domain name for the private hosted zone"
  type        = string
  default     = "midaz.internal"
}

variable "additional_vpcs" {
  description = "List of additional VPC IDs to associate with the private hosted zone"
  type        = list(string)
  default     = []
}

variable "additional_tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}

variable "vpc_name" {
  description = "VPC name to be used to filter the VPC id"
  type        = string
}
