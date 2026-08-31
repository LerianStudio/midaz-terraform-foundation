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
  description = "Product these buckets belong to. Pinned to \"br-sfn\" by validation: the derived bucket name (br-sfn-{env}-{logical}-{account_id}) IS the cross-stack discovery contract, and the correios rail reads it from OBJECT_STORAGE_BUCKET. A different value here silently produces a bucket the br-sfn release never writes to. Note this is br-sfn and NOT plugin-bc-correios, even though the rail runs that product's image — the bucket belongs to the monorepo deployment that owns it."
  type        = string
  default     = "br-sfn"

  validation {
    condition     = var.product == "br-sfn"
    error_message = "The product must be \"br-sfn\". To provision object storage for another product, copy this directory to examples/aws/products/<product>/s3 instead — products/plugin-bc-correios/s3 already exists for the standalone chart."
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
# Keyed by LOGICAL name. The key is what the rail's OBJECT_STORAGE_BUCKET
# resolves against, and helm_values indexes "correios-attachments" specifically
# — which is why the validation below requires that key to be present. Extra
# buckets are allowed and simply do not appear in helm_values.
#
# THE KEY DIFFERS FROM products/plugin-bc-correios/s3 ON PURPOSE. That root uses
# "bc-correios-attachments", matching its chart's own default. Here the component
# is called `correios` everywhere in br-sfn, so the bucket follows the rail
# vocabulary of the chart it belongs to. The real bucket names differ regardless
# (br-sfn-... vs plugin-bc-correios-...), so the two never collide and nothing
# migrates automatically between them.
################################################################################

variable "buckets" {
  description = <<-EOT
    Buckets to create, keyed by LOGICAL name. Each key becomes part of the real
    bucket name: {product}-{environment}-{logical_name}-{account_id}.

    Per bucket options (all optional): versioning_enabled, kms_key_arn,
    force_destroy, lifecycle_enabled, transition_ia_days,
    transition_glacier_days, expiration_days, noncurrent_expiration_days,
    abort_incomplete_multipart_upload_days, cors_rules. See
    _modules/s3-bucket/README.md for the full table and the ordering rules the
    module validates (glacier after IA, expiration after both).
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

  default = {
    "correios-attachments" = {}
  }

  validation {
    condition     = contains(keys(var.buckets), "correios-attachments")
    error_message = "The buckets map must contain the key \"correios-attachments\": it is the bucket the br-sfn correios rail expects in OBJECT_STORAGE_BUCKET, and helm_values indexes it by name. Additional buckets may be added alongside it."
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
  description = "Create the IAM role a br-sfn pod assumes to reach the bucket, and resolve the cluster OIDC provider to do it. TRUE is the normal path and makes this root depend on infra-base/eks existing — a harder prerequisite than the datastore roots have, because the OIDC lookup is a singular data source that fails the plan rather than resolving to nothing. FALSE emits the per-bucket IAM policies only, for an EKS stack that attaches them to a role it already manages."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster IAM OIDC provider. Leave EMPTY (the default) to derive it: the cluster name comes from module.network, data \"aws_eks_cluster\" reads its issuer URL and data \"aws_iam_openid_connect_provider\" turns that into the ARN. Set it explicitly only to point at a cluster this repository did not create — an explicit value skips both lookups entirely, which also makes the plan work with no EKS read permissions."
  type        = string
  default     = ""
}

variable "service_account" {
  description = <<-EOT
    Kubernetes service account allowed to assume the IRSA role, in
    "namespace:name" form (the notation examples/aws/infra-base/eks/iam.tf
    already uses).

    THE NAME HALF IS CONFIRMED FROM THE CHART, THE NAMESPACE HALF IS NOT.
    br-sfn.serviceAccountName falls back to br-sfn.fullname, which is
    nameOverride "br-sfn" (templates/_helpers.tpl:4-14, 33-38), and
    serviceAccount.create defaults to true (values.yaml:31-34). The namespace is
    whatever the release is installed into; check it before the first apply,
    because a mismatch fails at RUNTIME with AccessDenied rather than at apply
    time.

    THIS GRANT IS BROADER THAN THE CORREIOS RAIL, AND THE CHART GIVES NO WAY TO
    NARROW IT. br-sfn defines ONE chart-level ServiceAccount shared by every
    component — the helper is literally commented "shared by every component" —
    so the role created here is assumable by spb, spi, siloc, scr, slc-edge,
    desk and cockpit too, not only correios. Per-rail least privilege would need
    per-rail ServiceAccounts in the chart. Recorded here rather than papered
    over; if that matters for your threat model, set irsa_enabled = false and
    attach iam_policy_arns to a role scoped however the EKS stack scopes it.
  EOT

  type    = string
  default = "br-sfn:br-sfn"

  validation {
    condition     = var.service_account == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?:[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.service_account))
    error_message = "The service_account must be in \"namespace:name\" form, e.g. \"br-sfn:br-sfn\"."
  }
}

################################################################################
# Cross-stack context
################################################################################

variable "eks_cluster_name" {
  description = "Name of the EKS cluster whose OIDC provider is resolved. Leave empty (the default) to DERIVE \"lerian-{environment}-eks\" — the cluster belongs to infra-base and carries the \"lerian\" product label, NOT \"br-sfn\"."
  type        = string
  default     = ""
}
