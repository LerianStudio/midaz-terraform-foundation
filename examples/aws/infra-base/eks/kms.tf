# Customer managed key used for envelope encryption of Kubernetes secrets
# (etcd). Brought from outside the EKS module on purpose, so the key survives
# cluster replacement and its rotation policy is explicit here.
#
# The EKS module has create_kms_key = false in main.tf: without that, the module
# would create a second, unused key and fight this one over the alias.
module "eks_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "1.5.0"

  description             = "Envelope encryption of Kubernetes secrets for ${module.naming.name}"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  key_administrators = [data.aws_caller_identity.current.arn]
  key_users          = [data.aws_caller_identity.current.arn]

  # Alias carries the environment through module.naming, so dev/stg/prd keys
  # coexist in one account. The cluster IAM role reaches the key through the
  # encryption policy the EKS module attaches (attach_encryption_policy).
  aliases = ["eks/${module.naming.name}"]

  tags = merge(module.naming.tags, {
    Name = "eks/${module.naming.name}"
  })
}
