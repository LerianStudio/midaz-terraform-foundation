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

  # A writer that cannot read the lock configuration cannot tell whether the object
  # it just wrote is actually retained, which on a custody bucket is the only fact
  # that matters.
  dynamic "statement" {
    for_each = each.value.object_lock_enabled ? [1] : []

    content {
      sid    = "ObjectLockBucketLevel"
      effect = "Allow"

      actions = [
        # A writer that cannot read the lock configuration cannot tell whether the
        # object it just wrote is actually retained, which on a custody bucket is the
        # only fact that matters. br-consignado-gw refuses to boot without this call:
        # it asserts the bucket carries a COMPLIANCE default of at least 1827 days.
        "s3:GetBucketObjectLockConfiguration",
        # ListObjectVersions. NOT covered by s3:ListBucket — a versioned custody
        # bucket is enumerated by version, and the retained-storage client does
        # exactly that when recovering a partially written artefact.
        "s3:ListBucketVersions",
      ]

      resources = [module.buckets[each.key].s3_bucket_arn]
    }
  }

  # s3:DeleteObject is withheld on a WORM bucket. COMPLIANCE protects the object
  # VERSIONS — nobody can remove them — but DeleteObject on a versioned bucket
  # still writes a DELETE MARKER, and a delete marker hides the artefact from an
  # unversioned GET and from a plain ListObjectsV2. The bytes survive; the evidence
  # stops being findable by anyone who does not know to look at versions. No Lerian
  # retained-storage caller invokes DeleteObject, so nothing legitimate loses a
  # capability here.
  statement {
    sid    = "ObjectLevelAccess"
    effect = "Allow"

    actions = concat(
      [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ],
      each.value.object_lock_enabled ? [] : ["s3:DeleteObject"],
    )

    resources = ["${module.buckets[each.key].s3_bucket_arn}/*"]
  }

  # s3:PutObjectRetention IS REQUIRED even though no caller invokes an API by that
  # name. AWS evaluates it on any PutObject that carries ObjectLockRetainUntilDate,
  # which is exactly how br-consignado-gw writes an averbação artefact
  # (ObjectLockMode: COMPLIANCE + ObjectLockRetainUntilDate, inline on the write).
  # Omit it and every custody write fails with AccessDenied naming an action the
  # code never calls — an hour of confusion at the worst possible moment.
  #
  # s3:BypassGovernanceRetention is DELIBERATELY ABSENT and must stay absent. It is
  # the one permission that lets a principal delete a GOVERNANCE-retained object
  # early: granting it to the application that writes the custody artefacts turns
  # WORM back into ordinary storage while still looking like WORM in the console.
  # (It has no effect on COMPLIANCE, which nobody can bypass — but a bucket that
  # starts GOVERNANCE and a policy that carries the bypass is a real hole.)
  #
  # Legal hold is not granted: no Lerian service places one today, and it is the
  # one Object Lock control that can be toggled off again by whoever holds it.
  dynamic "statement" {
    for_each = each.value.object_lock_enabled ? [1] : []

    content {
      sid    = "ObjectRetention"
      effect = "Allow"

      actions = [
        "s3:GetObjectRetention",
        "s3:PutObjectRetention",
      ]

      resources = ["${module.buckets[each.key].s3_bucket_arn}/*"]
    }
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
