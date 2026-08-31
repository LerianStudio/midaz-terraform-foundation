variable "product" {
  description = "Lerian product this resource belongs to (e.g. midaz, reporter, br-sisbajud). Two reserved labels: \"lerian\" for the base foundation (VPC, EKS) and \"shared\" for the shared datastore tier owned by products/shared-resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.product))
    error_message = "The product must be lowercase alphanumeric with single hyphens, and must not start or end with a hyphen."
  }

  validation {
    condition     = !can(regex("--", var.product))
    error_message = "The product must not contain consecutive hyphens (rejected by RDS and DocumentDB identifiers)."
  }

  validation {
    condition     = length(var.product) <= 24
    error_message = "The product must be at most 24 characters to keep derived resource names within AWS limits."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

variable "component" {
  description = "Optional component suffix appended to the prefix (e.g. postgres, docdb, valkey). Leave empty to get the bare prefix."
  type        = string
  default     = ""

  validation {
    condition     = var.component == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.component))
    error_message = "The component must be lowercase alphanumeric with single hyphens, and must not start or end with a hyphen."
  }
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}
