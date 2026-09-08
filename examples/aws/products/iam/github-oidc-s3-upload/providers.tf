################################################################################
# Provider
#
# DECISION: no `default_tags` block, the same decision documented in
# infra-base/vpc/providers.tf and products/iam/oidc-cross-account-role.
# Every resource this root creates is tagged explicitly from module.naming.tags.
#
# ONE PROVIDER, ONE ACCOUNT. The role and the GitHub identity provider both live
# in the account that OWNS the migrations bucket, which is why no bucket policy
# is needed: an in-account role with s3:PutObject is enough, and the
# _modules/s3-bucket module has no bucket-policy input to grow.
################################################################################

provider "aws" {
  region = var.region
}
