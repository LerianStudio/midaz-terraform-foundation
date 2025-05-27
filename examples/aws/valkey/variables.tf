variable "name" {
  description = "Base name for resources"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_name" {
  description = "VPC name where Valkey instance will be created"
  type        = string
}

variable "node_type" {
  description = "Valkey node type"
  type        = string
  default     = "cache.m7g.large"
}

variable "engine_version" {
  description = "Valkey engine version"
  type        = string
  default     = "7.2"
}

variable "parameter_group_family" {
  description = "Valkey parameter group family"
  type        = string
  default     = "valkey7"
}

variable "maintenance_window" {
  description = "Maintenance window"
  type        = string
  default     = "mon:00:00-mon:03:00"
}

variable "parameters" {
  description = "A list of Valkey parameters to apply"
  type = list(object({
    name  = string
    value = string
  }))
  default = [
    {
      name  = "latency-tracking"
      value = "yes"
    }
  ]
}

variable "apply_immediately" {
  description = "Specifies whether any modifications are applied immediately, or during the next maintenance window"
  type        = bool
  default     = false
}

variable "additional_tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}
variable "dns_name" {
  description = "DNS record name (without zone name)"
  type        = string
  default     = "redis"
}

variable "dns_zone_name" {
  description = "Route53 zone name"
  type        = string
  default     = "midaz.internal"
}

# transit_encryption_mode and auth_token will be used once Midaz accepts TLS certificates configuration
# variable "transit_encryption_mode" {
#   description = "Transit encryption mode for Valkey cluster. Valid values are preferred and required"
#   type        = string
#   default     = "preferred"
#   validation {
#     condition     = contains(["preferred", "required"], var.transit_encryption_mode)
#     error_message = "transit_encryption_mode must be either 'preferred' or 'required'"
#   }
# }

variable "transit_encryption_enabled" {
  description = "Enable transit encryption for Valkey cluster"
  type        = bool
  default     = true
}
