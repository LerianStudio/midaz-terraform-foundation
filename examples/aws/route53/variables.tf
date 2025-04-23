variable "name" {
  description = "Base name for resources"
  type        = string
  default     = "midaz-foundation"
}

variable "environment" {
  description = "Deployment environment: dev, hml, or prod"
  type        = string
  default     = "dev"
}

variable "private_domain_name" {
  description = "Domain name for the private hosted zone"
  type        = string
  default     = "midaz.internal"
}

variable "vpc_id" {
  description = "VPC ID for private hosted zone"
  type        = string
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
