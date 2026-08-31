# Customer managed CMK used to encrypt the DocumentDB cluster storage.
module "docdb_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "1.5.0"

  count = local.create ? 1 : 0

  # Basic key configuration with automatic rotation enabled
  description             = "KMS key for DocumentDB ${module.naming.name}"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true

  # Grant key administration and usage permissions to the current AWS identity
  key_administrators = [data.aws_caller_identity.current[0].arn]
  key_users          = [data.aws_caller_identity.current[0].arn]

  # The alias already carries the environment through module.naming.name, so it
  # is unique per env inside a single AWS account. Do not append the environment
  # again - the legacy stack used "docdb/${var.name}-${var.environment}".
  aliases = ["docdb/${module.naming.name}"]

  tags = merge(module.naming.tags, { Name = "docdb/${module.naming.name}" })
}
