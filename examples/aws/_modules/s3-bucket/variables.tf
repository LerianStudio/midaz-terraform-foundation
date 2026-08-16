################################################################################
# Contract variables
#
# NOTE: this module has no `mode`. See README.md — object storage is always owned
# by the product that writes to it, there is no shared bucket to resolve.
################################################################################

variable "product" {
  description = "Lerian product owning these buckets (e.g. reporter, fetcher, plugin-bc-correios)."
  type        = string
}

variable "environment" {
  description = "Deployment environment. One of dev, stg or prd."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "The environment must be one of: dev, stg, prd."
  }
}

################################################################################
# Buckets
################################################################################

variable "buckets" {
  description = <<-EOT
    Buckets to create, keyed by LOGICAL name. Each key becomes part of the real
    bucket name: {product}-{environment}-{logical_name}-{account_id}.

    Per bucket options:
      versioning_enabled                     enable object versioning (default true)
      kms_key_arn                            SSE-KMS with this CMK instead of SSE-S3/AES256
      force_destroy                          allow terraform destroy on a non-empty bucket
      lifecycle_enabled                      emit a lifecycle configuration at all (default true)
      transition_ia_days                     days before transitioning to the IA class
      transition_glacier_days                days before transitioning to the Glacier class
      expiration_days                        days before current versions expire
      noncurrent_expiration_days             days before noncurrent versions expire
      abort_incomplete_multipart_upload_days days before abandoned multipart uploads are purged
      cors_rules                             CORS rules, empty means no CORS configuration
  EOT

  type = map(object({
    versioning_enabled                     = optional(bool, true)
    kms_key_arn                            = optional(string, null)
    force_destroy                          = optional(bool, false)
    lifecycle_enabled                      = optional(bool, true)
    transition_ia_days                     = optional(number, null)
    transition_glacier_days                = optional(number, null)
    expiration_days                        = optional(number, null)
    noncurrent_expiration_days             = optional(number, null)
    abort_incomplete_multipart_upload_days = optional(number, 7)
    cors_rules = optional(list(object({
      allowed_headers = optional(list(string), ["*"])
      allowed_methods = list(string)
      allowed_origins = list(string)
      expose_headers  = optional(list(string), [])
      max_age_seconds = optional(number, 3600)
    })), [])
  }))

  validation {
    condition     = length(var.buckets) > 0
    error_message = "At least one bucket must be declared."
  }

  validation {
    condition = alltrue([
      for k, v in var.buckets : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", k))
    ])
    error_message = "Every bucket logical name must be lowercase alphanumeric with single hyphens, and must not start or end with a hyphen."
  }

  validation {
    condition = alltrue([
      for k, v in var.buckets : !can(regex("--", k))
    ])
    error_message = "Bucket logical names must not contain consecutive hyphens."
  }

  # S3 caps bucket names at 63 characters. The account id contributes a fixed 13
  # ("-" plus 12 digits), so a logical name over 30 characters cannot fit for any
  # realistic product/environment pair. The exact check, which needs the resolved
  # account id, runs as a precondition in iam.tf.
  validation {
    condition = alltrue([
      for k, v in var.buckets : length(k) <= 30
    ])
    error_message = "Bucket logical names must be at most 30 characters, otherwise the final name cannot fit the 63 character S3 limit."
  }

  validation {
    condition = alltrue([
      for k, v in var.buckets :
      v.transition_ia_days == null || v.transition_glacier_days == null || v.transition_glacier_days > v.transition_ia_days
    ])
    error_message = "When both are set, transition_glacier_days must be greater than transition_ia_days."
  }

  validation {
    condition = alltrue([
      for k, v in var.buckets :
      v.expiration_days == null || (
        (v.transition_ia_days == null || v.expiration_days > v.transition_ia_days) &&
        (v.transition_glacier_days == null || v.expiration_days > v.transition_glacier_days)
      )
    ])
    error_message = "The expiration_days must be greater than any configured transition day count."
  }

  validation {
    condition = alltrue([
      for k, v in var.buckets :
      v.abort_incomplete_multipart_upload_days == null || v.abort_incomplete_multipart_upload_days >= 1
    ])
    error_message = "The abort_incomplete_multipart_upload_days must be at least 1 when set."
  }
}

variable "transition_ia_storage_class" {
  description = "Storage class used by transition_ia_days."
  type        = string
  default     = "STANDARD_IA"

  validation {
    condition     = contains(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING"], var.transition_ia_storage_class)
    error_message = "The transition_ia_storage_class must be one of: STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING."
  }
}

variable "transition_glacier_storage_class" {
  description = "Storage class used by transition_glacier_days."
  type        = string
  default     = "GLACIER"

  validation {
    condition     = contains(["GLACIER", "GLACIER_IR", "DEEP_ARCHIVE"], var.transition_glacier_storage_class)
    error_message = "The transition_glacier_storage_class must be one of: GLACIER, GLACIER_IR, DEEP_ARCHIVE."
  }
}

variable "require_latest_tls_policy" {
  description = "Additionally deny requests negotiating a TLS version older than 1.2. The policy denying plain HTTP is always attached and is not optional."
  type        = bool
  default     = true
}

################################################################################
# IRSA
################################################################################

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster IAM OIDC provider. Set together with service_account to have this module create the IRSA role. Empty creates the IAM policies only."
  type        = string
  default     = ""
}

variable "service_account" {
  description = "Kubernetes service account allowed to assume the IRSA role, in \"namespace:name\" form (the same notation examples/aws/infra-base/eks/iam.tf uses). Empty creates the IAM policies only."
  type        = string
  default     = ""

  validation {
    condition     = var.service_account == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?:[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.service_account))
    error_message = "The service_account must be in \"namespace:name\" form, e.g. \"reporter:reporter\"."
  }
}

################################################################################
# Tagging
################################################################################

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set."
  type        = map(string)
  default     = {}
}
