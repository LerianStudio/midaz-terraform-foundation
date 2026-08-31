################################################################################
# Stack identity
#
# NOTE: there is no `mode` variable here, unlike every sibling root. See the
# header of main.tf — _modules/s3-bucket has no mode input because object storage
# has no shared tier to resolve.
################################################################################

variable "region" {
  description = "AWS region the buckets are created in. Keep it equal to the region of the sibling datastore roots: the bucket is reached over the regional S3 endpoint and a cross-region bucket pays inter-region transfer on every object."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "The region must be a valid AWS region identifier, e.g. us-east-1 or sa-east-1."
  }
}

variable "product" {
  description = "Product these buckets belong to. Pinned to \"br-consignado-gw\" by validation: the derived bucket name (br-consignado-gw-{env}-{logical}-{account_id}) IS the cross-stack discovery contract, and the service reads it from AVERBACAO_ARTIFACTS_BUCKET. A different value here silently produces a bucket the gateway never writes to."
  type        = string
  default     = "br-consignado-gw"

  validation {
    condition     = var.product == "br-consignado-gw"
    error_message = "The product must be \"br-consignado-gw\". To provision object storage for another product, copy this directory to examples/aws/products/<product>/s3 instead."
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

variable "extra_tags" {
  description = "Additional tags merged on top of the standard Lerian tag set (Product, Environment, ManagedBy, Repository)."
  type        = map(string)
  default     = {}
}

################################################################################
# Buckets
#
# Keyed by LOGICAL name. The key is what AVERBACAO_ARTIFACTS_BUCKET resolves
# against, and helm_values indexes "averbacao-artifacts" specifically — which is why
# the validation below requires that key, WITH Object Lock, WITH COMPLIANCE mode and
# WITH at least 1827 days of retention. The gateway asserts all three at boot and
# refuses to start otherwise, so a plan-time refusal here is strictly better than a
# CrashLoopBackOff after the bucket has been created unfixably wrong.
################################################################################

variable "buckets" {
  description = <<-EOT
    Buckets to create, keyed by LOGICAL name. Each key becomes part of the real
    bucket name: {product}-{environment}-{logical_name}-{account_id}.

    Per bucket options (all optional): versioning_enabled, kms_key_arn,
    force_destroy, object_lock_enabled, object_lock_mode, object_lock_days,
    object_lock_years, lifecycle_enabled, transition_ia_days,
    transition_glacier_days, expiration_days, noncurrent_expiration_days,
    abort_incomplete_multipart_upload_days, cors_rules. See
    _modules/s3-bucket/README.md for the full table and the ordering rules the
    module validates (glacier after IA, expiration after both).

    OBJECT LOCK IS SETTABLE ONLY AT BUCKET CREATION. It cannot be enabled later and
    cannot be disabled once enabled; fixing it means replacing the bucket, and the
    objects already written under COMPLIANCE cannot be deleted, so the old bucket
    cannot be cleaned up either. The validations below exist because this is a
    one-shot decision on a money path.
  EOT

  type = map(object({
    versioning_enabled                     = optional(bool, true)
    kms_key_arn                            = optional(string, null)
    force_destroy                          = optional(bool, false)
    object_lock_enabled                    = optional(bool, false)
    object_lock_mode                       = optional(string, null)
    object_lock_days                       = optional(number, null)
    object_lock_years                      = optional(number, null)
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

  default = {
    "averbacao-artifacts" = {
      object_lock_enabled = true
      object_lock_mode    = "COMPLIANCE"
      object_lock_days    = 1827
      lifecycle_enabled   = false
    }
  }

  validation {
    condition     = contains(keys(var.buckets), "averbacao-artifacts")
    error_message = "The buckets map must contain the key \"averbacao-artifacts\": it is the bucket AVERBACAO_ARTIFACTS_BUCKET points at, and helm_values indexes it by name. Additional buckets may be added alongside it."
  }

  validation {
    condition     = try(var.buckets["averbacao-artifacts"].object_lock_enabled, false)
    error_message = "averbacao-artifacts must set object_lock_enabled = true. br-consignado-gw reads the bucket's Object Lock configuration at boot and REFUSES TO START without it — and Object Lock cannot be enabled on an existing bucket, so a bucket created without it has to be replaced."
  }

  validation {
    condition     = try(var.buckets["averbacao-artifacts"].object_lock_mode, "") == "COMPLIANCE"
    error_message = "averbacao-artifacts must use object_lock_mode = \"COMPLIANCE\". The gateway pins COMPLIANCE when it writes. GOVERNANCE would let any principal holding s3:BypassGovernanceRetention delete an averbação artefact early, which is the one property this custody trail cannot lose."
  }

  # 1827 days = 5 years, the floor the gateway asserts at boot. Expressed in days
  # rather than years because that is the unit the assertion uses; object_lock_years
  # would pass Terraform and fail the boot check.
  validation {
    condition     = try(var.buckets["averbacao-artifacts"].object_lock_days, 0) >= 1827
    error_message = "averbacao-artifacts must set object_lock_days to at least 1827 (five years). The gateway asserts this exact floor at boot and refuses to start below it. Use object_lock_days, not object_lock_years: the boot check reads days."
  }

  # An expiration rule on a COMPLIANCE-locked object does not delete it; it just
  # accumulates failed lifecycle transitions while looking like a working retention
  # policy in the console.
  validation {
    condition     = !try(var.buckets["averbacao-artifacts"].lifecycle_enabled, true) && try(var.buckets["averbacao-artifacts"].expiration_days, null) == null
    error_message = "averbacao-artifacts must set lifecycle_enabled = false and no expiration_days. Retention is the policy on a WORM bucket; a lifecycle expiry cannot delete a COMPLIANCE-locked object and only produces silent, repeated lifecycle failures."
  }
}

variable "transition_ia_storage_class" {
  description = "Storage class used by transition_ia_days. Passed through to the module."
  type        = string
  default     = "STANDARD_IA"
}

variable "transition_glacier_storage_class" {
  description = "Storage class used by transition_glacier_days. Passed through to the module."
  type        = string
  default     = "GLACIER"
}

variable "require_latest_tls_policy" {
  description = "Additionally deny requests negotiating a TLS version older than 1.2. The policy denying plain HTTP is always attached by the module and is not optional."
  type        = bool
  default     = true
}

################################################################################
# IRSA
################################################################################

variable "irsa_enabled" {
  description = "Create the IAM role a gateway pod assumes to reach the bucket, and resolve the cluster OIDC provider to do it. TRUE is the normal path and makes this root depend on infra-base/eks existing — a harder prerequisite than the datastore roots have, because the OIDC lookup is a singular data source that fails the plan rather than resolving to nothing. FALSE emits the per-bucket IAM policies only, for an EKS stack that attaches them to a role it already manages."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster IAM OIDC provider. Leave EMPTY (the default) to derive it: the cluster name comes from module.network, data \"aws_eks_cluster\" reads its issuer URL and data \"aws_iam_openid_connect_provider\" turns that into the ARN. Set it explicitly only to point at a cluster this repository did not create — an explicit value skips both lookups entirely, which also makes the plan work with no EKS read permissions."
  type        = string
  default     = ""
}

variable "service_account" {
  description = "Kubernetes service account allowed to assume the IRSA role, in \"namespace:name\" form (the notation examples/aws/infra-base/eks/iam.tf already uses). CONFIRM IT AGAINST THE CHART: br-consignado-gw ships no Helm chart, so the default below is the intended convention rather than a measured fact. A mismatch produces a role no pod can assume, and the failure surfaces at runtime as AccessDenied on the first custody write, not at apply time."
  type        = string
  default     = "consignado:br-consignado-gw"

  validation {
    condition     = var.service_account == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?:[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.service_account))
    error_message = "The service_account must be in \"namespace:name\" form, e.g. \"consignado:br-consignado-gw\"."
  }
}

################################################################################
# Cross-stack context
################################################################################

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose OIDC provider is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT this product's."
  type        = string
  default     = ""
}
