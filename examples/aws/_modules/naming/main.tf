################################################################################
# Naming and tagging contract
#
# Single source of truth for how every AWS resource in this repository is named
# and tagged. The convention is:
#
#   {product}-{environment}[-{component}]
#
# Examples: midaz-dev-postgres, reporter-prd-docdb, shared-dev-valkey, lerian-stg-vpc
#
# Every stack MUST derive names from this module. Hardcoded resource names are
# what makes dev/stg/prd collide inside a single AWS account, and what breaks
# the cross-stack tag:Name lookups this repository relies on.
#
# Secrets Manager paths follow the same rule: consumers build them as
# "<name>/<credential>", e.g. midaz-dev-postgres/password.
#
# Globally unique names (S3 buckets) additionally append the AWS account id,
# which the s3-bucket module resolves via aws_caller_identity.
################################################################################

locals {
  prefix = "${var.product}-${var.environment}"

  name = var.component == "" ? local.prefix : "${local.prefix}-${var.component}"

  standard_tags = {
    Product     = var.product
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "lerian-terraform-foundation"
  }

  tags = merge(local.standard_tags, var.extra_tags)
}
