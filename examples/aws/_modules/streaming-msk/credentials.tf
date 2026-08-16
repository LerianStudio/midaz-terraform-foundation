################################################################################
# SASL/SCRAM credentials
#
# Two AWS constraints shape this file and both are non-negotiable:
#
#   1. The secret NAME must start with "AmazonMSK_". This is why the MSK secret
#      path deviates from the repository convention of
#      "{product}-{environment}-{component}/password" — the prefix comes first
#      and the naming module supplies the rest.
#
#   2. The secret must be encrypted with a customer managed CMK. The AWS managed
#      aws/secretsmanager key is rejected by aws_msk_scram_secret_association.
################################################################################

resource "random_password" "scram" {
  count = local.dedicated && var.enable_sasl_scram ? 1 : 0

  length  = 32
  special = true

  # ":" is the SCRAM field delimiter and is rejected by MSK. Quotes, backslash
  # and "/" are dropped as well so the value survives shell and URI handling in
  # the consuming charts.
  override_special = "!#$%&()*+,-.<=>?@[]^_{|}~"

  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
  min_special = 2
}

resource "aws_secretsmanager_secret" "scram" {
  count = local.dedicated && var.enable_sasl_scram ? 1 : 0

  name        = "AmazonMSK_${module.naming.name}"
  description = "SASL/SCRAM credentials for the ${module.naming.name} MSK cluster"
  kms_key_id  = module.msk_secret_kms_key[0].key_arn

  tags = merge(module.naming.tags, { Name = "AmazonMSK_${module.naming.name}" })
}

resource "aws_secretsmanager_secret_version" "scram" {
  count = local.dedicated && var.enable_sasl_scram ? 1 : 0

  secret_id = aws_secretsmanager_secret.scram[0].id

  # MSK expects exactly these two keys.
  secret_string = jsonencode({
    username = var.scram_username
    password = random_password.scram[0].result
  })
}

# Without this resource policy MSK cannot read the secret it was told to use.
data "aws_iam_policy_document" "scram_secret" {
  count = local.dedicated && var.enable_sasl_scram ? 1 : 0

  statement {
    sid       = "AllowMskToReadScramSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["kafka.amazonaws.com"]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "scram" {
  count = local.dedicated && var.enable_sasl_scram ? 1 : 0

  secret_arn = aws_secretsmanager_secret.scram[0].arn
  policy     = data.aws_iam_policy_document.scram_secret[0].json
}
