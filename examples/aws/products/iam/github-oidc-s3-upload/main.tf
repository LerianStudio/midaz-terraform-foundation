################################################################################
# products/iam/github-oidc-s3-upload — the identity a release pipeline uses to
# publish migrations into this account's migrations bucket
#
# The tenant manager reads a service's SQL migrations out of an S3 bucket in the
# APPLICATION account, under {channel}/{service}/{module}/{dbType}/. The files
# get there from the service's release pipeline: go-release's `S3 Upload` job
# copies them on every tag. That job authenticates by asking GitHub for a fresh
# OIDC token and calling sts:AssumeRoleWithWebIdentity — so the principal a trust
# policy must name is GITHUB'S OIDC PROVIDER, not a role in another AWS account.
#
# Three parts, all of them load-bearing:
#
#   1. GitHub's OIDC issuer, registered as an identity provider in THIS account,
#      so a token minted by GitHub Actions is a principal this account
#      recognises at all;
#   2. a trust policy pinning `:sub` to TAG pushes of ONE repository and `:aud`
#      to sts.amazonaws.com, so exactly one repository's releases can assume it;
#   3. one inline policy with s3:PutObject over exactly the prefixes that
#      repository publishes to.
#
# THE ROLE LIVES IN THE ACCOUNT THAT OWNS THE BUCKET, which is what makes a
# bucket policy unnecessary: an in-account role with s3:PutObject is sufficient,
# and _modules/s3-bucket does not have to grow a bucket-policy input.
#
# WHY IT LIVES UNDER products/ WHEN IT IS NOT A PRODUCT. lerian-infra discovers
# roots by walking products/*/* and nothing else, and its infra-base stage is
# hardcoded to exactly vpc and eks. A root outside that shape has no target, no
# ordering, no state key and no account guard. Precedent:
# products/iam/oidc-cross-account-role, products/lerian-platform/dns.
#
# Deploy order: the bucket first (products/tenant-manager/s3, here), then this
# root, then the `aws_role_arn` entry in the other repository's release.yml.
# Until that last step lands, NOTHING assumes this role.
################################################################################

module "naming" {
  source = "../../../_modules/naming"

  product     = local.repository_name
  environment = var.environment
  component   = "migrations-upload"
  extra_tags  = var.extra_tags
}

# Partition rather than a literal "aws": the same ARNs have to render correctly in
# GovCloud and China, where the partition is aws-us-gov / aws-cn.
data "aws_partition" "current" {}

locals {
  repository_name = split("/", var.github_repository)[1]

  ##############################################################################
  # The channel folders — DERIVED, NEVER AN INPUT
  #
  # go-release picks the top-level folder from the tag's channel, and the
  # mapping is its code, not a preference of this estate:
  #
  #   *-beta*                      -> development/
  #   *-rc*                        -> staging/
  #   ^v[0-9]+\.[0-9]+\.[0-9]+$    -> production/
  #
  # An `s3_uploads` entry is NOT conditional on the channel: it runs on every tag
  # the repository cuts. A service that cuts a beta on each merge to develop
  # therefore writes to development/ constantly, and a policy listing only
  # production/ turns every one of those merges into a red `S3 Upload` job — the
  # step runs under `set -euo pipefail`, so one AccessDenied kills the job.
  #
  # Listing the three in a tfvars would make "all the channels, and only the
  # channels" a thing somebody has to remember. Deriving them here makes it true
  # by construction, and the cost of the two folders nothing reads today is zero.
  ##############################################################################
  channel_folders = ["development", "staging", "production"]

  # {channel}/{repo}/* — one IAM wildcard, and it crosses "/", so the module and
  # dbType segments go-release appends (br-consignado-gw/consignado/postgresql/…)
  # are already covered at any depth.
  object_prefix_arns = [
    for channel in local.channel_folders :
    "arn:${data.aws_partition.current.partition}:s3:::${var.migrations_bucket_name}/${channel}/${local.repository_name}/*"
  ]

  upload_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PutMigrationObjects"
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = local.object_prefix_arns
    }]
  })
}

################################################################################
# GitHub's OIDC issuer, registered in this account
#
# NO thumbprint_list. Since 2023 AWS validates token.actions.githubusercontent.com
# against its own trust store and ignores whatever thumbprint is recorded; pinning
# GitHub's intermediate CA fingerprint here would be a value that means nothing,
# rots on rotation, and reads as a security control.
#
# ONE PER ACCOUNT. AWS refuses a second provider for the same URL
# (EntityAlreadyExists), so a second repository that needs the same treatment
# reuses this one via the oidc_provider_arn output rather than registering its own.
################################################################################

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-oidc" })
}

################################################################################
# Trust policy
#
# :sub IS THE BOUNDARY AND IT IS FAIL-CLOSED ON TAGS. Every GitHub Actions token
# in the world carries the same issuer, so :sub is the only thing keeping other
# repositories out. StringLike rather than StringEquals because the tag name is
# part of the subject and changes on every release — the wildcard is on the tag,
# never on the repository.
#
#   repo:OWNER/REPO:ref:refs/tags/v3.0.0-rc.9   admitted
#   repo:OWNER/REPO:ref:refs/heads/develop      REFUSED (a branch push is a
#                                               different subject entirely)
#   repo:OWNER/REPO:pull_request                REFUSED
#   repo:OTHER/REPO:ref:refs/tags/v1.0.0        REFUSED
#
# The branch case is the one that matters: a workflow run from a pull request of
# a fork cannot mint a token this role accepts, so a contributor cannot reach the
# bucket by editing a workflow file.
#
# :aud pins sts.amazonaws.com, the audience go-release requests. The provider's
# client_id_list already requires it, so a token minted for another audience is
# refused before any condition is read; it is written out because AWS documents
# pinning both for web-identity trust, and because a second audience added to
# client_id_list later would otherwise widen this role silently.
################################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AllowRepositoryTagPushToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/tags/*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                  = var.role_name
  description           = "Release pipeline of ${var.github_repository} publishing migrations to s3://${var.migrations_bucket_name}"
  assume_role_policy    = data.aws_iam_policy_document.assume_role.json
  force_detach_policies = true

  # The AWS default (1 hour), written out because it is the ceiling on a
  # credential handed to a CI runner. Raising it would not make an upload more
  # reliable: the job finishes in seconds, so a longer session only lengthens the
  # window in which a leaked credential still works.
  max_session_duration = 3600

  tags = merge(module.naming.tags, { Name = var.role_name })
}

################################################################################
# Grants — one inline policy, one verb
#
# INLINE and not managed: an inline policy cannot be attached to a second
# principal, and deleting the role deletes it too, with no orphan left behind for
# something else to pick up.
#
# NO s3:DeleteObject, and this is a correctness constraint rather than a taste.
# The tenant manager decides what to run by comparing the migrations a tenant has
# APPLIED against the ones AVAILABLE in the bucket. Removing a .sql a tenant
# already applied puts a hole in that comparison. A release pipeline only ever
# adds files, so it never needs to remove one.
#
# NO s3:ListBucket either: go-release copies each file by key. Listing is the
# reader's job, and the reader is not this identity.
################################################################################

resource "aws_iam_role_policy" "upload" {
  name = "${var.role_name}-policy"
  role = aws_iam_role.this.id

  # jsonencode of a local rather than aws_iam_policy_document, and the reason is
  # the test: a data source is a provider round trip, so under mock_provider the
  # rendered document is generated noise and the ONE thing worth asserting — the
  # set of prefixes actually attached to the role — cannot be read at all.
  # Built here, tests/reach_and_subject.tftest.hcl reads the real document.
  policy = local.upload_policy
}
