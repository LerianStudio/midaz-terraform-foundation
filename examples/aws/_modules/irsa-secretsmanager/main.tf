################################################################################
# IRSA for AWS Secrets Manager — the missing half of the credential path
#
# Every datastore module here generates a credential and writes it to Secrets
# Manager. None of them grants anybody permission to read it back: before this
# module the whole repository held exactly one secretsmanager:GetSecretValue, and
# it was a RESOURCE policy on the MSK SCRAM secret for kafka.amazonaws.com.
#
# See README.md for the measured path formats and for why ListSecrets is a
# separate variable.
################################################################################

module "naming" {
  source = "../naming"

  product     = var.product
  environment = var.environment
  component   = var.component
  extra_tags  = var.extra_tags
}

locals {
  # arn:aws:iam::123456789012:oidc-provider/oidc.eks.<region>.amazonaws.com/id/ABC
  #   -> oidc.eks.<region>.amazonaws.com/id/ABC
  oidc_provider_url = replace(
    var.oidc_provider_arn, "/^arn:[^:]+:iam::[0-9]+:oidc-provider\\//", ""
  )

  service_account_namespace = split(":", var.service_account)[0]
  service_account_name      = split(":", var.service_account)[1]

  # Secrets Manager appends six random characters to every secret ARN, so a prefix
  # pattern only matches with a trailing wildcard. The module appends it and
  # var.secret_path_prefixes refuses one, so "**" cannot be written by accident.
  secret_arns = [
    for prefix in var.secret_path_prefixes :
    "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${prefix}*"
  ]

  scoped_actions = concat(var.read_actions, var.write_actions)
}

################################################################################
# Trust policy
#
# Copied deliberately from _modules/s3-bucket/iam.tf so there is one trust shape in
# this repository rather than two. :sub pins the exact service account and :aud
# pins sts.amazonaws.com — without the :aud condition any pod in the cluster can
# mint a token for this role.
################################################################################

data "aws_iam_policy_document" "assume_role" {
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

resource "aws_iam_role" "this" {
  name                  = "${module.naming.name}-irsa"
  description           = "IRSA role for ${local.service_account_namespace}/${local.service_account_name} reaching AWS Secrets Manager"
  assume_role_policy    = data.aws_iam_policy_document.assume_role.json
  force_detach_policies = true

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-irsa" })

  lifecycle {
    # A role with a trust policy and no grants is worse than no role: the pod comes
    # up holding an identity, every vault call returns AccessDenied, and the service
    # reports a credential problem rather than a configuration one.
    precondition {
      condition     = length(local.scoped_actions) > 0 || var.allow_list_secrets || length(var.extra_policy_statements) > 0
      error_message = "This role would grant nothing. Set secret_path_prefixes with read_actions/write_actions, or allow_list_secrets, or extra_policy_statements."
    }

    # The inverse: actions with nothing to act on. Terraform would render a
    # statement with an empty resources list, which AWS rejects mid-apply with a
    # MalformedPolicyDocument that names neither variable.
    precondition {
      condition     = length(local.scoped_actions) == 0 || length(var.secret_path_prefixes) > 0
      error_message = "read_actions/write_actions were given but secret_path_prefixes is empty, so the statement would have no resource. ListSecrets is the only unscopeable action and it has its own variable (allow_list_secrets)."
    }
  }
}

################################################################################
# Policy
################################################################################

data "aws_iam_policy_document" "this" {
  dynamic "statement" {
    for_each = length(local.scoped_actions) > 0 ? [1] : []

    content {
      sid       = "ScopedSecretAccess"
      effect    = "Allow"
      actions   = local.scoped_actions
      resources = local.secret_arns
    }
  }

  # Resource "*" is not a shortcut here, it is the only legal form: AWS does not
  # evaluate ListSecrets against a resource. The caller sees every secret NAME in
  # the account and no value. Gated behind its own variable so it is a decision.
  dynamic "statement" {
    for_each = var.allow_list_secrets ? [1] : []

    content {
      sid       = "ListSecretsAccountWide"
      effect    = "Allow"
      actions   = ["secretsmanager:ListSecrets"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []

    content {
      sid    = "SecretEncryptionKey"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]

      resources = var.kms_key_arns
    }
  }

  dynamic "statement" {
    for_each = { for s in var.extra_policy_statements : s.sid => s }

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = statement.value.condition != null ? [statement.value.condition] : []

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_policy" "this" {
  name        = "${module.naming.name}-access"
  description = "Secrets Manager access for ${local.service_account_namespace}/${local.service_account_name}"
  policy      = data.aws_iam_policy_document.this.json

  tags = merge(module.naming.tags, { Name = "${module.naming.name}-access" })
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
