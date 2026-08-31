################################################################################
# Customer managed keys
#
# Two distinct CMKs on purpose:
#   * one encrypts broker data at rest,
#   * one encrypts the SASL/SCRAM secret. MSK REFUSES a SCRAM secret encrypted
#     with the AWS managed aws/secretsmanager key, so a CMK is not optional here.
#
# Separating them keeps each key policy scoped to a single service instead of
# granting Kafka and Secrets Manager access to one shared key.
################################################################################

module "msk_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "1.5.0"

  count = local.dedicated && var.encryption_at_rest_kms_key_arn == "" ? 1 : 0

  description             = "Data at rest encryption for the ${module.naming.name} MSK cluster"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true

  key_administrators = [data.aws_caller_identity.current.arn]
  key_users          = [data.aws_caller_identity.current.arn]

  aliases = ["msk/${module.naming.name}"]

  tags = merge(module.naming.tags, { Name = "msk/${module.naming.name}" })
}

module "msk_secret_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "1.5.0"

  count = local.dedicated && var.enable_sasl_scram ? 1 : 0

  description             = "SASL/SCRAM credential encryption for the ${module.naming.name} MSK cluster"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true

  key_administrators = [data.aws_caller_identity.current.arn]
  key_users          = [data.aws_caller_identity.current.arn]

  # MSK reads the secret on behalf of the cluster, so the Kafka service
  # principal needs to decrypt it — but only when going through Secrets Manager.
  key_statements = [
    {
      sid       = "AllowMskToDecryptScramSecret"
      actions   = ["kms:Decrypt", "kms:DescribeKey"]
      resources = ["*"]

      principals = [
        {
          type        = "Service"
          identifiers = ["kafka.amazonaws.com"]
        }
      ]

      conditions = [
        {
          test     = "StringEquals"
          variable = "kms:ViaService"
          values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
        }
      ]
    }
  ]

  aliases = ["msk/${module.naming.name}-scram"]

  tags = merge(module.naming.tags, { Name = "msk/${module.naming.name}-scram" })
}
