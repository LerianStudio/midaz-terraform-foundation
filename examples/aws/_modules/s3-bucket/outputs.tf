################################################################################
# Outputs
#
# The uniform datastore contract (endpoint/port/secret_arn/...) is
# deliberately NOT implemented here. See README.md: an S3 bucket has no host, no
# port and no credential — access is by IAM role, not by connection string.
# Every output below is keyed by the LOGICAL bucket name from var.buckets.
################################################################################

output "bucket_names" {
  description = "Map of logical bucket name to the real, globally unique S3 bucket name."
  value       = local.bucket_names
}

output "bucket_ids" {
  description = "Map of logical bucket name to bucket id, as reported by AWS."
  value       = { for k, m in module.buckets : k => m.s3_bucket_id }
}

output "bucket_arns" {
  description = "Map of logical bucket name to bucket ARN."
  value       = { for k, m in module.buckets : k => m.s3_bucket_arn }
}

output "bucket_regional_domain_names" {
  description = "Map of logical bucket name to region specific domain name, for SDK endpoint configuration."
  value       = { for k, m in module.buckets : k => m.s3_bucket_bucket_regional_domain_name }
}

output "iam_policy_arns" {
  description = "Map of logical bucket name to the ARN of its access policy. Attach these to the pod IAM role for IRSA."
  value       = { for k, p in aws_iam_policy.bucket_access : k => p.arn }
}

output "iam_policy_names" {
  description = "Map of logical bucket name to the name of its access policy."
  value       = { for k, p in aws_iam_policy.bucket_access : k => p.name }
}

output "iam_role_arn" {
  description = "ARN of the IRSA role. Null unless both oidc_provider_arn and service_account were supplied. This is the eks.amazonaws.com/role-arn annotation value."
  value       = one(aws_iam_role.irsa[*].arn)
}

output "iam_role_name" {
  description = "Name of the IRSA role. Null unless the role was created."
  value       = one(aws_iam_role.irsa[*].name)
}

output "tags" {
  description = "Standard Lerian tag set applied to every resource in this module."
  value       = module.naming.tags
}
