################################################################################
# IRSA — one IAM policy PER BUCKET, plus an optional role
#
# Why per bucket and not one consolidated policy:
#
#   A consolidated policy would grant every attached principal access to every
#   bucket in the invocation. Buckets in this repository do not share a blast
#   radius — reporter-storage holds generated customer reports while
#   external-data holds raw extraction output, and a service that needs one has
#   no business reading the other. One policy per bucket keeps each grant
#   independently attachable and independently auditable, at the cost of a few
#   extra IAM objects (the account limit is 1500 policies, so this is free).
#
# The role is optional. With oidc_provider_arn and service_account unset, this
# file produces policies only and the EKS stack attaches them to whatever role it
# already manages.
################################################################################

locals {
  create_irsa_role = var.oidc_provider_arn != "" && var.service_account != ""

  # arn:aws:iam::123456789012:oidc-provider/oidc.eks.<region>.amazonaws.com/id/ABC
  #   -> oidc.eks.<region>.amazonaws.com/id/ABC
  oidc_provider_url = var.oidc_provider_arn != "" ? replace(
    var.oidc_provider_arn, "/^arn:[^:]+:iam::[0-9]+:oidc-provider\\//", ""
  ) : ""

  service_account_namespace = var.service_account != "" ? split(":", var.service_account)[0] : ""
  service_account_name      = var.service_account != "" ? split(":", var.service_account)[1] : ""
}

data "aws_iam_policy_document" "bucket_access" {
  for_each = var.buckets

  statement {
    sid    = "BucketLevelAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
    ]

    resources = [module.buckets[each.key].s3_bucket_arn]
  }

  statement {
    sid    = "ObjectLevelAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = ["${module.buckets[each.key].s3_bucket_arn}/*"]
  }

  # Without this the application can write to an SSE-KMS bucket but never read
  # back what it wrote.
  dynamic "statement" {
    for_each = each.value.kms_key_arn != null ? [each.value.kms_key_arn] : []

    content {
      sid    = "ObjectEncryptionKey"
      effect = "Allow"

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]

      resources = [statement.value]
    }
  }
}

resource "aws_iam_policy" "bucket_access" {
  for_each = var.buckets

  name        = "${module.naming.prefix}-${each.key}-s3-access"
  description = "Application access to the ${local.bucket_names[each.key]} bucket"
  policy      = data.aws_iam_policy_document.bucket_access[each.key].json

  tags = merge(module.naming.tags, { Name = "${module.naming.prefix}-${each.key}-s3-access" })

  lifecycle {
    # Exact 63 character check, run once the account id is known. A failing
    # precondition aborts the whole plan, so no bucket is created either.
    precondition {
      condition     = length(local.bucket_names[each.key]) <= 63
      error_message = "The bucket name for \"${each.key}\" would exceed the 63 character S3 limit. Shorten the logical name or the product name."
    }
  }
}

################################################################################
# Optional IRSA role
################################################################################

data "aws_iam_policy_document" "irsa_assume_role" {
  count = local.create_irsa_role ? 1 : 0

  statement {
    sid     = "AllowServiceAccountToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${local.service_account_namespace}:${local.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  count = local.create_irsa_role ? 1 : 0

  name                  = "${module.naming.name}-irsa"
  description           = "IRSA role for ${local.service_account_namespace}/${local.service_account_name} accessing ${var.product} object storage"
  assume_role_policy    = data.aws_iam_policy_document.irsa_assume_role[0].json
  force_detach_policies = true

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-irsa" })
}

resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = local.create_irsa_role ? var.buckets : {}

  role       = aws_iam_role.irsa[0].name
  policy_arn = aws_iam_policy.bucket_access[each.key].arn
}
