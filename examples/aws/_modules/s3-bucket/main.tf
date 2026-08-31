################################################################################
# S3 object storage
#
# In the Helm charts object storage is SeaweedFS. On AWS it becomes S3. Three
# products need it:
#
#   reporter             -> reporter-storage      (generated reports)
#   fetcher              -> external-data         (extracted source data)
#   plugin-bc-correios   -> bc-correios-attachments
#
# One module invocation creates N buckets for one product, each with its own
# least-privilege IAM policy for IRSA. See README.md.
################################################################################

module "naming" {
  source = "../naming"

  product     = var.product
  environment = var.environment
  component   = "s3"
  extra_tags  = var.extra_tags
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # NAMING EXCEPTION: S3 bucket names are globally unique across every AWS
  # account, so the account id is appended. The prefix still comes from the
  # naming module, per the repository contract.
  bucket_names = {
    for logical_name, config in var.buckets :
    logical_name => "${module.naming.prefix}-${logical_name}-${local.account_id}"
  }

  # IA and Glacier transitions share one element type so they can be concatenated.
  lifecycle_transitions = {
    for logical_name, config in var.buckets :
    logical_name => concat(
      config.transition_ia_days != null ? [{
        days          = config.transition_ia_days
        storage_class = var.transition_ia_storage_class
      }] : [],
      config.transition_glacier_days != null ? [{
        days          = config.transition_glacier_days
        storage_class = var.transition_glacier_storage_class
      }] : [],
    )
  }

  # Every optional block is expressed as an empty list rather than a null, because
  # the upstream module does flatten([rule.value.expiration]) — a null would
  # render an empty, invalid block instead of no block at all.
  lifecycle_rules = {
    for logical_name, config in var.buckets :
    logical_name => config.lifecycle_enabled ? [{
      id                                     = "lerian-lifecycle"
      enabled                                = true
      abort_incomplete_multipart_upload_days = coalesce(config.abort_incomplete_multipart_upload_days, 7)
      transition                             = local.lifecycle_transitions[logical_name]

      expiration = config.expiration_days != null ? [{
        days = config.expiration_days
      }] : []

      noncurrent_version_expiration = config.noncurrent_expiration_days != null ? [{
        days = config.noncurrent_expiration_days
      }] : []
    }] : []
  }

  # WORM. The upstream module reads exactly rule.default_retention.{mode,days,years}
  # and creates aws_s3_bucket_object_lock_configuration only when object_lock_enabled
  # is true AND rule.default_retention is non-null — an empty map here therefore means
  # "no lock", not "a lock with defaults".
  object_lock_configuration = {
    for logical_name, config in var.buckets :
    logical_name => config.object_lock_enabled ? {
      rule = {
        default_retention = {
          mode  = config.object_lock_mode
          days  = config.object_lock_days
          years = config.object_lock_years
        }
      }
    } : {}
  }

  server_side_encryption = {
    for logical_name, config in var.buckets :
    logical_name => {
      rule = {
        apply_server_side_encryption_by_default = config.kms_key_arn != null ? {
          sse_algorithm     = "aws:kms"
          kms_master_key_id = config.kms_key_arn
          } : {
          sse_algorithm = "AES256"
        }
        bucket_key_enabled = true
      }
    }
  }
}

module "buckets" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.15.4"

  for_each = var.buckets

  bucket        = local.bucket_names[each.key]
  force_destroy = each.value.force_destroy

  versioning = {
    enabled = each.value.versioning_enabled
  }

  # Object Lock is a CREATE-TIME property of the bucket. It cannot be enabled on an
  # existing bucket, and it cannot be disabled once enabled: turning it on later
  # means replacing the bucket and re-uploading everything in it.
  object_lock_enabled       = each.value.object_lock_enabled
  object_lock_configuration = local.object_lock_configuration[each.key]

  server_side_encryption_configuration = local.server_side_encryption[each.key]

  # Public access block, all four flags on.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # ACLs disabled entirely, the bucket owner owns every object.
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  # Plain HTTP is always denied. TLS version floor is opt-out.
  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = var.require_latest_tls_policy

  lifecycle_rule = local.lifecycle_rules[each.key]
  cors_rule      = each.value.cors_rules

  tags = merge(module.naming.tags, { Name = local.bucket_names[each.key] })
}
