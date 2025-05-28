# KMS key configuration for encrypting EKS cluster secrets
module "eks_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "1.5.0"

  # Basic key configuration with automatic rotation enabled
  description             = "KMS key for EKS ${var.name}"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  # Grant key administration and usage permissions to the current AWS identity
  key_administrators = [data.aws_caller_identity.current.arn]
  key_users          = [data.aws_caller_identity.current.arn]

  # Create a unique alias for the key using cluster name and environment
  aliases = ["eks/${var.name}-${var.environment}"]

  # Apply standard tags plus any additional tags provided
  tags = merge({
    Environment = lower(var.environment)
    Name        = "eks/${var.name}"
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}
